//
//  AutoBackupServiceTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for auto-backup lifecycle: change tracking, backup on close/quit,
//  and state reset. Failed backups silently lose the user's work.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Auto Backup Service — Tier 1: Silent Killers")
@MainActor
struct AutoBackupServiceTests {

    // MARK: - Helpers

    private func createTestDatabase(content: String) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/autobackup-test-\(UUID().uuidString).ff")
        return try TestFixtureFactory.createFixture(at: url, content: content)
    }

    private func getProjectId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }
    }

    private func configureService(db: ProjectDatabase) throws -> (AutoBackupService, String) {
        let pid = try getProjectId(db)
        let service = AutoBackupService()
        service.configure(database: db, projectId: pid)
        return (service, pid)
    }

    private func snapshotCount(db: ProjectDatabase, projectId: String) throws -> Int {
        try db.dbWriter.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM snapshot WHERE projectId = ?",
                arguments: [projectId]
            ) ?? 0
        }
    }

    // MARK: - Change Tracking

    @Test("contentDidChange sets unsaved flag")
    func contentDidChangeSetsUnsavedFlag() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        #expect(!service.hasUnsavedChanges)
        service.contentDidChange()
        #expect(service.hasUnsavedChanges)
    }

    @Test("contentDidSave resets unsaved flag")
    func contentDidSaveResetsUnsavedFlag() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        service.contentDidChange()
        #expect(service.hasUnsavedChanges)

        service.contentDidSave()
        #expect(!service.hasUnsavedChanges)
    }

    // MARK: - Lifecycle Backups

    @Test("projectWillClose creates backup when changes exist")
    func projectWillCloseCreatesBackup() async throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)

        let countBefore = try snapshotCount(db: db, projectId: pid)
        service.contentDidChange()
        await service.projectWillClose()

        let countAfter = try snapshotCount(db: db, projectId: pid)
        #expect(countAfter > countBefore, "projectWillClose should create a snapshot")
    }

    @Test("projectWillClose skips when no changes")
    func projectWillCloseSkipsWhenNoChanges() async throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)

        let countBefore = try snapshotCount(db: db, projectId: pid)
        // No contentDidChange() call
        await service.projectWillClose()

        let countAfter = try snapshotCount(db: db, projectId: pid)
        #expect(countAfter == countBefore, "projectWillClose should not create snapshot without changes")
    }

    @Test("appWillQuit creates backup when changes exist")
    func appWillQuitCreatesBackup() async throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)

        let countBefore = try snapshotCount(db: db, projectId: pid)
        service.contentDidChange()
        await service.appWillQuit()

        let countAfter = try snapshotCount(db: db, projectId: pid)
        #expect(countAfter > countBefore, "appWillQuit should create a snapshot")
    }

    // MARK: - Reset

    @Test("reset clears all state")
    func resetClearsAllState() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        service.contentDidChange()
        #expect(service.hasUnsavedChanges)

        service.reset()
        #expect(!service.hasUnsavedChanges)
    }
}
