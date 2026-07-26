//
//  Database+Blocks.swift
//  final final
//
//  Block CRUD operations for the block-based content model.
//

import Foundation
import GRDB

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
    var aggregateGoal: Int??
    var aggregateGoalType: GoalType?
    var wordCount: Int?
    var imageSrc: String??
    var imageAlt: String??
    var imageCaption: String??
    var imageWidth: Int??
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
        aggregateGoal: Int?? = nil,
        aggregateGoalType: GoalType? = nil,
        wordCount: Int? = nil,
        imageSrc: String?? = nil,
        imageAlt: String?? = nil,
        imageCaption: String?? = nil,
        imageWidth: Int?? = nil,
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
        self.aggregateGoal = aggregateGoal
        self.aggregateGoalType = aggregateGoalType
        self.wordCount = wordCount
        self.imageSrc = imageSrc
        self.imageAlt = imageAlt
        self.imageCaption = imageCaption
        self.imageWidth = imageWidth
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

    /// Lightweight count of blocks for a project (SELECT COUNT(*), no row fetching)
    func fetchBlockCount(projectId: String) throws -> Int {
        try read { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchCount(db)
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

    /// Update block aggregate goal
    func updateBlockAggregateGoal(id: String, goal: Int?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE block SET aggregateGoal = ?, updatedAt = ? WHERE id = ?",
                arguments: [goal, Date(), id]
            )
        }
    }

    /// Update block aggregate goal type
    func updateBlockAggregateGoalType(id: String, goalType: GoalType) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE block SET aggregateGoalType = ?, updatedAt = ? WHERE id = ?",
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
                    if let aggregateGoalUpdate = updates.aggregateGoal {
                        block.aggregateGoal = aggregateGoalUpdate
                    }
                    if let aggregateGoalType = updates.aggregateGoalType {
                        block.aggregateGoalType = aggregateGoalType
                    }
                    if let wordCount = updates.wordCount {
                        block.wordCount = wordCount
                    }
                    if let isBibliography = updates.isBibliography {
                        block.isBibliography = isBibliography
                    }
                    if let imageSrcUpdate = updates.imageSrc {
                        block.imageSrc = imageSrcUpdate
                    }
                    if let imageAltUpdate = updates.imageAlt {
                        block.imageAlt = imageAltUpdate
                    }
                    if let imageCaptionUpdate = updates.imageCaption {
                        block.imageCaption = imageCaptionUpdate
                    }
                    if let imageWidthUpdate = updates.imageWidth {
                        block.imageWidth = imageWidthUpdate
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
                // Safety net: Notes and Bibliography rows are machine-managed by their sync
                // services (FootnoteSyncService / BibliographySyncService), which perform their
                // own deletions inside their own transactions. A delete arriving via the editor
                // diff for one of these rows is a stale-diff artifact — reject it.
                if let existing = try Block.fetchOne(db, key: id), existing.isBibliography || existing.isNotes {
                    DebugLog.log(.data, "[Database+Blocks] Rejecting editor-diff delete of \(existing.isNotes ? "notes" : "bibliography") block: \(id.prefix(8))")
                    continue
                }
                try Block.deleteOne(db, key: id)
            }

            // Track image sources inserted within this batch to prevent duplicates
            // (catches the race condition where multiple inserts of the same image arrive in one sync cycle)
            var insertedImageSources: [String: String] = [:]  // imageSrc -> permanentId

            // Process inserts BEFORE updates — so idMapping is populated when
            // a temp-ID update arrives for a block that was also inserted
            for insert in changes.inserts {
                // Calculate sort order based on afterBlockId
                var sortOrder: Double
                let resolvedAfterId = insert.afterBlockId.map { idMapping[$0] ?? $0 }
                if let afterId = resolvedAfterId,
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
                } else if resolvedAfterId == nil, insert.atDocumentStart == true {
                    // Block is literal ProseMirror doc position 0 — anchor it before the
                    // current first block instead of falling through to append-at-end.
                    let firstBlock = try Block
                        .filter(Block.Columns.projectId == projectId)
                        .order(Block.Columns.sortOrder)
                        .fetchOne(db)
                    if let first = firstBlock {
                        sortOrder = first.sortOrder / 2.0
                    } else {
                        sortOrder = 1.0
                    }
                } else {
                    // No afterBlockId (and not atDocumentStart), or afterBlockId present but
                    // unresolvable — use the shared running counter
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
                    headingLevel: effectiveHeadingLevel,
                    // A genuinely new section_break block (the /break "text before" / "text
                    // after" / "split" cases all insert one) must be flagged as a pseudo-section
                    // here — observeOutlineBlocks and fetchOutlineBlocks filter on isPseudoSection,
                    // not blockType, so without this the block silently never appears in the
                    // outline sidebar despite being correctly typed as .sectionBreak.
                    isPseudoSection: blockType == .sectionBreak
                )
                block.recalculateWordCount()

                // Mark footnote definitions as isNotes (safety net for editor-created blocks)
                if insertTrimmed.range(of: #"^\[\^\d+\]:\s*"#, options: .regularExpression) != nil {
                    block.isNotes = true
                }

                // Auto-populate image metadata from markdown for image blocks
                if blockType == .image {
                    let meta = BlockParser.parseImageFragmentMeta(from: insertTrimmed)
                    block.imageSrc = meta.src
                    block.imageAlt = meta.alt
                    block.imageCaption = meta.caption
                    // Parse {width=N%} from Pandoc attributes
                    block.imageWidth = BlockParser.parseImageWidthPercent(from: insertTrimmed)

                    // Within-batch dedup: skip duplicate image inserts in the same sync cycle
                    if let src = block.imageSrc, !src.isEmpty {
                        if let existingId = insertedImageSources[src] {
                            idMapping[insert.tempId] = existingId
                            DebugLog.log(.data, "[Blocks] Skipped duplicate image insert: \(src)")
                            continue
                        }
                    }
                }

                try block.insert(db)

                // Record image source for within-batch dedup
                if blockType == .image, let src = block.imageSrc, !src.isEmpty {
                    insertedImageSources[src] = permanentId
                }

                // Record the mapping from temp ID to permanent ID
                idMapping[insert.tempId] = permanentId
            }

            // Process updates (after inserts so idMapping is available for temp-ID lookups)
            for update in changes.updates {
                if var block = try Block.fetchOne(db, key: update.id) {
                    // Safety net: never overwrite bibliography blocks via editor sync
                    // Bibliography content is machine-generated by BibliographySyncService
                    if block.isBibliography {
                        DebugLog.log(.data, "[Database+Blocks] Rejecting update to bibliography block: \(update.id.prefix(8))")
                        continue
                    }
                    // Safety net: never let a stale editor diff revert or destroy a Notes row's
                    // footnote label. Legitimate definition-text edits (label unchanged) are allowed —
                    // the forced-flush pipeline in handleFootnoteInsertedImmediate depends on them.
                    // A label change here means JS held a pre-rename view (reconcileNotesBlocks renames
                    // labels in place, keeping the same block id), so reject it.
                    // Note: a user manually retyping an existing Notes row's label in place is
                    // indistinguishable from this stale-rename-revert signature and will also be
                    // silently rejected — accepted trade-off, same category as the manual-deletion
                    // callout below.
                    // (Checked: this guard cannot be bypassed via a markdownFragment == nil,
                    // textContent-only update. block-sync-plugin.ts's detectChanges always sets
                    // markdownFragment via getMarkdownFragment(newBlock) — a non-optional string —
                    // whenever it enqueues a pendingUpdate, so the editor diff never omits it.)
                    if block.isNotes, let incomingFragment = update.markdownFragment {
                        let currentLabel = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label
                        let incomingLabel = FootnoteSyncService.parseNotesLabel(from: incomingFragment)?.label
                        if incomingLabel != currentLabel {
                            DebugLog.log(.data, "[Database+Blocks] Rejecting label-changing update to notes block: \(update.id.prefix(8)) (\(currentLabel ?? "nil")→\(incomingLabel ?? "nil"))")
                            continue
                        }
                    }
                    // Block found - apply updates
                    if let textContent = update.textContent {
                        block.textContent = textContent
                        let oldWC = block.wordCount
                        block.recalculateWordCount()
                        if oldWC != block.wordCount {
                            let id8 = String(block.id.prefix(8))
                            DebugLog.log(.data, "[Blocks:edit] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                        }
                    }
                    if let markdownFragment = update.markdownFragment {
                        block.markdownFragment = markdownFragment
                        // Detect block type changes from content (e.g., paragraph → heading from paste)
                        let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression),
                           !MarkdownUtils.isGhostImageMarkdown(String(trimmed[match.upperBound...])) {
                            let hashes = trimmed[match].filter { $0 == "#" }
                            block.blockType = .heading
                            block.headingLevel = hashes.count
                            block.isPseudoSection = false
                            // Strip heading prefix from textContent for sidebar display
                            if let textContent = update.textContent, textContent.hasPrefix("#") {
                                block.textContent = BlockParser.extractTextContent(from: trimmed, blockType: .heading)
                                let oldWC = block.wordCount
                                block.recalculateWordCount()
                                if oldWC != block.wordCount {
                                    let id8 = String(block.id.prefix(8))
                                    DebugLog.log(.data, "[Blocks:edit:→heading] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                                }
                            }
                        } else if trimmed.contains("<!-- ::break:: -->") {
                            // paragraph → section_break in-place conversion (bare /break on an
                            // empty paragraph reaches here as an UPDATE, not an INSERT — see
                            // block-id-plugin.ts phase1CanClaim: section_break is not in
                            // ATOMIC_BLOCK_TYPES, so the exact-offset claim keeps the paragraph's
                            // existing block ID). Without isPseudoSection=true here, the block
                            // never satisfies observeOutlineBlocks'/fetchOutlineBlocks' filter and
                            // silently never appears in the outline sidebar.
                            block.blockType = .sectionBreak
                            block.headingLevel = nil
                            block.isPseudoSection = true
                            block.textContent = ""
                            let oldWC = block.wordCount
                            block.recalculateWordCount()
                            if oldWC != block.wordCount {
                                let id8 = String(block.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:→sectionBreak] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                            }
                        } else if block.blockType == .paragraph,
                                  trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil {
                            // paragraph → horizontal_rule in-place conversion (typing "---"
                            // character-by-character into an EXISTING paragraph reaches here as
                            // an UPDATE, not an INSERT — see block-id-plugin.ts phase1CanClaim: hr
                            // is not in ATOMIC_BLOCK_TYPES and the block count doesn't change, so
                            // the exact-offset claim keeps the paragraph's existing block ID.
                            // Without this branch the row silently stayed a paragraph with
                            // markdownFragment '---' and the next sync minted a duplicate hr insert.
                            //
                            // Scope, confirmed (see review notes on this branch, superdev
                            // hr-block-sync-types round 2):
                            // - Paragraph-only by construction (the `block.blockType == .paragraph`
                            //   guard above): a code_block's markdownFragment is always fence-wrapped
                            //   ("```lang\n…\n```", see nodeToMarkdownFragment in
                            //   block-sync-plugin.ts) so it could never trim down to bare dashes
                            //   even without this guard — the explicit check is defensive
                            //   belt-and-suspenders against a future serializer change, and it also
                            //   protects blockquote/list/table/heading/image/math rows the same way.
                            // - Escape handling matches BlockParser.swift's own thematic-break
                            //   detector (line ~396, identical `^[-*_]{3,}$` pattern) exactly — ANY
                            //   leading backslash (e.g. `\---`) fails the anchored match on both
                            //   sides, so literal escaped dashes are never misread as a rule. This
                            //   branch deliberately does not invent different escape semantics.
                            //   (Separately: block-sync-plugin.ts's escapeInlineText only
                            //   re-escapes a leading `#`/`[^N]:` on round-trip, not leading `-`/`*`/
                            //   `_` — so a paragraph whose true text content is exactly "---" is
                            //   already ambiguous with a real rule before it reaches Swift at all.
                            //   That ambiguity is pre-existing on both the old BlockParser.swift
                            //   detector and this branch equally; not a regression introduced here.)
                            // - All three CommonMark thematic-break characters (-, *, _) are
                            //   covered — same `{3,}` character class as BlockParser.swift, not a
                            //   narrower "---"-only pattern.
                            // - WYSIWYG-only: this whole applyBlockChangesFromEditor() function is
                            //   reached only via BlockSyncService.applyChanges(), which is fed by
                            //   the Milkdown webview's getBlockChanges() poll —
                            //   BlockSyncService.configure(webView:) is wired up exclusively from
                            //   MilkdownEditor's onWebViewReady (ContentView+ContentRebuilding.swift),
                            //   never from CodeMirrorEditor's. Source Mode content instead flows
                            //   through flushContentToDatabase() → BlockParser.parse() (a full
                            //   document reparse using the same pre-existing detector referenced
                            //   above), a completely different path this branch cannot see. So a
                            //   YAML-frontmatter "---" delimiter or mid-typing source text can never
                            //   reach this specific branch — only a WYSIWYG paragraph whose full
                            //   trimmed content is already exactly "---"/"***"/"___" does.
                            block.blockType = .horizontalRule
                            block.headingLevel = nil
                            block.textContent = ""
                            let oldWC = block.wordCount
                            block.recalculateWordCount()
                            if oldWC != block.wordCount {
                                let id8 = String(block.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:→horizontalRule] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                            }
                        } else if block.blockType == .heading {
                            // Was heading but no longer has heading syntax
                            block.blockType = .paragraph
                            block.headingLevel = nil
                            // Type changed: recalculate against the new type's rules
                            let oldWC = block.wordCount
                            block.recalculateWordCount()
                            if oldWC != block.wordCount {
                                let id8 = String(block.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:→paragraph] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                            }
                        } else if block.blockType == .horizontalRule {
                            // Defensive symmetry with the heading/sectionBreak reverse cases above:
                            // user backspaces into an existing hr row, turning "---" back into
                            // plain text that no longer matches the thematic-break pattern.
                            block.blockType = .paragraph
                            block.headingLevel = nil
                            let oldWC = block.wordCount
                            block.recalculateWordCount()
                            if oldWC != block.wordCount {
                                let id8 = String(block.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:→paragraph:fromHorizontalRule] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                            }
                        } else if block.blockType == .sectionBreak {
                            // Defensive symmetry: a section_break block is a leaf node with no
                            // editable content in the ProseMirror schema, so this branch is
                            // believed unreachable via normal editing; kept defensively —
                            // reachability via deleting the sole/last section_break, causing
                            // ProseMirror to backfill an empty paragraph at the same offset
                            // (which could claim the section_break's block id via the normal
                            // UPDATE path, since section_break isn't in ATOMIC_BLOCK_TYPES and
                            // meaningfulTextOverlap treats empty↔empty as a valid claim), is
                            // plausible but unverified. Kept so isPseudoSection can never drift
                            // out of sync with blockType if that path exists.
                            block.blockType = .paragraph
                            block.isPseudoSection = false
                            let oldWC = block.wordCount
                            block.recalculateWordCount()
                            if oldWC != block.wordCount {
                                let id8 = String(block.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:→paragraph:fromSectionBreak] block=\(id8) oldWC=\(oldWC) newWC=\(block.wordCount)")
                            }
                        }
                        // Re-extract image width AND caption/alt from the updated fragment
                        // (unconditional: clears if removed). This path fires for things like
                        // ProseMirror undo/redo of a caption/alt edit, which doesn't go through
                        // the dedicated "update image meta" message — export reads the
                        // imageCaption/imageAlt DB columns (not live document text), so without
                        // this an export could keep showing a stale caption/alt the editor no
                        // longer displays.
                        if block.blockType == .image {
                            block.imageWidth = BlockParser.parseImageWidthPercent(from: trimmed)
                            let meta = BlockParser.parseImageFragmentMeta(from: trimmed)
                            block.imageAlt = meta.alt
                            block.imageCaption = meta.caption
                        }
                    }
                    if let headingLevel = update.headingLevel {
                        block.headingLevel = headingLevel
                    }

                    block.updatedAt = Date()
                    try block.update(db)
                } else if update.id.hasPrefix("temp-") {
                    // Check if this temp ID was already inserted (and assigned a permanent ID)
                    if let permanentId = idMapping[update.id],
                       var existingBlock = try Block.fetchOne(db, key: permanentId) {
                        // Update the already-inserted block with newer content
                        if let textContent = update.textContent {
                            existingBlock.textContent = textContent
                            let oldWC = existingBlock.wordCount
                            existingBlock.recalculateWordCount()
                            if oldWC != existingBlock.wordCount {
                                let id8 = String(existingBlock.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:merged] block=\(id8) oldWC=\(oldWC) newWC=\(existingBlock.wordCount)")
                            }
                        }
                        if let markdownFragment = update.markdownFragment {
                            existingBlock.markdownFragment = markdownFragment
                            let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                            // paragraph ↔ horizontal_rule in-place conversion, mirrored from the
                            // primary update branch above. A temp-ID block can hit THIS merge path
                            // instead of that one when its permanent-ID confirmation races an
                            // in-flight "---" edit (see the "Fix 1 (JS remap) and Fix 2 (Swift
                            // resolution)" comment on the stale-temp-id branch below). Same scope
                            // as the primary branch: paragraph-only guard, identical
                            // BlockParser.swift-matching regex (all 3 rule chars, no special
                            // escape handling), WYSIWYG-only (this whole function is never reached
                            // from Source Mode/CodeMirror) — see the primary branch's doc comment
                            // above for the full analysis.
                            if existingBlock.blockType == .paragraph,
                               trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil {
                                existingBlock.blockType = .horizontalRule
                                existingBlock.headingLevel = nil
                                existingBlock.textContent = ""
                                existingBlock.recalculateWordCount()
                            } else if existingBlock.blockType == .horizontalRule {
                                existingBlock.blockType = .paragraph
                                existingBlock.headingLevel = nil
                                existingBlock.recalculateWordCount()
                            }
                            // Re-derive image width/caption/alt alongside the generic .update
                            // case above — see its comment for why (undo/redo etc. can reach
                            // this merge path too, and export reads these DB columns directly).
                            if existingBlock.blockType == .image {
                                existingBlock.imageWidth = BlockParser.parseImageWidthPercent(from: trimmed)
                                let meta = BlockParser.parseImageFragmentMeta(from: trimmed)
                                existingBlock.imageAlt = meta.alt
                                existingBlock.imageCaption = meta.caption
                            }
                        }
                        if let headingLevel = update.headingLevel {
                            existingBlock.headingLevel = headingLevel
                        }
                        existingBlock.updatedAt = Date()
                        try existingBlock.update(db)
                        DebugLog.log(.data, "[Database+Blocks] Merged temp update into insert: \(update.id) → \(permanentId)")
                    } else if var existingBlock = try Block.fetchOne(db, key: update.id) {
                        // Block exists with temp ID (defensive)
                        if let textContent = update.textContent {
                            existingBlock.textContent = textContent
                            let oldWC = existingBlock.wordCount
                            existingBlock.recalculateWordCount()
                            if oldWC != existingBlock.wordCount {
                                let id8 = String(existingBlock.id.prefix(8))
                                DebugLog.log(.data, "[Blocks:edit:defensive] block=\(id8) oldWC=\(oldWC) newWC=\(existingBlock.wordCount)")
                            }
                        }
                        if let markdownFragment = update.markdownFragment {
                            existingBlock.markdownFragment = markdownFragment
                            let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                            // paragraph ↔ horizontal_rule in-place conversion — see the identical
                            // branch on the "already inserted" merge path above for why a temp-ID
                            // block can reach this defensive path too. Same paragraph-only guard
                            // and scope as the primary branch (see its doc comment above).
                            if existingBlock.blockType == .paragraph,
                               trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil {
                                existingBlock.blockType = .horizontalRule
                                existingBlock.headingLevel = nil
                                existingBlock.textContent = ""
                                existingBlock.recalculateWordCount()
                            } else if existingBlock.blockType == .horizontalRule {
                                existingBlock.blockType = .paragraph
                                existingBlock.headingLevel = nil
                                existingBlock.recalculateWordCount()
                            }
                            // Re-derive image width/caption/alt — see the generic .update case
                            // above for why (this defensive temp-id path can carry a caption/alt
                            // edit too, and export reads these DB columns directly).
                            if existingBlock.blockType == .image {
                                existingBlock.imageWidth = BlockParser.parseImageWidthPercent(from: trimmed)
                                let meta = BlockParser.parseImageFragmentMeta(from: trimmed)
                                existingBlock.imageAlt = meta.alt
                                existingBlock.imageCaption = meta.caption
                            }
                        }
                        if let headingLevel = update.headingLevel {
                            existingBlock.headingLevel = headingLevel
                        }
                        existingBlock.updatedAt = Date()
                        try existingBlock.update(db)
                    } else {
                        // Stale temp ID — block was already confirmed to a permanent ID
                        // in a previous poll cycle. Drop the update safely.
                        // This fires only if both Fix 1 (JS remap) and Fix 2 (Swift resolution) failed.
                        DebugLog.log(.data, "[Database+Blocks] Dropping stale temp update: \(update.id) (no matching block)")
                    }
                } else {
                    DebugLog.log(.data, "[Database+Blocks] Warning: Block not found for update: \(update.id)")
                }
            }
        }

        return idMapping
    }

    // MARK: - Image Deduplication

    /// Remove adjacent duplicate image blocks (same markdownFragment in consecutive sort order positions).
    /// Keeps the first occurrence, deletes the rest. Only affects blocks that are consecutive by array index
    /// when sorted by sortOrder — legitimately repeated images with distant sort orders are preserved.
    func deduplicateAdjacentImageBlocks(projectId: String) throws {
        try write { db in
            let imageBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.image.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            guard imageBlocks.count > 1 else { return }

            var idsToDelete: [String] = []
            var previousSrc: String?

            for block in imageBlocks {
                let src = block.imageSrc ?? ""
                if !src.isEmpty && src == previousSrc {
                    idsToDelete.append(block.id)
                } else {
                    previousSrc = src
                }
            }

            if !idsToDelete.isEmpty {
                try Block.deleteAll(db, keys: idsToDelete)
                DebugLog.always("[Blocks] Removed \(idsToDelete.count) duplicate image blocks from project \(projectId.prefix(8))")
                for id in idsToDelete {
                    DebugLog.log(.data, "[Blocks] Deleted duplicate image block: \(id.prefix(8))")
                }
            }
        }
    }

    // MARK: - Image Metadata

    /// Update image metadata for a block (caption, alt text, width)
    func updateBlockImageMeta(
        id: String,
        imageSrc: String? = nil,
        imageAlt: String? = nil,
        imageCaption: String? = nil,
        imageWidth: Int? = nil
    ) throws {
        try write { db in
            guard var block = try Block.fetchOne(db, key: id) else {
                DebugLog.log(.data, "[Database+Blocks] Block not found for image meta update: \(id)")
                return
            }

            if let src = imageSrc {
                block.imageSrc = src
            }
            if let alt = imageAlt {
                block.imageAlt = alt
            }
            if let caption = imageCaption {
                block.imageCaption = caption
            }
            if let width = imageWidth {
                block.imageWidth = width
                // KEY FIX: Also encode width in the markdown fragment so it survives round-trips
                block.markdownFragment = Self.updateWidthInMarkdown(block.markdownFragment, width: width)
                DebugLog.log(.image, "[updateBlockImageMeta] id=\(id.prefix(8)) width=\(width) fragment=\(block.markdownFragment.prefix(80))")
            }

            block.updatedAt = Date()
            try block.update(db)
        }
    }

    /// Update or insert `{width=N%}` in a markdown fragment containing an image.
    /// - Has `{...width=N%...}` → update the number
    /// - Has `{...}` without width → insert `width=N%` before `}`
    /// - No `{...}` after image → append `{width=N%}`
    /// - No image pattern → return unchanged
    static func updateWidthInMarkdown(_ fragment: String, width: Int) -> String {
        // Find the image pattern: ![...](...) — capture range for reuse in Case 3
        guard let imageRange = fragment.range(of: #"!\[[^\]]*\]\([^)]+\)"#, options: .regularExpression) else {
            return fragment
        }

        // Case 1: Already has {width=N%} — update the number
        if let existing = fragment.range(
            of: #"(\{[^}]*width=)\d+(%[^}]*\})"#,
            options: .regularExpression
        ) {
            let match = String(fragment[existing])
            // Replace just the digits between width= and %
            if let updated = match.range(of: #"(?<=width=)\d+(?=%)"#, options: .regularExpression) {
                var result = fragment
                let globalRange = result.range(of: match)!
                var newMatch = match
                newMatch.replaceSubrange(updated, with: "\(width)")
                result.replaceSubrange(globalRange, with: newMatch)
                return result
            }
        }

        // Case 2: Has {...} without width — insert width=N% before }
        // Find the LAST occurrence of {...} after the image pattern
        if let braceRange = fragment.range(of: #"\{[^}]*\}"#, options: [.regularExpression, .backwards]) {
            var result = fragment
            let braceStr = String(fragment[braceRange])
            let insertPos = braceStr.index(before: braceStr.endIndex)
            var newBrace = braceStr
            let prefix = braceStr.count > 2 ? " " : ""  // Add space if there's existing content
            newBrace.insert(contentsOf: "\(prefix)width=\(width)%", at: insertPos)
            result.replaceSubrange(braceRange, with: newBrace)
            return result
        }

        // Case 3: No {...} — append {width=N%} after image (reuse imageRange from guard)
        var result = fragment
        result.insert(contentsOf: "{width=\(width)%}", at: imageRange.upperBound)
        return result
    }

}
