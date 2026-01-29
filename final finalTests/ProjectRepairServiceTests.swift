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
