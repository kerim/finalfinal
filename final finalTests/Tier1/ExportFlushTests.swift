//
//  ExportFlushTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression test for exports reading stale blocks: DocumentManager.exportBlocks()
//  (and loadContentForExport()) must await `flushBeforeExport` before reading from
//  the database — otherwise a footnote inserted or edited just before export can be
//  missed, showing the literal slash-trigger text and a blank definition in the
//  exported document instead of `[^1]` and its Notes-section text.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite(.serialized)
struct ExportFlushTests {

    // MARK: - Helpers

    /// Create a temp directory for test fixtures
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/ExportFlushTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Clean up temp directory
    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Tests

    @Test("loadContentForExport awaits flushBeforeExport before reading blocks")
    @MainActor
    func loadContentForExportAwaitsFlushBeforeReadingBlocks() async throws {
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            DocumentManager.shared.flushBeforeExport = nil
            DocumentManager.shared.closeProject()
        }

        // Open a fixture with no footnotes yet — matches the DB state before the
        // in-flight editor edit has been flushed.
        let fixtureURL = dir.appendingPathComponent("FlushTest.ff")
        try TestFixtureFactory.createFixture(
            at: fixtureURL,
            title: "FlushTest",
            content: "# Test Document\n\nNo footnotes yet."
        )
        let projectId = try DocumentManager.shared.openProject(at: fixtureURL)

        // Fake flush: writes a footnote reference and its Notes definition directly
        // into the DB, standing in for the real
        // `blockSyncService.pollBlockChangesNow()` hook (which pulls fresh content
        // from the live WebView). If `exportBlocks()`/`loadContentForExport()` read
        // blocks before awaiting this closure, the assertions below would fail.
        DocumentManager.shared.flushBeforeExport = {
            guard let db = DocumentManager.shared.projectDatabase else { return }
            do {
                try db.write { database in
                    var bodyBlock = Block(
                        projectId: projectId,
                        sortOrder: 100,
                        blockType: .paragraph,
                        textContent: "See the footnote[^1].",
                        markdownFragment: "See the footnote[^1]."
                    )
                    try bodyBlock.insert(database)

                    var notesHeading = Block(
                        projectId: projectId,
                        sortOrder: 200,
                        blockType: .heading,
                        textContent: "Notes",
                        markdownFragment: "# Notes",
                        headingLevel: 1,
                        isNotes: true
                    )
                    try notesHeading.insert(database)

                    var notesDefinition = Block(
                        projectId: projectId,
                        sortOrder: 201,
                        blockType: .paragraph,
                        textContent: "[^1]: real definition text",
                        markdownFragment: "[^1]: real definition text",
                        isNotes: true
                    )
                    try notesDefinition.insert(database)
                }
            } catch {
                Issue.record("Fake flush failed to write footnote blocks: \(error)")
            }
        }

        let exported = try await DocumentManager.shared.loadContentForExport()

        #expect(exported?.contains("[^1]") == true, "Export should contain the footnote reference")
        #expect(
            exported?.contains("real definition text") == true,
            "Export should contain the flushed footnote definition, not a blank Notes entry"
        )
    }

    @Test("exportBlocks awaits flushBeforeExport before fetching blocks")
    @MainActor
    func exportBlocksAwaitsFlushBeforeFetching() async throws {
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            DocumentManager.shared.flushBeforeExport = nil
            DocumentManager.shared.closeProject()
        }

        let fixtureURL = dir.appendingPathComponent("FlushTest2.ff")
        try TestFixtureFactory.createFixture(
            at: fixtureURL,
            title: "FlushTest2",
            content: "# Test Document\n\nBody text."
        )
        let projectId = try DocumentManager.shared.openProject(at: fixtureURL)

        var flushCalled = false
        DocumentManager.shared.flushBeforeExport = {
            guard let db = DocumentManager.shared.projectDatabase else { return }
            flushCalled = true
            do {
                try db.write { database in
                    var block = Block(
                        projectId: projectId,
                        sortOrder: 100,
                        blockType: .paragraph,
                        textContent: "Flushed paragraph.",
                        markdownFragment: "Flushed paragraph."
                    )
                    try block.insert(database)
                }
            } catch {
                Issue.record("Fake flush failed to write block: \(error)")
            }
        }

        let blocks = try await DocumentManager.shared.exportBlocks()

        #expect(flushCalled, "flushBeforeExport must be invoked before blocks are fetched")
        #expect(
            blocks.contains { $0.textContent == "Flushed paragraph." },
            "exportBlocks should return the block written by the flush"
        )
    }

    @Test("exportBlocks reflects an in-editor block move that the incremental diff never recorded")
    @MainActor
    func exportBlocksReflectsBlockMoveNotRecordedByIncrementalDiff() async throws {
        let dir = try makeTempDir()
        defer {
            cleanup(dir)
            DocumentManager.shared.flushBeforeExport = nil
            DocumentManager.shared.closeProject()
        }

        // Seed a fixture with 4 blocks in a known order: heading, paragraph, image, paragraph.
        let fixtureURL = dir.appendingPathComponent("BlockMoveTest.ff")
        try TestFixtureFactory.createFixture(
            at: fixtureURL,
            title: "BlockMoveTest",
            content: "# Title\n\nPara A.\n\n![alt](media/img.png)\n\nPara B."
        )
        let projectId = try DocumentManager.shared.openProject(at: fixtureURL)

        // Model the confirmed bug: block-sync-plugin.ts's detectChanges() silently
        // drops a pure move when a block's ProseMirror node reference is unchanged,
        // even though its position moved -- so the DB is deliberately left untouched
        // here. editorState.content starts as the stale pre-move markdown, matching
        // what's still in the DB.
        let editorState = EditorViewState()
        editorState.projectDatabase = DocumentManager.shared.projectDatabase
        editorState.currentProjectId = projectId
        editorState.content = "# Title\n\nPara A.\n\n![alt](media/img.png)\n\nPara B."

        // Drives the SAME production method ContentView.swift wires flushBeforeExport
        // to (EditorViewState+Zoom.swift's flushLiveContentToDatabase(currentContent:))
        // -- not a hand-rolled stand-in -- with a stubbed content provider in place of a
        // live WebView fetch, returning the post-move markdown (image now after the
        // second paragraph) that a real fetchContentFromWebView() would have returned
        // after the drag. This makes the test a genuine regression guard: if
        // flushLiveContentToDatabase were reverted to the old poll-only behavior, this
        // test would fail.
        DocumentManager.shared.flushBeforeExport = {
            await editorState.flushLiveContentToDatabase {
                "# Title\n\nPara A.\n\nPara B.\n\n![alt](media/img.png)"
            }
        }

        let blocks = try await DocumentManager.shared.exportBlocks()
        let sorted = blocks.sorted { $0.sortOrder < $1.sortOrder }

        let imageIndex = try #require(
            sorted.firstIndex { $0.blockType == .image },
            "Expected an image block in the exported blocks"
        )
        let paraBIndex = try #require(
            sorted.firstIndex { $0.textContent == "Para B." },
            "Expected a 'Para B.' paragraph block in the exported blocks"
        )
        #expect(
            imageIndex > paraBIndex,
            "Image block should sort after 'Para B.' (its new neighbor post-move), not before it, as the untouched, stale DB order would show"
        )

        let exported = try await DocumentManager.shared.loadContentForExport()
        let markdown = try #require(exported)
        let paraBRange = try #require(markdown.range(of: "Para B."))
        let imageRange = try #require(markdown.range(of: "media/img.png"))
        #expect(
            paraBRange.lowerBound < imageRange.lowerBound,
            "Exported markdown should show the image after 'Para B.', reflecting its new position"
        )
    }
}
