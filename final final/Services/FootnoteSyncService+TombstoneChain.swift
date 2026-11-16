//
//  FootnoteSyncService+TombstoneChain.swift
//  final final
//
//  Footnote clean-up: find each removed row's neighbour in one pass (t-83251af6).
//
//  When Notes rows are deleted, the write records for each one which SURVIVING row stood
//  before it (`DeletedAnchor`), so a late editor insert anchored on a removed row can
//  re-anchor onto a row that still exists. The old walk
//  (`resolveTombstoneChainOneQueryPerStep`, kept beside it in
//  `FootnoteSyncService+Reconciliation.swift` as the reference) asked the database for each
//  step of that walk separately: N deleted rows that stood next to each other cost about
//  N squared over two queries inside the write -- about 45,000 for the 300 footnotes of a
//  book -- while the writer was held and every save queued behind it waited.
//

import Foundation
import GRDB

extension FootnoteSyncService {
    /// Phase 2 (t-94369a83), §2.3 point 4: resolves the tombstone anchor for EVERY row in
    /// `deletedIds` -- a set of rows all about to be deleted together, in the SAME write,
    /// none of them deleted yet when this runs. Each id gets the nearest row BEFORE it in
    /// document order that is not itself in `deletedIds` (`.after(thatRow)`), or
    /// `.documentStart` if no such row exists -- so a late insert anchored on any of these
    /// rows lands on a row that will actually survive this write. A predecessor that is
    /// itself deleted (two adjacent continuation paragraphs of the same now-deleted
    /// definition, say) is walked past, exactly as the one-query-per-step walk did.
    ///
    /// ONE read of the project's row ids in document order (`ORDER BY sortOrder`, the same
    /// order the old walk's `sortOrder DESC LIMIT 1` queries used), then a single pass:
    /// the id seen last that is not being deleted is every later deleted row's neighbour.
    /// The pass stops at the last deleted row -- nothing after it can be anyone's
    /// neighbour. The old walk's other special cases come out the same:
    ///   - the first row of the project has no predecessor: `.documentStart`;
    ///   - a run of deleted rows at the very start of the project: all `.documentStart`;
    ///   - an id with no row in this project (the old walk's lookup found nothing to
    ///     measure from): `.documentStart`;
    ///   - rows of another project are never anchors (the read is filtered by `projectId`);
    ///   - an empty set returns `[:]` without touching the database.
    /// The old walk's cycle guard (at most `deletedIds.count` hops per row) is not needed:
    /// this pass moves forward through the rows once and cannot loop.
    ///
    /// `sortOrder` values are distinct within a project (the writers renumber to keep them
    /// so). Were two rows ever to share one, the old query's choice between them was SQLite's
    /// to make, not the SQL's, so there is no old result to match.
    nonisolated static func resolveTombstoneChain(
        db: Database, projectId: String, deletedIds: Set<String>
    ) throws -> [String: DeletedAnchor] {
        guard !deletedIds.isEmpty else { return [:] }
        var anchors: [String: DeletedAnchor] = [:]
        var nearestSurvivor: String?
        let rowIds = try String.fetchCursor(
            db, sql: "SELECT id FROM block WHERE projectId = ? ORDER BY sortOrder", arguments: [projectId])
        while let id = try rowIds.next() {
            if deletedIds.contains(id) {
                if let survivor = nearestSurvivor {
                    anchors[id] = .after(survivor)
                } else {
                    anchors[id] = .documentStart
                }
                if anchors.count == deletedIds.count { break }
            } else {
                nearestSurvivor = id
            }
        }
        for id in deletedIds where anchors[id] == nil { anchors[id] = .documentStart }
        return anchors
    }
}
