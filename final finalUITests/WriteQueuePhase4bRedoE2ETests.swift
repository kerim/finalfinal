//
//  WriteQueuePhase4bRedoE2ETests.swift
//  final finalUITests
//
//  bt task t-14f908b4 (parent t-94369a83), ROUND C: THE REDO AFTER A STRUCTURAL OPERATION, proven in the real app, in BOTH editors.
//  The defect: Duplicate Section, a Version History restore or (Markdown) a sidebar drag, then typing inside the new / moved text, then Cmd-Z
//  until the typing and the operation are both undone, then Cmd-Shift-Z until both are redone: the operation came back but the typing did
//  not (in Markdown it could even land inside the next chapter's heading line). The fix keeps the editor's redo steps aside at the undo and
//  puts them back once the redo has landed (web/milkdown/src/redo-branch.ts, web/codemirror/src/redo-branch.ts). Plan and amendments:
//  .claude/superdev/redo-after-structural-op/ (plan-v1.md section 3, plan-v1-amendments.md "Round C", C8; the scenario-to-claim map is
//  e2e-map.md in the same folder).
//
//  CLASS NAME: after the TASK (vmtest's retry-refusal streak is keyed by class and method name across worktrees). The class inherits the
//  harness of WriteQueuePhase4bDeleteE2ETests.swift (`Phase4bDelHarness`: launch, seeding, the app-log follower, the sidebar driving, the
//  evidence writer) and uses the pure helpers of WriteQueuePhase4bDeleteFlowE2ETests.swift (`Phase4bFlow`, `Phase4bFlowRow`,
//  `Phase4bFlowWalk`, `Phase4bFlowSoftChecks`) and the static seeds of WriteQueuePhase4bStructuralQueueE2ETests.swift (`withPlainLines`) and
//  WriteQueuePhase4bMarkdownEFE2ETests.swift (`flattening`); it changes nothing in any of them. The behaviour classes' own instance helpers
//  live in THEIR final classes, so the few this class needs are copied here (as the earlier classes did). It is ONE new permanent file
//  (scripts/e2e-hygiene.sh allows one per branch), so it disables the file-length rule like every other Phase 4b e2e file.
//
//  THE DOCUMENTS (generated, never a manuscript; every note starts with the fixture tag `[<size> W<words> S<sections> C<citation groups>
//  F<footnote marks> L<characters>]`, and `noteCounts()` adds the block, footnote-reference, footnote-definition and citation-bracket counts
//  read from the DATABASE):
//    article  x1 chapter:   58,764 characters, 68 citation groups,   9 footnote marks (60+ resolving citations, footnotes, comment / task /
//                           reference marks, a block quote, Chinese text, a generated bibliography)
//    book6    x6 chapters: 349,810 characters, 408 citation groups,  54 footnote marks
//  Every top-level chapter holds nine footnote references; the sections "N.6 Conclusion" hold NONE (four paragraphs with citations), so a
//  Duplicate of one needs no footnote renumber and the Cmd-Z / Cmd-Shift-Z counts are EXACT. The section copied in the exact-count tests:
//    article  Rich Text and Markdown   "1.6 Conclusion"   (footnote-free: the generator puts the nine footnotes on paragraphs 4, 10, ..., 52 of
//                                                          60; the Conclusion is paragraphs 56-59; the heading after its copy is "# Notes")
//    book6    Rich Text                "5.6 Conclusion"   (the heading after its copy is "# Chapter 6: ...")
//    book6    Markdown                 "3.6 Conclusion"   (the heading after its copy is "# Chapter 4: The Quiet Archive and Its Ledgers": the
//                                                          line the Markdown defect used to split)
//  Two plain lines are seeded directly under the copied section's heading ("Dup01 line of the fixture document.", "Dup02 ..."), as the
//  other duplicate tests do: the copy repeats them, and the COPY's own are found by their place on screen after the sidebar's click has
//  scrolled the editor to the copy's heading (`visibleLeaf`, the last fully visible one).
//
//  THE TESTS (map: e2e-map.md; "exact" = the Cmd-Z / Cmd-Shift-Z counts are fixed by the claim and asserted, "polled" = the keys are
//  pressed one at a time until the app's own keydown line says the operation was reached, at most 6, and the count used is reported)
//    testRtDuplicateTypeUndoRedo_{article,book6}      exact   Rich Text: Duplicate, type in the copy, Cmd-Z x2 (sentence, copy), Cmd-Shift-Z x2
//    testMdDuplicateTypeUndoRedo_{article,book6}      exact   Markdown: the same; the heading line after the copy is unchanged; book6 also
//                                                             asserts around the SECOND Cmd-Shift-Z (M8) that the Dup02 neighbour stays
//                                                             within 80 pt and that the caret is in the typed line
//    testRtDuplicateTwoCycles_book6                   exact   Rich Text: the four keys twice
//    testMdDuplicateTwoCycles_book6                   exact   Markdown: the four keys twice
//    testRtDuplicateFootnoteChapter_book6             polled  Rich Text: Duplicate a whole footnoted chapter, type at once, undo / redo polled
//    testMdDuplicateFootnoteChapter_book6             polled  Markdown: the same; no heading line changed
//    testRtRestoreEntireProjectTypeUndoRedo_book6     polled  Rich Text: Save Version, edit, Restore Entire Project, type, undo / redo polled
//    testMdRestoreEntireProjectTypeUndoRedo_book6     polled  Markdown: the same (the old-body restore)
//    testMdDragTypeUndoRedo_book6                     polled  Markdown: drag "Chapter 5" above "Chapter 4", type inside it, undo / redo polled
//    testMdDuplicateTypeUndoRedo_book12               exact   Markdown on the twelve-chapter book; records the put-back's cost (ms=K)
//    testMdDuplicateFootnoteScrollKeep_{book6,book12} polled  Markdown, footnoted chapter: scroll away after the first Cmd-Z, the page must not
//                                                             jump when the footnote renumber lands (armed only if the renumber is late);
//                                                             after the copy is undone the page is scrolled down from the document's
//                                                             first screen and the page's position after the STRUCTURAL Cmd-Shift-Z (the
//                                                             redo and the put-back's install) is only REPORTED (the series of readings,
//                                                             not asserted); the last, plain Cmd-Shift-Z must show the typing
//    testRtDuplicateSharedFootnoteDefinitionTyping_book6     polled  Rich Text: click the copy's first footnote reference, type in
//                                                             the footnote definition in the Notes (the one the copy SHARES with the original:
//                                                             the app keeps the first appearance of each label), undo / redo polled; the
//                                                             sentence is back in that definition, end state only
//  The first test of each exact pair that runs on the article types and presses the keys STRAIGHT AFTER the typing (no wait for the saved
//  rows); the book6 test and the second cycle wait for the rows to agree first (the amendments ask for both).
//
//  WAITS: every wait is a CONDITION (a log line, a database row, the sidebar, the accessibility tree, a status-bar label); the keys of one
//  cycle are pressed straight after each other. Typing is user-origin (typeText / typeKey). Rows are read from the block table only after a
//  poll, never straight after a command. A typed line longer than about 40 characters WRAPS to two visual lines in the VM's editor column, so
//  the typed sentence is looked for in the joined text of the editor's runs (`sentenceOnScreen`), never as one exact leaf.
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; several --scope flags make one run, never a comma list):
//    scripts/vmtest/vmtest run --detach --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bRedoE2ETests/testRtDuplicateTypeUndoRedo_article"
//

// swiftlint:disable file_length
import XCTest

// MARK: - Which editor, what is typed

/// The editor a scenario runs in.
enum Phase4bRedoEditor {
    case richText
    case markdown

    var name: String { self == .richText ? "Rich Text" : "Markdown" }
    /// The typed sentence: short, no character the editor transforms (no quote, dash, asterisk, underscore, slash, bracket).
    var sentence: String { self == .richText ? "Typed in Rich Text." : "Typed in the copy." }
    var sentenceWords: Int { sentence.split(separator: " ").count }
}

/// One Cmd-Z or Cmd-Shift-Z as the editor's own `[UnifiedUndo] keydown` line reports it.
struct Phase4bRedoPress {
    let number: Int
    let redo: Bool
    /// `fallthrough` (a plain text step of the editor's own history), `structural`, `swallow` (held behind a running one), or `none` when the
    /// editor wrote no keydown line within 15 s (the key reached no editor).
    let decision: String
    let undoDepth: Int?
    let redoDepth: Int?
    /// For a structural press: its `performed` line arrived (false on a logged failure or the operation timeout).
    let performed: Bool
    /// The editor's keydown line from its `[UnifiedUndo]` marker on.
    let line: String

    var isStructural: Bool { decision == "structural" || decision == "swallow" }
    /// The editor held the press behind a request that was still in flight (its latch); it is routed when Swift's reply arrives. Routed
    /// structurally, it has a `performed` line of its own; run as a text step, it leaves no log line.
    var held: Bool { decision == "swallow" }

    var summary: String {
        let ending = held
            ? (performed ? ", held, then performed" : ", held, no sequence of its own")
            : (performed ? ", performed" : ", NOT performed")
        return "press \(number) (\(redo ? "redo" : "undo")): \(decision), undo depth \(undoDepth.map(String.init) ?? "n/a"), "
            + "redo depth \(redoDepth.map(String.init) ?? "n/a")" + (isStructural ? ending : "")
    }
}

/// What the editor's keydown line says about one press (read straight from the log, for the exact-count tests).
struct Phase4bRedoKey {
    let decision: String
    let undoDepth: Int?
    let redoDepth: Int?
    let text: String
}

/// A Duplicate Section that has been made and typed into: what the following checks compare against.
struct Phase4bRedoDup {
    let title: String
    let copyTitle: String
    let editor: Phase4bRedoEditor
    /// The document before the duplicate (the text rows of `pre`).
    let before: [Phase4bFlowRow]
    /// The document with the copy and the sentence typed at the end of the copy's Dup01 line.
    let withTyping: [Phase4bFlowRow]
    /// The app-log index just before the Duplicate click.
    let from: Int
}

/// A sidebar drag worked out by `prepareDrag` but not yet pressed: the cards (the dragged one first, then the one dropped on), the point
/// the pointer ends at, and the title of the card dropped on.
struct Phase4bRedoDrag {
    let cards: [XCUIElement]
    let dropPoint: XCUICoordinate
    let dropOn: String
}

// MARK: - The test class

/// The redo after a structural operation, in the real app. See the file header.
final class WriteQueuePhase4bRedoE2ETests: Phase4bDelHarness {
    /// The saved document right after the load settled, before the scenario's first command.
    var pre: [Phase4bFlowRow] = []
    /// How many versions this test has saved (each needs its own name).
    var versionSaves = 0

    static let dupOnePrefix = "Dup01"
    static let dupTwoPrefix = "Dup02"
    static var dupLineOne: String { dupOnePrefix + " line of the fixture document." }
    static var dupLineTwo: String { dupTwoPrefix + " line of the fixture document." }
    static let moveLine = "Move05 line of the fixture document."
    /// The most presses a polled loop makes (a text step or two, the structural press, a footnote renumber's own step).
    static let pressCap = 6
    /// How far (points) a paragraph on screen may sit from where it was: while the footnote renumber of `runFootnoteScrollKeep` lands (its
    /// watch window), and (the typed line's neighbour) around the second Cmd-Shift-Z of the exact-count tests. NOT asserted anywhere else:
    /// a redo reveals what it restored (CodeMirror scrolls the restored selection or the typed line into view), so the page's position
    /// after the structural redo of `runFootnoteScrollKeep` is only reported. One wrapped line is about 24.
    static let scrollTolerance: CGFloat = 80
    static let versionName = "Redo base"
    /// Typed after the version was saved; the restore takes it away again. No character the editor transforms.
    static let editMarker = "EDITEDRDO"

    static func chapter(_ number: Int) -> String { "Chapter \(number): The Quiet Archive and Its Ledgers" }

    /// The seed hook: the two Dup lines as their own paragraphs directly under the heading `title` of level `level`.
    static func dupSeed(under title: String, level: Int) -> (Phase4bDoc) -> Phase4bDoc {
        { generated in
            WriteQueuePhase4bStructuralQueueE2ETests.withPlainLines(
                generated, under: title, level: level, lines: [dupLineOne, dupLineTwo])
        }
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4bRedoE2ETests {
    /// Begins the method, seeds (flattened when `flat` is not empty) and launches the document, reads the saved document, logs the fixture
    /// counts, and (Markdown) switches the editor with Cmd-/. False after a reported failure.
    func startScenario(
        _ size: Phase4bDelSize, method: String, editor: Phase4bRedoEditor, flat: [Int] = [], seed: ((Phase4bDoc) -> Phase4bDoc)? = nil
    ) -> Bool {
        begin(method: method, size: size)
        if !flat.isEmpty, let generated = doc {
            let flattened = WriteQueuePhase4bMarkdownEFE2ETests.flattening(generated, chapters: flat)
            doc = flattened
            note("SEED: a FLATTENED COPY, chapters \(flat) have no sub-headings; \(flattened.counts.reportLine)")
        } else {
            note("SEED: the generated document, NOT flattened (the full outline)")
        }
        if let seed, let current = doc {
            let seeded = seed(current)
            doc = seeded
            note("SEED: a seed hook was applied to it; \(seeded.counts.reportLine)")
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
        guard editor == .richText || switchMode(to: "Markdown") else { return false }
        newPhase()
        return true
    }

    /// Each phase of a test gets the size's whole wall-clock budget: `capped(...)` shortens every wait to a 5 s floor once the budget is spent.
    func newPhase() { startedAt = Date() }

    @discardableResult
    func noteCounts() -> String {
        let walk = Phase4bFlowWalk(rows: pre)
        let citations = pre.reduce(0) { $0 + Phase4bGenerator.matches(#"\[-?@"#, in: $1.fragment).count }
        let line = "COUNTS read from the database: \(pre.count) block rows, \(walk.refs.count) footnote reference(s), "
            + "\(walk.definitions.count) footnote definition(s), \(citations) citation bracket(s) in the rows, "
            + "\(pre.filter(\.isNotes).count) Notes row(s), \(pre.filter(\.isBibliography).count) Bibliography row(s), "
            + "\(sectionsInDatabase) section row(s)"
        note(line)
        return line
    }

    /// Switches the editor to `wanted` ("Markdown" or "Rich Text") with Cmd-/, the shortcut of the View menu's "Switch to ..." item, pressed
    /// ONCE, then waits for the badge (a condition).
    func switchMode(to wanted: String) -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        if mode.label != wanted {
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            guard mode.waitForLabel("== '\(wanted)'", timeout: appWait(size.operationTimeout * 2, before: "the mode button reads \(wanted)")) else {
                fail("the editor-mode button never reported \(wanted) after the toggle keystroke (it reads \(mode.label))")
                return false
            }
        }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: \(wanted); the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }
}

// MARK: - Reading the saved document

extension WriteQueuePhase4bRedoE2ETests {
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

    /// The row of `pre` that is `line`, or a reported TEST-SETUP failure.
    func requireRow(_ line: String) -> Int? {
        guard let row = pre.firstIndex(where: { $0.fragment == line }) else {
            fail("TEST-SETUP: the loaded document has no row \"\(line)\"")
            return nil
        }
        return row
    }

    var preUserRows: [Phase4bFlowRow] { pre.filter { !$0.isManaged } }
    var preManagedRows: [Phase4bFlowRow] { pre.filter(\.isManaged) }

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

    func waitForSentenceGone(_ sentence: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is looked for to be gone from the database"))
        repeat {
            if blocksContaining(sentence) == 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// Waits until the block table holds exactly `wanted` rows with the sentence.
    func waitForSentenceCount(_ sentence: String, equalTo wanted: Int, timeout: TimeInterval) -> Int {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "\"\(sentence)\" is counted in the database"))
        var count = blocksContaining(sentence)
        while count != wanted, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            count = blocksContaining(sentence)
        }
        return count
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

    func recordDifferences(_ what: String, _ label: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        rowDifferenceLog.append("[\(what)] \(label)\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
    }

    /// The text rows the document must hold once the section `title` has been duplicated (nil: no duplicate): `pre` without the Notes and
    /// Bibliography rows and without `removed`, the section's rows copied right after the section with the copy's heading reading
    /// "<heading> copy". `originalTyped` replaces the whole text of original rows (row number in `pre`), `copyTyped` the copy's rows (offset
    /// in the section, 0 is the heading). The hand-worked answer ("a copy of the section, right after it"), not a reading of the app.
    func expectedUserRows(
        duplicating title: String?, removed: [Range<Int>] = [], originalTyped: [Int: String] = [:], copyTyped: [Int: String] = [:]
    ) -> [Phase4bFlowRow]? {
        let removedIndexes = Set(removed.flatMap { Array($0) })
        var range: Range<Int>?
        if let title {
            guard let found = section(title), found.allSatisfy({ !removedIndexes.contains($0) }) else { return nil }
            range = found
        }
        func replaced(_ base: Phase4bFlowRow, with text: String?) -> Phase4bFlowRow {
            guard let text else { return base }
            return Phase4bFlowRow(type: base.type, isNotes: false, isBibliography: false, fragment: text)
        }
        var rows: [Phase4bFlowRow] = []
        for index in pre.indices where !pre[index].isManaged && !removedIndexes.contains(index) {
            rows.append(replaced(pre[index], with: originalTyped[index]))
            if let range, index == range.upperBound - 1 {
                for (offset, source) in pre[range].enumerated() {
                    let base = offset == 0
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
    /// reading order, one definition each); it is off for a document that holds a copy of a FOOTNOTED section or a moved chapter.
    func rowProblems(_ post: [Phase4bFlowRow], what: String, expectedUser: [Phase4bFlowRow], managed: [Phase4bFlowRow]?, walk: Bool) -> [String] {
        var found: [String] = []
        let expected = expectedUser.enumerated().map { (row: $0.offset, value: $0.element) }
        let actual = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expected, actual: actual, exact: false)
        recordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        if let managed {
            let expectedManaged = managed.enumerated().map { (row: $0.offset, value: $0.element) }
            let actualManaged = post.enumerated().filter { $0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
            let managedLines = Phase4bFlow.rowDifferences(expected: expectedManaged, actual: actualManaged, exact: true)
            recordDifferences(what, "Notes / Bibliography rows", managedLines)
            found += managedLines.map { "the Notes / Bibliography rows are not those expected: \($0)" }
        }
        if walk { found += Phase4bFlowWalk(rows: post).problems.map { "footnotes: \($0)" } }
        return found
    }

    /// Reads the block table and adds every problem of `rowProblems` to `soft`. Returns the rows read.
    @discardableResult
    func addRowChecks(
        _ what: String, expectedUser: [Phase4bFlowRow], managed: [Phase4bFlowRow]?, walk: Bool = true, to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        let post = readRows()
        let problems = rowProblems(post, what: what, expectedUser: expectedUser, managed: managed, walk: walk)
        note("\(what): \(post.count) block rows (\(pre.count) before); \(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// The heading lines as the block table holds them now, trimmed (Notes and Bibliography left out).
    func headingFragmentsInDatabase() -> [String] {
        FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT markdownFragment FROM block WHERE blockType = 'heading' AND isNotes = 0 AND isBibliography = 0 "
                + "ORDER BY sortOrder, id;")
            .split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func headingLines(of rows: [Phase4bFlowRow]) -> [String] {
        rows.filter { !$0.isManaged && $0.headingLevel != nil }.map { $0.fragment.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    /// THE USER-VISIBLE CLAIM "no heading line was changed": the heading lines of the block table equal the hand-worked list. A typed
    /// sentence that landed inside a heading line shows up here as a heading that is not what it should be.
    func addHeadingChecks(_ what: String, expectedRows: [Phase4bFlowRow], to soft: inout Phase4bFlowSoftChecks) {
        let expected = headingLines(of: expectedRows)
        let found = headingFragmentsInDatabase()
        note("\(what): \(found.count) heading line(s), \(expected.count) expected; first difference: \(firstDifference(expected, found))")
        soft.check(found == expected, "\(what): the heading lines are not exactly the expected ones, a heading line may have been damaged "
            + "(\(firstDifference(expected, found)))")
    }
}

// MARK: - Reading the app's log

extension WriteQueuePhase4bRedoE2ETests {
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

    func traceLinesCount() -> Int {
        tail.poll()
        return tail.lines.count
    }

    func performedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step == "performed" }.count
    }

    func startedCount(_ label: String, from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && $0.label == label && $0.step.hasPrefix("start") }.count
    }

    func quickRuns(from index: Int, label: String? = nil) -> [Phase4bQuRun] {
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        let all = Phase4bQuLog.runs(in: tail.lines[index...])
        return label.map { name in all.filter { $0.label == name } } ?? all
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

    /// The editor's `[UnifiedUndo] keydown direction=<direction>` lines since `index`, parsed.
    func keydowns(_ direction: String, from index: Int) -> [Phase4bRedoKey] {
        logLines(containing: "[UnifiedUndo] keydown direction=\(direction) ", from: index).map { line in
            Phase4bRedoKey(
                decision: Phase4bDelTypingParser.word(after: "decision=", in: line.text) ?? "none",
                undoDepth: Phase4bDelTypingParser.intAfter("undoDepth=", in: line.text),
                redoDepth: Phase4bDelTypingParser.intAfter("redoDepth=", in: line.text), text: line.text)
        }
    }

    /// Waits (a condition on the app's log) until `count` keydown lines of `direction` exist since `index`; returns what is there.
    func waitForKeydowns(_ direction: String, count: Int, from index: Int, timeout: TimeInterval) -> [Phase4bRedoKey] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var found = keydowns(direction, from: index)
        while found.count < count, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            found = keydowns(direction, from: index)
        }
        return found
    }

    /// Plain whole-document pushes of the editor's content, which would wipe typing and its undo history.
    func plainPushCount(from index: Int) -> Int { logLines(containing: "[SYNC-DIAG:UpdateNSView] PUSHING", from: index).count }

    func beepLines(from index: Int) -> [String] { logLines(containing: "beeping", from: index).map(\.text) }

    func toastLines(containing needle: String, from index: Int) -> [String] {
        logLines(containing: needle, from: index).map(\.text).filter { $0.contains("[toast] show") }
    }

    /// The warning toast of a queued press that could not be carried out.
    func droppedPressToasts(from index: Int) -> [String] { toastLines(containing: "could not be carried out", from: index) }

    /// Every line since `index` that says an editor-first command took another road than the one under test. Rich Text: the editor-first
    /// roads of Duplicate and the restores must not fall back. Markdown: Duplicate and the restores take the old body by design, so only the
    /// lines that say a job or the page FAILED count there.
    func fallbackEvidence(from index: Int, editor: Phase4bRedoEditor) -> [String] {
        let failures = [
            "the job did not apply", "could not be reserved", " threw after dispatch=", "page refused or failed", "the settle gave up waiting",
            "step 8: no live text"
        ]
        let markers = editor == .markdown ? failures : failures + [
            "[EF-STRUCT]", "old path for this press", "refused by the editor", "refused (quick)", "refused (markdown"
        ]
        tail.poll()
        guard index <= tail.lines.count else { return [] }
        return tail.lines[index...].map(\.text).filter { text in markers.contains { text.contains($0) } }.map { String($0.suffix(160)) }
    }

    /// The editor's success lines of an editor-first operation since `index`: `[STRUCT-TRACE] <label>-editor-first opId=<id8> ok=true`.
    func editorFirstOkLines(_ label: String, from index: Int) -> [String] {
        logLines(containing: "[STRUCT-TRACE] \(label)-editor-first opId=", from: index).map(\.text).filter { $0.contains(" ok=true") }
    }

    /// `[STRUCT-TRACE] replace-editor-first mode=<mode> opId=.. ok=true|false` (a restore's click) since `index`.
    func replaceEditorFirstLines(mode: String, succeeded: Bool, from index: Int) -> [String] {
        let verdict = succeeded ? " ok=true" : " ok=false"
        return logLines(containing: "[STRUCT-TRACE] replace-editor-first mode=\(mode) opId=", from: index).map(\.text).filter { $0.contains(verdict) }
    }

    /// THE MECHANISM LINE OF THE FIX: the put-back after a structural redo. Rich Text writes `<label> opId=<id8> redoPutBack=<n>` (or
    /// `redo put-back skipped: <reason>`), Markdown writes `markdown-swap redo put-back events=<n> dropped=<m>` (or `skipped` / `threw`).
    func putBackLines(editor: Phase4bRedoEditor, from index: Int) -> (done: [String], skipped: [String]) {
        let lines = logLines(containing: "[STRUCT-TRACE]", from: index).map(\.text)
        switch editor {
        case .richText:
            return (lines.filter { $0.contains(" redoPutBack=") }, lines.filter { $0.contains("redo put-back skipped") })
        case .markdown:
            return (lines.filter { $0.contains("redo put-back events=") },
                    lines.filter { $0.contains("redo put-back skipped") || $0.contains("redo put-back threw") })
        }
    }

    /// The checks every test makes about the app's log since `index`: the put-back ran `expectedPutBacks` time(s) and never skipped (when
    /// the redo went the road that has one), no fallback line, no beep (a Cmd-Shift-Z with nothing to redo beeps: the defect's fingerprint),
    /// no dropped-press toast, and in Rich Text no whole-document push.
    func addLogChecks(
        from index: Int, editor: Phase4bRedoEditor, putBacks expected: Int?, checkBeeps: Bool = true, to soft: inout Phase4bFlowSoftChecks
    ) {
        let putBack = putBackLines(editor: editor, from: index)
        let fallbacks = fallbackEvidence(from: index, editor: editor)
        let pushes = plainPushCount(from: index)
        result("MECHANISM (\(editor.name)): put-back line(s) \(putBack.done.count) \(putBack.done.prefix(2).map { String($0.suffix(90)) }); "
            + "put-back skipped / threw line(s) \(putBack.skipped.count) \(putBack.skipped.prefix(2).map { String($0.suffix(140)) }); "
            + "fallback line(s) \(fallbacks.count); whole-document pushes \(pushes); failure line: \(failureLine(from: index) ?? "none")")
        if editor == .markdown {
            // The cost of the Markdown put-back (`ms=K`, the page's own clock) and the redo steps the undo set aside (`setAside=N`): recorded
            // beside the fixture tag for every Markdown run, no time bound asserted. K must be present on every put-back line.
            let millis = putBack.done.compactMap { Phase4bDelTypingParser.intAfter(" ms=", in: $0) }
            let setAsides = logLines(containing: "markdown-swap redo carry", from: index)
                .compactMap { Phase4bDelTypingParser.intAfter("setAside=", in: $0.text) }
            result("PUT-BACK COST (Markdown, \(size.identifier)): put-back ms=\(millis) (\(putBack.done.count) put-back line(s)); "
                + "the undo carry set aside setAside=\(setAsides) redo step(s) (recorded, no time bound asserted)")
            soft.check(millis.count == putBack.done.count,
                "\(putBack.done.count - millis.count) of \(putBack.done.count) put-back line(s) carry no `ms=` figure")
        }
        if let expected {
            soft.check(putBack.done.count == expected,
                "\(putBack.done.count) put-back line(s) in the log, expected \(expected): the redo did not put the redo steps back that many times")
        }
        soft.check(putBack.skipped.isEmpty, "the put-back was skipped or threw: \(putBack.skipped.prefix(2))")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        if editor == .richText { soft.check(pushes == 0, "\(pushes) `[SYNC-DIAG:UpdateNSView] PUSHING` line(s) (must be 0 in Rich Text)") }
        if checkBeeps {
            let beeps = beepLines(from: index)
            soft.check(beeps.isEmpty, "the editor beeped \(beeps.count) time(s) (a press that found nothing to do): \(beeps.prefix(2))")
        }
        let dropped = droppedPressToasts(from: index)
        soft.check(dropped.isEmpty, "the warning toast \"Some undo or redo presses could not be carried out\" showed: \(dropped)")
    }
}

// MARK: - Driving the app

extension WriteQueuePhase4bRedoE2ETests {
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

    /// Types straight into whatever has the keyboard focus (the editor, where the caret was placed). One `typeText` call: a verified retype
    /// would wait, and these scenarios are about what happens when the keys come right after the typing.
    func typeNow(_ text: String) {
        // e2e-lint: allow raw-typetext -- typed at once on purpose; the saved document is what the scenario checks, not the keystrokes.
        app.typeText(text)
    }

    func shot(_ name: String) { attachEvidenceScreenshot(app.screenshot(), name: "\(name)-\(size.identifier)") }

    /// Clicks the sidebar card (the UX contract: clicking navigates; the editor scrolls to the section). Coordinate click: cards are
    /// non-hittable by design.
    func navigate(to card: XCUIElement) {
        app.activateAndWaitForForeground()
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// The exact-value leaf of the plain line `line` that lies fully inside the editor's visible band (the LAST one when several do: a copy
    /// sits after its original), found within `timeout`. A copy repeats its original's text, so the text alone cannot name it; its place on
    /// screen does, once the sidebar's click has scrolled the editor to the copy's heading.
    func visibleLeaf(_ line: String, timeout: TimeInterval) -> XCUIElement? {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let editor = app.editorArea.frame
            var visible: [XCUIElement] = []
            for index in 0..<leaves.count {
                let leaf = leaves.element(boundBy: index)
                guard leaf.exists else { continue }
                let frame = leaf.frame
                if frame.width > 0, frame.minY >= editor.minY + 24, frame.maxY <= editor.maxY - 24 { visible.append(leaf) }
            }
            if let last = visible.last {
                app.waitForStableFrame(last)
                if last.exists { return last }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return nil
    }

    /// Puts the caret at the end of the on-screen plain line `line` (a one-line paragraph of `words` words) and confirms it through the status
    /// bar's selection count. Fails the test (and returns false) when the line cannot be found or the caret cannot be confirmed: typing into
    /// an unknown place would make every later assertion mean nothing. Never falls back to a blind click.
    func placeCaretAtEndOfVisibleLine(_ line: String, words: Int, timeout: TimeInterval) -> Bool {
        guard let leaf = visibleLeaf(line, timeout: timeout) else {
            fail("no leaf with the exact text \"\(line)\" is fully on screen after \(Int(timeout)) s (editor frame \(app.editorArea.frame))")
            return false
        }
        let frame = leaf.frame
        app.activateAndWaitForForeground()
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        let probe = app.caretSelectionProbe(expectedWords: words, atEnd: true)
        note("CARET at the end of the on-screen \"\(line)\" (leaf \(Self.describeFrame(frame))): probe \(probe)")
        guard probe == "ok" else {
            fail("the caret could not be confirmed at the end of the on-screen \"\(line)\" (probe: \(probe); leaf \(Self.describeFrame(frame)))")
            return false
        }
        return true
    }

    /// The editor's text as the accessibility tree shows it: the runs joined with one space, every run of whitespace (a no-break space
    /// included) collapsed to a single space. A typed line that WRAPS is two runs, so a sentence is looked for in this joined text.
    func joinedScreenText() -> String? {
        guard let values = app.editorStaticTextValues() else { return nil }
        return values.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Waits (a condition) until the editor's text does (`present`) or does not hold `sentence`; nil when no snapshot could be read.
    func waitForSentenceOnScreen(_ sentence: String, present: Bool, timeout: TimeInterval) -> Bool? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var read = false
        repeat {
            if let text = joinedScreenText() {
                read = true
                if text.contains(sentence) == present { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return read ? false : nil
    }

    /// One Cmd-Z (or Cmd-Shift-Z), then only as much waiting as the press needs, told by the app's own log: the editor writes a
    /// `[UnifiedUndo] keydown` line for every press before it acts on it (polled every 0.1 s, at most 15 s; none: decision `none`); a
    /// `structural` decision means a structural undo or redo is coming, and its `performed` line is waited for as long as the operation
    /// timeout; a `swallow` (the press was held behind a request still in flight) is waited for up to 40 s. A text step (`fallthrough`)
    /// returns at once.
    func pressAndRead(redo: Bool, number: Int, activate: Bool = true) -> Phase4bRedoPress {
        let label = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        if activate { app.activateAndWaitForForeground() }
        if redo { pressRedo() } else { pressUndo() }
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
            performed = waitForPerformed(
                label, from: from, timeout: appWait(size.operationTimeout * 2, before: "the \(label) performed line of press \(number)"))
        } else if decision == "swallow" {
            // Held behind a request still in flight: routed when Swift's reply arrives, structurally (a `performed` line of its own) or as a
            // text step (no log line), so the wait is short.
            performed = waitForPerformed(
                label, from: from, timeout: appWait(40, before: "the held \(label) press \(number) is routed"))
        }
        let shown = text.flatMap { full in full.range(of: "[UnifiedUndo]").map { String(full[$0.lowerBound...]) } } ?? "no keydown line"
        return Phase4bRedoPress(
            number: number, redo: redo, decision: decision,
            undoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("undoDepth=", in: $0) },
            redoDepth: text.flatMap { Phase4bDelTypingParser.intAfter("redoDepth=", in: $0) },
            performed: performed, line: shown)
    }

    /// Cmd-Z, one press at a time, until a STRUCTURAL press has run (the operation is undone), at most `pressCap`. A press the editor did
    /// not decide (`none`) ends the loop: the key reached no editor.
    func undoUntilStructural() -> [Phase4bRedoPress] {
        var presses: [Phase4bRedoPress] = []
        for number in 1...Self.pressCap {
            let press = pressAndRead(redo: false, number: number)
            presses.append(press)
            result(press.summary)
            if press.isStructural || press.decision == "none" { break }
        }
        return presses
    }

    /// Cmd-Shift-Z, one press at a time, until the editor's text redo has used its last step (a text press with redo depth 1) or there is
    /// nothing left to redo (a text press with redo depth 0: the defect), at most `pressCap`. The first press is the structural redo.
    func redoUntilTypingBack() -> [Phase4bRedoPress] {
        var presses: [Phase4bRedoPress] = []
        for number in 1...Self.pressCap {
            // The second press is made straight after the first press's click sequence performed: no foreground check in between.
            let press = pressAndRead(redo: true, number: number, activate: number == 1)
            presses.append(press)
            result("\(press.summary); the editor's line: \(press.line)")
            if press.decision == "none" { break }
            // A press held by the editor's latch (the structural redo's reply is still on its way) runs its text step after the reply: it is
            // the last press needed when one redo step was left when it was made.
            if press.decision == "fallthrough" || press.held, (press.redoDepth ?? 0) <= 1 { break }
        }
        return presses
    }

    /// Reports the presses of a polled loop and attaches them.
    func reportPresses(_ name: String, _ presses: [Phase4bRedoPress]) {
        let text = presses.map(\.summary).joined(separator: "\n")
        let depths = presses.map { "\($0.decision) u\($0.undoDepth.map(String.init) ?? "-") r\($0.redoDepth.map(String.init) ?? "-")" }
        result("\(name): \(presses.count) press(es) used (cap \(Self.pressCap)): \(depths)")
        attachText("presses-\(methodName)-\(name.replacingOccurrences(of: " ", with: "-")).txt", text)
    }
}

// MARK: - Duplicate Section, then the caret in the copy, then the typing

extension WriteQueuePhase4bRedoE2ETests {
    /// Duplicate Section on the card `title` (the caller seeded the two Dup lines under it), wait for the copy's card and for the click's
    /// own sequence to finish, and scroll the editor to the copy (the sidebar's navigation). `copyTyped` are the copy's rows (offset in the
    /// section, 0 is the heading) the scenario is going to type into, for the hand-worked document. `quick` (Markdown) does not wait for the
    /// document to be quiet after the copy's rows are saved: the footnote renumber of a footnoted copy may still be on its way. Nil after a
    /// reported failure.
    func makeDuplicate(title: String, editor: Phase4bRedoEditor, copyTyped: [Int: String], quick: Bool = false) -> Phase4bRedoDup? {
        guard let range = requireSection(title) else { return nil }
        guard range.lowerBound + 2 < pre.count, pre[range.lowerBound + 1].fragment == Self.dupLineOne,
              pre[range.lowerBound + 2].fragment == Self.dupLineTwo else {
            fail("TEST-SETUP: the section \"\(title)\" does not hold the seeded \"\(Self.dupLineOne)\" and \"\(Self.dupLineTwo)\" "
                + "as its first two body rows")
            return nil
        }
        let copyTitle = title + " copy"
        guard let before = expectedUserRows(duplicating: nil), let withTyping = expectedUserRows(duplicating: title, copyTyped: copyTyped),
              let card = bringSidebarCardIntoView(title) else { return nil }
        let from = chooseSidebarItem(card, item: "Duplicate Section")
        let shown = sidebarCard(copyTitle).waitForExistence(timeout: appWait(size.operationTimeout, before: "the copy's card shows"))
        assertCheck(shown, "the copy's sidebar card \"\(copyTitle)\" appears after Duplicate Section")
        guard shown else { return nil }
        if editor == .richText {
            // Editor first: the click's own sequence ends within milliseconds; the rows follow later through the write queue.
            waitForPerformed("sectionDuplicate", from: from, timeout: appWait(size.operationTimeout * 2, before: "the duplicate performs"))
        } else {
            // Markdown keeps the old body (database first, then the page is rebuilt): typing is safe once the copy's rows are saved.
            let rows = waitForHeadingRows(copyTitle, equalTo: 1, timeout: appWait(size.operationTimeout * 2, before: "the copy's rows are saved"))
            assertCheck(rows == 1, "the block table holds the copy's heading \"\(copyTitle)\" once (it holds \(rows))")
            if !quick { settle() }
        }
        guard let copyCard = bringSidebarCardIntoView(copyTitle) else { return nil }
        navigate(to: copyCard)
        return Phase4bRedoDup(title: title, copyTitle: copyTitle, editor: editor, before: before, withTyping: withTyping, from: from)
    }

    /// `makeDuplicate`, then the caret at the end of the COPY's Dup01 line and the editor's sentence typed there in one go. Nil after a
    /// reported failure.
    func duplicateAndType(title: String, editor: Phase4bRedoEditor, quick: Bool = false) -> Phase4bRedoDup? {
        let sentence = editor.sentence
        let typedLine = Self.dupLineOne + " " + sentence
        guard let dup = makeDuplicate(title: title, editor: editor, copyTyped: [1: typedLine], quick: quick) else { return nil }
        // Rich Text: the sidebar's click scrolls exactly to the copy. Markdown: it only lands NEAR it (see `placeCaretInMarkdownCopyDupLine`).
        let placed = editor == .markdown
            ? placeCaretInMarkdownCopyDupLine(copyTitle: dup.copyTitle)
            : placeCaretAtEndOfVisibleLine(Self.dupLineOne, words: 6, timeout: capped(90))
        guard placed else { return nil }
        typeNow(" " + sentence)
        note("TYPED \"\(sentence)\" at the end of the copy's Dup01 line (\(editor.name)); \(typedLine.count) characters in the line, so it wraps")
        return dup
    }

    /// The section the status bar's outline button reports (its accessibility VALUE, the full name; the visible text is cut short): the
    /// section the CARET is in. Empty when the button cannot be read.
    func statusBarSectionName() -> String {
        let button = app.buttons["status-bar-outline"]
        guard button.exists else { return "" }
        return (button.value as? String) ?? ""
    }

    /// Waits (a condition) until the status bar's section name contains `needle`; the last name read is returned too.
    func waitForStatusBarSection(containing needle: String, timeout: TimeInterval) -> (found: Bool, last: String) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var name = statusBarSectionName()
        while !name.contains(needle), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            name = statusBarSectionName()
        }
        return (name.contains(needle), name)
    }

    /// In Markdown: puts the caret at the end of the COPY's Dup01 line. WHY NOT `placeCaretAtEndOfVisibleLine` (run-1792958788-91725 failed with
    /// "no leaf with the exact text ... is fully on screen after 90 s" on both Markdown Duplicate tests): in Markdown the sidebar's click
    /// only lands NEAR the section (the page scrolls to an offset it works out from the text, and CodeMirror's heights for lines it has not
    /// drawn yet are estimates), here a few paragraphs past the copy's heading: the video shows a body paragraph of the Conclusion at the top
    /// of the editor, and the accessibility tree holds only the lines CodeMirror has drawn, so the Dup01 line was not in the tree at all
    /// (the match count was 0 on every poll). Rich Text scrolls exactly, which is why its tests passed.
    ///
    /// So the line is SEARCHED for with the mouse wheel, as a person does: look at the landing place, then scroll further down and further
    /// up in growing steps (500 points more each time, alternating) and look again. The copy repeats the original's text, so a Dup01 line
    /// found is NOT known to be the copy's: the caret is put at its end and the status bar (its outline button's accessibility value is the
    /// section the caret is in) must then read the copy's section name ("... copy"); a line in the original answers with the original's
    /// name and the search goes on. The caret is then confirmed as in Rich Text (Cmd-Right, the selection count of the line's 6 words).
    /// Fails loudly (TEST-SETUP) with the section names read, never types into an unconfirmed place.
    func placeCaretInMarkdownCopyDupLine(copyTitle: String) -> Bool {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", Self.dupLineOne))
        var sign: CGFloat = 1   // the deltaY sign that scrolls DOWN, found by one small probe scroll
        var travelled: CGFloat = 0
        var read: [String] = []
        let stops: [CGFloat] = [0, 500, -500, 1000, -1000, 1500, -1500, 2000, -2000, 2600, -2600, 3200, -3200]
        for (round, stop) in stops.enumerated() {
            if round == 1 {
                // One small scroll to learn which way the wheel goes (the content moves UP when the editor reads further down).
                let anchor = viewportAnchor()
                app.editorArea.scroll(byDeltaX: 0, deltaY: -150)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                if let anchor, let top = anchorTop(anchor), top > anchor.top + 10 { sign = -1 }
                travelled = sign > 0 ? 150 : -150   // the probe's own travel, in the reading-down direction
            }
            if stop != travelled {
                app.editorArea.scroll(byDeltaX: 0, deltaY: -(stop - travelled) * sign)
                travelled = stop
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            }
            for leaf in fullyVisible(leaves).reversed() {
                app.waitForStableFrame(leaf)
                guard leaf.exists else { continue }
                app.activateAndWaitForForeground()
                leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
                let section = waitForStatusBarSection(containing: copyTitle, timeout: 4)
                read.append("round \(round): \"\(section.last)\"")
                guard section.found else { continue }
                app.typeKey(.rightArrow, modifierFlags: .command)
                let probe = app.caretSelectionProbe(expectedWords: 6, atEnd: true)
                note("CARET (Markdown) at the end of the COPY's Dup01 line, found in search round \(round) (net scroll \(Int(travelled)) pt): "
                    + "the status bar reads \"\(section.last)\"; probe \(probe)")
                guard probe == "ok" else {
                    fail("the caret could not be confirmed at the end of the copy's Dup01 line (probe: \(probe))")
                    return false
                }
                return true
            }
        }
        shot("md-copy-dup-line-not-found")
        fail("TEST-SETUP: the copy's Dup01 line (\"\(Self.dupLineOne)\" in the section \"\(copyTitle)\") was not found by scrolling the "
            + "Markdown editor through \(stops.count) places (net \(Int(stops.min() ?? 0)) to \(Int(stops.max() ?? 0)) pt around where the "
            + "sidebar's click landed); the status bar read, after a click in each Dup01 line found: \(read)")
        return false
    }

    /// The leaves of `leaves` that lie fully inside the editor's visible band (24 points in from each edge), in tree order.
    func fullyVisible(_ leaves: XCUIElementQuery) -> [XCUIElement] {
        let editor = app.editorArea.frame
        var visible: [XCUIElement] = []
        for index in 0..<leaves.count {
            let leaf = leaves.element(boundBy: index)
            guard leaf.exists else { continue }
            let frame = leaf.frame
            if frame.width > 0, frame.minY >= editor.minY + 24, frame.maxY <= editor.maxY - 24 { visible.append(leaf) }
        }
        return visible
    }

    /// Waits for the typing to reach the block table and the document to be quiet (the "after a pause" variant).
    func waitForTypingSaved(_ dup: Phase4bRedoDup) -> Bool {
        let saved = waitForSentenceInDatabase(dup.editor.sentence, timeout: 90)
        assertCheck(saved, "the sentence typed into the copy reached the block table")
        settle()
        return saved
    }
}

// MARK: - The exact-count cycle: Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z

extension WriteQueuePhase4bRedoE2ETests {
    /// Whether the editor's text is read from the accessibility tree (a snapshot of a book-length Rich Text editor takes many seconds; the
    /// screen-equals-database round trip covers that case).
    func readsScreen(_ dup: Phase4bRedoDup) -> Bool { dup.editor == .markdown || size == .article }

    /// Cmd-Z twice, straight after each other. The claim: the first takes the sentence away, the second removes the copy.
    func undoTwice(_ dup: Phase4bRedoDup, cycle: Int, to soft: inout Phase4bFlowSoftChecks) {
        let what = "cycle \(cycle) after Cmd-Z x2"
        let index = traceLinesCount()
        app.activateAndWaitForForeground()
        pressUndo()
        pressUndo()
        let keys = waitForKeydowns("undo", count: 2, from: index, timeout: 20)
        let decisions = keys.map(\.decision)
        result("CYCLE \(cycle) Cmd-Z x2: the editor decided \(decisions) with undo depth \(keys.map { $0.undoDepth.map(String.init) ?? "-" }), "
            + "redo depth \(keys.map { $0.redoDepth.map(String.init) ?? "-" })")
        if let depth = keys.first?.undoDepth, depth > 1 {
            soft.check(false, "TEST-SETUP: the editor's text history held \(depth) undo steps at the first Cmd-Z (the typing alone is 1): "
                + "the typing split into groups at the VM's pace, or a recorded rewrite landed after it; two Cmd-Z presses cannot reach the copy")
        }
        soft.check(keys.count == 2 && decisions[0] == "fallthrough" && ["structural", "swallow"].contains(decisions[1]),
            "\(what): the editor decided \(decisions), expected [fallthrough (the sentence), structural (the copy)]")
        soft.check(waitForCard(dup.copyTitle, present: false, timeout: appWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "\(what): the copy's sidebar card \"\(dup.copyTitle)\" is still in the Outline")
        soft.check(waitForSentenceGone(dup.editor.sentence, timeout: 120),
            "\(what): the sentence \"\(dup.editor.sentence)\" is still in the block table")
        settle(gone: [dup.copyTitle])
        addRowChecks(what, expectedUser: dup.before, managed: preManagedRows, to: &soft)
        addHeadingChecks(what, expectedRows: dup.before, to: &soft)
        if readsScreen(dup), let gone = waitForSentenceOnScreen(dup.editor.sentence, present: false, timeout: 60) {
            soft.check(gone, "\(what): the sentence is still on screen")
        }
    }

    /// Cmd-Shift-Z twice, straight after each other (or, with `watch`, one at a time with the scroll and caret read around the second).
    /// The claim: the first brings the copy back, the second brings the sentence back exactly once, inside the copy.
    func redoTwice(_ dup: Phase4bRedoDup, cycle: Int, watch: Bool, to soft: inout Phase4bFlowSoftChecks) {
        let what = "cycle \(cycle) after Cmd-Shift-Z x2"
        let index = traceLinesCount()
        app.activateAndWaitForForeground()
        var before: CGFloat?
        if watch {
            pressRedo()
            _ = waitForKeydowns("redo", count: 1, from: index, timeout: 20)
            soft.check(waitForCard(dup.copyTitle, present: true, timeout: appWait(size.operationTimeout * 2, before: "the copy's card is back")),
                "\(what): the copy's sidebar card is not back after the first Cmd-Shift-Z")
            _ = waitForBlocksToSettle()
            before = visibleLeaf(Self.dupLineTwo, timeout: 30).map { $0.frame.minY }
            note("SCROLL before the second Cmd-Shift-Z: the copy's Dup02 line top is at \(before.map { String(Int($0)) } ?? "not on screen")")
            pressRedo()
        } else {
            pressRedo()
            pressRedo()
        }
        let keys = waitForKeydowns("redo", count: 2, from: index, timeout: 20)
        let decisions = keys.map(\.decision)
        result("CYCLE \(cycle) Cmd-Shift-Z x2: the editor decided \(decisions) with redo depth \(keys.map { $0.redoDepth.map(String.init) ?? "-" }) "
            + "(the second press must find 1 redo step: the sentence)")
        soft.check(keys.count == 2 && ["structural", "swallow"].contains(decisions[0]) && ["fallthrough", "swallow"].contains(decisions[1]),
            "\(what): the editor decided \(decisions), expected [structural (the copy), fallthrough (the sentence)]")
        if keys.count == 2, keys[1].decision == "fallthrough" {
            soft.check(keys[1].redoDepth == 1,
                "\(what): the second Cmd-Shift-Z found redo depth \(keys[1].redoDepth.map(String.init) ?? "n/a"), expected 1: "
                + "the redo steps of the typing were lost by the structural undo / redo (the defect)")
        }
        soft.check(waitForCard(dup.copyTitle, present: true, timeout: appWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "\(what): the copy's sidebar card \"\(dup.copyTitle)\" is not back in the Outline")
        let sentence = dup.editor.sentence
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "\(what): the sentence \"\(sentence)\" is in \(count) block row(s), expected exactly 1 (the copy's first paragraph)")
        settle(back: [dup.copyTitle])
        addRowChecks(what, expectedUser: dup.withTyping, managed: preManagedRows, to: &soft)
        addHeadingChecks(what, expectedRows: dup.withTyping, to: &soft)
        if readsScreen(dup), let shown = waitForSentenceOnScreen(sentence, present: true, timeout: 90) {
            soft.check(shown, "\(what): the editor does not show the sentence \"\(sentence)\"")
        }
        if watch { addScrollAndCaretChecks(before: before, what: what, to: &soft) }
    }

    /// M8: after the second Cmd-Shift-Z the scroll position did not jump (the copy's Dup02 line, an unchanged one-line paragraph next to
    /// the typed one, is within `scrollTolerance` of where it was; a wrapped typed line pushes it down by one line at most) and the caret is
    /// in the typed line (Shift-Cmd-Left from the caret selects words back to the line's visual start: at least one, at most the whole line).
    func addScrollAndCaretChecks(before: CGFloat?, what: String, to soft: inout Phase4bFlowSoftChecks) {
        let after = visibleLeaf(Self.dupLineTwo, timeout: 30).map { $0.frame.minY }
        let words = caretWordsToLineStart()
        let lineWords = Self.dupLineOne.split(separator: " ").count + 4
        result("SCROLL / CARET around the second Cmd-Shift-Z: the Dup02 line top \(before.map { String(Int($0)) } ?? "n/a") before, "
            + "\(after.map { String(Int($0)) } ?? "n/a") after (tolerance \(Int(Self.scrollTolerance)) pt); "
            + "the caret selects \(words.map(String.init) ?? "n/a") word(s) back to its line start "
            + "(1...\(lineWords) means it sits in the typed line)")
        if let before {
            soft.check(after != nil && abs(after! - before) <= Self.scrollTolerance,
                "\(what): the scroll position JUMPED around the second Cmd-Shift-Z: the Dup02 line top was at \(Int(before)), now "
                + "\(after.map { String(Int($0)) } ?? "off screen") (more than \(Int(Self.scrollTolerance)) pt is a visible jump: must-fix)")
        } else {
            note("SCROLL: no 'before' reading (the copy's Dup02 line was not fully on screen after the first Cmd-Shift-Z); only the caret is checked")
        }
        soft.check(words != nil && (1...lineWords).contains(words!),
            "\(what): the caret is not in the typed line after the second Cmd-Shift-Z "
            + "(Shift-Cmd-Left selected \(words.map(String.init) ?? "nothing"))")
    }

    /// Reads where the caret is without touching the document: Shift-Cmd-Left, the status bar's selection count, then Right to collapse.
    func caretWordsToLineStart() -> Int? {
        let baseline = app.wordCountStatusText()
        app.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        var seen = baseline
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            seen = app.wordCountStatusText()
        } while seen == baseline && Date() < deadline
        app.typeKey(.rightArrow, modifierFlags: [])
        return seen == baseline ? nil : XCUIApplication.leadingNumber(seen)
    }

    /// File > Save Version then a second read of the block table: the two reads must be identical ("the screen equals the database").
    func addScreenEqualsDatabaseCheck(before: [Phase4bFlowRow], what: String, to soft: inout Phase4bFlowSoftChecks) {
        versionSaves += 1
        let name = "Redo check \(versionSaves)"
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

    /// The whole exact-count scenario: duplicate `title`, type in the copy, then `cycles` times Cmd-Z x2 / Cmd-Shift-Z x2. `immediate`: the
    /// first cycle's keys come straight after the typing (no wait for the saved rows); otherwise the rows are waited for first.
    /// `immediate` and `watchScroll` carry their usual values as defaults (the lint rule on parameter count does not count defaulted ones);
    /// every caller still passes them by name.
    func runExactCycles(
        _ size: Phase4bDelSize, method: String, editor: Phase4bRedoEditor, title: String, cycles: Int,
        immediate: Bool = true, watchScroll: Bool = false
    ) {
        guard startScenario(size, method: method, editor: editor, seed: Self.dupSeed(under: title, level: 2)),
              let dup = duplicateAndType(title: title, editor: editor) else { return }
        note("SCENARIO (\(editor.name)): \"\(title)\" duplicated, \"\(editor.sentence)\" typed in the copy's first paragraph; \(cycles) cycle(s) of "
            + "Cmd-Z x2, Cmd-Shift-Z x2; first cycle \(immediate ? "STRAIGHT AFTER the typing" : "after the rows agreed")")
        var soft = Phase4bFlowSoftChecks()
        if !immediate { _ = waitForTypingSaved(dup) }
        let keysFrom = traceLinesCount()
        for cycle in 1...cycles {
            undoTwice(dup, cycle: cycle, to: &soft)
            redoTwice(dup, cycle: cycle, watch: watchScroll && cycle == cycles, to: &soft)
        }
        let post = readRows()
        shot("redo-exact-\(editor == .richText ? "rt" : "md")-end")
        addLogChecks(from: keysFrom, editor: editor, putBacks: cycles, to: &soft)
        if editor == .richText {
            let okLines = editorFirstOkLines("duplicate", from: dup.from)
            let redoLines = editorFirstOkLines("duplicate-redo", from: dup.from)
            soft.check(okLines.count == 1, "\(okLines.count) `duplicate-editor-first ... ok=true` line(s), expected 1 (the click ran editor-first)")
            soft.check(redoLines.count == cycles,
                "\(redoLines.count) `duplicate-redo-editor-first ... ok=true` line(s), expected \(cycles) (the quick redo)")
        }
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "\(editor.name): Duplicate \"\(title)\", type in the copy, Cmd-Z x2, Cmd-Shift-Z x2 (\(cycles) cycle(s)), "
            + "on \(size.identifier)")
    }
}

// MARK: - 1-3 The exact-count tests

extension WriteQueuePhase4bRedoE2ETests {
    /// Hand test, Rich Text: right-click the card of a footnote-free section, Duplicate Section, click at the end of the copy's first
    /// paragraph, type "Typed in Rich Text.", Cmd-Z, Cmd-Z (the sentence goes, then the copy), Cmd-Shift-Z, Cmd-Shift-Z (the copy is back,
    /// then the sentence, once, inside the copy). The article presses the keys straight after the typing; the book waits for the rows first.
    func testRtDuplicateTypeUndoRedo_article() {
        runExactCycles(.article, method: #function, editor: .richText, title: "1.6 Conclusion", cycles: 1, immediate: true, watchScroll: false)
    }

    func testRtDuplicateTypeUndoRedo_book6() {
        runExactCycles(.book6, method: #function, editor: .richText, title: "5.6 Conclusion", cycles: 1, immediate: false, watchScroll: false)
    }

    /// The same after View > Switch to Markdown. The copy of "3.6 Conclusion" sits right before "# Chapter 4: ..." (the line the defect used to
    /// split), and the heading lines are asserted unchanged. The book also records the scroll and caret position around the SECOND Cmd-Shift-Z.
    func testMdDuplicateTypeUndoRedo_article() {
        runExactCycles(.article, method: #function, editor: .markdown, title: "1.6 Conclusion", cycles: 1, immediate: true, watchScroll: false)
    }

    func testMdDuplicateTypeUndoRedo_book6() {
        runExactCycles(.book6, method: #function, editor: .markdown, title: "3.6 Conclusion", cycles: 1, immediate: false, watchScroll: true)
    }

    /// The same on the twelve-chapter book (699,139 characters, 816 citation groups, 108 footnote marks): the keys come straight after the
    /// typing and straight after each other. Records the put-back's cost (`ms=K` of the `markdown-swap redo put-back` line, and the
    /// `setAside=N` of the undo carry line) as a result line: no time bound is asserted, but a put-back line without K fails.
    func testMdDuplicateTypeUndoRedo_book12() {
        runExactCycles(.book12, method: #function, editor: .markdown, title: "3.6 Conclusion", cycles: 1, immediate: true, watchScroll: false)
    }

    /// The four keys twice: a second undo / redo cycle works (the set-aside record is made afresh for the redone entry).
    func testRtDuplicateTwoCycles_book6() {
        runExactCycles(.book6, method: #function, editor: .richText, title: "5.6 Conclusion", cycles: 2, immediate: true, watchScroll: false)
    }

    func testMdDuplicateTwoCycles_book6() {
        runExactCycles(.book6, method: #function, editor: .markdown, title: "3.6 Conclusion", cycles: 2, immediate: true, watchScroll: false)
    }
}

// MARK: - 4 A whole footnoted chapter: the presses are polled

extension WriteQueuePhase4bRedoE2ETests {
    /// Duplicate a whole footnoted chapter ("Chapter 3": nine footnote references, sub-sections), type in the copy at once, then Cmd-Z one
    /// press at a time until the operation is undone (the app's footnote renumber can surface as a Cmd-Z step of its own about 3 s after the
    /// click, so the count is not fixed) and Cmd-Shift-Z until the typing is back; each press waits for the editor's own keydown line, at most 6
    /// presses, and the count used is reported. Asserted: the end state (the sentence once, in the copy; no heading line changed).
    func runFootnoteChapter(editor: Phase4bRedoEditor, method: String) {
        let size = Phase4bDelSize.book6
        let title = Self.chapter(3)
        guard startScenario(size, method: method, editor: editor, seed: Self.dupSeed(under: title, level: 1)),
              let dup = duplicateAndType(title: title, editor: editor) else { return }
        let sentence = editor.sentence
        note("SCENARIO (\(editor.name)): the whole chapter \"\(title)\" (\(section(title).map { Phase4bFlow.footnoteRefsInRange(pre, $0) } ?? -1) "
            + "footnote reference(s)) duplicated, \"\(sentence)\" typed in the copy at once, polled undo and redo (cap \(Self.pressCap))")
        var soft = Phase4bFlowSoftChecks()
        let keysFrom = traceLinesCount()
        let undoPresses = undoUntilStructural()
        reportPresses("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the copy was not removed by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(waitForCard(dup.copyTitle, present: false, timeout: appWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's sidebar card is still in the Outline after \(undoPresses.count) Cmd-Z press(es)")
        soft.check(waitForSentenceGone(sentence, timeout: 120), "the sentence is still in the block table after \(undoPresses.count) Cmd-Z press(es)")
        settle(gone: [dup.copyTitle])
        addRowChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedUser: dup.before, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedRows: dup.before, to: &soft)

        let redoPresses = redoUntilTypingBack()
        reportPresses("redo", redoPresses)
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), expected exactly 1: "
            + "the redo depth before each press was \(redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" })")
        soft.check(waitForCard(dup.copyTitle, present: true, timeout: appWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "the copy's sidebar card is not back after \(redoPresses.count) Cmd-Shift-Z press(es)")
        settle(back: [dup.copyTitle])
        let post = addRowChecks(
            "after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedUser: dup.withTyping, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedRows: dup.withTyping, to: &soft)
        let walk = Phase4bFlowWalk(rows: post)
        result("FOOTNOTES at the end (informational): \(walk.summary)")
        shot("redo-footnote-chapter-\(editor == .richText ? "rt" : "md")-end")
        result("PRESS COUNTS: Cmd-Z \(undoPresses.count), Cmd-Shift-Z \(redoPresses.count) "
            + "(the clean case is 2 and 2; a footnote renumber that landed as its own step adds one)")
        addLogChecks(from: keysFrom, editor: editor, putBacks: nil, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "\(editor.name): Duplicate the footnoted chapter, type in the copy, polled Cmd-Z / Cmd-Shift-Z, on \(size.identifier)")
    }

    func testRtDuplicateFootnoteChapter_book6() { runFootnoteChapter(editor: .richText, method: #function) }
    func testMdDuplicateFootnoteChapter_book6() { runFootnoteChapter(editor: .markdown, method: #function) }
}

extension Phase4bFlow {
    /// How many footnote references the rows of `range` hold (for a note).
    static func footnoteRefsInRange(_ rows: [Phase4bFlowRow], _ range: Range<Int>) -> Int {
        rows[range].reduce(0) { $0 + footnoteRefs(in: $1.fragment).count }
    }
}

// MARK: - 5 and 8 Restore Entire Project

extension WriteQueuePhase4bRedoE2ETests {
    /// File > Save Version with `name`, and the wait (a condition) for its snapshot row. Saving a version writes the LIVE editor text into
    /// the block table first.
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

    /// Cmd-Opt-V: opens (or brings to the front) the Version History window, found by its window IDENTIFIER (not the title).
    func openVersionHistory() -> XCUIElement? {
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        guard window.waitForExistence(timeout: appWait(90, before: "the Version History window is looked for")) else {
            fail("the Version History window never appeared after Cmd-Opt-V (the app has \(app.windows.count) window(s))")
            return nil
        }
        return window
    }

    /// Clicks the version `name` in the window's list (the row text is the version's name, unique here).
    func selectVersion(named name: String, in window: XCUIElement) -> Bool {
        // e2e-lint: allow statictext-firstmatch -- scoped to the Version History window and an exact `==` on label or value (no CONTAINS).
        let row = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
        guard row.waitForExistence(timeout: appWait(120, before: "the version \"\(name)\" is looked for in the list")) else {
            fail("the version \"\(name)\" never appeared in the Version History list")
            return false
        }
        row.click()
        note("VERSION HISTORY: the version \"\(name)\" is selected in the list")
        return true
    }

    /// "Restore All", then the "Restore Entire Project" confirmation. Returns the index of the first app-log line after the confirm click.
    func confirmFullRestore(in window: XCUIElement) -> Int? {
        let restoreAll = window.buttons["Restore All"]
        guard restoreAll.waitForExistence(timeout: appWait(60, before: "the Restore All button is looked for")) else {
            fail("the \"Restore All\" button never appeared once the version was selected")
            return nil
        }
        restoreAll.click()
        let confirm = waitForSaveVersionAlert().buttons["version-history-full-restore-confirm"]
        guard confirm.waitForExistence(timeout: 15) else {
            fail("the \"Restore Entire Project\" confirmation never offered its button (sheet present: \(app.sheets.firstMatch.exists))")
            return nil
        }
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        confirm.click()
        return from
    }

    /// The window closes itself when the restore reports it is done (the Swift sequence's `performed`). Waits for that (a condition).
    func waitForVersionHistoryToClose(_ window: XCUIElement) -> Bool {
        let closed = window.waitForDisappearance(timeout: appWait(size.operationTimeout * 2, before: "the Version History window closes"))
        if !closed { fail("the Version History window was still open \(Int(size.operationTimeout * 2)) s after the whole-project restore") }
        return closed
    }

    /// Deletes the section `title` from its sidebar card and waits until its heading is gone and the document is quiet.
    func deleteSectionFromSidebar(_ title: String, editor: Phase4bRedoEditor) -> Bool {
        guard let card = bringSidebarCardIntoView(title) else { return false }
        let from = chooseSidebarItem(card, item: "Delete Section")
        // The Markdown editor-first delete starts no `sectionDelete` sequence (the old Markdown body did); its end is the heading leaving the table.
        if editor == .richText {
            waitForPerformed("sectionDelete", from: from, timeout: appWait(size.operationTimeout * 2, before: "the delete performs"))
        }
        let gone = settle(gone: [title])
        assertCheck(gone, "\"\(title)\" is gone from the block table once its delete has settled")
        return gone
    }

    /// EDITEDRDO at the end of the Dup02 line of `sectionTitle` (a plain footnote-free paragraph). Waits until the database holds it.
    func makeParagraphEdit(sectionTitle: String) -> Bool {
        guard let card = bringSidebarCardIntoView(sectionTitle) else { return false }
        navigate(to: card)
        guard placeCaretAtAnchorEnd(paragraph: Self.dupTwoPrefix, exactLine: Self.dupLineTwo) else { return false }
        typeNow(" " + Self.editMarker)
        let landed = waitForSentenceInDatabase(Self.editMarker, timeout: 90)
        assertCheck(landed, "the edit \"\(Self.editMarker)\" typed after the version was saved reached the database")
        settle()
        return landed
    }

    /// Save Version, delete the last section of chapter 1, edit a paragraph, then Version History > Restore All > Restore Entire Project,
    /// type at the end of the Dup01 line straight away (Markdown: the old-body restore replaces the whole document from position 0 and
    /// leaves the editor at the TOP of it, where CodeMirror draws only the lines near the window, so a person goes back to the section
    /// from the sidebar and clicks the line: `placeCaretInSection`; Rich Text needs no click), then Cmd-Z one press at a time until the
    /// restore is undone and Cmd-Shift-Z until the typing is back.
    /// The restore leaves every paragraph with a fresh block id, so typing in ANY paragraph used to be lost on the redo.
    func runRestoreProject(editor: Phase4bRedoEditor, method: String) {
        let size = Phase4bDelSize.book6
        let sectionTitle = Phase4bDelSize.restoreSectionTitle
        let deletedTitle = Phase4bDelSize.restoreDeletedTitle
        let sentence = editor.sentence
        guard startScenario(size, method: method, editor: editor, seed: Self.dupSeed(under: sectionTitle, level: 2)),
              let sectionRange = requireSection(sectionTitle), let deletedRange = requireSection(deletedTitle),
              let dupOne = requireRow(Self.dupLineOne), let dupTwo = requireRow(Self.dupLineTwo), sectionRange.contains(dupOne) else { return }
        let restored = expectedUserRows(duplicating: nil, originalTyped: [dupOne: Self.dupLineOne + " " + sentence])
        let undone = expectedUserRows(
            duplicating: nil, removed: [deletedRange], originalTyped: [dupTwo: Self.dupLineTwo + " " + Self.editMarker])
        guard let restored, let undone else { fail("TEST-SETUP: the expected rows could not be worked out"); return }
        let saved = saveVersion(named: Self.versionName)
        assertCheck(saved, "the version \"\(Self.versionName)\" was saved")
        guard saved else { return }
        settle()
        guard deleteSectionFromSidebar(deletedTitle, editor: editor), makeParagraphEdit(sectionTitle: sectionTitle),
              placeCaretAtAnchorEnd(paragraph: Self.dupOnePrefix, exactLine: Self.dupLineOne) else { return }
        settle()
        note("BEFORE THE RESTORE (\(editor.name)): \"\(deletedTitle)\" is deleted, \(Self.editMarker) is typed")
        guard let window = openVersionHistory(), selectVersion(named: Self.versionName, in: window),
              let restoreFrom = confirmFullRestore(in: window), waitForVersionHistoryToClose(window) else { return }
        app.activateAndWaitForForeground()
        if editor == .markdown {
            guard placeCaretInSection(sectionTitle, line: Self.dupLineOne, prefix: Self.dupOnePrefix) else { return }
        }
        typeNow(" " + sentence)
        var soft = Phase4bFlowSoftChecks()
        soft.check(waitForSentenceInDatabase(sentence, timeout: 90), "the sentence typed after the restore reached the block table")
        waitForPerformed("restoreProject", from: restoreFrom, timeout: appWait(size.operationTimeout * 2, before: "the restore performs"))
        settle(back: [deletedTitle])
        addRowChecks("after the restore and the typing", expectedUser: restored, managed: preManagedRows, to: &soft)
        soft.check(blocksContaining(Self.editMarker) == 0, "the edit made after the version was saved (\(Self.editMarker)) is still in the document")

        let keysFrom = traceLinesCount()
        let undoPresses = undoUntilStructural()
        reportPresses("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the restore was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(waitForSentenceGone(sentence, timeout: 120), "the sentence is still in the block table after the restore was undone")
        settle(gone: [deletedTitle])
        addRowChecks("after the restore was undone", expectedUser: undone, managed: nil, walk: false, to: &soft)
        let runs = quickRuns(from: keysFrom, label: "undo")
        result("ROUTE of the restore's Cmd-Z: \(runs.map { "\($0.label) \($0.quick ? "quick" : "slow")" })")

        let redoPresses = redoUntilTypingBack()
        reportPresses("redo", redoPresses)
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), expected exactly 1: "
            + "the redo depth before each press was \(redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" })")
        settle(back: [deletedTitle])
        let post = addRowChecks("after the restore was redone", expectedUser: restored, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after the restore was redone", expectedRows: restored, to: &soft)
        soft.check(blocksContaining(Self.editMarker) == 0, "the edit made after the version was saved (\(Self.editMarker)) came back with the redo")
        shot("redo-restore-\(editor == .richText ? "rt" : "md")-end")
        result("PRESS COUNTS: Cmd-Z \(undoPresses.count), Cmd-Shift-Z \(redoPresses.count)")
        // The put-back runs only on the quick road of a Rich Text restore (the slow road keeps the typing by itself); Markdown always puts back.
        let quickRestore = editor == .richText ? runs.contains { $0.quick } : true
        addLogChecks(from: restoreFrom, editor: editor, putBacks: quickRestore ? 1 : nil, to: &soft)
        if editor == .richText {
            let okLines = replaceEditorFirstLines(mode: "whole", succeeded: true, from: restoreFrom)
            soft.check(okLines.count == 1,
                "\(okLines.count) `replace-editor-first mode=whole ... ok=true` line(s), expected 1 (the restore ran editor-first)")
        }
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "\(editor.name): Save Version, edit, Restore Entire Project, type, polled Cmd-Z / Cmd-Shift-Z, on \(size.identifier)")
    }

    func testRtRestoreEntireProjectTypeUndoRedo_book6() { runRestoreProject(editor: .richText, method: #function) }
    func testMdRestoreEntireProjectTypeUndoRedo_book6() { runRestoreProject(editor: .markdown, method: #function) }
}

// MARK: - 6 Markdown: drag a chapter, type inside it, undo, redo

extension WriteQueuePhase4bRedoE2ETests {
    /// `rows` with the section titled `title` (its heading and everything up to the next heading of the same or a higher level) taken out and
    /// put before the section titled `target`: the hand-worked document after a plain drag.
    func rowsMoving(_ rows: [Phase4bFlowRow], _ title: String, before target: String) -> [Phase4bFlowRow] {
        guard let start = rows.firstIndex(where: { $0.headingTitle == title }), let level = rows[start].headingLevel else { return rows }
        var end = start + 1
        while end < rows.count, !(rows[end].headingLevel.map { $0 <= level } ?? false) { end += 1 }
        let run = Array(rows[start..<end])
        var rest = rows
        rest.removeSubrange(start..<end)
        let insertion = rest.firstIndex { $0.headingTitle == target } ?? rest.count
        rest.insert(contentsOf: run, at: insertion)
        return rest
    }

    static func level(_ fragment: String) -> Int { fragment.prefix(while: { $0 == "#" }).count }
    static func title(_ fragment: String) -> String { String(fragment.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespacesAndNewlines) }

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

    /// Works out a drag of the card `moved` to just before the heading `target` (a drop on the card ABOVE `target`, at heading level 1: a
    /// chapter is dropped at the far left of the card). The cards are brought into the visible band and the drop point is computed; nothing
    /// is pressed. Nil after a reported failure.
    func prepareDrag(_ moved: String, before target: String) -> Phase4bRedoDrag? {
        guard let dropOn = headingAbove(target) else {
            fail("TEST-SETUP: \"\(target)\" is the first heading of the block table: there is no card above it to drop on")
            return nil
        }
        guard let cards = bringIntoView([moved, dropOn]) else { return nil }
        let predecessorLevel = headingFragmentsInDatabase().first { Self.title($0) == dropOn }.map { Self.level($0) } ?? 1
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let zones = CGFloat(predecessorLevel + 1)
        let screenX = scroll.frame.minX + 0.5 * scroll.frame.width / zones
        let dropCard = cards[1]
        let dropPoint = dropCard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: screenX - dropCard.frame.minX, dy: 0))
        let point = dropPoint.screenPoint
        note("DRAG PREPARED: \"\(moved.prefix(40))\" to just before \"\(target.prefix(40))\" "
            + "(dropped on the card of \"\(dropOn.prefix(40))\") at level 1: "
            + "pointer ends at (\(Int(point.x)), \(Int(point.y))) in the sidebar \(Self.describeFrame(scroll.frame)); dragged card "
            + "\(Self.describeFrame(cards[0].frame)); drop card \(Self.describeFrame(dropCard.frame))")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        return Phase4bRedoDrag(cards: cards, dropPoint: dropPoint, dropOn: dropOn)
    }

    /// The caret at the end of the seeded `line` of the chapter whose card is `card`: the sidebar's own navigation (a click on the card
    /// scrolls the editor to the chapter), then the exact-line recipe. False after a reported failure.
    func placeCaretInSection(_ card: String, line: String, prefix: String) -> Bool {
        guard let cardElement = bringSidebarCardIntoView(card) else { return false }
        navigate(to: cardElement)
        return placeCaretAtAnchorEnd(paragraph: prefix, exactLine: line)
    }

    /// Hand test, Markdown: drag the card "Chapter 5" above "Chapter 4" (the cards of chapters 3 to 5 are flattened so that they sit next to
    /// each other), type inside chapter 5 with no click (the caret travelled with the moved text), then Cmd-Z one press at a time until the
    /// drag is undone and Cmd-Shift-Z until the typing is back. The OLD limit (board t-14f908b4) was that this typing could not be redone;
    /// the editor now puts it back. Asserted: the heading order as after the drag, no heading line damaged, the sentence once, in chapter 5.
    func testMdDragTypeUndoRedo_book6() {
        let size = Phase4bDelSize.book6
        let moved = Self.chapter(5)
        let target = Self.chapter(4)
        let flat = [1, 3, 4, 5, 6]
        let sentence = Phase4bRedoEditor.markdown.sentence
        let moveSeed: (Phase4bDoc) -> Phase4bDoc = { generated in
            WriteQueuePhase4bStructuralQueueE2ETests.withPlainLines(generated, under: moved, level: 1, lines: [Self.moveLine])
        }
        guard startScenario(size, method: #function, editor: .markdown, flat: flat, seed: moveSeed),
              let movedRange = requireSection(moved), requireSection(target) != nil, let moveRow = requireRow(Self.moveLine) else { return }
        guard pre[movedRange].dropFirst().allSatisfy({ $0.headingLevel == nil }) else {
            fail("TEST-SETUP: \"\(moved)\" has sub-headings; a plain drag would leave them behind")
            return
        }
        guard let drag = prepareDrag(moved, before: target), placeCaretInSection(moved, line: Self.moveLine, prefix: "Move05") else { return }
        let original = preUserRows
        let arrangement = rowsMoving(original, moved, before: target)
        let typedLine = Self.moveLine + " " + sentence
        let typedArrangement = arrangement.map { $0.fragment == Self.moveLine
            ? Phase4bFlowRow(type: $0.type, isNotes: false, isBibliography: false, fragment: typedLine) : $0 }
        let originalHeadings = headingLines(of: original)
        let movedHeadings = headingLines(of: arrangement)
        note("SCENARIO (Markdown): the caret is at the end of the Move05 line in \"\(moved.prefix(12))...\"; that chapter is dragged to just before "
            + "\"\(target.prefix(12))...\"; \"\(sentence)\" is typed with no click; polled Cmd-Z and Cmd-Shift-Z (cap \(Self.pressCap)); "
            + "chapters \(flat) are flat in this copy; \(Phase4bFlowWalk(rows: pre).refs.count) footnote references")
        var soft = Phase4bFlowSoftChecks()

        app.activateAndWaitForForeground()
        tail.poll()
        let dragFrom = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = dragFrom }
        let grab = drag.cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grab.press(forDuration: 0.5, thenDragTo: drag.dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3)
        typeNow(" " + sentence)
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order")),
            "after the drag the block table's heading order is not the dragged one (\(firstDifference(movedHeadings, headingFragmentsInDatabase())))")
        soft.check(waitForSentenceInDatabase(sentence, timeout: 90), "the sentence typed straight after the drop never reached the block table")
        settle()
        addRowChecks("after the drag and the typing (settled)", expectedUser: typedArrangement, managed: nil, walk: false, to: &soft)

        let keysFrom = traceLinesCount()
        let undoPresses = undoUntilStructural()
        reportPresses("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the drag was not undone by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the original order")),
            "after the drag was undone the heading order is not the original one "
            + "(\(firstDifference(originalHeadings, headingFragmentsInDatabase())))")
        soft.check(waitForSentenceGone(sentence, timeout: 120), "the sentence is still in the block table after the drag was undone")
        settle()
        addRowChecks("after the drag was undone (settled)", expectedUser: original, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after the drag was undone", expectedRows: original, to: &soft)

        let redoPresses = redoUntilTypingBack()
        reportPresses("redo", redoPresses)
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), "
            + "expected exactly 1 (inside chapter 5): "
            + "the redo depth before each press was \(redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" })")
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order comes back")),
            "after the redo the heading order is not the dragged one (\(firstDifference(movedHeadings, headingFragmentsInDatabase())))")
        settle()
        let post = addRowChecks("after the drag was redone (settled)", expectedUser: typedArrangement, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after the drag was redone", expectedRows: typedArrangement, to: &soft)
        soft.check(post.contains { $0.fragment == typedLine },
            "no row reads exactly \"\(typedLine)\": the sentence is not at the end of the Move05 line of chapter 5 "
            + "(row \(moveRow) in the document as loaded)")
        shot("redo-drag-md-end")
        result("PRESS COUNTS: Cmd-Z \(undoPresses.count), Cmd-Shift-Z \(redoPresses.count) (a footnote renumber after the drag can add a step)")
        addLogChecks(from: dragFrom, editor: .markdown, putBacks: nil, checkBeeps: false, to: &soft)
        let putBack = putBackLines(editor: .markdown, from: keysFrom)
        soft.check(!putBack.done.isEmpty, "no `markdown-swap redo put-back events=` line after the drag's redo: the put-back did not run")
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "Markdown: drag \"\(moved.prefix(12))...\" above \"\(target.prefix(12))...\", type inside it, "
            + "polled Cmd-Z / Cmd-Shift-Z, on \(size.identifier) "
            + "(flattened copy, chapters \(flat) flat)")
    }
}

// MARK: - 7 Markdown: the footnote renumber that keeps a waiting redo list must not move the page

/// A plain paragraph that is fully on screen: its text and where its top edge is.
struct Phase4bRedoAnchor {
    let value: String
    let top: CGFloat
}

/// The page's position around one Cmd-Shift-Z press: the anchor paragraph read before it, where that paragraph's top SETTLED after it
/// (nil: it was not in the accessibility tree), and the whole series of readings that led there, as text for the log.
struct Phase4bRedoScrollReading {
    let number: Int
    let before: Phase4bRedoAnchor
    let settledTop: CGFloat?
    let series: String
}

extension WriteQueuePhase4bRedoE2ETests {
    /// The first plain paragraph (30 or more characters, no footnote mark, not one of the Dup lines) that lies fully inside the editor's
    /// visible band: a reference point for "the page did not move". CodeMirror draws only the lines near the viewport, so the tree is small.
    func viewportAnchor() -> Phase4bRedoAnchor? {
        let editor = app.editorArea.frame
        for leaf in app.editorArea.staticTexts.allElementsBoundByIndex {
            guard leaf.exists, let value = leaf.value as? String, value.count >= 30, !value.contains("[^"), !value.hasPrefix("Dup0") else { continue }
            let frame = leaf.frame
            guard frame.width > 0, frame.minY >= editor.minY + 24, frame.maxY <= editor.maxY - 24 else { continue }
            return Phase4bRedoAnchor(value: value, top: frame.minY)
        }
        return nil
    }

    /// Where the anchor's paragraph is now: the top of the leaf with its exact text that lies nearest to where it was. Nil when no such leaf
    /// is in the accessibility tree (the page scrolled far away from it).
    func anchorTop(_ anchor: Phase4bRedoAnchor) -> CGFloat? {
        let matches = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", anchor.value))
        var best: CGFloat?
        for index in 0..<matches.count {
            let leaf = matches.element(boundBy: index)
            guard leaf.exists else { continue }
            let top = leaf.frame.minY
            if let current = best, abs(top - anchor.top) >= abs(current - anchor.top) { continue }
            best = top
        }
        return best
    }

    /// Scrolls the editor with the mouse wheel until the copy's Dup01 line (where the caret is) is no longer fully on screen, as a person
    /// does who scrolls away to look at the copy. Returns the wheel delta of the scroll that did it (its sign is the way the page went), or
    /// nil after three tries.
    func scrollAwayFromCaret() -> CGFloat? {
        for delta in [CGFloat(-1500), CGFloat(-3000), CGFloat(6000)] {
            app.editorArea.scroll(byDeltaX: 0, deltaY: delta)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            if visibleLeaf(Self.dupLineOne, timeout: 2) == nil { return delta }
        }
        return nil
    }

    /// `viewportAnchor()` with a person's patience. The screen the wheel landed on may have no plain paragraph fully on it (a screen of
    /// headings only, or the middle of a long wrapped paragraph that is not fully on screen). Then the editor is scrolled a little further
    /// (400 to 800 points a try, first on in `way`, the sign of the wheel delta that got here, then back and forth), and the paragraph is
    /// looked for again, at most `extraScrolls` times. A screen that shows the copy's Dup01 line (where the caret is) does not count.
    /// Returns the anchor (nil when none was found) and how many further scrolls were made.
    func viewportAnchorScrollingOn(way: CGFloat, extraScrolls: Int = 4) -> (anchor: Phase4bRedoAnchor?, scrolls: Int) {
        if let anchor = viewportAnchor() { return (anchor, 0) }
        let steps: [CGFloat] = [600, 800, -400, -700]
        for (index, step) in steps.prefix(extraScrolls).enumerated() {
            app.editorArea.scroll(byDeltaX: 0, deltaY: step * (way < 0 ? -1 : 1))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            if let anchor = viewportAnchor(), visibleLeaf(Self.dupLineOne, timeout: 1) == nil { return (anchor, index + 1) }
        }
        return (nil, min(extraScrolls, steps.count))
    }

    /// The text every paragraph of the document's FIRST SCREEN starts with: the 14 plain lines "Anchor01 line of the fixture document." ...
    /// at the top of chapter 1. A page whose first fully visible paragraph does not start with it has left the first screen.
    static let firstScreenLinePrefix = "Anchor"

    /// Scrolls the editor with the mouse wheel from the document's FIRST SCREEN down to a place well below it, as a person does who reads on
    /// (about 2000 points a try; the wheel's direction is learned from the first try that moves nothing). Returns a plain paragraph that lies
    /// fully on screen there, to be the anchor of a position reading, or nil after four tries.
    ///
    /// WHY HERE, WHY THIS FAR: after the copy is undone (a structural Cmd-Z) the page sits at the top of the document, because that undo's
    /// swap scrolls the saved caret into view and the caret is on the first screen. A reading taken there tells nothing about the redo: a
    /// scroll that is lost and a scroll back to the caret both land on the first screen, exactly where the page already is. Below it, both
    /// move the page, and the anchor, which lies in chapter 1, above the copy's insertion point (after chapter 3), shows it by leaving its
    /// place or the tree, while text inserted below the window leaves it in place. The wheel does not move the caret and does not take the
    /// keyboard from the editor, which a click in the sidebar might (a Cmd-Shift-Z would then not reach the editor).
    func scrollDownFromFirstScreen() -> Phase4bRedoAnchor? {
        var down: CGFloat = -1   // the deltaY sign that scrolls DOWN (the other sign scrolls up); flipped when a try moves nothing
        for _ in 1...4 {
            let before = viewportAnchor()
            app.editorArea.scroll(byDeltaX: 0, deltaY: 2000 * down)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            if let before, let top = anchorTop(before), abs(top - before.top) < 10 {
                down = -down
                continue
            }
            if let now = viewportAnchor(), !now.value.hasPrefix(Self.firstScreenLinePrefix) { return now }
        }
        return nil
    }

    /// The editor's text that is ON SCREEN: the runs (static texts) of ONE accessibility snapshot of the editor of which at least half lies
    /// inside the editor's visible band, top to bottom, joined with one space, every run of whitespace collapsed. A typed line that wraps is
    /// two runs. CodeMirror also draws lines above and below the window, so the whole tree (`joinedScreenText`) is not "on screen". Nil
    /// when no snapshot could be read.
    func onScreenEditorText() -> String? {
        guard let root = try? app.editorArea.snapshot() else { return nil }
        var runs: [(frame: CGRect, value: String)] = []
        func collect(_ node: XCUIElementSnapshot) {
            for child in node.children {
                if child.elementType == .staticText, let value = child.value as? String, child.frame.height > 0 {
                    let shown = root.frame.intersection(child.frame)
                    if !shown.isNull, shown.height >= child.frame.height / 2 { runs.append((frame: child.frame, value: value)) }
                }
                collect(child)
            }
        }
        collect(root)
        let ordered = runs.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        return ordered.map { $0.value }.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Waits (a condition) until the editor's text on screen holds `sentence`. False when it never does within `timeout`, nil when no
    /// snapshot could be read.
    func waitForSentenceInView(_ sentence: String, timeout: TimeInterval) -> Bool? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var read = false
        repeat {
            if let text = onScreenEditorText() {
                read = true
                if text.contains(sentence) { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return read ? false : nil
    }

    /// How many readings in a row must agree for the page to count as settled, and how far (points) apart they may be.
    static let settleRun = 3
    static let settleTolerance: CGFloat = 2
    /// How long (seconds) the page's position is sampled after the structural Cmd-Shift-Z, and how often.
    static let settleWindow: TimeInterval = 5
    static let settleStep: TimeInterval = 0.5

    /// The index of the last reading of the FIRST run of `settleRun` readings in a row that agree: all off the tree (nil), or all on it and
    /// within `settleTolerance` of each other. Nil when no such run exists.
    static func settledIndex(_ series: [CGFloat?]) -> Int? {
        guard series.count >= settleRun else { return nil }
        for end in (settleRun - 1)..<series.count {
            let run = series[(end - settleRun + 1)...end]
            let values = run.compactMap { $0 }
            if values.isEmpty { return end }
            if values.count == run.count, let low = values.min(), let high = values.max(), high - low <= settleTolerance { return end }
        }
        return nil
    }

    /// Where the anchor's paragraph SETTLES after a press. CodeMirror re-estimates and re-measures line heights over several frames after the
    /// editor state is replaced, so one reading taken straight after the press can be taken mid-settle. `immediate` is that first reading (t0.0);
    /// then the paragraph is read again every `settleStep` for up to `settleWindow`, until `settleRun` readings in a row agree. Settled = the
    /// last reading of that run, or the last reading taken when none comes ("off the tree" is a reading too). The series is kept as text.
    func settledReading(number: Int, before: Phase4bRedoAnchor, immediate: CGFloat?) -> Phase4bRedoScrollReading {
        let started = Date()
        var readings: [CGFloat?] = [immediate]
        var seconds: [TimeInterval] = [0]
        while Self.settledIndex(readings) == nil, Date().timeIntervalSince(started) < Self.settleWindow {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.settleStep))
            seconds.append(Date().timeIntervalSince(started))
            readings.append(anchorTop(before))
        }
        let end = Self.settledIndex(readings) ?? readings.count - 1
        let series = (0...end).map { index -> String in
            let value = readings[index].map { String(Int($0)) } ?? "off the tree"
            return "t\(String(format: "%.1f", seconds[index]))=\(value)"
        }.joined(separator: " ")
        return Phase4bRedoScrollReading(number: number, before: before, settledTop: readings[end], series: series)
    }

    /// Cmd-Shift-Z, one press at a time, until the typing is back (at most `pressCap`): `runFootnoteScrollKeep`'s redo. The page's position
    /// is read before and after EVERY press (press 1 uses `anchor`, chosen after the wheel scroll) and REPORTED, never asserted: a redo
    /// reveals what it restored, so the structural redo scrolls the restored selection into view and the page does not stay where the user
    /// was reading (measured: without the put-back's install the page leaves the screen, with it the page ends about 130 pt from where it
    /// was). At the structural press the position the page SETTLES at is reported (`settledReading`), with the whole series of readings,
    /// because one reading straight after the press can fall in the middle of CodeMirror's re-measuring. The last press is CodeMirror's own
    /// redo of the typing and scrolls to it. Returns the presses.
    func redoReadingScroll(from anchor: Phase4bRedoAnchor?) -> [Phase4bRedoPress] {
        var presses: [Phase4bRedoPress] = []
        var structural: Phase4bRedoScrollReading?
        for number in 1...Self.pressCap {
            let before = number == 1 ? anchor : viewportAnchor()
            let press = pressAndRead(redo: true, number: number)
            presses.append(press)
            result("\(press.summary); the editor's line: \(press.line)")
            if let before {
                let afterTop = anchorTop(before)
                let sampled = press.isStructural && press.performed
                result("SCROLL around press \(number) (\(press.decision)): the anchor paragraph top was \(Int(before.top)) before, "
                    + "\(afterTop.map { String(Int($0)) } ?? "off the tree") straight after"
                    + (sampled ? "" : " (no series: only a performed structural press gets one; CodeMirror's own redo scrolls to the typing)"))
                if sampled, structural == nil { structural = settledReading(number: number, before: before, immediate: afterTop) }
            }
            if press.decision == "none" { break }
            if press.decision == "fallthrough", (press.redoDepth ?? 0) <= 1 { break }
        }
        reportPresses("redo", presses)
        // Nothing here is asserted: a structural redo that was not performed fails the card, row and heading checks of the caller.
        guard let structural else {
            note("SCROLL after the structural Cmd-Shift-Z: no structural press was performed in \(presses.count) press(es), nothing to report")
            return presses
        }
        let settledText = structural.settledTop.map { String(Int($0)) } ?? "off the tree"
        result("SCROLL SERIES after press \(structural.number): \(structural.series) settled=\(settledText) (before \(Int(structural.before.top)))")
        result("SCROLL after the structural Cmd-Shift-Z (press \(structural.number)), informational, not asserted: before "
            + "\(Int(structural.before.top)), settled \(settledText) (series \(structural.series)). The redo itself scrolls the restored "
            + "selection into view; without the put-back the page leaves the screen (measured run-1792988998-34998), with it the page ends "
            + "about 130 pt from where it was (measured, both books)")
        return presses
    }

    /// After the last Cmd-Shift-Z, a plain redo of the typing: CodeMirror's design is to show what came back, so the typed sentence must be
    /// on screen (not merely drawn above or below the window).
    func addSentenceInViewCheck(_ sentence: String, to soft: inout Phase4bFlowSoftChecks) {
        let inView = waitForSentenceInView(sentence, timeout: capped(30))
        result("SENTENCE after the last Cmd-Shift-Z: on screen \(inView.map(Self.yesNo) ?? "unreadable (no accessibility snapshot)")")
        soft.check(inView == true,
            "the typed sentence \"\(sentence)\" is not on screen after the last Cmd-Shift-Z (a redo shows what came back); "
            + "readable: \(Self.yesNo(inView != nil))")
    }

    /// Scrolls the editor away from the copy's Dup01 line (where the caret is) with the mouse wheel and picks the paragraph the scroll watch
    /// compares the page's position with, scrolling a little further when the screen it landed on has none. Nil after a reported TEST-SETUP
    /// failure.
    func scrollAwayAndFindAnchor() -> Phase4bRedoAnchor? {
        guard let away = scrollAwayFromCaret() else {
            fail("TEST-SETUP: the editor could not be scrolled away from the copy's Dup01 line with the mouse wheel")
            return nil
        }
        let found = viewportAnchorScrollingOn(way: away)
        guard let anchor = found.anchor else {
            fail("TEST-SETUP: no plain paragraph is fully on screen after the scroll, nor after \(found.scrolls) further wheel scroll(s) of "
                + "400 to 800 points, so there is nothing to compare the page's position with")
            return nil
        }
        let further = found.scrolls == 0 ? ""
            : " (found after \(found.scrolls) further wheel scroll(s): the first screen had no plain paragraph fully on it)"
        note("SCROLL WATCH: anchor paragraph \"\(anchor.value.prefix(40))...\" top at \(Int(anchor.top))" + further)
        return anchor
    }

    /// The scroll watch of `runFootnoteScrollKeep`: while the app's footnote renumber lands (up to 25 s when `armed`, 8 s otherwise, and
    /// until four quiet polls after it landed), the anchor paragraph must stay in the accessibility tree and within `scrollTolerance` of
    /// where it was. The renumber is a recorded change that the page keeps the waiting redo list across by installing a new state
    /// (`renumber-keep`), and Swift's timer, not the user, triggers it.
    func watchPageDuringRenumber(anchor: Phase4bRedoAnchor, armed: Bool, to soft: inout Phase4bFlowSoftChecks) {
        var landed = false
        var lost = false
        var worst: CGFloat = 0
        var quietPolls = 0
        let deadline = Date(timeIntervalSinceNow: armed ? 25 : 8)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            if armed, !landed, Phase4bFlowWalk(rows: readRows()).problems.isEmpty { landed = true }
            if let top = anchorTop(anchor) { worst = max(worst, abs(top - anchor.top)) } else { lost = true }
            if landed { quietPolls += 1 }
        } while Date() < deadline && quietPolls < 4
        result("RENUMBER-KEEP WATCH: armed \(Self.yesNo(armed)); the renumber landed inside the window: \(Self.yesNo(landed)); "
            + "the anchor paragraph moved at most \(Int(worst)) pt (tolerance \(Int(Self.scrollTolerance)) pt); "
            + "anchor left the tree: \(Self.yesNo(lost))")
        soft.check(!lost && worst <= Self.scrollTolerance,
            "the page JUMPED while the editor was scrolled away from the caret (renumber landed in the window: \(Self.yesNo(landed))): "
            + "the anchor paragraph moved \(Int(worst)) pt (more than \(Int(Self.scrollTolerance)) pt is a jump back to the caret: "
            + "must-fix), left the tree: \(Self.yesNo(lost))")
    }

    /// Cmd-Z, one press at a time from press 2 on (`first` was made already and leads the result), until a structural press has run or the
    /// editor decided nothing, at most `pressCap`.
    func undoUntilStructural(after first: Phase4bRedoPress) -> [Phase4bRedoPress] {
        var presses = [first]
        if !first.isStructural {
            for number in 2...Self.pressCap {
                let press = pressAndRead(redo: false, number: number)
                presses.append(press)
                result(press.summary)
                if press.isStructural || press.decision == "none" { break }
            }
        }
        return presses
    }

    /// Reports where the page is, and what is under the caret, before the redo (the anchor of the structural press' reading); a scroll that
    /// could not be done costs the report, not the test.
    func noteAnchorBeforeRedo(_ anchor: Phase4bRedoAnchor?) {
        guard let anchor else {
            note("SCROLL BEFORE THE REDO: the editor could not be scrolled down from the document's first screen with the mouse wheel; "
                + "the page's position after the structural Cmd-Shift-Z is not reported")
            return
        }
        note("SCROLL BEFORE THE REDO: anchor paragraph \"\(anchor.value.prefix(40))...\" top at \(Int(anchor.top)); "
            + "the status bar puts the caret in the section \"\(statusBarSectionName())\"")
    }

    /// Markdown, a footnoted chapter ("Chapter 3": nine references): Duplicate, type in the copy (the document is not waited for to be quiet
    /// after the copy's rows are saved, so the app's footnote renumber may still be on its way), Cmd-Z once (the sentence goes: the redo list
    /// now holds it), scroll away from the caret, and watch the page for up to 25 s while the renumber lands. A renumber outside a structural
    /// settle is a recorded change; the page keeps the waiting redo list across it by installing a new state (`renumber-keep`), and that
    /// install must keep the scroll position, because Swift's timer, not the user, triggers it. Asserted: the paragraph that was on screen
    /// stays within 80 pt of where it was, the whole time the renumber is awaited.
    ///
    /// Then Cmd-Z until the copy is gone, and the page is scrolled down from the document's first screen (where that undo leaves it) to a
    /// place above the copy's insertion point. Then Cmd-Shift-Z until the typing is back, with the page's position read before and after
    /// EVERY press and REPORTED, NOT ASSERTED. At the STRUCTURAL press (press 1: the redo and the put-back's `installState(keepScroll:
    /// true)`, which puts the typing that the undo set aside back by installing a new editor state) the position the page SETTLES at is
    /// reported, not the one reading taken straight after the press (CodeMirror re-estimates and re-measures line heights over several frames
    /// after the state is replaced, so that reading can fall mid-settle): the paragraph is read again every 0.5 s for up to 5 s until three
    /// readings in a row agree within 2 pt (`settledReading`), and the whole series is logged ("SCROLL SERIES after press 1: ..."). Why it is
    /// not an assertion: a redo reveals what it restored, so the structural redo itself scrolls the restored selection into view. Measured
    /// in the real app: with the put-back's install off the page leaves the screen, with it the page ends about 130 pt from where the user
    /// was reading, in both books; the install already keeps the page much closer than the redo alone. The LAST press is CodeMirror's own redo
    /// of the typed sentence (decision `fallthrough`), which scrolls to the typed line by design: the sentence must be on screen after it
    /// and the caret in its line.
    ///
    /// NOT DETERMINISTIC, SAID PLAINLY: the renumber lands about 3 s after the click and the VM needs longer than that to navigate to the
    /// copy, place the caret and type, so in most runs it has landed BEFORE the first Cmd-Z and the renumber-keep path is not exercised. The
    /// test reads the saved footnotes right after the first Cmd-Z (`armed`: not yet 1...n) and prints whether the renumber landed inside the
    /// watch window; there is no success line for a renumber-keep in the page's trace (only a failure line, "footnote renumber: the redo
    /// list was not kept"), and no UI-test seam delays the Markdown renumber. The scroll watch and the reading around the structural
    /// Cmd-Shift-Z run in every case.
    func runFootnoteScrollKeep(_ size: Phase4bDelSize, method: String) {
        let title = Self.chapter(3)
        let sentence = Phase4bRedoEditor.markdown.sentence
        guard startScenario(size, method: method, editor: .markdown, seed: Self.dupSeed(under: title, level: 1)),
              let dup = duplicateAndType(title: title, editor: .markdown, quick: true) else { return }
        var soft = Phase4bFlowSoftChecks()
        let keysFrom = traceLinesCount()

        // Cmd-Z #1: the sentence goes and the redo list holds it.
        let first = pressAndRead(redo: false, number: 1)
        result(first.summary)
        soft.check(first.decision == "fallthrough",
            "the first Cmd-Z was decided \(first.decision), expected a text step (fallthrough) that takes the sentence away")
        let armed = !Phase4bFlowWalk(rows: readRows()).problems.isEmpty
        let armedText = armed
            ? "NOT yet 1...n (the renumber is still to come: ARMED)"
            : "already 1...n (the renumber landed before the first Cmd-Z: this run does NOT exercise the renumber-keep)"
        note("RENUMBER-KEEP: right after the first Cmd-Z the saved footnotes were \(armedText)")

        // Scroll away from the caret and watch the page.
        guard let anchor = scrollAwayAndFindAnchor() else { return }
        watchPageDuringRenumber(anchor: anchor, armed: armed, to: &soft)

        // Cmd-Z until the copy is gone.
        let undoPresses = undoUntilStructural(after: first)
        reportPresses("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the copy was not removed by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(waitForCard(dup.copyTitle, present: false, timeout: appWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's sidebar card is still in the Outline after \(undoPresses.count) Cmd-Z press(es)")
        soft.check(waitForSentenceGone(sentence, timeout: 120), "the sentence is still in the block table after \(undoPresses.count) Cmd-Z press(es)")
        settle(gone: [dup.copyTitle])
        addRowChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedUser: dup.before, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedRows: dup.before, to: &soft)

        // Scroll down from the document's first screen, where the undo left the page: a reading taken there tells nothing about the redo.
        // The page's position after the redo is only reported, so a scroll that cannot be done costs the report, not the test.
        let redoAnchor = scrollDownFromFirstScreen()
        noteAnchorBeforeRedo(redoAnchor)

        // Cmd-Shift-Z until the typing is back, with the page's position read around every press and reported at the structural one.
        let redoPresses = redoReadingScroll(from: redoAnchor)
        addSentenceInViewCheck(sentence, to: &soft)
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), expected exactly 1: "
            + "the redo depth before each press was \(redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" })")
        let words = caretWordsToLineStart()
        let lineWords = Self.dupLineOne.split(separator: " ").count + Phase4bRedoEditor.markdown.sentenceWords
        result("CARET after the last Cmd-Shift-Z: Shift-Cmd-Left selects \(words.map(String.init) ?? "nothing") word(s) back to its line start "
            + "(1...\(lineWords) means the caret sits in the typed line)")
        soft.check(words != nil && (1...lineWords).contains(words ?? 0),
            "the caret is not in the typed line after the last Cmd-Shift-Z (Shift-Cmd-Left selected \(words.map(String.init) ?? "nothing"))")
        soft.check(waitForCard(dup.copyTitle, present: true, timeout: appWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "the copy's sidebar card is not back after \(redoPresses.count) Cmd-Shift-Z press(es)")
        settle(back: [dup.copyTitle])
        let post = addRowChecks(
            "after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedUser: dup.withTyping, managed: nil, walk: false, to: &soft)
        addHeadingChecks("after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedRows: dup.withTyping, to: &soft)
        shot("redo-footnote-scroll-keep-md-end")
        result("PRESS COUNTS: Cmd-Z \(undoPresses.count), Cmd-Shift-Z \(redoPresses.count)")
        addLogChecks(from: keysFrom, editor: .markdown, putBacks: nil, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "Markdown: Duplicate the footnoted chapter, type in the copy, Cmd-Z, scroll away, renumber, polled undo / redo, "
            + "on \(size.identifier)")
    }

    func testMdDuplicateFootnoteScrollKeep_book6() { runFootnoteScrollKeep(.book6, method: #function) }
    func testMdDuplicateFootnoteScrollKeep_book12() { runFootnoteScrollKeep(.book12, method: #function) }
}

// MARK: - 8 Rich Text: typing inside a footnote definition reached through the copy's first reference

extension WriteQueuePhase4bRedoE2ETests {
    static let noteSentence = "Typed in the note."

    /// The label of the first footnote reference in the rows of `range` (reading order), nil when there is none.
    func firstFootnoteLabel(in range: Range<Int>) -> Int? {
        for row in pre[range] {
            if let label = Phase4bFlow.footnoteRefs(in: row.fragment).first { return label }
        }
        return nil
    }

    /// Clicks the footnote REFERENCE pill whose text is `label` (the superscript number) and that lies fully on screen, scrolling the editor
    /// down in steps from where the sidebar's click on the copy's card left it (the copy's heading at the top; the original's pills lie
    /// above and out of the band). The click handler of `footnote-plugin.ts` (about lines 452 to 512) moves the caret into the matching
    /// definition in the Notes and scrolls there. The copy re-references the original's footnotes by the SAME labels (two `[^19]` are two
    /// references to one note), so the definition reached is the shared one. Fails loudly as TEST-SETUP, with the visible runs, when no pill
    /// is found: a click on a leaf that is not the pill would put the caret in the body and the sentence would land in the wrong place.
    func clickFootnoteReferencePill(label: Int) -> Bool {
        let text = String(label)
        let pills = app.editorArea.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
        for round in 0..<14 {
            let editor = app.editorArea.frame
            for index in 0..<pills.count {
                let pill = pills.element(boundBy: index)
                guard pill.exists else { continue }
                let frame = pill.frame
                guard frame.width > 0, frame.minY >= editor.minY + 40, frame.maxY <= editor.maxY - 40 else { continue }
                app.waitForStableFrame(pill)
                guard pill.exists else { continue }
                let topBefore = pill.frame.minY
                app.activateAndWaitForForeground()
                pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                // The handler scrolls to the definition (smooth): wait, as a condition, until the pill has left its place.
                let deadline = Date(timeIntervalSinceNow: 6)
                var moved = false
                while !moved, Date() < deadline {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                    moved = !pill.exists || abs(pill.frame.minY - topBefore) > 20
                }
                note("FOOTNOTE: clicked the reference pill \"\(text)\" (frame \(Self.describeFrame(frame))) after \(round) scroll round(s); "
                    + "the page moved to the definition: \(Self.yesNo(moved))")
                return true
            }
            app.editorArea.scroll(byDeltaX: 0, deltaY: -450)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        }
        let values = (app.editorStaticTextValues() ?? []).prefix(12).map { String($0.prefix(40)) }
        fail("TEST-SETUP: no footnote reference pill with the text \"\(text)\" was found fully on screen below the copy's heading after 14 scrolls "
            + "(visible runs: \(values)); how the pill is exposed in the accessibility tree was not verified before this run")
        return false
    }

    /// Rich Text, a footnoted chapter ("Chapter 3"): Duplicate; click the copy's FIRST footnote reference, which puts the caret into its
    /// definition in the Notes; type "Typed in the note."; Cmd-Z until the copy is gone and Cmd-Shift-Z until the typing is back (polled, at
    /// most 6 presses each, the counts reported).
    ///
    /// WHAT IT PROVES: after a Duplicate of a footnoted chapter, typing in the footnote definition comes back after Cmd-Z twice and
    /// Cmd-Shift-Z twice (the clean case is 2 and 2; a footnote renumber that lands as a step of its own adds a press, which is why the
    /// presses are polled and the counts reported). The definition is the one the copy SHARES with the original: the app keeps only the
    /// first appearance of each footnote label (`extractFootnoteRefs`, FootnoteSyncService+Reconciliation.swift), so the copy's references
    /// point at the original's definitions and the Notes hold no definition of the copy's own (a real-app run on the six-chapter book
    /// showed the copy's first references equal the original's and no new definition rows). The test therefore types at once, with no
    /// wait for the Notes to change, into whatever definition the click reaches, and asserts only the end state: the sentence is in exactly
    /// one block row, a Notes definition row, before the undo and after the redo, and in none after the undo; the text rows are the
    /// hand-worked ones. The put-back lines that occurred are printed by `addLogChecks`.
    /// When it fails with "TEST-SETUP" the click or the landing was not what the test needs (how the reference pill is exposed in the
    /// accessibility tree was not verified before the first run); any other failure message is the finding.
    func runFootnoteDefinitionTyping(_ size: Phase4bDelSize, method: String) {
        let title = Self.chapter(3)
        let sentence = Self.noteSentence
        guard startScenario(size, method: method, editor: .richText, seed: Self.dupSeed(under: title, level: 1)),
              let range = requireSection(title), let label = firstFootnoteLabel(in: range),
              let dup = makeDuplicate(title: title, editor: .richText, copyTyped: [:]) else { return }
        note("SCENARIO (Rich Text): the footnoted chapter \"\(title)\" is duplicated; the first footnote reference clicked is \(label) "
            + "(the copy repeats the original's labels, so the definition reached is the one they share); clicking it puts the caret into "
            + "the definition in the Notes, where \"\(sentence)\" is typed at once")
        guard clickFootnoteReferencePill(label: label) else { return }
        typeNow(sentence + " ")
        var soft = Phase4bFlowSoftChecks()
        guard waitForSentenceInDatabase(sentence, timeout: 90) else {
            fail("TEST-SETUP: the sentence \"\(sentence)\" never reached the block table")
            return
        }
        let holders = readRows().filter { $0.fragment.contains(sentence) }
        let holderTexts = holders.map { "\($0.isNotes ? "Notes" : "text") row \"\($0.fragment.prefix(60))\"" }
        note("LANDING: \(holders.count) row(s) hold the sentence: \(holderTexts)")
        guard holders.count == 1, holders[0].isNotes else {
            fail("TEST-SETUP: the sentence did not land in one Notes definition (\(holders.count) row(s) hold it; Notes rows among them: "
                + "\(holders.filter(\.isNotes).count)): the click on the reference pill did not put the caret into its definition")
            return
        }
        settle()
        let keysFrom = traceLinesCount()
        let undoPresses = undoUntilStructural()
        reportPresses("undo", undoPresses)
        soft.check(undoPresses.last?.isStructural == true && undoPresses.last?.performed == true,
            "the copy was not removed by a structural Cmd-Z within \(Self.pressCap) presses (\(undoPresses.map(\.summary)))")
        soft.check(waitForCard(dup.copyTitle, present: false, timeout: appWait(size.operationTimeout * 2, before: "the copy's card leaves")),
            "the copy's sidebar card is still in the Outline after \(undoPresses.count) Cmd-Z press(es)")
        soft.check(waitForSentenceGone(sentence, timeout: 120), "the sentence is still in the block table after \(undoPresses.count) Cmd-Z press(es)")
        settle(gone: [dup.copyTitle])
        addRowChecks("after \(undoPresses.count) Cmd-Z press(es)", expectedUser: dup.before, managed: nil, walk: false, to: &soft)

        let redoPresses = redoUntilTypingBack()
        reportPresses("redo", redoPresses)
        let count = waitForSentenceCount(sentence, equalTo: 1, timeout: 120)
        soft.check(count == 1, "the sentence is in \(count) block row(s) after \(redoPresses.count) Cmd-Shift-Z press(es), expected exactly 1 "
            + "(inside the footnote definition): the redo depth before each press was "
            + "\(redoPresses.map { "\($0.decision) \($0.redoDepth.map(String.init) ?? "n/a")" })")
        soft.check(waitForCard(dup.copyTitle, present: true, timeout: appWait(size.operationTimeout * 2, before: "the copy's card is back")),
            "the copy's sidebar card is not back after \(redoPresses.count) Cmd-Shift-Z press(es)")
        settle(back: [dup.copyTitle])
        let post = addRowChecks(
            "after \(redoPresses.count) Cmd-Shift-Z press(es)", expectedUser: dup.withTyping, managed: nil, walk: false, to: &soft)
        let after = post.filter { $0.fragment.contains(sentence) }
        soft.check(after.count == 1 && after[0].isNotes && Phase4bFlow.definition(after[0].fragment) != nil,
            "after the redo the sentence is not inside one footnote definition of the Notes (\(after.count) row(s) hold it; "
            + "\(after.map { "\($0.isNotes ? "Notes" : "text") \"\($0.fragment.prefix(50))\"" }))")
        shot("redo-footnote-definition-rt-end")
        result("PRESS COUNTS: Cmd-Z \(undoPresses.count), Cmd-Shift-Z \(redoPresses.count) (the clean case is 2 and 2)")
        addLogChecks(from: keysFrom, editor: .richText, putBacks: nil, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "at the end", to: &soft)
        assertSoft(soft, "Rich Text: Duplicate the footnoted chapter, type in the footnote definition reached from the copy's first reference, "
            + "polled Cmd-Z / Cmd-Shift-Z, on \(size.identifier)")
    }

    /// Hand test, Rich Text: right-click the card of a footnoted chapter, Duplicate Section, click the first footnote reference of the copy
    /// (the caret goes into the footnote's definition in the Notes), type "Typed in the note.", Cmd-Z, Cmd-Z (the sentence goes, then the
    /// copy), Cmd-Shift-Z, Cmd-Shift-Z (the copy is back, then the sentence, once, in the footnote definition the copy shares with the original).
    func testRtDuplicateSharedFootnoteDefinitionTyping_book6() { runFootnoteDefinitionTyping(.book6, method: #function) }
}
