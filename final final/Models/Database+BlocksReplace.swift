//
//  Database+BlocksReplace.swift
//  final final
//
//  Block replace operations: full-document and range replacement. The two main entry
//  points, plus the shared support types they and their helpers use. The actual helper
//  functions live in the sibling files Database+BlocksReplace+Preservation.swift (heading/
//  image metadata preservation) and Database+BlocksReplace+RowOps.swift (live-db row
//  mutation: delete, shift, merge, re-anchor, renumber).
//

import Foundation
import GRDB

// MARK: - Block Heading Metadata

/// Preserved heading metadata during block replacement (avoids large tuple)
struct HeadingMetadata {
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
struct ImageMeta {
    let imageCaption: String?
    let imageWidth: Int?
}

/// A single existing heading's id + metadata, queued by title so duplicate-titled headings
/// are matched by occurrence index (1st old "Notes" -> 1st new "Notes", 2nd -> 2nd, ...)
/// instead of every same-titled heading colliding on one scalar slot. See the FIFO-queue
/// usage below for why: absolute position would churn every downstream id when a paragraph
/// is inserted above a heading, so occurrence-within-title is the stable key instead.
struct PreservedHeading {
    let id: String
    let metadata: HeadingMetadata
}

extension PreservedHeading {
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
struct PreservedRowReservation {
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
    ///   `rebuildContentFromSections()` has filtered `isBibliography` AND `isNotes` sections
    ///   out of it (see that function's doc comment) — so, unlike every other caller,
    ///   `blocks` contains NO bibliography or Notes content at all, and an unconditional
    ///   delete-and-replace would permanently wipe the real bibliography (owned by
    ///   `BibliographySyncService`) and the real footnote text (owned by
    ///   `FootnoteSyncService`) instead of leaving them alone. `restoreEntireProject` stays
    ///   on the default `false`: its markdown is reassembled from the FULL block table,
    ///   bibliography and Notes included.
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
    ///   `deleteBlocksInRange`, `handleMachineManagedBlock`, `reanchorPreservedRows`) — now
    ///   scoped to BOTH bibliography AND Notes, on equal footing, via each helper's
    ///   `protectingNotes`/`handlingNotes: true` parameter. This is genuinely equal footing,
    ///   not just a structurally-similar call shape: `notesRowByLabel` below is seeded from
    ///   `buildNotesRowIndex(from: existingBlocks)`, the exact same call
    ///   `replaceBlocksInRange` makes, so `handleMachineManagedBlock`'s same-label merge path
    ///   can actually find a preserved row to merge into here too — without that seed, the
    ///   lookup would be empty and every labeled incoming Notes block would fall through to a
    ///   normal insert, duplicating the preserved row's footnote definition instead of merging
    ///   into it. Notes gets the exact same protection bibliography does here because it needs
    ///   it for the exact same reason:
    ///   `Section.isNotes` now has a production writer (`SectionReconciler`'s dedicated
    ///   `isNotes` match path — see that type's doc comment), so `parseHeaders` can emit a
    ///   flagged "Notes" section boundary, `existingNotesTitle` is no longer always nil, and
    ///   `rebuildContentFromSections` can genuinely include real footnote text in the
    ///   markdown these two call sites re-parse into `blocks` — but `rebuildContentFromSections`
    ///   deliberately excludes it (see that function's doc comment), so `blocks` here is
    ///   guaranteed Notes-free at these two call sites, same as bibliography. Before this
    ///   fix, a single-section restore silently deleted the existing Notes rows with no
    ///   replacement content coming back from `blocks` — the real, production-shaped data-loss
    ///   bug this preservation path now closes.
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
                // Bibliography + Notes preservation path -- see this function's doc comment
                // for why both are protected on equal footing here.
                let headingQueueResult = buildHeadingQueues(existing: existingBlocks, newBlocks: blocks, protectingNotes: true)
                var headingsByTitle = headingQueueResult.queues
                let protectedHeadingIds = headingQueueResult.protectedIds

                // Every existing isBibliography/isNotes row this replace must NOT delete: the
                // protected "# Bibliography"/"# Notes" heading (above) plus every non-heading
                // bibliography/notes row (entries, terminator). Mirrors
                // replaceBlocksInRange's `preservedRowIds` exactly.
                let preservedRowIds: [String] = existingBlocks
                    .filter { block in
                        protectedHeadingIds.contains(block.id) ||
                        ((block.isBibliography || block.isNotes) && block.blockType != .heading)
                    }
                    .map { $0.id }

                // Delete everything else -- see deleteBlocksInRange's `protectingNotes: true`
                // branch for the exact predicate (never delete a non-heading isBibliography/
                // isNotes row or a protectedHeadingIds heading).
                try deleteBlocksInRange(
                    db: db,
                    projectId: projectId,
                    startSortOrder: nil,
                    endSortOrder: nil,
                    protectedHeadingIds: protectedHeadingIds,
                    protectingNotes: true
                )

                let notesIndex = buildNotesRowIndex(from: existingBlocks)
                var notesRowByLabel = notesIndex.byLabel
                var notesContinuationsByOwner = notesIndex.continuationsByOwner
                var claimedNotesLabels: Set<String> = []
                var currentNotesOwnerLabel: String?
                // Genuinely-NEW continuation paragraphs (a footnote that grew: more incoming
                // labelless continuations than preserved rows existed for) -- collected here
                // instead of inserted immediately, and given a real position adjacent to
                // their owner only once the owner's FINAL (reanchored) position is known. See
                // `insertDeferredContinuations`'s doc comment.
                var deferredNotesContinuations: [String: [Block]] = [:]

                for (index, var block) in blocks.enumerated() {
                    block.sortOrder = Double(index)

                    // Bibliography-shaped incoming block: skip (defensive -- `blocks` never
                    // legitimately contains one at these call sites, since bibliography
                    // content is excluded from the source markdown entirely). `handlingNotes:
                    // true` merges a same-label incoming Notes row into its preserved row in
                    // place, same as replaceBlocksInRange -- see handleMachineManagedBlock.
                    if try handleMachineManagedBlock(
                        db: db,
                        block: block,
                        notesRowByLabel: &notesRowByLabel,
                        claimedNotesLabels: &claimedNotesLabels,
                        notesContinuationsByOwner: &notesContinuationsByOwner,
                        currentNotesOwnerLabel: &currentNotesOwnerLabel,
                        deferredNewContinuations: &deferredNotesContinuations,
                        handlingNotes: true
                    ) {
                        continue
                    }

                    applyPreservedHeading(to: &block, queues: &headingsByTitle)
                    applyPreservedImageMetadata(to: &block, index: &imageMetaBySrc)
                    try block.insert(db)
                }

                // Deliberately NO `deleteUnclaimedContinuations` call on this path -- unlike
                // `replaceBlocksInRange`, see below. `blocks` here is guaranteed Notes-free at
                // every real production call site (this function's own doc comment); any
                // Notes-shaped content that DOES appear in it is an accidental/collision case
                // to merge-if-possible (the labeled branch above), never an authoritative,
                // exhaustive statement of "here is everything this footnote's continuations
                // should be now." Treating an unclaimed continuation as "the user deleted it"
                // here would be wrong precisely because this call was never attempting to
                // represent that footnote's continuations at all -- confirmed by
                // BibliographySectionFlagTests+DataIntegrity.swift's "Issue 2 fixed" and
                // "MUST-FIX 1 regression guard" tests, both of which seed a continuation,
                // pass `blocks` that omits it entirely (in the MUST-FIX-1 case, even while
                // the SAME footnote's labeled definition IS present and correctly merges),
                // and assert the continuation survives untouched. `replaceBlocksInRange`'s
                // `newBlocks`, by contrast, is a reparse of a specific bounded range that ITS
                // callers assert is exhaustive for that range -- see that function's own call
                // to `deleteUnclaimedContinuations` and `MultiParagraphFootnoteReplaceTests`'
                // shrink test.

                // Re-anchor preserved bibliography/Notes rows immediately after all
                // newly-inserted content -- see reanchorPreservedRows for why leaving them at
                // a stale position risks a numeric collision with the freshly-sequenced new
                // blocks.
                if !preservedRowIds.isEmpty {
                    try reanchorPreservedRows(db: db, rowIds: preservedRowIds, anchorBase: Double(blocks.count))
                }

                // MUST run AFTER reanchorPreservedRows -- see insertDeferredContinuations'
                // doc comment for why placement depends on the owner's FINAL position.
                try insertDeferredContinuations(db: db, projectId: projectId, deferredByOwner: deferredNotesContinuations)

                try renumberSortOrders(db: db, projectId: projectId, now: Date())
                try Self.recomputeSectionParents(db: db, projectId: projectId)
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

            // Whether the fresh parse recognised ANY bibliography heading at all, anywhere in
            // `blocks` — see `applyPreservedHeading`'s `restoringBibliography` doc comment for
            // why this is a single, call-wide gate rather than a per-heading check: once the
            // fresh parse has correctly identified the real heading, restoring a stale
            // `isBibliography` flag onto any OTHER heading by title match would just be the
            // bare-title false positive persisting through this function instead of being
            // fixed by it.
            let parseFoundBibliographyHeading = blocks.contains {
                ($0.blockType == .heading || $0.blockType == .bibliography) && $0.isBibliography
            }

            for index in prepared.indices {
                let parserRecognisedBibliography = prepared[index].blockType == .heading && prepared[index].isBibliography

                // Gated on BOTH conditions: the fresh parse recognised no bibliography heading
                // at all (as before), AND this specific heading has a genuine, non-empty,
                // terminator-bounded run beneath it in `prepared` — see
                // `hasGenuineBibliographyRun`'s doc comment. Without the second condition, a
                // document already in the KNOWN-LIMITATION damaged state (heading flagged,
                // entries not, terminator immediately after the heading) would resurrect the
                // stale flag onto a heading with nothing real beneath it — the empty-run
                // shape `BibliographyOpeningSelector` itself refuses to select as evidence.
                // Only meaningful for headings (`applyPreservedHeading` only ever reads this
                // for `block.blockType == .heading`), so non-heading blocks skip the check.
                let restoringBibliography = !parseFoundBibliographyHeading
                    && prepared[index].blockType == .heading
                    && hasGenuineBibliographyRun(in: prepared, after: index)

                // Preserve heading ID and metadata by occurrence-indexed title match (see
                // applyPreservedHeading): pop the front of this title's queue and apply id +
                // metadata from that SAME popped entry in one branch, so they can never come
                // from two different existing occurrences of the same title. A unique title
                // has a one-element queue, which behaves exactly like the old first-match-wins.
                applyPreservedHeading(
                    to: &prepared[index],
                    queues: &headingsByTitle,
                    restoringBibliography: restoringBibliography
                )

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

            try Self.recomputeSectionParents(db: db, projectId: projectId)
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
            let notesIndex = buildNotesRowIndex(from: existingBlocks)
            var notesRowByLabel = notesIndex.byLabel
            var notesContinuationsByOwner = notesIndex.continuationsByOwner
            var currentNotesOwnerLabel: String?
            // Genuinely-NEW continuation paragraphs (a footnote that grew) -- see
            // `insertDeferredContinuations`'s doc comment; populated by
            // handleMachineManagedBlock below, consumed after reanchorPreservedRows runs.
            var deferredNotesContinuations: [String: [Block]] = [:]

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
                    claimedNotesLabels: &claimedNotesLabels,
                    notesContinuationsByOwner: &notesContinuationsByOwner,
                    currentNotesOwnerLabel: &currentNotesOwnerLabel,
                    deferredNewContinuations: &deferredNotesContinuations
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

            // Any continuation row the incoming batch never claimed -- the user deleted that
            // paragraph of the footnote -- must be deleted now, before the reanchor step
            // below moves it to a fresh position and makes it look intentional. See
            // `deleteUnclaimedContinuations`'s doc comment.
            try deleteUnclaimedContinuations(db: db, notesContinuationsByOwner: notesContinuationsByOwner)

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

            // MUST run AFTER reanchorPreservedRows -- see insertDeferredContinuations's doc
            // comment for why placement depends on the owner's FINAL position.
            try insertDeferredContinuations(db: db, projectId: projectId, deferredByOwner: deferredNotesContinuations)

            // 6. Normalize sort orders inline (atomic with delete+insert above). Trap: do not
            // merge this with the public normalizeSortOrders(projectId:) in
            // Database+BlocksReorder.swift — see renumberSortOrders for why they must stay
            // separate (a single hoisted `now` here vs. a fresh Date() per row there).
            try renumberSortOrders(db: db, projectId: projectId, now: Date())

            try Self.recomputeSectionParents(db: db, projectId: projectId)
        }
    }

}
