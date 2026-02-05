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

    // MARK: Content

    func fetchContent(for projectId: String) throws -> Content? {
        try read { db in
            try Content.filter(Column("projectId") == projectId).fetchOne(db)
        }
    }

    func saveContent(markdown: String, for projectId: String) throws {
        try write { db in
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

        // Rebuild outline cache
        try rebuildOutlineCache(markdown: markdown, projectId: projectId)
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
        print("[ProjectDatabase] Rebuilt outline cache: \(nodes.count) nodes")
    }
}
