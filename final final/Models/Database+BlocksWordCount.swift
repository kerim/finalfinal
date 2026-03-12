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

    /// Batch word count result for a heading block
    struct HeadingWordCounts {
        let sectionOnly: Int
        let aggregate: Int  // includes sub-headings (for aggregate goals)
    }

    /// Batch-compute word counts for multiple heading blocks in a single DB read.
    /// Returns [blockId: HeadingWordCounts] — only includes blocks that are headings.
    /// Replaces N individual sectionOnlyWordCount + wordCountForHeading calls with one read.
    func batchWordCounts(blockIds: [String], needsAggregate: Set<String> = []) throws -> [String: HeadingWordCounts] {
        guard !blockIds.isEmpty else { return [:] }
        return try read { db in
            // Fetch all heading blocks we need in one query
            let headingBlocks = try Block
                .filter(blockIds.contains(Block.Columns.id))
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            guard !headingBlocks.isEmpty else { return [:] }

            // Get the projectId (all blocks should be same project)
            guard let projectId = headingBlocks.first?.projectId else { return [:] }

            // Fetch ALL heading blocks for this project (needed for boundary calculation)
            let allHeadings = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Fetch ALL blocks with their word counts, ordered by sortOrder
            let allBlocks = try Row.fetchAll(db, sql: """
                SELECT id, sortOrder, wordCount, blockType, headingLevel
                FROM block WHERE projectId = ? ORDER BY sortOrder
                """, arguments: [projectId])

            // Build a sorted array of heading sortOrders for boundary lookup
            let headingSortOrders = allHeadings.map { $0.sortOrder }

            // Sum word counts for blocks in [startSortOrder, endSortOrder)
            func sumWords(from startSortOrder: Double, until endSortOrder: Double?) -> Int {
                var total = 0
                for row in allBlocks {
                    let rowSortOrder: Double = row["sortOrder"]
                    if rowSortOrder < startSortOrder { continue }
                    if let limit = endSortOrder, rowSortOrder >= limit { break }
                    total += row["wordCount"] as Int
                }
                return total
            }

            var result: [String: HeadingWordCounts] = [:]

            for heading in headingBlocks {
                let headingSortOrder = heading.sortOrder

                // Section-only: from this heading to the next heading of ANY level
                let nextAnyIdx = headingSortOrders.firstIndex(where: { $0 > headingSortOrder })
                let nextAnySortOrder = nextAnyIdx.map { headingSortOrders[$0] }
                let sectionOnly = sumWords(from: headingSortOrder, until: nextAnySortOrder)

                // Aggregate: from this heading to next heading at same or higher level
                var aggregate = sectionOnly  // Default if not needed
                if needsAggregate.contains(heading.id), let headingLevel = heading.headingLevel {
                    let nextSameOrHigherSO = allHeadings
                        .first(where: { $0.sortOrder > headingSortOrder && ($0.headingLevel ?? 99) <= headingLevel })
                        .map { $0.sortOrder }
                    aggregate = sumWords(from: headingSortOrder, until: nextSameOrHigherSO)
                }

                result[heading.id] = HeadingWordCounts(sectionOnly: sectionOnly, aggregate: aggregate)
            }

            return result
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
