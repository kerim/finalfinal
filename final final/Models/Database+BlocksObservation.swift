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

    /// Returns an async sequence of block updates for reactive UI
    func observeBlocks(for projectId: String) -> AsyncThrowingStream<[Block], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
                    .fetchAll(db)
            }
            .removeDuplicates()

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

    /// Returns an async sequence of outline blocks (headings + section breaks) for sidebar
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
            .removeDuplicates()

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
