//
//  SnapshotBackupFlushTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression test for snapshot/backup creation reading stale blocks: the same
//  staleness bug fixed for export (see ExportFlushTests.swift) also applied to
//  SnapshotService.createManualSnapshot/createAutoSnapshot and
//  AutoBackupService's idle-timeout auto-backup path -- none of them flushed
//  fresh WebView content into the block table before reading it.
//  block-sync-plugin.ts's incremental detectChanges() silently drops a pure
//  block move (same id, same content, different position) when the
//  ProseMirror node reference is unchanged, so without an explicit flush a
//  version saved or an idle-timeout backup taken right after a drag would show
//  the moved block in its stale, pre-move position.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite(.serialized)
struct SnapshotBackupFlushTests {

    // MARK: - Helpers

    /// Create a temp directory for test fixtures
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/SnapshotBackupFlushTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clean up temp directory
    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Markdown before the simulated in-editor drag: heading, paragraph, image, paragraph.
    private let preMoveMarkdown = "# Title\n\nPara A.\n\n![alt](media/img.png)\n\nPara B."

    /// Markdown after the drag: image now follows "Para B." instead of preceding it.
    private let postMoveMarkdown = "# Title\n\nPara A.\n\nPara B.\n\n![alt](media/img.png)"

    /// Seed a fixture with the pre-move markdown (so the DB is deliberately left stale,
    /// exactly like the confirmed bug: block-sync's incremental diff drops a pure block
    /// move), then construct an `EditorViewState` wired to the same DB/project whose
    /// `content` still holds that stale pre-move markdown, matching what's still in the DB.
    @MainActor
    private func makeStaleMoveFixture(in dir: URL, name: String) throws -> (db: ProjectDatabase, projectId: String, editorState: EditorViewState) {
        let fixtureURL = dir.appendingPathComponent("\(name).ff")
        let db = try TestFixtureFactory.createFixture(at: fixtureURL, title: name, content: preMoveMarkdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let editorState = EditorViewState()
        editorState.projectDatabase = db
        editorState.currentProjectId = projectId
        editorState.content = preMoveMarkdown

        return (db, projectId, editorState)
    }

    /// Assert that markdown shows the image after "Para B." (the post-move position),
    /// not before it (the stale pre-move position) -- matches ExportFlushTests' pattern
    /// of asserting via `range(of:)` ordering.
    private func expectPostMoveOrder(_ markdown: String) throws {
        let paraBRange = try #require(markdown.range(of: "Para B."))
        let imageRange = try #require(markdown.range(of: "media/img.png"))
        #expect(
            paraBRange.lowerBound < imageRange.lowerBound,
            "Expected the image after 'Para B.' (its new position post-move), not before it, as the stale, unflushed DB order would show"
        )
    }

    /// Assert the inverse: markdown still shows the stale pre-move order (image before
    /// "Para B."), documenting that a path intentionally relies on its caller having
    /// already flushed live content.
    private func expectStalePreMoveOrder(_ markdown: String) throws {
        let paraBRange = try #require(markdown.range(of: "Para B."))
        let imageRange = try #require(markdown.range(of: "media/img.png"))
        #expect(
            imageRange.lowerBound < paraBRange.lowerBound,
            "Expected the stale pre-move DB order (image before 'Para B.') since no flush occurred"
        )
    }

    // MARK: - Tests

    @Test("createManualSnapshot reflects an in-editor block move the incremental diff never recorded")
    @MainActor
    func createManualSnapshotReflectsBlockMoveNotRecordedByIncrementalDiff() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let (db, projectId, editorState) = try makeStaleMoveFixture(in: dir, name: "ManualSnapshotMove")

        // Drives the SAME production method handleSaveVersion() now calls before creating
        // a snapshot -- EditorViewState+Zoom.swift's
        // flushLiveContentToDatabase(currentContent:) -- with a stubbed content provider
        // standing in for a live WebView fetch that already caught the drag.
        await editorState.flushLiveContentToDatabase { postMoveMarkdown }

        let snapshot = try SnapshotService(database: db, projectId: projectId).createManualSnapshot(name: "Test Version")

        try expectPostMoveOrder(snapshot.previewMarkdown)
    }

    @Test("createAutoSnapshot reflects an in-editor block move the incremental diff never recorded")
    @MainActor
    func createAutoSnapshotReflectsBlockMoveNotRecordedByIncrementalDiff() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let (db, projectId, editorState) = try makeStaleMoveFixture(in: dir, name: "AutoSnapshotMove")

        await editorState.flushLiveContentToDatabase { postMoveMarkdown }

        let snapshot = try #require(try SnapshotService(database: db, projectId: projectId).createAutoSnapshot())

        try expectPostMoveOrder(snapshot.previewMarkdown)
    }

    @Test("Idle-timeout auto-backup flushes live content before snapshotting")
    @MainActor
    func autoBackupIdleTimeoutFlushesLiveContentBeforeSnapshotting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let (db, projectId, editorState) = try makeStaleMoveFixture(in: dir, name: "IdleBackupMove")

        // Stand-in for a settled live WebView edit: editorState.content holds the
        // post-move markdown. blockSyncService is left unconfigured, so
        // fetchContentFromWebView() gracefully returns nil without a real WebView, and
        // flushLiveContentToDatabase falls back to using editorState.content -- exactly
        // what's under test.
        editorState.content = postMoveMarkdown

        let backupService = AutoBackupService()
        backupService.configure(database: db, projectId: projectId)
        backupService.editorState = editorState
        backupService.contentDidChange()

        // Drives createBackupIfNeeded directly (no real 60s idle sleep), exactly as
        // restartIdleTimer()'s idle-timeout path now calls it.
        await backupService.createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: true)

        let snapshot = try #require(try SnapshotService(database: db, projectId: projectId).fetchMostRecentAutoSnapshot())

        try expectPostMoveOrder(snapshot.previewMarkdown)
    }

    @Test("Idle-timeout auto-backup without needsLiveFlush relies on its caller having already flushed")
    @MainActor
    func autoBackupIdleTimeoutWithoutLiveFlushKeepsStaleDatabaseOrder() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let (db, projectId, editorState) = try makeStaleMoveFixture(in: dir, name: "IdleBackupNoFlushMove")

        // Same post-move editor content as the positive case above, but this time the
        // caller passes needsLiveFlush: false, so it's never read.
        editorState.content = postMoveMarkdown

        let backupService = AutoBackupService()
        backupService.configure(database: db, projectId: projectId)
        backupService.editorState = editorState
        backupService.contentDidChange()

        await backupService.createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: false)

        let snapshot = try #require(try SnapshotService(database: db, projectId: projectId).fetchMostRecentAutoSnapshot())

        try expectStalePreMoveOrder(snapshot.previewMarkdown)
    }
}
