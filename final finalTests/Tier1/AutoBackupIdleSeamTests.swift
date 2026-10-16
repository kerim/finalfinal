//
//  AutoBackupIdleSeamTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2b; the VM test testQuickUndoAfterIdleBackup_book6): the UI-test idle seam
//  (`TestMode.uiTestingAutoBackupIdleSeconds`) fires the idle backup ONCE after a few seconds instead of 60. A test project that was
//  seeded and backed up a moment ago would make that firing a no-op ("Too soon since last backup"), so the firing passes
//  `uiTestSeamFiring: true` and bypasses the minimum interval and the "no unsaved changes" check. An ordinary idle timeout keeps both.
//    - U-Q49  (sw81)  the seam's firing flushes and snapshots right after a backup; the same call without the flag does nothing
//

import Foundation
import Testing
@testable import final_final

@Suite("Idle backup: the UI-test seam's one firing (Tier 1)", .serialized)
@MainActor
struct AutoBackupIdleSeamTests {

    private let original = "# Title\n\nPara A."

    @Test("U-Q49 (VM seam): the idle seam's one firing bypasses the minimum interval; an ordinary idle timeout does not")
    func testIdleSeamFiringBypassesTheMinimumInterval() async throws {
        let db = try TestFixtureFactory.createTemporary(content: original)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = pid
        editorState.content = original
        let backups = AutoBackupService()
        // `contentDidChange()` arms the real 60 s idle Task; reset() (which cancels it) must run before the pool goes away.
        defer { backups.reset() }
        backups.configure(database: db, projectId: pid)
        backups.editorState = editorState
        let snapshots = SnapshotService(database: db, projectId: pid)

        // A backup was made a moment ago.
        backups.contentDidChange()
        await backups.createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: false)
        let first = try #require(try snapshots.fetchMostRecentAutoSnapshot(), "precondition: the first backup exists")
        #expect(!first.previewMarkdown.contains("Para B."), "precondition: it holds the original text")

        // The editor changed since; nothing is marked unsaved. The seam's firing flushes the editor's text and snapshots it anyway.
        editorState.content = original + "\n\nPara B."
        await backups.createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: true, uiTestSeamFiring: true)
        let afterSeam = try #require(try snapshots.fetchMostRecentAutoSnapshot())
        #expect(
            afterSeam.previewMarkdown.contains("Para B."),
            "expected the idle backup to run its live flush after the seam fired (the minimum interval was not bypassed)")

        // Control: the same call without the flag, with unsaved changes, is still too soon after the backup just made.
        editorState.content = original + "\n\nPara B.\n\nPara C."
        backups.contentDidChange()
        await backups.createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: true)
        let afterOrdinary = try #require(try snapshots.fetchMostRecentAutoSnapshot())
        #expect(!afterOrdinary.previewMarkdown.contains("Para C."), "an ordinary idle timeout stays subject to the minimum interval")
    }
}
