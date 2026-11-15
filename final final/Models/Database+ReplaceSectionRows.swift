//
//  Database+ReplaceSectionRows.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2d-ii: the two range-scoped writes the editor-first SECTION restores stand on (plan D3, D5). They
//  are `replaceProjectRows(db:)` (Database+ReplaceProjectRows.swift) for a part of the document, and share its rules:
//
//    - they run inside the caller's own write transaction (the restore job's), on the `Database` the transaction holds;
//    - they never touch the project's block-write epoch and never restamp a row (no `stampWholeProjectForRewrite`, never a forward to
//      `replaceBlocks(db:)`: see `replaceProjectRows` for why that would refuse the typing made after the click, whole, for a stale
//      epoch). A row that SURVIVES keeps the stamp it had; a new row carries the default (0, 0), which compares below any batch;
//    - they decide nothing about the rows' content: the caller supplies ids, text, flags and metadata. They decide only WHERE the rows
//      go, and they decide it NOW, inside the transaction, against the table as it stands (after every batch reserved before the job
//      has applied), not against the picture the click read: typing made just before the click may have added a block next to the range.
//
//  `replaceFlatSectionRange` removes the FLAT range of a heading (`flatSectionBlockIds`) and puts `rows` in its place; `insertRows` puts
//  `rows` after a block, or after the last block that is not Notes / Bibliography. New rows take sort orders spread evenly between the
//  block before them and the block after, so no other row's `sortOrder` changes (the method `duplicateSections` uses), except when
//  that room is used up (the step would fall below `ProjectDatabase.crowdedSortOrderGap`, after several inserts in one spot, or a range
//  an earlier duplicate squeezed): then every row is first re-spaced 1, 2, 3 ... in order, in the same transaction, and the old numbers
//  are logged in the `renumberLog` the caller hands in (t-bf66e4ee). Every bound is read again from the table after a re-spacing.
//

import Foundation
import GRDB

extension ProjectDatabase {

    /// The old rows of a flat range as they stand now, and where `replaceFlatSectionRange` puts the new ones.
    private struct FlatRangePlacement {
        let old: [Block]
        let first: Double
        let step: Double
    }

    /// nil when the range has no row left (`replaceFlatSectionRange` then writes nothing and answers false).
    private static func flatRangePlacement(
        db: Database, projectId: String, rangeIds: [String], rowCount: Int
    ) throws -> FlatRangePlacement? {
        let old = try Block.filter(keys: rangeIds).fetchAll(db)
        guard let first = old.map(\.sortOrder).min(), let last = old.map(\.sortOrder).max() else { return nil }
        let next = try Double.fetchOne(
            db, sql: "SELECT MIN(sortOrder) FROM block WHERE projectId = ? AND sortOrder > ?", arguments: [projectId, last])
        let upper = next ?? (last + Double(rowCount) + 1.0)
        return FlatRangePlacement(old: old, first: first, step: (upper - first) / Double(rowCount))
    }

    /// Replaces the flat range of the heading `headingId` with exactly `rows`, in order. A row whose id is in the old range (the heading
    /// itself, when the caller reuses its id) is written again with the stamp and the creation date it had. Returns false, having
    /// written nothing, when `headingId` is not a heading or section break of the project that is neither Notes nor Bibliography
    /// (`flatSectionBlockIds` answers nil). Throws when a row cannot be inserted (a database fault, or an id that is a row elsewhere):
    /// the caller's transaction rolls back.
    ///
    /// When the step between the new rows would fall below `crowdedSortOrderGap` (the range was squeezed into almost no room, or the
    /// version has many more rows than the range), every saved position is re-spaced first and the old numbers are logged in
    /// `renumberLog` (t-bf66e4ee); the range's bounds are then read again from the table.
    static func replaceFlatSectionRange(
        db: Database, projectId: String, headingId: String, rows: [Block], renumberLog: SortOrderRenumberLog? = nil
    ) throws -> Bool {
        guard !rows.isEmpty, let rangeIds = try flatSectionBlockIds(db: db, headingId: headingId, projectId: projectId) else { return false }
        guard var placement = try flatRangePlacement(db: db, projectId: projectId, rangeIds: rangeIds, rowCount: rows.count) else {
            return false
        }
        if placement.step < crowdedSortOrderGap {
            let renumbered = try renumberAllSortOrders(db: db, projectId: projectId)
            Self.logSortOrderRenumbersOnCommit([renumbered], to: renumberLog, db: db)
            DebugLog.log(.data, "[ReplaceSectionRows] replace would crowd sort orders - renumbered \(renumbered.count) rows first")
            guard let respaced = try flatRangePlacement(db: db, projectId: projectId, rangeIds: rangeIds, rowCount: rows.count) else {
                return false
            }
            placement = respaced
        }
        let old = placement.old
        let first = placement.first
        let step = placement.step

        let surviving = Set(rows.map(\.id)).intersection(rangeIds)
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var survivingStamps: [String: BlockWriteStamp] = [:]
        for id in surviving {
            // At most the heading itself: one indexed read.
            guard let row = try Row.fetchOne(
                db, sql: "SELECT lastWriteEpoch, lastWriteSequence FROM block WHERE id = ?", arguments: [id]) else { continue }
            survivingStamps[id] = BlockWriteStamp(epoch: row["lastWriteEpoch"], sequence: row["lastWriteSequence"])
        }

        _ = try Block.filter(keys: rangeIds).deleteAll(db)
        for (index, original) in rows.enumerated() {
            var row = original
            row.projectId = projectId
            row.sortOrder = first + step * Double(index)
            if let before = oldById[row.id] { row.createdAt = before.createdAt }
            try row.insert(db)
        }
        let restore = try db.cachedStatement(sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = ? WHERE id = ?")
        for (id, stamp) in survivingStamps where stamp != BlockWriteStamp(epoch: 0, sequence: 0) {
            try restore.execute(arguments: [stamp.epoch, stamp.sequence, id])
        }
        try Self.recomputeSectionParents(db: db, projectId: projectId)
        return true
    }

    /// Inserts `rows` right after the block `afterBlockId`, or, when it is nil, after the last block of the project that is not Notes
    /// or Bibliography (the auto-bibliography marker row counts as Bibliography), or first when there is none. Returns false, having
    /// written nothing, when `afterBlockId` is not a block of the project or is Notes / Bibliography. Throws on an insert that fails.
    ///
    /// When the step between the new rows would fall below `crowdedSortOrderGap` (the normal case after several inserts: the room
    /// before the Notes or the Bibliography is the one every earlier insert already divided), every saved position is re-spaced first
    /// and the old numbers are logged in `renumberLog` (t-bf66e4ee); the anchor's number and the room after it are then read again.
    static func insertRows(
        db: Database, projectId: String, afterBlockId: String?, rows: [Block], renumberLog: SortOrderRenumberLog? = nil
    ) throws -> Bool {
        guard !rows.isEmpty else { return false }
        guard var placement = try insertPlacement(db: db, projectId: projectId, afterBlockId: afterBlockId, rowCount: rows.count) else {
            return false
        }
        if placement.step < crowdedSortOrderGap {
            let renumbered = try renumberAllSortOrders(db: db, projectId: projectId)
            Self.logSortOrderRenumbersOnCommit([renumbered], to: renumberLog, db: db)
            DebugLog.log(.data, "[ReplaceSectionRows] insert would crowd sort orders - renumbered \(renumbered.count) rows first")
            guard let respaced = try insertPlacement(
                db: db, projectId: projectId, afterBlockId: afterBlockId, rowCount: rows.count
            ) else { return false }
            placement = respaced
        }
        for (index, original) in rows.enumerated() {
            var row = original
            row.projectId = projectId
            row.sortOrder = placement.lower + placement.step * Double(index + 1)
            try row.insert(db)
        }
        try Self.recomputeSectionParents(db: db, projectId: projectId)
        return true
    }

    /// Where `insertRows` puts the new rows: the number of the row they follow, and the step between one new row and the next.
    private struct RowsInsertPlacement {
        let lower: Double
        let step: Double
    }

    /// nil when `afterBlockId` is not a usable anchor (`insertRows` then writes nothing and answers false). The new rows fill the room
    /// between the anchor and the row after it, `room / (rows + 1)` apart; with nothing after it the room is made up
    /// (`rows + 1`), so the step is 1. Always reads the table as it stands now.
    private static func insertPlacement(
        db: Database, projectId: String, afterBlockId: String?, rowCount: Int
    ) throws -> RowsInsertPlacement? {
        let lower: Double
        if let afterBlockId {
            guard let anchor = try Block.fetchOne(db, key: afterBlockId), anchor.projectId == projectId,
                  !anchor.isNotes, !anchor.isBibliography, anchor.blockType != .bibliography else { return nil }
            lower = anchor.sortOrder
        } else if let lastUserRow = try Double.fetchOne(
            db, sql: """
                SELECT MAX(sortOrder) FROM block WHERE projectId = ? AND isNotes = 0 AND isBibliography = 0 AND blockType != ?
                """, arguments: [projectId, BlockType.bibliography.rawValue]) {
            lower = lastUserRow
        } else {
            // No block that is not managed: the rows go before everything there is.
            let lowest = try Double.fetchOne(db, sql: "SELECT MIN(sortOrder) FROM block WHERE projectId = ?", arguments: [projectId]) ?? 1.0
            lower = lowest - Double(rowCount) - 1.0
        }
        let next = try Double.fetchOne(
            db, sql: "SELECT MIN(sortOrder) FROM block WHERE projectId = ? AND sortOrder > ?", arguments: [projectId, lower])
        let upper = next ?? (lower + Double(rowCount) + 1.0)
        return RowsInsertPlacement(lower: lower, step: (upper - lower) / Double(rowCount + 1))
    }
}
