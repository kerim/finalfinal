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
    /// 5. Apply heading level changes (headingLevel, and the markdownFragment's `#` prefix rebuilt from the LIVE row) if provided
    ///
    /// The old whole-document reorder (Markdown mode, zoomed, an editor-first refusal) lands here. It is a thin wrapper around the
    /// static `reorderAllBlocks(db:leaderIds:projectId:levels:)`, which the queued reorder job (`SectionReorderJob`) runs inside its own
    /// transaction. Only the `headingLevel` of each update is read now: the fragment is rebuilt from the row as it is in the table, so
    /// a heading renamed a moment ago keeps its new title (t-0b70d1e9, A14; the sidebar's `markdownContent` can be a moment stale).
    func reorderAllBlocks(
        sections: [SectionViewModel],
        projectId: String,
        headingUpdates: [String: HeadingUpdate] = [:]
    ) throws {
        let leaderIds = sections.map(\.id)
        let levels = headingUpdates.compactMapValues(\.headingLevel)
        try write { db in
            try Self.reorderAllBlocks(db: db, leaderIds: leaderIds, projectId: projectId, levels: levels)
        }
    }

    /// The reorder itself, on an open transaction (t-0b70d1e9): the old instance method above wraps it in `write`, and the queued
    /// `SectionReorderJob` runs it after its snapshot. `leaderIds` is every section leader in FINAL order; a block is a leader if and
    /// only if its id is in the list, every other block belongs to the leader before it, and blocks before the first leader are the
    /// preamble (the same rule `groupBlocksBySections` has always applied, and the one the editor's range move uses).
    ///
    /// Every block is renumbered 1, 2, 3... in the final order. Only a row whose id is in `levels` AND whose type is `heading` has its
    /// level touched: `headingLevel` is set and `markdownFragment` rewritten with the `#` prefix of that level, computed from the row as
    /// it is NOW (never from the sidebar's copy of the text). A section break, Notes or Bibliography row listed in `levels` is left
    /// alone, and so is a heading the plan did not change. Ends with `recomputeSectionParents`. Plain `[String]` and `[String: Int]` so
    /// the writer's thread can take them (`SectionViewModel` is not `Sendable`).
    ///
    /// NOTES AND BIBLIOGRAPHY ARE RESOLVED FROM THE LIVE ROWS, not from `leaderIds` (t-0b70d1e9, C1). Any listed id whose row is
    /// flagged `isNotes` or `isBibliography` is dropped from the list, and the live Notes heading and then the live Bibliography
    /// heading are appended last. Why: the bibliography rebuild deletes every `isBibliography` row and inserts new ones under FRESH ids;
    /// if it commits between the plan and this job, the planned Bibliography id matches no row and the new Bibliography heading is
    /// unlisted, so it would join the previous leader's group and travel with the last chapter. The document always ends with Notes
    /// then Bibliography, so this also holds for the old whole-document path, whose plan is clamped the same way.
    static func reorderAllBlocks(
        db: Database,
        leaderIds: [String],
        projectId: String,
        levels: [String: Int]
    ) throws {
        // 1. Fetch all blocks in current sort order
        let allBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
        let leaderRows = Dictionary(allBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The list actually used: the listed ids minus whatever is Notes or Bibliography NOW, then the live Notes heading(s), then the
        // live Bibliography heading(s). (A listed id with no row stays: its section is skipped below, as it always was.)
        let managedHeadings = allBlocks.filter { $0.blockType == .heading && ($0.isNotes || $0.isBibliography) }
        let orderedLeaderIds = leaderIds.filter { id in leaderRows[id].map { !($0.isNotes || $0.isBibliography) } ?? true }
            + managedHeadings.filter(\.isNotes).map(\.id)
            + managedHeadings.filter { !$0.isNotes && $0.isBibliography }.map(\.id)

        // 2. Group blocks: each "group leader" (heading, pseudo-section, bibliography)
        //    owns subsequent non-leader blocks until the next leader (see groupBlocksBySections)
        let (groups, preamble) = groupBlocksBySections(allBlocks, sectionIds: Set(orderedLeaderIds))

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

        // Sections in the order of `orderedLeaderIds` (see reorderSection)
        for leaderId in orderedLeaderIds {
            sortCounter = try reorderSection(
                leader: leaderRows[leaderId], body: groups[leaderId], level: levels[leaderId],
                startingAt: sortCounter, now: now, db: db)
        }

        // Reordering can change which heading precedes which -- re-persist
        // sectionParentId to match. See Database+BlockParents.swift.
        try recomputeSectionParents(db: db, projectId: projectId)
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

    /// Partitions `allBlocks` into a leaderId -> body-blocks map plus a preamble. Extraction of `reorderAllBlocks` step 2.
    static func groupBlocksBySections(
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
    /// `level` is the plan's new level for this leader, if it has one: it is applied only to a `heading` row, and the fragment's `#`
    /// prefix is rebuilt from the row's own fragment as it is now (see the static `reorderAllBlocks`).
    static func reorderSection(
        leader: Block?,
        body bodyBlocks: [Block]?,
        level: Int?,
        startingAt initialSortCounter: Double,
        now: Date,
        db: Database
    ) throws -> Double {
        guard var headingBlock = leader else {
            return initialSortCounter
        }
        var sortCounter = initialSortCounter
        headingBlock.sortOrder = sortCounter
        headingBlock.updatedAt = now
        if let level, headingBlock.blockType == .heading {
            headingBlock.headingLevel = level
            headingBlock.markdownFragment = SectionSyncService.updateHeaderLevel(in: headingBlock.markdownFragment, to: level)
        }
        try headingBlock.update(db)
        sortCounter += 1.0
        if let bodyBlocks {
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
