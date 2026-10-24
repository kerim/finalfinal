//
//  ContentChangedOrderingTests.swift
//  final finalTests
//
//  t-4a8fd8af, round 1b, T-U22 (judge O26). ON UNMODIFIED PRODUCTION CODE.
//
//  The question: when the page posts `contentChanged(X)` and, in the SAME JavaScript turn, answers a
//  `getContentRaw` evaluation with Y, has Swift HANDLED X (is it in the content record) by the time the
//  evaluation's reply resumes in Swift?
//
//  Why it matters. The Markdown step-8 flush reads the live text with `getContentRaw()` and adopts it into the
//  content record (judge O25). If an OLDER `contentChanged` (posted before that evaluation) were handled in
//  Swift AFTER the evaluation's reply, it would overwrite the adopted text with older text: a letter would go
//  backwards. The Swift handler does not handle the message inline: CodeMirrorCoordinator+MessageDispatch.swift
//  (`handleContentMessage`, "contentChanged") hops to the main actor with `Task { @MainActor in ... }` before
//  `handleContentPush` updates the record, so the order is not obvious from reading the code. This test measures it.
//
//  How the test forces "contentChanged posted before the evaluation's reply" (for a reviewer to judge):
//    * It loads the REAL editor page (EditorTestHelper(editorType: .codemirror): the built web bundle, main.ts)
//      in a real WKWebView, and registers the REAL `CodeMirrorEditor.Coordinator` as the page's "contentChanged"
//      script message handler. Its real `userContentController(_:didReceive:)` runs, with its real `Task { @MainActor }`
//      hop and the real `handleContentPush`. Only the coordinator's bindings are the test's (a box standing for
//      `editorState.sourceContent` / `editorState.content`).
//    * Each measured evaluation is ONE script, so the post and the reply are in one JavaScript turn:
//          window.webkit.messageHandlers.contentChanged.postMessage({content: X, wasUndo: false});   // X posted first
//          return window.FinalFinal.getContentRaw();                                                    // reply = Y, the real document
//      The reply cannot be produced before the post has been made, and the post is made before the script returns.
//    * Y is real: before each measured turn the test sets the page's document to Y with `setContent` and waits until
//      the page's own debounced `contentChanged` echo of Y has been handled, so the only message in flight in the
//      measured turn is X.
//    * The assertions run immediately after `await evaluateJavaScript(...)` returns, with NO suspension point between
//      the resume and the assertions. If Swift handled X later than the reply (the order inverted), the record still
//      holds the previous text (Y of the previous iteration) at that moment and the assertion fails. 200 iterations,
//      each with a distinct X and Y.
//    * A control test posts the message 300 ms AFTER the turn and asserts the record does NOT yet show X at resume
//      (and shows it later): so the observation point can tell "handled before the reply" from "handled after it".
//
//  If this test fails the pre-authorised fallback (judge section 2) is a document-change counter carried by both
//  `contentChanged` and `getContentRaw`, with Swift ignoring an older `contentChanged`.
//
//  Needs `cd web && pnpm build` first (the host tests load the built bundle). XCTest, not Swift Testing, because
//  WKWebView requires a run loop.
//

import XCTest
import SwiftUI
import WebKit
@testable import final_final

final class ContentChangedOrderingTests: XCTestCase {

    /// Stands for `editorState.sourceContent` (the coordinator's content binding) and the closure that sets
    /// `editorState.content` (`onContentChange`).
    private final class ContentRecord {
        var bound = ""
        var handled: [String] = []
    }

    private static let iterations = 200

    private var helper: EditorTestHelper!
    private var record: ContentRecord!
    private var coordinator: CodeMirrorEditor.Coordinator!
    private var hostWindow: NSWindow?

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)

        let record = ContentRecord()
        self.record = record
        let coordinator = CodeMirrorEditor.Coordinator(
            content: Binding(get: { record.bound }, set: { record.bound = $0 }),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            onContentChange: { text, _ in record.handled.append(text) },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil,
            windowToken: UUID()
        )
        // The state in which handleContentPush accepts a message (the guards at the top of that function).
        coordinator.isEditorReady = true
        self.coordinator = coordinator

        // Registered BEFORE navigation so the handler exists for the whole page lifetime.
        helper.webView.configuration.userContentController.add(coordinator, name: "contentChanged")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.orderFront(nil)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame (same shim and rationale as
        // BlockIdAlignmentHardeningLiveTests / ZoomWordCountSyncTests).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )
    }

    @MainActor
    override func tearDown() async throws {
        helper.webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentChanged")
        hostWindow?.orderOut(nil)
        hostWindow = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A JS string literal for `text` (JSON string syntax is valid JS).
    private func literal(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// Sets the page's document to `text` and waits until the page's own debounced `contentChanged` echo of it has
    /// been handled, so that nothing else is in flight afterwards.
    @MainActor
    private func settleDocument(to text: String) async throws {
        let textLiteral = try literal(text)
        _ = try await helper.webView.evaluateJavaScript(
            "(function(){ window.FinalFinal.setContent(\(textLiteral)); return true; })()"
        )
        await waitUntil("the page's echo of the document \(text.prefix(12))") { record.handled.last == text }
    }

    // MARK: - T-U22

    /// The pin. 200 iterations: X is posted, then the same turn replies Y; at the moment the reply resumes X is
    /// already in the content record. Fails if the order is ever inverted.
    @MainActor
    func testContentChangedPostedBeforeTheReplyIsHandledBeforeTheReplyResumes() async throws {
        for i in 0..<Self.iterations {
            let y = "document Y number \(i): " + String(repeating: "y", count: 1 + i % 9)
            let x = "older text X number \(i): " + String(repeating: "x", count: 1 + (i * 3) % 11)
            try await settleDocument(to: y)
            let handledBefore = record.handled.count
            let xLiteral = try literal(x)
            coordinator.lastPushTime = .distantPast   // outside the 150 ms push grace window, as for a user's keystroke

            let reply = try await helper.webView.evaluateJavaScript("""
                (function () {
                    window.webkit.messageHandlers.contentChanged.postMessage({content: \(xLiteral), wasUndo: false});
                    return window.FinalFinal.getContentRaw();
                })()
                """)

            // NO suspension point between the resume above and the assertions below.
            let handledAtResume = record.handled
            let boundAtResume = record.bound
            let lastPushedAtResume = coordinator.lastPushedContent

            XCTAssertEqual(reply as? String, y, "iteration \(i): the evaluation's reply should be the page's real document Y")
            XCTAssertEqual(
                handledAtResume.last, x,
                "iteration \(i): ORDER INVERTED -- contentChanged(X) was posted before the getContentRaw reply but was not yet handled "
                    + "when the reply resumed (last handled: \(handledAtResume.last ?? "nil"))"
            )
            XCTAssertEqual(
                handledAtResume.count, handledBefore + 1, "iteration \(i): X should have been handled exactly once by the time the reply resumes")
            XCTAssertEqual(boundAtResume, x, "iteration \(i): the content binding should hold X at resume")
            XCTAssertEqual(lastPushedAtResume, x, "iteration \(i): lastPushedContent should be X at resume")
            if handledAtResume.last != x { break }   // one inverted iteration is the answer; do not bury it in 200 failures
        }
    }

    /// Control: a message posted 300 ms AFTER the turn is NOT yet handled when the reply resumes, and is handled later.
    /// It proves the observation point in the test above can tell "handled before the reply" from "handled after it".
    @MainActor
    func testControlAMessagePostedAfterTheTurnIsNotYetHandledAtResume() async throws {
        let y = "control document Y"
        let x = "control text X posted 300 ms after the turn"
        try await settleDocument(to: y)
        coordinator.lastPushTime = .distantPast
        let xLiteral = try literal(x)

        let reply = try await helper.webView.evaluateJavaScript("""
            (function () {
                setTimeout(function () {
                    window.webkit.messageHandlers.contentChanged.postMessage({content: \(xLiteral), wasUndo: false});
                }, 300);
                return window.FinalFinal.getContentRaw();
            })()
            """)

        XCTAssertEqual(reply as? String, y)
        XCTAssertNotEqual(record.handled.last, x, "control: X is posted 300 ms later, so it cannot be handled at resume")
        await waitUntil("the late message to be handled") { record.handled.last == x }
    }
}
