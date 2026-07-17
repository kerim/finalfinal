//
//  CitationDeleteTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — regression tests for one-press citation deletion.
//
//  Covers the fix that lets Backspace/Delete remove an adjacent citation node
//  in a single press (instead of requiring the user to first select the atomic
//  node, then press again) and collapses the doubled space left behind when a
//  citation sat between two spaces — plus undo restoring both the citation and
//  the collapsed space in one step (proving the deletion is one atomic
//  transaction, per web/milkdown/src/citation-delete.ts).
//
//  Real NSEvent keyDown/keyUp through the host window — not
//  document.execCommand — per this codebase's established rule for WKWebView
//  caret/deletion bugs (see LinkTrailingTextTests.swift's rationale: execCommand
//  never exercises WebKit's native caret-canonicalization / contenteditable
//  deletion path, which is exactly what's implicated for an atomic,
//  contentEditable=false citation node).
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop —
//  same reason as LinkTrailingTextTests.swift.
//

import XCTest
import WebKit
@testable import final_final

final class CitationDeleteTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Harness (mirrors LinkTrailingTextTests.swift / PasteAboveHeadingOrderBugTests.swift)

    @MainActor
    private func makeHelper() async throws -> EditorTestHelper {
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
        return helper
    }

    /// Real keyDown/keyUp NSEvent pair through the host window — see
    /// PasteAboveHeadingOrderBugTests.swift's `sendKeyCommand` for the established
    /// generalized (keyCode-parameterized) version of this pattern.
    @MainActor
    private func sendKeyCommand(
        character: String, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, window: NSWindow
    ) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifierFlags,
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: modifierFlags,
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode
            )
        else {
            throw NSError(domain: "citation-delete-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for keyCode \(keyCode)"])
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// kVK_Delete (labeled "delete"/backspace on Mac keyboards, backward delete).
    @MainActor
    private func pressBackspace(window: NSWindow) throws {
        try sendKeyCommand(character: "\u{7F}", keyCode: 51, modifierFlags: [], window: window)
    }

    /// kVK_ForwardDelete (labeled "fn+delete"/forward delete). Character is
    /// NSDeleteFunctionKey (0xF728), the AppKit function-key constant WebKit's
    /// key-binding tables resolve to the `deleteForward:` editing command.
    @MainActor
    private func pressForwardDelete(window: NSWindow) throws {
        try sendKeyCommand(character: "\u{F728}", keyCode: 117, modifierFlags: [], window: window)
    }

    /// Cmd+Z — undo. Milkdown's history plugin binds Mod-z to its undo command
    /// via a real ProseMirror keymap (see @milkdown/plugin-history), so this
    /// exercises the same real keymap dispatch path as Backspace/Delete above,
    /// not a Swift-side shortcut.
    @MainActor
    private func pressCmdZ(window: NSWindow) throws {
        try sendKeyCommand(character: "z", keyCode: 6, modifierFlags: .command, window: window)
    }

    // MARK: - Fixture

    /// Seeds two resolvable citations so deleting ONE still leaves the bibliography
    /// section existing (matching the real bug scenario: the interesting, common
    /// case is "one of several citations disappeared", not "the last one did").
    @MainActor
    private func seedCitations() throws {
        let item1JSON = """
        {"id":"citedeltest2026","type":"book","title":"Cite Delete Test One","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let item2JSON = """
        {"id":"citedeltest2027","type":"book","title":"Cite Delete Test Two","author":[{"family":"Roe","given":"Richard"}],"issued":{"date-parts":[[2021]]}}
        """
        let item1 = try JSONDecoder().decode(CSLItem.self, from: Data(item1JSON.utf8))
        let item2 = try JSONDecoder().decode(CSLItem.self, from: Data(item2JSON.utf8))
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item1)
        ZoteroService.shared.loadItem(item2)
    }

    @MainActor
    private func clearCitations() {
        ZoteroService.shared.isConnected = false
        ZoteroService.shared.clearCache()
    }

    // Citation followed by more text in the SAME paragraph — cursor-adjacent-to-
    // citation is mid-paragraph, not block-start, so ProseMirror's baseKeymap
    // backspace/delete commands (gated on "cursor at the very start/end of a
    // textblock") do NOT fire; only the citation-specific keymap can handle this.
    private static let originalMarkdown = """
    # Test Document

    See [@citedeltest2026] and [@citedeltest2027] for details and more context after it.

    # References

    Doe, J. (2020). Cite Delete Test One.

    Roe, R. (2021). Cite Delete Test Two.
    """

    /// Places a collapsed native DOM selection immediately after the first citation
    /// span — mirrors LinkTrailingTextTests.swift's DOM Range/Selection placement
    /// technique (what a real click right after the citation actually produces).
    @MainActor
    private func placeCursorAfterFirstCitation(_ helper: EditorTestHelper) async throws {
        let placement = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                pm.focus();
                const cite = document.querySelector('.ff-citation');
                if (!cite) return 'no-citation';
                const range = document.createRange();
                range.setStartAfter(cite);
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(placement, "ok", "failed to place cursor immediately after the first citation (diagnostic: \(String(describing: placement)))")
    }

    /// Places a collapsed native DOM selection immediately before the first citation
    /// span (symmetric counterpart to placeCursorAfterFirstCitation, for Delete).
    @MainActor
    private func placeCursorBeforeFirstCitation(_ helper: EditorTestHelper) async throws {
        let placement = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                pm.focus();
                const cite = document.querySelector('.ff-citation');
                if (!cite) return 'no-citation';
                const range = document.createRange();
                range.setStartBefore(cite);
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(placement, "ok", "failed to place cursor immediately before the first citation (diagnostic: \(String(describing: placement)))")
    }

    @MainActor
    private func citationCount(_ helper: EditorTestHelper) async throws -> Int? {
        try await helper.webView.evaluateJavaScript(
            "document.querySelectorAll('.ff-citation').length"
        ) as? Int
    }

    // MARK: - Backspace

    @MainActor
    func testBackspaceAfterCitationMidParagraph_removesCitationAndCollapsesSpace() async throws {
        let helper = try await makeHelper()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try seedCitations()
        defer { clearCitations() }

        try await helper.setContent(Self.originalMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountBefore = try await citationCount(helper)
        XCTAssertEqual(citeCountBefore, 2, "setContent should have produced exactly 2 citation nodes")

        try await placeCursorAfterFirstCitation(helper)
        try await Task.sleep(nanoseconds: 200_000_000)

        try pressBackspace(window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let citeCountAfter = try await citationCount(helper)
        XCTAssertEqual(citeCountAfter, 1, "Backspace immediately after a citation should remove exactly one citation node in a single press")

        let content = try await helper.getContent()
        XCTAssertFalse(content.contains("  "), "deleting the citation must not leave a doubled space behind:\n\(content)")
        XCTAssertTrue(
            content.contains("See and [@citedeltest2027]"),
            "expected the collapsed single space between \"See\" and \"and\":\n\(content)"
        )
    }

    // MARK: - Delete (forward)

    @MainActor
    func testForwardDeleteBeforeCitationMidParagraph_removesCitationAndCollapsesSpace() async throws {
        let helper = try await makeHelper()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try seedCitations()
        defer { clearCitations() }

        try await helper.setContent(Self.originalMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountBefore = try await citationCount(helper)
        XCTAssertEqual(citeCountBefore, 2, "setContent should have produced exactly 2 citation nodes")

        try await placeCursorBeforeFirstCitation(helper)
        try await Task.sleep(nanoseconds: 200_000_000)

        try pressForwardDelete(window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let citeCountAfter = try await citationCount(helper)
        XCTAssertEqual(citeCountAfter, 1, "Forward Delete immediately before a citation should remove exactly one citation node in a single press")

        let content = try await helper.getContent()
        XCTAssertFalse(content.contains("  "), "deleting the citation must not leave a doubled space behind:\n\(content)")
        XCTAssertTrue(
            content.contains("See and [@citedeltest2027]"),
            "expected the collapsed single space between \"See\" and \"and\":\n\(content)"
        )
    }

    // MARK: - Popup Delete button survives a real background resync (position drift)

    /// Regression test for the position-drift bug fixed in citation-edit-popup.ts /
    /// citation-plugin.ts: the popup used to cache the citation's ProseMirror document
    /// position as a one-time captured integer. Any full-document replace between
    /// popup-open and the user's Delete click — exactly what setContentWithBlockIds
    /// performs in the background (bibliography resync, LanguageTool, block
    /// realignment) — could shift that position, silently no-op'ing the Delete button.
    ///
    /// This drives the REAL production API (`window.FinalFinal.setContentWithBlockIds`,
    /// the same one Swift itself calls) while the popup is open, then clicks the real
    /// Delete button, and asserts the citation is still correctly removed at its NEW
    /// position — proving the fix's live getPos() re-resolution, not just the trivial
    /// same-position case already covered above.
    ///
    /// The resync markdown keeps the same top-level block count/order and only grows
    /// the text BEFORE the citations within their existing paragraph. This exact shape
    /// was empirically verified (see
    /// web/milkdown/src/__tests__/citation-delete.test.ts) to make ProseMirror's view
    /// reconciliation reuse the citation's NodeView instance (so its live getPos()
    /// closure keeps tracking the shifted position) rather than destroy/recreate it —
    /// inserting a whole new paragraph ahead of it instead, by contrast, does NOT
    /// survive reconciliation and is covered separately by the JS test suite's
    /// "unrelated structural change" case (the fix's graceful-close path).
    ///
    /// Popup opening is driven via a real DOM click dispatched through JS rather than a
    /// native NSEvent: unlike the Backspace/Delete keyboard tests above (which need
    /// WebKit's native contenteditable/caret machinery — the reason this file uses real
    /// NSEvents at all), a plain button/element click listener registered via
    /// addEventListener('click', ...) fires identically for a JS-dispatched
    /// MouseEvent('click') as for a genuine hardware click, so no native event is
    /// needed here.
    @MainActor
    func testPopupDeleteButtonSurvivesBackgroundResyncPositionDrift() async throws {
        let helper = try await makeHelper()

        try seedCitations()
        defer { clearCitations() }

        try await helper.setContent(Self.originalMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountBefore = try await citationCount(helper)
        XCTAssertEqual(citeCountBefore, 2, "setContent should have produced exactly 2 citation nodes")

        // Open the real in-app edit popup via a real DOM click on the first citation —
        // exercises citation-plugin.ts's actual click handler end-to-end, which passes
        // the NodeView's live getPos() closure (not a snapshot) into showCitationEditPopup.
        let clickResult = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const cite = document.querySelector('.ff-citation');
                if (!cite) return 'no-citation';
                cite.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(clickResult, "ok", "failed to click the first citation")
        try await Task.sleep(nanoseconds: 200_000_000)

        let popupOpen = try await helper.webView.evaluateJavaScript(
            "document.querySelector('.ff-citation-edit-popup')?.style.display"
        ) as? String
        XCTAssertEqual(popupOpen, "block", "popup should be open after the click")

        // Real background resync via the production API, growing the text BEFORE the
        // citations within their existing paragraph (same top-level block count/order).
        let resyncMarkdown = """
        # Test Document

        See right here, with quite a lot more introductory text than before, [@citedeltest2026] and [@citedeltest2027] for details and more context after it.

        # References

        Doe, J. (2020). Cite Delete Test One.

        Roe, R. (2021). Cite Delete Test Two.
        """
        let escapedResync = resyncMarkdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setContentWithBlockIds(`\(escapedResync)`, [], {})"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountAfterResync = try await citationCount(helper)
        XCTAssertEqual(citeCountAfterResync, 2, "resync should still leave exactly 2 citation nodes in the document")

        // Popup is still open; click Delete now — must act on the citation's CURRENT
        // (shifted) position, not the stale one captured when the popup opened.
        let stillOpen = try await helper.webView.evaluateJavaScript(
            "document.querySelector('.ff-citation-edit-popup')?.style.display"
        ) as? String
        XCTAssertEqual(stillOpen, "block", "popup should still be open across the resync")

        let deleteClickResult = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const btn = document.querySelector('.ff-citation-delete-button');
                if (!btn) return 'no-delete-button';
                btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(deleteClickResult, "ok", "failed to click the Delete Citation button")
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountAfterDelete = try await citationCount(helper)
        XCTAssertEqual(citeCountAfterDelete, 1, "Delete button should remove exactly one citation at its NEW (shifted) position")

        let popupClosed = try await helper.webView.evaluateJavaScript(
            "document.querySelector('.ff-citation-edit-popup')?.style.display"
        ) as? String
        XCTAssertEqual(popupClosed, "none", "popup should close after Delete")

        let content = try await helper.getContent()
        XCTAssertTrue(content.contains("citedeltest2027"), "the surviving citation should still be present:\n\(content)")
        XCTAssertFalse(content.contains("citedeltest2026"), "the deleted citation should be gone:\n\(content)")
    }

    // MARK: - Undo

    @MainActor
    func testUndoAfterBackspaceRestoresCitationAndSpace() async throws {
        let helper = try await makeHelper()
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try seedCitations()
        defer { clearCitations() }

        try await helper.setContent(Self.originalMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let citeCountBefore = try await citationCount(helper)
        XCTAssertEqual(citeCountBefore, 2, "setContent should have produced exactly 2 citation nodes")

        let contentBefore = try await helper.getContent()

        try await placeCursorAfterFirstCitation(helper)
        try await Task.sleep(nanoseconds: 200_000_000)

        try pressBackspace(window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let citeCountAfterDelete = try await citationCount(helper)
        XCTAssertEqual(citeCountAfterDelete, 1, "precondition: Backspace should have removed one citation before testing undo")

        try pressCmdZ(window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let citeCountAfterUndo = try await citationCount(helper)
        XCTAssertEqual(citeCountAfterUndo, 2, "Cmd+Z should restore the deleted citation")

        let contentAfterUndo = try await helper.getContent()
        XCTAssertEqual(
            contentAfterUndo, contentBefore,
            "undo should restore the original content exactly, including the citation AND its surrounding space " +
            "(proves the deletion was one atomic transaction, not two separate steps)"
        )
    }
}
