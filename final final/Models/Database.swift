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

        // Note: eraseDatabaseOnSchemaChange removed - it was causing databases to be wiped
        // on schema changes. Migrations are stable and handle schema evolution properly.

        // AppDatabase stores app-level state only (recent projects, global settings)
        // Project data (content, outline) is stored in per-project ProjectDatabase
        migrator.registerMigration("v1_app_database") { db in
            try db.create(table: "recentProject") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(index: "recentProject_lastOpened", on: "recentProject", columns: ["lastOpenedAt"])

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
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

// MARK: - Setting Record

struct Setting: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "settings"

    var key: String
    var value: String
}

// MARK: - AppDatabase Settings

extension AppDatabase {
    func getSetting(key: String) throws -> String? {
        try read { db in
            try Setting.filter(Column("key") == key).fetchOne(db)?.value
        }
    }

    func setSetting(key: String, value: String) throws {
        try write { db in
            var setting = Setting(key: key, value: value)
            try setting.save(db, onConflict: .replace)
        }
    }

    func deleteSetting(key: String) throws {
        try write { db in
            try Setting.filter(Column("key") == key).deleteAll(db)
        }
    }
}
