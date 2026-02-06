//
//  Database+Blocks.swift
//  final final
//
//  Block CRUD operations for the block-based content model.
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

// MARK: - Block Change Types

/// Represents a surgical change to apply to the blocks table
enum BlockChange {
    case insert(Block)
    case update(id: String, updates: BlockUpdates)
    case delete(id: String)
}

/// Updates to apply to an existing block (all fields optional)
struct BlockUpdates {
    var parentId: String??          // Double-optional: nil = don't change, .some(nil) = set to nil
    var sortOrder: Double?
    var blockType: BlockType?
    var textContent: String?
    var markdownFragment: String?
    var headingLevel: Int??         // Double-optional for nullable field
    var status: SectionStatus??
    var tags: [String]??
    var wordGoal: Int??
    var goalType: GoalType?
    var wordCount: Int?
    var isBibliography: Bool?
    var isPseudoSection: Bool?

    init(
        parentId: String?? = nil,
        sortOrder: Double? = nil,
        blockType: BlockType? = nil,
        textContent: String? = nil,
        markdownFragment: String? = nil,
        headingLevel: Int?? = nil,
        status: SectionStatus?? = nil,
        tags: [String]?? = nil,
        wordGoal: Int?? = nil,
        goalType: GoalType? = nil,
        wordCount: Int? = nil,
        isBibliography: Bool? = nil,
        isPseudoSection: Bool? = nil
    ) {
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.blockType = blockType
        self.textContent = textContent
        self.markdownFragment = markdownFragment
        self.headingLevel = headingLevel
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
        self.goalType = goalType
        self.wordCount = wordCount
        self.isBibliography = isBibliography
        self.isPseudoSection = isPseudoSection
    }
}

// MARK: - ProjectDatabase Block CRUD

extension ProjectDatabase {

    // MARK: - Fetch Operations

    /// Fetch all blocks for a project, sorted by sortOrder
    func fetchBlocks(projectId: String) throws -> [Block] {
        try read { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch only heading blocks for outline display
    func fetchHeadingBlocks(projectId: String) throws -> [Block] {
        try read { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch blocks that can appear in the outline sidebar (headings + section breaks)
    func fetchOutlineBlocks(projectId: String) throws -> [Block] {
        try read { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(
                    Block.Columns.blockType == BlockType.heading.rawValue ||
                    Block.Columns.isPseudoSection == true
                )
                .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    /// Fetch a single block by ID
    func fetchBlock(id: String) throws -> Block? {
        try read { db in
            try Block.fetchOne(db, key: id)
        }
    }

    /// Fetch child blocks of a parent
    func fetchChildBlocks(parentId: String) throws -> [Block] {
        try read { db in
            try Block
                .filter(Block.Columns.parentId == parentId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch blocks within a sort order range (for getting blocks "under" a heading)
    func fetchBlocksInRange(
        projectId: String,
        afterSortOrder: Double,
        beforeSortOrder: Double?
    ) throws -> [Block] {
        try read { db in
            var query = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder > afterSortOrder)

            if let before = beforeSortOrder {
                query = query.filter(Block.Columns.sortOrder < before)
            }

            return try query.order(Block.Columns.sortOrder).fetchAll(db)
        }
    }

    // MARK: - Insert/Update Operations

    /// Insert a new block
    func insertBlock(_ block: Block) throws {
        var block = block
        try write { db in
            try block.insert(db)
        }
    }

    /// Update an existing block
    func updateBlock(_ block: Block) throws {
        var updated = block
        updated.updatedAt = Date()
        try write { db in
            try updated.update(db)
        }
    }

    /// Update block status (for heading blocks)
    func updateBlockStatus(id: String, status: SectionStatus?) throws {
        let statusValue = status.map { $0 == .final_ ? "final" : $0.rawValue }
        try write { db in
            try db.execute(
                sql: "UPDATE block SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [statusValue, Date(), id]
            )
        }
    }

    /// Update block word goal
    func updateBlockWordGoal(id: String, goal: Int?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE block SET wordGoal = ?, updatedAt = ? WHERE id = ?",
                arguments: [goal, Date(), id]
            )
        }
    }

    /// Update block goal type
    func updateBlockGoalType(id: String, goalType: GoalType) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE block SET goalType = ?, updatedAt = ? WHERE id = ?",
                arguments: [goalType.rawValue, Date(), id]
            )
        }
    }

    /// Update block tags
    func updateBlockTags(id: String, tags: [String]?) throws {
        let tagsString: String?
        if let tags = tags {
            let tagsData = try JSONEncoder().encode(tags)
            tagsString = String(data: tagsData, encoding: .utf8)
        } else {
            tagsString = nil
        }
        try write { db in
            try db.execute(
                sql: "UPDATE block SET tags = ?, updatedAt = ? WHERE id = ?",
                arguments: [tagsString, Date(), id]
            )
        }
    }

    // MARK: - Delete Operations

    /// Delete a block by ID
    func deleteBlock(id: String) throws {
        try write { db in
            try Block.deleteOne(db, key: id)
        }
    }

    /// Delete all blocks for a project
    func deleteAllBlocks(projectId: String) throws {
        try write { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .deleteAll(db)
        }
    }

    // MARK: - Bulk Operations

    /// Apply surgical block changes (insert/update/delete) within a single transaction
    func applyBlockChanges(_ changes: [BlockChange], for projectId: String) throws {
        try write { db in
            for change in changes {
                switch change {
                case .insert(var block):
                    try block.insert(db)

                case .update(let id, let updates):
                    guard var block = try Block.fetchOne(db, key: id) else { continue }

                    // Apply only the fields that are set
                    if let parentIdUpdate = updates.parentId {
                        block.parentId = parentIdUpdate
                    }
                    if let sortOrder = updates.sortOrder {
                        block.sortOrder = sortOrder
                    }
                    if let blockType = updates.blockType {
                        block.blockType = blockType
                    }
                    if let textContent = updates.textContent {
                        block.textContent = textContent
                    }
                    if let markdownFragment = updates.markdownFragment {
                        block.markdownFragment = markdownFragment
                    }
                    if let headingLevelUpdate = updates.headingLevel {
                        block.headingLevel = headingLevelUpdate
                    }
                    if let statusUpdate = updates.status {
                        block.status = statusUpdate
                    }
                    if let tagsUpdate = updates.tags {
                        block.tags = tagsUpdate
                    }
                    if let wordGoalUpdate = updates.wordGoal {
                        block.wordGoal = wordGoalUpdate
                    }
                    if let goalType = updates.goalType {
                        block.goalType = goalType
                    }
                    if let wordCount = updates.wordCount {
                        block.wordCount = wordCount
                    }
                    if let isBibliography = updates.isBibliography {
                        block.isBibliography = isBibliography
                    }
                    if let isPseudoSection = updates.isPseudoSection {
                        block.isPseudoSection = isPseudoSection
                    }

                    block.updatedAt = Date()
                    try block.update(db)

                case .delete(let id):
                    try Block
                        .filter(Block.Columns.id == id)
                        .deleteAll(db)
                }
            }
        }
    }

    /// Apply changes from editor (BlockChanges struct)
    /// Returns a mapping of temporary IDs to permanent IDs for newly inserted blocks
    func applyBlockChangesFromEditor(_ changes: BlockChanges, for projectId: String) throws -> [String: String] {
        var idMapping: [String: String] = [:]

        try write { db in
            // Query max sort order ONCE for the entire transaction
            var nextSortOrder = (try Double.fetchOne(db,
                sql: "SELECT MAX(sortOrder) FROM block WHERE projectId = ?",
                arguments: [projectId]) ?? 0) + 1.0

            // Process deletes first
            for id in changes.deletes {
                try Block.deleteOne(db, key: id)
            }

            // Process updates
            for update in changes.updates {
                if var block = try Block.fetchOne(db, key: update.id) {
                    // Block found - apply updates
                    if let textContent = update.textContent {
                        block.textContent = textContent
                        block.wordCount = MarkdownUtils.wordCount(for: textContent)
                    }
                    if let markdownFragment = update.markdownFragment {
                        block.markdownFragment = markdownFragment
                        // Detect block type changes from content (e.g., paragraph → heading from paste)
                        let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
                            let hashes = trimmed[match].filter { $0 == "#" }
                            block.blockType = .heading
                            block.headingLevel = hashes.count
                            // Strip heading prefix from textContent for sidebar display
                            if let textContent = update.textContent, textContent.hasPrefix("#") {
                                block.textContent = BlockParser.extractTextContent(from: trimmed, blockType: .heading)
                                block.wordCount = MarkdownUtils.wordCount(for: block.textContent)
                            }
                        } else if block.blockType == .heading {
                            // Was heading but no longer has heading syntax
                            block.blockType = .paragraph
                            block.headingLevel = nil
                        }
                    }
                    if let headingLevel = update.headingLevel {
                        block.headingLevel = headingLevel
                    }

                    block.updatedAt = Date()
                    try block.update(db)
                } else if update.id.hasPrefix("temp-") {
                    // Temp ID not found in DB — create new block (handles first-edit-in-new-project)
                    let trimmed = (update.markdownFragment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let blockType: BlockType
                    let detectedLevel: Int?
                    var textContent = update.textContent ?? ""

                    if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
                        blockType = .heading
                        detectedLevel = trimmed[match].filter({ $0 == "#" }).count
                        textContent = BlockParser.extractTextContent(from: trimmed, blockType: .heading)
                    } else {
                        blockType = update.headingLevel != nil ? .heading : .paragraph
                        detectedLevel = update.headingLevel
                    }

                    let permanentId = UUID().uuidString

                    var block = Block(
                        id: permanentId,
                        projectId: projectId,
                        sortOrder: nextSortOrder,
                        blockType: blockType,
                        textContent: textContent,
                        markdownFragment: update.markdownFragment ?? ""
                    )
                    if let hl = detectedLevel { block.headingLevel = hl }
                    block.recalculateWordCount()
                    try block.insert(db)
                    idMapping[update.id] = permanentId
                    nextSortOrder += 1.0

                    #if DEBUG
                    print("[Database+Blocks] Created block from temp update: \(update.id) → \(permanentId)")
                    #endif
                } else {
                    #if DEBUG
                    print("[Database+Blocks] Warning: Block not found for update: \(update.id)")
                    #endif
                }
            }

            // Process inserts
            for insert in changes.inserts {
                // Calculate sort order based on afterBlockId
                var sortOrder: Double
                if let afterId = insert.afterBlockId,
                   let afterBlock = try Block.fetchOne(db, key: afterId) {
                    // Find the next block to calculate midpoint
                    let nextBlock = try Block
                        .filter(Block.Columns.projectId == projectId)
                        .filter(Block.Columns.sortOrder > afterBlock.sortOrder)
                        .order(Block.Columns.sortOrder)
                        .fetchOne(db)

                    if let next = nextBlock {
                        sortOrder = (afterBlock.sortOrder + next.sortOrder) / 2.0
                    } else {
                        sortOrder = afterBlock.sortOrder + 1.0
                    }
                } else {
                    // No afterBlockId — use the shared running counter
                    sortOrder = nextSortOrder
                    nextSortOrder += 1.0
                }

                // Detect heading from markdown content (belt-and-suspenders with JS detection)
                let blockType: BlockType
                let effectiveHeadingLevel: Int?
                let insertTrimmed = insert.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                if let hMatch = insertTrimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
                    blockType = .heading
                    effectiveHeadingLevel = insertTrimmed[hMatch].filter({ $0 == "#" }).count
                } else {
                    blockType = BlockType(rawValue: insert.blockType) ?? .paragraph
                    effectiveHeadingLevel = insert.headingLevel
                }

                let permanentId = UUID().uuidString
                let insertTextContent = blockType == .heading
                    ? BlockParser.extractTextContent(from: insertTrimmed, blockType: .heading)
                    : insert.textContent

                var block = Block(
                    id: permanentId,
                    projectId: projectId,
                    sortOrder: sortOrder,
                    blockType: blockType,
                    textContent: insertTextContent,
                    markdownFragment: insert.markdownFragment,
                    headingLevel: effectiveHeadingLevel
                )
                block.recalculateWordCount()
                try block.insert(db)

                // Record the mapping from temp ID to permanent ID
                idMapping[insert.tempId] = permanentId
            }
        }

        return idMapping
    }

    /// Replace all blocks for a project (used during initial parse)
    func replaceBlocks(_ blocks: [Block], for projectId: String) throws {
        try write { db in
            // Delete existing blocks
            try Block
                .filter(Block.Columns.projectId == projectId)
                .deleteAll(db)

            // Insert in order (already sorted by sortOrder)
            for var block in blocks {
                try block.insert(db)
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

    // MARK: - Word Count Operations

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

    // MARK: - Reactive Observation

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
