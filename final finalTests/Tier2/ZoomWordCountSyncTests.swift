//
//  ZoomWordCountSyncTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — DIAGNOSTIC for "word count not updating while zoomed".
//
//  Reproduces the full editor→DB sync chain with a real Milkdown WKWebView:
//    edit in editor → block-sync diff → BlockSyncService poll → applyBlockChangesFromEditor
//    → stored Block.wordCount changes.
//
//  The control test runs the chain un-zoomed (full document pushed with all block IDs).
//  The zoomed test replicates exactly what ContentView.onZoomToSection does:
//  setContentWithBlockIds(zoomed subset) followed by pushBlockIds(for: range), which
//  flips the JS editor into zoom mode (blockIdZoomMode = true).
//
//  If the control passes and the zoomed test fails, the freeze is in the editor→DB
//  hop while zoomed (not in the GRDB observation layer, which OutlineObservationTests
//  already prove works).
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//
//  Split across two files to stay under SwiftLint's type_body_length / file_length
//  caps: this file holds the shared test infrastructure plus the control, selection,
//  and forced-flush/reentrancy tests; ZoomWordCountSyncZoomedTests.swift holds the
//  zoomed-scenario tests. Same suite, same test names/counts — only which file a
//  test method lives in changed. `makeStack`, `totalWordCount`, and
//  `editBetaParagraph` are internal (not private) so the zoomed-scenario extension
//  can share them.
//

import XCTest
import WebKit
@testable import final_final

/// Collects selectionChanged script messages for assertions.
@MainActor
private final class SelectionMessageCollector: NSObject, WKScriptMessageHandler {
    private(set) var received: [String] = []
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        Task { @MainActor in
            self.received.append(text)
        }
    }
}

final class ZoomWordCountSyncTests: XCTestCase {

    /// Two sections so we can zoom into the second one.
    private static let doc = """
    # Alpha

    one two three.

    # Beta

    four five six.
    """

    // MARK: - Helpers

    /// Sum of stored block word counts — the same quantity batchWordCounts aggregates.
    /// Not private: shared with the zoomed-scenario tests in ZoomWordCountSyncZoomedTests.swift.
    func totalWordCount(_ db: ProjectDatabase, _ pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COALESCE(SUM(wordCount), 0)
                FROM block
                WHERE projectId = ?
                """, arguments: [pid]) ?? 0
        }
    }

    /// Simulate typing by replacing "six" with a longer phrase via the find/replace
    /// API — a real ProseMirror transaction, indistinguishable from an edit for the
    /// block-sync plugin (find/replace does not pause sync).
    /// Not private: shared with the zoomed-scenario tests in ZoomWordCountSyncZoomedTests.swift.
    @MainActor
    func editBetaParagraph(_ webView: WKWebView) async throws {
        let findResult = try await webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.find('six'))"
        ) as? String
        let replacedCount = try await webView.evaluateJavaScript(
            "window.FinalFinal.replaceAll('six seven eight nine')"
        ) as? Int
        DebugLog.always("[ZoomWordCountSyncTests] find=\(String(describing: findResult)) replaced=\(String(describing: replacedCount))")
        // detectChanges debounce is 100ms; leave generous headroom
        try await Task.sleep(nanoseconds: 600_000_000)
        let contentAfter = try await webView.evaluateJavaScript(
            "window.FinalFinal.getContent()"
        ) as? String ?? ""
        DebugLog.always("[ZoomWordCountSyncTests] editor content after edit: \(contentAfter.replacingOccurrences(of: "\n", with: "\\n"))")

        // Probe 1: did requestAnimationFrame ever fire? (deferredSnapshotAndUnpause depends on it)
        _ = try await webView.evaluateJavaScript(
            "window.__rafFired = false; requestAnimationFrame(() => { window.__rafFired = true; }); true"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        let rafFired = try await webView.evaluateJavaScript("window.__rafFired") as? Bool
        // Probe 2: are block IDs assigned? (cursor sits at the replace target after find())
        let blockAtCursor = try await webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.getBlockAtCursor())"
        ) as? String
        // Probe 3: a report not yet acknowledged?
        let pending = try await webView.evaluateJavaScript(SwitchFlushTestSupport.outboxNotEmptyScript) as? Bool
        DebugLog.always(
            "[ZoomWordCountSyncTests] rafFired=\(String(describing: rafFired)) "
            + "blockAtCursor=\(String(describing: blockAtCursor)) heldInOutbox=\(String(describing: pending))"
        )
    }

    /// Keeps the WebView on-screen so requestAnimationFrame fires.
    /// block-sync's deferredSnapshotAndUnpause() relies on rAF; an offscreen
    /// WKWebView never runs it and sync stays paused forever (test artifact).
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    /// Not private: shared with the zoomed-scenario tests in ZoomWordCountSyncZoomedTests.swift.
    struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
    }

    /// Not private: shared with the zoomed-scenario tests in ZoomWordCountSyncZoomedTests.swift.
    @MainActor
    func makeStack() async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.orderFront(nil)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on — without this,
        // sync stays paused forever and no edit ever registers (pure test artifact;
        // verified via __rafFired probe).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)
        return EditorStack(helper: helper, db: db, pid: pid, sync: sync)
    }

    // MARK: - Selection word count push

    /// The selection-stats plugin must push selected text via the
    /// selectionChanged message (debounced), and push '' on deselect.
    /// find() dispatches a real ProseMirror text selection over the match;
    /// replaceCurrent() with identical text collapses it again.
    @MainActor
    func testSelectionChanged_pushesSelectedTextAndClearsOnDeselect() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let sync = stack.sync
        let collector = SelectionMessageCollector()
        helper.webView.configuration.userContentController.add(collector, name: "selectionChanged")
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "selectionChanged") }

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Select the Beta paragraph's text the way a mouse drag does: set the DOM
        // selection over the text node; ProseMirror's DOM observer syncs it into
        // state.selection. (find() only places a collapsed cursor — decorations,
        // not a range selection.) Then wait out the 150ms debounce.
        let selected = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                pm.focus();
                const walker = document.createTreeWalker(pm, NodeFilter.SHOW_TEXT);
                let target = null;
                while (walker.nextNode()) {
                    if (walker.currentNode.textContent.includes('four five six')) {
                        target = walker.currentNode; break;
                    }
                }
                if (!target) return 'no-target';
                const range = document.createRange();
                range.selectNodeContents(target);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return sel.toString();
            })()
            """
        ) as? String
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(
            collector.received.contains { $0.contains("four five six") },
            "selectionChanged must push the selected text (DOM selected: \(String(describing: selected)), got: \(collector.received))"
        )

        // find() places a collapsed cursor → selection cleared → '' push
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.find('four'); true")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(
            collector.received.last, "",
            "deselect must push an empty string (got: \(collector.received))"
        )
    }

    // MARK: - Control (not zoomed)

    @MainActor
    func testControl_editWhileNotZoomed_updatesStoredWordCount() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)

        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try totalWordCount(db, pid)
        try await editBetaParagraph(helper.webView)
        _ = await sync.flushForDatabaseRebuild()

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            "CONTROL: un-zoomed edit must reach the DB (before=\(before), after=\(after))"
        )
    }
}
