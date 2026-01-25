//
//  Database+Sections.swift
//  final final
//

import Foundation
import GRDB

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

    /// Replace all sections for a project (used by sync service)
    func replaceSections(_ sections: [Section], for projectId: String) throws {
        try write { db in
            // Delete existing sections
            try Section
                .filter(Section.Columns.projectId == projectId)
                .deleteAll(db)

            // Insert new sections
            for var section in sections {
                try section.insert(db)
            }
        }
    }

    /// Recalculate word counts for all sections in a project
    func recalculateWordCounts(projectId: String) throws {
        try write { db in
            var sections = try Section
                .filter(Section.Columns.projectId == projectId)
                .fetchAll(db)

            for i in sections.indices {
                sections[i].recalculateWordCount()
                sections[i].updatedAt = Date()
                try sections[i].update(db)
            }
        }
    }

    /// Get aggregated word count for a section and all its descendants
    func aggregatedWordCount(sectionId: String) throws -> Int {
        try read { db in
            guard let section = try Section.fetchOne(db, key: sectionId) else { return 0 }

            var total = section.wordCount

            // Add children's counts recursively
            func addChildCounts(parentId: String) throws {
                let children = try Section
                    .filter(Section.Columns.parentId == parentId)
                    .fetchAll(db)

                for child in children {
                    total += child.wordCount
                    try addChildCounts(parentId: child.id)
                }
            }

            try addChildCounts(parentId: sectionId)
            return total
        }
    }
}
