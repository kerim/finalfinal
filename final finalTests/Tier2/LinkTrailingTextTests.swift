//
//  LinkTrailingTextTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — regression test for "text typed right after a
//  freshly-created link gets absorbed into the link instead of staying plain".
//
//  Two creation paths can produce a link while typing:
//    1. Bare autolink: "https://example.com" + space (autolink-plugin.ts)
//    2. Markdown-link syntax: "[text](url)" (markdown-link-input-rule.ts)
//
//  History, because this bug round-tripped twice before the real fix landed:
//
//  Round 1 cleared ProseMirror's `storedMarks` once, inline, in the transaction
//  that creates the link. It passed isolated ProseMirror-state unit tests but
//  failed live: live diagnostic logging showed multiple consecutive characters
//  getting absorbed before the mark state self-corrected — a one-shot clear
//  doesn't reliably survive real typing speed.
//
//  Round 2 replaced that with a self-healing `appendTransaction` plugin
//  (web/milkdown/src/link-cursor.ts), modeled on this codebase's already-shipped
//  fix for the identical trap shape on inline code spans (inline-code-cursor.ts).
//  This is real and still needed — it fixes the markdown-link-syntax case, where
//  the caret legitimately lands at the link's inclusive right edge. But the user
//  reported the bug was UNCHANGED after this fix too, and a first version of this
//  test file — typing via `document.execCommand('insertText', ...)` — passed
//  against both the broken and fixed builds, giving false confidence.
//
//  Root cause (round 3): this app never imported ProseMirror's mandatory base
//  stylesheet (prosemirror-view/style/prosemirror.css), so `.ProseMirror` had
//  `white-space: normal` instead of `pre-wrap`/`break-spaces`. Under `normal`, a
//  paragraph-final space (the one autolink inserts right after a fresh link)
//  renders as zero-width, and WebKit's real caret-canonicalization logic moves
//  the caret backward across that collapsed space into the preceding `<a>` on the
//  very next real keystroke — deleting the space and landing the typed character
//  inside the link. Fixed in web/milkdown/src/styles.css.
//
//  Why `execCommand` couldn't catch it: it inserts directly into a DOM range and
//  never exercises WebKit's native caret-canonicalization path — the exact
//  mechanism the bug lives in. Confirmed by dispatching genuine `NSEvent`
//  keyDown/keyUp events through the actual host window instead: that reproduced
//  the bug deterministically against the broken build and passes against the
//  fixed one. This file exists ONLY in that NSEvent form now — do not add an
//  `execCommand`-based typing path back to this file; it cannot be trusted for
//  cursor/caret-boundary behavior in a WKWebView editor. See the memory
//  "execCommand doesn't replicate real keyboard input" for the general lesson.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
import WebKit
@testable import final_final

final class LinkTrailingTextTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Harness

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

    /// Establishes a real, empty, editable paragraph and places a collapsed
    /// cursor at its end, ready for typed input.
    ///
    /// A freshly-loaded/empty document's only block is a non-editable
    /// `.section-break` marker ("§"), NOT an editable paragraph — `setContent(" ")`
    /// normalizes to a real, empty `<p>` (Milkdown trims the whitespace-only
    /// paragraph to empty), and collapsing a selection to the END of that
    /// paragraph's contents is where typed input actually lands.
    @MainActor
    private func establishEmptyParagraphAndFocus(_ helper: EditorTestHelper) async throws {
        try await helper.setContent(" ")
        try await Task.sleep(nanoseconds: 300_000_000)

        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const p = pm.querySelector('p');
                if (!p) return 'no-paragraph';
                pm.focus();
                const range = document.createRange();
                range.selectNodeContents(p);
                range.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to establish an empty paragraph and focus it (diagnostic: \(String(describing: result)))")
    }

    /// Sends a real keyDown/keyUp NSEvent pair for each character through the
    /// host window — this is what actually exercises WebKit's native typing path
    /// (interpretKeyEvents -> insertText: -> DOM mutation -> ProseMirror
    /// DOMObserver), including the caret-canonicalization behavior that
    /// `execCommand('insertText', ...)` bypasses entirely.
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
                throw NSError(domain: "diag", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for \(charString)"])
            }
            window.sendEvent(down)
            window.sendEvent(up)
        }
    }

    @MainActor
    private func paragraphHTML(_ webView: WKWebView) async throws -> String {
        (try await webView.evaluateJavaScript(
            "(document.querySelector('.ProseMirror p') || {}).innerHTML || '<<none>>'"
        ) as? String) ?? "<<eval-failed>>"
    }

    @MainActor
    private func linkCount(_ webView: WKWebView) async throws -> Int {
        let result = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.ProseMirror a').length"
        )
        return (result as? Int) ?? -1
    }

    @MainActor
    private func linkTexts(_ webView: WKWebView) async throws -> [String] {
        let jsonString = try await webView.evaluateJavaScript(
            "JSON.stringify(Array.from(document.querySelectorAll('.ProseMirror a')).map(a => a.textContent))"
        ) as? String
        guard let json = jsonString, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: - Autolink via real key events (fast typing, no delay)

    @MainActor
    func testAutolink_sentinelTypedAfterSpaceStaysOutsideLink() async throws {
        let helper = try await makeHelper()
        let webView = helper.webView
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await establishEmptyParagraphAndFocus(helper)

        try typeViaNSEvents("https://example.com", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let htmlAfterURL = try await paragraphHTML(webView)
        if !htmlAfterURL.contains("https") {
            throw XCTSkip("INCONCLUSIVE: NSEvent keystrokes never reached the editor (paragraph: \(htmlAfterURL))")
        }

        try typeViaNSEvents(" W", window: window)
        try await Task.sleep(nanoseconds: 800_000_000)

        let html = try await paragraphHTML(webView)
        let texts = try await linkTexts(webView)
        let content = try await helper.getContent()

        XCTAssertEqual(
            texts, ["https://example.com"],
            "sentinel absorbed into link via real key events. innerHTML: \(html) markdown: \(content)"
        )
        XCTAssertFalse(
            content.contains("comW"),
            "sentinel fused to URL (typed space lost) via real key events. innerHTML: \(html) markdown: \(content)"
        )
        XCTAssertTrue(
            content.contains("> W") || content.contains(") W") || content.contains("com W"),
            "the space typed after the autolink must survive the next keystroke. " +
            "innerHTML: \(html) markdown: \(content)"
        )
    }

    // MARK: - Autolink via real key events (human-speed pause before sentinel)

    @MainActor
    func testAutolink_sentinelTypedAfterSpaceStaysOutsideLink_humanSpeed() async throws {
        let helper = try await makeHelper()
        let webView = helper.webView
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await establishEmptyParagraphAndFocus(helper)

        try typeViaNSEvents("https://example.com", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let htmlAfterURL = try await paragraphHTML(webView)
        if !htmlAfterURL.contains("https") {
            throw XCTSkip("INCONCLUSIVE: NSEvent keystrokes never reached the editor (paragraph: \(htmlAfterURL))")
        }

        try typeViaNSEvents(" ", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        try typeViaNSEvents("W", window: window)
        try await Task.sleep(nanoseconds: 800_000_000)

        let html = try await paragraphHTML(webView)
        let texts = try await linkTexts(webView)
        let content = try await helper.getContent()

        XCTAssertEqual(
            texts, ["https://example.com"],
            "sentinel absorbed into link at human typing speed. innerHTML: \(html) markdown: \(content)"
        )
        XCTAssertTrue(
            content.contains("> W") || content.contains(") W") || content.contains("com W"),
            "the space typed after the autolink must survive the next keystroke at human speed. " +
            "innerHTML: \(html) markdown: \(content)"
        )
    }

    // MARK: - Markdown-link syntax via real key events

    @MainActor
    func testMarkdownLinkSyntax_sentinelTypedAfterCloseParenStaysOutsideLink() async throws {
        let helper = try await makeHelper()
        let webView = helper.webView
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await establishEmptyParagraphAndFocus(helper)

        try typeViaNSEvents("[hello](https://example.com)", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let htmlAfterLink = try await paragraphHTML(webView)
        if !htmlAfterLink.contains("hello") {
            throw XCTSkip("INCONCLUSIVE: NSEvent keystrokes never reached the editor (paragraph: \(htmlAfterLink))")
        }

        try typeViaNSEvents("x", window: window)
        try await Task.sleep(nanoseconds: 800_000_000)

        let html = try await paragraphHTML(webView)
        let texts = try await linkTexts(webView)
        let content = try await helper.getContent()

        XCTAssertEqual(
            texts, ["hello"],
            "sentinel absorbed into markdown-syntax link via real key events. innerHTML: \(html) markdown: \(content)"
        )
        XCTAssertFalse(
            content.contains("hellox"),
            "sentinel fused to link text via real key events. innerHTML: \(html) markdown: \(content)"
        )
    }

    // MARK: - Regression guard: editing mid-link must still absorb into the link

    /// The fix must only stop trailing text at the link's *boundary* — normal
    /// editing of already-existing link text (cursor placed strictly inside the
    /// link, not at an edge) must still carry the link mark. Uses real key events
    /// for consistency with the rest of this file, even though this particular
    /// case was never timing/caret-canonicalization-sensitive.
    @MainActor
    func testEditingInsideExistingLink_charIsAbsorbedIntoLink() async throws {
        let helper = try await makeHelper()
        let webView = helper.webView
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        try await helper.setContent("Check out [example](https://example.com) today.")
        try await Task.sleep(nanoseconds: 300_000_000)

        let countBefore = try await linkCount(webView)
        XCTAssertEqual(countBefore, 1, "setContent did not produce exactly one link to edit into")

        // Place a collapsed cursor strictly inside the link's text node (not at
        // either boundary).
        let placement = try await webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                pm.focus();
                const a = document.querySelector('.ProseMirror a');
                if (!a) return 'no-link';
                const textNode = a.firstChild;
                if (!textNode || textNode.nodeType !== Node.TEXT_NODE) return 'no-text-node';
                const len = textNode.textContent.length;
                if (len < 3) return 'link-text-too-short';
                const offset = Math.floor(len / 2); // strictly inside, not at either edge
                const range = document.createRange();
                range.setStart(textNode, offset);
                range.collapse(true);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok:' + textNode.textContent + ':' + offset;
            })()
            """
        ) as? String
        XCTAssertEqual(
            placement?.hasPrefix("ok:"), true,
            "failed to place a mid-link cursor via DOM selection (diagnostic: \(String(describing: placement)))"
        )

        let originalText = try await linkTexts(webView).first ?? ""
        XCTAssertFalse(originalText.isEmpty, "could not read the link's original text before editing")

        try typeViaNSEvents("Z", window: window)
        try await Task.sleep(nanoseconds: 500_000_000)

        let countAfter = try await linkCount(webView)
        XCTAssertEqual(countAfter, 1, "editing inside the link must not create or destroy link nodes")

        let texts = try await linkTexts(webView)
        let newText = texts.first ?? ""
        XCTAssertEqual(
            newText.count, originalText.count + 1,
            "typing inside an existing link's text should grow the linked text by exactly one " +
            "character (before: \(originalText), after: \(newText))"
        )
        XCTAssertTrue(
            newText.contains("Z"),
            "the character typed inside the link must become part of the link's text " +
            "(before: \(originalText), after: \(newText))"
        )
    }
}
