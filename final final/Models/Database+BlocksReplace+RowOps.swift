//
//  Database+BlocksReplace+RowOps.swift
//  final final
//
//  Block replace helpers: live-db row mutation (delete, shift, merge, re-anchor, renumber).
//  Extracted from Database+BlocksReplace.swift, which owns the two main entry points
//  (replaceBlocks, replaceBlocksInRange). See Database+BlocksReplace+Preservation.swift
//  for the no-db-parameter heading/image metadata preservation helpers.
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
    ///   at all. Defaults to `true`. Both `replaceBlocksInRange`'s call site and
    ///   `replaceBlocks`' bibliography+Notes preservation path pass `true` -- a Notes-shaped
    ///   incoming block is merged into its preserved row there too now, on equal footing with
    ///   `replaceBlocksInRange` -- see `replaceBlocks`' doc comment.
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
