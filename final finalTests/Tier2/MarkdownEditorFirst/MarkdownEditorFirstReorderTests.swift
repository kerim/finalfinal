//
//  MarkdownEditorFirstReorderTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder in Markdown mode), round 1: the PIN
//  that the settle which already exists renumbers the footnotes after a Markdown reorder. It runs against the REAL CodeMirror page, a real
//  database and the real writer (`MarkdownClickRig`), and it changes no product code. Needs `cd web && pnpm build` first. NOT RUN by the
//  coder: the driver builds and runs every Swift test.
//
//  WHY IT IS A PIN. A move changes the ORDER of the footnote references in the text but not which labels there are. The settle's footnote
//  resync would renumber them back into 1..N, which ends in the very list the footnote service last committed
//  (`lastRenumberedHash`), so `performFootnoteUpdate` returns at its `contentHash != lastRenumberedHash` guard and neither the references
//  nor the Notes are renumbered, for good. The footnote resync of a reorder's settle therefore forgets the committed hash itself, for
//  `.sectionReorder` only (t-f1a22aa7, Phase 4c, FIX-E / FIX-G: `resyncAfterEditorFirstDelete(forgetsCommittedNotes:)` in
//  StructuralUndoController+EditorFirstDelete.swift passes `forgetCommittedHash:` to `FootnoteSyncService.resyncNow`, which forgets after
//  its idle wait and just before it writes). It used to be forgotten by `settleReorderOverlay`, the first step of the settle. That settle
//  is shared by Rich Text and Markdown (`ReorderFootnoteSettleTests` pins the Rich Text half with a scripted editor); this pins the
//  Markdown half: the renumber reaches the CodeMirror page through the coordinator's `.renumberFootnotes` observer, and the Notes rows
//  follow the text.
//
//  THE STAGING. The footnote service is PRIMED first, as it always is by the time a user drags (an earlier resync has committed the
//  hash of 1..9). Only then are the rows and the page put into the state a drag leaves: three chapters whose references read 1-3, 7-9,
//  4-6 in reading order, the Notes section untouched (a move rewrites no Notes row and no Notes line). The rows are moved with the
//  job's own renumbering (`ProjectDatabase.reorderAllBlocks`); the page by its application-origin push; the content record by the click's
//  own adopt (`adoptMarkdownPageText`).
//
//  WHAT THE PAGE'S NOTES LOOK LIKE. The page's own renumber renames every `[^N]` in the document, definitions included, so the page's
//  Notes lines carry the right numbers and the right text. Review round (V1): during a structural settle the renumber ALSO SORTS the
//  Notes definitions in the same transaction (Swift hands the page the Notes heading line with the settle flag, `markMarkdownSettle`;
//  web/codemirror/src/notes-region-sort.ts), so the page's Notes are checked for "every definition exactly once, in numeric order, each
//  with its reference's text", and the database rows the same way. (Before the page sorted, only the rows' order could be checked here:
//  putting the page's lines in order was the Notes rebuild's job, and this rig has no ContentView.)
//
//  Break patch (a 1-5 line change in production code that must make the test fail), and the failure it shows:
//
//   T-U11a  BREAK (BP-G, t-f1a22aa7 FIX-G): in `FootnoteSyncService.resyncNow` (Services/FootnoteSyncService.swift) delete the line
//                  `if forgetCommittedHash { forgetCommittedNotesState() }`.
//           FAILS: "footnote references out of order: [1, 2, 3, 7, 8, 9, 4, 5, 6]" (the resync is skipped at the hash guard, so the page
//                  keeps the moved order; the Notes rows also stay in their old order, "Notes row 4 ...").
//                  (Before Phase 4c the forget sat in `settleReorderOverlay`, StructuralUndoController+EditorFirstDelete.swift.)
//
//  ROUND 3a (the Swift click, `performMarkdownEditorFirstReorder`) adds the tests below. They drive a real drag through
//  `performSectionReorderDetailed` against the real page, rows and writer. Break patches (a 1-5 line change in production code):
//
//   T-R1   testAMarkdownDragMovesThePageThenTheRowsLiftsTheOverlayAndReleasesTheHold
//          BREAK: in `startEditorFirstReorderJob` remove the two `notifyMarkdownJobEnded` calls.   FAILS: "hold still up after settle".
//   T-U11  testAMarkdownDragRenumbersTheFootnotesOfAPrimedDocument
//          BREAK (BP-G): delete `if forgetCommittedHash { forgetCommittedNotesState() }` in `FootnoteSyncService.resyncNow`.
//          FAILS: "footnote references out of order: [1, 2, 3, 7, 8, 9, 4, 5, 6]".
//   T-FH1  testTheDragsSettleRunsAsAReorderAndForgetsTheFootnoteHash
//          BREAK A (BP-E, the old forget site back): re-add `footnoteSyncService?.forgetCommittedNotesState()` at the end of
//          `settleReorderOverlay` (and pass `forgetCommittedHash: false` in `resyncAfterEditorFirstDelete`).
//          FAILS: "the settle forgot the footnote hash before its flag (the old site)".
//          BREAK B: in `startEditorFirstReorderJob` pass `kind: .sectionDelete` to `editorFirstJobSettled`.
//          FAILS: "footnote references out of order" (and "the settle did not lift the reorder overlay").
//   T-R2   testTypingJustBeforeADragIsSavedWithItAndNothingIsPushedBack
//          BREAK: in `markdownReorderReplyTurn` do not call `writer.prepareStructuralClick`.   FAILS: "typed text missing from rows".
//   T-R13  testALevelOnlyDropTakesTheEditorFirstRoad
//          BREAK: in `runMarkdownEditorFirstReorder` return nil when the plan's order equals the sidebar's.
//          FAILS: "editor-first road not taken for a level-only drop".
//   T-R16  testADragRightAfterADeleteKeepsItsOwnRebuildStampAndPendingCount
//          BREAK: in `runMarkdownEditorFirstReorder` delete the `editorState.pendingEditorFirstJobs += 1` line.
//          FAILS: "pending count 0 while the drag's job is unapplied".
//

import Foundation
import GRDB
import XCTest
@testable import final_final

@MainActor
final class MarkdownEditorFirstReorderTests: XCTestCase {

    var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    // MARK: - The document

    static let labelCount = 9

    /// A chapter whose paragraphs each carry one reference, in the order of `labels`.
    private static func chapter(_ title: String, _ labels: [Int]) -> String {
        (["# \(title)"] + labels.map { "Claim \($0) rests on a source[^\($0)]." }).joined(separator: "\n\n")
    }

    /// The Notes section: definition k is "Note k text." One per number, in numeric order.
    private static var notesSection: String {
        (["# Notes"] + (1...labelCount).map { "[^\($0)]: Note \($0) text." }).joined(separator: "\n\n")
    }

    private static let first = [1, 2, 3]
    private static let second = [4, 5, 6]
    private static let third = [7, 8, 9]

    /// Chapters in reading order, references 1..9, the Notes in the same order.
    static var original: String {
        [chapter("Chapter One", first), chapter("Chapter Two", second), chapter("Chapter Three", third), notesSection]
            .joined(separator: "\n\n")
    }

    /// What a drag of Chapter Three above Chapter Two leaves: the references read 1-3, 7-9, 4-6; the Notes are as they were.
    static var moved: String {
        [chapter("Chapter One", first), chapter("Chapter Three", third), chapter("Chapter Two", second), notesSection]
            .joined(separator: "\n\n")
    }

    /// The labels in reading order after the move.
    static var movedLabels: [String] { (first + third + second).map(String.init) }
    static var sequentialLabels: [String] { (1...labelCount).map(String.init) }

    // MARK: - Reading the result

    /// The Notes definition rows of the database in document order.
    func noteFragments() throws -> [String] {
        try rig.db.fetchBlocks(projectId: rig.pid)
            .filter { $0.isNotes && $0.blockType != .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.markdownFragment)
    }

    /// Every definition line of the page (a line that starts `[^N]: `), in the order the page holds them. A reference inside a paragraph
    /// never starts a line, so these are the Notes definitions and nothing else.
    static func definitionLines(in text: String) -> [(label: String, text: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("[^"), let close = line.range(of: "]: ") else { return nil }
            let label = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            return (label, String(line[close.upperBound...]))
        }
    }

    // MARK: - T-U11a

    // The settle after a Markdown reorder of Chapter Three above Chapter Two (nine footnotes, three per chapter). The footnote service has
    // committed 1..9 for the unmoved document; the page and the rows now read 1-3, 7-9, 4-6. The settle must make the service renumber:
    // the page's references read 1..9 again, and the Notes definitions follow their references (the note that was labelled 7 is now
    // labelled 4), each exactly once, in numeric order in the rows.
    func testMarkdownReorderSettleRenumbersFootnotes() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.original, observesPage: true)
        self.rig = rig
        rig.installReparseHost()   // the settle reads the page's live text through the host, as in the app
        rig.coordinator?.webView = rig.helper.webView   // the coordinator sends the service's renumber to this page
        rig.footnotes.systemWriter = SystemWriter(blockSync: rig.writerRig.sync)   // the service writes through the queue, as in the app

        // (1) PRIME the service: one resync of the UNMOVED document, references 1..9 in order. Without this the hash is 0 and the guard
        // never meets the move (the unit rig of the other tests never saw the defect for exactly that reason).
        await rig.footnotes.resyncNow(footnoteRefs: Self.sequentialLabels, projectId: rig.pid, fullContent: Self.original)
        guard rig.footnotes.lastRenumberedHash != 0 else {
            XCTFail("premise: the priming resync committed no hash (lastRenumberedHash is still 0), so the guard this test pins is not armed")
            return
        }
        XCTAssertEqual(rig.footnotes.lastKnownRefs, Self.sequentialLabels, "premise: the service has committed 1..\(Self.labelCount)")
        let notesBefore = try noteFragments()
        XCTAssertEqual(notesBefore.count, Self.labelCount, "premise: one Notes row per number before the move")
        XCTAssertTrue(notesBefore.first?.hasPrefix("[^1]: Note 1 text.") == true, "premise: the Notes start in the original order")

        // (2) The state a drag leaves. The rows: the job's own renumbering puts Chapter Three before Chapter Two (Notes stay last).
        let one = try rig.section("Chapter One")
        let two = try rig.section("Chapter Two")
        let three = try rig.section("Chapter Three")
        let projectId = rig.pid
        try rig.db.write { database in
            try ProjectDatabase.reorderAllBlocks(
                db: database, leaderIds: [one.id, three.id, two.id], projectId: projectId, levels: [:])
        }
        // The page: the editor-first click moved the text; the content record takes the page's text in the click's own turn.
        try await rig.type(Self.moved)
        let movedPage = try await rig.pageText()
        rig.editorState.adoptMarkdownPageText(movedPage)
        XCTAssertEqual(
            FootnoteSyncService.extractFootnoteRefs(from: movedPage), Self.movedLabels,
            "premise: the page reads its references 1-3, 7-9, 4-6")
        XCTAssertEqual(
            FootnoteSyncService.extractFootnoteRefs(from: rig.editorState.content), Self.movedLabels,
            "premise: the content record holds the moved text")
        let storedAfterMove = try rig.writerRig.storedText()
        XCTAssertEqual(
            FootnoteSyncService.extractFootnoteRefs(from: storedAfterMove), Self.movedLabels, "premise: the rows hold the moved order")
        let notesAfterMove = try noteFragments()
        XCTAssertEqual(notesAfterMove, notesBefore, "premise: a move rewrites no Notes row")

        // (3) The entry and its job slot, as the click registers them, then the settle of the reorder's job.
        let opId = UUID()
        rig.controller.efOpEpoch[opId] = 1
        rig.controller.efSlots.open(opId)
        rig.controller.efEditorKind[opId] = .markdown
        rig.unifiedUndo.record(StructuralEntry(id: opId, kind: .sectionReorder, title: "Reorder Sections", undoSnapshotId: nil))
        defer { rig.controller.efSlots.remove(opId) }

        await rig.controller.editorFirstJobSettled(opId: opId, outcome: .applied, removedLeaders: [], kind: .sectionReorder)

        // (4) The renumber reaches the page through the coordinator's observer and the page's own FIFO: wait for it (bounded).
        let page = try await rig.waitForPage { FootnoteSyncService.extractFootnoteRefs(from: $0) == Self.sequentialLabels }
        let pageRefs = FootnoteSyncService.extractFootnoteRefs(from: page)
        XCTAssertEqual(
            pageRefs, Self.sequentialLabels,
            "footnote references out of order: [\(pageRefs.joined(separator: ", "))] (wanted 1 to \(Self.labelCount) in reading order)")

        // The page's Notes: every definition exactly once, each carrying the text of the reference it belongs to.
        let definitions = Self.definitionLines(in: page)
        let labels = definitions.map(\.label)
        XCTAssertEqual(
            labels, Self.sequentialLabels, "the page's Notes do not hold each definition exactly once, in numeric order: \(labels)")
        let textByLabel = Dictionary(definitions.map { ($0.label, $0.text) }, uniquingKeysWith: { first, _ in first })
        for (index, old) in Self.movedLabels.enumerated() {
            XCTAssertEqual(
                textByLabel["\(index + 1)"], "Note \(old) text.",
                "the page's definition [^\(index + 1)] should be the note that was labelled \(old)")
        }

        // The rows: the Notes definitions follow the text, one per number, in numeric order.
        let fragments = try noteFragments()
        XCTAssertEqual(fragments.count, Self.labelCount, "\(fragments.count) Notes rows instead of \(Self.labelCount)")
        for (index, old) in Self.movedLabels.enumerated() where index < fragments.count {
            let fragment = fragments[index]
            let wanted = "[^\(index + 1)]:"
            XCTAssertTrue(
                fragment.hasPrefix(wanted) && fragment.contains("Note \(old) text."),
                "Notes row \(index + 1) should be '\(wanted) Note \(old) text.', it is '\(fragment)'")
        }
        XCTAssertEqual(rig.footnotes.lastKnownRefs, Self.sequentialLabels, "the service does not hold 1..\(Self.labelCount) afterwards")
    }
}

// The round 3a tests are an extension of the class above (the same fixture and helpers) so that the class body stays under SwiftLint's
// type_body_length limit.
extension MarkdownEditorFirstReorderTests {

    // MARK: - Round 3a: the click (driving a drag)

    static let book3 = "# Alpha\n\nAlpha body.\n\n# Bravo\n\nBravo body.\n\n# Charlie\n\nCharlie body."
    static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    /// The request the sidebar sends when the card titled `title` is dropped right after the card titled `target` (nil: at the very top)
    /// and the pre-gate plan worked out against the list the sidebar shows now. `level`: the heading level the drop gives the card;
    /// `parentTitle`: the card it becomes a sub-section of.
    func dropRequest(
        _ title: String, after target: String?, level: Int? = nil, asChildOf parentTitle: String? = nil
    ) throws -> (plan: [SectionViewModel], request: SectionReorderRequest) {
        let cards = rig.editorState.sections
        let moved = try XCTUnwrap(cards.first { $0.title == title }, "no card titled \(title): \(cards.map(\.title))")
        let after = try target.map { name in try XCTUnwrap(cards.first { $0.title == name }, "no card titled \(name): \(cards.map(\.title))") }
        let parent = try parentTitle.map { name in try XCTUnwrap(cards.first { $0.title == name }, "no card titled \(name): \(cards.map(\.title))") }
        let request = SectionReorderRequest(
            sectionId: moved.id, targetSectionId: after?.id, newLevel: level ?? moved.headerLevel,
            newParentId: parent?.id ?? after?.parentId)
        var plan = cards
        if case .plan(let planned) = SectionReorderPlanner.plan(request: request, in: cards, syncService: rig.sectionSync) { plan = planned }
        return (plan, request)
    }

    /// A drop, as `ContentView.dispatchSectionReorder` makes it: the controller plans again under its structural gate.
    @discardableResult
    func drop(
        _ title: String, after target: String?, level: Int? = nil, asChildOf parentTitle: String? = nil
    ) async throws -> (outcome: StructuralUndoController.StructuralOpOutcome, editorFirst: Bool) {
        let (plan, request) = try dropRequest(title, after: target, level: level, asChildOf: parentTitle)
        return await rig.controller.performSectionReorderDetailed(sections: plan, request: request)
    }

    /// The non-empty lines of a Markdown text (blank lines carry no content): what the page and the rows are compared by.
    static func contentLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func pageContentLines() async throws -> [String] {
        Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText()))
    }

    /// A rig on the nine-footnote document with everything a drag's settle needs: the host the settle reads the page through, the
    /// coordinator that carries the footnote service's renumber to the page, the service's queue, and the service PRIMED (an earlier resync
    /// has committed 1..9, as it always has by the time a user drags).
    func makePrimedRig(routesUndo: Bool = false) async throws -> MarkdownClickRig {
        let rig = try await MarkdownClickRig(markdown: Self.original, observesPage: true, routesUndo: routesUndo)
        self.rig = rig
        rig.installReparseHost()
        rig.coordinator?.webView = rig.helper.webView
        rig.footnotes.systemWriter = SystemWriter(blockSync: rig.writerRig.sync)
        await rig.footnotes.resyncNow(footnoteRefs: Self.sequentialLabels, projectId: rig.pid, fullContent: Self.original)
        return rig
    }

    /// The page's references read 1..9, its Notes hold each definition once with the text of the note that was labelled differently
    /// before the move, and the Notes ROWS follow the text, one per number, in numeric order (T-U11a's checks).
    func assertFootnotesRenumbered(page: String) throws {
        let pageRefs = FootnoteSyncService.extractFootnoteRefs(from: page)
        XCTAssertEqual(
            pageRefs, Self.sequentialLabels,
            "footnote references out of order: [\(pageRefs.joined(separator: ", "))] (wanted 1 to \(Self.labelCount) in reading order)")
        let definitions = Self.definitionLines(in: page)
        let labels = definitions.map(\.label)
        XCTAssertEqual(
            labels, Self.sequentialLabels, "the page's Notes do not hold each definition exactly once, in numeric order: \(labels)")
        let textByLabel = Dictionary(definitions.map { ($0.label, $0.text) }, uniquingKeysWith: { first, _ in first })
        for (index, old) in Self.movedLabels.enumerated() {
            XCTAssertEqual(
                textByLabel["\(index + 1)"], "Note \(old) text.",
                "the page's definition [^\(index + 1)] should be the note that was labelled \(old)")
        }
        let fragments = try noteFragments()
        XCTAssertEqual(fragments.count, Self.labelCount, "\(fragments.count) Notes rows instead of \(Self.labelCount)")
        for (index, old) in Self.movedLabels.enumerated() where index < fragments.count {
            let fragment = fragments[index]
            let wanted = "[^\(index + 1)]:"
            XCTAssertTrue(
                fragment.hasPrefix(wanted) && fragment.contains("Note \(old) text."),
                "Notes row \(index + 1) should be '\(wanted) Note \(old) text.', it is '\(fragment)'")
        }
    }

    // MARK: - T-R1: a drag end to end

    // A drag in Markdown mode through the real entry point (`performSectionReorderDetailed`): the editor-first road is taken, the page
    // shows the new order, the rows follow after the job, the sidebar overlay is lifted by the settle, the Markdown writer's hold is
    // released, and the old body's out-of-queue bump is NOT made (so an earlier Delete stays quick-undoable). The hold is released by the
    // hold continuation, which waits for the job-ended gate: the reorder job's task must call `notifyMarkdownJobEnded`.
    func testAMarkdownDragMovesThePageThenTheRowsLiftsTheOverlayAndReleasesTheHold() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let outOfQueueBefore = rig.editorState.structuralOutOfQueueGeneration

        let drag = try await drop("Alpha", after: "Bravo")

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        XCTAssertEqual(
            rig.editorState.sections.map(\.title), ["Bravo", "Alpha", "Charlie"], "the sidebar does not show the dragged order")
        await rig.settleEverything()

        let wantedLines = ["# Bravo", "Bravo body.", "# Alpha", "Alpha body.", "# Charlie", "Charlie body."]
        let pageLines = try await pageContentLines()
        XCTAssertEqual(pageLines, wantedLines, "the page is not in the dragged order")
        let storedLines = Self.contentLines(try rig.writerRig.storedText())
        XCTAssertEqual(storedLines, pageLines, "the rows differ from the page after the settle")
        XCTAssertNil(rig.editorState.pendingReorder, "the sidebar overlay was not lifted by the settle")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after settle")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the job's pending count was not brought down")
        XCTAssertEqual(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueueBefore,
            "the drag bumped structuralOutOfQueueGeneration: an earlier Delete would lose its quick undo")
        let entry = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the drag recorded no entry")
        XCTAssertTrue(entry.kind == .sectionReorder && entry.isEditorFirst && entry.undoSnapshotId == nil, "the entry is \(entry)")
        XCTAssertEqual(rig.controller.efEditorKind[entry.id], .markdown, "the entry is not recorded as a Markdown editor-first entry")
    }

    // MARK: - T-U11 and T-FH1: the footnotes through the real click

    // T-U11: the nine-footnote document, the service primed, Chapter Three dragged above Chapter Two through the real click. When the
    // settle is over the page's references read 1..9 and the Notes rows hold one definition per number, in order.
    func testAMarkdownDragRenumbersTheFootnotesOfAPrimedDocument() async throws {
        let rig = try await makePrimedRig()
        guard rig.footnotes.lastRenumberedHash != 0 else {
            XCTFail("premise: the priming resync committed no hash (lastRenumberedHash is still 0), so the guard this test pins is not armed")
            return
        }
        XCTAssertEqual(try noteFragments().count, Self.labelCount, "premise: one Notes row per number before the drag")

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()

        let page = try await rig.waitForPage { FootnoteSyncService.extractFootnoteRefs(from: $0) == Self.sequentialLabels }
        let headings = Self.contentLines(page).filter { $0.hasPrefix("# ") }
        XCTAssertEqual(headings, ["# Chapter One", "# Chapter Three", "# Chapter Two", "# Notes"], "the page is not in the dragged order")
        try assertFootnotesRenumbered(page: page)
    }

    // T-FH1 (the forget site): the reorder job's settle must run with kind `.sectionReorder`, because only that kind forgets the footnote
    // service's committed hash, and since t-f1a22aa7 (Phase 4c) the FOOTNOTE RESYNC forgets it, not the settle's first step
    // (`resyncAfterEditorFirstDelete(forgetsCommittedNotes:)` hands the flag to `FootnoteSyncService.resyncNow(forgetCommittedHash:)`,
    // FIX-E / FIX-G). Seen at the settle's own hold (the DEBUG seam sits after the overlay step and before the resyncs): the overlay is
    // lifted, and the hash is NOT forgotten yet (a forget at the start of the settle is the old site: a `/footnote` typed during the settle
    // commits a hash of its own after it, and the resync then skips at the guard; R4b in MarkdownEditorFirstReorderTests+TimerRace.swift
    // is that case). The forget shows in the result: the references are renumbered. A settle that ran as a delete would leave the overlay
    // up and never forget the hash.
    func testTheDragsSettleRunsAsAReorderAndForgetsTheFootnoteHash() async throws {
        let rig = try await makePrimedRig()
        guard rig.footnotes.lastRenumberedHash != 0 else {
            XCTFail("premise: the priming resync committed no hash (lastRenumberedHash is still 0)")
            return
        }
        var hashAtSettleHold: Int?
        var overlayAtSettleHold: PendingReorder?
        var settleHoldReached = false
        let footnotes = rig.footnotes
        let editorState = rig.editorState
        rig.controller.testEFSettleHold = {
            settleHoldReached = true
            hashAtSettleHold = footnotes.lastRenumberedHash
            overlayAtSettleHold = editorState.pendingReorder
        }

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        await rig.settleEverything()

        XCTAssertTrue(settleHoldReached, "premise: the job's settle never reached its hold (the job did not apply)")
        XCTAssertNotEqual(hashAtSettleHold, 0, "the settle forgot the footnote hash before its flag (the old site)")
        XCTAssertNil(overlayAtSettleHold, "the settle did not lift the reorder overlay: it did not run as a reorder (kind .sectionReorder)")
        let page = try await rig.waitForPage { FootnoteSyncService.extractFootnoteRefs(from: $0) == Self.sequentialLabels }
        try assertFootnotesRenumbered(page: page)
    }

    // MARK: - T-R2: typing, then a drag at once

    // The user types into Bravo and drags Charlie at once, with the reorder job held. The click's own typing batch (reserved ahead of the
    // job) puts the typing into the rows BEFORE the job applies, and nothing pushes the whole document back into the page (the Delete's
    // twin: T-U1 and T-U14). The page keeps the typing in the moved order, and the job and step 8 leave the rows and the page equal.
    func testTypingJustBeforeADragIsSavedWithItAndNothingIsPushedBack() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let hold = rig.holdNextJob()
        try await installSetContentCounter()
        try await rig.userTypes(" zq7", after: "Bravo body.")

        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")

        // The job is held: step 8's flush cannot have saved anything yet, so only the click's own typing batch can have put "zq7" into the
        // rows. The job has not applied, so the rows are still in the old order.
        let batchSaved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("Bravo body. zq7")) == true }
        XCTAssertTrue(batchSaved, "typed text missing from rows: zq7 is not in the rows before the job ran")
        let storedWhileHeld = try rig.writerRig.storedText()
        let bravoAt = try XCTUnwrap(storedWhileHeld.range(of: "# Bravo"), "premise: Bravo is in the rows")
        let charlieAt = try XCTUnwrap(storedWhileHeld.range(of: "# Charlie"), "premise: Charlie is in the rows")
        XCTAssertLessThan(bravoAt.lowerBound, charlieAt.lowerBound, "premise: the job has not run yet, so the rows are still in the old order")
        let pageWhileHeld = try await pageContentLines()
        XCTAssertEqual(
            pageWhileHeld, ["# Alpha", "Alpha body.", "# Charlie", "Charlie body.", "# Bravo", "Bravo body. zq7"],
            "the page lost the typing or is not in the dragged order while the job is held")
        let pushesWhileHeld = try await setContentCalls()
        XCTAssertEqual(pushesWhileHeld, 0, "a whole-content setContent reached the page while the job was held")

        hold.release()
        await rig.settleEverything()
        let pageAfter = try await pageContentLines()
        XCTAssertEqual(
            pageAfter, ["# Alpha", "Alpha body.", "# Charlie", "Charlie body.", "# Bravo", "Bravo body. zq7"], "the page changed after the job")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageAfter, "the rows differ from the page after the settle")
        let pushesAfter = try await setContentCalls()
        XCTAssertEqual(pushesAfter, 0, "a whole-content setContent reached the page")
    }

    /// Counts the page's whole-content pushes (`window.FinalFinal.setContent`, the call the coordinator and the old body use).
    private func installSetContentCounter() async throws {
        _ = try await rig.helper.webView.evaluateJavaScript(
            """
            (() => {
              const ff = window.FinalFinal;
              const original = ff.setContent;
              window.__setContentCalls = 0;
              ff.setContent = function () { window.__setContentCalls += 1; return original.apply(this, arguments); };
              return true;
            })()
            """)
    }

    private func setContentCalls() async throws -> Int {
        let count = try await rig.helper.webView.evaluateJavaScript("window.__setContentCalls")
        return (count as? NSNumber)?.intValue ?? -1
    }

    // MARK: - T-R13: a level-only drop

    // Dropping Two right under One a step to the right changes only Two's level: the order stays One, Two, Three. It still takes the
    // editor-first road (the page's no-move branch rewrites the `#` count, one entry is recorded, the job writes the level).
    func testALevelOnlyDropTakesTheEditorFirstRoad() async throws {
        let rig = try await MarkdownClickRig(
            markdown: "# One\n\nOne body.\n\n# Two\n\nTwo body.\n\n# Three\n\nThree body.", observesPage: true)
        self.rig = rig
        rig.installReparseHost()

        let drag = try await drop("Two", after: "One", level: 2, asChildOf: "One")

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "editor-first road not taken for a level-only drop")
        XCTAssertTrue(
            rig.controller.efEditorKind.values.contains(.markdown), "editor-first road not taken for a level-only drop")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.isEditorFirst, true, "editor-first road not taken for a level-only drop")
        await rig.settleEverything()

        let pageLines = try await pageContentLines()
        XCTAssertEqual(pageLines, ["# One", "One body.", "## Two", "Two body.", "# Three", "Three body."], "the page does not show Two as level 2")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the settle")
        let two = try rig.section("Two")
        XCTAssertEqual(two.headingLevel, 2, "Two's level in the rows is \(String(describing: two.headingLevel))")
        XCTAssertEqual(two.markdownFragment, "## Two", "Two's text in the rows is '\(two.markdownFragment)'")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after settle")
    }

    // MARK: - T-R16: a drag at once after a Delete

    // Delete Section, then a drag straight away. The drag waits for the Delete's job and its step 8 (the writer's hold; in Markdown the
    // two never overlap), then raises its OWN rebuild stamp and pending count, and the drag's job brings its own count down again. While
    // the drag's job is unapplied a rebuild that read the database is stale (read while a job is pending), and so is one that read before
    // the click (the click generation moved); once the job has settled a fresh read is current again. (T-R16 as the plan wrote it
    // assumed the Rich Text order, where the drag does not wait: the count of an unapplied Delete cannot survive into the drag's job in
    // Markdown, so this test pins the drag's own count and generation instead.)
    func testADragRightAfterADeleteKeepsItsOwnRebuildStampAndPendingCount() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let deleteHold = rig.holdNextJob()
        let chapter4 = try rig.section("Chapter 4")
        let deleted = await rig.controller.performSectionDelete(rootId: chapter4.id)
        XCTAssertEqual(deleted, .performed, "premise: the Delete was refused")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 1, "premise: the Delete's job is held, so its pending count is up")

        // The drag job gets a hold of its own (the reorder seam wins over the shared one the Delete's job was started with).
        let dragHold = MarkdownClickRig.JobHold()
        rig.controller.testEFReorderJobBodyHold = { dragHold.wait() }
        let (plan, request) = try dropRequest("Chapter 3", after: "Chapter 1")
        let generationBefore = rig.editorState.editorFirstClickGeneration
        let controller = rig.controller
        let dragTask = Task { @MainActor in await controller.performSectionReorderDetailed(sections: plan, request: request) }

        let waiting = await rig.waitUntil { rig.markdownWriter.structuralHoldWaiterCount == 1 }
        XCTAssertTrue(waiting, "premise: the drag does not wait for the Delete's hold")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 1, "pending count wrong while the drag waits: it must still be the Delete's alone")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generationBefore, "the drag moved the rebuild stamp before its turn")

        deleteHold.release()
        let drag = await dragTask.value
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")

        // The drag's job is held (unapplied) and the Delete's is over: the only count is the drag's.
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 1, "pending count 0 while the drag's job is unapplied")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generationBefore + 1, "the drag did not move the rebuild stamp")
        let whileUnapplied = rig.editorState.stampRebuildRead()
        XCTAssertTrue(whileUnapplied.readWhileEditorFirstJobPending, "a rebuild that reads now is not marked as read while a job is pending")
        XCTAssertFalse(
            rig.editorState.rebuildPushStillWanted(whileUnapplied), "a rebuild push read while the drag's job is unapplied is treated as current")

        dragHold.release()
        await rig.settleEverything()
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the drag's job did not bring its pending count down")
        XCTAssertTrue(
            rig.editorState.rebuildPushStillWanted(rig.editorState.stampRebuildRead()),
            "a rebuild that reads after both jobs have settled is still treated as stale")
        let pageLines = try await pageContentLines()
        XCTAssertEqual(
            pageLines, ["# Chapter 1", "First chapter text.", "# Chapter 3", "Third chapter text.", "# Chapter 2", "Second chapter text."],
            "the page is not Chapter 1, 3, 2 (Chapter 4 deleted)")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the settle")
    }
}
