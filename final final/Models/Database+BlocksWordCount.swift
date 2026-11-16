//
//  Database+BlocksWordCount.swift
//  final final
//
//  Heading-scoped word count aggregation. The single entry point is
//  `batchWordCounts(blockIds:needsAggregate:)` — one DB read, and one walk over the
//  block rows, computes both section-only and aggregate counts for any number of
//  heading blocks (t-58d64b34; it used to walk the rows once per heading).
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
            try Self.batchWordCounts(in: db, blockIds: blockIds, needsAggregate: needsAggregate)
        }
    }

    /// The headings a word-count request is about. `requested` are the requested ids that are headings of the project;
    /// `allHeadings` are every heading of that project in document order, because a section's end is found among ALL of them,
    /// not only among the requested ones.
    private struct WordCountHeadings {
        let projectId: String
        let requested: [Block]
        let allHeadings: [Block]
    }

    /// Finds the headings `batchWordCounts(in:blockIds:needsAggregate:)` works on. nil when there is nothing to count: no ids, or
    /// none of them is a heading.
    private static func wordCountHeadings(in db: Database, blockIds: [String]) throws -> WordCountHeadings? {
        guard !blockIds.isEmpty else { return nil }

        // Fetch the requested heading blocks
        let headingBlocks = try Block
            .filter(blockIds.contains(Block.Columns.id))
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        guard !headingBlocks.isEmpty else { return nil }

        // Safety: callers should only pass blockIds from one project.
        // If multiple projects sneak in, only process the dominant one.
        let projectIds = Set(headingBlocks.map { $0.projectId })
        if projectIds.count > 1 {
            DebugLog.log(.outline, "[batchWordCounts] WARNING: blockIds span \(projectIds.count) projects; using first")
        }
        guard let projectId = headingBlocks.first?.projectId else { return nil }

        let inProject = headingBlocks.filter { $0.projectId == projectId }

        // Fetch every heading in the project (needed to find boundaries)
        let allHeadings = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        return WordCountHeadings(projectId: projectId, requested: inProject, allHeadings: allHeadings)
    }

    /// The walk of the one-pass count: reads the project's block rows ONCE, in document order, and returns for each heading (given by
    /// its sortOrder, ascending) the words of every row whose sortOrder is below the heading's, plus the words of all rows.
    ///
    /// A heading is settled when the first row at or past its sortOrder arrives (every row seen so far is then below it); the
    /// headings are in the same order as the rows, so one pointer serves them all.
    private static func wordsBeforeEachHeading(
        in db: Database,
        projectId: String,
        headingSortOrders: [Double]
    ) throws -> (wordsBefore: [Int], total: Int) {
        var wordsBefore = [Int](repeating: 0, count: headingSortOrders.count)
        var nextHeading = 0
        var running = 0
        // The COALESCE guards against the legacy column being NULL after migration drift.
        let rows = try Row.fetchCursor(db, sql: """
            SELECT sortOrder, COALESCE(wordCount, 0) AS wordCount
            FROM block
            WHERE projectId = ?
            ORDER BY sortOrder
            """, arguments: [projectId])
        while let row = try rows.next() {
            let rowSort: Double = (row[0] as Double?) ?? 0
            while nextHeading < headingSortOrders.count, headingSortOrders[nextHeading] <= rowSort {
                wordsBefore[nextHeading] = running
                nextHeading += 1
            }
            running += (row[1] as Int?) ?? 0
        }
        // A heading past the last row (not possible inside one read transaction, where a heading is itself a row) has an empty
        // section, as it had when each section was summed from its own row range.
        while nextHeading < headingSortOrders.count {
            wordsBefore[nextHeading] = running
            nextHeading += 1
        }
        return (wordsBefore, running)
    }

    /// The computation of `batchWordCounts(blockIds:needsAggregate:)` inside a read the caller already has open, so that
    /// the outline snapshot (`readOutlineSnapshotData`) takes its heading rows and these counts from ONE read transaction
    /// and the two cannot disagree.
    ///
    /// ONE WALK. The block rows are read once, in document order, and every heading's counts are taken from that single pass
    /// (t-58d64b34; the old way walked the rows again for every heading, twice for a heading with an aggregate goal, so a book
    /// with 200 headings and 5,000 blocks made hundreds of passes after every pause in typing). Every count is a difference of two
    /// running totals: "words in all rows before position p" is recorded for each heading as the walk passes it, and a section from
    /// heading A to heading B is `before(B) - before(A)`. Positions are compared by
    /// `sortOrder` VALUE, as the old code did, so rows or headings that share a `sortOrder` (fractional insertion can run out of
    /// room) all fall on the same side of a boundary, exactly as before.
    ///
    /// The ends of the sections are then found walking the headings backwards, once: the section-only end is the nearest later
    /// heading with a LARGER `sortOrder`; the aggregate end is the nearest such heading whose level is the same or higher (a
    /// smaller or equal number; a heading with no level counts as 99). `BatchWordCountsOnePassTests` keeps a copy of the old
    /// per-heading computation (with its own heading lookup) and compares this one against it.
    static func batchWordCounts(
        in db: Database,
        blockIds: [String],
        needsAggregate: Set<String> = []
    ) throws -> [String: HeadingWordCounts] {
        guard let scope = try wordCountHeadings(in: db, blockIds: blockIds) else { return [:] }
        let headings = scope.allHeadings
        let headingSortOrders = headings.map { $0.sortOrder }
        let (wordsBefore, total) = try wordsBeforeEachHeading(in: db, projectId: scope.projectId, headingSortOrders: headingSortOrders)

        // The ends, walking the headings backwards one group at a time (a group = headings sharing one sortOrder; none of them
        // ends another's section, so a group is settled before it becomes "later" for the headings above it).
        let requested = Set(scope.requested.map { $0.id })
        var result: [String: HeadingWordCounts] = [:]
        result.reserveCapacity(requested.count)
        var nextAnyBefore = total                      // `before` of the nearest later heading with a larger sortOrder (total: none)
        var nearestBeforeByLevel: [Int: Int] = [:]     // the same, per heading level (nil level = 99)
        var groupEnd = headings.count - 1
        while groupEnd >= 0 {
            var groupStart = groupEnd
            while groupStart > 0, headingSortOrders[groupStart - 1] == headingSortOrders[groupEnd] { groupStart -= 1 }

            for index in groupStart...groupEnd where requested.contains(headings[index].id) {
                let heading = headings[index]
                // Section-only ends at the next heading of any level
                let sectionOnly = nextAnyBefore - wordsBefore[index]
                // Aggregate ends at the next heading of same-or-higher level (lower number)
                var aggregate = sectionOnly
                if needsAggregate.contains(heading.id), let level = heading.headingLevel {
                    var end = total
                    for (otherLevel, before) in nearestBeforeByLevel where otherLevel <= level { end = min(end, before) }
                    aggregate = end - wordsBefore[index]
                }
                result[heading.id] = HeadingWordCounts(sectionOnly: sectionOnly, aggregate: aggregate)
            }

            let groupBefore = wordsBefore[groupStart]   // the same for every heading of the group
            nextAnyBefore = groupBefore
            for index in groupStart...groupEnd { nearestBeforeByLevel[headings[index].headingLevel ?? 99] = groupBefore }
            groupEnd = groupStart - 1
        }

        // Gated so the total-reduce only runs when `.outline` logging is on.
        // `batchWordCounts` fires on every sidebar refresh, so the savings add up.
        if DebugLog.isEnabled(.outline) {
            let sectionTotal = result.values.reduce(0) { $0 + $1.sectionOnly }
            let id8 = String(scope.projectId.prefix(8))
            DebugLog.log(.outline, "[batchWordCounts] project=\(id8) headings=\(result.count) total=\(sectionTotal)")
        }

        return result
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
