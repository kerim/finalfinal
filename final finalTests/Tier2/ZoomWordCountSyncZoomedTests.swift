//
//  ZoomWordCountSyncZoomedTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — DIAGNOSTIC for "word count not updating while zoomed".
//
//  Split out of ZoomWordCountSyncTests.swift to stay under SwiftLint's
//  type_body_length / file_length caps. The suite lives across two files —
//  ZoomWordCountSyncTests.swift (shared infrastructure, control, selection,
//  and forced-flush/reentrancy tests) and this one (the zoomed-scenario
//  tests) — same suite, same test names/counts.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
@testable import final_final

extension ZoomWordCountSyncTests {

    // MARK: - Zoomed: new block created while zoomed (regression for frozen word count)

    /// Reproduces the root cause of "word count not updating while zoomed":
    /// blocks created during zoom got no temp ID (blanket zoom-mode suppression),
    /// were invisible to block-sync, and never reached the DB until zoom-out.
    /// With the fix (suppression scoped to the mini-Notes tail), a paragraph
    /// split while zoomed must produce a DB insert on the next poll.
    @MainActor
    func testZoomed_newBlockWhileZoomed_reachesDatabase() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 300_000_000)

        let blockCountBefore = try db.fetchBlockCount(projectId: pid)

        // Select "six" (places a real selection inside the paragraph), then press
        // Enter via synthetic keydown — ProseMirror's keymap handles it and splits
        // the paragraph, creating a NEW block while zoomed.
        _ = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                window.FinalFinal.find('six');
                const pm = document.querySelector('.ProseMirror');
                pm.focus();
                return pm.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                    bubbles: true, cancelable: true
                }));
            })()
            """
        )
        try await Task.sleep(nanoseconds: 600_000_000)

        let hasChanges = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        await sync.pollBlockChangesNow()

        let blockCountAfter = try db.fetchBlockCount(projectId: pid)
        XCTAssertGreaterThan(
            blockCountAfter, blockCountBefore,
            """
            ZOOMED: paragraph split while zoomed did not reach the DB \
            (blocks before=\(blockCountBefore), after=\(blockCountAfter), \
            hasBlockChanges=\(String(describing: hasChanges))). \
            New blocks created during zoom must get temp IDs and sync live.
            """
        )
    }

    // MARK: - Zoomed: mini-Notes tail must NOT sync (the reason zoom mode exists)

    /// The temp-ID fix must not regress the original protection: the appended
    /// mini-Notes tail (zoom_notes_marker + # Notes + footnote definitions) is
    /// presentation-only and must never be inserted into the DB by block-sync.
    @MainActor
    func testZoomed_miniNotesTail_staysOutOfDatabase() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        // Mirror zoomToSection's mini-Notes append (EditorViewState+Zoom.swift)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)
            + "\n\n<!-- ::zoom-notes:: -->\n# Notes\n\n[^note1]: A footnote definition that must not sync.\n"

        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 500_000_000)

        let blockCountBefore = try db.fetchBlockCount(projectId: pid)

        // Two poll cycles: any temp IDs wrongly assigned to the mini-Notes tail
        // would surface as inserts here.
        await sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        await sync.pollBlockChangesNow()

        let blockCountAfter = try db.fetchBlockCount(projectId: pid)
        XCTAssertEqual(
            blockCountAfter, blockCountBefore,
            "Mini-Notes tail must never be inserted into the DB by block-sync"
        )
        let leaked = try TestFixtureFactory.fetchBlocks(from: db).filter {
            $0.textContent.contains("must not sync") || ($0.blockType == .heading && $0.textContent == "Notes")
        }
        XCTAssertTrue(leaked.isEmpty, "Mini-Notes content leaked into DB: \(leaked.map { $0.textContent })")
    }

    // MARK: - Zoomed

    @MainActor
    func testZoomed_editInsideZoomedSection_updatesStoredWordCount() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        guard let betaHeading = blocks.first(where: {
            $0.blockType == .heading && $0.textContent.contains("Beta")
        }) else {
            XCTFail("Fixture must contain a Beta heading"); return
        }

        // Replicate EditorViewState.zoomToSection's content assembly:
        // every block from the Beta heading to the end (Beta is the last section).
        let zoomedBlocks = blocks.filter {
            $0.sortOrder >= betaHeading.sortOrder && !$0.isBibliography && !$0.isNotes
        }
        let zoomedIds = BlockParser.idsForProseMirrorAlignment(zoomedBlocks)
        let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

        // Replicate ContentView.onZoomToSection: push zoomed content + IDs, then
        // pushBlockIds(for: range) which enables JS zoom mode.
        await sync.setContentWithBlockIds(markdown: zoomedContent, blockIds: zoomedIds)
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.pushBlockIds(for: (start: betaHeading.sortOrder, end: nil))
        try await Task.sleep(nanoseconds: 300_000_000)

        let before = try totalWordCount(db, pid)
        try await editBetaParagraph(helper.webView)

        // Diagnostic visibility: what does the JS side think it has pending?
        let hasChanges = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        DebugLog.always("[ZoomWordCountSyncTests] zoomed hasBlockChanges=\(String(describing: hasChanges))")

        await sync.pollBlockChangesNow()

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            """
            ZOOMED: edit inside the zoomed section did not reach the DB \
            (before=\(before), after=\(after), hasBlockChanges=\(String(describing: hasChanges))). \
            This reproduces the frozen-word-count-while-zoomed bug.
            """
        )
    }

    // MARK: - Zoomed: heading deleted while zoomed (SectionSyncService.syncZoomedSections deletion path)

    /// Exercises `syncZoomedSections`'s deletion branch directly (via `contentChanged`, the
    /// same entry point `ViewNotificationModifiers` calls) rather than through the block-sync/
    /// WKWebView chain the other tests in this file use. Section-level sync while zoomed is
    /// data-integrity-adjacent — deleting a section's heading while zoomed must remove exactly
    /// that section from the sections table, leave sections outside the zoomed set untouched,
    /// and report the removal via `onZoomedSectionsUpdated`.
    @MainActor
    func testZoomed_headingDeletedWhileZoomed_removesFromDatabase() async throws {
        let fullMarkdown = """
        # Alpha

        Alpha text.

        # Beta

        Beta text.

        # Gamma

        Gamma text.
        """
        let db = try TestFixtureFactory.createTemporary(content: fullMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: pid)

        // Populate the sections table from the full document, as the initial sync would.
        await syncService.syncNow(fullMarkdown)

        let sectionsBefore = try db.fetchSections(projectId: pid)
        XCTAssertEqual(sectionsBefore.map(\.title), ["Alpha", "Beta", "Gamma"])
        guard let alpha = sectionsBefore.first(where: { $0.title == "Alpha" }),
              let beta = sectionsBefore.first(where: { $0.title == "Beta" }),
              let gamma = sectionsBefore.first(where: { $0.title == "Gamma" }) else {
            XCTFail("Expected Alpha, Beta, and Gamma sections after initial sync")
            return
        }

        // Zoom into Beta + Gamma, then delete Gamma's heading from the zoomed content —
        // mirrors what ContentView's zoomed editor sends via contentChanged(_:zoomedIds:).
        let zoomedIds: Set<String> = [beta.id, gamma.id]
        let editedZoomedMarkdown = """
        # Beta

        Beta text.
        """

        var receivedIds: Set<String>?
        syncService.onZoomedSectionsUpdated = { ids in receivedIds = ids }

        syncService.contentChanged(editedZoomedMarkdown, zoomedIds: zoomedIds)
        // contentChanged debounces for 500ms before syncing; leave generous headroom.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let sectionsAfter = try db.fetchSections(projectId: pid)
        XCTAssertEqual(
            sectionsAfter.count, 2,
            "Deleting Gamma's heading while zoomed must remove exactly one section, got \(sectionsAfter.map(\.title))"
        )
        XCTAssertFalse(
            sectionsAfter.contains { $0.id == gamma.id },
            "Gamma must be removed from the database after its heading was deleted while zoomed"
        )
        XCTAssertTrue(
            sectionsAfter.contains { $0.id == alpha.id },
            "Alpha (outside the zoomed set) must be untouched by the zoomed deletion"
        )
        XCTAssertTrue(
            sectionsAfter.contains { $0.id == beta.id },
            "Beta must remain — only Gamma's heading was deleted"
        )
        XCTAssertEqual(
            receivedIds, [beta.id],
            "onZoomedSectionsUpdated must report the deleted section removed from the zoomed set"
        )
    }
}
