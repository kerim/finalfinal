//
//  WriteQueuePhase4bQuickUndoE2ETests.swift
//  final finalUITests
//
//  PHASE 4b PART 2, SLICE 2b (bt task t-07eac5cb, parent t-94369a83): THE QUICK UNDO OF A SECTION DELETE, proven in the real app.
//  Delete Section is editor-first; since this slice its Cmd-Z (and Cmd-Shift-Z) is editor-first too: the editor puts the section back (or
//  takes it out again) at once, and the database, the undo snapshot, Notes and the bibliography follow through the ordered write queue
//  (`undo op=<id> start (quick)` ... `performed`, then `reinsert op=<id> applied` / `settled`). This class asserts what a user must see:
//  the section is back on screen at once, typing during and after the undo is never lost, and the database ends equal to the screen.
//
//  CLASS NAME: named after the task on purpose (vmtest's retry-refusal streak keys are not worktree-scoped, so a generic scratch name would
//  collide across parallel worktrees). It reuses the harness of WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`: launch, seeding,
//  the app-log follower, the sidebar driving, the evidence writer) and the pure helpers of WriteQueuePhase4bDeleteFlowE2ETests.swift
//  (`Phase4bFlow`, `Phase4bFlowRow`, `Phase4bFlowWalk`, `Phase4bFlowSoftChecks`); it changes nothing in either file. Its own helpers are the
//  `Phase4bQu...` types and the extensions below (the behaviour class's helpers live in ITS class, so they are copied in the few places
//  they are needed rather than moved).
//
//  THE DOCUMENTS (generated; the counts stand beside every number as the fixture tag `[<size> W<words> S<sections> C<citation groups>
//  F<footnote marks> L<characters>]` that `Phase4bDelHarness.note` puts in front of every line, and `noteCounts()` adds the block, footnote
//  and citation counts read from the DATABASE at the start of each test):
//    article  x1 chapter:   58,764 characters, 68 citation groups,   9 footnote marks (the long article of the committed Phase 4b tests)
//    book6    x6 chapters: 349,810 characters, 408 citation groups,  54 footnote marks
//    book12   x12 chapters: 699,139 characters, 816 citation groups, 108 footnote marks
//  Every chapter also holds 30 comment/task/reference marks, a block quote and Chinese text; the Notes section holds every definition and the
//  generated bibliography follows it. Every chapter of a book repeats the first chapter's prose (same random seed), so no test finds a
//  paragraph of a later chapter by its text.
//
//  HOW "AT ONCE" IS MEASURED: from the app's own log, never from accessibility polling. The Cmd-Z key press is the `[TYPING-TRACE] key` line
//  with the Z key code; the section is painted when the editor's `[STRUCT-TRACE] restore painted op=<id8> path=<quick|slow>` line arrives
//  (the editor posts it from the first animation frame after the swap, on BOTH paths; the quick undo's sidebar update follows that paint, so
//  on the twelve-chapter book the quick figure is about 60 ms key to painted while the Swift `performed` line, which waits for that sidebar
//  update, comes about half a second after the section is already on screen: no assertion bounds key to `performed`). Both lines carry the
//  log's own millisecond stamp, written by the app, so the figure is stamp to stamp. The timing test runs the slow path (forced for the first undo by
//  `FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N=1`) and the quick path in ONE session, and asserts from the log which path each undo took BEFORE it
//  compares the figures. 250 ms is the REPORTED acceptance figure; the asserted bounds are generous (on every document the quick median is
//  under the slow undo and at most 500 ms, and each quick undo's key to `quick restore done` is at most 150 ms: the part the app controls).
//  A book12 median above 250 ms is a standing STOP for the driver, printed as such, not a test failure.
//
//  HOW "TYPED DURING THE UNDO" IS PROVEN: the quick undo has a window in which the editor is paused (typing is shown but not yet queued) that
//  the app resumes at the end. `FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS` stretches that window with a plain suspension (the writer stays
//  free) placed between the editor's restore and the START of the reinsert, so the held window holds nothing but the paused editor: the
//  reinsert and the Notes / bibliography rebuild it triggers start after the hold and cannot end the pause early (with the hold after the
//  reservation the first VM runs saw `quick-resume ... pausedUpdates=0`). The typing tests prove that: the editor's `quick-resume` line shows
//  pausedUpdates >= 1 and no push reaches the editor inside the window (`addPausedWindowProof`). The tests type straight after the
//  app's own `quick restore done` line (a condition, not a wait: a key typed BEFORE the restore turn
//  would be refused by design) and then assert from the app's log that every typed key's time lies between that line and `resumed`.
//  The settle's own hold (`FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS`) and the rebuild's (`FF_UI_TESTING_REBUILD_PUSH_DELAY_MS`) are bounded the
//  same way, by the app's own `[QuickUndoHold]`, `[ReinsertSettleHold]` and `[RebuildPushHold]` start/end markers in diagnostic.log. No seam
//  here blocks the database writer for more than the 3.5 s of the one job-hold test, which also proves the undo does not wait for the job.
//
//  EVERY TEST: prints the counts; reads the block table with `readRows()` / `settle(back:)` BEFORE quitting (the lifecycle's whole-document save
//  would mask a database loss); counts `[SYNC-DIAG:UpdateNSView] PUSHING` lines from the Cmd-Z to the end (must be 0: a plain whole-document
//  push would wipe typing and undo history); and attaches a screenshot before the assertion that can abort.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; see .claude/superdev/quick-undo-section-delete/e2e-map.md for the scopes):
//    scripts/vmtest/vmtest run --scope "final finalUITests/WriteQueuePhase4bQuickUndoE2ETests/testQuickUndoTiming_book6" --timeout 4200
//

// swiftlint:disable file_length
import XCTest

// MARK: - Reading the quick undo's trace

/// One undo or redo the app ran: its Swift sequence lines (`start`, `quick restore done`, `reinsert reserved`, `resumed`, `performed`, ...),
/// the Z key press it answers, and the editor's paint marker.
struct Phase4bQuRun {
    let label: String
    let opId: String
    /// True when the sequence began `start (quick...` (`start (quick)`, or `start (quick, duplicate)` / `start (quick, restore)` for the quick
    /// redo of a duplicate or a restore). False for both slow roads: the old body's plain `start`, and, since t-18b7fa48 slice 3, the queued
    /// slow undo and redo's `start (editor-first undo)` / `start (editor-first redo)`.
    let quick: Bool
    let startT: Int
    /// The Z key press this run answers: the log's stamp and the app's clock reading.
    var keyDate: Date?
    var keyT: Int?
    /// The app's clock reading (`t=`) of the first line of each known step.
    var stepT: [String: Int] = [:]
    var refusal: String?
    var paintedDate: Date?
    var paintedPath: String?

    var performedT: Int? { stepT["performed"] }
    /// Cmd-Z to the editor's own paint marker, stamp to stamp.
    var keyToPaintedMs: Int? {
        guard let keyDate, let paintedDate else { return nil }
        return Int((paintedDate.timeIntervalSince(keyDate) * 1000).rounded())
    }
    /// Cmd-Z to the Swift sequence's `performed` line, on the app's own clock.
    var keyToPerformedMs: Int? {
        guard let keyT, let performedT else { return nil }
        return performedT - keyT
    }
    /// Cmd-Z to the quick undo's `quick restore done` line, on the app's own clock: the gap in which a key typed straight after the Cmd-Z
    /// would refuse the undo (plan R-7). Nil on the slow path.
    var keyToRestoreDoneMs: Int? {
        guard let keyT, let restoreT = stepT["quick restore done"] else { return nil }
        return restoreT - keyT
    }
}

enum Phase4bQuLog {
    /// The steps of the quick sequences, longest names first so a step with arguments is recorded under its name.
    static let knownSteps = ["quick restore done", "reinsert reserved", "resumed", "performed", "quick removal done", "delete job reserved"]

    /// The undo and redo runs in `lines`, in order, each with its key press and paint marker. Lines of the `reinsert` label are not runs.
    static func runs(in lines: ArraySlice<Phase4bLogLine>) -> [Phase4bQuRun] {
        var runs: [Phase4bQuRun] = []
        var keys: [(date: Date?, t: Int)] = []
        for line in lines {
            let text = line.text
            if let key = Phase4bDelTypingParser.key(text), key.code == Phase4bDelTypingParser.zKeyCode {
                keys.append((line.date, key.t))
            } else if let trace = Phase4bDelTraceLine(line), trace.family == .sequence, trace.label == "undo" || trace.label == "redo" {
                absorb(trace, into: &runs, keys: &keys)
            } else if text.contains("restore painted op="), let opId = Phase4bDelTypingParser.word(after: "op=", in: text),
                      let index = runs.lastIndex(where: { $0.opId.lowercased() == opId.lowercased() && $0.paintedDate == nil }) {
                runs[index].paintedDate = line.date
                runs[index].paintedPath = Phase4bDelTypingParser.word(after: "path=", in: text)
            }
        }
        return runs
    }

    private static func absorb(_ trace: Phase4bDelTraceLine, into runs: inout [Phase4bQuRun], keys: inout [(date: Date?, t: Int)]) {
        if trace.isOpStart {
            var run = Phase4bQuRun(label: trace.label, opId: trace.opId, quick: trace.step.hasPrefix("start (quick"), startT: trace.t)
            // The newest Z key line at most a minute before the start: the slow path first waits for running rebuilds (seconds on a book).
            if let index = keys.lastIndex(where: { $0.t <= trace.t && trace.t - $0.t <= 60_000 }) {
                run.keyDate = keys[index].date
                run.keyT = keys[index].t
                keys.remove(at: index)
            }
            runs.append(run)
        } else if let index = runs.lastIndex(where: { $0.label == trace.label && $0.opId == trace.opId }) {
            let name = knownSteps.first { trace.step.hasPrefix($0) } ?? trace.step
            if runs[index].stepT[name] == nil { runs[index].stepT[name] = trace.t }
            if trace.step.hasPrefix("refused (quick)") { runs[index].refusal = trace.step }
        }
    }

    /// The median of a list of whole numbers (the upper middle for an even count).
    static func median(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }
}

/// The section a typing test deletes: its title, its rows in the document as loaded, and the row of the seeded Inner01 paragraph.
struct Phase4bQuTarget {
    let title: String
    let range: Range<Int>
    let inner: Int
}

/// One typed key, as the app's key monitor logged it: the app's clock reading and the log's stamp.
struct Phase4bQuKey {
    let t: Int
    let date: Date?
}

// MARK: - The titles and the seed

extension Phase4bDelSize {
    /// The four sections the timing test deletes, one after the other: A is undone by the slow path (forced), B, C and D by the quick path.
    /// Every chapter of a book is built the same way, so the four deletions are the same size.
    var quickTimingTitles: [String] {
        switch self {
        case .article:
            return ["1.3 Prices at the Market", "1.2 The Village Registers", "1.4 Bridges and Boundaries", "1.5 Lanterns After Dark"]
        case .book6:
            return [deleteTitle] + [4, 2, 5].map { "Chapter \($0): The Quiet Archive and Its Ledgers" }
        case .book12:
            return [deleteTitle] + [7, 5, 8].map { "Chapter \($0): The Quiet Archive and Its Ledgers" }
        }
    }
}

/// The test class. See the file header.
final class WriteQueuePhase4bQuickUndoE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// How many versions this test has saved (the screen-equals-database check saves one each time; each needs its own name).
    var versionSaves = 0

    /// A plain one-line paragraph the typing tests seed directly under the heading of "1.2.2 ...": the caret is placed at its end BEFORE the
    /// delete, so the editor's saved copy of the document (the undo's checkpoint) holds that caret, and a Cmd-Z puts it back in the
    /// restored section, where the test types at once.
    static let innerPrefix = "Inner01"
    static var innerLine: String { innerPrefix + " line of the fixture document." }

    /// The environment variables the tests set, so a relaunch can clear them again.
    static let seamKeys = [
        "FF_UI_TESTING_STRUCT_JOB_HOLD_MS", "FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N", "FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS",
        "FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS", "FF_UI_TESTING_REBUILD_PUSH_DELAY_MS", "FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS"
    ]

    /// The seeded document with `innerLine` as its own paragraph directly under the heading of the first "### 1.2.2 ..." (chapter 1's).
    static func withInnerParagraph(_ generated: Phase4bDoc) -> Phase4bDoc {
        var text = generated.markdown
        guard let heading = text.range(of: "\n\n### 1.2.2 "), let lineEnd = text.range(of: "\n\n", range: heading.upperBound..<text.endIndex) else {
            return generated
        }
        text.replaceSubrange(lineEnd, with: "\n\n" + innerLine + "\n\n")
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bQuickUndoE2ETests {
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

    func section(_ title: String) -> Range<Int>? { Phase4bFlow.sectionRange(title, in: pre) }

    /// The heading title of the first "1.2.2 ..." section (the generator's words differ per document, so it is read from the rows).
    func innerSectionTitle() -> String? {
        let title = pre.first { $0.headingLevel == 3 && ($0.headingTitle ?? "").hasPrefix("1.2.2 ") }?.headingTitle
        if title == nil { fail("the seeded document has no \"### 1.2.2 ...\" heading in the block table") }
        return title
    }

    /// The row number (in `pre`) of the seeded Inner01 paragraph.
    func innerRowIndex() -> Int? {
        let index = pre.firstIndex { $0.fragment == Self.innerLine }
        if index == nil { fail("the seeded \"\(Self.innerLine)\" paragraph is not in the block table (the seed did not take)") }
        return index
    }

    func blocksContaining(_ text: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(text))') > 0;") ?? -1
    }

    /// Waits for the app to write `sentence` into the block table. `timeout` is a fixed number of seconds, NEVER `capped(...)` (see
    /// `appWait`): the wait starts only if the test's budget is not already spent.
    func waitForSentenceInDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is looked for in the database"))
        repeat {
            if blocksContaining(sentence) >= 1 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits until the named sections' heading rows are gone / back (the delete's job, or the undo's reinsert, has applied) and the block
    /// table and the app's log have stopped changing. Every wait is a condition.
    @discardableResult
    func settle(gone: [String] = [], back: [String] = []) -> Bool {
        var allDone = true
        for title in gone { allDone = waitForHeadingRows(title, equalTo: 0, timeout: capped(size.operationTimeout)) == 0 && allDone }
        for title in back { allDone = waitForHeadingRows(title, equalTo: 1, timeout: capped(size.operationTimeout)) == 1 && allDone }
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        return allDone
    }

    /// Remembers the exact lines of a difference for the `row-differences-<method>.txt` attachment.
    func recordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// What is wrong with a saved document, against the one before the scenario: the text rows (rows of `typedRows` are expected to read
    /// as given, a row of `removed` is gone), the Notes / Bibliography rows (identical when nothing was removed), the footnote numbering and
    /// the footnote definition texts of the references that remain. Empty: nothing is wrong.
    func documentProblems(
        _ post: [Phase4bFlowRow], what: String, removed: [Range<Int>] = [], typedRows: [Int: String] = [:]
    ) -> [String] {
        var found: [String] = []
        let removedIndexes = Set(removed.flatMap { Array($0) })
        func expectedRow(_ index: Int) -> Phase4bFlowRow {
            guard let text = typedRows[index] else { return pre[index] }
            return Phase4bFlowRow(type: pre[index].type, isNotes: false, isBibliography: false, fragment: text)
        }
        let expectedUser = pre.indices.filter { !removedIndexes.contains($0) && !pre[$0].isManaged }.map { (row: $0, value: expectedRow($0)) }
        let actualUser = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        if removed.isEmpty {
            let expectedManaged = pre.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let actualManaged = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let managedLines = Phase4bFlow.rowDifferences(expected: expectedManaged, actual: actualManaged, exact: true)
            recordDifferences(what, "Notes / Bibliography rows", managedLines)
            found += managedLines.map { "the Notes / Bibliography rows differ from before: \($0)" }
        }
        let walk = Phase4bFlowWalk(rows: post)
        found += walk.problems.map { "footnotes: \($0)" }
        let textLines = Phase4bFlow.differenceLines(
            Phase4bFlow.expectedDefinitionTexts(pre: pre, removed: removedIndexes), walk.definitions.map(\.text))
        recordDifferences(what, "footnote definition texts", textLines)
        found += textLines.map { "the footnote definition texts are not those of the references that remain: \($0)" }
        return found
    }

    /// Reads the block table and adds every problem of `documentProblems` to `soft`, noting the sizes beside the verdict.
    @discardableResult
    func addDocumentChecks(
        _ what: String, removed: [Range<Int>] = [], typedRows: [Int: String] = [:], to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        let post = readRows()
        let walk = Phase4bFlowWalk(rows: post)
        let problems = documentProblems(post, what: what, removed: removed, typedRows: typedRows)
        note("\(what): \(post.count) block rows (\(pre.count) before), footnotes \(walk.summary); \(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// The counts of the document as the database holds it at the start of a test (beside the fixture tag every note carries).
    func noteCounts() {
        let walk = Phase4bFlowWalk(rows: pre)
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        note("COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), \(walk.definitions.count) "
            + "footnote definition(s), \(citations) citation bracket(s) in the rows, \(pre.filter(\.isNotes).count) Notes row(s), "
            + "\(pre.filter(\.isBibliography).count) Bibliography row(s)")
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4bQuickUndoE2ETests {
    func traceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    func performedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step == "performed" }.count
    }

    func quickRuns(from index: Int, label: String? = nil) -> [Phase4bQuRun] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        let all = Phase4bQuLog.runs(in: tail.lines[index...])
        return label.map { name in all.filter { $0.label == name } } ?? all
    }

    func firstLogIndex(from index: Int, where matches: (Phase4bLogLine) -> Bool) -> Int? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return (index..<tail.lines.count).first { matches(tail.lines[$0]) }
    }

    /// A line of the app's log, as one text: the stamp and the line.
    func describeLine(_ index: Int?) -> String {
        guard let index, index < tail.lines.count else { return "never" }
        return "log line \(index) (\(tail.lines[index].stamp))"
    }

    /// The editor's `routing-refused` lines since `index` that are real refusals (`failed=latched` is a press held behind a running undo).
    private func routingRefusals(from index: Int) -> [Phase4bLogLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].filter { $0.text.contains("[STRUCT-TRACE] routing-refused") && !$0.text.contains(" failed=latched ") }
    }

    /// A refusal or failure the app logged since `index`: the editor's real `routing-refused` line or the controller's own.
    func problemLine(from index: Int) -> String? {
        guard index <= tail.lines.count else { return nil }
        if let refusal = routingRefusals(from: index).first { return refusal.text }
        return Phase4bLog(lines: Array(tail.lines[index...])).failureLine(since: "")?.text
    }

    /// Waits for `count` `<label> performed` lines since `index`; false on a logged refusal or failure (noted) or on the timeout (noted).
    @discardableResult
    func waitForPerformed(_ label: String, count: Int = 1, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if performedCount(label, from: index) >= count { return true }
            if let problem = problemLine(from: index) {
                note("PROBLEM while waiting for \(count) \(label) performed line(s): \(problem)")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        note("TIMED OUT after \(Int(timeout)) s waiting for \(count) \(label) performed line(s); saw \(performedCount(label, from: index))")
        return false
    }

    func expectPerformed(_ label: String, count: Int = 1, from index: Int, _ message: String, slow: Bool = false) {
        let timeout = appWait(size.operationTimeout * (slow ? 2 : 1), before: message)
        assertCheck(waitForPerformed(label, count: count, from: index, timeout: timeout), message)
    }

    /// The timeout of a wait on the APP's answer to an action the test has already taken (a `performed` line, a word reaching the database,
    /// a word on screen, a saved version). Never shortened by the budget: `capped` cuts every wait down to its 5 s floor once the test's
    /// wall-clock budget is spent, which made a working app look broken (the caret walk of `testTypeDuringQuickUndoWindow_book12` spent the
    /// whole 35 minutes before the delete was clicked, vmtest strike-2 diagnosis 2026-10-16). Where the budget is already spent when such a
    /// wait starts, the test fails at once, loudly, as a TEST-SETUP failure that cannot be taken for an app failure.
    func appWait(_ seconds: TimeInterval, before step: String) -> TimeInterval {
        let left = size.budgetSeconds - Date().timeIntervalSince(startedAt)
        if left <= 0 {
            fail("TEST-SETUP: BUDGET EXHAUSTED before \(step): the \(Int(size.budgetSeconds)) s budget of \(size.identifier) was spent "
                + "\(Int(-left)) s ago, so the app's answer cannot be waited for fairly (the earlier steps of the test used the time, not the app)")
        }
        return seconds
    }

    /// Waits for the newest run of `label` since `index` to have logged `step`; returns that run.
    func waitForStep(_ label: String, _ step: String, from index: Int, timeout: TimeInterval) -> Phase4bQuRun? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let run = quickRuns(from: index, label: label).last(where: { $0.stepT[step] != nil }) { return run }
            if problemLine(from: index) != nil { return nil }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    /// Waits for the editor's paint marker of the newest `label` run since `index`.
    func waitForPainted(_ label: String, from index: Int, timeout: TimeInterval) -> Phase4bQuRun? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let run = quickRuns(from: index, label: label).last(where: { $0.paintedDate != nil }) { return run }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        return nil
    }

    /// The first log index since `index` whose line holds `needle`, waited for (the line's own category and prefix vary; the needle is a phrase).
    func waitForLogIndex(containing needles: [String], from index: Int, timeout: TimeInterval) -> Int? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let found = firstLogIndex(from: index, where: { line in needles.contains { line.text.contains($0) } }) { return found }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    /// The `[SYNC-DIAG:UpdateNSView] PUSHING` lines since `index`: plain whole-document pushes of the editor's content, which would wipe typing
    /// and its undo history. Must be 0 in every test here.
    func plainPushCount(from index: Int) -> Int {
        tail.poll()
        guard index <= tail.lines.count else { return 0 }
        return tail.lines[index...].filter { $0.text.contains("[SYNC-DIAG:UpdateNSView] PUSHING") }.count
    }

    /// The `[toast] show` lines that say "Undoing" since `index`: the slow path's progress toast. The quick path is instant and shows
    /// nothing (the user-verification list's step 2).
    func undoingToastCount(from index: Int, to end: Int? = nil) -> Int {
        tail.poll()
        let upper = min(end ?? tail.lines.count, tail.lines.count)
        guard index <= upper else { return 0 }
        return tail.lines[index..<upper].filter { $0.text.contains("[toast] show") && $0.text.contains("Undoing") }.count
    }

    /// As `waitForLogIndex`, for a line that must satisfy several conditions at once (an AND of phrases, such as a marker and its op id).
    func waitForLogLine(from index: Int, timeout: TimeInterval, where matches: (Phase4bLogLine) -> Bool) -> Int? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let found = firstLogIndex(from: index, where: matches) { return found }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    /// "undo quick, redo quick": the path each run took, for a message.
    static func describePaths(_ runs: [Phase4bQuRun]) -> String {
        runs.map { "\($0.label) \($0.quick ? "quick" : "slow")" }.joined(separator: ", ")
    }

    /// The undo, redo and reinsert lines since `index`, for a failure message.
    func describeSequence(from index: Int) -> String {
        let lines = traceLines(from: index).filter { $0.family == .sequence && ["undo", "redo", "reinsert", "sectionDelete"].contains($0.label) }
        return lines.suffix(14).map { "\($0.label) op=\($0.opId) \($0.step.prefix(70)) @\($0.t)" }.joined(separator: " | ")
    }

    // MARK: Typed keys

    /// The keys the app logged as typed into the editor (not the Z key) since `index`.
    func typedKeys(from index: Int) -> [Phase4bQuKey] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { line in
            guard let key = Phase4bDelTypingParser.key(line.text), key.code != Phase4bDelTypingParser.zKeyCode, key.inEditor else { return nil }
            return Phase4bQuKey(t: key.t, date: line.date)
        }
    }

    /// Types `text` straight into whatever has the keyboard focus (the editor, where the caret was placed) in one `typeText` call, then waits
    /// (bounded; a condition) until the app's key monitor has logged the keys, and returns them with their times.
    func typeAndRecord(_ text: String) -> [Phase4bQuKey] {
        tail.poll()
        let from = tail.lines.count
        // Typed at once on purpose, right after the app's own `quick restore done` line: the saved document and the app's key lines are
        // what the test checks, not the keystrokes (a verified retype would wait, which is the point of the test).
        // e2e-lint: allow raw-typetext -- see the two lines above; typed at once on purpose.
        app.typeText(text)
        let deadline = Date(timeIntervalSinceNow: 8)
        var keys = typedKeys(from: from)
        while keys.count < text.count, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            keys = typedKeys(from: from)
        }
        note("TYPED \"\(text)\": \(text.count) character(s) sent, \(keys.count) key line(s) logged by the app, at app-clock ms "
            + "\(keys.first.map { String($0.t) } ?? "-")...\(keys.last.map { String($0.t) } ?? "-")")
        return keys
    }

    /// A failure text (nil: all good) unless every key lies between `startT` and `endT` on the app's clock.
    func keysInsideText(_ keys: [Phase4bQuKey], from startT: Int, to endT: Int, what: String) -> String? {
        let before = keys.filter { $0.t < startT }.count
        let after = keys.filter { $0.t > endT }.count
        note("KEYS vs \(what): \(keys.count) typed key(s), \(keys.count - before - after) inside the window (\(startT)...\(endT) ms, "
            + "\(endT - startT) ms long), \(before) before it, \(after) after it")
        guard !keys.isEmpty else { return "\(what): the app logged no typed key at all (the keys did not reach the editor)" }
        guard before == 0, after == 0 else {
            return "\(what): \(before) key(s) before and \(after) after the window (TEST-SETUP failure if the hold was too short for the "
                + "typing, an app failure if the keys were typed inside the window and logged outside it)"
        }
        return nil
    }

    /// As `keysInsideText`, on the log's stamps (for windows whose ends are lines without a clock reading).
    func keysInsideStampsText(_ keys: [Phase4bQuKey], from start: Date?, to end: Date?, what: String) -> String? {
        guard let start, let end else { return "\(what): a window line has no readable stamp" }
        let dates = keys.compactMap(\.date)
        let before = dates.filter { $0 < start }.count
        let after = dates.filter { $0 > end }.count
        note("KEYS vs \(what): \(keys.count) typed key(s), \(dates.count - before - after) inside the window "
            + "(\(Int((end.timeIntervalSince(start) * 1000).rounded())) ms long), \(before) before it, \(after) after it")
        guard !keys.isEmpty else { return "\(what): the app logged no typed key at all (the keys did not reach the editor)" }
        guard before == 0, after == 0 else { return "\(what): \(before) key(s) before and \(after) after the window" }
        return nil
    }
}

// MARK: - Driving the app

extension WriteQueuePhase4bQuickUndoE2ETests {
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

    func pressUndo() { app.typeKey("z", modifierFlags: .command) }
    func pressRedo() { app.typeKey("z", modifierFlags: [.command, .shift]) }

    /// One exact-value leaf of the editor: an exact `==` on the value is about 1.5 s on a book (a `CONTAINS` walk of the whole tree took a
    /// minute), and a heading's value is a number, so only `==` is safe.
    private func exactLeaf(_ value: String) -> XCUIElement {
        // e2e-lint: allow statictext-firstmatch -- scoped to `editor-area` (never the sidebar's mirror) and an exact `==` on the value.
        app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// True once the line `line` shows `word` after it, retried for up to `timeout`: the leaf reads "<line> <word>" as one run, or the
    /// editor exposes the typed part as a leaf of its own, with or without the leading space (" <word>" or "<word>": when the line soft-wraps
    /// at the space, the space drops out of the leaf's value, as the first VM run of the book6 typing test showed). Every shape is an exact
    /// `==` on the value inside the editor area. That the word sits in THIS paragraph is the database comparison's job (the row text with
    /// its space, and the screen-equals-database check): a leaf cannot say which paragraph it belongs to. `timeout` is a fixed number of
    /// seconds, NEVER `capped(...)` (see `appWait`).
    func typedLineOnScreen(_ line: String, word: String, timeout: TimeInterval) -> Bool {
        let whole = exactLeaf("\(line) \(word)")
        let separate = exactLeaf(" " + word)
        let bare = exactLeaf(word)
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(word)\" is looked for on screen"))
        repeat {
            if whole.exists || separate.exists || bare.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

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

    /// Starts the app again on the same project and waits until the editor shows the document (the follower is the same for the whole
    /// test: the app appends to the same `diagnostic.log` across launches; the wait only looks past the index noted here).
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
        note("REOPENED: the editor shows the document; \"editor-ready gate satisfied\" line: \(Self.yesNo(ready))")
        return true
    }

    func reopen() -> Bool { quitWithCommandQ() && relaunch() }

    /// Begins the method, seeds and launches the document with the given seams in the app's environment, and reads the saved document. The
    /// footnote numbers of the document as loaded are checked first: every later comparison assumes they are 1...n. False after a failure.
    func startScenario(
        _ size: Phase4bDelSize, method: String, env: [String: String] = [:], seed: ((Phase4bDoc) -> Phase4bDoc)? = nil
    ) -> Bool {
        begin(method: method, size: size)
        if let seed, let generated = doc {
            let seeded = seed(generated)
            doc = seeded
            note("SEED variant: \(seeded.counts.reportLine)")
        }
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            app.launchEnvironment[key] = value
            note("SEAM \(key)=\(value)")
        }
        guard launchScenario(), requireSectionRows() != nil else { return false }
        pre = readRows()
        tail.poll()
        evidenceLogStart = tail.lines.count
        let walk = Phase4bFlowWalk(rows: pre)
        note("BEFORE: \(pre.count) block rows; footnotes \(walk.summary)")
        guard walk.problems.isEmpty else {
            fail("the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        noteCounts()
        return true
    }

    /// The typing tests' set-up: navigates the editor to the "1.2.2 ..." section (clicking a sidebar card scrolls to it), and puts the caret
    /// at the end of the seeded Inner01 line (the helper confirms it through the status bar's selection count). The section's title and rows.
    func placeCaretInSection() -> Phase4bQuTarget? {
        guard let title = innerSectionTitle(), let range = section(title), let inner = innerRowIndex(),
              let card = bringSidebarCardIntoView(title) else { return nil }
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        guard placeCaretAtAnchorEnd(paragraph: Self.innerPrefix, exactLine: Self.innerLine) else { return nil }
        note("SECTION \"\(title)\": rows \(range.lowerBound)..<\(range.upperBound) of \(pre.count); the caret is at the end of \"\(Self.innerLine)\"")
        return Phase4bQuTarget(title: title, range: range, inner: inner)
    }

    /// Chooses Delete Section on the card of `title` and returns the log index just before the click.
    func deleteSection(_ title: String) -> Int? {
        guard let card = bringSidebarCardIntoView(title) else { return nil }
        return chooseSidebarItem(card, item: "Delete Section")
    }
}

// MARK: - Shared checks (the screen equals the database; an exact match; the figures a person would feel)

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// File > Save Version with `name`, and the wait (a condition) for its snapshot row. Saving a version runs
    /// `flushLiveContentToDatabase`, which writes the LIVE editor text into the block table first.
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

    /// The text of every difference between two row lists (type, flags and raw text compared exactly), recorded for the attachment too.
    func exactRowDifferences(_ what: String, _ label: String, expected: [Phase4bFlowRow], actual: [Phase4bFlowRow]) -> [String] {
        let lines = Phase4bFlow.rowDifferences(
            expected: expected.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: actual.enumerated().map { (row: $0.offset, value: $0.element) }, exact: true)
        recordDifferences(what, label, lines)
        return lines
    }

    /// The house rule "the screen equals the database": `before` is a read of the block table; File > Save Version then writes the live
    /// editor text into the table (`flushLiveContentToDatabase`), and the table is read again. The two reads must be identical, every row,
    /// Notes and Bibliography included (`readRows` reads no ids, so a row the flush re-identified is harmless).
    func addScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout Phase4bFlowSoftChecks) {
        versionSaves += 1
        let name = "Screen check \(versionSaves)"
        let saved = saveVersion(named: name)
        soft.check(saved, "\(what): the version \"\(name)\" was saved (its flush writes the live editor text into the block table)")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let after = readRows()
        let lines = exactRowDifferences(what, "the block table before and after Save Version (screen vs database)", expected: before, actual: after)
        note("\(what): SCREEN vs DATABASE: \(before.count) rows before Save Version, \(after.count) after; \(lines.count) difference line(s)")
        soft.check(lines.isEmpty, "\(what): the live editor text differs from the saved block table: \(lines.joined(separator: " | "))")
    }

    /// An exact match (type, flags, raw text of every row, Notes and Bibliography included) of two reads of the block table.
    func addExactMatchCheck(_ what: String, expected: [Phase4bFlowRow], actual: [Phase4bFlowRow], to soft: inout Phase4bFlowSoftChecks) {
        let lines = exactRowDifferences(what, "exact match against the earlier read", expected: expected, actual: actual)
        soft.check(lines.isEmpty, "\(what): the block table is not exactly the one read earlier: \(lines.joined(separator: " | "))")
    }

    /// For every quick undo in `runs`: the Cmd-Z key to `quick restore done` (a key typed in that gap refuses the undo, plan R-7; book12
    /// above about 100 ms is a STOP-style REPORT for the driver, not a failure), the key to the painted marker (with `flagPainted`, book12
    /// above 250 ms is the standing STOP line) and the key to `performed`.
    func reportQuickFigures(_ runs: [Phase4bQuRun], what: String, flagPainted: Bool = false) {
        for run in runs where run.quick {
            let restore = run.keyToRestoreDoneMs
            let painted = run.keyToPaintedMs
            func text(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }
            result("QUICK UNDO op=\(run.opId) (\(what)): key to `quick restore done` \(text(restore)), "
                + "key to the painted marker \(text(painted)), key to `performed` \(text(run.keyToPerformedMs))")
            if size == .book12, let restore, restore > 100 {
                result("STOP-STYLE REPORT: key to `quick restore done` is \(restore) ms on book12 (above about 100 ms): a person typing straight "
                    + "after Cmd-Z can land in this gap and get the undo refused (plan R-7)")
            }
            if flagPainted, size == .book12, let painted, painted > 250 {
                result("STANDING STOP: key to the painted marker is \(painted) ms on book12 (above the 250 ms acceptance figure)")
            }
        }
    }
}

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// The result lines and the asserted timing checks of the timing test. Asserted on EVERY document: the quick median is under the slow
    /// undo's figure; each quick undo's key to `quick restore done` is at most 150 ms (the part the app controls: the routing and the editor's
    /// restore, 29 to 93 ms in the first VM runs); the quick median is at most 500 ms. NOT asserted, only reported: the 250 ms acceptance
    /// figure and the book12 STANDING STOP. (The old check "quick median under a third of the slow undo" is replaced: it measured how slow
    /// the old path happened to be, not what a user feels; judge ruling, see e2e-map.md.) The figure is key to the editor's paint marker (about
    /// 60 ms on book12 now that the quick undo's sidebar update follows the editor's paint). NOTHING here bounds key to `performed`: that
    /// line waits for the deferred sidebar update and arrives about half a second after the section is already on screen.
    func addTimingChecks(size: Phase4bDelSize, undos: [Phase4bQuRun], to soft: inout Phase4bFlowSoftChecks) {
        let quick = Array(undos.dropFirst())
        let quickFigures = quick.compactMap(\.keyToPaintedMs)
        guard let slow = undos.first?.keyToPaintedMs, let median = Phase4bQuLog.median(quickFigures) else { return }   // missing figures are flagged
        let restoreFigures = quick.map { $0.keyToRestoreDoneMs.map { "\($0)" } ?? "n/a" }
        result("TIMING \(size.identifier): quick median \(median) ms (of \(quickFigures)), slow \(slow) ms, quick/slow = "
            + String(format: "%.2f", Double(median) / Double(max(slow, 1))) + "; key to `quick restore done` per quick undo \(restoreFigures) ms "
            + "(document: \(pre.count) block rows, \(Phase4bFlowWalk(rows: pre).refs.count) footnote references)")
        result("ACCEPTANCE FIGURE 250 ms (reported, not asserted): the quick median is \(median) ms: \(median <= 250 ? "MET" : "NOT MET")"
            + (median > 250 && size == .book12 ? " -- STANDING STOP for the driver (a book12 median above 250 ms)" : ""))
        soft.check(median < slow, "the quick median (\(median) ms) is not under the slow undo (\(slow) ms)")
        soft.check(median <= 500, "the median of the quick undos is \(median) ms, above the generous bound of 500 ms")
        for run in quick {
            guard let restore = run.keyToRestoreDoneMs else { continue }   // a missing key line is flagged by the figures check
            soft.check(restore <= 150, "quick undo op=\(run.opId): key to `quick restore done` is \(restore) ms, above 150 ms (the app's own part)")
        }
    }

    /// POSITIVE CONTROL for the "no Undoing toast" checks: the slow undo shows "Undoing..." once it has run for a second, so a slow undo that
    /// ran longer must have logged a `[toast] show ... Undoing` line; otherwise a zero count for the quick undos could not be told from a
    /// changed log format. The control applies when the key to the painted marker was over 1000 ms AND the undo itself (its `start` to its
    /// `performed` line) ran past 1.2 s, a margin over the toast's one-second delay (an undo of 1.0 to 1.2 s may end before its toast shows).
    func addUndoingToastControl(
        slowRun: Phase4bQuRun?, slowFigure: Int?, pressed slowPress: Int, quickFrom firstQuickPress: Int, to soft: inout Phase4bFlowSoftChecks
    ) {
        guard let slowRun, let slowFigure, slowFigure > 1000, let performedT = slowRun.performedT else {
            note("CONTROL for the \"Undoing\" toast: not applicable, the forced slow undo took \(slowFigure.map { "\($0) ms" } ?? "n/a") "
                + "key to painted (not over 1000 ms)")
            return
        }
        let ran = performedT - slowRun.startT
        let slowToasts = undoingToastCount(from: slowPress, to: firstQuickPress)
        note("CONTROL for the \"Undoing\" toast: the forced slow undo ran \(ran) ms (key to painted \(slowFigure) ms); "
            + "\"Undoing\" toast lines: \(slowToasts)")
        guard ran > 1200 else { return }
        soft.check(slowToasts >= 1, "CONTROL: the forced slow undo ran \(ran) ms (key to painted \(slowFigure) ms) but the log has no "
            + "`[toast] show` \"Undoing\" line, so a zero count for the quick undos proves nothing")
    }
}

// MARK: - 1. How fast is the quick undo, against the slow one, in one session

extension WriteQueuePhase4bQuickUndoE2ETests {
    func testQuickUndoTiming_article() { runQuickUndoTiming(.article, method: #function) }
    func testQuickUndoTiming_book6() { runQuickUndoTiming(.book6, method: #function) }
    func testQuickUndoTiming_book12() { runQuickUndoTiming(.book12, method: #function) }

    /// Delete A, undo A (forced SLOW by `FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N=1`), delete B, undo B, delete C, undo C, delete D, undo D (the
    /// last three QUICK: a slow undo makes every earlier-recorded delete ineligible, so the quick ones come after it). Each delete is settled
    /// before its undo, each undo before the next delete. From the app's log: which path each undo took (asserted first), key press to the
    /// editor's paint marker and to `quick restore done` for each, the median of the three quick ones against the slow one (`addTimingChecks`).
    func runQuickUndoTiming(_ size: Phase4bDelSize, method: String) {
        guard startScenario(size, method: method, env: ["FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N": "1"]) else { return }
        let titles = size.quickTimingTitles
        guard titles.allSatisfy({ section($0) != nil }) else { fail("a section of \(titles) is not in the block table"); return }
        tail.poll()
        let sessionFrom = tail.lines.count
        var firstQuickPress = sessionFrom
        var slowPress = sessionFrom
        for (number, title) in titles.enumerated() {
            guard let deleteFrom = deleteSection(title) else { return }
            expectPerformed("sectionDelete", from: deleteFrom, "delete \(number + 1) (\"\(title)\") reached its performed line")
            assertCheck(settle(gone: [title]), "delete \(number + 1): the heading row \"\(title)\" is gone from the block table")
            app.activateAndWaitForForeground()
            tail.poll()
            let pressFrom = tail.lines.count
            if number == 0 { slowPress = pressFrom }
            if number == 1 { firstQuickPress = pressFrom }
            pressUndo()
            expectPerformed("undo", from: pressFrom, "undo \(number + 1) of \"\(title)\" reached its performed line", slow: number == 0)
            guard waitForPainted("undo", from: pressFrom, timeout: capped(size.operationTimeout)) != nil else {
                fail("undo \(number + 1): no `restore painted` line followed the press (the editor posts it only while the typing trace is on); "
                    + describeSequence(from: pressFrom))
                return
            }
            assertCheck(settle(back: [title]), "undo \(number + 1): the heading row \"\(title)\" is back in the block table")
        }
        let undos = quickRuns(from: sessionFrom, label: "undo")
        let paths = undos.map { $0.quick ? "quick" : "slow" }
        note("PATHS of the \(undos.count) undo(s), from the log's `start` lines: \(paths)")
        var soft = Phase4bFlowSoftChecks()
        soft.check(undos.count == titles.count, "the app logged \(undos.count) undo run(s) for \(titles.count) deletes")
        soft.check(undos.first.map { !$0.quick } == true && undos.dropFirst().allSatisfy(\.quick),
                   "the paths are slow, quick, quick, quick (verdict M24: the forced slow undo first); the log says \(paths)")
        let slow = undos.first?.keyToPaintedMs
        let quickFigures = undos.dropFirst().compactMap(\.keyToPaintedMs)
        soft.check(slow != nil && quickFigures.count == titles.count - 1,
                   "every undo has a Cmd-Z key line and a paint marker (slow \(slow.map(String.init) ?? "none"), quick \(quickFigures))")
        let performedFigures = undos.dropFirst().compactMap(\.keyToPerformedMs)
        note("FIGURES key press to the editor's paint marker: slow undo (\"\(titles[0])\", \(undos.first?.paintedPath ?? "?")) "
            + "\(slow.map { "\($0) ms" } ?? "n/a"); quick undos (\(titles.dropFirst().joined(separator: "; "))) \(quickFigures) ms; "
            + "key press to the Swift `performed` line, quick: \(performedFigures) ms")
        addTimingChecks(size: size, undos: undos, to: &soft)
        soft.check(plainPushCount(from: firstQuickPress) == 0,
                   "\(plainPushCount(from: firstQuickPress)) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) from the first quick Cmd-Z to the end")
        soft.check(undoingToastCount(from: firstQuickPress) == 0, "an \"Undoing...\" toast was shown by a quick undo")
        reportQuickFigures(undos, what: "timing, \(size.identifier)")
        addUndoingToastControl(slowRun: undos.first, slowFigure: slow, pressed: slowPress, quickFrom: firstQuickPress, to: &soft)
        addDocumentChecks("after four deletes and four undos", to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "quick-undo-timing-\(size.identifier)")
        assertSoft(soft, "quick undo timing on \(size.identifier)")
    }
}

// MARK: - 2. Typing during the quick undo (the paused window)

extension WriteQueuePhase4bQuickUndoE2ETests {
    func testTypeDuringQuickUndoWindow_book6() { runTypeDuringQuickUndo(.book6, method: #function) }
    func testTypeDuringQuickUndoWindow_book12() { runTypeDuringQuickUndo(.book12, method: #function) }

    /// How long the quick undo is held between the editor's restore and the start of its reinsert (`FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS`;
    /// a plain suspension, nothing is blocked; the editor's own latch times out at 30 s, so it stays well under that).
    static func resumeHoldMs(for size: Phase4bDelSize) -> Int { size == .book12 ? 8_000 : 5_000 }

    /// PROOF THAT THE HELD WINDOW HOLDS ONLY THE PAUSED EDITOR (the hold sits before the reinsert starts, so the reinsert and the Notes /
    /// bibliography rebuild it triggers cannot land inside it; with the hold after the reservation the first VM runs saw
    /// `quick-resume ... pausedUpdates=0`: the rebuild's push ended the pause early and normal sync saved the typing). Two soft checks, both
    /// printed as RESULT lines: (i) the editor's own `quick-resume opId=<id8> ok=true pausedUpdates=N` line shows N >= 1 (the typing in the
    /// window was detected at the resume); (ii) no push reached the editor in the window: no editor-side `[API:setContentWithBlockIds] entry`
    /// line lies in the log between the undo's `quick restore done` and `resumed` lines. (The Swift-side entry lines and the
    /// `push skipped (stale` lines of the delete's in-flight Notes rebuild are counted and printed, not asserted: the stale-rebuild guard
    /// stops that push before it reaches the editor. The first version of this check counted them and failed on its first run.)
    func addPausedWindowProof(run: Phase4bQuRun, from index: Int, to soft: inout Phase4bFlowSoftChecks) {
        let opId = run.opId.lowercased()
        let resumeAt = waitForLogLine(from: index, timeout: appWait(30, before: "the editor's quick-resume line is looked for")) { line in
            line.text.contains("quick-resume opId=") && line.text.lowercased().contains("opid=\(opId)")
        }
        let paused = resumeAt.flatMap { Phase4bDelTypingParser.intAfter("pausedUpdates=", in: tail.lines[$0].text) }
        let resumeText = resumeAt.map { String(tail.lines[$0].text.suffix(100)) } ?? "none"
        let pausedText = paused.map(String.init) ?? "n/a"
        result("PAUSED WINDOW (i): the editor's resume line for op \(run.opId): \(resumeText); pausedUpdates \(pausedText)")
        soft.check((paused ?? 0) >= 1, "the editor's quick-resume line for op \(run.opId) shows pausedUpdates=\(pausedText), not 1 or more: "
            + "the typing in the held window was not detected at the resume (the pause ended early, or the keys never reached the paused editor)")
        func stepIndex(_ step: String) -> Int? {
            firstLogIndex(from: index) { line in
                guard let trace = Phase4bDelTraceLine(line) else { return false }
                return trace.family == .sequence && trace.label == "undo" && trace.opId == run.opId && trace.step.hasPrefix(step)
            }
        }
        guard let restoreAt = stepIndex("quick restore done"), let resumedAt = stepIndex("resumed"), restoreAt < resumedAt else {
            let restoreLine = describeLine(stepIndex("quick restore done"))
            soft.check(false, "the log has no `quick restore done` ... `resumed` pair for op \(run.opId) (restore at \(restoreLine), "
                + "resumed at \(describeLine(stepIndex("resumed"))))")
            return
        }
        // Only a push that REACHED THE EDITOR counts: the editor's own `[API:setContentWithBlockIds] entry` line. The delete's in-flight Notes
        // rebuild legitimately writes Swift's `[SYNC-DIAG:BlockSync] setContentWithBlockIds:` entry line inside the window, and the stale-rebuild
        // guard then skips it (`push skipped (stale: a quick undo or redo started since the read)`): designed behaviour, printed as evidence only.
        let window = (restoreAt + 1)..<resumedAt
        let swiftEntries = window.filter { tail.lines[$0].text.contains("[SYNC-DIAG:BlockSync] setContentWithBlockIds:") }
        let skipped = window.filter { tail.lines[$0].text.contains("push skipped (stale") }
        let reachedEditor = window.filter { tail.lines[$0].text.contains("[API:setContentWithBlockIds] entry") }
        result("PAUSED WINDOW (ii): between `quick restore done` (log line \(restoreAt)) and `resumed` (log line \(resumedAt)): "
            + "\(swiftEntries.count) Swift-side `setContentWithBlockIds` entry line(s), \(skipped.count) `push skipped (stale` line(s) "
            + "(the stale-rebuild guard working), \(reachedEditor.count) push(es) that reached the editor (`[API:setContentWithBlockIds] entry`)"
            + (reachedEditor.first.map { "; first: \(describeLine($0)) \(tail.lines[$0].text.suffix(90))" } ?? ""))
        soft.check(reachedEditor.isEmpty, "\(reachedEditor.count) `[API:setContentWithBlockIds] entry` line(s) fell inside the held window of op "
            + "\(run.opId) (first: \(describeLine(reachedEditor.first))): a rebuild push reached the editor in the window and ended its pause early")
    }

    /// The caret is at the end of the Inner01 line of "1.2.2 ..." (a section with a footnote and citations); the section is deleted and
    /// Cmd-Z is pressed at once; as soon as the app's own `quick restore done` line shows, " KEPTQUIN" is typed at the restored caret, inside
    /// the resume hold. Every key must fall between `quick restore done` and `resumed`. After the undo has settled, " KEPTQUOUT" is typed
    /// at the end of the Anchor05 line (chapter 1's first lines; the caret is moved there with a click, which takes longer than any hold, so
    /// these keys come AFTER `resumed` and are only checked for being saved). The block table then holds the whole document as it was, the
    /// two words, no renumbering damage; and the app logged no plain whole-document push.
    func runTypeDuringQuickUndo(_ size: Phase4bDelSize, method: String) {
        let hold = Self.resumeHoldMs(for: size)
        guard startScenario(size, method: method, env: ["FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS": String(hold)], seed: Self.withInnerParagraph),
              let target = placeCaretInSection() else { return }
        let wordIn = "KEPTQUIN"
        let wordOut = "KEPTQUOUT"
        guard let deleteFrom = deleteSection(target.title) else { return }
        pressUndo()
        guard let restored = waitForStep("undo", "quick restore done", from: deleteFrom, timeout: capped(size.operationTimeout)),
              let restoredT = restored.stepT["quick restore done"] else {
            fail("no `quick restore done` line after the Cmd-Z: \(describeSequence(from: deleteFrom))")
            return
        }
        let keysIn = typeAndRecord(" " + wordIn)
        expectPerformed("undo", from: deleteFrom, "the undo reached its performed line after the hold")
        guard let run = quickRuns(from: deleteFrom, label: "undo").last, let resumedT = run.stepT["resumed"] else {
            fail("the undo has no `resumed` line: \(describeSequence(from: deleteFrom))")
            return
        }
        var soft = Phase4bFlowSoftChecks()
        soft.check(run.quick, "the Cmd-Z took the quick path (the log says `start\(run.quick ? " (quick)" : "")`)")
        if let problem = keysInsideText(keysIn, from: restoredT, to: resumedT, what: "typed during the quick undo's paused window") {
            soft.check(false, problem)
        }
        note("WINDOW: `quick restore done` at \(restoredT), `reinsert reserved` at \(run.stepT["reinsert reserved"].map(String.init) ?? "-"), "
            + "`resumed` at \(resumedT) (the hold was \(hold) ms), `performed` at \(run.performedT.map(String.init) ?? "-")")
        // PROOF THE SEAM TOOK: the app's own marker for the hold (diagnostic.log), with this undo's op id.
        let holdStart = firstLogIndex(from: deleteFrom) { $0.text.contains("[QuickUndoHold] start ms=") && $0.text.contains("op=\(run.opId)") }
        soft.check(holdStart != nil, "the resume hold took: no `[QuickUndoHold] start ms=\(hold) op=\(run.opId)` line in the app log")
        note("HOLD MARKER: \(holdStart.map { String(tail.lines[$0].text.suffix(60)) } ?? "none")")
        addPausedWindowProof(run: run, from: deleteFrom, to: &soft)
        // The Cmd-Z pressed straight after the delete: the figures a person would feel (key to restored gap, key to painted).
        soft.check(waitForPainted("undo", from: deleteFrom, timeout: capped(60)) != nil, "the editor's `restore painted` marker followed the Cmd-Z")
        reportQuickFigures(
            quickRuns(from: deleteFrom, label: "undo"), what: "typing test \(size.identifier), Cmd-Z straight after the delete", flagPainted: true)
        soft.check(waitForCard(target.title, present: true, timeout: capped(60)), "the section's sidebar card \"\(target.title)\" is back")
        soft.check(settle(back: [target.title]), "the heading row \"\(target.title)\" is back in the block table")
        soft.check(waitForSentenceInDatabase(wordIn, timeout: 90), "\"\(wordIn)\", typed during the paused window, reached the database")
        soft.check(typedLineOnScreen(Self.innerLine, word: wordIn, timeout: 90),
                   "the restored section's first line reads \"\(Self.innerLine) \(wordIn)\" on screen")
        // The second word, in another place, after the window.
        app.typeKey(.upArrow, modifierFlags: .command)
        clickBackIntoAnchor()
        let keysOut = typeAndRecord(" " + wordOut)
        soft.check(keysOut.allSatisfy { $0.t > resumedT },
                   "\"\(wordOut)\" was typed after `resumed` (as designed: the click back takes longer than the hold)")
        soft.check(waitForSentenceInDatabase(wordOut, timeout: 90), "\"\(wordOut)\", typed after the undo, reached the database")
        _ = settle()
        let anchorRow = pre.firstIndex { $0.fragment == Self.anchorLine }
        var typed = [target.inner: "\(Self.innerLine) \(wordIn)"]
        if let anchorRow { typed[anchorRow] = "\(Self.anchorLine) \(wordOut)" }
        soft.check(anchorRow != nil, "the Anchor05 row is in the block table")
        soft.check(plainPushCount(from: deleteFrom) == 0,
                   "\(plainPushCount(from: deleteFrom)) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) from the delete to the end (must be 0)")
        soft.check(undoingToastCount(from: deleteFrom) == 0, "an \"Undoing...\" toast was shown by the quick undo")
        let post = addDocumentChecks("after delete, Cmd-Z, typing in the paused window and after it", typedRows: typed, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after delete, Cmd-Z and typing", to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "type-during-quick-undo-\(size.identifier)")
        assertSoft(soft, "typing during the quick undo on \(size.identifier)")
    }

    /// The text of the Anchor05 line the typing tests put their second word after.
    static var anchorLine: String { Phase4bDelHarness.anchorPrefix + " line of the fixture document." }
}

// MARK: - 3. Typing while the delete's job is held (a 3.5 s job hold: the undo must not wait for the job)

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// The extra case of verdict-v1 M27, and the proof that the undo no longer waits for the delete's saving job (the task's own bug): the
    /// delete's job is held 3.5 s (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS`, which blocks the writer: under
    /// the 4 s limit and nothing but this test's own typing is pending). Delete, Cmd-Z at once, type at the restored caret once the app's
    /// `quick restore done` line shows; the reinsert queues behind the held job. Every key must come before the reinsert's own body line (the
    /// writer was still held), and the word is in the database and the section back once the job and the reinsert have run.
    func testTypeWhileDeleteJobHeld_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, env: ["FF_UI_TESTING_STRUCT_JOB_HOLD_MS": "3500"], seed: Self.withInnerParagraph),
              let target = placeCaretInSection() else { return }
        let word = "KEPTJH"
        guard let deleteFrom = deleteSection(target.title) else { return }
        pressUndo()
        guard waitForStep("undo", "quick restore done", from: deleteFrom, timeout: capped(size.operationTimeout)) != nil else {
            fail("no `quick restore done` line after the Cmd-Z: \(describeSequence(from: deleteFrom))")
            return
        }
        let keys = typeAndRecord(" " + word)
        expectPerformed("undo", from: deleteFrom, "the undo reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        let reinsertBody = waitForLogIndex(containing: ["[SectionReinsertJob]"], from: deleteFrom, timeout: capped(size.operationTimeout))
        let bodyDate = reinsertBody.flatMap { tail.lines[$0].date }
        let restoreDate = firstLogIndex(from: deleteFrom) { $0.text.contains(" undo op=") && $0.text.contains("quick restore done") }
            .flatMap { tail.lines[$0].date }
        if let problem = keysInsideStampsText(
            keys, from: restoreDate, to: bodyDate, what: "typed while the delete's job (held 3.5 s) was still running") {
            soft.check(false, problem)
        }
        soft.check(quickRuns(from: deleteFrom, label: "undo").last?.quick == true, "the Cmd-Z took the quick path")
        // THE TASK'S OWN BUG: the old undo waited for the delete's saving job. With the job held 3.5 s, the section must be painted back
        // (and the undo performed) BEFORE the held job has finished, i.e. before the reinsert (queued behind it) writes its body line.
        let paintedAt = waitForLogLine(from: deleteFrom, timeout: capped(60)) { $0.text.contains("restore painted op=") }
        let performedAt = firstLogIndex(from: deleteFrom) { line in
            Phase4bDelTraceLine(line).map { $0.family == .sequence && $0.label == "undo" && $0.step == "performed" } ?? false
        }
        let lines = "painted marker \(describeLine(paintedAt)), performed line \(describeLine(performedAt)), "
            + "reinsert body line \(describeLine(reinsertBody))"
        if let paintedAt, let performedAt, let reinsertBody {
            soft.check(paintedAt < reinsertBody && performedAt < reinsertBody,
                       "the section must be painted back and the undo performed BEFORE the held delete job finished, but the undo waited "
                           + "for the job (\(lines))")
        } else {
            soft.check(false, "all three lines are needed to show that the undo did not wait for the job (\(lines))")
        }
        let run = quickRuns(from: deleteFrom, label: "undo").last
        note("AT-ONCE UNDO with the delete's job held 3500 ms: key to the painted marker \(run?.keyToPaintedMs.map { "\($0) ms" } ?? "n/a") "
            + "(must be well under the 3500 ms hold)")
        if let painted = run?.keyToPaintedMs {
            soft.check(painted < 3500, "key to the painted marker is \(painted) ms, not under the 3500 ms job hold")
        }
        reportQuickFigures(quickRuns(from: deleteFrom, label: "undo"), what: "job held, Cmd-Z straight after the delete")
        soft.check(waitForCard(target.title, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [target.title]), "the heading row \"\(target.title)\" is back in the block table")
        soft.check(waitForSentenceInDatabase(word, timeout: 90), "\"\(word)\" reached the database")
        soft.check(plainPushCount(from: deleteFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the delete to the end")
        addDocumentChecks(
            "after delete, Cmd-Z at once, typing while the job was held", typedRows: [target.inner: "\(Self.innerLine) \(word)"], to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "type-while-job-held-book6")
        assertSoft(soft, "typing while the delete's job is held")
    }
}

// MARK: - 4. Typing while the reinsert's settle is held

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// `FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS=6000` suspends the reinsert's settle (the resyncs and the push of the database's Notes and
    /// bibliography into the editor) for 6 s after the reinsert's rows committed; the writer is free. The delete is settled first, Cmd-Z is
    /// pressed, and once the section's heading row is back in the block table (the reinsert has committed: a database condition) a word is
    /// typed at the restored caret. Every key must fall after the reinsert's own body line and before `reinsert op=<id> applied` (the line the
    /// settle writes when the hold is over); the settle's pushes then keep the typing, and no plain whole-document push is logged.
    func testTypeDuringReinsertSettle_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, env: ["FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS": "6000"], seed: Self.withInnerParagraph),
              let target = placeCaretInSection() else { return }
        let word = "KEPTRS"
        guard let deleteFrom = deleteSection(target.title) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [target.title]), "the delete's job has run: the heading row is gone")
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: pressFrom, "the undo reached its performed line")
        assertCheck(waitForHeadingRows(target.title, equalTo: 1, timeout: capped(size.operationTimeout)) == 1,
                    "the reinsert committed: the heading row \"\(target.title)\" is back in the block table")
        let opId = quickRuns(from: pressFrom, label: "undo").last?.opId ?? "--------"
        // The window is the app's own pair of markers (`[ReinsertSettleHold] start ms=<n> op=<id8>` ... `end op=<id8>`, diagnostic.log):
        // typing starts once the start marker shows, and every key must lie before the end marker.
        guard let holdStartAt = waitForLogLine(from: pressFrom, timeout: capped(60), where: { line in
            line.text.contains("[ReinsertSettleHold] start ms=") && line.text.contains("op=\(opId)")
        }) else {
            fail("no `[ReinsertSettleHold] start ms=6000 op=\(opId)` line: the settle hold did not take: \(describeSequence(from: pressFrom))")
            return
        }
        let keys = typeAndRecord(" " + word)
        var soft = Phase4bFlowSoftChecks()
        let holdEndAt = waitForLogLine(from: holdStartAt, timeout: capped(60), where: { line in
            line.text.contains("[ReinsertSettleHold] end") && line.text.contains("op=\(opId)")
        })
        soft.check(holdEndAt != nil, "the log has `[ReinsertSettleHold] end op=\(opId)` after the start marker (\(describeLine(holdStartAt)))")
        _ = waitForPainted("undo", from: pressFrom, timeout: capped(60))
        reportQuickFigures(quickRuns(from: pressFrom, label: "undo"), what: "settle-hold test, Cmd-Z after the delete settled", flagPainted: true)
        if let problem = keysInsideStampsText(
            keys, from: tail.lines[holdStartAt].date, to: holdEndAt.flatMap { tail.lines[$0].date },
            what: "typed while the reinsert's settle was held 6 s (the app's own start and end markers)") {
            soft.check(false, problem)
        }
        let settledAt = waitForLogIndex(containing: ["reinsert op=\(opId) settled"], from: pressFrom, timeout: capped(size.operationTimeout))
        soft.check(settledAt != nil, "the reinsert's settle ended (`reinsert op=\(opId) settled`)")
        soft.check(quickRuns(from: pressFrom, label: "undo").last?.quick == true, "the Cmd-Z took the quick path")
        _ = settle(back: [target.title])
        soft.check(waitForSentenceInDatabase(word, timeout: 90), "\"\(word)\", typed during the settle hold, reached the database")
        soft.check(typedLineOnScreen(Self.innerLine, word: word, timeout: 90),
                   "after the settle's pushes the restored section's first line still reads \"\(Self.innerLine) \(word)\" on screen")
        soft.check(plainPushCount(from: pressFrom) == 0,
                   "\(plainPushCount(from: pressFrom)) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) from the Cmd-Z to the end (must be 0)")
        addDocumentChecks("after delete, settle, Cmd-Z, typing in the settle hold", typedRows: [target.inner: "\(Self.innerLine) \(word)"], to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "type-during-reinsert-settle-book6")
        assertSoft(soft, "typing during the reinsert's settle")
    }
}

// MARK: - 5. Undo, redo, undo after a footnote renumber (verdict S4)

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// "1.2.2 ..." holds footnote 4 of 54, so deleting it renumbers every later footnote. The delete is settled (the renumber absorbed, the
    /// Notes rebuilt), then Cmd-Z, Cmd-Shift-Z, Cmd-Z, each waited for. All three run the quick path; after each the block table holds the
    /// document it must (section back with the original numbers, section gone with footnotes renumbered, section back again): the labels in
    /// the body are 1...n, every label has exactly one Notes definition, and each definition's text is the original's.
    func testQuickUndoRedoUndoAfterRenumber_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function), let title = innerSectionTitle(), let range = section(title) else { return }
        guard let deleteFrom = deleteSection(title) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [title]), "the delete's job has run: the heading row \"\(title)\" is gone")
        let renumberAt = firstLogIndex(from: deleteFrom) { $0.text.contains("[STRUCT-TRACE] registry-advance") }
        assertCheck(renumberAt != nil,
                    "TEST-SETUP: the footnote renumber was absorbed before the first Cmd-Z (a `registry-advance` line follows the delete)")
        var soft = Phase4bFlowSoftChecks()
        let afterDelete = addDocumentChecks("after the delete (renumbered)", removed: [range], to: &soft)
        app.activateAndWaitForForeground()
        tail.poll()
        let undoFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: undoFrom, "the first Cmd-Z reached its performed line")
        soft.check(settle(back: [title]), "after the first Cmd-Z the heading row is back")
        addDocumentChecks("after the first Cmd-Z", to: &soft)
        tail.poll()
        let redoFrom = tail.lines.count
        pressRedo()
        expectPerformed("redo", from: redoFrom, "the Cmd-Shift-Z reached its performed line")
        soft.check(settle(gone: [title]), "after the Cmd-Shift-Z the heading row is gone again")
        let afterRedo = addDocumentChecks("after the redo (renumbered again)", removed: [range], to: &soft)
        // `removed:` turns the Notes / Bibliography comparison off, so the redo is also compared EXACTLY (every row, Notes and Bibliography
        // included) with the table read after the original delete had settled.
        addExactMatchCheck("after the redo", expected: afterDelete, actual: afterRedo, to: &soft)
        tail.poll()
        let lastFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: lastFrom, "the second Cmd-Z reached its performed line")
        soft.check(settle(back: [title]), "after the second Cmd-Z the heading row is back")
        let finalRows = addDocumentChecks("after undo, redo, undo", to: &soft)
        addScreenEqualsDatabaseCheck(before: finalRows, what: "after undo, redo, undo", to: &soft)
        let runs = quickRuns(from: undoFrom)
        note("RUNS: \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")" })")
        soft.check(runs.count == 3 && runs.allSatisfy(\.quick) && runs.map(\.label) == ["undo", "redo", "undo"],
                   "undo, redo, undo all ran the quick path, in that order (the log says \(Self.describePaths(runs)))")
        soft.check(problemLine(from: undoFrom) == nil, "nothing was refused or failed (\(problemLine(from: undoFrom) ?? "none"))")
        soft.check(plainPushCount(from: undoFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the first Cmd-Z to the end")
        soft.check(undoingToastCount(from: undoFrom) == 0, "an \"Undoing...\" toast was shown by a quick undo or redo")
        attachEvidenceScreenshot(app.screenshot(), name: "undo-redo-undo-after-renumber-book6")
        assertSoft(soft, "undo, redo, undo after a renumber")
    }
}

// MARK: - 6. Redo pressed straight after the undo (verdict S5)

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// Cmd-Z and Cmd-Shift-Z one right after the other, with no pause: the redo is held in the editor until the undo has answered, then runs
    /// the quick path (`redo op=<id> start (quick)` ... `performed`), never a fallback or a refusal. The section ends gone, on screen and in the
    /// block table, with the footnotes renumbered and the Notes clean.
    func testRedoStraightAfterQuickUndo_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function), let range = section(size.deleteTitle) else { return }
        guard let deleteFrom = deleteSection(size.deleteTitle) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [size.deleteTitle]), "the delete's job has run")
        let afterDelete = readRows()
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        pressRedo()
        expectPerformed("undo", from: pressFrom, "the Cmd-Z reached its performed line")
        expectPerformed("redo", from: pressFrom, "the Cmd-Shift-Z, pressed at once, reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        let runs = quickRuns(from: pressFrom)
        note("RUNS: \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")\($0.refusal.map { " (\($0))" } ?? "")" })")
        soft.check(runs.map(\.label) == ["undo", "redo"] && runs.allSatisfy(\.quick),
                   "the undo and then the redo both ran the quick path (the log says \(Self.describePaths(runs)))")
        let fallbacks = traceLines(from: pressFrom).filter { $0.step.contains("fallback") || $0.step.hasPrefix("refused") }
        soft.check(fallbacks.isEmpty, "no undo or redo fell back or was refused (\(fallbacks.map(\.step)))")
        soft.check(problemLine(from: pressFrom) == nil, "nothing was refused or failed (\(problemLine(from: pressFrom) ?? "none"))")
        soft.check(waitForCard(size.deleteTitle, present: false, timeout: capped(60)), "the section is off the screen (its sidebar card is gone)")
        soft.check(settle(gone: [size.deleteTitle]), "the heading row is gone from the block table")
        soft.check(plainPushCount(from: pressFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the Cmd-Z to the end")
        soft.check(undoingToastCount(from: pressFrom) == 0, "an \"Undoing...\" toast was shown by the quick undo or redo")
        let afterRedo = addDocumentChecks("after Cmd-Z and Cmd-Shift-Z at once", removed: [range], to: &soft)
        // `removed:` turns the Notes / Bibliography comparison off: compare EXACTLY with the table read after the original delete settled.
        addExactMatchCheck("after Cmd-Z and Cmd-Shift-Z at once", expected: afterDelete, actual: afterRedo, to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "redo-straight-after-undo-book6")
        assertSoft(soft, "redo straight after the quick undo")
    }
}

// MARK: - 7. Two deletes, two undos

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// Two adjacent sections are deleted (chapter 3's last section and chapter 4) and Cmd-Z is pressed twice with real keys, the second while
    /// the first runs (the editor holds it). Both undos run the quick path; the second delete comes back first, then the first, each in
    /// its place; the document is the one before.
    func testTwoDeletesTwoQuickUndos_book6() {
        let size = Phase4bDelSize.book6
        let first = Phase4bDelSize.pairFirst
        let second = Phase4bDelSize.pairSecond
        guard startScenario(size, method: #function), section(first) != nil, section(second) != nil,
              let firstCard = bringSidebarCardIntoView(first) else { return }
        let secondCard = sidebarCard(second)
        assertCheck(secondCard.exists, "the second section's card is on screen beside the first")
        let from = chooseSidebarItem(firstCard, item: "Delete Section")
        chooseSidebarItem(secondCard, item: "Delete Section", activate: false)
        expectPerformed("sectionDelete", count: 2, from: from, "both deletes reached their performed line")
        assertCheck(settle(gone: [first, second]), "both sections are gone from the block table")
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        pressUndo()
        expectPerformed("undo", count: 2, from: pressFrom, "both real Cmd-Z key presses reached their performed line")
        var soft = Phase4bFlowSoftChecks()
        let runs = quickRuns(from: pressFrom, label: "undo")
        soft.check(runs.count == 2 && runs.allSatisfy(\.quick), "both undos ran the quick path (the log says \(Self.describePaths(runs)))")
        // J5: the SECOND section comes back first. The app's own op ids decide: the first Cmd-Z must undo the second delete.
        let deleteOps = traceLines(from: from).filter { $0.family == .sequence && $0.label == "sectionDelete" && $0.isOpStart }.map(\.opId)
        note("OP IDS: deletes in the order pressed \(deleteOps); undos in the order they ran \(runs.map(\.opId))")
        soft.check(deleteOps.count == 2 && runs.count == 2 && runs[0].opId == deleteOps[1] && runs[1].opId == deleteOps[0],
                   "the first Cmd-Z undid the SECOND delete and the second Cmd-Z the first (deletes \(deleteOps), undos \(runs.map(\.opId)))")
        soft.check(problemLine(from: pressFrom) == nil, "nothing was refused or failed (\(problemLine(from: pressFrom) ?? "none"))")
        soft.check(waitForCard(first, present: true, timeout: capped(60)) && waitForCard(second, present: true, timeout: capped(60)),
                   "both sections are back in the sidebar")
        soft.check(settle(back: [first, second]), "both sections are back in the block table")
        soft.check(undoingToastCount(from: pressFrom) == 0, "an \"Undoing...\" toast was shown by a quick undo")
        let rows = addDocumentChecks("after two deletes and two Cmd-Z", to: &soft)
        let order = rows.compactMap(\.headingTitle).filter { $0 == first || $0 == second }
        soft.check(order == [first, second], "the two sections are back in the order they had: \(order)")
        soft.check(plainPushCount(from: pressFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the first Cmd-Z to the end")
        addScreenEqualsDatabaseCheck(before: rows, what: "after two deletes and two Cmd-Z", to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "two-deletes-two-quick-undos-book6")
        assertSoft(soft, "two deletes, two quick undos")
    }
}

// MARK: - 8. Delete, wait, undo

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// A chapter of the twelve-chapter book is deleted, the test waits until the delete has settled (its job, the footnote renumber and the
    /// Notes and bibliography rebuilds are done and the log is quiet), then Cmd-Z: the quick path, the section back with its footnote numbers
    /// and bibliography entries; and a reopen holds the same document (the block table equals the one before the delete, Notes and
    /// Bibliography rows included).
    func testDeleteWaitThenQuickUndo_book12() {
        let size = Phase4bDelSize.book12
        guard startScenario(size, method: #function), section(size.deleteTitle) != nil else { return }
        guard let deleteFrom = deleteSection(size.deleteTitle) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [size.deleteTitle]), "the delete has settled: the heading row is gone and the log is quiet")
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: pressFrom, "the Cmd-Z reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        soft.check(quickRuns(from: pressFrom, label: "undo").last?.quick == true, "the Cmd-Z took the quick path")
        soft.check(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [size.deleteTitle]), "the heading row is back in the block table")
        soft.check(plainPushCount(from: pressFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the Cmd-Z to the end")
        soft.check(undoingToastCount(from: pressFrom) == 0, "an \"Undoing...\" toast was shown by the quick undo")
        addDocumentChecks("after delete, wait, Cmd-Z", to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "delete-wait-quick-undo-book12")
        assertSoft(soft, "delete, wait, quick undo")
        guard reopen() else { return }
        var reopened = Phase4bFlowSoftChecks()
        reopened.check(sidebarCard(size.deleteTitle).exists, "after the reopen the section is in the sidebar")
        addDocumentChecks("after the reopen", to: &reopened)
        assertSoft(reopened, "the reopened project")
    }
}

// MARK: - 9. Quick undo, typing, quit, reopen

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// Delete, Cmd-Z at once, type a word at the restored caret as soon as the restore shows. BEFORE quitting the block table is read: the
    /// restored section's rows and the word are in the DATABASE already (the quit's whole-document save would mask a loss). Then Cmd-Q and
    /// a reopen: the same document, the word in the editor.
    func testQuickUndoThenQuitAndReopen_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, seed: Self.withInnerParagraph), let target = placeCaretInSection() else { return }
        let word = "KEPTQR"
        guard let deleteFrom = deleteSection(target.title) else { return }
        pressUndo()
        guard waitForStep("undo", "quick restore done", from: deleteFrom, timeout: capped(size.operationTimeout)) != nil else {
            fail("no `quick restore done` line after the Cmd-Z: \(describeSequence(from: deleteFrom))")
            return
        }
        _ = typeAndRecord(" " + word)
        expectPerformed("undo", from: deleteFrom, "the undo reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        soft.check(quickRuns(from: deleteFrom, label: "undo").last?.quick == true, "the Cmd-Z took the quick path")
        soft.check(waitForPainted("undo", from: deleteFrom, timeout: capped(60)) != nil, "the editor's `restore painted` marker followed the Cmd-Z")
        reportQuickFigures(quickRuns(from: deleteFrom, label: "undo"), what: "quit test, Cmd-Z straight after the delete", flagPainted: true)
        soft.check(waitForCard(target.title, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [target.title]), "the heading row is back in the block table")
        soft.check(waitForSentenceInDatabase(word, timeout: 90), "\"\(word)\" is in the DATABASE before the quit")
        let typed = [target.inner: "\(Self.innerLine) \(word)"]
        addDocumentChecks("before the quit", typedRows: typed, to: &soft)
        soft.check(plainPushCount(from: deleteFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the delete to the quit")
        attachEvidenceScreenshot(app.screenshot(), name: "quick-undo-before-quit-book6")
        assertSoft(soft, "quick undo, typing, before the quit")
        guard reopen() else { return }
        var reopened = Phase4bFlowSoftChecks()
        reopened.check(sidebarCard(target.title).exists || waitForCard(target.title, present: true, timeout: capped(60)),
                       "after the reopen the section is in the sidebar")
        addDocumentChecks("after the reopen", typedRows: typed, to: &reopened)
        // After a reopen the editor starts at the top; chapter 1's "1.2.2 ..." is below the viewport, where the accessibility tree may not list
        // its text at all. Clicking the section's sidebar card scrolls the editor to it (the UX contract: clicking navigates).
        if let card = bringSidebarCardIntoView(target.title) {
            app.activateAndWaitForForeground()
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        reopened.check(typedLineOnScreen(Self.innerLine, word: word, timeout: 180),
                       "after the reopen the restored section's first line reads \"\(Self.innerLine) \(word)\" on screen")
        attachEvidenceScreenshot(app.screenshot(), name: "quick-undo-after-reopen-book6")
        assertSoft(reopened, "the reopened project")
    }
}

// MARK: - 10. A flush (idle backup, Save Version) before the Cmd-Z

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// The idle backup, Save Version and export write the post-delete screen into the table outside the queue and push fresh block ids; they
    /// must not send the next Cmd-Z down the slow path (verdict-v2 A1, v3 T1/T2): the user's step 6, a flush after a QUIET stretch. The seam
    /// `FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS=45` stays dormant until the first editor-first delete of the launch (the load cannot use it
    /// up), then makes the next idle timer fire 45 s after the delete's LAST content change, once. 45 s and not 10: `settle(gone:)` can take
    /// up to about 40 s when the app's log never goes quiet (its quiet-log wait is capped at 30 s), and the backup must come after it, in
    /// the quiet. The test then waits for the backup's own log line (`[AutoBackupService] Created auto-backup on idle timeout` or `Skipped
    /// auto-backup on idle timeout`), and Cmd-Z: the log shows `start (quick)`; the block table equals the one before the delete (the
    /// reinsert set every row, the re-identified ones included).
    ///
    /// TEST-SETUP failures (never a silent pass without a flush): a skip line instead of a backup (`Too soon since last backup, skipping on
    /// idle timeout`, `No unsaved changes, skipping backup on idle timeout`), a backup that fired before `settle(gone:)` returned, or a
    /// rebuild push that landed after it and before the backup. `testQuickUndoAfterSaveVersion_book6` covers the same flush path without a timer.
    func testQuickUndoAfterIdleBackup_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, env: ["FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS": "45"]) else { return }
        let backupMarkers = [
            "Created auto-backup on idle timeout", "Skipped auto-backup on idle timeout",
            "Too soon since last backup, skipping on idle timeout", "No unsaved changes, skipping backup on idle timeout"
        ]
        guard let deleteFrom = deleteSection(size.deleteTitle) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [size.deleteTitle]), "the delete has settled")
        tail.poll()
        let settledAt = tail.lines.count
        guard let backupAt = waitForLogIndex(containing: backupMarkers, from: deleteFrom, timeout: capped(180)) else {
            fail("TEST-SETUP: no idle backup line followed the delete within 180 s: the seam did not fire "
                + "(is `FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS` armed by the delete's click?)")
            return
        }
        let backupText = tail.lines[backupAt].text
        note("IDLE BACKUP: \(backupText.suffix(100)) (\(describeLine(backupAt)); `settle(gone:)` returned at log line \(settledAt))")
        guard backupText.contains("Created auto-backup") || backupText.contains("Skipped auto-backup") else {
            fail("TEST-SETUP: the idle timer fired but no backup was made (\(backupText.suffix(100))): no flush ran, so the test would prove nothing")
            return
        }
        let lastPush = (deleteFrom..<backupAt).last(where: { tail.lines[$0].text.contains("-rebuild-push") })
        guard backupAt >= settledAt, (lastPush ?? -1) < settledAt else {
            fail("TEST-SETUP: the backup (\(describeLine(backupAt))) did not come in a quiet stretch after the delete's settle: settle returned at "
                + "log line \(settledAt), the last rebuild-push line before the backup is \(describeLine(lastPush))")
            return
        }
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: pressFrom, "the Cmd-Z after the backup reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        let run = quickRuns(from: pressFrom, label: "undo").last
        let path = Self.describePaths(run.map { [$0] } ?? [])
        soft.check(run?.quick == true, "the Cmd-Z after the idle backup took the quick path (`start (quick)`; the log says \(path))")
        soft.check(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [size.deleteTitle]), "the heading row is back in the block table")
        addDocumentChecks("after delete, idle backup, Cmd-Z", to: &soft)
        let reinsertLine = waitForLogLine(from: pressFrom, timeout: capped(60)) { $0.text.contains("[SectionReinsertJob]") }
        let reidentified = reinsertLine.flatMap { Phase4bDelTypingParser.intAfter("re-identified ", in: tail.lines[$0].text) }
        let reinsertText = reinsertLine.map { String(tail.lines[$0].text.suffix(170)) } ?? "no [SectionReinsertJob] line"
        result("REINSERT after the idle backup: re-identified rows \(reidentified.map(String.init) ?? "n/a") (the rows the backup's flush "
            + "gave fresh ids, put back by the reinsert); line: \(reinsertText)")
        soft.check(reinsertLine != nil, "the reinsert's `[SectionReinsertJob]` line is in the app log after the Cmd-Z")
        soft.check(plainPushCount(from: pressFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the Cmd-Z to the end")
        attachEvidenceScreenshot(app.screenshot(), name: "quick-undo-after-idle-backup-book6")
        assertSoft(soft, "quick undo after an idle backup")
    }

    /// The same flush path without a timer: File > Save Version after the delete (`flushLiveContentToDatabase` runs inside it), then Cmd-Z: the
    /// quick path, the document the one before the delete.
    func testQuickUndoAfterSaveVersion_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function), section(size.deleteTitle) != nil else { return }
        guard let deleteFrom = deleteSection(size.deleteTitle) else { return }
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line")
        assertCheck(settle(gone: [size.deleteTitle]), "the delete has settled")
        assertCheck(saveVersion(named: "After delete"), "the saved version exists exactly once")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        app.activateAndWaitForForeground()
        tail.poll()
        let pressFrom = tail.lines.count
        pressUndo()
        expectPerformed("undo", from: pressFrom, "the Cmd-Z after Save Version reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        soft.check(quickRuns(from: pressFrom, label: "undo").last?.quick == true, "the Cmd-Z after Save Version took the quick path")
        soft.check(waitForCard(size.deleteTitle, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [size.deleteTitle]), "the heading row is back in the block table")
        addDocumentChecks("after delete, Save Version, Cmd-Z", to: &soft)
        soft.check(plainPushCount(from: pressFrom) == 0, "no `[SYNC-DIAG:UpdateNSView] PUSHING` line from the Cmd-Z to the end")
        attachEvidenceScreenshot(app.screenshot(), name: "quick-undo-after-save-version-book6")
        assertSoft(soft, "quick undo after Save Version")
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
}

// MARK: - 11. A rebuild in flight when Cmd-Z is pressed (verdict v4)

extension WriteQueuePhase4bQuickUndoE2ETests {
    /// A Notes or bibliography rebuild that had read the post-delete database just before Cmd-Z would push stale text over the restored
    /// section and the typing in it (the model found it; plan v4). `FF_UI_TESTING_REBUILD_PUSH_DELAY_MS=3000` (the existing non-blocking
    /// hold between a rebuild's read and its push; at most 3 s, or the content-state watchdog would fire) widens that window. The delete's own
    /// resync starts such a rebuild about a second after the click; the test waits for the app's own `[RebuildPushHold] start ms=3000` line (the
    /// rebuild has read and is holding), presses Cmd-Z, and types " KEPTRB" at the restored caret once `quick restore done` shows.
    /// The Cmd-Z key line and the first typed key must both come before the first `[RebuildPushHold] end` line (the rebuild's push follows
    /// it), and the log must show `rebuild push skipped (stale: quick restore)`. Afterwards the section
    /// and the word are on screen and in the block table, the footnotes sequential with one definition each, and no plain push was logged.
    func testRebuildInFlightAtQuickUndo_book6() {
        let size = Phase4bDelSize.book6
        guard startScenario(size, method: #function, env: ["FF_UI_TESTING_REBUILD_PUSH_DELAY_MS": "3000"], seed: Self.withInnerParagraph),
              let target = placeCaretInSection() else { return }
        let word = "KEPTRB"
        guard let deleteFrom = deleteSection(target.title) else { return }
        // The anchor is the app's own marker: `[RebuildPushHold] start ms=3000` is written right after a rebuild has READ the database and
        // before it pushes (diagnostic.log); `[RebuildPushHold] end` is written when that hold is over, just before the push.
        guard let holdStartAt = waitForLogLine(from: deleteFrom, timeout: capped(size.operationTimeout), where: { line in
            line.text.contains("[RebuildPushHold] start ms=")
        }) else {
            fail("TEST-SETUP: no `[RebuildPushHold] start ms=` line after the delete: no rebuild read the database (or the seam did not take)")
            return
        }
        pressUndo()
        guard let restored = waitForStep("undo", "quick restore done", from: holdStartAt, timeout: capped(size.operationTimeout)),
              restored.stepT["quick restore done"] != nil else {
            fail("no `quick restore done` line after the Cmd-Z: \(describeSequence(from: deleteFrom))")
            return
        }
        let keys = typeAndRecord(" " + word)
        expectPerformed("undo", from: deleteFrom, "the undo reached its performed line")
        var soft = Phase4bFlowSoftChecks()
        _ = waitForPainted("undo", from: deleteFrom, timeout: capped(60))
        reportQuickFigures(quickRuns(from: deleteFrom, label: "undo"), what: "rebuild-hold test, Cmd-Z while a rebuild held", flagPainted: true)
        let holdEndAt = waitForLogLine(from: holdStartAt, timeout: capped(60), where: { $0.text.contains("[RebuildPushHold] end") })
        let pressLine = firstLogIndex(from: holdStartAt) { line in
            Phase4bDelTypingParser.key(line.text).map { $0.code == Phase4bDelTypingParser.zKeyCode } ?? false
        }
        let endDate = holdEndAt.flatMap { tail.lines[$0].date }
        soft.check(holdEndAt != nil && pressLine != nil && pressLine.map { $0 < (holdEndAt ?? 0) } == true,
                   "TEST-SETUP: the Cmd-Z key (\(describeLine(pressLine))) came before the rebuild's hold ended (`[RebuildPushHold] end`, "
                       + "\(describeLine(holdEndAt)); the hold started at \(describeLine(holdStartAt)))")
        let keyDates = keys.compactMap(\.date)
        let insideCount = keyDates.filter { date in endDate.map { date < $0 } ?? false }.count
        func stamped(_ date: Date?) -> String { date.map { WriteQueuePhase4bTraceE2ETests.stamp($0) } ?? "-" }
        note("KEYS vs the rebuild's hold: \(keys.count) typed key(s), \(insideCount) before `[RebuildPushHold] end`; first key stamp "
            + "\(stamped(keyDates.first)), hold end stamp \(stamped(endDate)), hold start stamp \(stamped(tail.lines[holdStartAt].date))")
        soft.check(insideCount >= 1 && keyDates.first.map { date in endDate.map { date < $0 } ?? false } == true,
                   "TEST-SETUP: the first typed key fell before `[RebuildPushHold] end` (\(insideCount) of \(keys.count) did)")
        let skipped = waitForLogIndex(containing: ["rebuild push skipped (stale"], from: holdStartAt, timeout: capped(60))
        soft.check(skipped != nil, "the log has `rebuild push skipped (stale: quick restore)` (the stale rebuild's push was not applied)")
        let opId = quickRuns(from: deleteFrom, label: "undo").last?.opId ?? "--------"
        soft.check(waitForLogIndex(containing: ["reinsert op=\(opId) settled"], from: deleteFrom, timeout: capped(size.operationTimeout)) != nil,
                   "the reinsert's settle ended (`reinsert op=\(opId) settled`)")
        soft.check(quickRuns(from: deleteFrom, label: "undo").last?.quick == true, "the Cmd-Z took the quick path")
        soft.check(waitForCard(target.title, present: true, timeout: capped(60)), "the section's sidebar card is back")
        soft.check(settle(back: [target.title]), "the heading row is back in the block table")
        soft.check(waitForSentenceInDatabase(word, timeout: 90), "\"\(word)\" reached the database")
        soft.check(typedLineOnScreen(Self.innerLine, word: word, timeout: 90),
                   "after the rebuild's hold the restored section's first line still reads \"\(Self.innerLine) \(word)\" on screen")
        soft.check(plainPushCount(from: deleteFrom) == 0,
                   "\(plainPushCount(from: deleteFrom)) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) from the delete to the end (must be 0)")
        addDocumentChecks("after delete, a rebuild in flight, Cmd-Z, typing", typedRows: [target.inner: "\(Self.innerLine) \(word)"], to: &soft)
        attachEvidenceScreenshot(app.screenshot(), name: "rebuild-in-flight-at-quick-undo-book6")
        assertSoft(soft, "a rebuild in flight at the quick undo")
    }
}
