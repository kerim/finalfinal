//
//  Database+CRUD.swift
//  final final
//

import Foundation
import GRDB

// MARK: - ProjectDatabase CRUD

extension ProjectDatabase {
    // MARK: Project

    func fetchProject() throws -> Project? {
        try read { db in
            try Project.fetchOne(db)
        }
    }

    func updateProject(_ project: Project) throws {
        var updated = project
        updated.updatedAt = Date()
        try write { db in
            try updated.update(db)
        }
    }

    /// Update document goal settings without touching other fields
    func updateDocumentGoal(
        goal: Int?,
        goalType: GoalType,
        excludeBibliography: Bool
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE project
                    SET documentGoal = ?,
                        documentGoalType = ?,
                        excludeBibliography = ?,
                        updatedAt = ?
                    """,
                arguments: [goal, goalType.rawValue, excludeBibliography, Date()]
            )
        }
    }

    // MARK: Content

    func fetchContent(for projectId: String) throws -> Content? {
        try read { db in
            try Content.filter(Column("projectId") == projectId).fetchOne(db)
        }
    }

    func saveContent(markdown: String, for projectId: String) throws {
        try write { db in
            try Self.writeContentRow(db: db, markdown: markdown, projectId: projectId)
        }

        // Rebuild outline cache
        try rebuildOutlineCache(markdown: markdown, projectId: projectId)
    }

    /// `saveContent` on an open `Database` handle, for use INSIDE one write transaction (t-94369a83
    /// Phase 4b, slice 2a: `SectionDeleteJob` writes the content row, the outline cache, the Version History
    /// snapshot and the row delete in one transaction and must not open a nested `ProjectDatabase.write`).
    /// The same three writes `saveContent(markdown:for:)` makes, only in one transaction instead of three.
    static func saveContent(db: Database, markdown: String, projectId: String) throws {
        try writeContentRow(db: db, markdown: markdown, projectId: projectId)
        try rebuildOutlineCache(db: db, markdown: markdown, projectId: projectId)
    }

    /// The content row and project timestamp half of `saveContent`, shared by both forms.
    private static func writeContentRow(db: Database, markdown: String, projectId: String) throws {
        // Update content
        if var content = try Content.filter(Column("projectId") == projectId).fetchOne(db) {
            content.markdown = markdown
            content.updatedAt = Date()
            try content.update(db)
        }

        // Update project timestamp
        if var project = try Project.fetchOne(db) {
            project.updatedAt = Date()
            try project.update(db)
        }
    }

    /// `fetchContent` on an open `Database` handle (see `saveContent(db:markdown:projectId:)`).
    static func fetchContent(db: Database, projectId: String) throws -> Content? {
        try Content.filter(Column("projectId") == projectId).fetchOne(db)
    }

    // MARK: Outline Nodes

    func fetchOutlineNodes(for projectId: String) throws -> [OutlineNode] {
        try read { db in
            try OutlineNode
                .filter(Column("projectId") == projectId)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    func replaceOutlineNodes(_ nodes: [OutlineNode], for projectId: String) throws {
        try write { db in
            // Delete existing nodes
            try OutlineNode.filter(Column("projectId") == projectId).deleteAll(db)

            // Insert new nodes
            for var node in nodes {
                try node.insert(db)
            }
        }
    }

    private func rebuildOutlineCache(markdown: String, projectId: String) throws {
        // Get existing bibliography title for detection (when marker is not present)
        let existingBibTitle = try read { db in
            try Section
                .filter(Section.Columns.projectId == projectId)
                .filter(Section.Columns.isBibliography == true)
                .fetchOne(db)?
                .title
        }
        let nodes = OutlineParser.parse(markdown: markdown, projectId: projectId, existingBibTitle: existingBibTitle)
        try replaceOutlineNodes(nodes, for: projectId)
        DebugLog.log(.data, "[ProjectDatabase] Rebuilt outline cache: \(nodes.count) nodes")
    }

    /// `rebuildOutlineCache` on an open `Database` handle: the same bibliography-title read, parse and
    /// delete-then-insert of the nodes, inside the caller's transaction.
    private static func rebuildOutlineCache(db: Database, markdown: String, projectId: String) throws {
        let existingBibTitle = try Section
            .filter(Section.Columns.projectId == projectId)
            .filter(Section.Columns.isBibliography == true)
            .fetchOne(db)?
            .title
        let nodes = OutlineParser.parse(markdown: markdown, projectId: projectId, existingBibTitle: existingBibTitle)
        try OutlineNode.filter(Column("projectId") == projectId).deleteAll(db)
        for var node in nodes {
            try node.insert(db)
        }
        DebugLog.log(.data, "[ProjectDatabase] Rebuilt outline cache: \(nodes.count) nodes")
    }
}
