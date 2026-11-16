//
//  DuplicateSectionKeepsOrderE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE real-app proof for t-bf66e4ee (the permanent proof is the unit tests DuplicateSectionSortOrderRoomTests (Tier 2) and
//  DuplicateSectionSortOrderRoomPrimitivesTests (Tier 1)): Duplicate Section done again and again on a long chapter, and Version
//  History's "Insert as New Section" done again and again, keep every copy's paragraphs in order, with room between saved positions,
//  through a zoom, a switch to Markdown and a reopen.
//
//  The bug it pins: each batch of new rows was squeezed into the room the last one left (room / (rows + 1)), so after about five
//  duplicates of a 100-paragraph chapter two saved positions were closer than 2^-30 (after seven, they tied) and the copy's paragraphs
//  came back in the wrong order the next time the document was loaded (a zoom, a switch to Markdown, a reopen). The fix spreads every
//  saved position out again, inside the same write, when the next copy would get less than 2^-30.
//
//  What a person does here, and what each test proves:
//    1. testEightDuplicatesKeepOrderThroughUndoZoomSwitchAndReopen: Chapter One (100 paragraphs) then Chapter Two. Eight times: right-click
//       the newest card, Duplicate Section (each copy duplicates the copy before it). After every click the database reads back in the
//       chained order and no two saved positions are closer than 2^-30. Then Cmd-Z four times (back through duplicates 8, 7, 6 and 5:
//       the fifth is the one that re-spaces) and Cmd-Shift-Z four times (forward again, the fifth re-spacing once more), the database
//       checked after EVERY press (the order for that many copies, room between positions). Then a double-click on the last copy's card
//       (only that copy, in order), zoom out (the whole document, in order), Cmd-/ to Markdown (the end of the document: the last
//       copy's paragraphs in order, ending at "Paragraph 100." right before Chapter Two), Cmd-/ back, Cmd-Q and a reopen (the page and
//       the database as before). The Cmd-Z presses come right after the eighth duplicate and before the zoom and the switch: both are
//       barriers on the undo timeline (docs/architecture/unified-undo.md), so a Cmd-Z after them would not reach the duplicates.
//       WHAT THE ZOOM, SWITCH AND REOPEN STAGES DO NOT PROVE: they do not prove the fix. A mode switch, a zoom and above all the
//       close at Cmd-Q rewrite the whole document and renumber the saved positions anyway (the close-time check renumbers when two
//       positions are close, `LifecycleWholeDocumentWrite`), so they would pass on the broken code too. The proof is the per-round
//       database checks (after every duplicate, every Cmd-Z and every Cmd-Shift-Z) and the unit tests T1-T6.
//    2. testEightInsertAsNewSectionKeepOrder: the same chapter, then Chapter Two with a footnote, then Notes. Save Version, then eight times
//       Version History > the version > right-click "Chapter One" > Insert as New Section > Restore. The new sections read back in order
//       above the Notes with room between saved positions after every round; the last inserted section zooms, switches to Markdown and back
//       in order.
//
//  How it reads the page and the app (each choice is a recorded e2e-verify lesson, see the skill's "Proven patterns"): editor text lives
//  in `value`, read from ONE `snapshot()` (`editorStaticTextValues()`); the database is read with `sqlite3` through `FixtureDatabase.read`
//  and POLLED (an editor-first command shows on screen at once, its rows follow through the write queue); sidebar cards are scoped to the
//  sidebar's scroll view and clicked by coordinate after being scrolled into the visible band; the clipboard is not used; every wait is a
//  poll with a bound; each stage attaches its still BEFORE its assertions.
//
//  NOT RUN by the coder (compile only): the driver runs it in the VM, `scripts/vmtest/vmtest run --scope
//  "final finalUITests/DuplicateSectionKeepsOrderE2ETests"`.
//

import XCTest

final class DuplicateSectionKeepsOrderE2ETests: XCTestCase {
    var app: XCUIApplication!

    static let paragraphCount = 100
    static let rounds = 8
    /// Cmd-Z presses after the last duplicate (and Cmd-Shift-Z presses after them): back through duplicates 8, 7, 6 and 5.
    static let undoPresses = 4
    static let twoBody = "Two body."

    static func paragraph(_ number: Int) -> String { String(format: "Paragraph %03d.", number) }
    static let paragraphs: [String] = (1...paragraphCount).map(paragraph)

    /// "Chapter One", "Chapter One copy", "Chapter One copy copy", ...
    static func copyTitle(_ generation: Int) -> String { "Chapter One" + String(repeating: " copy", count: generation) }

    static let versionName = "Insert v1"

    /// The first line is a heading (a heading-less seed defeats the readiness checks).
    static let duplicateSeed = (["# Chapter One"] + paragraphs + ["# Chapter Two", twoBody]).joined(separator: "\n\n")

    /// Chapter Two holds a footnote reference and the Notes follow it: "Insert as New Section" puts each new section above the Notes.
    static let insertSeed = (["# Chapter One"] + paragraphs + ["# Chapter Two", "A cited claim.[^1]", "# Notes", "[^1]: The note."])
        .joined(separator: "\n\n")

    /// The document's rows (markdown) after `copies` chained duplicates.
    static func rowsAfterDuplicates(_ copies: Int) -> [String] {
        var rows = ["# Chapter One"] + paragraphs
        for generation in 0..<copies { rows += ["# " + copyTitle(generation + 1)] + paragraphs }
        return rows + ["# Chapter Two", twoBody]
    }

    /// The user's rows (Notes and Bibliography left out) after `inserts` Insert as New Section restores of Chapter One.
    static func rowsAfterInserts(_ inserts: Int) -> [String] {
        var rows = ["# Chapter One"] + paragraphs + ["# Chapter Two", "A cited claim.[^1]"]
        for _ in 0..<inserts { rows += ["# Chapter One"] + paragraphs }
        return rows
    }

    /// The paragraph numbers a page must list: `chapters` runs of 1...100.
    static func numbers(chapters: Int) -> [Int] { (0..<chapters).flatMap { _ in Array(1...paragraphCount) } }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The tests

    func testEightDuplicatesKeepOrderThroughUndoZoomSwitchAndReopen() throws {
        try launch(seed: Self.duplicateSeed)
        for round in 1...Self.rounds {
            try duplicateSection(titled: Self.copyTitle(round - 1), newTitle: Self.copyTitle(round))
            try require(
                checkDuplicateRows(copies: round, stage: "1-after-duplicate-\(round)"),
                "the database is wrong after duplicate \(round) (see the attachments)")
        }

        // Back through duplicates 8, 7, 6 and 5 (the fifth is the one that re-spaces every saved position: 102^-5 < 2^-30), one Cmd-Z at
        // a time, then forward again. The database is checked after EVERY press: the order for that many copies, room between positions.
        for press in 1...Self.undoPresses {
            let copies = Self.rounds - press
            try pressCommandZ(shift: false)
            try require(
                sidebarCard(titled: Self.copyTitle(copies + 1)).waitForDisappearance(timeout: 60),
                "Cmd-Z \(press) did not take the card \"\(Self.copyTitle(copies + 1))\" out of the Outline")
            try require(
                checkDuplicateRows(copies: copies, stage: "2-after-cmd-z-\(press)"),
                "the database is wrong after Cmd-Z \(press) (see the attachments)")
        }
        for press in 1...Self.undoPresses {
            let copies = Self.rounds - Self.undoPresses + press
            try pressCommandZ(shift: true)
            try require(
                sidebarCard(titled: Self.copyTitle(copies)).waitForExistence(timeout: 60),
                "Cmd-Shift-Z \(press) did not bring the card \"\(Self.copyTitle(copies))\" back")
            try require(
                checkDuplicateRows(copies: copies, stage: "3-after-cmd-shift-z-\(press)"),
                "the database is wrong after Cmd-Shift-Z \(press) (see the attachments)")
        }

        try zoomIntoCard(sidebarCard(titled: Self.copyTitle(Self.rounds)), named: Self.copyTitle(Self.rounds))
        checkPage("4-zoomed-into-last-copy", expected: Self.numbers(chapters: 1), twoBody: .absent)
        try zoomOut()
        checkPage("5-zoomed-out", expected: Self.numbers(chapters: Self.rounds + 1), twoBody: .required)

        try switchMode(to: "Markdown")
        try showEndOfMarkdownDocument()
        checkPage("6-markdown-end", expected: nil, twoBody: .required)
        try switchMode(to: "Rich Text")
        checkPage("7-back-in-rich-text", expected: Self.numbers(chapters: Self.rounds + 1), twoBody: .required)

        try quitWithCommandQ()
        softly { _ = checkDuplicateRows(copies: Self.rounds, stage: "8-after-quit") }
        try relaunch()
        checkPage("9-after-reopen", expected: Self.numbers(chapters: Self.rounds + 1), twoBody: .required)
        softly { _ = checkDuplicateRows(copies: Self.rounds, stage: "9-after-reopen") }
    }

    func testEightInsertAsNewSectionKeepOrder() throws {
        try launch(seed: Self.insertSeed)
        try saveVersion(named: Self.versionName)
        for round in 1...Self.rounds {
            try insertChapterOneAsNewSection(round: round)
            try require(
                checkInsertRows(inserts: round, stage: "1-after-insert-\(round)"),
                "the database is wrong after insert \(round) (see the attachments)")
        }

        // The last inserted section is the lowest of the "Chapter One" cards.
        let lastCard = try lowestCard(titled: "Chapter One")
        try zoomIntoCard(lastCard, named: "the last inserted \"Chapter One\"")
        checkPage("2-zoomed-into-last-insert", expected: Self.numbers(chapters: 1), twoBody: .ignored)
        try switchMode(to: "Markdown")
        checkPage("3-zoomed-markdown", expected: nil, twoBody: .ignored)
        try switchMode(to: "Rich Text")
        checkPage("4-zoomed-back-in-rich-text", expected: Self.numbers(chapters: 1), twoBody: .ignored)
        try zoomOut()
        softly { _ = checkInsertRows(inserts: Self.rounds, stage: "5-zoomed-out") }
    }
}

// MARK: - Steps that drive the app

private struct DuplicateE2EStop: Error {}

extension DuplicateSectionKeepsOrderE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without.
    func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw DuplicateE2EStop()
    }

    /// Runs `body` so that a failed assertion inside it is recorded without ending the test.
    func softly(_ body: () -> Void) {
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }
        body()
    }

    /// Polls `probe` every `pollInterval` until it returns true or `timeout` passes; returns the last answer.
    func pollUntilTrue(timeout: TimeInterval, pollInterval: TimeInterval = 0.5, _ probe: () -> Bool) -> Bool {
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

    /// Seeds the project, launches, and waits until the editor shows the document in Rich Text.
    func launch(seed: String) throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seed)
        // macOS inline predictive text can swallow keystrokes (e2e-verify, "Runner environment"): the version name is typed.
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        try waitForSeededDocument()
    }

    func waitForSeededDocument() throws {
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        // The status-bar word count reads "0 words" before the editor exists, so it is no readiness signal: wait for real content.
        let first = Self.paragraph(1)
        try require(
            app.editorStaticText(startingWith: first, exactLine: first, timeout: 60) != nil,
            "TEST-SETUP: the seeded paragraph \"\(first)\" never appeared in the editor")
        try require(
            app.buttons["status-bar-editor-mode"].waitForLabel("== 'Rich Text'", timeout: 10),
            "TEST-SETUP: the document must open in Rich Text mode")
    }

    /// Cmd-Q, then the app is gone.
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

    /// Cmd-Z, or Cmd-Shift-Z with `shift`, with the app brought to the front first.
    func pressCommandZ(shift: Bool) throws {
        try require(app.activateAndWaitForForeground(), "TEST-SETUP: the app is not in the foreground for the key press")
        app.typeKey("z", modifierFlags: shift ? [.command, .shift] : .command)
    }

    /// Cmd-/ until the editor-mode button reports `target`: the keystroke can drop when the app is not in the foreground at the instant it
    /// is sent (proven pattern in EditorModeSwitchUndoE2ETests): re-activate and retry.
    func switchMode(to target: String) throws {
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button did not appear")
        var registered = false
        for _ in 1...5 where !registered {
            if editorMode.label == target {
                registered = true
                continue
            }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            registered = editorMode.waitForLabel("== '\(target)'", timeout: 5)
        }
        try require(registered, "Cmd-/ did not switch the editor to \(target) (the mode button still reads \"\(editorMode.label)\")")
    }

    /// In Markdown mode: the caret to the true end of the document (Cmd-Down on a drawn line), so CodeMirror draws the lines before Chapter Two.
    func showEndOfMarkdownDocument() throws {
        let line = app.editorStaticText(startingWith: "Paragraph", timeout: 30)
        try require(line != nil, "TEST-SETUP: the Markdown page draws no paragraph line to click into")
        if let line { app.moveCaretToDocumentEnd(clickingInto: line) }
        try require(
            pollUntilTrue(timeout: 45) { (self.app.editorStaticTextValues() ?? []).map(Self.normalized).contains(Self.twoBody) },
            "TEST-SETUP: after Cmd-Down the Markdown page never drew \"\(Self.twoBody)\"")
    }
}

// MARK: - The Outline sidebar

extension DuplicateSectionKeepsOrderE2ETests {
    var sidebarScroll: XCUIElement { app.groups["outline-sidebar"].scrollViews.firstMatch }

    /// A sidebar card by its exact title. The title lives in `value`; the query is scoped to the sidebar's scroll view (the editor also
    /// shows each heading, and a zoomed page adds a breadcrumb with the same text).
    func cards(titled title: String) -> XCUIElementQuery {
        sidebarScroll.descendants(matching: .staticText).matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
    }

    func sidebarCard(titled title: String) -> XCUIElement {
        // e2e-lint: allow statictext-firstmatch -- scoped to the sidebar's scroll view and an exact `==` on label or value (no CONTAINS).
        cards(titled: title).firstMatch
    }

    /// The lowest card of that title (every card of a title is a section of that name; the last one is the one lowest in the document).
    func lowestCard(titled title: String) throws -> XCUIElement {
        let query = cards(titled: title)
        var lowest: (index: Int, minY: CGFloat)?
        for index in 0..<query.count {
            let card = query.element(boundBy: index)
            guard card.exists else { continue }
            if lowest.map({ card.frame.minY > $0.minY }) ?? true { lowest = (index, card.frame.minY) }
        }
        let found = try XCTUnwrap(lowest, "TEST-SETUP: the Outline sidebar has no card titled \"\(title)\"")
        return query.element(boundBy: found.index)
    }

    /// Scrolls the sidebar until `card` lies inside its visible band (a card can exist in the tree while clipped, and a coordinate click on
    /// it then lands on nothing). The scroll direction is learned from the first move (proven pattern: WriteQueuePhase4bTraceE2ETests).
    func bringIntoView(_ card: XCUIElement, named name: String) throws {
        let scroll = sidebarScroll
        try require(scroll.waitForExistence(timeout: 30), "TEST-SETUP: the Outline sidebar's scroll view never appeared")
        try require(card.waitForExistence(timeout: 60), "TEST-SETUP: the Outline sidebar has no card \"\(name)\"")
        var direction: CGFloat = 1
        for _ in 1...25 {
            let frame = card.frame
            if scroll.frame.insetBy(dx: 0, dy: 20).contains(frame) { return }
            let wanted = max(-1200, min(1200, frame.midY - scroll.frame.midY))
            scroll.scroll(byDeltaX: 0, deltaY: -wanted * direction)
            app.waitForStableFrame(card)
            // The card should have moved opposite to `wanted`; if it moved the other way the scroll sign is the other one.
            if card.exists, (card.frame.midY - frame.midY) * (-wanted) < 0 { direction = -direction }
        }
        try require(false, "TEST-SETUP: the card \"\(name)\" could not be scrolled into the sidebar's visible band (\(scroll.frame))")
    }

    /// Right-clicks the card `title`, chooses Duplicate Section, and waits for the copy's card.
    func duplicateSection(titled title: String, newTitle: String) throws {
        let card = sidebarCard(titled: title)
        try bringIntoView(card, named: title)
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: "Duplicate Section").click()
        try require(sidebarCard(titled: newTitle).waitForExistence(timeout: 60), "The Outline never showed the card \"\(newTitle)\"")
    }

    /// Double-click on a card (the zoom trigger the suite already uses). Cards are not hittable by design, so the click goes through a
    /// coordinate.
    func zoomIntoCard(_ card: XCUIElement, named name: String) throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        try bringIntoView(card, named: name)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        try require(exitGlyph.waitForExistence(timeout: 30), "The double-click on the card \(name) did not zoom into it")
    }

    func zoomOut() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        // The app disables the glyph while the document is still busy, and a disabled control cannot be clicked: the one bounded wait
        // that gates an action here.
        try require(
            pollUntilTrue(timeout: 30) { exitGlyph.exists && exitGlyph.isEnabled }, "TEST-SETUP: the zoom exit glyph never became enabled")
        exitGlyph.click()
        try require(exitGlyph.waitForDisappearance(timeout: 30), "The click on the zoom exit glyph did not leave the zoom")
    }
}

// MARK: - Save Version and Version History

extension DuplicateSectionKeepsOrderE2ETests {
    /// The sheet of File > Save Version and of the restore confirmation (a sheet, or a dialog on some macOS builds).
    func waitForSheet() -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// File > Save Version (Shift-Cmd-S) with `name`, and the wait for its snapshot row.
    func saveVersion(named name: String) throws {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let sheet = waitForSheet()
        let field = sheet.textFields.firstMatch
        try require(field.waitForExistence(timeout: 10), "TEST-SETUP: the Save Version alert never offered a name field")
        field.click()
        field.typeText(name)
        let save = sheet.buttons["Save"]
        try require(save.waitForExistence(timeout: 10), "TEST-SETUP: the Save Version alert has no Save button")
        save.click()
        let count = "SELECT count(*) FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';"
        try require(
            pollUntilTrue(timeout: 60) { Int(FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: count)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == 1 },
            "TEST-SETUP: the version \"\(name)\" never reached the snapshot table")
    }

    /// The "Selected Version" pane: the window's scroll view furthest to the right.
    func selectedVersionPane(in window: XCUIElement) -> XCUIElement? {
        let panes = window.scrollViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 150 && $0.frame.height > 200 }
        return panes.max { $0.frame.minX < $1.frame.minX }
    }

    /// One round: Version History, the version, right-click "Chapter One" in its preview, Insert as New Section, Restore, and the wait for
    /// the window to close (it closes when the restore reports it is done).
    func insertChapterOneAsNewSection(round: Int) throws {
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        try require(window.waitForExistence(timeout: 90), "TEST-SETUP: round \(round): the Version History window never appeared")

        // e2e-lint: allow statictext-firstmatch -- scoped to the Version History window and an exact `==` on label or value (no CONTAINS).
        let row = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", Self.versionName, Self.versionName)).firstMatch
        try require(row.waitForExistence(timeout: 120), "TEST-SETUP: round \(round): the version never appeared in the list")
        row.click()

        let title = try chapterOneTitleInPreview(window, round: round)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: "Insert as New Section").click()
        let confirm = waitForSheet().buttons["version-history-restore-confirm"]
        try require(confirm.waitForExistence(timeout: 15), "TEST-SETUP: round \(round): the Restore Section confirmation never offered its button")
        confirm.click()
        try require(window.waitForDisappearance(timeout: 180), "TEST-SETUP: round \(round): the Version History window did not close")
    }

    /// The row title "Chapter One" in the selected version's preview, inside the pane's visible band. It is the first section of the
    /// version, so it is at the top; the pane is scrolled up a little when it is not.
    func chapterOneTitleInPreview(_ window: XCUIElement, round: Int) throws -> XCUIElement {
        var pane: XCUIElement?
        _ = pollUntilTrue(timeout: 60) {
            pane = self.selectedVersionPane(in: window)
            return pane != nil
        }
        let found = try XCTUnwrap(pane, "TEST-SETUP: round \(round): the Selected Version pane never appeared")
        // e2e-lint: allow statictext-firstmatch -- scoped to the Version History pane and an exact `==` on label or value (no CONTAINS).
        let titleQuery = found.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Chapter One", "Chapter One"))
        let title = titleQuery.firstMatch
        try require(title.waitForExistence(timeout: 120), "TEST-SETUP: round \(round): the preview shows no \"Chapter One\"")
        for _ in 1...10 where !found.frame.insetBy(dx: 0, dy: 20).contains(title.frame) {
            found.scroll(byDeltaX: 0, deltaY: 480)
            app.waitForStableFrame(title)
        }
        try require(
            found.frame.insetBy(dx: 0, dy: 20).contains(title.frame),
            "TEST-SETUP: round \(round): \"Chapter One\" (\(title.frame)) is outside the preview pane's visible band (\(found.frame))")
        return title
    }
}

// MARK: - Reading the page

extension DuplicateSectionKeepsOrderE2ETests {
    /// What one reading of the page found wrong (empty = nothing wrong), and a dump of what it saw.
    struct PageReading {
        var problems: [String]
        var dump: String
    }

    /// Whether "Two body." must be on the page, must not, or is not looked at.
    enum TwoBodyRule {
        case required
        case absent
        case ignored
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// N for a text run reading exactly "Paragraph NNN.", or nil.
    static func paragraphNumber(_ text: String) -> Int? {
        let prefix = "Paragraph "
        guard text.hasPrefix(prefix), text.hasSuffix("."), text.count == paragraph(1).count else { return nil }
        return Int(text.dropFirst(prefix.count).prefix(3))
    }

    /// The paragraphs a page lists must follow each other: N is followed by N + 1, and 100 by the first paragraph of the next copy.
    static func orderProblem(_ numbers: [Int]) -> String? {
        for (index, pair) in zip(numbers, numbers.dropFirst()).enumerated() {
            let (current, following) = pair
            if following != current + 1 && !(current == paragraphCount && following == 1) {
                return "paragraph \(current) is followed by \(following) (page position \(index + 1)): a copy's paragraphs are out of order"
            }
        }
        return nil
    }

    static func describeDifference(_ numbers: [Int], _ expected: [Int]) -> String {
        let shared = min(numbers.count, expected.count)
        let index = (0..<shared).first { numbers[$0] != expected[$0] } ?? shared
        let got = index < numbers.count ? String(numbers[index]) : "(end)"
        let wanted = index < expected.count ? String(expected[index]) : "(end)"
        return "the page lists \(numbers.count) paragraphs, expected \(expected.count); "
            + "first difference at position \(index): got \(got), expected \(wanted)"
    }

    /// Reads the page once. `expected`: the exact list of paragraph numbers the page must list (nil: whichever lines the editor draws, in
    /// order; CodeMirror draws only the lines near the viewport).
    func readPage(expected: [Int]?, twoBody: TwoBodyRule) -> PageReading? {
        guard let raw = app.editorStaticTextValues() else { return nil }
        let values = raw.map(Self.normalized)
        let numbers = values.compactMap(Self.paragraphNumber)
        var problems: [String] = []
        if numbers.isEmpty { problems.append("no paragraph is on the page") }
        if let expected {
            if numbers != expected { problems.append(Self.describeDifference(numbers, expected)) }
        } else if let problem = Self.orderProblem(numbers) {
            problems.append(problem)
        }
        problems += Self.twoBodyProblems(values, numbers: numbers, rule: twoBody)
        let lines = values.enumerated().map { "[\($0.offset)] \"\($0.element)\"" }
        return PageReading(problems: problems, dump: lines.isEmpty ? "(no static text in editor-area)" : lines.joined(separator: "\n"))
    }

    /// What is wrong with "Two body." on the page: present when it must not be (a zoomed copy), absent when it must be, or a paragraph below
    /// it, or the paragraph before it not the last one of a copy.
    static func twoBodyProblems(_ values: [String], numbers: [Int], rule: TwoBodyRule) -> [String] {
        let closing = values.firstIndex(of: twoBody)
        switch rule {
        case .ignored:
            return []
        case .absent:
            return closing == nil ? [] : ["\"\(twoBody)\" is on the page: the page is not zoomed into the copy"]
        case .required:
            guard let closing else { return ["\"\(twoBody)\" is not on the page"] }
            var problems: [String] = []
            if let lastParagraph = values.lastIndex(where: { paragraphNumber($0) != nil }), lastParagraph > closing {
                problems.append("a paragraph is below \"\(twoBody)\": a copy passed Chapter Two")
            }
            if numbers.last != paragraphCount {
                problems.append("the paragraph before Chapter Two is \(numbers.last.map(String.init) ?? "none"), not \(paragraphCount)")
            }
            return problems
        }
    }

    /// Polls the page until nothing is wrong or the budget passes (the tree can be empty right after a switch, and a long document's
    /// snapshot is slow: the budget is generous), attaches the still FIRST, then asserts softly.
    func checkPage(_ stage: String, expected: [Int]?, twoBody: TwoBodyRule) {
        var last = PageReading(problems: ["the editor's accessibility tree could not be read"], dump: "(no snapshot)")
        _ = pollUntilTrue(timeout: 90, pollInterval: 1) {
            guard let reading = readPage(expected: expected, twoBody: twoBody) else { return false }
            last = reading
            return reading.problems.isEmpty
        }
        attachEvidenceScreenshot(app.screenshot(), name: stage)
        attachText(last.dump, name: "\(stage)-page-text-runs")
        let problems = last.problems.joined(separator: "; ")
        softly { XCTAssertTrue(last.problems.isEmpty, "[\(stage)] the page does not show the paragraphs in order: \(problems)") }
    }
}

// MARK: - The database

extension DuplicateSectionKeepsOrderE2ETests {
    /// The rows' markdown in the order the app assembles them: saved position, a heading before a paragraph at the same position, then
    /// insertion order. Blank rows are left out. `userRowsOnly` leaves out the Notes and Bibliography rows.
    func databaseRows(userRowsOnly: Bool = false) -> [String] {
        let sentinel = "###ROWEND###"
        let filter = userRowsOnly ? "WHERE isNotes = 0 AND isBibliography = 0 AND blockType != 'bibliography' " : ""
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block \(filter)"
            + "ORDER BY sortOrder, CASE WHEN blockType = 'heading' THEN 0 ELSE 1 END, rowid;"
        let output = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return output.components(separatedBy: "\(sentinel)\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// How many adjacent saved positions are closer than 2^-30 (a tie counts). A count in SQL, so no printed number is parsed back. Nil
    /// when the answer is not a number.
    func crowdedGapCount() -> Int? {
        let sql = "SELECT COUNT(*) FROM (SELECT sortOrder - LAG(sortOrder) OVER (ORDER BY sortOrder) AS gap FROM block) "
            + "WHERE gap < 1.0 / 1073741824.0;"
        return Int(FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How many user rows are saved below the Notes heading (0 = every new section went above the Notes). Nil when not a number.
    func userRowsBelowNotes() -> Int? {
        let sql = "SELECT COUNT(*) FROM block WHERE isNotes = 0 AND isBibliography = 0 AND blockType != 'bibliography' "
            + "AND sortOrder > (SELECT MIN(sortOrder) FROM block WHERE isNotes = 1);"
        return Int(FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How many Notes heading rows the project has. `userRowsBelowNotes` is 0 when the Notes are gone altogether (its subquery is NULL),
    /// so a check on it alone would pass on a document that lost its Notes. Nil when not a number.
    func notesHeadingRows() -> Int? {
        let sql = "SELECT COUNT(*) FROM block WHERE isNotes = 1 AND blockType = 'heading';"
        return Int(FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Polls the rows until they are `expected`: the editor changes at once, the rows follow through the write queue. Attaches the rows
    /// and asserts softly (rows, then room); returns whether both held.
    func checkRows(
        _ stage: String, expected: [String], userRowsOnly: Bool, extra: ((inout [String]) -> Void)? = nil
    ) -> Bool {
        var rows = databaseRows(userRowsOnly: userRowsOnly)
        _ = pollUntilTrue(timeout: 90) {
            rows = self.databaseRows(userRowsOnly: userRowsOnly)
            return rows == expected
        }
        let gaps = crowdedGapCount()
        var problems: [String] = []
        if rows != expected {
            let index = zip(rows, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(rows.count, expected.count)
            problems.append(
                "the rows are not in the expected order: \(rows.count) rows, expected \(expected.count); first difference at row \(index): "
                    + "got \"\(index < rows.count ? rows[index] : "(end)")\", expected \"\(index < expected.count ? expected[index] : "(end)")\"")
        }
        if gaps != 0 {
            let count = gaps.map(String.init) ?? "an unreadable number of"
            problems.append("\(count) adjacent saved positions are closer than 2^-30 (or tie)")
        }
        extra?(&problems)
        attachText(rows.joined(separator: "\n"), name: "\(stage)-database-rows")
        softly { XCTAssertTrue(problems.isEmpty, "[\(stage)] \(problems.joined(separator: "; "))") }
        return problems.isEmpty
    }

    func checkDuplicateRows(copies: Int, stage: String) -> Bool {
        checkRows(stage, expected: Self.rowsAfterDuplicates(copies), userRowsOnly: false)
    }

    func checkInsertRows(inserts: Int, stage: String) -> Bool {
        checkRows(stage, expected: Self.rowsAfterInserts(inserts), userRowsOnly: true) { problems in
            if let below = self.userRowsBelowNotes(), below != 0 { problems.append("\(below) user row(s) are saved below the Notes heading") }
            if (self.notesHeadingRows() ?? 0) < 1 { problems.append("the Notes heading row is gone (no row with isNotes = 1 and blockType heading)") }
        }
    }
}
