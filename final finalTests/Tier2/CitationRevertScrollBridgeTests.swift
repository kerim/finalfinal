//
//  CitationRevertScrollBridgeTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Regression test for the citation-revert-to-/cite bug fixed in commit cb88bc2
//  ("Fix citation reverting to /cite and scrolling to top in Source Mode"). One of two
//  independent defects fixed there: setContent() in web/codemirror/src/api.ts used to
//  do an unconditional whole-document replace (`from: 0, to: doc.length`). CodeMirror
//  maps any selection inside a fully-replaced range to the START of the replacement, so
//  the cursor -- and with it the scroll anchor -- silently teleported to document
//  position 0 on every derived-content push (e.g. the bibliography-section resync that
//  follows a citation insert). The fix (text-diff.ts's computeMinimalChange) confines
//  the dispatched change to the span that actually differs, so a push whose diff
//  doesn't span the cursor leaves CodeMirror's own position mapping to carry the cursor
//  (and scroll) forward untouched.
//
//  web/codemirror/src/__tests__/set-content-selection.test.ts already hardens the
//  underlying diff MECHANISM at the jsdom unit level, but jsdom has no real layout
//  engine, so it can't touch actual scroll pixels (see that file's header comment) --
//  it proves where CodeMirror's selection ends up, not what a user would actually see.
//  This test instead drives the real WKWebView-hosted CodeMirror editor end-to-end
//  through the same window.FinalFinal bridge Swift calls in production, and asserts the
//  thing a user actually notices: cursor position AND scroll position, both read back
//  via getCursorPosition() (line/column/scrollFraction/topLine/cursorIsVisible), survive
//  a tail-only derived-content push unchanged.
//
//  Calls setCursorPosition()/getCursorPosition() directly via helper.webView
//  .evaluateJavaScript(...) rather than extending EditorTestHelper, following the same
//  direct-eval pattern EditorBridgeTests.swift already uses for bridge surfaces it
//  doesn't wrap (e.g. testCodeMirrorSmartQuotesBridgeMethodsCallable).
//

import XCTest
@testable import final_final

final class CitationRevertScrollBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    // MARK: - Fixture

    private struct Fixture {
        let before: String
        let after: String
        let citationLine: Int    // 1-indexed CodeMirror line containing the citation
        let citationColumn: Int  // column right after "[@citekey2026]" on that line
    }

    /// Mirrors set-content-selection.test.ts's "bibliography-resync-shaped tail change"
    /// fixture, but built long enough (80 short padding paragraphs) that the fixed-size
    /// (800x600) test WKWebView actually needs to scroll to reach the cursor's
    /// paragraph -- proving real pixel scroll position, not just logical cursor
    /// position, survives the push. Paragraph text is deliberately short (well under an
    /// 800px line-wrap width -- CodeMirror's lineWrapping extension is on in
    /// main.ts) so line count, and therefore total document height, stays identical
    /// between "before" and "after". That isolates the assertions to the fix's own
    /// behavior instead of incidental height/wrap drift from unrelated line-count or
    /// wrap changes.
    private func makeFixture() -> Fixture {
        let paragraphCount = 80
        let citationParagraph = 40
        var lines: [String] = ["# Test Document", ""]
        var citationLine = 0
        var citationColumn = 0

        for i in 1...paragraphCount {
            if i == citationParagraph {
                let text = "Paragraph \(i) cites the source via [@citekey2026] right here."
                citationLine = lines.count + 1 // 1-indexed line this is about to occupy
                if let range = text.range(of: "[@citekey2026]") {
                    citationColumn = text.distance(from: text.startIndex, to: range.upperBound)
                }
                lines.append(text)
            } else {
                lines.append("Paragraph \(i) padding line for scroll test.")
            }
            lines.append("")
        }
        lines.append("## Bibliography")
        lines.append("")
        lines.append("Oldauthor, O. (2020). Old bibliography entry.")

        let before = lines.joined(separator: "\n")

        var afterLines = lines
        afterLines[afterLines.count - 1] = "Newauthor, N. (2026). Newly resolved bibliography entry."
        let after = afterLines.joined(separator: "\n")

        precondition(citationLine > 0, "Fixture construction must have located the citation paragraph")
        return Fixture(before: before, after: after, citationLine: citationLine, citationColumn: citationColumn)
    }

    // MARK: - Bridge calls not wrapped by EditorTestHelper

    private struct CursorSnapshot: Codable {
        let line: Int
        let column: Int
        let scrollFraction: Double
        let cursorIsVisible: Bool
        let topLine: Double
    }

    @MainActor
    private func setCursorPosition(line: Int, column: Int) async throws {
        _ = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.setCursorPosition({line: \(line), column: \(column)})"
        )
    }

    @MainActor
    private func getCursorSnapshot() async throws -> CursorSnapshot {
        let json = try await helper.webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.getCursorPosition())"
        ) as? String
        guard let json, let data = json.data(using: .utf8) else {
            XCTFail("getCursorPosition() did not return a JSON string")
            return CursorSnapshot(line: 1, column: 0, scrollFraction: 0, cursorIsVisible: true, topLine: 1)
        }
        return try JSONDecoder().decode(CursorSnapshot.self, from: data)
    }

    /// CodeMirror virtualizes its viewport (only renders visible lines + a margin), so
    /// scrollIntoView() targeting a position ~80 lines below the initially-rendered
    /// range doesn't land in one tick -- it converges over several animation-frame
    /// measure passes as CM extends the rendered range toward the target. A flat sleep
    /// long enough to be safe on every machine would be pure guesswork; polling until
    /// two consecutive reads agree is what loadAndWaitForReady() already does for the
    /// analogous "has this settled yet" problem, so this follows the same pattern.
    @MainActor
    private func waitForStableCursorSnapshot(maxAttempts: Int = 30) async throws -> CursorSnapshot {
        var previous: CursorSnapshot?
        for _ in 0..<maxAttempts {
            let current = try await getCursorSnapshot()
            if let previous,
                previous.line == current.line,
                previous.column == current.column,
                abs(previous.scrollFraction - current.scrollFraction) < 0.001 {
                return current
            }
            previous = current
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        XCTFail("Cursor/scroll position never stabilized within \(maxAttempts * 100)ms")
        return previous ?? CursorSnapshot(line: 1, column: 0, scrollFraction: 0, cursorIsVisible: true, topLine: 1)
    }

    // MARK: - The regression test

    @MainActor
    func testCursorAndScrollSurviveTailOnlyDerivedContentPush() async throws {
        let fixture = makeFixture()

        try await helper.setContent(fixture.before)
        try await Task.sleep(nanoseconds: 600_000_000)

        // Place the cursor deep in the document -- right after the resolved citation,
        // exactly where a real /cite resolution would leave it -- and let CodeMirror's
        // own scrollIntoView(center) put the viewport there, mirroring the real
        // post-citation-insert state this bug actually manifested in.
        try await setCursorPosition(line: fixture.citationLine, column: fixture.citationColumn)

        let before = try await waitForStableCursorSnapshot()
        XCTAssertEqual(before.line, fixture.citationLine, "Cursor must have moved to the citation's line")
        XCTAssertEqual(before.column, fixture.citationColumn, "Cursor must have moved to the citation's column")
        XCTAssertGreaterThan(
            before.scrollFraction, 0.05,
            "Fixture must actually require scrolling, otherwise this test can't prove scroll position survives"
        )
        XCTAssertLessThan(before.scrollFraction, 0.95, "Cursor should be placed well before the document's tail")

        // The derived-content push: a tail-only bibliography-section resync, exactly the
        // scenario cb88bc2 fixed. Everything up to and including the cursor's paragraph
        // is byte-identical between before/after -- only the bibliography entry at the
        // very end differs, so the diff is confined entirely to the tail.
        try await helper.setContent(fixture.after)

        let content = try await helper.getContent()
        XCTAssertTrue(content.contains("Newly resolved bibliography entry"), "The derived-content push must have landed")
        XCTAssertFalse(content.contains("Old bibliography entry"), "The stale bibliography entry must be gone")

        let after = try await waitForStableCursorSnapshot()
        XCTAssertEqual(after.line, before.line, "Cursor line must survive a tail-only derived-content push")
        XCTAssertEqual(after.column, before.column, "Cursor column must survive a tail-only derived-content push")
        XCTAssertEqual(
            after.scrollFraction, before.scrollFraction, accuracy: 0.01,
            "Scroll position must survive a tail-only derived-content push -- this is the user-visible symptom cb88bc2 fixed"
        )
        XCTAssertEqual(
            after.topLine, before.topLine, accuracy: 0.5,
            "The visible top line must not jump -- confirms the fix at the pixel/viewport level, not just a cursor-index match"
        )
        XCTAssertEqual(after.cursorIsVisible, before.cursorIsVisible, "Cursor visibility in the viewport must be unchanged")
    }
}
