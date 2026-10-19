//
//  Database+ReplaceProjectRows.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2b: the "replace this project's rows" write the editor-first Version History restores stand
//  on (plan D5). It is `replaceBlocks(db:)` without the part that makes `replaceBlocks(db:)` unsafe for them.
//

import Foundation
import GRDB

extension ProjectDatabase {

    /// Replaces every `block` row of `projectId` with exactly `rows`, inside the caller's own write transaction, WITHOUT touching the
    /// project's block-write epoch and without restamping any row.
    ///
    /// WHY NOT `replaceBlocks(db:)`. The existing whole-document body (`replaceBlocks(db:_:for:preservingMachineManagedBlocks:)`,
    /// Database+BlocksReplace.swift) ends in `stampWholeProjectForRewrite`: it bumps the project's epoch (E -> E+1) and restamps
    /// every row to `(E+1, 0)`. That is the right thing for a write that came from a stale picture of the document (a file load, the
    /// close/quit save, the legacy restore): any editor batch fetched before it describes a document that no longer exists, and rule 1
    /// of `applyBlockChangesFromEditor` (Database+BlockWriteStamp.swift) refuses such a batch WHOLE, inserts included. An
    /// editor-first restore is the opposite case. The editor has ALREADY changed its own document, and what the user keeps typing
    /// is typed into the restored text. A batch reserved before this write commits carries epoch E; if the write bumped the epoch, rule
    /// 1 would refuse that batch whole when it applies after the commit (the writer orders the restore job first; see the
    /// `.lifecycleWholeDocument` paragraph of `DocumentWriter.applySystemWrite`, the one system write that does bump, and why that one
    /// is safe), and everything the user typed in that window would be lost without a message. So this write moves no epoch.
    ///
    /// STAMPS. The `block` table's `lastWriteEpoch` / `lastWriteSequence` columns are not part of `Block` (see the header of
    /// Database+BlockWriteStamp.swift), so inserting a row writes the column defaults `(0, 0)`: the stamp a row carries when a native
    /// structural writer creates it. A row whose id SURVIVES this replace (a heading kept by title keeps its id) must not lose the stamp
    /// it had, or a late editor batch older than that stamp, which rule 2 drops, would apply over the restored text. So the stamps of
    /// surviving rows are read before the delete and written back after the insert, unchanged; this is the convention for every system
    /// write ("rows it touches keep whatever stamp they already carried"), not a restamp. A row with a new id keeps the default
    /// `(0, 0)`, which compares below any batch.
    ///
    /// WHAT IT DOES. Reads the project's row ids and the stamps of the rows that survive, deletes every row in chunks (a database
    /// delete cascades to the rows hanging off a block, as `replaceBlocks(db:)` does: annotations, list items), inserts `rows` in
    /// the order given, writes the surviving stamps back, and recomputes the section parents (`sectionParentId`). It decides nothing
    /// else: the caller supplies the final ids, sort orders, flags and metadata. The caller also owns the rest of the document's
    /// state that depends on the rows (the content row, the `section` table, annotations, the outline cache); the Version History
    /// restore job runs them in the same transaction, using the other db-level forms.
    ///
    /// Static on purpose: with no `self`, a re-entrant `self.read`/`self.write` from inside `dbWriter.write` is structurally
    /// impossible (same reason as the other db-level statics). It NEVER calls `stampWholeProjectForRewrite`, never forwards to
    /// `replaceBlocks(db:)`, and never bumps `blockWriteEpoch`; the unit test that pins this is `RestorePrimitivesTests`
    /// `testReplaceProjectRowsMovesNoEpochAndNoSurvivingStamp`.
    static func replaceProjectRows(db: Database, projectId: String, rows: [Block]) throws {
        let surviving = Set(rows.map(\.id))
        var existingIds: [String] = []
        var survivingStamps: [String: BlockWriteStamp] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT id, lastWriteEpoch, lastWriteSequence FROM block WHERE projectId = ?", arguments: [projectId]) {
            let id: String = row["id"]
            existingIds.append(id)
            let stamp = BlockWriteStamp(epoch: row["lastWriteEpoch"], sequence: row["lastWriteSequence"])
            // A row at the default (0, 0) needs no write back: the insert gives it that.
            if surviving.contains(id), stamp != BlockWriteStamp(epoch: 0, sequence: 0) { survivingStamps[id] = stamp }
        }

        // Deleted in chunks so no statement carries more bound ids than SQLite's variable limit allows (a book has about 1,100 rows).
        for start in stride(from: 0, to: existingIds.count, by: Self.replaceProjectRowsChunkSize) {
            let chunk = Array(existingIds[start..<min(start + Self.replaceProjectRowsChunkSize, existingIds.count)])
            try Block.filter(keys: chunk).deleteAll(db)
        }

        for var row in rows {
            try row.insert(db)
        }

        if !survivingStamps.isEmpty {
            let restore = try db.cachedStatement(sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = ? WHERE id = ?")
            for (id, stamp) in survivingStamps {
                try restore.execute(arguments: [stamp.epoch, stamp.sequence, id])
            }
        }

        try Self.recomputeSectionParents(db: db, projectId: projectId)
    }

    /// Ids per delete statement in `replaceProjectRows(db:projectId:rows:)`.
    private static let replaceProjectRowsChunkSize = 400
}
