//
//  ProjectRepairServiceTests.swift
//  final finalTests
//
//  Tests for ProjectRepairService to verify repair behavior
//  with various corruption scenarios.
//

import Testing
import Foundation
import GRDB
@testable import final_final

// MARK: - Test Helper

/// Factory for creating corrupted database scenarios
struct CorruptedDatabaseFactory {
    let tempDir: URL

    init() throws {
        // Use /tmp/claude/ for sandbox compatibility
        tempDir = URL(fileURLWithPath: "/tmp/claude/RepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    var databaseURL: URL {
        tempDir.appendingPathComponent("content.sqlite")
    }

    /// Create a complete healthy database with sample data
    func createHealthyDatabase(projectId: String, withSections: Bool) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: databaseURL.path)

        try dbQueue.write { db in
            // Create project table
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            // Create content table
            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    FOREIGN KEY (projectId) REFERENCES project(id) ON DELETE CASCADE
                )
            """)

            // Create section table
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
                    updatedAt DATETIME NOT NULL,
                    FOREIGN KEY (projectId) REFERENCES project(id) ON DELETE CASCADE
                )
            """)

            // Insert project record
            let now = Date()
            try db.execute(
                sql: "INSERT INTO project (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [projectId, "Test Project", now, now]
            )

            // Insert content record
            try db.execute(
                sql: "INSERT INTO content (id, projectId, markdown, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, projectId, "# Test\n\nContent here", now]
            )

            if withSections {
                // Insert section records
                try db.execute(
                    sql: """
                        INSERT INTO section (id, projectId, sortOrder, headerLevel, title, markdownContent, createdAt, updatedAt)
                        VALUES (?, ?, 0, 1, 'Test Section', '# Test Section\\n\\nContent', ?, ?)
                    """,
                    arguments: [UUID().uuidString, projectId, now, now]
                )
            }
        }

        return dbQueue
    }

    /// Create database with sections but NO project record (the bug scenario)
    /// CRITICAL: Uses PRAGMA foreign_keys = OFF to allow orphaned sections
    func createMissingProjectRecord(projectId: String) throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: databaseURL.path)

        try dbQueue.write { db in
            // Disable foreign keys to allow orphaned sections
            try db.execute(sql: "PRAGMA foreign_keys = OFF")

            // Create project table (empty - this is the corruption)
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            // Create content table (empty)
            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            // Create section table matching v4 schema (WITHOUT foreign key constraints)
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

            // Insert section WITH known projectId (no project record exists!)
            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO section (id, projectId, sortOrder, headerLevel, title, markdownContent, createdAt, updatedAt)
                    VALUES (?, ?, 0, 1, 'Orphaned Section', '# Orphaned\\n\\nThis section has no project', ?, ?)
                """,
                arguments: [UUID().uuidString, projectId, now, now]
            )

            // Insert content with same orphaned projectId
            try db.execute(
                sql: "INSERT INTO content (id, projectId, markdown, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, projectId, "# Orphaned Content", now]
            )
        }

        return dbQueue
    }

    /// Create database missing both project table and project record
    func createMissingProjectTable() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: databaseURL.path)

        try dbQueue.write { db in
            // Create content table only
            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            // Create section table
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

        return dbQueue
    }

    /// Create database with orphaned sections (parentId points to non-existent section)
    func createOrphanedSections(projectId: String) throws -> DatabaseQueue {
        let dbQueue = try createHealthyDatabase(projectId: projectId, withSections: false)

        try dbQueue.write { db in
            let now = Date()
            let parentId = UUID().uuidString

            // Insert parent section
            try db.execute(
                sql: """
                    INSERT INTO section (id, projectId, sortOrder, headerLevel, title, markdownContent, createdAt, updatedAt)
                    VALUES (?, ?, 0, 1, 'Parent', '# Parent', ?, ?)
                """,
                arguments: [parentId, projectId, now, now]
            )

            // Insert child section with INVALID parentId
            try db.execute(
                sql: """
                    INSERT INTO section (id, projectId, parentId, sortOrder, headerLevel, title, markdownContent, createdAt, updatedAt)
                    VALUES (?, ?, ?, 1, 2, 'Orphaned Child', '## Orphaned Child', ?, ?)
                """,
                arguments: [UUID().uuidString, projectId, "NONEXISTENT-PARENT-ID", now, now]
            )
        }

        return dbQueue
    }

    /// Clean up temporary directory
    func cleanup() throws {
        try FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Test Suite

struct ProjectRepairServiceTests {

    // MARK: - Scenario 1: Missing Project Record + Existing Sections (THE BUG)

    @Test func repairPreservesExistingProjectIdFromSections() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        let knownProjectId = "KNOWN-PROJECT-ID-12345"
        let dbQueue = try factory.createMissingProjectRecord(projectId: knownProjectId)

        // Verify setup: sections exist, project record doesn't
        let sectionCount = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM section")
        })
        #expect(sectionCount > 0, "Setup should have created sections")

        let projectCountBefore = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project")
        })
        #expect(projectCountBefore == 0, "Setup should have no project record")

        // Verify section has the known project ID
        let sectionProjectId = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT projectId FROM section LIMIT 1")
        }
        #expect(sectionProjectId == knownProjectId, "Section should have known projectId")

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()
        #expect(report.issues.contains { $0 == .missingProjectRecord }, "Should detect missing project record")

        // Run repair
        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success, "Repair should succeed")

        // CRITICAL: Verify project ID was RECOVERED, not generated
        let recoveredProjectId = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1")
        }
        #expect(recoveredProjectId == knownProjectId, "Repair should recover existing projectId from sections, not generate new one")

        // Verify sections still accessible via recovered project
        let sectionsAfterRepair = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM section WHERE projectId = ?", arguments: [knownProjectId])
        })
        #expect(sectionsAfterRepair > 0, "Sections should still be accessible after repair")
    }

    // MARK: - Scenario 2: Missing Project Record + Existing Content

    @Test func repairPreservesExistingProjectIdFromContent() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        let knownProjectId = "CONTENT-PROJECT-ID-67890"

        // Create database with content but no project record and no sections
        let dbQueue = try DatabaseQueue(path: factory.databaseURL.path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")

            // Create tables
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

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

            // Insert content with known projectId (no project record!)
            let now = Date()
            try db.execute(
                sql: "INSERT INTO content (id, projectId, markdown, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID().uuidString, knownProjectId, "# Important Content", now]
            )
        }

        // Run integrity check and repair
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()
        #expect(report.issues.contains { $0 == .missingProjectRecord })

        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success)

        // Verify project ID was recovered from content
        let recoveredProjectId = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1")
        }
        #expect(recoveredProjectId == knownProjectId, "Repair should recover projectId from content table")
    }

    // MARK: - Scenario 3: No Existing Data (New UUID Expected)

    @Test func repairCreatesNewProjectIdWhenNoExistingData() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        // Create database with empty tables
        let dbQueue = try DatabaseQueue(path: factory.databaseURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
            """)

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

        // Run integrity check and repair
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()
        #expect(report.issues.contains { $0 == .missingProjectRecord })

        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success)

        // Verify a new UUID was created (not nil)
        let newProjectId = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM project LIMIT 1")
        }
        #expect(newProjectId != nil, "Repair should create new projectId when no existing data")
        #expect(UUID(uuidString: newProjectId!) != nil, "New projectId should be valid UUID")
    }

    // MARK: - Scenario 4: Repair Order (Table Before Record)

    @Test func repairHandlesMultipleIssuesInCorrectOrder() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        // Create database missing project table entirely
        _ = try factory.createMissingProjectTable()

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        // Should detect missing table (not missing record, since table doesn't exist)
        #expect(report.issues.contains { $0 == .missingProjectTable }, "Should detect missing project table")

        // Run repair
        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success, "Repair should succeed")

        // Verify table was created
        let dbQueue = try DatabaseQueue(path: factory.databaseURL.path)
        let hasProjectTable = try dbQueue.read { db in
            try db.tableExists("project")
        }
        #expect(hasProjectTable, "Project table should exist after repair")
    }

    // MARK: - Scenario 5: Backup Created

    @Test func backupCreatedBeforeRepair() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        let projectId = "BACKUP-TEST-PROJECT"
        _ = try factory.createMissingProjectRecord(projectId: projectId)

        // Run integrity check and repair
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)

        // Verify backup was created
        #expect(result.backupURL != nil, "Backup URL should be returned")
        #expect(FileManager.default.fileExists(atPath: result.backupURL!.path), "Backup file should exist")
    }

    // MARK: - Scenario 6: Orphaned Sections Cleanup

    @Test func orphanedSectionsDeleted() throws {
        let factory = try CorruptedDatabaseFactory()
        defer { try? factory.cleanup() }

        let projectId = "ORPHAN-TEST-PROJECT"
        let dbQueue = try factory.createOrphanedSections(projectId: projectId)

        // Verify orphaned section exists
        let orphanCountBefore = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM section
                WHERE projectId = ?
                AND parentId IS NOT NULL
                AND parentId NOT IN (SELECT id FROM section WHERE projectId = ?)
            """, arguments: [projectId, projectId])
        })
        #expect(orphanCountBefore > 0, "Should have orphaned sections before repair")

        // Run integrity check
        let checker = ProjectIntegrityChecker(packageURL: factory.tempDir)
        let report = try checker.validate()

        // Should detect orphaned sections
        let hasOrphanedSections = report.issues.contains { issue in
            if case .orphanedSections = issue { return true }
            return false
        }
        #expect(hasOrphanedSections, "Should detect orphaned sections")

        // Run repair
        let repairService = ProjectRepairService(packageURL: factory.tempDir)
        let result = try repairService.repair(report: report)
        #expect(result.success)

        // Verify orphaned sections were deleted
        let orphanCountAfter = try #require(try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM section
                WHERE projectId = ?
                AND parentId IS NOT NULL
                AND parentId NOT IN (SELECT id FROM section WHERE projectId = ?)
            """, arguments: [projectId, projectId])
        })
        #expect(orphanCountAfter == 0, "Orphaned sections should be deleted after repair")
    }

}
