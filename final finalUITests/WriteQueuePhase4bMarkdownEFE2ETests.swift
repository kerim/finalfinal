//
//  WriteQueuePhase4bMarkdownEFE2ETests.swift
//  final finalUITests
//
//  bt task t-4a8fd8af, SLICE 1 (VM test authoring): THE MARKDOWN-MODE DELETE SECTION AND ITS CMD-Z / CMD-SHIFT-Z, editor first, proven in the
//  real app. In Markdown mode (View > Switch to Markdown, Cmd-/) a Delete Section from the Outline card's context menu used to read the text
//  out of the editor, save all of it, delete the rows, build the text again and push it back over the editor, so words typed around the click
//  could be lost. Now the CodeMirror page removes the section at once, the Outline hides it at once, a queued job makes the rows agree behind
//  everything typed, and Cmd-Z puts the section back in one editor turn (no "Undoing..." message), Cmd-Shift-Z deletes it again, and a second
//  Cmd-Z pressed while the first runs is held and carried out. The design record is in .claude/superdev/write-queue-phase4b-markdown/
//  (plan-v2.md section E and I, plan-v2.1-addendum.md section 5 = the hand-test list these tests mirror) and in docs/architecture/
//  document-writer.md, "Markdown editor-first Delete Section and its Cmd-Z / Cmd-Shift-Z".
//
//  CLASS NAME: after the TASK (vmtest's retry-refusal streak is keyed by class and method name across worktrees). The class inherits the
//  harness of WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`: launch, seeding, the app-log follower, the sidebar driving, the
//  evidence writer) and the pure helpers of WriteQueuePhase4bDeleteFlowE2ETests.swift (`Phase4bFlow`, `Phase4bFlowRow`, `Phase4bFlowWalk`,
//  `Phase4bFlowSoftChecks`) and WriteQueuePhase4bQuickUndoE2ETests.swift (`Phase4bQuLog`); it changes nothing in any of them. The few
//  behaviour-class helpers it needs (they live in THEIR final classes) are copied here, as the earlier classes did. It is ONE file on
//  purpose: scripts/e2e-hygiene.sh allows one new permanent UI-test file per branch (a second needs an `e2e-cap: allow` trailer), so the
//  file disables the file-length rule at its first import, like every other Phase 4b e2e file.
//
//  THE DOCUMENTS (generated, never a manuscript; every note and result line starts with the fixture tag `[<size> W<words> S<sections>
//  C<citation groups> F<footnote marks> L<characters>]` and `noteCounts()` adds the block, footnote-reference, footnote-definition and
//  citation-bracket counts read from the DATABASE; both go into the `fixture-counts-<method>.txt` attachment and an XCTContext activity):
//    article  x1 chapter:   58,764 characters, 68 citation groups,   9 footnote marks (60+ resolving citations, footnotes, 30 comment/task/
//                           reference marks, a block quote, Chinese text, a generated bibliography)
//    book6    x6 chapters: 349,810 characters, 408 citation groups,  54 footnote marks
//    book12   x12 chapters: 699,139 characters, 816 citation groups, 108 footnote marks
//  Every chapter of a book repeats the first chapter's prose (same random seed): no test finds a paragraph of a later chapter by its text.
//  Only chapter 1 holds the "Anchor01..14 line of the fixture document." paragraphs, so the typing goes to the Anchor05 line (the caret is put
//  there with the proven exact-line recipe), which lies in the chapter BEFORE the chapter a test deletes.
//
//  FLATTENED COPIES (a drag needs two neighbouring cards on screen; the sidebar's visible band is about 585 pt and XCUITest cannot scroll
//  during a drag, and "Delete, then Delete at once" needs both cards on screen too): the sub-headings of some chapters are turned into plain
//  lines (`flattening`: words, citations and footnotes unchanged, only the `##` / `###` marks go). THE TESTS THAT USE A FLATTENED COPY:
//    testMdDragThenDeleteThenUndo_book6           chapters 1, 3, 5 and 6 flat (was testMdOldPathDragThenDeleteThenUndo_book6)
//    testMdDeleteThenDelete_book6                 chapters 1, 3, 5 and 6 flat
//    testMdDeleteThenDeleteHeld_book6             chapters 1, 3, 5 and 6 flat
//    testMdDeleteThenDelete_book12                chapters 1, 3, 5, 6, 7 and 8 flat
//  EVERY OTHER TEST USES THE UNFLATTENED GENERATED DOCUMENT (the full outline: 18, 103 and 205 headings).
//
//  THE TESTS (plan-v2 E and the slice-1 hand-test list = plan-v2.1-addendum section 5; docs: e2e-mapping.md in the run folder)
//    testMdTypeAroundDelete_{article,book6}        T-E1  type, Delete at once, the word and the deletion are in editor, Outline, database, reopen
//    testMdDeleteUndoRedo_{article,book6,book12}   T-E2  Delete, Cmd-Z (no "Undoing..."), Cmd-Shift-Z, Cmd-Z twice quickly
//    testMdFootnotedDeleteTypeKeep_{article,book6} T-E3  a footnoted section: Notes gapless, one definition each, both phrases kept, Cmd-Z
//    testMdLastChapterBeforeBibliography_{book6,book12}  T-E4  the last chapter before Notes and Bibliography
//    testMdRenamedHeadingThenDelete_{article,book6}      T-E5  rename a heading word, Delete at once, Cmd-Z brings it back with the new title
//    testMdDragThenDeleteThenUndo_book6            T-E6  (FLATTENED) editor-first drag, Delete, Cmd-Z quick, Cmd-Z undoes the drag
//    testMdCloseWithJobQueued_{article,book6}      T-E7  type, Delete, Cmd-W at once, reopen
//    testMdRichTextPass_{article,book6}            T-E8  Delete + at once switch to Rich Text; Rich Text Delete + Cmd-Z unchanged
//    testMdTiming_book12                           T-E9a the editor turn, the Outline, the quick undo and redo, with the counts
//    testMdDeleteThenDelete_{book6,book12}         T-E9b (FLATTENED) Delete then Delete at once, no job hold
//    testMdDeleteThenDeleteHeld_book6              T-E9c (FLATTENED) the same with the first job held 30 s (so the second click comes while
//                                                  it is held, proven from the log): the "Finishing the last change" notice must show
//
//  WHAT THE APP WRITES FOR A MARKDOWN DELETE (read from the code, 2026-10-23; the mechanism evidence every test asserts):
//    * `[STRUCT-TRACE] ... click-start type=<mouse event> age=<ms>` when the menu item is chosen (the event's own time).
//    * `[MdWrite] structural hold raised (count N)` when the editor-first click starts its work (step 2) and `[MdWrite] structural hold
//      released (count N)` when the job has applied and the live text was flushed (step 8). Every editor-first Markdown command (Delete,
//      the quick Cmd-Z, the quick Cmd-Shift-Z, the queued slow Cmd-Z) raises and releases exactly one hold.
//    * NO `sectionDelete op=.. start` line: the old Markdown body begins that sequence, the new path does not (a test asserts its absence).
//    * The page writes NO success line for the delete (only `markdown-delete plan threw` / `dispatch threw` on errors), so "the editor turn" is
//      measured as click-start (the event time) to the hold-raised line and to the first `[SidebarBody]` render after it (the Outline hiding
//      the section); the job's end is the hold-released line. The tests say so next to every figure.
//    * The quick Cmd-Z / Cmd-Shift-Z: `[STRUCT-TRACE] .. undo|redo op=<id8> start (quick, markdown)`, `quick restore done (markdown)` /
//      `quick removal done (markdown)`, `performed`. The queued slow route (an old-style drag's Cmd-Z): `start (markdown queued undo|redo)`.
//    * ZERO fallback lines: "old path for this press", "page refused or failed", "markdown put-back", "the settle gave up waiting",
//      "step 8: no live text", `[EF-STRUCT]`, "refused (markdown queued", "refused (quick)".
//
//  WAITS: every wait is a CONDITION (the app's log, a database row, the sidebar, a status-bar label, a toast); the user-facing steps are driven
//  straight after each other (type, then at once the menu click, then at once the key). Assertions poll with generous timeouts. Typing is
//  user-origin (typeText / typeKey). Rows are read from the block table only after the settle, never straight after a command.
//  Vocabulary: "settled" = the heading rows moved as wanted, the block table stopped changing and the app's log was quiet for 3 s.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; at most two runs at once; several --scope flags make one run, never a comma list):
//    scripts/vmtest/vmtest run --detach --timeout 1200 \
//      --scope "final finalUITests/WriteQueuePhase4bMarkdownEFE2ETests/testMdTypeAroundDelete_article"
//    book6 runs take 1800 to 3600 s, book12 runs 3600 to 7000 s (see the hand-over for the exact lines).
//

// swiftlint:disable file_length
import AppKit
import XCTest

// MARK: - What a scenario expects of the saved document

/// What must be true of the saved document after a scenario.
struct Phase4bMdExpectation {
    /// Sections (as ranges of the document BEFORE the scenario) that must be gone.
    var removed: [Range<Int>] = []
    /// Complete new fragments of rows of the document before (row number in `pre`), for the rows typed into.
    var typed: [Int: String] = [:]
    /// The Bibliography rows must be exactly those of the document before (true by construction for the books: every chapter repeats the
    /// same citations; not asserted for the article, whose sections hold citations of their own).
    var bibliographyExact = true
    /// Every Notes and Bibliography row must be exactly as before (a scenario that removes nothing).
    var managedExact = false
}

/// One press of Cmd-Z or Cmd-Shift-Z: what the editor decided (`structural`, `fallthrough` = a text step, `swallow` = held behind a running
/// undo, `none`), whether a structural sequence started and was waited for to its `performed` line.
struct Phase4bMdPress {
    let decision: String
    let structural: Bool
    /// Every distinct toast message the accessibility tree showed in the 1.2 s after the key (empty when not watched).
    var toasts: [String] = []
}

/// The timings of one Markdown Delete, from the app's own log (wall clock of the log stamps; the click's own time is the stamp minus `age`).
struct Phase4bMdDeleteTiming {
    var clickToHoldRaisedMs: Int?
    var clickToOutlineMs: Int?
    var clickToHoldReleasedMs: Int?
    var clickAgeMs: Int?
    var clickType: String?
    var holdsRaised = 0
    var finishingNotices = 0

    var text: String {
        func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }
        return "click-start event type=\(clickType ?? "n/a") age=\(ms(clickAgeMs)); click to hold raised \(ms(clickToHoldRaisedMs)); "
            + "click to the first Outline render after it \(ms(clickToOutlineMs)); click to hold released (job applied and flushed) "
            + "\(ms(clickToHoldReleasedMs)); \"Finishing the last change\" notice(s) \(finishingNotices)"
    }
}

/// What the log says about two Deletes in a row: whether the second click came before the first hold was released, and how long the
/// second Delete's wait behind the first was.
struct Phase4bMdOverlap {
    let overlapped: Bool
    let waitMs: Int?
    let text: String
}

// MARK: - The test class

/// The Markdown-mode Delete Section, editor first. See the file header.
final class WriteQueuePhase4bMarkdownEFE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// How many versions this test has saved (each needs its own name).
    var versionSaves = 0

    /// Words with no character the editor transforms (no quote, dash, asterisk, underscore, slash, bracket).
    static let phraseOne = "KEPTMDONE"
    static let phraseTwo = "KEPTMDTWO"
    static let anchorLine = Phase4bDelHarness.anchorPrefix + " line of the fixture document."
    /// The writer holds every queued structural job this long (under the 4 s limit of a hold that blocks the writer).
    static let jobHoldMs = 3_500
    /// A hold of the FIRST job only, long enough that the second Delete's click comes while it is still held. Every XCUITest step takes
    /// seconds in the VM (the second click came about 10 s after the first in the first run), so a few seconds cannot make the two overlap;
    /// the test PROVES the overlap from the log and fails as a TEST-SETUP failure when it did not happen. It blocks the writer for the whole
    /// hold (past the 4 s the e2e skill advises and past the 5 s content-state watchdog), so the held test records the whole-document
    /// push lines instead of asserting there are none, and ends with the screen-equals-database check.
    static let overlapHoldMs = 30_000
    static let holdKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_MS"
    static let holdFirstKey = "FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N"
    /// The six-chapter book's flat chapters: their cards sit next to each other (see the file header).
    static let flatBook6 = [1, 3, 5, 6]
    static let flatBook12 = [1, 3, 5, 6, 7, 8]

    static func chapter(_ number: Int) -> String { "Chapter \(number): The Quiet Archive and Its Ledgers" }

    /// The section a "type around the Delete" test deletes: in the chapter right after the one that holds the Anchor05 line (the article's
    /// Anchor lines sit in its opening, before section 1.1).
    static func typeAroundTarget(_ size: Phase4bDelSize) -> String {
        size == .article ? "1.3 Prices at the Market" : chapter(2)
    }

    /// The footnoted section the T-E3 tests delete (article: section 1.2 holds footnote references 3 and 4; a book chapter holds nine).
    static func footnotedTarget(_ size: Phase4bDelSize) -> String {
        size == .article ? "1.2 The Village Registers" : chapter(2)
    }

    /// The sections whose heading the T-E5 tests rename ("<n>.6 Conclusion" of chapter n; the Markdown H1 line is not exposed as a StaticText,
    /// so the heading renamed is the closing H2 of a chapter, and the section deleted is that H2 with its text).
    static func renameTarget(_ size: Phase4bDelSize) -> String { size == .article ? "1.6 Conclusion" : "2.6 Conclusion" }

    var anchorRow: Int? { pre.firstIndex { $0.fragment == Self.anchorLine } }

    /// The seed with the sub-headings of `chapters` turned into plain lines: a block `## 3.1 Title` / `### 3.1.1 Title` becomes the paragraph
    /// `3.1 Title`. Words, citations and footnotes are unchanged; only the heading marks go.
    static func flattening(_ generated: Phase4bDoc, chapters: [Int]) -> Phase4bDoc {
        let prefixes = chapters.map { "\($0)." }
        let blocks = generated.markdown.components(separatedBy: "\n\n").map { block -> String in
            for marks in ["### ", "## "] where block.hasPrefix(marks) {
                let text = String(block.dropFirst(marks.count))
                if prefixes.contains(where: { text.hasPrefix($0) }) { return text }
            }
            return block
        }
        let text = blocks.joined(separator: "\n\n")
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Begins the method, seeds (flattened when `flat` is not empty) and launches the document with the given seams, reads the saved document,
    /// logs the fixture counts, and switches to Markdown (View > Switch to Markdown). False after a reported failure.
    func startScenario(
        _ size: Phase4bDelSize, method: String, env: [String: String] = [:], flat: [Int] = [], markdown: Bool = true,
        seed: ((Phase4bDoc) -> Phase4bDoc)? = nil
    ) -> Bool {
        begin(method: method, size: size)
        if !flat.isEmpty, let generated = doc {
            let flattened = Self.flattening(generated, chapters: flat)
            doc = flattened
            note("SEED: a FLATTENED COPY, chapters \(flat) have no sub-headings; \(flattened.counts.reportLine)")
        } else {
            note("SEED: the generated document, NOT flattened (the full outline)")
        }
        // `seed` (the drag tests' E-D3 tags every footnote definition with a unique word) runs on the document as flattened above.
        if let seed, let current = doc {
            let seeded = seed(current)
            doc = seeded
            note("SEED: a seed hook was applied to it; \(seeded.counts.reportLine)")
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
        guard walk.problems.isEmpty else {
            fail("the loaded document's footnotes are not 1...n before anything was done: \(walk.problems)")
            return false
        }
        let counts = noteCounts()
        attachText("fixture-counts-\(methodName).txt", "\(fixtureTag)\n\(counts)")
        XCTContext.runActivity(named: "FIXTURE \(fixtureTag) \(counts)") { _ in }
        guard !markdown || switchToMarkdown() else { return false }
        newPhase()
        return true
    }

    /// Each phase of a test (after the load, after a reopen) gets the size's whole wall-clock budget: `capped(...)` shortens every wait to a
    /// 5 s floor once the budget is spent, which would make a working app look broken in a test that makes several phases.
    func newPhase() { startedAt = Date() }

    /// The counts of the document as the database holds it at the start of a test (beside the fixture tag every note carries).
    @discardableResult
    func noteCounts() -> String {
        let walk = Phase4bFlowWalk(rows: pre)
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        let line = "COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), "
            + "\(walk.definitions.count) footnote definition(s), \(citations) citation bracket(s) in the rows, "
            + "\(pre.filter(\.isNotes).count) Notes row(s), \(pre.filter(\.isBibliography).count) Bibliography row(s), "
            + "\(sectionsInDatabase) section row(s), word total shown: \(wordTotal().map(String.init) ?? "n/a")"
        note(line)
        return line
    }

    /// The editor-mode button reads "Markdown" or "Rich Text" (the mode's display name).
    var modeLabel: String { app.buttons["status-bar-editor-mode"].label }

    /// Switches the editor to `wanted` ("Markdown" or "Rich Text") with Cmd-/, the shortcut of the View menu's "Switch to ..." item, pressed
    /// ONCE (the switch holds behind queued structural work and applies afterwards), then waits for the badge (a condition) and, for
    /// Markdown, for the page itself (`waitForMarkdownPageReady`: the badge flips before the page exists, t-55b63c87).
    func switchMode(to wanted: String) -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        if mode.label != wanted {
            app.activateAndWaitForForeground()
            tail.poll()
            let switchFrom = tail.lines.count
            // The View menu's "Switch to ..." item is bound to Cmd-/ (the status bar's hint); this IS that menu command.
            app.typeKey("/", modifierFlags: .command)
            guard mode.waitForLabel("== '\(wanted)'", timeout: appWait(size.operationTimeout * 2,
                before: "the mode button reads \(wanted)")) else {
                fail("the editor-mode button never reported \(wanted) after the toggle keystroke (it reads \(mode.label))")
                return false
            }
            if wanted == "Markdown" { guard waitForMarkdownPageReady(from: switchFrom) else { return false } }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: \(wanted); the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    func switchToMarkdown() -> Bool { switchMode(to: "Markdown") }

    /// The word total in the status bar ("N words", or "K of N words" while a selection exists), or nil when unreadable.
    func wordTotal() -> Int? {
        let text = app.wordCountStatusText()
        let tokens = text.split(separator: " ").map(String.init)
        guard let words = tokens.firstIndex(of: "words"), words > 0 else { return nil }
        return Int(tokens[words - 1].replacingOccurrences(of: ",", with: ""))
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bMarkdownEFE2ETests {
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

    /// The section `title` of `pre`, or a reported TEST-SETUP failure.
    func requireSection(_ title: String) -> Range<Int>? {
        guard let range = section(title) else {
            fail("TEST-SETUP: the loaded document has no section \"\(title)\"")
            return nil
        }
        return range
    }

    func blocksContaining(_ text: String) -> Int {
        dbInt("SELECT count(*) FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(text))') > 0;") ?? -1
    }

    /// Waits for the app to write `sentence` into the block table. `timeout` is a fixed number of seconds, never `capped(...)`.
    func waitForSentenceInDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is looked for in the database"))
        repeat {
            if blocksContaining(sentence) >= 1 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    func waitForSentenceGoneFromDatabase(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is looked for to be gone from the database"))
        repeat {
            if blocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// The timeout of a wait on the APP's answer to an action the test has already taken. Never shortened by the budget (`capped` cuts every
    /// wait down to its 5 s floor once the budget is spent, which made a working app look broken); where the budget is already spent when such
    /// a wait starts, the test fails at once as a TEST-SETUP failure that cannot be taken for an app failure.
    func appWait(_ seconds: TimeInterval, before step: String) -> TimeInterval {
        let left = size.budgetSeconds - Date().timeIntervalSince(startedAt)
        if left <= 0 {
            fail("TEST-SETUP: BUDGET EXHAUSTED before \(step): the \(Int(size.budgetSeconds)) s budget of \(size.identifier) was spent "
                + "\(Int(-left)) s ago, so the app's answer cannot be waited for fairly (the earlier steps of the test used the time, not the"
                    + " app)")
        }
        return seconds
    }

    /// Waits until the named sections' heading rows are gone / back and the block table and the app's log have stopped changing. With no
    /// names it just waits for the document to be quiet. Every wait is a condition.
    @discardableResult
    func settle(gone: [String] = [], back: [String] = []) -> Bool {
        var allDone = true
        for title in gone { allDone = waitForHeadingRows(title, equalTo: 0, timeout: appWait(size.operationTimeout,
            before: "\(title) is gone")) == 0 && allDone }
        for title in back { allDone = waitForHeadingRows(title, equalTo: 1, timeout: appWait(size.operationTimeout,
            before: "\(title) is back")) == 1 && allDone }
        _ = waitForBlocksToSettle()
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        return allDone
    }

    /// Remembers the exact lines of a difference for the `row-differences-<method>.txt` attachment.
    func recordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// `pre`'s text rows without the rows of `removed`, with `typed` (row number in `pre` to the complete new fragment) applied: the
    /// hand-worked answer ("the document before, minus the deleted section, plus what was typed"), not a reading of the app.
    func expectedUserRows(removed: [Range<Int>] = [], typed: [Int: String] = [:]) -> [Phase4bFlowRow] {
        let gone = Set(removed.flatMap { Array($0) })
        var rows: [Phase4bFlowRow] = []
        for (index, row) in pre.enumerated() where !row.isManaged && !gone.contains(index) {
            if let text = typed[index] {
                rows.append(Phase4bFlowRow(type: row.type, isNotes: false, isBibliography: false, fragment: text))
            } else {
                rows.append(row)
            }
        }
        return rows
    }

    /// What is wrong with a saved document against `expect` (empty: nothing). Text rows are compared with footnote numbers read as `[^#]`
    /// (the app renumbers them); the footnote walk (numbers 1...n in reading order, one definition each, none blank) always counts, and so
    /// do the definition TEXTS of the references that remain.
    func documentProblems(_ post: [Phase4bFlowRow], _ expect: Phase4bMdExpectation, _ what: String) -> [String] {
        var found: [String] = []
        let gone = Set(expect.removed.flatMap { Array($0) })
        let expectedUser = expectedUserRows(removed: expect.removed, typed: expect.typed).enumerated().map { (row: $0.offset, value: $0.element) }
        let actualUser = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        if expect.managedExact {
            let before = pre.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let after = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let lines = Phase4bFlow.rowDifferences(expected: before, actual: after, exact: true)
            recordDifferences(what, "Notes / Bibliography rows", lines)
            found += lines.map { "the Notes / Bibliography rows differ from before: \($0)" }
        } else if expect.bibliographyExact {
            let before = pre.enumerated().filter { $0.element.isBibliography }.map { (row: $0.offset, value: $0.element) }
            let after = post.enumerated().filter { $0.element.isBibliography }.map { (row: $0.offset, value: $0.element) }
            let lines = Phase4bFlow.rowDifferences(expected: before, actual: after, exact: true)
            recordDifferences(what, "Bibliography rows", lines)
            found += lines.map { "the Bibliography rows differ from before: \($0)" }
        }
        let walk = Phase4bFlowWalk(rows: post)
        found += walk.problems.map { "footnotes: \($0)" }
        let expectedTexts = Phase4bFlow.expectedDefinitionTexts(pre: pre, removed: gone)
        let textLines = Phase4bFlow.differenceLines(expectedTexts, walk.definitions.map(\.text))
        recordDifferences(what, "footnote definition texts", textLines)
        found += textLines.map { "the footnote definition texts are not those of the references that remain: \($0)" }
        return found
    }

    /// Reads the block table and adds every problem of `documentProblems` to `soft`, noting the sizes beside the verdict. Returns the rows.
    @discardableResult
    func addDocumentChecks(
        _ what: String, expect: Phase4bMdExpectation, to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        let post = readRows()
        let walk = Phase4bFlowWalk(rows: post)
        let problems = documentProblems(post, expect, what)
        note("\(what): \(post.count) block rows (\(pre.count) before), footnotes \(walk.summary), numbers"
            + " \(walk.refs.prefix(4))...\(walk.refs.suffix(3)); "
            + "\(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// Reports every failure collected in `soft` together, in one assertion.
    func assertAll(_ soft: Phase4bFlowSoftChecks, _ what: String) {
        assertSoft(soft, what)
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func traceLines(from index: Int) -> [Phase4bDelTraceLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].compactMap { Phase4bDelTraceLine($0) }
    }

    /// The log lines since `index` that hold `needle`.
    func logLines(containing needle: String, from index: Int) -> [Phase4bLogLine] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].filter { $0.text.contains(needle) }
    }

    func performedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step == "performed" }.count
    }

    func startedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step.hasPrefix("start") }.count
    }

    /// The undo and redo runs since `index` (the quick ones begin `start (quick, markdown)`: `quick` is true for them).
    func quickRuns(from index: Int, label: String? = nil) -> [Phase4bQuRun] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        let all = Phase4bQuLog.runs(in: tail.lines[index...])
        return label.map { name in all.filter { $0.label == name } } ?? all
    }

    func toastLines(containing needle: String, from index: Int) -> [String] {
        logLines(containing: needle, from: index).map(\.text).filter { $0.contains("[toast] show") }
    }

    func undoingToastCount(from index: Int) -> Int { toastLines(containing: "Undoing", from: index).count }

    /// The warning toast of a queued press that could not be carried out.
    func droppedPressToasts(from index: Int) -> [String] { toastLines(containing: "could not be carried out", from: index) }

    func beepLines(from index: Int) -> [String] { logLines(containing: "beeping", from: index).map(\.text) }

    /// Plain whole-document pushes of the editor's content, which would wipe typing and its undo history. Must be 0.
    func plainPushCount(from index: Int) -> Int { logLines(containing: "[SYNC-DIAG:UpdateNSView] PUSHING", from: index).count }

    /// Every line since `index` that says a Markdown editor-first command took another road than the one under test.
    func fallbackEvidence(from index: Int) -> [String] {
        let markers = [
            "old path for this press", "page refused or failed", "markdown put-back", "the settle gave up waiting", "step 8: no live text",
            "[EF-STRUCT]", "refused (markdown", "refused (quick)", "timeline generation changed mid-click", "the job did not apply",
            "could not be reserved"
        ]
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].map(\.text).filter { text in markers.contains { text.contains($0) } }.map { String($0.suffix(160)) }
    }

    /// The mechanism of Markdown editor-first commands since `index`, printed and added to `soft`: at least `commands` holds were raised
    /// (each Markdown Delete, quick Cmd-Z and quick Cmd-Shift-Z raises one), every hold was released, the old Markdown body's
    /// `sectionDelete op=.. start` sequence never began, and no fallback line was written.
    func addMarkdownMechanismChecks(from index: Int, commands: Int, to soft: inout Phase4bFlowSoftChecks) {
        let raised = logLines(containing: "[MdWrite] structural hold raised", from: index).count
        let released = logLines(containing: "[MdWrite] structural hold released", from: index).count
        let oldStarts = traceLines(from: index).filter { $0.family == .sequence && $0.label == "sectionDelete" && $0.isOpStart }
        let fallbacks = fallbackEvidence(from: index)
        result("MECHANISM: \(raised) `[MdWrite] structural hold raised` line(s) (at least \(commands) expected), \(released) released; "
            + "old-body `sectionDelete start` lines \(oldStarts.count); fallback lines \(fallbacks.count)")
        soft.check(raised >= commands, "only \(raised) `[MdWrite] structural hold raised` line(s), expected at least \(commands): "
            + "the Markdown editor-first road did not run for every command")
        soft.check(released == raised, "\(raised) hold(s) raised but \(released) released: a hold was left up")
        soft.check(oldStarts.isEmpty,
            "\(oldStarts.count) old-body `sectionDelete` sequence start(s): a Delete took the old Markdown road \(oldStarts.map(\.step))")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
    }

    /// The checks every test here makes about the app's log since `index`: no whole-document push, no beep.
    func addLogChecks(from index: Int, checkBeeps: Bool = true, checkPushes: Bool = true, to soft: inout Phase4bFlowSoftChecks) {
        let pushes = plainPushCount(from: index)
        if checkPushes {
            soft.check(pushes == 0, "\(pushes) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) since log line \(index) (must be 0)")
        } else {
            result("WHOLE-DOCUMENT PUSHES (recorded, not asserted: the 30 s writer hold of this test passes the 5 s content-state watchdog):"
                + " \(pushes)")
        }
        if checkBeeps {
            let beeps = beepLines(from: index)
            soft.check(beeps.isEmpty, "the editor beeped \(beeps.count) time(s): \(beeps)")
        }
        let dropped = droppedPressToasts(from: index)
        soft.check(dropped.isEmpty, "the warning toast \"Some undo or redo presses could not be carried out\" showed: \(dropped)")
    }

    /// A refusal or failure the controller (or the sidebar action that called it) logged since `index`.
    func failureLine(from index: Int) -> String? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return Phase4bLog(lines: Array(tail.lines[index...])).failureLine(since: "")?.text
    }

    /// Waits for `count` `<label> performed` lines since `index`; false on a logged failure (noted) or on the timeout (noted).
    @discardableResult
    func waitForPerformed(_ label: String, count: Int = 1, from index: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if performedCount(label, from: index) >= count { return true }
            if let problem = failureLine(from: index) {
                note("PROBLEM while waiting for \(count) \(label) performed line(s): \(problem)")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        note("TIMED OUT after \(Int(timeout)) s waiting for \(count) \(label) performed line(s); saw \(performedCount(label, from: index))")
        return false
    }

    /// One Cmd-Z (`redo` false) or Cmd-Shift-Z press: what the editor decided, whether a structural sequence started, and the wait for its
    /// `performed` line. The press is made straight away (no settle before it); the waiting happens AFTER it.
    func pressStep(redo: Bool, number: Int, watchToasts: Bool = false) -> Phase4bMdPress {
        let direction = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        app.activateAndWaitForForeground()
        if redo { pressRedo() } else { pressUndo() }
        // Right after the key (the accessibility tree of a Markdown editor is small): every toast the press shows in its first 1.2 s.
        let toasts = watchToasts ? toastMessages(watching: 1.2) : []
        var decision = "none"
        let decideBy = Date(timeIntervalSinceNow: 15)
        repeat {
            tail.poll()
            let marker = "[UnifiedUndo] keydown direction=\(direction) "
            if let line = tail.lines[min(from, tail.lines.count)...].first(where: { $0.text.contains(marker) }) {
                decision = Phase4bDelTypingParser.word(after: "decision=", in: line.text) ?? "none"
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < decideBy
        var structural = false
        if decision == "structural" || decision == "swallow" {
            let startBy = Date(timeIntervalSinceNow: appWait(size.operationTimeout * 2, before: "press \(number) starts"))
            while startedCount(direction, from: from) == 0, Date() < startBy { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
            structural = startedCount(direction, from: from) > 0
            if structural {
                waitForPerformed(direction, from: from, timeout: appWait(size.operationTimeout * 2, before: "press \(number) performs"))
            }
        }
        note("PRESS \(number) (\(direction)): the editor decided \(decision);"
            + " \(structural ? "a STRUCTURAL \(direction) ran" : "a text step (or nothing)"); "
            + "toasts in the first 1.2 s: \(toasts)")
        return Phase4bMdPress(decision: decision, structural: structural, toasts: toasts)
    }

    /// The timings of the Markdown Delete whose menu click came after log line `index`, from the app's own log. The click's own time is the
    /// `click-start` stamp minus its `age`; the hold-raised line, the first `[SidebarBody]` render after it and the hold-released line are
    /// the next lines. `nth` picks the nth Delete of the window (0 is the first).
    func deleteTiming(from index: Int, nth: Int = 0) -> Phase4bMdDeleteTiming {
        tail.poll()
        var timing = Phase4bMdDeleteTiming()
        guard index <= tail.lines.count else { return timing }
        let window = Array(tail.lines[index...])
        let clicks = window.indices.filter { window[$0].text.contains("click-start") && window[$0].text.contains(" sectionDelete op=") }
        guard nth < clicks.count else { return timing }
        let clickIndex = clicks[nth]
        let click = window[clickIndex]
        let parsed = Phase4bDelTraceLine(click)
        timing.clickType = parsed.flatMap { Phase4bDelTypingParser.word(after: "type=", in: $0.step) }
        timing.clickAgeMs = parsed.flatMap { Phase4bDelTypingParser.intAfter("age=", in: $0.step) }
        let clickWall = click.date.map { $0.addingTimeInterval(-Double(timing.clickAgeMs ?? 0) / 1000) }
        func ms(_ line: Phase4bLogLine?) -> Int? {
            guard let clickWall, let date = line?.date else { return nil }
            return Int((date.timeIntervalSince(clickWall) * 1000).rounded())
        }
        let after = window[(clickIndex + 1)...]
        let raised = after.first { $0.text.contains("[MdWrite] structural hold raised") }
        timing.clickToHoldRaisedMs = ms(raised)
        if let raised, let raisedAt = window.firstIndex(where: { $0.stamp == raised.stamp && $0.text == raised.text }) {
            timing.clickToOutlineMs = ms(window[(raisedAt + 1)...].first { $0.text.contains("[SidebarBody]") })
            timing.clickToHoldReleasedMs = ms(window[(raisedAt + 1)...].first { $0.text.contains("[MdWrite] structural hold released") })
        }
        timing.holdsRaised = window.filter { $0.text.contains("[MdWrite] structural hold raised") }.count
        let nextClick = nth + 1 < clicks.count ? clicks[nth + 1] : window.count
        timing.finishingNotices = window[clickIndex..<nextClick].filter {
            $0.text.contains("[toast] show") && $0.text.contains("Finishing the last change")
        }.count
        return timing
    }
}

// MARK: - Driving the app

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func sidebarCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    func waitForCard(_ title: String, present: Bool, timeout: TimeInterval) -> Bool {
        secondsUntilCard(title, present: present, timeout: timeout) != nil
    }

    /// Seconds (on the test's clock, a coarse figure: each existence check is an accessibility round trip) until the sidebar card is gone
    /// (`present` false) or there (`present` true); nil on the timeout.
    func secondsUntilCard(_ title: String, present: Bool, timeout: TimeInterval) -> Double? {
        let began = Date()
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if sidebarCard(title).exists == present { return Date().timeIntervalSince(began) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return nil
    }

    func pressUndo() { app.typeKey("z", modifierFlags: .command) }
    func pressRedo() { app.typeKey("z", modifierFlags: [.command, .shift]) }

    /// Types straight into whatever has the keyboard focus (the editor, where the caret was placed). One `typeText` call: a verified retype
    /// would wait, and these scenarios are about what happens when typing comes right after another command.
    func typeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typed at once on purpose; the saved document is what the scenario checks, not the keystrokes.
        app.typeText(text)
    }

    /// The caret at the end of the Anchor05 line (the proven exact-line recipe; confirmed through the status bar's selection count).
    func placeCaret() -> Bool {
        placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine)
    }

    /// Right-clicks the sidebar card whose frame (read BEFORE the typing) is `frame` and chooses `item`. A card is found by its place, not by
    /// its title, for a test that edits the title in between (the sidebar renames the card a moment after the heading line changes). The
    /// app-log index just before the click is returned.
    @discardableResult
    func chooseSidebarItem(atFrame frame: CGRect, item: String) -> Int {
        app.activateAndWaitForForeground()
        tail.poll()
        let fromIndex = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = fromIndex }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let origin = scroll.frame
        scroll.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.minX, dy: frame.midY - origin.minY)).rightClick()
        app.menuItem(titleStartingWith: item).click()
        return fromIndex
    }

    /// The exact-value leaf of the editor (an exact `==` on the value; scoped to `editor-area`, never the sidebar's mirror).
    func exactLeaf(_ value: String) -> XCUIElement {
        // e2e-lint: allow statictext-firstmatch -- scoped to `editor-area` (never the sidebar's mirror) and an exact `==` on the value.
        app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// The leaf that holds the END of the typed line, however CodeMirror exposes it (fix rounds 1 and 2). The typed line "<anchor line>
    /// <sentence>" is 48 characters and WRAPS to two visual lines in the Markdown column (`EditorView.lineWrapping`), so the tree shows either
    /// two leaves (the anchor words with a trailing space, and the sentence alone with no leading space) or ONE two-line leaf, and the typed
    /// space may be a no-break space. In the order of preference: (1) a leaf whose value is the sentence alone (with or without a plain or
    /// a no-break leading space): the end of the line, on its own; (2) the one-run whole line (plain or no-break space); (3) the leaf the line
    /// STARTS with (`editorStaticText(startingWith:)` matches in Swift, so a heading's numeric value cannot throw as a CONTAINS predicate
    /// would): the last resort. Polled for `timeout`. Returns the leaf and which road found it.
    func typedLineLeaf(sentence: String, timeout: TimeInterval) -> (leaf: XCUIElement, how: String)? {
        let spaces = ["", " ", "\u{00A0}"]
        let sentenceAlone = spaces.map { exactLeaf($0 + sentence) }
        let wholeLine = [" ", "\u{00A0}"].map { exactLeaf("\(Self.anchorLine)\($0)\(sentence)") }
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let hit = sentenceAlone.first(where: { $0.exists }) { return (hit, "a leaf holding the sentence alone") }
            if let hit = wholeLine.first(where: { $0.exists }) { return (hit, "the one-run whole line") }
            if let hit = app.editorStaticText(startingWith: Self.anchorLine, timeout: 2) { return (hit, "the leaf the line starts with") }
        } while Date() < deadline
        return nil
    }

    /// A caret probe that is valid for a line that WRAPS. `XCUIApplication.caretSelectionProbe` presses Shift-Cmd-Left and expects the words
    /// of the whole line, which is only right for a one-visual-line paragraph: CodeMirror's Shift-Cmd-Left stops at the wrap point, so from the
    /// end of a wrapped line it selects the LAST visual line only. This one accepts the selection of the last visual line (`lastLineWords`,
    /// 1 word for "KEPTMDONE") or, if the line did not wrap at all, of the whole line (`wholeLineWords`). A caret at the wrap point cannot pass:
    /// from the end of the FIRST visual line Shift-Cmd-Left selects that whole line (the anchor line's 6 words), and from the start of the
    /// second there is nothing to select (the status bar does not change: "unreadable"). The selection is collapsed back to the caret's own
    /// (right) edge afterwards with one Right arrow, as the shared probe does. Returns "ok", "wrong (...)" or "unreadable (...)".
    func caretProbeForWrappedLine(lastLineWords: Int, wholeLineWords: Int) -> String {
        let accepted: Set<Int> = [lastLineWords, wholeLineWords]
        let baseline = app.wordCountStatusText()
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        var seen = baseline
        let deadline = Date(timeIntervalSinceNow: 2.5)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            seen = app.wordCountStatusText()
            if seen != baseline, let words = XCUIApplication.leadingNumber(seen), accepted.contains(words) { break }
        } while Date() < deadline
        app.typeKey(.rightArrow, modifierFlags: [])
        if seen == baseline { return "unreadable (the status bar still read \"\(seen)\")" }
        if let words = XCUIApplication.leadingNumber(seen), accepted.contains(words) { return "ok" }
        return "wrong (the status bar read \"\(seen)\"; a caret at the end of the line selects \(lastLineWords) word(s) back to the wrap point, "
            + "or \(wholeLineWords) when the line does not wrap)"
    }

    /// What the editor shows about the typed line, for a failure message: how many static texts it has, those that mention "Anchor05" or the
    /// sentence (non-ASCII characters written as \u{..}, so a no-break space shows), the first and last values (where the viewport is), and
    /// the editor frame.
    func typedLineEvidence(sentence: String) -> String {
        func escaped(_ value: String) -> String {
            let text = value.unicodeScalars.map { $0.isASCII ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
            return "\"\(text.prefix(90))\""
        }
        guard let values = app.editorStaticTextValues() else { return "the editor's accessibility tree could not be read" }
        let mentioning = values.filter { $0.contains("Anchor05") || $0.contains(sentence) }
        return "\(values.count) static text(s) in editor-area (editor frame \(Self.describeFrame(app.editorArea.frame))); "
            + "mentioning Anchor05 or \(sentence): \(mentioning.map(escaped)); first values \(values.prefix(3).map(escaped)); "
            + "last values \(values.suffix(3).map(escaped)); editorContainsText(Anchor05) \(app.editorContainsText("Anchor05", timeout: 2)), "
            + "editorContainsText(\(sentence)) \(app.editorContainsText(sentence, timeout: 2))"
    }

    /// A person's click back into the line they typed in (the click on a sidebar card moved the keyboard focus to the Outline): the
    /// PARAGRAPH is the target. `typedLineLeaf` finds the line within about 8 s; if it is not in the accessibility tree the editor is scrolled
    /// to its top by the mouse wheel, as a person would (CodeMirror draws only the lines near the viewport), the wheel sign is tried both ways,
    /// and
    /// the line is looked for again. THE LINE WRAPS (fix round 2): the click goes to the right end of the leaf that holds the END of the line
    /// (`typedLineLeaf`) at a height just above the leaf's BOTTOM edge, never the middle (the middle of a two-line leaf is the boundary between
    /// its visual lines, which put the caret at the wrap point and the second phrase in the middle of the line). That lands on the last visual
    /// line of a two-line leaf and still works for a one-line leaf, and to the right of the text it puts the caret at the line's end. No
    /// Cmd-Right follows (it also stops at a wrap point). `caretProbeForWrappedLine` then CONFIRMS the caret: Shift-Cmd-Left selects back to the
    /// start of the last visual line, which must be the sentence alone (1 word), or the whole line if it did not wrap. Fails loudly with the
    /// evidence above, never falls back to a blind click.
    func clickBackIntoTypedLine(sentence: String) -> Bool {
        var found = typedLineLeaf(sentence: sentence, timeout: appWait(8, before: "the typed line is looked for"))
        var scrolled: [String] = []
        for wheel in [CGFloat(20_000), CGFloat(-40_000)] where found == nil {
            scrolled.append("wheel \(Int(wheel))")
            app.editorArea.scroll(byDeltaX: 0, deltaY: wheel)
            found = typedLineLeaf(sentence: sentence, timeout: 8)
        }
        guard let (leaf, how) = found else {
            shot("md-click-back-failed")
            fail("the typed line \"\(Self.anchorLine) \(sentence)\" could not be found to click back into (tried exact leaves with a plain and a "
                + "no-break space, the leaf the line starts with, and the editor scrolled to its top: \(scrolled)). "
                + typedLineEvidence(sentence: sentence))
            return false
        }
        app.waitForStableFrame(leaf)
        guard leaf.exists else { fail("the typed line's leaf vanished while its frame settled"); return false }
        let frame = leaf.frame
        // Just above the leaf's bottom edge: the last visual line of a two-line leaf (never 0.5, the boundary between two visual lines).
        let clickHeight = frame.height > 0 ? max(0.5, (frame.height - 8) / frame.height) : 0.5
        app.activateAndWaitForForeground()
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: clickHeight)).click()
        let lastLineWords = sentence.split(separator: " ").count
        let wholeLineWords = Self.anchorLine.split(separator: " ").count + lastLineWords
        let probe = caretProbeForWrappedLine(lastLineWords: lastLineWords, wholeLineWords: wholeLineWords)
        note("CLICK BACK: found \(how) (frame \(Self.describeFrame(frame)), click at dx 0.97 dy \(String(format: "%.2f", clickHeight)))"
            + "\(scrolled.isEmpty ? "" : " after \(scrolled)"); caret probe (accepts \(lastLineWords) or \(wholeLineWords) words) \(probe)")
        guard probe == "ok" else {
            fail("the caret could not be confirmed at the end of the typed line \"\(Self.anchorLine) \(sentence)\" (leaf \(how), frame "
                + "\(Self.describeFrame(frame)), click dy \(String(format: "%.2f", clickHeight))): \(probe). "
                + typedLineEvidence(sentence: sentence))
            return false
        }
        return true
    }

    /// True when the editor shows `text` (Markdown: CodeMirror draws only the lines near the viewport, so the whole-tree search is cheap).
    func editorShows(_ text: String, timeout: TimeInterval) -> Bool { app.editorContainsText(text, timeout: timeout) }

    /// "The marker is NOT on screen" that cannot pass for the wrong reason: first the plain anchor line itself must be found (the positive
    /// control: the tree IS being read, and that leaf is the one the marker would be part of), then the marker is asked for.
    func markerGoneFromScreen(_ marker: String, timeout: TimeInterval) -> Bool {
        guard exactLeaf(Self.anchorLine).waitForExistence(timeout: timeout) else { return false }
        return !app.editorContainsText(marker, timeout: 3)
    }

    /// The message of the toast on screen right now, from one accessibility snapshot (`toast-message`).
    func toastMessage() -> String? {
        guard let snapshot = try? app.staticTexts["toast-message"].snapshot() else { return nil }
        return (snapshot.value as? String) ?? snapshot.label
    }

    /// Looks at the toast for `seconds` (a figure, not a wait of the scenario: it runs right after a key press) and returns every distinct
    /// message seen.
    func toastMessages(watching seconds: TimeInterval) -> [String] {
        var seen: [String] = []
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            if let message = toastMessage(), !message.isEmpty, !seen.contains(message) { seen.append(message) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return seen
    }

    // MARK: Close, quit, reopen

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
        app.launchEnvironment[Self.holdKey] = nil
        app.launchEnvironment[Self.holdFirstKey] = nil
        tail.poll()
        let relaunchIndex = tail.lines.count
        note("RELAUNCH: app-log line \(relaunchIndex) is the first line the reopened app can write")
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        guard app.editorArea.waitForExistence(timeout: capped(60)) else { fail("the editor area never appeared after the"
            + " relaunch"); return false }
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
            if let message = toastMessage(), message.hasPrefix("The project wasn't closed") {
                fail("the close was cancelled by its time budget and the app said so: \"\(message)\"")
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        fail("the project picker never appeared 300 s after Cmd-W")
        return false
    }

    // MARK: Save Version (the screen equals the database)

    /// File > Save Version with `name`, and the wait for its snapshot row. Saving a version runs `flushLiveContentToDatabase`, which writes
    /// the LIVE editor text into the block table first.
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

    /// The house rule "the screen equals the database": `before` is a read of the block table; File > Save Version then writes the live
    /// editor text into the table, and the table is read again. The two reads must be identical, every row, Notes and Bibliography included.
    func addScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout Phase4bFlowSoftChecks) {
        versionSaves += 1
        let name = "Markdown check \(versionSaves)"
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

// MARK: - Dragging a card (the old click in Markdown; the flattened test only)

extension WriteQueuePhase4bMarkdownEFE2ETests {
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

    /// The heading list `headings` with the section titled `moved` (its heading and every deeper heading after it) taken out and put before
    /// the heading titled `target`: the hand-worked order after a drag.
    func headingsMoving(_ headings: [String], moved: String, before target: String) -> [String] {
        guard let start = headings.firstIndex(where: { Self.title($0) == moved }) else { return headings }
        let level = Self.level(headings[start])
        var end = start + 1
        while end < headings.count, Self.level(headings[end]) > level { end += 1 }
        let run = Array(headings[start..<end])
        var rest = headings
        rest.removeSubrange(start..<end)
        let insertion = rest.firstIndex { Self.title($0) == target } ?? rest.count
        rest.insert(contentsOf: run, at: insertion)
        return rest
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

    func firstDifference(_ expected: [String], _ actual: [String]) -> String {
        guard let first = zip(expected, actual).enumerated().first(where: { $0.element.0 != $0.element.1 }) else {
            return expected.count == actual.count ? "none" : "\(expected.count) headings expected, \(actual.count) found"
        }
        return "heading \(first.offset): expected \"\(expected[first.offset].prefix(50))\", found \"\(actual[first.offset].prefix(50))\""
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
        note("SIDEBAR: cards \(titles.map { "\"\($0.prefix(30))\"" }) span \(Self.describeFrame(both)); visible band"
            + " \(Self.describeFrame(band)); "
            + "all inside: \(Self.yesNo(band.contains(both)))")
        guard band.contains(both) else {
            fail("TEST-SETUP: the cards \(titles) are not all inside the sidebar's visible band, so one drag cannot reach from one to the other")
            return nil
        }
        return cards
    }

    /// Drags the card `moved` and lets it go on the title of the card `target` (the section lands right after it: "insert before X" is a
    /// drop on the card above X), aiming at the horizontal zone of heading level `level` (the card is split into predecessor level + 1
    /// equal zones, zone n is level n + 1: a chapter is dropped at the far left). The app-log index just before the press, nil after a
    /// reported failure.
    func dragCard(_ moved: String, after target: String, level: Int, dropY: CGFloat = 0.5) -> Int? {
        guard let cards = bringIntoView([moved, target]) else { return nil }
        let predecessorLevel = headingFragmentsInDatabase().first { Self.title($0) == target }.map { Self.level($0) } ?? 1
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let zones = CGFloat(predecessorLevel + 1)
        let wanted = CGFloat(min(max(level, 1), predecessorLevel + 1))
        let screenX = scroll.frame.minX + (wanted - 0.5) * scroll.frame.width / zones
        let targetCard = cards[1]
        let dropPoint = targetCard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: dropY))
            .withOffset(CGVector(dx: screenX - targetCard.frame.minX, dy: 0))
        let point = dropPoint.screenPoint
        note("DRAG: \"\(moved.prefix(40))\" to just after \"\(target.prefix(40))\" at level \(level): pointer ends at (\(Int(point.x)),"
            + " \(Int(point.y))) in the "
            + "sidebar \(Self.describeFrame(scroll.frame)); predecessor level \(predecessorLevel); dragged card"
                + " \(Self.describeFrame(cards[0].frame)); "
            + "target card \(Self.describeFrame(targetCard.frame))")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let grab = cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.5, thenDragTo: dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3)
        return from
    }
}

// MARK: - Shared pieces of the tests

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func requireAnchorRow() -> Int? {
        guard let row = anchorRow else {
            fail("TEST-SETUP: the loaded document has no \"\(Self.anchorLine)\" row")
            return nil
        }
        return row
    }

    func shot(_ name: String) { attachEvidenceScreenshot(app.screenshot(), name: "\(name)-\(size.identifier)") }

    // MARK: The word total the status bar shows, from the database

    /// The sum of the app's own per-block word counts (`block.wordCount`). The status bar adds up exactly this column:
    /// `ProjectDatabase.batchWordCounts` gives each heading the sum of the block counts from that heading to the next heading, and the bar
    /// sums the headings (`EditorViewState.filteredTotalWordCount`), leaving the Bibliography section out when `excludeBibliography` is on.
    func blockWordSum(excludingBibliography: Bool) -> Int? {
        dbInt("SELECT COALESCE(SUM(COALESCE(wordCount, 0)), 0) FROM block\(excludingBibliography ? " WHERE isBibliography = 0" : "");")
    }

    /// Every block's `wordCount`, in the order `readRows()` lists the rows (so index i is the same block).
    func blockWordCounts() -> [Int] {
        FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath, sql: "SELECT COALESCE(wordCount, 0) FROM block ORDER BY sortOrder, id;")
            .split(separator: "\n", omittingEmptySubsequences: true).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Reads, from the document AS LOADED and untouched, which of the two block sums the status-bar total equals: true when it leaves the
    /// Bibliography blocks out, false when it counts every block, nil when it equals neither (the caller reports a TEST-SETUP failure).
    func statusBarLeavesBibliographyOut() -> Bool? {
        guard let bar = wordTotal(), let everything = blockWordSum(excludingBibliography: false),
              let withoutBibliography = blockWordSum(excludingBibliography: true) else {
            note("WORD BASIS: the status bar or the block sums could not be read")
            return nil
        }
        note("WORD BASIS (document as loaded): status bar \(bar); sum of all block word counts \(everything); "
            + "sum without the Bibliography blocks \(withoutBibliography)")
        if bar == everything { return false }
        return bar == withoutBibliography ? true : nil
    }

    /// Polls (a condition, bounded) until the status-bar total equals the sum of the saved blocks' word counts, and returns the last pair
    /// read (so a mismatch is reported with both figures).
    func waitForBarToMatchBlocks(excludingBibliography: Bool, timeout: TimeInterval) -> (bar: Int?, blocks: Int?) {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the status-bar total is compared with the saved blocks"))
        var pair = (bar: wordTotal(), blocks: blockWordSum(excludingBibliography: excludingBibliography))
        while pair.bar == nil || pair.bar != pair.blocks, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            pair = (bar: wordTotal(), blocks: blockWordSum(excludingBibliography: excludingBibliography))
        }
        return pair
    }

    /// The footnote references (reading order) of the rows of `range` in `pre`, as numbers.
    func footnoteNumbers(in range: Range<Int>) -> [Int] {
        pre[range].flatMap { Phase4bFlow.footnoteRefs(in: $0.fragment) }
    }
}

// MARK: - T-E1 Type, Delete at once, then everything is where it should be

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdTypeAroundDelete_article() { runTypeAroundDelete(.article, method: #function) }
    func testMdTypeAroundDelete_book6() { runTypeAroundDelete(.book6, method: #function) }

    /// Hand-test step 1: "Click at the end of a paragraph in the chapter before the target, type a word. Then, without clicking anywhere
    /// else first, right-click the target's card and choose Delete Section." The section is gone from the Outline and the text, the word is
    /// in the editor; after the settle the word AND the deletion are in the block table, the editor's text equals the table (Save Version),
    /// and a quit and reopen shows the same document with the SAME word total (the reorder job once left a dip: totals are asserted).
    func runTypeAroundDelete(_ size: Phase4bDelSize, method: String) {
        let title = Self.typeAroundTarget(size)
        guard startScenario(size, method: method), let range = requireSection(title), let anchor = requireAnchorRow(), placeCaret(),
              let card = bringSidebarCardIntoView(title) else { return }
        let phrase = Self.phraseOne
        let wordsBefore = wordTotal()
        note("SCENARIO: the caret is at the end of the Anchor05 line (chapter 1); \"\(title)\" (rows \(range.lowerBound)..<\(range.upperBound), "
            + "\(footnoteNumbers(in: range).count) footnote reference(s) in it) is deleted straight after typing \"\(phrase)\"")
        typeNow(" " + phrase)
        let from = chooseSidebarItem(card, item: "Delete Section")
        var soft = Phase4bFlowSoftChecks()
        let seconds = secondsUntilCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline"))
        result("OUTLINE: the card \"\(title)\" left the Outline after \(seconds.map { String(format: "%.1f", $0) } ?? "never") s on the test's"
            + " clock")
        soft.check(seconds != nil, "the card \"\(title)\" is still in the Outline \(Int(size.operationTimeout)) s after Delete Section")
        soft.check(editorShows(phrase, timeout: 60), "the typed word \"\(phrase)\" is not in the Markdown editor after the Delete")
        shot("md-type-around-delete-1-after-the-delete")
        soft.check(settle(gone: [title]), "the heading \"\(title)\" is still in the block table once the job should have run")
        soft.check(waitForSentenceInDatabase(phrase, timeout: 90), "the word \"\(phrase)\" never reached the block table")
        _ = settle()
        let expectation = Phase4bMdExpectation(
            removed: [range], typed: [anchor: Self.anchorLine + " " + phrase], bibliographyExact: size != .article)
        let post = addDocumentChecks("after the delete (settled)", expect: expectation, to: &soft)
        soft.check(blocksContaining(phrase) == 1, "the word is in \(blocksContaining(phrase)) row(s), expected exactly 1")
        let liveTotal = wordTotal()
        addMarkdownMechanismChecks(from: from, commands: 1, to: &soft)
        addLogChecks(from: from, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the delete", to: &soft)

        guard reopen() else { return }
        let reopened = wordTotal()
        result("WORD TOTALS: before \(wordsBefore.map(String.init) ?? "n/a"), live after the settle \(liveTotal.map(String.init) ?? "n/a"), "
            + "after the quit and reopen \(reopened.map(String.init) ?? "n/a")")
        soft.check(liveTotal != nil && liveTotal == reopened,
            "the word total differs: \(liveTotal.map(String.init) ?? "n/a") shown after the settle, "
            + "\(reopened.map(String.init) ?? "n/a") after the reopen")
        if let wordsBefore, let reopened { soft.check(reopened < wordsBefore,
            "the total after the reopen (\(reopened)) is not below the total before (\(wordsBefore))") }
        soft.check(!sidebarCard(title).exists, "after the reopen the card \"\(title)\" is back in the Outline")
        addDocumentChecks("after the quit and reopen", expect: expectation, to: &soft)
        shot("md-type-around-delete-2-reopened")
        assertAll(soft, "Markdown: type, Delete at once, settle, reopen, on \(size.identifier)")
    }
}

// MARK: - T-E2 Delete, Cmd-Z, Cmd-Shift-Z, Cmd-Z twice quickly

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdDeleteUndoRedo_article() { runDeleteUndoRedo(.article, method: #function) }
    func testMdDeleteUndoRedo_book6() { runDeleteUndoRedo(.book6, method: #function) }
    func testMdDeleteUndoRedo_book12() { runDeleteUndoRedo(.book12, method: #function) }

    /// Hand-test steps 1 to 4. A word is typed, the section deleted, and then: Cmd-Z at once (the section is back word for word, no
    /// "Undoing..." message in the first 1.2 s: the log's `[toast] show` lines AND the `toast-message` element), Cmd-Shift-Z (gone again),
    /// then Cmd-Z TWICE straight after each other (two key events, nothing between): the first brings the section back and the second,
    /// held while the first runs, takes the typed word away. The end state is the document as loaded (rows, Notes and Bibliography
    /// byte for byte, the word total as before), and the editor's text equals the table (Save Version). FIX ROUND 4: the quick Cmd-Z and the
    /// quick Cmd-Shift-Z that take over 1.4 s from the key to `performed` must have shown "Finishing the last change..."
    /// (`addQuickPressNoticeCheck`).
    func runDeleteUndoRedo(_ size: Phase4bDelSize, method: String) {
        let title = size.deleteTitle
        guard startScenario(size, method: method), let range = requireSection(title), let anchor = requireAnchorRow(), placeCaret(),
              let card = bringSidebarCardIntoView(title) else { return }
        let phrase = Self.phraseOne
        let typedLine = Self.anchorLine + " " + phrase
        let wordsBefore = wordTotal()
        var soft = Phase4bFlowSoftChecks()
        typeNow(" " + phrase)
        let from = chooseSidebarItem(card, item: "Delete Section")

        // Cmd-Z straight after the click: the quick undo, no notice.
        let undoFrom = traceLinesCount()
        let undo = pressStep(redo: false, number: 1, watchToasts: true)
        soft.check(undo.decision == "structural" && undo.structural,
            "Cmd-Z right after the Delete was decided \(undo.decision) (structural ran: \(undo.structural)), not a quick structural undo")
        let undoRuns = quickRuns(from: undoFrom, label: "undo")
        soft.check(undoRuns.count == 1 && undoRuns.allSatisfy(\.quick),
            "the Cmd-Z ran as \(undoRuns.map { "\($0.label) \($0.quick ? "quick" : "slow")" }), expected one quick undo")
        soft.check(undoingToastCount(from: undoFrom) == 0,
            "an \"Undoing...\" toast was written to the log (\(toastLines(containing: "Undoing", from: undoFrom)))")
        soft.check(!undo.toasts.contains { $0.contains("Undoing") },
            "the toast-message element showed \"Undoing...\" within 1.2 s of Cmd-Z: \(undo.toasts)")
        result("QUICK UNDO: key to performed \(undoRuns.first?.keyToPerformedMs.map { "\($0) ms" } ?? "n/a") on the app's clock; toasts in the"
            + " first 1.2 s \(undo.toasts)")
        addQuickPressNoticeCheck("UNDO", label: "undo", from: undoFrom, to: &soft)
        soft.check(waitForCard(title, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(title)\" did not come back after Cmd-Z")
        settle(back: [title])
        let afterUndo = addDocumentChecks(
            "after Cmd-Z (settled)", expect: Phase4bMdExpectation(typed: [anchor: typedLine], managedExact: true), to: &soft)
        let totalBack = wordTotal()
        soft.check(wordsBefore != nil && totalBack == wordsBefore.map { $0 + 1 },
            "the word total after Cmd-Z is \(totalBack.map(String.init) ?? "n/a"), expected \(wordsBefore.map { String($0 + 1) } ?? "n/a")"
            + " (before + the typed word)")
        shot("md-delete-undo-redo-1-after-cmd-z")

        // Cmd-Shift-Z: gone again.
        let redoFrom = traceLinesCount()
        let redo = pressStep(redo: true, number: 2, watchToasts: true)
        soft.check(redo.decision == "structural" && redo.structural,
            "Cmd-Shift-Z was decided \(redo.decision) (structural ran: \(redo.structural))")
        let redoRuns = quickRuns(from: redoFrom, label: "redo")
        soft.check(redoRuns.count == 1 && redoRuns.allSatisfy(\.quick),
            "the Cmd-Shift-Z ran as \(redoRuns.map { "\($0.label) \($0.quick ? "quick" : "slow")" }), expected one quick redo")
        soft.check(!redo.toasts.contains { $0.contains("Redoing") || $0.contains("Undoing") },
            "a progress toast showed within 1.2 s of Cmd-Shift-Z: \(redo.toasts)")
        addQuickPressNoticeCheck("REDO", label: "redo", from: redoFrom, to: &soft)
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves again")),
            "the card \"\(title)\" is still in the Outline after Cmd-Shift-Z")
        settle(gone: [title])
        addDocumentChecks(
            "after Cmd-Shift-Z (settled)",
            expect: Phase4bMdExpectation(removed: [range], typed: [anchor: typedLine], bibliographyExact: size != .article), to: &soft)
        let totalGone = wordTotal()
        soft.check(totalGone != nil && totalBack != nil && totalGone! < totalBack!,
            "the word total after the redo (\(totalGone.map(String.init) ?? "n/a")) is not below the total with the section"
            + " (\(totalBack.map(String.init) ?? "n/a"))")
        shot("md-delete-undo-redo-2-after-cmd-shift-z")

        // Cmd-Z twice, quickly: two key events, nothing between them.
        let doubleFrom = traceLinesCount()
        app.activateAndWaitForForeground()
        pressUndo()
        pressUndo()
        let cardBack = waitForCard(title, present: true, timeout: appWait(size.operationTimeout * 2,
            before: "the card comes back after two Cmd-Z"))
        soft.check(cardBack, "the card \"\(title)\" did not come back after two quick Cmd-Z presses")
        soft.check(waitForSentenceGoneFromDatabase(phrase, timeout: 120),
            "the typed word \"\(phrase)\" is still in the block table after two Cmd-Z presses: the second press did not act")
        settle(back: [title])
        let held = logLines(containing: " failed=latched ", from: doubleFrom).count
        let keydowns = logLines(containing: "[UnifiedUndo] keydown direction=undo ", from: doubleFrom)
        result("DOUBLE Cmd-Z: \(keydowns.count) editor keydown line(s)"
            + " \(keydowns.map { Phase4bDelTypingParser.word(after: "decision=", in: $0.text) ?? "?" }); "
            + "presses held behind the running undo (`failed=latched`): \(held)")
        soft.check(keydowns.count >= 2, "the editor logged \(keydowns.count) Cmd-Z keydown line(s) for two presses")
        // THE UNDO GROUPS (fix round 5): the second press undoes the LAST undo group of the typing. The word is normally ONE group (the
        // page's `undoDepth` is 1 at the first Cmd-Z), so the second press takes the whole word away. On a loaded machine the page can stall
        // between two keys for longer than the history's 500 ms group delay and the word becomes two or more groups (`undoDepth` 2 from the
        // very first press): the second press then undoes only the last group (the last letter), which is correct behaviour.
        let groups = undoDepthOfFirstStructuralPress(from: undoFrom)
        let doubleGroups = undoDepthOfFirstStructuralPress(from: doubleFrom)
        // Whatever the groups: the first press was structural (asserted above), the chapter is back (asserted above), the second press
        // was not refused (no `routing-refused` line but a press held behind the running undo, no beep, no dropped-press toast).
        let refusals = logLines(containing: "[STRUCT-TRACE] routing-refused", from: doubleFrom).filter { !$0.text.contains(" failed=latched ") }
        soft.check(refusals.isEmpty, "a Cmd-Z of the double press was refused: \(refusals.map(\.text))")
        let end: [Phase4bFlowRow]
        let totalEnd: Int?
        if (groups ?? 1) <= 1 {
            end = addDocumentChecks("after two quick Cmd-Z presses (settled)", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
            soft.check(markerGoneFromScreen(phrase, timeout: 60), "the typed word \"\(phrase)\" is still on screen after two quick Cmd-Z presses")
            totalEnd = wordTotal()
            soft.check(totalEnd != nil && totalEnd == wordsBefore,
                "the word total at the end is \(totalEnd.map(String.init) ?? "n/a"), expected the total before everything"
                + " (\(wordsBefore.map(String.init) ?? "n/a"))")
        } else {
            result("DOUBLE Cmd-Z: typing was split into \(groups ?? 0) undo groups under load (undoDepth at the double press's first key: "
                + "\(doubleGroups.map(String.init) ?? "n/a")); second press undid the last group only")
            let typedFull = Self.anchorLine + " " + phrase
            let remaining = readRows().first { $0.fragment.hasPrefix(Self.anchorLine) }?.fragment ?? ""
            soft.check(remaining.hasPrefix(Self.anchorLine) && typedFull.hasPrefix(remaining) && remaining.count < typedFull.count,
                "after the second press the anchor line reads \"\(remaining)\": expected a shorter prefix of \"\(typedFull)\" "
                + "(the last undo group taken away, the earlier ones kept)")
            // Every other row is the document before everything; the anchor row is whatever the editor kept (the screen-equals-database
            // round trip at the end proves that the saved rows ARE the editor's text).
            end = addDocumentChecks(
                "after two quick Cmd-Z presses (settled; the typing is split in \(groups ?? 0) groups)",
                expect: Phase4bMdExpectation(typed: [anchor: remaining], managedExact: true), to: &soft)
            soft.check(app.editorStaticText(startingWith: Self.anchorLine, timeout: 60) != nil && !app.editorContainsText(phrase, timeout: 3),
                "the whole typed word \"\(phrase)\" is still on screen after two quick Cmd-Z presses (or the anchor line is not on screen)")
            let steps = logLines(containing: "[UnifiedUndo] keydown-path-invocation direction=undo", from: doubleFrom).filter { line in
                let before = Phase4bDelTypingParser.intAfter("docLengthBefore=", in: line.text) ?? 0
                let after = Phase4bDelTypingParser.intAfter("docLengthAfter=", in: line.text) ?? 0
                return after < before
            }
            soft.check(keydowns.contains { $0.text.contains("decision=fallthrough") } && !steps.isEmpty,
                "the second press made no text step: no `decision=fallthrough` keydown line and a text undo that shortened the document "
                + "(lines: \(steps.map(\.text)))")
            let addedWords = max(0, remaining.split(separator: " ").count - Self.anchorLine.split(separator: " ").count)
            totalEnd = wordTotal()
            soft.check(totalEnd != nil && wordsBefore != nil && totalEnd == wordsBefore.map { $0 + addedWords },
                "the word total at the end is \(totalEnd.map(String.init) ?? "n/a"), expected the total before everything "
                + "(\(wordsBefore.map(String.init) ?? "n/a")) plus the \(addedWords) word(s) of the typing that is left (\"\(remaining)\")")
        }
        result("WORD TOTALS: before \(wordsBefore.map(String.init) ?? "n/a"); with the word and the section"
            + " \(totalBack.map(String.init) ?? "n/a"); "
            + "section gone (redo) \(totalGone.map(String.init) ?? "n/a"); at the end \(totalEnd.map(String.init) ?? "n/a")")
        addMarkdownMechanismChecks(from: from, commands: 4, to: &soft)
        addLogChecks(from: from, to: &soft)
        _ = afterUndo
        addScreenEqualsDatabaseCheck(before: end, what: "at the end", to: &soft)
        shot("md-delete-undo-redo-3-end")
        assertAll(soft, "Markdown: Delete, Cmd-Z, Cmd-Shift-Z, Cmd-Z twice, on \(size.identifier)")
    }

    /// FLOOR 3 for a QUICK Cmd-Z or Cmd-Shift-Z (fix round 4: on book12 a Cmd-Z pressed about a second after a Delete took 1539 ms from the
    /// key to `performed` with nothing shown; the app now keeps one delayed "Finishing the last change..." notice from the press until the
    /// press ends, undo and redo). `label` is "undo" or "redo", `index` the log index just before the press. When the press took longer than
    /// 1.4 s from the key to its `performed` line (the app's clock), the app log must hold a `[toast] show ... Finishing the last change` line
    /// stamped between the key line and the `performed` line (50 ms of slack for the stamps' resolution; when a stamp cannot be read, any
    /// such line since `index` counts). A press under 1.4 s needs no notice and nothing is asserted either way. Always records
    /// `RESULT QUICK <UNDO|REDO> NOTICE: <n> ms, notice seen: yes/no`.
    func addQuickPressNoticeCheck(_ name: String, label: String, from index: Int, to soft: inout Phase4bFlowSoftChecks) {
        guard let run = quickRuns(from: index, label: label).first, let figure = run.keyToPerformedMs else {
            result("QUICK \(name) NOTICE: n/a ms, notice seen: n/a (no quick run or no key line in the log)")
            return
        }
        let performed = traceLines(from: index).first {
            $0.family == .sequence && $0.label == label && $0.opId == run.opId && $0.step == "performed"
        }
        let notices = logLines(containing: "Finishing the last change", from: index).filter { line in
            guard line.text.contains("[toast] show") else { return false }
            guard let shown = line.date, let key = run.keyDate, let end = performed?.line.date else { return true }
            return shown >= key.addingTimeInterval(-0.05) && shown <= end.addingTimeInterval(0.05)
        }
        let seen = !notices.isEmpty
        result("QUICK \(name) NOTICE: \(figure) ms, notice seen: \(seen ? "yes" : "no")")
        if figure > 1_400 {
            soft.check(seen, "FLOOR 3: the quick \(label) took \(figure) ms from the key to `performed` (over 1.4 s) and no `[toast] show ... "
                + "Finishing the last change` line was written between the key and `performed`")
        }
    }

    /// The page's own `undoDepth` (how many undo groups its text history holds) at the first Cmd-Z since `index` that the editor decided
    /// `structural`, read from its `[UnifiedUndo] keydown direction=undo decision=structural undoDepth=N ...` line; nil if there is none.
    func undoDepthOfFirstStructuralPress(from index: Int) -> Int? {
        logLines(containing: "[UnifiedUndo] keydown direction=undo ", from: index)
            .first { $0.text.contains("decision=structural") }
            .flatMap { Phase4bDelTypingParser.intAfter("undoDepth=", in: $0.text) }
    }

    /// The index of the next app-log line (where the next operation's own lines begin).
    func traceLinesCount() -> Int {
        tail.poll()
        return tail.lines.count
    }
}

// MARK: - T-E3 A footnoted section: type, Delete at once, keep typing, the Notes stay gapless

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdFootnotedDeleteTypeKeep_article() { runFootnotedDelete(.article, method: #function) }
    func testMdFootnotedDeleteTypeKeep_book6() { runFootnotedDelete(.book6, method: #function) }

    /// The footnote labels the editor shows for the Notes definitions that are on screen (a leaf that starts with `[^N]:`), in the order the
    /// accessibility tree lists them.
    func visibleNoteLabels() -> [Int] {
        let values = app.editorStaticTextValues() ?? []
        return values.compactMap { value -> Int? in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("[^"), let close = text.range(of: "]:") else { return nil }
            return Int(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
        }
    }

    /// Hand-test step 5. A section with footnotes is deleted straight after a word was typed in the section before it, and a second
    /// phrase is typed after clicking back into the text (the right-click moved the focus to the Outline). The footnote references run
    /// 1..N with no gap, every number has exactly one definition (no duplicate `[^N]:`), both phrases are in the text, and the editor
    /// text equals the table. Cmd-Z then brings the section AND its notes back with the numbers still gapless (the plan says one press;
    /// when the second phrase was typed after the Delete the editor hands the first press to the text undo, so the number of presses it
    /// took is reported and at most two are allowed).
    func runFootnotedDelete(_ size: Phase4bDelSize, method: String) {
        let title = Self.footnotedTarget(size)
        guard startScenario(size, method: method), let range = requireSection(title), let anchor = requireAnchorRow(), placeCaret(),
              let card = bringSidebarCardIntoView(title) else { return }
        let numbers = footnoteNumbers(in: range)
        let totalNumbers = Phase4bFlowWalk(rows: pre).refs.count
        note("FOOTNOTED SECTION: \"\(title)\" holds \(numbers.count) footnote reference(s) \(numbers) of the document's \(totalNumbers)")
        var soft = Phase4bFlowSoftChecks()
        soft.check(!numbers.isEmpty, "TEST-SETUP: the section \"\(title)\" holds no footnote reference")
        typeNow(" " + Self.phraseOne)
        let from = chooseSidebarItem(card, item: "Delete Section")
        guard clickBackIntoTypedLine(sentence: Self.phraseOne) else { return }
        typeNow(" " + Self.phraseTwo)
        let typedLine = Self.anchorLine + " " + Self.phraseOne + " " + Self.phraseTwo
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline")),
            "the card \"\(title)\" is still in the Outline")
        soft.check(settle(gone: [title]), "the heading \"\(title)\" is still in the block table once the job should have run")
        soft.check(waitForSentenceInDatabase(Self.phraseTwo, timeout: 90),
            "the second phrase \"\(Self.phraseTwo)\" never reached the block table")
        _ = settle()
        let expectation = Phase4bMdExpectation(removed: [range], typed: [anchor: typedLine], bibliographyExact: size != .article)
        let post = addDocumentChecks("after the delete and the typing (settled)", expect: expectation, to: &soft)
        let walk = Phase4bFlowWalk(rows: post)
        let remaining = totalNumbers - numbers.count
        soft.check(walk.refs == Array(1...max(remaining, 1)) || remaining == 0, "the footnote references run \(walk.refs), not 1...\(remaining)")
        soft.check(walk.definitions.map(\.number) == Array(stride(from: 1, through: remaining, by: 1)),
            "the definitions are numbered \(walk.definitions.map(\.number)), not 1...\(remaining) (one each)")
        shot("md-footnoted-delete-1-after-the-delete")

        // Scroll to Notes (the Outline card of the Notes section) and read the definition labels the editor shows, from one snapshot of the
        // editor's tree (`addNotesOnScreenCheck`: no label read within 30 s of the click is a FAILURE, with the tree dump and the screenshot
        // attached; the old run-by-run reader came back empty and its `labels.isEmpty || consecutive` check passed on nothing).
        addNotesOnScreenCheck("after the delete and the typing", to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the delete and the typing", to: &soft)
        addMarkdownMechanismChecks(from: from, commands: 1, to: &soft)
        addLogChecks(from: from, to: &soft)

        // Cmd-Z: the section and its notes come back.
        let undoFrom = traceLinesCount()
        var presses = 0
        while presses < 2, !sidebarCard(title).exists {
            presses += 1
            let press = pressStep(redo: false, number: presses, watchToasts: presses == 1)
            soft.check(press.decision == "structural" || press.decision == "fallthrough", "Cmd-Z press \(presses) was decided \(press.decision)")
            _ = waitForCard(title, present: true, timeout: press.structural ? appWait(size.operationTimeout, before: "the card comes back") : 8)
        }
        result("CMD-Z: the section was back after \(presses) press(es) (the plan says 1; a second phrase typed after the Delete makes the"
            + " first press a text undo)")
        soft.check(sidebarCard(title).exists, "the card \"\(title)\" is not back after \(presses) Cmd-Z press(es)")
        settle(back: [title])
        let phraseTwoKept = blocksContaining(Self.phraseTwo) >= 1
        soft.check(blocksContaining(Self.phraseOne) == 1,
            "the word typed BEFORE the Delete is in \(blocksContaining(Self.phraseOne)) row(s) after Cmd-Z, expected 1")
        let lineAfter = Self.anchorLine + " " + Self.phraseOne + (phraseTwoKept ? " " + Self.phraseTwo : "")
        addDocumentChecks("after Cmd-Z (settled)", expect: Phase4bMdExpectation(typed: [anchor: lineAfter], managedExact: true), to: &soft)
        soft.check(undoingToastCount(from: undoFrom) == 0,
            "an \"Undoing...\" toast was written to the log: \(toastLines(containing: "Undoing", from: undoFrom))")
        addLogChecks(from: undoFrom, to: &soft)
        shot("md-footnoted-delete-3-after-cmd-z")
        assertAll(soft, "Markdown: footnoted section, type, Delete at once, type again, Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - T-E4 The last chapter before the Bibliography

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdLastChapterBeforeBibliography_book6() { runLastChapter(.book6, method: #function) }
    func testMdLastChapterBeforeBibliography_book12() { runLastChapter(.book12, method: #function) }

    /// Hand-test step 6. The last chapter (right before Notes and Bibliography) is deleted: the Bibliography rows are exactly those of the
    /// document before (the books repeat one chapter's citations, so none leaves the bibliography), Notes lose only that chapter's nine
    /// definitions, nothing of Notes or the Bibliography was cut away by the range; Cmd-Z brings the chapter back and the Notes and
    /// Bibliography rows are byte for byte those of the document before.
    func runLastChapter(_ size: Phase4bDelSize, method: String) {
        let title = Self.chapter(size.chapters)
        guard startScenario(size, method: method), let range = requireSection(title), placeCaret(),
              let card = bringSidebarCardIntoView(title) else { return }
        let next = range.upperBound < pre.count ? pre[range.upperBound] : nil
        var soft = Phase4bFlowSoftChecks()
        soft.check(next?.isManaged == true,
            "TEST-SETUP: the row after \"\(title)\" is not a Notes or Bibliography row (it is \(next?.type ?? "past the end"))")
        let bibliographyRows = pre.filter(\.isBibliography).count
        let notesRows = pre.filter(\.isNotes).count
        note("LAST CHAPTER: \"\(title)\" is rows \(range.lowerBound)..<\(range.upperBound) of \(pre.count); \(notesRows) Notes row(s), "
            + "\(bibliographyRows) Bibliography row(s) follow")
        let from = chooseSidebarItem(card, item: "Delete Section")
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline")),
            "the card \"\(title)\" is still in the Outline")
        soft.check(settle(gone: [title]), "the heading \"\(title)\" is still in the block table once the job should have run")
        let post = addDocumentChecks("after the delete (settled)", expect: Phase4bMdExpectation(removed: [range]), to: &soft)
        soft.check(post.filter(\.isBibliography).count == bibliographyRows,
            "the Bibliography has \(post.filter(\.isBibliography).count) row(s) after the delete, \(bibliographyRows) before")
        soft.check(post.filter(\.isNotes).count > 0, "the Notes section is gone after the delete")
        soft.check(sidebarCard("Notes").exists, "the Outline has no \"Notes\" card after the delete")
        shot("md-last-chapter-1-after-the-delete")
        addScreenEqualsDatabaseCheck(before: post, what: "after the delete", to: &soft)

        let undoFrom = traceLinesCount()
        let undo = pressStep(redo: false, number: 1, watchToasts: true)
        soft.check(undo.decision == "structural" && undo.structural, "Cmd-Z was decided \(undo.decision) (structural ran: \(undo.structural))")
        soft.check(!undo.toasts.contains { $0.contains("Undoing") } && undoingToastCount(from: undoFrom) == 0,
            "an \"Undoing...\" toast showed: \(undo.toasts)")
        soft.check(waitForCard(title, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(title)\" did not come back")
        settle(back: [title])
        addDocumentChecks("after Cmd-Z (settled)", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
        addMarkdownMechanismChecks(from: from, commands: 2, to: &soft)
        addLogChecks(from: from, to: &soft)
        shot("md-last-chapter-2-after-cmd-z")
        assertAll(soft, "Markdown: the last chapter before the Bibliography, Delete and Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - T-E5 A heading renamed, then Delete at once

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdRenamedHeadingThenDelete_article() { runRenamedHeading(.article, method: #function) }
    func testMdRenamedHeadingThenDelete_book6() { runRenamedHeading(.book6, method: #function) }

    /// Hand-test step 7. One word of a section's heading line is changed ("Conclusion" to "Closure": a click at the end of the line, Option-
    /// Shift-Left to select the last word, typing over it), and without clicking elsewhere the section's card is right-clicked and Delete
    /// Section chosen. The Outline still shows the old title when the click comes (the card is found by its place), so the page's heading
    /// line and the rows' differ: the click flushes the typing and goes on editor first (no old-body `sectionDelete` sequence). The section
    /// is gone with its new title; Cmd-Z brings it back WITH the new title.
    func runRenamedHeading(_ size: Phase4bDelSize, method: String) {
        let title = Self.renameTarget(size)
        let renamed = title.replacingOccurrences(of: "Conclusion", with: "Closure")
        guard startScenario(size, method: method), let range = requireSection(title), let card = bringSidebarCardIntoView(title) else { return }
        // Navigate to the heading (a click on its card scrolls the editor there), then find its line in the editor.
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.waitForStableFrame(card)
        guard let line = app.editorHeadingText(matching: title, timeout: appWait(60, before: "the heading line is looked for")) else {
            fail("the heading line \"\(title)\" is not exposed in the Markdown editor after a click on its card (leaves:"
                + " \(app.editorStaticTextsDump().prefix(600)))")
            return
        }
        let cardFrame = card.frame
        app.waitForStableFrame(line)
        line.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift])
        typeNow("Closure")
        let from = chooseSidebarItem(atFrame: cardFrame, item: "Delete Section")
        var soft = Phase4bFlowSoftChecks()
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline")) &&
                   waitForCard(renamed, present: false, timeout: 30),
                       "the card (\"\(title)\" or \"\(renamed)\") is still in the Outline after Delete Section")
        soft.check(settle(gone: [title, renamed]), "the section is still in the block table once the job should have run")
        let expectation = Phase4bMdExpectation(removed: [range], bibliographyExact: size != .article)
        addDocumentChecks("after the delete (settled)", expect: expectation, to: &soft)
        soft.check(headingRows(renamed) == 0 && headingRows(title) == 0,
            "heading rows after the delete: \(headingRows(title)) \"\(title)\", \(headingRows(renamed)) \"\(renamed)\"")
        shot("md-renamed-heading-1-after-the-delete")

        let undoFrom = traceLinesCount()
        let undo = pressStep(redo: false, number: 1, watchToasts: true)
        soft.check(undo.decision == "structural" && undo.structural, "Cmd-Z was decided \(undo.decision) (structural ran: \(undo.structural))")
        soft.check(!undo.toasts.contains { $0.contains("Undoing") } && undoingToastCount(from: undoFrom) == 0,
            "an \"Undoing...\" toast showed: \(undo.toasts)")
        soft.check(waitForCard(renamed, present: true, timeout: appWait(size.operationTimeout,
            before: "the card comes back with the new title")), "the card \"\(renamed)\" (the NEW title) did not come back")
        settle(back: [renamed])
        let headingRow = range.lowerBound
        let renamedFragment = pre[headingRow].fragment.replacingOccurrences(of: "Conclusion", with: "Closure")
        let post = addDocumentChecks(
            "after Cmd-Z (settled)", expect: Phase4bMdExpectation(typed: [headingRow: renamedFragment], managedExact: true), to: &soft)
        soft.check(headingRows(renamed) == 1 && headingRows(title) == 0,
            "heading rows after Cmd-Z: \(headingRows(title)) \"\(title)\" (expected 0), \(headingRows(renamed)) \"\(renamed)\" (expected 1)")
        addMarkdownMechanismChecks(from: from, commands: 2, to: &soft)
        addLogChecks(from: from, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after Cmd-Z", to: &soft)
        shot("md-renamed-heading-2-after-cmd-z")
        assertAll(soft, "Markdown: a renamed heading, Delete at once, Cmd-Z, on \(size.identifier)")
    }
}

// MARK: - T-E6 (E-D4) An editor-first drag, then Delete, then Cmd-Z at once (FLATTENED book6)

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// A Cmd-Z or Cmd-Shift-Z press; when the key reached no editor (no `[UnifiedUndo] keydown` line), the test records that as a FINDING and
    /// clicks back into the Anchor05 line (as a person does) and presses again, so the rest of the scenario still runs.
    func pressStepRefocusing(redo: Bool, number: Int, watchToasts: Bool, what: String, soft: inout Phase4bFlowSoftChecks) -> Phase4bMdPress {
        var press = pressStep(redo: redo, number: number, watchToasts: watchToasts)
        if press.decision == "none" {
            soft.check(false,
                "FINDING (\(what)): the key reached no editor (no `[UnifiedUndo] keydown` line within 15 s): the keyboard focus was not in the"
                + " editor")
            clickBackIntoAnchor()
            press = pressStep(redo: redo, number: number + 100, watchToasts: watchToasts)
        }
        return press
    }

    /// "1...36, 46...54, 37...45": the ascending runs of a number list, for the footnote observation.
    static func ascendingRuns(_ numbers: [Int]) -> String {
        var runs: [String] = []
        var start: Int?
        var last = 0
        for number in numbers {
            if let begin = start, number == last + 1 {
                last = number
                _ = begin
            } else {
                if let begin = start { runs.append(begin == last ? "\(begin)" : "\(begin)...\(last)") }
                start = number
                last = number
            }
        }
        if let begin = start { runs.append(begin == last ? "\(begin)" : "\(begin)...\(last)") }
        return runs.joined(separator: ", ")
    }

    /// The rows of `rows` that Delete Section on `title` takes out: the section's own rows and the Notes definitions of the footnotes the
    /// section references (the editor removes exactly those: the section and the notes only it used). Nil when `title` is no section.
    func rowIndexesDeleting(_ title: String, in rows: [Phase4bFlowRow]) -> [Int]? {
        guard let range = Phase4bFlow.sectionRange(title, in: rows) else { return nil }
        let labels = Set(rows[range].flatMap { Phase4bFlow.footnoteRefs(in: $0.fragment) })
        var indexes = Array(range)
        for (index, row) in rows.enumerated() where row.isNotes {
            if let definition = Phase4bFlow.definition(row.fragment), labels.contains(definition.number) { indexes.append(index) }
        }
        return indexes.sorted()
    }

    /// The Notes footnote labels that more than one saved row carries (the defect: duplicate definition rows saved after a Markdown drag,
    /// a Delete and a Cmd-Z).
    func duplicateNoteLabels(in rows: [Phase4bFlowRow]) -> [Int] {
        let labels = rows.filter(\.isNotes).compactMap { Phase4bFlow.definition($0.fragment)?.number }
        return Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    /// The status-bar total once it equals the sum of the saved blocks' word counts (see `runCloseWithJobQueued`, assertion (a)): recorded,
    /// checked, and returned, so a test can compare the settled states with each other (the total never changes without an edit).
    func settledWordTotal(_ what: String, basis: Bool?, to soft: inout Phase4bFlowSoftChecks) -> Int? {
        guard let basis else { return wordTotal() }
        let pair = waitForBarToMatchBlocks(excludingBibliography: basis, timeout: 60)
        result("WORD TOTAL \(what): status bar \(pair.bar.map(String.init) ?? "n/a"), sum of the saved blocks' word counts "
            + "\(pair.blocks.map(String.init) ?? "n/a")")
        soft.check(pair.bar != nil && pair.bar == pair.blocks,
            "\(what): the status-bar total (\(pair.bar.map(String.init) ?? "n/a")) is not the sum "
            + "of the saved blocks' word counts (\(pair.blocks.map(String.init) ?? "n/a"))")
        return pair.bar
    }

    /// Checks the saved rows after an undo against the document right after the drag (`snapshot`): the same number of rows, no Notes label
    /// saved twice, and every row the same (footnote numbers read as `[^#]`).
    func addSnapshotChecks(
        _ what: String, rows: [Phase4bFlowRow], snapshot: [Phase4bFlowRow], to soft: inout Phase4bFlowSoftChecks
    ) {
        let lines = Phase4bFlow.rowDifferences(
            expected: snapshot.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: rows.enumerated().map { (row: $0.offset, value: $0.element) }, exact: false)
        recordDifferences(what, "rows against the document right after the drag", lines)
        let duplicates = duplicateNoteLabels(in: rows)
        result("\(what): \(rows.count) saved rows (\(snapshot.count) right after the drag); duplicated Notes label(s) \(duplicates)")
        soft.check(rows.count == snapshot.count, "\(what): the saved project has \(rows.count) rows, expected \(snapshot.count)")
        soft.check(duplicates.isEmpty, "\(what): a Notes footnote label is saved more than once: \(duplicates)")
        soft.check(lines.isEmpty, "\(what): the rows differ from the document right after the drag: \(lines.joined(separator: " | "))")
    }

    /// Checks the saved rows after the Delete ALONE, settled: exactly the document right after the drag minus the section and its notes
    /// (the row count, the other text rows, the remaining definitions' words), and no Notes label saved twice.
    func addAloneChecks(
        rows: [Phase4bFlowRow], snapshot: [Phase4bFlowRow], removed: [Int], to soft: inout Phase4bFlowSoftChecks
    ) {
        let gone = Set(removed)
        let expectedCount = snapshot.count - removed.count
        let duplicates = duplicateNoteLabels(in: rows)
        result("AFTER THE DELETE ALONE (settled): \(rows.count) saved rows, expected \(expectedCount) (\(snapshot.count) right after the drag "
            + "minus \(removed.count) rows of the chapter and its notes); duplicated Notes label(s) \(duplicates)")
        soft.check(rows.count == expectedCount, "after the Delete alone the saved project has \(rows.count) rows, expected \(expectedCount): "
            + "the document the editor holds (the \(snapshot.count) rows right after the drag minus the chapter and its \(removed.count) rows)")
        soft.check(duplicates.isEmpty, "after the Delete alone a Notes footnote label is saved more than once: \(duplicates)")
        let expectedUser = snapshot.enumerated().filter { !gone.contains($0.offset) && !$0.element.isManaged }
            .map { (row: $0.offset, value: $0.element) }
        let actualUser = rows.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences("after the Delete alone", "text rows", userLines)
        soft.check(userLines.isEmpty,
            "after the Delete alone the text rows are not the document minus the chapter: \(userLines.joined(separator: " | "))")
        let expectedNotes = snapshot.enumerated().filter { !gone.contains($0.offset) && $0.element.isNotes }
            .compactMap { Phase4bFlow.definition($0.element.fragment)?.text }.sorted()
        let actualNotes = rows.filter(\.isNotes).compactMap { Phase4bFlow.definition($0.fragment)?.text }.sorted()
        let noteLines = Phase4bFlow.differenceLines(expectedNotes, actualNotes)
        recordDifferences("after the Delete alone", "footnote definition texts", noteLines)
        soft.check(noteLines.isEmpty, "after the Delete alone the footnote definitions are not those of the references that remain: "
            + noteLines.joined(separator: " | "))
    }

    func footnoteObservation(_ label: String, rows: [Phase4bFlowRow]) -> String {
        let walk = Phase4bFlowWalk(rows: rows)
        return "\(label): \(walk.refs.count) reference(s) in text order, runs [\(Self.ascendingRuns(walk.refs))]; "
            + "numbering problems: \(walk.problems.isEmpty ? "none" : walk.problems.joined(separator: " | "))\n  all numbers: \(walk.refs)"
    }

    /// Hand-test steps 9 and 10. FLIPPED in t-4a8fd8af slice 2 (it was `testMdOldPathDragThenDeleteThenUndo_book6`, which asserted the OLD
    /// road: a plain `start` and no `reorder-editor-first` line). A chapter card is dragged above its neighbour: in Markdown the drag is now
    /// EDITOR FIRST (the sequence begins `start (editor-first) mode=markdown`, the page's reply `reorder-editor-first ... ok=true
    /// mode=markdown` is in the log, and NO plain `start` is written), then another chapter is deleted and Cmd-Z is pressed AT ONCE: the
    /// chapter returns with no "Undoing..." message (the QUICK undo, and it stays quick because the new drag raises no structural-generation
    /// bump: the old body's drag is what used to close it, plan v2 A13); a second Cmd-Z undoes the drag (the queued slow route; a notice MAY
    /// show) and the heading order and every row are those of the document before.
    /// NOW ASSERTED (board t-8dc76a0b, which this slice closes for Markdown): the footnote reference numbers of the document right after
    /// the drag has settled read 1...N in text order with no jump back, and the Notes are numbered 1...N once each. The numbers right after
    /// the drag's `performed` line (the job may not have applied yet) and the ones after the drag was undone are still recorded in
    /// `footnote-observation-<method>.txt` and `result` lines; the last ones are asserted equal to the document before.
    /// FIX ROUND 3 (the judge's extra checks, after an independent diagnosis found a real app defect: duplicate footnote-definition rows
    /// saved after Markdown drag + Delete + Cmd-Z, 573 rows became 591): (i) the Delete ALONE, settled and before any Cmd-Z, saves exactly the
    /// document right after the drag minus the chapter and its notes (the row count, the other rows, the remaining definitions' words) and no
    /// Notes label twice; (ii) after EACH Cmd-Z (the one pressed at once and the one after the settled Delete) the saved rows are exactly the
    /// rows right after the drag, the same count (573) and no duplicated label; (iii) the word total shown never changes without an edit:
    /// as loaded, after the drag, after each Cmd-Z and after the drag is undone it is the same, after the Delete alone it is at most the
    /// total minus the chapter's and its notes' words, and in every settled state it equals the sum of the saved blocks' word counts.
    /// The test ends with the screen-equals-database check.
    /// USES A FLATTENED COPY (chapters 1, 3, 5, 6 have no sub-headings).
    func testMdDragThenDeleteThenUndo_book6() {
        let size = Phase4bDelSize.book6
        let moved = Self.chapter(6)
        let target = Self.chapter(5)
        let deleted = Self.chapter(3)
        guard startScenario(size, method: #function, flat: Self.flatBook6), requireSection(moved) != nil, requireSection(target) != nil,
              requireSection(deleted) != nil, placeCaret() else { return }
        let original = preHeadingFragments
        guard let targetIndex = original.firstIndex(where: { Self.title($0) == target }), targetIndex > 0 else {
            fail("TEST-SETUP: \"\(target)\" is not a heading of the loaded document with a predecessor")
            return
        }
        let predecessor = Self.title(original[targetIndex - 1])
        var observation = [footnoteObservation("BEFORE the drag", rows: pre)]
        var soft = Phase4bFlowSoftChecks()
        let leavesBibliographyOut = statusBarLeavesBibliographyOut()
        soft.check(leavesBibliographyOut != nil, "TEST-SETUP: the status-bar total as loaded equals neither the sum of all block word counts "
            + "nor the sum without the Bibliography blocks, so the word totals cannot be checked against the saved blocks")
        let totalLoaded = wordTotal()
        note("DRAG: \"\(moved)\" is dropped just after \"\(predecessor)\" (so it lands above \"\(target)\"); then \"\(deleted)\" is deleted"
            + " and Cmd-Z pressed at once; then the Delete alone, settled, and Cmd-Z once more; then the drag is undone")

        guard let dragFrom = dragCard(moved, after: predecessor, level: 1) else { return }
        soft.check(waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs")),
            "the drag's `sectionReorder` sequence never performed")
        observation.append(footnoteObservation("RIGHT AFTER the drag's performed line", rows: readRows()))
        let dragged = headingsMoving(original, moved: moved, before: target)
        soft.check(waitForHeadingOrder(dragged, timeout: 180),
            "after the drag the block table's heading order is not the expected one (\(firstDifference(dragged, headingFragmentsInDatabase())))")
        settle()
        let settledRows = readRows()
        observation.append(footnoteObservation("AFTER the drag has settled", rows: settledRows))
        let wordCounts = blockWordCounts()
        let totalDragged = settledWordTotal("after the drag (settled)", basis: leavesBibliographyOut, to: &soft)
        soft.check(totalDragged != nil && totalDragged == totalLoaded,
            "the word total changed with no edit: \(totalLoaded.map(String.init) ?? "n/a") "
            + "as loaded, \(totalDragged.map(String.init) ?? "n/a") after the drag")
        guard let removedIndexes = rowIndexesDeleting(deleted, in: settledRows) else {
            soft.check(false, "TEST-SETUP: \"\(deleted)\" is no section of the document right after the drag")
            assertAll(soft, "Markdown: editor-first drag, Delete, Cmd-Z, on book6 (flattened); \(countsLine)")
            return
        }
        // THE FLIP: the drag took the editor-first road (and NOT the old body's plain `start`), and the footnotes follow the text.
        let starts = traceLines(from: dragFrom).filter { $0.family == .sequence && $0.label == "sectionReorder" && $0.isOpStart }
        soft.check(starts.count == 1 && starts[0].step == "start (editor-first) mode=markdown",
            "the Markdown drag's sequence began \(starts.map(\.step)), expected one `start (editor-first) mode=markdown` (the old body logs a "
            + "plain `start`)")
        soft.check(!starts.contains { $0.step == "start" }, "a plain `start` of the old body was written for the Markdown drag")
        let replies = logLines(containing: "[STRUCT-TRACE] reorder-editor-first opId=", from: dragFrom)
            .filter { $0.text.contains(" ok=true") && $0.text.contains("mode=markdown") }
        soft.check(replies.count == 1, "\(replies.count) `reorder-editor-first ... ok=true mode=markdown` line(s) for the drag, expected 1")
        let settledWalk = Phase4bFlowWalk(rows: settledRows)
        let footnotesBefore = Phase4bFlowWalk(rows: pre).refs.count
        let oneToN = Array(stride(from: 1, through: footnotesBefore, by: 1))
        soft.check(settledWalk.refs == oneToN,
            "after the drag has settled the footnote references read [\(Self.ascendingRuns(settledWalk.refs))] in text order, "
            + "expected 1...\(footnotesBefore) with no jump back (t-8dc76a0b); \(countsLine)")
        soft.check(settledWalk.definitions.map(\.number) == oneToN,
            "after the drag has settled the Notes are numbered [\(Self.ascendingRuns(settledWalk.definitions.map(\.number)))], "
            + "expected 1...\(footnotesBefore) once each")
        shot("md-drag-then-delete-1-after-the-drag")

        // Delete another chapter, and Cmd-Z at once.
        guard let card = bringSidebarCardIntoView(deleted) else { return }
        let deleteFrom = chooseSidebarItem(card, item: "Delete Section")
        let undo = pressStepRefocusing(redo: false, number: 1, watchToasts: true, what: "Cmd-Z at once after the Delete", soft: &soft)
        soft.check(undo.decision == "structural" && undo.structural,
            "Cmd-Z was decided \(undo.decision) (structural ran: \(undo.structural)), not a quick undo of the delete")
        let runs = quickRuns(from: deleteFrom, label: "undo")
        result("CMD-Z after the editor-first drag: runs \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")" }); key to performed"
            + " \(runs.first?.keyToPerformedMs.map { "\($0) ms" } ?? "n/a")")
        soft.check(runs.first?.quick == true,
            "the Cmd-Z after drag + Delete was not the quick undo (\(runs.map { $0.quick ? "quick" : "slow" }))")
        soft.check(undoingToastCount(from: deleteFrom) == 0 && !undo.toasts.contains { $0.contains("Undoing") },
            "an \"Undoing...\" message showed: \(undo.toasts) \(toastLines(containing: "Undoing", from: deleteFrom))")
        soft.check(waitForCard(deleted, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(deleted)\" did not come back after Cmd-Z")
        settle(back: [deleted])
        soft.check(waitForHeadingOrder(dragged, timeout: 120),
            "after the first Cmd-Z the heading order is not the post-drag one (\(firstDifference(dragged, headingFragmentsInDatabase())))")
        // THE EXACT COMPARISON: after the Cmd-Z the saved rows are the rows right after the drag (the defect saved duplicate footnote
        // definition rows here: 573 rows became 591).
        addSnapshotChecks("after the first Cmd-Z (at once)", rows: readRows(), snapshot: settledRows, to: &soft)
        let totalBack = settledWordTotal("after the first Cmd-Z (settled)", basis: leavesBibliographyOut, to: &soft)
        soft.check(totalBack != nil && totalBack == totalDragged,
            "the word total changed with no edit: \(totalDragged.map(String.init) ?? "n/a") after the "
            + "drag, \(totalBack.map(String.init) ?? "n/a") after the Delete and its Cmd-Z")
        shot("md-drag-then-delete-2-after-the-first-cmd-z")

        // THE DELETE ALONE, settled (the judge's extra checks): Delete the same chapter again, wait for the settle, and check what was
        // saved BEFORE any Cmd-Z: the document the editor holds is the one right after the drag minus the chapter and its notes, so the
        // saved row count is that count, and no Notes label is saved twice. Then Cmd-Z, with the same exact comparison.
        newPhase()
        guard let aloneCard = bringSidebarCardIntoView(deleted) else { return }
        chooseSidebarItem(aloneCard, item: "Delete Section")
        soft.check(waitForCard(deleted, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves")),
            "the card \"\(deleted)\" is still in the Outline after the Delete alone")
        settle(gone: [deleted])
        addAloneChecks(rows: readRows(), snapshot: settledRows, removed: removedIndexes, to: &soft)
        let totalAlone = settledWordTotal("after the Delete alone (settled)", basis: leavesBibliographyOut, to: &soft)
        let removedWords = wordCounts.count == settledRows.count ? removedIndexes.reduce(0) { $0 + wordCounts[$1] } : nil
        if let totalDragged, let totalAlone, let removedWords {
            result("WORD TOTAL arithmetic: \(totalDragged) after the drag - \(removedWords) words of the chapter and its notes = "
                + "\(totalDragged - removedWords); shown after the Delete alone \(totalAlone)")
            soft.check(totalAlone <= totalDragged - removedWords,
                "after the Delete alone the word total (\(totalAlone)) is above \(totalDragged - removedWords) "
                + "(\(totalDragged) after the drag minus the \(removedWords) words of the chapter and its notes): the deletion is not in the"
                    + " total")
        }
        let aloneUndoFrom = traceLinesCount()
        let aloneUndo = pressStepRefocusing(redo: false, number: 2, watchToasts: true, what: "Cmd-Z after the settled Delete", soft: &soft)
        soft.check(aloneUndo.decision == "structural" && aloneUndo.structural,
            "Cmd-Z after the settled Delete was decided \(aloneUndo.decision) (structural ran: \(aloneUndo.structural))")
        soft.check(quickRuns(from: aloneUndoFrom, label: "undo").first?.quick == true,
            "the Cmd-Z after the settled Delete was not the quick undo")
        soft.check(waitForCard(deleted, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(deleted)\" did not come back after the second Cmd-Z")
        settle(back: [deleted])
        addSnapshotChecks("after the Cmd-Z of the settled Delete", rows: readRows(), snapshot: settledRows, to: &soft)
        let totalBack2 = settledWordTotal("after the Cmd-Z of the settled Delete", basis: leavesBibliographyOut, to: &soft)
        soft.check(totalBack2 != nil && totalBack2 == totalDragged,
            "the word total changed with no edit: \(totalDragged.map(String.init) ?? "n/a") after "
            + "the drag, \(totalBack2.map(String.init) ?? "n/a") after the settled Delete and its Cmd-Z")
        shot("md-drag-then-delete-2b-after-the-settled-delete-and-cmd-z")

        // Cmd-Z once more: the drag is undone (the slow, queued road).
        let secondFrom = traceLinesCount()
        let second = pressStepRefocusing(redo: false, number: 3, watchToasts: true, what: "the Cmd-Z that undoes the drag", soft: &soft)
        soft.check(second.decision == "structural" && second.structural,
            "the Cmd-Z that undoes the drag was decided \(second.decision) (structural ran: \(second.structural)), the drag was not undone")
        let secondRuns = quickRuns(from: secondFrom, label: "undo")
        let secondStart = traceLines(from: secondFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #2 (the drag's undo): runs \(secondRuns.map { $0.quick ? "quick" : "slow" }); sequence began `\(secondStart?.step ?? "none")`; "
            + "\"Undoing...\" notice(s) in the log: \(undoingToastCount(from: secondFrom)) (allowed); toasts in the first 1.2 s \(second.toasts)")
        soft.check(secondStart?.step.hasPrefix("start (markdown queued undo") == true,
            "the Cmd-Z that undoes the drag began `\(secondStart?.step ?? "none")`, expected the queued slow route `start (markdown queued undo)`")
        soft.check(waitForHeadingOrder(original, timeout: appWait(size.operationTimeout * 2, before: "the order is restored")),
            "after the second Cmd-Z the heading order is not the original (\(firstDifference(original, headingFragmentsInDatabase())))")
        settle()
        let finalRows = addDocumentChecks("after the second Cmd-Z (settled)", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
        observation.append(footnoteObservation("AFTER the drag was undone", rows: finalRows))
        soft.check(Phase4bFlowWalk(rows: finalRows).refs == Phase4bFlowWalk(rows: pre).refs,
            "the footnote reference numbers after undoing the drag are not those of the document before")
        let totalEnd = settledWordTotal("after the drag was undone (settled)", basis: leavesBibliographyOut, to: &soft)
        soft.check(totalEnd != nil && totalEnd == totalLoaded,
            "the word total changed with no edit: \(totalLoaded.map(String.init) ?? "n/a") as loaded, "
            + "\(totalEnd.map(String.init) ?? "n/a") after the drag was undone")
        // The drag, two Deletes, their Cmd-Z, and the slow Cmd-Z of the drag each raise one hold (the drag once, a Delete and a quick undo
        // twice, the queued undo once). Nothing may have wiped the undo timeline (`invalidateAll`) since the drag: that is what closed the
        // quick road of an earlier Delete in the old body.
        addMarkdownMechanismChecks(from: dragFrom, commands: 6, to: &soft)
        let wiped = logLines(containing: "[UnifiedUndoService] invalidateAll:", from: dragFrom).map(\.text)
        soft.check(wiped.isEmpty, "the undo timeline was wiped (`invalidateAll`) since the drag began: \(wiped.prefix(2))")
        let beeps = beepLines(from: dragFrom)
        soft.check(beeps.isEmpty, "the editor beeped \(beeps.count) time(s): \(beeps)")
        addScreenEqualsDatabaseCheck(before: finalRows, what: "at the end", to: &soft)
        attachText("footnote-observation-\(methodName).txt", observation.joined(separator: "\n\n"))
        for line in observation { result("FOOTNOTE OBSERVATION (recorded): " + line.replacingOccurrences(of: "\n", with: " ")) }
        shot("md-drag-then-delete-3-after-the-drag-was-undone")
        assertAll(soft, "Markdown: editor-first drag, Delete, Cmd-Z at once, the Delete alone and Cmd-Z, the drag's Cmd-Z, on book6 (flattened); "
            + countsLine)
    }
}

// MARK: - T-E7 Close with a job queued

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdCloseWithJobQueued_article() { runCloseWithJobQueued(.article, method: #function) }
    func testMdCloseWithJobQueued_book6() { runCloseWithJobQueued(.book6, method: #function) }

    /// Hand-test step 10. A word is typed, a section deleted, and Cmd-W pressed at once while the delete's database job is still queued (the
    /// seam `FF_UI_TESTING_STRUCT_JOB_HOLD_MS` holds every queued structural job 3.5 s, so the job is pending on a fast machine too; the
    /// seam delays the job's body in the writer, never the editor's removal). The project closes, is reopened, and the word AND the
    /// deletion are in the saved document.
    ///
    /// THE WORD TOTAL (fix round 1, from the first article run): the total read just before the close is a TRANSIENT. With the job still
    /// pending the editor has already dropped the section but the Notes region still holds the deleted section's footnote definition
    /// (the Notes replace is part of the job's settle), so on the article it read 5611 against 5527 once everything was saved. That figure is
    /// therefore only RECORDED (it is in the result line). What is asserted, and cannot pass for the wrong reason:
    ///  (a) the total shown after the reopen equals the sum of the saved blocks' own word counts (`block.wordCount`, read from the database
    ///      after the reopen): the status bar adds up exactly that column (ProjectDatabase.batchWordCounts: each heading's section-only count
    ///      is the sum of the block counts up to the next heading), so a dip or a stale count in the saved project shows as a difference. Whether
    ///      the bar leaves Bibliography blocks out is read from the document as loaded (the bar must equal one of the two sums there, or the
    ///      test says so as a TEST-SETUP failure instead of guessing);
    ///  (b) the deletion is in the total: it is at most the total before the typing and the Delete, plus the typed word, minus the words of
    ///      the deleted section's own blocks (their `wordCount` read from the database before the Delete). The definition of the deleted
    ///      section's footnote can only lower it further, so the bound can only fail when words were NOT removed.
    func runCloseWithJobQueued(_ size: Phase4bDelSize, method: String) {
        let title = Self.typeAroundTarget(size)
        guard startScenario(size, method: method, env: [Self.holdKey: String(Self.jobHoldMs)]), let range = requireSection(title),
              let anchor = requireAnchorRow(), placeCaret(), let card = bringSidebarCardIntoView(title) else { return }
        let phrase = Self.phraseOne
        let totalBefore = wordTotal()
        let leavesBibliographyOut = statusBarLeavesBibliographyOut()
        let blockCounts = blockWordCounts()
        let removedWords = blockCounts.count == pre.count ? blockCounts[range].reduce(0, +) : nil
        typeNow(" " + phrase)
        let from = chooseSidebarItem(card, item: "Delete Section")
        let totalAtClose = wordTotal()
        let pending = logLines(containing: "[MdWrite] structural hold released", from: from).isEmpty
        guard closeProjectWithCommandW() else { return }
        guard relaunch() else { return }
        var soft = Phase4bFlowSoftChecks()
        soft.check(!sidebarCard(title).exists, "after the reopen the card \"\(title)\" is back in the Outline")
        soft.check(waitForSentenceInDatabase(phrase, timeout: 60),
            "the word \"\(phrase)\" is not in the saved project after the close and reopen")
        let expectation = Phase4bMdExpectation(removed: [range], typed: [anchor: Self.anchorLine + " " + phrase],
            bibliographyExact: size != .article)
        addDocumentChecks("after Cmd-W and the reopen", expect: expectation, to: &soft)
        soft.check(blocksContaining(phrase) == 1, "the word is in \(blocksContaining(phrase)) row(s), expected exactly 1")

        // The word total: (a) the bar equals the saved blocks' counts, (b) the deletion is in it, (c) the pre-close figure is only recorded.
        soft.check(leavesBibliographyOut != nil, "TEST-SETUP: the status-bar total as loaded equals neither the sum of all block word counts "
            + "nor the sum without the Bibliography blocks, so the bar cannot be checked against the saved blocks")
        let reopened = waitForBarToMatchBlocks(excludingBibliography: leavesBibliographyOut ?? false, timeout: 60)
        result("WORD TOTALS: before the typing and the Delete \(totalBefore.map(String.init) ?? "n/a"); shown just before closing "
            + "\(totalAtClose.map(String.init) ?? "n/a") (a TRANSIENT, recorded only: the job was still pending at that read: "
            + "\(Self.yesNo(pending)); the Notes still held the deleted section's footnote definition); status bar after the reopen "
            + "\(reopened.bar.map(String.init) ?? "n/a"); sum of the saved blocks' word counts after the reopen "
            + "\(reopened.blocks.map(String.init) ?? "n/a") "
            + "(bar leaves Bibliography out: \(leavesBibliographyOut.map { Self.yesNo($0) } ?? "unknown")); "
            + "words of the deleted section's blocks \(removedWords.map(String.init) ?? "n/a")")
        if leavesBibliographyOut != nil {
            soft.check(reopened.bar != nil && reopened.bar == reopened.blocks,
                "after the reopen the status-bar total (\(reopened.bar.map(String.init) ?? "n/a")) is not the sum of the saved blocks' word"
                    + " counts "
                + "(\(reopened.blocks.map(String.init) ?? "n/a")): the saved project and the total disagree")
        }
        if let totalBefore, let removedWords, let bar = reopened.bar {
            let ceiling = totalBefore + 1 - removedWords
            soft.check(bar <= ceiling,
                "the word total after the reopen (\(bar)) is above \(ceiling) (the total before \(totalBefore), plus the typed "
                + "word, minus the \(removedWords) words of the deleted section): the deletion is not in the saved total")
        }
        let released = logLines(containing: "[MdWrite] structural hold released", from: from).count
        soft.check(released >= 1, "the delete's hold was never released before the project closed (the close did not wait for the job)")
        shot("md-close-with-job-queued")
        assertAll(soft, "Markdown: type, Delete, Cmd-W at once, reopen, on \(size.identifier)")
    }
}

// MARK: - T-E8 Rich Text pass

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdRichTextPass_article() { runRichTextPass(.article, method: #function) }
    func testMdRichTextPass_book6() { runRichTextPass(.book6, method: #function) }

    /// Hand-test steps 8 (of the plan) and 12. In Markdown a section is deleted and View > Switch to Rich Text (Cmd-/) is pressed at once:
    /// the switch waits for the job and then happens, the section stays deleted. In Rich Text another section is deleted and Cmd-Z pressed:
    /// both are the Rich Text editor-first road as before (a `delete-editor-first ... ok=true` line, a `start (quick)` undo, no Markdown hold,
    /// no "Undoing..."). Switching back to Markdown leaves the document as it is.
    func runRichTextPass(_ size: Phase4bDelSize, method: String) {
        let first = Self.typeAroundTarget(size)
        let second = size == .article ? "1.5 Lanterns After Dark" : Self.chapter(4)
        guard startScenario(size, method: method), let firstRange = requireSection(first), requireSection(second) != nil, placeCaret(),
              let card = bringSidebarCardIntoView(first) else { return }
        var soft = Phase4bFlowSoftChecks()
        let from = chooseSidebarItem(card, item: "Delete Section")
        // View > Switch to Rich Text is bound to Cmd-/; pressed once and at once, the switch must wait for the job and then happen.
        app.typeKey("/", modifierFlags: .command)
        let mode = app.buttons["status-bar-editor-mode"]
        soft.check(mode.waitForLabel("== 'Rich Text'", timeout: appWait(size.operationTimeout * 2, before: "the switch to Rich Text")),
            "the mode button never read Rich Text after Cmd-/ (it reads \(mode.label))")
        soft.check(settle(gone: [first]), "the heading \"\(first)\" is still in the block table after the switch")
        soft.check(!sidebarCard(first).exists, "the card \"\(first)\" is back in the Outline after the switch to Rich Text")
        addDocumentChecks("after Delete + the switch to Rich Text (settled)", expect: Phase4bMdExpectation(removed: [firstRange],
            bibliographyExact: size != .article), to: &soft)
        addMarkdownMechanismChecks(from: from, commands: 1, to: &soft)
        shot("md-rich-text-pass-1-after-the-switch")

        // Rich Text: Delete another section, Cmd-Z. Both as before this change.
        guard let secondCard = bringSidebarCardIntoView(second) else { return }
        let rtFrom = chooseSidebarItem(secondCard, item: "Delete Section")
        soft.check(waitForPerformed("sectionDelete", from: rtFrom, timeout: appWait(size.operationTimeout,
            before: "the Rich Text delete performs")), "the Rich Text delete never reached its `performed` line")
        let okLines = logLines(containing: "[STRUCT-TRACE] delete-editor-first opId=", from: rtFrom).filter { $0.text.contains(" ok=true") }
        soft.check(okLines.count == 1,
            "the log has \(okLines.count) `delete-editor-first ... ok=true` line(s) for the Rich Text Delete, expected 1")
        soft.check(logLines(containing: "[MdWrite] structural hold raised", from: rtFrom).isEmpty,
            "a Markdown hold was raised by the Rich Text Delete")
        let undoFrom = traceLinesCount()
        let undo = pressStepRefocusing(redo: false, number: 1, watchToasts: true, what: "Cmd-Z in Rich Text", soft: &soft)
        soft.check(undo.decision == "structural" && undo.structural,
            "the Rich Text Cmd-Z was decided \(undo.decision) (structural ran: \(undo.structural))")
        let undoStart = traceLines(from: undoFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        soft.check(undoStart?.step == "start (quick)", "the Rich Text undo began `\(undoStart?.step ?? "nothing")`, expected `start (quick)`")
        soft.check(undoingToastCount(from: undoFrom) == 0 && !undo.toasts.contains { $0.contains("Undoing") },
            "an \"Undoing...\" message showed: \(undo.toasts)")
        soft.check(waitForCard(second, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(second)\" did not come back after Cmd-Z in Rich Text")
        settle(back: [second])
        addDocumentChecks("after the Rich Text Delete and Cmd-Z (settled)", expect: Phase4bMdExpectation(removed: [firstRange],
            bibliographyExact: size != .article), to: &soft)
        soft.check(logLines(containing: "[MdWrite] structural hold raised", from: rtFrom).isEmpty,
            "a Markdown hold was raised during the Rich Text Delete and Cmd-Z")
        shot("md-rich-text-pass-2-rich-text-delete-and-undo")

        // Back to Markdown: the document is as it was.
        soft.check(switchMode(to: "Markdown"), "the switch back to Markdown failed")
        settle()
        addDocumentChecks("after the switch back to Markdown (settled)", expect: Phase4bMdExpectation(removed: [firstRange],
            bibliographyExact: size != .article), to: &soft)
        soft.check(!sidebarCard(first).exists && sidebarCard(second).exists,
            "the Outline after the switch back: \"\(first)\" present \(sidebarCard(first).exists), \"\(second)\" present"
            + " \(sidebarCard(second).exists)")
        shot("md-rich-text-pass-3-back-in-markdown")
        assertAll(soft, "Markdown Delete + switch to Rich Text; Rich Text Delete + Cmd-Z unchanged, on \(size.identifier)")
    }
}

// MARK: - T-E9 Timing, and Delete then Delete at once

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdTiming_book12() { runTiming(.book12, method: #function) }
    func testMdDeleteThenDelete_book6() { runDeleteThenDelete(.book6, method: #function, hold: false) }
    func testMdDeleteThenDelete_book12() { runDeleteThenDelete(.book12, method: #function, hold: false) }
    func testMdDeleteThenDeleteHeld_book6() { runDeleteThenDelete(.book6, method: #function, hold: true) }

    /// THE EDITOR TURN OF A MARKDOWN DELETE IS A RECORDED RESULT, NOT AN ASSERTION (fix round 3, the judge's ruling in the run notes,
    /// judge-window-verdict.md section 4): on a long book the page's own turn (the click to the first Outline render after it) can take
    /// over a second with nothing shown. That is a KNOWN LIMITATION, measured here and disclosed, not a failure of this test. What is
    /// asserted is only a hard sanity bound: the part of the click's time AFTER the Delete began working (the click to the Outline render,
    /// minus the time it waited behind an earlier Delete, `waitedMs`) is at most 15 s. The result line is
    /// `RESULT EDITOR TURN (known limitation, see the run notes): <n> ms, notices <n>` and carries the fixture tag (the counts).
    func recordEditorTurn(
        _ name: String, _ timing: Phase4bMdDeleteTiming, waitedMs: Int? = nil, to soft: inout Phase4bFlowSoftChecks
    ) {
        let total = timing.clickToOutlineMs
        let own = total.map { $0 - (waitedMs ?? 0) }
        result("EDITOR TURN (known limitation, see the run notes): \(total.map(String.init) ?? "n/a") ms, notices \(timing.finishingNotices)"
            + " [\(name); the click to the first Outline render after it; after the wait behind an earlier Delete: "
            + "\(own.map(String.init) ?? "n/a") ms; \(timing.text)]")
        if let own {
            soft.check(own <= 15_000, "SANITY BOUND: \(name) took \(own) ms from the start of its work to the Outline render (over 15 s)")
        }
    }

    /// A key press's `performed` time is recorded too (the quick Cmd-Z and Cmd-Shift-Z): the figure, the notices in the log, and nothing
    /// asserted, because no press here waited behind a Delete that is proven by the log.
    func recordKeyFigure(_ name: String, figureMs: Int?, notices: Int) {
        result("KEY TIMING (recorded): \(name) key to `performed` \(figureMs.map { "\($0) ms" } ?? "n/a"); progress notices in the log"
            + " \(notices)")
    }

    /// What the log says about two Deletes in a row (`from` is the log index just before the first click): did the SECOND click come BEFORE
    /// the first hold was released (the second Delete waited behind the first), and how long was that wait, by the app's own stamps
    /// (the second click's event time, its `click-start` stamp minus its `age`, to the first release stamp)?
    func deleteOverlap(from index: Int) -> Phase4bMdOverlap {
        tail.poll()
        guard index <= tail.lines.count else { return Phase4bMdOverlap(overlapped: false, waitMs: nil, text: "no log") }
        let window = Array(tail.lines[index...])
        let clicks = window.indices.filter { window[$0].text.contains("click-start") && window[$0].text.contains(" sectionDelete op=") }
        guard clicks.count >= 2 else {
            return Phase4bMdOverlap(overlapped: false, waitMs: nil, text: "\(clicks.count) Delete click-start line(s) in the log, expected 2")
        }
        guard let firstRaised = window.indices.first(where: { window[$0].text.contains("[MdWrite] structural hold raised") }),
              let firstRelease = window[firstRaised...].firstIndex(where: { $0.text.contains("[MdWrite] structural hold released") }) else {
            return Phase4bMdOverlap(overlapped: false, waitMs: nil, text: "the first Delete's hold was never raised and released in the log")
        }
        let overlapped = clicks[1] < firstRelease
        let age = Phase4bDelTraceLine(window[clicks[1]]).flatMap { Phase4bDelTypingParser.intAfter("age=", in: $0.step) } ?? 0
        var waitMs: Int?
        if let clickDate = window[clicks[1]].date, let releaseDate = window[firstRelease].date {
            waitMs = Int(((releaseDate.timeIntervalSince(clickDate)) * 1000).rounded()) + age
        }
        let verdict = overlapped ? "the second click CAME BEFORE the release (it waited behind the first)"
            : "the second click came AFTER the release (no overlap)"
        return Phase4bMdOverlap(
            overlapped: overlapped, waitMs: waitMs,
            text: "the second Delete's click-start is log line \(clicks[1]), the first hold's release is line \(firstRelease): " + verdict)
    }

    /// Polls the `toast-message` element for distinct messages until one holds "Finishing the last change", the first Delete's hold is
    /// released in the log (the wait is over) or `timeout` passes. Returns every distinct message seen.
    func watchForFinishingNotice(from index: Int, timeout: TimeInterval) -> [String] {
        var seen: [String] = []
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let message = toastMessage(), !message.isEmpty, !seen.contains(message) { seen.append(message) }
            if seen.contains(where: { $0.contains("Finishing the last change") }) { break }
            if !logLines(containing: "[MdWrite] structural hold released", from: index).isEmpty { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        return seen
    }

    /// T-E9a. The editor turn of a Markdown Delete on the twelve-chapter book (816 citation groups, 108 footnote marks), the time until the
    /// section leaves the Outline and the screen, and the quick Cmd-Z and Cmd-Shift-Z, from the app's own log. WHAT THE APP EMITS: the
    /// `click-start` line (the mouse event's own time), `[MdWrite] structural hold raised` (the click's work begins), the first
    /// `[SidebarBody]` render after it (the Outline hides the section), `[MdWrite] structural hold released` (the job applied and flushed);
    /// the page writes no success line, so the editor's own turn is bounded by hold raised to the Outline render. The test also prints the
    /// card's time on its own clock (coarse: an accessibility round trip). UNFLATTENED book12.
    func runTiming(_ size: Phase4bDelSize, method: String) {
        let title = size.deleteTitle
        guard startScenario(size, method: method), let range = requireSection(title), placeCaret(),
            let card = bringSidebarCardIntoView(title) else { return }
        var soft = Phase4bFlowSoftChecks()
        let from = chooseSidebarItem(card, item: "Delete Section")
        let seconds = secondsUntilCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline"))
        soft.check(seconds != nil, "the card \"\(title)\" is still in the Outline")
        settle(gone: [title])
        let timing = deleteTiming(from: from)
        result("DELETE TIMING on \(size.identifier): \(timing.text); the card left the Outline after"
            + " \(seconds.map { String(format: "%.1f", $0) } ?? "never") s on the test's clock")
        soft.check(timing.clickType.map { Self.mouseEventTypes.contains($0) } ?? false,
            "the click-start line names \(timing.clickType ?? "no") event, not a mouse event")
        recordEditorTurn("Delete of \(title.prefix(12))", timing, to: &soft)
        let afterDelete = addDocumentChecks("after the delete (settled)", expect: Phase4bMdExpectation(removed: [range]), to: &soft)

        let undoFrom = traceLinesCount()
        let undo = pressStep(redo: false, number: 1, watchToasts: true)
        let undoRun = quickRuns(from: undoFrom, label: "undo").first
        soft.check(undo.structural && undoRun?.quick == true,
            "Cmd-Z was decided \(undo.decision), run \(undoRun.map { $0.quick ? "quick" : "slow" } ?? "none")")
        let undoNotices = undoingToastCount(from: undoFrom) + toastLines(containing: "Finishing the last change", from: undoFrom).count
        recordKeyFigure("Cmd-Z", figureMs: undoRun?.keyToPerformedMs, notices: undoNotices)
        soft.check(waitForCard(title, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card did not come back after Cmd-Z")
        settle(back: [title])

        let redoFrom = traceLinesCount()
        let redo = pressStep(redo: true, number: 2, watchToasts: true)
        let redoRun = quickRuns(from: redoFrom, label: "redo").first
        soft.check(redo.structural && redoRun?.quick == true,
            "Cmd-Shift-Z was decided \(redo.decision), run \(redoRun.map { $0.quick ? "quick" : "slow" } ?? "none")")
        let redoNotices = toastLines(containing: "Redoing", from: redoFrom).count + toastLines(containing: "Finishing the last change",
            from: redoFrom).count
        recordKeyFigure("Cmd-Shift-Z", figureMs: redoRun?.keyToPerformedMs, notices: redoNotices)
        soft.check(waitForCard(title, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves again")),
            "the card did not leave again after Cmd-Shift-Z")
        settle(gone: [title])
        addMarkdownMechanismChecks(from: from, commands: 3, to: &soft)
        addLogChecks(from: from, to: &soft)
        _ = afterDelete
        shot("md-timing")
        assertAll(soft, "Markdown timing: Delete, Cmd-Z, Cmd-Shift-Z, on \(size.identifier)")
    }

    /// T-E9b / T-E9c. "Delete, then Delete at once": two neighbouring chapter cards (both on screen, which is why this test uses a FLATTENED
    /// copy: chapters 1, 3, 5, 6 of book6; 1, 3, 5, 6, 7, 8 of book12) are deleted one straight after the other. Every XCUITest step takes
    /// seconds in the VM (the second click came about 10 s after the first), so WITHOUT the seam the second Delete usually comes after the
    /// first one's job has applied and nothing waits: "second Delete at once" is only PROVABLE with the seam. The HELD variant holds the
    /// first job 30 s (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS` with `..._FIRST_N=1`), and the test reads the log to PROVE the overlap: the second
    /// `click-start` line must come BEFORE the first `[MdWrite] structural hold released` line (a TEST-SETUP failure otherwise, never a
    /// product failure). When the overlap is proven and the second Delete waited more than 2.5 s (always, in the held variant) it must
    /// not be refused and the "Finishing the last change..." notice must show: in the app's log and, in the held variant, in the
    /// `toast-message` element, polled for up to the wait. Both chapters end deleted, the saved rows are the document minus both, and the
    /// editor's text equals the table (Save Version). The editor turn of each Delete is a RECORDED result (`recordEditorTurn`).
    func runDeleteThenDelete(_ size: Phase4bDelSize, method: String, hold: Bool) {
        let firstTitle = size == .book6 ? Self.chapter(5) : Self.chapter(6)
        let secondTitle = size == .book6 ? Self.chapter(6) : Self.chapter(7)
        let env = hold ? [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"] : [:]
        let flat = size == .book6 ? Self.flatBook6 : Self.flatBook12
        guard startScenario(size, method: method, env: env, flat: flat), let firstRange = requireSection(firstTitle),
              let secondRange = requireSection(secondTitle), placeCaret(), let cards = bringIntoView([firstTitle, secondTitle]) else { return }
        var soft = Phase4bFlowSoftChecks()
        let from = chooseSidebarItem(cards[0], item: "Delete Section")
        chooseSidebarItem(cards[1], item: "Delete Section", activate: false)
        let noticeTimeout = hold ? Double(Self.overlapHoldMs) / 1_000 + 15 : 6
        let noticesOnScreen = watchForFinishingNotice(from: from, timeout: noticeTimeout)
        soft.check(waitForCard(firstTitle, present: false, timeout: appWait(size.operationTimeout, before: "the first card leaves")),
            "the card \"\(firstTitle)\" is still in the Outline")
        soft.check(waitForCard(secondTitle, present: false, timeout: appWait(size.operationTimeout * 2, before: "the second card leaves")),
            "the card \"\(secondTitle)\" is still in the Outline: the second Delete was refused or lost")
        soft.check(settle(gone: [firstTitle, secondTitle]), "a deleted chapter is still in the block table once the jobs should have run")

        // Did the second click really come while the first Delete's job was still pending? Read from the log, never assumed.
        let overlap = deleteOverlap(from: from)
        result("OVERLAP of the two Deletes: \(overlap.text); the second Delete's wait behind the first (its click to the first release): "
            + "\(overlap.waitMs.map { "\($0) ms" } ?? "n/a")")
        if hold {
            soft.check(overlap.overlapped, "TEST-SETUP: the second Delete's click did not come before the first hold was released although the "
                + "first job was held \(Self.overlapHoldMs) ms (\(overlap.text)); the premise \"Delete, then Delete at once\" did not happen")
        }
        let first = deleteTiming(from: from, nth: 0)
        let second = deleteTiming(from: from, nth: 1)
        result("DELETE #1 (\(firstTitle.prefix(10))): \(first.text)")
        result("DELETE #2 (\(secondTitle.prefix(10))): \(second.text); toast-message messages seen while it waited: \(noticesOnScreen)")
        recordEditorTurn("Delete #1 \(firstTitle.prefix(10))", first, to: &soft)
        recordEditorTurn("Delete #2 \(secondTitle.prefix(10))", second, waitedMs: overlap.overlapped ? second.clickToHoldRaisedMs : nil,
            to: &soft)

        // The second Delete waited behind the first (proven by the log): the notice must have shown.
        if overlap.overlapped, let waitMs = overlap.waitMs, hold || waitMs > 2_500 {
            soft.check(second.finishingNotices >= 1, "the second Delete waited \(waitMs) ms behind the first (its click came before the first "
                + "hold's release) and no \"Finishing the last change\" notice was written to the log")
            if hold {
                soft.check(noticesOnScreen.contains { $0.contains("Finishing the last change") },
                    "the toast-message element never showed \"Finishing the last change\" while the second Delete waited \(waitMs) ms "
                    + "(messages seen: \(noticesOnScreen))")
            }
        }
        soft.check(first.holdsRaised == 2, "\(first.holdsRaised) hold(s) raised for two Deletes")
        soft.check(failureLine(from: from) == nil, "the app logged a refusal or failure: \(failureLine(from: from) ?? "")")
        soft.check(!app.dialogs.firstMatch.exists && !app.sheets.firstMatch.exists, "an alert or sheet is on screen after the two Deletes")
        let post = addDocumentChecks(
            "after both Deletes (settled)", expect: Phase4bMdExpectation(removed: [firstRange, secondRange]), to: &soft)
        addMarkdownMechanismChecks(from: from, commands: 2, to: &soft)
        addLogChecks(from: from, checkPushes: !hold, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after both Deletes", to: &soft)
        shot("md-delete-then-delete\(hold ? "-held" : "")")
        assertAll(soft, "Markdown: Delete, then Delete at once\(hold ? " (first job held)" : ""), on \(size.identifier) (flattened)")
    }
}
