//
//  Database.swift
//  final final
//

import Foundation
import GRDB

struct AppDatabase: Sendable {
    let dbWriter: any DatabaseWriter & Sendable

    /// Creates a persistent database in Application Support directory
    static func makeDefault() throws -> AppDatabase {
        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appSupportURL = supportURL.appendingPathComponent("com.kerim.final-final", isDirectory: true)
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let dbPath = appSupportURL.appendingPathComponent("database.sqlite").path
        return try make(at: dbPath)
    }

    /// Creates an in-memory database (for testing)
    static func makeInMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let database = AppDatabase(dbWriter: dbQueue)
        try database.migrate()
        return database
    }

    static func make(at path: String) throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(path: path)
        let database = AppDatabase(dbWriter: dbQueue)
        try database.migrate()
        return database
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

        migrator.registerMigration("v2_recent_projects") { db in
            try db.create(table: "recentProject") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(index: "recentProject_lastOpened", on: "recentProject", columns: ["lastOpenedAt"])
        }

        try migrator.migrate(dbWriter)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }
}

// MARK: - AppDatabase Recent Projects

extension AppDatabase {
    func fetchRecentProjects(limit: Int = 10) throws -> [RecentProject] {
        try read { db in
            try RecentProject
                .order(Column("lastOpenedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func addRecentProject(path: String, title: String) throws {
        try write { db in
            // Check if already exists
            if var existing = try RecentProject.filter(Column("path") == path).fetchOne(db) {
                existing.title = title
                existing.lastOpenedAt = Date()
                try existing.update(db)
            } else {
                var recent = RecentProject(path: path, title: title)
                try recent.insert(db)
            }
        }
    }

    func removeRecentProject(at path: String) throws {
        try write { db in
            try RecentProject.filter(Column("path") == path).deleteAll(db)
        }
    }

    func clearRecentProjects() throws {
        try write { db in
            try RecentProject.deleteAll(db)
        }
    }
}
