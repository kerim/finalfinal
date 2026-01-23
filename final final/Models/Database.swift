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

        try migrator.migrate(dbWriter)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }
}
