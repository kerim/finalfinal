//
//  WriteQueuePhase4bMdRestoreEFE2ETests.swift
//  final finalUITests
//
//  bt task t-4a8fd8af, PHASE 4b MARKDOWN SLICE 4, ROUND D: THE THREE VERSION HISTORY RESTORES IN MARKDOWN MODE, EDITOR FIRST, proven in the
//  real app. Until this slice a Markdown restore (Restore Entire Project, Replace Current Section, Insert as New Section) wrote the rows
//  first and then pushed the WHOLE document into the page (`setContent len=... anchorCount=0`): the push carried no `<!-- @sid:ID -->` markers
//  (the Outline card click then landed 1500 to 3200 points away), and Cmd-Z / Cmd-Shift-Z took the slow queued route. Now Swift writes the
//  rows' ids into the restored text as markers, the page swaps that text in with ONE change that touches only what differs, the Rich Text
//  job writes the rows behind anything typed, and Cmd-Z / Cmd-Shift-Z are quick. The design record is
//  .claude/superdev/write-queue-phase4b-markdown-restores/ (plan-v1.md section 4 "Real app (E)", plan-v1-addendum.md sections 8, 11, 12;
//  premise-check.md = what TODAY's code does, measured in this VM); the claim-to-test map is
//  docs/architecture/write-queue-plan/phase4b-markdown/slice4-restores/e2e-mapping.md.
//
//  CLASS NAME: after the TASK (vmtest's retry-refusal streak is keyed by class and method name across worktrees). The class inherits the
//  harness `Phase4bDelHarness` (WriteQueuePhase4bDeleteE2ETests.swift: launch, seeding, the app-log follower, the sidebar driving, the
//  evidence writer) and uses the pure helpers of WriteQueuePhase4bDeleteFlowE2ETests.swift (`Phase4bFlow`, `Phase4bFlowRow`,
//  `Phase4bFlowWalk`, `Phase4bFlowSoftChecks`), `Phase4bQuLog` and the static seed `withPlainLines`; it changes nothing in any of them. The
//  instance helpers of the other behaviour classes live in THEIR final classes and cannot be inherited, so the few this class needs are
//  copied here as methods prefixed `mdRst` (DEBT, the same as the slice 3 class: moving them into the harness is a clean-up for a later
//  task). It is ONE new permanent file (scripts/e2e-hygiene.sh allows one per branch), so it disables the file-length rule like every other
//  Phase 4b e2e file. The Version History driving is copied from the premise check that ran green in the VM
//  (`Phase4bMdRestorePremiseE2ETests`, run-1793283787-47727 and run-1793286414-66116).
//
//  THE DOCUMENTS (generated, never a manuscript; every note starts with the fixture tag `[<size> W<words> S<sections> C<citation groups>
//  F<footnote marks> L<characters>]`):
//    book6   x6 chapters:  349,810 characters, 408 citation groups,  54 footnote marks
//    book12  x12 chapters: 699,139 characters, 816 citation groups, 108 footnote marks
//  Chapter n is "# Chapter n: The Quiet Archive and Its Ledgers", then sections "## n.1 Ledgers and Their Keepers", "## n.2 The Village
//  Registers" (holds footnote references 3 and 4 of its chapter), ... "## n.6 Conclusion". Seeded plain lines: "Sub01 / Sub02 line of the
//  fixture document." directly under the chapter heading the test replaces (they are inside that heading's FLAT range, the restore's
//  target), and "Dup01 / Dup02 ..." under "1.1 Ledgers and Their Keepers" for the Insert and the timing tests.
//
//  EVERY METHOD: seed, launch, Cmd-/ to Markdown, Save Version "RST v1", ONE edit " RSTEDIT" at the end of a line the restore takes away
//  again, then the restore through Version History (Cmd-Opt-V, the version, the restore, the confirmation).
//
//  WHAT A CARD CLICK "LANDS" MEANS HERE (E1, E5): after ONE click on the Outline card the test scrolls NOTHING itself (`rounds=0`) and looks
//  (a condition, bounded 45 s on book12) for the seeded plain line fully inside the editor's visible band and in its upper 60 percent; it
//  then clicks the end of that line and the status bar (its outline button names the section the caret is in) must read the card's title.
//  Where the heading's own leaf is exposed in the accessibility tree it must also be fully visible above the landed line. TODAY the same
//  click lands 1500 to 3200 points away and the line is never on screen (premise check: found only in search round 6 of 12, or not at all).
//
//  THE TESTS (each says what it claims, what TODAY's code does, and its BREAK patch; the map is e2e-mapping.md)
//    E1   testMdRstSecCardLands_book12                    MUST-FAIL today   Replace on a middle chapter: ONE card click lands, rounds=0
//    E2   testMdRstSecTypeAfterClick_book12               CONTROL           typing straight after the click is kept on screen and in rows
//    E3   testMdRstSecUndoRedoQuickNoToast_book6          MUST-FAIL today   Replace: Cmd-Z / Cmd-Shift-Z / Cmd-Z quick, no toast
//    E4   testMdRstSecTypeInsideUndoRedo_book6            MUST-FAIL today   typing inside the restored section comes back after undo, redo
//    E5   testMdRstInsertAsNewCardUndo_book12             MUST-FAIL today   Insert as New: card lands before Notes, quick Cmd-Z; Notes CONTROL
//    E6   testMdRstWholeTypeUndoRedo_book6                MUST-FAIL today   Restore Entire Project, type, quick undo / redo, typing kept
//    E7   testMdRstWholeFootnotes_book6                   CONTROL           Notes of the page equal the Notes rows after the restore, after Cmd-Z
//    E8   testMdRstDeleteThenRestoreHeldUndoUndo_book6    MUST-FAIL today   Delete, Replace, Cmd-Z twice back to back: both quick, both act
//    E9   testMdRstTiming_book12                          MEASUREMENT       the three restores on book12: click to text, click to rows
//    E9b  testMdRstWholeHeavyDifferenceTiming_book12      MEASUREMENT       Restore Entire Project over a document that differs almost entirely
//    E10  testMdRstSecRestoredTextOnScreenWhileJobHeld_book6  MUST-FAIL today  the restored text is on screen while the rows still hold the old
//
//  WAITS: every wait is a CONDITION (a log line, a database row, the sidebar, the accessibility tree, a status-bar label); the keys of one
//  cycle are pressed one at a time and read from the editor's own `[UnifiedUndo] keydown` line. Typing is user-origin (typeText / typeKey).
//  Rows are read from the block table only after a poll that waits for them to match, never straight after a command. NO ASSERTION says
//  "the click arrives within N ms of a held job" (the UI driver needs 7 to 10 s for one Version History restore on a book): where a job hold
//  is switched on (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS` 3500, under the 4 s limit; `FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N` 1) the assertion is on
//  the app's OWN log and on the database at the moment the app's log says so, not on the test's clock. Query budgets on book12 are 45 s and
//  every lookup is an exact line. A typed line longer than about 40 characters WRAPS in the VM's editor column, so a typed sentence is looked
//  for in the joined text of the editor's runs. Notes labels are NEVER read from the accessibility tree (the WebView's tree drops content that
//  is on screen): E7 reads the Notes region of the PAGE through the Save Version round trip (File > Save Version writes the LIVE editor text
//  into the block table) and the rows through the database.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; several --scope flags make one run, never a comma list; the scope is
//  `final finalUITests/WriteQueuePhase4bMdRestoreEFE2ETests/<method>`; compare the number of `Test Case ... passed` lines with the number
//  of scopes after every run; at most two VM runs at once, the model checker paused for E3/E4/E6/E8/E9/E9b/E10):
//    scripts/vmtest/vmtest run --detach --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bMdRestoreEFE2ETests/testMdRstSecUndoRedoQuickNoToast_book6"
//
//  TIMING (E9, E9b): the OLD Markdown restore showed the restored text 2463 ms (Replace) and 2380 ms (Restore Entire) after its `start` line on
//  book12 and kept the app busy for 26 to 28 s afterwards (premise-check.md). The shipped Delete raises its hold in 573 ms and the Outline
//  reacts in 1.08 s (WriteQueuePhase4bMdDeleteE2ETests figures). The new restore has no threshold: the figures are printed as RESULT lines for
//  the hand-over, and the only assertion is that a click that took over 1.4 s showed the working notice "Finishing the last change...".
//

// swiftlint:disable file_length
import AppKit
import XCTest

// MARK: - Small value types of this class

/// Which of the three Version History restores a method uses.
enum MdRstKind {
    case entire
    case replace
    case insertAsNew

    /// The Swift sequence label the controller writes for it (`[STRUCT-TRACE] ... <label> op=<id> <step>`).
    var sequenceLabel: String {
        switch self {
        case .entire: return "restoreProject"
        case .replace: return "restoreSectionReplace"
        case .insertAsNew: return "restoreSectionDuplicate"
        }
    }

    var name: String {
        switch self {
        case .entire: return "Restore Entire Project"
        case .replace: return "Replace Current Section"
        case .insertAsNew: return "Insert as New Section"
        }
    }
}

/// One Cmd-Z or Cmd-Shift-Z as the editor's own `[UnifiedUndo] keydown` line reports it, with the wait for its `performed` line.
struct MdRstPress {
    let number: Int
    let redo: Bool
    /// `fallthrough` (a plain text step of the editor's own history), `structural`, `swallow` (held behind a running one), or `none` when
    /// the editor wrote no keydown line within 15 s (the key reached no editor).
    let decision: String
    let undoDepth: Int?
    let redoDepth: Int?
    /// The editor's document length when the press arrived (`docLength=` of the keydown line).
    let docLength: Int?
    /// For a text step: the editor's document length right after it (`docLengthAfter=` of the `keydown-path-invocation` line).
    let docLengthAfter: Int?
    /// For a structural or held press: its `performed` line arrived.
    let performed: Bool

    var isStructural: Bool { decision == "structural" || decision == "swallow" }

    var summary: String {
        "press \(number) (\(redo ? "redo" : "undo")): \(decision), undo depth \(undoDepth.map(String.init) ?? "n/a"), "
            + "redo depth \(redoDepth.map(String.init) ?? "n/a"), editor length at the press \(docLength.map(String.init) ?? "n/a"), "
            + "after a text step \(docLengthAfter.map(String.init) ?? "n/a")" + (isStructural ? (performed ? ", performed" : ", NOT performed") : "")
    }
}

/// One undo or redo sequence of the app's log (`[STRUCT-TRACE] ... undo|redo op=<id> <step>`), with what the real-app claims read from it.
struct MdRstRun {
    let label: String
    let opId: String
    /// The sequence began `start (quick, markdown)`.
    var startedQuickMarkdown = false
    /// The run's own "the page has swapped" line exists: `quick restore done (markdown)` for an undo, `quick restore redo done (markdown)`
    /// for a redo (code review C17: the redo writes its OWN words, so the undo's line cannot satisfy a redo's check).
    var restoreDone = false
    /// Any line of the slow queued road (`start (markdown queued ...`, `start (editor-first undo|redo)`, a plain `start`).
    var slowRoad = false
    var steps: [String] = []
}

/// Where a card click put the page: the line found, how far from the editor's top it is (0 is the top edge, 1 the bottom edge), and how many
/// leaves with that text were fully on screen.
struct MdRstLanding {
    let leaf: XCUIElement
    /// The leaf's frame AT THE MOMENT it was found (the leaf is an index into a query and can point at nothing once the page redraws).
    let frame: CGRect
    let topFraction: CGFloat
    let visibleCount: Int
}

/// Which card `mdRstCheckCardLanding` clicks and what it expects of the landing: the card's `title`, the `line` that must come fully on
/// screen, `useLast` (the card is the last of two that share the title) and `checkHeading` (the heading's own leaf is checked too).
struct MdRstCardTarget {
    let title: String
    let line: String
    let useLast: Bool
    let checkHeading: Bool
}

/// The figures of one restore click, all from the app's own log stamps (never from the test's steps).
struct MdRstTiming {
    /// The first log line after the confirm click to the page's `markdown-restore` line (the restored text is in the page).
    var clickToTextMs: Int?
    /// The `start (editor-first)` line to the page's line.
    var startToTextMs: Int?
    /// The first log line after the confirm click to `[MdWrite] structural hold released` (the job applied, the live text flushed).
    var clickToRowsMs: Int?
    /// The page's own `ms=` figure (plan, refined diff, dispatch).
    var pageMs: Int?
    var hunks: Int?
    var noticeSeen = false
}

/// What the Version History window's "Selected Version" pane has done so far while scrolling to a section (a copy of the structural class's walk).
struct MdRstPaneWalk {
    var rounds = 0
    var scrolledDown: CGFloat = 0
    var lastVisible: Int?
    private var unchanged = 0
    private var reversals = 0
    private var lastAmount: CGFloat = 0
    var direction: CGFloat = 1

    mutating func record(visibleIndex: Int?, amount: CGFloat) -> String? {
        if let visibleIndex {
            unchanged = visibleIndex == lastVisible ? unchanged + 1 : 0
            lastVisible = visibleIndex
            if unchanged >= 10 { return "does not move" }
        }
        if amount * lastAmount < 0 { reversals += 1 }
        lastAmount = amount
        return reversals >= 6 ? "keeps turning round" : nil
    }
}

// MARK: - The test class

/// The three Version History restores in Markdown mode, editor first. See the file header.
final class WriteQueuePhase4bMdRestoreEFE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// How many Save Version round trips this test has made (each needs its own name).
    var versionSaves = 0
    /// What the last status-bar read said, round by round (for a failure message).
    var landingReads: [String] = []

    static let versionName = "RST v1"
    static let dupOne = "Dup01 line of the fixture document."
    static let dupTwo = "Dup02 line of the fixture document."
    static let subOne = "Sub01 line of the fixture document."
    static let subTwo = "Sub02 line of the fixture document."
    static let anchorOneLine = "Anchor01 line of the fixture document."
    static let anchorFiveLine = "Anchor05 line of the fixture document."
    /// The edit made AFTER the version was saved: the restore takes it away again. No character the editor transforms.
    static let edit = "RSTEDIT"
    static let typedOne = "RSTKEPTONE"
    static let typedTwo = "RSTKEPTTWO"
    /// The section the Insert and the timing tests restore (a level-2 section with two seeded plain lines under it).
    static let insertSection = Phase4bDelSize.restoreSectionTitle
    static let holdKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_MS"
    static let holdFirstKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N"
    /// The writer holds the first queued structural job this long (under the 4 s limit of a hold that blocks the writer).
    static let jobHoldMs = 3_500
    /// The most presses a polled loop makes: the text steps of the typing a test did (a slow host splits one typed sentence into several undo
    /// groups), then the structural press. It only bounds a failing run. A footnote renumber's own step is no longer allowed for: since
    /// t-f1a22aa7 (Phase 4c) the footnote burst timer stands aside while a command is unfinished, and `testMdRstWholeFootnotes_book6`, which
    /// types nothing, asserts exactly one press for its Cmd-Z.
    static let pressCap = 10
    /// A landing counts as "on the section" when the seeded line lies in the upper part of the editor's band.
    static let landingTopFraction: CGFloat = 0.6
    /// Over this many milliseconds the working notice "Finishing the last change..." must have shown (it is delayed one second).
    static let noticeAfterMs = 1_400

    /// The chapter a Replace test restores: chapter 3 of the book (a middle chapter of six, two chapters deep in twelve).
    static let chapterThree = "Chapter 3: The Quiet Archive and Its Ledgers"

    static func plainSeed(under title: String, level: Int, lines: [String]) -> (Phase4bDoc) -> Phase4bDoc {
        { WriteQueuePhase4bStructuralQueueE2ETests.withPlainLines($0, under: title, level: level, lines: lines) }
    }

    /// The seeds: Sub01/Sub02 under chapter 3 (the Replace target) and/or Dup01/Dup02 under 1.1 (the Insert and timing source).
    static func seeds(sub: Bool, dup: Bool) -> [(Phase4bDoc) -> Phase4bDoc] {
        var list: [(Phase4bDoc) -> Phase4bDoc] = []
        if dup { list.append(plainSeed(under: insertSection, level: 2, lines: [dupOne, dupTwo])) }
        if sub { list.append(plainSeed(under: chapterThree, level: 1, lines: [subOne, subTwo])) }
        return list
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// Begins the method, seeds, launches the document with the given seams, reads the saved document, logs the fixture counts, and switches
    /// the editor to Markdown with Cmd-/. False after a reported failure.
    func mdRstStart(
        _ size: Phase4bDelSize, method: String, env: [String: String] = [:], seeds: [(Phase4bDoc) -> Phase4bDoc] = []
    ) -> Bool {
        begin(method: method, size: size)
        for seed in seeds {
            if let current = doc { doc = seed(current) }
        }
        if let seeded = doc { note("SEED: seed hooks applied; \(seeded.counts.reportLine)") }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            app.launchEnvironment[key] = value
            note("SEAM \(key)=\(value)")
        }
        guard launchScenario() else { return false }
        pre = mdRstReadRows()
        tail.poll()
        evidenceLogStart = tail.lines.count
        let walk = Phase4bFlowWalk(rows: pre)
        guard walk.problems.isEmpty else {
            fail("TEST-SETUP: the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        let counts = "COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), "
            + "\(walk.definitions.count) footnote definition(s), \(citations) citation bracket(s) in the rows, "
            + "\(pre.filter(\.isNotes).count) Notes row(s), \(pre.filter(\.isBibliography).count) Bibliography row(s), "
            + "\(sectionsInDatabase) section row(s)"
        note(counts)
        attachText("fixture-counts-\(methodName).txt", "\(fixtureTag)\n\(counts)")
        guard mdRstSwitchToMarkdown() else { return false }
        startedAt = Date()
        return true
    }

    /// Cmd-/ (the View menu's "Switch to Markdown"), pressed once, then the wait for the badge (a condition).
    func mdRstSwitchToMarkdown() -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("TEST-SETUP: the editor-mode button never appeared"); return false }
        if mode.label != "Markdown" {
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            let modeTimeout = mdRstAppWait(size.operationTimeout * 2, before: "the mode button reads Markdown")
            guard mode.waitForLabel("== 'Markdown'", timeout: modeTimeout) else {
                fail("TEST-SETUP: the editor-mode button never reported Markdown after the toggle keystroke (it reads \(mode.label))")
                return false
            }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: Markdown; the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    /// The timeout of a wait on the APP's answer to an action the test has already taken. Never shortened by the budget; where the budget
    /// is already spent when such a wait starts, the test fails at once as a TEST-SETUP failure that cannot be taken for an app failure.
    func mdRstAppWait(_ seconds: TimeInterval, before step: String) -> TimeInterval {
        let left = size.budgetSeconds - Date().timeIntervalSince(startedAt)
        if left <= 0 {
            attachEvidenceScreenshot(app.screenshot(), name: "md-rst-budget-exhausted-\(size.identifier)")
            fail("TEST-SETUP: BUDGET EXHAUSTED before \(step): the \(Int(size.budgetSeconds)) s budget of \(size.identifier) was spent "
                + "\(Int(-left)) s ago, so the app's answer cannot be waited for fairly")
        }
        return seconds
    }

    func mdRstShot(_ name: String) { attachEvidenceScreenshot(app.screenshot(), name: "\(name)-\(size.identifier)") }

    /// FAILS the test after attaching the evidence screenshot (`continueAfterFailure` is false: a still taken after the failure never exists).
    func mdRstFailWithShot(_ message: String, name: String) {
        mdRstShot(name)
        fail(message)
    }

    /// Waits for the document to be quiet: the block table steady and the app's log quiet (conditions).
    func mdRstSettle() {
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
    }

    func mdRstTypeNow(_ text: String) {
        // The stored rows and the editor text are what the scenario reads, not the keystrokes.
        // e2e-lint: allow raw-typetext -- typed at once on purpose.
        app.typeText(text)
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    func mdRstReadRows() -> [Phase4bFlowRow] {
        let output = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT blockType || '|' || isNotes || '|' || isBibliography || '|' || hex(markdownFragment) "
                + "FROM block ORDER BY sortOrder, id;")
        var rows: [Phase4bFlowRow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else {
                fail(
                    "TEST-SETUP: a block row could not be read from \(TestFixtureHelper.fixturePath)/content.sqlite "
                        + "(line starts \"\(line.prefix(60))\")")
                continue
            }
            rows.append(Phase4bFlowRow(
                type: String(parts[0]), isNotes: parts[1] == "1", isBibliography: parts[2] == "1", fragment: Phase4bFlow.decodeHex(parts[3])))
        }
        return rows
    }

    /// The section `title` of `pre`, or a reported TEST-SETUP failure.
    func mdRstRequireSection(_ title: String) -> Range<Int>? {
        guard let range = Phase4bFlow.sectionRange(title, in: pre) else {
            fail("TEST-SETUP: the loaded document has no section \"\(title)\"")
            return nil
        }
        return range
    }

    /// The row of `pre` that is `line`, or a reported TEST-SETUP failure.
    func mdRstRequireRow(_ line: String) -> Int? {
        guard let row = pre.firstIndex(where: { $0.fragment == line }) else {
            fail("TEST-SETUP: the loaded document has no row \"\(line)\"")
            return nil
        }
        return row
    }

    func mdRstBlocksContaining(_ text: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(text))') > 0;") ?? -1
    }

    /// `pre` with the row that is exactly `line` replaced by `text` (the hand-worked document after an edit or a typed word).
    func mdRstPreRows(replacing line: String, with text: String) -> [Phase4bFlowRow] {
        pre.map { row in
            guard row.fragment == line, !row.isManaged else { return row }
            return Phase4bFlowRow(type: row.type, isNotes: false, isBibliography: false, fragment: text)
        }
    }

    func mdRstUserRows(_ rows: [Phase4bFlowRow]) -> [Phase4bFlowRow] { rows.filter { !$0.isManaged } }

    func mdRstManagedRows(_ rows: [Phase4bFlowRow]) -> [Phase4bFlowRow] { rows.filter(\.isManaged) }

    /// Differences between the user rows (Notes and Bibliography left out; footnote numbers read as `[^#]`) of `post` and `expectedUser`.
    func mdRstUserDifferences(_ post: [Phase4bFlowRow], expectedUser: [Phase4bFlowRow]) -> [String] {
        let expected = expectedUser.enumerated().map { (row: $0.offset, value: $0.element) }
        let actual = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        return Phase4bFlow.rowDifferences(expected: expected, actual: actual, exact: false)
    }

    /// Differences between the Notes and Bibliography rows of `post` and `expected`, compared exactly.
    func mdRstManagedDifferences(_ post: [Phase4bFlowRow], expected: [Phase4bFlowRow]) -> [String] {
        let want = expected.enumerated().map { (row: $0.offset, value: $0.element) }
        let have = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        return Phase4bFlow.rowDifferences(expected: want, actual: have, exact: true)
    }

    /// Waits (a condition, polled once a second) until the user rows of the block table equal `expectedUser`, and returns the last read. The
    /// rows follow an editor-first command later, through the write queue (e2e-verify: a read straight after a command races the write).
    @discardableResult
    func mdRstWaitForUserRows(_ expectedUser: [Phase4bFlowRow], timeout: TimeInterval) -> [Phase4bFlowRow] {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(timeout, before: "the block table's user rows match the expected document"))
        var post = mdRstReadRows()
        while !mdRstUserDifferences(post, expectedUser: expectedUser).isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            post = mdRstReadRows()
        }
        return post
    }

    /// Reads the block table (after `mdRstWaitForUserRows` or a settle) and adds every difference to `soft`. Returns the rows read.
    @discardableResult
    func mdRstAddRowChecks(
        _ what: String, expectedUser: [Phase4bFlowRow], managed: [Phase4bFlowRow]? = nil, walk: Bool = true,
        to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        let post = mdRstReadRows()
        let user = mdRstUserDifferences(post, expectedUser: expectedUser)
        var problems = user.map { "text rows: \($0)" }
        if !user.isEmpty { rowDifferenceLog.append("[\(what)] text rows\n" + user.map { "  " + $0 }.joined(separator: "\n")) }
        if let managed {
            let managedLines = mdRstManagedDifferences(post, expected: managed)
            problems += managedLines.map { "the Notes / Bibliography rows are not those expected: \($0)" }
            if !managedLines.isEmpty {
                rowDifferenceLog.append("[\(what)] Notes / Bibliography rows\n" + managedLines.map { "  " + $0 }.joined(separator: "\n"))
            }
        }
        if walk { problems += Phase4bFlowWalk(rows: post).problems.map { "footnotes: \($0)" } }
        note("\(what): \(post.count) block rows (\(pre.count) loaded); \(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// Waits for the app to write `sentence` into the block table. `timeout` is a fixed number of seconds, never `capped(...)`.
    func mdRstWaitForSentenceInDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(timeout, before: "\"\(sentence)\" is looked for in the database"))
        repeat {
            if mdRstBlocksContaining(sentence) >= 1 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func mdRstWaitForSentenceGone(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(timeout, before: "\"\(sentence)\" is looked for to be gone from the database"))
        repeat {
            if mdRstBlocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// The editor's text as the accessibility tree shows it: the runs joined with one space, every run of whitespace (a no-break space
    /// included) collapsed to one space. nil when no snapshot could be read. NEVER used for Notes labels.
    func mdRstJoinedScreenText() -> String? {
        guard let values = app.editorStaticTextValues() else { return nil }
        return values.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Waits (a condition) until the editor's text does (`present`) or does not hold `sentence`; nil when no snapshot could be read.
    func mdRstWaitForSentenceOnScreen(_ sentence: String, present: Bool, timeout: TimeInterval) -> Bool? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var read = false
        repeat {
            if let text = mdRstJoinedScreenText() {
                read = true
                if text.contains(sentence) == present { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return read ? false : nil
    }

    /// The house rule "the screen equals the database": `before` is a read of the block table; File > Save Version then writes the LIVE
    /// editor text into the table, and the table is read again. The two reads must be identical, every row, Notes and Bibliography included.
    /// This is the page-text seam: it never reads Notes labels from the accessibility tree.
    func mdRstAddScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout Phase4bFlowSoftChecks) {
        versionSaves += 1
        let name = "RST check \(versionSaves)"
        let saved = mdRstSaveVersion(named: name)
        soft.check(saved, "\(what): the version \"\(name)\" was saved (its flush writes the live editor text into the block table)")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let after = mdRstReadRows()
        let lines = Phase4bFlow.rowDifferences(
            expected: before.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: after.enumerated().map { (row: $0.offset, value: $0.element) }, exact: true)
        if !lines.isEmpty {
            rowDifferenceLog.append(
                "[\(what)] the block table before and after Save Version\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
        }
        note("\(what): SCREEN vs DATABASE: \(before.count) rows before Save Version, \(after.count) after; \(lines.count) difference line(s)")
        soft.check(lines.isEmpty, "\(what): the live editor text differs from the saved block table: \(lines.joined(separator: " | "))")
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    func mdRstLogCount() -> Int {
        tail.poll()
        return tail.lines.count
    }

    /// The log lines since `index` that hold `needle`.
    func mdRstLogLines(containing needle: String, from index: Int) -> [Phase4bLogLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].filter { $0.text.contains(needle) }
    }

    func mdRstTraceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    func mdRstPerformedCount(_ label: String, from index: Int) -> Int {
        mdRstTraceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step.hasPrefix("performed") }.count
    }

    /// Waits for a `<label> performed` line since `index`; false on a logged failure (noted) or on the timeout (noted).
    @discardableResult
    func mdRstWaitForPerformed(_ label: String, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdRstPerformedCount(label, from: index) >= 1 { return true }
            tail.poll()
            if index <= tail.lines.count, let problem = Phase4bLog(lines: Array(tail.lines[index...])).failureLine(since: "")?.text {
                note("PROBLEM while waiting for the \(label) performed line: \(problem)")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        note("TIMED OUT after \(Int(timeout)) s waiting for the \(label) performed line")
        return false
    }

    /// Waits (a condition) for a log line holding `needle` since `index`; the first such line, nil on the timeout.
    func mdRstWaitForLogLine(containing needle: String, from index: Int, timeout: TimeInterval) -> Phase4bLogLine? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let line = mdRstLogLines(containing: needle, from: index).first { return line }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date() < deadline
        return nil
    }

    /// The undo and redo runs since `index`, in order: per run whether it began `start (quick, markdown)`, whether its own done line was
    /// written (`quick restore done (markdown)` for an undo, `quick restore redo done (markdown)` for a redo), and whether any line of a
    /// slow road was.
    ///
    /// A run is counted from its OWN `start` line, never from its (label, id) pair: an entry's undo and redo are written under the ENTRY's id
    /// (`undo op=F41B8AD9` for the first and the third press alike), so a second undo of the same entry has the same label and id as the
    /// first. Keyed by the pair, the third press of E3 (undo, redo, undo) was merged into the first run and the log showed 2 runs for 3
    /// presses (run-1793296353-18579; the app had run three quick roads). Every other line of the sequence goes to the latest run with its
    /// label and id, which is the one in progress: presses are polled, so a run's last line is written before the next press is made.
    func mdRstRuns(from index: Int) -> [MdRstRun] {
        var runs: [MdRstRun] = []
        for line in mdRstTraceLines(from: index) where line.family == .sequence && (line.label == "undo" || line.label == "redo") {
            if line.isOpStart {
                runs.append(MdRstRun(label: line.label, opId: line.opId, steps: [line.step]))
            } else if let position = runs.lastIndex(where: { $0.label == line.label && $0.opId == line.opId }) {
                runs[position].steps.append(line.step)
            } else {
                // A line whose `start` was written before `index`: kept as a run of its own, which then fails `startedQuickMarkdown` loudly.
                runs.append(MdRstRun(label: line.label, opId: line.opId, steps: [line.step]))
            }
        }
        for position in runs.indices {
            let steps = runs[position].steps
            runs[position].startedQuickMarkdown = steps.contains("start (quick, markdown)")
            let doneLine = Self.mdRstDoneLine(forRunLabel: runs[position].label)
            runs[position].restoreDone = steps.contains { $0.hasPrefix(doneLine) }
            runs[position].slowRoad = steps.contains { step in
                step.contains("queued") || step.hasPrefix("start (editor-first") || step == "start" || step.hasPrefix("start (markdown")
            }
        }
        return runs
    }

    /// The trace line a quick run writes when the page has swapped: the undo's and the redo's are different lines (code review C17), so a
    /// redo's check cannot be satisfied by the undo's line. Matches `markdownQuickRedoDoneTrace` and the undo's `trace.log` in
    /// StructuralUndoController+MarkdownQuickUndo.swift.
    static func mdRstDoneLine(forRunLabel label: String) -> String {
        label == "redo" ? "quick restore redo done (markdown)" : "quick restore done (markdown)"
    }

    /// Adds the checks of the quick road for `count` undo / redo presses since `index`: that many runs, each `start (quick, markdown)` with
    /// its own done line (`quick restore done (markdown)` for an undo, `quick restore redo done (markdown)` for a redo), no `markdown
    /// queued` (slow road) line, and no `[toast] show` line at all.
    func mdRstAddQuickChecks(from index: Int, count: Int, what: String, to soft: inout Phase4bFlowSoftChecks) {
        let runs = mdRstRuns(from: index)
        let toasts = mdRstLogLines(containing: "[toast] show", from: index).map { String($0.text.suffix(120)) }
        result("QUICK ROAD (\(what)): \(runs.count) undo / redo run(s) "
            + "\(runs.map { "\($0.label) \($0.startedQuickMarkdown ? "quick-markdown" : "NOT quick") done=\($0.restoreDone)" }); "
            + "toast line(s) \(toasts.count) \(toasts.prefix(2))")
        soft.check(runs.count == count, "\(what): \(runs.count) undo / redo run(s) in the log, expected \(count)")
        for run in runs {
            soft.check(
                run.startedQuickMarkdown,
                "\(what): the \(run.label) op=\(run.opId) did not begin `start (quick, markdown)` (steps \(run.steps.prefix(4)))")
            soft.check(
                run.restoreDone,
                "\(what): the \(run.label) op=\(run.opId) wrote no `\(Self.mdRstDoneLine(forRunLabel: run.label))` "
                    + "line (steps \(run.steps.prefix(6)))")
            soft.check(!run.slowRoad, "\(what): the \(run.label) op=\(run.opId) took the slow queued road (steps \(run.steps.prefix(6)))")
        }
        soft.check(toasts.isEmpty, "\(what): \(toasts.count) `[toast] show` line(s) in the log, expected none: \(toasts.prefix(2))")
    }

    /// The mechanism of the restore click(s) since `index` as checks: that many `start (editor-first) mode=markdown` sequences (none on the
    /// old body), that many `<label>-editor-first ... ok=true mode=markdown` lines, no fallback line, and not one whole-document
    /// `setContent ... anchorCount=0` line (the old body's push).
    func mdRstAddMechanismChecks(kind: MdRstKind, from index: Int, restores: Int, to soft: inout Phase4bFlowSoftChecks) {
        let starts = mdRstTraceLines(from: index).filter { $0.family == .sequence && $0.label == kind.sequenceLabel && $0.isOpStart }
        let oldStarts = starts.filter { !$0.step.hasPrefix("start (editor-first)") }
        let okLines = mdRstLogLines(containing: "[STRUCT-TRACE] \(kind.sequenceLabel)-editor-first opId=", from: index)
            .filter { $0.text.contains(" ok=true") && $0.text.contains(" mode=markdown") }
        let setContents = mdRstLogLines(containing: "[CodeMirrorEditor] setContent len=", from: index).filter { $0.text.contains("anchorCount=0") }
        let fallbacks = mdRstFallbackEvidence(from: index)
        result("MECHANISM (\(kind.name), expected \(restores) click(s)): \(starts.count) start(s), \(oldStarts.count) on the old body; "
            + "\(okLines.count) `\(kind.sequenceLabel)-editor-first ... ok=true mode=markdown` line(s); fallback line(s) \(fallbacks.count); "
            + "whole-document `setContent ... anchorCount=0` line(s) \(setContents.count)")
        soft.check(starts.count == restores && oldStarts.isEmpty,
            "\(starts.count) \(kind.sequenceLabel) sequence(s), \(oldStarts.count) on the old body (\(oldStarts.map(\.step).prefix(2))), "
            + "expected \(restores) `start (editor-first) mode=markdown`")
        soft.check(okLines.count == restores,
            "\(okLines.count) `\(kind.sequenceLabel)-editor-first ... ok=true mode=markdown` line(s), expected \(restores): "
                + "the click did not run editor-first")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        soft.check(setContents.isEmpty,
            "\(setContents.count) whole-document `setContent ... anchorCount=0` line(s): the page was given the whole document again")
    }

    /// Every line since `index` that says a Markdown editor-first command took another road than the one under test.
    func mdRstFallbackEvidence(from index: Int) -> [String] {
        let markers = [
            "old path for this press", "page refused or failed", "markdown put-back", "the settle gave up waiting", "step 8: no live text",
            "[EF-STRUCT]", "refused (markdown", "refused (quick)", "timeline generation changed mid-click", "the job did not apply",
            "could not be reserved", "fell back to the old sequence"
        ]
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].map(\.text).filter { text in markers.contains { text.contains($0) } }.map { String($0.suffix(160)) }
    }
}

// MARK: - Save Version and Version History (copies of the premise check's helpers)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// File > Save Version with `name`, and the wait (a condition) for its snapshot row. Saving a version writes the LIVE editor text into
    /// the block table first.
    @discardableResult
    func mdRstSaveVersion(named name: String) -> Bool {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = mdRstWaitForSheet()
        guard alert.exists else { fail("TEST-SETUP: the Save Version alert never appeared"); return false }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { fail("TEST-SETUP: the Save Version alert has no name field"); return false }
        field.click()
        field.typeText(name)
        let save = alert.buttons["Save"]
        guard save.waitForExistence(timeout: 10) else { fail("TEST-SETUP: the Save Version alert has no Save button"); return false }
        save.click()
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(60, before: "the saved version \"\(name)\" is looked for in the snapshot table"))
        var saved = false
        repeat {
            saved = dbInt("SELECT count(*) FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';") == 1
            if !saved { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        } while !saved && Date() < deadline
        if !saved { fail("TEST-SETUP: the version \"\(name)\" never reached the snapshot table") }
        return saved
    }

    /// The sheet of File > Save Version and of the restore confirmations (a sheet, or a dialog on some macOS builds).
    func mdRstWaitForSheet() -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// Cmd-Opt-V: opens (or brings to the front) the Version History window, found by its window IDENTIFIER (not the title).
    func mdRstOpenVersionHistory() -> XCUIElement? {
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        guard window.waitForExistence(timeout: mdRstAppWait(90, before: "the Version History window is looked for")) else {
            fail("TEST-SETUP: the Version History window never appeared after Cmd-Opt-V (the app has \(app.windows.count) window(s))")
            return nil
        }
        return window
    }

    /// Clicks the version `name` in the window's list (the row text is the version's name, unique here).
    func mdRstSelectVersion(named name: String, in window: XCUIElement) -> Bool {
        // e2e-lint: allow statictext-firstmatch -- scoped to the Version History window and an exact `==` on label or value (no CONTAINS).
        let row = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
        guard row.waitForExistence(timeout: mdRstAppWait(120, before: "the version \"\(name)\" is looked for in the list")) else {
            fail("TEST-SETUP: the version \"\(name)\" never appeared in the Version History list")
            return false
        }
        row.click()
        note("VERSION HISTORY: the version \"\(name)\" is selected in the list")
        return true
    }

    /// "Restore All", then the "Restore Entire Project" confirmation. Returns the index of the first app-log line after the confirm click.
    func mdRstConfirmFullRestore(in window: XCUIElement) -> Int? {
        let restoreAll = window.buttons["Restore All"]
        guard restoreAll.waitForExistence(timeout: mdRstAppWait(60, before: "the Restore All button is looked for")) else {
            fail("TEST-SETUP: the \"Restore All\" button never appeared once the version was selected")
            return nil
        }
        restoreAll.click()
        let confirm = mdRstWaitForSheet().buttons["version-history-full-restore-confirm"]
        guard confirm.waitForExistence(timeout: 15) else {
            fail("TEST-SETUP: the \"Restore Entire Project\" confirmation never offered its button (sheet present: \(app.sheets.firstMatch.exists))")
            return nil
        }
        let from = mdRstLogCount()
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        confirm.click()
        return from
    }

    /// The window closes itself when the restore reports it is done (the Swift sequence's `performed`). Waits for that (a condition).
    func mdRstWaitForVersionHistoryToClose(_ window: XCUIElement) -> Bool {
        let closed = window.waitForDisappearance(timeout: mdRstAppWait(size.operationTimeout * 2, before: "the Version History window closes"))
        if !closed { fail("TEST-SETUP: the Version History window was still open \(Int(size.operationTimeout * 2)) s after the restore") }
        return closed
    }

    /// The "Selected Version" pane: the window's scroll view furthest to the right.
    func mdRstSelectedVersionPane(in window: XCUIElement) -> XCUIElement? {
        let panes = window.scrollViews.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 150 && $0.frame.height > 200 }
        return panes.max { $0.frame.minX < $1.frame.minX }
    }

    static let versionSectionTitlePattern = "^(Chapter [0-9]+: |[0-9]+\\.[0-9]+(\\.[0-9]+)? ).*"
    static let leastSectionRowHeight: CGFloat = 300

    /// How far the next scroll in the Selected Version pane goes (positive: further down), from the number of headings between the one the
    /// pane shows on top and the target.
    static func versionPaneScrollAmount(gap: Int) -> CGFloat {
        if gap <= 0 { return -480 }
        if gap == 1 { return 480 }
        return min(1200, max(480, CGFloat(gap - 1) * leastSectionRowHeight))
    }

    /// The row title of the section `title` in the "Selected Version" pane, scrolled fully into the pane (a copy of the structural class's
    /// `versionSectionTitle`: the pane is looked up once and the scroll size comes from the heading order).
    func mdRstVersionSectionTitle(_ title: String, in window: XCUIElement) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(900, before: "the section \"\(title)\" is looked for in the selected version"))
        let order = pre.filter { !$0.isManaged }.compactMap(\.headingTitle)
        let targetIndex = order.firstIndex(of: title)
        var found: XCUIElement?
        while found == nil, Date() < deadline {
            found = mdRstSelectedVersionPane(in: window)
            if found == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        }
        guard let pane = found else {
            fail("TEST-SETUP: the Selected Version pane never appeared in the Version History window")
            return nil
        }
        let band = pane.frame
        let titleQuery = pane.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
        let headingQuery = pane.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label MATCHES %@", Self.versionSectionTitlePattern))
        note("VERSION HISTORY: looking for \"\(title)\" (heading \(targetIndex.map { "#\($0) of \(order.count)" } ?? "unknown")) in the Selected "
            + "Version pane (\(Self.describeFrame(band)))")
        var walk = MdRstPaneWalk()
        while Date() < deadline, walk.rounds < 250 {
            walk.rounds += 1
            // e2e-lint: allow statictext-firstmatch -- scoped to the Version History pane and an exact `==` on label or value (no CONTAINS).
            if let snapshot = try? titleQuery.firstMatch.snapshot() {
                if band.insetBy(dx: 0, dy: 20).contains(snapshot.frame) {
                    // e2e-lint: allow statictext-firstmatch -- same query as above.
                    let leaf = titleQuery.firstMatch
                    app.waitForStableFrame(leaf)
                    guard leaf.exists else { continue }
                    note("VERSION HISTORY: the section \"\(title)\" is in view after \(walk.rounds - 1) round(s), \(Int(walk.scrolledDown)) pt down")
                    return leaf
                }
                mdRstCenterVersionTitle(titleQuery, at: snapshot.frame, band: band, in: pane, walk: &walk)
                continue
            }
            // e2e-lint: allow statictext-firstmatch -- scoped to the Version History pane; the label is matched with MATCHES, not CONTAINS.
            let visibleTitle = (try? headingQuery.firstMatch.snapshot())?.label
            let visibleIndex = visibleTitle.flatMap { order.firstIndex(of: $0) }
            let amount = targetIndex.flatMap { target in visibleIndex.map { Self.versionPaneScrollAmount(gap: target - $0) } } ?? 480
            if let problem = walk.record(visibleIndex: visibleIndex, amount: amount) {
                fail("TEST-SETUP: the Selected Version pane \(problem) beside \"\(title)\": it shows \"\(visibleTitle ?? "no heading")\" "
                    + "(\(Int(walk.scrolledDown)) pt scrolled down in \(walk.rounds) round(s))")
                return nil
            }
            pane.scroll(byDeltaX: 0, deltaY: -amount)
            walk.scrolledDown += amount
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        fail("TEST-SETUP: the section \"\(title)\" could not be scrolled into view in the Selected Version pane after \(walk.rounds) round(s) "
            + "and \(Int(walk.scrolledDown)) pt down")
        return nil
    }

    func mdRstCenterVersionTitle(
        _ query: XCUIElementQuery, at frame: CGRect, band: CGRect, in pane: XCUIElement, walk: inout MdRstPaneWalk
    ) {
        let wanted = max(-1200, min(1200, frame.midY - band.midY))
        pane.scroll(byDeltaX: 0, deltaY: -wanted * walk.direction)
        walk.scrolledDown += wanted * walk.direction
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        // e2e-lint: allow statictext-firstmatch -- scoped to the Version History pane and an exact `==` on label or value (no CONTAINS).
        if let after = try? query.firstMatch.snapshot(), (after.frame.midY - frame.midY) * (-wanted) < 0 {
            walk.direction = -walk.direction
        }
    }

    /// Right-clicks the section's row in the selected version, chooses `item` and confirms the "Restore Section" dialog. Returns the index
    /// of the first app-log line after the confirm click.
    func mdRstRestoreSection(_ title: String, item: String, in window: XCUIElement) -> Int? {
        guard let leaf = mdRstVersionSectionTitle(title, in: window) else { return nil }
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: item).click()
        let confirm = mdRstWaitForSheet().buttons["version-history-restore-confirm"]
        guard confirm.waitForExistence(timeout: 15) else {
            let picker = app.sheets.staticTexts["Select Target Section"].exists
            fail("TEST-SETUP: the \"Restore Section\" confirmation never offered its Restore button (the window asked for a target section "
                + "instead: \(picker); a sheet is open: \(app.sheets.firstMatch.exists))")
            return nil
        }
        let from = mdRstLogCount()
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        confirm.click()
        return from
    }

    /// Version History: opens the window, picks `version`, makes the restore `kind` (`title` names the section of a Replace or an Insert; it
    /// is ignored for a whole restore) up to and including the click on the confirmation. Returns the window and the index of the first
    /// app-log line after the confirm click; nil after a reported failure. The caller waits for the window to close.
    func mdRstStartRestore(_ kind: MdRstKind, title: String, version: String = WriteQueuePhase4bMdRestoreEFE2ETests.versionName)
        -> (window: XCUIElement, from: Int)? {
        guard let window = mdRstOpenVersionHistory(), mdRstSelectVersion(named: version, in: window) else { return nil }
        let from: Int?
        switch kind {
        case .entire: from = mdRstConfirmFullRestore(in: window)
        case .replace: from = mdRstRestoreSection(title, item: "Replace Current Section", in: window)
        case .insertAsNew: from = mdRstRestoreSection(title, item: "Insert as New Section", in: window)
        }
        guard let from else { return nil }
        return (window, from)
    }

    /// `mdRstStartRestore`, then the wait for the window to close. Returns the log index of the confirm click; nil after a reported failure.
    func mdRstRestore(_ kind: MdRstKind, title: String, version: String = WriteQueuePhase4bMdRestoreEFE2ETests.versionName) -> Int? {
        guard let started = mdRstStartRestore(kind, title: title, version: version),
              mdRstWaitForVersionHistoryToClose(started.window) else { return nil }
        return started.from
    }
}

// MARK: - Driving the app: cards, keys, carets

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// Every sidebar card titled exactly `title`, top to bottom.
    func mdRstCards(titled title: String) -> [XCUIElement] {
        let cards = app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
        var found: [XCUIElement] = []
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            if card.exists { found.append(card) }
        }
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    func mdRstCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    /// Waits (a condition) until exactly `wanted` cards are titled exactly `title`; returns the last count read.
    func mdRstWaitForCardCount(_ title: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(timeout, before: "the cards titled \"\(title)\" are counted"))
        var count = mdRstCards(titled: title).count
        while count != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = mdRstCards(titled: title).count
        }
        return count
    }

    func mdRstWaitForCard(_ title: String, present: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if mdRstCard(title).exists == present { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Clicks the sidebar card (the UX contract: clicking navigates; the editor scrolls to the section). Coordinate click: cards are
    /// non-hittable by design.
    func mdRstNavigate(to card: XCUIElement) {
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Brings the element `resolve` returns into the sidebar's visible band. Fails the test (TEST-SETUP) and returns nil when it cannot.
    func mdRstBringIntoView(_ what: String, resolve: () -> XCUIElement?) -> XCUIElement? {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: capped(30)) else {
            mdRstFailWithShot("TEST-SETUP: the outline sidebar's scroll view never appeared", name: "md-rst-sidebar-missing")
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
        mdRstFailWithShot(
            "TEST-SETUP: the sidebar card \(what) could not be scrolled into view (scroll view \(scroll.frame))",
            name: "md-rst-card-not-in-view")
        return nil
    }

    /// Right-clicks a sidebar card and chooses `item` ("Delete Section"), and returns the app-log index just before the click. The card must
    /// exist and lie INSIDE the visible band; when no menu item with that title appears within 10 s the menu is dismissed with Escape and
    /// the right-click is made ONCE more; only then the test fails, with a screenshot taken first.
    @discardableResult
    func mdRstChooseSidebarItem(_ card: XCUIElement, item: String) -> Int {
        app.activateAndWaitForForeground()
        let from = mdRstLogCount()
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        for attempt in 1...2 {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            let entry = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", item)).firstMatch
            if entry.waitForExistence(timeout: 10) {
                entry.click()
                return from
            }
            note("SIDEBAR: no menu item starting \"\(item)\" appeared within 10 s of the right-click (attempt \(attempt) of 2)")
            mdRstShot("md-rst-no-menu-attempt-\(attempt)")
            app.typeKey(.escape, modifierFlags: [])
        }
        mdRstFailWithShot("No menu item starting \"\(item)\" appeared after two right-clicks on the card", name: "md-rst-no-menu")
        return from
    }

    /// Places the caret at the end of the plain one-line paragraph `exactLine` (its prefix `paragraph`) and confirms it (the status bar's
    /// selection count). A failure is a TEST-SETUP failure.
    func mdRstPlaceCaret(paragraph: String, exactLine: String, what: String) -> Bool {
        let placed = app.placeCaretByClicking(
            paragraphStartingWith: paragraph, atEnd: true, runProbe: true, findTimeout: capped(45), exactLine: exactLine)
        note("CARET at the end of \(what): probe \(placed.probe) after \(placed.attempts.count) click attempt(s)")
        guard placed.confirmed else {
            XCTFail("TEST-SETUP: the caret could not be confirmed at the end of \(what) (probe: \(placed.probe); \(placed.attempts))")
            return false
        }
        return true
    }

    /// The edit that the restore will take away again (or, for Insert, that makes the original differ from the copy): the caret goes to
    /// the end of a seeded line the restore replaces, the edit is typed there, and the wait (a condition) is for the block table to hold it.
    func mdRstMakeEdit(kind: MdRstKind) -> Bool {
        switch kind {
        case .entire:
            guard mdRstPlaceCaret(
                paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorFiveLine, what: "the Anchor05 line"
            ) else { return false }
        case .replace:
            guard let card = mdRstBringIntoView("\"\(Self.chapterThree)\"", resolve: { self.mdRstCard(Self.chapterThree) }) else { return false }
            mdRstNavigate(to: card)
            guard mdRstPlaceCaret(paragraph: "Sub02", exactLine: Self.subTwo, what: "the Sub02 line of chapter 3") else { return false }
        case .insertAsNew:
            guard let card = mdRstBringIntoView("\"\(Self.insertSection)\"", resolve: { self.mdRstCard(Self.insertSection) }) else { return false }
            mdRstNavigate(to: card)
            guard mdRstPlaceCaret(
                paragraph: "Dup02", exactLine: Self.dupTwo, what: "the Dup02 line of \"\(Self.insertSection)\""
            ) else { return false }
        }
        mdRstTypeNow(" " + Self.edit)
        let landed = mdRstWaitForSentenceInDatabase(Self.edit, timeout: 90)
        note("EDIT \"\(Self.edit)\" typed; it reached the block table: \(Self.yesNo(landed))")
        guard landed else {
            XCTFail("TEST-SETUP: the edit \"\(Self.edit)\" never reached the block table")
            return false
        }
        return true
    }

    /// The leaves of `leaves` that lie fully inside the editor's visible band (24 points in from each edge), in tree order. ONE snapshot per
    /// leaf: a leaf that has gone is simply not visible.
    func mdRstFullyVisible(_ leaves: XCUIElementQuery) -> [XCUIElement] {
        let editor = app.editorArea.frame
        var visible: [XCUIElement] = []
        for index in 0..<leaves.count {
            let leaf = leaves.element(boundBy: index)
            guard let frame = (try? leaf.snapshot())?.frame else { continue }
            if frame.width > 0, frame.minY >= editor.minY + 24, frame.maxY <= editor.maxY - 24 { visible.append(leaf) }
        }
        return visible
    }

    /// The frame of `element` once two reads 0.4 s apart agree (at most `timeout`), read from SNAPSHOTS: nil as soon as the element has gone.
    func mdRstStableFrame(_ element: XCUIElement, timeout: TimeInterval = 3) -> CGRect? {
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

    /// The section the status bar's outline button reports (its accessibility VALUE): the section the CARET is in.
    func mdRstStatusBarSection() -> String {
        let button = app.buttons["status-bar-outline"]
        guard button.exists else { return "" }
        return (button.value as? String) ?? ""
    }

    func mdRstWaitForStatusSection(containing needle: String, timeout: TimeInterval) -> (found: Bool, last: String) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var name = mdRstStatusBarSection()
        while !name.contains(needle), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            name = mdRstStatusBarSection()
        }
        return (name.contains(needle), name)
    }

    /// ONE look at the page after a card click, with NO scroll of the test's own (`rounds=0`): waits (a condition, bounded) for a leaf with
    /// the exact text `line` fully inside the editor's band, and returns the LAST such leaf with its place in the band. Nil when none shows
    /// up within `timeout`.
    func mdRstLanded(on line: String, timeout: TimeInterval) -> MdRstLanding? {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let visible = mdRstFullyVisible(leaves)
            if let last = visible.last, let frame = mdRstStableFrame(last) {
                let editor = app.editorArea.frame
                let fraction = editor.height > 0 ? (frame.minY - editor.minY) / editor.height : 1
                return MdRstLanding(leaf: last, frame: frame, topFraction: fraction, visibleCount: visible.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return nil
    }

    /// Clicks the right end of `leaf` (a one-line paragraph of `words` words), moves the caret to the line's end and confirms it through
    /// the status bar's selection count. False when the caret cannot be confirmed.
    func mdRstClickEnd(of leaf: XCUIElement, words: Int, what: String) -> Bool {
        let frame = (try? leaf.snapshot())?.frame ?? .zero
        app.activateAndWaitForForeground()
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        let probe = app.caretSelectionProbe(expectedWords: words, atEnd: true)
        note("CARET at the end of \(what) (leaf \(Self.describeFrame(frame))): probe \(probe)")
        return probe == "ok"
    }

    /// ONE click on the card of `title` (the `last` card of that title when two cards share it) and the facts of where the page landed
    /// (`rounds=0`: the test scrolls nothing): `line` must be fully on screen within 45 s, in the upper part of the band; the caret put at
    /// its end must read `title` in the status bar; where the heading's own leaf is exposed (`checkHeading`) it must be fully visible above
    /// the landed line. The screenshot is attached BEFORE the checks. Returns the landing.
    @discardableResult
    func mdRstCheckCardLanding(
        _ target: MdRstCardTarget, what: String, to soft: inout Phase4bFlowSoftChecks
    ) -> MdRstLanding? {
        let title = target.title, line = target.line
        let useLast = target.useLast, checkHeading = target.checkHeading
        guard let card = mdRstBringIntoView("\"\(title)\"\(useLast ? " (the last of its title)" : "")", resolve: {
            useLast ? self.mdRstCards(titled: title).last : self.mdRstCards(titled: title).first
        }) else { return nil }
        let from = mdRstLogCount()
        mdRstNavigate(to: card)
        note("ONE CLICK on the card \"\(title)\"\(useLast ? " (the last of its title)" : "") (\(what)); log index \(from)")
        let landing = mdRstLanded(
            on: line,
            timeout: mdRstAppWait(45, before: "the \"\(line.prefix(10))...\" line shows after one card click (\(what))"))
        var caretOk = false
        var section: String?
        if let landing {
            caretOk = mdRstClickEnd(
                of: landing.leaf, words: line.split(separator: " ").count,
                what: "the \"\(line.prefix(10))...\" line the click landed on (\(what))")
            section = mdRstWaitForStatusSection(containing: title, timeout: 4).last
        }
        let position = landing.map {
            "its top is \(Int($0.topFraction * 100)) percent down the editor band, \($0.visibleCount) such line(s) on screen"
        } ?? "none on screen"
        result("CARD CLICK LANDING (\(what)): rounds=0 (the test scrolled nothing); line fully visible: \(Self.yesNo(landing != nil)); \(position); "
            + "the status bar names \"\(section ?? "n/a")\"")
        var headingNote = "not checked"
        var headingProblem: String?
        if checkHeading, let landing {
            if let heading = app.editorHeadingText(matching: title, timeout: 2) {
                let editor = app.editorArea.frame
                let frame = (try? heading.snapshot())?.frame ?? .zero
                let fullyVisible = frame.width > 0 && frame.minY >= editor.minY && frame.maxY <= editor.maxY
                let above = frame.width > 0 && frame.maxY <= landing.frame.minY + 1
                headingNote = "exposed at \(Self.describeFrame(frame)), fully visible \(Self.yesNo(fullyVisible)), "
                    + "above the landed line \(Self.yesNo(above))"
                if !(fullyVisible && above) { headingProblem = headingNote }
            } else {
                headingNote = "not exposed in the accessibility tree (nothing asserted about the heading line)"
            }
        }
        result("HEADING LEAF of \"\(title)\" (\(what)): \(headingNote)")
        mdRstShot("md-rst-landing-\(what.replacingOccurrences(of: " ", with: "-"))")
        if let headingProblem { soft.check(false, "\(what): the heading line is not fully on screen above the landed line (\(headingProblem))") }
        guard let landing else {
            soft.check(false, "\(what): after ONE click on the card of \"\(title)\" no \"\(line)\" line was fully on screen within 45 s "
                + "(rounds=0, the test scrolled nothing): the card click did not land on the section")
            return nil
        }
        soft.check(landing.topFraction <= Self.landingTopFraction,
            "\(what): the line is \(Int(landing.topFraction * 100)) percent down the editor band (more than \(Int(Self.landingTopFraction * 100))): "
            + "the click did not put the heading at the top")
        soft.check(caretOk, "\(what): the caret could not be confirmed at the end of the landed line")
        soft.check(section?.contains(title) == true,
            "\(what): the line the click landed on belongs to \"\(section ?? "n/a")\", not to \"\(title)\": the click landed elsewhere")
        return landing
    }
}

// MARK: - Driving the app: Cmd-Z and Cmd-Shift-Z

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// One Cmd-Z (or Cmd-Shift-Z), then only as much waiting as the press needs, told by the app's own log: the editor writes a
    /// `[UnifiedUndo] keydown` line for every press before it acts on it (polled, at most 15 s; none: decision `none`); a `structural`
    /// decision means a structural undo or redo is coming, and its `performed` line is waited for as long as the operation timeout; a
    /// `swallow` (held behind a request still in flight) is waited for up to 40 s. A text step (`fallthrough`) returns at once, with the
    /// editor's own length after it.
    func mdRstPress(redo: Bool, number: Int, activate: Bool = true) -> MdRstPress {
        let label = redo ? "redo" : "undo"
        let from = mdRstLogCount()
        if activate { app.activateAndWaitForForeground() }
        app.typeKey("z", modifierFlags: redo ? [.command, .shift] : .command)
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
            performed = mdRstWaitForPerformed(
                label, from: from,
                timeout: mdRstAppWait(size.operationTimeout * 2, before: "the \(label) performed line of press \(number)"))
        } else if decision == "swallow" {
            performed = mdRstWaitForPerformed(label, from: from, timeout: mdRstAppWait(40, before: "the held \(label) press \(number) is routed"))
        }
        var after: Int?
        if decision == "fallthrough" {
            // The text step's own line follows the keydown line within a moment; a short bounded look.
            let lineDeadline = Date(timeIntervalSinceNow: 5)
            repeat {
                tail.poll()
                after = tail.lines[min(from, tail.lines.count)...]
                    .first { $0.text.contains("[UnifiedUndo] keydown-path-invocation direction=\(label) ") }
                    .flatMap { Phase4bDelTypingParser.intAfter("docLengthAfter=", in: $0.text) }
                if after != nil { break }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            } while Date() < lineDeadline
        }
        return MdRstPress(
            number: number, redo: redo, decision: decision,
            undoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("undoDepth=", in: $0) },
            redoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("redoDepth=", in: $0) },
            docLength: text.flatMap { Phase4bDelTypingParser.intAfter("docLength=", in: $0) }, docLengthAfter: after, performed: performed)
    }

    /// Cmd-Z, one press at a time, until a STRUCTURAL press has run (the restore is undone), at most `pressCap`. The typing before it is
    /// undone by text presses (a loaded host splits one typed sentence into several undo groups, so the count is never fixed). A press the
    /// editor did not decide (`none`) ends the loop: the key reached no editor.
    func mdRstUndoUntilStructural() -> [MdRstPress] {
        var presses: [MdRstPress] = []
        for number in 1...Self.pressCap {
            let press = mdRstPress(redo: false, number: number)
            presses.append(press)
            result(press.summary)
            if press.isStructural || press.decision == "none" { break }
        }
        return presses
    }

    /// Cmd-Shift-Z, one press at a time: first until a STRUCTURAL press has run (the restore is redone), then, for typing that comes back
    /// after it, until the editor's own document length is `wantedLength` (read from the text step's `docLengthAfter=`) or there is nothing
    /// left to redo. At most `pressCap` presses in all.
    func mdRstRedoUntilLength(_ wantedLength: Int?) -> [MdRstPress] {
        var presses: [MdRstPress] = []
        var structuralSeen = false
        for number in 1...Self.pressCap {
            let press = mdRstPress(redo: true, number: number, activate: number == 1)
            presses.append(press)
            result(press.summary)
            if press.decision == "none" { break }
            if press.isStructural { structuralSeen = true; if wantedLength == nil { break }; continue }
            // A text press before the structural one with nothing to redo (it beeps) ends the loop: more presses would find nothing either.
            guard structuralSeen else { if (press.redoDepth ?? 0) == 0 { break } else { continue } }
            if let after = press.docLengthAfter, after == wantedLength { break }
            if (press.redoDepth ?? 0) <= 1 { break }
        }
        return presses
    }

    func mdRstReport(_ name: String, _ presses: [MdRstPress]) {
        let used = presses.map { "\($0.decision) u\($0.undoDepth.map(String.init) ?? "-") r\($0.redoDepth.map(String.init) ?? "-")" }
        result("\(name): \(presses.count) press(es) used (cap \(Self.pressCap)): \(used)")
        attachText("presses-\(methodName)-\(name.replacingOccurrences(of: " ", with: "-")).txt", presses.map(\.summary).joined(separator: "\n"))
    }

    /// The editor's document length read WITHOUT changing anything: a Cmd-Shift-Z with nothing to redo is a plain text step of the editor's
    /// own history that finds nothing (it beeps, legitimately), and its `[UnifiedUndo] keydown` line carries `docLength=`. ONLY valid when
    /// nothing is left to redo. Returns nil when no keydown line showed up.
    func mdRstProbeDocLength() -> Int? {
        let from = mdRstLogCount()
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: [.command, .shift])
        let marker = "[UnifiedUndo] keydown direction=redo "
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            tail.poll()
            if let line = tail.lines[min(from, tail.lines.count)...].first(where: { $0.text.contains(marker) }) {
                return Phase4bDelTypingParser.intAfter("docLength=", in: line.text)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }
}

// MARK: - Measuring a restore click (from the app's own log)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    func mdRstMilliseconds(_ later: Date?, _ earlier: Date?) -> Int? {
        guard let later, let earlier else { return nil }
        return Int((later.timeIntervalSince(earlier) * 1000).rounded())
    }

    static func figure(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }

    /// The figures of the restore click that began at log index `from`, from the app's own log stamps: the FIRST log line after the confirm
    /// click is zero (the old restore's `start` line came 0.4 to 0.65 s after it). Waits (a condition) for the page's `markdown-restore` line
    /// and for `[MdWrite] structural hold released` (the job applied, the live text flushed). Nothing here is a threshold.
    func mdRstMeasure(kind: MdRstKind, from: Int, label: String) -> MdRstTiming {
        var timing = MdRstTiming()
        let wait = mdRstAppWait(size.operationTimeout * 2, before: "the \(label) job releases its hold")
        let pageLine = mdRstWaitForLogLine(containing: "[STRUCT-TRACE] markdown-restore mode=", from: from, timeout: wait)
        let released = mdRstWaitForLogLine(containing: "[MdWrite] structural hold released", from: from, timeout: wait)
        tail.poll()
        let first = from < tail.lines.count ? tail.lines[from] : nil
        let start = mdRstTraceLines(from: from).first { $0.family == .sequence && $0.label == kind.sequenceLabel && $0.isOpStart }
        timing.clickToTextMs = mdRstMilliseconds(pageLine?.date, first?.date)
        timing.startToTextMs = mdRstMilliseconds(pageLine?.date, start?.line.date)
        timing.clickToRowsMs = mdRstMilliseconds(released?.date, first?.date)
        timing.pageMs = pageLine.flatMap { Phase4bDelTypingParser.intAfter(" ms=", in: $0.text) }
        timing.hunks = pageLine.flatMap { Phase4bDelTypingParser.intAfter(" hunks=", in: $0.text) }
        let notices = mdRstLogLines(containing: "Finishing the last change", from: from).filter { $0.text.contains("[toast] show") }
        timing.noticeSeen = !notices.isEmpty
        result("TIMING \(label) (\(kind.name), app's clock from its log): click (first log line after the confirm) to the restored text in the page "
            + "\(Self.figure(timing.clickToTextMs)); `start` line to the text \(Self.figure(timing.startToTextMs)); click to the rows written "
            + "and the hold released \(Self.figure(timing.clickToRowsMs)); the page's own work \(Self.figure(timing.pageMs)) for "
            + "\(timing.hunks.map(String.init) ?? "n/a") changed place(s); working notice \"Finishing the last change...\" shown: "
            + "\(Self.yesNo(timing.noticeSeen)). Compare: the shipped Delete raises its hold in 573 ms and the Outline reacts in 1.08 s; "
            + "the OLD Markdown restore showed the text 2.4 s after its start line")
        return timing
    }

    /// The only assertions of a measurement: the page answered (a text figure exists), the job finished (a rows figure exists), and a click
    /// that took over 1.4 s showed the working notice.
    func mdRstAddTimingChecks(_ timing: MdRstTiming, label: String, to soft: inout Phase4bFlowSoftChecks) {
        soft.check(timing.clickToTextMs != nil, "\(label): the page's `markdown-restore` line never appeared (the restore did not run editor-first)")
        soft.check(timing.clickToRowsMs != nil, "\(label): `[MdWrite] structural hold released` never appeared (the job did not finish)")
        if let text = timing.clickToTextMs, text > Self.noticeAfterMs {
            soft.check(timing.noticeSeen,
                "\(label): the click took \(text) ms to put the text in the page (over \(Self.noticeAfterMs) ms) and no "
                    + "`[toast] show ... Finishing the last change` line was written")
        }
    }
}

// MARK: - E1 The replaced section's card lands on the heading (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E1. CLAIM: on the twelve-chapter book (Markdown) the text of chapter 3 is changed by one typed word, the version saved before is
    /// restored with Replace Current Section (the chapter's flat range: heading, Sub01, Sub02, opening paragraph); straight after the window
    /// closes ONE click on the Outline card "Chapter 3: ..." puts the heading and the seeded Sub01 line on screen with NO scroll search
    /// (`rounds=0`), the heading's own leaf (where exposed) fully visible above it. After the settle the rows are the document as loaded (the
    /// edit gone), the click ran editor-first (`restoreSectionReplace ... start (editor-first) mode=markdown`) and the page was not given a
    /// whole document (`setContent ... anchorCount=0`: zero).
    /// TODAY: MUST FAIL. The old Markdown restore pushes the whole document without section markers; the card click lands 1500 pt away
    /// (premise check, book12: found only in search round 6 of 12, 10,500 pt scrolled in total).
    /// BREAK (addendum 11): the request sends `plan.markdown` instead of `markdownPageText` (swift-U4.patch): no markers, the click lands elsewhere.
    func testMdRstSecCardLands_book12() {
        let title = Self.chapterThree
        guard mdRstStart(.book12, method: #function, seeds: Self.seeds(sub: true, dup: false)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        let beforeRestore = mdRstReadRows()
        note("ROWS before the restore: \(beforeRestore.count); rows holding \"\(Self.edit)\": \(mdRstBlocksContaining(Self.edit))")
        guard let from = mdRstRestore(.replace, title: title) else { return }
        var soft = Phase4bFlowSoftChecks()
        mdRstCheckCardLanding(
            MdRstCardTarget(title: title, line: Self.subOne, useLast: false, checkHeading: true), what: "at once", to: &soft)

        mdRstWaitForUserRows(mdRstUserRows(pre), timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after the Replace (settled)", expectedUser: mdRstUserRows(pre), to: &soft)
        soft.check(
            mdRstBlocksContaining(Self.edit) == 0,
            "the edit \"\(Self.edit)\" is still in \(mdRstBlocksContaining(Self.edit)) row(s) after the Replace")
        mdRstAddMechanismChecks(kind: .replace, from: from, restores: 1, to: &soft)
        mdRstShot("md-rst-e1-end")
        assertSoft(soft, "Markdown: Replace Current Section on \"\(title)\", ONE click on its card, on \(size.identifier)")
    }
}

// MARK: - E2 Typing straight after the click (CONTROL)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E2 (CONTROL). CLAIM: the same Replace as E1; as soon as the window has closed a word is typed at the end of the restored Sub01 line
    /// (the caret is placed with a click, the typing follows at once). The first job of the launch is held 3.5 s (a pending job is likely on
    /// a fast host; REPORTED, not asserted). The word is on screen and in the block table exactly once, in the Sub01 row, and nothing else
    /// changed: the rows are the loaded document with that one line extended.
    /// TODAY: PASSES. Premise (a) of the plan is confirmed in the VM: a sentence typed straight after the click, once the Version History
    /// window has closed, was in the editor's text and in the stored rows in all five premise runs; typing DURING the old click cannot be
    /// driven by XCUITest (the window is the key window until it closes). So this test is a CONTROL for the new flow, never a must-fail.
    /// BREAK (addendum 11): release the hold before step 8 (swift-U2.patch): the word is lost or lands in the wrong row.
    func testMdRstSecTypeAfterClick_book12() {
        let title = Self.chapterThree
        let env = [Self.holdKey: String(Self.jobHoldMs), Self.holdFirstKey: "1"]
        guard mdRstStart(.book12, method: #function, env: env, seeds: Self.seeds(sub: true, dup: false)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        guard let from = mdRstRestore(.replace, title: title) else { return }
        guard mdRstPlaceCaret(
            paragraph: "Sub01", exactLine: Self.subOne, what: "the restored Sub01 line (straight after the window closed)"
        ) else { return }
        let typedAt = mdRstLogCount()
        mdRstTypeNow(" " + Self.typedOne)
        tail.poll()   // the lines written while the word was typed must be in `tail.lines` before the hold-released line is looked for
        let releasedAt = tail.lines[min(from, tail.lines.count)...].firstIndex { $0.text.contains("[MdWrite] structural hold released") }
        let jobState = releasedAt.map { $0 > typedAt ? "still pending" : "already done" } ?? "still pending"
        result("TYPING vs THE JOB (reported, not asserted): the word was typed at log line \(typedAt); the click's hold was released at log line "
            + "\(releasedAt.map(String.init) ?? "not yet at that moment") (so the job was \(jobState) when it was typed)")
        var soft = Phase4bFlowSoftChecks()
        soft.check(mdRstWaitForSentenceInDatabase(Self.typedOne, timeout: 90), "the word \"\(Self.typedOne)\" never reached the block table")
        let onScreen = mdRstWaitForSentenceOnScreen(Self.typedOne, present: true, timeout: 60)
        soft.check(onScreen != false, "the word \"\(Self.typedOne)\" is not on screen")
        mdRstSettle()
        let expected = mdRstUserRows(mdRstPreRows(replacing: Self.subOne, with: Self.subOne + " " + Self.typedOne))
        mdRstWaitForUserRows(expected, timeout: size.operationTimeout * 2)
        let post = mdRstAddRowChecks("after the Replace and the typing (settled)", expectedUser: expected, to: &soft)
        soft.check(mdRstBlocksContaining(Self.typedOne) == 1, "the word is in \(mdRstBlocksContaining(Self.typedOne)) row(s), expected 1")
        soft.check(
            mdRstBlocksContaining(Self.edit) == 0,
            "the edit \"\(Self.edit)\" is still in \(mdRstBlocksContaining(Self.edit)) row(s): the Replace did not take effect")
        mdRstAddMechanismChecks(kind: .replace, from: from, restores: 1, to: &soft)
        mdRstAddScreenEqualsDatabaseCheck(before: post, what: "after the Replace and the typing", to: &soft)
        mdRstShot("md-rst-e2-end")
        assertSoft(soft, "Markdown: Replace Current Section, type straight after the click (CONTROL), on \(size.identifier)")
    }
}

// MARK: - E3 Cmd-Z and Cmd-Shift-Z are quick, no toast (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E3. CLAIM: on the six-chapter book, Replace Current Section on chapter 3 (edit taken away), then Cmd-Z, Cmd-Shift-Z, Cmd-Z, each polled
    /// (one press at a time, cap 10: a footnote renumber can surface as a text step of its own): the edit is back / gone / back. Every
    /// press is the QUICK Markdown road: its sequence began `start (quick, markdown)` and wrote its own done line (`quick restore done
    /// (markdown)` for an undo, `quick restore redo done (markdown)` for a redo), no line of the slow queued road (`markdown queued`), and
    /// the log holds NO `[toast] show` line at all. The editor's own document length after the undo (read at the next press) equals the
    /// length before the restore, and after the redo (read by a Cmd-Shift-Z with nothing to redo) the length after the restore.
    /// TODAY: MUST FAIL. The old body's undo and redo take the slow route (premise check, book6: `undo SLOW` / `redo SLOW`; "Undoing..."
    /// shows on a loaded host).
    /// BREAK (addendum 11): skip `efRecordedStructGeneration[opId] = ...` in the click (the slow route runs); the third press
    /// (S2) breaks with `efSlots.markReserved(opId)` deleted from `markdownRestoreReplyTurn`.
    func testMdRstSecUndoRedoQuickNoToast_book6() {
        let title = Self.chapterThree
        guard mdRstStart(.book6, method: #function, seeds: Self.seeds(sub: true, dup: false)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        let withEdit = mdRstUserRows(mdRstPreRows(replacing: Self.subTwo, with: Self.subTwo + " " + Self.edit))
        let withoutEdit = mdRstUserRows(pre)
        guard let lengthBefore = mdRstProbeDocLength() else {
            fail("TEST-SETUP: the editor's document length could not be read before the restore (no keydown line)")
            return
        }
        guard let from = mdRstRestore(.replace, title: title) else { return }
        var soft = Phase4bFlowSoftChecks()
        mdRstWaitForUserRows(withoutEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after the Replace (settled)", expectedUser: withoutEdit, to: &soft)
        mdRstAddMechanismChecks(kind: .replace, from: from, restores: 1, to: &soft)
        // The keyboard focus is in the editor when Cmd-Z comes (a click puts the caret back; it changes no text and adds no undo step).
        guard mdRstPlaceCaret(paragraph: "Sub01", exactLine: Self.subOne, what: "the restored Sub01 line (focus for Cmd-Z)") else { return }

        // Cmd-Z: the restore is undone (the edit is back); the length after it is read at the next press.
        let keysFrom = mdRstLogCount()
        let undo = mdRstUndoUntilStructural()
        mdRstReport("undo", undo)
        soft.check(undo.last?.isStructural == true && undo.last?.performed == true,
            "the restore was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undo.map(\.summary)))")
        let lengthAfterRestore = undo.first?.docLength
        mdRstWaitForUserRows(withEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Z (settled)", expectedUser: withEdit, to: &soft)
        soft.check(mdRstBlocksContaining(Self.edit) == 1, "the edit is in \(mdRstBlocksContaining(Self.edit)) row(s) after Cmd-Z, expected 1")

        // Cmd-Shift-Z: the restore is redone (the edit is gone again); the length after the undo is read at this press.
        let redo = mdRstRedoUntilLength(nil)
        mdRstReport("redo", redo)
        soft.check(redo.first?.isStructural == true && redo.first?.performed == true,
            "Cmd-Shift-Z was decided \(redo.first?.decision ?? "none") (performed: \(redo.first?.performed ?? false)), expected the structural redo")
        soft.check(redo.first?.docLength == lengthBefore,
            "the editor's length after the undo is \(redo.first?.docLength.map(String.init) ?? "n/a"), "
                + "expected the length before the restore \(lengthBefore)")
        mdRstWaitForUserRows(withoutEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Shift-Z (settled)", expectedUser: withoutEdit, to: &soft)

        // Cmd-Z again: the redone entry is undone quickly too (S2: the redo's slot was reserved).
        let again = mdRstUndoUntilStructural()
        mdRstReport("undo again", again)
        soft.check(again.last?.isStructural == true && again.last?.performed == true,
            "the second Cmd-Z did not undo the redone restore within \(Self.pressCap) presses (\(again.map(\.summary)))")
        mdRstWaitForUserRows(withEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after the second Cmd-Z (settled)", expectedUser: withEdit, to: &soft)
        // Exactly the three presses so far: the undo, the redo and the second undo are THREE runs even though they carry one entry id (see
        // `mdRstRuns`); the extra Cmd-Shift-Z below comes after this check and is not counted.
        mdRstAddQuickChecks(from: keysFrom, count: 3, what: "Cmd-Z, Cmd-Shift-Z, Cmd-Z", to: &soft)
        // The length after the SECOND undo is read last, at the arrival of one more Cmd-Shift-Z (which redoes the restore once more: the
        // test is over, nothing is asserted about the document after it).
        let lengthAfterRedoPress = mdRstPress(redo: true, number: 99)
        result("LENGTHS: before the restore \(lengthBefore); after the restore (first Cmd-Z arrival) "
            + "\(lengthAfterRestore.map(String.init) ?? "n/a"); "
            + "after the second undo, read at the last Cmd-Shift-Z arrival: \(lengthAfterRedoPress.docLength.map(String.init) ?? "n/a")")
        soft.check(lengthAfterRedoPress.docLength == lengthBefore,
            "the editor's length after the second Cmd-Z is \(lengthAfterRedoPress.docLength.map(String.init) ?? "n/a"), "
                + "expected the length before the restore \(lengthBefore)")
        mdRstShot("md-rst-e3-end")
        assertSoft(soft, "Markdown: Replace Current Section, quick Cmd-Z / Cmd-Shift-Z / Cmd-Z without a toast, on \(size.identifier)")
    }
}

// MARK: - E4 Typing inside the restored section comes back (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E4. CLAIM: on the six-chapter book, Replace Current Section on chapter 3; a word is typed at the end of the restored Sub01 line; Cmd-Z
    /// one press at a time (cap 10) until the structural undo has run (the typing is undone by text steps first: a slow host splits it into
    /// several groups); the restore is undone and the editor's length is the length before the restore; Cmd-Shift-Z one press at a time (cap
    /// 10): first the structural redo, then text steps until the editor's own length is the length it had with the typing. The word is back
    /// exactly once, in the Sub01 row, on screen too, no heading line damaged, and every undo / redo of the structural entry was quick.
    /// TODAY: MUST FAIL on the mechanism (slow route, `undo SLOW`); if only the typing came back the old body would pass that half too.
    /// BREAK (addendum 11): delete `putBackSetAsideRedo(view, opId, depthBeforeRedo);` (api-structural-markdown.ts:946): the word is not back.
    func testMdRstSecTypeInsideUndoRedo_book6() {
        let title = Self.chapterThree
        guard mdRstStart(.book6, method: #function, seeds: Self.seeds(sub: true, dup: false)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        let withEdit = mdRstUserRows(mdRstPreRows(replacing: Self.subTwo, with: Self.subTwo + " " + Self.edit))
        let withTyping = mdRstUserRows(mdRstPreRows(replacing: Self.subOne, with: Self.subOne + " " + Self.typedOne))
        guard let lengthBefore = mdRstProbeDocLength() else {
            fail("TEST-SETUP: the editor's document length could not be read before the restore (no keydown line)")
            return
        }
        guard let from = mdRstRestore(.replace, title: title) else { return }
        mdRstWaitForUserRows(mdRstUserRows(pre), timeout: size.operationTimeout * 2)
        mdRstSettle()
        guard mdRstPlaceCaret(paragraph: "Sub01", exactLine: Self.subOne, what: "the restored Sub01 line") else { return }
        mdRstTypeNow(" " + Self.typedOne)
        var soft = Phase4bFlowSoftChecks()
        soft.check(
            mdRstWaitForSentenceInDatabase(Self.typedOne, timeout: 90),
            "the word typed into the restored section never reached the block table")
        mdRstSettle()
        let keysFrom = mdRstLogCount()
        let undo = mdRstUndoUntilStructural()
        mdRstReport("undo", undo)
        soft.check(undo.last?.isStructural == true && undo.last?.performed == true,
            "the restore was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undo.map(\.summary)))")
        let lengthWithTyping = undo.first?.docLength
        soft.check(mdRstWaitForSentenceGone(Self.typedOne, timeout: 120), "the word is still in the block table after the undo")
        mdRstWaitForUserRows(withEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Z (settled)", expectedUser: withEdit, to: &soft)

        let redo = mdRstRedoUntilLength(lengthWithTyping)
        mdRstReport("redo", redo)
        soft.check(redo.first?.isStructural == true && redo.first?.performed == true,
            "Cmd-Shift-Z was decided \(redo.first?.decision ?? "none") (performed: \(redo.first?.performed ?? false)), expected the structural redo")
        soft.check(redo.first?.docLength == lengthBefore,
            "the editor's length after the undo is \(redo.first?.docLength.map(String.init) ?? "n/a"), "
                + "expected the length before the restore \(lengthBefore)")
        let count = mdRstWaitForSentenceCount(Self.typedOne, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the word is in \(count) block row(s) after \(redo.count) Cmd-Shift-Z press(es), expected exactly 1 (the Sub01 line)")
        mdRstWaitForUserRows(withTyping, timeout: size.operationTimeout * 2)
        mdRstSettle()
        let post = mdRstAddRowChecks("after Cmd-Shift-Z (settled)", expectedUser: withTyping, to: &soft)
        if let shown = mdRstWaitForSentenceOnScreen(Self.typedOne, present: true, timeout: 90) {
            soft.check(shown, "the editor does not show the word \"\(Self.typedOne)\" after the redo")
        }
        let headings = post.filter { $0.headingLevel != nil && !$0.isManaged }.map(\.fragment)
        let expectedHeadings = withTyping.filter { $0.headingLevel != nil }.map(\.fragment)
        soft.check(headings == expectedHeadings, "a heading line was damaged: \(headings.count) heading line(s), \(expectedHeadings.count) expected")
        let beeps = mdRstLogLines(containing: "beeping", from: keysFrom)
        soft.check(
            beeps.isEmpty,
            "the editor beeped \(beeps.count) time(s) (a Cmd-Shift-Z that found nothing to redo is the defect's fingerprint): "
                + "\(beeps.prefix(2).map(\.text))")
        // The structural presses (the undo's last, the redo's first) were quick; the text steps in between write no sequence at all.
        let runs = mdRstRuns(from: keysFrom)
        soft.check(runs.count == 2 && runs.allSatisfy { $0.startedQuickMarkdown && $0.restoreDone && !$0.slowRoad },
            "the structural undo and redo ran as \(runs.map { "\($0.label) \($0.startedQuickMarkdown ? "quick" : "slow")" }), "
                + "expected two quick Markdown runs")
        mdRstAddMechanismChecks(kind: .replace, from: from, restores: 1, to: &soft)
        mdRstAddScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        mdRstShot("md-rst-e4-end")
        assertSoft(soft, "Markdown: Replace, type in the restored section, polled Cmd-Z, polled Cmd-Shift-Z, on \(size.identifier)")
    }

    /// Waits until the block table holds exactly `wanted` rows with the sentence.
    func mdRstWaitForSentenceCount(_ sentence: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(timeout, before: "\"\(sentence)\" is counted in the database"))
        var count = mdRstBlocksContaining(sentence)
        while count != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = mdRstBlocksContaining(sentence)
        }
        return count
    }
}

// MARK: - E5 Insert as New Section: the card lands, quick Cmd-Z (MUST-FAIL today; Notes part a CONTROL)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E5. CLAIM: on the twelve-chapter book, "1.1 Ledgers and Their Keepers" (two seeded plain lines under it, the original's Dup02 line
    /// extended by an edit) is inserted as a new section from the saved version. The copy lands after the last section and before Notes: the
    /// rows before it are exactly the document as it was, there are two headings of that title, the second one comes after the last original
    /// section heading and before the first Notes row. ONE click on the LAST card of that title lands on the copy with NO scroll search
    /// (`rounds=0`: the plain Dup02 line, which the edited original no longer has, is fully visible near the top). Then Cmd-Z (polled, cap
    /// 10) removes the copy quickly (`start (quick, markdown)`, no toast), the document is the one before the restore, and the Notes and
    /// Bibliography rows are unchanged (CONTROL: they are not touched by an Insert and passed on the old code).
    /// TODAY: MUST FAIL on the card (premise check, book6: the copy's card was NOT FOUND within 12 scroll rounds, 40,000 pt scrolled) and
    /// on the undo (SLOW). The Notes / Bibliography half passes on the old code.
    /// BREAK (addendum 11): the request sends `plan.markdown` instead of `markdownPageText` (swift-U4.patch): the card does not land.
    func testMdRstInsertAsNewCardUndo_book12() {
        let title = Self.insertSection
        guard mdRstStart(.book12, method: #function, seeds: Self.seeds(sub: false, dup: true)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.dupOne) != nil, mdRstRequireRow(Self.dupTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .insertAsNew) else { return }
        mdRstSettle()
        let beforeRows = mdRstReadRows()
        let beforeUser = mdRstUserRows(beforeRows)
        let beforeManaged = mdRstManagedRows(beforeRows)
        note("ROWS before the Insert: \(beforeRows.count) (\(beforeManaged.count) Notes / Bibliography row(s)); headings titled \"\(title)\": "
            + "\(beforeRows.filter { $0.headingTitle == title }.count)")
        guard let from = mdRstRestore(.insertAsNew, title: title) else { return }
        var soft = Phase4bFlowSoftChecks()
        soft.check(mdRstWaitForCardCount(title, equalTo: 2, timeout: size.operationTimeout) == 2,
            "the Outline does not show two cards titled \"\(title)\" after the Insert")
        mdRstCheckCardLanding(
            MdRstCardTarget(title: title, line: Self.dupTwo, useLast: true, checkHeading: false),
            what: "the copy at once", to: &soft)

        // Where the copy lands: after the last original section heading, before the first Notes row; nothing before it changed.
        let lastOriginalHeading = beforeUser.lastIndex { $0.headingLevel != nil }
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(size.operationTimeout * 2, before: "the copy's heading row is in the block table"))
        var post = mdRstReadRows()
        while post.filter({ $0.headingTitle == title }).count < 2, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            post = mdRstReadRows()
        }
        mdRstSettle()
        post = mdRstReadRows()
        let headings = post.indices.filter { post[$0].headingTitle == title }
        let notesAt = post.firstIndex { $0.isNotes || $0.isBibliography }
        soft.check(headings.count == 2, "the block table holds \(headings.count) heading rows titled \"\(title)\", expected 2")
        if headings.count == 2, let notesAt, let lastOriginalHeading {
            soft.check(
                headings[1] < notesAt,
                "the copy's heading is at row \(headings[1]), not before the Notes / Bibliography rows (row \(notesAt))")
            soft.check(headings[1] > lastOriginalHeading,
                "the copy's heading is at row \(headings[1]), not after the last original section heading (user row \(lastOriginalHeading)): "
                    + "it landed in the middle")
        }
        let head = Array(post.prefix(beforeUser.count))
        let headProblems = mdRstUserDifferences(head, expectedUser: beforeUser)
        soft.check(headProblems.isEmpty, "the rows before the copy changed: \(headProblems.prefix(3))")
        mdRstAddMechanismChecks(kind: .insertAsNew, from: from, restores: 1, to: &soft)

        // Cmd-Z: the copy is removed (quickly); the document is the one before the Insert.
        let keysFrom = mdRstLogCount()
        let undo = mdRstUndoUntilStructural()
        mdRstReport("undo", undo)
        soft.check(undo.last?.isStructural == true && undo.last?.performed == true,
            "the copy was not removed by a structural Cmd-Z within \(Self.pressCap) presses (\(undo.map(\.summary)))")
        soft.check(mdRstWaitForCardCount(title, equalTo: 1, timeout: size.operationTimeout * 2) == 1,
            "the Outline still shows \(mdRstCards(titled: title).count) cards titled \"\(title)\" after Cmd-Z")
        mdRstWaitForUserRows(beforeUser, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Z (settled)", expectedUser: beforeUser, to: &soft)
        let afterUndo = mdRstReadRows()
        let managedProblems = mdRstManagedDifferences(afterUndo, expected: beforeManaged)
        soft.check(managedProblems.isEmpty, "(CONTROL) the Notes / Bibliography rows are not those before the Insert: \(managedProblems.prefix(3))")
        mdRstAddQuickChecks(from: keysFrom, count: 1, what: "Cmd-Z of the Insert", to: &soft)
        mdRstShot("md-rst-e5-end")
        assertSoft(soft, "Markdown: Insert as New Section of \"\(title)\", ONE click on the copy's card, quick Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - E6 Restore Entire Project, type, quick undo and redo (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E6. CLAIM: on the six-chapter book, Restore Entire Project takes an edit at the end of the Anchor05 line away; a word is typed at the
    /// end of that restored Anchor05 line straight after the window closes (in the rows and on screen); Cmd-Z one press at a time (cap 10)
    /// until the structural undo has run; the edit is back and the editor's length is the length before the restore; Cmd-Shift-Z one press
    /// at a time (cap 10): the structural redo, then the typing, until the editor's own length is the length it had with the typing. The
    /// undo and the redo of the entry are quick (`start (quick, markdown)`, `quick restore done (markdown)` for the undo and `quick restore
    /// redo done (markdown)` for the redo, no slow-road line) and the log
    /// holds no `[toast] show` line; the typing is kept.
    /// TODAY: MUST FAIL on the mechanism (premise check, book6: `undo SLOW` / `redo SLOW`, one whole-document `setContent anchorCount=0`).
    /// BREAK (addendum 11): as E3, skip `efRecordedStructGeneration[opId] = ...` in the click (the slow route runs).
    func testMdRstWholeTypeUndoRedo_book6() {
        guard mdRstStart(.book6, method: #function), mdRstRequireRow(Self.anchorFiveLine) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .entire) else { return }
        mdRstSettle()
        let withEdit = mdRstUserRows(mdRstPreRows(replacing: Self.anchorFiveLine, with: Self.anchorFiveLine + " " + Self.edit))
        let withTyping = mdRstUserRows(mdRstPreRows(replacing: Self.anchorFiveLine, with: Self.anchorFiveLine + " " + Self.typedOne))
        guard let lengthBefore = mdRstProbeDocLength() else {
            fail("TEST-SETUP: the editor's document length could not be read before the restore (no keydown line)")
            return
        }
        guard let from = mdRstRestore(.entire, title: "") else { return }
        mdRstWaitForUserRows(mdRstUserRows(pre), timeout: size.operationTimeout * 2)
        mdRstSettle()
        guard mdRstPlaceCaret(
            paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorFiveLine, what: "the restored Anchor05 line"
        ) else { return }
        mdRstTypeNow(" " + Self.typedOne)
        var soft = Phase4bFlowSoftChecks()
        soft.check(mdRstWaitForSentenceInDatabase(Self.typedOne, timeout: 90), "the word typed after the restore never reached the block table")
        soft.check(
            mdRstWaitForSentenceOnScreen(Self.typedOne, present: true, timeout: 60) != false,
            "the word typed after the restore is not on screen")
        mdRstSettle()
        mdRstAddRowChecks("after the restore and the typing (settled)", expectedUser: withTyping, to: &soft)
        mdRstAddMechanismChecks(kind: .entire, from: from, restores: 1, to: &soft)

        let keysFrom = mdRstLogCount()
        let undo = mdRstUndoUntilStructural()
        mdRstReport("undo", undo)
        soft.check(undo.last?.isStructural == true && undo.last?.performed == true,
            "the restore was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undo.map(\.summary)))")
        let lengthWithTyping = undo.first?.docLength
        soft.check(mdRstWaitForSentenceGone(Self.typedOne, timeout: 120), "the typed word is still in the block table after the undo")
        mdRstWaitForUserRows(withEdit, timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Z (settled)", expectedUser: withEdit, to: &soft)

        let redo = mdRstRedoUntilLength(lengthWithTyping)
        mdRstReport("redo", redo)
        soft.check(redo.first?.isStructural == true && redo.first?.performed == true,
            "Cmd-Shift-Z was decided \(redo.first?.decision ?? "none") (performed: \(redo.first?.performed ?? false)), expected the structural redo")
        soft.check(redo.first?.docLength == lengthBefore,
            "the editor's length after the undo is \(redo.first?.docLength.map(String.init) ?? "n/a"), "
                + "expected the length before the restore \(lengthBefore)")
        let count = mdRstWaitForSentenceCount(Self.typedOne, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the typed word is in \(count) block row(s) after \(redo.count) Cmd-Shift-Z press(es), expected exactly 1")
        mdRstWaitForUserRows(withTyping, timeout: size.operationTimeout * 2)
        mdRstSettle()
        let post = mdRstAddRowChecks("after Cmd-Shift-Z (settled)", expectedUser: withTyping, to: &soft)
        mdRstAddQuickChecks(from: keysFrom, count: 2, what: "Cmd-Z and Cmd-Shift-Z of the whole restore", to: &soft)
        mdRstAddScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        mdRstShot("md-rst-e6-end")
        assertSoft(soft, "Markdown: Restore Entire Project, type, polled quick Cmd-Z / Cmd-Shift-Z, typing kept, on \(size.identifier)")
    }
}

// MARK: - E7 Notes of the page equal the Notes rows (CONTROL)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E7 (CONTROL). CLAIM: on the six-chapter book a version is saved, a FOOTNOTED section ("2.2 The Village Registers", two footnote
    /// references) is deleted (the footnotes renumber, the Notes shrink), and Restore Entire Project brings the version back. After the
    /// settle the Notes region of the PAGE equals the Notes rows (the Save Version round trip writes the live editor text into the table:
    /// the table before and after must be identical, every row), the footnote references run 1...n with one definition each, and the user
    /// rows are the version's. Cmd-Z (polled) undoes the restore: again the page equals the rows, the footnotes run 1...n, and the rows are
    /// the document as it was before the restore. The Notes region is read ONLY through this page-text and database seam, never from the
    /// accessibility tree.
    /// TODAY: a CONTROL. The old body writes the rows first and pushes them into the page, so page and rows agree; the plan keeps parity
    /// (D5: nothing new is built). THE CMD-Z TAKES EXACTLY ONE PRESS (asserted): the test types nothing, the document settles before the
    /// restore, and the restore brings back sequential labels, so no footnote renumber is due. The footnote-timer race t-f1a22aa7 (a burst
    /// timer that fired inside the restore's unfinished work and became a Cmd-Z step of its own) was fixed in Phase 4c: the timer now stands
    /// aside while the restore is unfinished. A pin of the count, not a break detector (nothing here makes a renumber due).
    /// BREAK: none (a control). A mismatch goes back to the plan judge as an [approach] question (premise-check.md item 6).
    func testMdRstWholeFootnotes_book6() {
        let deleteTitle = "2.2 The Village Registers"
        guard mdRstStart(.book6, method: #function), let range = mdRstRequireSection(deleteTitle) else { return }
        let refs = Phase4bFlow.footnoteRefsInRange(pre, range)
        guard refs > 0 else {
            fail("TEST-SETUP: the section \"\(deleteTitle)\" holds no footnote reference in the loaded document")
            return
        }
        note("SCENARIO: save a version, delete the footnoted section \"\(deleteTitle)\" (\(refs) footnote reference(s)), "
            + "Restore Entire Project, Cmd-Z")
        guard mdRstSaveVersion(named: Self.versionName),
              let card = mdRstBringIntoView("\"\(deleteTitle)\"", resolve: { self.mdRstCard(deleteTitle) }) else { return }
        mdRstSettle()
        mdRstChooseSidebarItem(card, item: "Delete Section")
        var soft = Phase4bFlowSoftChecks()
        soft.check(mdRstWaitForCard(deleteTitle, present: false, timeout: mdRstAppWait(size.operationTimeout, before: "the deleted card leaves")),
            "the card \"\(deleteTitle)\" is still in the Outline after Delete Section")
        mdRstWaitForHeadingGone(deleteTitle)
        mdRstSettle()
        let beforeRestore = mdRstReadRows()
        note("ROWS before the restore: \(beforeRestore.count); Notes row(s) \(mdRstManagedRows(beforeRestore).count); "
            + "\(Phase4bFlowWalk(rows: beforeRestore).summary)")
        guard let from = mdRstRestore(.entire, title: "") else { return }
        mdRstWaitForUserRows(mdRstUserRows(pre), timeout: size.operationTimeout * 2)
        mdRstSettle()
        let restored = mdRstAddRowChecks("after Restore Entire Project (settled)", expectedUser: mdRstUserRows(pre), to: &soft)
        result("NOTES after the restore (rows): \(Phase4bFlowWalk(rows: restored).summary)")
        mdRstAddScreenEqualsDatabaseCheck(before: restored, what: "after Restore Entire Project (Notes region of the page vs the rows)", to: &soft)
        mdRstAddMechanismChecks(kind: .entire, from: from, restores: 1, to: &soft)
        // The Save Version alert took the keyboard focus: a click puts the caret back in the editor (the page is at the top, Anchor05 is drawn).
        guard mdRstPlaceCaret(
            paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorFiveLine, what: "the Anchor05 line (focus for Cmd-Z)"
        ) else { return }

        let undo = mdRstUndoUntilStructural()
        mdRstReport("undo", undo)
        soft.check(undo.last?.isStructural == true && undo.last?.performed == true,
            "the restore was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undo.map(\.summary)))")
        // THE PRESS COUNT IS ASSERTED (t-f1a22aa7, Phase 4c): nothing was typed and the document settled before the restore, so the
        // editor's text history holds no step ahead of the restore and Cmd-Z #1 is the structural undo.
        result("PRESS COUNT (asserted, t-f1a22aa7): the Cmd-Z took \(undo.count) press(es) (expected exactly 1)")
        soft.check(undo.count == 1,
            "the Cmd-Z took \(undo.count) presses, expected exactly 1 (the structural undo): \(max(0, undo.count - 1)) text step(s) stood before it, "
            + "a footnote renumber of its own (t-f1a22aa7) or typing the test never made (\(undo.map(\.summary)))")
        mdRstWaitForUserRows(mdRstUserRows(beforeRestore), timeout: size.operationTimeout * 2)
        mdRstSettle()
        let undone = mdRstAddRowChecks("after Cmd-Z (settled)", expectedUser: mdRstUserRows(beforeRestore), to: &soft)
        result("NOTES after Cmd-Z (rows): \(Phase4bFlowWalk(rows: undone).summary)")
        mdRstAddScreenEqualsDatabaseCheck(before: undone, what: "after Cmd-Z (Notes region of the page vs the rows)", to: &soft)
        mdRstShot("md-rst-e7-end")
        assertSoft(
            soft,
            "Markdown: Restore Entire Project over a footnoted section's delete, the Notes of the page equal the rows (CONTROL), "
                + "on \(size.identifier)")
    }

    /// Waits (a condition) until no heading row is titled `title`.
    func mdRstWaitForHeadingGone(_ title: String) {
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(size.operationTimeout * 2, before: "the heading rows of \"\(title)\" are gone"))
        while mdRstReadRows().contains(where: { $0.headingTitle == title }), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        }
    }
}

// MARK: - E8 Delete, Replace, Cmd-Z twice back to back (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E8. CLAIM: on the six-chapter book a version is saved, an edit is typed into chapter 3's flat range, a footnote-free level-3
    /// sub-section of chapter 3 is deleted with the Delete's job held 3.5 s (`FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N=1`: the held job is the
    /// Delete's, the restore's job is not), and Replace Current Section on chapter 3 is pressed straight after (its click waits behind the
    /// Delete's hold when it arrives inside it). Then Cmd-Z TWICE, back to back (two key events, nothing between them, NO polled loop): both
    /// act. The edit is back (the Replace is undone), the deleted sub-section is back (the Delete is undone), the rows are the document as
    /// it was before the Delete, and both presses are quick (two `start (quick, markdown)` runs, no slow-road line). An earlier Delete stays
    /// quick-undoable after a restore because the restore does NOT bump `structuralOutOfQueueGeneration`.
    /// HELD OR NOT: the VM's Version History driving needs 7 to 10 s, longer than the 3.5 s hold, so whether the Replace click met the
    /// held Delete is REPORTED (`REPLACE CLICK vs THE DELETE'S HOLD`), never asserted (e2e-verify: never assert a click within N ms of a held
    /// job). That the held restore waits and then acts is proven by the unit tests U6 and U15; this test proves the end state in the real app.
    /// TODAY: MUST FAIL. The old restore bumps the generation: the Delete's undo goes the slow route ("Undoing...") and so does the
    /// restore's.
    /// BREAK (addendum 11): bump `structuralOutOfQueueGeneration` in the Markdown restore click (swift-U7.patch).
    func testMdRstDeleteThenRestoreHeldUndoUndo_book6() {
        let title = Self.chapterThree
        let env = [Self.holdKey: String(Self.jobHoldMs), Self.holdFirstKey: "1"]
        guard mdRstStart(.book6, method: #function, env: env, seeds: Self.seeds(sub: true, dup: false)),
              let chapterRange = mdRstRequireSection(title), mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil else { return }
        guard let target = mdRstFootnoteFreeSubsection(in: chapterRange) else {
            fail("TEST-SETUP: chapter 3 holds no footnote-free level-3 sub-section to delete")
            return
        }
        note("SCENARIO: save a version, type \"\(Self.edit)\" into chapter 3's flat range, delete the footnote-free sub-section \"\(target.title)\" "
            + "(job held), Replace Current Section on chapter 3, Cmd-Z twice back to back")
        guard mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        let beforeDelete = mdRstReadRows()
        guard let deleteCard = mdRstBringIntoView("\"\(target.title)\"", resolve: { self.mdRstCard(target.title) }) else { return }
        let deleteFrom = mdRstChooseSidebarItem(deleteCard, item: "Delete Section")
        var soft = Phase4bFlowSoftChecks()
        soft.check(mdRstWaitForCard(target.title, present: false, timeout: mdRstAppWait(size.operationTimeout, before: "the deleted card leaves")),
            "the card \"\(target.title)\" is still in the Outline after Delete Section")
        guard let started = mdRstStartRestore(.replace, title: title) else { return }
        let heldAtClick = mdRstLogLines(containing: "[MdWrite] structural hold released", from: deleteFrom).isEmpty
        let heldNote = heldAtClick
            ? "NOT yet been released (the click waited behind it)"
            : "already been released (the VM was slower than the 3.5 s hold)"
        result("REPLACE CLICK vs THE DELETE'S HOLD (reported, not asserted): when the Replace's confirm click reached the app the Delete's hold "
            + "had \(heldNote)")
        guard mdRstWaitForVersionHistoryToClose(started.window) else { return }
        // The Delete took the sub-section's rows away and the Replace took the edit away: the loaded document without those rows.
        let afterBoth = pre.enumerated().filter { !target.range.contains($0.offset) && !$0.element.isManaged }.map(\.element)
        mdRstWaitForUserRows(afterBoth, timeout: size.operationTimeout * 2)
        mdRstSettle()
        soft.check(
            mdRstBlocksContaining(Self.edit) == 0,
            "the edit \"\(Self.edit)\" is still in \(mdRstBlocksContaining(Self.edit)) row(s) after the Replace")
        mdRstAddMechanismChecks(kind: .replace, from: started.from, restores: 1, to: &soft)

        // The keyboard focus is in the editor when the keys come (a click puts the caret back; it changes no text and adds no undo step).
        guard mdRstPlaceCaret(paragraph: "Sub01", exactLine: Self.subOne, what: "the restored Sub01 line (focus for Cmd-Z)") else { return }
        // Cmd-Z twice, back to back: two key events, nothing between them, no polled loop.
        let twoFrom = mdRstLogCount()
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        soft.check(
            mdRstWaitForCard(
                target.title, present: true,
                timeout: mdRstAppWait(size.operationTimeout * 2, before: "the deleted card is back")),
            "the deleted sub-section's card \"\(target.title)\" is not back after the two Cmd-Z presses: the second press did not act")
        soft.check(mdRstWaitForSentenceCount(Self.edit, equalTo: 1, timeout: 120) == 1,
            "the edit \"\(Self.edit)\" is in \(mdRstBlocksContaining(Self.edit)) row(s) after the two Cmd-Z presses, expected 1: "
                + "the first press did not undo the Replace")
        mdRstWaitForUserRows(mdRstUserRows(beforeDelete), timeout: size.operationTimeout * 2)
        mdRstSettle()
        mdRstAddRowChecks("after Cmd-Z x2 (settled)", expectedUser: mdRstUserRows(beforeDelete), to: &soft)
        let runs = mdRstRuns(from: twoFrom)
        let keydowns = mdRstLogLines(containing: "[UnifiedUndo] keydown direction=undo ", from: twoFrom)
            .map { Phase4bDelTypingParser.word(after: "decision=", in: $0.text) ?? "?" }
        result("DOUBLE Cmd-Z: \(keydowns.count) editor keydown line(s) \(keydowns); \(runs.count) undo run(s) "
            + "\(runs.map { $0.startedQuickMarkdown ? "quick" : "SLOW" }); "
            + "presses held behind the running undo (`failed=latched`): \(mdRstLogLines(containing: " failed=latched ", from: twoFrom).count)")
        soft.check(runs.count == 2 && runs.allSatisfy { $0.startedQuickMarkdown && !$0.slowRoad },
            "the two Cmd-Z presses ran as \(runs.map { $0.startedQuickMarkdown ? "quick" : "slow" }), expected two `start (quick, markdown)` runs "
            + "(the Delete must stay quick-undoable after the restore)")
        let toasts = mdRstLogLines(containing: "[toast] show", from: twoFrom).map { String($0.text.suffix(120)) }
        let slow = toasts.filter { $0.contains("Undoing") || $0.contains("Redoing") }
        soft.check(slow.isEmpty, "\(slow.count) \"Undoing...\" / \"Redoing...\" toast line(s): \(slow.prefix(2))")
        let refused = mdRstLogLines(containing: "[STRUCT-TRACE] routing-refused", from: twoFrom).filter { !$0.text.contains(" failed=latched ") }
        soft.check(refused.isEmpty, "a Cmd-Z of the double press was refused: \(refused.map(\.text))")
        let fallbacks = mdRstFallbackEvidence(from: deleteFrom)
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        mdRstShot("md-rst-e8-end")
        assertSoft(soft, "Markdown: Delete a sub-section (held), Replace Current Section, Cmd-Z twice back to back, on \(size.identifier)")
    }

    /// The first level-3 heading of `chapterRange` (rows of `pre`) whose own rows hold no footnote reference: a footnote-free single section
    /// to delete without a footnote renumber. Nil when there is none.
    func mdRstFootnoteFreeSubsection(in chapterRange: Range<Int>) -> (title: String, range: Range<Int>)? {
        for index in chapterRange where pre[index].headingLevel == 3 {
            guard let title = pre[index].headingTitle, let range = Phase4bFlow.sectionRange(title, in: pre) else { continue }
            if Phase4bFlow.footnoteRefsInRange(pre, range) == 0 { return (title, range) }
        }
        return nil
    }
}

// MARK: - E9 Timing of the three restores (MEASUREMENT)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E9 (MEASUREMENT). On the twelve-chapter book (699,139 characters, 816 citation groups, 108 footnote marks) the three restores of one
    /// saved version, one after the other in ONE launch: Replace Current Section on "1.1 Ledgers and Their Keepers" (its pane row is cheap
    /// to reach; the cost of the click does not depend on the section), Insert as New Section of the same section, Restore Entire
    /// Project. For each the RESULT lines give, from the app's own log (never from the test's steps): the first log line after the confirm
    /// click to the restored text in the page, the `start (editor-first)` line to the text, the click to `[MdWrite] structural hold released`
    /// (the rows written, the live text flushed), and the page's own `markdown-restore ... ms=` figure with its number of changed places. The
    /// numbers are for the hand-over: compare the shipped Delete (hold raised 573 ms, Outline reacts 1.08 s) and the OLD restore (text 2.4 s
    /// after its start line, the app busy 26 to 28 s afterwards: premise-check.md). The only assertions: the page answered, the job
    /// finished, and a click over 1.4 s showed the working notice "Finishing the last change...".
    /// TODAY: a MEASUREMENT. On the old body there is no `markdown-restore` line, so its checks fail on the mechanism; the old figures are in
    /// premise-check.md. Take the numbers from a run on ONE VM alone, with the model checker paused (e2e-verify: two VMs plus a model-check
    /// run overload this Mac).
    func testMdRstTiming_book12() {
        let title = Self.insertSection
        guard mdRstStart(.book12, method: #function, seeds: Self.seeds(sub: false, dup: true)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.dupTwo) != nil, mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .insertAsNew) else { return }
        mdRstSettle()
        var soft = Phase4bFlowSoftChecks()
        for (kind, label) in [(MdRstKind.replace, "1 Replace"), (.insertAsNew, "2 Insert"), (.entire, "3 Restore Entire")] {
            guard let from = mdRstRestore(kind, title: title) else { return }
            let timing = mdRstMeasure(kind: kind, from: from, label: label)
            mdRstAddTimingChecks(timing, label: label, to: &soft)
            mdRstAddMechanismChecks(kind: kind, from: from, restores: 1, to: &soft)
            mdRstSettle()
        }
        mdRstShot("md-rst-e9-end")
        assertSoft(soft, "Markdown: the three restores timed (MEASUREMENT, no threshold), on \(size.identifier)")
    }
}

// MARK: - E9b A whole restore over a document that differs almost entirely (MEASUREMENT)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E9b (MEASUREMENT, addendum 8). Save version V1 (the twelve-chapter book, 699,139 characters); in Markdown Cmd-A and paste the text of
    /// the six-chapter book (349,810 characters, put on the general pasteboard by the test: a plain-text paste into the editor); save V2;
    /// then Restore All V1, Restore Entire Project: the document the page holds (the six-chapter book) and the version (the twelve-chapter
    /// book) differ almost entirely, the worst case for the page's refined diff. The RESULT lines give, from the app's own log, the click to
    /// the text in the page, the click to the rows written, and the page's own `ms=` with its number of changed places. The cap rule of
    /// the addendum (a `charRunLimit` for the restore) applies only if the page's figure is over 100 ms here; WR16 measured the diff alone
    /// on the dev Mac (26 to 29 ms). The only assertions are those of E9.
    func testMdRstWholeHeavyDifferenceTiming_book12() {
        guard mdRstStart(.book12, method: #function), mdRstRequireRow(Self.anchorFiveLine) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        let smaller = Phase4bDelGenerator.make(chapters: 6)
        note("PASTE: the six-chapter book (\(smaller.counts.characters) characters) goes on the pasteboard; "
            + "the version V1 holds \(doc?.counts.characters ?? 0) characters")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(smaller.markdown, forType: .string)
        guard mdRstPlaceCaret(
            paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorFiveLine, what: "the Anchor05 line (before Cmd-A)"
        ) else { return }
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        // The paste has landed when the rows no longer hold the twelve-chapter book's chapter 12 heading.
        let deadline = Date(timeIntervalSinceNow: mdRstAppWait(
            size.operationTimeout * 3, before: "the pasted six-chapter book reaches the block table"))
        func chapterTwelveRows() -> Int {
            dbInt("SELECT count(*) FROM block WHERE blockType = 'heading' AND instr(markdownFragment, 'Chapter 12:') > 0;") ?? -1
        }
        while chapterTwelveRows() != 0, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 2)) }
        guard chapterTwelveRows() == 0 else {
            mdRstFailWithShot(
                "TEST-SETUP: the pasted six-chapter book never reached the block table (chapter 12 rows: \(chapterTwelveRows()))",
                name: "md-rst-e9b-paste-failed")
            return
        }
        mdRstSettle()
        guard mdRstSaveVersion(named: "RST v2") else { return }
        mdRstSettle()
        var soft = Phase4bFlowSoftChecks()
        guard let from = mdRstRestore(.entire, title: "") else { return }
        let timing = mdRstMeasure(kind: .entire, from: from, label: "Restore Entire Project over a document that differs almost entirely")
        mdRstAddTimingChecks(timing, label: "heavy whole restore", to: &soft)
        mdRstAddMechanismChecks(kind: .entire, from: from, restores: 1, to: &soft)
        mdRstSettle()
        let restoredChapters = dbInt("SELECT count(*) FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# Chapter 12:') > 0;") ?? -1
        soft.check(
            restoredChapters == 1,
            "after the restore the block table holds \(restoredChapters) rows with the heading of chapter 12, expected 1 (the version's text)")
        mdRstShot("md-rst-e9b-end")
        assertSoft(soft, "Markdown: Restore Entire Project over a document that differs almost entirely (MEASUREMENT), on \(size.identifier)")
    }
}

// MARK: - E10 The restored text is on screen while the job is held (MUST-FAIL today)

extension WriteQueuePhase4bMdRestoreEFE2ETests {
    /// E10. CLAIM: on the six-chapter book the first (and only) queued job of the launch is held 3.5 s (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS=3500`,
    /// `FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N=1`: the held job is the restore's). Replace Current Section on chapter 3 takes an edit at the end
    /// of its Sub02 line away. Within 1.0 s of the confirm click, by the app's own log, the page reports the restored text applied (the
    /// `markdown-restore` line); at the moment the test sees that line the rows STILL hold the old text (the edit is in the Sub02 row) and
    /// `[MdWrite] structural hold released` has not been written. After the hold the rows match the page: the edit is gone from the rows, the
    /// restored Sub02 line is on screen, and the Save Version round trip finds the page equal to the table.
    /// TODAY: MUST FAIL. The old body writes the rows before the page shows anything (no `markdown-restore` line at all; "on today's code the
    /// rows change before the text").
    /// BREAK (addendum 11): `guard MarkdownEditorFirstSwitch.enabled` -> `guard false` in the outer function (the old body runs).
    func testMdRstSecRestoredTextOnScreenWhileJobHeld_book6() {
        let title = Self.chapterThree
        let env = [Self.holdKey: String(Self.jobHoldMs), Self.holdFirstKey: "1"]
        guard mdRstStart(.book6, method: #function, env: env, seeds: Self.seeds(sub: true, dup: false)),
              mdRstRequireSection(title) != nil, mdRstRequireRow(Self.subOne) != nil, mdRstRequireRow(Self.subTwo) != nil,
              mdRstSaveVersion(named: Self.versionName) else { return }
        mdRstSettle()
        guard mdRstMakeEdit(kind: .replace) else { return }
        mdRstSettle()
        guard let started = mdRstStartRestore(.replace, title: title) else { return }
        var soft = Phase4bFlowSoftChecks()
        // The page's own report that the restored text is applied; then, at once, the rows and the hold, read in the same breath.
        let pageLine = mdRstWaitForLogLine(containing: "[STRUCT-TRACE] markdown-restore mode=", from: started.from,
                                           timeout: mdRstAppWait(60, before: "the page reports the restored text applied"))
        let rowsAtThatMoment = mdRstBlocksContaining(Self.edit)
        let subTwoRow = mdRstReadRows().first { $0.fragment.hasPrefix("Sub02") }?.fragment ?? "no Sub02 row"
        let releasedAlready = !mdRstLogLines(containing: "[MdWrite] structural hold released", from: started.from).isEmpty
        tail.poll()
        let first = started.from < tail.lines.count ? tail.lines[started.from] : nil
        let clickToText = mdRstMilliseconds(pageLine?.date, first?.date)
        result("HELD JOB: the page reported the restored text \(Self.figure(clickToText)) after the first log line following the confirm click; "
            + "at that moment the rows holding \"\(Self.edit)\": \(rowsAtThatMoment) (the Sub02 row reads \"\(subTwoRow.suffix(40))\"); "
            + "the job's hold already released: "
            + Self.yesNo(releasedAlready))
        soft.check(
            pageLine != nil,
            "the page never reported the restored text applied (no `markdown-restore` line): the restore did not run editor-first")
        if releasedAlready {
            fail(
                "TEST-SETUP: the held job had already finished when the test read the rows (the 3.5 s hold ended first): "
                    + "the old-text check below would mean nothing")
            return
        }
        soft.check((clickToText ?? Int.max) <= 1_000,
            "the restored text reached the page \(Self.figure(clickToText)) after the confirm click (by the app's log), expected within 1000 ms")
        soft.check(rowsAtThatMoment >= 1,
            "at the moment the page showed the restored text the rows no longer held the old text (\"\(Self.edit)\" in \(rowsAtThatMoment) row(s)): "
            + "the rows were changed before the text, the old order")
        guard mdRstWaitForVersionHistoryToClose(started.window) else { return }
        // After the hold: the rows match the page.
        soft.check(mdRstWaitForSentenceGone(Self.edit, timeout: 120), "the edit is still in the block table after the held job finished")
        mdRstWaitForUserRows(mdRstUserRows(pre), timeout: size.operationTimeout * 2)
        mdRstSettle()
        let post = mdRstAddRowChecks("after the hold (settled)", expectedUser: mdRstUserRows(pre), to: &soft)
        soft.check(app.editorStaticText(startingWith: Self.subTwo, timeout: capped(45)) != nil,
            "the restored Sub02 line \"\(Self.subTwo)\" is not on screen after the hold")
        soft.check(
            mdRstWaitForSentenceOnScreen(Self.edit, present: false, timeout: 60) != false,
            "the edit \"\(Self.edit)\" is still on screen after the hold")
        mdRstAddMechanismChecks(kind: .replace, from: started.from, restores: 1, to: &soft)
        mdRstAddScreenEqualsDatabaseCheck(before: post, what: "after the held job", to: &soft)
        mdRstShot("md-rst-e10-end")
        assertSoft(soft, "Markdown: Replace Current Section, the restored text on screen while the job is held, on \(size.identifier)")
    }
}
