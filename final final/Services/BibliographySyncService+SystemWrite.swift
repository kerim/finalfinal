//
//  BibliographySyncService+SystemWrite.swift
//  final final
//
//  Phase 2 (t-94369a83), §2.1: the bibliography write/removal bodies, routed through
//  `DocumentWriter`'s system-write queue (§1) instead of writing directly. Bodies are
//  `nonisolated static func`s taking only `Database` and plain `Sendable` values --
//  never `ProjectDatabase` (a `ProjectDatabase` call that opens its own read/write
//  would crash -- GRDB "not reentrant" -- if called from inside the already-open write
//  transaction `DocumentWriter.applySystemWrite` runs these in).
//
//  `writeBibliographyRows`/`writeBibliographyRemoval` are `BibliographySyncService.
//  updateBibliographyBlock`/`removeBibliographyBlock`'s own transaction bodies, moved
//  here near-verbatim (every existing comment kept) with one addition: each deleted
//  old bibliography row's tombstone anchor (`SystemWriteBody.deletedAnchors`), per the
//  plan's §2.1 table --
//    - Regeneration (at least one new row written): every deleted old id -> `.after`
//      the LAST newly-written row -- a late insert anchored inside/after the old
//      section reappears after the new one.
//    - Zero-row regeneration, or a plain removal (no new rows at all): every deleted
//      old id falls back to `.after(predecessorAnchor(of the FIRST deleted row,
//      computed BEFORE any delete))`, or `.documentStart` if there is no predecessor.
//

import Foundation
import GRDB

extension BibliographySyncService {
    /// `predecessorAnchor` (§2.1): the row with the greatest `sortOrder` strictly
    /// below `blockId`'s own, or `.documentStart` if none. Same SQL as
    /// `Database+BlockWriteStamp.swift`'s own tombstone-anchor computation (the
    /// addendum A2 §2 "record each about-to-be-deleted row's own predecessor WHILE it
    /// still exists" query) -- reused verbatim rather than re-derived, so the two
    /// anchor computations can never silently drift apart.
    nonisolated static func predecessorAnchor(db: Database, blockId: String, projectId: String) throws -> DeletedAnchor {
        if let predecessorId = try String.fetchOne(db, sql: """
                SELECT id FROM block WHERE projectId = ? \
                AND sortOrder < (SELECT sortOrder FROM block WHERE id = ?) \
                ORDER BY sortOrder DESC LIMIT 1
                """, arguments: [projectId, blockId]) {
            return .after(predecessorId)
        }
        return .documentStart
    }

    /// Moved verbatim from `updateBibliographyBlock`'s transaction body (formerly
    /// wrapped in `try database.write { db in ... }`) -- `db` now arrives as the
    /// parameter `DocumentWriter.applySystemWrite` already has an open transaction on,
    /// rather than this function opening its own. Returns the count of fragments
    /// written as `value` (diagnostic only; no caller inspects it yet) plus the
    /// tombstone anchors described in this file's header comment.
    nonisolated static func writeBibliographyRows(
        db: Database, content: String, projectId: String
    ) throws -> SystemWriteBody<Int> {
        // Re-derive the effective header name from INSIDE this serialized GRDB write
        // section -- NOT from a read captured on the MainActor before this closure was
        // scheduled to run (the prior shape here). `content`'s own heading text was
        // already baked in by `generateBibliographyMarkdown`, called before this
        // function, using whatever name was current at THAT moment. If a rename's write
        // (`BibliographyHeadingRenamer.rename`) commits in between, that baked-in name
        // goes stale. GRDB serializes writes, so reading the effective name again here --
        // inside the write closure, rather than before it -- is what makes BOTH
        // write-orderings converge on whichever name is actually current in settings at
        // the moment EACH write actually commits, regardless of which of the two closures
        // was scheduled first. See `BibliographyHeadingRenamer.rename`'s doc comment for
        // the counterpart half of this fix (why IT doesn't need a busy-guard against this
        // function). Phase 2: both writes now go through the SAME ordered writer queue,
        // so this re-read is (additionally) what lets a rename that reserved its own
        // system-write turn AFTER this one still win if it applies first -- see
        // `performBibliographyHeaderNameChange`'s own doc comment.
        let headerName = ExportSettings.load().effectiveBibliographyHeaderName
        // Fetch the existing bibliography blocks BEFORE deleting them, so the regenerated
        // bibliography can be reinserted back where the old one was, instead of always
        // landing past whatever the user has typed after it since. See the anchor/step
        // derivation below for how that position is reconstructed after the delete.
        let existingBib = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == true)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        // Anchor = the sortOrder the regenerated bibliography should return to: the REAL
        // bibliography section's own heading position. The insert-time path (see
        // `Database+BlocksInsert.swift`'s `resolveInsertPlacement`/`buildInsertedBlock`)
        // only flags a heading `isBibliography = true` when it carries the literal
        // `<!-- ::auto-bibliography:: -->` marker (`BlockParser.hasBibliographyMarker`) --
        // a bare-title heading a user types or pastes (e.g. an ordinary "# Bibliography"
        // chapter heading, a completely normal thing to write) is NOT flagged by that path
        // at all, regardless of where in the document it lands. A second flagged heading
        // can still occur, though: pasted text that happens to carry the marker literally,
        // or a historical orphan already flagged in the DB from before this and the
        // insert-time fix (see the "Historical orphans" comment further below) -- so
        // picking the lowest-sortOrder flagged heading unconditionally could still pick the
        // wrong one instead of the real section's, relocating the entire regenerated
        // bibliography to the wrong position.
        //
        // Disambiguate with the same containment rule `resolveInsertPlacement` already
        // applies: a flagged heading is the REAL bibliography heading only if the block
        // immediately following it (by sortOrder, among ALL blocks -- not just
        // bibliography-flagged ones) is ALSO bibliography-flagged. `generateBibliographyMarkdown`
        // always emits heading-plus-entries together, so the real section's heading always
        // has a bibliography-flagged block right after it; a lone stray heading with
        // ordinary content after it does not.
        //
        // Falls back to the simpler "first flagged heading, unconditional" selector -- and,
        // failing that, the first surviving bibliography block that is NOT a bare opening
        // marker (see `isBareOpeningMarker` below) -- when no heading satisfies the stricter
        // check. Covers first-ever generation (no heading exists yet to satisfy anything)
        // and an already-degenerate state (e.g. a heading-only bibliography with no
        // surviving entries after it) so those cases don't regress. The bare-marker
        // exclusion at this last level exists because a marker orphan (an entire block
        // whose content IS the bare opening-marker literal, left behind when CodeMirror's
        // Source Mode hides the marker as an invisible atomic decoration and the user
        // deletes the visible bibliography section around it) is not a heading, so it can
        // only ever surface here -- unexcluded, it would hijack regeneration to the
        // orphan's stale mid-document position instead of the document end. `nil` means
        // there was no prior bibliography at all (or the only surviving block WAS a bare
        // marker orphan), which keeps today's append-at-the-end behavior.
        let realBibliographyHeadingAnchor = try existingBib.first { candidate in
            guard candidate.blockType == .heading else { return false }
            let nextBlock = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder > candidate.sortOrder)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)
            return nextBlock?.isBibliography ?? false
        }?.sortOrder
        let anchor = realBibliographyHeadingAnchor
            ?? existingBib.first { $0.blockType == .heading }?.sortOrder
            ?? existingBib.first { !$0.isBareOpeningMarker }?.sortOrder

        // §2.1 tombstones: computed BEFORE any delete, for the zero-row-regeneration
        // fallback below. The first (lowest-sortOrder) surviving bibliography row is
        // "the first deleted bibliography row" the plan names.
        let fallbackAnchor: DeletedAnchor
        if let firstDeletedId = existingBib.first?.id {
            fallbackAnchor = try predecessorAnchor(db: db, blockId: firstDeletedId, projectId: projectId)
        } else {
            fallbackAnchor = .documentStart
        }

        // Delete ALL existing bibliography blocks (handles duplicates)
        try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == true)
            .deleteAll(db)

        // Split "# Bibliography\n\nEntry1\n\nEntry2\n\n" into individual fragments
        // so each DB block maps 1:1 with a ProseMirror top-level node.
        // This prevents block-sync from seeing temp-ID paragraphs as spurious INSERTs.
        let rawBlocks = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Placement: `start` is where the first fragment (the heading, always index 0 --
        // see generateBibliographyMarkdown) lands; `step` is the sortOrder distance
        // between consecutive fragments.
        let start: Double
        let step: Double
        if let anchor {
            start = anchor
            // Whatever now immediately follows the anchor position (e.g. a trailing
            // paragraph the user typed after the old bibliography) bounds how far the
            // regenerated fragments can spread before colliding with it.
            let nextBlock = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder > anchor)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)
            if let nextBlock {
                let gap = nextBlock.sortOrder - anchor
                step = min(1.0, gap / Double(max(rawBlocks.count, 1)))
                if step < 1e-6 {
                    // Defensive logging only -- no block mutation. `gap / N` still keeps
                    // every insert strictly increasing and correctly ordered relative to
                    // `nextBlock` for any positive gap; this just makes an unusually tight
                    // squeeze visible if it ever happens.
                    DebugLog.log(.bib, "[BibliographySyncService] Tight bibliography sortOrder gap: " +
                        "anchor=\(anchor) next=\(nextBlock.sortOrder) step=\(step)")
                }
            } else {
                // Bibliography was already the last thing in the document -- nothing to
                // pack against, so it simply stays put without needing to shift.
                step = 1.0
            }
        } else {
            // First-ever generation: no prior bibliography blocks existed, so there is
            // nothing to anchor back to. Unchanged existing behavior -- append at the end.
            let maxSortOrder = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder.desc)
                .fetchOne(db)?.sortOrder ?? 0
            start = maxSortOrder + 1.0
            step = 1.0
        }

        // No self-heal sweep here (deliberately removed — a prior version tried to
        // delete unflagged orphan rows by exact-text match, position-bounded to
        // "at/after the bibliography heading"). That bound was unsound in both
        // directions at once: computed from `maxSortOrder` AFTER the delete above, an
        // orphan surviving in the table shifts the next heading's placement above it,
        // permanently excluding that orphan from future sweeps; widened to catch it,
        // the same unbounded-above range would just as readily delete a trailing user
        // paragraph that happens to exact-match a regenerated fragment, silently and
        // without undo. `Database+Blocks.swift`'s insert-time containment fix (see
        // `resolveInsertPlacement`) prevents new orphans from being created at all, and
        // `BlockParser.parse()`'s `sectionFlagCarriedForward` re-derives every block's
        // `isBibliography` flag from scratch — no drift possible — on every full
        // document reparse (project open with no existing blocks, Source Mode's
        // debounced re-parse, snapshot restore).
        //
        // Historical orphans (rows already mis-flagged `isBibliography == true` from
        // before the insert-time fix) do NOT self-heal from any of that, and must not be
        // assumed to: `assembleMarkdownForEditor` inserts the terminator immediately
        // after the LAST block flagged `isBibliography`, which in an already-corrupted
        // document IS the orphaned paragraph itself, so the regenerated markdown places
        // the terminator AFTER the orphan every time — a reparse of that markdown
        // re-derives the identical wrong flag via `sectionFlagCarriedForward`, not a
        // corrected one. Worse, `ContentView+ProjectLifecycle.swift`'s
        // `loadInitialContent` only calls `BlockParser.parse()` when no blocks exist yet
        // for the project; once blocks exist (which they do for any already-corrupted
        // document) project open just reassembles them via `assembleMarkdownForEditor`
        // and never reparses at all. Clearing existing historical orphans would need a
        // dedicated one-time migration — out of scope here.
        //
        // UPDATE: the orphan-as-anchor half of this harm is now closed. The `anchor`
        // derivation above excludes any bare-opening-marker block (`isBareOpeningMarker`,
        // both the unstripped-literal and legacy-load stripped-empty shapes) from its last
        // fallback level, so a historical orphan row can no longer hijack regeneration to
        // its own stale position. Deriving the anchor is not this comment's job, so it does
        // not delete anything on its own — but that is not the end of the story for a project
        // that actually regenerates: the orphan row is still flagged `isBibliography == true`
        // (that flag is exactly why it had to be excluded above), so the SAME regeneration's
        // own `deleteAll(isBibliography == true)` call just below removes it as a side effect,
        // like any other stale bibliography row — see `BibliographyOrphanMarkerAnchorTests.
        // swift`, which asserts this twice. The genuine remaining gap is narrower than "the
        // orphan is never cleaned up": a project that has an orphan but NEVER regenerates (no
        // citation is ever added or removed afterward) still has that orphan sitting in the
        // database forever, since nothing on the read/display path deletes it either. That
        // case alone still requires the dedicated one-time migration described above.

        var lastNewId: String?
        for (index, fragment) in rawBlocks.enumerated() {
            let isHeading = fragment.hasPrefix("#")
            // Rewrite the heading's own markdown text to the freshly-read `headerName`
            // too, not just `textContent` below -- otherwise a rename landing between
            // this write being scheduled and it actually committing would leave the
            // persisted `markdownFragment` (what both editors actually render) showing
            // the stale name baked into `content` while `textContent` showed the fresh
            // one, self-desyncing the very row this write is about to insert. Idempotent
            // when the name hasn't changed: `fragment` already reads "# \(headerName)" in
            // that case, so this just rebuilds the identical string.
            let effectiveFragment = isHeading ? "# \(headerName)" : fragment
            let textContent = isHeading
                ? headerName
                : BlockParser.extractTextContent(from: fragment, blockType: .paragraph)
            var block = Block(
                projectId: projectId,
                sortOrder: start + Double(index) * step,
                blockType: isHeading ? .heading : .paragraph,
                textContent: textContent,
                markdownFragment: effectiveFragment,
                headingLevel: isHeading ? 1 : nil,
                status: isHeading ? .final_ : nil,
                wordCount: MarkdownUtils.wordCount(for: textContent),
                isBibliography: true
            )
            try block.insert(db)
            lastNewId = block.id
        }

        // §2.1 tombstones: every OLD bibliography row this write deleted re-anchors to
        // just after the newly-written section when there IS one; otherwise (zero-row
        // regeneration -- `rawBlocks` came out empty) it falls back to the predecessor
        // of the first deleted row, computed above before the delete.
        var deletedAnchors: [String: DeletedAnchor] = [:]
        let anchorForDeleted: DeletedAnchor = lastNewId.map(DeletedAnchor.after) ?? fallbackAnchor
        for old in existingBib {
            deletedAnchors[old.id] = anchorForDeleted
        }

        return SystemWriteBody(value: rawBlocks.count, deletedAnchors: deletedAnchors)
    }

    /// Moved verbatim from `removeBibliographyBlock`'s transaction body. No new rows
    /// are ever written here, so every deleted old row falls back to
    /// `predecessorAnchor(of the first deleted row)` (or `.documentStart`) -- the same
    /// "zero-row" case `writeBibliographyRows` above falls back to.
    nonisolated static func writeBibliographyRemoval(
        db: Database, projectId: String
    ) throws -> SystemWriteBody<Int> {
        let existingBib = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == true)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
        guard !existingBib.isEmpty else {
            return SystemWriteBody(value: 0)
        }

        let fallbackAnchor: DeletedAnchor
        if let firstDeletedId = existingBib.first?.id {
            fallbackAnchor = try predecessorAnchor(db: db, blockId: firstDeletedId, projectId: projectId)
        } else {
            fallbackAnchor = .documentStart
        }

        try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == true)
            .deleteAll(db)

        var deletedAnchors: [String: DeletedAnchor] = [:]
        for old in existingBib {
            deletedAnchors[old.id] = fallbackAnchor
        }
        return SystemWriteBody(value: existingBib.count, deletedAnchors: deletedAnchors)
    }
}
