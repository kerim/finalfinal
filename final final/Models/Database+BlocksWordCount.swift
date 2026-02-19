//
//  Database+BlocksWordCount.swift
//  final final
//
//  Block word count operations.
//

import Foundation
import GRDB

// MARK: - ProjectDatabase Word Count Operations

extension ProjectDatabase {

    /// Recalculate word counts for all blocks in a project
    func recalculateBlockWordCounts(projectId: String) throws {
        try write { db in
            var blocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchAll(db)

            for i in blocks.indices {
                blocks[i].recalculateWordCount()
                blocks[i].updatedAt = Date()
                try blocks[i].update(db)
            }
        }
    }

    /// Get total word count for a project
    func totalWordCount(projectId: String) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(wordCount), 0) FROM block WHERE projectId = ?",
                arguments: [projectId]
            ) ?? 0
        }
    }

    /// Get section-only word count (own content only, excluding sub-headings)
    /// Counts from this heading to the next heading of ANY level
    func sectionOnlyWordCount(blockId: String) throws -> Int {
        try read { db in
            guard let headingBlock = try Block.fetchOne(db, key: blockId),
                  headingBlock.blockType == .heading else { return 0 }

            // Find the very next heading block (any level)
            let nextAnyHeading = try Block
                .filter(Block.Columns.projectId == headingBlock.projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.sortOrder > headingBlock.sortOrder)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)

            // Sum blocks from this heading to the next heading
            var query = Block
                .filter(Block.Columns.projectId == headingBlock.projectId)
                .filter(Block.Columns.sortOrder >= headingBlock.sortOrder)
            if let next = nextAnyHeading {
                query = query.filter(Block.Columns.sortOrder < next.sortOrder)
            }
            return try Int.fetchOne(db, query.select(sum(Block.Columns.wordCount))) ?? 0
        }
    }

    /// Get word count for blocks under a heading (until next same/higher level heading)
    func wordCountForHeading(blockId: String) throws -> Int {
        try read { db in
            guard let headingBlock = try Block.fetchOne(db, key: blockId),
                  headingBlock.blockType == .heading,
                  let headingLevel = headingBlock.headingLevel else {
                return 0
            }

            // Find the next heading at the same or higher level
            let nextHeading = try Block
                .filter(Block.Columns.projectId == headingBlock.projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.sortOrder > headingBlock.sortOrder)
                .filter(Block.Columns.headingLevel <= headingLevel)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)

            // Sum word counts between this heading and the next
            var query = Block
                .filter(Block.Columns.projectId == headingBlock.projectId)
                .filter(Block.Columns.sortOrder > headingBlock.sortOrder)

            if let next = nextHeading {
                query = query.filter(Block.Columns.sortOrder < next.sortOrder)
            }

            let sum = try Int.fetchOne(
                db,
                query.select(sum(Block.Columns.wordCount))
            )

            return (sum ?? 0) + headingBlock.wordCount
        }
    }

}
