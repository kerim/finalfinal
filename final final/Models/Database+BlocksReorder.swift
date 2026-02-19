//
//  Database+BlocksReorder.swift
//  final final
//
//  Block reorder, replace, and normalize operations.
//

import Foundation
import GRDB

// MARK: - Heading Update Info

/// Information about heading changes during reorder/hierarchy enforcement
/// Passed from ContentView to reorderAllBlocks so heading markdownFragment and level
/// can be updated atomically alongside sort order changes.
struct HeadingUpdate: Sendable {
    let markdownFragment: String?
    let headingLevel: Int?
}

// MARK: - Block Heading Metadata

/// Preserved heading metadata during block replacement (avoids large tuple)
private struct HeadingMetadata {
    let status: SectionStatus?
    let tags: [String]?
    let wordGoal: Int?
    let goalType: GoalType
    let aggregateGoal: Int?
    let aggregateGoalType: GoalType
    let isBibliography: Bool
}

// MARK: - ProjectDatabase Block Reorder/Replace

extension ProjectDatabase {

    /// Replace all blocks for a project, preserving heading IDs and metadata by title match.
    /// Used during initial parse, project open, and non-zoomed CodeMirror re-parse.
    func replaceBlocks(_ blocks: [Block], for projectId: String) throws {
        try write { db in
            let existingBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            var idByTitle: [String: String] = [:]
            var metadataByTitle: [String: HeadingMetadata] = [:]
            for block in existingBlocks where block.blockType == .heading {
                if idByTitle[block.textContent] == nil {
                    idByTitle[block.textContent] = block.id
                }
                metadataByTitle[block.textContent] = HeadingMetadata(
                    status: block.status, tags: block.tags,
                    wordGoal: block.wordGoal, goalType: block.goalType,
                    aggregateGoal: block.aggregateGoal, aggregateGoalType: block.aggregateGoalType,
                    isBibliography: block.isBibliography
                )
            }

            try Block.filter(Block.Columns.projectId == projectId).deleteAll(db)

            for var block in blocks {
                if block.blockType == .heading, let preservedId = idByTitle[block.textContent] {
                    block.id = preservedId
                    idByTitle.removeValue(forKey: block.textContent)
                }
                if block.blockType == .heading, let meta = metadataByTitle[block.textContent] {
                    block.status = meta.status
                    block.tags = meta.tags
                    block.wordGoal = meta.wordGoal
                    block.goalType = meta.goalType
                    block.aggregateGoal = meta.aggregateGoal
                    block.aggregateGoalType = meta.aggregateGoalType
                    if meta.isBibliography { block.isBibliography = true }
                }
                try block.insert(db)
            }
        }
    }

    /// Replace blocks within a sort order range (used during zoomed CodeMirror re-parse).
    /// Only deletes/inserts blocks in [startSortOrder, endSortOrder), preserving blocks outside the zoom.
    /// Restores heading metadata (status, tags, wordGoal, goalType) by title match.
    func replaceBlocksInRange(
        _ newBlocks: [Block],
        for projectId: String,
        startSortOrder: Double,
        endSortOrder: Double?
    ) throws {
        try write { db in
            // 1. Fetch existing blocks in range to preserve heading metadata and IDs
            var existingQuery = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder >= startSortOrder)
            if let end = endSortOrder {
                existingQuery = existingQuery.filter(Block.Columns.sortOrder < end)
            }
            let existingBlocks = try existingQuery.order(Block.Columns.sortOrder).fetchAll(db)

            // Build metadata lookup by title for heading blocks
            var metadataByTitle: [String: HeadingMetadata] = [:]
            // Build ID lookup by title for heading blocks (preserves zoomedSectionId across re-parses)
            var idByTitle: [String: String] = [:]
            for block in existingBlocks where block.blockType == .heading {
                metadataByTitle[block.textContent] = HeadingMetadata(
                    status: block.status,
                    tags: block.tags,
                    wordGoal: block.wordGoal,
                    goalType: block.goalType,
                    aggregateGoal: block.aggregateGoal,
                    aggregateGoalType: block.aggregateGoalType,
                    isBibliography: block.isBibliography
                )
                if idByTitle[block.textContent] == nil {
                    idByTitle[block.textContent] = block.id
                }
            }

            // 2. Delete blocks in range
            var deleteQuery = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder >= startSortOrder)
            if let end = endSortOrder {
                deleteQuery = deleteQuery.filter(Block.Columns.sortOrder < end)
            }
            try deleteQuery.deleteAll(db)

            // 2.5. Shift blocks after range to prevent sort order collisions
            // when inserted blocks overflow the original range
            if let end = endSortOrder {
                let insertEnd = startSortOrder + Double(newBlocks.count)
                if insertEnd > end {
                    let shift = insertEnd - end
                    try db.execute(
                        sql: """
                            UPDATE block SET sortOrder = sortOrder + ?, updatedAt = ?
                            WHERE projectId = ? AND sortOrder >= ?
                            """,
                        arguments: [shift, Date(), projectId, end]
                    )
                }
            }

            // 3. Insert new blocks with sort orders starting at startSortOrder
            for (index, var block) in newBlocks.enumerated() {
                block.sortOrder = startSortOrder + Double(index)

                // 4. Preserve heading ID by title match (first-match-wins)
                if block.blockType == .heading, let preservedId = idByTitle[block.textContent] {
                    block.id = preservedId
                    idByTitle.removeValue(forKey: block.textContent)
                }

                // 5. Restore heading metadata by title match
                if block.blockType == .heading, let meta = metadataByTitle[block.textContent] {
                    block.status = meta.status
                    block.tags = meta.tags
                    block.wordGoal = meta.wordGoal
                    block.goalType = meta.goalType
                    block.aggregateGoal = meta.aggregateGoal
                    block.aggregateGoalType = meta.aggregateGoalType
                    if meta.isBibliography { block.isBibliography = true }
                }

                try block.insert(db)
            }

            // 6. Normalize sort orders inline (atomic with delete+insert above)
            let allProjectBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
            let sorted = allProjectBlocks.sorted { a, b in
                let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                return aKey < bKey
            }
            let now = Date()
            for (index, var block) in sorted.enumerated() {
                let newSortOrder = Double(index + 1)
                if block.sortOrder != newSortOrder {
                    block.sortOrder = newSortOrder
                    block.updatedAt = now
                    try block.update(db)
                }
            }
        }
    }

    // MARK: - Reorder All Blocks (Atomic)

    /// Reorder ALL blocks (headings + body) to match a new section order.
    /// Body blocks follow their heading in the order they appeared before reorder.
    /// Executes in a single write transaction for atomicity.
    ///
    /// Algorithm:
    /// 1. Fetch all blocks sorted by current sortOrder
    /// 2. Group: for each heading/pseudo-section/bibliography, collect body blocks that follow
    ///    until the next group leader → those are its "body blocks"
    /// 3. Collect orphan body blocks before the first heading (preamble)
    /// 4. Re-assign sequential sort orders: preamble first, then for each heading in section
    ///    order → heading + its body blocks
    /// 5. Apply heading updates (markdownFragment, headingLevel) if provided
    func reorderAllBlocks(
        sections: [SectionViewModel],
        projectId: String,
        headingUpdates: [String: HeadingUpdate] = [:]
    ) throws {
        try write { db in
            // 1. Fetch all blocks in current sort order
            let allBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // 2. Group blocks: each "group leader" (heading, pseudo-section, bibliography)
            //    owns subsequent non-leader blocks until the next leader
            let sectionIds = Set(sections.map { $0.id })
            var groups: [String: [Block]] = [:]  // leaderId -> body blocks
            var preamble: [Block] = []           // body blocks before first leader
            var currentLeaderId: String?
            var leaderOrder: [String] = []       // preserves original leader order for lookup

            for block in allBlocks {
                let isLeader = sectionIds.contains(block.id)

                if isLeader {
                    currentLeaderId = block.id
                    groups[block.id] = []
                    leaderOrder.append(block.id)
                } else if let leaderId = currentLeaderId {
                    groups[leaderId, default: []].append(block)
                } else {
                    // Body block before any heading (preamble)
                    preamble.append(block)
                }
            }

            // 3. Build new order: preamble, then sections in new order with their body blocks
            var sortCounter: Double = 1.0
            let now = Date()

            // Preamble blocks first
            for var block in preamble {
                if block.sortOrder != sortCounter {
                    block.sortOrder = sortCounter
                    block.updatedAt = now
                    try block.update(db)
                }
                sortCounter += 1.0
            }

            // Sections in the order specified by the sections array
            for section in sections {
                // Update the heading/leader block
                if var headingBlock = try Block.fetchOne(db, key: section.id) {
                    headingBlock.sortOrder = sortCounter
                    headingBlock.updatedAt = now

                    // Apply heading updates if provided
                    if let update = headingUpdates[section.id] {
                        if let fragment = update.markdownFragment {
                            headingBlock.markdownFragment = fragment
                        }
                        if let level = update.headingLevel {
                            headingBlock.headingLevel = level
                        }
                    }

                    try headingBlock.update(db)
                    sortCounter += 1.0

                    // Body blocks follow in their original order
                    if let bodyBlocks = groups[section.id] {
                        for var bodyBlock in bodyBlocks {
                            if bodyBlock.sortOrder != sortCounter {
                                bodyBlock.sortOrder = sortCounter
                                bodyBlock.updatedAt = now
                                try bodyBlock.update(db)
                            }
                            sortCounter += 1.0
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sort Order Operations

    /// Reorder a block (drag-and-drop handler)
    func reorderBlock(id: String, afterBlockId: String?) throws {
        try write { db in
            guard var block = try Block.fetchOne(db, key: id) else { return }

            let projectId = block.projectId
            var newSortOrder: Double

            if let afterId = afterBlockId {
                guard let afterBlock = try Block.fetchOne(db, key: afterId) else { return }

                // Find the next block after the target
                let nextBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.sortOrder > afterBlock.sortOrder)
                    .filter(Block.Columns.id != id)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)

                if let next = nextBlock {
                    newSortOrder = (afterBlock.sortOrder + next.sortOrder) / 2.0
                } else {
                    newSortOrder = afterBlock.sortOrder + 1.0
                }
            } else {
                // Move to beginning
                let firstBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.id != id)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)

                if let first = firstBlock {
                    newSortOrder = first.sortOrder / 2.0
                } else {
                    newSortOrder = 1.0
                }
            }

            block.sortOrder = newSortOrder
            block.updatedAt = Date()
            try block.update(db)
        }
    }

    /// Normalize sort orders (when fractional values get too small or duplicates exist)
    /// Uses tie-breaking: headings sort before non-headings at the same sortOrder
    func normalizeSortOrders(projectId: String) throws {
        try write { db in
            let blocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Re-sort with tie-breaking: headings before non-headings at same sortOrder
            let sorted = blocks.sorted { a, b in
                let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                return aKey < bKey
            }

            for (index, var block) in sorted.enumerated() {
                let newSortOrder = Double(index + 1)
                if block.sortOrder != newSortOrder {
                    block.sortOrder = newSortOrder
                    block.updatedAt = Date()
                    try block.update(db)
                }
            }
        }
    }

}
