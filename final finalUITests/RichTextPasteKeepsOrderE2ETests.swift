//
//  RichTextPasteKeepsOrderE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression test for t-75d20927: in Rich Text, pasting (or typing) many paragraphs in one spot keeps them in order, in
//  front of the paragraph that followed, through a zoom, a switch to Markdown and a quit.
//
//  The bug it pins: each inserted paragraph is saved halfway between the paragraph it follows and the next saved position, so a paste of
//  about 50 or more paragraphs ran out of room between two positions and the end of the paste tied with, or passed, the paragraph that
//  followed it. Nothing looked wrong until the document was loaded again (a zoom, a switch to Markdown, a reopen), which then showed
//  the last pasted paragraphs below "Two closing.". The fix keeps room between positions for every Rich Text save, and keeps a zoom's
//  boundaries on the same paragraphs when it does.
//
//  Why this is a permanent UI test and not a unit one: the unit tests (RichTextSortOrderSpacingTests) drive the writer with 200
//  inserts; only the running app proves what the real editor sends for a paste (paragraphs that follow one another, each placed
//  after the one before; how many reports carry them is the page's business) and that the reloads a zoom, a mode switch and a quit
//  do read the right rows (the quit while zoomed is where a stale zoom range would write the paste twice or cut into the next chapter).
//
//  What a person does here, and what each test proves:
//    1. testPasteInMiddleKeepsOrderThroughZoomAndSwitch: three chapters; click at the end of "Two body.", Return, paste 80 paragraphs
//       ("Pasted 01." to "Pasted 80.", blank line between them). The page, and the database, show them in order, then "Two closing.".
//       Zoom into Chapter Two (double-click its Outline card): same order, the other chapters' text absent, "Two closing." present.
//       Zoom out: same order. Cmd-/ to Markdown: the lines in order before "Two closing.". Cmd-/ back: same order.
//    2. testZoomedPasteThenQuitKeepsEachParagraphOnce: zoom into Chapter Two, paste the same 80 after "Two body.", then Cmd-Q at once.
//       The database holds each "Pasted NN." exactly once, in order, "Two closing." after "Pasted 80.", and the other chapters
//       unchanged. Reopened, the page shows the same.
//       WHAT THIS TEST DOES NOT PROVE: it passes with OR without the re-spacing guard. A VM run with the guard switched off in
//       `applyAndConfirm` still passed it, because the quit rewrites the zoomed chapter from the page's own text, whatever the
//       saved positions were. So it guards the zoomed-paste-then-quit flow as a whole, but it is NOT the proof that the zoom range
//       follows a re-spacing. That proof is the unit tests in RichTextSortOrderSpacingTests: T5 (`zoomRangeFollowsTheRespacing`), T6
//       (`zoomedCloseAfterRespacingReplacesExactlyTheChapter`), the two-paste close test
//       (`closeAfterTwoRespacedPastesReplacesExactlyTheChapter`) and the zoomed-range-write test
//       (`zoomedRangeWriteAfterARespacingReplacesExactlyTheChapter`).
//
//  How it reads the page (every choice is a recorded e2e-verify lesson, see the skill's "Proven patterns"):
//    - Editor text lives in `value`; the page is read from ONE `snapshot()` (`editorStaticTextValues()`), never per element.
//    - The database is read with `sqlite3` through `FixtureDatabase.read`, polled with a bound (the page's report reaches the database
//      through the write queue), ordered like the app orders rows (position, a heading before a paragraph at the same position).
//      "No two rows share a position" is read as a count, not parsed from printed numbers.
//    - The paste text goes on the clipboard right before EVERY Cmd-V (the clipboard is shared with the host and can be overwritten
//      between a copy and the paste: E2ESectionReconcilerPseudoSectionTests, "Phase 7").
//    - Each stage attaches its still BEFORE its assertions, and the stages are checked softly so one run says which of them fail.
//    - Waits are polls with a bound that return the moment the condition holds. No fixed sleeps.
//

import AppKit
import XCTest

final class RichTextPasteKeepsOrderE2ETests: XCTestCase {
    var app: XCUIApplication!

    static let pasteCount = 80
    static let twoBody = "Two body."
    static let twoClosing = "Two closing."

    static func pasted(_ number: Int) -> String { String(format: "Pasted %02d.", number) }

    static let pastedLines: [String] = (1...pasteCount).map(pasted)

    /// Eighty paragraphs separated by blank lines, the way copied prose arrives.
    static let clipboardText: String = pastedLines.joined(separator: "\n\n")

    /// The first line is a heading (a heading-less seed defeats the readiness checks). Three chapters at the same level, so each has
    /// its own Outline card to double-click.
    static let seedMarkdown = """
    # Chapter One

    One body.

    # Chapter Two

    Two body.

    Two closing.

    # Chapter Three

    Three body.
    """

    /// What the database must hold, in document order, after the paste (blank rows left out).
    static let expectedRows: [String] =
        ["# Chapter One", "One body.", "# Chapter Two", twoBody] + pastedLines + [twoClosing, "# Chapter Three", "Three body."]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // macOS inline predictive text can swallow keystrokes (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The tests

    func testPasteInMiddleKeepsOrderThroughZoomAndSwitch() throws {
        try waitForSeededDocument()
        try pasteAfterTwoBody()

        softly { checkRichText("1-after-paste", chapterOneShown: true, chapterThreeShown: true) }

        try zoomIntoChapterTwo()
        softly { checkRichText("2-zoomed-in", chapterOneShown: false, chapterThreeShown: false) }
        try zoomOut()
        softly { checkRichText("3-zoomed-out", chapterOneShown: true, chapterThreeShown: true) }

        try switchMode(to: "Markdown")
        softly { checkMarkdown("4-markdown") }
        try switchMode(to: "Rich Text")
        softly { checkRichText("5-back-in-rich-text", chapterOneShown: true, chapterThreeShown: true) }
    }

    // Passes with OR without the re-spacing guard (the quit rewrites the zoomed chapter from the page text): it guards this flow as a
    // whole, and is NOT the proof that the zoom range follows a re-spacing. See the header, and RichTextSortOrderSpacingTests.
    func testZoomedPasteThenQuitKeepsEachParagraphOnce() throws {
        try waitForSeededDocument()
        try zoomIntoChapterTwo()
        try pasteAfterTwoBody()
        // At once: no wait for the page's report to reach the database, no check of the zoom first. What the quit saves is the whole point.
        try quitWithCommandQ()

        let rows = databaseRows()
        attachText(rows.joined(separator: "\n"), name: "after-quit-database-rows")
        XCTAssertEqual(
            rows, Self.expectedRows,
            "After Cmd-Q the database must hold each pasted paragraph exactly once, in order, between \"\(Self.twoBody)\" and "
                + "\"\(Self.twoClosing)\", with the other chapters unchanged"
        )
        XCTAssertEqual(duplicatedSortOrders(), 0, "After Cmd-Q no two rows may share a saved position")

        try relaunch()
        softly { checkRichText("after-reopen", chapterOneShown: true, chapterThreeShown: true) }
    }
}

// MARK: - Steps that drive the app

private struct StopTest: Error {}

extension RichTextPasteKeepsOrderE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without. (The stage checks
    /// are soft and never use this.)
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

    func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func waitForSeededDocument() throws {
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        // The status-bar word count reads "0 words" before the editor exists, so it is no readiness signal: wait for real content.
        try require(
            app.editorStaticText(startingWith: Self.twoBody, exactLine: Self.twoBody, timeout: 30) != nil,
            "TEST-SETUP: the seeded paragraph \"\(Self.twoBody)\" never appeared in the editor"
        )
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForLabel("== 'Rich Text'", timeout: 10), "TEST-SETUP: the document must open in Rich Text mode")
    }

    /// Caret to the end of "Two body.", Return, then the eighty paragraphs from the clipboard. The paste is confirmed by the page showing
    /// its last line (one snapshot per poll). A paste that is only slow is not repeated: before pasting again, the first pasted line is looked
    /// for on the page and in the database, and when it is there the earlier paste is waited for instead; only a paste that left no trace
    /// is made again, with the clipboard written again first.
    func pasteAfterTwoBody() throws {
        let caret = app.placeCaretByClicking(paragraphStartingWith: Self.twoBody, atEnd: true, exactLine: Self.twoBody)
        try require(
            caret.confirmed,
            "TEST-SETUP: the caret could not be placed at the end of \"\(Self.twoBody)\" (probe: \(caret.probe)); attempts: \(caret.attempts)"
        )
        app.typeKey(.return, modifierFlags: [])
        let last = Self.pasted(Self.pasteCount)
        var landed = false
        for attempt in 1...3 where !landed {
            if attempt > 1, firstPastedLineIsThere() {
                landed = pollUntilTrue(timeout: 20, pollInterval: 0.25) { pageValues().contains(last) }
                continue
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.clipboardText, forType: .string)
            app.activateAndWaitForForeground()
            app.typeKey("v", modifierFlags: .command)
            landed = pollUntilTrue(timeout: 10, pollInterval: 0.25) { pageValues().contains(last) }
        }
        try require(landed, "TEST-SETUP: after three pastes the page never showed \"\(last)\"")
    }

    /// Whether the first pasted paragraph is on the page or in the database: some paste has landed, however late.
    func firstPastedLineIsThere() -> Bool {
        let first = Self.pasted(1)
        return pageValues().contains(first) || databaseRows().contains(first)
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
    func zoomIntoChapterTwo() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        let card = sidebarCard(titled: "Chapter Two")
        try require(card.waitForExistence(timeout: 15), "TEST-SETUP: the Outline sidebar has no card titled \"Chapter Two\"")
        let visibleBand = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        try require(
            visibleBand.contains(card.frame),
            "TEST-SETUP: the \"Chapter Two\" card (\(card.frame)) is outside the sidebar's visible band (\(visibleBand))"
        )
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        try require(exitGlyph.waitForExistence(timeout: 20), "The double-click on the \"Chapter Two\" card did not zoom into it")
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
    /// reliably in the foreground at the instant it is sent (proven pattern in EditorModeSwitchUndoE2ETests): re-activate and retry.
    func switchMode(to target: String) throws {
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button did not appear")
        var registered = false
        for _ in 1...5 {
            if editorMode.label == target {
                registered = true
                break
            }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== '\(target)'", timeout: 5) {
                registered = true
                break
            }
        }
        try require(registered, "Cmd-/ did not switch the editor to \(target) (the mode button still reads \"\(editorMode.label)\")")
    }

    /// Cmd-Q, then the app is gone. Fails the test if it is still running after the wait.
    func quitWithCommandQ() throws {
        app.activateAndWaitForForeground()
        app.typeKey("q", modifierFlags: .command)
        try require(app.wait(for: .notRunning, timeout: 180), "The app was still running 180 s after Cmd-Q")
    }

    /// Starts the app again on the same project and waits until the editor shows the document.
    func relaunch() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        try waitForSeededDocument()
    }
}

// MARK: - Reading the page

extension RichTextPasteKeepsOrderE2ETests {
    /// What one reading of the page found wrong (empty = nothing wrong), and a dump of what it saw.
    struct PageReading {
        var problems: [String]
        var dump: String
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// N for a text run reading exactly "Pasted NN.", or nil.
    static func pastedNumber(_ text: String) -> Int? {
        let prefix = "Pasted "
        guard text.hasPrefix(prefix), text.hasSuffix("."), text.count == pasted(1).count else { return nil }
        return Int(text.dropFirst(prefix.count).prefix(2))
    }

    /// Every static-text value of the editor, normalized, in document order, from ONE snapshot. Empty when the tree cannot be read.
    func pageValues() -> [String] {
        (app.editorStaticTextValues() ?? []).map(Self.normalized)
    }

    /// Reads the page once. `allPasted`: every one of the eighty lines must be on it (the Rich Text page lists the whole document);
    /// false = whichever lines the editor draws are enough (CodeMirror draws only the lines near the viewport). `chapterOneShown` /
    /// `chapterThreeShown`: whether that chapter's paragraph must be on the page (nil = not checked). `closingRequired`: whether
    /// "Two closing." must be on the page; when it is there it must come after every pasted line either way.
    func readPage(
        allPasted: Bool, closingRequired: Bool, chapterOneShown: Bool?, chapterThreeShown: Bool?
    ) -> PageReading? {
        guard let raw = app.editorStaticTextValues() else { return nil }
        let values = raw.map(Self.normalized)
        var problems = pastedLineProblems(values, allPasted: allPasted)
        problems += neighbourProblems(values, closingRequired: closingRequired)
        for (text, shown) in [("One body.", chapterOneShown), ("Three body.", chapterThreeShown)] {
            if let shown, values.contains(text) != shown {
                problems.append(shown ? "\"\(text)\" is missing: the whole document is not on the page"
                                      : "\"\(text)\" is on the page: the page is not zoomed into Chapter Two")
            }
        }
        let lines = values.enumerated().map { "[\($0.offset)] \"\($0.element)\"" }
        return PageReading(problems: problems, dump: lines.isEmpty ? "(no static text in editor-area)" : lines.joined(separator: "\n"))
    }

    /// The pasted lines on the page: some, in strictly increasing order, and (when `allPasted`) all eighty.
    func pastedLineProblems(_ values: [String], allPasted: Bool) -> [String] {
        let numbers = values.compactMap(Self.pastedNumber)
        var problems: [String] = []
        if numbers.isEmpty { problems.append("no pasted line is on the page") }
        if zip(numbers, numbers.dropFirst()).contains(where: { $0 >= $1 }) {
            problems.append("the pasted lines are out of order on the page: \(numbers)")
        }
        let missing = Set(1...Self.pasteCount).subtracting(numbers)
        if allPasted, !missing.isEmpty, let first = missing.min() {
            problems.append("\(missing.count) of the \(Self.pasteCount) pasted lines are not on the page (the first missing is \(first))")
        }
        return problems
    }

    /// "Two body." comes before the first pasted line, "Two closing." after the last one.
    func neighbourProblems(_ values: [String], closingRequired: Bool) -> [String] {
        let pastedIndices = values.indices.filter { Self.pastedNumber(values[$0]) != nil }
        var problems: [String] = []
        if let body = values.firstIndex(of: Self.twoBody), let first = pastedIndices.first, first < body {
            problems.append("a pasted line is above \"\(Self.twoBody)\"")
        }
        if let closing = values.firstIndex(of: Self.twoClosing) {
            if let last = pastedIndices.last, last > closing {
                problems.append("a pasted line is below \"\(Self.twoClosing)\": the end of the paste passed the paragraph that followed it")
            }
        } else if closingRequired {
            problems.append("\"\(Self.twoClosing)\" is not on the page")
        }
        return problems
    }

    /// Polls the page until nothing is wrong or `timeout` passes (the tree can be empty right after a switch, and a long document's
    /// snapshot is slow: the budget is generous); returns the last reading.
    func settledReading(
        allPasted: Bool, closingRequired: Bool, chapterOneShown: Bool?, chapterThreeShown: Bool?, timeout: TimeInterval = 45
    ) -> PageReading {
        var last = PageReading(problems: ["the editor's accessibility tree could not be read"], dump: "(no snapshot)")
        _ = pollUntilTrue(timeout: timeout, pollInterval: 0.5) {
            guard let reading = readPage(
                allPasted: allPasted, closingRequired: closingRequired, chapterOneShown: chapterOneShown,
                chapterThreeShown: chapterThreeShown) else { return false }
            last = reading
            return reading.problems.isEmpty
        }
        return last
    }
}

// MARK: - The database

extension RichTextPasteKeepsOrderE2ETests {
    /// The rows' markdown in the order the app assembles them: saved position, a heading before a paragraph at the same position, then
    /// insertion order. Blank rows (the empty paragraph a Return can leave) are left out.
    func databaseRows() -> [String] {
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block "
            + "ORDER BY sortOrder, CASE WHEN blockType = 'heading' THEN 0 ELSE 1 END, rowid;"
        let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return output.components(separatedBy: "\(sentinel)\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// How many rows share a saved position with another row (0 = every position is its own). A count in SQL, so no printed number is
    /// parsed back. Nil when the answer is not a number.
    func duplicatedSortOrders() -> Int? {
        let output = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath, sql: "SELECT COUNT(*) - COUNT(DISTINCT sortOrder) FROM block;")
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - The stage checks

extension RichTextPasteKeepsOrderE2ETests {
    /// The database after a stage: the rows read in the expected order, and no two rows share a saved position. Polled, never read
    /// once: the page's report reaches the database through the write queue.
    func checkDatabase(_ stage: String) {
        var rows = databaseRows()
        _ = pollUntilTrue(timeout: 45, pollInterval: 0.5) {
            rows = databaseRows()
            return rows == Self.expectedRows
        }
        attachText(rows.joined(separator: "\n"), name: "\(stage)-database-rows")
        XCTAssertEqual(
            rows, Self.expectedRows,
            "[\(stage)] the database must hold \"\(Self.twoBody)\", the eighty pasted paragraphs in order, then \"\(Self.twoClosing)\", "
                + "with the other chapters unchanged"
        )
        XCTAssertEqual(duplicatedSortOrders(), 0, "[\(stage)] no two rows may share a saved position")
    }

    /// A Rich Text stage: the page lists all eighty lines in order between "Two body." and "Two closing." (and shows, or does not show,
    /// the other chapters), and the database agrees.
    func checkRichText(_ stage: String, chapterOneShown: Bool, chapterThreeShown: Bool) {
        let reading = settledReading(
            allPasted: true, closingRequired: true, chapterOneShown: chapterOneShown, chapterThreeShown: chapterThreeShown)
        // Evidence first: an assertion that ends the test must not be the reason there is no still.
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(reading.dump, name: "\(stage)-page-text-runs")
        XCTAssertTrue(
            reading.problems.isEmpty,
            "[\(stage)] the Rich Text page does not show the pasted paragraphs in order: \(reading.problems.joined(separator: "; ")).\n"
                + "Text runs on the page:\n\(reading.dump)"
        )
        checkDatabase(stage)
    }

    /// The Markdown stage: whichever pasted lines CodeMirror draws are in order and above "Two closing." (it draws only the lines near
    /// the viewport, so the whole list cannot be demanded), and the database agrees.
    func checkMarkdown(_ stage: String) {
        let reading = settledReading(allPasted: false, closingRequired: false, chapterOneShown: nil, chapterThreeShown: nil)
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(reading.dump, name: "\(stage)-page-text-runs")
        XCTAssertTrue(
            reading.problems.isEmpty,
            "[\(stage)] the Markdown page does not show the pasted lines in order before \"\(Self.twoClosing)\": "
                + "\(reading.problems.joined(separator: "; ")).\nText runs on the page:\n\(reading.dump)"
        )
        checkDatabase(stage)
    }
}
