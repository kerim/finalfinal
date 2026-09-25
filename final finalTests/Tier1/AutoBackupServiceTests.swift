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

    private func configureService(db: ProjectDatabase) throws -> (AutoBackupService, String) {
        let pid = try TestFixtureFactory.getProjectId(from: db)
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
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        #expect(!service.hasUnsavedChanges)
        service.contentDidChange()
        #expect(service.hasUnsavedChanges)
    }

    @Test("contentDidSave resets unsaved flag")
    func contentDidSaveResetsUnsavedFlag() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        service.contentDidChange()
        #expect(service.hasUnsavedChanges)

        service.contentDidSave()
        #expect(!service.hasUnsavedChanges)
    }

    // MARK: - Lifecycle Backups

    @Test("projectWillClose creates backup when changes exist")
    func projectWillCloseCreatesBackup() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)

        let countBefore = try snapshotCount(db: db, projectId: pid)
        service.contentDidChange()
        await service.projectWillClose()

        let countAfter = try snapshotCount(db: db, projectId: pid)
        #expect(countAfter > countBefore, "projectWillClose should create a snapshot")
    }

    @Test("projectWillClose skips when no changes")
    func projectWillCloseSkipsWhenNoChanges() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)

        let countBefore = try snapshotCount(db: db, projectId: pid)
        // No contentDidChange() call
        await service.projectWillClose()

        let countAfter = try snapshotCount(db: db, projectId: pid)
        #expect(countAfter == countBefore, "projectWillClose should not create snapshot without changes")
    }

    @Test("appWillQuit creates backup when changes exist")
    func appWillQuitCreatesBackup() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
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
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try configureService(db: db)

        service.contentDidChange()
        #expect(service.hasUnsavedChanges)

        service.reset()
        #expect(!service.hasUnsavedChanges)
    }

    // MARK: - §4.3 "Auto-backup skipped or failed" -> persistent warning toast

    @Test("An unconfigured service does not show the backup-failed warning toast")
    func unconfiguredServiceDoesNotShowBackupFailedToast() async throws {
        let service = AutoBackupService()
        let isolatedToastCenter = ToastCenter()
        service.toastCenter = isolatedToastCenter

        // Never configured -- snapshotService is nil, the "no snapshot service configured"
        // early-return path. This is a STATE condition (no project open), not a write failure,
        // so it must not raise the persistent failure warning -- only a genuine write error
        // (the `catch` block below, exercised by realWriteFailureShowsBackupFailedToast) does.
        await service.createAutoBackup(reason: "test")

        #expect(isolatedToastCenter.current == nil)
    }

    @Test("A successful auto-backup clears a previously shown backup-failed toast")
    func successfulBackupClearsPreviousToast() async throws {
        let db1 = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid1) = try configureService(db: db1)
        let isolatedToastCenter = ToastCenter()
        service.toastCenter = isolatedToastCenter
        defer { service.reset() }

        // Show the failure toast first via a genuine write failure (mirrors
        // realWriteFailureShowsBackupFailedToast below) -- the "unconfigured" guard no longer
        // raises this warning (fix: it's a state condition, not a failure), so the precondition
        // has to come from a real error instead.
        service.contentDidChange()
        try await db1.dbWriter.write { database in
            try database.execute(sql: "DELETE FROM content WHERE projectId = ?", arguments: [pid1])
        }
        await service.createAutoBackup(reason: "test")
        #expect(isolatedToastCenter.current != nil, "precondition: the failure toast must be showing before the success case can prove it clears")

        // Now point the service at a fresh, healthy project and succeed.
        let db2 = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid2 = try TestFixtureFactory.getProjectId(from: db2)
        service.configure(database: db2, projectId: pid2)
        service.contentDidChange()

        await service.createAutoBackup(reason: "test")

        #expect(isolatedToastCenter.current == nil, "a successful backup should clear its own prior failure warning")
    }

    @Test("reset() clears a previously shown backup-failed toast")
    func resetClearsBackupFailedToast() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)
        let isolatedToastCenter = ToastCenter()
        service.toastCenter = isolatedToastCenter

        // Show the failure toast via a genuine write failure -- the "unconfigured" guard no
        // longer raises this warning (state, not failure), so this needs a real error too.
        service.contentDidChange()
        try await db.dbWriter.write { database in
            try database.execute(sql: "DELETE FROM content WHERE projectId = ?", arguments: [pid])
        }
        await service.createAutoBackup(reason: "test")
        #expect(isolatedToastCenter.current != nil, "precondition: the failure toast must be showing before reset() can prove it clears")

        // Closing/switching a project retracts its own warning -- an "Open Diagnostics" button
        // pointing at a no-longer-open project would be confusing. `reset()` also cancels the
        // idle timer started by `contentDidChange()` above, so no `defer` is needed here.
        service.reset()

        #expect(isolatedToastCenter.current == nil)
    }

    /// A real (not mocked) throw from `SnapshotService.createAutoSnapshot()`, exercising
    /// `createAutoBackup`'s `catch` block end to end -- this is the path the plan's manual
    /// verification step (a read-only `.ff` package) exercises in the real app.
    ///
    /// NOT via filesystem permissions: `ProjectDatabase` uses a GRDB `DatabasePool`, whose
    /// writer connection is opened once, up front, and kept open for the database's lifetime.
    /// POSIX permission checks happen at `open()`, not at each `write()` -- chmod'ing the
    /// package read-only AFTER that connection is already open does not reliably (or at all,
    /// e.g. running as root) make a subsequent write through it fail, so that approach was
    /// dropped as unreliable rather than shipped as a flaky test (plan's own instruction).
    /// Instead, this drives a genuine, deterministic throw already reachable in production:
    /// `Database+CRUD.swift`'s `saveContent(markdown:for:)` only UPDATES an existing `content`
    /// row and silently no-ops if none exists (`if var content = ... fetchOne(db)`), so deleting
    /// that row first makes the immediately-following `fetchContent(for:)` inside
    /// `createAutoSnapshot()` come back nil, hitting its real `throw SnapshotError.noContent`.
    @Test("A real write failure from createAutoSnapshot() shows the persistent backup-failed toast")
    func realWriteFailureShowsBackupFailedToast() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try configureService(db: db)
        let isolatedToastCenter = ToastCenter()
        service.toastCenter = isolatedToastCenter
        defer { service.reset() }

        service.contentDidChange()
        try await db.dbWriter.write { database in
            try database.execute(sql: "DELETE FROM content WHERE projectId = ?", arguments: [pid])
        }

        await service.createAutoBackup(reason: "test")

        #expect(isolatedToastCenter.current?.style == .warning)
        #expect(isolatedToastCenter.current?.action?.title == "Open Diagnostics")
    }
}
