//
//  HeadingParagraphExportOrderTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — DIAGNOSTIC ONLY, for investigating a user report that a
//  document with two "Title + paragraph" sections exported (PDF) with both headings
//  grouped before all paragraphs, plus an extra, unexplained third paragraph.
//
//  This is a real, WKWebView-hosted Milkdown editor driven with real NSEvent keyDown/
//  keyUp keystrokes (not execCommand, not hand-constructed BlockChanges/DB rows) —
//  see the "execCommand doesn't replicate real keyboard input" lesson. Three typing
//  shapes are exercised, per the investigation brief:
//
//    A. Straight-through, single continuous burst: heading, paragraph, heading,
//       paragraph, typed with no artificial pauses — everything should land in one
//       sync batch.
//    B. Straight-through, but with a forced sync flush between the two sections
//       (simulates autosave/debounce splitting an otherwise-in-order typing session
//       into two poll cycles).
//    C. Cross-cycle leading-heading insert, done for BOTH sections: type the
//       paragraph alone, force a flush (so it becomes a real, committed, permanent-id
///      block), THEN go back and prepend a heading for it in a separate cycle. This is
//       the exact shape the in-worktree "export-order-bug" fix targets — done here
//       twice (once per section) to see whether the second section's cross-cycle
//       prepend (NOT at literal document position 0) behaves the same as the first.
//
//  Export ordering is checked via the same function DocumentManager.loadContentForExport()
//  uses (BlockParser.assembleMarkdownForExport), reading directly from the on-disk
//  block table — Markdown export is sufficient to see block-order corruption; no PDF
//  rendering is needed to observe the bug's mechanism.
//

import XCTest
import WebKit
@testable import final_final

final class HeadingParagraphExportOrderTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Harness

    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
    }

    /// Starts from a genuinely empty document (no pre-existing blocks) — matching a
    /// brand-new .ff project, not a fixture with content already in it.
    @MainActor
    private func makeEmptyStack() async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: "")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on (see
        // ZoomWordCountSyncTests for the same shim + rationale).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)

        // Push the (empty) starting content + IDs, mirroring how a real project loads.
        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 400_000_000)

        return EditorStack(helper: helper, db: db, pid: pid, sync: sync)
    }

    /// Places a collapsed cursor at the very end of the document.
    @MainActor
    private func focusDocumentEnd(_ webView: WKWebView) async throws {
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                pm.focus();
                const range = document.createRange();
                range.selectNodeContents(pm);
                range.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to focus document end (diagnostic: \(String(describing: result)))")
    }

    /// Places a collapsed cursor at the very START of the first top-level block whose
    /// textContent starts with `text` — used to simulate "go back and prepend a heading"
    /// cross-cycle edits at a specific, real DOM location (not assumed cursor state).
    @MainActor
    private func focusStartOfBlock(containingPrefix text: String, webView: WKWebView) async throws {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let result = try await webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                pm.focus();
                const blocks = Array.from(pm.children);
                const target = blocks.find(el => el.textContent && el.textContent.startsWith('\(escaped)'));
                if (!target) return 'no-target:' + blocks.map(b => b.textContent).join('|');
                const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
                const firstText = walker.nextNode();
                const range = document.createRange();
                if (firstText) {
                    range.setStart(firstText, 0);
                } else {
                    range.selectNodeContents(target);
                }
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to focus start of block prefixed '\(text)' (diagnostic: \(String(describing: result)))")
    }

    /// Sends a real keyDown/keyUp NSEvent pair per character (see LinkTrailingTextTests
    /// for why this — and not execCommand — is required to exercise real editor behavior).
    @MainActor
    private func typeViaNSEvents(_ text: String, window: NSWindow) throws {
        for ch in text {
            let s = String(ch)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: s, charactersIgnoringModifiers: s,
                    isARepeat: false, keyCode: 0
                ),
                let up = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: s, charactersIgnoringModifiers: s,
                    isARepeat: false, keyCode: 0
                )
            else {
                throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for \(s)"])
            }
            window.sendEvent(down)
            window.sendEvent(up)
        }
    }

    /// Sends a real Return keypress (keyCode 36) via NSEvent — splits the current block.
    @MainActor
    private func pressEnter(window: NSWindow) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
        else {
            throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Human-readable dump of stored blocks in sortOrder, for assertion failure messages.
    private func orderSummary(_ blocks: [Block]) -> String {
        blocks.sorted { $0.sortOrder < $1.sortOrder }
            .map { "\($0.blockType.rawValue)(so=\(String(format: "%.4f", $0.sortOrder))):\"\($0.textContent.prefix(30))\"" }
            .joined(separator: " | ")
    }

    /// The exact function DocumentManager.loadContentForExport() uses for real
    /// PDF/Word/Markdown export — checked directly against the on-disk block table,
    /// which is enough to observe/report block-order corruption without rendering PDF.
    private func exportedMarkdown(_ blocks: [Block]) -> String {
        BlockParser.assembleMarkdownForExport(from: blocks.filter { !$0.isBibliography })
    }

    // MARK: - Shape A: straight-through, single continuous burst

    @MainActor
    func testShapeA_straightThroughSingleContinuousBurst() async throws {
        let stack = try await makeEmptyStack()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await focusDocumentEnd(stack.helper.webView)

        // Continuous burst: heading, paragraph, heading, paragraph — no sleeps, no
        // explicit poll calls in between. Real typing speed via NSEvent.
        try typeViaNSEvents("# Alpha Heading", window: window)
        try pressEnter(window: window)
        try typeViaNSEvents("Alpha paragraph text one two three test.", window: window)
        try pressEnter(window: window)
        try typeViaNSEvents("# Beta Heading", window: window)
        try pressEnter(window: window)
        try typeViaNSEvents("Beta paragraph text four five six test.", window: window)

        // Let the debounce settle, then force a flush the way a real save/export would.
        try await Task.sleep(nanoseconds: 800_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        await stack.sync.pollBlockChangesNow()

        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let contentAfter = try await stack.helper.getContent()
        if blocks.isEmpty || !contentAfter.contains("Alpha Heading") {
            throw XCTSkip("INCONCLUSIVE: typing never reached the editor/DB. editor content: \(contentAfter)")
        }

        let summary = orderSummary(blocks)
        let markdown = exportedMarkdown(blocks)
        print("SHAPE-A blocks: \(summary)")
        print("SHAPE-A exported markdown:\n\(markdown)")

        let sorted = blocks.sorted { $0.sortOrder < $1.sortOrder }
        let types = sorted.map { $0.blockType.rawValue }
        XCTAssertEqual(
            types, ["heading", "paragraph", "heading", "paragraph"],
            "SHAPE A (single continuous burst): expected heading,paragraph,heading,paragraph in that order, got: \(summary)"
        )
    }

    // MARK: - Shape B: straight-through, forced flush between sections

    @MainActor
    func testShapeB_straightThroughWithFlushBetweenSections() async throws {
        let stack = try await makeEmptyStack()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await focusDocumentEnd(stack.helper.webView)

        try typeViaNSEvents("# Alpha Heading", window: window)
        try pressEnter(window: window)
        try typeViaNSEvents("Alpha paragraph text one two three test.", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)

        try pressEnter(window: window)
        try typeViaNSEvents("# Beta Heading", window: window)
        try pressEnter(window: window)
        try typeViaNSEvents("Beta paragraph text four five six test.", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        await stack.sync.pollBlockChangesNow()

        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let contentAfter = try await stack.helper.getContent()
        if blocks.isEmpty || !contentAfter.contains("Alpha Heading") {
            throw XCTSkip("INCONCLUSIVE: typing never reached the editor/DB. editor content: \(contentAfter)")
        }

        let summary = orderSummary(blocks)
        let markdown = exportedMarkdown(blocks)
        print("SHAPE-B blocks: \(summary)")
        print("SHAPE-B exported markdown:\n\(markdown)")

        let sorted = blocks.sorted { $0.sortOrder < $1.sortOrder }
        let types = sorted.map { $0.blockType.rawValue }
        XCTAssertEqual(
            types, ["heading", "paragraph", "heading", "paragraph"],
            "SHAPE B (flush between sections): expected heading,paragraph,heading,paragraph in that order, got: \(summary)"
        )
    }

    // MARK: - Shape C: cross-cycle leading heading, for BOTH sections

    @MainActor
    func testShapeC_crossCycleLeadingHeadingForBothSections() async throws {
        let stack = try await makeEmptyStack()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        // --- Section 1: paragraph first, flush, THEN prepend heading (doc position 0) ---
        try await focusDocumentEnd(stack.helper.webView)
        try typeViaNSEvents("Alpha paragraph text one two three test.", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)

        let contentAfterPara1 = try await stack.helper.getContent()
        if !contentAfterPara1.contains("Alpha paragraph") {
            throw XCTSkip("INCONCLUSIVE: section-1 paragraph never reached the editor. content: \(contentAfterPara1)")
        }

        try await focusStartOfBlock(containingPrefix: "Alpha paragraph", webView: stack.helper.webView)
        try typeViaNSEvents("Alpha Heading", window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
        try await focusStartOfBlock(containingPrefix: "Alpha Heading", webView: stack.helper.webView)
        try typeViaNSEvents("# ", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)

        // --- Section 2: paragraph appended at the end, flush, THEN prepend heading
        //     (NOT at literal document position 0 — heading1+paragraph1 precede it) ---
        try await focusDocumentEnd(stack.helper.webView)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try typeViaNSEvents("Beta paragraph text four five six test.", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)

        let contentAfterPara2 = try await stack.helper.getContent()
        if !contentAfterPara2.contains("Beta paragraph") {
            throw XCTSkip("INCONCLUSIVE: section-2 paragraph never reached the editor. content: \(contentAfterPara2)")
        }

        try await focusStartOfBlock(containingPrefix: "Beta paragraph", webView: stack.helper.webView)
        try typeViaNSEvents("Beta Heading", window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
        try await focusStartOfBlock(containingPrefix: "Beta Heading", webView: stack.helper.webView)
        try typeViaNSEvents("# ", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)
        await stack.sync.pollBlockChangesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        await stack.sync.pollBlockChangesNow()

        let blocks = try TestFixtureFactory.fetchBlocks(from: stack.db)
        let contentAfter = try await stack.helper.getContent()
        if blocks.isEmpty || !contentAfter.contains("Alpha Heading") || !contentAfter.contains("Beta Heading") {
            throw XCTSkip("INCONCLUSIVE: cross-cycle heading typing never reached the editor/DB. editor content: \(contentAfter)")
        }

        let summary = orderSummary(blocks)
        let markdown = exportedMarkdown(blocks)
        print("SHAPE-C blocks: \(summary)")
        print("SHAPE-C exported markdown:\n\(markdown)")

        let sorted = blocks.sorted { $0.sortOrder < $1.sortOrder }
        let types = sorted.map { $0.blockType.rawValue }
        XCTAssertEqual(
            types, ["heading", "paragraph", "heading", "paragraph"],
            "SHAPE C (cross-cycle leading heading x2): expected heading,paragraph,heading,paragraph in that order, got: \(summary)"
        )
    }
}
