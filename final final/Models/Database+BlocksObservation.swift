//
//  Database+BlocksObservation.swift
//  final final
//
//  What the Outline sidebar reads from the block table, and the signal that the table changed.
//
//  Phase 6 (numbered sidebar snapshots) replaced the `ValueObservation` that used to live here. The sidebar's list is now read by
//  `OutlineSnapshotPublisher` (Services/), one numbered snapshot at a time, whenever a transaction that touched the `block` table has
//  committed. This file holds the two database pieces that publisher needs: the single read that builds a snapshot, and the commit
//  signal.
//

import Foundation
import GRDB

// MARK: - Outline snapshot data

extension ProjectDatabase {

    /// The raw material of one outline snapshot: the heading and section-break rows (bibliography last) and the word counts of those
    /// headings, read in ONE read transaction. The old chain read the rows and the counts in two separate reads, so a commit between
    /// them could leave the sidebar showing rows and counts from different moments until the next tick.
    struct OutlineSnapshotData: Sendable {
        let blocks: [Block]
        let counts: [String: HeadingWordCounts]
    }

    /// `fetchOutlineBlocks(projectId:)` (Database+Blocks.swift) inside a read the caller already has open: the heading rows and
    /// section breaks, bibliography last.
    static func fetchOutlineBlocks(in db: Database, projectId: String) throws -> [Block] {
        try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(
                Block.Columns.blockType == BlockType.heading.rawValue ||
                Block.Columns.isPseudoSection == true
            )
            .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
            .fetchAll(db)
    }

    /// Reads the outline rows and their word counts in one read transaction.
    ///
    /// The counts are asked for every heading row (a section a pending editor-first delete hides is still counted: the counts are keyed
    /// by id, `batchWordCounts` finds a section's end from every heading in the project, not from the list it is given, so the values
    /// are the same either way) and the aggregate for the rows that have an aggregate goal.
    func readOutlineSnapshotData(projectId: String) throws -> OutlineSnapshotData {
        try read { db in
            let blocks = try Self.fetchOutlineBlocks(in: db, projectId: projectId)
            let needsAggregate = Set(blocks.filter { $0.aggregateGoal != nil }.map(\.id))
            let counts = try Self.batchWordCounts(in: db, blockIds: blocks.map(\.id), needsAggregate: needsAggregate)
            return OutlineSnapshotData(blocks: blocks, counts: counts)
        }
    }

    // MARK: - Commit signal

    /// Calls `onCommit` after every committed transaction that changed anything in the `block` table (any row, any column; the same
    /// table-wide region the old `ValueObservation` tracked). A body-only edit counts: the sidebar's per-section word totals come
    /// from the body blocks' `wordCount`, so the signal must fire for a change to a paragraph even though no heading row changed
    /// (`OutlineSnapshotPublisherTests.bodyEditProducesATick`; the lesson behind the old "DO NOT ADD .removeDuplicates()" banner).
    ///
    /// `onCommit` runs on the writer's dispatch queue, serialized with every write: keep it to flipping a flag. A rolled-back
    /// transaction does not call it. Cancelling the returned cancellable never blocks (the observation is dropped, the callback is
    /// never called again).
    ///
    /// Starting it blocks the caller until a write access exists (GRDB establishes the observation inside the writer queue and
    /// waits for the writer). The publisher starts it on the caller's thread at project open, when the writer is idle.
    func observeBlockCommits(onCommit: @escaping @Sendable () -> Void) -> AnyDatabaseCancellable {
        DatabaseRegionObservation(tracking: Block.all()).start(
            in: dbWriter,
            onError: { error in
                DebugLog.log(.outline, "[ProjectDatabase] block commit observation error: \(error)")
            },
            onChange: { _ in onCommit() }
        )
    }
}
