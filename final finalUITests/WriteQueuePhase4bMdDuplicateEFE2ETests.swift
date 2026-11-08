//
//  WriteQueuePhase4bMdDuplicateEFE2ETests.swift
//  final finalUITests
//
//  bt task t-a0fc657e / t-b0fb31ae, PHASE 4b MARKDOWN SLICE 3, ROUND D: DUPLICATE SECTION IN MARKDOWN MODE, EDITOR FIRST, proven in the real app.
//  Until this slice a Markdown Duplicate read the text out of the page, saved it, copied the rows, built the whole document again and
//  pushed it back over the editor (`setContent len=... anchorCount=0`): the push carried no `<!-- @sid:ID -->` section markers, so the copy's
//  Outline card landed 2600 points away (10 scroll rounds), typing around the click could be lost, and every Cmd-Z / Cmd-Shift-Z showed
//  "Undoing..." / "Redoing...". Now the page inserts the copy in ONE dispatch (Swift minted the copy's section ids first and the page wrote
//  them into the copy's markers), a queued job copies the rows behind anything typed, and Cmd-Z / Cmd-Shift-Z are quick. The design record
//  is .claude/superdev/write-queue-phase4b-markdown-duplicate/ (plan-v1.md step 3, plan-v1-addendum.md the test table, judge-plan-verdicts.md,
//  premise-check.md = what TODAY's code does); the claim-to-test map is
//  docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/e2e-mapping.md.
//
//  CLASS NAME: after the TASK (vmtest's retry-refusal streak is keyed by class and method name across worktrees). The class inherits the
//  harness of WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`: launch, seeding, the app-log follower, the sidebar driving, the
//  evidence writer) and uses the pure helpers of WriteQueuePhase4bDeleteFlowE2ETests.swift (`Phase4bFlow`, `Phase4bFlowRow`,
//  `Phase4bFlowWalk`, `Phase4bFlowSoftChecks`), `Phase4bQuLog` and the static seeds `withPlainLines` / `withSectionBreaks`
//  (WriteQueuePhase4bStructuralQueueE2ETests.swift); it changes nothing in any of them. The behaviour classes' own INSTANCE helpers live in
//  THEIR final classes and cannot be reused, so the few this class needs are copied here as private methods prefixed `mdDup` (DEBT: the
//  same copies exist in WriteQueuePhase4bRedoE2ETests, WriteQueuePhase4bMarkdownEFE2ETests and WriteQueuePhase4bStructuralQueueE2ETests;
//  moving them into the harness is a clean-up for a later task, not this one). It is ONE new permanent file (scripts/e2e-hygiene.sh allows
//  one per branch), so it disables the file-length rule like every other Phase 4b e2e file.
//
//  THE DOCUMENTS (generated, never a manuscript; every note starts with the fixture tag `[<size> W<words> S<sections> C<citation groups>
//  F<footnote marks> L<characters>]`):
//    article  x1 chapter:   58,764 characters, 68 citation groups,   9 footnote marks
//    book6    x6 chapters: 349,810 characters, 408 citation groups,  54 footnote marks
//    book12   x12 chapters: 699,139 characters, 816 citation groups, 108 footnote marks
//  Chapter n of a book is "# Chapter n: The Quiet Archive and Its Ledgers", then sections "## n.1 Ledgers and Their Keepers", "## n.2 The Village
//  Registers" (holds footnote references 3 and 4 of its chapter), "## n.3 Prices at the Market", "## n.4 Bridges and Boundaries",
//  "## n.5 Lanterns After Dark" (each with two "###" sub-sections) and the closing "## n.6 Conclusion" (FOOTNOTE-FREE: its Duplicate needs
//  no footnote renumber, so the Cmd-Z / Cmd-Shift-Z counts are exact). Two plain lines "Dup01 / Dup02 line of the fixture document." are seeded
//  under the heading a test duplicates; the copy repeats them, which is how a landing place on the page is recognised.
//
//  WHAT A CARD CLICK "LANDS ON THE COPY" MEANS HERE: after ONE click on the copy's Outline card the test scrolls NOTHING itself (`rounds=0`)
//  and looks (a condition, bounded) for the seeded Dup01 line fully inside the editor's visible band and in its upper 60 percent; it then
//  clicks the end of that line and the status bar (its outline button names the section the caret is in) must read the copy's title. Today
//  the same click lands 2600 points away and the line is never on screen.
//
//  THE TESTS (each says what it claims, what TODAY's code does, and a one-line BREAK idea; map: e2e-mapping.md)
//    E1   testMdDupCopyAtOnceCardLandsOnCopy_book12      FAILS today (10 scroll rounds)   copy card click lands, rounds=0, at once and settled
//    E2   testMdDupTypeDuringClick_book12                FAILS today (predicted)          typing before and after the click is kept
//    E3   testMdDupUndoRedoQuickNoToast_book6            FAILS today ("Undoing...")       2 cycles quick, same ids; Cmd-Shift-Z right after Cmd-Z
//    E4   testMdDupTypeInCopyUndoRedoPutBack_book6       CONTROL (passes today)           typing inside the copy comes back after undo / redo
//    E5   testMdDupUndoScrollShowsCaret_book6            CONTROL                          the caret line is on screen after Cmd-Z (Markdown)
//    E5RT testRtDupUndoScrollShowsCaret_book6            CONTROL                          the same in Rich Text; the two positions are compared
//    E6   testMdDupDeleteThenDupHeldUndoUndo_book6       FAILS today (slow route)         Delete, Duplicate, Cmd-Z x2: both quick
//    E7   testMdDupFootnotedChapter_book6                FAILS today (mechanism, toasts)  footnoted + cited section, no waits; Notes unchanged
//    E8   testMdDupLastChapterBeforeNotes_book12         mechanism line only (reported)   the copy lands before Notes / Bibliography
//    E9   testMdDupSectionBreakRoot_book6                FAILS today (no markers)         a section-break root: no suffix, click lands on copy
//    E10  testMdDupTiming_book12                         REPORT (mechanism line only)     click to copy on screen, click to rows
//    E11  testMdDupChapterWithSubsections_book12         FAILS today                      the copied SUB-section card lands in the copy
//    E12  testMdDupSameSectionTwiceAtOnce_book6          FAILS today (mechanism)          END-STATE of two Duplicates in a row: page = Outline = rows
//    E13  testMdDupThenDeleteCopyAtOnceUndoTwice_book6   FAILS today (slow route)         Duplicate, Delete the copy at once, Cmd-Z x2 quick
//    E14  testMdDupTypeInCopyThenCloseAtOnceReopen_book6 CONTROL (reported either way)    type in the copy, Cmd-W at once, reopen
//    E15  testMdDupSaveVersionAtOnce_book6               mechanism line only (reported)   Save Version at once; the copy is in it once; click lands
//
//  WAITS: every wait is a CONDITION (a log line, a database row, the sidebar, the accessibility tree, a status-bar label); the keys of one
//  cycle are pressed straight after each other. Typing is user-origin (typeText / typeKey). Rows are read from the block table only after a
//  poll, never straight after a command. NO ASSERTION says "the click arrives within N ms of a held job" (the UI driver needs 7 to 10 s for
//  one right-click plus menu click on a book): where a job hold is switched on (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS` 3500, under the 4 s
//  limit) it only makes a pending job likely on a fast host, and what is asserted is the end state. A typed line longer than about 40
//  characters WRAPS in the VM's editor column, so a typed sentence is looked for in the joined text of the editor's runs.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; several --scope flags make one run, never a comma list; the scope is
//  `final finalUITests/WriteQueuePhase4bMdDuplicateEFE2ETests/<method>`; compare the number of `Test Case ... passed` lines with the
//  number of scopes after every run):
//    scripts/vmtest/vmtest run --detach --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bMdDuplicateEFE2ETests/testMdDupUndoRedoQuickNoToast_book6"
//

// swiftlint:disable file_length
import AppKit
import XCTest

// MARK: - Small value types of this class

/// One Cmd-Z or Cmd-Shift-Z as the editor's own `[UnifiedUndo] keydown` line reports it, with the wait for its `performed` line.
struct MdDupPress {
    let number: Int
    let redo: Bool
    /// `fallthrough` (a plain text step of the editor's own history), `structural`, `swallow` (held behind a running one), or `none` when the
    /// editor wrote no keydown line within 15 s (the key reached no editor).
    let decision: String
    let undoDepth: Int?
    let redoDepth: Int?
    /// For a structural or held press: its `performed` line arrived.
    let performed: Bool
    /// Every distinct toast message the accessibility tree showed in the 1.2 s after the key (empty when not watched).
    var toasts: [String] = []

    var isStructural: Bool { decision == "structural" || decision == "swallow" }

    var summary: String {
        "press \(number) (\(redo ? "redo" : "undo")): \(decision), undo depth \(undoDepth.map(String.init) ?? "n/a"), "
            + "redo depth \(redoDepth.map(String.init) ?? "n/a")" + (isStructural ? (performed ? ", performed" : ", NOT performed") : "")
    }
}

/// One row of the block table with its id.
struct MdDupIdRow {
    let id: String
    let row: Phase4bFlowRow
}

/// Where a card click put the page: the Dup line found, how far from the editor's top it is (0 is the top edge, 1 the bottom edge), and
/// how many leaves with that text were fully on screen.
struct MdDupLanding {
    let leaf: XCUIElement
    /// The leaf's frame AT THE MOMENT it was found. The `leaf` element is an index into a query (`element(boundBy: n)`); once the caret has
    /// moved and the page has redrawn, index n can point at nothing and reading `leaf.frame` then aborts the test with "Failed to get
    /// matching snapshot: No matches found for Element at index n" (round-1 failure of E1). Later arithmetic uses this value, not the element.
    let frame: CGRect
    let topFraction: CGFloat
    let visibleCount: Int
}

/// Where the Dup line sat once the page had settled (`mdDupSettledLineTop`): its top in points below the editor band's top edge (nil: not
/// fully on screen), the whole series of readings as text, and the band's height.
struct MdDupLineTop {
    let top: CGFloat?
    let series: String
    let editorHeight: CGFloat
}

/// Every soft failure of the running test, in ONE place the test class can read: the budget-exhausted path prints what failed so far.
final class MdDupSoftLog {
    var failures: [String] = []
}

/// `Phase4bFlowSoftChecks` with a copy of every failure written to the test's `MdDupSoftLog` (a reference, so the log outlives the
/// struct copies passed `inout` to the helpers).
struct MdDupSoft {
    private(set) var failures: [String] = []
    let log: MdDupSoftLog

    init(log: MdDupSoftLog) { self.log = log }

    mutating func check(_ holds: Bool, _ message: @autoclosure () -> String) {
        guard !holds else { return }
        let text = message()
        failures.append(text)
        log.failures.append(text)
    }
}

// MARK: - The test class

/// Duplicate Section in Markdown mode, editor first. See the file header.
final class WriteQueuePhase4bMdDuplicateEFE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// How many versions this test has saved (each needs its own name).
    var versionSaves = 0
    /// What the last `mdDupPlaceCaret` read from the status bar, round by round (for a failure message).
    var landingReads: [String] = []
    /// The soft failures collected so far by this test (see `MdDupSoft`).
    let softLog = MdDupSoftLog()

    static let dupLineOne = "Dup01 line of the fixture document."
    static let dupLineTwo = "Dup02 line of the fixture document."
    static let subLine = "Sub01 line of the fixture document."
    static let anchorLine = Phase4bDelHarness.anchorPrefix + " line of the fixture document."
    static let anchorSixLine = "Anchor06 line of the fixture document."
    /// The typed sentence: short, no character the editor transforms (no quote, dash, asterisk, underscore, slash, bracket).
    static let sentence = "Typed in the copy."
    /// Words with no character the editor transforms.
    static let phraseOne = "KEPTMDONE"
    static let phraseTwo = "KEPTMDTWO"
    static let subMarker = "SUBMARKCOPY"
    static let orderMarkerA = "ORDERMARKA"
    static let orderMarkerB = "ORDERMARKB"
    static let breakMarker = "BREAKMARKCOPY"
    /// The section duplicated in most tests: footnote-free (a Duplicate of it needs no footnote renumber).
    static let conclusion = "3.6 Conclusion"
    static let holdKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_MS"
    /// The writer holds every queued structural job this long (under the 4 s limit of a hold that blocks the writer).
    static let jobHoldMs = 3_500
    /// The most presses a polled loop makes: the text steps of any typing the test did (a slow host splits one typed sentence into several
    /// undo groups), then the structural press. It only bounds a failing run. A footnote renumber's own step is no longer allowed for: since
    /// t-f1a22aa7 (Phase 4c) the footnote burst timer stands aside while a command is unfinished, and `testMdDupFootnotedChapter_book6`, which
    /// types nothing, asserts exactly one press for its undo and one for its redo.
    static let pressCap = 6
    /// A landing counts as "on the copy" when the Dup line lies in the upper part of the editor's band (the card click scrolls the copy's
    /// heading to the top; the Dup line is right under it).
    static let landingTopFraction: CGFloat = 0.6
    static let versionName = "Md dup base"

    static func chapter(_ number: Int) -> String { "Chapter \(number): The Quiet Archive and Its Ledgers" }

    /// The seed hook: the two Dup lines (or `lines`) as their own paragraphs directly under the heading `title` of level `level`.
    static func dupSeed(under title: String, level: Int, lines: [String]? = nil) -> (Phase4bDoc) -> Phase4bDoc {
        { generated in
            WriteQueuePhase4bStructuralQueueE2ETests.withPlainLines(
                generated, under: title, level: level,
                lines: lines ?? [WriteQueuePhase4bMdDuplicateEFE2ETests.dupLineOne, WriteQueuePhase4bMdDuplicateEFE2ETests.dupLineTwo])
        }
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// Begins the method, seeds, launches the document with the given seams, reads the saved document, logs the fixture counts, and (for
    /// `markdown`) switches the editor to Markdown with Cmd-/. False after a reported failure.
    func mdDupStart(
        _ size: Phase4bDelSize, method: String, env: [String: String] = [:], markdown: Bool = true,
        seed: ((Phase4bDoc) -> Phase4bDoc)? = nil
    ) -> Bool {
        begin(method: method, size: size)
        if let seed, let current = doc {
            let seeded = seed(current)
            doc = seeded
            note("SEED: a seed hook was applied; \(seeded.counts.reportLine)")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            app.launchEnvironment[key] = value
            note("SEAM \(key)=\(value)")
        }
        guard launchScenario() else { return false }
        pre = mdDupReadRows()
        tail.poll()
        evidenceLogStart = tail.lines.count
        let walk = Phase4bFlowWalk(rows: pre)
        guard walk.problems.isEmpty else {
            fail("the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        let counts = "COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), "
            + "\(walk.definitions.count) footnote definition(s), \(citations) citation bracket(s) in the rows, "
            + "\(pre.filter(\.isNotes).count) Notes row(s), \(pre.filter(\.isBibliography).count) Bibliography row(s), "
            + "\(sectionsInDatabase) section row(s)"
        note(counts)
        attachText("fixture-counts-\(methodName).txt", "\(fixtureTag)\n\(counts)")
        guard !markdown || mdDupSwitchMode(to: "Markdown") else { return false }
        startedAt = Date()
        return true
    }

    /// Switches the editor to `wanted` ("Markdown" or "Rich Text") with Cmd-/ (the View menu's "Switch to ..." item), pressed ONCE, then
    /// waits for the badge (a condition) and, for Markdown, for the page itself (`waitForMarkdownPageReady`: the badge flips before the
    /// page exists, t-55b63c87).
    func mdDupSwitchMode(to wanted: String) -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        if mode.label != wanted {
            app.activateAndWaitForForeground()
            tail.poll()
            let switchFrom = tail.lines.count
            app.typeKey("/", modifierFlags: .command)
            let modeTimeout = mdDupAppWait(size.operationTimeout * 2, before: "the mode button reads \(wanted)")
            guard mode.waitForLabel("== '\(wanted)'", timeout: modeTimeout) else {
                fail("the editor-mode button never reported \(wanted) after the toggle keystroke (it reads \(mode.label))")
                return false
            }
            if wanted == "Markdown" { guard waitForMarkdownPageReady(from: switchFrom) else { return false } }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: \(wanted); the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    /// The timeout of a wait on the APP's answer to an action the test has already taken. Never shortened by the budget; where the budget
    /// is already spent when such a wait starts, the test fails at once as a TEST-SETUP failure that cannot be taken for an app failure.
    func mdDupAppWait(_ seconds: TimeInterval, before step: String) -> TimeInterval {
        let left = size.budgetSeconds - Date().timeIntervalSince(startedAt)
        if left <= 0 {
            attachEvidenceScreenshot(app.screenshot(), name: "md-dup-budget-exhausted-\(size.identifier)")
            let soFar = softLog.failures.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " | ")
            for failure in softLog.failures { note("SOFT CHECK FAILED before the budget ran out: \(failure)") }
            fail("TEST-SETUP: BUDGET EXHAUSTED before \(step): the \(Int(size.budgetSeconds)) s budget of \(size.identifier) was spent "
                + "\(Int(-left)) s ago, so the app's answer cannot be waited for fairly; soft check failure(s) collected so far: "
                + (soFar.isEmpty ? "none" : soFar))
        }
        return seconds
    }

    /// A fresh soft-check collector for the running test (its failures are also written to `softLog`).
    func mdDupSoft() -> MdDupSoft { MdDupSoft(log: softLog) }

    /// Reports every failure collected in `soft` together, in one assertion (the harness's `assertSoft`).
    func mdDupAssert(_ soft: MdDupSoft, _ what: String) {
        var forwarded = Phase4bFlowSoftChecks()
        for failure in soft.failures { forwarded.check(false, failure) }
        assertSoft(forwarded, what)
    }

    /// FAILS the test after attaching the evidence screenshot (`continueAfterFailure` is false: a still taken after the failure never exists).
    func mdDupFailWithShot(_ message: String, name: String) {
        mdDupShot(name)
        fail(message)
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    func mdDupReadIdRows() -> [MdDupIdRow] {
        let output = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT id || '|' || blockType || '|' || isNotes || '|' || isBibliography || '|' || hex(markdownFragment) "
                + "FROM block ORDER BY sortOrder, id;")
        var rows: [MdDupIdRow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5 else {
                fail("a block row could not be read from \(TestFixtureHelper.fixturePath)/content.sqlite (line starts \"\(line.prefix(60))\")")
                continue
            }
            rows.append(MdDupIdRow(
                id: String(parts[0]),
                row: Phase4bFlowRow(
                    type: String(parts[1]), isNotes: parts[2] == "1", isBibliography: parts[3] == "1", fragment: Phase4bFlow.decodeHex(parts[4]))))
        }
        return rows
    }

    func mdDupReadRows() -> [Phase4bFlowRow] { mdDupReadIdRows().map(\.row) }

    func mdDupSection(_ title: String) -> Range<Int>? { Phase4bFlow.sectionRange(title, in: pre) }

    /// The section `title` of `pre`, or a reported TEST-SETUP failure.
    func mdDupRequireSection(_ title: String) -> Range<Int>? {
        guard let range = mdDupSection(title) else {
            fail("TEST-SETUP: the loaded document has no section \"\(title)\"")
            return nil
        }
        return range
    }

    /// The row of `pre` that is `line`, or a reported TEST-SETUP failure.
    func mdDupRequireRow(_ line: String) -> Int? {
        guard let row = pre.firstIndex(where: { $0.fragment == line }) else {
            fail("TEST-SETUP: the loaded document has no row \"\(line)\"")
            return nil
        }
        return row
    }

    var mdDupPreManaged: [Phase4bFlowRow] { pre.filter(\.isManaged) }

    func mdDupBlocksContaining(_ text: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(text))') > 0;") ?? -1
    }

    /// Waits for the app to write `sentence` into the block table. `timeout` is a fixed number of seconds, never `capped(...)`.
    func mdDupWaitForSentenceInDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(timeout, before: "\"\(sentence)\" is looked for in the database"))
        repeat {
            if mdDupBlocksContaining(sentence) >= 1 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func mdDupWaitForSentenceGone(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(timeout, before: "\"\(sentence)\" is looked for to be gone from the database"))
        repeat {
            if mdDupBlocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits (a condition) until exactly `wanted` heading rows are titled exactly `title`; returns the last count read.
    func mdDupWaitForExactHeadings(_ title: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(timeout, before: "\"\(title)\" heading rows are counted in the block table"))
        var count = mdDupReadRows().filter { $0.headingTitle == title }.count
        while count != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = mdDupReadRows().filter { $0.headingTitle == title }.count
        }
        return count
    }

    /// Waits until the named sections' heading rows are gone / back and the block table and the app's log have stopped changing. With no
    /// names it just waits for the document to be quiet. Every wait is a condition.
    @discardableResult
    func mdDupSettle(gone: [String] = [], back: [String] = []) -> Bool {
        var allDone = true
        for title in gone {
            let goneTimeout = mdDupAppWait(size.operationTimeout, before: "\(title) is gone")
            allDone = mdDupWaitForExactHeadings(title, equalTo: 0, timeout: goneTimeout) == 0 && allDone
        }
        for title in back {
            allDone = mdDupWaitForExactHeadings(title, equalTo: 1, timeout: mdDupAppWait(size.operationTimeout, before: "\(title) is back")) == 1
                && allDone
        }
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        return allDone
    }

    /// The text rows the document must hold once the rows `range` of `pre` have been duplicated: `pre` without the Notes and Bibliography
    /// rows, the range copied right after itself, the copy's first row reading "<heading> copy" when `suffix` (a heading root; a section
    /// break gets none). `originalTyped` replaces the whole text of original rows (row number in `pre`), `copyTyped` the copy's rows (offset in
    /// the range, 0 is the root). The hand-worked answer, not a reading of the app.
    func mdDupExpectedRows(
        range: Range<Int>?, suffix: Bool = true, originalTyped: [Int: String] = [:], copyTyped: [Int: String] = [:]
    ) -> [Phase4bFlowRow] {
        func replaced(_ base: Phase4bFlowRow, with text: String?) -> Phase4bFlowRow {
            guard let text else { return base }
            return Phase4bFlowRow(type: base.type, isNotes: false, isBibliography: false, fragment: text)
        }
        var rows: [Phase4bFlowRow] = []
        for index in pre.indices where !pre[index].isManaged {
            rows.append(replaced(pre[index], with: originalTyped[index]))
            if let range, index == range.upperBound - 1 {
                for (offset, source) in pre[range].enumerated() {
                    let base = offset == 0 && suffix
                        ? Phase4bFlowRow(type: source.type, isNotes: false, isBibliography: false, fragment: source.fragment + " copy")
                        : source
                    rows.append(replaced(base, with: copyTyped[offset]))
                }
            }
        }
        return rows
    }

    /// What is wrong with a saved document against `expectedUser` (the text rows, footnote numbers read as `[^#]`: the app renumbers them)
    /// and `managed` (the Notes and Bibliography rows compared exactly; nil: not compared). `walk` adds the footnote walk (numbers 1...n in
    /// reading order, one definition each); it is off for a document that holds a copy of a FOOTNOTED section.
    func mdDupRowProblems(
        _ post: [Phase4bFlowRow], what: String, expectedUser: [Phase4bFlowRow], managed: [Phase4bFlowRow]?, walk: Bool
    ) -> [String] {
        var found: [String] = []
        let expected = expectedUser.enumerated().map { (row: $0.offset, value: $0.element) }
        let actual = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expected, actual: actual, exact: false)
        mdDupRecordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        if let managed {
            let expectedManaged = managed.enumerated().map { (row: $0.offset, value: $0.element) }
            let actualManaged = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let managedLines = Phase4bFlow.rowDifferences(expected: expectedManaged, actual: actualManaged, exact: true)
            mdDupRecordDifferences(what, "Notes / Bibliography rows", managedLines)
            found += managedLines.map { "the Notes / Bibliography rows are not those expected: \($0)" }
        }
        if walk { found += Phase4bFlowWalk(rows: post).problems.map { "footnotes: \($0)" } }
        return found
    }

    func mdDupRecordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// Reads the block table and adds every problem of `mdDupRowProblems` to `soft`. Returns the rows read.
    @discardableResult
    func mdDupAddRowChecks(
        _ what: String, expectedUser: [Phase4bFlowRow], managed: [Phase4bFlowRow]?, walk: Bool = true, to soft: inout MdDupSoft
    ) -> [Phase4bFlowRow] {
        let post = mdDupReadRows()
        let problems = mdDupRowProblems(post, what: what, expectedUser: expectedUser, managed: managed, walk: walk)
        note("\(what): \(post.count) block rows (\(pre.count) before); \(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// The ids of the section `title`'s LEADER rows (its headings, or its section breaks) in document order; nil if there is no such section.
    /// Only leaders are compared across undo / redo cycles: the page carries the copy's leader ids, every other row gets a fresh id.
    func mdDupLeaderIds(of title: String, in rows: [MdDupIdRow]) -> [String]? {
        guard let range = Phase4bFlow.sectionRange(title, in: rows.map(\.row)) else { return nil }
        return rows[range].filter { $0.row.headingLevel != nil || $0.row.type == "section_break" }.map(\.id)
    }

    /// The first level-3 heading of `chapterRange` (rows of `pre`) whose own rows hold no footnote reference: a footnote-free single section
    /// to delete without a footnote renumber. Nil when there is none.
    func mdDupFootnoteFreeSubsection(in chapterRange: Range<Int>) -> (title: String, range: Range<Int>)? {
        for index in chapterRange where pre[index].headingLevel == 3 {
            guard let title = pre[index].headingTitle, let range = Phase4bFlow.sectionRange(title, in: pre) else { continue }
            if Phase4bFlow.footnoteRefsInRange(pre, range) == 0 { return (title, range) }
        }
        return nil
    }

    func mdDupHeadingFragments() -> [String] {
        FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT markdownFragment FROM block WHERE blockType = 'heading' AND isNotes = 0 AND isBibliography = 0 ORDER BY sortOrder, id;")
            .split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    func mdDupTraceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    /// The log lines since `index` that hold `needle`.
    func mdDupLogLines(containing needle: String, from index: Int) -> [Phase4bLogLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].filter { $0.text.contains(needle) }
    }

    func mdDupTraceCount() -> Int {
        tail.poll()
        return tail.lines.count
    }

    func mdDupPerformedCount(_ label: String, from index: Int) -> Int {
        mdDupTraceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step == "performed" }.count
    }

    /// The undo and redo runs since `index` (a quick one begins `start (quick...`: `quick` is true for it).
    func mdDupQuickRuns(from index: Int, label: String? = nil) -> [Phase4bQuRun] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        let all = Phase4bQuLog.runs(in: tail.lines[index...])
        return label.map { name in all.filter { $0.label == name } } ?? all
    }

    /// The `[toast] show` lines since `index` that hold `needle`.
    func mdDupToastLines(containing needle: String, from index: Int) -> [String] {
        mdDupLogLines(containing: needle, from: index).map(\.text).filter { $0.contains("[toast] show") }
    }

    /// The slow-route notices ("Undoing...", "Redoing...") and the delayed "Finishing the last change..." notice, as the app's log shows them.
    func mdDupProgressToasts(from index: Int) -> (slow: [String], finishing: [String]) {
        let slow = mdDupToastLines(containing: "Undoing", from: index) + mdDupToastLines(containing: "Redoing", from: index)
        return (slow, mdDupToastLines(containing: "Finishing the last change", from: index))
    }

    func mdDupBeeps(from index: Int) -> [String] { mdDupLogLines(containing: "beeping", from: index).map(\.text) }

    func mdDupPlainPushes(from index: Int) -> Int { mdDupLogLines(containing: "[SYNC-DIAG:UpdateNSView] PUSHING", from: index).count }

    /// A refusal or failure the controller (or the sidebar action that called it) logged since `index`.
    func mdDupFailureLine(from index: Int) -> String? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return Phase4bLog(lines: Array(tail.lines[index...])).failureLine(since: "")?.text
    }

    /// Every line since `index` that says a Markdown editor-first command took another road than the one under test.
    func mdDupFallbackEvidence(from index: Int) -> [String] {
        let markers = [
            "old path for this press", "page refused or failed", "markdown put-back", "the settle gave up waiting", "step 8: no live text",
            "[EF-STRUCT]", "refused (markdown", "refused (quick)", "timeline generation changed mid-click", "the job did not apply",
            "could not be reserved", "fell back to the old sequence"
        ]
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].map(\.text).filter { text in markers.contains { text.contains($0) } }.map { String($0.suffix(160)) }
    }

    /// `[STRUCT-TRACE] sectionDuplicate-editor-first opId=<id8> ok=true mode=markdown copies=<n>`: the Markdown Duplicate click ran editor-first.
    func mdDupEditorFirstOkLines(from index: Int) -> [String] {
        mdDupLogLines(containing: "[STRUCT-TRACE] sectionDuplicate-editor-first opId=", from: index).map(\.text)
            .filter { $0.contains(" ok=true") && $0.contains(" mode=markdown") }
    }

    /// Waits for `count` `<label> performed` lines since `index`; false on a logged failure (noted) or on the timeout (noted).
    @discardableResult
    func mdDupWaitForPerformed(_ label: String, count: Int = 1, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdDupPerformedCount(label, from: index) >= count { return true }
            if let problem = mdDupFailureLine(from: index) {
                note("PROBLEM while waiting for \(count) \(label) performed line(s): \(problem)")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        note("TIMED OUT after \(Int(timeout)) s waiting for \(count) \(label) performed line(s); saw \(mdDupPerformedCount(label, from: index))")
        return false
    }

    /// Waits (a condition, up to `timeout`) until `count` `sectionDuplicate-editor-first ... ok=true mode=markdown` lines exist since `index`;
    /// the line is written when the page answered, which can be a moment after the copy's card shows. False on the timeout.
    func mdDupWaitForEditorFirstOk(count: Int = 1, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdDupEditorFirstOkLines(from: index).count >= count { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// The `[SYNC-DIAG:UpdateNSView] PUSHING` lines (a whole-document push of the editor's content) since `index`, split at the end of the
    /// CLICK WINDOW: the first `[MdWrite] structural hold released` line after the click (the click's job applied and its text flushed), or
    /// the end of the log when there is none. Only the click window is the Duplicate's own business; a later push is a rebuild, reported.
    func mdDupPushesSplit(from index: Int) -> (click: Int, later: Int) {
        tail.poll()
        guard index <= tail.lines.count else { return (0, 0) }
        let end = tail.lines[index...].firstIndex { $0.text.contains("[MdWrite] structural hold released") } ?? tail.lines.count
        let click = tail.lines[index..<end].filter { $0.text.contains("[SYNC-DIAG:UpdateNSView] PUSHING") }.count
        let all = tail.lines[index...].filter { $0.text.contains("[SYNC-DIAG:UpdateNSView] PUSHING") }.count
        return (click, all - click)
    }

    /// The mechanism of Markdown Duplicate click(s) since `index` as ONE report line (nothing asserted).
    func mdDupMechanismSummary(from index: Int) -> String {
        let okLines = mdDupEditorFirstOkLines(from: index)
        let starts = mdDupTraceLines(from: index).filter { $0.family == .sequence && $0.label == "sectionDuplicate" && $0.isOpStart }
        let setContents = mdDupLogLines(containing: "[CodeMirrorEditor] setContent len=", from: index).filter { $0.text.contains("anchorCount=0") }
        let pushes = mdDupPushesSplit(from: index)
        return "\(okLines.count) `sectionDuplicate-editor-first ... ok=true mode=markdown` line(s) "
            + "\(okLines.prefix(2).map { String($0.suffix(80)) }); "
            + "\(starts.count) sectionDuplicate start(s), \(starts.filter { !$0.step.hasPrefix("start (editor-first") }.count) on the old body; "
            + "fallback line(s) \(mdDupFallbackEvidence(from: index).count); "
            + "whole-document `setContent ... anchorCount=0` line(s) \(setContents.count); "
            + "`[SYNC-DIAG:UpdateNSView] PUSHING` line(s): \(pushes.click) in the click window, \(pushes.later) later"
    }

    /// The mechanism of `duplicates` Markdown Duplicate click(s) since `index`, added to `soft`: that many `sectionDuplicate-editor-first
    /// ... ok=true mode=markdown` lines, every `sectionDuplicate` sequence began `start (editor-first)` (none took the old body), no
    /// fallback line, no whole-document push IN THE CLICK WINDOW (a later rebuild push is reported, not asserted), no beep (unless
    /// `checkBeeps` is false: a polled redo whose redo steps a footnote renumber cleared beeps legitimately, and the caller reports it), no
    /// dropped-press toast. The `setContent ... anchorCount=0` lines (the old body's whole-document push) are counted and returned.
    @discardableResult
    func mdDupAddMechanismChecks(from index: Int, duplicates: Int, checkBeeps: Bool = true, to soft: inout MdDupSoft) -> Int {
        let okLines = mdDupEditorFirstOkLines(from: index)
        let starts = mdDupTraceLines(from: index).filter { $0.family == .sequence && $0.label == "sectionDuplicate" && $0.isOpStart }
        let oldStarts = starts.filter { !$0.step.hasPrefix("start (editor-first") }
        let fallbacks = mdDupFallbackEvidence(from: index)
        let setContents = mdDupLogLines(containing: "[CodeMirrorEditor] setContent len=", from: index).filter { $0.text.contains("anchorCount=0") }
        let pushes = mdDupPushesSplit(from: index)
        result("MECHANISM (expected \(duplicates) click(s)): \(mdDupMechanismSummary(from: index))")
        soft.check(okLines.count == duplicates,
            "\(okLines.count) `sectionDuplicate-editor-first ... ok=true mode=markdown` line(s) in the log, expected \(duplicates): "
            + "the Markdown Duplicate click did not run editor-first")
        soft.check(oldStarts.isEmpty, "\(oldStarts.count) sectionDuplicate sequence(s) took the old body: \(oldStarts.map(\.step))")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        soft.check(
            pushes.click == 0, "\(pushes.click) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) between the click and the release of its hold (must be 0)")
        let beeps = mdDupBeeps(from: index)
        if checkBeeps {
            soft.check(beeps.isEmpty, "the editor beeped \(beeps.count) time(s): \(beeps.prefix(2))")
        } else {
            result("BEEPS (reported, not asserted here): \(beeps.count) \(beeps.prefix(2))")
        }
        let dropped = mdDupToastLines(containing: "could not be carried out", from: index)
        soft.check(dropped.isEmpty, "the warning toast \"Some undo or redo presses could not be carried out\" showed: \(dropped)")
        return setContents.count
    }
}

// MARK: - Driving the app: cards, keys, typing

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    func mdDupCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    /// Every sidebar card titled exactly `title`, top to bottom (the original and its copies carry the same title).
    func mdDupCards(titled title: String) -> [XCUIElement] {
        let cards = app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
        var found: [XCUIElement] = []
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            if card.exists { found.append(card) }
        }
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    func mdDupWaitForCard(_ title: String, present: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdDupCard(title).exists == present { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Clicks the sidebar card (the UX contract: clicking navigates; the editor scrolls to the section). Coordinate click: cards are
    /// non-hittable by design.
    func mdDupNavigate(to card: XCUIElement) {
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func mdDupPressUndo() { app.typeKey("z", modifierFlags: .command) }
    func mdDupPressRedo() { app.typeKey("z", modifierFlags: [.command, .shift]) }

    /// Types straight into whatever has the keyboard focus (the editor, where the caret was placed). One `typeText` call: a verified retype
    /// would wait, and these scenarios are about what happens when typing comes right after another command.
    func mdDupTypeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typed at once on purpose; the saved document is what the scenario checks, not the keystrokes.
        app.typeText(text)
    }

    func mdDupShot(_ name: String) { attachEvidenceScreenshot(app.screenshot(), name: "\(name)-\(size.identifier)") }

    /// Scrolls the sidebar so the card has room below it for the copy's card (the copy appears right under the original, and a card outside
    /// the visible band cannot be right-clicked or clicked).
    func mdDupMakeRoomBelow(_ card: XCUIElement, title: String) {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let band = scroll.frame
        guard let start = (try? card.snapshot())?.frame else { return }
        let wanted = start.midY - (band.minY + band.height * 0.3)
        guard wanted > 20 else { return }
        scroll.scroll(byDeltaX: 0, deltaY: -wanted)
        var after = mdDupStableFrame(card)
        var moved = after.map { start.midY - $0.midY } ?? 0
        if moved < -1 {
            scroll.scroll(byDeltaX: 0, deltaY: wanted * 2)
            after = mdDupStableFrame(card)
            moved = after.map { start.midY - $0.midY } ?? 0
        }
        // The wheel can move the list by far more than `wanted` (round 1 of E11: 1316 pt for about 300), leaving the card above or below the
        // visible band, where a right-click hits another card or nothing. A card outside the band is brought back before anything is clicked.
        let inside = after.map { band.insetBy(dx: 0, dy: 20).contains($0) } ?? false
        note("SIDEBAR: \"\(title)\" scrolled up by \(Int(moved)) pt to leave room for its copy (band y \(Int(band.minY))-\(Int(band.maxY))); "
            + "the card is inside the band afterwards: \(Self.yesNo(inside))")
        if !inside { _ = mdDupBringIntoView("\"\(title)\" after making room", resolve: { card }) }
    }

    /// Right-clicks a sidebar card and chooses `item` ("Duplicate Section", "Delete Section"), and returns the app-log index just before the
    /// click. Unlike the harness's `chooseSidebarItem` (which fails the test when no menu item shows): the card must exist and lie INSIDE the
    /// visible band before the right-click (else it is brought into view first); when no menu item with that title appears within 10 s the
    /// menu is dismissed with Escape, the card is brought into view again and the right-click is made ONCE more; only then the test fails,
    /// with a screenshot taken first. `activate` false skips the foreground check, for a command given straight after the previous one.
    @discardableResult
    func mdDupChooseSidebarItem(_ card: XCUIElement, item: String, activate: Bool = true) -> Int {
        if activate { app.activateAndWaitForForeground() }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        func ensureInsideBand(_ when: String) {
            guard let frame = (try? card.snapshot())?.frame else {
                note("SIDEBAR: the card of \"\(item)\" is not in the accessibility tree \(when)")
                _ = mdDupBringIntoView("the card of \"\(item)\"", resolve: { card })
                return
            }
            if !scroll.frame.insetBy(dx: 0, dy: 6).contains(frame) {
                note("SIDEBAR: the card of \"\(item)\" is outside the visible band \(when) (card \(Self.describeFrame(frame)), band "
                    + "\(Self.describeFrame(scroll.frame))): bringing it into view")
                _ = mdDupBringIntoView("the card of \"\(item)\"", resolve: { card })
            }
        }
        ensureInsideBand("before the right-click")
        tail.poll()
        let fromIndex = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = fromIndex }
        for attempt in 1...2 {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            let entry = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", item)).firstMatch
            if entry.waitForExistence(timeout: 10) {
                entry.click()
                return fromIndex
            }
            note("SIDEBAR: no menu item starting \"\(item)\" appeared within 10 s of the right-click (attempt \(attempt) of 2)")
            mdDupShot("md-dup-no-menu-attempt-\(attempt)")
            app.typeKey(.escape, modifierFlags: [])
            if attempt == 1 { ensureInsideBand("after the first failed right-click") }
        }
        mdDupFailWithShot("No menu item starting \"\(item)\" appeared after two right-clicks on the card (the second one after Escape and bringing "
            + "the card into the band again)", name: "md-dup-no-menu")
        return fromIndex
    }

    /// The copy's sidebar card straight after the Duplicate click, for the second command a person gives right after the first. ONE
    /// accessibility resolution per try; a card outside the band is brought into view (that costs time, which is noted).
    func mdDupCopyCardAtOnce(_ copyTitle: String, band: CGRect) -> XCUIElement? {
        let card = mdDupCard(copyTitle)
        var shown: CGRect?
        let deadline = Date(timeIntervalSinceNow: 10)
        repeat {
            shown = (try? card.snapshot())?.frame
            if shown == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        } while shown == nil && Date() < deadline
        guard let frame = shown else {
            mdDupFailWithShot(
                "the copy's sidebar card \"\(copyTitle)\" did not appear straight after the Duplicate click", name: "md-dup-copy-card-missing")
            return nil
        }
        if band.insetBy(dx: 0, dy: 20).contains(frame) { return card }
        note("SIDEBAR: the copy's card \"\(copyTitle)\" is outside the visible band (card \(Self.describeFrame(frame)), band "
            + "\(Self.describeFrame(band))): scrolling it into view costs time before the next command")
        return bringSidebarCardIntoView(copyTitle)
    }

    /// Brings the element `resolve` returns into the sidebar's visible band (as `bringSidebarCardIntoView`, for a card that cannot be named
    /// by its title alone). Fails the test (and returns nil) when it cannot.
    func mdDupBringIntoView(_ what: String, resolve: () -> XCUIElement?) -> XCUIElement? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: capped(30)) else {
            mdDupFailWithShot("the outline sidebar's scroll view never appeared", name: "md-dup-sidebar-missing")
            return nil
        }
        var direction: CGFloat = 1
        for _ in 1...size.sidebarScrollAttempts {
            guard let card = resolve(), card.exists else {
                scroll.scroll(byDeltaX: 0, deltaY: -500 * direction)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                continue
            }
            let band = scroll.frame
            let frame = card.frame
            if band.insetBy(dx: 0, dy: 20).contains(frame) { return card }
            let wanted = max(-1200, min(1200, frame.midY - band.midY))
            scroll.scroll(byDeltaX: 0, deltaY: -wanted * direction)
            app.waitForStableFrame(card)
            if card.exists, (card.frame.midY - frame.midY) * (-wanted) < 0 { direction = -direction }
        }
        mdDupFailWithShot("the sidebar card \(what) could not be scrolled into view (scroll view \(scroll.frame))", name: "md-dup-card-not-in-view")
        return nil
    }

    // MARK: Keys

    /// The message of the toast on screen right now, from one accessibility snapshot (`toast-message`).
    func mdDupToastMessage() -> String? {
        guard let snapshot = try? app.staticTexts["toast-message"].snapshot() else { return nil }
        return (snapshot.value as? String) ?? snapshot.label
    }

    /// Looks at the toast for `seconds` (a figure, not a wait of the scenario: it runs right after a key press) and returns every distinct
    /// message seen.
    func mdDupToastMessages(watching seconds: TimeInterval) -> [String] {
        var seen: [String] = []
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            if let message = mdDupToastMessage(), !message.isEmpty, !seen.contains(message) { seen.append(message) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return seen
    }

    /// One Cmd-Z (or Cmd-Shift-Z), then only as much waiting as the press needs, told by the app's own log: the editor writes a
    /// `[UnifiedUndo] keydown` line for every press before it acts on it (polled, at most 15 s; none: decision `none`); a `structural`
    /// decision means a structural undo or redo is coming, and its `performed` line is waited for as long as the operation timeout; a
    /// `swallow` (held behind a request still in flight) is waited for up to 40 s. A text step (`fallthrough`) returns at once.
    func mdDupPress(redo: Bool, number: Int, watchToasts: Bool = false) -> MdDupPress {
        let label = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        app.activateAndWaitForForeground()
        if redo { mdDupPressRedo() } else { mdDupPressUndo() }
        let toasts = watchToasts ? mdDupToastMessages(watching: 1.2) : []
        let marker = "[UnifiedUndo] keydown direction=\(label) "
        var text: String?
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            tail.poll()
            text = tail.lines[min(from, tail.lines.count)...].first { $0.text.contains(marker) }?.text
            if text != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        let decision = text.flatMap { Phase4bDelTypingParser.word(after: "decision=", in: $0) } ?? "none"
        var performed = false
        if decision == "structural" {
            performed = mdDupWaitForPerformed(
                label, from: from, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the \(label) performed line of press \(number)"))
        } else if decision == "swallow" {
            performed = mdDupWaitForPerformed(label, from: from, timeout: mdDupAppWait(40, before: "the held \(label) press \(number) is routed"))
        }
        return MdDupPress(
            number: number, redo: redo, decision: decision,
            undoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("undoDepth=", in: $0) },
            redoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("redoDepth=", in: $0) },
            performed: performed, toasts: toasts)
    }

    /// Cmd-Z, one press at a time, until a STRUCTURAL press has run (the operation is undone), at most `pressCap`. A press the editor did
    /// not decide (`none`) ends the loop: the key reached no editor.
    func mdDupUndoUntilStructural(watchFirstToast: Bool = false) -> [MdDupPress] {
        var presses: [MdDupPress] = []
        for number in 1...Self.pressCap {
            let press = mdDupPress(redo: false, number: number, watchToasts: watchFirstToast && number == 1)
            presses.append(press)
            result(press.summary)
            if press.isStructural || press.decision == "none" { break }
        }
        return presses
    }

    /// Cmd-Shift-Z exactly `count` times, one press at a time (a polled undo of `count` presses is undone by `count` redo presses).
    func mdDupRedoPresses(count: Int, watchFirstToast: Bool = false) -> [MdDupPress] {
        var presses: [MdDupPress] = []
        for number in 1...max(1, count) {
            let press = mdDupPress(redo: true, number: number, watchToasts: watchFirstToast && number == 1)
            presses.append(press)
            result(press.summary)
            if press.decision == "none" { break }
        }
        return presses
    }

    /// Cmd-Shift-Z, one press at a time, until a STRUCTURAL press has run (the operation is redone), at most `pressCap`, as the undo is
    /// polled. A text press that finds nothing left to redo (redo depth 0: it beeps) or a press the editor did not decide ends the loop.
    func mdDupRedoUntilStructural() -> [MdDupPress] {
        var presses: [MdDupPress] = []
        for number in 1...Self.pressCap {
            let press = mdDupPress(redo: true, number: number)
            presses.append(press)
            result(press.summary)
            if press.isStructural || press.decision == "none" { break }
            if press.decision == "fallthrough", (press.redoDepth ?? 0) == 0 { break }
        }
        return presses
    }

    func mdDupReport(_ name: String, _ presses: [MdDupPress]) {
        let used = presses.map { "\($0.decision) u\($0.undoDepth.map(String.init) ?? "-") r\($0.redoDepth.map(String.init) ?? "-")" }
        result("\(name): \(presses.count) press(es) used (cap \(Self.pressCap)): \(used)")
        attachText("presses-\(methodName)-\(name.replacingOccurrences(of: " ", with: "-")).txt", presses.map(\.summary).joined(separator: "\n"))
    }
}

// MARK: - Driving the app: the page

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// The leaves of `leaves` that lie fully inside the editor's visible band (24 points in from each edge), in tree order.
    func mdDupFullyVisible(_ leaves: XCUIElementQuery) -> [XCUIElement] {
        let editor = app.editorArea.frame
        var visible: [XCUIElement] = []
        for index in 0..<leaves.count {
            let leaf = leaves.element(boundBy: index)
            // ONE snapshot per leaf, never `exists` then `frame`: the page redraws between two queries and the second one would abort the
            // test ("No matches found for Element at index n"); a leaf that has gone is simply not visible.
            guard let frame = (try? leaf.snapshot())?.frame else { continue }
            if frame.width > 0, frame.minY >= editor.minY + 24, frame.maxY <= editor.maxY - 24 { visible.append(leaf) }
        }
        return visible
    }

    /// The frame of `element` once two reads 0.4 s apart agree (at most `timeout`), read from SNAPSHOTS: nil as soon as the element has
    /// gone from the tree. (`waitForStableFrame` reads `.frame` itself, and a read of an element that has just vanished aborts the test.)
    func mdDupStableFrame(_ element: XCUIElement, timeout: TimeInterval = 3) -> CGRect? {
        guard var last = (try? element.snapshot())?.frame else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard let now = (try? element.snapshot())?.frame else { return nil }
            if now == last { return now }
            last = now
        }
        return last
    }

    /// The section the status bar's outline button reports (its accessibility VALUE, the full name): the section the CARET is in.
    func mdDupStatusBarSection() -> String {
        let button = app.buttons["status-bar-outline"]
        guard button.exists else { return "" }
        return (button.value as? String) ?? ""
    }

    /// Waits (a condition) until the status bar's section name contains `needle` (with `exactly`: equals it, so "3.6 Conclusion" is not
    /// satisfied by "3.6 Conclusion copy"); the last name read is returned too.
    func mdDupWaitForStatusSection(containing needle: String, timeout: TimeInterval, exactly: Bool = false) -> (found: Bool, last: String) {
        func matches(_ name: String) -> Bool { exactly ? name == needle : name.contains(needle) }
        let deadline = Date(timeIntervalSinceNow: timeout)
        var name = mdDupStatusBarSection()
        while !matches(name), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            name = mdDupStatusBarSection()
        }
        return (matches(name), name)
    }

    /// ONE look at the page after a card click, with NO scroll of the test's own (`rounds=0`): waits (a condition, bounded) for a leaf with
    /// the exact text `line` fully inside the editor's band, and returns the LAST such leaf (a copy sits after its original) with its place
    /// in the band. Nil when none shows up within `timeout`.
    func mdDupLanded(on line: String, timeout: TimeInterval, useFirst: Bool = false) -> MdDupLanding? {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let visible = mdDupFullyVisible(leaves)
            if let last = useFirst ? visible.first : visible.last {
                if let frame = mdDupStableFrame(last) {
                    let editor = app.editorArea.frame
                    let fraction = editor.height > 0 ? (frame.minY - editor.minY) / editor.height : 1
                    return MdDupLanding(leaf: last, frame: frame, topFraction: fraction, visibleCount: visible.count)
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return nil
    }

    /// Clicks the right end of `leaf` (a one-line paragraph of `words` words), moves the caret to the line's end and confirms it through the
    /// status bar's selection count. Reports the probe; false when the caret cannot be confirmed (the caller decides what that means).
    func mdDupClickEnd(of leaf: XCUIElement, words: Int, what: String) -> Bool {
        let frame = (try? leaf.snapshot())?.frame ?? .zero
        app.activateAndWaitForForeground()
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        let probe = app.caretSelectionProbe(expectedWords: words, atEnd: true)
        note("CARET at the end of \(what) (leaf \(Self.describeFrame(frame))): probe \(probe)")
        return probe == "ok"
    }

    /// The facts of a landing, as ONE result line with `rounds=0`.
    func mdDupReportLanding(_ what: String, _ landing: MdDupLanding?, section: String?) {
        let position = landing.map {
            "its top is \(Int($0.topFraction * 100)) percent down the editor band, \($0.visibleCount) such line(s) on screen"
        } ?? "none on screen"
        result("CARD CLICK LANDING (\(what)): rounds=0 (the test scrolled nothing); Dup line fully visible: \(Self.yesNo(landing != nil)); "
            + "\(position); "
            + "the status bar names \"\(section ?? "n/a")\"")
    }

    /// In Markdown: puts the caret at the end of the one-line paragraph `line` that belongs to the section whose name contains `name`.
    /// Round 0 is the place the sidebar's click landed (polled for `firstRoundTimeout`); with `search` the editor is then scrolled in growing
    /// alternating steps (CodeMirror draws only the lines near the viewport and a card click can land far from the section) and looked at
    /// again. A line found is NOT known to be the section's (a copy repeats its original's text): the caret is put at its end and the
    /// status bar must name the section (with `exactName` the status must EQUAL `name`: a copy's name "X copy" does not satisfy "X"); a
    /// line of another section is skipped. Returns the round that worked, nil after a miss
    /// (`landingReads` says what the status bar read). Never types into an unconfirmed place.
    func mdDupPlaceCaret(
        inSection name: String, line: String, search: Bool, exactName: Bool = false, firstRoundTimeout: TimeInterval = 20
    ) -> Int? {
        landingReads = []
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let stops: [CGFloat] = search ? [0, 500, -500, 1000, -1000, 1500, -1500, 2000, -2000, 2600, -2600, 3200, -3200] : [0]
        var travelled: CGFloat = 0
        for (round, stop) in stops.enumerated() {
            if stop != travelled {
                app.editorArea.scroll(byDeltaX: 0, deltaY: -(stop - travelled))
                travelled = stop
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            }
            var tried = Set<Int>()
            let deadline = Date(timeIntervalSinceNow: round == 0 ? firstRoundTimeout : 0.1)
            repeat {
                for leaf in mdDupFullyVisible(leaves).reversed() {
                    guard let leafFrame = mdDupStableFrame(leaf), tried.insert(Int(leafFrame.minY)).inserted else { continue }
                    app.activateAndWaitForForeground()
                    leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
                    let section = mdDupWaitForStatusSection(containing: name, timeout: 4, exactly: exactName)
                    landingReads.append("round \(round): \"\(section.last)\"")
                    guard section.found else { continue }
                    app.typeKey(.rightArrow, modifierFlags: .command)
                    let probe = app.caretSelectionProbe(expectedWords: line.split(separator: " ").count, atEnd: true)
                    note("CARET (Markdown) at the end of \"\(line)\" of \"\(name)\", found in search round \(round) "
                        + "(net scroll \(Int(travelled)) pt): "
                        + "the status bar reads \"\(section.last)\"; probe \(probe)")
                    guard probe == "ok" else {
                        fail("the caret could not be confirmed at the end of \"\(line)\" of \"\(name)\" (probe: \(probe))")
                        return nil
                    }
                    return round
                }
                if round == 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
            } while Date() < deadline
        }
        return nil
    }

    /// Rich Text: the exact-value leaf of the plain line `line` that lies fully inside the editor's band (the LAST one when several do),
    /// found within `timeout`.
    func mdDupVisibleLeaf(_ line: String, timeout: TimeInterval) -> XCUIElement? {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let last = mdDupFullyVisible(leaves).last, mdDupStableFrame(last) != nil { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return nil
    }

    /// The editor's text as the accessibility tree shows it: the runs joined with one space, every run of whitespace (a no-break space
    /// included) collapsed to a single space. A typed line that WRAPS is two runs, so a sentence is looked for in this joined text.
    func mdDupJoinedScreenText() -> String? {
        guard let values = app.editorStaticTextValues() else { return nil }
        return values.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Waits (a condition) until the editor's text does (`present`) or does not hold `sentence`; nil when no snapshot could be read.
    func mdDupWaitForSentenceOnScreen(_ sentence: String, present: Bool, timeout: TimeInterval) -> Bool? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var read = false
        repeat {
            if let text = mdDupJoinedScreenText() {
                read = true
                if text.contains(sentence) == present { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return read ? false : nil
    }

    /// Where the Dup line sits in the editor's band (points from the band's top edge) once the page has SETTLED: sampled every half second
    /// until three readings in a row agree within 2 points (at most `window` seconds), the whole series kept as text. CodeMirror re-measures
    /// line heights over several frames after the state is replaced, so one reading straight after a press can be taken mid-settle.
    func mdDupSettledLineTop(_ line: String, window: TimeInterval = 6) -> MdDupLineTop {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let started = Date()
        var readings: [CGFloat?] = []
        var stamps: [TimeInterval] = []
        func settled() -> Bool {
            guard readings.count >= 3 else { return false }
            let lastThree = readings.suffix(3)
            let values = lastThree.compactMap { $0 }
            if values.isEmpty { return true }
            guard values.count == 3, let low = values.min(), let high = values.max() else { return false }
            return high - low <= 2
        }
        repeat {
            let editor = app.editorArea.frame
            readings.append(mdDupFullyVisible(leaves).last.map { $0.frame.minY - editor.minY })
            stamps.append(Date().timeIntervalSince(started))
            if settled() { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date().timeIntervalSince(started) < window
        let series = zip(stamps, readings)
            .map { "t\(String(format: "%.1f", $0))=\($1.map { String(Int($0)) } ?? "off screen")" }
            .joined(separator: " ")
        return MdDupLineTop(top: readings.last ?? nil, series: series, editorHeight: app.editorArea.frame.height)
    }
}

// MARK: - Duplicate, Delete, Save Version, close, reopen

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// Duplicate Section on the card `title`, wait for the copy's card (a condition), and with `settled` for the copy's rows and a quiet
    /// document. Returns the app-log index just before the click; nil after a reported failure.
    func mdDupChooseDuplicate(title: String, settled: Bool, makeRoom: Bool = true) -> Int? {
        guard let card = bringSidebarCardIntoView(title) else { return nil }
        if makeRoom { mdDupMakeRoomBelow(card, title: title) }
        let copyTitle = title + " copy"
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        let shown = mdDupCard(copyTitle).waitForExistence(timeout: mdDupAppWait(size.operationTimeout, before: "the copy's card shows"))
        if !shown { mdDupShot("md-dup-copy-card-not-shown") }   // before the aborting assertion
        assertCheck(shown, "the copy's sidebar card \"\(copyTitle)\" appears after Duplicate Section")
        guard shown else { return nil }
        if settled {
            let rowsTimeout = mdDupAppWait(size.operationTimeout * 2, before: "the copy's rows are saved")
            let rows = mdDupWaitForExactHeadings(copyTitle, equalTo: 1, timeout: rowsTimeout)
            if rows != 1 { mdDupShot("md-dup-copy-rows-not-saved") }
            assertCheck(rows == 1, "the block table holds the copy's heading \"\(copyTitle)\" once (it holds \(rows))")
            mdDupSettle()
        }
        return from
    }

    /// Right-clicks a section's card and chooses Delete Section; returns the app-log index just before the click.
    func mdDupChooseDelete(card: XCUIElement, activate: Bool = true) -> Int {
        mdDupChooseSidebarItem(card, item: "Delete Section", activate: activate)
    }

    /// File > Save Version with `name`, and the wait (a condition) for its snapshot row. Saving a version writes the LIVE editor text into
    /// the block table first.
    @discardableResult
    func mdDupSaveVersion(named name: String) -> Bool {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = mdDupWaitForSheet()
        guard alert.exists else { fail("the Save Version alert never appeared"); return false }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { fail("the Save Version alert has no name field"); return false }
        field.click()
        field.typeText(name)
        let save = alert.buttons["Save"]
        guard save.waitForExistence(timeout: 10) else { fail("the Save Version alert has no Save button"); return false }
        save.click()
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(60, before: "the saved version \"\(name)\" is looked for in the snapshot table"))
        var saved = false
        repeat {
            saved = dbInt("SELECT count(*) FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';") == 1
            if !saved { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        } while !saved && Date() < deadline
        return saved
    }

    /// The sheet of File > Save Version (a sheet, or a dialog on some macOS builds).
    func mdDupWaitForSheet() -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// The house rule "the screen equals the database": `before` is a read of the block table; File > Save Version then writes the live
    /// editor text into the table, and the table is read again. The two reads must be identical, every row, Notes and Bibliography included.
    func mdDupAddScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout MdDupSoft) {
        versionSaves += 1
        let name = "Md dup check \(versionSaves)"
        let saved = mdDupSaveVersion(named: name)
        soft.check(saved, "\(what): the version \"\(name)\" was saved (its flush writes the live editor text into the block table)")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let after = mdDupReadRows()
        let lines = Phase4bFlow.rowDifferences(
            expected: before.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: after.enumerated().map { (row: $0.offset, value: $0.element) }, exact: true)
        mdDupRecordDifferences(what, "the block table before and after Save Version (screen vs database)", lines)
        note("\(what): SCREEN vs DATABASE: \(before.count) rows before Save Version, \(after.count) after; \(lines.count) difference line(s)")
        soft.check(lines.isEmpty, "\(what): the live editor text differs from the saved block table: \(lines.joined(separator: " | "))")
    }

    /// Cmd-W (Close Project), then the wait for the project picker (a condition).
    func mdDupCloseProject() -> Bool {
        // e2e-lint: allow cmd-w -- closing the project IS the scenario (Cmd-W is the app's Close Project).
        app.typeKey("w", modifierFlags: .command)
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(300, before: "the project picker shows"))
        repeat {
            if app.groups["project-picker"].exists { return true }
            if let message = mdDupToastMessage(), message.hasPrefix("Couldn't close the project") {
                mdDupFailWithShot("the close was cancelled by its time budget and the app said so: \"\(message)\"", name: "md-dup-close-cancelled")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        mdDupFailWithShot("the project picker never appeared 300 s after Cmd-W", name: "md-dup-close-no-picker")
        return false
    }

    /// Starts the app again on the same project and waits until the editor shows the document.
    func mdDupRelaunch() -> Bool {
        app.launchEnvironment[Self.holdKey] = nil
        tail.poll()
        let relaunchIndex = tail.lines.count
        note("RELAUNCH: app-log line \(relaunchIndex) is the first line the reopened app can write")
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        guard app.editorArea.waitForExistence(timeout: capped(60)) else { fail("the editor area never appeared after the relaunch"); return false }
        guard app.staticTexts["status-bar-word-count"].waitForValueNot("== '0 words'", timeout: capped(size.loadTimeout)) else {
            fail("the status bar still shows 0 words \(Int(size.loadTimeout)) s after the relaunch")
            return false
        }
        let ready = waitForLog(containing: "editor-ready gate satisfied", from: relaunchIndex, timeout: capped(size.loadTimeout))
        note("REOPENED: the editor shows the document; \"editor-ready gate satisfied\" line: \(Self.yesNo(ready))")
        startedAt = Date()
        return true
    }

    /// ONE card click on the copy's card and the facts of where the page landed (`rounds=0`: the test scrolls nothing): the Dup line must be
    /// fully on screen, in the upper part of the band, and the line it clicked must belong to the copy (the status bar names it). The
    /// screenshot is attached BEFORE the checks. `what` names the moment ("at once", "after the settle").
    @discardableResult
    func mdDupCheckLanding(_ what: String, copyTitle: String, to soft: inout MdDupSoft, checkHeading: Bool = false) -> Bool {
        guard let copyCard = bringSidebarCardIntoView(copyTitle) else { return false }
        mdDupNavigate(to: copyCard)
        return mdDupCheckLandingAfterClick(what, copyTitle: copyTitle, to: &soft, checkHeading: checkHeading)
    }

    /// The part of `mdDupCheckLanding` after the card was clicked (a test that clicks the card itself, at once, calls this).
    ///
    /// WHAT THIS CAN AND CANNOT TELL APART (review F6): the Dup line is in the original AND in the copy. The line the click puts on screen
    /// belongs to the copy only if the status bar says so after the caret was put at its end, and that tells copy from original only while
    /// the section is longer than one screen (a short section can show both Dup lines, and the LAST fully visible one is taken, the copy's).
    /// The sections used (a "N.6 Conclusion" of four long paragraphs, a whole chapter) are longer than one screen. Where the copy's heading
    /// leaf is exposed in the accessibility tree (an H2 line sometimes is: `heading` is read by its bare title, never by the `##` mark) it
    /// must be fully on screen ABOVE the landed Dup line; where it is not exposed that is said in the result line and nothing is asserted.
    @discardableResult
    func mdDupCheckLandingAfterClick(_ what: String, copyTitle: String, to soft: inout MdDupSoft, checkHeading: Bool = false) -> Bool {
        let landing = mdDupLanded(on: Self.dupLineOne, timeout: mdDupAppWait(60, before: "the copy's Dup line shows after one click (\(what))"))
        var caretOk = false
        var section: String?
        if let landing {
            caretOk = mdDupClickEnd(of: landing.leaf, words: 6, what: "the Dup01 line the one card click landed on (\(what))")
            section = mdDupWaitForStatusSection(containing: copyTitle, timeout: 4).last
        }
        mdDupReportLanding(what, landing, section: section)
        var headingNote = "not checked"
        var headingProblem: String?
        if checkHeading, let landing {
            if let heading = app.editorHeadingText(matching: copyTitle, timeout: 2) {
                let editor = app.editorArea.frame
                let frame = (try? heading.snapshot())?.frame ?? .zero
                let fullyVisible = frame.width > 0 && frame.minY >= editor.minY && frame.maxY <= editor.maxY
                let above = frame.width > 0 && frame.maxY <= landing.frame.minY + 1
                headingNote = "exposed at \(Self.describeFrame(frame)), fully visible \(Self.yesNo(fullyVisible)), "
                    + "above the landed Dup line \(Self.yesNo(above))"
                if !(fullyVisible && above) { headingProblem = headingNote }
            } else {
                headingNote = "not exposed in the accessibility tree (nothing asserted about the heading line)"
            }
        }
        result("HEADING LEAF of \"\(copyTitle)\" (\(what)): \(headingNote)")
        mdDupShot("md-dup-landing-\(what.replacingOccurrences(of: " ", with: "-"))")
        if let headingProblem {
            soft.check(false, "\(what): the copy's heading line is not fully on screen above the landed Dup line (\(headingProblem))")
        }
        guard let landing else {
            soft.check(false, "\(what): after ONE click on the copy's card no \"\(Self.dupLineOne)\" line was fully on screen within 60 s "
                + "(rounds=0, the test scrolled nothing): the card click did not land on the copy")
            return false
        }
        soft.check(landing.topFraction <= Self.landingTopFraction,
            "\(what): the Dup line is \(Int(landing.topFraction * 100)) percent down the editor band "
            + "(more than \(Int(Self.landingTopFraction * 100))): the click did not put the copy's heading at the top")
        soft.check(caretOk, "\(what): the caret could not be confirmed at the end of the landed Dup line")
        soft.check(section?.contains(copyTitle) == true,
            "\(what): the Dup line the click landed on belongs to \"\(section ?? "n/a")\", not to the copy \"\(copyTitle)\": the click landed "
            + "on the ORIGINAL (or elsewhere)")
        return true
    }
}

// MARK: - E1 The copy's card lands on the copy

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E1. CLAIM: Duplicate "3.6 Conclusion" on the twelve-chapter book (Markdown); the copy shows in the Outline at once; ONE click on the
    /// copy's card, straight away (its rows may not exist yet), puts the copy on screen with NO scroll search (`rounds=0`); after the
    /// settle the same holds again (the click away to the original and back). The mechanism line `sectionDuplicate-editor-first ... ok=true
    /// mode=markdown` is in the log and the page was not given a whole document (`setContent ... anchorCount=0`: zero).
    /// TODAY: FAILS. The old Markdown Duplicate pushes the whole document without section markers; the copy's card click lands 2600 pt away
    /// (premise check: found in search round 10, net scroll -2600 pt) and there is no `sectionDuplicate-editor-first` line.
    /// BREAK: the copy keeps its original's `@sid` marker (swift-U4.patch / web-WD1*.patch): the click lands on the ORIGINAL ("belongs to
    /// \"3.6 Conclusion\", not to the copy").
    /// LIMIT (review F6): the first click tells copy from original only while the section is longer than one screen (see
    /// `mdDupCheckLandingAfterClick`); "3.6 Conclusion" is four long paragraphs. The second check starts from a confirmed caret in the
    /// original (status bar exactly "3.6 Conclusion"), so the copy's name that follows is a change, not a stale value. Where the copy's
    /// heading leaf is exposed it must be fully visible above the landed line (asserted); where it is not, that is only reported.
    func testMdDupCopyAtOnceCardLandsOnCopy_book12() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book12, method: #function, seed: Self.dupSeed(under: title, level: 2)),
              mdDupRequireSection(title) != nil, let card = bringSidebarCardIntoView(title) else { return }
        mdDupMakeRoomBelow(card, title: title)
        let band = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        var soft = mdDupSoft()
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        guard let copyCard = mdDupCopyCardAtOnce(copyTitle, band: band) else { return }
        let rowsAtClick = mdDupReadRows().filter { $0.headingTitle == copyTitle }.count
        mdDupNavigate(to: copyCard)
        note("ONE CLICK on the copy's card straight after the Duplicate; the block table held \(rowsAtClick) row(s) for the copy's heading then")
        mdDupCheckLandingAfterClick("at once", copyTitle: copyTitle, to: &soft, checkHeading: true)

        mdDupSettle()
        let setContents = mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        soft.check(
            setContents == 0, "\(setContents) whole-document `setContent ... anchorCount=0` line(s): the page was given the whole document again")
        mdDupAddRowChecks(
            "after the Duplicate (settled)", expectedUser: mdDupExpectedRows(range: mdDupSection(title)), managed: mdDupPreManaged, to: &soft)

        // The same click after the settle: away to the ORIGINAL first (the caret is put at the end of the original's Dup01 line and the
        // status bar must read exactly "3.6 Conclusion": so the caret really left the copy and the next read cannot be a stale copy name),
        // then the copy's card again: the status bar must change from the original's name to the copy's.
        if let originalCard = bringSidebarCardIntoView(title) {
            mdDupNavigate(to: originalCard)
            let away = mdDupPlaceCaret(inSection: title, line: Self.dupLineOne, search: true, exactName: true)
            result("CLICK AWAY to the original: caret at the end of its Dup01 line with the status bar reading exactly \"\(title)\": "
                + (away.map { "yes (search round \($0))" } ?? "NO; the status bar read \(landingReads)"))
            soft.check(
                away != nil,
                "the click away to the original's card did not put the caret into the original (status bar reads: \(landingReads)): "
                + "the second landing check below would start from a stale value")
            mdDupCheckLanding("after the settle", copyTitle: copyTitle, to: &soft, checkHeading: true)
        }
        mdDupAssert(soft, "Markdown: Duplicate \"\(title)\", ONE click on the copy's card at once and again after the settle, on \(size.identifier)")
    }
}

// MARK: - E2 Typing around the click

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E2. CLAIM: a word is typed at the end of the Anchor05 line (chapter 1), "3.6 Conclusion" is duplicated straight after, and a second
    /// word is typed at the end of the Anchor06 line as soon as the caret is back in the text (a click: the right-click moved the keyboard
    /// focus to the Outline). The job is held 3.5 s (a pending job is likely on a fast host; NOT asserted, only reported). Both words are on
    /// screen and in the block table exactly once, nothing else changed, the copy is there, the editor text equals the table.
    /// TODAY: predicted FAIL (the whole-document push can drop typing near the click); if it passes it is a CONTROL: never proven.
    /// BREAK: release the writer hold at the click (swift-U2.patch): the second word is lost or lands in the wrong row.
    func testMdDupTypeDuringClick_book12() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book12, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title), let anchor = mdDupRequireRow(Self.anchorLine), let six = mdDupRequireRow(Self.anchorSixLine),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine),
              let card = bringSidebarCardIntoView(title) else { return }
        mdDupTypeNow(" " + Self.phraseOne)
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        guard placeCaretAtAnchorEnd(paragraph: "Anchor06", exactLine: Self.anchorSixLine) else { return }
        tail.poll()
        let typedAt = tail.lines.count
        mdDupTypeNow(" " + Self.phraseTwo)
        tail.poll()   // the lines written while the word was typed must be in `tail.lines` before the hold-released line is looked for
        let released = tail.lines[min(from, tail.lines.count)...].firstIndex { $0.text.contains("[MdWrite] structural hold released") }
        let jobState = released.map { $0 > typedAt } ?? true ? "still pending" : "already done"
        result("TYPING vs THE JOB (reported, not asserted): the second word was typed at log line \(typedAt); "
            + "the click's hold was released at log line \(released.map(String.init) ?? "not yet at that moment") "
            + "(so the job was \(jobState) when it was typed)")
        var soft = mdDupSoft()
        soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: mdDupAppWait(size.operationTimeout, before: "the copy's card shows")),
            "the copy's card \"\(copyTitle)\" never showed")
        soft.check(app.editorContainsText(Self.phraseTwo, timeout: 60), "the second word \"\(Self.phraseTwo)\" is not on screen")
        soft.check(mdDupWaitForSentenceInDatabase(Self.phraseTwo, timeout: 90), "the second word \"\(Self.phraseTwo)\" never reached the block table")
        soft.check(mdDupWaitForSentenceInDatabase(Self.phraseOne, timeout: 90), "the first word \"\(Self.phraseOne)\" never reached the block table")
        mdDupSettle()
        let expected = mdDupExpectedRows(range: range, originalTyped: [
            anchor: Self.anchorLine + " " + Self.phraseOne, six: Self.anchorSixLine + " " + Self.phraseTwo
        ])
        let post = mdDupAddRowChecks("after the Duplicate and the typing (settled)", expectedUser: expected, managed: mdDupPreManaged, to: &soft)
        soft.check(mdDupBlocksContaining(Self.phraseOne) == 1 && mdDupBlocksContaining(Self.phraseTwo) == 1,
            "the words are in \(mdDupBlocksContaining(Self.phraseOne)) and \(mdDupBlocksContaining(Self.phraseTwo)) row(s), expected 1 each")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "after the Duplicate and the typing", to: &soft)
        mdDupShot("md-dup-e2-end")
        mdDupAssert(soft, "Markdown: type, Duplicate \"\(title)\", type again, on \(size.identifier)")
    }
}

// MARK: - E3 Cmd-Z and Cmd-Shift-Z are quick, twice over, with the same ids

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E3. CLAIM: Duplicate "3.6 Conclusion" (six-chapter book, Markdown), then TWO full cycles of Cmd-Z, Cmd-Shift-Z, Cmd-Z, Cmd-Shift-Z:
    /// the copy is gone / back / gone / back; after each Cmd-Shift-Z the copy's LEADER (heading) ids in the block table are the ids of the
    /// click (the page carries them, the redo job gives the rows the same ones; the other rows get fresh ids by design); every press is a
    /// QUICK undo or redo (`start (quick...`) and the log holds NO `[toast] show` line with "Undoing" or "Redoing" for the cycles. The
    /// delayed "Finishing the last change..." notice is only REPORTED: with every job held 3.5 s a press that waits behind a held job for
    /// over 1 s legitimately shows it (UX contract: past one second the app shows it is working). THEN (judge D3) Cmd-Shift-Z is pressed
    /// STRAIGHT after a Cmd-Z, with nothing between the two key events: the copy is back with the click's ids, the rows are consistent,
    /// nothing refused or beeped, no Undoing / Redoing notice.
    /// TODAY: FAILS. The old body's undo and redo take the slow route and show "Undoing..." / "Redoing..." (premise check: toasts at 14:45:19
    /// and 14:45:32), and the copy's ids are not the click's.
    /// BREAK: force the slow route for the redo (swift-U5b.patch: "Redoing..." toast, not quick); fresh ids on the redo (swift-U5.patch:
    /// "leader ids ... are not those of the click"). swift-U5d.patch (remove the hold wait in the quick route) breaks the unit test U5d,
    /// not this test: the held press cannot be forced from XCUITest (see JOB HOLD below).
    /// JOB HOLD: every queued job is held 3.5 s for the whole test (kept so a press can meet a held job where the host allows). Round 1
    /// of the real app showed (a) a press that waits behind a held job legitimately shows "Finishing the last change...", so that notice
    /// is REPORTED, not asserted; (b) the VM's key events are too far apart for the straight-after pair ever to meet a running undo (0
    /// presses held although every job was held), and XCUITest cannot force a held press: the number of held presses (`failed=latched`)
    /// is therefore REPORTED only. That the second key is held and then acts is proven by the unit test U5d and its break patch
    /// swift-U5d. What this test asserts for the pair is the END STATE: the copy is back with the click's ids and the rows are consistent.
    func testMdDupUndoRedoQuickNoToast_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title), let from = mdDupChooseDuplicate(title: title, settled: true) else { return }
        let withCopy = mdDupExpectedRows(range: range)
        let without = mdDupExpectedRows(range: nil)
        var soft = mdDupSoft()
        let clickIds = mdDupLeaderIds(of: copyTitle, in: mdDupReadIdRows())
        soft.check(clickIds?.isEmpty == false, "TEST-SETUP: the copy \"\(copyTitle)\" has no leader rows in the block table after the settle")
        note("COPY LEADER IDS at the click (settled): \(clickIds ?? [])")
        let cyclesFrom = mdDupTraceCount()
        for cycle in 1...2 {
            let undo = mdDupPress(redo: false, number: cycle * 2 - 1, watchToasts: true)
            result(undo.summary + "; toasts in the first 1.2 s \(undo.toasts)")
            soft.check(
                undo.decision == "structural" && undo.performed, "cycle \(cycle): Cmd-Z was decided \(undo.decision) (performed: \(undo.performed))")
            soft.check(!undo.toasts.contains { $0.contains("Undoing") },
                "cycle \(cycle): the toast element showed \"Undoing...\" within 1.2 s of Cmd-Z: \(undo.toasts)")
            soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout, before: "the copy's card leaves")),
                "cycle \(cycle): the copy's card \"\(copyTitle)\" is still in the Outline after Cmd-Z")
            mdDupSettle(gone: [copyTitle])
            mdDupAddRowChecks("cycle \(cycle) after Cmd-Z (settled)", expectedUser: without, managed: mdDupPreManaged, to: &soft)

            let redo = mdDupPress(redo: true, number: cycle * 2, watchToasts: true)
            result(redo.summary + "; toasts in the first 1.2 s \(redo.toasts)")
            soft.check(
                redo.decision == "structural" && redo.performed,
                "cycle \(cycle): Cmd-Shift-Z was decided \(redo.decision) (performed: \(redo.performed))")
            soft.check(!redo.toasts.contains { $0.contains("Redoing") || $0.contains("Undoing") },
                "cycle \(cycle): the toast element showed \"Redoing...\" or \"Undoing...\" within 1.2 s of Cmd-Shift-Z: \(redo.toasts)")
            soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: mdDupAppWait(size.operationTimeout, before: "the copy's card is back")),
                "cycle \(cycle): the copy's card \"\(copyTitle)\" is not back after Cmd-Shift-Z")
            mdDupSettle(back: [copyTitle])
            mdDupAddRowChecks("cycle \(cycle) after Cmd-Shift-Z (settled)", expectedUser: withCopy, managed: mdDupPreManaged, to: &soft)
            let ids = mdDupLeaderIds(of: copyTitle, in: mdDupReadIdRows())
            soft.check(
                ids == clickIds, "cycle \(cycle): the copy's leader ids after the redo \(ids ?? []) are not those of the click \(clickIds ?? [])")
        }
        mdDupShot("md-dup-e3-after-two-cycles")
        let progress = mdDupProgressToasts(from: cyclesFrom)
        let runs = mdDupQuickRuns(from: cyclesFrom)
        let runLabels = runs.map { "\($0.label) \($0.quick ? "quick" : "SLOW")" }
        result("TWO CYCLES: \(runs.count) undo / redo run(s) \(runLabels); progress toast line(s) in the log: "
            + "\(progress.slow.count) Undoing / Redoing, \(progress.finishing.count) Finishing the last change")
        soft.check(runs.count == 4 && runs.allSatisfy(\.quick),
            "the four presses ran as \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")" }), expected four quick runs")
        soft.check(
            progress.slow.isEmpty, "\(progress.slow.count) \"Undoing...\" / \"Redoing...\" toast line(s) in the log: \(progress.slow.prefix(2))")
        // "Finishing the last change..." is REPORTED above, not asserted: a press behind a held job for over 1 s legitimately shows it.

        // D3: Cmd-Shift-Z straight after Cmd-Z, nothing between the two key events.
        let straightFrom = mdDupTraceCount()
        app.activateAndWaitForForeground()
        mdDupPressUndo()
        mdDupPressRedo()
        let undoWait = mdDupAppWait(size.operationTimeout * 2, before: "the straight-after undo performs")
        let undoDone = mdDupWaitForPerformed("undo", from: straightFrom, timeout: undoWait)
        let redoWait = mdDupAppWait(size.operationTimeout * 2, before: "the straight-after redo performs")
        let redoDone = mdDupWaitForPerformed("redo", from: straightFrom, timeout: redoWait)
        soft.check(undoDone && redoDone, "Cmd-Z then Cmd-Shift-Z straight after: undo performed \(undoDone), redo performed \(redoDone)")
        let cardBackWait = mdDupAppWait(size.operationTimeout, before: "the copy's card is back after the pair")
        soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: cardBackWait),
            "the copy's card is not back after Cmd-Z and Cmd-Shift-Z pressed straight after each other")
        mdDupSettle(back: [copyTitle])
        mdDupAddRowChecks(
            "after Cmd-Z + Cmd-Shift-Z straight after each other (settled)", expectedUser: withCopy, managed: mdDupPreManaged, to: &soft)
        let pairIds = mdDupLeaderIds(of: copyTitle, in: mdDupReadIdRows())
        soft.check(
            pairIds == clickIds, "after the straight-after pair the copy's leader ids \(pairIds ?? []) are not those of the click \(clickIds ?? [])")
        let refused = mdDupLogLines(containing: "[STRUCT-TRACE] routing-refused", from: straightFrom).filter { !$0.text.contains(" failed=latched ") }
        let held = mdDupLogLines(containing: " failed=latched ", from: straightFrom).count
        let pairProgress = mdDupProgressToasts(from: straightFrom)
        result("STRAIGHT-AFTER PAIR: presses held behind the running undo (`failed=latched`): \(held); refused: \(refused.count); "
            + "\"Finishing the last change...\" notices \(pairProgress.finishing.count) (legitimate when the hold lasts over 1 s); "
            + "\"Undoing / Redoing\" notices \(pairProgress.slow.count)")
        soft.check(refused.isEmpty, "a press of the straight-after pair was refused: \(refused.map(\.text))")
        soft.check(pairProgress.slow.isEmpty, "the straight-after pair showed \"Undoing...\" / \"Redoing...\": \(pairProgress.slow.prefix(2))")
        // The number of held presses is a REPORT (see the header): the VM's key events are too far apart to force a held press.
        mdDupShot("md-dup-e3-after-the-pair")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupAssert(soft, "Markdown: Duplicate, two quick undo / redo cycles and a Cmd-Shift-Z straight after Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - E4 Typing inside the copy comes back (CONTROL)

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E4 (CONTROL). CLAIM: Duplicate "3.6 Conclusion", type "Typed in the copy." at the end of the copy's Dup01 line, Cmd-Z until the copy
    /// is gone (polled: a slow host splits the typing into several undo groups, so the presses are read one at a time, at most 6), then
    /// the same number of Cmd-Shift-Z: the copy is back WITH the sentence, once, inside the copy, no heading line damaged, the editor text
    /// equals the table.
    /// TODAY: passes (the redo job t-14f908b4 made this work for the old body); a CONTROL for the new composed redo. It asserts no
    /// mechanism line (E3 does, on the same Duplicate): only that the typing comes back.
    /// BREAK: drop the 'duplicate' kind from the moved range in `buildSwappedState` (web-WD8a.patch): the sentence is not back inside the
    /// copy ("the sentence is in 0 block row(s)").
    func testMdDupTypeInCopyUndoRedoPutBack_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title), let from = mdDupChooseDuplicate(title: title, settled: true),
              let copyCard = bringSidebarCardIntoView(copyTitle) else { return }
        mdDupNavigate(to: copyCard)
        guard mdDupPlaceCaret(inSection: copyTitle, line: Self.dupLineOne, search: true) != nil else {
            mdDupShot("md-dup-e4-caret-not-placed")
            fail("TEST-SETUP: the copy's Dup01 line was not found after the card click and a scroll search; the status bar read \(landingReads)")
            return
        }
        let typedLine = Self.dupLineOne + " " + Self.sentence
        mdDupTypeNow(" " + Self.sentence)
        let without = mdDupExpectedRows(range: nil)
        let withTyping = mdDupExpectedRows(range: range, copyTyped: [1: typedLine])
        var soft = mdDupSoft()
        soft.check(mdDupWaitForSentenceInDatabase(Self.sentence, timeout: 90), "the sentence typed into the copy never reached the block table")
        mdDupSettle()
        let keysFrom = mdDupTraceCount()
        let undoPresses = mdDupUndoUntilStructural()
        mdDupReport("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the copy was not removed by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's card is still in the Outline after \(undoPresses.count) Cmd-Z press(es)")
        soft.check(mdDupWaitForSentenceGone(Self.sentence, timeout: 120), "the sentence is still in the block table after the undo")
        mdDupSettle(gone: [copyTitle])
        mdDupAddRowChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedUser: without, managed: mdDupPreManaged, to: &soft)
        let redoPresses = mdDupRedoPresses(count: undoPresses.count)
        mdDupReport("redo", redoPresses)
        let count = mdDupWaitForSentenceCount(Self.sentence, equalTo: 1, timeout: 120)
        soft.check(
            count == 1,
            "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), expected exactly 1 (the copy's Dup01 line)")
        soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "the copy's card is not back after \(redoPresses.count) Cmd-Shift-Z press(es)")
        mdDupSettle(back: [copyTitle])
        let post = mdDupAddRowChecks(
            "after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedUser: withTyping, managed: mdDupPreManaged, to: &soft)
        let headings = mdDupHeadingFragments()
        let expectedHeadings = withTyping.filter { $0.headingLevel != nil }.map { $0.fragment.trimmingCharacters(in: .whitespacesAndNewlines) }
        soft.check(headings == expectedHeadings, "a heading line was damaged: \(headings.count) heading line(s), \(expectedHeadings.count) expected")
        if let shown = mdDupWaitForSentenceOnScreen(Self.sentence, present: true, timeout: 90) {
            soft.check(shown, "the editor does not show the sentence \"\(Self.sentence)\" after the redo")
        }
        let beeps = mdDupBeeps(from: keysFrom)
        soft.check(
            beeps.isEmpty,
            "the editor beeped \(beeps.count) time(s) (a Cmd-Shift-Z that found nothing to redo is the defect's fingerprint): \(beeps.prefix(2))")
        // NO mechanism assertion here (review F1): the editor-first click line fails on today's code, which would make this "control" fail
        // today. E3 asserts the mechanism on the same Duplicate; this test is the pure "typing comes back" check.
        result("MECHANISM (reported only; E3 asserts it): \(mdDupMechanismSummary(from: from))")
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        mdDupShot("md-dup-e4-end")
        mdDupAssert(soft, "Markdown: Duplicate, type in the copy, polled Cmd-Z, polled Cmd-Shift-Z, on \(size.identifier)")
    }

    /// Waits until the block table holds exactly `wanted` rows with the sentence.
    func mdDupWaitForSentenceCount(_ sentence: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(timeout, before: "\"\(sentence)\" is counted in the database"))
        var count = mdDupBlocksContaining(sentence)
        while count != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = mdDupBlocksContaining(sentence)
        }
        return count
    }
}

// MARK: - E5 and E5RT The caret line is on screen after Cmd-Z (CONTROLS, both editors)

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E5 (CONTROL, Markdown). CLAIM: the caret sits at the end of the ORIGINAL's Dup01 line, "3.6 Conclusion" is duplicated, the page is
    /// taken to the copy by its card, Cmd-Z removes the copy: afterwards the Dup01 line (the caret's line) is fully on screen. The position
    /// of that line in the editor band, after the page has settled, is LOGGED in one format (`UNDO SCROLL (<editor>): ...`) so this test
    /// and E5RT, its Rich Text twin, can be compared: the judge's condition is that if the two differ the driver takes it to the user, it is
    /// never settled silently. NO assertion about page movement around the press (the editors' own undo scrolls the restored change into
    /// view: the e2e-verify rule).
    /// TODAY: passes (CodeMirror's undo scrolls the pre-op caret into view). BREAK: none (a control; the claim is parity with Rich Text).
    func testMdDupUndoScrollShowsCaret_book6() {
        mdDupRunUndoScroll(editor: .markdown, method: #function)
    }

    /// E5RT (CONTROL, Rich Text twin of E5): the same scenario in Rich Text, on the same section of the same book.
    func testRtDupUndoScrollShowsCaret_book6() {
        mdDupRunUndoScroll(editor: .richText, method: #function)
    }

    func mdDupRunUndoScroll(editor: Phase4bRedoEditor, method: String) {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        let markdown = editor == .markdown
        guard mdDupStart(.book6, method: method, markdown: markdown, seed: Self.dupSeed(under: title, level: 2)),
              mdDupRequireSection(title) != nil, let card = bringSidebarCardIntoView(title) else { return }
        mdDupNavigate(to: card)
        if markdown {
            guard mdDupPlaceCaret(inSection: title, line: Self.dupLineOne, search: true) != nil else {
                mdDupShot("md-dup-e5-caret-not-placed")
                fail("TEST-SETUP: the original's Dup01 line was not found in Markdown; the status bar read \(landingReads)")
                return
            }
        } else {
            guard let leaf = mdDupVisibleLeaf(Self.dupLineOne, timeout: capped(90)),
                  mdDupClickEnd(of: leaf, words: 6, what: "the original's on-screen Dup01 line (Rich Text)") else {
                fail("TEST-SETUP: the caret could not be placed at the end of the original's Dup01 line in Rich Text")
                return
            }
        }
        guard mdDupChooseDuplicate(title: title, settled: true) != nil, let copyCard = bringSidebarCardIntoView(copyTitle) else { return }
        mdDupNavigate(to: copyCard)
        let atCopy = mdDupLanded(on: Self.dupLineOne, timeout: 30)
        let beforeTop = atCopy.map { $0.frame.minY - app.editorArea.frame.minY }
        note("BEFORE Cmd-Z: the page was taken to the copy; a Dup01 line is on screen: \(Self.yesNo(atCopy != nil)); its top is "
            + "\(beforeTop.map { String(Int($0)) } ?? "n/a") pt below the editor band's top")
        var soft = mdDupSoft()
        let undo = mdDupPress(redo: false, number: 1)
        result(undo.summary)
        soft.check(undo.decision == "structural" && undo.performed, "Cmd-Z was decided \(undo.decision) (performed: \(undo.performed))")
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's card is still in the Outline after Cmd-Z")
        mdDupSettle(gone: [copyTitle])
        let after = mdDupSettledLineTop(Self.dupLineOne)
        mdDupShot("md-dup-e5-\(markdown ? "md" : "rt")-after-undo")
        let placed = after.top.map {
            "fully on screen, its top \(Int($0)) pt below the band's top (band height \(Int(after.editorHeight)) pt)"
        } ?? "NOT fully on screen"
        result("UNDO SCROLL (\(editor.name)): after Cmd-Z the caret line \"\(Self.dupLineOne)\" is "
            + placed
            + "; series of readings \(after.series)")
        soft.check(after.top != nil, "after Cmd-Z the caret line \"\(Self.dupLineOne)\" is not fully on screen (series: \(after.series))")
        mdDupAssert(soft, "\(editor.name): caret at the original's Dup01 line, Duplicate, go to the copy, Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - E6 Delete, Duplicate, Cmd-Z twice (the Delete stays quick-undoable)

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E6. CLAIM: a footnote-free level-3 sub-section of chapter 3 is deleted, "3.6 Conclusion" is duplicated, and Cmd-Z is pressed twice
    /// straight after each other with every queued job held 3.5 s (so the second press meets the first one's job): the copy is gone, then
    /// the deleted sub-section is back, BOTH presses are quick (`start (quick...`), no "Undoing..." notice, and the document equals the one
    /// before. An earlier Delete stays quick-undoable after a Duplicate because the new click does NOT bump `structuralOutOfQueueGeneration`.
    /// TODAY: FAILS. The old body bumps the generation: the Delete's undo goes the slow route ("Undoing...") and so does the Duplicate's.
    /// BREAK: bump `structuralOutOfQueueGeneration` at the click (swift-U7.patch): "Delete not quick" / an "Undoing..." notice.
    func testMdDupDeleteThenDupHeldUndoUndo_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              let chapterRange = mdDupRequireSection(Self.chapter(3)), mdDupRequireSection(title) != nil else { return }
        guard let target = mdDupFootnoteFreeSubsection(in: chapterRange) else {
            fail("TEST-SETUP: chapter 3 holds no footnote-free level-3 sub-section to delete")
            return
        }
        note("SCENARIO: delete the footnote-free sub-section \"\(target.title)\" (rows \(target.range)), duplicate \"\(title)\", Cmd-Z twice")
        guard let deleteCard = bringSidebarCardIntoView(target.title) else { return }
        let deleteFrom = mdDupChooseSidebarItem(deleteCard, item: "Delete Section")
        var soft = mdDupSoft()
        soft.check(mdDupWaitForCard(target.title, present: false, timeout: mdDupAppWait(size.operationTimeout, before: "the deleted card leaves")),
            "the card \"\(target.title)\" is still in the Outline after Delete Section")
        guard mdDupChooseDuplicate(title: title, settled: false) != nil else { return }
        let twoFrom = mdDupTraceCount()
        app.activateAndWaitForForeground()
        mdDupPressUndo()
        mdDupPressUndo()
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's card is still in the Outline after the two Cmd-Z presses")
        let deletedBackWait = mdDupAppWait(size.operationTimeout * 2, before: "the deleted card is back")
        soft.check(mdDupWaitForCard(target.title, present: true, timeout: deletedBackWait),
            "the deleted sub-section's card \"\(target.title)\" is not back after the two Cmd-Z presses")
        mdDupSettle(gone: [copyTitle], back: [target.title])
        let runs = mdDupQuickRuns(from: twoFrom, label: "undo")
        let progress = mdDupProgressToasts(from: twoFrom)
        let runKinds = runs.map { $0.quick ? "quick" : "SLOW" }
        result("DOUBLE Cmd-Z: \(runs.count) undo run(s) \(runKinds); \"Undoing / Redoing\" notices \(progress.slow.count); "
            + "\"Finishing the last change\" notices \(progress.finishing.count) (legitimate when the second press waits over 1 s)")
        soft.check(runs.count == 2 && runs.allSatisfy(\.quick),
            "the two Cmd-Z presses ran as \(runs.map { $0.quick ? "quick" : "slow" }), "
            + "expected two quick undos (the Delete must stay quick-undoable)")
        soft.check(progress.slow.isEmpty, "\(progress.slow.count) \"Undoing...\" / \"Redoing...\" toast line(s): \(progress.slow.prefix(2))")
        mdDupAddRowChecks("after Cmd-Z x2 (settled)", expectedUser: mdDupExpectedRows(range: nil), managed: mdDupPreManaged, to: &soft)
        let refused = mdDupLogLines(containing: "[STRUCT-TRACE] routing-refused", from: twoFrom).filter { !$0.text.contains(" failed=latched ") }
        soft.check(refused.isEmpty, "a Cmd-Z of the double press was refused: \(refused.map(\.text))")
        let fallbacks = mdDupFallbackEvidence(from: deleteFrom)
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        mdDupShot("md-dup-e6-end")
        mdDupAssert(soft, "Markdown: Delete a sub-section, Duplicate \"\(title)\", Cmd-Z twice, on \(size.identifier)")
    }
}

// MARK: - E7 A footnoted, cited section, no waits

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E7. CLAIM (the judge's acceptance test for the sync-model finding): "2.2 The Village Registers" of the six-chapter book holds two
    /// footnote references and citations. It is duplicated STRAIGHT after the scenario started (no wait before) and Cmd-Z / Cmd-Shift-Z
    /// are pressed STRAIGHT after the copy's card shows (no wait after). The test types nothing and the copy shares the original's labels,
    /// so no footnote renumber is due: THE UNDO TAKES EXACTLY ONE PRESS (the structural undo) AND THE REDO EXACTLY ONE (asserted; the
    /// footnote burst timer that used to add a text step of its own, board t-f1a22aa7, now stands aside while the Duplicate is unfinished;
    /// a pin of the counts, not a break detector). When it is quiet: the copy is there, the copy SHARES the original's footnote definitions
    /// (the Notes rows are exactly those of the document before, one definition per label), the editor text equals the table. A second,
    /// polled Cmd-Z then
    /// restores the document as loaded. LOGGED (judge D5, board t-53a9fb75): whether the Duplicate made the app run a bibliography or Notes
    /// rebuild push or show any toast (the content state `bibliographyUpdate` writes no log line of its own, the rebuild pushes do).
    /// TODAY: FAILS (no `sectionDuplicate-editor-first` line; the old body forces a footnote / bibliography resync and its undo shows toasts).
    /// BREAK: the straight-away undo / redo act too early or on stale rows when the undo's hold is handed off before the reinsert
    /// (swift-U6.patch) or the quick route does not wait for the hold (swift-U5d.patch): the rows differ from the page after the settle. The
    /// "Notes holds a label twice" break (the job also copies the section's Notes definitions) is not a 1-5 line change, so it has no patch.
    func testMdDupFootnotedChapter_book6() {
        let title = "2.2 The Village Registers"
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title) else { return }
        let refs = Phase4bFlow.footnoteRefsInRange(pre, range)
        let citations = pre[range].reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        var soft = mdDupSoft()
        soft.check(
            refs >= 1 && citations >= 1,
            "TEST-SETUP: \"\(title)\" holds \(refs) footnote reference(s) and \(citations) citation(s), expected at least one of each")
        let definitionsBefore = Phase4bFlowWalk(rows: pre).definitions.count
        note("FOOTNOTED SECTION: \"\(title)\" rows \(range.lowerBound)..<\(range.upperBound), "
            + "\(refs) footnote reference(s), \(citations) citation bracket(s); "
            + "the document has \(definitionsBefore) footnote definition(s)")
        guard let card = bringSidebarCardIntoView(title) else { return }
        mdDupMakeRoomBelow(card, title: title)
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        let shown = mdDupCard(copyTitle).waitForExistence(timeout: mdDupAppWait(size.operationTimeout, before: "the copy's card shows"))
        soft.check(shown, "the copy's card \"\(copyTitle)\" never showed")
        // No wait: the keys straight after the card shows.
        let undoPresses = mdDupUndoUntilStructural()
        // The redo is POLLED too (review F13): until a structural redo has performed, at most 6 presses (the cap only bounds a failing run).
        let redoPresses = mdDupRedoUntilStructural()
        mdDupReport("undo straight away", undoPresses)
        mdDupReport("redo straight away", redoPresses)
        // THE PRESS COUNTS ARE ASSERTED (t-f1a22aa7, Phase 4c). This test types nothing (the two Dup lines are seeded in the file) and the copy
        // shares the original's footnote labels, so no footnote renumber is due after the Duplicate: the undo is ONE press (the structural
        // undo) and the redo is ONE press (the structural redo). Before the fix the footnote burst timer could fire inside the Duplicate's
        // unfinished work and add a text step of its own (a renumber), which made the polled loops take two presses. A pin of the counts, not
        // a break detector: with the timer's stand-aside switched off this test can still pass (nothing here makes a renumber due).
        result("PRESS COUNTS (asserted, t-f1a22aa7): the undo took \(undoPresses.count) press(es) (expected exactly 1), "
            + "the redo took \(redoPresses.count) press(es) (expected exactly 1)")
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the first Cmd-Z series did not reach the structural undo within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(redoPresses.last?.isStructural == true && redoPresses.last?.performed == true,
            "the Cmd-Shift-Z series did not reach a performed structural redo within \(Self.pressCap) presses (\(redoPresses.map(\.summary)))")
        soft.check(undoPresses.count == 1,
            "the undo took \(undoPresses.count) presses, expected exactly 1 (the structural undo): "
            + "\(max(0, undoPresses.count - 1)) text step(s) stood before it, a footnote renumber of its own (t-f1a22aa7) "
            + "or typing the test never made (\(undoPresses.map(\.summary)))")
        soft.check(redoPresses.count == 1,
            "the redo took \(redoPresses.count) presses, expected exactly 1 (the structural redo): "
            + "\(max(0, redoPresses.count - 1)) text step(s) stood before it, a footnote renumber of its own (t-f1a22aa7) "
            + "(\(redoPresses.map(\.summary)))")
        soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "the copy's card \"\(copyTitle)\" is not back after the straight-away Cmd-Z / Cmd-Shift-Z")
        mdDupSettle(back: [copyTitle])
        let withCopy = mdDupExpectedRows(range: range)
        let post = mdDupAddRowChecks(
            "after Duplicate, Cmd-Z, Cmd-Shift-Z (settled)", expectedUser: withCopy, managed: mdDupPreManaged, walk: false, to: &soft)
        let walk = Phase4bFlowWalk(rows: post)
        let labels = walk.definitions.map(\.number)
        soft.check(
            walk.definitions.count == definitionsBefore,
            "\(walk.definitions.count) footnote definition(s) now, \(definitionsBefore) before: the copy must share the definitions")
        soft.check(Set(labels).count == labels.count, "the Notes hold a footnote label twice: \(labels)")
        let rebuilds = mdDupLogLines(containing: "bibliography-rebuild-push", from: from).count
            + mdDupLogLines(containing: "notes-rebuild-push", from: from).count
        let stateLines = mdDupLogLines(containing: "bibliographyUpdate", from: from).count
        let toasts = mdDupLogLines(containing: "[toast] show", from: from).map { String($0.text.suffix(90)) }
        result("FINDING C CHECK (judge D5, t-53a9fb75): bibliography / Notes rebuild push line(s) since the click: \(rebuilds); log lines naming "
            + "`bibliographyUpdate`: \(stateLines); toast lines: \(toasts.count) \(toasts.prefix(4))")
        mdDupShot("md-dup-e7-copy-back")
        // Rebuild pushes after the click window are REPORTED (the FINDING C line above), not asserted; the click window itself must have none.
        // A Cmd-Shift-Z that finds nothing left to redo beeps legitimately here, so beeps are reported, not asserted.
        mdDupAddMechanismChecks(from: from, duplicates: 1, checkBeeps: false, to: &soft)
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "after the straight-away undo / redo", to: &soft)

        // The copy is taken out again: polled Cmd-Z, then the document is the one as loaded.
        let secondUndo = mdDupUndoUntilStructural()
        mdDupReport("undo at the end", secondUndo)
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's card is still in the Outline after the final Cmd-Z")
        mdDupSettle(gone: [copyTitle])
        mdDupAddRowChecks("after the final Cmd-Z (settled)", expectedUser: mdDupExpectedRows(range: nil), managed: mdDupPreManaged, to: &soft)
        mdDupAssert(soft, "Markdown: Duplicate the footnoted, cited section with no waits, undo / redo, undo, on \(size.identifier)")
    }
}

// MARK: - E8 The last chapter, right before Notes and Bibliography

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E8. CLAIM: the last chapter of the twelve-chapter book (the row after it is Notes) is duplicated: the copy lands BEFORE Notes (the
    /// block table is the document plus the copy, then the Notes and Bibliography rows byte for byte as before), the Outline still has its
    /// "Notes" card, and the editor text equals the table (Save Version: the page's Notes and Bibliography regions are intact too).
    /// TODAY: predicted to fail on the mechanism line only (no `sectionDuplicate-editor-first` line); the row, Notes and screen-equals-
    /// database checks are about the end state the old body also reaches, and are reported either way.
    /// BREAK: ignore the page's `stopLine` so the copy is inserted after Notes (swift-U9.patch / web-WD3a.patch): "copy after Notes" /
    /// "the Notes / Bibliography rows are not those expected".
    func testMdDupLastChapterBeforeNotes_book12() {
        let title = Self.chapter(12)
        let copyTitle = title + " copy"
        guard mdDupStart(.book12, method: #function), let range = mdDupRequireSection(title) else { return }
        var soft = mdDupSoft()
        soft.check(range.upperBound < pre.count && pre[range.upperBound].isManaged,
            "TEST-SETUP: the row after \"\(title)\" is not a Notes or Bibliography row")
        let notesRows = pre.filter(\.isNotes).count
        let bibliographyRows = pre.filter(\.isBibliography).count
        note("LAST CHAPTER: \"\(title)\" is rows \(range.lowerBound)..<\(range.upperBound) of \(pre.count); "
            + "\(notesRows) Notes row(s), \(bibliographyRows) Bibliography row(s) follow")
        guard let from = mdDupChooseDuplicate(title: title, settled: true) else { return }
        let expected = mdDupExpectedRows(range: range)
        let post = mdDupAddRowChecks("after the Duplicate (settled)", expectedUser: expected, managed: mdDupPreManaged, walk: false, to: &soft)
        soft.check(post.filter(\.isNotes).count == notesRows && post.filter(\.isBibliography).count == bibliographyRows,
            "Notes rows \(post.filter(\.isNotes).count) (before \(notesRows)), "
            + "Bibliography rows \(post.filter(\.isBibliography).count) (before \(bibliographyRows))")
        let firstManaged = post.firstIndex(where: \.isManaged)
        soft.check(
            firstManaged == expected.count,
            "the first Notes / Bibliography row is row \(firstManaged.map(String.init) ?? "n/a"), "
            + "expected \(expected.count): the copy is not right before them")
        soft.check(
            mdDupCard("Notes").exists || mdDupWaitForCard("Notes", present: true, timeout: 30),
            "the Outline has no \"Notes\" card after the Duplicate")
        soft.check(mdDupCard(copyTitle).exists, "the Outline has no card \"\(copyTitle)\"")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "after the Duplicate of the last chapter", to: &soft)
        mdDupShot("md-dup-e8-end")
        mdDupAssert(soft, "Markdown: Duplicate the last chapter before Notes and Bibliography, on \(size.identifier)")
    }
}

// MARK: - E9 A section-break root

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    static let breakLine = "Break01 paragraph after a section break."

    /// E9. CLAIM: the six-chapter book is seeded with ONE section break (`<!-- ::break:: -->` and the paragraph "Break01 paragraph after a
    /// section break." right before section 3.4; review F4: the old body's wrong landing was measured on this book, about 2600 pt away, while
    /// on the one-chapter article the row-arithmetic error is only 300 to 500 pt). The break's card (it reads just "§") is duplicated.
    /// ONE click on the SECOND "§" card (no scroll search, `rounds=0`) puts a Break01 line on screen in the upper part of the band. The copy
    /// sits directly after its original, so the landing alone cannot tell them apart (both Break01 lines can show): therefore the FIRST fully
    /// visible Break01 line is clicked at its end and a marker word is typed there. If the click landed on the copy's break, the original's
    /// Break01 line is above the screen and the first visible one is the copy's; if it landed on the ORIGINAL, the first visible one is the
    /// original's. The word must be in the SECOND Break01 row of the table (the copy's).
    /// Also: the block table has two section_break rows and two Break01 rows, the Outline has two "§" cards, no heading ends in " copy", and
    /// AFTER the screen-equals-database check (Save Version writes the page's text into the rows) every section_break row still reads exactly
    /// `<!-- ::break:: -->` and the editor's text has no "copy" after a break marker (review F3: the page-side " copy" suffix of web-WD2 shows
    /// only there, not in the rows the job wrote).
    /// TODAY: FAILS (no markers after the whole-document push, so the click lands about 2600 pt away; no `sectionDuplicate-editor-first` line).
    /// BREAK: add " copy" to the section-break root's line on the page (web-WD2.patch): a break row no longer equals `<!-- ::break:: -->`
    /// after the Save Version flush / the editor text shows "copy" after the break marker. Keep the original's marker (web-WD1a.patch): the
    /// word lands in the first Break01 row.
    func testMdDupSectionBreakRoot_book6() {
        guard mdDupStart(
            .book6, method: #function,
            seed: { WriteQueuePhase4bStructuralQueueE2ETests.withSectionBreaks($0, before: ["3.4 Bridges and Boundaries"]) })
        else { return }
        let breakMarker = "<!-- ::break:: -->"
        let breaksBefore = pre.filter { $0.type == "section_break" }.count
        var soft = mdDupSoft()
        soft.check(breaksBefore == 1 && pre.filter { $0.fragment == Self.breakLine }.count == 1,
            "TEST-SETUP: the seeded book holds \(breaksBefore) section_break row(s) and "
            + "\(pre.filter { $0.fragment == Self.breakLine }.count) Break01 row(s), expected 1 and 1")
        guard let card = bringSidebarCardIntoView("§") else { return }
        mdDupMakeRoomBelow(card, title: "§")
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        let secondShown = mdDupWaitForCount(of: "§", atLeast: 2, timeout: mdDupAppWait(size.operationTimeout, before: "the second § card shows"))
        soft.check(secondShown, "the Outline shows \(mdDupCards(titled: "§").count) \"§\" card(s) after the Duplicate, expected 2")
        guard let copyCard = mdDupBringIntoView(
            "the copy's \"§\"", resolve: { mdDupCards(titled: "§").count >= 2 ? mdDupCards(titled: "§")[1] : nil }) else { return }
        mdDupNavigate(to: copyCard)
        let landing = mdDupLanded(on: Self.breakLine, timeout: mdDupAppWait(60, before: "the Break01 line shows after one click"), useFirst: true)
        mdDupReportLanding("the second § card", landing, section: nil)
        mdDupShot("md-dup-e9-after-one-click")
        var typed = false
        if let landing {
            soft.check(landing.topFraction <= Self.landingTopFraction,
                "the first visible Break01 line is \(Int(landing.topFraction * 100)) percent down the editor band: "
                + "the click did not put the copy at the top")
            if mdDupClickEnd(of: landing.leaf, words: 6, what: "the first visible Break01 line") {
                mdDupTypeNow(" " + Self.breakMarker)
                typed = true
            } else {
                soft.check(false, "the caret could not be confirmed at the end of the first visible Break01 line")
            }
        } else {
            soft.check(
                false,
                "after ONE click on the second \"§\" card no Break01 line was fully on screen within 60 s (rounds=0): "
                + "the click did not land on the copy")
        }
        if typed {
            soft.check(
                mdDupWaitForSentenceInDatabase(Self.breakMarker, timeout: 90),
                "the marker word \"\(Self.breakMarker)\" never reached the block table")
        }
        mdDupSettle()
        let post = mdDupReadRows()
        let breaks = post.filter { $0.type == "section_break" }.count
        let lineRows = post.indices.filter { post[$0].fragment.hasPrefix(Self.breakLine) }
        let markedRows = post.indices.filter { post[$0].fragment.contains(Self.breakMarker) }
        let suffixed = post.filter { $0.headingLevel != nil && $0.fragment.trimmingCharacters(in: .whitespaces).hasSuffix(" copy") }
        soft.check(
            breaks == 2 && lineRows.count == 2,
            "the block table holds \(breaks) section_break row(s) and \(lineRows.count) Break01 row(s), expected 2 and 2")
        if typed {
            soft.check(lineRows.count == 2 && markedRows == [lineRows[1]],
                "the marker word is in row(s) \(markedRows); the Break01 rows are \(lineRows): it must be in the SECOND one (the copy's): "
                + "the click landed on the original's break, or the word went elsewhere")
        }
        soft.check(suffixed.isEmpty, "a heading ends with \" copy\" although the root is a section break: \(suffixed.map(\.fragment))")
        soft.check(post.count > pre.count && post.filter(\.isManaged).count == pre.filter(\.isManaged).count,
            "the block table has \(post.count) row(s) (\(pre.count) before) and \(post.filter(\.isManaged).count) "
            + "Notes / Bibliography row(s) (\(pre.filter(\.isManaged).count) before)")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "after the Duplicate of the section break", to: &soft)

        // After the flush: every break row is still exactly the marker, and the editor's text has no "copy" after a break marker (review F3).
        let flushed = mdDupReadRows()
        let breakRows = flushed.filter { $0.type == "section_break" }
        let wrong = breakRows.filter { $0.fragment.trimmingCharacters(in: .whitespacesAndNewlines) != breakMarker }
        soft.check(breakRows.count == 2 && wrong.isEmpty,
            "after the Save Version flush the block table holds \(breakRows.count) section_break row(s) (expected 2), "
            + "and \(wrong.count) of them do not read exactly `\(breakMarker)`: \(wrong.map(\.fragment))")
        if let screen = mdDupJoinedScreenText() {
            let breakShown = screen.contains("::break::")
            result("EDITOR TEXT after the flush: a break marker is on screen: \(Self.yesNo(breakShown)) "
                + "(the \"no copy after a break\" check below is vacuous when it is not)")
            soft.check(screen.range(of: #"::break::\s*-->\s*copy"#, options: .regularExpression) == nil,
                "the editor's text shows \"copy\" after a section-break marker: the page-side copy of the break root got a \" copy\" suffix")
        } else {
            note("EDITOR TEXT after the flush could not be read (no accessibility snapshot); the rows check above stands alone")
        }
        mdDupShot("md-dup-e9-end")
        mdDupAssert(soft, "Markdown: Duplicate a section break, ONE click on its copy's card, a word typed at the landed line, on \(size.identifier)")
    }

    /// Waits (a condition) until at least `count` sidebar cards are titled exactly `title`.
    func mdDupWaitForCount(of title: String, atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdDupCards(titled: title).count >= count { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }
}

// MARK: - E10 Timing (a REPORT)

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E10 (REPORT only, NO threshold: it asserts nothing about time). Duplicate "3.6 Conclusion" on the twelve-chapter book and record, on
    /// the test's clock (coarse: each existence check is an accessibility round trip) and on the app's own clock from its log: the click to
    /// the copy's card on screen, the click to the copy's rows in the block table, the click to the hold being released (the job applied and
    /// the live text flushed). The only assertions are the functional ones: the card shows and the rows arrive. Compare the figures with
    /// the Rich Text Duplicate's, which the plan names as the model.
    /// TODAY: it fails on the mechanism line only (no `sectionDuplicate-editor-first` line); the card and the rows arrive with the old body
    /// too. A REPORT, not a control.
    func testMdDupTiming_book12() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book12, method: #function, seed: Self.dupSeed(under: title, level: 2)),
              mdDupRequireSection(title) != nil, let card = bringSidebarCardIntoView(title) else { return }
        mdDupMakeRoomBelow(card, title: title)
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        let began = Date()
        var cardSeconds: Double?
        var rowsSeconds: Double?
        let deadline = Date(timeIntervalSinceNow: mdDupAppWait(size.operationTimeout * 2, before: "the copy shows"))
        repeat {
            if cardSeconds == nil, mdDupCard(copyTitle).exists { cardSeconds = Date().timeIntervalSince(began) }
            if rowsSeconds == nil, mdDupReadRows().contains(where: { $0.headingTitle == copyTitle }) { rowsSeconds = Date().timeIntervalSince(began) }
            if cardSeconds != nil, rowsSeconds != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        mdDupSettle()
        func figure(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "never" }
        result("TIMING REPORT (test's clock, coarse; no threshold): click to the copy's card on screen \(figure(cardSeconds)); "
            + "click to the copy's rows in the block table \(figure(rowsSeconds))")
        let click = mdDupLogLines(containing: "click-start", from: from).first { $0.text.contains(" sectionDuplicate op=") }
        let age = click.flatMap { Phase4bDelTraceLine($0) }.flatMap { Phase4bDelTypingParser.intAfter("age=", in: $0.step) }
        let clickWall = click?.date.map { $0.addingTimeInterval(-Double(age ?? 0) / 1000) }
        func appMs(_ needle: String) -> String {
            guard let clickWall, let line = mdDupLogLines(containing: needle, from: from).first, let date = line.date else { return "n/a" }
            return "\(Int((date.timeIntervalSince(clickWall) * 1000).rounded())) ms"
        }
        result("TIMING REPORT (app's clock, from the log): click to `[MdWrite] structural hold raised` \(appMs("[MdWrite] structural hold raised")); "
            + "click to the first Outline render `[SidebarBody]` \(appMs("[SidebarBody]")); "
            + "click to `[MdWrite] structural hold released` (job applied, text flushed) "
            + "\(appMs("[MdWrite] structural hold released")); click-start event age \(age.map { "\($0) ms" } ?? "n/a")")
        var soft = mdDupSoft()
        soft.check(cardSeconds != nil, "the copy's card never showed")
        soft.check(rowsSeconds != nil, "the copy's rows never reached the block table")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupShot("md-dup-e10-end")
        mdDupAssert(soft, "Markdown: Duplicate timing report (no threshold), on \(size.identifier)")
    }
}

// MARK: - E11 A chapter with sub-sections: the copied sub-section's card

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E11. CLAIM: "Chapter 3" of the twelve-chapter book (with sub-sections 3.1 to 3.6 and their sub-sub-sections) is duplicated; ONE click
    /// on the card of the COPIED sub-section "3.1 Ledgers and Their Keepers" (the one below the "... copy" chapter card) lands on it with no
    /// scroll search: the seeded "Sub01 line" under that heading is on screen in the upper part of the band; a word typed at its end goes
    /// into a row INSIDE the copied chapter (after the "Chapter 3: ... copy" heading), and the nearest H1 above that row is the copy. Every
    /// copied leader got its own marker (a root-only rewrite leaves the sub-sections' markers pointing at the original).
    /// TODAY: FAILS (no markers; the click lands elsewhere and no Sub01 line is on screen).
    /// BREAK: rewrite only the root's marker (web-WD1b.patch): "went into row ..., outside the copied chapter" or no Sub01 line on screen.
    /// LIMIT (review F6): the landing line alone cannot tell the copied sub-section from the original's (same text); what tells them apart
    /// is WHERE the typed word ends up in the table (inside the copied chapter's rows or not), which is asserted.
    func testMdDupChapterWithSubsections_book12() {
        let chapter = Self.chapter(3)
        let copyChapter = chapter + " copy"
        let subTitle = "3.1 Ledgers and Their Keepers"
        guard mdDupStart(.book12, method: #function, seed: Self.dupSeed(under: subTitle, level: 2, lines: [Self.subLine])),
              let range = mdDupRequireSection(chapter), let subRow = mdDupRequireRow(Self.subLine) else { return }
        // Review F18: fail only when both the chapter's range and the Sub01 row were found and the row is outside the range.
        guard range.contains(subRow) else {
            fail("TEST-SETUP: the seeded Sub01 line (row \(subRow)) is not inside \"\(chapter)\" (rows \(range))")
            return
        }
        var soft = mdDupSoft()
        let subHeadings = pre[range].dropFirst().filter { $0.headingLevel != nil }.count
        note("THE CHAPTER \"\(chapter)\": \(range.count) rows, \(subHeadings) sub-section heading(s) after its own")
        soft.check(subHeadings >= 6, "TEST-SETUP: \"\(chapter)\" holds \(subHeadings) sub-section heading(s), expected at least 6")
        // No room-making for the 79-row chapter (review D3): the copied sub-section's card is brought into view by its own lookup below.
        guard let from = mdDupChooseDuplicate(title: chapter, settled: false, makeRoom: false) else { return }
        guard let subCard = mdDupBringIntoView("the copied \"\(subTitle)\"", resolve: {
            let chapterCard = mdDupCard(copyChapter)
            guard chapterCard.exists else { return nil }
            return mdDupCards(titled: subTitle).first { $0.frame.minY > chapterCard.frame.minY }
        }) else { return }
        mdDupNavigate(to: subCard)
        let landing = mdDupLanded(on: Self.subLine, timeout: mdDupAppWait(60, before: "the copied sub-section's Sub01 line shows after one click"))
        mdDupReportLanding("the copied sub-section's card", landing, section: nil)
        mdDupShot("md-dup-e11-after-one-click")
        guard let landing else {
            soft.check(
                false,
                "after ONE click on the copied \"\(subTitle)\" card no Sub01 line was fully on screen within 60 s (rounds=0): "
                + "the click did not land on the copy")
            mdDupAssert(soft, "Markdown: Duplicate a chapter with sub-sections, ONE click on a copied sub-section's card, on \(size.identifier)")
            return
        }
        soft.check(landing.topFraction <= Self.landingTopFraction, "the Sub01 line is \(Int(landing.topFraction * 100)) percent down the editor band")
        guard mdDupClickEnd(of: landing.leaf, words: 6, what: "the Sub01 line the click landed on") else {
            fail("TEST-SETUP: the caret could not be confirmed at the end of the landed Sub01 line")
            return
        }
        mdDupTypeNow(" " + Self.subMarker)
        soft.check(mdDupWaitForSentenceInDatabase(Self.subMarker, timeout: 90), "the marker word \"\(Self.subMarker)\" never reached the block table")
        mdDupSettle()
        let post = mdDupReadRows()
        let marked = post.indices.filter { post[$0].fragment.contains(Self.subMarker) }
        soft.check(marked.count == 1, "the marker word is in \(marked.count) row(s), expected exactly 1")
        if let markedRow = marked.first, let copyRange = Phase4bFlow.sectionRange(copyChapter, in: post) {
            soft.check(
                copyRange.contains(markedRow),
                "the marker word went into row \(markedRow), outside the copied chapter (rows \(copyRange)): "
                + "the click landed on the ORIGINAL's sub-section")
            let nearestH1 = post[..<markedRow].last { $0.headingLevel == 1 }?.headingTitle
            soft.check(
                nearestH1 == copyChapter,
                "the nearest chapter heading above the typed row is \"\(nearestH1 ?? "n/a")\", expected \"\(copyChapter)\"")
        } else {
            soft.check(false, "the copied chapter \"\(copyChapter)\" or the marked row is missing from the block table")
        }
        let expectedLine = Self.subLine + " " + Self.subMarker
        let copyOffset = subRow - range.lowerBound
        mdDupAddRowChecks(
            "after the Duplicate and the typing (settled)", expectedUser: mdDupExpectedRows(range: range, copyTyped: [copyOffset: expectedLine]),
            managed: nil, walk: false, to: &soft)
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        mdDupAssert(soft, "Markdown: Duplicate a chapter with sub-sections, ONE click on a copied sub-section's card, on \(size.identifier)")
    }
}

// MARK: - E12 The same section twice, straight after each other

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E12 (an END-STATE check of two Duplicates in a row; review F7/F8). CLAIM: "3.6 Conclusion" is duplicated and, straight after,
    /// duplicated AGAIN. Both copies carry the title "3.6 Conclusion copy", so they are told apart by a word typed into each through its own
    /// card: the upper copy gets "ORDERMARKA", the lower "ORDERMARKB". Afterwards the Outline lists the original above both copies; the
    /// block table lists the original's rows, then the upper copy (with A), then the lower copy (with B); no failure line; and the editor
    /// text equals the table (Save Version): the page order (X, copy 2, copy 1) is the Outline's order is the rows' order.
    /// WHAT THIS DOES NOT CLAIM: that the second click is HELD behind the first one's job. The second Duplicate is a full right-click plus
    /// menu choice (7 to 10 s in the VM), so even with every job held 3.5 s (set, so the pair overlaps where the host is fast) it will
    /// normally find the first job finished. "The second command is held, never refused" is covered by the unit test U18
    /// (`MarkdownEditorFirstDuplicateTests`), where the job is held for as long as the test wants.
    /// TODAY: FAILS (the old body logs no `sectionDuplicate-editor-first` line for either click).
    /// BREAK: none for THIS test. swift-U18.patch (remove `await writer.awaitStructuralHoldReleased()` from the new click) cannot fail it
    /// without an overlap; it breaks unit test U18.
    func testMdDupSameSectionTwiceAtOnce_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title), let card = bringSidebarCardIntoView(title) else { return }
        mdDupMakeRoomBelow(card, title: title)
        var soft = mdDupSoft()
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        let secondFrom = mdDupChooseSidebarItem(card, item: "Duplicate Section", activate: false)
        result("TWO CLICKS: the first at log line \(from), the second at log line \(secondFrom)")
        soft.check(mdDupWaitForCount(of: copyTitle, atLeast: 2, timeout: mdDupAppWait(size.operationTimeout * 2, before: "both copies' cards show")),
            "the Outline shows \(mdDupCards(titled: copyTitle).count) card(s) \"\(copyTitle)\" after two Duplicates, expected 2")
        soft.check(mdDupFailureLine(from: from) == nil, "a refusal or failure was logged: \(mdDupFailureLine(from: from) ?? "")")
        let bothRowsWait = mdDupAppWait(size.operationTimeout * 2, before: "both copies' rows are saved")
        soft.check(mdDupWaitForExactHeadings(copyTitle, equalTo: 2, timeout: bothRowsWait) == 2,
            "the block table does not hold the copy's heading twice")
        mdDupSettle()
        mdDupAddMechanismChecks(from: from, duplicates: 2, to: &soft)
        let cards = mdDupCards(titled: copyTitle)
        let originalCards = mdDupCards(titled: title)
        // `mdDupCards` sorts by position, so "copy 1 above copy 2" is true by construction and is not asserted; the original above both is.
        if cards.count == 2, let original = originalCards.first {
            soft.check(original.frame.minY < cards[0].frame.minY,
                "the Outline does not list the original above both copies (y \(Int(original.frame.minY)), "
                + "copies \(Int(cards[0].frame.minY)) and \(Int(cards[1].frame.minY)))")
        }
        // Tell the copies apart: a word into each, through its own card.
        for (index, marker) in [Self.orderMarkerA, Self.orderMarkerB].enumerated() {
            guard let copyCard = mdDupBringIntoView("copy number \(index + 1) of \"\(copyTitle)\"", resolve: {
                let found = mdDupCards(titled: copyTitle)
                return found.count > index ? found[index] : nil
            }) else { return }
            mdDupNavigate(to: copyCard)
            let lineWait = mdDupAppWait(60, before: "copy \(index + 1)'s Dup line shows")
            guard let landing = mdDupLanded(on: Self.dupLineOne, timeout: lineWait, useFirst: index == 0),
                  mdDupClickEnd(of: landing.leaf, words: 6, what: "copy \(index + 1)'s Dup01 line") else {
                mdDupShot("md-dup-e12-copy-\(index + 1)-not-found")
                fail("TEST-SETUP: copy \(index + 1)'s Dup01 line could not be found or confirmed after its card was clicked")
                return
            }
            mdDupTypeNow(" " + marker)
        }
        soft.check(mdDupWaitForSentenceInDatabase(Self.orderMarkerA, timeout: 90) && mdDupWaitForSentenceInDatabase(Self.orderMarkerB, timeout: 90),
            "the marker words never both reached the block table")
        mdDupSettle()
        let lineA = Self.dupLineOne + " " + Self.orderMarkerA
        let lineB = Self.dupLineOne + " " + Self.orderMarkerB
        var expected = mdDupExpectedRows(range: range, copyTyped: [1: lineA])
        let secondCopy = Array(mdDupExpectedRows(range: range, copyTyped: [1: lineB])[range.upperBound..<(range.upperBound + range.count)])
        expected.insert(contentsOf: secondCopy, at: range.upperBound + range.count)
        let post = mdDupAddRowChecks("after two Duplicates and the markers (settled)", expectedUser: expected, managed: mdDupPreManaged, to: &soft)
        let a = post.firstIndex { $0.fragment == lineA }
        let b = post.firstIndex { $0.fragment == lineB }
        soft.check(
            a != nil && b != nil && a! < b!,
            "the upper copy's marker is at row \(a.map(String.init) ?? "n/a"), "
            + "the lower copy's at row \(b.map(String.init) ?? "n/a"): not in the Outline's order")
        mdDupAddScreenEqualsDatabaseCheck(before: post, what: "after two Duplicates of the same section", to: &soft)
        mdDupShot("md-dup-e12-end")
        mdDupAssert(soft, "Markdown: Duplicate \"\(title)\" twice straight after each other, on \(size.identifier)")
    }
}

// MARK: - E13 Duplicate, Delete the copy at once, Cmd-Z twice

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E13. CLAIM: "3.6 Conclusion" is duplicated and the COPY is deleted straight after (review F9: the Delete is a full right-click plus
    /// menu choice, 7 to 10 s in the VM, so by then the copy's rows normally exist already; with the 3.5 s job hold set, whether the
    /// Duplicate's job was still pending at the Delete is REPORTED, not asserted; the case of a copy that exists only in the Outline's
    /// overlay is covered by the unit tests). Cmd-Z #1 brings the copy back, Cmd-Z #2 takes it out again: both are QUICK undos
    /// (`start (quick...`), no "Undoing..." notice, and the document is the one as loaded.
    /// TODAY: FAILS (the old body bumps the generation: the Delete's undo and the Duplicate's undo go the slow route, "Undoing...").
    /// BREAK: do not record `efRecordedStructGeneration[opId]` in the click (swift-U20.patch): "the Duplicate's Cmd-Z took the slow route".
    func testMdDupThenDeleteCopyAtOnceUndoTwice_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              mdDupRequireSection(title) != nil, let card = bringSidebarCardIntoView(title) else { return }
        mdDupMakeRoomBelow(card, title: title)
        let band = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        var soft = mdDupSoft()
        let from = mdDupChooseSidebarItem(card, item: "Duplicate Section")
        guard let copyCard = mdDupCopyCardAtOnce(copyTitle, band: band) else { return }
        let deleteFrom = mdDupChooseSidebarItem(copyCard, item: "Delete Section", activate: false)
        let duplicateJobDone = !mdDupLogLines(containing: "[MdWrite] structural hold released", from: from).isEmpty
        result("DELETE vs THE DUPLICATE'S JOB (reported, not asserted): when the Delete was chosen (log line \(deleteFrom)) the Duplicate's job was "
            + (duplicateJobDone ? "already done" : "still pending") + " (its hold had " + (duplicateJobDone ? "" : "not yet ") + "been released)")
        let copyGoneWait = mdDupAppWait(size.operationTimeout, before: "the deleted copy's card leaves")
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: copyGoneWait),
            "the copy's card \"\(copyTitle)\" is still in the Outline after Delete Section on it")
        let undoFrom = mdDupTraceCount()
        let first = mdDupPress(redo: false, number: 1, watchToasts: true)
        result(first.summary + "; toasts in the first 1.2 s \(first.toasts)")
        soft.check(first.decision == "structural" && first.performed, "Cmd-Z #1 was decided \(first.decision) (performed: \(first.performed))")
        soft.check(mdDupWaitForCard(copyTitle, present: true, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy comes back")),
            "the copy's card is not back after Cmd-Z #1 (the undo of the Delete)")
        let second = mdDupPress(redo: false, number: 2, watchToasts: true)
        result(second.summary + "; toasts in the first 1.2 s \(second.toasts)")
        soft.check(second.decision == "structural" && second.performed, "Cmd-Z #2 was decided \(second.decision) (performed: \(second.performed))")
        soft.check(mdDupWaitForCard(copyTitle, present: false, timeout: mdDupAppWait(size.operationTimeout * 2, before: "the copy leaves again")),
            "the copy's card is still in the Outline after Cmd-Z #2 (the undo of the Duplicate)")
        mdDupSettle(gone: [copyTitle])
        let runs = mdDupQuickRuns(from: undoFrom, label: "undo")
        let progress = mdDupProgressToasts(from: undoFrom)
        let runKinds = runs.map { $0.quick ? "quick" : "SLOW" }
        result("TWO UNDOS: \(runs.count) undo run(s) \(runKinds); \"Undoing / Redoing\" notices \(progress.slow.count); "
            + "\"Finishing the last change\" notices \(progress.finishing.count)")
        soft.check(
            runs.count == 2 && runs.allSatisfy(\.quick),
            "the two Cmd-Z presses ran as \(runs.map { $0.quick ? "quick" : "slow" }), expected two quick undos")
        soft.check(progress.slow.isEmpty, "\(progress.slow.count) \"Undoing...\" / \"Redoing...\" toast line(s): \(progress.slow.prefix(2))")
        soft.check(!first.toasts.contains { $0.contains("Undoing") } && !second.toasts.contains { $0.contains("Undoing") },
            "the toast element showed \"Undoing...\": \(first.toasts) \(second.toasts)")
        mdDupAddRowChecks("after Cmd-Z x2 (settled)", expectedUser: mdDupExpectedRows(range: nil), managed: mdDupPreManaged, to: &soft)
        let fallbacks = mdDupFallbackEvidence(from: from)
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        mdDupShot("md-dup-e13-end")
        mdDupAssert(soft, "Markdown: Duplicate, Delete the copy at once, Cmd-Z twice, on \(size.identifier)")
    }
}

// MARK: - E14 Type in the copy, close at once, reopen

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E14. CLAIM: "3.6 Conclusion" is duplicated (every queued job held 3.5 s so a job is pending on a fast host too: NOT asserted, only
    /// reported), a sentence is typed at the end of the copy's Dup01 line, and Cmd-W (Close Project) is pressed at once; the project is
    /// reopened and the copy AND the sentence are in the saved project exactly once, the Outline has the copy's card.
    /// CONTROL (review F10). The 3.5 s hold has normally expired by the time the UI driver has typed the sentence and pressed Cmd-W (each
    /// UI step takes seconds in the VM), so the test cannot show that the CLOSE waits for a pending job; it shows that a Duplicate followed
    /// by typing in the copy and a close is saved whole, and it reports whether the hold was still up. The earlier check "the hold was
    /// released at least once" passed whatever the close did and was dropped.
    /// TODAY: predicted to pass or fail, reported either way (the old body finished its work before the user could type).
    /// BREAK (predicted, not proven: no patch was run): never hand the writer hold on to the step-8 continuation (the second hunk of
    /// swift-U22.patch): the hold stays raised, the close waits for it and is cancelled ("Couldn't close the project") or the sentence is
    /// missing after the reopen. No practical 1-5 line patch makes the "close does not wait for the job" case itself fail.
    func testMdDupTypeInCopyThenCloseAtOnceReopen_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              let range = mdDupRequireSection(title), let from = mdDupChooseDuplicate(title: title, settled: false),
              let copyCard = bringSidebarCardIntoView(copyTitle) else { return }
        mdDupNavigate(to: copyCard)
        guard mdDupPlaceCaret(inSection: copyTitle, line: Self.dupLineOne, search: true) != nil else {
            mdDupShot("md-dup-e14-caret-not-placed")
            fail("TEST-SETUP: the copy's Dup01 line was not found after the card click and a scroll search; the status bar read \(landingReads)")
            return
        }
        mdDupTypeNow(" " + Self.sentence)
        let pending = mdDupLogLines(containing: "[MdWrite] structural hold released", from: from).isEmpty
        result("CLOSE AT ONCE: the click's hold was still raised when Cmd-W was pressed: \(Self.yesNo(pending)) (reported, not asserted)")
        guard mdDupCloseProject(), mdDupRelaunch() else { return }
        var soft = mdDupSoft()
        soft.check(mdDupCard(copyTitle).exists || mdDupWaitForCard(copyTitle, present: true, timeout: capped(60)),
            "after the reopen the copy's card \"\(copyTitle)\" is not in the Outline")
        soft.check(
            mdDupWaitForSentenceInDatabase(Self.sentence, timeout: 60),
            "the sentence \"\(Self.sentence)\" is not in the saved project after the close and reopen")
        soft.check(mdDupBlocksContaining(Self.sentence) == 1, "the sentence is in \(mdDupBlocksContaining(Self.sentence)) row(s), expected exactly 1")
        let expected = mdDupExpectedRows(range: range, copyTyped: [1: Self.dupLineOne + " " + Self.sentence])
        mdDupAddRowChecks("after Cmd-W and the reopen", expectedUser: expected, managed: mdDupPreManaged, to: &soft)
        mdDupShot("md-dup-e14-reopened")
        mdDupAssert(soft, "Markdown: Duplicate, type in the copy, Cmd-W at once, reopen, on \(size.identifier)")
    }
}

// MARK: - E15 Save Version at once

extension WriteQueuePhase4bMdDuplicateEFE2ETests {
    /// E15. CLAIM: "3.6 Conclusion" is duplicated and File > Save Version is chosen straight after. Every queued job is held 3.5 s so the
    /// pair overlaps where the host is fast; the Save Version alert takes seconds to drive in the VM, so the job has normally finished
    /// before the save (review F11) and the test does NOT claim the save waited for a pending job. What it shows: the saved version holds
    /// the copy (its `previewMarkdown` has the heading "## 3.6 Conclusion copy" and its `snapshotSection` rows list "3.6 Conclusion copy";
    /// this proves only that the copy IS in the saved version, once; it is SUBSTITUTED for a look at the Version History window: finding a
    /// named section in the window's 20,000-point preview pane costs minutes of scrolling, see the precedent `versionSectionTitle`).
    /// The check with teeth is the ROW check afterwards: the table holds the document plus ONE copy (no second set of copy rows). THEN ONE
    /// click on the copy's card still lands on the copy (rounds=0): if the Save Version flush re-minted the heading ids the page's markers
    /// would all be stale and this fails. A failure is a general Markdown card-click bug: report, never skip. Where the copy's heading leaf
    /// is exposed it must be fully on screen above the landed Dup line (see `mdDupCheckLandingAfterClick`, which also states what a
    /// landing check can and cannot tell apart).
    /// TODAY: predicted to fail on the mechanism line only; the rest is reported either way (the old body re-mints ids with every
    /// whole-document rebuild, so the final card click may fail too).
    /// BREAK: none practical (this tests the shared flush; the claim is that the new path left the shared flush's ids alone).
    func testMdDupSaveVersionAtOnce_book6() {
        let title = Self.conclusion
        let copyTitle = title + " copy"
        guard mdDupStart(.book6, method: #function, env: [Self.holdKey: String(Self.jobHoldMs)], seed: Self.dupSeed(under: title, level: 2)),
              mdDupRequireSection(title) != nil, let from = mdDupChooseDuplicate(title: title, settled: false) else { return }
        var soft = mdDupSoft()
        // The click's mechanism is read BEFORE the save: the save's own flush is not part of what this check says about the click. The
        // `ok=true` line is written when the page answered, which can be a moment after the card shows: polled (review F12), then checked.
        let okWait = mdDupAppWait(size.operationTimeout, before: "the editor-first ok line is written")
        let okSeen = mdDupWaitForEditorFirstOk(from: from, timeout: okWait)
        result("EDITOR-FIRST OK LINE seen before the check: \(Self.yesNo(okSeen))")
        mdDupAddMechanismChecks(from: from, duplicates: 1, to: &soft)
        let name = Self.versionName
        let saved = mdDupSaveVersion(named: name)
        soft.check(saved, "the version \"\(name)\" was not saved")
        let snapshotId = dbText("SELECT id FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';")
        let preview = dbText("SELECT previewMarkdown FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';")
        let listed = dbInt(
            "SELECT count(*) FROM snapshotSection WHERE snapshotId = '\(FixtureDatabase.escape(snapshotId))' "
            + "AND title = '\(FixtureDatabase.escape(copyTitle))';")
        result("SAVED VERSION: the preview holds the copy's heading: \(Self.yesNo(preview.contains("## " + copyTitle))); "
            + "snapshotSection rows titled \"\(copyTitle)\": \(listed.map(String.init) ?? "n/a")")
        soft.check(
            preview.contains("## " + copyTitle),
            "the saved version's preview does not hold the heading \"## \(copyTitle)\": the Save Version did not wait for the Duplicate")
        soft.check(listed == 1, "the saved version lists \(listed.map(String.init) ?? "n/a") section(s) titled \"\(copyTitle)\", expected 1")
        mdDupSettle(back: [copyTitle])
        mdDupAddRowChecks(
            "after Duplicate and Save Version (settled)", expectedUser: mdDupExpectedRows(range: mdDupSection(title)),
            managed: mdDupPreManaged, to: &soft)
        mdDupCheckLanding("after Save Version", copyTitle: copyTitle, to: &soft, checkHeading: true)
        mdDupAssert(soft, "Markdown: Duplicate, Save Version at once, ONE click on the copy's card, on \(size.identifier)")
    }
}
