//
//  ProjectDatabase.swift
//  final final
//

import Foundation
import GRDB

final class ProjectDatabase: Sendable {
    let dbWriter: any DatabaseWriter & Sendable
    let package: ProjectPackage

    init(package: ProjectPackage) throws {
        self.package = package
        self.dbWriter = try DatabaseQueue(path: package.databaseURL.path)
        try migrate()
    }

    /// Creates a new project database with initial project and content
    /// - Parameters:
    ///   - package: The project package
    ///   - title: Project title
    ///   - initialContent: Initial markdown content (defaults to empty string)
    static func create(package: ProjectPackage, title: String, initialContent: String = "") throws -> ProjectDatabase {
        let db = try ProjectDatabase(package: package)
        try db.dbWriter.write { database in
            var project = Project(title: title)
            try project.insert(database)

            var content = Content(projectId: project.id, markdown: initialContent)
            try content.insert(database)
        }
        return db
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // Note: eraseDatabaseOnSchemaChange removed - it was causing databases to be wiped
        // on schema changes, leading to "noProjectInDatabase" errors. Migrations (v1-v4) are
        // stable and handle schema evolution properly.

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "content") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("markdown", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(index: "content_projectId", on: "content", columns: ["projectId"])

            try db.create(table: "outlineNode") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("headerLevel", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("parentId", .text)
                    .references("outlineNode", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("isPseudoSection", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "outlineNode_projectId", on: "outlineNode", columns: ["projectId"])

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        // Phase 1.6: Sections as blocks (replacing outline_nodes cache)
        migrator.registerMigration("v2_sections") { db in
            try db.create(table: "section") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("parentId", .text)
                    .references("section", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("headerLevel", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("markdownContent", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "writing")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("wordGoal", .integer)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(index: "section_projectId", on: "section", columns: ["projectId"])
            try db.create(index: "section_parentId", on: "section", columns: ["parentId"])
            try db.create(index: "section_sortOrder", on: "section", columns: ["projectId", "sortOrder"])
        }

        // Phase 1.6: Add startOffset to sections for scroll-to-section
        migrator.registerMigration("v3_section_offset") { db in
            try db.alter(table: "section") { t in
                t.add(column: "startOffset", .integer).notNull().defaults(to: 0)
            }
        }

        // Fix pseudo-section level inheritance: add isPseudoSection flag, fix headerLevel values
        migrator.registerMigration("v4_section_isPseudoSection") { db in
            try db.alter(table: "section") { t in
                t.add(column: "isPseudoSection", .boolean).notNull().defaults(to: false)
            }

            // Mark existing level-0 sections as pseudo-sections
            try db.execute(sql: "UPDATE section SET isPseudoSection = 1 WHERE headerLevel = 0")

            // Fix levels per-project, respecting document order
            // Pseudo-sections should inherit the level from the preceding real header
            let projectIds = try String.fetchAll(db, sql: "SELECT DISTINCT projectId FROM section")
            for projectId in projectIds {
                let sections = try Row.fetchAll(db, sql: """
                    SELECT id, headerLevel FROM section
                    WHERE projectId = ? ORDER BY sortOrder
                    """, arguments: [projectId])

                var lastActualLevel = 1  // Default to H1 if first section is pseudo
                for row in sections {
                    let id: String = row["id"]
                    let level: Int = row["headerLevel"]

                    if level == 0 {
                        // Pseudo-section: inherit level from last real header
                        try db.execute(
                            sql: "UPDATE section SET headerLevel = ? WHERE id = ?",
                            arguments: [lastActualLevel, id]
                        )
                    } else {
                        // Real header: track its level for subsequent pseudo-sections
                        lastActualLevel = level
                    }
                }
            }
        }

        // Phase 2: Annotations (task, comment, reference) stored as HTML comments in markdown
        migrator.registerMigration("v5_annotations") { db in
            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text)
                t.column("contentId", .text).notNull()
                    .references("content", onDelete: .cascade)
                t.column("sectionId", .text)
                    .references("section", onDelete: .setNull)
                t.column("type", .text).notNull()
                    .check(sql: "type IN ('task', 'comment', 'reference')")
                t.column("text", .text).notNull()
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("charOffset", .integer).notNull()
                t.column("highlightStart", .integer)
                t.column("highlightEnd", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(index: "annotation_contentId", on: "annotation", columns: ["contentId"])
            try db.create(index: "annotation_type", on: "annotation", columns: ["type"])
            try db.create(index: "annotation_sectionId", on: "annotation", columns: ["sectionId"])
        }

        // Phase 1.8: Bibliography section flag for auto-generated bibliography
        migrator.registerMigration("v6_bibliography") { db in
            try db.alter(table: "section") { t in
                t.add(column: "isBibliography", .boolean).notNull().defaults(to: false)
            }
        }

        // Phase 2: Version history (snapshots)
        migrator.registerMigration("v7_snapshots") { db in
            try db.create(table: "snapshot") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("name", .text)  // NULL for auto-backups
                t.column("createdAt", .datetime).notNull()
                t.column("isAutomatic", .boolean).notNull()
                t.column("previewMarkdown", .text).notNull()
            }

            try db.create(index: "snapshot_createdAt", on: "snapshot", columns: ["createdAt"])
            try db.create(index: "snapshot_projectId", on: "snapshot", columns: ["projectId"])

            try db.create(table: "snapshotSection") { t in
                t.primaryKey("id", .text)
                t.column("snapshotId", .text).notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("originalSectionId", .text)  // Plain TEXT, no FK (sections can be deleted)
                t.column("title", .text).notNull()
                t.column("markdownContent", .text).notNull()
                t.column("headerLevel", .integer).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("status", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("wordGoal", .integer)
            }

            try db.create(index: "snapshotSection_snapshotId", on: "snapshotSection", columns: ["snapshotId"])
        }

        try migrator.migrate(dbWriter)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: - Reactive Observation

    /// Returns an async sequence of section updates for reactive UI
    /// Uses ValueObservation to automatically push updates when the database changes
    func observeSections(for projectId: String) -> AsyncThrowingStream<[Section], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Section
                    .filter(Section.Columns.projectId == projectId)
                    .order(Section.Columns.sortOrder)
                    .fetchAll(db)
            }
            .removeDuplicates()  // Prevent unnecessary re-renders

        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: .main)
            ) { error in
                continuation.finish(throwing: error)
            } onChange: { sections in
                continuation.yield(sections)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// Returns an async sequence of annotation updates for reactive UI
    /// Uses ValueObservation to automatically push updates when annotations change
    func observeAnnotations(for contentId: String) -> AsyncThrowingStream<[Annotation], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Annotation
                    .filter(Annotation.Columns.contentId == contentId)
                    .order(Annotation.Columns.charOffset)
                    .fetchAll(db)
            }
            .removeDuplicates()

        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: .main)
            ) { error in
                continuation.finish(throwing: error)
            } onChange: { annotations in
                continuation.yield(annotations)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
