//
//  CAYWConcurrentInsertTestsHelpers.swift
//  final finalTests
//
//  Split out of CAYWConcurrentInsertTests.swift to keep that file's class body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full CAYW
//  (Cite-As-You-Write) concurrent-insert background. This file holds the shared bridge stand-in
//  (`CAYWRequestCollector`), the real-WKWebView test harness (`makeHelper`, real NSEvent
//  keyDown/keyUp typing, cursor placement), the fixture markdown, and the DOM/debug-state
//  helpers the two tests in CAYWConcurrentInsertTests.swift drive through. `CAYWRequestCollector`
//  and `originalMarkdown` are `internal` (not `private`) because the tests instantiate/reference
//  them directly by name from the other file -- Swift's `private` same-file relaxation only
//  covers extensions in the SAME file.
//

import XCTest
import WebKit
@testable import final_final

extension CAYWConcurrentInsertTests {

    // MARK: - Stand-in Swift<->Zotero bridge

    /// Stands in for the real MilkdownCoordinator+MessageHandlers.swift round trip
    /// to Zotero: captures every requestId posted to "openCitationPicker" in call
    /// order, without needing a real Zotero connection. This lets the test control
    /// resolution order deterministically. Mirrors ZoomWordCountSyncTests.swift's
    /// SelectionMessageCollector idiom (nonisolated WKScriptMessageHandler callback,
    /// hopping to @MainActor to mutate state — WebKit always delivers script
    /// messages on the main thread, but the protocol requirement itself is
    /// nonisolated).
    @MainActor
    final class CAYWRequestCollector: NSObject, WKScriptMessageHandler {
        private(set) var requestIds: [Int] = []

        nonisolated func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "openCitationPicker", let requestId = message.body as? Int else { return }
            Task { @MainActor in
                self.requestIds.append(requestId)
            }
        }
    }

    // MARK: - Harness (mirrors CitationDeleteTests.swift, plus the collector
    // registered on the userContentController BEFORE loadAndWaitForReady, per
    // task instructions, since the real "openCitationPicker" handler is only
    // ever wired up by production MilkdownCoordinator, not by the bare
    // WKWebViewConfiguration EditorTestHelper constructs for tests).

    @MainActor
    func makeHelper(collector: CAYWRequestCollector) async throws -> EditorTestHelper {
        let helper = EditorTestHelper(editorType: .milkdown)
        helper.webView.configuration.userContentController.add(collector, name: "openCitationPicker")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)
        return helper
    }

    /// Real keyDown/keyUp NSEvent pair per character (see LinkTrailingTextTests.swift /
    /// HeadingParagraphExportOrderTests.swift for why this — and not execCommand — is
    /// required to exercise real editor behavior).
    @MainActor
    private func typeViaNSEvents(_ text: String, window: NSWindow) throws {
        for character in text {
            let charString = String(character)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                ),
                let upEvent = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                )
            else {
                throw NSError(
                    domain: "cayw-concurrent-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(upEvent)
        }
    }

    /// Real Return keypress (keyCode 36) via NSEvent — splits the current block.
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
            let upEvent = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
        else {
            throw NSError(domain: "cayw-concurrent-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(upEvent)
    }

    // MARK: - Fixture

    static let originalMarkdown = """
    First sentence here.

    Second sentence here.
    """

    // MARK: - DOM helpers

    /// Places a collapsed native DOM selection immediately after the first
    /// occurrence of `text` in the ProseMirror document — the real-world
    /// equivalent of "user clicked right after this sentence". Generalizes
    /// CitationDeleteTests.swift's placeCursorAfterFirstCitation to arbitrary
    /// target text via TreeWalker instead of a fixed CSS selector.
    @MainActor
    private func placeCursorAfterText(_ text: String, in helper: EditorTestHelper) async throws {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                pm.focus();
                const target = '\(escaped)';
                const walker = document.createTreeWalker(pm, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                    const idx = node.textContent.indexOf(target);
                    if (idx !== -1) {
                        const range = document.createRange();
                        range.setStart(node, idx + target.length);
                        range.collapse(true);
                        const sel = window.getSelection();
                        sel.removeAllRanges();
                        sel.addRange(range);
                        return 'ok';
                    }
                }
                return 'not-found';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to place cursor after '\(text)' (diagnostic: \(String(describing: result)))")
    }

    /// Places a collapsed cursor at the very START of the first top-level block
    /// whose textContent starts with `text` (mirrors HeadingParagraphExportOrderTests
    /// .swift's focusStartOfBlock) — used as the anchor for the intervening edit that
    /// prepends a whole new paragraph before both sentences.
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

    @MainActor
    func citationCount(_ helper: EditorTestHelper) async throws -> Int? {
        try await helper.webView.evaluateJavaScript(
            "document.querySelectorAll('.ff-citation').length"
        ) as? Int
    }

    struct CitationInfo: Decodable {
        let citekeys: String
        let paragraphText: String
    }

    /// Reads back every real `.ff-citation` DOM node's `data-citekeys` attribute
    /// (set by citation-plugin.ts's toDOM) plus its enclosing paragraph's text —
    /// the structural proof of "which citation landed next to which sentence".
    @MainActor
    func citationInfos(_ helper: EditorTestHelper) async throws -> [CitationInfo] {
        let json = try await helper.webView.evaluateJavaScript(
            """
            JSON.stringify(Array.from(document.querySelectorAll('.ff-citation')).map(el => {
                const p = el.closest('p');
                return {
                    citekeys: el.dataset.citekeys || '',
                    paragraphText: p ? p.textContent : (el.parentElement ? el.parentElement.textContent : '')
                };
            }))
            """
        ) as? String
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([CitationInfo].self, from: data)
    }

    struct CAYWDebugPendingEntry: Decodable {
        let requestId: Int
        let start: Int
        let end: Int
    }

    struct CAYWDebugState: Decodable {
        let pendingCAYWRequests: [CAYWDebugPendingEntry]
        let hasEditor: Bool
        let docSize: Int?
    }

    /// Reads `window.FinalFinal.getCAYWDebugState()` — the production debug hook
    /// (cayw.ts's getCAYWDebugState) that exposes the pending-request Map directly,
    /// used here to prove a cancelled request is actually gone from the map (not
    /// just that its side effects happen to look right).
    @MainActor
    func caywDebugState(_ helper: EditorTestHelper) async throws -> CAYWDebugState {
        let json = try await helper.webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.getCAYWDebugState())"
        ) as? String
        guard let json, let data = json.data(using: .utf8) else {
            throw NSError(domain: "cayw-concurrent-test", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to read getCAYWDebugState()"])
        }
        return try JSONDecoder().decode(CAYWDebugState.self, from: data)
    }

    // MARK: - Request lifecycle helpers

    /// Polls the collector until it has captured at least `count` requestIds, or
    /// the timeout elapses (in which case the caller's own assertion on the final
    /// count produces the failure, with a clear message).
    @MainActor
    private func waitForRequestCount(_ collector: CAYWRequestCollector, atLeast count: Int, timeout: TimeInterval = 3.0) async throws {
        let start = Date()
        while collector.requestIds.count < count {
            if Date().timeIntervalSince(start) > timeout { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Opens a new CAYW request at the cursor placed after `afterText`, via the
    /// SAME JS entry point the native toolbar "Cite" button calls
    /// (`window.FinalFinal.insertCitation` -> cayw.ts's insertCitationAtCursor ->
    /// openCAYWPicker), and waits for the stand-in bridge to capture its requestId.
    @MainActor
    func openCitationRequest(
        after afterText: String, helper: EditorTestHelper, collector: CAYWRequestCollector
    ) async throws -> Int {
        try await placeCursorAfterText(afterText, in: helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        let countBefore = collector.requestIds.count
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.insertCitation()")
        try await waitForRequestCount(collector, atLeast: countBefore + 1)
        XCTAssertEqual(collector.requestIds.count, countBefore + 1, "expected exactly one new CAYW request to open after '\(afterText)'")
        return collector.requestIds[countBefore]
    }

    /// Resolves a pending request via the real `citationPickerCallback` JS entry
    /// point (api-annotations.ts -> cayw.ts's handleCAYWCallback), with a minimal
    /// but valid CSL-JSON item — same shape citeproc-engine.ts's CSLItem expects.
    @MainActor
    func resolveCitation(_ helper: EditorTestHelper, requestId: Int, citekey: String, title: String) async throws {
        _ = try await helper.webView.evaluateJavaScript(
            """
            window.FinalFinal.citationPickerCallback(
                {
                    requestId: \(requestId),
                    citekeys: ['\(citekey)'],
                    locators: '[]',
                    prefix: '',
                    suppressAuthor: false,
                    rawSyntax: '[@\(citekey)]'
                },
                [{ id: '\(citekey)', type: 'book', title: '\(title)', author: [{ family: 'Test', given: 'Author' }], \
            issued: { 'date-parts': [[2024]] } }]
            )
            """
        )
    }

    /// Performs the intervening edit that shifts BOTH pending requests' positions:
    /// real typing (not execCommand, not a hand-built PM transaction) that inserts
    /// a whole new paragraph before both sentences, via placing the cursor at the
    /// very start of the document, typing new text, then splitting it off into its
    /// own paragraph with Enter.
    @MainActor
    func performInterveningEdit(helper: EditorTestHelper, window: NSWindow) async throws {
        try await focusStartOfBlock(containingPrefix: "First sentence here.", webView: helper.webView)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("Prepended intro text. ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
    }
}
