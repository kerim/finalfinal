//
//  SidebarWordCountsE2ETests.swift
//  final finalUITests
//
//  t-58d64b34: the Outline sidebar's word counts are now taken in ONE walk over the block rows (`ProjectDatabase.batchWordCounts`, read
//  after every saved change) instead of one walk per heading. The numbers on the cards must not have changed. The unit tests
//  (`BatchWordCountsOnePassTests`) prove the new counts equal the old function's on the committed fixtures and on a generated
//  5,000-block document; only the running app shows that the whole chain still ends in the right number on the card: the real parser
//  writing the block rows, the real publisher reading them in one read, the sidebar drawing the numbers, and the real editor's typing
//  reaching the cards.
//
//  What a card shows (SectionCardView / SectionViewModel.wordCountDisplay): its section's own words, from the heading line to the next
//  heading of ANY level (a parent's number does not hold its sub-sections), as a bare number; or, when the section has an AGGREGATE
//  goal, "Σ ~N/goal" where N counts the section and every sub-section under it, up to the next heading of the same or a higher level.
//
//  The document is six chapters, each a one-word heading and one short paragraph, so every number can be worked out from the text:
//      # Alpha    (1 word) + "Alpha prelude text sits here." (5)
//      ## Beta    (1) + "Beta body text goes right here now." (7)
//      ### Gamma  (1) + "Gamma is a one line text of nine words." (9)
//      ## Delta   (1) + "Delta text keeps going for eleven words in this one paragraph." (11)
//      # Epsilon  (1) + "Epsilon opens the second part with thirteen words that are plain and short." (13)
//      ## Zeta    (1) + "Zeta closes the whole document with exactly fifteen simple words placed right at the end." (15)
//
//  Method testCardsShowTheRightCountsAndTypingMovesOnlyTheRightCards. A person:
//    1. opens the document (first launch). With no goals set every card shows its own section's words: Alpha 6, Beta 8, Gamma 10,
//       Delta 12, Epsilon 14, Zeta 16. Alpha, Beta and Epsilon are parents, and their numbers do NOT hold their sub-sections.
//    2. gives Alpha, Beta, Delta and Epsilon an aggregate goal and reopens the document (the goals are written into the block rows
//       between the two launches, with the app closed: the app has no other way to set a goal short of a popover). Now Alpha shows
//       Σ 36 (6+8+10+12: three levels deep, ends at the next Part), Beta Σ 18 (8+10: stops at its sibling Delta), Delta Σ 12 (stops at
//       the next Part), Epsilon Σ 30 (14+16: runs to the end of the document); Gamma 10 and Zeta 16 stay plain numbers.
//    3. clicks to the end of Gamma's paragraph, presses Return and types a four-word line. Gamma goes to 14, Beta (its parent) to
//       Σ 22 and Alpha (its grandparent) to Σ 40; Delta, Epsilon and Zeta do not change. The reading is polled (the page reports the
//       typing, the write queue saves it, the publisher reads it, the sidebar draws it), never read once.
//
//  Every number is read from the screen: one accessibility snapshot of the sidebar's scroll view per reading; each card's label is the
//  numeric static text that sits below its title. The expected numbers are hand-worked from the text above, never read from the app. A
//  TEST-SETUP check also reads the parsed block rows and compares each block's stored word count with the hand count (a heading is one
//  word, each paragraph its own), so a slip in the hand count is told apart from a wrong sidebar.
//
//  Evidence (attached before each assertion): a screenshot of the sidebar at each of the three readings and the reading as text.
//
//  Every wait below has a bound. No fixed sleeps.
//

import XCTest

private struct WordCountStop: Error {}

final class SidebarWordCountsE2ETests: XCTestCase {
    var app: XCUIApplication!
    /// The text of the sidebar's last accessibility snapshot, attached when the cards never read as expected.
    var lastSnapshotTree = ""

    // MARK: - The document, and what each card must show

    struct Chapter {
        let title: String
        let level: Int
        let body: String
        /// Hand-counted: the words of `body` (the heading is one word).
        let bodyWords: Int
    }

    static let chapters: [Chapter] = [
        Chapter(title: "Alpha", level: 1, body: "Alpha prelude text sits here.", bodyWords: 5),
        Chapter(title: "Beta", level: 2, body: "Beta body text goes right here now.", bodyWords: 7),
        // Gamma's paragraph is where the test clicks to type, so it must fit ONE visual line of the editor (about 400 pt wide in the VM,
        // room for roughly 41 characters): the caret probe of `placeCaretByClicking` selects one visual line and counts its words.
        // The first VM run (run-1794811501-91346) used a 64-character sentence that wrapped, and the probe read "3 of 66 words".
        Chapter(title: "Gamma", level: 3, body: "Gamma is a one line text of nine words.", bodyWords: 9),
        Chapter(title: "Delta", level: 2, body: "Delta text keeps going for eleven words in this one paragraph.", bodyWords: 11),
        Chapter(title: "Epsilon", level: 1, body: "Epsilon opens the second part with thirteen words that are plain and short.", bodyWords: 13),
        Chapter(
            title: "Zeta", level: 2,
            body: "Zeta closes the whole document with exactly fifteen simple words placed right at the end.", bodyWords: 15
        )
    ]

    static var seedMarkdown: String {
        chapters.map { "\(String(repeating: "#", count: $0.level)) \($0.title)\n\n\($0.body)" }.joined(separator: "\n\n")
    }

    /// What a card's label says: the number, and whether it is the aggregate form ("Σ ~36/9999").
    struct Shown: Equatable, CustomStringConvertible {
        let number: Int
        let aggregate: Bool
        var description: String { aggregate ? "Sigma \(number)" : "\(number)" }
    }

    /// Launch 1, no goals: each card's own section (heading plus paragraph). 1+5, 1+7, 1+9, 1+11, 1+13, 1+15.
    static let sectionOnlyShown: [String: Shown] = [
        "Alpha": Shown(number: 6, aggregate: false), "Beta": Shown(number: 8, aggregate: false),
        "Gamma": Shown(number: 10, aggregate: false), "Delta": Shown(number: 12, aggregate: false),
        "Epsilon": Shown(number: 14, aggregate: false), "Zeta": Shown(number: 16, aggregate: false)
    ]

    /// The chapters that get an aggregate goal between the launches.
    static let aggregateGoalTitles = ["Alpha", "Beta", "Delta", "Epsilon"]
    static let aggregateGoal = 9999

    /// Launch 2, aggregate goals on Alpha, Beta, Delta, Epsilon: Alpha 6+8+10+12, Beta 8+10, Delta 12, Epsilon 14+16.
    static let aggregateShown: [String: Shown] = [
        "Alpha": Shown(number: 36, aggregate: true), "Beta": Shown(number: 18, aggregate: true),
        "Gamma": Shown(number: 10, aggregate: false), "Delta": Shown(number: 12, aggregate: true),
        "Epsilon": Shown(number: 30, aggregate: true), "Zeta": Shown(number: 16, aggregate: false)
    ]

    static let typedLine = "quietly orbiting lanterns glow"
    static let typedWords = 4

    /// After the four words typed at the end of Gamma's paragraph: Gamma +4, its parent Beta +4, its grandparent Alpha +4; no other card.
    static let afterTypingShown: [String: Shown] = [
        "Alpha": Shown(number: 40, aggregate: true), "Beta": Shown(number: 22, aggregate: true),
        "Gamma": Shown(number: 14, aggregate: false), "Delta": Shown(number: 12, aggregate: true),
        "Epsilon": Shown(number: 30, aggregate: true), "Zeta": Shown(number: 16, aggregate: false)
    ]

    // MARK: - Set up

    override func setUpWithError() throws {
        // Each phase's evidence is worth having even when an earlier phase's numbers were wrong, so a failed number does not stop the
        // test; a step the rest cannot run without throws WordCountStop instead (`require`).
        continueAfterFailure = true
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // Fast typing into the WKWebView editor: the inline predictive-text feature can swallow keystrokes (e2e-verify, "Runner
        // environment"), and autocorrect would change the typed words.
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO", "-NSAutomaticSpellingCorrectionEnabled", "NO",
                                "-NSAutomaticTextReplacementEnabled", "NO"]
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The method

    func testCardsShowTheRightCountsAndTypingMovesOnlyTheRightCards() throws {
        for chapter in Self.chapters {
            XCTAssertEqual(
                chapter.body.split(separator: " ").count, chapter.bodyWords,
                "TEST-SETUP: the hand count of \(chapter.title)'s paragraph is wrong"
            )
        }
        XCTAssertEqual(Self.typedLine.split(separator: " ").count, Self.typedWords, "TEST-SETUP: the hand count of the typed line is wrong")
        // The caret probe reads ONE visual line, so the paragraph the test clicks (Gamma's) must not wrap: "Opening paragraph about the
        // privacy test." (41 characters) is the longest line the same probe has been proven on in this editor width.
        let gammaLength = Self.chapters.first(where: { $0.title == "Gamma" })?.body.count ?? 0
        XCTAssertLessThanOrEqual(
            gammaLength, 41, "TEST-SETUP: Gamma's paragraph is too long to stay on one visual line, so the caret probe cannot read it"
        )
        do {
            try readSectionOnlyCountsOnFirstLaunch()
            try reopenWithAggregateGoalsAndReadThem()
            try typeIntoGammaAndReadAgain()
        } catch is WordCountStop {
            // `require` already recorded the failure and its evidence.
        }
    }
}

// MARK: - The three phases

extension SidebarWordCountsE2ETests {
    /// Phase 1: the first launch parses the seeded markdown into block rows; with no goals every card shows its own section's words.
    private func readSectionOnlyCountsOnFirstLaunch() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        let outcome = waitForSidebar(toShow: Self.sectionOnlyShown, timeout: 60)
        attachEvidenceScreenshot(app.screenshot(), name: "1-sidebar-no-goals")
        attachText("1-sidebar-no-goals-reading", outcome.report)
        assertCards(outcome, equal: Self.sectionOnlyShown, phase: "first launch, no goals (each card's own section)")

        // TEST-SETUP: the parsed block rows hold the hand-counted words (heading 1, paragraph its own).
        let wanted = Self.chapters.flatMap { ["heading|\($0.level)|1", "paragraph||\($0.bodyWords)"] }
        let rows = blockRows()
        attachText("1-block-rows", rows.joined(separator: "\n"))
        XCTAssertEqual(rows, wanted, "TEST-SETUP: the parsed block rows (blockType|headingLevel|wordCount) are not the hand-counted ones")
        try require(rows.count >= wanted.count, "TEST-SETUP: the first launch did not write all \(wanted.count) block rows (found \(rows.count))")
    }

    /// Phase 2: with the app closed, the aggregate goals are written into the block rows; the reopened document shows the aggregates.
    private func reopenWithAggregateGoalsAndReadThem() throws {
        app.terminate() // never write to the fixture database while the app holds it open
        let titles = Self.aggregateGoalTitles.map { "'\(FixtureDatabase.escape($0))'" }.joined(separator: ", ")
        FixtureDatabase.write(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "UPDATE block SET aggregateGoal = \(Self.aggregateGoal), aggregateGoalType = 'approx' "
                + "WHERE blockType = 'heading' AND textContent IN (\(titles));"
        )
        let goalsSet = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT count(*) FROM block WHERE aggregateGoal = \(Self.aggregateGoal);"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(
            goalsSet == "\(Self.aggregateGoalTitles.count)",
            "TEST-SETUP: expected \(Self.aggregateGoalTitles.count) heading rows to take the aggregate goal, the database says \(goalsSet)"
        )

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear after the reopen")
        let outcome = waitForSidebar(toShow: Self.aggregateShown, timeout: 60)
        attachEvidenceScreenshot(app.screenshot(), name: "2-sidebar-aggregate-goals")
        attachText("2-sidebar-aggregate-goals-reading", outcome.report)
        assertCards(outcome, equal: Self.aggregateShown, phase: "reopened with aggregate goals on Alpha, Beta, Delta, Epsilon")
    }

    /// Phase 3: four words typed at the end of Gamma's paragraph move Gamma, its parent and its grandparent by exactly four, and nothing else.
    private func typeIntoGammaAndReadAgain() throws {
        guard let gamma = Self.chapters.first(where: { $0.title == "Gamma" }) else { throw WordCountStop() }
        // The status-bar word count reads "0 words" before the editor exists, so it is no readiness signal: wait for real content.
        try require(
            app.editorStaticText(startingWith: gamma.body, exactLine: gamma.body, timeout: 30) != nil,
            "TEST-SETUP: Gamma's paragraph never appeared in the editor"
        )
        try require(
            app.buttons["status-bar-editor-mode"].waitForLabel("== 'Rich Text'", timeout: 10),
            "TEST-SETUP: the document must open in Rich Text mode"
        )
        let caret = app.placeCaretByClicking(paragraphStartingWith: gamma.body, atEnd: true, exactLine: gamma.body)
        try require(caret.confirmed, "TEST-SETUP: the caret could not be placed at the end of Gamma's paragraph (probe: \(caret.probe))")
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded(Self.typedLine)

        let saved = waitForDatabase(containing: Self.typedLine, timeout: 45)
        attachText("3-typed-line-in-database", "reached the database: \(saved)\nblock rows now:\n" + blockRows().joined(separator: "\n"))

        let outcome = waitForSidebar(toShow: Self.afterTypingShown, timeout: 60)
        attachEvidenceScreenshot(app.screenshot(), name: "3-sidebar-after-typing")
        attachText("3-sidebar-after-typing-reading", outcome.report)
        assertCards(outcome, equal: Self.afterTypingShown, phase: "after typing \(Self.typedWords) words at the end of Gamma's paragraph")
    }
}

// MARK: - Reading the sidebar

/// One static text of the sidebar's accessibility snapshot: every string it exposes (value and label) and its frame.
private struct SidebarText {
    let candidates: [String]
    let frame: CGRect
}

/// One word-count label found in the snapshot: what it reads, the text it was read from, and its frame.
private struct SidebarCount {
    let shown: SidebarWordCountsE2ETests.Shown
    let raw: String
    let frame: CGRect
}

/// One reading of the Outline: what each expected card's word-count label shows, and the evidence text.
private struct SidebarReading {
    var shown: [String: SidebarWordCountsE2ETests.Shown] = [:]
    var report = ""
}

/// What polling the sidebar ended with: the last reading (nil when no snapshot could ever be taken) and the evidence text.
private struct SidebarOutcome {
    let reading: SidebarReading?
    let report: String
}

extension SidebarWordCountsE2ETests {
    /// The strings a word-count label can read: "36", or "Σ ~36/9999" (a section with an aggregate goal).
    private static func countText(from text: String) -> Shown? {
        let form = "^(\u{03A3} )?[~\u{2265}\u{2264}]?[0-9]+(/[0-9]+)?$"
        guard text.range(of: form, options: .regularExpression) != nil else { return nil }
        let digits = text.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        guard let number = Int(digits) else { return nil }
        return Shown(number: number, aggregate: text.hasPrefix("\u{03A3}"))
    }

    private static func collectStaticTexts(in node: XCUIElementSnapshot, into found: inout [SidebarText]) {
        for child in node.children {
            if child.elementType == .staticText {
                let candidates = [child.value as? String, child.label].compactMap { $0 }.filter { !$0.isEmpty }
                if !candidates.isEmpty { found.append(SidebarText(candidates: candidates, frame: child.frame)) }
            }
            collectStaticTexts(in: child, into: &found)
        }
    }

    /// The whole snapshot as indented text (type, frame, identifier, label, value): attached when the cards do not read as expected.
    private static func describeTree(_ node: XCUIElementSnapshot, depth: Int = 0) -> String {
        let value = (node.value as? String).map { "\"\($0)\"" } ?? String(describing: node.value)
        let line = String(repeating: "  ", count: depth)
            + "type=\(node.elementType.rawValue) \(describeFrame(node.frame)) id=\"\(node.identifier)\" label=\"\(node.label)\" value=\(value)"
        return ([line] + node.children.map { describeTree($0, depth: depth + 1) }).joined(separator: "\n")
    }

    private static func describeFrame(_ frame: CGRect) -> String {
        "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
    }

    /// One reading, from ONE accessibility snapshot of the sidebar's scroll view (the cards' titles and numbers are plain static texts
    /// there; the editor's own copy of each heading is outside it). Each expected title is found by its exact text, and its number is the
    /// nearest count-shaped static text at or below the title and above the next title. nil when no snapshot could be taken.
    private func readSidebar() -> SidebarReading? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard let snapshot = try? scroll.snapshot() else { return nil }
        var texts: [SidebarText] = []
        Self.collectStaticTexts(in: snapshot, into: &texts)

        var titles: [(title: String, frame: CGRect)] = []
        for chapter in Self.chapters {
            if let match = texts.filter({ $0.candidates.contains(chapter.title) }).min(by: { $0.frame.minY < $1.frame.minY }) {
                titles.append((chapter.title, match.frame))
            }
        }
        titles.sort { $0.frame.minY < $1.frame.minY }
        let counts = texts.compactMap { text -> SidebarCount? in
            for candidate in text.candidates {
                if let shown = Self.countText(from: candidate) { return SidebarCount(shown: shown, raw: candidate, frame: text.frame) }
            }
            return nil
        }

        var reading = SidebarReading()
        var lines: [String] = []
        for (index, entry) in titles.enumerated() {
            let ceiling = index + 1 < titles.count ? titles[index + 1].frame.minY : CGFloat.greatestFiniteMagnitude
            let own = counts.filter { $0.frame.minY >= entry.frame.minY && $0.frame.minY < ceiling }
                .min(by: { $0.frame.minY < $1.frame.minY })
            if let own { reading.shown[entry.title] = own.shown }
            let label = own.map { "\"\($0.raw)\" -> \($0.shown)" } ?? "none found"
            lines.append("\(entry.title): title \(Self.describeFrame(entry.frame)); label \(label)")
        }
        let missing = Self.chapters.map(\.title).filter { title in !titles.contains { $0.title == title } }
        if !missing.isEmpty { lines.append("no card title found for: \(missing.joined(separator: ", "))") }
        reading.report = lines.joined(separator: "\n") + "\n--- every static text of the sidebar ---\n"
            + texts.map { "\(Self.describeFrame($0.frame)) \($0.candidates)" }.joined(separator: "\n")
        lastSnapshotTree = Self.describeTree(snapshot)
        return reading
    }

    /// Polls the sidebar until every expected card reads as expected, or `timeout` passes. Returns the last reading and the evidence text.
    private func waitForSidebar(toShow expected: [String: Shown], timeout: TimeInterval) -> SidebarOutcome {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last: SidebarReading?
        var attempts = 0
        repeat {
            attempts += 1
            last = readSidebar() ?? last
            if let last, last.shown == expected {
                return SidebarOutcome(reading: last, report: "matched on reading \(attempts)\n" + last.report)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        let tree = lastSnapshotTree.isEmpty ? "(no snapshot could be taken)" : lastSnapshotTree
        let report = "NOT matched after \(attempts) readings\n" + (last?.report ?? "(no reading)") + "\n--- last snapshot tree ---\n" + tree
        return SidebarOutcome(reading: last, report: report)
    }

    /// One assertion per card, so the failure names the card, what it showed and what the text works out to.
    private func assertCards(
        _ outcome: SidebarOutcome, equal expected: [String: Shown], phase: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for chapter in Self.chapters {
            XCTAssertEqual(
                outcome.reading?.shown[chapter.title], expected[chapter.title],
                "\(phase): the card \"\(chapter.title)\" shows a different number than the text works out to. Full reading:\n\(outcome.report)",
                file: file, line: line
            )
        }
    }
}

// MARK: - Small helpers

extension SidebarWordCountsE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without.
    private func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw WordCountStop()
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text.isEmpty ? "(none)" : text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The block rows in document order, one string per row: "blockType|headingLevel|wordCount" (the level is empty for a paragraph).
    private func blockRows() -> [String] {
        FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT blockType || '|' || ifnull(headingLevel, '') || '|' || wordCount FROM block ORDER BY sortOrder;"
        ).split(separator: "\n").map(String.init)
    }

    /// True once a block's stored markdown holds `text` (polled with a bound: the write queue saves behind the typing).
    private func waitForDatabase(containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let stored = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: "SELECT markdownFragment FROM block;")
            if stored.contains(text) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }
}
