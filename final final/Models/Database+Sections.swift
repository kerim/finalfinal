//
//  Database+Sections.swift
//  final final
//

import Foundation
import GRDB

// MARK: - Section Change Types

/// Represents a surgical change to apply to the sections table
enum SectionChange: Sendable {
    case insert(Section)
    case update(id: String, updates: SectionUpdates)
    case delete(id: String)

    /// Sweeps a genuine DUPLICATE flagged (`isBibliography`/`isNotes`) row (`loserId`) that
    /// lost this pass's match to a sibling row (`survivorId`), while preserving whatever real
    /// user data the loser was carrying instead of silently discarding it as a side effect of
    /// the delete:
    ///   1. Any `annotation` rows pointed at `loserId` are reassigned to `survivorId` --
    ///      without this, `annotation.sectionId`'s `onDelete: .setNull` FK trigger would fire
    ///      first and simply null them out, disconnecting real user annotations from any
    ///      section.
    ///   2. `survivorUpdates` (built by `SectionReconciler.mergeSurvivorUpdates`) carries the
    ///      loser's `status`/`tags`/`wordGoal` onto the survivor, but ONLY for fields where
    ///      the survivor itself is still at its default -- a survivor's own real data is never
    ///      clobbered by the loser's.
    ///   3. The loser row is then deleted.
    /// Plain `.delete` remains correct for the OTHER sweep case -- the flag is verifiably gone
    /// (`bibliographyGone`/`notesGone`), meaning there is no winning sibling this pass to
    /// migrate data onto. See `SectionReconciler`'s delete-sweep doc comment for the full
    /// reasoning, and `isExemptFromDeleteSweep`/`duplicateSurvivor` for how the two cases are
    /// told apart.
    case deleteDuplicate(loserId: String, survivorId: String, survivorUpdates: SectionUpdates)
}

/// Updates to apply to an existing section (all fields optional)
struct SectionUpdates: Sendable {
    var title: String?
    var headerLevel: Int?
    var isPseudoSection: Bool?
    var sortOrder: Int?
    var markdownContent: String?
    var wordCount: Int?
    var startOffset: Int?
    var parentId: String??  // Double-optional: nil = don't change, .some(nil) = set to nil
    var isBibliography: Bool?
    var isNotes: Bool?
    /// Only ever populated by `SectionReconciler.mergeSurvivorUpdates` as part of a
    /// `.deleteDuplicate` change's `survivorUpdates` -- `buildUpdates` (the ordinary path)
    /// never sets these three. Single-optional like every field above except `parentId`:
    /// nil means "don't change" (never used here to explicitly clear a survivor's own
    /// status/tags/wordGoal back to default).
    var status: SectionStatus?
    var tags: [String]?
    var wordGoal: Int?

    init(
        title: String? = nil,
        headerLevel: Int? = nil,
        isPseudoSection: Bool? = nil,
        sortOrder: Int? = nil,
        markdownContent: String? = nil,
        wordCount: Int? = nil,
        startOffset: Int? = nil,
        parentId: String?? = nil,
        isBibliography: Bool? = nil,
        isNotes: Bool? = nil,
        status: SectionStatus? = nil,
        tags: [String]? = nil,
        wordGoal: Int? = nil
    ) {
        self.title = title
        self.headerLevel = headerLevel
        self.isPseudoSection = isPseudoSection
        self.sortOrder = sortOrder
        self.markdownContent = markdownContent
        self.wordCount = wordCount
        self.startOffset = startOffset
        self.parentId = parentId
        self.isBibliography = isBibliography
        self.isNotes = isNotes
        self.status = status
        self.tags = tags
        self.wordGoal = wordGoal
    }
}

// MARK: - ProjectDatabase Section CRUD

extension ProjectDatabase {

    // MARK: - Fetch Operations

    /// Fetch all sections for a project, sorted by sortOrder
    func fetchSections(projectId: String) throws -> [Section] {
        try read { db in
            try Section
                .filter(Section.Columns.projectId == projectId)
                .order(Section.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// C6: everything `SectionSyncService.syncContent`/`syncZoomedSections` need to read
    /// before calling `parseHeaders` and reconciling, gathered in ONE `read` transaction
    /// instead of the four-to-five separate `read {}` calls (`fetchSections`,
    /// `fetchBibliographyHeadingTitle`, an equivalent Notes query, `hasBibliographyBlocks`,
    /// `hasNotesBlocks`) each of those functions used to make independently. Each
    /// standalone `read` opens and closes its OWN transaction, so between any two of them a
    /// concurrent write on another `Task` (this whole call already runs inside
    /// `Task.detached`, off the MainActor serialization that would otherwise rule this out)
    /// could land -- e.g. a bibliography/Notes heading being flagged or unflagged mid-way
    /// through this function's own reads, making `existingBibTitle`/`bibliographyExistsInBlocks`
    /// (or their Notes equivalents) describe two different, inconsistent moments of the same
    /// project. Wrapping every one of those reads in a single transaction here gives them
    /// one consistent snapshot instead.
    struct SectionSyncSnapshot {
        let dbSections: [Section]
        let existingBibTitle: String?
        let existingNotesTitle: String?
        let bibliographyExistsInBlocks: Bool
        let notesExistsInBlocks: Bool
    }

    /// See `SectionSyncSnapshot`'s doc comment. `existingBibTitle`/`existingNotesTitle` keep
    /// the exact same block-table-first, section-table-fallback precedence
    /// `fetchBibliographyHeadingTitle`'s own doc comment describes (the "first
    /// citation/footnote ever" gap) -- `fetchNotesHeadingTitle` (C2) closes the same gap for
    /// Notes that already existed for Bibliography.
    func fetchSectionSyncSnapshot(projectId: String) throws -> SectionSyncSnapshot {
        try read { db in
            let dbSections = try Section
                .filter(Section.Columns.projectId == projectId)
                .order(Section.Columns.sortOrder)
                .fetchAll(db)
            let bibHeadingTitle = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.isBibliography == true)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)?.textContent
            let notesHeadingTitle = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.isNotes == true)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)?.textContent
            let bibliographyExistsInBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == true)
                .fetchCount(db) > 0
            let notesExistsInBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isNotes == true)
                .fetchCount(db) > 0
            return SectionSyncSnapshot(
                dbSections: dbSections,
                existingBibTitle: bibHeadingTitle ?? dbSections.first(where: { $0.isBibliography })?.title,
                existingNotesTitle: notesHeadingTitle ?? dbSections.first(where: { $0.isNotes })?.title,
                bibliographyExistsInBlocks: bibliographyExistsInBlocks,
                notesExistsInBlocks: notesExistsInBlocks
            )
        }
    }

    /// Fetch only root sections (no parent) for a project
    func fetchRootSections(projectId: String) throws -> [Section] {
        try read { db in
            try Section
                .filter(Section.Columns.projectId == projectId)
                .filter(Section.Columns.parentId == nil)
                .order(Section.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch direct children of a section
    func fetchChildren(of sectionId: String) throws -> [Section] {
        try read { db in
            try Section
                .filter(Section.Columns.parentId == sectionId)
                .order(Section.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch a single section by ID
    func fetchSection(id: String) throws -> Section? {
        try read { db in
            try Section.fetchOne(db, key: id)
        }
    }

    /// Fetch sections filtered by status
    func fetchSections(projectId: String, status: SectionStatus) throws -> [Section] {
        try read { db in
            try Section
                .filter(Section.Columns.projectId == projectId)
                .filter(Section.Columns.status == status.rawValue)
                .order(Section.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch all descendants of a section (for zoom view)
    func fetchDescendants(of sectionId: String) throws -> [Section] {
        try read { db in
            var result: [Section] = []
            var toProcess = [sectionId]

            while !toProcess.isEmpty {
                let parentId = toProcess.removeFirst()
                let children = try Section
                    .filter(Section.Columns.parentId == parentId)
                    .order(Section.Columns.sortOrder)
                    .fetchAll(db)

                result.append(contentsOf: children)
                toProcess.append(contentsOf: children.map(\.id))
            }

            return result
        }
    }

    // MARK: - Insert/Update Operations

    /// Insert a new section
    func insertSection(_ section: Section) throws {
        var section = section
        try write { db in
            try section.insert(db)
        }
    }

    /// Update an existing section
    func updateSection(_ section: Section) throws {
        var updated = section
        updated.updatedAt = Date()
        try write { db in
            try updated.update(db)
        }
    }

    /// Update section status
    func updateSectionStatus(id: String, status: SectionStatus) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE section SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [status.rawValue, Date(), id]
            )
        }
    }

    /// Update section word goal
    func updateSectionWordGoal(id: String, goal: Int?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE section SET wordGoal = ?, updatedAt = ? WHERE id = ?",
                arguments: [goal, Date(), id]
            )
        }
    }

    /// Update section goal type
    func updateSectionGoalType(id: String, goalType: GoalType) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE section SET goalType = ?, updatedAt = ? WHERE id = ?",
                arguments: [goalType.rawValue, Date(), id]
            )
        }
    }

    /// Update section tags
    func updateSectionTags(id: String, tags: [String]) throws {
        let tagsData = try JSONEncoder().encode(tags)
        let tagsString = String(data: tagsData, encoding: .utf8) ?? "[]"
        try write { db in
            try db.execute(
                sql: "UPDATE section SET tags = ?, updatedAt = ? WHERE id = ?",
                arguments: [tagsString, Date(), id]
            )
        }
    }

    // MARK: - Delete Operations

    /// Delete a section and optionally move its children up to the parent
    func deleteSection(id: String, moveChildrenUp: Bool = true) throws {
        try write { db in
            guard let section = try Section.fetchOne(db, key: id) else { return }

            if moveChildrenUp {
                // Move children to parent (or root if no parent)
                try db.execute(
                    sql: "UPDATE section SET parentId = ?, updatedAt = ? WHERE parentId = ?",
                    arguments: [section.parentId, Date(), id]
                )
            }
            // Note: If moveChildrenUp is false, cascade delete will remove children

            try Section.deleteOne(db, key: id)
        }
    }

    /// Delete all sections for a project
    func deleteAllSections(projectId: String) throws {
        try write { db in
            try Section
                .filter(Section.Columns.projectId == projectId)
                .deleteAll(db)
        }
    }

    // MARK: - Reorder Operations

    /// Reorder a section (drag-and-drop handler)
    /// - Parameters:
    ///   - id: Section ID to move
    ///   - newParentId: New parent section ID (nil for root)
    ///   - newSortOrder: New position in sibling list
    ///   - newLevel: New header level (optional, preserves if nil)
    func reorderSection(
        id: String,
        newParentId: String?,
        newSortOrder: Int,
        newLevel: Int? = nil
    ) throws {
        try write { db in
            guard var section = try Section.fetchOne(db, key: id) else { return }

            let oldParentId = section.parentId
            let oldLevel = section.headerLevel
            let levelDelta = (newLevel ?? oldLevel) - oldLevel

            // Update the moved section
            section.parentId = newParentId
            section.sortOrder = newSortOrder
            if let newLevel = newLevel {
                section.headerLevel = newLevel
            }
            section.updatedAt = Date()
            try section.update(db)

            // Adjust sort orders of siblings at new location
            try db.execute(
                sql: """
                    UPDATE section
                    SET sortOrder = sortOrder + 1, updatedAt = ?
                    WHERE projectId = ?
                    AND (parentId = ? OR (parentId IS NULL AND ? IS NULL))
                    AND sortOrder >= ?
                    AND id != ?
                    """,
                arguments: [Date(), section.projectId, newParentId, newParentId, newSortOrder, id]
            )

            // Adjust sort orders at old location (close the gap)
            if oldParentId != newParentId {
                try db.execute(
                    sql: """
                        UPDATE section
                        SET sortOrder = sortOrder - 1, updatedAt = ?
                        WHERE projectId = ?
                        AND (parentId = ? OR (parentId IS NULL AND ? IS NULL))
                        AND sortOrder > ?
                        """,
                    arguments: [Date(), section.projectId, oldParentId, oldParentId, section.sortOrder]
                )
            }

            // If level changed, update all descendants' levels proportionally
            if levelDelta != 0 {
                try updateDescendantLevels(db: db, parentId: id, levelDelta: levelDelta)
            }
        }
    }

    /// Recursively update descendant header levels
    private func updateDescendantLevels(db: Database, parentId: String, levelDelta: Int) throws {
        let children = try Section
            .filter(Section.Columns.parentId == parentId)
            .fetchAll(db)

        for var child in children {
            let newLevel = max(1, min(6, child.headerLevel + levelDelta))
            child.headerLevel = newLevel
            child.updatedAt = Date()
            try child.update(db)

            // Recurse into children
            try updateDescendantLevels(db: db, parentId: child.id, levelDelta: levelDelta)
        }
    }

    // MARK: - Bulk Operations

    /// Apply surgical section changes (insert/update/delete) within a single transaction
    /// This replaces the previous DELETE ALL + INSERT ALL pattern to prevent race conditions
    func applySectionChanges(_ changes: [SectionChange], for projectId: String) throws {
        try write { db in
            for change in changes {
                switch change {
                case .insert(var section):
                    try section.insert(db)

                case .update(let id, let updates):
                    guard var section = try Section.fetchOne(db, key: id) else { continue }
                    Self.applyFields(updates, to: &section)
                    try section.update(db)

                case .delete(let id):
                    try Section
                        .filter(Section.Columns.id == id)
                        .deleteAll(db)

                case .deleteDuplicate(let loserId, let survivorId, let survivorUpdates):
                    // Reassign the loser's annotations onto the survivor BEFORE deleting the
                    // loser -- annotation.sectionId's `onDelete: .setNull` FK trigger would
                    // otherwise fire first and null them out, disconnecting real user
                    // annotations from any section entirely.
                    try db.execute(
                        sql: "UPDATE annotation SET sectionId = ?, updatedAt = ? WHERE sectionId = ?",
                        arguments: [survivorId, Date(), loserId]
                    )

                    if var survivor = try Section.fetchOne(db, key: survivorId) {
                        Self.applyFields(survivorUpdates, to: &survivor)
                        try survivor.update(db)
                    }

                    try Section
                        .filter(Section.Columns.id == loserId)
                        .deleteAll(db)
                }
            }
        }
    }

    /// Applies every set field of `updates` onto `section` in place, bumping `updatedAt`.
    /// Shared by the `.update` and `.deleteDuplicate` cases above so both apply the exact
    /// same field semantics (in particular the `parentId` double-optional handling).
    private static func applyFields(_ updates: SectionUpdates, to section: inout Section) {
        applyContentFields(updates, to: &section)
        applyMetadataFields(updates, to: &section)
        section.updatedAt = Date()
    }

    private static func applyContentFields(_ updates: SectionUpdates, to section: inout Section) {
        if let title = updates.title {
            section.title = title
        }
        if let headerLevel = updates.headerLevel {
            section.headerLevel = headerLevel
        }
        if let isPseudoSection = updates.isPseudoSection {
            section.isPseudoSection = isPseudoSection
        }
        if let sortOrder = updates.sortOrder {
            section.sortOrder = sortOrder
        }
        if let markdownContent = updates.markdownContent {
            section.markdownContent = markdownContent
        }
        if let wordCount = updates.wordCount {
            section.wordCount = wordCount
        }
        if let startOffset = updates.startOffset {
            section.startOffset = startOffset
        }
        // Double-optional handling for parentId
        if let parentIdUpdate = updates.parentId {
            section.parentId = parentIdUpdate  // Can be nil or a value
        }
    }

    private static func applyMetadataFields(_ updates: SectionUpdates, to section: inout Section) {
        if let isBibliography = updates.isBibliography {
            section.isBibliography = isBibliography
        }
        if let isNotes = updates.isNotes {
            section.isNotes = isNotes
        }
        if let status = updates.status {
            section.status = status
        }
        if let tags = updates.tags {
            section.tags = tags
        }
        if let wordGoal = updates.wordGoal {
            section.wordGoal = wordGoal
        }
    }

    /// Replace all sections for a project (used by sync service)
    /// Sections are sorted topologically (parents before children) to satisfy foreign key constraints
    /// @deprecated Use applySectionChanges() for surgical updates instead
    func replaceSections(_ sections: [Section], for projectId: String) throws {
        try write { db in
            // Delete existing sections
            try Section
                .filter(Section.Columns.projectId == projectId)
                .deleteAll(db)

            // Sort sections: parents before children (topological sort)
            let sorted = topologicalSortSections(sections)

            // Insert in order
            for var section in sorted {
                try section.insert(db)
            }
        }
    }

    /// Sort sections so parents are inserted before children
    /// This prevents FOREIGN KEY constraint failures when sections reference parent IDs
    private func topologicalSortSections(_ sections: [Section]) -> [Section] {
        var result: [Section] = []
        var remaining = sections
        var insertedIds = Set<String>()

        // First pass: insert all root sections (no parent)
        let roots = remaining.filter { $0.parentId == nil }
        result.append(contentsOf: roots)
        insertedIds.formUnion(roots.map(\.id))
        remaining.removeAll { $0.parentId == nil }

        // Iteratively insert sections whose parents are already inserted
        while !remaining.isEmpty {
            let canInsert = remaining.filter { section in
                guard let parentId = section.parentId else { return true }
                return insertedIds.contains(parentId)
            }

            if canInsert.isEmpty {
                // Circular reference or orphaned sections - insert remaining anyway
                // This prevents infinite loops if data is corrupted
                result.append(contentsOf: remaining)
                break
            }

            result.append(contentsOf: canInsert)
            insertedIds.formUnion(canInsert.map(\.id))
            remaining.removeAll { canInsert.contains($0) }
        }

        return result
    }

}
