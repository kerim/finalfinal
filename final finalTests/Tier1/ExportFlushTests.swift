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
}
