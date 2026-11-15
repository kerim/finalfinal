//
//  ReturnBackspaceLeavesNoStrayRowE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE real-app proof for t-80274c66: in Rich Text, a paragraph made with Return and removed again with Backspace before the
//  page has sent its insert leaves no row in the database, through a zoom in and a zoom out.
//
//  The bug it pins: the page's report folded a paragraph's insert and its delete into ONE report (it kept the insert of a block whose
//  delete arrived), the database applies a report's deletes BEFORE its inserts, so the delete found no row and the insert then made one:
//  an empty paragraph the editor no longer had. It showed after a zoom or a reopen as a blank paragraph after the one that had been
//  typed in. Two lines of defence now stop it: the page cancels the unsent insert and drops the delete (report-outbox.ts `applyOps`),
//  and the database takes out any insert whose own delete is in the same batch (`ProjectDatabase.cancellingInsertsDeletedInSameBatch`).
//
//  WHAT THIS TEST PROVES, AND WHAT IT DOES NOT: it fails only when BOTH defences are removed (either one alone already stops the stray
//  row). The vitest file report-outbox-insert-delete.test.ts (the page side) and RichTextInsertDeleteSameReportTests (the database side)
//  are the proof for each defence on its own; this test guards the flow a person actually does: real keystrokes in the real editor, the
//  real report timing, the real writer, then the reloads a zoom does.
//
//  What a person does here, and what each stage proves:
//    1. Click at the end of a body paragraph, type `x`, then ten times Return and Backspace at a steady pace, then ` done.`. The database
//       is polled (bounded) until the paragraph's row reads `... x done.`. Because reports reach the database in order, every report
//       the Returns and Backspaces made has been applied by then. The rows must be exactly the seeded ones with that one paragraph
//       extended, and the row count (empty rows counted too) must be what it was before the typing.
//    2. Zoom into the chapter from the Outline sidebar (double-click its card): the same rows, the same count.
//    3. Zoom out (the status-bar exit glyph): the same rows, the same count.
//
//  Why the report interval is stretched: `FF_UI_TESTING_REPORT_INTERVAL_MS=3000` (TestMode.uiTestingReportIntervalMs, read by the page's
//  document-start script) makes the page hold a report for 3 s after the previous one. The user's own steps hit the bug because a word
//  is typed first: that typing report leaves at once, the next one waits for the interval, and a Return and Backspace pressed inside
//  that wait go into one report. (A Return pressed after a pause is posted at once, and its delete then goes out by its temp id: never
//  buggy.) The UI driver's keystrokes are slower than a person's, so the wider interval keeps the Return's insert unsent when the
//  Backspace's delete is detected. A Return/Backspace pair that straddles a report boundary is sent as an insert and, later, its delete
//  by temp id: it leaves no stray row either way, so the check does not depend on where the boundaries fall. Without the fixes the
//  cycles that do not straddle one each leave an empty row.
//
//  How it reads the app (each choice is a recorded e2e-verify lesson, see the skill's "Proven patterns"):
//    - The database is read with `sqlite3` through `FixtureDatabase.read`, polled with a bound (the page's report reaches the database
//      through the write queue), ordered like the app orders rows; the count comes from SQL, so nothing printed is parsed back except
//      two integers.
//    - The caret goes to the paragraph's end through the confirmed helper (`placeCaretByClicking`), never a blind offset click.
//    - Each stage attaches its still BEFORE its assertions, and the stages are checked softly so one run says which of them fail.
//    - No underscores or asterisks are typed (Milkdown's input rules turn typed `_x_` / `*x*` into italic).
//

import XCTest

final class ReturnBackspaceLeavesNoStrayRowE2ETests: XCTestCase {
    var app: XCUIApplication!

    static let bodyParagraph = "Body paragraph for the Return test."
    static let secondParagraph = "Second body paragraph."
    static let otherParagraph = "Other chapter paragraph."
    static let chapterTitle = "First Chapter"
    static let cycles = 10
    /// A person's pace between two keys; also keeps the Return's insert (detected within 100 ms) pending when the Backspace follows.
    static let keyPause: TimeInterval = 0.3

    /// The first line is a heading (a heading-less seed defeats the readiness checks).
    static let seedMarkdown = """
    # Stray Row Test Document

    ## First Chapter

    Body paragraph for the Return test.

    Second body paragraph.

    ## Second Chapter

    Other chapter paragraph.
    """

    /// The body paragraph after the typing: `x`, ten Returns each undone by a Backspace, then ` done.`.
    static let typedBodyRow = bodyParagraph + "x done."

    /// What the database must hold, in document order, after the typing (blank rows left out, and counted separately).
    static let expectedRows: [String] = [
        "# Stray Row Test Document", "## First Chapter", typedBodyRow, secondParagraph, "## Second Chapter", otherParagraph
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // macOS inline predictive text can swallow keystrokes (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        // The page holds a report for 3 s after the previous one (see the header): the Return's insert is still unsent when the
        // Backspace's delete is detected. Set before launchForTesting, which adds its own variables and keeps these.
        app.launchEnvironment["FF_UI_TESTING_REPORT_INTERVAL_MS"] = "3000"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The test

    func testReturnThenBackspaceLeavesNoStrayRowThroughZoom() throws {
        try waitForSeededDocument()
        let before = try settledRowCounts()
        attachText("rows before the typing: total \(before.total), empty \(before.empty)", name: "0-row-counts-before")

        try typeReturnBackspaceCycles()
        try waitForTypedRowInDatabase()

        softly { checkRows("1-after-typing", before: before) }

        try zoomIntoChapter()
        softly { checkRows("2-zoomed-in", before: before) }
        try zoomOut()
        softly { checkRows("3-zoomed-out", before: before) }
    }
}

// MARK: - Steps that drive the app

private struct StopTest: Error {}

extension ReturnBackspaceLeavesNoStrayRowE2ETests {
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
            app.editorStaticText(startingWith: Self.bodyParagraph, exactLine: Self.bodyParagraph, timeout: 30) != nil,
            "TEST-SETUP: the seeded body paragraph never appeared in the editor"
        )
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForLabel("== 'Rich Text'", timeout: 10), "TEST-SETUP: the document must open in Rich Text mode")
    }

    /// Caret to the end of the body paragraph, `x`, then ten times Return and Backspace at a steady pace, then ` done.`. The typing
    /// goes through `typeText` and the pairs through `typeKey`; the result is read from the database, not from the page (the page is
    /// right either way: the bug is in what the page reports).
    func typeReturnBackspaceCycles() throws {
        let caret = app.placeCaretByClicking(
            paragraphStartingWith: Self.bodyParagraph, atEnd: true, exactLine: Self.bodyParagraph
        )
        try require(
            caret.confirmed,
            "TEST-SETUP: the caret could not be placed at the end of the body paragraph (probe: \(caret.probe)); attempts: \(caret.attempts)"
        )
        // `typeTextVerifyingLanded` is for text on an otherwise empty line (its repair clears the whole line); this text is appended
        // to a paragraph, and the database poll below is what shows it landed.
        // e2e-lint: allow raw-typetext -- appended to an existing paragraph, where the landing helper's repair would clear the line.
        app.typeText("x")
        for _ in 1...Self.cycles {
            app.typeKey(.return, modifierFlags: [])
            pause(Self.keyPause)
            app.typeKey(.delete, modifierFlags: [])
            pause(Self.keyPause)
        }
        // e2e-lint: allow raw-typetext -- appended to an existing paragraph, where the landing helper's repair would clear the line.
        app.typeText(" done.")
    }

    /// One person-paced gap between two keys (a run-loop turn, not a thread sleep: the app and the test runner keep processing).
    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The reports reach the database in order, so once the row carries the last thing typed, every earlier report has been applied.
    func waitForTypedRowInDatabase() throws {
        try require(
            pollUntilTrue(timeout: 45, pollInterval: 0.5) { databaseRows().contains(Self.typedBodyRow) },
            "The database never held the body paragraph as \"\(Self.typedBodyRow)\" (rows now: \(databaseRows()))"
        )
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
    func zoomIntoChapter() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        let card = sidebarCard(titled: Self.chapterTitle)
        try require(card.waitForExistence(timeout: 15), "TEST-SETUP: the Outline sidebar has no card titled \"\(Self.chapterTitle)\"")
        let visibleBand = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        try require(
            visibleBand.contains(card.frame),
            "TEST-SETUP: the \"\(Self.chapterTitle)\" card (\(card.frame)) is outside the sidebar's visible band (\(visibleBand))"
        )
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        try require(exitGlyph.waitForExistence(timeout: 20), "The double-click on the \"\(Self.chapterTitle)\" card did not zoom into it")
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
}

// MARK: - The database

/// How many rows the block table holds, and how many of them are blank (the stray row an Enter leaves is blank).
struct StrayRowCounts: Equatable {
    let total: Int
    let empty: Int
}

extension ReturnBackspaceLeavesNoStrayRowE2ETests {
    /// The rows' markdown in the order the app assembles them: saved position, a heading before a paragraph at the same position, then
    /// insertion order. Blank rows are left out (they are counted by `rowCounts`).
    func databaseRows() -> [String] {
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block "
            + "ORDER BY sortOrder, CASE WHEN blockType = 'heading' THEN 0 ELSE 1 END, rowid;"
        let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return output.components(separatedBy: "\(sentinel)\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The total and the blank count, both counted in SQL. Nil when the answer is not two numbers.
    func rowCounts() -> StrayRowCounts? {
        let sql = "SELECT COUNT(*) || '|' || COALESCE(SUM(CASE WHEN trim(markdownFragment) = '' THEN 1 ELSE 0 END), 0) FROM block;"
        let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count == 2, let total = Int(parts[0]), let empty = Int(parts[1]) else { return nil }
        return StrayRowCounts(total: total, empty: empty)
    }

    /// The counts once the freshly opened document has been written: two reads 0.7 s apart agree and the table is not empty.
    func settledRowCounts() throws -> StrayRowCounts {
        var previous: StrayRowCounts?
        var settled: StrayRowCounts?
        _ = pollUntilTrue(timeout: 30, pollInterval: 0.7) {
            let now = rowCounts()
            defer { previous = now }
            if let now, now.total > 0, now == previous {
                settled = now
                return true
            }
            return false
        }
        return try XCTUnwrap(settled, "TEST-SETUP: the block table never settled before the typing (last read: \(String(describing: previous)))")
    }

    /// The database after a stage: the rows are the seeded ones with the body paragraph extended, and the row count (blank rows
    /// included) is what it was before the typing. Polled, never read once: the page's report reaches the database through the write
    /// queue. The still is attached before the assertions.
    func checkRows(_ stage: String, before: StrayRowCounts) {
        var rows = databaseRows()
        var counts = rowCounts()
        _ = pollUntilTrue(timeout: 20, pollInterval: 0.5) {
            rows = databaseRows()
            counts = rowCounts()
            return rows == Self.expectedRows && counts == before
        }
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(
            "total \(counts.map { String($0.total) } ?? "unreadable"), empty \(counts.map { String($0.empty) } ?? "unreadable")"
                + " (before: total \(before.total), empty \(before.empty))\n" + rows.joined(separator: "\n"),
            name: "\(stage)-rows"
        )
        XCTAssertEqual(
            counts, before,
            "[\(stage)] the block table must hold as many rows as before the typing, blank ones included: a Return removed again by a "
                + "Backspace before its insert was sent must leave no row"
        )
        XCTAssertEqual(
            rows, Self.expectedRows,
            "[\(stage)] the database must hold the seeded rows with only the body paragraph extended to \"\(Self.typedBodyRow)\""
        )
    }
}
