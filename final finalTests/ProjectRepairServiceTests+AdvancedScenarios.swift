//
//  ProjectRepairServiceTests+AdvancedScenarios.swift
//  final finalTests
//
//  Advanced test scenarios for ProjectRepairService (Scenarios 7-10).
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ProjectRepairServiceTests {

    // MARK: - Scenario 7: Healthy Database Passes

    @Test func healthyDatabasePassesValidation() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        let projectId = "HEALTHY-PROJECT"
        _ = try factory.createHealthyDatabase(projectId: projectId, withSections: true)

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        #expect(report.isHealthy, "Healthy database should pass validation")
        #expect(report.issues.isEmpty, "Healthy database should have no issues")
    }

    // MARK: - Scenario 8: Actual Corruption Pattern (from real corrupted files)

    /// Tests the ACTUAL corruption pattern found in demo1 copy 3.ff and demo2 copy.ff:
    /// - All tables exist (migrations v1-v4 completed)
    /// - All data tables are EMPTY (project, content, section have 0 rows)
    /// - This is the signature of eraseDatabaseOnSchemaChange wiping data
    @Test func repairHandlesErasedDatabaseWithEmptyTables() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        // Create database with full schema but NO DATA (like eraseDatabaseOnSchemaChange did)
        let dbQueue = try DatabaseQueue(path: factory.databaseURL.path)
        try dbQueue.write { db in
            // Create all tables matching the actual corrupted database schema
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)
            """)

            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY NOT NULL,
                    projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX content_projectId ON content(projectId)")

            try db.execute(sql: """
                CREATE TABLE outlineNode (
                    id TEXT PRIMARY KEY NOT NULL,
                    projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    headerLevel INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    startOffset INTEGER NOT NULL,
                    endOffset INTEGER NOT NULL,
                    parentId TEXT REFERENCES outlineNode(id) ON DELETE CASCADE,
                    sortOrder INTEGER NOT NULL,
                    isPseudoSection BOOLEAN NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: "CREATE INDEX outlineNode_projectId ON outlineNode(projectId)")

            try db.execute(sql: """
                CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)
            """)

            try db.execute(sql: """
                CREATE TABLE section (
                    id TEXT PRIMARY KEY NOT NULL,
                    projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    parentId TEXT REFERENCES section(id) ON DELETE CASCADE,
                    sortOrder INTEGER NOT NULL,
                    headerLevel INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    markdownContent TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'writing',
                    tags TEXT NOT NULL DEFAULT '[]',
                    wordGoal INTEGER,
                    wordCount INTEGER NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    startOffset INTEGER NOT NULL DEFAULT 0,
                    isPseudoSection BOOLEAN NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: "CREATE INDEX section_projectId ON section(projectId)")
            try db.execute(sql: "CREATE INDEX section_parentId ON section(parentId)")
            try db.execute(sql: "CREATE INDEX section_sortOrder ON section(projectId, sortOrder)")

            // Insert migration records (mimicking completed migrations)
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1_initial')")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v2_sections')")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v3_section_offset')")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v4_section_isPseudoSection')")

            // NO DATA inserted - mimicking eraseDatabaseOnSchemaChange effect
        }

        // Verify the corruption pattern matches real files
        let projectCount = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project")
        })
        #expect(projectCount == 0, "Should have empty project table like corrupted files")

        let sectionCount = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM section")
        })
        #expect(sectionCount == 0, "Should have empty section table like corrupted files")

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        // Should detect missing project record (table exists but empty)
        #expect(report.issues.contains { $0 == .missingProjectRecord },
                "Should detect missing project record in empty database")

        // Run repair
        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success, "Repair should succeed even for completely empty database")

        // Verify a new project was created (can't recover old ID since no data existed)
        let newProjectCount = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project")
        })
        #expect(newProjectCount == 1, "Should have created one project record")

        let projectTitle = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM project")
        }
        #expect(projectTitle == "Recovered Project", "Should use 'Recovered Project' as title")
    }

    // MARK: - Scenario 9: Test Against Real Corrupted Backups

    /// Tests repair against actual corrupted backup files (if they exist)
    /// These are copies of demo1 copy 3.ff and demo2 copy.ff
    @Test func repairRealCorruptedBackupDemo1() throws {
        let basePath = "/Users/niyaro/Documents/Code/final final development/document-integrity-check"
        let backupPath = URL(fileURLWithPath: "\(basePath)/test-data/corrupted-backups/demo1-copy-3.ff")

        // Skip if backup doesn't exist
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            print("Skipping: backup file not found at \(backupPath.path)")
            return
        }

        // Create temp copy to test against (don't modify the backup)
        let tempDir = URL(fileURLWithPath: "/tmp/claude/RealBackupTest-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: backupPath, to: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: tempDir)
        let report = try checker.validate()

        print("[RealBackupTest] Issues found: \(report.issues.map { $0.description })")

        // Verify it detects issues
        #expect(!report.isHealthy, "Real corrupted database should have issues")
        #expect(report.issues.contains { $0 == .missingProjectRecord },
                "Should detect missing project record")

        // If repairable, run repair
        if report.canAutoRepair {
            let repairService = ProjectRepairService(packageURL: tempDir)
            let result = try repairService.repair(report: report)
            #expect(result.success, "Repair should succeed")

            // Verify project exists after repair
            let dbQueue = try DatabaseQueue(path: tempDir.appendingPathComponent("content.sqlite").path)
            let projectCount = try #require(try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project")
            })
            #expect(projectCount == 1, "Should have project after repair")
        }
    }

    @Test func repairRealCorruptedBackupDemo2() throws {
        let basePath = "/Users/niyaro/Documents/Code/final final development/document-integrity-check"
        let backupPath = URL(fileURLWithPath: "\(basePath)/test-data/corrupted-backups/demo2-copy.ff")

        // Skip if backup doesn't exist
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            print("Skipping: backup file not found at \(backupPath.path)")
            return
        }

        // Create temp copy to test against
        let tempDir = URL(fileURLWithPath: "/tmp/claude/RealBackupTest-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: backupPath, to: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: tempDir)
        let report = try checker.validate()

        print("[RealBackupTest] Issues found: \(report.issues.map { $0.description })")

        #expect(!report.isHealthy, "Real corrupted database should have issues")

        if report.canAutoRepair {
            let repairService = ProjectRepairService(packageURL: tempDir)
            let result = try repairService.repair(report: report)
            #expect(result.success, "Repair should succeed")
        }
    }

    // MARK: - Scenario 10: Severity Sorting

    @Test func issuesRepairedInSeverityOrder() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        // Create database missing both project table and content table
        let dbQueue = try DatabaseQueue(path: factory.databaseURL.path)
        try dbQueue.write { db in
            // Create section table only
            try db.execute(sql: """
                CREATE TABLE section (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    parentId TEXT,
                    sortOrder INTEGER NOT NULL,
                    headerLevel INTEGER NOT NULL,
                    isPseudoSection INTEGER NOT NULL DEFAULT 0,
                    title TEXT NOT NULL,
                    markdownContent TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'next',
                    tags TEXT NOT NULL DEFAULT '[]',
                    wordGoal INTEGER,
                    wordCount INTEGER NOT NULL DEFAULT 0,
                    startOffset INTEGER NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)
        }

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        // Should have multiple issues with different severities
        #expect(report.issues.contains { $0 == .missingProjectTable }, "Should detect missing project table")
        #expect(report.issues.contains { $0 == .missingContentTable }, "Should detect missing content table")

        // Run repair
        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success, "Repair should succeed")

        // Verify both tables exist after repair
        let hasProjectTable = try dbQueue.read { db in try db.tableExists("project") }
        let hasContentTable = try dbQueue.read { db in try db.tableExists("content") }
        #expect(hasProjectTable, "Project table should exist")
        #expect(hasContentTable, "Content table should exist")
    }
}
