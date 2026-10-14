//
//  Database+BlocksReplace+RowOps.swift
//  final final
//
//  Block replace helpers: live-db row mutation (delete, shift, merge, re-anchor, renumber,
//  and the multi-paragraph-footnote continuation delete/insert pair). Extracted from
//  Database+BlocksReplace.swift, which owns the two main entry points (replaceBlocks,
//  replaceBlocksInRange). See Database+BlocksReplace+Preservation.swift for the
//  no-db-parameter heading/image metadata preservation helpers.
//

import Foundation
import GRDB

// MARK: - Replace Helpers (Row Ops)

/// Mechanical extractions from `replaceBlocks` and `replaceBlocksInRange`
/// (`Database+BlocksReplace.swift`) — no behavior change from the originals. Split-internal
/// helpers of those two entry points, not general-purpose API: every method below is
/// `internal` rather than `private` ONLY because Swift has no cross-file `fileprivate`
/// equivalent that would let the entry-point file call them — the same scope this whole
/// extension used to enforce via a single `private extension ProjectDatabase` before the
/// file_length split. Do not call these from outside this replace-helpers trio of files.
extension ProjectDatabase {

    /// Delete continuation rows left unclaimed after `handleMachineManagedBlock`'s main
    /// insert/merge loop finishes -- i.e. a preserved continuation whose paragraph the
    /// incoming batch no longer contains (the user deleted the second paragraph of a
    /// footnote, say). Without this, a SHRINKING multi-paragraph footnote resurrects its
    /// deleted paragraph: the labelless-continuation branch only ever claims rows
    /// positionally as incoming blocks consume them (mirroring `claimedNotesLabels`), so a
    /// row nobody claimed would otherwise sit untouched in the DB, then get silently
    /// re-anchored (by `reanchorPreservedRows`, since it's still in `preservedRowIds`) right
    /// back into the document as if nothing had changed.
    ///
    /// CALLED ONLY FROM `replaceBlocksInRange`, DELIBERATELY NOT from `replaceBlocks`'
    /// preservation path -- see the call site in `replaceBlocks` for the full reasoning.
    /// Short version: `replaceBlocksInRange`'s `newBlocks` is a reparse of a specific
    /// bounded range that its callers assert is EXHAUSTIVE for that range, so an unclaimed
    /// continuation there really does mean "deleted." `replaceBlocks`' preservation-path
    /// `blocks` is never exhaustive for Notes content by contract (guaranteed Notes-free at
    /// its real call sites) -- an unclaimed continuation there just means this call was
    /// never attempting to represent that footnote's continuations, and must survive
    /// untouched. Conflating the two here caused a real regression: two pre-existing tests
    /// (`BibliographySectionFlagTests+DataIntegrity.swift`'s "Issue 2 fixed" and "MUST-FIX 1
    /// regression guard") each seed a continuation, pass `blocks` that never reproduces it
    /// (one of them even while the SAME footnote's labeled definition IS present and
    /// correctly merges), and assert it survives -- calling this function from that path
    /// deleted it instead.
    func deleteUnclaimedContinuations(db: Database, notesContinuationsByOwner: [String: [Block]]) throws {
        for rows in notesContinuationsByOwner.values {
            for row in rows {
                try Block.deleteOne(db, key: row.id)
            }
        }
    }

    /// Insert genuinely-NEW continuation paragraphs -- a multi-paragraph footnote that GREW
    /// (more incoming labelless continuations than preserved rows existed for) -- deferred
    /// from `handleMachineManagedBlock`'s main loop and given a real position only now,
    /// immediately after their owning definition's FINAL position.
    ///
    /// MUST run AFTER `reanchorPreservedRows`, never before: the main insert loop assigns
    /// every genuinely-new block an index-based sortOrder inside the "new content" region
    /// (`[0, blocks.count)` / `[startSortOrder, startSortOrder + newBlocks.count)`), while
    /// `reanchorPreservedRows` moves the owning definition (and any of its surviving
    /// preserved continuations) to AFTER that entire region. A new continuation inserted at
    /// its batch index, before the owner is reanchored, would therefore sort AHEAD of its
    /// own definition -- `notesOwnershipMap`/`buildNotesRowIndex`'s walk would then see no
    /// preceding definition for it and misclassify it as pre-definition user prose (sorting
    /// it to the very end of the ENTIRE Notes group, owned by whatever footnote happens to
    /// be last) instead of its actual owner. "Add a third paragraph to footnote 1" must
    /// never end up folded into footnote 3's export.
    ///
    /// Placement: fractionally, just after the owner's last known row (its definition, or
    /// its last surviving continuation) in a FRESH post-reanchor fetch -- reanchored rows
    /// are integer-spaced (`anchorBase + Double(offset)`), so a `+0.01`-per-row fractional
    /// offset lands safely between the owner's row and whatever reanchored row comes next,
    /// without colliding. `renumberSortOrders`, which always runs after this, converts
    /// everything to clean sequential integers regardless.
    func insertDeferredContinuations(
        db: Database, projectId: String, deferredByOwner: [String: [Block]]
    ) throws {
        guard !deferredByOwner.isEmpty else { return }

        let notesRows = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        var lastOwnedSortOrder: [String: Double] = [:]
        var currentOwnerLabel: String?
        for row in notesRows {
            if row.blockType == .heading {
                currentOwnerLabel = nil
                continue
            }
            if let label = FootnoteSyncService.parseNotesLabel(from: row.markdownFragment)?.label {
                currentOwnerLabel = label
            }
            if let owner = currentOwnerLabel {
                lastOwnedSortOrder[owner] = row.sortOrder
            }
        }

        for (owner, newBlocks) in deferredByOwner {
            guard let baseSortOrder = lastOwnedSortOrder[owner] else {
                // Owner's definition isn't present in this fresh fetch -- shouldn't happen
                // (a continuation is only ever deferred once currentNotesOwnerLabel has
                // already been established from a labeled block earlier in this same
                // batch), but fail safe rather than crash: log so this is visible if it's
                // ever actually reached, and drop the positional placement for these rows.
                DebugLog.log(.data, "[Database+BlocksReplace] Deferred continuation(s) for owner \(owner) could not be "
                    + "placed: owner definition not found after reanchor")
                continue
            }
            for (index, var block) in newBlocks.enumerated() {
                block.sortOrder = baseSortOrder + Double(index + 1) * 0.01
                try block.insert(db)
            }
        }
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
    ///   Defaults to `true`. Both `replaceBlocksInRange`'s call site and `replaceBlocks`'
    ///   bibliography+Notes preservation path pass `true` -- see `replaceBlocks`' doc comment
    ///   for why Notes is protected on equal footing with bibliography there now.
    ///
    /// B3 (#4) -- tried and reverted, recorded here so it isn't retried the same way:
    /// this predicate exempts EVERY non-heading `isNotes == true` row unconditionally,
    /// including the user's own hand-typed prose living inside a flagged Notes run (once
    /// adoption can flag such a row at all). A first pass at B3 narrowed this to only
    /// MACHINE-OWNED rows (heading/definition/continuation, via
    /// `FootnoteSyncService.notesOwnershipMap`, the same classification B1's
    /// `removeNotesBlock` uses), on the theory that a non-machine-owned row should be as
    /// deletable/replaceable as any other body content. That regressed
    /// `MultiParagraphFootnoteReplaceTests.newContinuationNeverOverwritesLaterRunsUserProse`:
    /// `replaceBlocksInRange`'s range is not always exhaustive for every Notes run it
    /// happens to overlap -- a call scoped to editing Notes run ONE, with
    /// `endSortOrder: nil`, mechanically sweeps in a SECOND, unrelated Notes run's rows
    /// purely by sort order, and `newBlocks` was never meant to represent that second
    /// run at all. Narrowing the exemption made that second run's user prose look
    /// deletable for the wrong reason (never reproduced in `newBlocks`) rather than the
    /// right one (the user actually deleted it). Unlike B1's `removeNotesBlock` --  which
    /// only ever runs once ALL footnotes are gone from the WHOLE document, where a
    /// `.userProse` row is unambiguously orphaned -- this function cannot tell "the user
    /// deleted this row" apart from "this row just wasn't this call's business." Reverted
    /// to the original, unconditional exemption. The plan's own preferred remedy (C1(3):
    /// never flag arbitrary user prose as `isNotes` in the first place, so this predicate
    /// never has to make the distinction) is Stage C, not implemented here -- until then
    /// B3's "ghost row the editor can't delete" concern (if reachable at all, given B1
    /// already narrows the one confirmed destructive path) stays open, tracked for C1(3).
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
    /// Four-way outcome, in order:
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
    /// 4. Notes-shaped, non-heading, with NO parsed label at all: a continuation paragraph of
    ///    the current running owner (`currentNotesOwnerLabel`, updated by outcome 2/3 above
    ///    whenever a labeled block is seen). Consumes the next UNCLAIMED existing continuation
    ///    row for that owner, positionally, from `notesContinuationsByOwner` (mirrors how
    ///    `claimedNotesLabels` prevents double-claiming a definition), and updates it in place
    ///    (same id) — same merge shape as outcome 3. If no owner is established yet at all
    ///    (this batch's very first Notes-shaped block, no preceding label seen), this is
    ///    genuinely unattachable content and falls through to a normal insert (`false`) --
    ///    the caller has no better option. If an owner IS known but no preserved row remains
    ///    for it (the footnote grew a paragraph), the block is queued into
    ///    `deferredNewContinuations[owner]` instead of inserted immediately (`true` — the
    ///    caller must NOT do a normal insert) — see `insertDeferredContinuations`'s doc
    ///    comment for why its real position can only be resolved after the caller reanchors
    ///    preserved rows.
    ///
    /// - Parameter notesState: The Notes-merge bookkeeping (claimed labels, per-owner
    ///   continuation queues, current owner label, deferred new continuations) this function
    ///   reads and mutates in place for outcomes 2/3/4 above. See `NotesMergeState`'s doc
    ///   comment for why this is bundled into one `inout` value.
    /// - Parameter handlingNotes: Whether outcomes 2/3/4 (Notes-shaped merge-or-dedup) are
    ///   active at all. Defaults to `true`. Both `replaceBlocksInRange`'s call site and
    ///   `replaceBlocks`' bibliography+Notes preservation path pass `true` -- a Notes-shaped
    ///   incoming block is merged into its preserved row there too now, on equal footing with
    ///   `replaceBlocksInRange` -- see `replaceBlocks`' doc comment.
    func handleMachineManagedBlock(
        db: Database,
        block: Block,
        notesState: inout NotesMergeState,
        handlingNotes: Bool = true
    ) throws -> Bool {
        if block.isBibliography && block.blockType != .heading {
            DebugLog.log(.data, "[replaceBlocksInRange] Skipping insert of bibliography-shaped block (machine-managed)")
            return true
        }

        guard handlingNotes, block.isNotes, block.blockType != .heading else {
            return false
        }

        if let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
            notesState.currentNotesOwnerLabel = label

            if notesState.claimedNotesLabels.contains(label) {
                // Duplicate label within this same batch (e.g. two "[^1]:" paragraphs from a
                // copy-paste slip) — the first occurrence above already claimed this label
                // (merged or inserted); drop this one rather than producing a second DB row
                // with the same footnote label.
                DebugLog.log(.data, "[replaceBlocksInRange] Skipping duplicate notes label in batch: \(label)")
                return true
            }
            notesState.claimedNotesLabels.insert(label)

            if var existingNotesRow = notesState.notesRowByLabel[label] {
                existingNotesRow.markdownFragment = block.markdownFragment
                existingNotesRow.textContent = block.textContent
                existingNotesRow.recalculateWordCount()
                existingNotesRow.updatedAt = Date()
                try existingNotesRow.update(db)
                notesState.notesRowByLabel.removeValue(forKey: label)
                return true
            }
            return false
        }

        // Labelless Notes-shaped block: a continuation paragraph of the current running
        // owner. Consume the next UNCLAIMED existing continuation row for that owner, in
        // original order, so a three-paragraph footnote's two continuations each land on
        // their own preserved row instead of clobbering the same one.
        guard let owner = notesState.currentNotesOwnerLabel else {
            // No running owner established yet in this batch at all -- genuinely
            // unattachable content; fall through to a normal insert (no better option).
            return false
        }
        guard var remaining = notesState.notesContinuationsByOwner[owner], !remaining.isEmpty else {
            // Owner is known, but no preserved continuation row is left for it -- the
            // footnote grew a paragraph. Defer rather than fall through to a normal insert:
            // a normal insert would place it at this batch's index-based sortOrder, inside
            // the body-content region, sorting AHEAD of its own not-yet-reanchored owner.
            // See insertDeferredContinuations.
            notesState.deferredNewContinuations[owner, default: []].append(block)
            return true
        }
        var existingContinuation = remaining.removeFirst()
        notesState.notesContinuationsByOwner[owner] = remaining
        existingContinuation.markdownFragment = block.markdownFragment
        existingContinuation.textContent = block.textContent
        existingContinuation.recalculateWordCount()
        existingContinuation.updatedAt = Date()
        try existingContinuation.update(db)
        return true
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
