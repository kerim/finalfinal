//
//  MarkdownEditorFirstReorderTests+Undo.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder in Markdown mode), round 3b, part 1:
//  the tests of a drag that involve a real Cmd-Z or Cmd-Shift-Z (`MarkdownClickRig` with `routesUndo`: a real keydown reaches the
//  controller through the real coordinator, as in the app), or that look at what a drag leaves for the undo timeline. An extension of the
//  class in MarkdownEditorFirstReorderTests.swift (same fixtures and helpers; the class body stays under SwiftLint's limit). Real page,
//  real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  Break patches (a 1-5 line change in production code that must make the test fail) are in the driver's folder
//  (scratchpad breaks-3b/index.md). The failure each shows:
//
//   T-FH2  testTheSlowCmdZAndCmdShiftZOfADragKeepTheFootnotesInOrder   (a PIN: see the comment on the test)
//          BREAK: delete `forgetCommittedDerivedState()` in `snapshotSwapJobSettled` (StructuralUndoController+QueuedSnapshotUndo.swift).
//          FAILS (if at all): "footnote references out of order after Cmd-Z" / "after Cmd-Shift-Z".
//   T-U13a testTheMovedHeadingsKeepTheirIdsStatusAndTagsThroughTheDragAndTheTypingAfterIt
//          BREAK: delete `writer.noteQueuedStructuralJob()` in `markdownReorderReplyTurn` (+MarkdownEditorFirstReorder.swift).
//          FAILS: "heading id changed / status lost".
//   T-U13b testTheMovedHeadingsKeepTheirStatusAndTagsThroughTheSlowCmdZAndCmdShiftZOfTheDrag
//          BREAK: in `ProjectDatabase.preparedRowsForWholeReplace` (Database+BlocksReplace.swift) queue the existing headings by
//          `block.id` instead of `block.textContent`.   FAILS: "status lost after undo" (and "... after redo"). Passing
//          `existingSectionMetadata: nil` in `SnapshotService.wholeRestorePlan` alone does NOT fail it (a redundant second carrier).
//   T-U15  testCmdZPressedAtOnceAfterADragWithItsJobHeldIsHeldNotRefusedAndAStaleRebuildPushIsSkipped
//          BREAK: `rebuildPushStillWanted` (EditorViewState+RebuildGuard.swift) returns true.   FAILS: "a stale rebuild push was not skipped".
//   T-R6   testDeleteThenDragThenCmdZTwiceTheSecondPressIsQuickAndNothingBumpsTheGeneration
//          BREAK: `editorState.structuralOutOfQueueGeneration &+= 1` in `runMarkdownEditorFirstReorder`.
//          FAILS: "the drag click bumped structuralOutOfQueueGeneration" and "second Cmd-Z took the slow route".
//   T-R7   testDragThenDeleteThenCmdZUndoesTheDeleteQuicklyAndTheNextCmdZUndoesTheDrag
//          BREAK: `performMarkdownEditorFirstReorder` returns nil.   FAILS: "drag took the old body".
//

import Foundation
import XCTest
@testable import final_final

/// How many times the sections-updated handler ran (see `countingSectionsUpdatedHandler`).
final class SectionsUpdatedCount {
    var count = 0
}

extension MarkdownEditorFirstReorderTests {

    // MARK: - Helpers

    /// The heading lines of a page (`# Title` lines), in order.
    static func headings(in page: String) -> [String] {
        contentLines(page).filter { $0.hasPrefix("# ") }
    }

    static let originalHeadings = ["# Chapter One", "# Chapter Two", "# Chapter Three", "# Notes"]
    static let movedHeadings = ["# Chapter One", "# Chapter Three", "# Chapter Two", "# Notes"]

    /// A rig with a real Cmd-Z route (the page's undo messages reach the controller) and everything a drag's settle needs.
    func makeUndoRig(_ markdown: String) async throws -> MarkdownClickRig {
        let rig = try await MarkdownClickRig(markdown: markdown, observesPage: true, routesUndo: true)
        self.rig = rig
        rig.installReparseHost()
        rig.coordinator?.webView = rig.helper.webView
        rig.footnotes.systemWriter = SystemWriter(blockSync: rig.writerRig.sync)
        return rig
    }

    /// A real Cmd-Z (`"undo"`) or Cmd-Shift-Z (`"redo"`); waits until the page's text satisfies `condition`, then until the structural gate
    /// and everything the press started have finished.
    @discardableResult @nonobjc   // internal on an XCTestCase: without `@nonobjc` its async ObjC thunk would capture the non-escaping closure
    func pressAndSettle(_ direction: String, until condition: (String) -> Bool, _ message: String) async throws -> String {
        try await rig.press(direction)
        let text = try await rig.waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await rig.waitUntil(20) { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        return text
    }

    /// The footnote checks of `assertFootnotesRenumbered`, for any numbering: the page's references read 1..9, its Notes hold each
    /// definition exactly once with the text of the note that `oldLabels[k - 1]` names, and the Notes ROWS follow, one per number, in
    /// numeric order. `oldLabels` is the label each reference had in the ORIGINAL document: 1..9 for the original order, 1-3, 7-9,
    /// 4-6 after the drag of Chapter Three above Chapter Two.
    func assertFootnotes(page: String, notesFollow oldLabels: [String], context: String) throws {
        let pageRefs = FootnoteSyncService.extractFootnoteRefs(from: page)
        XCTAssertEqual(
            pageRefs, Self.sequentialLabels,
            "footnote references out of order \(context): [\(pageRefs.joined(separator: ", "))] (wanted 1 to \(Self.labelCount))")
        let definitions = Self.definitionLines(in: page)
        let labels = definitions.map(\.label)
        XCTAssertEqual(
            labels, Self.sequentialLabels,
            "the page's Notes do not hold each definition exactly once, in numeric order \(context): \(labels)")
        let textByLabel = Dictionary(definitions.map { ($0.label, $0.text) }, uniquingKeysWith: { first, _ in first })
        for (index, old) in oldLabels.enumerated() {
            XCTAssertEqual(
                textByLabel["\(index + 1)"], "Note \(old) text.",
                "the page's definition [^\(index + 1)] should be the note that was labelled \(old) \(context)")
        }
        let fragments = try noteFragments()
        XCTAssertEqual(fragments.count, Self.labelCount, "\(fragments.count) Notes rows instead of \(Self.labelCount) \(context)")
        for (index, old) in oldLabels.enumerated() where index < fragments.count {
            let wanted = "[^\(index + 1)]:"
            XCTAssertTrue(
                fragments[index].hasPrefix(wanted) && fragments[index].contains("Note \(old) text."),
                "Notes row \(index + 1) should be '\(wanted) Note \(old) text.', it is '\(fragments[index])' \(context)")
        }
    }

    /// The sections-updated handler ContentView installs, wrapped so a test can see that it ran (the settle's sidebar refresh calls it).
    /// The real handler is what decides whether hierarchy enforcement runs (`hasHierarchyViolations`), so a counted call that left the
    /// timeline alone is a real "enforcement was not reached".
    @MainActor
    static func countingSectionsUpdatedHandler(
        editorState: EditorViewState, syncService: SectionSyncService, counter: SectionsUpdatedCount
    ) -> () -> Void {
        let real = ContentView.makeSectionsUpdatedHandler(for: editorState, syncService: syncService)
        return {
            counter.count += 1
            real()
        }
    }

    // MARK: - T-FH2: the slow undo and redo of a drag, footnotes

    // PIN (it cannot go red from the footnote hash): removing `forgetCommittedDerivedState()` at QueuedSnapshotUndo.swift:303 does not
    // change the outcome, because the composed redo (web, round 2b) lands on the already renumbered text and the undo swaps the original
    // text in, so the numbering is right with or without the forget. The test keeps the user-visible outcome pinned.
    //
    // Forget site 2 of the footnote hash (QueuedSnapshotUndo.swift `snapshotSwapJobSettled`): the Markdown slow Cmd-Z and Cmd-Shift-Z of a
    // drag swap a snapshot in and the settle re-derives the footnotes. The service is PRIMED (an earlier resync committed 1..9). After
    // the drag, after Cmd-Z and after Cmd-Shift-Z the page's references read 1..9, its Notes hold each definition once, and the Notes rows
    // follow the text.
    func testTheSlowCmdZAndCmdShiftZOfADragKeepTheFootnotesInOrder() async throws {
        let rig = try await makePrimedRig(routesUndo: true)
        guard rig.footnotes.lastRenumberedHash != 0 else {
            XCTFail("premise: the priming resync committed no hash (lastRenumberedHash is still 0), so the guard this test pins is not armed")
            return
        }
        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        let afterDrag = try await rig.waitForPage { FootnoteSyncService.extractFootnoteRefs(from: $0) == Self.sequentialLabels }
        try assertFootnotes(page: afterDrag, notesFollow: Self.movedLabels, context: "after the drag")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.kind, .sectionReorder, "premise: the drag is the top of the undo timeline")

        let undone = try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == Self.originalHeadings }, "Cmd-Z did not put the chapters back in their old order")
        try assertFootnotes(page: undone, notesFollow: Self.sequentialLabels, context: "after Cmd-Z")

        let redone = try await pressAndSettle(
            "redo", until: { Self.headings(in: $0) == Self.movedHeadings }, "Cmd-Shift-Z did not move the chapter again")
        try assertFootnotes(page: redone, notesFollow: Self.movedLabels, context: "after Cmd-Shift-Z")
    }

    // MARK: - T-U13: ids, status and tags

    /// Gives Bravo and Charlie a status, tags and a word goal and returns the three headings as they are now.
    private func headingsWithMetadata() throws -> [Block] {
        try rig.writerRig.setMetadata(onHeading: "Bravo", status: .review, tags: ["bravo-tag"], wordGoal: 111)
        try rig.writerRig.setMetadata(onHeading: "Charlie", status: .final_, tags: ["charlie-tag", "second"], wordGoal: 222)
        return try ["Alpha", "Bravo", "Charlie"].map { try rig.section($0) }
    }

    /// Every heading in `before` is in the rows with the same status, tags and word goal, and (when `ids`) the same id.
    private func assertMetadataKept(_ before: [Block], ids: Bool, message: String) throws {
        for old in before {
            let now = try rig.section(old.textContent)
            if ids {
                XCTAssertEqual(now.id, old.id, "\(message): \(old.textContent) has a new id (heading id changed)")
            }
            XCTAssertEqual(now.status, old.status, "\(message): \(old.textContent) status \(String(describing: now.status)) (status lost)")
            XCTAssertEqual(now.tags, old.tags, "\(message): \(old.textContent) tags \(String(describing: now.tags)) (tags lost)")
            XCTAssertEqual(now.wordGoal, old.wordGoal, "\(message): \(old.textContent) word goal \(String(describing: now.wordGoal)) (goal lost)")
        }
    }

    // T-U13(a): the click tells the writer a structural job is queued (`noteQueuedStructuralJob`), so the typing batch it reserved cannot
    // install a text baseline that names the rows in their OLD order. Without it the next diff (step 8's flush, the re-parse after the
    // typing) compares the new-order text against the old-order baseline and deletes and re-inserts the moved headings: new ids, no status,
    // no tags. Drag Charlie above Bravo, type, re-parse: the three headings keep id, status, tags and word goal.
    func testTheMovedHeadingsKeepTheirIdsStatusAndTagsThroughTheDragAndTheTypingAfterIt() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let before = try headingsWithMetadata()
        XCTAssertEqual(before[1].status, .review, "premise: Bravo carries its status")

        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        try assertMetadataKept(before, ids: true, message: "after the drag")
        XCTAssertEqual(
            Self.contentLines(try rig.writerRig.storedText()).filter { $0.hasPrefix("# ") }, ["# Alpha", "# Charlie", "# Bravo"],
            "premise: the rows are in the dragged order")

        // Typing after the drag, then the debounced re-parse the app arms (the rig runs the real scheduler by hand).
        try await rig.userTypes(" zq7", after: "Bravo body.")
        let reported = await rig.waitUntil { rig.editorState.content.contains("zq7") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()
        try assertMetadataKept(before, ids: true, message: "after the typing that followed the drag was re-parsed")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Bravo body. zq7"), "the typing is not in the rows")
        let pageLines = try await pageContentLines()
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page")
    }

    // T-U13(b): the slow Cmd-Z and Cmd-Shift-Z of a drag replace the project's rows from a snapshot. First a PIN that says whether the
    // heading ids survive that (a section deleted and put back gets fresh ids; a reorder removes and adds no row, so the plan keeps the
    // table's ids: found by the first run and reported through the activity "PIN ..."). Then, whatever the ids do, the status, tags and
    // word goal of the moved headings are the same after Cmd-Z and after Cmd-Shift-Z; the ids are asserted only when they survived the undo.
    //
    // WHO CARRIES THE METADATA (found by the break runs): `ProjectDatabase.preparedRowsForWholeReplace` (Database+BlocksReplace.swift)
    // restores id and metadata onto the plan's rows by heading TITLE from the rows that are in the table when the plan is made. The
    // snapshot's own sections (`existingSectionMetadata` in `SnapshotService.wholeRestorePlan`) are a second, REDUNDANT carrier for a swap
    // like this one, where the headings are still in the table: taking only that argument away changes nothing the user sees. The honest
    // break takes the first carrier away.
    func testTheMovedHeadingsKeepTheirStatusAndTagsThroughTheSlowCmdZAndCmdShiftZOfTheDrag() async throws {
        let rig = try await makeUndoRig(Self.book3)
        let before = try headingsWithMetadata()
        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        try assertMetadataKept(before, ids: true, message: "after the drag")

        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == ["# Alpha", "# Bravo", "# Charlie"] }, "Cmd-Z did not put the chapters back")
        let idsSurviveUndo = try before.allSatisfy { try rig.section($0.textContent).id == $0.id }
        XCTContext.runActivity(named: "PIN T-U13b: heading ids survive the slow Cmd-Z of a reorder = \(idsSurviveUndo)") { _ in }
        print("[PIN T-U13b] heading ids survive the slow Cmd-Z of a reorder: \(idsSurviveUndo)")
        try assertMetadataKept(before, ids: idsSurviveUndo, message: "status lost after undo")

        try await pressAndSettle(
            "redo", until: { Self.headings(in: $0) == ["# Alpha", "# Charlie", "# Bravo"] }, "Cmd-Shift-Z did not move the chapter again")
        try assertMetadataKept(before, ids: idsSurviveUndo, message: "status lost after redo")
        let pageAfterRedo = try await pageContentLines()
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageAfterRedo, "the rows differ from the page after the redo")
    }

    // MARK: - T-U15: Cmd-Z at once after a drag

    // A drag of a footnoted chapter whose job is HELD, then Cmd-Z at once. The press is held (it waits for the job and its settle), not
    // refused: no "Some undo or redo presses could not be carried out." The B4 guard keeps a Notes rebuild that read the rows BEFORE the
    // click (its stamp predates the click) from pushing its stale Notes into the page while the job is unapplied: here the real pusher is
    // given exactly such a rebuild (`pushRebuild` with the stamp taken before the drag) and must skip it. Then the job is released and the
    // press carries out: the chapters are back in their old order, the footnotes are right, and no refusal notice was shown.
    func testCmdZPressedAtOnceAfterADragWithItsJobHeldIsHeldNotRefusedAndAStaleRebuildPushIsSkipped() async throws {
        let rig = try await makePrimedRig(routesUndo: true)
        let hold = MarkdownClickRig.JobHold()
        rig.controller.testEFReorderJobBodyHold = { hold.wait() }   // only the drag's job; the undo's own job is not held
        let editorState = rig.editorState
        let stamp = editorState.stampRebuildRead()
        let notesTitle = try? rig.db.fetchNotesHeadingTitle(projectId: rig.pid)
        let read = MarkdownManagedRegions.snapshot(markdown: editorState.content, projectId: rig.pid, notesTitle: notesTitle)
        let readNotes = try XCTUnwrap(read.notes, "premise: the editor's text has a Notes region")

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        let pageAfterClick = try await rig.pageText()
        XCTAssertEqual(Self.headings(in: pageAfterClick), Self.movedHeadings, "premise: the page shows the dragged order")

        // Cmd-Z at once: the press reaches the controller and waits for the held job.
        try await rig.press("undo")
        let reached = await rig.waitUntil { !editorState.structuralGate.isIdle }
        XCTAssertTrue(reached, "premise: the Cmd-Z press never reached the controller (it was not routed as a structural undo)")
        let pageWhileHeld = try await rig.pageText()
        XCTAssertEqual(pageWhileHeld, pageAfterClick, "the held press changed the page before the drag's job had applied")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.kind, .sectionReorder, "the held press moved the entry before the job had applied")

        // The stale rebuild: it read the rows (and the editor's Notes) before the click, and wants to put different Notes in now.
        var fresh = read
        fresh.notes = readNotes + "\n\n[^10]: A stale note from a rebuild that read before the drag."
        let pusher = MarkdownManagedRegionPusher(
            evaluate: { script in (try? await rig.helper.webView.evaluateJavaScript(script)) as? String },
            adopt: { editorState.adoptMarkdownPageText($0) })
        let report = await pusher.pushRebuild(
            regions: [.notes], read: read, fresh: fresh, stillWanted: { editorState.rebuildPushStillWanted(stamp) })
        XCTAssertTrue(report.staleSkipped, "a stale rebuild push was not skipped (the B4 guard let a push that read before the click through)")
        let pageAfterPush = try await rig.pageText()
        XCTAssertEqual(pageAfterPush, pageAfterClick, "a stale rebuild push reached the page while the drag's job was unapplied")

        hold.release()
        _ = await rig.waitUntil(20) { editorState.structuralGate.isIdle && !editorState.markdownWriter.isHeldForStructuralWork }
        await rig.settleEverything()
        let undone = try await rig.waitForPage { Self.headings(in: $0) == Self.originalHeadings }
        XCTAssertEqual(Self.headings(in: undone), Self.originalHeadings, "the held Cmd-Z did not put the chapters back after the job applied")
        try assertFootnotes(page: undone, notesFollow: Self.sequentialLabels, context: "after the held Cmd-Z")
        let refusal = "Some undo or redo presses could not be carried out."
        XCTAssertFalse(rig.toastLog.lines.contains { $0.contains(refusal) }, "refusal notice posted: \(rig.toastLog.lines)")
        XCTAssertNotEqual(editorState.toastCenter.current?.message, refusal, "refusal notice posted")
        XCTAssertEqual(rig.unifiedUndo.redoStack.last?.kind, .sectionReorder, "the drag's entry did not move to the redo stack")
    }

    // MARK: - T-R6: Delete, drag, Cmd-Z, Cmd-Z

    // The Delete stays quick-undoable across a drag: nothing on the new path touches `structuralOutOfQueueGeneration` (the click, the job,
    // the settle, the drag's slow undo), so the second Cmd-Z takes the quick path. And (M22) the sidebar refresh that the settle and the
    // slow undo end with runs the REAL sections-updated handler, which does not reach hierarchy enforcement (`invalidateAll(reason:
    // "hierarchy enforcement")` bumps the undo timeline's generation and clears both stacks): the timeline is unchanged all the way.
    func testDeleteThenDragThenCmdZTwiceTheSecondPressIsQuickAndNothingBumpsTheGeneration() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true, routesUndo: true)
        self.rig = rig
        rig.installReparseHost()
        let updates = SectionsUpdatedCount()
        rig.editorState.onSectionsUpdated = Self.countingSectionsUpdatedHandler(
            editorState: rig.editorState, syncService: rig.sectionSync, counter: updates)
        let original = try await rig.pageText()
        let fourChapters = ["# Chapter 1", "# Chapter 2", "# Chapter 3", "# Chapter 4"]
        let threeChapters = ["# Chapter 1", "# Chapter 2", "# Chapter 3"]

        let deleted = await rig.controller.performSectionDelete(rootId: try rig.section("Chapter 4").id)
        XCTAssertEqual(deleted, .performed, "premise: the Delete was refused")
        await rig.settleEverything()
        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "premise: the Delete recorded no entry")
        XCTAssertTrue(deleteEntry.isEditorFirst, "premise: the Delete was made editor-first")
        let outOfQueue = rig.editorState.structuralOutOfQueueGeneration
        let timeline = rig.unifiedUndo.generation
        updates.count = 0

        let drag = try await drop("Chapter 3", after: "Chapter 1")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        XCTAssertEqual(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueue, "the drag click bumped structuralOutOfQueueGeneration")
        await rig.settleEverything()
        XCTAssertEqual(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueue, "the drag's job or settle bumped structuralOutOfQueueGeneration")
        XCTAssertGreaterThan(
            updates.count, 0,
            "premise (M22): the settle's sidebar refresh never ran the sections-updated handler, so hierarchy enforcement was not exercised")
        XCTAssertEqual(
            rig.unifiedUndo.generation, timeline,
            "the undo timeline was wiped after the drag (invalidateAll: hierarchy enforcement reached after the drag's settle)")
        XCTAssertEqual(rig.unifiedUndo.undoStack.map(\.id).first, deleteEntry.id, "the Delete's entry is gone from the timeline")
        XCTAssertTrue(
            rig.controller.quickUndoEligible(deleteEntry), "second Cmd-Z took the slow route: the Delete's quick path is closed after the drag")

        updates.count = 0
        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == threeChapters }, "the first Cmd-Z did not put the dragged chapter back")
        XCTAssertEqual(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueue, "the drag's slow undo bumped structuralOutOfQueueGeneration")
        XCTAssertEqual(
            rig.unifiedUndo.generation, timeline,
            "the undo timeline was wiped by the drag's slow undo (invalidateAll: hierarchy enforcement reached after its settle)")
        XCTAssertGreaterThan(updates.count, 0, "premise (M22): the slow undo's sidebar refresh never ran the sections-updated handler")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, deleteEntry.id, "the Delete's entry is not the top of the timeline after the first Cmd-Z")
        XCTAssertTrue(
            rig.controller.quickUndoEligible(deleteEntry),
            "second Cmd-Z took the slow route: the Delete's quick path is closed after the drag's undo")

        try await pressAndSettle("undo", until: { Self.headings(in: $0) == fourChapters }, "the second Cmd-Z did not put Chapter 4 back")
        let slot = rig.controller.efSlots.slot(deleteEntry.id)?.state
        XCTAssertTrue(
            slot == .quickUndone || slot == .reinserted,
            "second Cmd-Z took the slow route (the Delete's slot is \(String(describing: slot)), not quickUndone or reinserted)")
        XCTAssertEqual(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueue, "the Delete's quick undo bumped structuralOutOfQueueGeneration")
        let finalPage = try await rig.pageText()
        XCTAssertEqual(Self.contentLines(finalPage), Self.contentLines(original), "the page is not the original document")
        XCTAssertEqual(
            Self.contentLines(try rig.writerRig.storedText()), Self.contentLines(original), "the rows are not the original document")
    }

    // MARK: - T-R7: drag, Delete, Cmd-Z, Cmd-Z

    // The drag first, the Delete after it. The Delete's Cmd-Z is the quick one, and the Cmd-Z after it undoes the drag (the queued slow
    // route). The drag took the editor-first road (a unit test cannot read the app log's `start (editor-first) mode=markdown` line: it
    // reads what that line stands for, the entry's editor kind and `isEditorFirst`; the real-app test E-D4 reads the log itself).
    func testDragThenDeleteThenCmdZUndoesTheDeleteQuicklyAndTheNextCmdZUndoesTheDrag() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true, routesUndo: true)
        self.rig = rig
        rig.installReparseHost()
        let original = try await rig.pageText()

        let drag = try await drop("Chapter 3", after: "Chapter 1")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "drag took the old body")
        await rig.settleEverything()
        let dragEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the drag recorded no entry")
        XCTAssertTrue(
            dragEntry.kind == .sectionReorder && dragEntry.isEditorFirst && rig.controller.efEditorKind[dragEntry.id] == .markdown,
            "drag took the old body: the entry is \(dragEntry)")

        let deleted = await rig.controller.performSectionDelete(rootId: try rig.section("Chapter 4").id)
        XCTAssertEqual(deleted, .performed, "the Delete after the drag was refused")
        await rig.settleEverything()
        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the Delete recorded no entry")
        XCTAssertEqual(deleteEntry.kind, .sectionDelete, "premise: the top of the timeline is the Delete")
        XCTAssertTrue(deleteEntry.isEditorFirst, "premise: the Delete was made editor-first")
        XCTAssertTrue(rig.controller.quickUndoEligible(deleteEntry), "Delete undo was slow: its quick path is closed after the drag")

        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == ["# Chapter 1", "# Chapter 3", "# Chapter 2", "# Chapter 4"] },
            "the first Cmd-Z did not put Chapter 4 back")
        let slot = rig.controller.efSlots.slot(deleteEntry.id)?.state
        XCTAssertTrue(
            slot == .quickUndone || slot == .reinserted,
            "Delete undo was slow (the Delete's slot is \(String(describing: slot)), not quickUndone or reinserted)")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, dragEntry.id, "the drag is not the next entry to undo")

        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == ["# Chapter 1", "# Chapter 2", "# Chapter 3", "# Chapter 4"] },
            "the second Cmd-Z did not undo the drag")
        let finalPage = try await rig.pageText()
        XCTAssertEqual(Self.contentLines(finalPage), Self.contentLines(original), "the page is not the original document")
        XCTAssertEqual(
            Self.contentLines(try rig.writerRig.storedText()), Self.contentLines(original), "the rows are not the original document")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after the last Cmd-Z")
    }
}
