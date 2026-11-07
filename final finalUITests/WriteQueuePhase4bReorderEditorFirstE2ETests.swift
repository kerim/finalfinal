//
//  WriteQueuePhase4bReorderEditorFirstE2ETests.swift
//  final finalUITests
//
//  bt task t-0b70d1e9 (round 4, e2e): THE EDITOR-FIRST SECTION REORDER, proven in the real app. A card dragged in the Outline sidebar used to
//  rewrite the whole document from the database and push it back over the editor, so text typed just before or just after the drop could be
//  lost, and the earlier delete's Cmd-Z lost its quick road. Now the EDITOR moves the section(s) in one range move (the caret and the
//  viewport stay where they were), the sidebar shows the new order at once, and a queued job (`SectionReorderJob`) makes the database agree
//  behind everything the user typed. The tests are members of `WriteQueuePhase4bStructuralQueueE2ETests` (the helpers of the earlier slices
//  are used as they are), under task-unique names (`testReorderEF...`): vmtest's retry-refusal streak keys are not worktree-scoped.
//
//  HOW A CARD IS DRAGGED (what this file adds to the recipe of `dragCard`, section 24 of the main file)
//    * "Insert BEFORE card X" is a drop on the TITLE of the card ABOVE X (the title text always lies below 30% of its card, so it is an
//      "insert after" drop, `SectionDropDelegate.dropUpdated`; a drop on X's own title can never be an "insert before"). Both end in the same
//      request (`handleDrop`: insertBefore(idx) targets filteredSections[idx - 1], insertAfter(idx - 1) the same card). Before the FIRST card
//      there is no card above: the pointer then lands in the top part of that card (16 pt above its title, inside the top 30%).
//    * The horizontal position of the drop decides the heading level (`calculateZoneLevel`: the card is split into (predecessor level + 1)
//      equal zones, zone n is level n + 1). `rqDrag` aims at the middle of the zone of the level the test wants, so a chapter (level 1) is
//      dropped at the far left and an H2 section in the second zone. Every test then COMPARES the whole heading list, `#` marks included,
//      with the list worked out by hand (judge item (ii): a chapter dropped near the left side of a card must stay a chapter).
//    * An Option-drag (a section together with its sub-sections) holds Option around the press-and-drag with
//      `XCUIElement.perform(withKeyModifiers: .option)`. The call type-checks for the macOS SDK (the 2026-10-20 probe, SDK MacOSX27.0), but
//      whether the VM's synthesized mouse-down carries the modifier is not proven: a plain drag would move only the heading and promote the
//      sub-sections, so every Option-drag test compares the whole heading list and a wrong result names this as the likely cause.
//    * The end drop is the empty strip under the last card (`EndDropDelegate`): the pointer is put 52 pt under the last card's title.
//
//  THE DOCUMENTS. Generated, never a manuscript. The six-chapter book has 17 headings per chapter (a chapter and the one after it are 17
//  cards apart, about 1,200 pt, and a drag needs source and target on screen at once: the sidebar's visible band is about 585 pt at the
//  VM's 1024x768 display and XCUITest cannot scroll during a drag). So the reorder tests turn the sub-headings of some chapters into plain
//  lines (`rqFlattening`: the words, citations and footnotes are unchanged, only the `##` / `###` marks go), which puts those chapters' cards
//  next to each other: chapters 1, 3, 5 and 6 are "flat"; chapters 2 and 4 keep their 16 sub-sections (an Option-drag of one carries them).
//  Every test prints the real counts of the document it ran on (the fixture tag: words, sections, citation groups, footnote marks).
//
//  THE TESTS (plan-v2 E1 to E11 and the judge's W12; names as in the plan)
//    testReorderEFTypeDragKeepTyping_book6          E1  type, Option-drag Chapter 4 before Chapter 3, type again at once with no click
//    testReorderEFUndoRedo_book6                    E2  drag, Cmd-Z at once, Cmd-Shift-Z: sidebar == text == database after each
//    testReorderEFDeleteThenDragQuickUndo_book6     E3  delete, drag, Cmd-Z, Cmd-Z: the delete's undo is QUICK
//    testReorderEFFootnoteChapterTypeDuringJob_book6 E4 a footnoted chapter above Chapter 1, typing during the job, Cmd-Z
//    testReorderEFDuplicateDragUndoTwice_article    E5  duplicate, Option-drag the copy, Cmd-Z twice
//    testReorderEFTwiceThenUndo_book6               E6  two drags, then Cmd-Z twice
//    testReorderEFMarkdown_article                  E7  a drag in Markdown mode is editor first (was testReorderEFMarkdownOldPath_article)
//    testReorderEFToBottomStaysBeforeNotes_book6    E8  a chapter dragged under the last card stays before Notes and Bibliography
//    testReorderEFFootnoteInsertThenDrag_book6      E9  insert a footnote, drag its chapter at once
//    testReorderEFBook12CJKTiming                   E10 CJK paragraph, Option-drag on the twelve-chapter book, `jsMs` recorded
//    testReorderEFTypeInMovedThenUndoTwice_book6    E11 drag, type in the moved chapter, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z
//    testReorderEFSwapOnScreenBelowCaret_book6      W12 two on-screen sections below the caret swapped: the caret line keeps its place
//    testReorderEFDragThenDeleteThenUndo_book6      S4  (user step 4) Option-drag, Delete Section at once, Cmd-Z: the delete's undo is quick
//
//  TWO SEED TRICKS beyond the flat chapters: `rqTaggingNotes` appends a unique tag to every footnote definition (E4 uses it: the books repeat
//  one chapter's prose, so without a tag the notes of chapter 2 read exactly like those of chapter 1 and a Notes list in the wrong order
//  could not be told from the right one); `rqFlattening(keeping:)` leaves the headings with a chosen text start as headings (S4 keeps "4.1 " alone).
//  `rqCheckOptionCarried` is the dedicated check after every Option-drag of a section that has sub-headings: the moved heading must be
//  followed in the block table by its OWN first sub-heading, else the failure says the Option key did not reach the drag.
//
//  MECHANISM LINES every test prints AND asserts: `[STRUCT-TRACE] reorder-editor-first opId=<id8> ok=true moved=.. jsMs total=..` (the editor's
//  success line) once per drag, the Swift sequence `sectionReorder start (editor-first)` once per drag, no `fell back` / `refused` step, no
//  `[EF-STRUCT]` line; the undo and redo of a reorder are the queued slow ones (`swap-editor-first ... ok=true`, `start (editor-first undo)`).
//
//  NOT READABLE FROM THE APP: the number of outline merges during the gesture (the app writes no line per merge). What is recorded instead:
//  the `[SidebarBody]` lines (one per render of the outline) and the `[EditorViewState:observe] SKIPPED` lines (the old `.dragReorder`
//  content state skipped results) between the press and the end of the gesture. A mid-drag screenshot cannot be taken: XCUITest's
//  press-and-drag blocks until the pointer is released, so the pictures are taken straight before the press and straight after the drop.
//
//  RUNNING (".../" stands for "final finalUITests/WriteQueuePhase4bStructuralQueueE2ETests/"; every vmtest call needs the sandbox off):
//    scripts/vmtest/vmtest run --timeout 7000 --scope ".../testReorderEFTypeDragKeepTyping_book6" --scope ".../testReorderEFUndoRedo_book6" ...
//

// swiftlint:disable file_length cyclomatic_complexity
import AppKit
import XCTest

/// Where the dragged card is let go.
enum Phase4bRqDrop {
    /// On the title of this card: the section lands right after it ("insert before X" is a drop on the card above X).
    case after(String)
    /// In the top part of the first card of the list: the section lands before everything.
    case top
    /// In the empty strip under the last card of the list (the end drop).
    case bottom
}

/// One user row of the document with the number it has in `pre`, so a typed text can be named by its row after rows have moved.
struct Phase4bRqRow {
    let id: Int
    let row: Phase4bFlowRow
}

// MARK: - The seed and the document worked out by hand

extension WriteQueuePhase4bStructuralQueueE2ETests {
    static let rqFirst = "KEPTRQFIRST"
    static let rqSecond = "KEPTRQSECOND"
    static let rqDuring = "KEPTRQDURING"
    static let rqNote = "KEPTRQNOTE"
    /// The six-chapter book's flat chapters (see the file header): chapters 2 and 4 keep their sub-sections.
    static let rqFlatBook6 = [1, 3, 5, 6]
    /// The writer holds every queued structural job 3.5 s (under the 4 s limit of a hold), so typing meets a pending job.
    static var rqJobHold: [String: String] { ["FF_UI_TESTING_STRUCT_JOB_HOLD_MS": String(jobHoldMs)] }

    static func rqChapter(_ number: Int) -> String { "Chapter \(number): The Quiet Archive and Its Ledgers" }
    static func rqLevel(_ fragment: String) -> Int { fragment.prefix(while: { $0 == "#" }).count }
    static func rqTitle(_ fragment: String) -> String {
        String(fragment.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The seed with the sub-headings of `chapters` turned into plain lines: a block `## 3.1 Title` / `### 3.1.1 Title` becomes the paragraph
    /// `3.1 Title` (a number-and-dot start is not a list marker). Words, citations and footnotes are unchanged; only the heading marks go.
    /// Headings whose text starts with one of `keeping` (for example "4.1 " with the space: the section 4.1 alone, not 4.1.1) stay headings.
    static func rqFlattening(_ generated: Phase4bDoc, chapters: [Int], keeping: [String] = []) -> Phase4bDoc {
        let prefixes = chapters.map { "\($0)." }
        let blocks = generated.markdown.components(separatedBy: "\n\n").map { block -> String in
            for marks in ["### ", "## "] where block.hasPrefix(marks) {
                let text = String(block.dropFirst(marks.count))
                if prefixes.contains(where: { text.hasPrefix($0) }), !keeping.contains(where: { text.hasPrefix($0) }) { return text }
            }
            return block
        }
        let text = blocks.joined(separator: "\n\n")
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// The tag a footnote definition carries after `rqTaggingNotes`: unique per footnote, so a test can tell which note a definition is.
    /// The books repeat one chapter's prose, so without it the nine notes of chapter 2 read exactly like the nine of chapter 1 and a Notes
    /// list in the wrong order could not be told from the right one. Letters and digits only; the closing "x" keeps "NoteTag1x" from
    /// being a part of "NoteTag10x".
    static func rqNoteTag(_ number: Int) -> String { "NoteTag\(number)x" }

    /// The seed with the tag of `rqNoteTag(n)` appended to the text of every footnote definition `[^n]: ...` (one word more per note).
    static func rqTaggingNotes(_ generated: Phase4bDoc) -> Phase4bDoc {
        let blocks = generated.markdown.components(separatedBy: "\n\n").map { block -> String in
            guard let note = Phase4bFlow.definition(block) else { return block }
            return block.trimmingCharacters(in: .newlines) + " " + rqNoteTag(note.number) + (block.hasSuffix("\n") ? "\n" : "")
        }
        let text = blocks.joined(separator: "\n\n")
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// Three short sections right after the Anchor01 line (W12): SwapOne and SwapTwo each hold one line, SwapRest takes the rest of chapter 1.
    /// The first line of the book is the caret line, so the caret line, SwapOne's line and SwapTwo's line are the first three paragraphs below
    /// the chapter heading: about 130 pt between lines, all inside the editor's first screen at the VM's 1024x768 (a seed after Anchor06 put
    /// SwapTwo's line below the visible band: the first VM run).
    static func rqWithSwapSections(_ generated: Phase4bDoc) -> Phase4bDoc {
        var text = generated.markdown
        guard let range = text.range(of: "Anchor01 line of the fixture document.\n\n") else { return generated }
        text.insert(
            contentsOf: "## SwapOne section\n\nSwapOne line of the fixture document.\n\n## SwapTwo section\n\n"
                + "SwapTwo line of the fixture document.\n\n## SwapRest section\n\n",
            at: range.upperBound)
        return Phase4bDoc(markdown: text, cslJSON: generated.cslJSON, counts: Phase4bGenerator.count(text))
    }

    /// The saved user rows (Notes and Bibliography left out), each with its number in `pre`.
    func rqUserRows() -> [Phase4bRqRow] {
        pre.enumerated().filter { !$0.element.isManaged }.map { Phase4bRqRow(id: $0.offset, row: $0.element) }
    }

    /// `rows` with the section titled `title` (its heading and everything up to the next heading of the same or a higher level, so its
    /// sub-sections go with it) taken out and put before the section titled `target` (the end of the user rows when nil).
    func rqMoving(_ rows: [Phase4bRqRow], _ title: String, before target: String?) -> [Phase4bRqRow] {
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

    /// The rows as the document should hold them; `typed` replaces the whole text of the rows named by their number in `pre`.
    func rqRows(_ rows: [Phase4bRqRow], typed: [Int: String] = [:]) -> [Phase4bFlowRow] {
        rows.map { item in
            guard let text = typed[item.id] else { return item.row }
            return Phase4bFlowRow(type: item.row.type, isNotes: false, isBibliography: false, fragment: text)
        }
    }

    /// The heading rows of `rows` as the block table writes them (`## 3.6 Conclusion`), in order.
    func rqHeadings(_ rows: [Phase4bRqRow]) -> [String] {
        rows.filter { $0.row.headingLevel != nil }.map { $0.row.fragment.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func rqHeadingLevel(of title: String) -> Int? {
        headingFragmentsInDatabase().first { Self.rqTitle($0) == title }.map { Self.rqLevel($0) }
    }

    /// The title of the heading right above `title` in the block table (nil for the first heading).
    func rqPredecessor(of title: String) -> String? {
        let titles = headingFragmentsInDatabase().map { Self.rqTitle($0) }
        guard let index = titles.firstIndex(of: title), index > 0 else { return nil }
        return titles[index - 1]
    }

    func rqFirstDifference(_ expected: [String], _ actual: [String]) -> String {
        guard let first = zip(expected, actual).enumerated().first(where: { $0.element.0 != $0.element.1 }) else {
            return expected.count == actual.count ? "none" : "\(expected.count) headings expected, \(actual.count) found"
        }
        return "heading \(first.offset): expected \"\(expected[first.offset].prefix(50))\", found \"\(actual[first.offset].prefix(50))\""
    }

    /// Titles that occur once in `titles` (a copy repeats its original's sub-section titles, which no card can be told apart by).
    func rqUnique(_ titles: [String]) -> [String] {
        let counts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
        return titles.filter { counts[$0] == 1 }
    }

    /// `rows` without the rows of the section titled `title` (as `pre` holds it): the document after that section was deleted.
    func rqWithout(_ rows: [Phase4bRqRow], section title: String) -> [Phase4bRqRow] {
        guard let range = section(title) else { return rows }
        return rows.filter { !range.contains($0.id) }
    }

    /// Notes follow the text: in a document tagged by `rqTaggingNotes` the definition `[^i]` must be the note whose reference stands i-th
    /// in the text of `arrangement` (the hand-worked rows, each carrying the ORIGINAL label of its references). Returns what is wrong.
    func rqNotesProblems(_ post: [Phase4bFlowRow], arrangement: [Phase4bRqRow]) -> [String] {
        let sequence = arrangement.flatMap { Phase4bFlow.footnoteRefs(in: $0.row.fragment) }
        let definitions = Dictionary(
            Phase4bFlowWalk(rows: post).definitions.map { ($0.number, $0.text) }, uniquingKeysWith: { first, _ in first })
        var problems: [String] = []
        for (index, original) in sequence.enumerated() {
            let label = index + 1
            guard let text = definitions[label] else {
                problems.append("no definition [^\(label)] (it should be the note originally numbered \(original))")
                continue
            }
            if !text.contains(Self.rqNoteTag(original)) {
                problems.append(
                    "[^\(label)] holds \"\(text.suffix(40))\", expected the note originally numbered \(original) "
                        + "(\(Self.rqNoteTag(original)))")
            }
        }
        if definitions.count != sequence.count {
            problems.append("\(definitions.count) definition(s) for \(sequence.count) reference(s)")
        }
        return problems
    }
}

// MARK: - Starting a scenario

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// Seeds (the chapters in `flat` flattened, then `extra`), launches, and prints what the document is. False after a reported failure.
    func rqStart(
        _ size: Phase4bDelSize, method: String, env: [String: String] = [:], flat: [Int], keeping: [String] = [],
        extra: ((Phase4bDoc) -> Phase4bDoc)? = nil
    ) -> Bool {
        let seed: (Phase4bDoc) -> Phase4bDoc = { generated in
            let flattened = flat.isEmpty ? generated : Self.rqFlattening(generated, chapters: flat, keeping: keeping)
            return extra?(flattened) ?? flattened
        }
        guard startScenario(size, method: method, env: env, seed: seed) else { return false }
        note("REORDER DOCUMENT: chapters \(flat) are flat (no sub-headings: their cards sit next to each other); "
            + "\(preHeadingFragments.count) headings in the block table; \(restoreCounts)")
        return true
    }

    /// Fails the test (TEST-SETUP) unless every title is a heading of the loaded document.
    func rqRequire(_ titles: [String]) -> Bool {
        for title in titles where !pre.contains(where: { $0.headingTitle == title }) {
            fail("TEST-SETUP: the loaded document has no heading \"\(title)\"")
            return false
        }
        return true
    }

    func rqAnchorRow() -> Int? {
        guard let anchor = pre.firstIndex(where: { $0.fragment == Self.anchorLine }) else {
            fail("TEST-SETUP: the loaded document has no \"\(Self.anchorLine)\" row")
            return nil
        }
        return anchor
    }

    /// The caret at the end of the seeded line `line` of the section whose card is `card` (the sidebar's own navigation, then the line).
    func rqPlaceCaret(inSectionCard card: String, line: String, prefix: String) -> Bool {
        guard let cardElement = bringSidebarCardIntoView(card) else { return false }
        navigate(to: cardElement)
        return placeCaretAtAnchorEnd(paragraph: prefix, exactLine: line)
    }
}

// MARK: - Dragging a card

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// Brings the cards of `titles` into the sidebar's visible band at once; fails the test (TEST-SETUP) when they cannot all fit.
    func rqBringIntoView(_ titles: [String]) -> [XCUIElement]? {
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

    /// Scrolls the sidebar to its end (the end drop needs the strip under the last card on screen). One sign check, as the other scrolls.
    func rqScrollToEnd(reference: XCUIElement) {
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        let before = reference.frame.midY
        scroll.scroll(byDeltaX: 0, deltaY: -4_000)
        app.waitForStableFrame(reference)
        if reference.exists, reference.frame.midY > before + 1 {
            scroll.scroll(byDeltaX: 0, deltaY: 8_000)
            app.waitForStableFrame(reference)
        }
    }

    /// The title of the last card of the sidebar (Bibliography, else Notes): the last heading row of the block table.
    func rqLastCardTitle() -> String? {
        let last = dbText("SELECT markdownFragment FROM block WHERE blockType = 'heading' ORDER BY sortOrder DESC, id DESC LIMIT 1;")
        return last.isEmpty ? nil : Self.rqTitle(last)
    }

    /// Drags the card `moved` and lets it go at `drop`, aiming at the horizontal zone of heading level `level` (see the file header). With
    /// `option` the sub-sections go with it. `dropY` is the height of the pointer inside the target title (the second and later drags of a
    /// launch use another value: the sidebar ignores a drop at exactly the same point as the one before). The app-log index just before the
    /// press, nil after a reported failure. Prints what the outline did during the gesture.
    func rqDrag(_ moved: String, _ drop: Phase4bRqDrop, level: Int, option: Bool, dropY: CGFloat) -> Int? {
        var titles = [moved]
        let predecessorLevel: Int
        switch drop {
        case .after(let title):
            titles.append(title)
            predecessorLevel = rqHeadingLevel(of: title) ?? 1
        case .top:
            guard let first = headingFragmentsInDatabase().first else { fail("TEST-SETUP: the block table has no heading"); return nil }
            titles.append(Self.rqTitle(first))
            predecessorLevel = 0
        case .bottom:
            guard let last = rqLastCardTitle() else { fail("TEST-SETUP: the block table has no heading"); return nil }
            titles.append(last)
            predecessorLevel = 1
        }
        guard var cards = rqBringIntoView(titles) else { return nil }
        let scroll = app.groups["outline-sidebar"].scrollViews.firstMatch
        if case .bottom = drop {
            rqScrollToEnd(reference: cards[1])
            cards = [sidebarCard(titles[0]), sidebarCard(titles[1])]
            guard cards[0].exists, cards[1].exists else { fail("TEST-SETUP: a card left the tree after the scroll to the end"); return nil }
        }
        let zones = CGFloat(predecessorLevel + 1)
        let wanted = CGFloat(min(max(level, 1), predecessorLevel + 1))
        let screenX = scroll.frame.minX + (wanted - 0.5) * scroll.frame.width / zones
        let target = cards[1]
        let horizontalOffset = screenX - target.frame.minX
        let dropPoint: XCUICoordinate
        switch drop {
        case .after:
            dropPoint = target.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: dropY))
                .withOffset(CGVector(dx: horizontalOffset, dy: 0))
        case .top:
            dropPoint = target.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: horizontalOffset, dy: -16 - (dropY - 0.5) * 8))
        case .bottom:
            dropPoint = target.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1))
                .withOffset(CGVector(dx: horizontalOffset, dy: 52 + (dropY - 0.5) * 8))
        }
        let point = dropPoint.screenPoint
        var geometry = "dragged card \(Self.describeFrame(cards[0].frame)); target card \"\(titles[1].prefix(30))\" "
            + Self.describeFrame(target.frame)
        switch drop {
        case .after:
            geometry += "; the pointer lands on the target's title text (an insert after it)"
        case .top:
            geometry += "; estimated top of the first card: y \(Int(target.frame.minY - 32)) (the title's top minus about 32 pt); "
                + "the pointer is 16 pt above the title, inside the card's top 30% when the card is at least 55 pt tall"
        case .bottom:
            geometry += "; estimated end strip under the last card: y \(Int(target.frame.maxY + 33)) to "
                + "\(Int(target.frame.maxY + 73)) (the title's bottom plus 4 pt spacing, the metadata row, 8 pt padding, "
                + "the divider and the 40 pt strip); the pointer is 52 pt under the title"
        }
        note("DRAG: \"\(moved.prefix(40))\" \(option ? "with its sub-sections (Option)" : "alone") to \(drop) at level \(level): pointer ends at "
            + "(\(Int(point.x)), \(Int(point.y))) in the sidebar \(Self.describeFrame(scroll.frame)); "
            + "predecessor level \(predecessorLevel); \(geometry)")
        guard scroll.frame.contains(point) else {
            fail("TEST-SETUP: the drop point (\(Int(point.x)), \(Int(point.y))) lies outside the sidebar \(Self.describeFrame(scroll.frame))")
            return nil
        }
        app.activateAndWaitForForeground()
        tail.poll()
        let from = tail.lines.count
        if firstTriggerIndex == nil { firstTriggerIndex = from }
        let grab = cards[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let gesture = { grab.press(forDuration: 0.5, thenDragTo: dropPoint, withVelocity: .slow, thenHoldForDuration: 0.3) }
        if option { XCUIElement.perform(withKeyModifiers: .option, block: gesture) } else { gesture() }
        tail.poll()
        let gestureEnd = tail.lines.count
        let seen = tail.lines[min(from, gestureEnd)..<gestureEnd].map(\.text)
        let renders = seen.filter { $0.contains("[SidebarBody]") }.count
        let skippedResults = seen.filter { $0.contains("[EditorViewState:observe] SKIPPED") }.count
        result("GESTURE (press to drop, app log lines \(from)..<\(gestureEnd)): \(renders) outline render(s) "
            + "(`[SidebarBody]`), \(skippedResults) skipped outline result(s). The app writes "
            + "no line per outline merge, so the number of merges cannot be read")
        return from
    }

    /// Drags `moved` to just before the card `target` (see the file header: a drop on the card above it, or the top of the first card).
    func rqDragBefore(_ moved: String, before target: String, level: Int, option: Bool, dropY: CGFloat) -> Int? {
        if let predecessor = rqPredecessor(of: target) {
            return rqDrag(moved, .after(predecessor), level: level, option: option, dropY: dropY)
        }
        return rqDrag(moved, .top, level: level, option: option, dropY: dropY)
    }
}

// MARK: - Checks

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// After an Option-drag of a section that has sub-headings: in the block table the moved heading must be followed directly by its OWN
    /// first sub-heading (`expected` is the hand-worked heading list, in which it is). A plain drag moves the heading alone and leaves its
    /// sub-sections behind, which is what a modifier that never reached the synthesized mouse-down would produce. The block table is waited
    /// for (a condition) to reach `expected` first. A section without a sub-heading in `expected` needs no check.
    func rqCheckOptionCarried(_ moved: String, expected: [String], what: String, to soft: inout Phase4bFlowSoftChecks) {
        let titles = expected.map { Self.rqTitle($0) }
        guard let place = titles.firstIndex(of: moved), place + 1 < expected.count,
              Self.rqLevel(expected[place + 1]) > Self.rqLevel(expected[place]) else { return }
        let child = titles[place + 1]
        let wait = appWait(size.operationTimeout, before: "\(what): the Option-drag is looked for in the block table")
        _ = waitForHeadingOrder(expected, timeout: wait)
        let found = headingFragmentsInDatabase().map { Self.rqTitle($0) }
        let next = found.firstIndex(of: moved).flatMap { $0 + 1 < found.count ? found[$0 + 1] : nil }
        result("OPTION-DRAG \(what): \"\(moved.prefix(40))\" is followed in the block table by \(next.map { "\"\($0.prefix(40))\"" } ?? "nothing"); "
            + "its own first sub-heading is \"\(child.prefix(40))\"")
        soft.check(next == child, "\(what): the Option key did not reach the drag: only the heading moved (\"\(moved)\" is followed by "
            + "\"\(next ?? "nothing")\" instead of its own first sub-heading \"\(child)\")")
    }

    /// The headings the editor exposes on screen, in the order the tree gives them, must be in the order of `titles` (a heading below the
    /// visible band is not in the tree, so this is a subsequence check). Nil when they are, else what is wrong.
    func rqEditorOrderProblem(_ titles: [String]) -> String? {
        guard let values = app.editorStaticTextValues() else {
            note("EDITOR ORDER: no snapshot of the editor could be taken (not asserted)")
            return nil
        }
        let known = Set(titles)
        var seen: [String] = []
        for value in values {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if known.contains(name), !seen.contains(name) { seen.append(name) }
        }
        var cursor = 0
        for name in seen {
            guard let found = titles[cursor...].firstIndex(of: name) else {
                return "the editor shows \"\(name)\" out of order (headings exposed on screen, in text order: \(seen))"
            }
            cursor = found + 1
        }
        note("EDITOR ORDER: \(seen.count) of \(titles.count) heading(s) are exposed on screen and in order: \(seen.prefix(6))")
        return nil
    }

    /// Judge rule (f): the block table, the sidebar and the editor's text agree on the heading order `expected` (the block table's
    /// `#` marks included). The database is waited for (a condition), the sidebar and the editor are read after it.
    func rqCheckOrder(_ what: String, expected: [String], to soft: inout Phase4bFlowSoftChecks) {
        let database = waitForHeadingOrder(expected, timeout: appWait(size.operationTimeout, before: "\(what): the heading order is looked for"))
        let found = headingFragmentsInDatabase()
        soft.check(database, "\(what): the block table's heading order is not the expected one (\(rqFirstDifference(expected, found)))")
        let titles = rqUnique(expected.map { Self.rqTitle($0) })
        let sidebar = waitForSidebarOrder(titles)
        soft.check(sidebar == nil, "\(what): the sidebar's card order differs from the block table's: \(sidebar ?? "")")
        let editor = rqEditorOrderProblem(titles)
        soft.check(editor == nil, "\(what): the editor's text order differs from the block table's: \(editor ?? "")")
        result("ORDER \(what): block table \(Self.yesNo(database)); sidebar \(Self.yesNo(sidebar == nil)) (\(titles.count) cards compared); "
            + "editor \(Self.yesNo(editor == nil))")
    }

    /// The facts about the reorder's mechanism since `from`, printed and added to `soft`: `drags` editor-first successes, every
    /// `sectionReorder` sequence began `start (editor-first)`, no `fell back` / `refused` step, no fallback line. The editor's `jsMs` is
    /// printed with the counts of the document.
    func addReorderMechanismChecks(from: Int, drags: Int, to soft: inout Phase4bFlowSoftChecks) {
        let okLines = editorFirstOkLines("reorder", from: from)
        let traces = traceLines(from: from).filter { $0.family == .sequence && $0.label == "sectionReorder" }
        let starts = traces.filter { $0.isOpStart }
        let fellBack = traces.filter { $0.step.hasPrefix("fell back") || $0.step.hasPrefix("refused") }
        let fallbacks = fallbackEvidence(from: from)
        let jsMs = okLines.compactMap { Phase4bDelTypingParser.intAfter("jsMs total=", in: $0) }
        let firstOk = okLines.first.map { "(\($0.suffix(150)))" } ?? ""
        result("MECHANISM: \(okLines.count) `reorder-editor-first ... ok=true` line(s) (expected \(drags)) \(firstOk); "
            + "sectionReorder start line(s) \(starts.map { "op=\($0.opId) \($0.step.prefix(26))" }); fell-back/refused steps \(fellBack.count); "
            + "fallback lines \(fallbacks.count); jsMs \(jsMs); \(restoreCounts)")
        soft.check(okLines.count == drags, "the log has \(okLines.count) `reorder-editor-first ... ok=true` line(s), expected \(drags): "
            + "the editor-first reorder did not run that many times")
        soft.check(starts.count == drags && starts.allSatisfy { $0.step.hasPrefix("start (editor-first)") },
                   "the sectionReorder sequences began \(starts.map(\.step)), expected \(drags) `start (editor-first)` "
                       + "(the old whole sequence logs a plain `start`)")
        soft.check(fellBack.isEmpty, "\(fellBack.count) `fell back` / `refused` step(s): \(fellBack.map(\.step))")
        soft.check(fallbacks.isEmpty, "\(fallbacks.count) fallback line(s) in the log: \(fallbacks.prefix(3))")
    }

    /// Everything a reorder test checks about its end state except the screen-equals-database round trip (which writes the live text into
    /// the table, so it comes last): the heading order in the three places, the rows against the hand-moved document, the mechanism lines,
    /// no refusal / beep / plain push, no dropped-press toast. Returns the rows read.
    @discardableResult
    func rqChecks(
        _ what: String, from: Int, drags: Int, rows: [Phase4bRqRow], typed: [Int: String] = [:], handedToTextUndo: Int = 0,
        plainPushes: Bool = true, to soft: inout Phase4bFlowSoftChecks
    ) -> [Phase4bFlowRow] {
        rqCheckOrder(what, expected: rqHeadings(rows), to: &soft)
        let post = addRowChecks(what, expectedUser: rqRows(rows, typed: typed), managed: nil, to: &soft)
        addReorderMechanismChecks(from: from, drags: drags, to: &soft)
        // `plainPushes` false: a test that gives a second structural command while the first job is held 3.9 s (the writer is busy past
        // the 5 s content-state watchdog's comfort) prints the plain-push count instead of asserting it, as `addRefusalAndBeepChecks` does.
        if plainPushes {
            addLogChecks(from: from, handedToTextUndo: handedToTextUndo, to: &soft)
        } else {
            addRefusalAndBeepChecks(from: from, to: &soft)
        }
        soft.check(droppedPressToasts(from: from).isEmpty,
                   "\(what): the warning toast \"Some undo or redo presses could not be carried out.\" was shown")
        return post
    }

    /// A reading as text: the number, or `fallback` when it could not be read.
    func rqShown(_ value: Int?, or fallback: String) -> String { value.map(String.init) ?? fallback }

    /// The document's word total as the status bar shows it: the element `status-bar-word-count` (a StaticText; its `value`, else its label)
    /// reads "N words", or "K of N words" while a selection or a zoom is on, or "N/G words" with a document goal (`StatusBar.wordCountDisplay`).
    /// The total N is read, whatever thousands separator is in it (a comma, a point or a space of any width). Nil when the text is not one of those.
    func rqWordTotal() -> Int? {
        let text = app.wordCountStatusText().replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        guard text.hasSuffix(" words") else { return nil }
        var body = String(text.dropLast(" words".count))
        if let range = body.range(of: " of ") { body = String(body[range.upperBound...]) }
        if let slash = body.firstIndex(of: "/") { body = String(body[..<slash]) }
        return Int(body.filter { $0.isASCII && $0.isNumber })
    }

    /// `rqWordTotal` once two reads one second apart agree (at most `timeout` seconds: the total follows the sidebar's counts, which follow the
    /// block table a moment after a change); the last read when they never do.
    func rqWordTotalStable(timeout: TimeInterval = 20) -> Int? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = rqWordTotal()
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            let next = rqWordTotal()
            if next != nil, next == last { return next }
            last = next
        }
        return last
    }

    /// `rows` with the blank definition `[^number]:` (empty text, whatever whitespace follows the colon) written without its trailing
    /// whitespace; every other row is returned as it is. The only tolerance `rqScreenEqualsDatabaseCheck` makes.
    func rqTrimmingBlankDefinition(_ rows: [Phase4bFlowRow], number: Int) -> [Phase4bFlowRow] {
        rows.map { row in
            guard let note = Phase4bFlow.definition(row.fragment), note.number == number, note.text.isEmpty else { return row }
            return Phase4bFlowRow(type: row.type, isNotes: row.isNotes, isBibliography: row.isBibliography,
                                  fragment: row.fragment.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// `addScreenEqualsDatabaseCheck` (File > Save Version writes the live editor text into the block table; the table read before and after
    /// must be identical, every row, Notes and Bibliography included) with ONE tolerance: the blank definition `[^blankDefinition]:` of a
    /// footnote that was just inserted and is still empty is stored as "[^N]: " and serialised by the live editor as "[^N]:" (the app does
    /// this for any new empty footnote), so that one row is compared whitespace-trimmed. Nothing else is relaxed.
    func rqScreenEqualsDatabaseCheck(
        before: [Phase4bFlowRow], what: String, blankDefinition number: Int, to soft: inout Phase4bFlowSoftChecks
    ) {
        versionSaves += 1
        let name = "Structural check \(versionSaves)"
        let saved = saveVersion(named: name)
        soft.check(saved, "\(what): the version \"\(name)\" was saved (its flush writes the live editor text into the block table)")
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let after = readRows()
        let expected = rqTrimmingBlankDefinition(before, number: number)
        let actual = rqTrimmingBlankDefinition(after, number: number)
        let lines = Phase4bFlow.rowDifferences(
            expected: expected.enumerated().map { (row: $0.offset, value: $0.element) },
            actual: actual.enumerated().map { (row: $0.offset, value: $0.element) }, exact: true)
        recordDifferences(
            what, "the block table before and after Save Version (screen vs database; the blank definition "
                + "[^\(number)] compared trimmed)", lines)
        note("\(what): SCREEN vs DATABASE: \(before.count) rows before Save Version, \(after.count) after; \(lines.count) difference line(s) "
            + "(the blank definition [^\(number)] compared without its trailing whitespace)")
        soft.check(lines.isEmpty, "\(what): the live editor text differs from the saved block table: \(lines.joined(separator: " | "))")
    }

    /// Where the first typed key fell against the reorder's own `performed` line, on the app's clock (printed; the typing is meant to
    /// come first: nothing is waited for between the drop and the typing).
    func rqReportTypingAgainstPerformed(dragFrom: Int, typedFrom: Int) {
        let performedLine = traceLines(from: dragFrom).first {
            $0.family == .sequence && $0.label == "sectionReorder" && $0.step == "performed"
        }
        guard let performed = performedLine,
              let key = firstTypedKey(from: typedFrom) else {
            result("TYPING vs `performed`: no `performed` line or no editor key line was found")
            return
        }
        result("TYPING vs `performed`: the first key came \(key.t - performed.t) ms after the reorder's `performed` line "
            + "(negative: typed BEFORE the reorder had performed, as the scenario asks)")
    }

    /// One Cmd-Z (`redo` false) or Cmd-Shift-Z press: what the editor decided (`fallthrough` = a text step, `structural`, `swallow`), whether a
    /// structural sequence started and was waited for to its `performed` line.
    func rqPressStep(redo: Bool, number: Int) -> UndoPress {
        let direction = redo ? "redo" : "undo"
        tail.poll()
        let from = tail.lines.count
        app.activateAndWaitForForeground()
        if redo { pressRedo() } else { pressUndo() }
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
                waitForPerformed(direction, from: from, timeout: appWait(size.operationTimeout * 2, before: "press \(number) performs"),
                                 includeRouting: false)
            }
        }
        if decision == "fallthrough" {
            let lineBy = Date(timeIntervalSinceNow: 5)
            while !tail.lines[min(from, tail.lines.count)...].contains(where: { $0.text.contains("[STRUCT-TRACE] routing-refused") }),
                  Date() < lineBy {
                tail.poll()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
        tail.poll()
        let refused = tail.lines[min(from, tail.lines.count)...].filter { $0.text.contains("[STRUCT-TRACE] routing-refused") }
        let handed = refused.filter { Self.routingVerdict(of: $0.text) == .handedToTextUndo }.map(\.text)
        let refusals = refused.filter { Self.routingVerdict(of: $0.text) == .refusal }.map(\.text)
        let kind = structural ? "a STRUCTURAL \(direction) ran" : "a text step (or nothing)"
        note("PRESS \(number) (\(direction)): the editor decided \(decision); \(kind); "
            + "\(handed.count) press(es) handed to the text undo (not a refusal), \(refusals.count) real refusal(s)")
        return UndoPress(decision: decision, structural: structural, handedToTextUndo: handed, refusals: refusals)
    }
}

// MARK: - E1 Type, Option-drag, type again at once (no click)

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 1: "Click at the end of a paragraph and type. Option-drag a chapter above another, and without clicking anywhere type
    /// again." The first sentence is typed at the end of the Anchor05 line (an unmoved paragraph of chapter 1); Chapter 4 (with its 16
    /// sub-sections) is Option-dragged before Chapter 3; the second sentence is typed the moment the drop is made: no wait, no click back.
    /// Both sentences sit side by side in the Anchor05 paragraph, on screen and in the database; the heading list is the one worked out by
    /// hand and Chapter 4 is still a chapter (level 1: judge item (ii)); screen equals database after the settle. The writer holds every
    /// job 3.5 s so the typing meets the pending job; where the first key fell is printed. On the base code the whole document is
    /// rewritten from the database and pushed over the editor, and the typing is lost or misplaced.
    /// THE WORD TOTAL (the status bar's "N words") is read four times and logged with the fixture tag: at the start, before the drag (after
    /// the first word is saved), after the settle, and after the reopen. Asserted: after the settle it equals the total before the drag plus
    /// the one word typed since (the editor-first block updates must not recount a moved section's paragraphs without their citations), and
    /// it equals the total after the reopen. The failures of the first part are collected, the reopen is made anyway, and everything is
    /// asserted at the end, so one run shows all four readings.
    func testReorderEFTypeDragKeepTyping_book6() {
        let moved = Self.rqChapter(4)
        let target = Self.rqChapter(3)
        guard rqStart(.book6, method: #function, env: Self.rqJobHold, flat: Self.rqFlatBook6),
              let anchor = rqAnchorRow(), rqRequire([moved, target]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let startTotal = rqWordTotalStable()
        typeNow(" " + Self.rqFirst)
        // The word total BEFORE the drag, read once the first word is saved (a condition: it is in the database and the log is quiet).
        let firstSaved = waitForSentenceInDatabase(Self.rqFirst, timeout: 90)
        _ = waitForLogQuiet(quiet: 2, cap: capped(30))
        let beforeDrag = rqWordTotalStable()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-type-drag-book6-1-before-the-drag")
        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5) else { return }
        tail.poll()
        let typedFrom = tail.lines.count
        typeNow(" " + Self.rqSecond)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-type-drag-book6-2-right-after-the-drop-and-the-typing")

        let landed = waitForSentenceInDatabase(Self.rqSecond, timeout: 90)
        guard waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        // The word total AFTER the settle (the drag, its job and the settle are over; nothing has written the live text into the table yet).
        let afterSettle = rqWordTotalStable()
        reportTypingAgainstSwapJob(jobFrom: dragFrom, typedFrom: typedFrom, holdMs: Self.jobHoldMs)
        rqReportTypingAgainstPerformed(dragFrom: dragFrom, typedFrom: typedFrom)
        let level = rqHeadingLevel(of: moved)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-type-drag-book6-3-after-the-settle")
        var soft = Phase4bFlowSoftChecks()
        soft.check(firstSaved, "the first sentence reached the database before the drag")
        // Both typed words are the whole difference: the total after the settle is the total before the drag plus the second word.
        let expectedAfterSettle = beforeDrag.map { $0 + 1 }
        soft.check(afterSettle != nil && afterSettle == expectedAfterSettle,
                   "WORD TOTAL: the status bar reads \(rqShown(afterSettle, or: "nothing readable")) after the drag and the settle, expected "
                       + "\(rqShown(expectedAfterSettle, or: "n/a")) (\(rqShown(beforeDrag, or: "n/a")) before the drag plus the one word typed "
                       + "since): the words of the section moved were recounted without their citations")
        soft.check(landed, "the second sentence, typed the moment the drop was made, reached the database")
        soft.check(level == 1, "JUDGE ITEM (ii): \"\(moved)\" is level \(level.map(String.init) ?? "missing") after a drop at the far left of "
            + "the card above \"\(target)\" (a chapter must stay a chapter)")
        let rows = rqMoving(rqUserRows(), moved, before: target)
        let typed = [anchor: Self.anchorLine + " " + Self.rqFirst + " " + Self.rqSecond]
        let post = rqChecks("after the drag and the typing", from: dragFrom, drags: 1, rows: rows, typed: typed, to: &soft)
        rqCheckOptionCarried(moved, expected: rqHeadings(rows), what: "after the drag", to: &soft)
        soft.check(blocksContaining(Self.rqFirst + " " + Self.rqSecond) == 1,
                   "the two sentences are not side by side in one row of the database (\(blocksContaining(Self.rqFirst)) row(s) hold the first, "
                       + "\(blocksContaining(Self.rqSecond)) the second)")
        addTypedLineOnScreenCheck(line: Self.anchorLine, marker: Self.rqFirst, requireIt: true, to: &soft)
        addTypedLineOnScreenCheck(line: Self.anchorLine, marker: Self.rqSecond, requireIt: true, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag and the typing", to: &soft)

        // User step 8: close and reopen. The chapters stand in the order they were left in and both sentences are there. The first part's
        // failures are NOT asserted yet: the reopen is made anyway, so one run shows the word total after the reopen as well.
        guard reopen() else { return }
        let afterReopen = rqWordTotalStable()
        rqCheckOrder("after the reopen", expected: rqHeadings(rows), to: &soft)
        addRowChecks("after the reopen", expectedUser: rqRows(rows, typed: typed), managed: nil, to: &soft)
        soft.check(blocksContaining(Self.rqFirst + " " + Self.rqSecond) == 1, "after the reopen the two sentences are not side by side in one row")
        result("WORD TOTALS (the status bar's \"N words\"): at the start \(rqShown(startTotal, or: "unreadable")); before the drag "
            + "(after the first word was saved) \(rqShown(beforeDrag, or: "unreadable")); after the drag and the settle "
            + "\(rqShown(afterSettle, or: "unreadable")); after the reopen \(rqShown(afterReopen, or: "unreadable")); "
            + "expected after the settle \(rqShown(expectedAfterSettle, or: "n/a"))")
        soft.check(afterSettle != nil && afterSettle == afterReopen,
                   "WORD TOTAL: \(rqShown(afterSettle, or: "nothing readable")) after the drag and the settle but "
                       + "\(rqShown(afterReopen, or: "nothing readable")) after the reopen: the live total was not the saved document's")
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-type-drag-book6-4-after-the-reopen")
        assertSoft(soft, "type, Option-drag, type again with no click, then the reopen, on book6")
    }
}

// MARK: - E2 Drag, Cmd-Z at once, Cmd-Shift-Z

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 2: "Option-drag a chapter above another. Press Cmd-Z, then Cmd-Shift-Z." The Cmd-Z is the next thing done after the drop
    /// (it waits its turn behind the drag's job: never refused). After the drag, after Cmd-Z and after Cmd-Shift-Z the sidebar's card
    /// order, the editor's heading order and the block table's heading order are the same, and each is the one worked out by hand. Both
    /// presses are the queued slow ones (`swap-editor-first ... ok=true`).
    func testReorderEFUndoRedo_book6() {
        let moved = Self.rqChapter(4)
        let target = Self.rqChapter(3)
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6), rqRequire([moved, target]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let original = rqUserRows()
        let reordered = rqMoving(original, moved, before: target)
        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5) else { return }

        // Cmd-Z straight after the drop.
        guard let undoFrom = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: undoFrom, "the Cmd-Z of the reorder reached its performed line", slow: true)
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-undo-redo-book6-1-after-cmd-z")
        var soft = Phase4bFlowSoftChecks()
        rqCheckOrder("after the drag and Cmd-Z", expected: rqHeadings(original), to: &soft)
        addRowChecks("after Cmd-Z", expectedUser: rqRows(original), managed: nil, to: &soft)

        // Cmd-Shift-Z.
        tail.poll()
        let redoFrom = tail.lines.count
        app.activateAndWaitForForeground()
        pressRedo()
        expectPerformed("redo", from: redoFrom, "the Cmd-Shift-Z of the reorder reached its performed line", slow: true)
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-undo-redo-book6-2-after-cmd-shift-z")
        let post = rqChecks("after the drag, Cmd-Z and Cmd-Shift-Z", from: dragFrom, drags: 1, rows: reordered, to: &soft)
        rqCheckOptionCarried(moved, expected: rqHeadings(reordered), what: "after the redo of the drag", to: &soft)
        addSlowUndoMechanismChecks("undo", from: undoFrom, to: &soft)
        addSlowUndoMechanismChecks("redo", from: redoFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag, Cmd-Z and Cmd-Shift-Z", to: &soft)
        assertSoft(soft, "drag, Cmd-Z at once, Cmd-Shift-Z, on book6")
    }
}

// MARK: - E3 Delete, drag, Cmd-Z, Cmd-Z: the delete's undo stays quick

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 3: "Delete Section on a chapter, Option-drag another, press Cmd-Z twice." The drag used to bump the structural generation, which
    /// closed the quick road of the earlier delete's undo. The first Cmd-Z is the reorder's (the queued slow undo); the SECOND is the
    /// delete's and must be QUICK: its sequence began `start (quick`, no `swap opId=` line, no "Undoing..." notice. Then a word typed at the
    /// end of a plain line in the RESTORED chapter's own body (Chapter 5: two lines are seeded under its heading) reaches the database in
    /// that row (the quick-restored section is live), and the document is the one before.
    func testReorderEFDeleteThenDragQuickUndo_book6() {
        let moved = Self.rqChapter(4)
        let target = Self.rqChapter(3)
        let deleted = Self.rqChapter(5)
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6,
                      extra: { Self.withPlainLines($0, under: deleted, level: 1, lines: [Self.dupLineOne, Self.dupLineTwo]) }),
              rqRequire([moved, target, deleted]), pre.contains(where: { $0.fragment == Self.dupLineOne }),
              let dupTwo = pre.firstIndex(where: { $0.fragment == Self.dupLineTwo }),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine),
              deleteSectionFromSidebar(deleted),
              let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5) else { return }
        _ = settle()
        note("AFTER the delete and the drag: \(headingFragmentsInDatabase().count) headings in the block table "
            + "(\(preHeadingFragments.count) before the delete)")
        var soft = Phase4bFlowSoftChecks()
        let movedWithoutDeleted = rqWithout(rqMoving(rqUserRows(), moved, before: target), section: deleted)
        rqCheckOptionCarried(moved, expected: rqHeadings(movedWithoutDeleted), what: "after the delete and the drag", to: &soft)

        guard let reorderUndoFrom = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: reorderUndoFrom, "the first Cmd-Z (the reorder's) reached its performed line", slow: true)
        _ = settle()
        guard let deleteUndoFrom = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: deleteUndoFrom, "the second Cmd-Z (the delete's) reached its performed line", slow: true)
        let back = settle(back: [deleted])
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-delete-drag-book6-after-both-undos")

        // Type into the RESTORED chapter's own body (user step 3): the sidebar's navigation to its card, then the plain line under its heading.
        guard rqPlaceCaret(inSectionCard: deleted, line: Self.dupLineTwo, prefix: Self.dupTwoPrefix) else { return }
        typeNow(" " + Self.rqFirst)
        let landed = waitForSentenceInDatabase(Self.rqFirst, timeout: 90)
        _ = settle()
        let runs = quickRuns(from: deleteUndoFrom, label: "undo")
        let starts = traceLines(from: deleteUndoFrom).filter { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("THE DELETE'S UNDO: sequence start line(s) \(starts.map(\.step)); paths \(Self.describePaths(runs)); "
            + "`swap opId=` lines \(swapLineCount(from: deleteUndoFrom)); "
            + "\"Undoing\" notices \(undoingToastCount(from: deleteUndoFrom)); \(restoreCounts)")
        soft.check(back, "\"\(deleted)\" is back in the block table and the document is quiet")
        soft.check(starts.count == 1 && starts[0].step.hasPrefix("start (quick"),
                   "the delete's undo did not take the QUICK road (start lines \(starts.map(\.step))): "
                       + "the reorder closed the quick road of an earlier delete")
        soft.check(runs.count == 1 && runs[0].quick, "the delete's undo ran \(Self.describePaths(runs)), expected one quick undo")
        soft.check(swapLineCount(from: deleteUndoFrom) == 0,
                   "\(swapLineCount(from: deleteUndoFrom)) `swap opId=` line(s) from the delete's undo on: the slow road")
        soft.check(undoingToastCount(from: deleteUndoFrom) == 0, "the delete's undo showed the \"Undoing...\" notice")
        soft.check(landed, "the word typed into the restored chapter's own body after the two undos reached the database")
        let typed = [dupTwo: Self.dupLineTwo + " " + Self.rqFirst]
        let post = rqChecks("after delete, drag, Cmd-Z, Cmd-Z and typing", from: dragFrom, drags: 1, rows: rqUserRows(), typed: typed, to: &soft)
        let typedRow = post.firstIndex { $0.fragment == Self.dupLineTwo + " " + Self.rqFirst }
        let restored = Phase4bFlow.sectionRange(deleted, in: post)
        result("THE TYPED WORD: row \(typedRow.map(String.init) ?? "none"); the restored chapter \"\(deleted.prefix(12))...\" covers rows "
            + "\(restored.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "none")")
        soft.check(typedRow != nil && restored.map { range in typedRow.map { range.contains($0) } ?? false } == true,
                   "the typed word is not in the restored chapter's own plain line (row \(typedRow.map(String.init) ?? "none"), the chapter covers "
                       + "\(restored.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "no rows"))")
        addSlowUndoMechanismChecks("undo", from: reorderUndoFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after delete, drag, Cmd-Z, Cmd-Z and typing", to: &soft)
        assertSoft(soft, "delete, Option-drag, Cmd-Z, Cmd-Z (the delete's undo stays quick), on book6")
    }
}

// MARK: - E4 A footnoted chapter above Chapter 1, typing during the job, Cmd-Z

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 6: "Move a chapter with footnotes to the top." The caret is in Chapter 2 (the end of a seeded line under "2.6 Conclusion");
    /// Chapter 2, with its sub-sections and nine footnotes, is Option-dragged above Chapter 1 (the top of the first card), and a word is
    /// typed at once, while the reorder's job is held in the writer. The typing is kept; the footnote numbers (references in reading order)
    /// and the Notes definitions follow the text (the footnote walk of `addRowChecks`); screen equals database. Then Cmd-Z until the
    /// original section order is back (at most four presses, each judged on its own): the typed word is undone by a text step first (the
    /// editor says so with one `routing-refused ... docs-not-equal` line, not a refusal), and NO press may leave the document in the
    /// state "moved order, original footnote numbers" (judge ruling W2: the renumber is never a text undo of its own).
    /// EACH NOTE IS TIED TO ITS REFERENCE: the seed appends a unique tag to every footnote definition (`rqTaggingNotes`; the books repeat
    /// one chapter's prose, so without a tag the notes of chapter 2 read exactly like those of chapter 1). After the settle the first
    /// reference of the document is the moved chapter's first one, the definition `[^i]` is the note whose reference stands i-th in the
    /// text, and the moved chapter's references point at their own original notes; the same mapping is asserted against the original
    /// after the Cmd-Z. (A renumber that relabels the references and leaves the Notes text in the old order passes the row comparison and
    /// the footnote walk, which look at numbers only; it fails here.)
    func testReorderEFFootnoteChapterTypeDuringJob_book6() {
        let moved = Self.rqChapter(2)
        let target = Self.rqChapter(1)
        let seededSection = "2.6 Conclusion"
        guard rqStart(.book6, method: #function, env: Self.rqJobHold, flat: Self.rqFlatBook6,
                      extra: { Self.rqTaggingNotes(Self.withDupLines($0, under: seededSection)) }),
              rqRequire([moved, target, seededSection]), requireDupLines(under: seededSection) != nil,
              let dupOne = pre.firstIndex(where: { $0.fragment == Self.dupLineOne }),
              rqPlaceCaret(inSectionCard: seededSection, line: Self.dupLineOne, prefix: Self.dupOnePrefix) else { return }
        let movedRows = section(moved) ?? 0..<0
        let movedOriginalRefs = pre[movedRows].flatMap { Phase4bFlow.footnoteRefs(in: $0.fragment) }
        let tagged = pre.filter { Phase4bFlow.definition($0.fragment).map { $0.text.contains(Self.rqNoteTag($0.number)) } ?? false }.count
        note("THE MOVED CHAPTER \"\(moved)\": \(movedRows.count) block rows, its footnote references are originally numbered \(movedOriginalRefs); "
            + "\(tagged) of \(Phase4bFlowWalk(rows: pre).definitions.count) definitions carry their tag; the caret is in its seeded line")
        let definitionCount = Phase4bFlowWalk(rows: pre).definitions.count
        guard !movedOriginalRefs.isEmpty, let movedFirstOriginal = movedOriginalRefs.first, tagged == definitionCount else {
            fail("TEST-SETUP: the moved chapter holds no footnote reference, or the definitions did not keep their tags")
            return
        }
        let original = rqUserRows()
        let reordered = rqMoving(original, moved, before: target)
        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5) else { return }
        tail.poll()
        let typedFrom = tail.lines.count
        typeNow(" " + Self.rqDuring)
        reportTypingAgainstSwapJob(jobFrom: dragFrom, typedFrom: typedFrom, holdMs: Self.jobHoldMs)
        let landed = waitForSentenceInDatabase(Self.rqDuring, timeout: 90)
        guard waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-footnote-chapter-book6-1-after-the-settle")
        var soft = Phase4bFlowSoftChecks()
        soft.check(landed, "the word typed while the reorder's job was held reached the database")
        let typed = [dupOne: Self.dupLineOne + " " + Self.rqDuring]
        let post = rqChecks("after the drag and the typing", from: dragFrom, drags: 1, rows: reordered, typed: typed, to: &soft)
        rqCheckOptionCarried(moved, expected: rqHeadings(reordered), what: "after the drag", to: &soft)
        let walk = Phase4bFlowWalk(rows: post)
        result("FOOTNOTES after the move: \(walk.summary) (before: \(Phase4bFlowWalk(rows: pre).summary)); first reference in the document: "
            + "\(walk.refs.first.map(String.init) ?? "none")")
        // The first reference of the document is the moved chapter's first one, and each note stays tied to its reference.
        let userPost = post.filter { !$0.isManaged }
        let firstReferenceRow = userPost.firstIndex { !Phase4bFlow.footnoteRefs(in: $0.fragment).isEmpty }
        soft.check(firstReferenceRow.map { $0 < movedRows.count && Phase4bFlow.footnoteRefs(in: userPost[$0].fragment).first == 1 } ?? false,
                   "the first reference of the document (row \(firstReferenceRow.map(String.init) ?? "none")) is not the moved chapter's first one "
                       + "(the chapter covers the first \(movedRows.count) rows, and its first reference must read [^1])")
        let notesAfter = rqNotesProblems(post, arrangement: reordered)
        let firstDefinition = walk.definitions.first { $0.number == 1 }?.text ?? ""
        result("NOTES TIED TO THEIR REFERENCES after the move: definition [^1] ends \"\(firstDefinition.suffix(40))\" "
            + "(it must be the note originally numbered \(movedFirstOriginal), \(Self.rqNoteTag(movedFirstOriginal))); "
            + "\(notesAfter.count) mismatch(es) over \(walk.refs.count) references")
        soft.check(firstDefinition.contains(Self.rqNoteTag(movedFirstOriginal)),
                   "definition [^1] is not the note the moved chapter's first reference pointed at (originally [^\(movedFirstOriginal)]): "
                       + "it ends \"\(firstDefinition.suffix(40))\"")
        soft.check(notesAfter.isEmpty, "the Notes do not follow the text after the move: \(notesAfter.prefix(3))")
        soft.check(blocksContaining(Self.rqDuring) == 1, "the typed word is in \(blocksContaining(Self.rqDuring)) row(s), expected exactly 1")
        addTypedLineOnScreenCheck(line: Self.dupLineOne, marker: Self.rqDuring, requireIt: true, to: &soft)

        // Cmd-Z until the original order is back.
        let movedHeadings = rqHeadings(reordered)
        let originalHeadings = rqHeadings(original)
        var decisions: [String] = []
        var presses = 0
        var orderBack = false
        for number in 1...4 {
            presses = number
            let press = rqPressStep(redo: false, number: number)
            decisions.append(press.decision)
            _ = settle()
            orderBack = headingFragmentsInDatabase() == originalHeadings
            if !orderBack, headingFragmentsInDatabase() == movedHeadings {
                let rowsNow = readRows()
                let state = Phase4bFlowWalk(rows: rowsNow)
                soft.check(state.problems.isEmpty,
                           "press \(number) left the moved order with footnote numbers that do not follow the text "
                               + "(\(state.problems.prefix(2))): the renumber was undone alone")
                let notesNow = rqNotesProblems(rowsNow, arrangement: reordered)
                soft.check(notesNow.isEmpty, "press \(number) left the moved order with Notes that do not follow the text: \(notesNow.prefix(2))")
            }
            soft.check(press.refusals.isEmpty, "press \(number) was refused: \(press.refusals.prefix(1))")
            if orderBack { break }
        }
        result("CMD-Z: the editor decided \(decisions) over \(presses) press(es); the original section order is back: \(Self.yesNo(orderBack))")
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-footnote-chapter-book6-2-after-cmd-z")
        soft.check(orderBack, "the original section order did not come back within \(presses) Cmd-Z presses (the editor decided \(decisions))")
        soft.check(presses <= 2, "it took \(presses) Cmd-Z presses to bring the section order back, expected at most 2 "
            + "(the typed word, then the reorder)")
        let typedKept = blocksContaining(Self.rqDuring) > 0
        let finalRows = typedKept ? rqRows(original, typed: typed) : rqRows(original)
        let after = addRowChecks("after Cmd-Z", expectedUser: finalRows, managed: nil, to: &soft)
        // The same mapping against the ORIGINAL arrangement: definition [^i] is the note originally numbered i again.
        let notesBack = rqNotesProblems(after, arrangement: original)
        let referencesBack = Phase4bFlowWalk(rows: after).refs.count
        result("NOTES TIED TO THEIR REFERENCES after Cmd-Z: \(notesBack.count) mismatch(es) over \(referencesBack) references")
        soft.check(notesBack.isEmpty, "the Notes do not follow the text after the Cmd-Z (the original arrangement): \(notesBack.prefix(3))")
        addSlowUndoMechanismChecks("undo", from: dragFrom, to: &soft)
        addScreenEqualsDatabaseCheck(before: after, what: "after the Cmd-Z presses", to: &soft)
        assertSoft(soft, "a footnoted chapter dragged to the top, typing during the job, Cmd-Z, on book6")
    }
}

// MARK: - E5 Duplicate, Option-drag the copy, Cmd-Z twice (article)

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 5: "Duplicate a section, Option-drag the copy above the original, press Cmd-Z twice." The article's "1.3 Prices at the
    /// Market" (an H2 with two sub-sections and footnotes) is duplicated; the copy (three cards) is Option-dragged to just above the original
    /// (dropped in the level-2 zone of the card above, so it stays an H2). The first Cmd-Z is the reorder's: the copy is back right after
    /// the original's last sub-section; the second is the duplicate's: the copy is gone and the document is the one before.
    func testReorderEFDuplicateDragUndoTwice_article() {
        let size = Phase4bDelSize.article
        let title = size.deleteTitle
        let copyTitle = title + " copy"
        guard rqStart(size, method: #function, flat: []), rqRequire([title]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine),
              let card = bringSidebarCardIntoView(title) else { return }
        let original = preHeadingFragments
        guard let start = original.firstIndex(where: { Self.rqTitle($0) == title }) else {
            fail("TEST-SETUP: the heading list has no \"\(title)\"")
            return
        }
        let level = Self.rqLevel(original[start])
        var end = start + 1
        while end < original.count, Self.rqLevel(original[end]) > level { end += 1 }
        var copy = Array(original[start..<end])
        copy[0] += " copy"
        let afterDuplicate = Array(original[..<end]) + copy + Array(original[end...])
        let afterDrag = Array(original[..<start]) + copy + Array(original[start..<end]) + Array(original[end...])
        note("THE SECTION \"\(title)\" is level \(level) with \(end - start - 1) sub-section(s); the copy holds the same \(copy.count) headings")

        let from = chooseSidebarItem(card, item: "Duplicate Section")
        expectPerformed("sectionDuplicate", from: from, "the duplicate reached its performed line")
        assertCheck(waitForCard(copyTitle, present: true, timeout: capped(30)), "the copy's sidebar card is shown")
        _ = settle()
        guard let dragFrom = rqDragBefore(copyTitle, before: title, level: level, option: true, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        var soft = Phase4bFlowSoftChecks()
        rqCheckOrder("after the duplicate and the drag (the copy above the original)", expected: afterDrag, to: &soft)
        rqCheckOptionCarried(copyTitle, expected: afterDrag, what: "after the drag of the copy", to: &soft)

        guard let firstUndo = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: firstUndo, "the first Cmd-Z (the reorder's) reached its performed line", slow: true)
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-duplicate-drag-article-1-after-first-cmd-z")
        rqCheckOrder("after the first Cmd-Z (the copy right after the original's last sub-section)", expected: afterDuplicate, to: &soft)

        guard let secondUndo = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: secondUndo, "the second Cmd-Z (the duplicate's) reached its performed line", slow: true)
        let gone = settle(gone: [copyTitle])
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-duplicate-drag-article-2-after-second-cmd-z")
        soft.check(gone, "the copy \"\(copyTitle)\" is gone from the block table once the second Cmd-Z has settled")
        rqCheckOrder("after the second Cmd-Z (the copy is gone)", expected: original, to: &soft)
        let post = addRowChecks("after both Cmd-Z presses", expectedUser: preUserRows, managed: preManagedRows, to: &soft)
        addMechanismChecks(from: from, to: &soft)
        addReorderMechanismChecks(from: dragFrom, drags: 1, to: &soft)
        soft.check(!swapEditorFirstLines(direction: "undo", succeeded: true, from: firstUndo).isEmpty,
                   "no `swap-editor-first direction=undo ... ok=true` line: the reorder's undo did not take the queued slow road")
        result("THE UNDOS: \(Self.describePaths(quickRuns(from: firstUndo, label: "undo")))")
        addLogChecks(from: from, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after both Cmd-Z presses", to: &soft)
        assertSoft(soft, "duplicate, Option-drag the copy, Cmd-Z twice, on the article")
    }
}

// MARK: - E6 Two drags, then Cmd-Z twice

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// "Drag twice, then press Cmd-Z twice." Chapter 4 is Option-dragged before Chapter 3, then Chapter 2 above Chapter 1 (the second drag of
    /// the launch drops at another height: the sidebar ignores a drop at exactly the point of the one before). After EACH drag the block
    /// table, the sidebar and the editor agree on the order; each Cmd-Z undoes one drag (the second drag first); after both the document
    /// is the one before.
    func testReorderEFTwiceThenUndo_book6() {
        let one = (moved: Self.rqChapter(4), target: Self.rqChapter(3))
        let two = (moved: Self.rqChapter(2), target: Self.rqChapter(1))
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6), rqRequire([one.moved, one.target, two.moved, two.target]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let original = rqUserRows()
        let afterOne = rqMoving(original, one.moved, before: one.target)
        let afterTwo = rqMoving(afterOne, two.moved, before: two.target)
        var soft = Phase4bFlowSoftChecks()
        // The word total (the status bar's "N words") at the start: no word is typed in this test, so every later reading must equal it.
        let startTotal = rqWordTotalStable()
        guard let firstFrom = rqDragBefore(one.moved, before: one.target, level: 1, option: true, dropY: 0.5),
              waitForReorderPerformed(from: firstFrom) else { return }
        _ = settle()
        let totalAfterFirst = rqWordTotalStable()
        rqCheckOrder("after the first drag", expected: rqHeadings(afterOne), to: &soft)
        rqCheckOptionCarried(one.moved, expected: rqHeadings(afterOne), what: "after the first drag", to: &soft)
        guard let secondFrom = rqDragBefore(two.moved, before: two.target, level: 1, option: true, dropY: 0.62),
              waitForReorderPerformed(from: secondFrom) else { return }
        _ = settle()
        let totalAfterSecond = rqWordTotalStable()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-twice-book6-1-after-two-drags")
        rqCheckOrder("after the second drag", expected: rqHeadings(afterTwo), to: &soft)
        rqCheckOptionCarried(two.moved, expected: rqHeadings(afterTwo), what: "after the second drag", to: &soft)

        guard let undoOne = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: undoOne, "the first Cmd-Z (the second drag's) reached its performed line", slow: true)
        _ = settle()
        let totalAfterFirstUndo = rqWordTotalStable()
        rqCheckOrder("after the first Cmd-Z (only the first drag is left)", expected: rqHeadings(afterOne), to: &soft)
        guard let undoTwo = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: undoTwo, "the second Cmd-Z (the first drag's) reached its performed line", slow: true)
        _ = settle()
        let totalAfterUndos = rqWordTotalStable()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-twice-book6-2-after-two-cmd-z")
        result("WORD TOTALS (the status bar's \"N words\"; no word was typed): at the start \(rqShown(startTotal, or: "unreadable")); "
            + "after the first drag \(rqShown(totalAfterFirst, or: "unreadable")); "
            + "after the second drag \(rqShown(totalAfterSecond, or: "unreadable")); "
            + "after the first Cmd-Z \(rqShown(totalAfterFirstUndo, or: "unreadable")) (printed only); after both Cmd-Z "
            + "\(rqShown(totalAfterUndos, or: "unreadable")); every reading must equal the starting total")
        for (when, total) in [("the first drag", totalAfterFirst), ("the second drag", totalAfterSecond), ("both Cmd-Z presses", totalAfterUndos)] {
            soft.check(startTotal != nil && total == startTotal,
                       "WORD TOTAL: the status bar reads \(rqShown(total, or: "nothing readable")) after \(when), "
                           + "expected \(rqShown(startTotal, or: "n/a")) "
                           + "(the total at the start; no word was typed and a reorder changes none)")
        }
        let post = rqChecks("after two drags and two Cmd-Z presses", from: firstFrom, drags: 2, rows: original, to: &soft)
        addSlowUndoMechanismChecks("undo", performed: 2, from: undoOne, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after two drags and two Cmd-Z presses", to: &soft)
        assertSoft(soft, "two drags, then Cmd-Z twice, on book6")
    }
}

// MARK: - E7 A drag in Markdown mode is editor first (flipped by t-4a8fd8af slice 2)

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// Switches to Markdown mode (the status-bar badge reads "Markdown") with Cmd-/ and waits until the app's log is quiet (the editor swap).
    func rqSwitchToMarkdown() -> Bool {
        let mode = app.buttons["status-bar-editor-mode"]
        guard mode.waitForExistence(timeout: 10) else { fail("the editor-mode button never appeared"); return false }
        var toggled = false
        for _ in 1...5 {
            if mode.label == "Markdown" { toggled = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if mode.waitForLabel("== 'Markdown'", timeout: 2) { toggled = true; break }
        }
        guard toggled else { fail("the editor-mode button never reported Markdown after the toggle keystroke"); return false }
        let quiet = waitForLogQuiet(quiet: 3, cap: capped(60))
        note("MODE: Markdown; the app's log was quiet for 3 s after the switch: \(Self.yesNo(quiet))")
        return true
    }

    /// User step 9: "Switch to Markdown, drag a section card, press Cmd-Z." FLIPPED by t-4a8fd8af slice 2: it was
    /// `testReorderEFMarkdownOldPath_article` and asserted that Markdown mode keeps the OLD road (a plain `start`, no `reorder-editor-first`
    /// line). Now Markdown mode takes the editor-first road: the drag's sequence began `start (editor-first) mode=markdown` and ZERO plain
    /// `start` lines were written for it, the page's reply `reorder-editor-first opId=.. ok=true mode=markdown` is in the log exactly once,
    /// the Markdown writer's hold was raised and released, and no `fell back` / `refused` step or fallback line was written. The same settled
    /// checks as before: the heading order is the hand-worked one in the block table, the sidebar and the editor's visible lines. Cmd-Z
    /// then brings the original heading order back (ASSERTED in the three places): it is pressed WITHOUT a click back into the line first
    /// (the old body rebuilt the editor and needed one; the editor-first drag leaves the keyboard focus where it was; a key that reaches no
    /// editor is recorded as a finding and the test then clicks back, as a person would), it is decided `structural`, and it takes the
    /// queued slow route (`start (markdown queued undo)`). Afterwards the content state is idle: a word typed after the undo has settled
    /// reaches the database.
    func testReorderEFMarkdown_article() {
        let size = Phase4bDelSize.article
        let moved = "1.6 Conclusion"
        let target = "1.5 Lanterns After Dark"
        guard rqStart(size, method: #function, flat: []), rqAnchorRow() != nil, rqRequire([moved, target]),
              rqSwitchToMarkdown(),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let rows = rqMoving(rqUserRows(), moved, before: target)
        guard let dragFrom = rqDragBefore(moved, before: target, level: 2, option: false, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        var soft = Phase4bFlowSoftChecks()
        rqCheckOrder("after the Markdown drag", expected: rqHeadings(rows), to: &soft)
        let traces = traceLines(from: dragFrom).filter { $0.family == .sequence && $0.label == "sectionReorder" }
        let starts = traces.filter { $0.isOpStart }
        let editorFirst = editorFirstOkLines("reorder", from: dragFrom)
        let fellBack = traces.filter { $0.step.hasPrefix("fell back") || $0.step.hasPrefix("refused") }
        tail.poll()
        let holdLines = tail.lines[min(dragFrom, tail.lines.count)...].map(\.text)
        let raised = holdLines.filter { $0.contains("[MdWrite] structural hold raised") }.count
        let released = holdLines.filter { $0.contains("[MdWrite] structural hold released") }.count
        result("MARKDOWN MECHANISM: sectionReorder start line(s) \(starts.map(\.step)); `reorder-editor-first` lines \(editorFirst.count); "
               + "fell-back/refused steps \(fellBack.count); Markdown holds raised \(raised), released \(released)")
        soft.check(starts.count == 1 && starts[0].step == "start (editor-first) mode=markdown",
                   "the Markdown drag's sequence began \(starts.map(\.step)), expected one `start (editor-first) mode=markdown` "
                       + "(the old body logs a plain `start`)")
        soft.check(!starts.contains { $0.step == "start" }, "a plain `start` of the old body was written for the Markdown drag")
        soft.check(editorFirst.count == 1 && editorFirst[0].contains("mode=markdown"),
                   "\(editorFirst.count) `reorder-editor-first ... ok=true mode=markdown` line(s) in Markdown mode, expected exactly 1")
        soft.check(fellBack.isEmpty, "\(fellBack.count) `fell back` / `refused` step(s): \(fellBack.map(\.step))")
        soft.check(raised >= 1 && released == raised, "\(raised) Markdown hold(s) raised but \(released) released by the drag's job")
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-markdown-article-1-after-the-drag")

        // User step 9's Cmd-Z, ASSERTED: the editor-first drag records a structural entry whose Cmd-Z is the queued slow route (docs/
        // architecture/document-writer.md, "Markdown editor-first section reorder"; the CodeMirror coordinator logs the same `[UnifiedUndo]
        // keydown` line). NO click back into the line first: the old road rebuilt the editor and needed one, this one does not. A key that
        // reached no editor is recorded as a finding, and then the test clicks back and presses again so the rest still runs.
        tail.poll()
        let undoFrom = tail.lines.count
        var press = rqPressStep(redo: false, number: 1)
        if press.decision == "none" {
            soft.check(false, "FINDING: the Cmd-Z right after the Markdown drag reached no editor (no `[UnifiedUndo] keydown` line): the keyboard "
                           + "focus did not survive the drag")
            clickBackIntoAnchor()
            press = rqPressStep(redo: false, number: 2)
        }
        let undoStart = traceLines(from: undoFrom).first { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("MARKDOWN CMD-Z: the editor decided \(press.decision); a structural undo ran: \(Self.yesNo(press.structural)); sequence began "
               + "`\(undoStart?.step ?? "none")`")
        soft.check(press.decision == "structural" && press.structural && undoStart?.step.hasPrefix("start (markdown queued undo") == true,
                   "the Cmd-Z of the Markdown drag was decided \(press.decision) (structural ran: \(Self.yesNo(press.structural))) and began "
                       + "`\(undoStart?.step ?? "none")`, expected a structural undo on the queued slow route `start (markdown queued undo)`")
        _ = settle()
        let afterUndo = rqRecordState("Cmd-Z in Markdown mode (the editor decided \(press.decision))", original: preHeadingFragments,
                                      moved: rqHeadings(rows), marker: Self.rqFirst)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-markdown-article-2-after-cmd-z")
        soft.check(afterUndo == "original",
                   "after Cmd-Z in Markdown mode the heading order is \(afterUndo), not the original one (the editor decided \(press.decision), "
                       + "a structural undo ran: \(Self.yesNo(press.structural)), refusals \(press.refusals.prefix(1)))")
        rqCheckOrder("after Cmd-Z in Markdown mode", expected: preHeadingFragments, to: &soft)

        // The content state is idle again: a word typed straight after the reorder (a click back into the line, as a person does after
        // the old road rebuilt the editor) reaches the database.
        clickBackIntoAnchor()
        typeNow(" " + Self.rqFirst)
        let landed = waitForSentenceInDatabase(Self.rqFirst, timeout: 90)
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-markdown-article-3-after-the-typing")
        soft.check(landed, "a word typed after the Markdown reorder never reached the database: the content state was not idle again")
        soft.check(blocksContaining(Self.rqFirst) == 1, "the typed word is in \(blocksContaining(Self.rqFirst)) row(s), expected exactly 1")
        assertSoft(soft, "a drag in Markdown mode is editor first, on the article")
    }
}

// MARK: - E8 A chapter dragged under the last card

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 7: "Drag a chapter into the empty space under the last card." Chapter 5 (a flat chapter, so its card is on screen with the
    /// end of the list) is dropped under the last card. It lands as the last CHAPTER, before Notes and Bibliography, which stay last in
    /// the block table, the sidebar and the text; the sequence began `start (editor-first)` (a book with footnotes used to leave this
    /// drop to the old road, because the section would have landed after Notes); the dropped heading is still level 1.
    func testReorderEFToBottomStaysBeforeNotes_book6() {
        let moved = Self.rqChapter(5)
        let last = Self.rqChapter(6)
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6), rqRequire([moved, last]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let rows = rqMoving(rqUserRows(), moved, before: nil)
        guard let dragFrom = rqDrag(moved, .bottom, level: 1, option: true, dropY: 0.5), waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        let level = rqHeadingLevel(of: moved)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-to-bottom-book6-after-the-drop")
        var soft = Phase4bFlowSoftChecks()
        soft.check(level == 1, "JUDGE ITEM (ii): \"\(moved)\" is level \(level.map(String.init) ?? "missing") after the end drop "
            + "(a chapter must stay a chapter)")
        let post = rqChecks("after the drop under the last card", from: dragFrom, drags: 1, rows: rows, to: &soft)
        let tailRows = post.drop(while: { !$0.isManaged })
        soft.check(!tailRows.isEmpty && tailRows.allSatisfy(\.isManaged), "Notes and Bibliography are not the last rows of the block table")
        if let range = Phase4bFlow.sectionRange(moved, in: post) {
            soft.check(range.upperBound == post.count - tailRows.count,
                       "\"\(moved)\" ends at row \(range.upperBound) but Notes start at row \(post.count - tailRows.count): "
                           + "it is not the last chapter")
        } else {
            soft.check(false, "\"\(moved)\" is not a section of the saved document")
        }
        var cards = [last, moved, "Notes"]
        if let bibliography = rqLastCardTitle(), bibliography != "Notes" { cards.append(bibliography) }
        let sidebar = waitForSidebarOrder(cards)
        soft.check(sidebar == nil, "the sidebar does not end with \(cards): \(sidebar ?? "")")
        addScreenEqualsDatabaseCheck(before: post, what: "after the drop under the last card", to: &soft)
        assertSoft(soft, "a chapter dragged under the last card stays before Notes, on book6")
    }
}

// MARK: - E9 Insert a footnote, then drag its chapter at once

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// "Insert a footnote in a chapter, then at once drag that chapter." Chapter 5 (flat) gets a marker word and a new footnote
    /// (Cmd-Shift-N) under its heading, and straight after it is dragged below Chapter 6. After the settle the new footnote is numbered
    /// after the footnotes that now stand above it (the references in reading order are 1...n), its Notes entry exists, no other
    /// definition is blank, the heading order is the one worked out by hand and screen equals database. READING THE CODE I CANNOT SAY THIS
    /// FAILS ON THE BASE: the old body flushes the editor first and waits for running rebuilds, so it may well pass there; the driver's red
    /// run decides whether E9 leaves the must-fail list.
    func testReorderEFFootnoteInsertThenDrag_book6() {
        let moved = Self.rqChapter(5)
        let below = Self.rqChapter(6)
        guard rqStart(.book6, method: #function, env: Self.rqJobHold, flat: Self.rqFlatBook6,
                      extra: { Self.withPlainLines($0, under: moved, level: 1, lines: [Self.dupLineOne, Self.dupLineTwo]) }),
              rqRequire([moved, below]), pre.contains(where: { $0.fragment == Self.dupLineOne }),
              rqPlaceCaret(inSectionCard: moved, line: Self.dupLineOne, prefix: Self.dupOnePrefix) else { return }
        let referencesBefore = Phase4bFlowWalk(rows: pre).refs.count
        let rows = rqMoving(rqUserRows(), moved, before: nil)
        typeNow(" " + Self.rqNote)
        app.typeKey("n", modifierFlags: [.command, .shift])
        guard let dragFrom = rqDrag(moved, .after(below), level: 1, option: false, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-footnote-insert-book6-after-the-settle")
        var soft = Phase4bFlowSoftChecks()
        rqCheckOrder("after the footnote and the drag", expected: rqHeadings(rows), to: &soft)
        let post = readRows()
        let walk = Phase4bFlowWalk(rows: post)
        var newLabel: Int?
        if let noteRow = post.firstIndex(where: { $0.fragment.contains(Self.rqNote) }) {
            let ownRefs = Phase4bFlow.footnoteRefs(in: post[noteRow].fragment)
            if ownRefs.count == 1 { newLabel = ownRefs.first }
            let before = post[..<noteRow].reduce(0) { $0 + Phase4bFlow.footnoteRefs(in: $1.fragment).count }
            result("THE NEW FOOTNOTE: its row holds reference(s) \(ownRefs); \(before) reference(s) stand above it; "
                + "definitions \(walk.definitions.count), blank ones \(walk.definitions.filter { $0.text.isEmpty }.map(\.number))")
            soft.check(ownRefs == [before + 1],
                       "the new footnote's row holds \(ownRefs), expected [\(before + 1)] (the references above it plus one)")
            soft.check(walk.definitions.contains { $0.number == before + 1 }, "the Notes hold no definition [^\(before + 1)] for the new footnote")
            // `Phase4bFlow.definition` reads the text whitespace-trimmed, so a blank definition stored as "[^37]: " (a trailing space, which
            // is how the app stores any new empty footnote) counts as blank here exactly like "[^37]:". Only the new footnote's may be blank.
            let blank = walk.definitions.filter { $0.text.isEmpty }.map(\.number)
            soft.check(blank.isEmpty || blank == [before + 1], "blank definitions \(blank): only the new footnote's may be blank")
        } else {
            soft.check(false, "no row holds the marker \"\(Self.rqNote)\" typed before the footnote was inserted")
        }
        soft.check(walk.refs.count == referencesBefore + 1, "\(walk.refs.count) footnote references, expected \(referencesBefore + 1)")
        let others = walk.problems.filter { !$0.hasPrefix("blank definition") }
        soft.check(others.isEmpty, "footnotes: \(others)")
        addReorderMechanismChecks(from: dragFrom, drags: 1, to: &soft)
        addLogChecks(from: dragFrom, to: &soft)
        // The one tolerance: the new, still empty footnote's definition row is stored as "[^N]: " (a trailing space) and the live editor
        // serialises it as "[^N]:" (FootnoteSyncService+Reconciliation.swift:874), for ANY new empty footnote. That one row is compared
        // whitespace-trimmed; every other row and every other difference stays exact.
        if let newLabel {
            rqScreenEqualsDatabaseCheck(before: post, what: "after the footnote and the drag", blankDefinition: newLabel, to: &soft)
        } else {
            addScreenEqualsDatabaseCheck(before: post, what: "after the footnote and the drag", to: &soft)
        }
        assertSoft(soft, "insert a footnote, drag its chapter at once, on book6")
    }
}

// MARK: - E10 CJK paragraph, Option-drag on the twelve-chapter book, jsMs recorded

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// The judge's gate on the reorder's editor turn: "at or under 100 ms passes, above that goes to the acceptance judge". A paragraph of
    /// Chinese text is pasted into Chapter 5 of the twelve-chapter book (through the pasteboard), then Chapter 5 with all its
    /// sub-sections is Option-dragged before Chapter 3 (chapters 3 and 4 are flat, so the three cards are on screen together). RECORDED,
    /// NOT ASSERTED: the editor's `jsMs total`, with the counts of the document, and the time from the editor's reply to the job's
    /// reservation (the reply turn that swaps the sidebar; production writes no separate number for the swap itself). Asserted: the order
    /// in the three places, the Chinese text intact once, footnotes consistent, the mechanism. The screen-equals-database round trip (Save
    /// Version) is skipped on this size, as in the other twelve-chapter tests; the paragraph is looked for on screen instead (printed).
    func testReorderEFBook12CJKTiming() {
        let size = Phase4bDelSize.book12
        let moved = Self.rqChapter(5)
        let target = Self.rqChapter(3)
        let seeded = "5.6 Conclusion"
        let cjk = "账簿与灯笼：村庄登记册记录了市场上的价格与桥梁的故事。"
        guard rqStart(size, method: #function, flat: [3, 4], extra: { Self.withDupLines($0, under: seeded) }),
              rqRequire([moved, target, seeded]), requireDupLines(under: seeded) != nil,
              rqPlaceCaret(inSectionCard: seeded, line: Self.dupLineTwo, prefix: Self.dupTwoPrefix) else { return }
        app.typeKey(.return, modifierFlags: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cjk, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        let pasted = waitForSentenceInDatabase(cjk, timeout: 90)
        assertCheck(pasted, "the pasted Chinese paragraph reached the database")
        _ = settle()
        let rows = rqMoving(rqUserRows(), moved, before: target)
        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-book12-cjk-after-the-drop")
        let traces = traceLines(from: dragFrom).filter { $0.family == .sequence && $0.label == "sectionReorder" }
        let jsLine = traces.first { $0.step.hasPrefix("after the editor-first JS call") }
        let reservedLine = traces.first { $0.step.hasPrefix("after the job reserved") }
        let jsMs = editorFirstOkLines("reorder", from: dragFrom).compactMap { Phase4bDelTypingParser.intAfter("jsMs total=", in: $0) }
        var replyTurn: Int?
        if let jsLine, let reservedLine { replyTurn = reservedLine.since - jsLine.since }
        attachText("sectionReorder-trace-\(methodName).txt", traces.map { "+\($0.since)ms \($0.step)" }.joined(separator: "\n"))
        result("JS GATE (judge call 1): the editor's reorder turn took jsMs total \(jsMs) ms on the twelve-chapter book (\(restoreCounts); "
            + "the pasted paragraph is \(cjk.count) Chinese characters). At or under 100 ms passes; above goes to the acceptance judge: "
            + "\(jsMs.first.map { $0 <= 100 ? "PASSES" : "ABOVE 100 ms: GOES TO THE ACCEPTANCE JUDGE" } ?? "NOT MEASURED"). Not asserted here")
        result("REPLY TURN (judge item C8): from the editor's reply to the job's reservation \(replyTurn.map { "\($0) ms" } ?? "n/a") "
            + "(the sidebar swap happens inside this turn; production writes no separate number for it). Not asserted here")
        var soft = Phase4bFlowSoftChecks()
        soft.check(!jsMs.isEmpty, "the editor wrote no `jsMs total` figure: the gate could not be read")
        rqCheckOrder("after the drag on book12", expected: rqHeadings(rows), to: &soft)
        rqCheckOptionCarried(moved, expected: rqHeadings(rows), what: "after the drag on book12", to: &soft)
        soft.check(blocksContaining(cjk) == 1, "the Chinese paragraph is in \(blocksContaining(cjk)) row(s) of the database after the drag, "
            + "expected exactly 1 (intact)")
        let post = readRows()
        let walk = Phase4bFlowWalk(rows: post)
        soft.check(walk.problems.isEmpty, "footnotes after the drag: \(walk.problems.prefix(3))")
        addReorderMechanismChecks(from: dragFrom, drags: 1, to: &soft)
        addLogChecks(from: dragFrom, to: &soft)
        addTypedLineOnScreenCheck(line: Self.dupLineTwo, marker: String(cjk.prefix(8)), requireIt: false, to: &soft)
        assertSoft(soft, "CJK paragraph, Option-drag, jsMs recorded, on book12")
    }
}

// MARK: - E11 Drag, type in the moved chapter, Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// The order of the three places and the typed word after one press, printed ("original", "moved" or "other" order).
    func rqRecordState(_ label: String, original: [String], moved: [String], marker: String) -> String {
        let order = headingFragmentsInDatabase()
        let kind = order == original ? "original" : (order == moved ? "moved" : "other")
        let present = blocksContaining(marker) > 0
        result("STATE after \(label): heading order \(kind); the typed word is \(present ? "present" : "gone") in the database")
        return kind
    }

    /// "Drag, type in the moved chapter, then Cmd-Z, Cmd-Z, Cmd-Shift-Z, Cmd-Shift-Z." Chapter 4 is Option-dragged before Chapter 3; a word
    /// is typed at the end of a seeded line of Chapter 4 (the sidebar's navigation to "4.6 Conclusion", then the line). Cmd-Z #1 is a text
    /// step (the word goes), Cmd-Z #2 the reorder's undo (the original order), Cmd-Shift-Z #1 the reorder's redo (the moved order again),
    /// Cmd-Shift-Z #2 whatever redo is left (the word may or may not come back; printed). After each press the block table, the sidebar
    /// and the editor agree on the order, and the end state equals the database.
    func testReorderEFTypeInMovedThenUndoTwice_book6() {
        let moved = Self.rqChapter(4)
        let target = Self.rqChapter(3)
        let seeded = "4.6 Conclusion"
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6, extra: { Self.withDupLines($0, under: seeded) }),
              rqRequire([moved, target, seeded]), requireDupLines(under: seeded) != nil,
              let dupTwo = pre.firstIndex(where: { $0.fragment == Self.dupLineTwo }),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine) else { return }
        let original = rqUserRows()
        let reordered = rqMoving(original, moved, before: target)
        let originalHeadings = rqHeadings(original)
        let movedHeadings = rqHeadings(reordered)
        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        guard rqPlaceCaret(inSectionCard: seeded, line: Self.dupLineTwo, prefix: Self.dupTwoPrefix) else { return }
        typeNow(" " + Self.rqSecond)
        let landed = waitForSentenceInDatabase(Self.rqSecond, timeout: 90)
        _ = settle()
        var soft = Phase4bFlowSoftChecks()
        soft.check(landed, "the word typed into the moved chapter reached the database")
        rqCheckOrder("after the drag and the typing in the moved chapter", expected: movedHeadings, to: &soft)
        rqCheckOptionCarried(moved, expected: movedHeadings, what: "after the drag", to: &soft)

        let undoFrom = tail.lines.count
        var presses: [UndoPress] = []
        presses.append(rqPressStep(redo: false, number: 1))
        _ = settle()
        soft.check(rqRecordState("Cmd-Z #1", original: originalHeadings, moved: movedHeadings, marker: Self.rqSecond) == "moved",
                   "Cmd-Z #1 changed the heading order: it should only take the typed word away")
        soft.check(blocksContaining(Self.rqSecond) == 0, "Cmd-Z #1 did not take the typed word away")
        rqCheckOrder("after Cmd-Z #1", expected: movedHeadings, to: &soft)
        presses.append(rqPressStep(redo: false, number: 2))
        _ = settle()
        soft.check(rqRecordState("Cmd-Z #2", original: originalHeadings, moved: movedHeadings, marker: Self.rqSecond) == "original",
                   "Cmd-Z #2 did not bring the original heading order back")
        rqCheckOrder("after Cmd-Z #2", expected: originalHeadings, to: &soft)
        let redoFrom = tail.lines.count
        presses.append(rqPressStep(redo: true, number: 3))
        _ = settle()
        soft.check(rqRecordState("Cmd-Shift-Z #1", original: originalHeadings, moved: movedHeadings, marker: Self.rqSecond) == "moved",
                   "Cmd-Shift-Z #1 did not bring the moved heading order back")
        rqCheckOrder("after Cmd-Shift-Z #1", expected: movedHeadings, to: &soft)
        presses.append(rqPressStep(redo: true, number: 4))
        _ = settle()
        _ = rqRecordState("Cmd-Shift-Z #2", original: originalHeadings, moved: movedHeadings, marker: Self.rqSecond)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-type-in-moved-book6-after-the-last-press")
        rqCheckOrder("after Cmd-Shift-Z #2", expected: movedHeadings, to: &soft)

        let decisions = presses.map(\.decision)
        result("THE FOUR PRESSES: the editor decided \(decisions)")
        soft.check(decisions.first == "fallthrough", "Cmd-Z #1 was decided \(decisions.first ?? "none"), expected a text step (fallthrough)")
        let undoDecision = presses.count > 1 ? presses[1].decision : "none"
        let redoDecision = presses.count > 2 ? presses[2].decision : "none"
        soft.check(presses.count == 4 && presses[1].structural, "Cmd-Z #2 did not run a structural undo (decided \(undoDecision))")
        soft.check(presses.count == 4 && presses[2].structural, "Cmd-Shift-Z #1 did not run a structural redo (decided \(redoDecision))")
        soft.check(presses.allSatisfy { $0.refusals.isEmpty }, "a press was refused: \(presses.flatMap(\.refusals).prefix(1))")
        let typedKept = blocksContaining(Self.rqSecond) > 0
        let typed = typedKept ? [dupTwo: Self.dupLineTwo + " " + Self.rqSecond] : [:]
        let post = addRowChecks("after the four presses", expectedUser: rqRows(reordered, typed: typed), managed: nil, to: &soft)
        addReorderMechanismChecks(from: dragFrom, drags: 1, to: &soft)
        addSlowUndoMechanismChecks("undo", from: undoFrom, to: &soft)
        addSlowUndoMechanismChecks("redo", from: redoFrom, to: &soft)
        addLogChecks(from: dragFrom, handedToTextUndo: decisions.filter { $0 == "fallthrough" }.count, checkBeeps: false, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the four presses", to: &soft)
        assertSoft(soft, "drag, type in the moved chapter, Cmd-Z twice, Cmd-Shift-Z twice, on book6")
    }
}

// MARK: - W12 Two on-screen sections below the caret swapped

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// The editor's text leaves with exactly `lines` as their value: how many there are, and the frame of the first one, against the editor's
    /// own frame (what a failed set-up prints, so the next run needs no diagnosis).
    func rqLeafReport(_ lines: [String]) -> String {
        let parts = lines.map { line -> String in
            let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", line))
            let count = leaves.count
            let frame = count > 0 ? Self.describeFrame(leaves.element(boundBy: 0).frame) : "none"
            return "\"\(line.prefix(14))...\" \(count) leaf(s), first \(frame)"
        }
        return "editor \(Self.describeFrame(app.editorArea.frame)); " + parts.joined(separator: "; ")
    }

    /// The top of each of `lines` on screen (each leaf fully inside the editor's visible band), or nil when they are not all there within
    /// `timeout` (a bounded wait: the leaves are looked for over and over, never once). Fails nothing.
    func rqOnScreenHeights(_ lines: [String], timeout: TimeInterval) -> [CGFloat]? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            var heights: [CGFloat] = []
            for line in lines {
                guard let leaf = visibleLeaf(line, timeout: 3) else { break }
                heights.append(leaf.frame.minY)
            }
            if heights.count == lines.count { return heights }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < deadline
        return nil
    }

    /// The judge's W12 (a stale frame would show): two short sections ("SwapOne section" and "SwapTwo section", one line each) sit on screen
    /// right below the caret line (Anchor01, the first line of the book: the caret line and the two swap lines are the first three paragraphs
    /// under the chapter heading, so they are on the editor's first screen together). SwapTwo is dragged above SwapOne (dropped in the
    /// level-2 zone of the Chapter 1 card, so it stays an H2). Pictures are attached before and after. The editor must show SwapTwo's line
    /// above SwapOne's now, and the caret line must be at the SAME screen height as before (within 3 pt): the viewport guarantee of the range
    /// move; nothing stale is painted. Set-up: the three lines are waited for on screen (bounded); when they are not, Cmd-Up takes the editor
    /// to its top, the caret is placed again and they are waited for once more; when they still are not, the failure prints the editor's
    /// frame and each line's frame.
    func testReorderEFSwapOnScreenBelowCaret_book6() {
        let one = "SwapOne section"
        let two = "SwapTwo section"
        let caretLine = "Anchor01 line of the fixture document."
        let lines = [caretLine, "SwapOne line of the fixture document.", "SwapTwo line of the fixture document."]
        guard rqStart(.book6, method: #function, flat: Self.rqFlatBook6, extra: Self.rqWithSwapSections),
              rqRequire([one, two, Self.rqChapter(1)]), pre.contains(where: { $0.fragment == caretLine }),
              placeCaretAtAnchorEnd(paragraph: "Anchor01", exactLine: caretLine) else { return }
        var heights = rqOnScreenHeights(lines, timeout: 30)
        if heights == nil {
            note("SET-UP RETRY: the three lines are not all on screen (\(rqLeafReport(lines))); "
                + "Cmd-Up to the top of the editor, the caret placed again")
            app.typeKey(.upArrow, modifierFlags: .command)
            guard placeCaretAtAnchorEnd(paragraph: "Anchor01", exactLine: caretLine) else { return }
            heights = rqOnScreenHeights(lines, timeout: 45)
        }
        guard let start = heights else {
            attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-swap-book6-0-setup-failed")
            fail("TEST-SETUP: the caret line and the two swap lines are not all on screen before the drag (\(rqLeafReport(lines)))")
            return
        }
        let before = (caret: start[0], one: start[1], two: start[2])
        note("SET-UP: the caret line, SwapOne's line and SwapTwo's line are on screen together at \(before) (\(rqLeafReport(lines)))")
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-swap-book6-1-before")
        let rows = rqMoving(rqUserRows(), two, before: one)
        guard let dragFrom = rqDragBefore(two, before: one, level: 2, option: false, dropY: 0.5),
              waitForReorderPerformed(from: dragFrom) else { return }
        _ = settle()
        let after = rqOnScreenHeights(lines, timeout: 45)
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-swap-book6-2-after")
        result("SCREEN HEIGHTS (minY of the lines, before -> after): "
            + "caret line \(before.caret) -> \(after.map { String(describing: $0[0]) } ?? "not on screen"); "
            + "SwapOne \(before.one) -> \(after.map { String(describing: $0[1]) } ?? "not on screen"); "
            + "SwapTwo \(before.two) -> \(after.map { String(describing: $0[2]) } ?? "not on screen")")
        var soft = Phase4bFlowSoftChecks()
        soft.check(before.one < before.two, "TEST-SETUP: SwapOne's line was not above SwapTwo's before the drag")
        if let after {
            soft.check(after[2] < after[1], "the editor still shows SwapOne's line above SwapTwo's after the drag (a stale frame)")
            soft.check(abs(after[0] - before.caret) <= 3, "the caret line moved from \(before.caret) to \(after[0]): the viewport jumped")
        } else {
            soft.check(false, "the caret line or a swap line is not on screen after the drag (\(rqLeafReport(lines)))")
        }
        let post = rqChecks("after the swap", from: dragFrom, drags: 1, rows: rows, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the swap", to: &soft)
        assertSoft(soft, "two on-screen sections below the caret swapped, on book6")
    }
}

// MARK: - User step 4: drag, then at once Delete Section, then Cmd-Z

extension WriteQueuePhase4bStructuralQueueE2ETests {
    /// User step 4: "Option-drag a chapter above another, then straight away Delete Section on a third chapter, then press Cmd-Z." Chapter 4
    /// is Option-dragged before Chapter 3; the next thing done, with NOTHING awaited (not even the reorder's `performed` line), is Delete
    /// Section on the flat Chapter 5 from its card's context menu; the first job (the reorder's) is held 3.9 s, so the delete meets it pending
    /// (`addHoldWindowCheck` proves from the app's clock that it did, a TEST-SETUP failure otherwise); then Cmd-Z. The delete's undo is
    /// QUICK (its sequence began `start (quick`, no `swap opId=` line, no "Undoing..." notice); Chapter 5 is back; Chapter 4 is still before
    /// Chapter 3 in the block table, the sidebar and the editor; the reorder's mechanism lines are present; screen equals database.
    /// Set-up: so that Chapter 5's card is on screen together with the cards of the drag (a delete "at once" has no time to scroll), Chapter
    /// 4 keeps only its section 4.1 (a subtree of two cards: with three-card chapters the seven cards would not fit the sidebar's band), and
    /// chapters 1, 3, 5 and 6 are flat as in the other tests; the cards of the drag and the delete are brought into the visible band
    /// before the drag. On the base code the drag bumps the structural generation, so the delete's undo is slow.
    func testReorderEFDragThenDeleteThenUndo_book6() {
        let moved = Self.rqChapter(4)
        let target = Self.rqChapter(3)
        let deleted = Self.rqChapter(5)
        let predecessor = "2.6 Conclusion"
        guard rqStart(.book6, method: #function, env: Self.firstJobHoldEnv, flat: [1, 3, 4, 5, 6], keeping: ["4.1 "]),
              rqRequire([moved, target, deleted, predecessor, "4.1 Ledgers and Their Keepers"]),
              placeCaretAtAnchorEnd(paragraph: Phase4bDelHarness.anchorPrefix, exactLine: Self.anchorLine),
              let cards = rqBringIntoView([moved, predecessor, deleted]) else { return }
        let deleteCard = cards[2]
        let original = rqUserRows()
        let reordered = rqMoving(original, moved, before: target)
        let afterDelete = rqWithout(reordered, section: deleted)
        var soft = Phase4bFlowSoftChecks()

        guard let dragFrom = rqDragBefore(moved, before: target, level: 1, option: true, dropY: 0.5) else { return }
        // At once: the next command is given the moment the drop is made.
        let deleteFrom = chooseSidebarItem(deleteCard, item: "Delete Section", activate: false)
        expectPerformed("sectionDelete", from: deleteFrom, "the delete reached its performed line", slow: true)
        guard waitForReorderPerformed(from: dragFrom) else { return }
        let gone = settle(gone: [deleted])
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-drag-delete-book6-1-after-the-delete")
        addHoldWindowCheck(firstFrom: dragFrom, secondFrom: deleteFrom, to: &soft)
        soft.check(gone, "\"\(deleted)\" is gone from the block table once the delete has settled")
        rqCheckOrder("after the drag and the delete", expected: rqHeadings(afterDelete), to: &soft)
        rqCheckOptionCarried(moved, expected: rqHeadings(afterDelete), what: "after the drag and the delete", to: &soft)
        addRowChecks("after the drag and the delete", expectedUser: rqRows(afterDelete), managed: nil, to: &soft)

        // Cmd-Z: the delete's undo.
        guard let undoFrom = pressUndoReachingTheEditor() else { return }
        expectPerformed("undo", from: undoFrom, "the Cmd-Z of the delete reached its performed line", slow: true)
        let back = settle(back: [deleted])
        attachEvidenceScreenshot(app.screenshot(), name: "reorder-ef-drag-delete-book6-2-after-cmd-z")
        let runs = quickRuns(from: undoFrom, label: "undo")
        let starts = traceLines(from: undoFrom).filter { $0.family == .sequence && $0.label == "undo" && $0.isOpStart }
        result("THE DELETE'S UNDO: sequence start line(s) \(starts.map(\.step)); paths \(Self.describePaths(runs)); "
            + "`swap opId=` lines \(swapLineCount(from: undoFrom)); "
            + "\"Undoing\" notices \(undoingToastCount(from: undoFrom)); \(restoreCounts)")
        soft.check(back, "\"\(deleted)\" is back in the block table and the document is quiet")
        soft.check(starts.count == 1 && starts[0].step.hasPrefix("start (quick"),
                   "the delete's undo did not take the QUICK road (start lines \(starts.map(\.step))): "
                       + "the reorder closed the quick road of the delete")
        soft.check(runs.count == 1 && runs[0].quick, "the delete's undo ran \(Self.describePaths(runs)), expected one quick undo")
        soft.check(swapLineCount(from: undoFrom) == 0,
                   "\(swapLineCount(from: undoFrom)) `swap opId=` line(s) from the delete's undo on: the slow road")
        soft.check(undoingToastCount(from: undoFrom) == 0, "the delete's undo showed the \"Undoing...\" notice")
        let post = rqChecks("after the drag, the delete and Cmd-Z", from: dragFrom, drags: 1, rows: reordered, plainPushes: false, to: &soft)
        addOperationMechanismChecks(from: dragFrom, duplicates: 0, deletes: 1, to: &soft)
        addScreenEqualsDatabaseCheck(before: post, what: "after the drag, the delete and Cmd-Z", to: &soft)
        assertSoft(soft, "Option-drag, Delete Section at once, Cmd-Z (the delete's undo is quick), on book6")
    }
}
// swiftlint:enable cyclomatic_complexity
