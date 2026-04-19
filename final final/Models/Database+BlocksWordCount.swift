//
//  Database+BlocksWordCount.swift
//  final final
//
//  Heading-scoped word count aggregation. The single entry point is
//  `batchWordCounts(blockIds:needsAggregate:)` — one DB read computes both
//  section-only and aggregate counts for any number of heading blocks.
//

import Foundation
import GRDB

// MARK: - ProjectDatabase Word Count Operations

extension ProjectDatabase {

    /// Word counts attached to a single heading block.
    /// - `sectionOnly`: words from this heading up to (but excluding) the next
    ///   heading of any level. Includes the heading block's own word count.
    /// - `aggregate`: words from this heading up to (but excluding) the next
    ///   heading at the same or higher level. Includes the heading block's
    ///   own word count plus all sub-headings beneath it.
    struct HeadingWordCounts: Sendable, Equatable {
        let sectionOnly: Int
        let aggregate: Int
    }

    /// Compute section-only and (optionally) aggregate word counts for a set
    /// of heading blocks in a single DB read.
    ///
    /// All blockIds must belong to the same project; blocks from other projects
    /// are silently ignored. Non-heading blocks in the input are also ignored.
    /// Aggregate counts are computed only for blocks listed in `needsAggregate`
    /// (cheaper for callers that don't display aggregate-goal sections).
    ///
    /// - Returns: A map keyed by block id. Heading blocks not present in the
    ///   project are absent from the result.
    func batchWordCounts(
        blockIds: [String],
        needsAggregate: Set<String> = []
    ) throws -> [String: HeadingWordCounts] {
        guard !blockIds.isEmpty else { return [:] }

        return try read { db in
            // Fetch the requested heading blocks
            let headingBlocks = try Block
                .filter(blockIds.contains(Block.Columns.id))
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            guard !headingBlocks.isEmpty else { return [:] }

            // Safety: callers should only pass blockIds from one project.
            // If multiple projects sneak in, only process the dominant one.
            let projectIds = Set(headingBlocks.map { $0.projectId })
            if projectIds.count > 1 {
                DebugLog.log(.outline, "[batchWordCounts] WARNING: blockIds span \(projectIds.count) projects; using first")
            }
            guard let projectId = headingBlocks.first?.projectId else { return [:] }

            let inProject = headingBlocks.filter { $0.projectId == projectId }

            // Fetch every heading in the project (needed to find boundaries)
            let allHeadings = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Fetch every block in the project (just sortOrder + wordCount)
            // The COALESCE guards against the legacy column being NULL after migration drift.
            let allBlocks = try Row.fetchAll(db, sql: """
                SELECT sortOrder, COALESCE(wordCount, 0) AS wordCount
                FROM block
                WHERE projectId = ?
                ORDER BY sortOrder
                """, arguments: [projectId])

            // Sum block wordCounts whose sortOrder falls in [start, end). End nil = open.
            // Single linear walk keeps this O(B) per call regardless of heading count.
            func sumWords(from startSortOrder: Double, until endSortOrder: Double?) -> Int {
                var total = 0
                for row in allBlocks {
                    let rowSort: Double = row["sortOrder"] ?? 0
                    if rowSort < startSortOrder { continue }
                    if let limit = endSortOrder, rowSort >= limit { break }
                    total += (row["wordCount"] as Int?) ?? 0
                }
                return total
            }

            let headingSortOrders = allHeadings.map { $0.sortOrder }

            var result: [String: HeadingWordCounts] = [:]
            result.reserveCapacity(inProject.count)

            for heading in inProject {
                let headingSortOrder = heading.sortOrder

                // Section-only ends at the next heading of any level
                let nextAnyIdx = headingSortOrders.firstIndex(where: { $0 > headingSortOrder })
                let nextAnySortOrder = nextAnyIdx.map { headingSortOrders[$0] }
                let sectionOnly = sumWords(from: headingSortOrder, until: nextAnySortOrder)

                // Aggregate ends at the next heading of same-or-higher level (lower number)
                var aggregate = sectionOnly
                if needsAggregate.contains(heading.id), let level = heading.headingLevel {
                    let nextSameOrHigherSO = allHeadings
                        .first(where: { $0.sortOrder > headingSortOrder && ($0.headingLevel ?? 99) <= level })
                        .map { $0.sortOrder }
                    aggregate = sumWords(from: headingSortOrder, until: nextSameOrHigherSO)
                }

                result[heading.id] = HeadingWordCounts(sectionOnly: sectionOnly, aggregate: aggregate)
            }

            let total = result.values.reduce(0) { $0 + $1.sectionOnly }
            DebugLog.log(.outline, "[batchWordCounts] project=\(String(projectId.prefix(8))) headings=\(result.count) total=\(total)")

            return result
        }
    }

    /// Summary of a `recomputeStoredBlockWordCounts` sweep.
    struct WordCountRecomputeSummary: Sendable, Equatable {
        let totalBlocks: Int
        let changedBlocks: Int
        let oldTotal: Int
        let newTotal: Int
    }

    /// Recompute `Block.wordCount` for every block in a project and write back
    /// only the rows whose value actually changed. Runs synchronously inside a
    /// single write transaction.
    ///
    /// Why this exists: `Block.wordCount` is a stored column, and any stored
    /// value computed under old `MarkdownUtils.wordCount` rules (e.g. the counts
    /// baked into bundled fixtures like `getting-started.ff`) lingers on disk
    /// until something re-saves the block. Without this sweep, opening a project
    /// shows stale counts that correct themselves only on the first edit.
    ///
    /// Idempotent — when all counts already match current rules, no writes are
    /// issued. Preserves `updatedAt` by using a partial-column update
    /// (`block.update(db, columns: [.wordCount])`) rather than full `update(db)`.
    @discardableResult
    func recomputeStoredBlockWordCounts(projectId: String) throws -> WordCountRecomputeSummary {
        try write { db in
            let blocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchAll(db)

            var oldTotal = 0
            var newTotal = 0
            var changed = 0

            for var block in blocks {
                let oldCount = block.wordCount
                oldTotal += oldCount
                block.recalculateWordCount()
                let newCount = block.wordCount
                newTotal += newCount
                if oldCount != newCount {
                    changed += 1
                    let id8 = String(block.id.prefix(8))
                    let what = "type=\(block.blockType.rawValue) isBib=\(block.isBibliography)"
                    DebugLog.log(.data, "[WordCount:migrate] block=\(id8) \(what) \(oldCount) -> \(newCount)")
                    // Partial update: only the wordCount column, so updatedAt is untouched.
                    try block.update(db, columns: [Block.Columns.wordCount])
                }
            }

            return WordCountRecomputeSummary(
                totalBlocks: blocks.count,
                changedBlocks: changed,
                oldTotal: oldTotal,
                newTotal: newTotal
            )
        }
    }
}
