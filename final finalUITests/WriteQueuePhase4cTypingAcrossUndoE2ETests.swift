//
//  WriteQueuePhase4cTypingAcrossUndoE2ETests.swift
//  final finalUITests
//
//  bt task t-d2061b27, PHASE 4c JOB 2: A Cmd-Z THAT WAITS BEHIND A SECTION COMMAND KEEPS WAITING WHEN THE USER TYPES, THEN RUNS ON THE DOCUMENT
//  AS IT WAS WHEN THE KEY WAS PRESSED, AND WHAT WAS TYPED IN THE WAIT IS PUT BACK ON TOP, proven in the real app. Until this job such a press was
//  cancelled with the toast "Some undo or redo presses could not be carried out." and the typing stayed (the old refusal, "D13"). The design
//  record is .claude/superdev/cmdz-waits-through-typing/ (plan-v2.md, plan-v2-amendments.md "New tests" and the judge's round-3 verdict D1,
//  swift-contract-rt.md and swift-contract-md.md for the trace line and the knobs).
//
//  CLASS NAME: after the TASK (vmtest's retry-refusal streak is keyed by class and method name across worktrees). The class inherits the harness
//  of WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`: launch, seeding, the app-log follower, the sidebar driving, the evidence writer)
//  and uses the pure helpers of the other Phase 4b files (`Phase4bFlow`, `Phase4bFlowRow`, `Phase4bFlowWalk`, `Phase4bFlowSoftChecks`,
//  `Phase4bSqReorderPair`, `Phase4bMdDragPair`, `Phase4bMdDrag`, `Phase4bDelTraceLine`, `Phase4bDelTypingParser`, and the static seeds
//  `WriteQueuePhase4bMarkdownEFE2ETests.flattening` / `.dragPair`); it changes nothing in any of them. The behaviour classes' own INSTANCE
//  helpers live in THEIR final classes and cannot be reused, so the few this class needs are copied here (the same debt the other Phase 4b
//  classes carry). It is the ONE new permanent UI-test file of the branch (scripts/e2e-hygiene.sh), so it disables the file-length rule.
//
//  THE DOCUMENTS (generated, never a manuscript; every note starts with the fixture tag `[<size> W<words> S<sections> C<citation groups>
//  F<footnote marks> L<characters>]` and `noteCounts()` prints the counts read from the DATABASE):
//    book6   x6 chapters:   349,810 characters, 408 citation groups,  54 footnote marks
//    book12  x12 chapters:  699,139 characters, 816 citation groups, 108 footnote marks
//  The books are the long, complex documents on purpose: the settle that follows a Delete or a drag REALLY rewrites the Notes (the deleted
//  chapter holds nine footnote references, so the footnotes after it are renumbered) and the Bibliography (hundreds of citation groups), and that
//  rewrite lands inside the wait, after the typing. `requireNotesAndBibliographyAtStake` checks it from the loaded rows and fails as TEST-SETUP
//  when the document would not exercise it.
//
//  THE WINDOW IS MADE BY THE TESTS, AND PROVEN BEFORE ANYTHING ELSE IS ASSERTED. A real person cannot press Cmd-Z and type inside the few
//  milliseconds a held press needs, so the tests widen the wait with the app's test-only knobs:
//    FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS    both SLOW routes (a drag's Cmd-Z in Rich Text and in Markdown): the press waits that long between
//        its plan and its swap click. A plain suspension: nothing is blocked. 8,000 ms in Rich Text (the value the earlier slow-undo tests
//        proved: on the twelve-chapter book the UI driver needed more than 3.5 s from the Cmd-Z to the first key), 3,500 ms in Markdown (the
//        route has a safe limit of about 3,900 ms, TestMode.uiTestingSlowUndoPressHoldMs).
//    FF_UI_TESTING_STRUCT_JOB_HOLD_MS (3,500, under the 4 s limit of a hold that blocks the writer: the content-state watchdog fires at 5 s)
//        with ..._FIRST_N=1: the MARKDOWN quick routes (a Delete's and a Duplicate's Cmd-Z): the first job, the command's own, is held, and
//        the Markdown Cmd-Z waits behind it (it waits for the previous Markdown job). The hold sits in the shared `jobBodyHold()`, which the
//        Rich Text Delete, the Rich Text and the Markdown Duplicate (`startEditorFirstDuplicateJob`) and the Markdown Delete
//        (`startEditorFirstJob`) all use, so it covers the Markdown Duplicate's job too (checked in the code, 2026-10-31).
//        It does NOT make the RICH TEXT quick Cmd-Z wait: that one submits its single JavaScript call at once and only its reinsert queues
//        behind the held job (measured: carried out 44 ms after the key). The Rich Text quick route (U2) therefore uses the press hold,
//        3,000 ms, which has to be honoured at the top of `performQuickUndoOfDelete` too; `quickPressWasHeld` checks that it was.
//  Every test types for real, with `typeText`: " don't stop" (an apostrophe, so the smart-quote rule runs), a Return, then "more words". No
//  pause and no wait stands between the Cmd-Z and the first key, or between the keys.
//
//  EVERY TEST ASSERTS, IN THIS ORDER (a failure of an earlier step ends the test, so the first thing a broken app fails is the premise):
//    (1) THE PREMISE, from the app's log: the page's trace line `[STRUCT-TRACE] typing-since-press press=P steps=N decision=rebased` with
//        N >= 1. The line is written whatever the outcome, so an app WITHOUT the fix fails right here, and the message quotes the line it found
//        (`decision=changed` is the old refusal; `decision=matched` means no typing fell in the wait, a TEST-SETUP failure of the window).
//    (2) NO TOAST "Some undo or redo presses could not be carried out." (the log's `[toast] show` lines AND the `toast-message` element).
//    (3) The operation was undone (the chapter is back / the copy is gone / the chapters are in their old order, rows and Outline) and the typed
//        words sit in ONE piece where they were typed, at the end of the Anchor05 line, in order; everything else is the document before.
//    (4) The Cmd-Z after that takes back exactly the typing and nothing else, then Cmd-Shift-Z puts it back. The presses are counted, never a
//        fixed number: a typed sentence is not one undo step on a loaded host (e2e-verify skill), so the loop presses until the rows say the
//        typing is gone (cap 10). When every key was typed inside the wait (none logged after the page's re-check line) the loop must need
//        exactly ONE press (the replay is one history step); otherwise the count is printed.
//    (5) After a quit and a reopen (U6: after Cmd-W and a reopen) the editor and the rows agree: the rows are the document before plus the
//        typing, "more words" occurs EXACTLY ONCE in the rows, and EXACTLY ONCE in the editor. The editor's text is read the way the suite
//        always reads it, through File > Save Version, which writes the LIVE editor text into the block table: the rows after it still hold
//        "more words" once and are unchanged. (A count of accessibility leaves was not used: whether a paragraph is exposed as one leaf or as a
//        container plus a leaf is not settled, so a leaf count could read two for one occurrence.)
//
//  THE TESTS (U-numbers are the plan's)
//    U1 testRichTextDragUndoTypeInWait_book12                    slow route. Drag the section "2.6 Conclusion" below the heading "Chapter 3: ..."
//        (the proven reorder pair; a chapter and its neighbour are seventeen cards apart, so two whole chapters cannot be on screen for a drag),
//        Cmd-Z, type.
//    U2 testRichTextDeleteUndoTypeInWait_book6                   quick route. Delete Section on "Chapter 3: ...", Cmd-Z at once (the quick
//        route's press hold keeps it waiting), type inside the hold; the delete's settle rewrites Notes and Bibliography inside the wait.
//    U3 testMarkdownDragUndoTypeInWait_book12                    slow route in Markdown. The flattened book12, Chapter 7 dropped above Chapter 6
//        (the drag of testMdTypeDragTypePersists_book12), Cmd-Z, type.
//    U4 testMarkdownDeleteUndoTypeInWait_book6                   quick route in Markdown. As U2, but the Cmd-Z waits behind the delete's held job.
//    U5 testMarkdownDuplicateUndoTypeInWait_book6                quick route in Markdown. Duplicate Section on "3.6 Conclusion", Cmd-Z at once, type.
//    U6 testRichTextCloseRightAfterWaitingUndoKeepsTypingOnce_book6   REGRESSION PIN, not a proof of the lifecycle release (see its doc
//        comment): drag, Cmd-Z, type, then Cmd-W at once while the press still waits; reopen: "more words" exactly once in the rows and in
//        the editor. (The Markdown close is a unit test.)
//  WHERE THE WORDS ARE TYPED: at the end of the Anchor05 line of chapter 1 (the proven caret recipe), outside every section these tests delete,
//  duplicate or drag. Typing INSIDE the moved chapter (the web test W2) is not driven here: the proven drags leave the caret outside it.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; at most two runs at once; several --scope flags make one run, never a comma list;
//  a wrong class name silently runs fewer tests, so count the `Test Case ... passed` lines against the scopes):
//    scripts/vmtest/vmtest run --detach --timeout 7000 \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testRichTextDeleteUndoTypeInWait_book6" \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testMarkdownDeleteUndoTypeInWait_book6" \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testMarkdownDuplicateUndoTypeInWait_book6" \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testRichTextCloseRightAfterWaitingUndoKeepsTypingOnce_book6"
//    scripts/vmtest/vmtest run --detach --timeout 7000 \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testRichTextDragUndoTypeInWait_book12"
//    scripts/vmtest/vmtest run --detach --timeout 7000 \
//      --scope "final finalUITests/WriteQueuePhase4cTypingAcrossUndoE2ETests/testMarkdownDragUndoTypeInWait_book12"
//  (book6 tests take 15 to 25 minutes each, book12 tests up to 35 minutes: the book12 tests run one per run.)
//

// swiftlint:disable file_length
import XCTest

// MARK: - What a test did

/// What the operation under test was; it decides what "the Cmd-Z was carried out" means for the block table and the Outline.
enum Phase4cKind {
    /// Delete Section on the section `title`; its undo brings the section back.
    case deleted(title: String)
    /// Duplicate Section on the section `title`; its undo takes the copy "<title> copy" away.
    case duplicated(title: String)
    /// A sidebar drag; its undo gives back the order. `order` lists the titles top to bottom as they read after the undo.
    case dragged(order: [String])
}

/// The moments of a test as app-log indexes.
struct Phase4cRun {
    let kind: Phase4cKind
    /// Just before the click (the delete, the duplicate, the drag).
    let operationFrom: Int
    /// Just before the Cmd-Z.
    let undoFrom: Int
    /// Just before the first typed key.
    let typedFrom: Int
    /// The press's wait in milliseconds (the knob's value), for the failure messages.
    let holdMs: Int
}

/// The page's `[STRUCT-TRACE] typing-since-press press=P steps=N decision=D` line, parsed.
struct Phase4cPremise {
    /// The line's index in the app-log follower.
    let index: Int
    let text: String
    let steps: Int
    let decision: String
}

// MARK: - The test class

/// A Cmd-Z that waits keeps waiting when the user types. See the file header.
final class WriteQueuePhase4cTypingAcrossUndoE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// True when the editor was switched to Markdown for this test.
    var markdownMode = false
    /// How many versions this test has saved (each needs its own name).
    var versionSaves = 0

    static let anchorLine = Phase4bDelHarness.anchorPrefix + " line of the fixture document."
    /// The words typed. The apostrophe is a straight one; the editors turn it into a curly one (`plain(_:)` reads both alike).
    static let wordsOne = "don't stop"
    static let wordsTwo = "more words"
    static let holdKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_MS"
    static let holdFirstKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N"
    static let pressHoldKey = "FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS"
    /// The seams every test sets, so a relaunch can clear them again.
    static let seamKeys = [
        "FF_UI_TESTING_STRUCT_JOB_HOLD_MS", "FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N", "FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS"
    ]
    /// The writer holds the first queued structural job this long (under the 4 s limit of a hold that blocks the writer).
    static let jobHoldMs = 3_500
    static let richTextPressHoldMs = 8_000
    static let markdownPressHoldMs = 3_500
    /// The Rich Text QUICK route's press hold (U2): the UI driver needed 482 ms from the Cmd-Z key to the first typed key on book6
    /// (run-1793469865-95890), so 3,000 ms leaves a margin of about six times that and stays far under the 15,000 ms clamp.
    static let richTextQuickPressHoldMs = 3_000
    /// The most text-undo (or redo) presses a polled loop makes. It only bounds a failing run.
    static let maxPresses = 10
    static let refusalToast = "Some undo or redo presses could not be carried out."

    /// The editors turn the typed apostrophe into a curly one and a no-break space can stand for a space: read both as plain.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    var anchorRow: Int? { pre.firstIndex { $0.fragment == Self.anchorLine } }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// Begins the method, seeds (a flattened copy when `flat` is not empty), launches the document with the given seams, reads the saved
    /// document, logs the fixture counts and, for `markdown`, switches the editor to Markdown (View > Switch to Markdown, Cmd-/). False after a
    /// reported failure.
    func startScenario(
        _ size: Phase4bDelSize, method: String, env: [String: String], markdown: Bool, flat: [Int] = []
    ) -> Bool {
        begin(method: method, size: size)
        markdownMode = markdown
        if !flat.isEmpty, let generated = doc {
            let flattened = WriteQueuePhase4bMarkdownEFE2ETests.flattening(generated, chapters: flat)
            doc = flattened
            note("SEED: a FLATTENED COPY, chapters \(flat) have no sub-headings; \(flattened.counts.reportLine)")
        } else {
            note("SEED: the generated document, NOT flattened (the full outline)")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            app.launchEnvironment[key] = value
            note("SEAM \(key)=\(value)")
        }
        guard launchScenario() else { return false }
        pre = readRows()
        tail.poll()
        evidenceLogStart = tail.lines.count
        let walk = Phase4bFlowWalk(rows: pre)
        guard walk.problems.isEmpty else {
            fail("the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        noteCounts()
        guard !markdown || switchMode(to: "Markdown") else { return false }
        newPhase()
        return true
    }

    /// Each phase of a test (after the load, after a reopen) gets the size's whole wall-clock budget: `capped(...)` shortens every wait to a 5 s
    /// floor once the budget is spent, which would make a working app look broken in a test that makes several phases.
    func newPhase() { startedAt = Date() }

    /// The counts of the document as the database holds it at the start of a test (beside the fixture tag every note carries).
    func noteCounts() {
        let walk = Phase4bFlowWalk(rows: pre)
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        note("COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), "
            + "\(walk.definitions.count) footnote definition(s), \(citations) citation bracket(s) in the rows, "
            + "\(pre.filter(\.isNotes).count) Notes row(s), \(pre.filter(\.isBibliography).count) Bibliography row(s)")
    }

    /// The editor-mode button reads "Markdown" or "Rich Text" (the mode's display name).
    var modeLabel: String { app.buttons["status-bar-editor-mode"].label }

    /// Switches the editor to `wanted` ("Markdown" or "Rich Text") with Cmd-/, the shortcut of the View menu's "Switch to ..." item, pressed
    /// ONCE, then waits for the badge (a condition) and, for Markdown, for the page itself (`waitForMarkdownPageReady`: the badge flips
    /// before the page exists, t-55b63c87).
    func switchMode(to wanted: String) -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        if mode.label != wanted {
            app.activateAndWaitForForeground()
            tail.poll()
            let switchFrom = tail.lines.count
            // The View menu's "Switch to ..." item is bound to Cmd-/ (the status bar's hint); this IS that menu command.
            app.typeKey("/", modifierFlags: .command)
            guard mode.waitForLabel("== '\(wanted)'", timeout: appWait(size.operationTimeout * 2, before: "the mode button reads \(wanted)")) else {
                fail("the editor-mode button never reported \(wanted) after the toggle keystroke (it reads \(mode.label))")
                return false
            }
            if wanted == "Markdown" { guard waitForMarkdownPageReady(from: switchFrom) else { return false } }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: \(wanted); the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    func requireAnchorRow() -> Bool {
        guard anchorRow != nil else {
            fail("TEST-SETUP: the loaded document has no \"\(Self.anchorLine)\" row")
            return false
        }
        return true
    }

    /// The caret at the end of the Anchor05 line (the proven exact-line recipe; confirmed through the status bar's selection count).
    func placeCaret() -> Bool {
        placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine)
    }

    /// The section `title` of `pre`, or a reported TEST-SETUP failure.
    func requireSection(_ title: String) -> Range<Int>? {
        guard let range = Phase4bFlow.sectionRange(title, in: pre) else {
            fail("TEST-SETUP: the loaded document has no section \"\(title)\"")
            return nil
        }
        return range
    }

    /// The stakes of the settle that follows a Delete: the deleted section holds footnote references (so the Notes are renumbered and
    /// rewritten) and the document holds hundreds of citations (so the Bibliography is rebuilt). The judge's round-2 note: the Delete tests
    /// must run on a book whose settle REALLY rewrites them. A TEST-SETUP failure when the loaded document would not exercise it.
    func requireNotesAndBibliographyAtStake(_ range: Range<Int>, title: String) -> Bool {
        let references = pre[range].flatMap { Phase4bFlow.footnoteRefs(in: $0.fragment) }.count
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        let notes = pre.filter(\.isNotes).count
        let bibliography = pre.filter(\.isBibliography).count
        note("SETTLE STAKES: \"\(title.prefix(40))\" holds \(references) footnote reference(s) (the footnotes after it are renumbered, so the "
            + "Notes are rewritten); the document holds \(citations) citation bracket(s), \(notes) Notes row(s), \(bibliography) Bibliography row(s)")
        guard references >= 1, citations >= 100, notes >= 1, bibliography >= 1 else {
            fail("TEST-SETUP: the settle of deleting \"\(title)\" would not rewrite the Notes and the Bibliography (\(references) footnote "
                + "reference(s) in the section, \(citations) citation bracket(s), \(notes) Notes row(s), \(bibliography) Bibliography row(s))")
            return false
        }
        return true
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func readRows() -> [Phase4bFlowRow] {
        let output = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT blockType || '|' || isNotes || '|' || isBibliography || '|' || hex(markdownFragment) FROM block ORDER BY sortOrder, id;")
        var rows: [Phase4bFlowRow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else {
                fail("a block row could not be read from \(TestFixtureHelper.fixturePath)/content.sqlite (line starts \"\(line.prefix(60))\")")
                continue
            }
            rows.append(Phase4bFlowRow(
                type: String(parts[0]), isNotes: parts[1] == "1", isBibliography: parts[2] == "1", fragment: Phase4bFlow.decodeHex(parts[3])))
        }
        return rows
    }

    /// How many times `text` occurs in the saved rows (all rows, Notes and Bibliography included), ignoring case. Counts OCCURRENCES, not
    /// rows: in Markdown a Return keeps both lines in one row, so a duplicated line would not show in a row count. -1 when unreadable.
    func occurrencesInRows(_ text: String) -> Int {
        let needle = FixtureDatabase.escape(text.lowercased())
        return dbInt("SELECT COALESCE(SUM((length(lower(markdownFragment)) - length(replace(lower(markdownFragment), '\(needle)', ''))) "
            + "/ length('\(needle)')), 0) FROM block;") ?? -1
    }

    /// The text of the saved Anchor05 row (the typing goes to its end), `apostrophes` and spaces read as plain; empty when there is none.
    func anchorRowInDatabase() -> String {
        Self.plain(dbText("SELECT markdownFragment FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(Self.anchorLine))') = 1 LIMIT 1;"))
    }

    /// True once the rows hold nothing of what was typed: no "more words" anywhere and the Anchor05 row cut back to the anchor line.
    func typedWordsAreGone() -> Bool {
        occurrencesInRows(Self.wordsTwo) == 0 && anchorRowInDatabase() == Self.anchorLine
    }

    /// True once the rows hold what was typed: "more words" once, and the Anchor05 row beginning "Anchor05 ... document. don't stop".
    func typedWordsAreBack() -> Bool {
        occurrencesInRows(Self.wordsTwo) == 1 && anchorRowInDatabase().hasPrefix(Self.anchorLine + " " + Self.wordsOne)
    }

    func exactHeadingCount(_ title: String) -> Int { readRows().filter { $0.headingTitle == title }.count }

    /// The heading rows whose text holds `copyTitle` (the copy's heading reads "<title> copy"), anchored to the heading marker.
    func copyHeadingRows(_ copyTitle: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE blockType = 'heading' AND instr(markdownFragment, '# \(FixtureDatabase.escape(copyTitle))') > 0;")
            ?? -1
    }

    /// The heading rows of `pre` (Notes and Bibliography left out), exactly as the block table holds them: `## 3.6 Conclusion`.
    var preHeadingFragments: [String] {
        pre.filter { !$0.isManaged && $0.headingLevel != nil }.map { $0.fragment.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The same list as the block table holds it now (one light query).
    func headingFragmentsInDatabase() -> [String] {
        FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT markdownFragment FROM block WHERE blockType = 'heading' AND isNotes = 0 AND isBibliography = 0 "
                + "ORDER BY sortOrder, id;")
            .split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func level(_ fragment: String) -> Int { fragment.prefix(while: { $0 == "#" }).count }
    static func title(_ fragment: String) -> String { String(fragment.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespacesAndNewlines) }

    func firstDifference(_ expected: [String], _ actual: [String]) -> String {
        guard let first = zip(expected, actual).enumerated().first(where: { $0.element.0 != $0.element.1 }) else {
            return expected.count == actual.count ? "none" : "\(expected.count) headings expected, \(actual.count) found"
        }
        return "heading \(first.offset): expected \"\(expected[first.offset].prefix(50))\", found \"\(actual[first.offset].prefix(50))\""
    }

    /// The timeout of a wait on the APP's answer to an action the test has already taken. Never shortened by the budget; where the budget is
    /// already spent when such a wait starts, the test fails at once as a TEST-SETUP failure that cannot be taken for an app failure.
    func appWait(_ seconds: TimeInterval, before step: String) -> TimeInterval {
        let left = size.budgetSeconds - Date().timeIntervalSince(startedAt)
        if left <= 0 {
            fail("TEST-SETUP: BUDGET EXHAUSTED before \(step): the \(Int(size.budgetSeconds)) s budget of \(size.identifier) was spent "
                + "\(Int(-left)) s ago, so the app's answer cannot be waited for fairly (the earlier steps of the test used the time, not the app)")
        }
        return seconds
    }

    /// Waits for the app to write the typed words into the block table ("more words" once or more). `timeout` is a fixed number of seconds.
    func waitForTypedWordsInRows(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the typed words are looked for in the block table"))
        repeat {
            if occurrencesInRows(Self.wordsTwo) >= 1, anchorRowInDatabase().hasPrefix(Self.anchorLine + " " + Self.wordsOne) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits until the block table holds exactly `wanted` heading rows whose text holds `copyTitle`.
    func waitForCopyRows(_ copyTitle: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the copy \"\(copyTitle)\" is looked for in the block table"))
        var rows = copyHeadingRows(copyTitle)
        while rows != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            rows = copyHeadingRows(copyTitle)
        }
        return rows
    }

    /// Waits (a condition) until the block table's heading list equals `wanted`.
    func waitForHeadingOrder(_ wanted: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the heading order is looked for in the block table"))
        repeat {
            if headingFragmentsInDatabase() == wanted { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits until the named sections' heading rows are gone / back and the block table and the app's log have stopped changing. With no
    /// names it just waits for the document to be quiet. Every wait is a condition.
    @discardableResult
    func settle(gone: [String] = [], back: [String] = []) -> Bool {
        var allDone = true
        for title in gone {
            allDone = waitForHeadingRows(title, equalTo: 0, timeout: appWait(size.operationTimeout, before: "\(title) is gone")) == 0 && allDone
        }
        for title in back {
            allDone = waitForHeadingRows(title, equalTo: 1, timeout: appWait(size.operationTimeout, before: "\(title) is back")) == 1 && allDone
        }
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        return allDone
    }

    /// Remembers the exact lines of a difference for the `row-differences-<method>.txt` attachment.
    func recordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }
}

// MARK: - What the document must hold

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// `rows` without the typed words: the Anchor05 row cut back to the anchor line and the paragraph "more words" dropped (Rich Text makes it
    /// a paragraph of its own; in Markdown it is a second line of the Anchor05 row, which the cut-back removes).
    func withoutTypedWords(_ rows: [Phase4bFlowRow]) -> [Phase4bFlowRow] {
        var kept: [Phase4bFlowRow] = []
        for row in rows where !row.isManaged {
            if Self.plain(row.fragment).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.wordsTwo { continue }
            if row.fragment.hasPrefix(Self.anchorLine) {
                kept.append(Phase4bFlowRow(type: row.type, isNotes: false, isBibliography: false, fragment: Self.anchorLine))
            } else {
                kept.append(row)
            }
        }
        return kept
    }

    /// What is wrong with a saved document: its text rows are `pre`'s text rows (with the typed words taken out when `typedWordsExpected`), its
    /// Notes and Bibliography rows are `pre`'s byte for byte, and the footnote walk (numbers 1...n in reading order, one definition each,
    /// none blank) is clean. Empty: nothing.
    func rowProblems(_ post: [Phase4bFlowRow], what: String, typedWordsExpected: Bool) -> [String] {
        var found: [String] = []
        let expectedUser = pre.filter { !$0.isManaged }.enumerated().map { (row: $0.offset, value: $0.element) }
        let actualRows = typedWordsExpected ? withoutTypedWords(post) : post.filter { !$0.isManaged }
        let actualUser = actualRows.enumerated().map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        let beforeManaged = pre.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let afterManaged = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let managedLines = Phase4bFlow.rowDifferences(expected: beforeManaged, actual: afterManaged, exact: true)
        recordDifferences(what, "Notes / Bibliography rows", managedLines)
        found += managedLines.map { "the Notes / Bibliography rows differ from before: \($0)" }
        found += Phase4bFlowWalk(rows: post).problems.map { "footnotes: \($0)" }
        return found
    }

    /// Nil when the typed words sit in one piece where they were typed: the Anchor05 row begins "Anchor05 ... document. don't stop" and
    /// nothing but "more words" follows it (in the same row after a line break, or as the next row).
    func typedPieceProblem(_ rows: [Phase4bFlowRow]) -> String? {
        let user = rows.filter { !$0.isManaged }
        guard let index = user.firstIndex(where: { $0.fragment.hasPrefix(Self.anchorLine) }) else {
            return "the Anchor05 row is gone from the block table"
        }
        var piece = Self.plain(user[index].fragment)
        if !piece.lowercased().contains(Self.wordsTwo), index + 1 < user.count { piece += "\n" + Self.plain(user[index + 1].fragment) }
        let head = Self.anchorLine + " " + Self.wordsOne
        guard piece.hasPrefix(head) else {
            return "the Anchor05 row reads \"\(piece.prefix(120))\", expected it to begin \"\(head)\""
        }
        let rest = piece.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard rest == Self.wordsTwo else {
            return "after \"\(head)\" the document reads \"\(rest.prefix(80))\", expected exactly \"\(Self.wordsTwo)\" (the typed words are not in one piece)"
        }
        return nil
    }

    /// What is wrong with the structure the undo should have given back (empty: nothing), read from the block table and the Outline.
    func structureProblems(_ kind: Phase4cKind) -> [String] {
        var found: [String] = []
        switch kind {
        case .deleted(let title):
            let rows = exactHeadingCount(title)
            if rows != 1 { found.append("the section \"\(title)\" is in the block table \(rows) time(s), expected once: the Cmd-Z did not bring it back") }
            if !sidebarCard(title).exists { found.append("the Outline has no card \"\(title)\"") }
        case .duplicated(let title):
            let copies = copyHeadingRows(title + " copy")
            if copies != 0 { found.append("the block table holds \(copies) heading row(s) \"\(title) copy\", expected none: the Cmd-Z did not take the copy away") }
            let originals = exactHeadingCount(title)
            if originals != 1 { found.append("the section \"\(title)\" is in the block table \(originals) time(s), expected once") }
            if sidebarCard(title + " copy").exists { found.append("the Outline still shows the card \"\(title) copy\"") }
        case .dragged(let order):
            let now = headingFragmentsInDatabase()
            if now != preHeadingFragments { found.append("the heading order is not the one before the drag (\(firstDifference(preHeadingFragments, now)))") }
            if let problem = sidebarOrderProblem(order) { found.append("the Outline does not show the old order: \(problem)") }
        }
        return found
    }

    /// Waits (conditions) until the undo's effect shows: the section is back, the copy is gone, the old order is back; then for the Outline.
    func waitUntilRestored(_ kind: Phase4cKind) {
        switch kind {
        case .deleted(let title):
            _ = settle(back: [title])
            _ = waitForCard(title, present: true, timeout: appWait(size.operationTimeout, before: "the card \"\(title)\" comes back"))
        case .duplicated(let title):
            _ = waitForCopyRows(title + " copy", equalTo: 0, timeout: appWait(size.operationTimeout * 2, before: "the copy's rows are gone"))
            _ = settle()
            _ = waitForCard(title + " copy", present: false, timeout: appWait(size.operationTimeout, before: "the copy's card leaves the Outline"))
        case .dragged(let order):
            _ = waitForHeadingOrder(preHeadingFragments, timeout: appWait(size.operationTimeout * 2, before: "the old heading order comes back"))
            _ = settle()
            _ = waitForSidebarOrder(order)
        }
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func logIndexNow() -> Int {
        tail.poll()
        return tail.lines.count
    }

    func traceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    /// The log lines since `index` that hold `needle`.
    func logLines(containing needle: String, from index: Int) -> [String] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].map(\.text).filter { $0.contains(needle) }
    }

    func firstLogIndex(from index: Int, where matches: (Phase4bLogLine) -> Bool) -> Int? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return (index..<tail.lines.count).first { matches(tail.lines[$0]) }
    }

    func waitForLogLine(from index: Int, timeout: TimeInterval, where matches: (Phase4bLogLine) -> Bool) -> Int? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let found = firstLogIndex(from: index, where: matches) { return found }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    /// Waits for the operation's own `<label> op=<id> performed` line (the end of the editor-first CLICK sequence; its database job may still
    /// run). False on the timeout.
    @discardableResult
    func waitForPerformed(_ label: String, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if traceLines(from: index).contains(where: { $0.family == .sequence && $0.label == label && $0.step == "performed" }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return false
    }

    /// The `[toast] show` lines since `index` that hold `needle`.
    func toastLines(containing needle: String, from index: Int) -> [String] {
        logLines(containing: "[toast] show", from: index).filter { $0.contains(needle) }
    }

    /// The editor's refusal beep (`structural undo refused (direction=...): beeping`).
    func beepLines(from index: Int) -> [String] { logLines(containing: "beeping", from: index) }

    /// The `[SYNC-DIAG:UpdateNSView] PUSHING` lines since `index`: plain whole-document pushes, which would wipe typing and its history.
    func plainPushCount(from index: Int) -> Int { logLines(containing: "[SYNC-DIAG:UpdateNSView] PUSHING", from: index).count }

    /// The log indexes of the keys the app logged as typed into the editor since `index` (not the Z key of an undo press).
    func typedEditorKeyIndexes(from index: Int) -> [Int] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return (index..<tail.lines.count).filter { position in
            guard let key = Phase4bDelTypingParser.key(tail.lines[position].text) else { return false }
            return key.inEditor && key.code != Phase4bDelTypingParser.zKeyCode
        }
    }

    /// The message of the toast on screen right now, from one accessibility snapshot (`toast-message`): a toast that goes away between an
    /// existence check and a property read cannot fail the test.
    func toastMessage() -> String? {
        guard let snapshot = try? app.staticTexts["toast-message"].snapshot() else { return nil }
        return (snapshot.value as? String) ?? snapshot.label
    }

    /// Waits for the page's `typing-since-press` line since `index` and parses it. Nil when none comes within `timeout`.
    func waitForTypingSincePress(from index: Int, timeout: TimeInterval) -> Phase4cPremise? {
        let marker = "[STRUCT-TRACE] typing-since-press "
        guard let found = waitForLogLine(from: index, timeout: timeout, where: { $0.text.contains(marker) }) else { return nil }
        let text = tail.lines[found].text
        return Phase4cPremise(
            index: found, text: String(text.suffix(200)), steps: Phase4bDelTypingParser.intAfter(" steps=", in: text) ?? -1,
            decision: Phase4bDelTypingParser.word(after: " decision=", in: text) ?? "none")
    }

    func shot(_ name: String) { attachEvidenceScreenshot(app.screenshot(), name: "\(name)-\(size.identifier)") }
}

// MARK: - Driving the app

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func sidebarCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    func waitForCard(_ title: String, present: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if sidebarCard(title).exists == present { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Nil when the sidebar lists the cards of `titles` top to bottom in this order; else what is wrong. Reads the cards' frames, which the
    /// accessibility tree keeps for cards scrolled out of the visible band.
    func sidebarOrderProblem(_ titles: [String]) -> String? {
        var previous: (title: String, y: CGFloat)?
        for title in titles {
            let card = sidebarCard(title)
            guard card.exists else { return "the sidebar has no card \"\(title)\"" }
            let y = card.frame.minY
            if let previous, y <= previous.y {
                return "\"\(title)\" (y \(Int(y))) is not below \"\(previous.title)\" (y \(Int(previous.y)))"
            }
            previous = (title, y)
        }
        return nil
    }

    /// Nil when the sidebar lists `titles` in this order (looked for, bounded, on a condition: the sidebar follows the block table a moment
    /// after it); else what is wrong.
    func waitForSidebarOrder(_ titles: [String]) -> String? {
        let deadline = Date(timeIntervalSinceNow: appWait(60, before: "the sidebar's card order is looked for"))
        var problem = sidebarOrderProblem(titles)
        while problem != nil, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            problem = sidebarOrderProblem(titles)
        }
        return problem
    }

    func pressUndo() { app.typeKey("z", modifierFlags: .command) }

    /// Types straight into whatever has the keyboard focus (the editor, where the caret was placed). One `typeText` call: a verified retype
    /// would wait, and these scenarios are about what happens when typing comes right after another command.
    func typeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typed at once on purpose; the saved document is what the scenario checks, not the keystrokes.
        app.typeText(text)
    }

    /// " don't stop", Return, "more words": real keystrokes, nothing awaited between them.
    func typeTheWords() {
        typeNow(" " + Self.wordsOne)
        app.typeKey(.return, modifierFlags: [])
        typeNow(Self.wordsTwo)
    }

    /// Presses Cmd-Z or Cmd-Shift-Z once and waits (a condition, bounded) for the editor's keydown line; returns what the editor decided for it
    /// (`fallthrough`: a plain text step; `structural`: a structural undo; `swallow`: held behind a running one; `none`: no line).
    func pressTextStep(redo: Bool) -> String {
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        app.typeKey("z", modifierFlags: redo ? [.command, .shift] : .command)
        let marker = "[UnifiedUndo] keydown direction=\(redo ? "redo" : "undo") "
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            tail.poll()
            if from <= tail.lines.count, let line = tail.lines[from...].first(where: { $0.text.contains(marker) }) {
                return Phase4bDelTypingParser.word(after: "decision=", in: line.text) ?? "none"
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        return "none"
    }

    /// Presses Cmd-Z (or Cmd-Shift-Z) one press at a time until `done()` holds, at most `cap` presses: after each press the rows are looked for
    /// a change (a condition, bounded) before the next press, so a press is never given on a stale reading. Returns the presses made, what
    /// the editor decided for each, and whether `done()` holds.
    func pressUntil(
        redo: Bool, cap: Int, what: String, signature: () -> String, done: () -> Bool
    ) -> (presses: Int, decisions: [String], done: Bool) {
        var decisions: [String] = []
        for number in 1...cap {
            let before = signature()
            decisions.append(pressTextStep(redo: redo))
            let deadline = Date(timeIntervalSinceNow: appWait(30, before: "press \(number): \(what)"))
            var finished = done()
            while !finished, signature() == before, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                finished = done()
            }
            if !finished { finished = done() }
            if finished { return (number, decisions, true) }
        }
        return (cap, decisions, false)
    }

    /// A signature of the typed region of the saved document, to see that a press changed something.
    func typedSignature() -> String { anchorRowInDatabase() + "|\(occurrencesInRows(Self.wordsTwo))" }

    /// Cmd-Q, then the app is gone. False (reported) if it is still running after the wait.
    func quitWithCommandQ() -> Bool {
        app.typeKey("q", modifierFlags: .command)
        guard app.wait(for: .notRunning, timeout: capped(180)) else {
            fail("the app was still running 180 s after Cmd-Q")
            return false
        }
        tail.poll()
        note("QUIT: the app is gone (Cmd-Q); the app log holds \(tail.lines.count) line(s) so far")
        return true
    }

    /// Starts the app again on the same project and waits until the editor shows the document.
    func relaunch() -> Bool {
        for key in Self.seamKeys { app.launchEnvironment[key] = nil }
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
        note("REOPENED: the editor shows the document (mode button: \(modeLabel)); \"editor-ready gate satisfied\" line: \(Self.yesNo(ready))")
        newPhase()
        return true
    }

    func reopen() -> Bool { quitWithCommandQ() && relaunch() }

    /// Cmd-W (Close Project), then the wait for the project picker (a condition).
    func closeProjectWithCommandW() -> Bool {
        // e2e-lint: allow cmd-w -- closing the project IS the scenario (Cmd-W is the app's Close Project).
        app.typeKey("w", modifierFlags: .command)
        let deadline = Date(timeIntervalSinceNow: appWait(300, before: "the project picker shows"))
        repeat {
            if app.groups["project-picker"].exists { return true }
            if let message = toastMessage(), message.hasPrefix("Couldn't close the project") {
                fail("the close was cancelled by its time budget and the app said so: \"\(message)\"")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        fail("the project picker never appeared 300 s after Cmd-W")
        return false
    }
}

// MARK: - Save Version: the editor's text equals the database

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// File > Save Version with `name`, and the wait for its snapshot row. Saving a version runs `flushLiveContentToDatabase`, which writes the
    /// LIVE editor text into the block table first.
    @discardableResult
    func saveVersion(named name: String) -> Bool {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = waitForSaveVersionAlert()
        guard alert.exists else { fail("the Save Version alert never appeared"); return false }
        let field = alert.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { fail("the Save Version alert has no name field"); return false }
        field.click()
        field.typeText(name)
        let save = alert.buttons["Save"]
        guard save.waitForExistence(timeout: 10) else { fail("the Save Version alert has no Save button"); return false }
        save.click()
        let deadline = Date(timeIntervalSinceNow: appWait(60, before: "the saved version \"\(name)\" is looked for in the snapshot table"))
        var saved = false
        repeat {
            saved = dbInt("SELECT count(*) FROM snapshot WHERE name = '\(FixtureDatabase.escape(name))';") == 1
            if !saved { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        } while !saved && Date() < deadline
        return saved
    }

    /// The sheet of File > Save Version (a sheet, or a dialog on some macOS builds).
    func waitForSaveVersionAlert() -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: 15)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// The house rule "the screen equals the database": `before` is a read of the block table; File > Save Version then writes the live editor
    /// text into the table, and the table is read again. The two reads must be identical, every row, Notes and Bibliography included. Because
    /// the rows are what the editor holds after that flush, "more words" read from the rows afterwards is "more words" in the editor.
    func addScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout Phase4bFlowSoftChecks) {
        versionSaves += 1
        let name = "Typing across undo check \(versionSaves)"
        let saved = saveVersion(named: name)
        soft.check(saved, "\(what): the version \"\(name)\" was saved (its flush writes the live editor text into the block table)")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let after = readRows()
        let lines = Phase4bFlow.rowDifferences(
            expected: before.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: after.enumerated().map { (row: $0.offset, value: $0.element) }, exact: true)
        recordDifferences(what, "the block table before and after Save Version (screen vs database)", lines)
        note("\(what): SCREEN vs DATABASE: \(before.count) rows before Save Version, \(after.count) after; \(lines.count) difference line(s)")
        soft.check(lines.isEmpty, "\(what): the live editor text differs from the saved block table: \(lines.joined(separator: " | "))")
    }
}

// MARK: - Dragging a card, Rich Text (the proven reorder pair)

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// The set-up check of a reorder: `pair.moved` is a section of `pre` directly followed by the heading `pair.below` (so their cards are
    /// neighbours in the sidebar). A TEST-SETUP failure (reported, false) when not.
    func requireReorderPair(_ pair: Phase4bSqReorderPair) -> Bool {
        guard let range = requireSection(pair.moved) else { return false }
        guard range.upperBound < pre.count, pre[range.upperBound].headingTitle == pair.below else {
            let next = range.upperBound < pre.count ? String(pre[range.upperBound].fragment.prefix(60)) : "nothing"
            fail("TEST-SETUP: the section \"\(pair.moved)\" is not directly followed by the heading \"\(pair.below)\" (the next row is \"\(next)\")")
            return false
        }
        return true
    }

    /// Brings the card of `pair.moved` into the sidebar's visible band and, with it, the card of `pair.below` right under it: a drag needs
    /// both on screen at once. Fails the test (TEST-SETUP) when they cannot both be made visible.
    func bringReorderCardsIntoView(_ pair: Phase4bSqReorderPair) -> (source: XCUIElement, target: XCUIElement)? {
        guard let source = bringSidebarCardIntoView(pair.moved) else { return nil }
        let target = sidebarCard(pair.below)
        guard target.waitForExistence(timeout: 10) else {
            fail("TEST-SETUP: the sidebar has no card \"\(pair.below)\" under the card \"\(pair.moved)\"")
            return nil
        }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        if !scroll.frame.insetBy(dx: 0, dy: 20).contains(source.frame.union(target.frame)) {
            // Centre the two cards in the band: one scroll, with one sign check.
            let wanted = (source.frame.minY + target.frame.maxY) / 2 - scroll.frame.midY
            let before = source.frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: -wanted)
            app.waitForStableFrame(source)
            if source.exists, (source.frame.midY - before) * (-wanted) < 0 {
                scroll.scroll(byDeltaX: 0, deltaY: wanted * 2)
                app.waitForStableFrame(source)
            }
        }
        let band = scroll.frame.insetBy(dx: 0, dy: 20)
        let both = source.frame.union(target.frame)
        note("SIDEBAR: \"\(pair.moved)\" \(Self.describeFrame(source.frame)) and \"\(pair.below)\" \(Self.describeFrame(target.frame)); "
            + "visible band \(Self.describeFrame(band)); both inside: \(Self.yesNo(band.contains(both)))")
        guard band.contains(both) else {
            fail("TEST-SETUP: the cards \"\(pair.moved)\" and \"\(pair.below)\" are not both inside the sidebar's visible band, "
                + "so one drag cannot reach from one to the other")
            return nil
        }
        return (source, target)
    }

    /// Drags the card of `pair.moved` onto the left end of the card of `pair.below` (press, drag slowly, hold: the proven recipe). The log
    /// index just before the drag, nil after a reported failure.
    func dragCard(_ pair: Phase4bSqReorderPair) -> Int? {
        guard let cards = bringReorderCardsIntoView(pair) else { return nil }
        app.activateAndWaitForForeground()
        let from = logIndexNow()
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let grab = cards.source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let drop = cards.target.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        grab.press(forDuration: 0.5, thenDragTo: drop, withVelocity: .slow, thenHoldForDuration: 0.3)
        note("DRAG: \"\(pair.moved)\" dragged onto the left end of \"\(pair.below)\"; app-log line \(from) is the first the reorder can write")
        return from
    }

    /// Waits (conditions on the log) for the reorder the drag started: its `start` line within 60 s and then its `performed` line. False after
    /// a reported failure.
    func waitForReorderPerformed(from index: Int) -> Bool {
        let started = waitForLogLine(from: index, timeout: appWait(60, before: "the reorder's start line is looked for")) {
            Phase4bDelTraceLine($0).map { $0.family == .sequence && $0.label == "sectionReorder" && $0.isOpStart } ?? false
        }
        guard started != nil else {
            fail("TEST-SETUP: no `sectionReorder start` line within 60 s of the drag: the press-and-drag did not register as a drag, or the drop "
                + "was a no-op")
            return false
        }
        guard waitForPerformed("sectionReorder", from: index, timeout: appWait(size.operationTimeout * 2, before: "the reorder performs")) else {
            fail("the reorder never reached its performed line within \(Int(size.operationTimeout * 2)) s")
            return false
        }
        return true
    }

    /// One Rich Text reorder, the way a person gives it: drag the section onto its target, wait (conditions) for the reorder to be performed and
    /// the document to be quiet, check that the heading order really changed (a TEST-SETUP failure when it did not: the undo would have nothing
    /// to undo), then click back into the Anchor05 line so the keyboard is in the editor, where the caret was when the reorder began. The log
    /// index just before the drag, nil after a reported failure.
    func reorderAndSettle(_ pair: Phase4bSqReorderPair) -> Int? {
        guard let dragFrom = dragCard(pair), waitForReorderPerformed(from: dragFrom) else { return nil }
        _ = settle()
        guard headingFragmentsInDatabase() != preHeadingFragments else {
            fail("TEST-SETUP: the heading order in the block table is the one before the drag: the reorder changed nothing, "
                + "so its undo has nothing to undo")
            return nil
        }
        clickBackIntoAnchor()
        return dragFrom
    }
}

// MARK: - Dragging a card, Markdown (the drag of testMdTypeDragTypePersists)

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// The heading right above `target` in the block table (nil for the first heading).
    func headingAbove(_ target: String) -> String? {
        let titles = headingFragmentsInDatabase().map { Self.title($0) }
        guard let index = titles.firstIndex(of: target), index > 0 else { return nil }
        return titles[index - 1]
    }

    /// Brings the cards of `titles` into the sidebar's visible band at once; fails the test (TEST-SETUP) when they cannot all fit.
    func bringIntoView(_ titles: [String]) -> [XCUIElement]? {
        guard let first = bringSidebarCardIntoView(titles[0]) else { return nil }
        var cards = [first]
        for title in titles.dropFirst() {
            let card = sidebarCard(title)
            guard card.waitForExistence(timeout: 10) else {
                fail("TEST-SETUP: the sidebar has no card \"\(title)\"")
                return nil
            }
            cards.append(card)
        }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let band = scroll.frame.insetBy(dx: 0, dy: 20)
        func union() -> CGRect { cards.map(\.frame).reduce(cards[0].frame) { $0.union($1) } }
        if !band.contains(union()) {
            let wanted = union().midY - scroll.frame.midY
            let before = cards[0].frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: -wanted)
            app.waitForStableFrame(cards[0])
            if cards[0].exists, (cards[0].frame.midY - before) * (-wanted) < 0 {
                scroll.scroll(byDeltaX: 0, deltaY: wanted * 2)
                app.waitForStableFrame(cards[0])
            }
        }
        let both = union()
        note("SIDEBAR: cards \(titles.map { "\"\($0.prefix(30))\"" }) span \(Self.describeFrame(both)); visible band \(Self.describeFrame(band)); "
            + "all inside: \(Self.yesNo(band.contains(both)))")
        guard band.contains(both) else {
            fail("TEST-SETUP: the cards \(titles) are not all inside the sidebar's visible band, so one drag cannot reach from one to the other")
            return nil
        }
        return cards
    }

    /// Works out a drag of the card `moved` to just before the heading `target` (a drop on the card ABOVE `target`) at heading level `level`:
    /// the cards are brought into the sidebar's visible band and the drop point is computed; nothing is pressed. Nil after a reported failure.
    func prepareDrag(_ moved: String, before target: String, level: Int) -> Phase4bMdDrag? {
        guard let dropOn = headingAbove(target) else {
            fail("TEST-SETUP: \"\(target)\" is the first heading of the block table: there is no card above it to drop on")
            return nil
        }
        guard let cards = bringIntoView([moved, dropOn]) else { return nil }
        let predecessorLevel = headingFragmentsInDatabase().first { Self.title($0) == dropOn }.map { Self.level($0) } ?? 1
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let zones = CGFloat(predecessorLevel + 1)
        let wanted = CGFloat(min(max(level, 1), predecessorLevel + 1))
        let screenX = scroll.frame.minX + (wanted - 0.5) * scroll.frame.width / zones
        let dropCard = cards[1]
        let dropPoint = dropCard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: screenX - dropCard.frame.minX, dy: 0))
        let point = dropPoint.screenPoint
        note("DRAG PREPARED: \"\(moved.prefix(40))\" alone to just before \"\(target.prefix(40))\" (dropped on the card of \"\(dropOn.prefix(40))\") "
            + "at level \(level): pointer ends at (\(Int(point.x)), \(Int(point.y))) in the sidebar \(Self.describeFrame(scroll.frame)); "
            + "dragged card \(Self.describeFrame(cards[0].frame)); drop card \(Self.describeFrame(dropCard.frame))")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        return Phase4bMdDrag(moved: moved, dropOn: dropOn, target: target, option: false, level: level, cards: cards, dropPoint: dropPoint)
    }

    /// Presses the dragged card and lets it go on the prepared drop point. The app-log index just before the press.
    func performDrag(_ drag: Phase4bMdDrag) -> Int {
        app.activateAndWaitForForeground()
        let from = logIndexNow()
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let grab = drag.cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.5, thenDragTo: drag.dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3)
        return from
    }
}

// MARK: - The five assertions of every test, in order

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    /// (1) THE PREMISE: the page's `typing-since-press` line says the typing fell inside the wait and was put back (`decision=rebased`,
    /// `steps` >= 1). Written whatever the outcome, so an app without the fix fails here with the line it wrote in the message.
    func requirePremise(_ run: Phase4cRun) -> Phase4cPremise? {
        let timeout = appWait(Double(run.holdMs) / 1_000 + size.operationTimeout * 2, before: "the page's typing-since-press line is looked for")
        guard let premise = waitForTypingSincePress(from: run.undoFrom, timeout: timeout) else {
            let seen = logLines(containing: "[STRUCT-TRACE]", from: run.undoFrom).suffix(4).map { String($0.suffix(120)) }
            shot("premise-no-line")
            fail("(1) PREMISE: no `[STRUCT-TRACE] typing-since-press` line within \(Int(timeout)) s of the Cmd-Z, so the waiting press never reached "
                + "its re-check (the last [STRUCT-TRACE] lines were \(seen))")
            return nil
        }
        let opened = premise.decision == "rebased" && premise.steps >= 1
        let typed = typedEditorKeyIndexes(from: run.typedFrom)
        result("PREMISE: \"\(premise.text.suffix(80))\" at log line \(premise.index); \(typed.count) editor key(s) logged since the Cmd-Z, "
            + "\(typed.filter { $0 < premise.index }.count) of them before that line")
        shot("premise")
        var hint = "decision=\(premise.decision) steps=\(premise.steps)"
        if premise.decision == "matched" {
            hint += ": the typing came AFTER the wait (a TEST-SETUP failure of the window; the hold was \(run.holdMs) ms)"
        } else if premise.decision != "rebased" {
            hint += ": the app did not put the typing back (this is the old refusal when it reads `changed`)"
        }
        assertCheck(opened, "(1) PREMISE: the page wrote `\(premise.text)`, expected `decision=rebased` with steps >= 1 (\(hint))")
        return premise
    }

    /// (2) NO TOAST "Some undo or redo presses could not be carried out." in the log and none on screen.
    func checkNoRefusalToast(_ run: Phase4cRun) {
        // The log needle is the middle of the sentence (the toast's full text is `Self.refusalToast`): the line may wrap it in other words.
        let logged = toastLines(containing: "could not be carried out", from: run.operationFrom)
        let onScreen = toastMessage() ?? ""
        shot("after-the-press")
        assertCheck(logged.isEmpty && !onScreen.contains("could not be carried out"),
                    "(2) TOAST: \"\(Self.refusalToast)\" was shown (\(logged.count) `[toast] show` line(s) in the log: \(logged.prefix(2)); on screen: "
                        + "\"\(onScreen)\"): the waiting Cmd-Z was cancelled instead of carried out")
    }

    /// (3) The operation was undone and the typed words sit in one piece where they were typed; everything else is the document before.
    func checkUndoneWithTypingInPlace(_ run: Phase4cRun) {
        waitUntilRestored(run.kind)
        let landed = waitForTypedWordsInRows(timeout: 90)
        _ = settle()
        let post = readRows()
        shot("undone-with-typing")
        var soft = Phase4bFlowSoftChecks()
        soft.check(landed, "(3) the words typed while the Cmd-Z waited never reached the block table (\"\(Self.wordsTwo)\" occurs "
                   + "\(occurrencesInRows(Self.wordsTwo)) time(s); the Anchor05 row reads \"\(anchorRowInDatabase().prefix(100))\")")
        for problem in rowProblems(post, what: "after the Cmd-Z that waited and the typing", typedWordsExpected: true) { soft.check(false, "(3) \(problem)") }
        for problem in structureProblems(run.kind) { soft.check(false, "(3) \(problem)") }
        if let problem = typedPieceProblem(post) { soft.check(false, "(3) \(problem)") }
        let count = occurrencesInRows(Self.wordsTwo)
        soft.check(count == 1, "(3) \"\(Self.wordsTwo)\" occurs \(count) time(s) in the block table, expected exactly once")
        if !markdownMode {
            let replayed = logLines(containing: "typingReplayed=true", from: run.undoFrom).filter { $0.contains(" ok=true") }
            soft.check(replayed.count == 1,
                       "(3) the editor's own success line carries `typingReplayed=true` \(replayed.count) time(s), expected once: \(replayed.map { String($0.suffix(60)) })")
        }
        let beeps = beepLines(from: run.undoFrom)
        soft.check(beeps.isEmpty, "(3) the editor beeped \(beeps.count) time(s) after the Cmd-Z: \(beeps.prefix(2).map { String($0.suffix(100)) })")
        let pushes = plainPushCount(from: run.undoFrom)
        soft.check(pushes == 0, "(3) \(pushes) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s): a plain whole-document push wipes typing")
        assertSoft(soft, "(3) the Cmd-Z was carried out and the typed words are in one piece where they were typed")
    }

    /// (4) One Cmd-Z takes back exactly the typing, then Cmd-Shift-Z puts it back. Presses are counted, never fixed: a typed sentence is not one
    /// undo step on a loaded host. When no key was typed after the page's re-check line the replay is the whole typing and it must be ONE step.
    func checkTypingUndoAndRedo(_ run: Phase4cRun, premise: Phase4cPremise) {
        let keys = typedEditorKeyIndexes(from: run.typedFrom)
        let after = keys.filter { $0 > premise.index }.count
        var soft = Phase4bFlowSoftChecks()

        let undo = pressUntil(redo: false, cap: Self.maxPresses, what: "the typing is taken back", signature: typedSignature) { typedWordsAreGone() }
        result("UNDO OF THE TYPING: \(undo.presses) Cmd-Z press(es), the editor decided \(undo.decisions); done: \(Self.yesNo(undo.done)); "
            + "\(keys.count) editor key(s) typed, \(after) of them after the page's re-check line")
        let afterUndo = readRows()
        shot("typing-undone")
        soft.check(undo.done, "(4) \(undo.presses) Cmd-Z press(es) did not take the typed words back out of the block table (decisions \(undo.decisions))")
        soft.check(undo.decisions.allSatisfy { $0 == "fallthrough" },
                   "(4) a Cmd-Z after the typing was not a plain text step (decisions \(undo.decisions)): the structural undo ran again")
        if after == 0 {
            soft.check(undo.presses == 1,
                       "(4) every key was typed inside the wait, so the replay is ONE history step, but it took \(undo.presses) Cmd-Z press(es) to take "
                           + "the typing back (decisions \(undo.decisions))")
        } else {
            note("(4) \(after) key(s) were typed after the swap, so the typing is more than one history step; \(undo.presses) press(es) were needed "
                + "(the exact-one-press rule applies only when every key fell inside the wait)")
        }
        for problem in rowProblems(afterUndo, what: "after the typing was undone", typedWordsExpected: false) { soft.check(false, "(4) \(problem)") }
        for problem in structureProblems(run.kind) { soft.check(false, "(4) after the typing was undone: \(problem)") }
        assertSoft(soft, "(4) one Cmd-Z removes exactly the typing done in the wait")

        let redo = pressUntil(redo: true, cap: max(undo.presses, 1), what: "the typing is put back", signature: typedSignature) { typedWordsAreBack() }
        result("REDO OF THE TYPING: \(redo.presses) Cmd-Shift-Z press(es), the editor decided \(redo.decisions); done: \(Self.yesNo(redo.done))")
        _ = settle()
        let afterRedo = readRows()
        shot("typing-redone")
        var redoSoft = Phase4bFlowSoftChecks()
        redoSoft.check(redo.done, "(4) \(redo.presses) Cmd-Shift-Z press(es) did not put the typed words back (decisions \(redo.decisions))")
        redoSoft.check(redo.presses == undo.presses, "(4) \(undo.presses) Cmd-Z press(es) took the typing out but \(redo.presses) Cmd-Shift-Z press(es) were needed to put it back")
        for problem in rowProblems(afterRedo, what: "after the typing was redone", typedWordsExpected: true) { redoSoft.check(false, "(4) \(problem)") }
        for problem in structureProblems(run.kind) { redoSoft.check(false, "(4) after the typing was redone: \(problem)") }
        if let problem = typedPieceProblem(afterRedo) { redoSoft.check(false, "(4) after the redo: \(problem)") }
        assertSoft(redoSoft, "(4) Cmd-Shift-Z puts the typing back")
    }

    /// (5) After a quit and a reopen the rows are the document before plus the typing, "more words" occurs exactly once in the rows, and exactly
    /// once in the editor (read through Save Version's flush of the live editor text).
    func checkAfterReopen(_ run: Phase4cRun) {
        guard reopen() else { return }
        waitUntilRestored(run.kind)
        _ = settle()
        let anchorShown = app.editorStaticText(startingWith: Self.anchorLine, timeout: appWait(90, before: "the Anchor05 line is looked for on screen")) != nil
        let rows = readRows()
        shot("reopened")
        var soft = Phase4bFlowSoftChecks()
        soft.check(anchorShown, "(5) after the reopen the Anchor05 line is not on screen")
        let rowCount = occurrencesInRows(Self.wordsTwo)
        soft.check(rowCount == 1, "(5) after the reopen \"\(Self.wordsTwo)\" occurs \(rowCount) time(s) in the rows, expected exactly once")
        for problem in rowProblems(rows, what: "after the quit and the reopen", typedWordsExpected: true) { soft.check(false, "(5) \(problem)") }
        for problem in structureProblems(run.kind) { soft.check(false, "(5) after the reopen: \(problem)") }
        if let problem = typedPieceProblem(rows) { soft.check(false, "(5) after the reopen: \(problem)") }
        addScreenEqualsDatabaseCheck(before: rows, what: "after the reopen", to: &soft)
        let editorCount = occurrencesInRows(Self.wordsTwo)
        result("(5) \"\(Self.wordsTwo)\" occurs \(rowCount) time(s) in the rows after the reopen and \(editorCount) time(s) in the rows after Save Version wrote "
            + "the live editor text into them")
        soft.check(editorCount == 1, "(5) after Save Version wrote the editor's text into the rows, \"\(Self.wordsTwo)\" occurs \(editorCount) time(s) there, expected exactly once in the editor")
        assertSoft(soft, "(5) after the reopen the editor and the rows agree")
    }

    /// The five assertions, in order. Each stage ends the test if it fails.
    func runAssertions(_ run: Phase4cRun) {
        guard let premise = requirePremise(run) else { return }
        checkNoRefusalToast(run)
        checkUndoneWithTypingInPlace(run)
        checkTypingUndoAndRedo(run, premise: premise)
        checkAfterReopen(run)
    }
}

// MARK: - U1 and U3: a drag, Cmd-Z, type

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func testRichTextDragUndoTypeInWait_book12() { runDragUndoTypeInWait(.book12, method: #function, markdown: false) }
    func testMarkdownDragUndoTypeInWait_book12() { runDragUndoTypeInWait(.book12, method: #function, markdown: true) }

    /// User step: "Drag a section in the Outline, press Cmd-Z, and type straight away." The drag settles, then Cmd-Z is the next thing done (a
    /// drag's undo is the queued SLOW route by itself) and the words are typed the moment the key is out; the press waits
    /// (`FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS`) so the typing falls inside the wait. See the file header for the five assertions.
    func runDragUndoTypeInWait(_ size: Phase4bDelSize, method: String, markdown: Bool) {
        let holdMs = markdown ? Self.markdownPressHoldMs : Self.richTextPressHoldMs
        let env = [Self.pressHoldKey: String(holdMs)]
        if markdown {
            runMarkdownDrag(size, method: method, env: env, holdMs: holdMs)
        } else {
            runRichTextDrag(size, method: method, env: env, holdMs: holdMs)
        }
    }

    func runRichTextDrag(_ size: Phase4bDelSize, method: String, env: [String: String], holdMs: Int) {
        let pair = Phase4bSqReorderPair(chapter: 2)
        guard startScenario(size, method: method, env: env, markdown: false), requireReorderPair(pair), requireAnchorRow(),
              placeCaret(), let dragFrom = reorderAndSettle(pair) else { return }
        note("SCENARIO: the section \"\(pair.moved)\" was dragged below \"\(pair.below)\"; Cmd-Z, then \"\(Self.wordsOne)\", Return, "
            + "\"\(Self.wordsTwo)\" typed at the end of the Anchor05 line while the press waits \(holdMs) ms")
        app.activateAndWaitForForeground()
        let undoFrom = logIndexNow()
        pressUndo()
        let typedFrom = logIndexNow()
        typeTheWords()
        guard keyReachedTheEditor(from: undoFrom) else { return }
        runAssertions(Phase4cRun(
            kind: .dragged(order: [pair.moved, pair.below]), operationFrom: dragFrom, undoFrom: undoFrom, typedFrom: typedFrom, holdMs: holdMs))
    }

    func runMarkdownDrag(_ size: Phase4bDelSize, method: String, env: [String: String], holdMs: Int) {
        let pair = WriteQueuePhase4bMarkdownEFE2ETests.dragPair(size)
        guard startScenario(size, method: method, env: env, markdown: true, flat: pair.flat), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireAnchorRow(), placeCaret(),
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level) else { return }
        let dragFrom = performDrag(drag)
        guard waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        guard headingFragmentsInDatabase() != preHeadingFragments else {
            fail("TEST-SETUP: the heading order in the block table is the one before the drag: the drag changed nothing, so its undo has nothing to undo")
            return
        }
        clickBackIntoAnchor()
        note("SCENARIO: the chapter \"\(pair.moved.prefix(12))...\" was dragged above \"\(pair.target.prefix(12))...\"; Cmd-Z, then \"\(Self.wordsOne)\", "
            + "Return, \"\(Self.wordsTwo)\" typed at the end of the Anchor05 line while the press waits \(holdMs) ms")
        app.activateAndWaitForForeground()
        let undoFrom = logIndexNow()
        pressUndo()
        let typedFrom = logIndexNow()
        typeTheWords()
        guard keyReachedTheEditor(from: undoFrom) else { return }
        runAssertions(Phase4cRun(
            kind: .dragged(order: [pair.target, pair.moved]), operationFrom: dragFrom, undoFrom: undoFrom, typedFrom: typedFrom, holdMs: holdMs))
    }

    /// A TEST-SETUP guard (after the typing, so it delays nothing): the Cmd-Z reached the editor, i.e. the editor logged its keydown line.
    func keyReachedTheEditor(from undoFrom: Int) -> Bool {
        let arrived = waitForLogLine(from: undoFrom, timeout: appWait(30, before: "the Cmd-Z keydown line is looked for")) {
            $0.text.contains("[UnifiedUndo] keydown direction=undo ")
        }
        guard arrived != nil else {
            fail("TEST-SETUP: no `[UnifiedUndo] keydown direction=undo` line within 30 s of the Cmd-Z: the key did not reach the editor "
                + "(which view had the keyboard focus?)")
            return false
        }
        return true
    }
}

// MARK: - U2 and U4: Delete Section, Cmd-Z at once, type

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func testRichTextDeleteUndoTypeInWait_book6() { runDeleteUndoTypeInWait(.book6, method: #function, markdown: false) }
    func testMarkdownDeleteUndoTypeInWait_book6() { runDeleteUndoTypeInWait(.book6, method: #function, markdown: true) }

    /// User step: "Delete a chapter, press Cmd-Z straight away, and type while it works." The Cmd-Z is the QUICK route; the words are typed
    /// inside its wait. The deleted chapter holds footnote references and the book hundreds of citations, so the delete's settle rewrites the
    /// Notes and the Bibliography inside the wait too.
    ///
    /// HOW THE WAIT IS MADE DIFFERS BY EDITOR (measured, VM run run-1793469865-95890, book6, Rich Text, the delete's job held 3.5 s):
    ///   Markdown: the quick Cmd-Z waits for the previous Markdown job (`awaitStructuralHoldReleased`), so the delete's JOB HOLD
    ///     (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS` 3,500 with `..._FIRST_N=1`) keeps it waiting: U4 passed with it.
    ///   Rich Text: the quick Cmd-Z does NOT queue behind the delete's job. It submits its one JavaScript call in a single synchronous stretch
    ///     (`submitEditorFirstDelete`: reserve a ticket and evaluate, no `await` between) and only its REINSERT job queues behind the held
    ///     job. In the log: Delete `performed` at t=1895546, the Cmd-Z key at t=1895868 (322 ms later), `undo start (quick)` +19 ms, the page's
    ///     `typing-since-press ... steps=0 decision=matched` and the `quick-undo ... ok=true` line +25 ms after that: the press was latched for
    ///     about 44 ms, and the first typed key came 482 ms after the Z key, so the job hold cannot make a window and the premise rightly said
    ///     `matched`. So the Rich Text run asks for the PRESS HOLD instead (`FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS`, 3,000 ms, no job hold:
    ///     the delete's settle then lands inside the wait, after the typing, as it does for a person). That knob must also sit on the quick
    ///     route (see the hand-over: one `await TestMode.holdSlowUndoPress(opId:)` at the top of `performQuickUndoOfDelete`); until it does the
    ///     run stops at `quickPressWasHeld` with a TEST-SETUP message that says so.
    func runDeleteUndoTypeInWait(_ size: Phase4bDelSize, method: String, markdown: Bool) {
        let title = size.deleteTitle
        let env = markdown
            ? [Self.holdKey: String(Self.jobHoldMs), Self.holdFirstKey: "1"]
            : [Self.pressHoldKey: String(Self.richTextQuickPressHoldMs)]
        let holdMs = markdown ? Self.jobHoldMs : Self.richTextQuickPressHoldMs
        guard startScenario(size, method: method, env: env, markdown: markdown), let range = requireSection(title), requireAnchorRow(),
              requireNotesAndBibliographyAtStake(range, title: title), placeCaret(), let card = bringSidebarCardIntoView(title) else { return }
        let why = markdown ? "behind the delete's job, held" : "on the press's own hold on the quick route, held"
        note("SCENARIO: \"\(title)\" is deleted from the Outline; Cmd-Z is the next thing done (it waits \(why) \(holdMs) ms), "
            + "then \"\(Self.wordsOne)\", Return, \"\(Self.wordsTwo)\" are typed at the end of the Anchor05 line")
        let deleteFrom = chooseSidebarItem(card, item: "Delete Section")
        // The command has started when its own line shows (a condition on the log; the click itself may take as long as it likes).
        let started = markdown
            ? waitForLog(containing: "[MdWrite] structural hold raised", from: deleteFrom, timeout: 30)
            : waitForPerformed("sectionDelete", from: deleteFrom, timeout: 30)
        guard started else {
            fail("TEST-SETUP: the delete of \"\(title)\" showed no start line within 30 s of the click")
            return
        }
        app.activateAndWaitForForeground()
        let undoFrom = logIndexNow()
        pressUndo()
        let typedFrom = logIndexNow()
        typeTheWords()
        guard keyReachedTheEditor(from: undoFrom), markdown || quickPressWasHeld(from: undoFrom) else { return }
        runAssertions(Phase4cRun(
            kind: .deleted(title: title), operationFrom: deleteFrom, undoFrom: undoFrom, typedFrom: typedFrom, holdMs: holdMs))
    }

    /// TEST-SETUP guard of the Rich Text QUICK route (after the typing, so it delays nothing): the quick Cmd-Z logged the press hold's
    /// `[SlowUndoPressHold] start` line, i.e. it really waited. Without that line the quick undo ran within about 40 ms of the key (the
    /// measured 44 ms of run-1793469865-95890), no key can fall inside, and the premise would read `decision=matched` for a reason that has
    /// nothing to do with the feature. Stops with the reason in the message instead of letting the premise say it.
    func quickPressWasHeld(from undoFrom: Int) -> Bool {
        let held = waitForLogLine(from: undoFrom, timeout: appWait(10, before: "the quick undo's press-hold line is looked for")) {
            $0.text.contains("[SlowUndoPressHold] start")
        }
        guard held != nil else {
            let quickStart = firstLogIndex(from: undoFrom) { $0.text.contains(" undo op=") && $0.text.contains("start (quick)") }
            fail("TEST-SETUP: no `[SlowUndoPressHold] start` line within 10 s of the Cmd-Z, so the Rich Text QUICK undo took no press hold and "
                + "was carried out within milliseconds of the key (its `start (quick)` line is \(quickStart.map { "log line \($0)" } ?? "missing")): "
                + "FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS is not honoured on the quick route yet (it must be called at the top of "
                + "`performQuickUndoOfDelete`), and the delete's job hold does not make the quick route wait")
            return false
        }
        return true
    }
}

// MARK: - U5: Duplicate Section (Markdown), Cmd-Z at once, type

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func testMarkdownDuplicateUndoTypeInWait_book6() { runDuplicateUndoTypeInWait(.book6, method: #function) }

    /// User step: "Duplicate a section, press Cmd-Z straight away, and type while it works." The duplicate's job is held 3.5 s (the first
    /// job only; `startEditorFirstDuplicateJob` takes the shared `jobBodyHold()` in Markdown too), so the QUICK Cmd-Z waits behind it. The
    /// duplicated section is the footnote-free "3.6 Conclusion"; the words are typed at the end of the Anchor05 line in the ORIGINAL
    /// chapter 1, so the copy goes and the typing stays.
    func runDuplicateUndoTypeInWait(_ size: Phase4bDelSize, method: String) {
        let title = Phase4bDelSize.pairFirst
        let env = [Self.holdKey: String(Self.jobHoldMs), Self.holdFirstKey: "1"]
        guard startScenario(size, method: method, env: env, markdown: true), requireSection(title) != nil, requireAnchorRow(),
              placeCaret(), let card = bringSidebarCardIntoView(title) else { return }
        note("SCENARIO: \"\(title)\" is duplicated from the Outline; Cmd-Z is the next thing done (it waits behind the duplicate's job, held "
            + "\(Self.jobHoldMs) ms), then \"\(Self.wordsOne)\", Return, \"\(Self.wordsTwo)\" are typed at the end of the Anchor05 line")
        let duplicateFrom = chooseSidebarItem(card, item: "Duplicate Section")
        let started = waitForLogLine(from: duplicateFrom, timeout: 30) {
            Phase4bDelTraceLine($0).map { $0.family == .sequence && $0.label == "sectionDuplicate" && $0.isOpStart } ?? false
        }
        guard started != nil else {
            fail("TEST-SETUP: the duplicate of \"\(title)\" showed no `sectionDuplicate start` line within 30 s of the click")
            return
        }
        app.activateAndWaitForForeground()
        let undoFrom = logIndexNow()
        pressUndo()
        let typedFrom = logIndexNow()
        typeTheWords()
        guard keyReachedTheEditor(from: undoFrom) else { return }
        runAssertions(Phase4cRun(
            kind: .duplicated(title: title), operationFrom: duplicateFrom, undoFrom: undoFrom, typedFrom: typedFrom, holdMs: Self.jobHoldMs))
    }
}

// MARK: - U6: Cmd-W right after the typing, while the press still waits (a regression pin)

extension WriteQueuePhase4cTypingAcrossUndoE2ETests {
    func testRichTextCloseRightAfterWaitingUndoKeepsTypingOnce_book6() { runCloseRightAfterWaitingUndo(.book6, method: #function) }

    /// REGRESSION PIN, not a proof of the lifecycle release: the typing survives a close right after a waiting Cmd-Z exactly once in the real
    /// app; the closing whole-document write carries it. The release of the held typing before the close flush is proven by the Swift unit
    /// tests T-a/T-c, not by this test; this test passes with and without that release.
    ///
    /// User step: "Drag a section, press Cmd-Z, type, and close the project at once." The press waits `richTextPressHoldMs`; the words are typed
    /// inside it and Cmd-W follows as the next thing done, while the press still waits. After the reopen "more words" occurs EXACTLY ONCE in
    /// the rows and EXACTLY ONCE in the editor (Save Version's flush), never zero (the hold lost the typing) and never two (the typing was
    /// saved by the close AND replayed). Whether the drag's undo was carried out before the close is printed, not asserted: the close may
    /// cancel the waiting press.
    func runCloseRightAfterWaitingUndo(_ size: Phase4bDelSize, method: String) {
        let pair = Phase4bSqReorderPair(chapter: 3)
        let holdMs = Self.richTextPressHoldMs
        let env = [Self.pressHoldKey: String(holdMs)]
        guard startScenario(size, method: method, env: env, markdown: false), requireReorderPair(pair), requireAnchorRow(),
              placeCaret(), let dragFrom = reorderAndSettle(pair) else { return }
        note("REGRESSION PIN, not a proof of the lifecycle release: the typing survives a close right after a waiting Cmd-Z exactly once in the "
            + "real app; the closing whole-document write carries it. The release of the held typing before the close flush is proven by the "
            + "Swift unit tests T-a/T-c, not by this test; this test passes with and without that release.")
        note("SCENARIO: the section \"\(pair.moved)\" was dragged below \"\(pair.below)\"; Cmd-Z, then \"\(Self.wordsOne)\", Return, "
            + "\"\(Self.wordsTwo)\" are typed while the press waits \(holdMs) ms, and Cmd-W is the next thing done")
        app.activateAndWaitForForeground()
        let undoFrom = logIndexNow()
        pressUndo()
        let typedFrom = logIndexNow()
        typeTheWords()
        let closeFrom = logIndexNow()
        guard closeProjectWithCommandW() else { return }

        // TEST-SETUP: the Cmd-W came while the press still waited, and the keys were typed inside the wait.
        let holdStart = firstLogIndex(from: undoFrom) { $0.text.contains("[SlowUndoPressHold] start") }
        let holdEnd = firstLogIndex(from: undoFrom) { $0.text.contains("[SlowUndoPressHold] end") }
        let armed = firstLogIndex(from: closeFrom) { $0.text.contains("[Lifecycle] armed close") }
        let keys = typedEditorKeyIndexes(from: typedFrom)
        result("WINDOW: press hold start at log line \(holdStart.map(String.init) ?? "none"), end at \(holdEnd.map(String.init) ?? "none"); "
            + "`[Lifecycle] armed close` at \(armed.map(String.init) ?? "none"); \(keys.count) editor key(s) typed, the last at log line "
            + "\(keys.last.map(String.init) ?? "none")")
        guard let holdStart, let armed, armed > holdStart, holdEnd.map({ armed < $0 }) ?? true, let lastKey = keys.last, lastKey > holdStart, lastKey < armed else {
            fail("TEST-SETUP: the close did not come while the Cmd-Z was still waiting with the typing inside the wait (press hold start \(holdStart.map(String.init) ?? "none"), "
                + "hold end \(holdEnd.map(String.init) ?? "none"), `[Lifecycle] armed close` \(armed.map(String.init) ?? "none"), last typed key "
                + "\(keys.last.map(String.init) ?? "none"))")
            return
        }
        guard relaunch() else { return }
        _ = settle()
        let anchorShown = app.editorStaticText(startingWith: Self.anchorLine, timeout: appWait(90, before: "the Anchor05 line is looked for on screen")) != nil
        let rows = readRows()
        shot("close-reopened")
        let undone = headingFragmentsInDatabase() == preHeadingFragments
        let rowCount = occurrencesInRows(Self.wordsTwo)
        result("REGRESSION PIN (not a proof of the lifecycle release; it passes with and without it) REOPENED AFTER Cmd-W: the drag's undo was carried out before the close: \(Self.yesNo(undone)); \"\(Self.wordsTwo)\" occurs \(rowCount) time(s) "
            + "in the rows; the Anchor05 row reads \"\(anchorRowInDatabase().prefix(100))\"")
        var soft = Phase4bFlowSoftChecks()
        soft.check(anchorShown, "after the reopen the Anchor05 line is not on screen")
        soft.check(rowCount == 1, "after Cmd-W and the reopen \"\(Self.wordsTwo)\" occurs \(rowCount) time(s) in the rows, expected exactly once "
                   + "(0: the held typing was lost by the close; 2: it was saved and replayed)")
        if let problem = typedPieceProblem(rows) { soft.check(false, "after the reopen: \(problem)") }
        soft.check(Phase4bFlowWalk(rows: rows).problems.isEmpty, "after the reopen the footnotes are not 1...n: \(Phase4bFlowWalk(rows: rows).problems)")
        addScreenEqualsDatabaseCheck(before: rows, what: "after Cmd-W and the reopen", to: &soft)
        let editorCount = occurrencesInRows(Self.wordsTwo)
        result("\"\(Self.wordsTwo)\" occurs \(editorCount) time(s) in the rows after Save Version wrote the live editor text into them")
        soft.check(editorCount == 1, "after Save Version wrote the editor's text into the rows, \"\(Self.wordsTwo)\" occurs \(editorCount) time(s) there, "
                   + "expected exactly once in the editor")
        assertSoft(soft, "Cmd-W right after typing in a waiting Cmd-Z's wait keeps the typing exactly once, on \(size.identifier) (drag from \(dragFrom))")
    }
}
