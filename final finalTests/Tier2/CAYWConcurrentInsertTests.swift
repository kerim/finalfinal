//
//  CAYWConcurrentInsertTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — end-to-end proof of the CAYW (Cite-As-You-Write)
//  position-tracking fix, driven through a real WKWebView and the real
//  Swift <-> JS bridge (not just the JS-level unit tests in
//  web/milkdown/src/__tests__/cayw.test.ts).
//
//  The bug this hardens against (web/milkdown/src/cayw.ts): the citation
//  picker's "where do I insert when Zotero answers" position used to live in
//  a single module-level singleton. The Zotero round-trip is a real async
//  HTTP call the app's UI does NOT block on, so a second citation request
//  opened before the first resolves would clobber the first's stored range,
//  and continued editing during either round-trip would leave stale raw
//  offsets pointing at the wrong content. The fix replaces the singleton with
//  `pendingCAYWRequests: Map<requestId, {start,end}>` keyed by a
//  monotonically-increasing `nextCAYWRequestId`, plus `caywRemapPlugin` (a
//  ProseMirror plugin) that remaps every pending entry's range across every
//  doc-changing transaction via `tr.mapping.map()`.
//
//  This file proves the fix survives the real bridge, not just direct TS
//  function calls in jsdom:
//    - a real WKScriptMessageHandler registered for "openCitationPicker",
//      matching MilkdownCoordinator+MessageHandlers.swift's exact message
//      shape (`message.body as? Int`, the bare requestId — see
//      handleOpenCitationPicker(requestId:) and
//      sendCitationPickerCancelled(webView:requestId:)).
//    - real cursor placement + a real `window.FinalFinal.insertCitation()`
//      call (the same JS entry point the native toolbar "Cite" button
//      invokes — see cayw.ts's insertCitationAtCursor doc comment).
//    - a real intervening edit typed via NSEvent keyDown/keyUp (per this
//      codebase's "execCommand doesn't replicate real keyboard input" rule),
//      not a hand-built ProseMirror transaction — so the position shift the
//      remap plugin has to track is the same kind of shift a real user
//      produces by continuing to type while Zotero's dialog is still open.
//    - real `window.FinalFinal.citationPickerCallback(...)` /
//      `citationPickerCancelled(...)` calls, resolved deliberately
//      out of order, plus `window.FinalFinal.getCAYWDebugState()` to inspect
//      the pending map directly.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop —
//  same reason as CitationDeleteTests.swift.
//

import XCTest
import WebKit
@testable import final_final

final class CAYWConcurrentInsertTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

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
    private final class CAYWRequestCollector: NSObject, WKScriptMessageHandler {
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
    private func makeHelper(collector: CAYWRequestCollector) async throws -> EditorTestHelper {
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
        for ch in text {
            let charString = String(ch)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                ),
                let up = NSEvent.keyEvent(
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
            window.sendEvent(up)
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
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
        else {
            throw NSError(domain: "cayw-concurrent-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    // MARK: - Fixture

    private static let originalMarkdown = """
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
    private func citationCount(_ helper: EditorTestHelper) async throws -> Int? {
        try await helper.webView.evaluateJavaScript(
            "document.querySelectorAll('.ff-citation').length"
        ) as? Int
    }

    private struct CitationInfo: Decodable {
        let citekeys: String
        let paragraphText: String
    }

    /// Reads back every real `.ff-citation` DOM node's `data-citekeys` attribute
    /// (set by citation-plugin.ts's toDOM) plus its enclosing paragraph's text —
    /// the structural proof of "which citation landed next to which sentence".
    @MainActor
    private func citationInfos(_ helper: EditorTestHelper) async throws -> [CitationInfo] {
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

    private struct CAYWDebugPendingEntry: Decodable {
        let requestId: Int
        let start: Int
        let end: Int
    }

    private struct CAYWDebugState: Decodable {
        let pendingCAYWRequests: [CAYWDebugPendingEntry]
        let hasEditor: Bool
        let docSize: Int?
    }

    /// Reads `window.FinalFinal.getCAYWDebugState()` — the production debug hook
    /// (cayw.ts's getCAYWDebugState) that exposes the pending-request Map directly,
    /// used here to prove a cancelled request is actually gone from the map (not
    /// just that its side effects happen to look right).
    @MainActor
    private func caywDebugState(_ helper: EditorTestHelper) async throws -> CAYWDebugState {
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
    private func openCitationRequest(
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
    private func resolveCitation(_ helper: EditorTestHelper, requestId: Int, citekey: String, title: String) async throws {
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
                [{ id: '\(citekey)', type: 'book', title: '\(title)', author: [{ family: 'Test', given: 'Author' }], issued: { 'date-parts': [[2024]] } }]
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
    private func performInterveningEdit(helper: EditorTestHelper, window: NSWindow) async throws {
        try await focusStartOfBlock(containingPrefix: "First sentence here.", webView: helper.webView)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents("Prepended intro text. ", window: window)
        try await Task.sleep(nanoseconds: 300_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Test 1: overlapping requests, resolved out of order, across an intervening edit

    /// Core proof of the fix: two requests opened while both are still pending
    /// (no singleton clobbering), an intervening real edit that shifts both their
    /// stored ranges (proving caywRemapPlugin's tr.mapping.map() actually runs),
    /// and out-of-order resolution (proving the Map/requestId lookup — not
    /// insertion order, not "whichever was open" — decides where each citation
    /// lands).
    @MainActor
    func testOverlappingRequestsResolvedOutOfOrder_eachLandsAtCorrectShiftedPosition() async throws {
        let collector = CAYWRequestCollector()
        let helper = try await makeHelper(collector: collector)
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "openCitationPicker") }
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await helper.setContent(Self.originalMarkdown)

        // R1: cursor at end of the FIRST sentence.
        let r1 = try await openCitationRequest(after: "First sentence here.", helper: helper, collector: collector)

        // R2: cursor at end of the SECOND sentence — opened BEFORE R1 resolves,
        // so both are simultaneously pending.
        let r2 = try await openCitationRequest(after: "Second sentence here.", helper: helper, collector: collector)

        XCTAssertNotEqual(r1, r2, "each open should get its own distinct requestId")

        let debugBeforeEdit = try await caywDebugState(helper)
        XCTAssertEqual(debugBeforeEdit.pendingCAYWRequests.count, 2, "both requests should be pending before the intervening edit")

        // Intervening edit: real typing that shifts both R1's and R2's positions forward.
        try await performInterveningEdit(helper: helper, window: window)

        // Resolve OUT OF ORDER: R2 first, then R1.
        try await resolveCitation(helper, requestId: r2, citekey: "caywconcurrent2002", title: "CAYW Concurrent Insert Test Two")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await resolveCitation(helper, requestId: r1, citekey: "caywconcurrent2001", title: "CAYW Concurrent Insert Test One")
        try await Task.sleep(nanoseconds: 300_000_000)

        let debugAfter = try await caywDebugState(helper)
        XCTAssertEqual(debugAfter.pendingCAYWRequests.count, 0, "both requests should be resolved, none left pending")

        let count = try await citationCount(helper)
        XCTAssertEqual(count, 2, "exactly two citation nodes should exist — no duplication, no dropped insert")

        let infos = try await citationInfos(helper)
        XCTAssertEqual(infos.count, 2)

        guard
            let citeOne = infos.first(where: { $0.citekeys == "caywconcurrent2001" }),
            let citeTwo = infos.first(where: { $0.citekeys == "caywconcurrent2002" })
        else {
            XCTFail("expected to find both citations by citekey, got: \(infos)")
            return
        }

        XCTAssertTrue(
            citeOne.paragraphText.contains("First sentence here."),
            "R1's citation should land next to the FIRST sentence, not be swapped:\n\(citeOne.paragraphText)"
        )
        XCTAssertFalse(
            citeOne.paragraphText.contains("Second sentence here."),
            "R1's citation must not land next to the SECOND sentence:\n\(citeOne.paragraphText)"
        )

        XCTAssertTrue(
            citeTwo.paragraphText.contains("Second sentence here."),
            "R2's citation should land next to the SECOND sentence, not be swapped:\n\(citeTwo.paragraphText)"
        )
        XCTAssertFalse(
            citeTwo.paragraphText.contains("First sentence here."),
            "R2's citation must not land next to the FIRST sentence:\n\(citeTwo.paragraphText)"
        )

        let content = try await helper.getContent()
        XCTAssertEqual(
            content.components(separatedBy: "First sentence here.").count - 1, 1,
            "the first sentence must appear exactly once (no duplication):\n\(content)"
        )
        XCTAssertEqual(
            content.components(separatedBy: "Second sentence here.").count - 1, 1,
            "the second sentence must appear exactly once (no duplication):\n\(content)"
        )
        XCTAssertTrue(content.contains("Prepended intro text."), "the intervening paragraph should still be present:\n\(content)")

        guard
            let firstRange = content.range(of: "First sentence here."),
            let citeOneRange = content.range(of: "caywconcurrent2001"),
            let secondRange = content.range(of: "Second sentence here."),
            let citeTwoRange = content.range(of: "caywconcurrent2002")
        else {
            XCTFail("expected all four markers present in exported markdown:\n\(content)")
            return
        }
        XCTAssertTrue(firstRange.upperBound <= citeOneRange.lowerBound, "R1's citekey should appear after the first sentence:\n\(content)")
        XCTAssertTrue(citeOneRange.upperBound <= secondRange.lowerBound, "R1's citekey should appear before the second sentence:\n\(content)")
        XCTAssertTrue(secondRange.upperBound <= citeTwoRange.lowerBound, "R2's citekey should appear after the second sentence:\n\(content)")
    }

    // MARK: - Test 2: cancel one, keep the other pending

    /// Proves cancellation is requestId-scoped: cancelling R1 removes ONLY R1 from
    /// the pending map, leaves document content untouched (insertCitationAtCursor's
    /// picker-open path has no /cite placeholder text to clean up — start === end
    /// === cursor position, unlike the /cite slash-command path in
    /// slash-commands.ts, which passes a non-empty [cmdStart, cmdEnd) range), and
    /// R2 survives — still correctly tracked across the SAME intervening edit — to
    /// resolve normally afterward.
    @MainActor
    func testCancellingOnePendingRequest_leavesOtherIntactAndStillResolvable() async throws {
        let collector = CAYWRequestCollector()
        let helper = try await makeHelper(collector: collector)
        defer { helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "openCitationPicker") }
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await helper.setContent(Self.originalMarkdown)

        let r1 = try await openCitationRequest(after: "First sentence here.", helper: helper, collector: collector)
        let r2 = try await openCitationRequest(after: "Second sentence here.", helper: helper, collector: collector)
        XCTAssertNotEqual(r1, r2, "each open should get its own distinct requestId")

        try await performInterveningEdit(helper: helper, window: window)

        let contentBeforeCancel = try await helper.getContent()

        // Cancel R1 only.
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.citationPickerCancelled(\(r1))")
        try await Task.sleep(nanoseconds: 300_000_000)

        let contentAfterCancel = try await helper.getContent()
        XCTAssertEqual(
            contentAfterCancel, contentBeforeCancel,
            "cancelling R1 must not alter document content (no /cite placeholder text existed for this insertion path)"
        )

        let countAfterCancel = try await citationCount(helper)
        XCTAssertEqual(countAfterCancel, 0, "no citation should exist yet — neither request has been resolved")

        let debugAfterCancel = try await caywDebugState(helper)
        XCTAssertEqual(
            debugAfterCancel.pendingCAYWRequests.map(\.requestId), [r2],
            "R1 should be gone from the pending map after cancelling it; R2 should remain, still tracked"
        )

        // R2 must still complete correctly, at its shifted position, despite
        // R1's cancellation and the shared intervening edit.
        try await resolveCitation(helper, requestId: r2, citekey: "caywconcurrent2102", title: "CAYW Cancel Test Two")
        try await Task.sleep(nanoseconds: 300_000_000)

        let countAfterResolve = try await citationCount(helper)
        XCTAssertEqual(countAfterResolve, 1, "R2 should resolve into exactly one citation node")

        let infos = try await citationInfos(helper)
        guard let citeTwo = infos.first(where: { $0.citekeys == "caywconcurrent2102" }) else {
            XCTFail("expected to find R2's citation by citekey, got: \(infos)")
            return
        }
        XCTAssertTrue(
            citeTwo.paragraphText.contains("Second sentence here."),
            "R2 should still land next to the SECOND sentence after R1 was cancelled:\n\(citeTwo.paragraphText)"
        )
        XCTAssertFalse(
            citeTwo.paragraphText.contains("First sentence here."),
            "R2 must not land next to the FIRST sentence:\n\(citeTwo.paragraphText)"
        )

        let debugFinal = try await caywDebugState(helper)
        XCTAssertEqual(debugFinal.pendingCAYWRequests.count, 0, "no pending requests should remain after cancel + resolve")
    }
}
