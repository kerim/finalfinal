//
//  WriteQueuePhase4bMarkdownEFE2ETests+Drag.swift
//  final finalUITests
//
//  bt task t-4a8fd8af, SLICE 2 (VM test authoring, batch 1): THE MARKDOWN-MODE SIDEBAR DRAG-REORDER, editor first, proven in the real app.
//  In Markdown mode (View > Switch to Markdown, Cmd-/) dragging an Outline card used to take the OLD body: the database was reordered, the
//  text was built again from the rows and pushed back over the editor (typing could be lost, an earlier Delete lost its quick Cmd-Z, and the
//  footnote numbers were left out of order: board t-8dc76a0b). Now the CodeMirror page moves the section's text in ONE transaction that takes
//  the typing so far and the caret with it, the Outline shows the new order at once, and a queued job (`SectionReorderJob`) makes the rows
//  agree behind anything typed; the shared settle renumbers the footnotes; Cmd-Z / Cmd-Shift-Z are the queued slow route and a Delete made
//  before the drag stays quick-undoable. The design record is in .claude/superdev/write-queue-phase4b-markdown-drag/ (plan-v2.md "Real-app
//  tests", plan-v2.1-addendum.md, judge-plan-round1.md Q5) and in docs/architecture/document-writer.md.
//
//  THIS FILE is an extension of `WriteQueuePhase4bMarkdownEFE2ETests` (same class, same helpers, same fixture generators and conventions;
//  one class so vmtest's retry-refusal streak keys stay per method). Its tests:
//    testMdDragMovesAtOnceAndPersists_{article,book6}   E-D1  the page moves the text first (rows still old, Outline new), the rows follow
//                                                              after the job, Cmd-W and reopen keep the order and the word total
//    testMdTypeDragTypePersists_{book6,book12}          E-D2  type, drag, type again at once with no click; both sentences, the order and
//                                                              the word total survive Cmd-W and reopen (job held 30 s, order proven by the log)
//    testMdDragFootnotesRenumbered_{book6,book12}       E-D3  Option-drag of a footnoted chapter: references 1..N in reading order (no jump
//                                                              back), Notes 1..N once each tied to their references, after the drag, Cmd-Z,
//                                                              Cmd-Shift-Z and a reopen (t-8dc76a0b)
//    testMdDeleteDragUndoUndo_book6                     E-D9  Delete, drag, Cmd-Z (the drag, slow route), Cmd-Z (the Delete, QUICK route)
//  BATCH 2 (appended to this file because scripts/e2e-hygiene.sh allows one new permanent UI-test file per branch):
//    testMdTypeAroundDrop_book6                         E-D6  type in the chapter to move, put the caret in the hopped-over chapter, drag,
//                                                              type with no click while the job is held (each sentence in its own chapter)
//    testMdDragLastChapterBeforeNotes_book12            E-D7  the last chapter above its neighbour, then a chapter to the last place (end
//                                                              drop): Notes and Bibliography stay last, no heading glued, footnotes 1..N
//    testMdDragChangesHeadingLevel_book6                E-D8  a drop that changes the heading level: `#` marks in page and rows, Cmd-Z
//                                                              restores it, Cmd-Shift-Z and a reopen keep it
//    testMdUndoOrderAfterTypingFollowingDrop_book6      E-D10 drag, type in the moved chapter, Cmd-Z x2, Cmd-Shift-Z x2 (since t-14f908b4 the
//                                                              typing comes back inside the moved chapter, once; it pinned the old limit)
//    testMdLevelOnlyAndOptionDropWithTyping_book6       E-D11 a level-only drop in place and an Option-drag with its sub-sections, each
//                                                              after typing in the moved chapter
//  BATCH 3 (judge items on the repeated-footnote book6; NO tagged notes, on purpose):
//    testMdDragSaveVersionAndCloseAtOnce_book6          E-D12 Option-drag, File > Save Version at once, Cmd-W at once, reopen: Notes and
//                                                              references 1..54 in order in the saved rows (order of events from the log)
//    testMdDragNotesStalePathForced_book6               E-D13 the stale Notes push: log sequence `re-push owed` -> second `notes rebuild:
//                                                              starts` -> page docChanged RECORDED only; Notes 1..54 in page, rows, reopen
//    testMdTwoDragsInARowThenUndoTwice_book6            E-D14 two drags in a row (the second given while the first job is held), Cmd-Z x2:
//                                                              order, footnotes 1..N and the hold at every step; Save Version, reopen
//  Batch 2 flattened copies: E-D6, E-D8, E-D10 use book6 with chapters 1, 3, 5, 6 flat; E-D11 the same (Chapter 4 keeps its 16 sub-sections
//  for the Option-drag); E-D7 uses book12 with chapters 1, 3, 5 to 12 flat (`flatBook12Tail`). E-D6, E-D10 and E-D11 seed one plain line
//  ("Move06 line of the fixture document.", "Hop05 ...", "Opt04 ...") right under a chapter heading so a caret can be put inside that chapter.
//  (E-D4 is `testMdDragThenDeleteThenUndo_book6` in WriteQueuePhase4bMarkdownEFE2ETests.swift, E-D5 is `testReorderEFMarkdown_article` in
//  WriteQueuePhase4bReorderEditorFirstE2ETests.swift: both are the flipped slice-1 / Rich Text tests of the old road.)
//
//  THE DOCUMENTS (generated, never a manuscript; the fixture tag in every note and the counts line in every failure message carry them):
//    article  x1 chapter:    68 citation groups,   9 footnote marks, 30 comment/task/reference marks, a block quote, Chinese text in every
//                            second paragraph and in half the footnote definitions, a generated bibliography
//    book6    x6 chapters:  408 citation groups,  54 footnote marks, 180 comment/task/reference marks, the same prose in every chapter
//    book12   x12 chapters: 816 citation groups, 108 footnote marks, 360 comment/task/reference marks
//  FLATTENED COPIES (a drag needs two neighbouring cards on screen; the sidebar's visible band is about 585 pt and XCUITest cannot scroll
//  during a drag): THE TESTS THAT USE A FLATTENED COPY ARE ALL OF THEM EXCEPT `..._article` (which uses the unflattened article):
//    book6:  chapters 1, 3, 5 and 6 flat  (`flatBook6`)  chapters 2 and 4 keep their 16 sub-sections (E-D3 Option-drags Chapter 4)
//    book12: chapters 1, 3, 5, 6, 7, 8 flat (`flatBook12`) chapters 2, 4, 9, 10, 11, 12 keep theirs (E-D3 Option-drags Chapter 9)
//  The flattened copies turn the `##` / `###` marks of those chapters into plain lines; words, citations and footnotes are unchanged.
//  The tests never touch the read-only master copies of the test books: every document is generated into the test's own fixture copy.
//
//  FOOTNOTES IN THE FIXTURES: every chapter holds nine footnote references, numbered (chapter - 1) * 9 + 1 ... chapter * 9, so book6 holds 54
//  and book12 108. Dragging Chapter 4 (28...36) above Chapter 3 (19...27) leaves the references reading 1...18, 28...36, 19...27, 37...54 until
//  the app renumbers them; dragging Chapter 9 (73...81) above Chapter 8 (64...72) leaves 1...63, 73...81, 64...72, 82...108. E-D3 states the
//  count in its failure message and refuses to run (TEST-SETUP) if the chosen drag would not scramble the numbers.
//
//  THE MECHANISM LINES (the new click writes them; an unchanged old-body app writes a plain `start` and no editor-first line, so every test
//  below fails on it):
//    [STRUCT-TRACE] t=.. +..ms sectionReorder op=<id8> start (editor-first) mode=markdown
//    [STRUCT-TRACE] reorder-editor-first opId=<id8> ok=true mode=markdown skipped=<n> levels=<n>     (the page's reply)
//    [STRUCT-TRACE] t=.. +..ms sectionReorder op=<id8> performed
//    [STRUCT-TRACE] markdown-reorder <detail>                                                         (the page's own line)
//  plus the hold pair `[MdWrite] structural hold raised/released`. ZERO `fell back` / `refused` steps, ZERO plain `start` lines.
//
//  WAITS: every wait is a condition (a log line, a database row, the sidebar, a status-bar label). A second user action "at once" cannot be
//  given by XCUITest in the slow VM (about 10 s between two clicks), so no test tries to race: where the order of events matters it is
//  proven by the app's log (E-D2) or by the 30 s hold of the first job (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS` with `..._FIRST_N=1`, the seam of
//  `testMdDeleteThenDeleteHeld_book6`: it blocks the writer past the 5 s content-state watchdog, so these tests RECORD the whole-document
//  push count instead of asserting it and always end with the screen-equals-database check).
//
//  RUNNING (VM only; every vmtest call needs the sandbox off; at most two runs at once; several --scope flags make one run):
//    scripts/vmtest/vmtest run --detach --timeout 1800 \
//      --scope "final finalUITests/WriteQueuePhase4bMarkdownEFE2ETests/testMdDragMovesAtOnceAndPersists_article"
//    book6 runs take 1800 to 3600 s, book12 runs 3600 to 7000 s.
//

// swiftlint:disable file_length
import AppKit
import XCTest

// MARK: - What a test drags

/// The two sections a drag test moves, the drop level and the flat chapters of the copy.
struct Phase4bMdDragPair {
    /// The section dragged.
    let moved: String
    /// The section it is dropped just BEFORE (the pointer is let go on the card right above this one).
    let target: String
    /// The heading level the drop aims at.
    let level: Int
    /// The chapters turned into plain lines in the seed (empty: the unflattened document).
    let flat: [Int]
}

/// A drag whose geometry is worked out (the cards are on screen, the drop point is known) but whose press has NOT been made yet, so a test
/// can type and press the very next thing without an accessibility query in between.
struct Phase4bMdDrag {
    let moved: String
    /// The card the pointer is let go on (the heading right above `target` in the block table).
    let dropOn: String
    let target: String
    let option: Bool
    let level: Int
    let cards: [XCUIElement]
    let dropPoint: XCUICoordinate
}

/// What the log says about the window in which the first job was held (E-D1, E-D2).
struct Phase4bMdJobWindow {
    /// The log index of the `onReserved fired` line of the drag's op.
    let reservedIndex: Int?
    /// The log index of the first `[MdWrite] structural hold released` line after it (the job applied and the live text flushed).
    let releasedIndex: Int?
    /// Seconds from the reserve line to the release line, by the log's stamps.
    let heldSeconds: Double?
}

/// One reading of the editor's accessibility tree for the Notes (`notesLabelsOnScreen`).
struct Phase4bNotesReading {
    /// The footnote labels `[^N]:` of the definitions the tree lists, in tree order (empty: none could be read).
    let labels: [Int]
    /// One line per node of the tree (type, label, value; the first 200 nodes), the evidence kept when no label could be read.
    let dump: [String]
}

// MARK: - Choosing the drag, and the document worked out by hand

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// A plain drag of a chapter with no sub-sections (or of the article's closing section, which has none) above its neighbour.
    static func dragPair(_ size: Phase4bDelSize) -> Phase4bMdDragPair {
        switch size {
        case .article:
            return Phase4bMdDragPair(moved: "1.6 Conclusion", target: "1.5 Lanterns After Dark", level: 2, flat: [])
        case .book6:
            return Phase4bMdDragPair(moved: chapter(6), target: chapter(5), level: 1, flat: flatBook6)
        case .book12:
            return Phase4bMdDragPair(moved: chapter(7), target: chapter(6), level: 1, flat: flatBook12)
        }
    }

    /// The Option-drag of E-D3: a footnoted chapter WITH its 16 sub-sections above its flat neighbour.
    static func footnoteDragPair(_ size: Phase4bDelSize) -> Phase4bMdDragPair {
        size == .book12
            ? Phase4bMdDragPair(moved: chapter(9), target: chapter(8), level: 1, flat: flatBook12)
            : Phase4bMdDragPair(moved: chapter(4), target: chapter(3), level: 1, flat: flatBook6)
    }

    /// The fixture's counts for a failure message: chapters, words, citation groups, footnote marks, comment / task / reference marks,
    /// headings, Chinese characters and characters (the seed's own counts; the flattened copy's headings are fewer).
    var countsLine: String {
        "FIXTURE \(size.identifier): \(size.chapters) chapter(s); \(doc?.counts.reportLine ?? "counts n/a")"
    }

    /// The saved user rows (Notes and Bibliography left out), each with its number in `pre`.
    func dragUserRows() -> [Phase4bRqRow] {
        pre.enumerated().filter { !$0.element.isManaged }.map { Phase4bRqRow(id: $0.offset, row: $0.element) }
    }

    /// `rows` with the section titled `title` (its heading and everything up to the next heading of the same or a higher level, so its
    /// sub-sections go with it) taken out and put before the section titled `target` (nil: at the end of the user rows, before Notes).
    func dragMoving(_ rows: [Phase4bRqRow], _ title: String, before target: String?) -> [Phase4bRqRow] {
        guard let start = rows.firstIndex(where: { $0.row.headingTitle == title }), let level = rows[start].row.headingLevel else { return rows }
        var end = start + 1
        while end < rows.count, !(rows[end].row.headingLevel.map { $0 <= level } ?? false) { end += 1 }
        let run = Array(rows[start..<end])
        var rest = rows
        rest.removeSubrange(start..<end)
        let insertionIndex = target.flatMap { name in rest.firstIndex { $0.row.headingTitle == name } } ?? rest.count
        rest.insert(contentsOf: run, at: insertionIndex)
        return rest
    }

    /// `rows` without the rows of the section titled `title` (as `pre` holds it): the document after that section was deleted.
    func dragWithout(_ rows: [Phase4bRqRow], section title: String) -> [Phase4bRqRow] {
        guard let range = section(title) else { return rows }
        return rows.filter { !range.contains($0.id) }
    }

    /// The rows as the document should hold them; `typed` replaces the whole text of the rows named by their number in `pre`.
    func dragRows(_ rows: [Phase4bRqRow], typed: [Int: String] = [:]) -> [Phase4bFlowRow] {
        rows.map { item in
            guard let text = typed[item.id] else { return item.row }
            return Phase4bFlowRow(type: item.row.type, isNotes: false, isBibliography: false, fragment: text)
        }
    }

    /// The heading rows of `rows` as the block table writes them (`## 3.6 Conclusion`), in order.
    func dragHeadings(_ rows: [Phase4bRqRow]) -> [String] {
        rows.filter { $0.row.headingLevel != nil }.map { $0.row.fragment.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The texts of the footnote definitions the document `arrangement` must carry: the definitions of its references in reading order
    /// (the app renumbers them 1...n and keeps each one's own words).
    func dragDefinitionTexts(_ arrangement: [Phase4bRqRow]) -> [String] {
        var textByNumber: [Int: String] = [:]
        for row in pre { if let found = Phase4bFlow.definition(row.fragment) { textByNumber[found.number] = found.text } }
        return arrangement.flatMap { Phase4bFlow.footnoteRefs(in: $0.row.fragment) }.compactMap { textByNumber[$0] }
    }

    /// TEST-SETUP: a PLAIN drag moves only the card's own section, so the moved section must have no sub-heading (the hand-worked document
    /// then equals an Option-drag's). False after a reported failure.
    func requireChildless(_ title: String) -> Bool {
        guard let range = section(title) else { return false }
        let deeper = pre[range].dropFirst().filter { $0.headingLevel != nil }.count
        guard deeper == 0 else {
            fail("TEST-SETUP: \"\(title)\" has \(deeper) sub-heading(s); a plain drag would leave them behind (use an Option-drag). \(countsLine)")
            return false
        }
        return true
    }

    /// The first difference between `expected` and the block table's heading list now (for a failure message).
    func orderDifference(_ expected: [String]) -> String { firstDifference(expected, headingFragmentsInDatabase()) }

    /// A reading as text for a message: the number, or "n/a" when it could not be read.
    func figure(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }

    /// The heading right above `target` in the block table (nil for the first heading).
    func headingAbove(_ target: String) -> String? {
        let titles = headingFragmentsInDatabase().map { Self.title($0) }
        guard let index = titles.firstIndex(of: target), index > 0 else { return nil }
        return titles[index - 1]
    }
}

// MARK: - Dragging a card: prepare, then press

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Works out a drag of the card `moved` to just before the heading `target` (a drop on the card ABOVE `target`: the title text always lies
    /// below 30% of its card, so a drop on it is an "insert after" and a drop on `target`'s own title could never be an "insert before"; both
    /// end in the same request) at heading level `level`. The cards are brought into the sidebar's visible band and the drop point is
    /// computed as `dragCard` computes it; nothing is pressed. Nil after a reported failure.
    func prepareDrag(
        _ moved: String, before target: String, level: Int = 1, option: Bool, dropY: CGFloat = 0.5
    ) -> Phase4bMdDrag? {
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
        let dropPoint = dropCard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: dropY))
            .withOffset(CGVector(dx: screenX - dropCard.frame.minX, dy: 0))
        let point = dropPoint.screenPoint
        note("DRAG PREPARED: \"\(moved.prefix(40))\" \(option ? "with its sub-sections (Option)" : "alone") to just before \"\(target.prefix(40))\" "
            + "(dropped on the card of \"\(dropOn.prefix(40))\") at level \(level): pointer ends at (\(Int(point.x)), \(Int(point.y))) in the "
            + "sidebar \(Self.describeFrame(scroll.frame)); predecessor level \(predecessorLevel); dragged card "
            + "\(Self.describeFrame(cards[0].frame)); drop card \(Self.describeFrame(dropCard.frame))")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        return Phase4bMdDrag(
            moved: moved, dropOn: dropOn, target: target, option: option, level: level, cards: cards, dropPoint: dropPoint)
    }

    /// Presses the dragged card and lets it go on the prepared drop point: nothing else is done first. With `option` the sub-sections go with
    /// it (Option held around the press-and-drag with `XCUIElement.perform(withKeyModifiers:)`; Option-drag was proven in the VM by the Rich
    /// Text reorder tests, and every Option-drag test here compares the whole heading list, so a modifier that did not reach the drag fails
    /// by name in `addOptionCarriedCheck`). The app-log index just before the press.
    func performDrag(_ drag: Phase4bMdDrag) -> Int {
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let grab = drag.cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let gesture = { grab.press(forDuration: 0.5, thenDragTo: drag.dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3) }
        if drag.option { XCUIElement.perform(withKeyModifiers: .option, block: gesture) } else { gesture() }
        return from
    }

    /// After an Option-drag of a section that has sub-headings: in the block table the moved heading must be followed directly by its OWN
    /// first sub-heading (`expected` is the hand-worked heading list, in which it is). A plain drag moves the heading alone and leaves its
    /// sub-sections behind, which is what a modifier that never reached the synthesized mouse-down would produce. The block table is waited
    /// for (a condition) to reach `expected` first.
    func addOptionCarriedCheck(_ moved: String, expected: [String], what: String, to soft: inout Phase4bFlowSoftChecks) {
        let titles = expected.map { Self.title($0) }
        guard let place = titles.firstIndex(of: moved), place + 1 < expected.count, Self.level(expected[place + 1]) > Self.level(expected[place])
        else { return }
        let child = titles[place + 1]
        _ = waitForHeadingOrder(expected, timeout: appWait(size.operationTimeout * 2, before: "\(what): the Option-drag is looked for"))
        let found = headingFragmentsInDatabase().map { Self.title($0) }
        let next = found.firstIndex(of: moved).flatMap { $0 + 1 < found.count ? found[$0 + 1] : nil }
        result("OPTION-DRAG \(what): \"\(moved.prefix(40))\" is followed in the block table by \(next.map { "\"\($0.prefix(40))\"" } ?? "nothing"); "
            + "its own first sub-heading is \"\(child.prefix(40))\"")
        soft.check(next == child, "\(what): the Option key did not reach the drag: only the heading moved (\"\(moved)\" is followed by "
            + "\"\(next ?? "nothing")\" instead of its own first sub-heading \"\(child)\")")
    }

    /// True once the sidebar lists the card `upper` above the card `lower` (a condition, polled): the Outline shows the dragged order at once,
    /// before the database holds it.
    func waitForSidebarAbove(_ upper: String, _ lower: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let first = sidebarCard(upper)
            let second = sidebarCard(lower)
            if first.exists, second.exists, first.frame.minY < second.frame.minY { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }
}

// MARK: - Checks: the saved rows against the hand-worked document

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// What is wrong with a saved document against the hand-worked `arrangement` (the user rows in their final order; `typed` replaces whole
    /// rows): the text rows (footnote numbers read as `[^#]`), the Bibliography rows when `bibliographyExact`, the footnote walk (references
    /// 1...n in reading order, definitions 1...n once each, none blank) and the TEXTS of the definitions in reading order (each note tied to
    /// its reference; a seed that tags its notes makes the texts unique). Empty: nothing.
    func dragProblems(
        _ post: [Phase4bFlowRow], arrangement: [Phase4bRqRow], typed: [Int: String], bibliographyExact: Bool, what: String
    ) -> [String] {
        var found: [String] = []
        let expectedUser = dragRows(arrangement, typed: typed).enumerated().map { (row: $0.offset, value: $0.element) }
        let actualUser = post.enumerated().filter { !$0.element.isManaged }.map { (row: $0.offset, value: $0.element) }
        let userLines = Phase4bFlow.rowDifferences(expected: expectedUser, actual: actualUser, exact: false)
        recordDifferences(what, "text rows", userLines)
        found += userLines.map { "text rows: \($0)" }
        if bibliographyExact {
            let before = pre.enumerated().filter { $0.element.isBibliography }.map { (row: $0.offset, value: $0.element) }
            let after = post.enumerated().filter { $0.element.isBibliography }.map { (row: $0.offset, value: $0.element) }
            let lines = Phase4bFlow.rowDifferences(expected: before, actual: after, exact: true)
            recordDifferences(what, "Bibliography rows", lines)
            found += lines.map { "the Bibliography rows differ from before: \($0)" }
        }
        let walk = Phase4bFlowWalk(rows: post)
        found += walk.problems.map { "footnotes: \($0)" }
        let textLines = Phase4bFlow.differenceLines(dragDefinitionTexts(arrangement), walk.definitions.map(\.text))
        recordDifferences(what, "footnote definition texts", textLines)
        found += textLines.map { "the footnote definition texts are not those of the references, in reading order: \($0)" }
        return found
    }

    /// Reads the block table, adds every problem of `dragProblems` to `soft` and notes the sizes beside the verdict. Returns the rows read.
    @discardableResult
    func addDragChecks(
        _ what: String, arrangement: [Phase4bRqRow], typed: [Int: String] = [:], bibliographyExact: Bool,
        to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        let post = readRows()
        let walk = Phase4bFlowWalk(rows: post)
        let problems = dragProblems(post, arrangement: arrangement, typed: typed, bibliographyExact: bibliographyExact, what: what)
        note("\(what): \(post.count) block rows (\(pre.count) before), footnotes \(walk.summary), reference runs [\(Self.ascendingRuns(walk.refs))]; "
            + "\(problems.count) problem(s)")
        for problem in problems { soft.check(false, "\(what): \(problem)") }
        return post
    }

    /// E-D3: the footnote references of the saved rows read 1...`count` in reading order with NO jump back, and the Notes hold the numbers
    /// 1...`count` once each, in order. Both are also part of `dragProblems`; this check names the failure in the words of t-8dc76a0b and
    /// prints the runs ("1...36, 46...54, 37...45" is the old Markdown drag's answer).
    func addFootnoteOrderCheck(_ what: String, rows: [Phase4bFlowRow], count: Int, to soft: inout Phase4bFlowSoftChecks) {
        let walk = Phase4bFlowWalk(rows: rows)
        let wanted = Array(stride(from: 1, through: count, by: 1))
        result("FOOTNOTES \(what): \(walk.refs.count) reference(s) in reading order, runs [\(Self.ascendingRuns(walk.refs))]; Notes numbered "
            + "[\(Self.ascendingRuns(walk.definitions.map(\.number)))] (expected 1...\(count))")
        soft.check(walk.refs == wanted, "\(what): the footnote references read [\(Self.ascendingRuns(walk.refs))] in reading order, "
            + "expected 1...\(count) with no jump back (t-8dc76a0b: the old Markdown drag left e.g. 1...36, 46...54, 37...45); \(countsLine)")
        let noteRuns = Self.ascendingRuns(walk.definitions.map(\.number))
        soft.check(walk.definitions.map(\.number) == wanted,
            "\(what): the Notes hold the numbers [\(noteRuns)], expected 1...\(count) once each, in order")
    }

    /// What the editor's accessibility tree lists of the Notes definitions after a click on the Notes card (the editor scrolls there). Nil
    /// when the card could not be brought into view. Polled (a condition, bounded by the test's budget) until a definition label is read;
    /// when none can be read in 30 s the last reading comes back with no label (and its tree dump).
    func notesLabelsOnScreen() -> Phase4bNotesReading? {
        guard let notesCard = bringSidebarCardIntoView("Notes", failIfMissing: false) else { return nil }
        app.activateAndWaitForForeground()
        notesCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let deadline = Date(timeIntervalSinceNow: capped(30))
        var reading = readNotesFromTree()
        while reading.labels.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            reading = readNotesFromTree()
        }
        return reading
    }

    /// One reading of the editor's tree from ONE snapshot (one accessibility round trip, walked in-process): the labels of the definitions
    /// among its text runs, and a dump of its first nodes. A snapshot that fails is printed and reads as no label (the caller polls again).
    func readNotesFromTree() -> Phase4bNotesReading {
        let root: XCUIElementSnapshot
        do {
            root = try app.editorArea.snapshot()
        } catch {
            print("[notesLabelsOnScreen] snapshot() of editor-area failed: \(error)")
            return Phase4bNotesReading(labels: [], dump: ["(the snapshot of editor-area failed: \(error))"])
        }
        let nodes = Self.snapshotNodes(of: root)
        let runs = nodes.compactMap { node -> String? in node.elementType == .staticText ? node.value as? String : nil }
        let dump = nodes.prefix(200).map { node -> String in
            let value = node.value.map { String(describing: $0) } ?? "nil"
            return "[type \(node.elementType.rawValue)] label \"\(node.label.prefix(90))\" value \"\(value.prefix(90))\""
        }
        return Phase4bNotesReading(labels: Self.definitionLabels(inRuns: runs), dump: dump)
    }

    /// Every node below `snapshot` (the root itself left out), in tree order.
    static func snapshotNodes(of snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        snapshot.children.flatMap { child -> [XCUIElementSnapshot] in [child] + snapshotNodes(of: child) }
    }

    /// The footnote labels of the definitions (`[^N]:` at the start of a Notes line) among the text runs `runs` of the editor, in order.
    /// The labels are looked for in the runs JOINED, not run by run: the editor marks a definition's `[^N]:` prefix with a decoration (so it
    /// is a run of its own), and the syntax colouring can cut a label into pieces (`[^1]` and `:`), which a run-by-run read never sees.
    static func definitionLabels(inRuns runs: [String]) -> [Int] {
        let joined = runs.joined()
        guard let pattern = try? NSRegularExpression(pattern: #"\[\^(\d+)\]:"#) else { return [] }
        let text = joined as NSString
        return pattern.matches(in: joined, range: NSRange(location: 0, length: text.length))
            .compactMap { Int(text.substring(with: $0.range(at: 1))) }
    }

    /// The Notes the editor SHOWS: no label twice and the labels in step (each one more than the one before). The editor draws only the
    /// definitions near the viewport, so this is a window onto the list.
    ///
    /// The labels come from the accessibility tree. The old reader (one run per label) read none while the failure screenshot of the same
    /// state showed "# Notes" with [^1] and [^2] (t-1268b095); the reader below joins the runs and so also reads a label the editor has cut
    /// into pieces. No label read within 30 s of the click on the Notes card is a FAILURE: the line below records it, the tree's first nodes
    /// and the screenshot are attached, and together they show on their own whether the editor did not scroll to the Notes or the reader is
    /// broken. The Notes' text itself is also asserted AFTER this check without the tree: the saved rows (`addDragChecks`: Notes numbered
    /// 1...N once each, in order) and `addScreenEqualsDatabaseCheck` (File > Save Version writes the live editor text into the table, and
    /// the table must be identical to the saved rows).
    func addNotesOnScreenCheck(_ what: String, to soft: inout Phase4bFlowSoftChecks) {
        guard let reading = notesLabelsOnScreen() else {
            result("NOTES ON SCREEN \(what): the Notes card could not be brought into view (not asserted)")
            return
        }
        let shotName = "md-drag-notes-on-screen-\(what.replacingOccurrences(of: " ", with: "-"))"
        let labels = reading.labels
        guard !labels.isEmpty else {
            result("NOTES ON SCREEN \(what): NOT READABLE: the accessibility tree listed no definition label in 30 s (FAILED below; the tree's "
                + "first \(reading.dump.count) node(s) and the screenshot are attached)")
            attachText("notes-on-screen-tree-\(methodName)-\(what.replacingOccurrences(of: " ", with: "-")).txt",
                reading.dump.joined(separator: "\n"))
            shot(shotName)
            soft.check(false, "\(what): no Notes definition label in the editor's tree 30 s after a click on the Notes card (tree dump and "
                + "screenshot attached: they show whether the editor did not scroll to the Notes or the reader is broken)")
            return
        }
        let duplicates = Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let consecutive = zip(labels, labels.dropFirst()).allSatisfy { $0.1 == $0.0 + 1 }
        result("NOTES ON SCREEN \(what): \(labels.count) definition label(s) visible \(labels); duplicates \(duplicates); consecutive \(consecutive)")
        soft.check(duplicates.isEmpty, "\(what): the Notes in the editor show duplicate definition label(s) \(duplicates)")
        soft.check(consecutive,
            "\(what): the Notes labels visible in the editor are not consecutive: \(labels) (t-9cf4d7e8: the on-screen Notes list can stay out of "
            + "number order after a renumber)")
        shot(shotName)
    }
}

// MARK: - Checks: what the app's log says

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// The editor-first reorder's success lines since `index` (the page's reply, written by the Swift click): `[STRUCT-TRACE]
    /// reorder-editor-first opId=<id8> ok=true mode=markdown skipped=<n> levels=<n>`.
    func reorderOkLines(from index: Int) -> [String] {
        logLines(containing: "[STRUCT-TRACE] reorder-editor-first opId=", from: index).map(\.text)
            .filter { $0.contains(" ok=true") && $0.contains("mode=markdown") }
    }

    /// The op id of the first `sectionReorder` sequence that began since `index`.
    func reorderOpId(from index: Int) -> String? {
        traceLines(from: index).first { $0.family == .sequence && $0.label == "sectionReorder" && $0.isOpStart }?.opId
    }

    /// The index of the first log line since `index` that holds every needle (nil when there is none).
    func mdLogIndex(containing needles: [String], from index: Int) -> Int? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return tail.lines[index...].firstIndex { line in needles.allSatisfy { line.text.contains($0) } }
    }

    /// The first key press the app saw in the editor since `index`.
    func firstEditorKeyLine(from index: Int) -> Phase4bLogLine? {
        tail.poll()
        guard index <= tail.lines.count else { return nil }
        return tail.lines[index...].first { Phase4bDelTypingParser.key($0.text)?.inEditor == true }
    }

    /// The window of the held first job: from the drag op's `onReserved fired` line to the next hold release.
    func jobWindow(opId: String, from index: Int) -> Phase4bMdJobWindow {
        let reserved = mdLogIndex(containing: ["sectionReorder op=\(opId)", "onReserved fired"], from: index)
        let released = reserved.flatMap { mdLogIndex(containing: ["[MdWrite] structural hold released"], from: $0) }
        var seconds: Double?
        if let reserved, let released, let start = tail.lines[reserved].date, let end = tail.lines[released].date {
            seconds = end.timeIntervalSince(start)
        }
        return Phase4bMdJobWindow(reservedIndex: reserved, releasedIndex: released, heldSeconds: seconds)
    }

    /// The facts about `drags` editor-first Markdown drags since `index`, printed and added to `soft`: every `sectionReorder` sequence began
    /// `start (editor-first) mode=markdown` and NONE began with the old body's plain `start`; the page's reply line `reorder-editor-first ...
    /// ok=true mode=markdown` is there once per drag, after its op's start line and before its `performed` line; no `fell back` /
    /// `refused` step and no fallback line; the page threw nothing; and nothing wiped the undo timeline (`invalidateAll`).
    func addDragTraceChecks(from index: Int, drags: Int, to soft: inout Phase4bFlowSoftChecks) {
        let traces = traceLines(from: index).filter { $0.family == .sequence && $0.label == "sectionReorder" }
        let starts = traces.filter { $0.isOpStart }
        let plain = starts.filter { $0.step == "start" }
        let editorFirst = starts.filter { $0.step == "start (editor-first) mode=markdown" }
        let fellBack = traces.filter { $0.step.hasPrefix("fell back") || $0.step.hasPrefix("refused") }
        let performed = traces.filter { $0.step == "performed" }
        let replies = reorderOkLines(from: index)
        let pageLines = logLines(containing: "[STRUCT-TRACE] markdown-reorder ", from: index).map(\.text)
        let pageErrors = pageLines.filter { $0.contains("threw") }
        let wiped = logLines(containing: "[UnifiedUndoService] invalidateAll:", from: index).map(\.text)
        let fallbacks = fallbackEvidence(from: index)
        result("DRAG TRACE: sectionReorder start line(s) \(starts.map { "op=\($0.opId) \($0.step)" }) (expected \(drags) `start (editor-first) "
            + "mode=markdown`, 0 plain `start`); `reorder-editor-first ... ok=true mode=markdown` line(s) \(replies.count); "
            + "performed \(performed.count); "
            + "fell back/refused \(fellBack.count); the page's own lines \(pageLines.count) (errors \(pageErrors.count)); "
            + "`invalidateAll` lines \(wiped.count); fallback lines \(fallbacks.count)")
        soft.check(editorFirst.count == drags, "\(editorFirst.count) `sectionReorder ... start (editor-first) mode=markdown` line(s), expected "
            + "\(drags) (the sequences began \(starts.map(\.step))): the Markdown drag did not take the editor-first road")
        soft.check(plain.isEmpty, "\(plain.count) plain `start` line(s) of a sectionReorder: a Markdown drag took the OLD body")
        soft.check(replies.count == drags,
            "\(replies.count) `reorder-editor-first ... ok=true mode=markdown` line(s), expected \(drags): the page did not answer ok")
        soft.check(performed.count == drags, "\(performed.count) `sectionReorder ... performed` line(s), expected \(drags)")
        soft.check(fellBack.isEmpty, "\(fellBack.count) `fell back` / `refused` step(s): \(fellBack.map(\.step))")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
        soft.check(pageErrors.isEmpty, "the page threw while moving the section: \(pageErrors.prefix(2))")
        soft.check(wiped.isEmpty, "the undo timeline was wiped (`invalidateAll`) since the drag began: \(wiped.prefix(2))")
        // The order per op: start, then the page's reply, then performed.
        for start in editorFirst {
            let opId = start.opId
            let startAt = mdLogIndex(containing: ["sectionReorder op=\(opId) start (editor-first)"], from: index)
            let okAt = mdLogIndex(containing: ["reorder-editor-first opId=\(opId) ok=true"], from: index)
            let doneAt = mdLogIndex(containing: ["sectionReorder op=\(opId) performed"], from: index)
            soft.check(startAt != nil && okAt != nil && doneAt != nil && startAt! < okAt! && okAt! < doneAt!,
                "op \(opId): the log order is not start (editor-first), the page's reply, performed (log lines \(startAt.map(String.init) ?? "-"), "
                + "\(okAt.map(String.init) ?? "-"), \(doneAt.map(String.init) ?? "-"))")
        }
    }

    /// The word total never changes without an edit: `expected` is the total as loaded (plus what was typed). Read once the status bar equals
    /// the sum of the saved blocks' word counts; asserted against `expected`.
    func addWordTotalCheck(
        _ what: String, expected: Int?, basis: Bool?, to soft: inout Phase4bFlowSoftChecks
    ) -> Int? {
        let total = settledWordTotal(what, basis: basis, to: &soft)
        soft.check(total != nil && total == expected,
            "WORD TOTAL \(what): the status bar reads \(figure(total)), expected \(figure(expected)); \(countsLine)")
        return total
    }
}

// MARK: - E-D1 The page moves the text first; the rows follow; the order persists

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdDragMovesAtOnceAndPersists_article() { runDragMovesAtOnce(.article, method: #function) }
    func testMdDragMovesAtOnceAndPersists_book6() { runDragMovesAtOnce(.book6, method: #function) }

    /// Hand-test steps 1, 2 and 8. In Markdown mode a card is dragged above its neighbour (article: "1.6 Conclusion" above "1.5 Lanterns After
    /// Dark" at level 2, the UNFLATTENED article; book6: Chapter 6 above Chapter 5 on the FLATTENED copy). The first job is held 30 s, so there
    /// is a long window in which the page has moved the text and the database has not: (1) the page's reply (`reorder-editor-first opId=..
    /// ok=true mode=markdown`) is in the log while the block table STILL holds the old heading order, and the Outline already lists the dragged
    /// card above its new neighbour; (2) the log shows `start (editor-first) mode=markdown` then the reply then `performed`, with no plain
    /// `start`, and the job's window (reserve to release) is about the 30 s of the hold; (3) after the job the block table's heading order and
    /// every text row are the hand-worked document (Notes and Bibliography last, the footnotes 1...n in reading order) and the word total is
    /// the one as loaded; (4) File > Save Version writes the LIVE editor text into the table and it is identical (the editor's text IS the
    /// table); (5) after Cmd-W and a reopen the order is still the dragged one and the word total is still the one as loaded. An unchanged
    /// old-body app fails (1) and (2) at once: its sequence begins with a plain `start` and no reply line is written.
    func runDragMovesAtOnce(_ size: Phase4bDelSize, method: String) {
        let pair = Self.dragPair(size)
        let env = [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"]
        guard startScenario(size, method: method, env: env, flat: pair.flat), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved) else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let originalHeadings = preHeadingFragments
        let movedHeadings = dragHeadings(arrangement)
        var soft = Phase4bFlowSoftChecks()
        let basis = statusBarLeavesBibliographyOut()
        soft.check(basis != nil, "TEST-SETUP: the status-bar total as loaded equals neither the sum of all block word counts nor the sum "
            + "without the Bibliography blocks, so the word totals cannot be checked against the saved blocks")
        let totalLoaded = wordTotal()
        note("SCENARIO: \"\(pair.moved)\" is dragged to just before \"\(pair.target)\" (level \(pair.level)); \(originalHeadings.count) headings; "
            + "the first job is held \(Self.overlapHoldMs) ms; word total as loaded \(figure(totalLoaded))")
        guard let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false) else { return }
        shot("md-drag-moves-1-before-the-drag")
        let dragFrom = performDrag(drag)

        // (1) The page has replied; the rows are still the old order (the job is held); the Outline already shows the new order.
        let replied = waitForLog(containing: "[STRUCT-TRACE] reorder-editor-first opId=", from: dragFrom,
                                 timeout: appWait(size.operationTimeout, before: "the page's reply to the drag is looked for"))
        let rowsAtReply = headingFragmentsInDatabase()
        soft.check(replied, "no `reorder-editor-first opId=.. ok=true mode=markdown` line within \(Int(size.operationTimeout)) s of the drop: the "
            + "Markdown drag did not take the editor-first road")
        soft.check(rowsAtReply == originalHeadings,
            "when the page's reply was logged the block table already held a different heading order "
            + "(\(firstDifference(originalHeadings, rowsAtReply))): "
            + "the move was not editor-first, or the job was not held")
        let sidebarNew = waitForSidebarAbove(pair.moved, pair.target, timeout: appWait(60, before: "the Outline's new order is looked for"))
        result("AT ONCE: the page's reply was logged \(Self.yesNo(replied)); the block table still held the OLD heading order at that moment: "
            + "\(Self.yesNo(rowsAtReply == originalHeadings)); the Outline lists \"\(pair.moved.prefix(30))\" above \"\(pair.target.prefix(30))\": "
            + "\(Self.yesNo(sidebarNew)) (the rows still old: \(Self.yesNo(headingFragmentsInDatabase() == originalHeadings)))")
        soft.check(sidebarNew, "the Outline does not list \"\(pair.moved)\" above \"\(pair.target)\" 60 s after the drop")
        shot("md-drag-moves-2-right-after-the-drop")

        // (2) The job, after the hold; the rows follow.
        let performed = waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs"))
        soft.check(performed, "the drag's `sectionReorder` sequence never performed")
        let applied = waitForHeadingOrder(movedHeadings, timeout: size.operationTimeout * 2)
        soft.check(applied, "after the job the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        settle()
        if let opId = reorderOpId(from: dragFrom) {
            let window = jobWindow(opId: opId, from: dragFrom)
            result("HOLD WINDOW: the job was reserved at log line \(figure(window.reservedIndex)) and the hold released at line "
                + "\(figure(window.releasedIndex)), \(window.heldSeconds.map { String(format: "%.1f", $0) } ?? "n/a") s later")
            soft.check((window.heldSeconds ?? 0) >= Double(Self.overlapHoldMs) / 1_000 - 3,
                "TEST-SETUP: the job's window was \(window.heldSeconds.map { String(format: "%.1f", $0) } ?? "n/a") s, not about the "
                + "\(Self.overlapHoldMs / 1_000) s of the hold: the premise \"the rows are still old while the page has moved\" was not set up")
        }
        let post = addDragChecks("after the drag (settled)", arrangement: arrangement, bibliographyExact: size != .article, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        addMarkdownMechanismChecks(from: dragFrom, commands: 1, to: &soft)
        addLogChecks(from: dragFrom, checkPushes: false, to: &soft)
        _ = addWordTotalCheck("after the drag (settled)", expected: totalLoaded, basis: basis, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag", to: &soft)
        shot("md-drag-moves-3-after-the-settle")

        // (5) Cmd-W and reopen: the order, the rows and the word total persist.
        guard closeProjectWithCommandW(), relaunch() else { return }
        let reopenedOrder = headingFragmentsInDatabase()
        soft.check(reopenedOrder == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(firstDifference(movedHeadings, reopenedOrder)))")
        addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, bibliographyExact: size != .article, to: &soft)
        let reopened = waitForBarToMatchBlocks(excludingBibliography: basis ?? false, timeout: 60)
        result("WORD TOTALS: as loaded \(figure(totalLoaded)); after the reopen \(figure(reopened.bar)) "
            + "(sum of the saved blocks' word counts \(figure(reopened.blocks)))")
        soft.check(reopened.bar != nil && reopened.bar == totalLoaded,
            "WORD TOTAL after the reopen: \(figure(reopened.bar)), expected the total as loaded (\(figure(totalLoaded))); "
            + "\(countsLine)")
        shot("md-drag-moves-4-reopened")
        assertAll(soft, "Markdown: drag a card above its neighbour, the page moves first, the rows follow, Cmd-W and reopen, on \(size.identifier) "
            + "(\(pair.flat.isEmpty ? "unflattened" : "flattened copy, chapters \(pair.flat) flat")); \(countsLine)")
    }
}

// MARK: - E-D2 Type, drag, type again at once; everything persists

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdTypeDragTypePersists_book6() { runTypeDragType(.book6, method: #function) }
    func testMdTypeDragTypePersists_book12() { runTypeDragType(.book12, method: #function) }

    /// Hand-test step 6 (the plain-drag half). The caret is put at the end of the Anchor05 line (chapter 1, which is not moved); the cards are
    /// brought into view BEFORE anything is typed, so that between the typing and the press there is no accessibility query; a short sentence
    /// (" KEPTMDONE", well under 40 characters) is typed, the card is pressed and dragged straight away, and the moment the drop is made a
    /// second sentence (" KEPTMDTWO") is typed with NO click back. The first job is held 30 s, so the second sentence is typed while the
    /// job is pending. "Straight away" is proven by the app's log and the database, not by the clock: (a) a `[MdWrite] applied` line (the
    /// typing batch) comes before the job's release line, the job's reserve line comes before it too, and the held window is about the 30 s of
    /// the hold; (b) at the first moment the block table shows the NEW heading order the first sentence is already in it; (c) the first key of
    /// the second sentence reached the editor before the job's hold was released. Then: both sentences sit side by side in the Anchor05 row
    /// (the caret stayed where it was), the rows are the hand-worked document, the word total is the total as loaded plus the two typed words,
    /// File > Save Version shows the editor's text equals the table, and after Cmd-W and a reopen BOTH sentences, the dragged order and the
    /// word total are all still there. An unchanged old-body app fails the trace checks.
    func runTypeDragType(_ size: Phase4bDelSize, method: String) {
        let pair = Self.dragPair(size)
        let env = [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"]
        guard startScenario(size, method: method, env: env, flat: pair.flat), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved), let anchor = requireAnchorRow(), placeCaret(),
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false) else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let originalHeadings = preHeadingFragments
        let movedHeadings = dragHeadings(arrangement)
        let typedLine = Self.anchorLine + " " + Self.phraseOne + " " + Self.phraseTwo
        var soft = Phase4bFlowSoftChecks()
        let basis = statusBarLeavesBibliographyOut()
        soft.check(basis != nil, "TEST-SETUP: the status-bar total as loaded equals neither the sum of all block word counts nor the sum "
            + "without the Bibliography blocks")
        let totalLoaded = wordTotal()
        let expectedTotal = totalLoaded.map { $0 + 2 }
        note("SCENARIO: the caret is at the end of the Anchor05 line; \"\(Self.phraseOne)\" is typed, \"\(pair.moved)\" is dragged to just before "
            + "\"\(pair.target)\" at once, \"\(Self.phraseTwo)\" is typed straight after the drop with no click; the first job is held "
            + "\(Self.overlapHoldMs) ms; word total as loaded \(figure(totalLoaded))")

        tail.poll()
        let typeFrom = tail.lines.count
        typeNow(" " + Self.phraseOne)
        let dragFrom = performDrag(drag)
        tail.poll()
        let typedFrom = tail.lines.count
        typeNow(" " + Self.phraseTwo)

        // (b) at the first moment the NEW heading order is in the block table, the first sentence is already there.
        var sentenceAtOrder: Bool?
        let orderDeadline = Date(
            timeIntervalSinceNow: appWait(size.operationTimeout * 2, before: "the dragged order is looked for in the block table"))
        repeat {
            let sentence = blocksContaining(Self.phraseOne) >= 1
            if headingFragmentsInDatabase() == movedHeadings {
                sentenceAtOrder = sentence
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < orderDeadline
        soft.check(sentenceAtOrder != nil, "after the job the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        soft.check(sentenceAtOrder == true,
            "at the first moment the block table showed the dragged order the first sentence \"\(Self.phraseOne)\" was NOT in it: "
            + "the typing batch was not saved before the job applied")
        soft.check(waitForSentenceInDatabase(Self.phraseTwo, timeout: 90),
            "the second sentence \"\(Self.phraseTwo)\", typed straight after the drop with no click, never reached the block table")
        settle()

        // (a) and (c) from the log.
        let performed = waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout, before: "the drag performs"))
        soft.check(performed, "the drag's `sectionReorder` sequence never performed")
        if let opId = reorderOpId(from: dragFrom) {
            let window = jobWindow(opId: opId, from: dragFrom)
            let appliedAt = mdLogIndex(containing: ["[MdWrite] applied seq="], from: typeFrom)
            let keyLine = firstEditorKeyLine(from: typedFrom)
            let releasedLine = window.releasedIndex.map { tail.lines[$0] }
            result("LOG ORDER: first typing batch `[MdWrite] applied` at log line \(figure(appliedAt)); the job reserved at line "
                + "\(figure(window.reservedIndex)); the hold released at line \(figure(window.releasedIndex)) "
                + "(\(window.heldSeconds.map { String(format: "%.1f", $0) } ?? "n/a") s after the reserve); the first key of the second sentence at "
                + "\(keyLine?.stamp ?? "n/a"), the hold released at \(releasedLine?.stamp ?? "n/a")")
            soft.check(appliedAt != nil && window.releasedIndex != nil && appliedAt! < window.releasedIndex!,
                "the typing batch's `[MdWrite] applied` line (\(appliedAt.map(String.init) ?? "none")) does not come before the job's release line "
                + "(\(window.releasedIndex.map(String.init) ?? "none"))")
            soft.check(window.reservedIndex != nil && window.releasedIndex != nil && window.reservedIndex! < window.releasedIndex!,
                "the job's `onReserved fired` line does not come before its release line")
            soft.check((window.heldSeconds ?? 0) >= Double(Self.overlapHoldMs) / 1_000 - 3,
                "TEST-SETUP: the job's window was \(window.heldSeconds.map { String(format: "%.1f", $0) } ?? "n/a") s, not about the "
                + "\(Self.overlapHoldMs / 1_000) s of the hold")
            if let key = keyLine?.date, let release = releasedLine?.date {
                soft.check(key < release,
                    "TEST-SETUP: the second sentence was typed AFTER the job's hold was released, so it did not meet a pending job")
            } else {
                result("TYPING vs the job: no editor key line or no release line could be read (not asserted)")
            }
        } else {
            soft.check(false, "no `sectionReorder` sequence began since the press: the drag did not register as a drag")
        }

        // The rows: the dragged document with both sentences side by side in the Anchor05 row.
        let post = addDragChecks("after the drag and the typing (settled)", arrangement: arrangement, typed: [anchor: typedLine],
                                 bibliographyExact: true, to: &soft)
        soft.check(blocksContaining(Self.phraseOne + " " + Self.phraseTwo) == 1,
            "the two sentences are not side by side in one row (\(blocksContaining(Self.phraseOne)) row(s) hold the first, "
            + "\(blocksContaining(Self.phraseTwo)) the second)")
        soft.check(originalHeadings != movedHeadings, "TEST-SETUP: the drag changes nothing in the heading list")
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        addMarkdownMechanismChecks(from: dragFrom, commands: 1, to: &soft)
        addLogChecks(from: dragFrom, checkPushes: false, to: &soft)
        _ = addWordTotalCheck("after the drag and both sentences (settled)", expected: expectedTotal, basis: basis, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag and the typing", to: &soft)
        shot("md-type-drag-type-1-after-the-settle")

        // Cmd-W and reopen: both sentences, the order and the word total.
        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        soft.check(blocksContaining(Self.phraseOne) == 1 && blocksContaining(Self.phraseTwo) == 1,
            "after the reopen the sentences are in \(blocksContaining(Self.phraseOne)) / \(blocksContaining(Self.phraseTwo)) row(s), expected 1 each")
        soft.check(blocksContaining(Self.phraseOne + " " + Self.phraseTwo) == 1, "after the reopen the two sentences are not side by side in one row")
        addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, typed: [anchor: typedLine], bibliographyExact: true, to: &soft)
        let reopened = waitForBarToMatchBlocks(excludingBibliography: basis ?? false, timeout: 60)
        result("WORD TOTALS: as loaded \(figure(totalLoaded)), expected with the two typed words \(figure(expectedTotal)); "
            + "after the reopen \(figure(reopened.bar)) (sum of the saved blocks' word counts \(figure(reopened.blocks)))")
        soft.check(reopened.bar != nil && reopened.bar == expectedTotal,
            "WORD TOTAL after the reopen: \(figure(reopened.bar)), expected \(figure(expectedTotal)) (as loaded "
            + "\(figure(totalLoaded)) plus the two typed words); \(countsLine)")
        shot("md-type-drag-type-2-reopened")
        assertAll(soft, "Markdown: type, drag at once, type again, Cmd-W and reopen, on \(size.identifier) "
            + "(flattened copy, chapters \(pair.flat) flat); "
            + "\(countsLine)")
    }
}

// MARK: - E-D3 An Option-drag of a footnoted chapter: the footnotes follow, after the drag, Cmd-Z and Cmd-Shift-Z

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdDragFootnotesRenumbered_book6() { runDragFootnotes(.book6, method: #function) }
    func testMdDragFootnotesRenumbered_book12() { runDragFootnotes(.book12, method: #function) }

    /// Hand-test steps 1 to 5 (board t-8dc76a0b: in Markdown the old drag left the footnote references reading e.g. 1...36, 46...54, 37...45).
    /// A footnoted chapter WITH its sub-sections is Option-dragged above its flat neighbour (book6: Chapter 4, references 28...36, above
    /// Chapter 3, 19...27: without a renumber they would read 1...18, 28...36, 19...27, 37...54; book12: Chapter 9, 73...81, above Chapter 8,
    /// 64...72: 1...63, 73...81, 64...72, 82...108). The seed tags every footnote definition with a unique word, so each note can be tied to
    /// its reference (the books repeat one chapter's prose). After the drag has settled, after Cmd-Z and after Cmd-Shift-Z: the heading order
    /// is the hand-worked one, the references read 1...N in reading order with NO jump back, the Notes hold 1...N once each in order and each
    /// definition is the note its reference points at (rows). After the redo (no key follows, so the click on the Notes card cannot take the
    /// keyboard focus away from a press) the Notes the editor SHOWS are checked too: no label twice, the labels in step
    /// (`addNotesOnScreenCheck`; no label read from the accessibility tree within 30 s of the click on the Notes card is a failure, with the
    /// tree dump and the screenshot attached for the diagnosis). Then File > Save
    /// Version shows the editor's text equals the table, and after Cmd-W and a reopen the references and Notes are still
    /// 1...N. The fixture's footnote count N is stated in every failure message (book6: 54, book12: 108). An unchanged old-body app fails the
    /// trace checks AND the footnote checks (its references keep reading 1...18, 28...36, 19...27, 37...54).
    func runDragFootnotes(_ size: Phase4bDelSize, method: String) {
        let pair = Self.footnoteDragPair(size)
        guard startScenario(size, method: method, flat: pair.flat, seed: { WriteQueuePhase4bStructuralQueueE2ETests.rqTaggingNotes($0) }),
              requireSection(pair.moved) != nil, requireSection(pair.target) != nil, placeCaret() else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let originalHeadings = preHeadingFragments
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        let scrambled = arrangement.flatMap { Phase4bFlow.footnoteRefs(in: $0.row.fragment) }
        let movedRefs = (section(pair.moved).map { footnoteNumbers(in: $0) } ?? [])
        var soft = Phase4bFlowSoftChecks()
        note("FOOTNOTES: the document holds \(total) footnote references (\(size.chapters) chapters x 9); \"\(pair.moved.prefix(12))...\" holds "
            + "\(movedRefs.count) of them \(Self.ascendingRuns(movedRefs)); without a renumber they would read "
            + "[\(Self.ascendingRuns(scrambled))] after the drag")
        guard !movedRefs.isEmpty, total > 0, scrambled != Array(stride(from: 1, through: total, by: 1)) else {
            fail("TEST-SETUP: this drag would not scramble the footnote numbers (the moved section holds \(movedRefs.count) reference(s), "
                + "the document "
                + "\(total)); the test would prove nothing. \(countsLine)")
            return
        }

        // The Option-drag.
        guard let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: true) else { return }
        let dragFrom = performDrag(drag)
        soft.check(waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs")),
            "the drag's `sectionReorder` sequence never performed")
        addOptionCarriedCheck(pair.moved, expected: movedHeadings, what: "after the drag", to: &soft)
        settle()
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after the drag the block table's heading order is not the hand-worked one (\(orderDifference(movedHeadings)))")
        let afterDrag = addDragChecks("after the drag (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after the drag (settled)", rows: afterDrag, count: total, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)

        // Cmd-Z: the original order and the original numbers.
        let undoFrom = traceLinesCount()
        let undo = pressStepRefocusing(redo: false, number: 1, watchToasts: true, what: "Cmd-Z after the drag", soft: &soft)
        soft.check(undo.decision == "structural" && undo.structural,
            "Cmd-Z after the drag was decided \(undo.decision) (structural ran: \(undo.structural)), not the drag's undo")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the order comes back")),
            "after Cmd-Z the block table's heading order is not the original one (\(orderDifference(originalHeadings)))")
        settle()
        let afterUndo = addDragChecks("after Cmd-Z (settled)", arrangement: original, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Z (settled)", rows: afterUndo, count: total, to: &soft)
        let undoStarts = traceLines(from: undoFrom).filter { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z of the drag: sequence start line(s) \(undoStarts.map(\.step)); \"Undoing\" notice(s) in the log "
            + "\(undoingToastCount(from: undoFrom)) (allowed)")
        shot("md-drag-footnotes-1-after-cmd-z")

        // Cmd-Shift-Z: the dragged order and the renumbered notes again.
        let redoFrom = traceLinesCount()
        let redo = pressStepRefocusing(redo: true, number: 2, watchToasts: true, what: "Cmd-Shift-Z after the undo", soft: &soft)
        soft.check(redo.decision == "structural" && redo.structural,
            "Cmd-Shift-Z was decided \(redo.decision) (structural ran: \(redo.structural)), not the drag's redo")
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order comes back")),
            "after Cmd-Shift-Z the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        settle()
        let afterRedo = addDragChecks("after Cmd-Shift-Z (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Shift-Z (settled)", rows: afterRedo, count: total, to: &soft)
        let redoStarts = traceLines(from: redoFrom).filter { $0.family == .sequence && $0.label == "redo" && $0.isOpStart }
        result("CMD-SHIFT-Z of the drag: sequence start line(s) \(redoStarts.map(\.step)); \"Redoing\" / \"Undoing\" notice(s) in the log "
            + "\(toastLines(containing: "Redoing", from: redoFrom).count + undoingToastCount(from: redoFrom)) (allowed)")
        addNotesOnScreenCheck("after Cmd-Shift-Z", to: &soft)
        addMarkdownMechanismChecks(from: dragFrom, commands: 3, to: &soft)
        addLogChecks(from: dragFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: afterRedo, what: "after the drag, Cmd-Z and Cmd-Shift-Z", to: &soft)

        // Cmd-W and reopen: the references and the Notes are still 1...N.
        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        let reopened = addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-W and the reopen", rows: reopened, count: total, to: &soft)
        shot("md-drag-footnotes-2-reopened")
        assertAll(soft, "Markdown: Option-drag of a footnoted chapter, Cmd-Z, Cmd-Shift-Z, Cmd-W and reopen, on \(size.identifier) "
            + "(flattened copy, chapters \(pair.flat) flat; \(total) footnote references in all); \(countsLine)")
    }
}

// MARK: - E-D9 Delete, drag, Cmd-Z, Cmd-Z: the Delete's undo is still the QUICK route

extension WriteQueuePhase4bMarkdownEFE2ETests {
    func testMdDeleteDragUndoUndo_book6() {
        let size = Phase4bDelSize.book6
        let deleted = Self.chapter(3)
        let pair = Self.dragPair(size)
        guard startScenario(size, method: #function, flat: pair.flat), requireSection(deleted) != nil, requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved), placeCaret() else { return }
        runDeleteDragUndoUndo(size, deleted: deleted, pair: pair)
    }

    /// Hand-test step 10 (and the heart of the slice: the drag must NOT close the quick road of an earlier Delete). Chapter 3 is deleted
    /// (Delete Section) and the document settles; Chapter 6 is dragged above Chapter 5 (editor first, plain `start (editor-first)
    /// mode=markdown`); then Cmd-Z TWICE, each pressed after the one before has finished (XCUITest cannot give the second at once in the slow
    /// VM, so the order is proven from the log, not raced). Press 1 undoes the DRAG: the queued slow route (`start (markdown queued undo)`;
    /// an "Undoing..." notice is allowed), the heading order is the one after the Delete alone and the rows are the hand-worked document.
    /// Press 2 undoes the DELETE by the QUICK route: its sequence began `start (quick, markdown)` (not the queued one), no "Undoing..." notice
    /// in the log or in the `toast-message` element in the first 1.2 s, and the slow-press notice rule holds (`addQuickPressNoticeCheck`). The
    /// chapter, its notes and its word count are back: the rows are the document as loaded, byte for byte in Notes and Bibliography, and the
    /// word total is the one as loaded. Nothing wiped the undo timeline (`invalidateAll`) between the drag and the second press, and the
    /// drag raised no structural-generation bump (a bump is what closed the quick road: the old body's drag did exactly that). An unchanged
    /// old-body app fails the trace checks, and its second Cmd-Z is the slow route. USES A FLATTENED COPY (chapters 1, 3, 5, 6 flat).
    func runDeleteDragUndoUndo(_ size: Phase4bDelSize, deleted: String, pair: Phase4bMdDragPair) {
        let original = dragUserRows()
        let originalHeadings = preHeadingFragments
        let afterDelete = dragWithout(original, section: deleted)
        let afterDeleteHeadings = dragHeadings(afterDelete)
        let draggedAfterDelete = dragMoving(afterDelete, pair.moved, before: pair.target)
        let draggedHeadings = dragHeadings(draggedAfterDelete)
        var soft = Phase4bFlowSoftChecks()
        let basis = statusBarLeavesBibliographyOut()
        soft.check(basis != nil, "TEST-SETUP: the status-bar total as loaded equals neither block sum")
        let totalLoaded = wordTotal()
        note("SCENARIO: \"\(deleted.prefix(12))...\" is deleted, \"\(pair.moved.prefix(12))...\" is dragged to just before "
            + "\"\(pair.target.prefix(12))...\", then "
            + "Cmd-Z twice (the drag, then the Delete); word total as loaded \(figure(totalLoaded))")

        // 1. Delete Section.
        guard let card = bringSidebarCardIntoView(deleted) else { return }
        let deleteFrom = chooseSidebarItem(card, item: "Delete Section")
        soft.check(waitForCard(deleted, present: false, timeout: appWait(size.operationTimeout, before: "the card leaves the Outline")),
            "the card \"\(deleted)\" is still in the Outline after Delete Section")
        soft.check(settle(gone: [deleted]), "the heading \"\(deleted)\" is still in the block table once the job should have run")
        addDragChecks("after the Delete (settled)", arrangement: afterDelete, bibliographyExact: true, to: &soft)

        // 2. The drag.
        guard let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false) else { return }
        let dragFrom = performDrag(drag)
        soft.check(waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs")),
            "the drag's `sectionReorder` sequence never performed")
        soft.check(waitForHeadingOrder(draggedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order")),
            "after the drag the block table's heading order is not the hand-worked one (\(orderDifference(draggedHeadings)))")
        settle()
        addDragChecks("after the Delete and the drag (settled)", arrangement: draggedAfterDelete, bibliographyExact: true, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        shot("md-delete-drag-undo-undo-1-after-the-drag")

        // 3. Cmd-Z #1: the drag is undone (the queued slow route).
        let firstFrom = traceLinesCount()
        let first = pressStepRefocusing(redo: false, number: 1, watchToasts: true, what: "the first Cmd-Z (the drag's)", soft: &soft)
        soft.check(first.decision == "structural" && first.structural,
            "the first Cmd-Z was decided \(first.decision) (structural ran: \(first.structural)), not the drag's undo")
        let firstRuns = quickRuns(from: firstFrom, label: "undo")
        let firstStart = traceLines(from: firstFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #1 (the drag's undo): runs \(firstRuns.map { $0.quick ? "quick" : "slow" }); sequence began `\(firstStart?.step ?? "none")`; "
            + "\"Undoing\" notice(s) in the log \(undoingToastCount(from: firstFrom)) (allowed); toasts in the first 1.2 s \(first.toasts)")
        soft.check(firstRuns.count == 1 && firstRuns[0].quick == false && firstStart?.step.hasPrefix("start (markdown queued undo") == true,
            "the first Cmd-Z ran as \(firstRuns.map { $0.quick ? "quick" : "slow" }) and began `\(firstStart?.step ?? "none")`, "
            + "expected the drag's queued slow "
            + "undo (`start (markdown queued undo)`)")
        soft.check(waitForHeadingOrder(afterDeleteHeadings, timeout: appWait(size.operationTimeout * 2, before: "the drag is undone")),
            "after the first Cmd-Z the block table's heading order is not the one after the Delete alone "
            + "(\(orderDifference(afterDeleteHeadings)))")
        settle()
        addDragChecks("after the first Cmd-Z (settled)", arrangement: afterDelete, bibliographyExact: true, to: &soft)
        soft.check(!sidebarCard(deleted).exists,
            "the deleted chapter \"\(deleted)\" is back in the Outline after the FIRST Cmd-Z (it undid the Delete, not the drag)")
        shot("md-delete-drag-undo-undo-2-after-the-first-cmd-z")

        // 4. Cmd-Z #2: the Delete is undone by the QUICK route.
        let secondFrom = traceLinesCount()
        let second = pressStepRefocusing(redo: false, number: 2, watchToasts: true, what: "the second Cmd-Z (the Delete's)", soft: &soft)
        soft.check(second.decision == "structural" && second.structural,
            "the second Cmd-Z was decided \(second.decision) (structural ran: \(second.structural)), not the Delete's undo")
        let secondRuns = quickRuns(from: secondFrom, label: "undo")
        let secondStart = traceLines(from: secondFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #2 (the Delete's undo): runs \(secondRuns.map { $0.quick ? "quick" : "slow" }); "
            + "sequence began `\(secondStart?.step ?? "none")`; "
            + "key to performed \(secondRuns.first?.keyToPerformedMs.map { "\($0) ms" } ?? "n/a"); toasts in the first 1.2 s \(second.toasts); "
            + "undoDepth at the press \(undoDepthOfFirstStructuralPress(from: secondFrom).map(String.init) ?? "n/a")")
        soft.check(secondRuns.count == 1 && secondRuns[0].quick == true && secondStart?.step == "start (quick, markdown)",
            "the second Cmd-Z ran as \(secondRuns.map { $0.quick ? "quick" : "slow" }) and began `\(secondStart?.step ?? "none")`, "
            + "expected the QUICK route "
            + "`start (quick, markdown)`: the drag closed the quick road of the earlier Delete")
        soft.check(undoingToastCount(from: secondFrom) == 0, "an \"Undoing...\" toast was written to the log for the Delete's undo: "
            + "\(toastLines(containing: "Undoing", from: secondFrom))")
        soft.check(!second.toasts.contains { $0.contains("Undoing") },
            "the toast-message element showed \"Undoing...\" within 1.2 s of the second Cmd-Z: \(second.toasts)")
        addQuickPressNoticeCheck("UNDO #2", label: "undo", from: secondFrom, to: &soft)
        soft.check(waitForCard(deleted, present: true, timeout: appWait(size.operationTimeout, before: "the card comes back")),
            "the card \"\(deleted)\" did not come back after the second Cmd-Z")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the original order")),
            "after the second Cmd-Z the block table's heading order is not the original one (\(orderDifference(originalHeadings)))")
        settle(back: [deleted])

        // 5. Everything is as loaded.
        let end = addDocumentChecks("after both Cmd-Z presses (settled)", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
        _ = addWordTotalCheck("after both Cmd-Z presses (settled)", expected: totalLoaded, basis: basis, to: &soft)
        let wiped = logLines(containing: "[UnifiedUndoService] invalidateAll:", from: dragFrom).map(\.text)
        soft.check(wiped.isEmpty, "the undo timeline was wiped (`invalidateAll`) between the drag and the end: \(wiped.prefix(2))")
        // The Delete (1 hold), the drag (1), the drag's queued undo (1) and the Delete's quick undo (1).
        addMarkdownMechanismChecks(from: deleteFrom, commands: 4, to: &soft)
        addLogChecks(from: deleteFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: end, what: "at the end", to: &soft)
        shot("md-delete-drag-undo-undo-3-end")
        assertAll(soft, "Markdown: Delete, drag, Cmd-Z (the drag), Cmd-Z (the Delete, quick), on \(size.identifier) (flattened copy, chapters "
            + "\(pair.flat) flat); \(countsLine)")
    }
}

// MARK: - Batch 2 helpers: seeded lines, the end drop, levels, the tail of the document

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// A plain one-line paragraph seeded under a chapter heading: "<prefix> line of the fixture document." It is its own exact leaf, so the
    /// caret can be put at its end with the proven exact-line recipe once the editor shows its chapter.
    static func seededLine(_ prefix: String) -> String { prefix + " line of the fixture document." }

    /// The seed hook (`startScenario(seed:)`) that puts one seeded line directly under the H1 heading of each chapter named.
    static func lineSeed(_ lines: [(title: String, line: String)]) -> (Phase4bDoc) -> Phase4bDoc {
        { generated in
            lines.reduce(generated) { document, entry in
                WriteQueuePhase4bStructuralQueueE2ETests.withPlainLines(document, under: entry.title, level: 1, lines: [entry.line])
            }
        }
    }

    /// The row of `pre` that is the seeded line `line`, or a reported TEST-SETUP failure.
    func requireSeededRow(_ line: String) -> Int? {
        guard let row = pre.firstIndex(where: { $0.fragment == line }) else {
            fail("TEST-SETUP: the loaded document has no seeded row \"\(line)\". \(countsLine)")
            return nil
        }
        return row
    }

    /// The caret at the end of the seeded `line` of the chapter whose card is `card`: the sidebar's own navigation (a click on the card
    /// scrolls the editor to the chapter), then the exact-line recipe. False after a reported failure.
    func placeCaretInSection(_ card: String, line: String, prefix: String) -> Bool {
        guard let cardElement = bringSidebarCardIntoView(card) else { return false }
        app.activateAndWaitForForeground()
        cardElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        return placeCaretAtAnchorEnd(paragraph: prefix, exactLine: line)
    }

    /// The saved text of the seeded line that begins `prefix` (one light query), nil when there is none.
    func lineInDatabase(startingWith prefix: String) -> String? {
        let text = dbText("SELECT markdownFragment FROM block WHERE instr(markdownFragment, '\(FixtureDatabase.escape(prefix))') = 1 LIMIT 1;")
        return text.isEmpty ? nil : text
    }

    /// Waits (a condition) until the saved seeded line that begins `prefix` reads exactly `expected`.
    func waitForLine(_ expected: String, startingWith prefix: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the line \"\(prefix)...\" is looked for in the database"))
        repeat {
            if lineInDatabase(startingWith: prefix) == expected { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return false
    }

    /// The heading level the block table stores for the heading titled `title`.
    func headingLevelInDatabase(of title: String) -> Int? {
        dbInt("SELECT headingLevel FROM block WHERE blockType = 'heading' "
            + "AND instr(markdownFragment, '\(FixtureDatabase.escape(title))') > 0 LIMIT 1;")
    }

    /// The stored heading level of the heading titled `title`, as text for a message.
    func levelText(_ title: String) -> String { figure(headingLevelInDatabase(of: title)) }

    /// `rows` with the heading titled `title` written at level `level` (everything after its `#` run is kept: the hand-worked answer of a
    /// level-changing drop).
    func dragReleveling(_ rows: [Phase4bRqRow], title: String, to level: Int) -> [Phase4bRqRow] {
        rows.map { item in
            guard item.row.headingTitle == title else { return item }
            let rest = String(item.row.fragment.drop(while: { $0 == "#" }))
            let row = Phase4bFlowRow(
                type: item.row.type, isNotes: item.row.isNotes, isBibliography: item.row.isBibliography,
                fragment: String(repeating: "#", count: level) + rest)
            return Phase4bRqRow(id: item.id, row: row)
        }
    }

    /// Works out the END DROP: the card `moved` is let go in the empty strip under the LAST card of the list (the Bibliography heading, else
    /// Notes), which lands the section as the last chapter, before Notes and Bibliography. The cards are brought into the visible band, the
    /// sidebar is scrolled to its end (the strip must be on screen) and the pointer is put 52 pt under the last card's title, at heading
    /// level `level` (a chapter at the far left). Nothing is pressed. Nil after a reported failure.
    func prepareEndDrag(_ moved: String, level: Int = 1, option: Bool, dropY: CGFloat = 0.5) -> Phase4bMdDrag? {
        let lastFragment = dbText("SELECT markdownFragment FROM block WHERE blockType = 'heading' ORDER BY sortOrder DESC, id DESC LIMIT 1;")
        let lastTitle = Self.title(lastFragment)
        guard !lastTitle.isEmpty else {
            fail("TEST-SETUP: the block table has no heading to drop under")
            return nil
        }
        guard let found = bringIntoView([moved, lastTitle]) else { return nil }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let before = found[1].frame.midY
        scroll.scroll(byDeltaX: 0, deltaY: -4_000)
        app.waitForStableFrame(found[1])
        if found[1].exists, found[1].frame.midY > before + 1 {
            scroll.scroll(byDeltaX: 0, deltaY: 8_000)
            app.waitForStableFrame(found[1])
        }
        let cards = [sidebarCard(moved), sidebarCard(lastTitle)]
        guard cards[0].exists, cards[1].exists, scroll.frame.insetBy(dx: 0, dy: 20).contains(cards[0].frame) else {
            fail("TEST-SETUP: after the scroll to the end of the sidebar the card \"\(moved)\" and the last card \"\(lastTitle)\" "
                + "are not both inside "
                + "its visible band (\(Self.describeFrame(scroll.frame)); dragged card \(Self.describeFrame(cards[0].frame)))")
            return nil
        }
        let wanted = CGFloat(min(max(level, 1), 2))
        let screenX = scroll.frame.minX + (wanted - 0.5) * scroll.frame.width / 2
        let lastCard = cards[1]
        let dropPoint = lastCard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1))
            .withOffset(CGVector(dx: screenX - lastCard.frame.minX, dy: 52 + (dropY - 0.5) * 8))
        let point = dropPoint.screenPoint
        note("END DRAG PREPARED: \"\(moved.prefix(40))\" \(option ? "with its sub-sections (Option)" : "alone") under the last card "
            + "\"\(lastTitle)\" at level \(level): pointer ends at (\(Int(point.x)), \(Int(point.y))) in the sidebar "
            + "\(Self.describeFrame(scroll.frame)); "
            + "dragged card \(Self.describeFrame(cards[0].frame)); last card \(Self.describeFrame(lastCard.frame))")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        return Phase4bMdDrag(
            moved: moved, dropOn: lastTitle, target: "(the end of the list)", option: option, level: level, cards: cards, dropPoint: dropPoint)
    }

    /// The tail of a saved document after a reorder: Notes and Bibliography are the last rows (as many as before, Notes rows before the
    /// Bibliography rows), the Notes heading row is byte for byte the one before, and no heading is glued to the line before it (no text row
    /// holds a `#` mark in the middle of a line, and no heading row holds a second line).
    func addTailCheck(_ what: String, rows post: [Phase4bFlowRow], to soft: inout Phase4bFlowSoftChecks) {
        let tailRows = post.drop(while: { !$0.isManaged })
        let managedBefore = pre.filter(\.isManaged).count
        soft.check(!tailRows.isEmpty && tailRows.allSatisfy(\.isManaged), "\(what): Notes and Bibliography are not the last rows of the block table")
        soft.check(tailRows.count == managedBefore,
            "\(what): \(tailRows.count) Notes / Bibliography row(s) at the end of the block table, \(managedBefore) before")
        if let firstBibliography = tailRows.firstIndex(where: \.isBibliography), let lastNotes = tailRows.lastIndex(where: \.isNotes) {
            soft.check(lastNotes < firstBibliography, "\(what): a Notes row comes after the Bibliography rows")
        }
        let notesBefore = pre.first { $0.isNotes && $0.headingLevel != nil }?.fragment
        let notesAfter = post.first { $0.isNotes && $0.headingLevel != nil }?.fragment
        soft.check(notesBefore != nil && notesBefore == notesAfter,
            "\(what): the Notes heading row is \"\(notesAfter ?? "missing")\", expected byte for byte \"\(notesBefore ?? "missing")\"")
        let glued = post.enumerated().filter { _, row in
            if row.headingLevel != nil { return row.fragment.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") }
            return !row.isManaged && row.fragment.range(of: #"\S#{1,6} (Chapter|[0-9])"#, options: .regularExpression) != nil
        }
        result("TAIL \(what): \(tailRows.count) managed row(s) at the end (\(managedBefore) before); "
            + "rows with a heading glued to text: \(glued.count)")
        soft.check(glued.isEmpty, "\(what): a heading is glued to the line before it in row(s) \(glued.prefix(3).map(\.offset))")
    }
}

// MARK: - E-D6 Type in the chapter to move, drag it, type in the chapter it hopped over while the job is held

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Hand-test step 6, the two-chapter half. Chapter 6 (to move) and Chapter 5 (hopped over) each hold a seeded line ("Move06 line of the
    /// fixture document.", "Hop05 line of the fixture document.") right under the heading, on the FLATTENED book6 copy. The caret is put at
    /// the end of the Move06 line and " KEPTMDONE" is typed; then the caret is put at the end of the Hop05 line of Chapter 5 (a click on
    /// its card, then the exact-line recipe); then Chapter 6 is dragged above Chapter 5 (the cards were brought into view before anything
    /// was typed; the first job is held 30 s) and, WHILE THE JOB IS HELD, " KEPTMDTWO" is typed with no click: the caret sits in the
    /// hopped-over chapter and travels through the move. THE CARET IS PLACED BEFORE THE DROP, not after it, on purpose: in Markdown mode
    /// a click on a sidebar card scrolls the editor to an offset worked out from the ROWS (`ContentView.scrollToSection`), and until the
    /// drag's job has applied the rows are still in the old order, so a click on "Chapter 5" taken after the drop shows Chapter 6 (the
    /// first run of this test found nothing at "Hop05" for that reason; the AX dump showed Chapter 6's text). Proven: each sentence is in its
    /// OWN chapter's seeded row (one row each, inside the right section of the saved document), the rows are the hand-worked document (the
    /// chapters in the dragged order, both seeded rows carrying their sentence, footnotes 1..N), the first key of the second sentence
    /// reached the editor before the hold was released (log stamps), the word total is the total as loaded plus two, File > Save Version
    /// shows the editor's text equals the table, and after Cmd-W and a reopen both sentences, the order, the rows and the total are the
    /// same. An unchanged old-body app fails the trace checks; a drag that loses typing fails the sentences.
    func testMdTypeAroundDrop_book6() {
        let size = Phase4bDelSize.book6
        let pair = Self.dragPair(size)
        let moveLine = Self.seededLine("Move06")
        let hopLine = Self.seededLine("Hop05")
        let env = [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"]
        let seed = Self.lineSeed([(title: pair.moved, line: moveLine), (title: pair.target, line: hopLine)])
        guard startScenario(size, method: #function, env: env, flat: pair.flat, seed: seed), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved), requireChildless(pair.target),
              let moveRow = requireSeededRow(moveLine), let hopRow = requireSeededRow(hopLine),
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false),
              placeCaretInSection(pair.moved, line: moveLine, prefix: "Move06") else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let movedHeadings = dragHeadings(arrangement)
        let typed = [moveRow: moveLine + " " + Self.phraseOne, hopRow: hopLine + " " + Self.phraseTwo]
        var soft = Phase4bFlowSoftChecks()
        let basis = statusBarLeavesBibliographyOut()
        soft.check(basis != nil, "TEST-SETUP: the status-bar total as loaded equals neither block sum")
        let totalLoaded = wordTotal()
        let expectedTotal = totalLoaded.map { $0 + 2 }
        note("SCENARIO: \"\(Self.phraseOne)\" is typed at the end of the Move06 line in \"\(pair.moved.prefix(12))...\", "
            + "the caret is then put at the end of the Hop05 line of \"\(pair.target.prefix(12))...\", the first chapter is dragged to just "
            + "before it (the first job is held \(Self.overlapHoldMs) ms), and \"\(Self.phraseTwo)\" is typed with no click; "
            + "word total as loaded \(figure(totalLoaded))")

        typeNow(" " + Self.phraseOne)
        guard placeCaretInSection(pair.target, line: hopLine, prefix: "Hop05") else { return }
        let dragFrom = performDrag(drag)
        tail.poll()
        let typedFrom = tail.lines.count
        typeNow(" " + Self.phraseTwo)

        soft.check(waitForHeadingOrder(movedHeadings, timeout: size.operationTimeout * 2),
            "after the job the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        soft.check(waitForSentenceInDatabase(Self.phraseOne, timeout: 90), "the first sentence \"\(Self.phraseOne)\" never reached the block table")
        soft.check(waitForSentenceInDatabase(Self.phraseTwo, timeout: 90),
            "the second sentence \"\(Self.phraseTwo)\", typed into the hopped-over chapter while the job was held, never reached the block table")
        settle()
        if let opId = reorderOpId(from: dragFrom) {
            let window = jobWindow(opId: opId, from: dragFrom)
            let keyLine = firstEditorKeyLine(from: typedFrom)
            let releasedLine = window.releasedIndex.map { tail.lines[$0] }
            result("LOG ORDER: the job reserved at line \(figure(window.reservedIndex)), the hold released at line \(figure(window.releasedIndex)) "
                + "(\(window.heldSeconds.map { String(format: "%.1f", $0) } ?? "n/a") s after the reserve); the first key of the second sentence at "
                + "\(keyLine?.stamp ?? "n/a"), the hold released at \(releasedLine?.stamp ?? "n/a")")
            if let key = keyLine?.date, let release = releasedLine?.date {
                soft.check(key < release,
                    "TEST-SETUP: the second sentence was typed AFTER the job's hold was released, so it did not meet a pending job")
            } else {
                result("TYPING vs the job: no editor key line or no release line could be read (not asserted)")
            }
        }
        let post = addDragChecks(
            "after the drag and both sentences (settled)", arrangement: arrangement, typed: typed, bibliographyExact: true, to: &soft)
        addSentencePlacementChecks(post, [(pair.moved, Self.phraseOne), (pair.target, Self.phraseTwo)], to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        addMarkdownMechanismChecks(from: dragFrom, commands: 1, to: &soft)
        addLogChecks(from: dragFrom, checkPushes: false, to: &soft)
        _ = addWordTotalCheck("after the drag and both sentences (settled)", expected: expectedTotal, basis: basis, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag and both sentences", to: &soft)
        shot("md-type-around-drop-1-after-the-settle")

        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        let reopenedRows = addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, typed: typed, bibliographyExact: true, to: &soft)
        addSentencePlacementChecks(reopenedRows, [(pair.moved, Self.phraseOne), (pair.target, Self.phraseTwo)], to: &soft)
        let reopened = waitForBarToMatchBlocks(excludingBibliography: basis ?? false, timeout: 60)
        soft.check(reopened.bar != nil && reopened.bar == expectedTotal,
            "WORD TOTAL after the reopen: \(figure(reopened.bar)), expected \(figure(expectedTotal)) "
            + "(as loaded \(figure(totalLoaded)) plus two words); \(countsLine)")
        shot("md-type-around-drop-2-reopened")
        assertAll(soft, "Markdown: type in the chapter to move, drag, type in the hopped-over chapter while the job is held, Cmd-W and reopen, on "
            + "\(size.identifier) (flattened copy, chapters \(pair.flat) flat); \(countsLine)")
    }

    /// Each `(chapter, sentence)`: the sentence is in exactly one saved row and that row lies inside that chapter's section of `post`.
    func addSentencePlacementChecks(
        _ post: [Phase4bFlowRow], _ placements: [(chapter: String, sentence: String)], to soft: inout Phase4bFlowSoftChecks
    ) {
        for placement in placements {
            let holders = post.enumerated().filter { $0.element.fragment.contains(placement.sentence) }.map(\.offset)
            let range = Phase4bFlow.sectionRange(placement.chapter, in: post)
            result("PLACEMENT: \"\(placement.sentence)\" is in saved row(s) \(holders); "
                + "the section \"\(placement.chapter.prefix(12))...\" covers rows "
                + "\(range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "none")")
            soft.check(holders.count == 1 && range.map { range in holders.first.map { range.contains($0) } ?? false } == true,
                "\"\(placement.sentence)\" is in row(s) \(holders), expected one row inside the section \"\(placement.chapter)\" "
                + "(rows \(range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "none"))")
        }
    }
}

// MARK: - E-D7 The last chapter above its neighbour, then a chapter to the last place

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// The twelve-chapter copy of E-D7: chapters 9 to 12 are flat too, so the last chapters' cards sit next to each other and next to Notes
    /// (chapters 2 and 4 keep their sub-sections, far from the action).
    static var flatBook12Tail: [Int] { flatBook12 + [9, 10, 11, 12] }

    /// Hand-test step 11. On the FLATTENED twelve-chapter copy (chapters 1, 3 and 5 to 12 flat): step 1 drags the LAST chapter (Chapter 12,
    /// the one right before Notes) above Chapter 11; step 2 drags Chapter 10 into the empty strip under the last card, which lands it as the
    /// last chapter, before Notes and Bibliography. After each step, once the job has settled: the block table's heading order and every
    /// text row are the hand-worked document, the references read 1..N (N = 108, the twelve chapters' nine each) in reading order with the
    /// Notes numbered 1..N once each in the order of the references, the Bibliography rows are byte for byte those of the document before,
    /// Notes and Bibliography are the last rows, the Notes heading row is unchanged, and no heading is glued to the line before it (the
    /// separator rules of the page's move when a range is last or moves to the end). At the end the log shows two editor-first drags and
    /// File > Save Version shows the editor's text equals the table. An unchanged old-body app fails the trace checks and the footnote checks.
    func testMdDragLastChapterBeforeNotes_book12() {
        let size = Phase4bDelSize.book12
        let last = Self.chapter(12)
        let neighbour = Self.chapter(11)
        let toEnd = Self.chapter(10)
        guard startScenario(size, method: #function, flat: Self.flatBook12Tail), requireSection(last) != nil, requireSection(neighbour) != nil,
              requireSection(toEnd) != nil, requireChildless(last), requireChildless(neighbour), requireChildless(toEnd) else { return }
        let original = dragUserRows()
        let stepOne = dragMoving(original, last, before: neighbour)
        let stepTwo = dragMoving(stepOne, toEnd, before: nil)
        let stepOneHeadings = dragHeadings(stepOne)
        let stepTwoHeadings = dragHeadings(stepTwo)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        let lastKinds = pre.suffix(3).map { row -> String in
            let flags = (row.isNotes ? " notes" : "") + (row.isBibliography ? " bibliography" : "")
            return row.type + flags
        }
        note("SCENARIO: \"\(last.prefix(12))...\" (the last chapter, right before Notes) is dragged above \"\(neighbour.prefix(12))...\", then "
            + "\"\(toEnd.prefix(12))...\" is dragged to the last place; \(total) footnote references in all; "
            + "the last rows of the loaded document: \(lastKinds)")

        // Step 1.
        guard let dragOne = prepareDrag(last, before: neighbour, level: 1, option: false) else { return }
        let stepOneFrom = performDrag(dragOne)
        soft.check(waitForPerformed("sectionReorder", from: stepOneFrom, timeout: appWait(size.operationTimeout * 2, before: "step 1 performs")),
            "step 1's `sectionReorder` sequence never performed")
        soft.check(waitForHeadingOrder(stepOneHeadings, timeout: appWait(size.operationTimeout * 2, before: "the order after step 1")),
            "after step 1 the block table's heading order is not the hand-worked one (\(orderDifference(stepOneHeadings)))")
        settle()
        let afterOne = addDragChecks("after step 1 (settled)", arrangement: stepOne, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after step 1 (settled)", rows: afterOne, count: total, to: &soft)
        addTailCheck("after step 1", rows: afterOne, to: &soft)
        shot("md-last-chapter-drag-1-after-step-1")
        newPhase()

        // Step 2.
        guard let dragTwo = prepareEndDrag(toEnd, level: 1, option: false) else { return }
        let stepTwoFrom = performDrag(dragTwo)
        soft.check(waitForPerformed("sectionReorder", from: stepTwoFrom, timeout: appWait(size.operationTimeout * 2, before: "step 2 performs")),
            "step 2's `sectionReorder` sequence never performed")
        soft.check(waitForHeadingOrder(stepTwoHeadings, timeout: appWait(size.operationTimeout * 2, before: "the order after step 2")),
            "after step 2 the block table's heading order is not the hand-worked one (\(orderDifference(stepTwoHeadings)))")
        settle()
        let afterTwo = addDragChecks("after step 2 (settled)", arrangement: stepTwo, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after step 2 (settled)", rows: afterTwo, count: total, to: &soft)
        addTailCheck("after step 2", rows: afterTwo, to: &soft)
        if let range = Phase4bFlow.sectionRange(toEnd, in: afterTwo) {
            let managedStart = afterTwo.firstIndex(where: \.isManaged) ?? afterTwo.count
            soft.check(range.upperBound == managedStart,
                "\"\(toEnd)\" ends at row \(range.upperBound) but Notes start at row \(managedStart): it is not the last chapter")
        } else {
            soft.check(false, "\"\(toEnd)\" is not a section of the saved document")
        }
        soft.check(headingLevelInDatabase(of: toEnd) == 1,
            "\"\(toEnd)\" is level \(levelText(toEnd)) after the end drop (a chapter must stay a chapter)")

        addDragTraceChecks(from: stepOneFrom, drags: 2, to: &soft)
        addMarkdownMechanismChecks(from: stepOneFrom, commands: 2, to: &soft)
        addLogChecks(from: stepOneFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: afterTwo, what: "after both drags", to: &soft)
        shot("md-last-chapter-drag-2-after-step-2")
        assertAll(soft, "Markdown: the last chapter above its neighbour, then a chapter to the last place, on \(size.identifier) "
            + "(flattened copy, chapters \(Self.flatBook12Tail) flat; \(total) footnote references in all); \(countsLine)")
    }
}

// MARK: - E-D8 A drop that changes the heading level

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Hand-test step 12. On the FLATTENED book6 copy Chapter 6 is dragged above Chapter 5 and let go in the THIRD zone of the card above (the
    /// last heading of Chapter 4, a level-2 heading, so the zones are levels 1, 2 and 3), which makes it a level-3 heading under it:
    /// `### Chapter 6: ...`. Proven in the page and the rows: the page's reply line says one level changed (`levels=1`), the heading row of
    /// Chapter 6 holds three `#` and the block table's stored heading level is 3, every other row is the hand-worked document (the text of
    /// the heading line is the old one with the new `#` run), the references read 1..N (the old Markdown drag left 1..36, 46..54, 37..45).
    /// Cmd-Z puts the old level (1) and the old order back (rows equal the document as loaded), Cmd-Shift-Z makes it level 3 again, File >
    /// Save Version shows the editor's text equals the table, and after Cmd-W and a reopen the level, the order and the rows are the same.
    func testMdDragChangesHeadingLevel_book6() {
        let size = Phase4bDelSize.book6
        let pair = Self.dragPair(size)
        let newLevel = 3
        guard startScenario(size, method: #function, flat: pair.flat), requireSection(pair.moved) != nil, requireSection(pair.target) != nil,
              requireChildless(pair.moved), placeCaret(),
              let drag = prepareDrag(pair.moved, before: pair.target, level: newLevel, option: false) else { return }
        let original = dragUserRows()
        let originalHeadings = preHeadingFragments
        let arrangement = dragReleveling(dragMoving(original, pair.moved, before: pair.target), title: pair.moved, to: newLevel)
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        soft.check(headingLevelInDatabase(of: pair.moved) == 1,
            "TEST-SETUP: \"\(pair.moved)\" is level \(levelText(pair.moved)) as loaded, expected 1")
        note("SCENARIO: \"\(pair.moved.prefix(12))...\" (level 1) is dragged to just before \"\(pair.target.prefix(12))...\" "
            + "and let go in the level-\(newLevel) "
            + "zone of the card above (\"\(drag.dropOn)\"); \(total) footnote references")

        let dragFrom = performDrag(drag)
        soft.check(waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs")),
            "the drag's `sectionReorder` sequence never performed")
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order and level")),
            "after the drag the block table's heading list is not the hand-worked one, `#` marks included (\(orderDifference(movedHeadings)))")
        settle()
        let replies = reorderOkLines(from: dragFrom)
        result("LEVEL: the page's reply lines \(replies.map { String($0.suffix(60)) }); "
            + "the block table stores level \(levelText(pair.moved))")
        soft.check(replies.count == 1 && replies[0].contains(" levels=1"),
            "the page's reply \(replies.map { String($0.suffix(60)) }) does not report exactly one changed level (`levels=1`)")
        soft.check(headingLevelInDatabase(of: pair.moved) == newLevel,
            "the stored heading level of \"\(pair.moved)\" is \(levelText(pair.moved)), expected \(newLevel)")
        let afterDrag = addDragChecks("after the drag (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        let movedRow = afterDrag.first { $0.headingTitle == pair.moved }
        soft.check(movedRow?.headingLevel == newLevel && movedRow?.fragment.hasPrefix(String(repeating: "#", count: newLevel) + " ") == true,
            "the heading row of \"\(pair.moved)\" reads \"\(movedRow.map { String($0.fragment.prefix(14)) } ?? "missing")\", "
            + "expected \(newLevel) `#` marks")
        addFootnoteOrderCheck("after the drag (settled)", rows: afterDrag, count: total, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        shot("md-drag-level-1-after-the-drag")

        // Cmd-Z: the old level and the old order.
        let undo = pressStepRefocusing(redo: false, number: 1, watchToasts: false, what: "Cmd-Z after the level-changing drag", soft: &soft)
        soft.check(undo.decision == "structural" && undo.structural,
            "Cmd-Z was decided \(undo.decision) (structural ran: \(undo.structural)), not the drag's undo")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the old order and level come back")),
            "after Cmd-Z the block table's heading list is not the original one (\(orderDifference(originalHeadings)))")
        settle()
        let afterUndo = addDragChecks("after Cmd-Z (settled)", arrangement: original, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Z (settled)", rows: afterUndo, count: total, to: &soft)
        soft.check(headingLevelInDatabase(of: pair.moved) == 1,
            "after Cmd-Z the stored heading level of \"\(pair.moved)\" is \(levelText(pair.moved)), "
            + "expected the old level 1")
        shot("md-drag-level-2-after-cmd-z")

        // Cmd-Shift-Z: level 3 again.
        let redo = pressStepRefocusing(redo: true, number: 2, watchToasts: false, what: "Cmd-Shift-Z after the undo", soft: &soft)
        soft.check(redo.decision == "structural" && redo.structural,
            "Cmd-Shift-Z was decided \(redo.decision) (structural ran: \(redo.structural)), not the drag's redo")
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order and level come back")),
            "after Cmd-Shift-Z the block table's heading list is not the dragged one (\(orderDifference(movedHeadings)))")
        settle()
        let afterRedo = addDragChecks("after Cmd-Shift-Z (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Shift-Z (settled)", rows: afterRedo, count: total, to: &soft)
        soft.check(headingLevelInDatabase(of: pair.moved) == newLevel,
            "after Cmd-Shift-Z the stored heading level of \"\(pair.moved)\" is \(levelText(pair.moved)), "
            + "expected \(newLevel)")
        addMarkdownMechanismChecks(from: dragFrom, commands: 3, to: &soft)
        addLogChecks(from: dragFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: afterRedo, what: "after the drag, Cmd-Z and Cmd-Shift-Z", to: &soft)

        // Cmd-W and reopen: the new level is kept.
        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading list is not the dragged one (\(orderDifference(movedHeadings)))")
        addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, bibliographyExact: true, to: &soft)
        soft.check(headingLevelInDatabase(of: pair.moved) == newLevel,
            "after the reopen the stored heading level of \"\(pair.moved)\" is \(levelText(pair.moved)), "
            + "expected \(newLevel)")
        shot("md-drag-level-3-reopened")
        assertAll(soft, "Markdown: a drag that changes the heading level, Cmd-Z, Cmd-Shift-Z, Cmd-W and reopen, on \(size.identifier) "
            + "(flattened copy, chapters \(pair.flat) flat); \(countsLine)")
    }
}

// MARK: - E-D10 Drag, type in the moved chapter, then Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Hand-test steps 6 and 7. On the FLATTENED book6 copy the caret is put at the end of a seeded line ("Move06 line ...") of Chapter 6,
    /// Chapter 6 is dragged above Chapter 5, and " KEPTMDONE" is typed WITHOUT a click (the caret travelled with the moved text). Then
    /// Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z, each after the one before has finished:
    ///   Cmd-Z #1  a TEXT step: it takes the sentence away and only the sentence (typing can split into a few undo groups under load, so
    ///             up to four text presses are allowed and counted; the structural undo must not run before the line is back);
    ///   Cmd-Z #2  undoes the DRAG, the queued slow route (`start (markdown queued undo`; "Undoing..." may show): the original order, rows
    ///             equal the document as loaded;
    ///   Cmd-Shift-Z #1 redoes the DRAG (the queued slow route again): the dragged order, the references read 1..N after the settle;
    ///   Cmd-Shift-Z #2 is a TEXT step: it brings the sentence back, once, at the end of the Move06 line inside the moved chapter.
    /// FLIPPED by t-14f908b4 (the redo after a structural operation): this test used to pin the old limit, that typing done inside a
    /// dragged chapter could not be redone after the drag was undone (the undo's carry dropped the redo events inside the moved range, and
    /// the alternative put " KEPTMDONE" at the start of the hopped-over chapter's heading line). The editor now sets the redo steps aside at
    /// the undo and puts them back after the redo, so the last press brings the sentence back. The test asserts that the sentence is back
    /// exactly once (in the rows, at the end of the Move06 line, and, by the Save Version round trip, in the editor), that every heading row
    /// equals its expected text (the hopped-over heading "# Chapter 5" and every other heading line is intact), that the order is the
    /// dragged one and that the rows equal the page. The last press must not beep.
    func testMdUndoOrderAfterTypingFollowingDrop_book6() {
        let size = Phase4bDelSize.book6
        let pair = Self.dragPair(size)
        let moveLine = Self.seededLine("Move06")
        let seed = Self.lineSeed([(title: pair.moved, line: moveLine)])
        guard startScenario(size, method: #function, flat: pair.flat, seed: seed), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil, requireChildless(pair.moved), let moveRow = requireSeededRow(moveLine),
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: false),
              placeCaretInSection(pair.moved, line: moveLine, prefix: "Move06") else { return }
        let original = dragUserRows()
        let originalHeadings = preHeadingFragments
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        note("SCENARIO: the caret is at the end of the Move06 line in \"\(pair.moved.prefix(12))...\"; that chapter is dragged to just before "
            + "\"\(pair.target.prefix(12))...\"; \"\(Self.phraseOne)\" is typed with no click; "
            + "then Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z; \(total) footnote references")

        let dragFrom = performDrag(drag)
        typeNow(" " + Self.phraseOne)
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order")),
            "after the job the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        soft.check(waitForLine(moveLine + " " + Self.phraseOne, startingWith: "Move06", timeout: 90),
            "the sentence typed straight after the drop, with no click, is not at the end of the Move06 line in the block table "
            + "(it reads \"\(lineInDatabase(startingWith: "Move06") ?? "nothing")\")")
        settle()
        addDragChecks("after the drag and the typing (settled)", arrangement: arrangement, typed: [moveRow: moveLine + " " + Self.phraseOne],
                      bibliographyExact: true, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        newPhase()

        // Cmd-Z #1: the sentence goes, as text steps.
        let firstFrom = traceLinesCount()
        var textPresses = 0
        var sentenceGone = false
        while textPresses < 4, !sentenceGone {
            textPresses += 1
            let press = pressStepRefocusing(redo: false, number: textPresses, watchToasts: false,
                                            what: "Cmd-Z #\(textPresses) (the sentence)", soft: &soft)
            soft.check(!press.structural,
                "Cmd-Z #\(textPresses) was decided \(press.decision) and ran a STRUCTURAL undo before the sentence was gone")
            if press.structural { break }
            sentenceGone = waitForLine(moveLine, startingWith: "Move06", timeout: 20)
        }
        let moveNow = lineInDatabase(startingWith: "Move06") ?? "nothing"
        result("CMD-Z #1: \(textPresses) text press(es) took the sentence away (the line reads \"\(moveNow)\")")
        soft.check(sentenceGone, "after \(textPresses) Cmd-Z press(es) the Move06 line still reads \"\(moveNow)\", "
            + "expected \"\(moveLine)\" (only the sentence removed)")
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "Cmd-Z #1 changed the heading order (\(orderDifference(movedHeadings))): it must remove only the sentence")
        soft.check(structuralStartCount(from: firstFrom) == 0,
            "a structural undo began during the text press(es): \(structuralStartCount(from: firstFrom))")
        settle()

        // Cmd-Z #2: the drag is undone.
        let secondFrom = traceLinesCount()
        let second = pressStepRefocusing(redo: false, number: textPresses + 1, watchToasts: false, what: "Cmd-Z #2 (the drag)", soft: &soft)
        let secondStart = traceLines(from: secondFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #2: decided \(second.decision); sequence began `\(secondStart?.step ?? "none")`; \"Undoing\" notice(s) in the log "
            + "\(undoingToastCount(from: secondFrom)) (allowed)")
        soft.check(second.decision == "structural" && second.structural && secondStart?.step.hasPrefix("start (markdown queued undo") == true,
            "Cmd-Z #2 was decided \(second.decision) (structural ran: \(second.structural)) and began `\(secondStart?.step ?? "none")`, "
            + "expected the drag's queued slow undo `start (markdown queued undo)`")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the original order")),
            "after Cmd-Z #2 the block table's heading order is not the original one (\(orderDifference(originalHeadings)))")
        settle()
        let afterUndo = addDragChecks("after Cmd-Z #2 (settled)", arrangement: original, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Z #2 (settled)", rows: afterUndo, count: total, to: &soft)

        // Cmd-Shift-Z #1: the drag is redone.
        let thirdFrom = traceLinesCount()
        let third = pressStepRefocusing(redo: true, number: textPresses + 2, watchToasts: false, what: "Cmd-Shift-Z #1 (the drag)", soft: &soft)
        let thirdStart = traceLines(from: thirdFrom).first { $0.family == .sequence && $0.label == "redo" && $0.isOpStart }
        result("CMD-SHIFT-Z #1: decided \(third.decision); sequence began `\(thirdStart?.step ?? "none")`")
        soft.check(third.decision == "structural" && third.structural,
            "Cmd-Shift-Z #1 was decided \(third.decision) (structural ran: \(third.structural)), not the drag's redo")
        soft.check(waitForHeadingOrder(movedHeadings, timeout: appWait(size.operationTimeout * 2, before: "the dragged order comes back")),
            "after Cmd-Shift-Z #1 the block table's heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        settle()
        let afterRedo = addDragChecks("after Cmd-Shift-Z #1 (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Shift-Z #1 (settled)", rows: afterRedo, count: total, to: &soft)

        // Cmd-Shift-Z #2: a TEXT step. The sentence comes back, once, at the end of the Move06 line of the moved chapter (t-14f908b4).
        let fourthFrom = traceLinesCount()
        let fourth = pressStepRefocusing(redo: true, number: textPresses + 3, watchToasts: false, what: "Cmd-Shift-Z #2 (the sentence)", soft: &soft)
        let sentenceBack = waitForLine(moveLine + " " + Self.phraseOne, startingWith: "Move06", timeout: 90)
        result("CMD-SHIFT-Z #2 (the redo after a structural operation, t-14f908b4): decided \(fourth.decision); structural undo/redo sequences "
            + "begun \(structuralStartCount(from: fourthFrom)); the sentence in the block table: \(blocksContaining(Self.phraseOne)) row(s)")
        _ = waitForLogQuiet(quiet: 3, cap: capped(30))
        settle()
        soft.check(structuralStartCount(from: fourthFrom) == 0, "Cmd-Shift-Z #2 began a structural sequence: it must be a plain text step")
        soft.check(sentenceBack,
            "the sentence \"\(Self.phraseOne)\" is not back at the end of the Move06 line after Cmd-Shift-Z #2 (the line reads "
            + "\"\(lineInDatabase(startingWith: "Move06") ?? "nothing")\"): typing done inside a dragged chapter must be redone after "
            + "undoing and redoing the drag")
        soft.check(blocksContaining(Self.phraseOne) == 1,
            "the sentence \"\(Self.phraseOne)\" is in \(blocksContaining(Self.phraseOne)) saved row(s) after Cmd-Shift-Z #2, expected exactly 1")
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-Shift-Z #2 the heading lines are not exactly the expected ones, a heading line may have been damaged "
            + "(\(orderDifference(movedHeadings)))")
        let end = addDragChecks("after Cmd-Shift-Z #2 (settled)", arrangement: arrangement, typed: [moveRow: moveLine + " " + Self.phraseOne],
                                bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Shift-Z #2 (settled)", rows: end, count: total, to: &soft)
        addMarkdownMechanismChecks(from: dragFrom, commands: 3, to: &soft)
        addLogChecks(from: dragFrom, checkBeeps: true, to: &soft)
        addScreenEqualsDatabaseCheck(before: end, what: "at the end (the sentence is on screen too)", to: &soft)
        shot("md-undo-order-after-typing-end")
        assertAll(soft, "Markdown: drag, type in the moved chapter with no click, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z (the typing comes back, "
            + "t-14f908b4), on \(size.identifier) (flattened copy, chapters \(pair.flat) flat); \(countsLine)")
    }

    /// How many structural `undo` / `redo` sequences began since log index `index`.
    func structuralStartCount(from index: Int) -> Int {
        traceLines(from: index).filter { $0.family == .sequence && ($0.label == "undo" || $0.label == "redo") && $0.isOpStart }.count
    }
}

// MARK: - E-D11 A level-only drop, and an Option-drag with its sub-sections, each after typing

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Hand-test step 12 (the drop in place) and the Option-drag half of step 6. On the FLATTENED book6 copy two chapters carry a seeded
    /// line under their heading ("Move06 line ..." in Chapter 6, "Opt04 line ..." in Chapter 4).
    /// (a) The caret is put at the end of the Move06 line, " KEPTMDONE" is typed, and Chapter 6 is let go in the level-2 zone of the card of
    ///     Chapter 5, which is right above it: the drop moves nothing and only changes the level (`## Chapter 6: ...`). It takes the
    ///     editor-first road (the sequence began `start (editor-first) mode=markdown`, the page's reply reports `levels=1`), keeps the sentence
    ///     typed just before it, and leaves the order alone: the heading list is the original one with that one heading at level 2.
    /// (b) The caret is put at the end of the Opt04 line of Chapter 4, which has 16 sub-sections, " KEPTMDTWO" is typed there, and Chapter 4
    ///     is Option-dragged above Chapter 3: the sub-sections move with it (its own first sub-heading follows it), the sentence is kept in
    ///     its row inside the moved chapter, the heading list and every text row are the hand-worked document (Chapter 6 still level 2), the
    ///     references read 1..N, and File > Save Version shows the editor's text equals the table. The log shows two editor-first drags.
    func testMdLevelOnlyAndOptionDropWithTyping_book6() {
        let size = Phase4bDelSize.book6
        let levelMoved = Self.chapter(6)
        let optionMoved = Self.chapter(4)
        let optionTarget = Self.chapter(3)
        let moveLine = Self.seededLine("Move06")
        let optLine = Self.seededLine("Opt04")
        let seed = Self.lineSeed([(title: levelMoved, line: moveLine), (title: optionMoved, line: optLine)])
        guard startScenario(size, method: #function, flat: Self.flatBook6, seed: seed), requireSection(levelMoved) != nil,
              requireSection(optionMoved) != nil, requireSection(optionTarget) != nil, requireChildless(levelMoved),
              let moveRow = requireSeededRow(moveLine), let optRow = requireSeededRow(optLine) else { return }
        let original = dragUserRows()
        let total = Phase4bFlowWalk(rows: pre).refs.count
        // (a) the hand-worked document after the level-only drop; (b) after the Option-drag as well.
        let afterLevel = dragReleveling(original, title: levelMoved, to: 2)
        let afterOption = dragMoving(afterLevel, optionMoved, before: optionTarget)
        let levelHeadings = dragHeadings(afterLevel)
        let optionHeadings = dragHeadings(afterOption)
        let typedA = [moveRow: moveLine + " " + Self.phraseOne]
        let typedB = [moveRow: moveLine + " " + Self.phraseOne, optRow: optLine + " " + Self.phraseTwo]
        var soft = Phase4bFlowSoftChecks()
        soft.check(levelHeadings != preHeadingFragments, "TEST-SETUP: the level-only drop changes nothing in the heading list")
        note("SCENARIO: (a) \"\(Self.phraseOne)\" is typed in the Move06 line of \"\(levelMoved.prefix(12))...\", "
            + "which is then let go in the level-2 zone of the card of its own predecessor (a drop in place); "
            + "(b) \"\(Self.phraseTwo)\" is typed in the Opt04 line of \"\(optionMoved.prefix(12))...\", "
            + "which is then Option-dragged above \"\(optionTarget.prefix(12))...\"; \(total) footnote references")

        // (a) The level-only drop.
        guard let dropInPlace = prepareDrag(levelMoved, before: levelMoved, level: 2, option: false),
              placeCaretInSection(levelMoved, line: moveLine, prefix: "Move06") else { return }
        typeNow(" " + Self.phraseOne)
        let levelFrom = performDrag(dropInPlace)
        soft.check(
            waitForPerformed("sectionReorder", from: levelFrom, timeout: appWait(size.operationTimeout * 2, before: "the level-only drop performs")),
            "the level-only drop's `sectionReorder` sequence never performed")
        soft.check(waitForHeadingOrder(levelHeadings, timeout: appWait(size.operationTimeout * 2, before: "the new level")),
            "after the level-only drop the block table's heading list is not the original one with one level changed "
            + "(\(orderDifference(levelHeadings)))")
        soft.check(waitForLine(moveLine + " " + Self.phraseOne, startingWith: "Move06", timeout: 90),
            "the sentence typed just before the level-only drop is not at the end of the Move06 line in the block table "
            + "(it reads \"\(lineInDatabase(startingWith: "Move06") ?? "nothing")\")")
        settle()
        let replies = reorderOkLines(from: levelFrom)
        result("LEVEL-ONLY DROP: the page's reply lines \(replies.map { String($0.suffix(60)) }); the block table stores level "
            + "\(levelText(levelMoved))")
        soft.check(replies.count == 1 && replies[0].contains(" levels=1"),
            "the page's reply \(replies.map { String($0.suffix(60)) }) does not report exactly one changed level (`levels=1`)")
        soft.check(headingLevelInDatabase(of: levelMoved) == 2,
            "the stored heading level of \"\(levelMoved)\" is \(levelText(levelMoved)), expected 2")
        addDragChecks("after the level-only drop (settled)", arrangement: afterLevel, typed: typedA, bibliographyExact: true, to: &soft)
        addDragTraceChecks(from: levelFrom, drags: 1, to: &soft)
        shot("md-level-only-1-after-the-level-only-drop")
        newPhase()

        // (b) The Option-drag.
        guard let optionDrag = prepareDrag(optionMoved, before: optionTarget, level: 1, option: true),
              placeCaretInSection(optionMoved, line: optLine, prefix: "Opt04") else { return }
        typeNow(" " + Self.phraseTwo)
        let optionFrom = performDrag(optionDrag)
        soft.check(
            waitForPerformed("sectionReorder", from: optionFrom, timeout: appWait(size.operationTimeout * 2, before: "the Option-drag performs")),
            "the Option-drag's `sectionReorder` sequence never performed")
        addOptionCarriedCheck(optionMoved, expected: optionHeadings, what: "after the Option-drag", to: &soft)
        soft.check(waitForLine(optLine + " " + Self.phraseTwo, startingWith: "Opt04", timeout: 90),
            "the sentence typed just before the Option-drag is not at the end of the Opt04 line in the block table "
            + "(it reads \"\(lineInDatabase(startingWith: "Opt04") ?? "nothing")\")")
        settle()
        soft.check(headingFragmentsInDatabase() == optionHeadings,
            "after the Option-drag the block table's heading list is not the hand-worked one (\(orderDifference(optionHeadings)))")
        let post = addDragChecks("after the Option-drag (settled)", arrangement: afterOption, typed: typedB, bibliographyExact: true, to: &soft)
        addSentencePlacementChecks(post, [(levelMoved, Self.phraseOne), (optionMoved, Self.phraseTwo)], to: &soft)
        addFootnoteOrderCheck("after the Option-drag (settled)", rows: post, count: total, to: &soft)
        soft.check(headingLevelInDatabase(of: levelMoved) == 2,
            "after the Option-drag the stored heading level of \"\(levelMoved)\" is \(levelText(levelMoved)), expected 2")
        addDragTraceChecks(from: levelFrom, drags: 2, to: &soft)
        addMarkdownMechanismChecks(from: levelFrom, commands: 2, to: &soft)
        addLogChecks(from: levelFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after both drops", to: &soft)
        shot("md-level-only-2-after-the-option-drag")
        assertAll(soft, "Markdown: a level-only drop and an Option-drag, each after typing, on \(size.identifier) "
            + "(flattened copy, chapters \(Self.flatBook6) flat; \(total) footnote references in all); \(countsLine)")
    }
}

// MARK: - E-D12 / E-D13 The Notes after a footnoted drag on the REPEATED-footnote book (judge items a and b)

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// The log index of the first line since `index` that holds `needle`.
    func firstLogLine(containing needle: String, from index: Int) -> Int? { mdLogIndex(containing: [needle], from: index) }

    /// JUDGE ITEM (a), "the next action at once" case, on the REPEATED-footnote book6 (the generated books repeat one chapter's nine
    /// footnote texts in every chapter; NO `rqTaggingNotes` here, on purpose: with tagged notes the page's Notes text always differs from
    /// the rows' text and the case below cannot arise). Chapter 4 (with its 16 sub-sections, references 28..36) is Option-dragged above
    /// Chapter 3 (19..27), with the first job held 30 s; the very next thing done is File > Save Version (the dialog, a name, Save: nothing
    /// is waited for in between), the very next thing after the version row exists is Cmd-W, and then the project is reopened. THE ORDER OF
    /// EVENTS is proven from the app's log, not by waiting: the job's `onReserved fired` line, then the Save Version request (the log index
    /// taken just before the shortcut), then the job's hold release, which is the job applied and the live text flushed (so Save Version
    /// was asked for while the job was still pending). After the reopen: the heading order is the dragged one, the references read
    /// 1..54 in reading order and the Notes hold the definitions 1..54 in order, once each (the saved rows, which are what a reopen
    /// reads). An unchanged old-body app fails the trace checks; the unfixed Notes push shows as definitions out of order here
    /// (the page's relabelled but unsorted Notes written into the rows by Save Version's flush and by Cmd-W).
    func testMdDragSaveVersionAndCloseAtOnce_book6() {
        let size = Phase4bDelSize.book6
        let pair = Self.footnoteDragPair(size)
        let env = [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"]
        guard startScenario(size, method: #function, env: env, flat: pair.flat), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil,
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: true) else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        let distinct = Set(Phase4bFlowWalk(rows: pre).definitions.map(\.text)).count
        note("SCENARIO: \"\(pair.moved.prefix(12))...\" is Option-dragged to just before \"\(pair.target.prefix(12))...\" (the first job is held "
            + "\(Self.overlapHoldMs) ms), then at once File > Save Version, then at once Cmd-W, then reopen; \(total) footnote references, "
            + "\(distinct) DISTINCT definition texts (repeated footnotes: the old Notes text and the sorted one are the same string)")

        let dragFrom = performDrag(drag)
        tail.poll()
        let saveFrom = tail.lines.count
        let saved = saveVersion(named: "Drag then close at once")
        soft.check(saved, "the version \"Drag then close at once\" was not saved")
        addOptionCarriedCheck(pair.moved, expected: movedHeadings, what: "after Save Version", to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        if let opId = reorderOpId(from: dragFrom) {
            let window = jobWindow(opId: opId, from: dragFrom)
            result("LOG ORDER: the job reserved at log line \(figure(window.reservedIndex)); Save Version requested at line \(saveFrom); "
                + "the hold released (job applied and flushed) at line \(figure(window.releasedIndex)); the first whole-document flush "
                + "line after the request at \(figure(firstLogLine(containing: "[FLUSH] Input length", from: saveFrom)))")
            soft.check(window.reservedIndex != nil && window.releasedIndex != nil && window.releasedIndex! > saveFrom,
                "TEST-SETUP: Save Version was requested at log line \(saveFrom) but the job's hold was released at line "
                + "\(figure(window.releasedIndex)): the job was not pending when Save Version began")
        } else {
            soft.check(false, "no `sectionReorder` sequence began since the press: the drag did not register as a drag")
        }

        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        let reopened = addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-W and the reopen", rows: reopened, count: total, to: &soft)
        shot("md-drag-save-version-close-reopened")
        assertAll(soft, "Markdown: Option-drag, Save Version at once, Cmd-W at once, reopen, on \(size.identifier) with REPEATED footnote texts "
            + "(\(distinct) distinct of \(total); flattened copy, chapters \(pair.flat) flat); \(countsLine)")
    }

    /// JUDGE ITEM (b), the Notes after a footnoted drag with every rebuild push delayed, on the REPEATED-footnote book6 (OBSERVATION-ONLY
    /// for the stale path, by the judge's ruling). The existing UI-testing seam `FF_UI_TESTING_REBUILD_PUSH_DELAY_MS`
    /// (`ContentView.holdRebuildFlushWindowForUITesting`, 3 s here, under the 4 s the content-state watchdog tolerates) is set, and Chapter 4
    /// (references 28..36) is Option-dragged above Chapter 3 (19..27). THIS TEST DOES NOT PROVE THE STALE PATH; THE UNIT TESTS DO (the
    /// Tier 1 test of `MarkdownManagedRegionPusher.pushRebuild` with a fake page that answers `regionChanged`). Why it cannot: the seam's
    /// hold sits AFTER the rebuild has read the content record (`markdownRegionRead()`) and BEFORE it pushes, so it widens the read-to-push
    /// window but cannot move the READ ahead of the page's own `contentChanged` for the footnote relabel (about 190 ms after the relabel),
    /// which is what makes the record lag the page. Whether a run enters the stale path is a race (the failing run: Notes write 54 ms,
    /// rebuild read at ~140 ms; the passing sibling: write 247 ms). So: what is ASSERTED on every run is the outcome the user sees: the
    /// references read 1..54 and the Notes are numbered 1..54 once each in order in the saved rows, on the page (File > Save Version writes
    /// the page's text into the rows and the table is identical; the Notes labels the accessibility tree lists on screen are consecutive with
    /// no duplicate label, and a click on the Notes card that yields no label within 30 s is a failure, with the tree dump and the screenshot
    /// attached for the diagnosis), and
    /// again in the rows after Cmd-W and a reopen; the editor-first trace; and that the seam was applied. What is only RECORDED (result
    /// lines, never a failure) is whether the stale path was entered and what followed: `[MdRegionPush] notes: ... re-push owed`, then a
    /// SECOND `notes rebuild: starts`, then a page `docChanged: true`.
    func testMdDragNotesStalePathForced_book6() {
        let size = Phase4bDelSize.book6
        let pair = Self.footnoteDragPair(size)
        let env = ["FF_UI_TESTING_REBUILD_PUSH_DELAY_MS": "3000"]
        guard startScenario(size, method: #function, env: env, flat: pair.flat), requireSection(pair.moved) != nil,
              requireSection(pair.target) != nil,
              let drag = prepareDrag(pair.moved, before: pair.target, level: pair.level, option: true) else { return }
        let original = dragUserRows()
        let arrangement = dragMoving(original, pair.moved, before: pair.target)
        let movedHeadings = dragHeadings(arrangement)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        note("SCENARIO: \"\(pair.moved.prefix(12))...\" is Option-dragged to just before \"\(pair.target.prefix(12))...\" with every rebuild push "
            + "delayed 3000 ms; \(total) footnote references, repeated footnote texts (no tagging)")

        let dragFrom = performDrag(drag)
        soft.check(waitForPerformed("sectionReorder", from: dragFrom, timeout: appWait(size.operationTimeout * 2, before: "the drag performs")),
            "the drag's `sectionReorder` sequence never performed")
        addOptionCarriedCheck(pair.moved, expected: movedHeadings, what: "after the drag", to: &soft)
        _ = waitForLogQuiet(quiet: 6, cap: capped(120))
        settle()

        // The log: was the stale path entered, and did it run in the right order?
        let owed = firstLogLine(containing: "[MdRegionPush] notes:", from: dragFrom).flatMap { first -> Int? in
            mdLogIndex(containing: ["[MdRegionPush] notes:", "re-push owed"], from: first)
        }
        let secondStart = owed.flatMap { firstLogLine(containing: "notes rebuild: starts", from: $0 + 1) }
        let pageChange = secondStart.flatMap { firstLogLine(containing: "docChanged: true", from: $0 + 1) }
        let startsInAll = logLines(containing: "notes rebuild: starts", from: dragFrom).count
        let holdLines = logLines(containing: "[RebuildPushHold]", from: dragFrom).count
        result("STALE PATH: `re-push owed` at log line \(figure(owed)); the next `notes rebuild: starts` at \(figure(secondStart)); the next page "
            + "`docChanged: true` at \(figure(pageChange)); `notes rebuild: starts` lines in all \(startsInAll); push-hold lines \(holdLines)")
        soft.check(holdLines >= 2, "the rebuild-push seam wrote \(holdLines) `[RebuildPushHold]` line(s) since the drag: it was not applied")
        // OBSERVATION ONLY (judge ruling): whether the stale path was entered in this run is recorded, never asserted.
        let entered = owed != nil
        let sequenceHolds = entered && secondStart != nil && pageChange != nil && startsInAll >= 2
        result("STALE PATH OBSERVATION: entered in this run: \(Self.yesNo(entered)); the sequence `re-push owed` -> a second `notes rebuild: starts` "
            + "-> a page docChanged followed: \(entered ? Self.yesNo(sequenceHolds) : "n/a (not entered; the unit tests prove this path)")")

        // The end state: rows first, then the page (Notes on screen, then Save Version equality).
        let rows = addDragChecks("after the drag (settled)", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after the drag (settled)", rows: rows, count: total, to: &soft)
        addDragTraceChecks(from: dragFrom, drags: 1, to: &soft)
        addNotesOnScreenCheck("after the drag", to: &soft)
        addScreenEqualsDatabaseCheck(before: rows, what: "after the drag (the page's Notes equal the rows' Notes)", to: &soft)
        shot("md-notes-stale-path-end")

        // Cmd-W and reopen (the delay seam is switched off for the reopen): the saved Notes and references are still 1..54, in order.
        app.launchEnvironment["FF_UI_TESTING_REBUILD_PUSH_DELAY_MS"] = nil
        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == movedHeadings,
            "after Cmd-W and the reopen the heading order is not the dragged one (\(orderDifference(movedHeadings)))")
        let reopened = addDragChecks("after Cmd-W and the reopen", arrangement: arrangement, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-W and the reopen", rows: reopened, count: total, to: &soft)
        assertAll(soft, "Markdown: the Notes after an Option-drag with the rebuild push delayed 3 s (stale path observed, not asserted), on "
            + "\(size.identifier) with REPEATED footnote texts (flattened copy, chapters \(pair.flat) flat; "
            + "\(total) footnote references); \(countsLine)")
    }
}

// MARK: - E-D14 Two drags in a row, then Cmd-Z twice (judge R3)

extension WriteQueuePhase4bMarkdownEFE2ETests {
    /// Every chapter of book6 flat: the six chapter cards, Notes and Bibliography all sit in the sidebar's visible band at once, so two
    /// drags in different places can be prepared up front and pressed one straight after the other.
    static var flatBook6All: [Int] { [1, 2, 3, 4, 5, 6] }

    /// The titles of the level-1 headings (the chapters) of `rows`, in order.
    func chapterTitles(_ rows: [Phase4bRqRow]) -> [String] {
        rows.compactMap { $0.row.headingLevel == 1 ? $0.row.headingTitle : nil }
    }

    /// Nil when the sidebar lists the cards of `titles` top to bottom in this order; else what is wrong.
    func sidebarOrderProblem(_ titles: [String]) -> String? {
        var previous: (title: String, minY: CGFloat)?
        for title in titles {
            let card = sidebarCard(title)
            guard card.exists else { return "the sidebar has no card \"\(title.prefix(30))\"" }
            let minY = card.frame.minY
            if let previous, minY <= previous.minY {
                return "\"\(title.prefix(20))...\" (y \(Int(minY))) is not below \"\(previous.title.prefix(20))...\" (y \(Int(previous.minY)))"
            }
            previous = (title, minY)
        }
        return nil
    }

    /// Looks (a condition, polled) for the sidebar to list the chapters in `titles` order; nil when it does, else the last problem.
    func waitForSidebarOrder(_ titles: [String], timeout: TimeInterval) -> String? {
        let deadline = Date(timeIntervalSinceNow: appWait(timeout, before: "the sidebar's card order is looked for"))
        var problem = sidebarOrderProblem(titles)
        while problem != nil, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            problem = sidebarOrderProblem(titles)
        }
        return problem
    }

    /// Judge R3, the everyday "drag, then drag again" flow, on the REPEATED-footnote book6 (no tagged notes) with EVERY chapter flat. Two
    /// plain drags: Chapter 6 above Chapter 5, then Chapter 3 above Chapter 2 (the second drops at another height, the sidebar ignores a
    /// drop at exactly the point of the one before). Both are prepared before either is pressed and pressed one straight after the other;
    /// the first job is held 30 s, so the second drag is GIVEN while the first job is pending, and the log proves it: the log index taken
    /// just before the second press is below the log index of the first job's hold release (a TEST-SETUP failure otherwise), and the
    /// second click's "Finishing the last change..." notice is in the log (UX contract 4.2: held, never refused). After both have
    /// settled: the block table's heading order, every text row and the sidebar's chapter order are the hand-worked document (1 2 3 4 6 5
    /// then 1 3 2 4 6 5), the references read 1..54 with the Notes 1..54 once each, two editor-first sequences and their reply lines, and
    /// every Markdown hold raised is released. Then Cmd-Z, each after the one before has finished: the SECOND drag is undone (queued slow
    /// route, `start (markdown queued undo`) and rows, sidebar and footnotes are the state after the first drag; Cmd-Z again: the original
    /// order, the rows equal the document as loaded byte for byte (Notes and Bibliography included), footnotes 1..54. At the end File >
    /// Save Version shows the editor's text equals the table, and after Cmd-W and a reopen the final state (the original) is kept.
    /// Rich Text has the analogue `testReorderEFTwiceThenUndo_book6`.
    func testMdTwoDragsInARowThenUndoTwice_book6() {
        let size = Phase4bDelSize.book6
        let one = (moved: Self.chapter(6), target: Self.chapter(5))
        let two = (moved: Self.chapter(3), target: Self.chapter(2))
        let env = [Self.holdKey: String(Self.overlapHoldMs), Self.holdFirstKey: "1"]
        guard startScenario(size, method: #function, env: env, flat: Self.flatBook6All), requireSection(one.moved) != nil,
              requireSection(one.target) != nil, requireSection(two.moved) != nil, requireSection(two.target) != nil,
              requireChildless(one.moved), requireChildless(two.moved), placeCaret(),
              let dragOne = prepareDrag(one.moved, before: one.target, level: 1, option: false),
              let dragTwo = prepareDrag(two.moved, before: two.target, level: 1, option: false, dropY: 0.62) else { return }
        let original = dragUserRows()
        let afterOne = dragMoving(original, one.moved, before: one.target)
        let afterTwo = dragMoving(afterOne, two.moved, before: two.target)
        let originalHeadings = preHeadingFragments
        let oneHeadings = dragHeadings(afterOne)
        let twoHeadings = dragHeadings(afterTwo)
        let total = Phase4bFlowWalk(rows: pre).refs.count
        var soft = Phase4bFlowSoftChecks()
        soft.check(twoHeadings != oneHeadings && oneHeadings != originalHeadings, "TEST-SETUP: the two drags do not change the heading list each")
        note("SCENARIO: \"\(one.moved.prefix(12))...\" is dragged above \"\(one.target.prefix(12))...\" and at once "
            + "\"\(two.moved.prefix(12))...\" above \"\(two.target.prefix(12))...\" "
            + "(the first job is held \(Self.overlapHoldMs) ms), then Cmd-Z twice; every chapter flat; "
            + "\(total) footnote references, repeated footnote texts")

        let firstFrom = performDrag(dragOne)
        let secondFrom = performDrag(dragTwo)

        // Both drags settle; the log says the second was given while the first job was pending.
        soft.check(waitForPerformed("sectionReorder", count: 2, from: firstFrom,
                                    timeout: appWait(size.operationTimeout * 3, before: "both drags perform")),
            "not both `sectionReorder` sequences performed (\(performedCount("sectionReorder", from: firstFrom)) of 2)")
        soft.check(waitForHeadingOrder(twoHeadings, timeout: appWait(size.operationTimeout * 3, before: "the order after both drags")),
            "after both drags the block table's heading order is not the hand-worked one (\(orderDifference(twoHeadings)))")
        settle()
        if let opOne = reorderOpId(from: firstFrom) {
            let window = jobWindow(opId: opOne, from: firstFrom)
            let notices = toastLines(containing: "Finishing the last change", from: secondFrom).count
            result("LOG ORDER: the first job reserved at line \(figure(window.reservedIndex)); the second drag pressed at line \(secondFrom); "
                + "the first hold released at line \(figure(window.releasedIndex)); "
                + "\"Finishing the last change\" notice(s) after the second press: \(notices)")
            soft.check(window.releasedIndex != nil && window.releasedIndex! > secondFrom,
                "TEST-SETUP: the second drag was pressed at log line \(secondFrom) but the first job's hold was released at line "
                + "\(figure(window.releasedIndex)): the first job was not pending when the second drag was given")
            soft.check(notices >= 1, "the second drag waited behind the first job's hold and no \"Finishing the last change\" notice was logged")
        } else {
            soft.check(false, "no `sectionReorder` sequence began since the first press")
        }
        let afterBoth = addDragChecks("after both drags (settled)", arrangement: afterTwo, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after both drags (settled)", rows: afterBoth, count: total, to: &soft)
        let sidebarBoth = waitForSidebarOrder(chapterTitles(afterTwo), timeout: 60)
        soft.check(sidebarBoth == nil, "after both drags the sidebar's chapter order differs from the hand-worked one: \(sidebarBoth ?? "")")
        addDragTraceChecks(from: firstFrom, drags: 2, to: &soft)
        addMarkdownMechanismChecks(from: firstFrom, commands: 2, to: &soft)
        addLogChecks(from: firstFrom, checkPushes: false, to: &soft)
        shot("md-two-drags-1-after-both-drags")
        newPhase()

        // Cmd-Z #1: the second drag is undone; the state is the one after the first drag.
        let undoOneFrom = traceLinesCount()
        let undoOne = pressStepRefocusing(redo: false, number: 1, watchToasts: false, what: "Cmd-Z #1 (the second drag)", soft: &soft)
        let undoOneStart = traceLines(from: undoOneFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #1: decided \(undoOne.decision); sequence began `\(undoOneStart?.step ?? "none")`; \"Undoing\" notice(s) in the log "
            + "\(undoingToastCount(from: undoOneFrom)) (allowed)")
        soft.check(undoOne.decision == "structural" && undoOne.structural && undoOneStart?.step.hasPrefix("start (markdown queued undo") == true,
            "Cmd-Z #1 was decided \(undoOne.decision) (structural ran: \(undoOne.structural)) and began `\(undoOneStart?.step ?? "none")`, "
            + "expected the second drag's queued slow undo `start (markdown queued undo)`")
        soft.check(waitForHeadingOrder(oneHeadings, timeout: appWait(size.operationTimeout * 2, before: "the state after the first drag")),
            "after Cmd-Z #1 the block table's heading order is not the one after the first drag (\(orderDifference(oneHeadings)))")
        settle()
        let afterUndoOne = addDragChecks("after Cmd-Z #1 (settled)", arrangement: afterOne, bibliographyExact: true, to: &soft)
        addFootnoteOrderCheck("after Cmd-Z #1 (settled)", rows: afterUndoOne, count: total, to: &soft)
        let sidebarOne = waitForSidebarOrder(chapterTitles(afterOne), timeout: 60)
        soft.check(sidebarOne == nil, "after Cmd-Z #1 the sidebar's chapter order is not the one after the first drag: \(sidebarOne ?? "")")

        // Cmd-Z #2: the first drag is undone; the document is as loaded.
        let undoTwoFrom = traceLinesCount()
        let undoTwo = pressStepRefocusing(redo: false, number: 2, watchToasts: false, what: "Cmd-Z #2 (the first drag)", soft: &soft)
        let undoTwoStart = traceLines(from: undoTwoFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("CMD-Z #2: decided \(undoTwo.decision); sequence began `\(undoTwoStart?.step ?? "none")`")
        soft.check(undoTwo.decision == "structural" && undoTwo.structural && undoTwoStart?.step.hasPrefix("start (markdown queued undo") == true,
            "Cmd-Z #2 was decided \(undoTwo.decision) (structural ran: \(undoTwo.structural)) and began `\(undoTwoStart?.step ?? "none")`, "
            + "expected the first drag's queued slow undo `start (markdown queued undo)`")
        soft.check(waitForHeadingOrder(originalHeadings, timeout: appWait(size.operationTimeout * 2, before: "the original order")),
            "after Cmd-Z #2 the block table's heading order is not the original one (\(orderDifference(originalHeadings)))")
        settle()
        let end = addDocumentChecks("after Cmd-Z #2 (settled)", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
        addFootnoteOrderCheck("after Cmd-Z #2 (settled)", rows: end, count: total, to: &soft)
        let sidebarEnd = waitForSidebarOrder(chapterTitles(original), timeout: 60)
        soft.check(sidebarEnd == nil, "after Cmd-Z #2 the sidebar's chapter order is not the original one: \(sidebarEnd ?? "")")
        addMarkdownMechanismChecks(from: firstFrom, commands: 4, to: &soft)
        addLogChecks(from: firstFrom, checkPushes: false, to: &soft)
        addScreenEqualsDatabaseCheck(before: end, what: "at the end", to: &soft)
        shot("md-two-drags-2-after-both-undos")

        // Cmd-W and reopen: the final state (the original) is kept.
        guard closeProjectWithCommandW(), relaunch() else { return }
        soft.check(headingFragmentsInDatabase() == originalHeadings,
            "after Cmd-W and the reopen the heading order is not the original one (\(orderDifference(originalHeadings)))")
        let reopened = addDocumentChecks("after Cmd-W and the reopen", expect: Phase4bMdExpectation(managedExact: true), to: &soft)
        addFootnoteOrderCheck("after Cmd-W and the reopen", rows: reopened, count: total, to: &soft)
        assertAll(soft, "Markdown: two drags in a row, Cmd-Z twice, Save Version, Cmd-W and reopen, on \(size.identifier) "
            + "with REPEATED footnote texts (flattened copy, all chapters flat; \(total) footnote references); \(countsLine)")
    }
}
