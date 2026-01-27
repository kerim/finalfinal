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
    static func create(package: ProjectPackage, title: String) throws -> ProjectDatabase {
        let db = try ProjectDatabase(package: package)
        try db.dbWriter.write { database in
            var project = Project(title: title)
            try project.insert(database)

            var content = Content(projectId: project.id)
            try content.insert(database)
        }
        return db
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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
}
