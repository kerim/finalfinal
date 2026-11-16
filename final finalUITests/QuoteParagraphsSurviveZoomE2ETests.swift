//
//  QuoteParagraphsSurviveZoomE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression test for t-4eb7bfa9: Rich Text saves each edited block with Milkdown's own serializer, so a quote typed with
//  two paragraphs keeps both of them through zoom in, zoom out and a switch to Markdown and back.
//
//  The bug it pins: the per-block save used a hand-written converter that wrote the quote as `> first` / `> second` (the paragraph
//  break was lost). That reads back as ONE paragraph, and that merged text was what the database kept, so the next zoom or mode
//  switch showed "first second" in a single paragraph. Milkdown's own serializer (and the whole-document save) writes
//  `> first` / `>` / `> second`.
//
//  Why this is a permanent UI test and not a unit or vitest one: the bug lives in the whole chain, typed text in the real Milkdown
//  editor -> the page's per-block report -> the database -> the reload a zoom or a mode switch does -> the page again. The vitest
//  (block-fragment-parity.test.ts) and the Swift round-trip test cover the two serializers and the write; only the running app
//  covers the real reload through the Outline sidebar and Cmd-/.
//
//  What a person does here, and what each step proves (the four items of the task):
//    1. Rich Text: type `> `, `first`, Return, `second`, Return, Return (leaves the quote), then a closing paragraph. The editor shows ONE
//       quote holding two paragraphs, and the database row for the quote reads `> first\n>\n> second`. (The row is what fails first
//       without the fix: the live page itself is still right at this point.)
//    2. Zoom into the chapter from the Outline sidebar, then zoom out: still two paragraphs in the quote, still that row.
//    3. Cmd-/ to Markdown: the text shows `> first`, a line holding only `>`, then `> second`.
//    4. Cmd-/ back to Rich Text: still two paragraphs in the quote.
//
//  How it reads the page (every choice below is a recorded e2e-verify lesson, see the skill's "Proven patterns"):
//    - Editor text lives in `value`, never `label`; the whole editor subtree is read from ONE `snapshot()` and walked in-process (no
//      per-element round trips, no `CONTAINS` predicate against staticTexts).
//    - "One quote holding two paragraphs" is read from geometry in that snapshot: a separate leaf "first" and a separate leaf "second"
//      on two lines, both indented like a quote relative to the body paragraph (the quote has a left border and padding), while the
//      paragraph typed after leaving the quote is NOT indented. A merged paragraph has no leaf "first" at all. "One quote, not two"
//      is proved by the Markdown text (the `>` line between the two paragraphs) and by the database row (one blockquote row).
//    - The row is read from the database, polled with a bound (the page's report reaches the database through the write queue, so a
//      single read right after typing can race it), never read once.
//    - Each stage attaches its still BEFORE its assertions (an aborting assertion would otherwise leave no image) and reports on its own:
//      the four items are checked softly so one run says which of them fail, not only the first.
//    - Waits are polls with a bound that return the moment the condition holds. The only wait that gates an action is the zoom exit
//      glyph, which the app disables while the document is busy (a disabled control cannot be clicked).
//    - No underscores or asterisks are typed (Milkdown's input rules turn typed `_x_` / `*x*` into italic); plain words only.
//

import XCTest

final class QuoteParagraphsSurviveZoomE2ETests: XCTestCase {
    var app: XCUIApplication!

    static let bodyParagraph = "Body paragraph before the quote."
    static let closingParagraph = "Closing words after the quote."
    static let otherParagraph = "Other chapter paragraph."
    static let rawHeading = "# Quote Test Document"
    /// What the database must hold for the quote at every stage: Milkdown's own serializer and the whole-document save both write it.
    static let expectedQuoteFragment = "> first\n>\n> second"

    /// The first line is a heading (a heading-less seed defeats the readiness checks). "Other Chapter" comes first so its paragraph is at
    /// the top of the page, always in view, and tells a zoomed page (absent) from the whole document (present). The quote chapter is
    /// last, so the quote is typed at the end of the document.
    static let seedMarkdown = """
    # Quote Test Document

    ## Other Chapter

    Other chapter paragraph.

    ## Quote Chapter

    Body paragraph before the quote.
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"  // toggleEditorModeUntilReceived reads the app log
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // macOS inline predictive text can swallow keystrokes while prose is typed at speed (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The test

    func testQuoteWithTwoParagraphsSurvivesZoomAndModeSwitch() throws {
        try waitForSeededDocument()
        try typeQuoteAndLeaveIt()

        // Item 1: one quote holding two paragraphs, and the saved row says so.
        softly { checkRichTextQuote("item1-after-typing", otherChapterShown: nil) }

        // Item 2: zoom into the chapter from the Outline sidebar, then zoom out.
        try zoomIntoQuoteChapter()
        softly { checkRichTextQuote("item2a-zoomed-in", otherChapterShown: false, checkDatabase: false) }
        try zoomOut()
        softly { checkRichTextQuote("item2b-zoomed-out", otherChapterShown: true) }

        // Item 3: the Markdown text shows `> first`, `>`, `> second`.
        try switchMode(to: "Markdown")
        softly { checkMarkdownQuote("item3-markdown") }

        // Item 4: back in Rich Text, still two paragraphs in the quote.
        try switchMode(to: "Rich Text")
        softly { checkRichTextQuote("item4-back-in-rich-text", otherChapterShown: true) }
    }
}

// MARK: - Steps that drive the app

private struct StopTest: Error {}

extension QuoteParagraphsSurviveZoomE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without. (The four item
    /// checks are soft and never use this: they report each on its own.)
    func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw StopTest()
    }

    /// Runs `body` so that a failed assertion inside it is recorded without ending the test.
    func softly(_ body: () -> Void) {
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        body()
    }

    /// Polls `probe` every `pollInterval` until it returns true or `timeout` passes; returns the last answer.
    func pollUntilTrue(timeout: TimeInterval, pollInterval: TimeInterval = 0.3, _ probe: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if probe() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return probe()
    }

    func waitForSeededDocument() throws {
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        // The status-bar word count reads "0 words" before the editor exists, so it is no readiness signal: wait for real content.
        try require(
            app.editorStaticText(startingWith: Self.bodyParagraph, timeout: 30) != nil,
            "TEST-SETUP: the seeded body paragraph never appeared in the editor"
        )
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForLabel("== 'Rich Text'", timeout: 10), "TEST-SETUP: the document must open in Rich Text mode")
    }

    /// Caret to the end of the body paragraph, then the quote exactly as a person types it: a new paragraph, `> `, first, Return,
    /// second, Return, Return (the second Return lifts the empty paragraph out of the quote), then a closing paragraph.
    func typeQuoteAndLeaveIt() throws {
        let caret = app.placeCaretByClicking(
            paragraphStartingWith: Self.bodyParagraph, atEnd: true, exactLine: Self.bodyParagraph
        )
        try require(
            caret.confirmed,
            "TEST-SETUP: the caret could not be placed at the end of the body paragraph (probe: \(caret.probe)); attempts: \(caret.attempts)"
        )
        app.typeKey(.return, modifierFlags: [])
        // `> ` is the quote input rule's trigger and is consumed by it, so it never stays as text: it cannot go through
        // typeTextVerifyingLanded, which verifies that its own argument landed. The words after it are verified.
        // e2e-lint: allow raw-typetext -- the input-rule trigger is consumed, there is nothing for a landing check to find.
        app.typeText("> ")
        app.typeTextVerifyingLanded("first")
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded("second")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded(Self.closingParagraph)
    }

    /// A sidebar card by its exact title. The title lives in `value`; the query is scoped to the sidebar's scroll view (the editor
    /// also shows each heading, and a zoomed page adds a breadcrumb with the same text).
    func sidebarCard(titled title: String) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        return sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
    }

    /// Double-click on the chapter's Outline card (the zoom trigger the suite already uses). Cards are not hittable by design, so the
    /// click goes through a coordinate.
    func zoomIntoQuoteChapter() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        let card = sidebarCard(titled: "Quote Chapter")
        try require(card.waitForExistence(timeout: 15), "TEST-SETUP: the Outline sidebar has no card titled \"Quote Chapter\"")
        let visibleBand = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        try require(
            visibleBand.contains(card.frame),
            "TEST-SETUP: the \"Quote Chapter\" card (\(card.frame)) is outside the sidebar's visible band (\(visibleBand))"
        )
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        try require(exitGlyph.waitForExistence(timeout: 20), "The double-click on the \"Quote Chapter\" card did not zoom into it")
    }

    func zoomOut() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        // The app disables the glyph while the document is still busy, and a disabled control cannot be clicked: the one bounded
        // wait that gates an action here.
        try require(
            pollUntilTrue(timeout: 20) { exitGlyph.exists && exitGlyph.isEnabled },
            "TEST-SETUP: the zoom exit glyph never became enabled"
        )
        exitGlyph.click()
        try require(exitGlyph.waitForDisappearance(timeout: 20), "The click on the zoom exit glyph did not leave the zoom")
    }

    /// Cmd-/ until the editor-mode button reports `target` ("Markdown" or "Rich Text"). The keystroke can drop when the app is not
    /// reliably in the foreground at the instant it is sent (proven pattern in EditorModeSwitchUndoE2ETests): re-activate and retry, but
    /// never resend a press the app already received (`toggleEditorModeUntilReceived`, UITestHelpers.swift).
    func switchMode(to target: String) throws {
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button did not appear")
        let toggle = toggleEditorModeUntilReceived(app, to: target, maxPresses: 5, receiptWindow: 5)
        try require(toggle.flipped, "Cmd-/ did not switch the editor to \(target) (the mode button still reads \"\(editorMode.label)\")")
    }
}

// MARK: - Reading the page

extension QuoteParagraphsSurviveZoomE2ETests {
    /// One node of the editor's accessibility subtree.
    struct QuoteNode {
        let type: XCUIElement.ElementType
        let label: String
        let value: String?
        let frame: CGRect
    }

    /// A static-text leaf of the editor with its text normalized and its frame.
    struct QuoteLeaf {
        let value: String
        let frame: CGRect
    }

    /// What one reading of the page found wrong (empty = nothing wrong), and a dump of what it saw.
    struct QuoteReading {
        var problems: [String]
        var dump: String
    }

    /// What one reading of the Markdown page found: the quote's three lines, how they were found, whether the Markdown editor is
    /// mounted at all, and a dump of what it saw.
    struct MarkdownReading {
        var found: Bool
        var via: String
        var mounted: Bool
        var dump: String
    }

    /// Non-breaking spaces become plain ones and CRLF becomes LF; nothing is trimmed (a multi-line value keeps its inner newlines).
    static func unified(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func normalized(_ text: String) -> String {
        unified(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every node below `snapshot`, in document order.
    static func flatten(_ snapshot: XCUIElementSnapshot) -> [QuoteNode] {
        var nodes: [QuoteNode] = []
        for child in snapshot.children {
            nodes.append(QuoteNode(type: child.elementType, label: child.label, value: child.value as? String, frame: child.frame))
            nodes.append(contentsOf: flatten(child))
        }
        return nodes
    }

    /// The whole editor subtree from ONE snapshot (a failed snapshot is retried), or nil.
    func readEditorNodes(attempts: Int = 4) -> [QuoteNode]? {
        for attempt in 1...attempts {
            do {
                return Self.flatten(try app.editorArea.snapshot())
            } catch {
                print("[QuoteParagraphs] snapshot() of editor-area failed (attempt \(attempt)): \(error)")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            }
        }
        return nil
    }

    /// Reads the Rich Text page. `otherChapterShown`: true = the other chapter's paragraph must be on the page (the whole document),
    /// false = it must be absent (zoomed into the quote chapter), nil = not checked.
    func readRichText(_ nodes: [QuoteNode], otherChapterShown: Bool?) -> QuoteReading {
        let leaves: [QuoteLeaf] = nodes.compactMap { node in
            guard node.type == .staticText, let value = node.value else { return nil }
            return QuoteLeaf(value: Self.normalized(value), frame: node.frame)
        }
        var problems = presenceProblems(leaves)
        problems += quoteShapeProblems(leaves)
        problems += closingProblems(leaves)
        if let wanted = otherChapterShown, leaves.contains(where: { $0.value == Self.otherParagraph }) != wanted {
            problems.append(
                wanted
                    ? "the other chapter's paragraph is missing: the whole document is not back"
                    : "the other chapter's paragraph is still on the page: the page is not zoomed into the quote chapter"
            )
        }
        let lines = leaves.enumerated().map { "[\($0.offset)] \"\($0.element.value)\" \(Self.frameText($0.element.frame))" }
        return QuoteReading(problems: problems, dump: lines.isEmpty ? "(no static text in editor-area)" : lines.joined(separator: "\n"))
    }

    /// The quote's two paragraphs must be two separate text runs (a merged paragraph has no run that reads exactly "first"), and the page
    /// must be the rendered quote, not raw Markdown.
    func presenceProblems(_ leaves: [QuoteLeaf]) -> [String] {
        var problems: [String] = []
        if !leaves.contains(where: { $0.value == Self.bodyParagraph }) {
            problems.append("the body paragraph \"\(Self.bodyParagraph)\" is not on the page")
        }
        if !leaves.contains(where: { $0.value == "first" }) {
            problems.append("no text run holds exactly \"first\" (the quote's first paragraph)")
        }
        if !leaves.contains(where: { $0.value == "second" }) {
            problems.append("no text run holds exactly \"second\" (the quote's second paragraph)")
        }
        for leaf in leaves where leaf.value.contains("first") && leaf.value.contains("second") {
            problems.append("the two quote paragraphs are merged into one: a single text run reads \"\(leaf.value)\"")
        }
        let rawMarkers = leaves.filter { $0.value == ">" || $0.value.hasPrefix("> ") }.map(\.value)
        if !rawMarkers.isEmpty {
            problems.append("raw quote markers are on the page \(rawMarkers): this is Markdown text, not the rendered quote")
        }
        return problems
    }

    /// "first" and "second" in document order after the body paragraph, on two separate lines, both indented like a quote.
    func quoteShapeProblems(_ leaves: [QuoteLeaf]) -> [String] {
        let bodyIndex = leaves.firstIndex(where: { $0.value == Self.bodyParagraph })
        let firstIndex = leaves.firstIndex(where: { $0.value == "first" })
        let secondIndex = leaves.firstIndex(where: { $0.value == "second" })
        guard let bodyIndex, let firstIndex, let secondIndex else { return [] }
        var problems: [String] = []
        let body = leaves[bodyIndex].frame
        let first = leaves[firstIndex].frame
        let second = leaves[secondIndex].frame
        if !(bodyIndex < firstIndex && firstIndex < secondIndex) {
            problems.append("the text runs are in the wrong order (body \(bodyIndex), first \(firstIndex), second \(secondIndex))")
        }
        if second.minY < first.maxY - 2 {
            problems.append(
                "\"first\" and \"second\" are not on two separate lines (first \(Self.frameText(first)), second \(Self.frameText(second)))"
            )
        }
        // The quote has a 4 pt left border and 1em of padding; a plain paragraph starts at the body paragraph's left edge.
        let indent: CGFloat = 10
        if first.minX < body.minX + indent {
            problems.append("\"first\" is not indented like a quote (first \(Self.frameText(first)), body \(Self.frameText(body)))")
        }
        if second.minX < body.minX + indent {
            problems.append("\"second\" is not indented like a quote (second \(Self.frameText(second)), body \(Self.frameText(body)))")
        }
        return problems
    }

    /// The paragraph typed after leaving the quote is a plain paragraph, level with the body paragraph: the quote ends after "second".
    func closingProblems(_ leaves: [QuoteLeaf]) -> [String] {
        guard let closing = leaves.first(where: { $0.value == Self.closingParagraph }) else {
            return ["the closing paragraph \"\(Self.closingParagraph)\" is not on the page"]
        }
        guard let body = leaves.first(where: { $0.value == Self.bodyParagraph }) else { return [] }
        if abs(closing.frame.minX - body.frame.minX) > 4 {
            return ["TEST-SETUP: the closing paragraph is indented like the quote, so Return, Return did not leave the quote"]
        }
        return []
    }

    static func frameText(_ frame: CGRect) -> String {
        XCUIApplication.describeFrame(frame)
    }

    /// Polls the page until nothing is wrong or `timeout` passes (frames settle a moment after a layout change, and the tree can be
    /// empty right after a switch); returns the last reading.
    func richTextReading(otherChapterShown: Bool?, timeout: TimeInterval = 20) -> QuoteReading {
        var last = QuoteReading(problems: ["the editor's accessibility tree could not be read"], dump: "(no snapshot)")
        _ = pollUntilTrue(timeout: timeout, pollInterval: 0.5) {
            guard let nodes = readEditorNodes() else { return false }
            last = readRichText(nodes, otherChapterShown: otherChapterShown)
            return last.problems.isEmpty
        }
        return last
    }

    /// The Markdown text of the quote: the lines `> first`, `>`, `> second` one after the other, as separate text runs or inside one
    /// multi-line value or label of any element. Returns whether it was found, how, whether the Markdown editor is mounted, and a
    /// dump. (CodeMirror's H1 line is exposed by some element's value OR label, never reliably as a static text: the mounted check and
    /// the multi-line fallback look at both, as EditorModeSwitchUndoE2ETests does.)
    func readMarkdown(_ nodes: [QuoteNode]) -> MarkdownReading {
        let leafLines: [String] = nodes.compactMap { node in
            guard node.type == .staticText, let value = node.value else { return nil }
            return Self.normalized(value)
        }
        let allTexts: [String] = nodes.flatMap { node in [node.value.map(Self.unified) ?? "", Self.unified(node.label)] }
        let mounted = allTexts.contains(where: { $0.contains(Self.rawHeading) })
        let wanted = ["> first", ">", "> second"]
        let viaLeaves = leafLines.indices.contains(where: { index in
            index + wanted.count <= leafLines.count && Array(leafLines[index..<(index + wanted.count)]) == wanted
        })
        let viaValue = allTexts.contains(where: { $0.contains(Self.expectedQuoteFragment) })
        let mentions = leafLines.enumerated()
            .filter { $0.element.contains(">") || $0.element.contains("first") || $0.element.contains("second") }
            .map { "[\($0.offset)] \"\($0.element)\"" }
        // The shape of any element whose text holds both words (newlines shown as a return sign), for a diagnosis round.
        let bothWords: [String] = allTexts.filter { $0.contains("first") && $0.contains("second") }
        let shapes: [String] = bothWords.map { text in
            let shown = String(text.prefix(300)).replacingOccurrences(of: "\n", with: "\u{23CE}")
            return "\"\(shown)\""
        }
        var dumpLines: [String] = []
        dumpLines.append("static text runs: \(leafLines.count); raw heading \"\(Self.rawHeading)\" present: \(mounted)")
        dumpLines.append("runs mentioning '>', first or second:")
        dumpLines.append(mentions.isEmpty ? "(none)" : mentions.joined(separator: "\n"))
        dumpLines.append("values or labels holding both words:")
        dumpLines.append(shapes.isEmpty ? "(none)" : shapes.joined(separator: "\n"))
        let dump = dumpLines.joined(separator: "\n")
        let via = viaLeaves ? "three consecutive text runs" : (viaValue ? "one multi-line value or label" : "not found")
        return MarkdownReading(found: viaLeaves || viaValue, via: via, mounted: mounted, dump: dump)
    }
}

// MARK: - The four checks

extension QuoteParagraphsSurviveZoomE2ETests {
    func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The quote's rows in the database: one blockquote row, `> first`, `>`, `> second`. Polled, never read once: the page's report
    /// reaches the database through the write queue.
    func quoteRowsInDatabase() -> [String] {
        var rows: [String] = []
        _ = pollUntilTrue(timeout: 20) {
            let sentinel = "###ROWEND###"
            let sql = "SELECT markdownFragment || '\(sentinel)' FROM block WHERE blockType = 'blockquote' ORDER BY sortOrder;"
            let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
            rows = output.components(separatedBy: "\(sentinel)\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return rows == [Self.expectedQuoteFragment]
        }
        return rows
    }

    /// Items 1, 2 and 4: the Rich Text page shows one quote holding two paragraphs (and, unless `checkDatabase` is false, the
    /// database row for the quote is `> first\n>\n> second`).
    func checkRichTextQuote(_ stage: String, otherChapterShown: Bool?, checkDatabase: Bool = true) {
        let reading = richTextReading(otherChapterShown: otherChapterShown)
        // Evidence first: an assertion that ends the test must not be the reason there is no still.
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(reading.dump, name: "\(stage)-editor-text-runs")
        XCTAssertTrue(
            reading.problems.isEmpty,
            "[\(stage)] the Rich Text page does not show one quote holding two paragraphs: \(reading.problems.joined(separator: "; ")).\n"
                + "Text runs on the page:\n\(reading.dump)"
        )
        guard checkDatabase else { return }
        let rows = quoteRowsInDatabase()
        attachText(rows.joined(separator: "\n---\n"), name: "\(stage)-quote-rows")
        XCTAssertEqual(
            rows, [Self.expectedQuoteFragment],
            "[\(stage)] the database must hold exactly one quote row, written with the paragraph break (`> first`, `>`, `> second`)"
        )
    }

    /// Item 3: the Markdown text shows `> first`, a line holding only `>`, then `> second`.
    func checkMarkdownQuote(_ stage: String) {
        var last = readMarkdown([])
        _ = pollUntilTrue(timeout: 20, pollInterval: 0.5) {
            guard let nodes = readEditorNodes() else { return false }
            last = readMarkdown(nodes)
            return last.found
        }
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(last.dump, name: "\(stage)-editor-text-runs")
        XCTAssertTrue(last.mounted, "[\(stage)] the Markdown editor never showed the document's raw heading \"\(Self.rawHeading)\"")
        XCTAssertTrue(
            last.found,
            "[\(stage)] the Markdown text does not show the quote as `> first`, a line holding only `>`, then `> second` "
                + "(found: \(last.via)).\n\(last.dump)"
        )
        let rows = quoteRowsInDatabase()
        attachText(rows.joined(separator: "\n---\n"), name: "\(stage)-quote-rows")
        XCTAssertEqual(
            rows, [Self.expectedQuoteFragment],
            "[\(stage)] the database must hold exactly one quote row, written with the paragraph break (`> first`, `>`, `> second`)"
        )
    }
}
