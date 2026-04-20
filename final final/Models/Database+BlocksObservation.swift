//
//  Database+BlocksObservation.swift
//  final final
//
//  Block reactive observation (ValueObservation streams).
//

import Foundation
import GRDB

// MARK: - ProjectDatabase Block Observation

extension ProjectDatabase {

    /// Returns an async sequence of outline blocks (headings + section breaks) for sidebar.
    ///
    /// ⚠️  DO NOT ADD `.removeDuplicates()` HERE.
    ///
    /// The tracking closure returns only heading + pseudo-section rows, but the
    /// downstream sidebar derives its per-section word counts by summing the
    /// `wordCount` column of the *body* blocks between those headings (via
    /// `batchWordCounts`). When a user types in a paragraph, the heading rows
    /// returned here are bytewise identical, but the derived word totals are
    /// different. `.removeDuplicates()` would silently suppress the re-emission
    /// and freeze the sidebar at its open-time values — which is exactly the
    /// bug this comment exists to prevent.
    ///
    /// This has been removed, re-added (drive-by in commit `a004534`), and
    /// removed again. If you think you need to add it back for a perf reason,
    /// stop and read:
    ///   - `docs/architecture/word-count.md` §"ValueObservation (primary)"
    ///   - `docs/lessons/grdb-database.md` §"removeDuplicates() Suppresses Derived-Data Updates"
    ///   - `docs/findings/sidebar-stale-after-content-state-transition.md`
    ///   - `docs/findings/minor-fixes.md` (the first time we removed it)
    ///
    /// The emission rate is already bounded: GRDB fires once per committed
    /// transaction (not per row), `BlockSyncService.pollInterval` is 2 s,
    /// `applyBlockChangesFromEditor` wraps every poll-cycle's writes into one
    /// transaction, and `EditorViewState.fetchBatchWordCounts` runs off the
    /// main actor via `Task.detached`. Dedup here buys nothing and breaks
    /// live word-count updates. The regression is covered by
    /// `OutlineObservationTests.bodyEditReEmits`.
    func observeOutlineBlocks(for projectId: String) -> AsyncThrowingStream<[Block], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(
                        Block.Columns.blockType == BlockType.heading.rawValue ||
                        Block.Columns.isPseudoSection == true
                    )
                    .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
                    .fetchAll(db)
            }

        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: .main)
            ) { error in
                continuation.finish(throwing: error)
            } onChange: { blocks in
                continuation.yield(blocks)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

}
