//
//  Database+BlocksReorder.swift
//  final final
//
//  Block reorder and normalize operations.
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

// MARK: - ProjectDatabase Block Reorder

extension ProjectDatabase {

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
            //    owns subsequent non-leader blocks until the next leader (see groupBlocksBySections)
            let sectionIds = Set(sections.map { $0.id })
            let (groups, preamble) = groupBlocksBySections(allBlocks, sectionIds: sectionIds)

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

            // Sections in the order specified by the sections array (see reorderSection)
            let context: SectionReorderContext = (groups: groups, headingUpdates: headingUpdates)
            for section in sections {
                sortCounter = try reorderSection(section, context: context, startingAt: sortCounter, now: now, db: db)
            }

            // Reordering can change which heading precedes which -- re-persist
            // sectionParentId to match. See Database+BlockParents.swift.
            try Self.recomputeSectionParents(db: db, projectId: projectId)
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

            // Renumbering here can change document order (this tie-break isn't guaranteed
            // stable against whatever order duplicate sortOrders happened to arrive in), which
            // is exactly the condition that can change a heading's section-hierarchy parent --
            // see Database+BlockParents.swift's recomputeSectionParents doc comment for why
            // every write that can reorder or restructure headings must end with this call.
            try Self.recomputeSectionParents(db: db, projectId: projectId)
        }
    }

}

// MARK: - Shared Reorder Helpers

/// Mechanical extractions from `reorderAllBlocks`, split out only for cyclomatic complexity —
/// no behavior change from the original.
private extension ProjectDatabase {

    // MARK: Reorder all blocks

    /// leaderId->body-blocks map + pending heading updates, bundled to keep reorderSection's param count under the limit.
    typealias SectionReorderContext = (groups: [String: [Block]], headingUpdates: [String: HeadingUpdate])

    /// Partitions `allBlocks` into a leaderId -> body-blocks map plus a preamble. Extraction of `reorderAllBlocks` step 2.
    func groupBlocksBySections(
        _ allBlocks: [Block],
        sectionIds: Set<String>
    ) -> (groups: [String: [Block]], preamble: [Block]) {
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
                preamble.append(block)  // body block before any heading
            }
        }
        return (groups, preamble)
    }

    /// Reorders one section (heading + body); extracted from `reorderAllBlocks` step 4 — a missing heading silently skips the section, as before.
    func reorderSection(
        _ section: SectionViewModel,
        context: SectionReorderContext,
        startingAt initialSortCounter: Double,
        now: Date,
        db: Database
    ) throws -> Double {
        guard var headingBlock = try Block.fetchOne(db, key: section.id) else {
            return initialSortCounter
        }
        var sortCounter = initialSortCounter
        headingBlock.sortOrder = sortCounter
        headingBlock.updatedAt = now
        if let update = context.headingUpdates[section.id] {
            if let fragment = update.markdownFragment { headingBlock.markdownFragment = fragment }
            if let level = update.headingLevel { headingBlock.headingLevel = level }
        }
        try headingBlock.update(db)
        sortCounter += 1.0
        if let bodyBlocks = context.groups[section.id] {
            for var bodyBlock in bodyBlocks {
                if bodyBlock.sortOrder != sortCounter {
                    bodyBlock.sortOrder = sortCounter
                    bodyBlock.updatedAt = now
                    try bodyBlock.update(db)
                }
                sortCounter += 1.0
            }
        }
        return sortCounter
    }

}
