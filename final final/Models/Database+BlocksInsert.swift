//
//  Database+BlocksInsert.swift
//  final final
//
//  Editor-diff insert-path helpers for applyBlockChangesFromEditor(): sort-order
//  placement (including the bibliography-section containment rule) and Block
//  construction for editor-created rows. Split out of Database+Blocks.swift to keep
//  that file under the project's file-length limit (see .swiftlint.yml).
//

import Foundation
import GRDB

extension ProjectDatabase {

    /// Inserts editor-created blocks (sort order, image dedup) and records each temp-ID →
    /// permanent-ID mapping.
    func processEditorInserts(
        db: Database,
        inserts: [BlockInsert],
        projectId: String,
        nextSortOrder: inout Double,
        idMapping: inout [String: String]
    ) throws {
        // Track image sources inserted within this batch to prevent duplicates
        // (catches the race condition where multiple inserts of the same image arrive in one sync cycle)
        var insertedImageSources: [String: String] = [:]  // imageSrc -> permanentId

        for insert in inserts {
            let placement = try resolveInsertPlacement(
                db: db, insert: insert, projectId: projectId, idMapping: idMapping, nextSortOrder: &nextSortOrder
            )
            var block = buildInsertedBlock(
                insert: insert, projectId: projectId, sortOrder: placement.sortOrder,
                isBibliographyContainment: placement.isBibliography
            )
            let permanentId = block.id

            // Within-batch dedup: skip duplicate image inserts in the same sync cycle
            if block.blockType == .image {
                if let src = block.imageSrc, !src.isEmpty {
                    if let existingId = insertedImageSources[src] {
                        idMapping[insert.tempId] = existingId
                        DebugLog.log(.data, "[Blocks] Skipped duplicate image insert: \(src)")
                        continue
                    }
                }
            }

            try block.insert(db)

            // Record image source for within-batch dedup
            if block.blockType == .image, let src = block.imageSrc, !src.isEmpty {
                insertedImageSources[src] = permanentId
            }

            // Record the mapping from temp ID to permanent ID
            idMapping[insert.tempId] = permanentId
        }
    }

    /// Sort order plus bibliography-containment for a resolved insert placement — both are
    /// derived from the same anchor/next-block lookup, so `resolveInsertPlacement` computes
    /// them together instead of fetching the same rows twice.
    struct InsertPlacement {
        let sortOrder: Double
        /// Whether this insert lands "inside" the bibliography section (see
        /// `resolveInsertPlacement`'s doc comment for the exact containment rule).
        let isBibliography: Bool
    }

    /// Resolves sort order (midpoint after `afterBlockId`, anchored before the first block for
    /// a literal doc-start insert, or the shared running counter when neither applies) AND
    /// whether the insert lands inside the bibliography section.
    ///
    /// Containment, not inheritance: an insert counts as "inside" the bibliography section iff
    /// its anchor block is flagged `isBibliography` AND the block immediately following the
    /// anchor (by sortOrder) is ALSO flagged `isBibliography`. An insert anchored after the
    /// LAST bibliography block (anchor flagged, but no next block, or next block unflagged)
    /// always resolves `false` — regardless of where in the document the bibliography section
    /// currently sits, `BibliographySyncService.updateBibliographyBlock` always packs its
    /// regenerated fragments strictly between the section's anchor position and whatever block
    /// already followed it there (or to the end of the document, if nothing did), so the block
    /// immediately after the LAST bibliography entry is never itself bibliography content —
    /// "user types a new trailing paragraph below the references" is the ordinary case, not an
    /// edge case, whether the section is at the document's end or was reinserted back at its
    /// prior mid-document position. Naive inheritance from the anchor alone would flag that
    /// trailing paragraph `isBibliography = true`, which is worse than doing nothing: `exportBlocks()` would
    /// silently drop it from every export, and the editor-diff delete safety net in
    /// `processEditorDeletes` would refuse to let the user delete it.
    ///
    /// Containment is also suppressed — forced `false` regardless of anchor/next-block
    /// flags — when the INSERTED fragment is itself a heading that does NOT carry the
    /// bibliography-opening marker. Without this, pasting e.g. "## Discussion" between two
    /// flagged bibliography entries would inherit `isBibliography = true` from its
    /// surroundings, contradicting `BlockParser.sectionFlagCarriedForward`'s rule that ANY
    /// non-matching heading ends the section on a full reparse — and with real teeth here:
    /// `processEditorDeletes`'s safety net would refuse to let the user delete that heading,
    /// and the next bibliography regeneration's flagged-row `deleteAll` would remove it
    /// outright. Deliberately MARKER-ONLY (`BlockParser.hasBibliographyMarker`), not
    /// `BlockParser.isBibliographyHeading`'s broader bare-title match: this single-fragment
    /// insert path has no document context with which to tell the real bibliography heading
    /// apart from a user heading that merely shares its title (e.g. a chapter titled
    /// "Bibliography") — accepting a bare title here would flag that user heading regardless
    /// of where it's inserted, exactly the false-positive this whole fix removes. The
    /// bibliography-opening-heading case itself (e.g. a marker-carrying "# References" pasted
    /// directly) is unaffected — that one is flagged `true` independently by
    /// `buildInsertedBlock`'s own `hasBibliographyMarker` check, OR'd in below.
    ///
    /// Both no-anchor branches (doc-start insert, shared-counter fallback) always resolve
    /// `false` — a block with no bibliography anchor on either side can never be "inside" the
    /// section by this rule.
    func resolveInsertPlacement(
        db: Database,
        insert: BlockInsert,
        projectId: String,
        idMapping: [String: String],
        nextSortOrder: inout Double
    ) throws -> InsertPlacement {
        let insertTrimmed = insert.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNonBibliographyHeadingInsert =
            insertTrimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) != nil
            && !BlockParser.hasBibliographyMarker(insertTrimmed)

        let resolvedAfterId = insert.afterBlockId.map { idMapping[$0] ?? $0 }
        if let afterId = resolvedAfterId,
           let afterBlock = try Block.fetchOne(db, key: afterId) {
            // Find the next block to calculate midpoint
            let nextBlock = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder > afterBlock.sortOrder)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)

            let sortOrder: Double
            if let next = nextBlock {
                sortOrder = (afterBlock.sortOrder + next.sortOrder) / 2.0
            } else {
                sortOrder = afterBlock.sortOrder + 1.0
            }
            let containment = afterBlock.isBibliography && (nextBlock?.isBibliography ?? false)
            let isBibliography = isNonBibliographyHeadingInsert ? false : containment
            return InsertPlacement(sortOrder: sortOrder, isBibliography: isBibliography)
        } else if resolvedAfterId == nil, insert.atDocumentStart == true {
            // Block is literal ProseMirror doc position 0 — anchor it before the
            // current first block instead of falling through to append-at-end.
            let firstBlock = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)
            let sortOrder = firstBlock.map { $0.sortOrder / 2.0 } ?? 1.0
            return InsertPlacement(sortOrder: sortOrder, isBibliography: false)
        } else {
            // No afterBlockId (and not atDocumentStart), or afterBlockId present but
            // unresolvable — use the shared running counter
            let sortOrder = nextSortOrder
            nextSortOrder += 1.0
            return InsertPlacement(sortOrder: sortOrder, isBibliography: false)
        }
    }

    /// Builds the Block row for an editor insert: detects heading syntax (belt-and-suspenders
    /// with JS detection), marks footnote-definition/image blocks, resolves the
    /// `isBibliography` flag (see `resolveInsertPlacement`'s doc comment for the containment
    /// rule `isBibliographyContainment` encodes), and recalculates word count.
    func buildInsertedBlock(
        insert: BlockInsert, projectId: String, sortOrder: Double, isBibliographyContainment: Bool
    ) -> Block {
        // Detect heading from markdown content (belt-and-suspenders with JS detection)
        let blockType: BlockType
        let effectiveHeadingLevel: Int?
        let insertTrimmed = insert.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hMatch = insertTrimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
            blockType = .heading
            effectiveHeadingLevel = insertTrimmed[hMatch].filter({ $0 == "#" }).count
        } else {
            blockType = BlockType(rawValue: insert.blockType) ?? .paragraph
            effectiveHeadingLevel = insert.headingLevel
        }

        let permanentId = UUID().uuidString
        let insertTextContent = blockType == .heading
            ? BlockParser.extractTextContent(from: insertTrimmed, blockType: .heading)
            : insert.textContent

        var block = Block(
            id: permanentId,
            projectId: projectId,
            sortOrder: sortOrder,
            blockType: blockType,
            textContent: insertTextContent,
            markdownFragment: insert.markdownFragment,
            headingLevel: effectiveHeadingLevel,
            // A genuinely new section_break block (the /break "text before" / "text
            // after" / "split" cases all insert one) must be flagged as a pseudo-section
            // here — observeOutlineBlocks and fetchOutlineBlocks filter on isPseudoSection,
            // not blockType, so without this the block silently never appears in the
            // outline sidebar despite being correctly typed as .sectionBreak.
            isPseudoSection: blockType == .sectionBreak
        )
        block.recalculateWordCount()

        // isBibliography: containment resolved by the caller (resolveInsertPlacement) OR'd
        // with the independent case of the inserted fragment itself carrying the
        // bibliography-opening MARKER (e.g. a marker-carrying "# References" typed/pasted
        // directly) — that heading is "inside" the section it opens regardless of anchor
        // placement. Deliberately marker-only, not `BlockParser.isBibliographyHeading`'s
        // broader bare-title match: see `resolveInsertPlacement`'s doc comment for why this
        // single-fragment path can't safely adopt a heading by title alone.
        block.isBibliography = isBibliographyContainment
            || (blockType == .heading && BlockParser.hasBibliographyMarker(insertTrimmed))

        // Mark footnote definitions as isNotes (safety net for editor-created blocks)
        if insertTrimmed.range(of: #"^\[\^\d+\]:\s*"#, options: .regularExpression) != nil {
            block.isNotes = true
        }

        // Auto-populate image metadata from markdown for image blocks
        if blockType == .image {
            let meta = BlockParser.parseImageFragmentMeta(from: insertTrimmed)
            block.imageSrc = meta.src
            block.imageAlt = meta.alt
            block.imageCaption = meta.caption
            // Parse {width=N%} from Pandoc attributes
            block.imageWidth = BlockParser.parseImageWidthPercent(from: insertTrimmed)
        }

        return block
    }
}
