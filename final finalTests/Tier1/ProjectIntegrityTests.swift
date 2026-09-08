//
//  ProjectIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for project integrity detection: healthy DB, missing DB, missing project
//  record, orphaned sections, and severity classification.
//  Undetected DB damage silently corrupts the user's project.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Project Integrity — Tier 1: Silent Killers")
struct ProjectIntegrityTests {

    // MARK: - Helpers

    /// Creates a .ff package directory with a valid database inside
    private func createHealthyPackage() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/claude/integrity-test-\(UUID().uuidString).ff")
        try TestFixtureFactory.createFixture(at: url)
        return url
    }

    /// Creates a .ff package directory without a database file
    private func createEmptyPackage() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/claude/integrity-empty-\(UUID().uuidString).ff")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a .ff package with a database that has no project record
    private func createPackageWithoutProjectRecord() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/claude/integrity-noproj-\(UUID().uuidString).ff")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let dbPath = url.appendingPathComponent("content.sqlite").path
        let dbQueue = try DatabaseQueue(path: dbPath)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE project (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE content (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    markdown TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE section (
                    id TEXT PRIMARY KEY,
                    projectId TEXT NOT NULL,
                    parentId TEXT,
                    sortOrder INTEGER NOT NULL,
                    headerLevel INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    markdownContent TEXT NOT NULL,
                    status TEXT,
                    tags TEXT DEFAULT '[]',
                    wordGoal INTEGER,
                    wordCount INTEGER DEFAULT 0
                )
            """)
            // No rows inserted — project table exists but is empty
        }
        return url
    }

    /// Creates a .ff package with orphaned sections
    private func createPackageWithOrphanedSections() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/claude/integrity-orphan-\(UUID().uuidString).ff")
        // Start with a healthy fixture
        let db = try TestFixtureFactory.createFixture(at: url)

        // Get the project ID
        let projectId = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }

        // Insert a section with orphaned parentId directly via DatabaseQueue
        // (bypasses GRDB's FK enforcement on ProjectDatabase)
        let dbPath = url.appendingPathComponent("content.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = false
        let rawDb = try DatabaseQueue(path: dbPath, configuration: config)
        try rawDb.write { database in
            let now = ISO8601DateFormatter().string(from: Date())
            try database.execute(
                sql: """
                    INSERT INTO section (id, projectId, parentId, sortOrder, headerLevel, title,
                        markdownContent, status, tags, wordCount, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, '[]', 0, ?, ?)
                """,
                arguments: [UUID().uuidString, projectId, "nonexistent-parent-id", 99, 2, "Orphaned Section", "Content", "next", now, now]
            )
        }
        return url
    }

    // MARK: - Tests

    @Test("Healthy database reports no issues")
    func healthyDatabaseReportsNoIssues() throws {
        let url = try createHealthyPackage()
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()
        #expect(report.isHealthy, "Valid fixture should report no issues")
    }

    @Test("Missing database detected with critical severity")
    func missingDatabaseDetected() throws {
        let url = try createEmptyPackage()
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()
        #expect(!report.isHealthy)
        #expect(report.issues.contains(.missingDatabase),
                "Should detect missing database")
        #expect(report.issues.first { $0 == .missingDatabase }?.severity == .critical,
                "Missing database should be critical")
    }

    @Test("Missing project record detected")
    func missingProjectRecordDetected() throws {
        let url = try createPackageWithoutProjectRecord()
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()
        #expect(!report.isHealthy)
        #expect(report.issues.contains(.missingProjectRecord),
                "Should detect missing project record")
    }

    @Test("Orphaned sections detected")
    func orphanedSectionsDetected() throws {
        let url = try createPackageWithOrphanedSections()
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()
        let orphanIssue = report.issues.first {
            if case .orphanedSections = $0 { return true }
            return false
        }
        #expect(orphanIssue != nil, "Should detect orphaned sections")
    }

    @Test("Report severity classification partitions correctly")
    func reportSeverityClassification() throws {
        // Create a report with known issues at different severities
        let issues: [IntegrityIssue] = [
            .missingDatabase,                    // critical
            .missingContentRecord,               // error
            .orphanedSections(count: 3)          // warning
        ]
        let report = IntegrityReport(
            issues: issues,
            packageURL: URL(fileURLWithPath: "/tmp/claude/test.ff")
        )

        #expect(report.criticalIssues.count == 1)
        #expect(report.errorIssues.count == 1)
        #expect(report.warningIssues.count == 1)
        #expect(report.hasCriticalIssues)
        #expect(report.hasErrors)
        #expect(!report.isHealthy)
    }

    // MARK: - ProjectOpenErrorState funnel (project-open-error-alert plan)
    //
    // These exercise ProjectOpenErrorState.report()/clear() in isolation -- pure
    // state mutation, no DocumentManager.shared involvement. IntegrityResolution.repair/
    // openAnyway are deliberately NOT covered here: both call through to
    // DocumentManager.shared.openProject/forceOpenProject, which would mount a real
    // project in the shared singleton and leak into sibling tests with no teardown
    // path available from this suite. Presentation (does the sheet actually appear
    // and show the right content) is covered by the e2e UI test instead, which is
    // the only place that can prove that without fighting the singleton.

    @Test("report() routes IntegrityError.corrupted to .integrity, preserving issues and URL")
    @MainActor
    func reportRoutesIntegrityError() throws {
        let state = ProjectOpenErrorState.shared
        defer { state.clear() }
        let url = URL(fileURLWithPath: "/tmp/claude/integrity-funnel-test.ff")
        let report = IntegrityReport(issues: [.missingDatabase], packageURL: url)

        state.report(IntegrityError.corrupted(report), url: url)

        guard case .integrity(let pendingReport, let pendingURL) = state.pending else {
            Issue.record("Expected .integrity, got \(String(describing: state.pending))")
            return
        }
        #expect(pendingReport.issues == report.issues)
        #expect(pendingURL == url)
    }

    @Test("report() routes a non-integrity error to .other, carrying localizedDescription")
    @MainActor
    func reportRoutesNonIntegrityError() throws {
        let state = ProjectOpenErrorState.shared
        defer { state.clear() }
        let url = URL(fileURLWithPath: "/tmp/claude/other-funnel-test.ff")
        let error = DocumentManager.DocumentError.bookmarkResolutionFailed

        state.report(error, url: url)

        guard case .other(let message, let pendingURL) = state.pending else {
            Issue.record("Expected .other, got \(String(describing: state.pending))")
            return
        }
        #expect(message == error.localizedDescription)
        #expect(pendingURL == url)
    }

    @Test("report(.other) then clear() leaves an isolated instance with pending == nil")
    @MainActor
    func reportOtherThenClear() throws {
        // Isolated instance (init() is not private -- see ProjectOpenErrorState.swift)
        // rather than .shared, so this test's assertions can't be affected by, or
        // leak into, any other test touching the app-wide singleton.
        let state = ProjectOpenErrorState()
        let url = URL(fileURLWithPath: "/tmp/claude/other-clear-test.ff")
        let error = DocumentManager.DocumentError.securityScopedAccessDenied

        state.report(error, url: url)
        guard case .other(let message, let pendingURL) = state.pending else {
            Issue.record("Expected .other, got \(String(describing: state.pending))")
            return
        }
        #expect(message == error.localizedDescription)
        #expect(pendingURL == url)

        state.clear()
        #expect(state.pending == nil)
    }

    @Test("report() routes IntegrityError.checkFailed (nil report) to .other, not .integrity")
    @MainActor
    func reportRoutesCheckFailedToOther() throws {
        let state = ProjectOpenErrorState.shared
        defer { state.clear() }
        let url = URL(fileURLWithPath: "/tmp/claude/checkfailed-funnel-test.ff")
        let underlying = DocumentManager.DocumentError.noProjectInDatabase
        let error = IntegrityError.checkFailed(underlying: underlying)

        state.report(error, url: url)

        guard case .other = state.pending else {
            Issue.record("Expected .other for checkFailed (nil integrityReport), got \(String(describing: state.pending))")
            return
        }
    }

    @Test("clear() resets pending to nil; a second report() replaces rather than stacks")
    @MainActor
    func clearResetsAndReportReplaces() throws {
        let state = ProjectOpenErrorState.shared
        defer { state.clear() }
        let urlA = URL(fileURLWithPath: "/tmp/claude/replace-a.ff")
        let urlB = URL(fileURLWithPath: "/tmp/claude/replace-b.ff")

        state.report(DocumentManager.DocumentError.noProjectOpen, url: urlA)
        #expect(state.pending != nil)

        state.clear()
        #expect(state.pending == nil)

        state.report(DocumentManager.DocumentError.noProjectOpen, url: urlA)
        state.report(DocumentManager.DocumentError.noProjectInDatabase, url: urlB)

        guard case .other(_, let pendingURL) = state.pending else {
            Issue.record("Expected .other after second report(), got \(String(describing: state.pending))")
            return
        }
        #expect(pendingURL == urlB, "Second report() should replace, not stack")
    }
}
