//
//  Database+BlocksReplace.swift
//  final final
//
//  Block replace operations: full-document and range replacement, with heading/image
//  metadata preservation.
//

import Foundation
import GRDB

// MARK: - Block Heading Metadata

/// Preserved heading metadata during block replacement (avoids large tuple)
private struct HeadingMetadata {
    let status: SectionStatus?
    let tags: [String]?
    let wordGoal: Int?
    let goalType: GoalType
    let aggregateGoal: Int?
    let aggregateGoalType: GoalType
    let isBibliography: Bool
    let isNotes: Bool
}

/// Preserved image metadata during block replacement
private struct ImageMeta {
    let imageCaption: String?
    let imageWidth: Int?
}

/// A single existing heading's id + metadata, queued by title so duplicate-titled headings
/// are matched by occurrence index (1st old "Notes" -> 1st new "Notes", 2nd -> 2nd, ...)
/// instead of every same-titled heading colliding on one scalar slot. See the FIFO-queue
/// usage below for why: absolute position would churn every downstream id when a paragraph
/// is inserted above a heading, so occurrence-within-title is the stable key instead.
private struct PreservedHeading {
    let id: String
    let metadata: HeadingMetadata
}

private extension PreservedHeading {
    /// Build a `PreservedHeading` snapshot from an existing `Block`. Shared by every site
    /// that queues an existing heading by title, so the id + metadata always come from the
    /// same source occurrence.
    init(from block: Block) {
        self.init(
            id: block.id,
            metadata: HeadingMetadata(
                status: block.status,
                tags: block.tags,
                wordGoal: block.wordGoal,
                goalType: block.goalType,
                aggregateGoal: block.aggregateGoal,
                aggregateGoalType: block.aggregateGoalType,
                isBibliography: block.isBibliography,
                isNotes: block.isNotes
            )
        )
    }
}

/// The sortOrder region reserved for preserved (undeleted) rows that `reanchorPreservedRows`
/// will place immediately after the newly-inserted content: `count` rows starting at `anchor`.
/// Bundled so `shiftBlocksAfterRange` can check its reservation invariant while staying
/// under the function_parameter_count limit.
private struct PreservedRowReservation {
    let anchor: Double
    let count: Int
}

// MARK: - ProjectDatabase Block Replace

extension ProjectDatabase {

    /// Replace all blocks for a project, preserving heading IDs and metadata by title match.
    /// Used during initial parse, project open, and non-zoomed CodeMirror re-parse.
    ///
    /// - Parameter preservingMachineManagedBlocks: Defaults to `false`, which leaves every
    ///   pre-existing call site (the 7 re-parse/roundtrip paths in
    ///   `EditorViewState+Zoom.swift`, `ContentView+ProjectLifecycle.swift`,
    ///   `ViewNotificationModifiers.swift` x2, `BlockSyncService.swift`, plus
    ///   `restoreEntireProject`) byte-identical to this function's prior behavior: delete
    ///   every existing block and reinsert `blocks` fresh, preserving only heading id/
    ///   metadata by title match. Pass `true` ONLY from the two section-restore call sites
    ///   in `SnapshotService` (`restoreSectionReplace`/`restoreSectionAsDuplicate`): their
    ///   `blocks` come from re-parsing `content.markdown` AFTER
    ///   `rebuildContentFromSections()` has filtered `isBibliography` sections out of it
    ///   (see that function's doc comment) — so, unlike every other caller, `blocks`
    ///   contains NO bibliography content at all, and an unconditional delete-and-replace
    ///   would permanently wipe the real bibliography (owned by `BibliographySyncService`)
    ///   instead of leaving it alone. `restoreEntireProject` stays on the default `false`:
    ///   its markdown is reassembled from the FULL block table, bibliography included.
    ///
    ///   On the DEFAULT (`false`) path only, `replaceBlocks` now also carries a restored
    ///   `isBibliography` flag forward onto the non-heading entry rows beneath a heading when
    ///   `applyPreservedHeading` re-flagged that heading from preserved metadata but the fresh
    ///   parse didn't itself recognize it (a custom bibliography header name changed since the
    ///   heading was written, or a demoted heading level). The carry is bounded by whichever
    ///   comes first — the next heading, or the document's own end-of-bibliography marker
    ///   (`BlockParser.bibliographyEndMarker`, via the transient `Block.endsBibliographyRun`
    ///   flag `BlockParser.parse()` sets) — and capped by how many non-heading `isBibliography`
    ///   rows the project already had. See `carryBibliographyFlagForward` for the full
    ///   mechanism. This is PREVENTIVE — it stops the flag from being lost on a document that
    ///   is currently healthy — not CURATIVE: it does not repair a document already in the
    ///   damaged state (heading flagged, entries not), where the terminator already sits
    ///   immediately after the heading and bounds nothing to carry. That limitation is
    ///   deliberate.
    ///
    ///   When `true`, reuses the same protection/reanchoring machinery
    ///   `replaceBlocksInRange` uses for its zoomed re-parse path (`buildHeadingQueues`,
    ///   `deleteBlocksInRange`, `handleMachineManagedBlock`, `reanchorPreservedRows`) —
    ///   but scoped to bibliography ONLY via each helper's `protectingNotes`/
    ///   `handlingNotes: false` parameter, never Notes. Notes is deliberately given no
    ///   special handling here for a stronger reason than a preference: Notes content is
    ///   ABSENT from `blocks` at these two call sites, not merely present-but-unprotected.
    ///   `parseHeaders` never emits a "Notes" section boundary in the first place, because
    ///   `Section.isNotes` has no production writer (every `isNotes: true` write constructs
    ///   a `Block`, never a `Section`) — so `existingNotesTitle` is always nil and
    ///   `rebuildContentFromSections` cannot emit Notes content into the re-parsed markdown
    ///   at all. Protecting isBibliography only is therefore the complete and correct
    ///   answer here, not a narrower choice made for convenience: there is no Notes content
    ///   in `blocks` to protect or to collide with. (This does mean a single-section
    ///   restore today deletes the existing Notes rows with no replacement content coming
    ///   back from `blocks` — `FootnoteSyncService` self-heals the structural "# Notes"
    ///   heading and terminator afterward, but not the actual footnote text. That is a
    ///   pre-existing bug, out of scope for this preservation work, and is being filed
    ///   separately.)
    func replaceBlocks(
        _ blocks: [Block],
        for projectId: String,
        preservingMachineManagedBlocks: Bool = false
    ) throws {
        try write { db in
            let existingBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Build image metadata lookup from existing blocks
            var imageMetaBySrc = buildImageMetadataIndex(from: existingBlocks)

            if !imageMetaBySrc.isEmpty {
                DebugLog.log(.data, "[replaceBlocks] Image metadata to preserve: \(imageMetaBySrc.mapValues { "width=\($0.imageWidth ?? -1)" })")
            }

            if preservingMachineManagedBlocks {
                // Bibliography-only preservation path -- see this function's doc comment for
                // why Notes gets no special handling here.
                let headingQueueResult = buildHeadingQueues(existing: existingBlocks, newBlocks: blocks, protectingNotes: false)
                var headingsByTitle = headingQueueResult.queues
                let protectedHeadingIds = headingQueueResult.protectedIds

                // Every existing isBibliography row this replace must NOT delete: the
                // protected "# Bibliography" heading (above) plus every non-heading
                // bibliography row (entries, terminator). Bibliography-only mirror of
                // replaceBlocksInRange's `preservedRowIds` (which also includes isNotes rows
                // there — deliberately dropped here).
                let preservedRowIds: [String] = existingBlocks
                    .filter { block in
                        protectedHeadingIds.contains(block.id) ||
                        (block.isBibliography && block.blockType != .heading)
                    }
                    .map { $0.id }

                // Delete everything else -- see deleteBlocksInRange's `protectingNotes: false`
                // branch for the exact predicate (never delete a non-heading isBibliography
                // row or a protectedHeadingIds heading; Notes participates in the normal
                // delete-and-reinsert flow like any other heading/content).
                try deleteBlocksInRange(
                    db: db,
                    projectId: projectId,
                    startSortOrder: nil,
                    endSortOrder: nil,
                    protectedHeadingIds: protectedHeadingIds,
                    protectingNotes: false
                )

                var notesRowByLabel: [String: Block] = [:]
                var claimedNotesLabels: Set<String> = []

                for (index, var block) in blocks.enumerated() {
                    block.sortOrder = Double(index)

                    // Bibliography-shaped incoming block: skip (defensive -- `blocks` never
                    // legitimately contains one at these call sites, since bibliography
                    // content is excluded from the source markdown entirely). `handlingNotes:
                    // false` means Notes-shaped blocks fall straight through to the normal
                    // insert flow below instead of being merged into a preserved row.
                    if try handleMachineManagedBlock(
                        db: db,
                        block: block,
                        notesRowByLabel: &notesRowByLabel,
                        claimedNotesLabels: &claimedNotesLabels,
                        handlingNotes: false
                    ) {
                        continue
                    }

                    applyPreservedHeading(to: &block, queues: &headingsByTitle)
                    applyPreservedImageMetadata(to: &block, index: &imageMetaBySrc)
                    try block.insert(db)
                }

                // Re-anchor preserved bibliography rows immediately after all newly-inserted
                // content -- see reanchorPreservedRows for why leaving them at a stale
                // position risks a numeric collision with the freshly-sequenced new blocks.
                if !preservedRowIds.isEmpty {
                    try reanchorPreservedRows(db: db, rowIds: preservedRowIds, anchorBase: Double(blocks.count))
                }

                try renumberSortOrders(db: db, projectId: projectId, now: Date())
                return
            }

            // Original behavior (preservingMachineManagedBlocks == false): delete every
            // existing block and reinsert `blocks` fresh, preserving only heading id/
            // metadata by title match — plus the bibliography carry-forward described in this
            // function's doc comment above.

            // Queue existing headings by title, in existing-document order. A duplicate title
            // (two headings both named "Notes", say) gets a queue of length > 1; consuming the
            // new parse in order pops the front of the matching title's queue, so the nth
            // heading titled T in the new parse inherits id+metadata from the nth heading
            // titled T in the old rows — not just the first (id) and last (metadata) as before,
            // which churned ids and cross-contaminated metadata on every duplicate title.
            var headingsByTitle: [String: [PreservedHeading]] = [:]
            for block in existingBlocks where block.blockType == .heading {
                headingsByTitle[block.textContent, default: []].append(PreservedHeading(from: block))
            }

            // Prepare every block in memory FIRST — heading id/metadata restoration and image
            // metadata gap-fill both only read `existingBlocks`/`imageMetaBySrc` (already
            // fetched above), never the live table — so hoisting this above the delete is
            // behavior-preserving for both of those on its own. It has to happen before the
            // delete because `carryBibliographyFlagForward` right below needs the WHOLE
            // prepared array (to find the next heading, or the terminator) before it can run.
            var prepared = blocks

            // Indices of headings where `applyPreservedHeading` had to RESTORE isBibliography
            // from preserved metadata because the fresh parse itself didn't recognise the
            // heading (a detection mismatch) — as opposed to a healthy heading the parser
            // already flagged on its own. Only the former should ever arm
            // `carryBibliographyFlagForward` below; see that function's doc comment for why.
            var mismatchedBibliographyHeadingIndices: Set<Int> = []

            for index in prepared.indices {
                let parserRecognisedBibliography = prepared[index].blockType == .heading && prepared[index].isBibliography

                // Preserve heading ID and metadata by occurrence-indexed title match (see
                // applyPreservedHeading): pop the front of this title's queue and apply id +
                // metadata from that SAME popped entry in one branch, so they can never come
                // from two different existing occurrences of the same title. A unique title
                // has a one-element queue, which behaves exactly like the old first-match-wins.
                applyPreservedHeading(to: &prepared[index], queues: &headingsByTitle)

                if prepared[index].blockType == .heading, prepared[index].isBibliography, !parserRecognisedBibliography {
                    mismatchedBibliographyHeadingIndices.insert(index)
                }

                // Preserve image metadata by imageSrc match (see applyPreservedImageMetadata).
                if applyPreservedImageMetadata(to: &prepared[index], index: &imageMetaBySrc) {
                    let block = prepared[index]
                    DebugLog.log(.data, "[replaceBlocks] Image block src=\(block.imageSrc ?? "nil") width=\(block.imageWidth ?? -1)")
                }
            }

            // Carry a restored isBibliography heading flag forward onto the entry rows beneath
            // it — see `carryBibliographyFlagForward`'s doc comment for the full mechanism and
            // its bounds. `budget` is the count of non-heading isBibliography rows the project
            // already had, from BEFORE this replace — a pure cap, independent of anything the
            // carry itself decides to flag.
            carryBibliographyFlagForward(
                &prepared,
                mismatchedHeadingIndices: mismatchedBibliographyHeadingIndices,
                budget: existingBlocks.filter { $0.isBibliography && $0.blockType != .heading }.count
            )

            try Block.filter(Block.Columns.projectId == projectId).deleteAll(db)

            for var block in prepared {
                try block.insert(db)
            }

        }
    }

    /// Replace blocks within a sort order range (used during zoomed CodeMirror re-parse).
    /// Only deletes/inserts blocks in [startSortOrder, endSortOrder), preserving blocks outside the zoom.
    /// Restores heading metadata (status, tags, wordGoal, goalType) by title match.
    func replaceBlocksInRange(
        _ newBlocks: [Block],
        for projectId: String,
        startSortOrder: Double,
        endSortOrder: Double?
    ) throws {
        try write { db in
            // 1. Fetch existing blocks in range to preserve heading metadata and IDs
            var existingQuery = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder >= startSortOrder)
            if let end = endSortOrder {
                existingQuery = existingQuery.filter(Block.Columns.sortOrder < end)
            }
            let existingBlocks = try existingQuery.order(Block.Columns.sortOrder).fetchAll(db)

            // 2. Build the heading id/metadata pop-queue (keyed by title) plus the set of
            // existing heading ids that must never be deleted or popped. This is the
            // highest-risk piece of logic in this function — see buildHeadingQueues for the
            // full occurrence-index / count-mismatch-protection rationale.
            let headingQueueResult = buildHeadingQueues(existing: existingBlocks, newBlocks: newBlocks)
            var headingsByTitle = headingQueueResult.queues
            let protectedHeadingIds = headingQueueResult.protectedIds

            // Safety net: Notes and Bibliography rows are machine-managed by their sync
            // services (FootnoteSyncService / BibliographySyncService), symmetric with the
            // guard in Database+Blocks.swift's applyBlockChangesFromEditor. A zoomed CodeMirror
            // re-parse must never silently delete them just because the current in-editor view
            // doesn't include them — flushContentToDatabase strips the mini-Notes text before
            // parsing for the footnote-insertion path, so newBlocks legitimately contains zero
            // isNotes rows on that call, which previously meant any real Notes row whose
            // sortOrder fell inside [start, end) was deleted with nothing to replace it.
            // Existing non-heading rows of these types are preserved untouched below (excluded
            // from the delete query); if newBlocks legitimately contains a matching (same-label)
            // Notes row, it is merged into the preserved row in place instead of inserted as a
            // duplicate alongside it. See buildNotesRowIndex for the lookup this builds.
            var notesRowByLabel = buildNotesRowIndex(from: existingBlocks)

            // The "# Notes"/"# Bibliography" HEADING itself needs a different rule than the
            // paragraph rows above: it normally survives via the delete-then-reinsert-by-title-
            // match flow below (which already preserves its id/metadata safely), but that only
            // works if its own occurrence slot actually gets popped by a same-titled newBlocks
            // heading (see protectedHeadingIds, computed above alongside the queue). When it
            // doesn't — newBlocks omits the title entirely (the mini-Notes-stripped scenario),
            // or a colliding duplicate title consumes an earlier slot and leaves this
            // occurrence's slot unreached — protectedHeadingIds already excludes it from the
            // delete query below, so unconditionally deleting it here can no longer orphan it.

            // Every row the delete-then-reinsert logic below will NOT touch: preserved
            // (undeleted) non-heading isNotes/isBibliography rows, plus a protected
            // "# Notes"/"# Bibliography" heading (protectedHeadingIds, above). These keep
            // whatever DB row they already have — nothing below assigns them a fresh sortOrder,
            // so they'd otherwise be left at their stale original position. Collected here (in
            // original relative order, since existingBlocks is already sorted by sortOrder) so
            // step 3.5 below can re-anchor them immediately after the new content instead of
            // leaving them at a stale absolute position that can numerically collide with, or
            // fall inside, the freshly-sequenced new blocks — which previously let a newly-typed
            // paragraph land between the preserved Notes heading and its own footnote
            // definition, splitting the Notes section.
            let preservedRowIds: [String] = existingBlocks
                .filter { block in
                    protectedHeadingIds.contains(block.id) ||
                    ((block.isNotes || block.isBibliography) && block.blockType != .heading)
                }
                .map { $0.id }

            // Build image metadata lookup
            var imageMetaBySrc = buildImageMetadataIndex(from: existingBlocks)

            // 2. Delete blocks in range — see deleteBlocksInRange for the exact
            // never-delete predicate (non-heading isNotes/isBibliography rows, and any
            // protectedHeadingIds heading).
            try deleteBlocksInRange(
                db: db,
                projectId: projectId,
                startSortOrder: startSortOrder,
                endSortOrder: endSortOrder,
                protectedHeadingIds: protectedHeadingIds
            )

            // 2.5. Shift blocks after range to prevent sort order collisions — see
            // shiftBlocksAfterRange for why insertEnd must reserve room for
            // preservedRowIds.count too, not just newBlocks.count. preservedRowsAnchor is
            // hoisted here (rather than inlined into insertEnd below) so it can also be passed
            // to shiftBlocksAfterRange's own reservation check, and reused unchanged as
            // reanchorPreservedRows' anchorBase below — one shared value instead of the same
            // expression written out twice.
            let preservedRowsAnchor = startSortOrder + Double(newBlocks.count)
            try shiftBlocksAfterRange(
                db: db,
                projectId: projectId,
                endSortOrder: endSortOrder,
                insertEnd: preservedRowsAnchor + Double(preservedRowIds.count),
                reservation: PreservedRowReservation(
                    anchor: preservedRowsAnchor,
                    count: preservedRowIds.count
                )
            )

            // Track footnote labels already claimed within this batch — whether by merging into
            // a preserved row or by falling through to a normal insert below — so a second
            // newBlocks entry with the same label (e.g. two "[^1]:" paragraphs from a
            // copy-paste slip or an interrupted renumbering) never produces a second DB row for
            // that label. First-occurrence-wins, matching the imageMetaBySrc dedup convention
            // used elsewhere in this file.
            var claimedNotesLabels: Set<String> = []

            // 3. Insert new blocks with sort orders starting at startSortOrder
            for (index, var block) in newBlocks.enumerated() {
                block.sortOrder = startSortOrder + Double(index)

                // Bibliography-skip / notes-merge-or-dedup — see handleMachineManagedBlock for
                // the exact three-way outcome (skip / merge-then-skip / fall through to normal
                // insert) this must preserve.
                if try handleMachineManagedBlock(
                    db: db,
                    block: block,
                    notesRowByLabel: &notesRowByLabel,
                    claimedNotesLabels: &claimedNotesLabels
                ) {
                    continue
                }

                // 4 & 5. Preserve heading ID and metadata by occurrence-indexed title match
                // (see applyPreservedHeading).
                applyPreservedHeading(to: &block, queues: &headingsByTitle)

                // 6. Preserve image metadata by imageSrc match (see applyPreservedImageMetadata).
                applyPreservedImageMetadata(to: &block, index: &imageMetaBySrc)

                try block.insert(db)
            }

            // 3.5. Re-anchor preserved isNotes/isBibliography rows (and any protected heading,
            // see preservedRowIds above) immediately after all newly-inserted content — see
            // reanchorPreservedRows for why leaving them at a stale position can split a
            // preserved Notes section from its own footnote definitions.
            if !preservedRowIds.isEmpty {
                try reanchorPreservedRows(
                    db: db,
                    rowIds: preservedRowIds,
                    anchorBase: preservedRowsAnchor
                )
            }

            // 6. Normalize sort orders inline (atomic with delete+insert above). Trap: do not
            // merge this with the public normalizeSortOrders(projectId:) in
            // Database+BlocksReorder.swift — see renumberSortOrders for why they must stay
            // separate (a single hoisted `now` here vs. a fresh Date() per row there).
            try renumberSortOrders(db: db, projectId: projectId, now: Date())
        }
    }

}

// MARK: - Replace Helpers

/// Mechanical extractions from `replaceBlocks` and `replaceBlocksInRange` — no behavior change
/// from the originals.
private extension ProjectDatabase {

    // MARK: Image metadata

    /// Build a src -> preserved-metadata lookup from existing image blocks (used for the
    /// imageWidth/imageCaption gap-fill during block replacement).
    func buildImageMetadataIndex(from existingBlocks: [Block]) -> [String: ImageMeta] {
        var imageMetaBySrc: [String: ImageMeta] = [:]
        for block in existingBlocks where block.blockType == .image {
            if let src = block.imageSrc, !src.isEmpty {
                imageMetaBySrc[src] = ImageMeta(
                    imageCaption: block.imageCaption,
                    imageWidth: block.imageWidth
                )
            }
        }
        return imageMetaBySrc
    }

    /// Extract a caption from a leading `<!-- caption: ... -->` comment line in a markdown
    /// fragment (legacy pre-`BlockParser.parseImageFragmentMeta` format). Anchored (`^`) so
    /// this can only match a comment immediately preceding the image, not one appearing
    /// anywhere else in the fragment. Returns nil if no such comment is present.
    func extractLegacyImageCaption(from fragment: String) -> String? {
        let frag = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let captionRange = frag.range(
            of: #"^<!--\s*caption:\s*(.*?)\s*-->"#, options: .regularExpression
        ) else {
            return nil
        }
        let fullMatch = String(frag[captionRange])
        guard let textRange = fullMatch.range(
            of: #"(?<=caption:\s).*?(?=\s*-->)"#, options: .regularExpression
        ) else {
            return nil
        }
        return String(fullMatch[textRange])
    }

    /// Preserve image metadata by imageSrc match: legacy-caption gap-fill, then
    /// imageWidth/imageCaption gap-fill from the existing-blocks index (first-match-wins).
    /// Returns whether `block` was an image block with a usable src — i.e. whether the
    /// gap-fill logic actually ran — so a caller that only logs for real image blocks
    /// (`replaceBlocks`) knows when to log. `replaceBlocksInRange` has no such log and
    /// simply discards the result.
    @discardableResult
    func applyPreservedImageMetadata(to block: inout Block, index: inout [String: ImageMeta]) -> Bool {
        guard block.blockType == .image, let src = block.imageSrc, !src.isEmpty else { return false }

        // Legacy migration only: recover a caption from a leading
        // <!-- caption: ... --> comment line, same guard as the gap-fill block
        // below (only if the parser hasn't already set imageCaption — new-format
        // fragments set it, even to "", via BlockParser.parseImageFragmentMeta) and
        // anchored (`^`) so this can only match a comment immediately preceding the
        // image, not one appearing anywhere else in the fragment.
        if block.imageCaption == nil, let legacyCaption = extractLegacyImageCaption(from: block.markdownFragment) {
            block.imageCaption = legacyCaption
        }

        // Gap-fill only: don't overwrite parser-extracted values with stale DB cache
        if let meta = index[src] {
            if block.imageWidth == nil, let width = meta.imageWidth {
                block.imageWidth = width
            }
            if block.imageCaption == nil, let caption = meta.imageCaption {
                block.imageCaption = caption
            }
            index.removeValue(forKey: src)  // first-match-wins
        }

        return true
    }

    // MARK: Heading pop-queue

    /// Preserve heading ID and metadata by occurrence-indexed title match: pop the front of
    /// this title's queue and apply id + metadata from that SAME popped entry in one branch
    /// (not two separate lookups), so they can never come from two different existing
    /// occurrences of the same title. A unique title has a one-element queue, which behaves
    /// exactly like the old first-match-wins.
    func applyPreservedHeading(to block: inout Block, queues: inout [String: [PreservedHeading]]) {
        if block.blockType == .heading,
           var queue = queues[block.textContent], !queue.isEmpty {
            let preserved = queue.removeFirst()
            queues[block.textContent] = queue
            block.id = preserved.id
            block.status = preserved.metadata.status
            block.tags = preserved.metadata.tags
            block.wordGoal = preserved.metadata.wordGoal
            block.goalType = preserved.metadata.goalType
            block.aggregateGoal = preserved.metadata.aggregateGoal
            block.aggregateGoalType = preserved.metadata.aggregateGoalType
            if preserved.metadata.isBibliography { block.isBibliography = true }
            if preserved.metadata.isNotes { block.isNotes = true }
        }
    }

    /// Restore `isBibliography` onto the entry rows beneath a heading that
    /// `applyPreservedHeading` just re-flagged from preserved metadata BECAUSE the fresh
    /// parse itself failed to recognise the heading (a detection mismatch) — never for a
    /// heading the parse recognised on its own. `mismatchedHeadingIndices` (built by the
    /// caller's prep loop, by comparing each heading's parser-derived `isBibliography` before
    /// `applyPreservedHeading` runs against its restored value after) is exactly that set: a
    /// healthy, parser-recognised heading's entries are already correctly flagged and need no
    /// help, and must never spend the `budget` below.
    ///
    /// WHY THIS EXISTS: `applyPreservedHeading` restores the flag onto the HEADING only.
    /// When `BlockParser.parse()` didn't recognise that heading (a custom header name since
    /// changed, a demoted heading level), every entry below it comes back unflagged. The next
    /// bibliography regeneration then deletes only the flagged heading and regenerates,
    /// leaving the old entries behind as duplicate body text in the document and in every
    /// export.
    ///
    /// TWO BOUNDS, WHICHEVER COMES FIRST — the terminator bound is ADDITIVE, it does NOT
    /// replace the next-heading rule:
    ///  - a heading stops the run, exactly as `BlockParser.sectionFlagCarriedForward` does;
    ///  - the first block after the arming heading carrying `endsBibliographyRun` stops it
    ///    too, inclusively, and can stop it EARLIER than a heading would.
    /// Reading the terminator as replacing the heading rule would let a run cross an
    /// intervening chapter heading and flag it — never do that.
    ///
    /// The terminator search MUST start strictly after the arming heading, and MUST take the
    /// FIRST match, not the last. A `lastIndex` search over the whole array lets a duplicate
    /// or stale terminator anywhere downstream extend the run over real user prose — flagged
    /// prose is dropped from every export and then deleted outright by the next regeneration.
    /// No terminator after the heading => carry NOTHING: an unbounded run is worse than an
    /// unrestored one.
    ///
    /// `assembleMarkdownForEditor` emits exactly ONE terminator per document — after the last
    /// flagged row anywhere, not one per section — so in a document with more than one
    /// bibliography-titled heading only the LAST such section is genuinely terminator-bounded;
    /// an earlier mismatched section's forward search finds that later terminator (past its
    /// own section) and effectively falls back to the next-heading bound only. This is still
    /// safe (a heading always stops the run, and `budget` still caps it) but is strictly less
    /// precise than the single-section case — documented here rather than left implicit.
    ///
    /// `budget` is the second, independent bound: never flag more non-heading blocks in one
    /// call than the project currently HAS non-heading `isBibliography` rows. A pure count —
    /// no content matching against existing rows, deliberately. This caps the blast radius
    /// even if the predicate above is later changed and gets it wrong.
    ///
    /// KNOWN LIMITATION, by design: on a document ALREADY in the damaged state (heading
    /// flagged, entries not), the assembler places the terminator directly after the heading,
    /// so this arms and disarms in the same step and restores nothing. This prevents
    /// recurrence on a healthy document; it does not heal an already-broken one.
    func carryBibliographyFlagForward(
        _ blocks: inout [Block],
        mismatchedHeadingIndices: Set<Int>,
        budget: Int
    ) {
        guard budget > 0 else { return }
        var remaining = budget
        var index = blocks.startIndex
        while index < blocks.endIndex {
            guard blocks[index].blockType == .heading, blocks[index].isBibliography,
                  mismatchedHeadingIndices.contains(index) else {
                index += 1
                continue
            }
            guard let end = blocks[blocks.index(after: index)...]
                .firstIndex(where: { $0.endsBibliographyRun }) else {
                index += 1
                continue
            }
            var cursor = blocks.index(after: index)
            while cursor <= end {
                if blocks[cursor].blockType == .heading { break }
                if remaining == 0 { break }
                blocks[cursor].isBibliography = true
                remaining -= 1
                cursor = blocks.index(after: cursor)
            }
            index = cursor
        }
    }

    /// Build the pop-queue of existing headings by title (consumed occurrence-by-occurrence
    /// as `newBlocks` is walked in `replaceBlocksInRange`) plus the set of existing heading
    /// ids that must never be deleted or popped.
    ///
    /// Count how many NEW headings share each title — this is how many old occurrences of
    /// that title the pop queue below will actually reach (the 1st new heading titled T
    /// claims the 1st old occurrence titled T, the 2nd new claims the 2nd old, ...). Used to
    /// decide, per OLD occurrence, whether its own slot will ever be popped.
    ///
    /// Group existing headings by title, in existing-range order (preserves zoomedSectionId
    /// across re-parses), then split each title's occurrences into `protectedIds` (never
    /// deleted, never eligible to be popped) vs. `queues` (the pop queue consumed by
    /// `applyPreservedHeading`). A duplicate title gets a queue of length > 1; consuming the
    /// new parse in order pops the front of the matching title's queue, so the nth heading
    /// titled T in the new parse inherits id+metadata from the nth QUEUED heading titled T in
    /// the old rows — occurrence-index matching, not absolute position (position would churn
    /// every downstream id when a paragraph is inserted above a heading).
    ///
    /// Real invariant this provides: a machine-managed (isNotes/isBibliography) old heading
    /// is protected specifically when ITS OWN occurrence slot — its position among old
    /// headings sharing its title — falls at or beyond the new-heading count for that title,
    /// i.e. no new heading will ever reach it to pop it. A title wholly absent from newBlocks
    /// has zero consumable slots, so every occurrence of it is protected — the common case,
    /// unchanged from before. The fix only changes behavior on a COUNT MISMATCH: e.g. a plain
    /// user heading that collides in title with the machine "Notes" heading used to strip
    /// protection from every "Notes"-titled occurrence (title-only check), including the
    /// machine one, even when the machine heading's own queue slot was never going to be
    /// reached by the single colliding new heading — silently deleting the machine section
    /// with nothing to bring it back. Because protected occurrences are excluded from the
    /// queue entirely, they are never candidates to be popped in the first place; a
    /// still-protected heading's queue slot can never be popped, but that was never the
    /// actual bug — the bug was protection LAPSING (a title leaving the protected set)
    /// despite the specific machine occurrence's slot remaining unreachable. See
    /// `ZoomDataIntegrityTests`'s title-collision-with-protected-heading tests for the exact
    /// scenario this guards.
    /// - Parameter protectingNotes: Whether an isNotes heading occurrence beyond the
    ///   consumable count is ALSO protected, alongside isBibliography (always protected
    ///   regardless of this flag). Defaults to `true`, matching `replaceBlocksInRange`'s
    ///   only call site unchanged. `replaceBlocks`' new bibliography-only preservation path
    ///   passes `false`: Notes gets no special protection there -- see that function's doc
    ///   comment for why (Notes content is absent from its incoming `blocks` entirely, same
    ///   as bibliography, so there is nothing there for protection to preserve or duplicate).
    func buildHeadingQueues(
        existing: [Block],
        newBlocks: [Block],
        protectingNotes: Bool = true
    ) -> (queues: [String: [PreservedHeading]], protectedIds: Set<String>) {
        var newHeadingCountByTitle: [String: Int] = [:]
        for block in newBlocks where block.blockType == .heading {
            newHeadingCountByTitle[block.textContent, default: 0] += 1
        }

        var existingHeadingsByTitle: [String: [Block]] = [:]
        for block in existing where block.blockType == .heading {
            existingHeadingsByTitle[block.textContent, default: []].append(block)
        }
        var protectedHeadingIds: Set<String> = []
        var headingsByTitle: [String: [PreservedHeading]] = [:]
        for (title, occurrences) in existingHeadingsByTitle {
            let consumable = newHeadingCountByTitle[title, default: 0]
            for (index, block) in occurrences.enumerated() {
                if ((protectingNotes && block.isNotes) || block.isBibliography) && index >= consumable {
                    protectedHeadingIds.insert(block.id)
                    continue
                }
                headingsByTitle[title, default: []].append(PreservedHeading(from: block))
            }
        }
        return (headingsByTitle, protectedHeadingIds)
    }

    // MARK: replaceBlocksInRange-only helpers

    /// Build a footnote-label -> existing-row lookup from existing isNotes blocks, used to
    /// merge a same-label incoming Notes row into its existing DB row instead of inserting a
    /// duplicate (see `handleMachineManagedBlock`).
    func buildNotesRowIndex(from existing: [Block]) -> [String: Block] {
        var notesRowByLabel: [String: Block] = [:]
        for block in existing where block.isNotes {
            if let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
                notesRowByLabel[label] = block
            }
        }
        return notesRowByLabel
    }

    /// Delete blocks in `[startSortOrder, endSortOrder)` (or the whole project, when
    /// `startSortOrder` is `nil` -- used by `replaceBlocks`' preservation path, which has no
    /// range to speak of) — never delete a non-heading isBibliography row (machine-managed,
    /// see the safety-net comment in `replaceBlocksInRange`), and never delete a
    /// protectedHeadingIds heading. Any other heading — including one of these when
    /// newBlocks DOES contain a same-titled replacement — is deleted here and recreated
    /// through the delete-then-reinsert-by-title-match flow.
    ///
    /// - Parameter protectingNotes: Whether a non-heading isNotes row is ALSO exempt from
    ///   deletion, alongside isBibliography (always exempt regardless of this flag).
    ///   Defaults to `true`, matching `replaceBlocksInRange`'s only call site unchanged.
    ///   `replaceBlocks`' bibliography-only preservation path passes `false` -- see that
    ///   function's doc comment for why Notes must go through the normal delete-and-
    ///   reinsert flow there instead of being preserved.
    func deleteBlocksInRange(
        db: Database,
        projectId: String,
        startSortOrder: Double?,
        endSortOrder: Double?,
        protectedHeadingIds: Set<String>,
        protectingNotes: Bool = true
    ) throws {
        var deleteQuery = Block.filter(Block.Columns.projectId == projectId)
        if let start = startSortOrder {
            deleteQuery = deleteQuery.filter(Block.Columns.sortOrder >= start)
        }
        if protectingNotes {
            deleteQuery = deleteQuery.filter(
                Block.Columns.blockType == BlockType.heading.rawValue ||
                (Block.Columns.isNotes == false && Block.Columns.isBibliography == false)
            )
        } else {
            deleteQuery = deleteQuery.filter(
                Block.Columns.blockType == BlockType.heading.rawValue ||
                Block.Columns.isBibliography == false
            )
        }
        if !protectedHeadingIds.isEmpty {
            deleteQuery = deleteQuery.filter(!protectedHeadingIds.contains(Block.Columns.id))
        }
        if let end = endSortOrder {
            deleteQuery = deleteQuery.filter(Block.Columns.sortOrder < end)
        }
        try deleteQuery.deleteAll(db)
    }

    /// Shift blocks after the range forward to prevent sort order collisions when the
    /// inserted blocks — plus any preserved rows re-anchored by `reanchorPreservedRows` —
    /// overflow the original `[startSortOrder, endSortOrder)` range. The caller computes
    /// `insertEnd` as `startSortOrder + newBlocks.count + preservedRowIds.count` — the
    /// `preservedRowIds.count` term (not just `newBlocks.count`) must be included, or
    /// `reanchorPreservedRows`' positions can themselves collide with whatever comes after
    /// the range.
    ///
    /// `reservation.anchor` and `reservation.count` exist to make that invariant checkable at
    /// runtime for FUTURE, independent callers — ones that compute `insertEnd` themselves from
    /// scratch rather than reusing `reservation.anchor`. Dropping the reservation term
    /// type-checks and compiles fine, but silently corrupts sortOrder once
    /// `reanchorPreservedRows` runs; the precondition below is what would catch that. For the
    /// CURRENT (and only) caller, this is documentation of the invariant rather than live
    /// enforcement: it passes `insertEnd: preservedRowsAnchor + Double(preservedRowIds.count)`
    /// and builds `reservation` from those same two values (`anchor: preservedRowsAnchor,
    /// count: preservedRowIds.count`), so `insertEnd` and `reservation.anchor +
    /// Double(reservation.count)` are the same IEEE 754 expression over the same operands — an
    /// arithmetic identity — and the precondition can never fire there, in either the growing
    /// or shrinking case. Checking against `insertEnd` alone (or against
    /// `endSortOrder`) can't tell a genuine under-reservation from a legitimate call where
    /// `newBlocks.count` shrinks the range enough that no shift is needed at all — only
    /// comparing against `reservation.anchor` (independent of how `insertEnd` was computed)
    /// can, which is why this guard is worth keeping for a future caller even though it's inert
    /// for today's. Any new caller must build `insertEnd` using the same grouping/expression
    /// shape (reservation anchor + reservation count) it passes as
    /// `reservation.anchor`/`reservation.count` — a differently-grouped but mathematically
    /// equivalent expression can round to a different `Double` and land a hair below the
    /// threshold, turning this data-integrity guard into an unexpected crash. This is a
    /// `precondition` (not `assert`), so it's live — and can trap — in Release builds too.
    func shiftBlocksAfterRange(
        db: Database,
        projectId: String,
        endSortOrder: Double?,
        insertEnd: Double,
        reservation: PreservedRowReservation
    ) throws {
        precondition(
            insertEnd >= reservation.anchor + Double(reservation.count),
            "shiftBlocksAfterRange: insertEnd (\(insertEnd)) doesn't reserve room for " +
            "\(reservation.count) preserved row(s) anchored at \(reservation.anchor) — needs " +
            "to be >= \(reservation.anchor + Double(reservation.count)). Did a caller drop the " +
            "preservedRowIds.count term when computing insertEnd?"
        )
        if let end = endSortOrder {
            if insertEnd > end {
                let shift = insertEnd - end
                try db.execute(
                    sql: """
                        UPDATE block SET sortOrder = sortOrder + ?, updatedAt = ?
                        WHERE projectId = ? AND sortOrder >= ?
                        """,
                    arguments: [shift, Date(), projectId, end]
                )
            }
        }
    }

    /// Handle a `newBlocks` entry that may be machine-managed before it reaches the normal
    /// heading/image preserve-and-insert flow. Returns `true` when the block was fully
    /// handled here and the caller must `continue` (skip the normal insert); `false` when it
    /// should fall through.
    ///
    /// Three-way outcome, in order:
    /// 1. Bibliography-shaped, non-heading: skipped outright — Bibliography rows are 100%
    ///    machine-generated (BibliographySyncService is the sole writer); the existing
    ///    (preserved, undeleted) row above remains authoritative. The "# Bibliography"
    ///    heading itself is excluded here (it goes through the normal
    ///    delete-then-reinsert-by-title-match flow, which already handles it).
    /// 2. Notes-shaped, non-heading, with a footnote label already claimed in this batch:
    ///    dropped — a duplicate label within the same batch (e.g. two "[^1]:" paragraphs from
    ///    a copy-paste slip) must not produce a second DB row for that label.
    /// 3. Notes-shaped, non-heading, with a label matching a preserved existing row: merged
    ///    into that row in place (content + word count + updatedAt) instead of inserted as a
    ///    duplicate — same rule as the `applyBlockChangesFromEditor` guard. A stale/mismatched
    ///    label falls through to a normal insert rather than being silently dropped. (The
    ///    "# Notes" heading itself never matches `parseNotesLabel`'s "[^N]:" pattern, so it
    ///    always falls through to the title-match flow, same as any other heading.)
    ///
    /// - Parameter handlingNotes: Whether outcome 2/3 (Notes-shaped merge-or-dedup) is active
    ///   at all. Defaults to `true`, matching `replaceBlocksInRange`'s only call site
    ///   unchanged. `replaceBlocks`' bibliography-only preservation path passes `false`: a
    ///   Notes-shaped block there always falls straight through to a normal insert (outcome
    ///   1, the bibliography-shaped check, is unaffected by this flag either way) -- see that
    ///   function's doc comment for why Notes must never be merged into a preserved row there.
    func handleMachineManagedBlock(
        db: Database,
        block: Block,
        notesRowByLabel: inout [String: Block],
        claimedNotesLabels: inout Set<String>,
        handlingNotes: Bool = true
    ) throws -> Bool {
        if block.isBibliography && block.blockType != .heading {
            DebugLog.log(.data, "[replaceBlocksInRange] Skipping insert of bibliography-shaped block (machine-managed)")
            return true
        }

        if handlingNotes, block.isNotes && block.blockType != .heading,
           let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
            if claimedNotesLabels.contains(label) {
                // Duplicate label within this same batch (e.g. two "[^1]:" paragraphs from a
                // copy-paste slip) — the first occurrence above already claimed this label
                // (merged or inserted); drop this one rather than producing a second DB row
                // with the same footnote label.
                DebugLog.log(.data, "[replaceBlocksInRange] Skipping duplicate notes label in batch: \(label)")
                return true
            }
            claimedNotesLabels.insert(label)

            if var existingNotesRow = notesRowByLabel[label] {
                existingNotesRow.markdownFragment = block.markdownFragment
                existingNotesRow.textContent = block.textContent
                existingNotesRow.recalculateWordCount()
                existingNotesRow.updatedAt = Date()
                try existingNotesRow.update(db)
                notesRowByLabel.removeValue(forKey: label)
                return true
            }
        }

        return false
    }

    /// Re-anchor preserved isNotes/isBibliography rows (and any protected heading) immediately
    /// after all newly-inserted content, in their original relative order. They keep their
    /// stale original sortOrder through the merge/skip logic above, which can numerically fall
    /// inside the range the new blocks now occupy — most commonly when endSortOrder is nil
    /// (zooming a document's last section, which sits right before its own trailing
    /// footnotes). Re-fetches each row fresh by id (rather than reusing the pre-loop
    /// existingBlocks snapshot) so a content update already applied by the merge logic above
    /// isn't clobbered by a stale copy.
    func reanchorPreservedRows(db: Database, rowIds: [String], anchorBase: Double) throws {
        let now = Date()
        for (offset, rowId) in rowIds.enumerated() {
            guard var row = try Block.fetchOne(db, key: rowId) else { continue }
            let newSortOrder = anchorBase + Double(offset)
            if row.sortOrder != newSortOrder {
                row.sortOrder = newSortOrder
                row.updatedAt = now
                try row.update(db)
            }
        }
    }

    /// Normalize sort orders to sequential integers, atomically with the delete+insert above
    /// (tie-breaking: headings before non-headings at the same sortOrder). Trap: do not merge
    /// this with the public `normalizeSortOrders(projectId:)` in Database+BlocksReorder.swift —
    /// they look identical but this one takes a single hoisted `now` (one timestamp for the
    /// whole batch) while the public one calls `Date()` fresh inside its loop (a distinct
    /// timestamp per row); unifying them would change the timestamp granularity of a normalize
    /// pass, not which rows get touched.
    func renumberSortOrders(db: Database, projectId: String, now: Date) throws {
        let allProjectBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
        let sorted = allProjectBlocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        for (index, var block) in sorted.enumerated() {
            let newSortOrder = Double(index + 1)
            if block.sortOrder != newSortOrder {
                block.sortOrder = newSortOrder
                block.updatedAt = now
                try block.update(db)
            }
        }
    }

}
