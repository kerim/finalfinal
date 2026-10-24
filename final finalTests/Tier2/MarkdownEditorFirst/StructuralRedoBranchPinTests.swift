//
//  StructuralRedoBranchPinTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown mode structural commands go editor-first), round 1, T-U21 (host half).
//
//  A PIN of what Markdown mode does TODAY, on unmodified production code (it is later re-run as an
//  assertion, round 7). The question: after Delete Section in Markdown mode, does the editor's text
//  redo branch survive the old structural undo and redo, so that
//
//      Delete Section, type, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z
//
//  brings the typing back with the last press?
//
//  Today's Markdown structural undo/redo is the old body (StructuralUndoController.performStructuralOp /
//  performUndo / performRedo): the database changes and the editor then receives the assembled markdown
//  through `window.FinalFinal.setContent(text)` with no options, an `addToHistory: false` minimal-diff
//  dispatch (web/codemirror/src/api.ts). This test drives the REAL editor page in a real WKWebView
//  (EditorTestHelper(editorType: .codemirror): the built web bundle, main.ts's real extension set, real
//  listeners and the real capture-phase Cmd-Z interceptor) and plays Swift's side of the bridge exactly as
//  the old body does:
//    forward op : beginStructuralOp -> setContent(post) -> finalizeStructuralOpPostOpDoc -> setUndoDescriptor
//    undo       : (the page posts structuralUndoRequested) -> setContent(pre) -> setUndoDescriptor -> receiveUndoOutcome
//    redo       : (the page posts structuralRedoRequested) -> setContent(post) -> setUndoDescriptor -> receiveRedoOutcome
//  The web half of this pin (jsdom, the same real main.ts) is
//  web/codemirror/src/__tests__/structural-redo-branch-pin.test.ts and prints the history depths too.
//
//  Needs `cd web && pnpm build` first (the host tests load the built bundle). Uses XCTest (not Swift
//  Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
@testable import final_final

/// Collects the two structural-request messages the page posts when Cmd-Z / Cmd-Shift-Z routes structural.
/// Same shape as ZoomWordCountSyncTests.SelectionMessageCollector (nonisolated callback hopping to the MainActor).
@MainActor
private final class StructuralRequestCollector: NSObject, WKScriptMessageHandler {
    private(set) var undoRequests: [String] = []
    private(set) var redoRequests: [String] = []

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let opId = dict["opId"] as? String else { return }
        let name = message.name
        Task { @MainActor in
            if name == "structuralUndoRequested" {
                self.undoRequests.append(opId)
            } else if name == "structuralRedoRequested" {
                self.redoRequests.append(opId)
            }
        }
    }
}

final class StructuralRedoBranchPinTests: XCTestCase {

    private static let chapter1 = "# Chapter 1\n\nFirst chapter text.\n\n"
    private static let chapter2 = "# Chapter 2\n\nSecond chapter text.\n\n"
    private static let chapter3 = "# Chapter 3\n\nThird chapter text.\n\n"
    private static let chapter4 = "# Chapter 4\n\nFourth chapter text.\n"
    /// The document before Delete Section on Chapter 3.
    private static let preText = chapter1 + chapter2 + chapter3 + chapter4
    /// The document after it.
    private static let postText = chapter1 + chapter2 + chapter4

    private let opId = "11111111-2222-3333-4444-555555555555"

    private var helper: EditorTestHelper!
    private var collector: StructuralRequestCollector!
    private var hostWindow: NSWindow?

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)

        // Register the capture BEFORE navigation so it is present for the whole page lifetime (the page posts
        // with optional chaining, so without a handler the request is silently dropped).
        collector = StructuralRequestCollector()
        helper.webView.configuration.userContentController.add(collector, name: "structuralUndoRequested")
        helper.webView.configuration.userContentController.add(collector, name: "structuralRedoRequested")

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
        hostWindow?.orderOut(nil)
        hostWindow = nil
        try await super.tearDown()
    }

    // MARK: - Page helpers

    /// Runs a script in the page; the trailing `true` keeps a `void` call from surfacing as a bridge error.
    @MainActor
    @discardableResult
    private func js(_ script: String) async throws -> Any? {
        try await helper.webView.evaluateJavaScript("(function(){ \(script) ; return true; })()")
    }

    @MainActor
    private func documentText() async throws -> String {
        let value = try await helper.webView.evaluateJavaScript("window.FinalFinal.getContentRaw()")
        return value as? String ?? ""
    }

    /// A JS string literal for `text` (JSON string syntax is valid JS).
    private func literal(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// A real Cmd-Z / Cmd-Shift-Z keydown on the editor's content element: the page's capture-phase interceptor and
    /// CodeMirror's own keymap handle it.
    @MainActor
    private func press(_ direction: String) async throws {
        let isRedo = direction == "redo"
        try await js("""
            var el = document.querySelector('.cm-content');
            el.dispatchEvent(new KeyboardEvent('keydown', {
                key: '\(isRedo ? "Z" : "z")', code: 'KeyZ', keyCode: 90,
                metaKey: true, shiftKey: \(isRedo ? "true" : "false"),
                bubbles: true, cancelable: true
            }));
            """)
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let start = Date()
        while !condition() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    // MARK: - The pin

    @MainActor
    func testRedoBranchSurvivesDeleteSectionUndoRedo() async throws {
        let pre = Self.preText
        let post = Self.postText
        let preLiteral = try literal(pre)
        let postLiteral = try literal(post)

        // The document as opened (an intentional push: addToHistory false, so the text history starts empty).
        try await js("window.FinalFinal.setContent(\(preLiteral))")
        var text = try await documentText()
        XCTAssertEqual(text, pre)

        // 1. Delete Section on Chapter 3, as the old body does it in Markdown mode.
        let started = try await helper.webView.evaluateJavaScript("window.FinalFinal.beginStructuralOp('\(opId)')")
        XCTAssertEqual(started as? Bool, true, "beginStructuralOp should record the entry")
        try await js("window.FinalFinal.setContent(\(postLiteral))")
        let finalized = try await helper.webView.evaluateJavaScript("window.FinalFinal.finalizeStructuralOpPostOpDoc('\(opId)')")
        XCTAssertEqual(finalized as? Bool, true, "finalizeStructuralOpPostOpDoc should capture the post-op document")
        try await js("window.FinalFinal.setUndoDescriptor({undoTopOpId: '\(opId)'})")
        text = try await documentText()
        XCTAssertEqual(text, post, "Chapter 3 should be gone after Delete Section")

        // 2. Type at the end of Chapter 2's first paragraph (line 7 of the post-delete text, column 20).
        try await js("window.FinalFinal.setCursorPosition({line: 7, column: 20})")
        try await js("window.FinalFinal.insertAtCursor('hello there')")
        let typed = post.replacingOccurrences(of: "Second chapter text.", with: "Second chapter text.hello there")
        text = try await documentText()
        XCTAssertEqual(text, typed, "the typing should be in Chapter 2")

        // 3. Cmd-Z: the document is not the post-op document, so this is a plain text undo that removes the typing.
        try await press("undo")
        text = try await documentText()
        XCTAssertEqual(text, post, "first Cmd-Z should undo the typing")

        // 4. Cmd-Z: the document equals the post-op document, so the page routes it structural (it posts the request).
        try await press("undo")
        await waitUntil("the structural undo request") { collector.undoRequests.count == 1 }
        XCTAssertEqual(collector.undoRequests, [opId])
        XCTAssertTrue(collector.redoRequests.isEmpty)
        // Swift's old body: restore (the assembled pre-op text), push the descriptor, reply.
        try await js("window.FinalFinal.setContent(\(preLiteral))")
        try await js("window.FinalFinal.setUndoDescriptor({redoTopOpId: '\(opId)'})")
        try await js("window.FinalFinal.receiveUndoOutcome('\(opId)', 'performed')")
        text = try await documentText()
        XCTAssertEqual(text, pre, "second Cmd-Z should bring Chapter 3 back")

        // 5. Cmd-Shift-Z: the document equals the pre-op document, so the page routes it structural.
        try await press("redo")
        await waitUntil("the structural redo request") { collector.redoRequests.count == 1 }
        XCTAssertEqual(collector.redoRequests, [opId])
        try await js("window.FinalFinal.setContent(\(postLiteral))")
        try await js("window.FinalFinal.setUndoDescriptor({undoTopOpId: '\(opId)'})")
        try await js("window.FinalFinal.receiveRedoOutcome('\(opId)', 'performed')")
        text = try await documentText()
        XCTAssertEqual(text, post, "first Cmd-Shift-Z should delete Chapter 3 again")

        // 6. Cmd-Shift-Z: nothing structural is left on the redo stack, so this falls through to the text redo.
        try await press("redo")
        text = try await documentText()
        XCTAssertEqual(text, typed, "typing not restored by redo: the text redo branch did not survive the structural undo/redo")
        XCTAssertEqual(collector.undoRequests.count, 1, "the last press must have been a text redo, not another structural request")
        XCTAssertEqual(collector.redoRequests.count, 1, "the last press must have been a text redo, not another structural request")
    }
}
