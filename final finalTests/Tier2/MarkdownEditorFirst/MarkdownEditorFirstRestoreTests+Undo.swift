//
//  MarkdownEditorFirstRestoreTests+Undo.swift
//  final finalTests
//
//  t-4a8fd8af slice 4, round C2: the tests of the Markdown restores that involve a real Cmd-Z or Cmd-Shift-Z (`MarkdownClickRig` with
//  `routesUndo`: a real keydown reaches the controller through the real coordinator, as in the app). An extension of the class in
//  MarkdownEditorFirstRestoreTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  HOW "QUICK" IS PROVEN. Not by timing. The controller's ordering spy (`testOrderingSpy`) sees `quickUndoRestoreApplied` once per quick
//  Cmd-Z (it sits right after the `start (quick, markdown)` trace line and the page's swap) and `quickRedoJobReserved` once per quick
//  Cmd-Shift-Z; the QUEUED route passes `markdownSlowSwapReserved` instead and writes the persisted line "markdown queued ...". The rig's
//  toast log must stay empty too (no "Undoing…" / "Redoing…" / "Finishing the last change…").
//
//   U5   testCmdZCmdShiftZOfAWholeRestoreAreQuick...  /  ...OfAReplace...  /  ...OfAnInsertAsNew...
//        BREAK A: in `markdownQuickRedoComposedReplyTurn` give the redo's plan fresh ids (regenerate ids on redo).
//        FAILS: "redo rows differ from the click's" (cycle 1)
//        BREAK B (S2): delete `if jobKey != nil { efSlots.markReserved(opId) }` in `markdownRestoreReplyTurn`.
//        FAILS: "the third Cmd-Z was not quick" / "took the queued route"
//        BREAK C (S10): record a second entry in `markdownRestoreReplyTurn`.   FAILS: "the entry is on the timeline N times"
//   U6   testASecondCmdZPressedWhileTheRestoresUndoWaitsIsHeldAndActs
//        BREAK: in `resolveMarkdownQuickPath` replace `await editorState.markdownWriter.awaitStructuralHoldReleased()` with
//        `if editorState.markdownWriter.isHeldForStructuralWork { return .failed }`.   FAILS: "the second Cmd-Z was lost"
//   U7   testAnEarlierDeleteStaysQuickUndoableAfterARestore
//        BREAK: `editorState.structuralOutOfQueueGeneration &+= 1` in the Markdown restore click.   FAILS: "Delete not quick"
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstRestoreTests {

    // MARK: - U5

    /// The whole cycle for one kind of restore: click, then two full Cmd-Z / Cmd-Shift-Z cycles, then a THIRD Cmd-Z.
    private func assertTheRestoreCyclesAreQuick(
        _ document: String, editAfter marker: String,
        press pressRestore: (Snapshot) async throws -> StructuralUndoController.StructuralOpOutcome
    ) async throws {
        try await startRig(document, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        alwaysLog = RestoreAlwaysLog()
        try rig.writerRig.setMetadata(onHeading: "Chapter 1", status: .review, tags: ["alpha"], wordGoal: 500)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: marker)
        let pre = try await pageText()
        let rowsBefore = try rowSnapshot()

        let outcome = try await pressRestore(version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        let post = try await pageText()
        let rowsAfterClick = try rowSnapshot()
        XCTAssertNotEqual(post, pre, "premise: the restore changed the page")
        XCTAssertNotEqual(rowsAfterClick, rowsBefore, "premise: the restore changed the rows")
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id, "premise: the restore is on the timeline")
        let clickHeadingIds = Self.headingIds(of: try rig.writerRig.rows())

        for cycle in 1...2 {
            try await press("undo", until: { $0 == pre }, "cycle \(cycle): Cmd-Z did not bring back the text from before the restore")
            assertQuiet("after the Cmd-Z of cycle \(cycle)")
            XCTAssertEqual(spy.count("quickUndoRestoreApplied"), cycle, "cycle \(cycle): the Cmd-Z was not quick")
            XCTAssertEqual(try rowSnapshot(), rowsBefore, "cycle \(cycle): rows after Cmd-Z differ from the rows before the restore")
            try await assertRowsMatchPage("after the Cmd-Z of cycle \(cycle)")

            try await press("redo", until: { $0 == post }, "cycle \(cycle): Cmd-Shift-Z did not bring back the restored text the click made")
            assertQuiet("after the Cmd-Shift-Z of cycle \(cycle)")
            XCTAssertEqual(spy.count("quickRedoJobReserved"), cycle, "cycle \(cycle): the Cmd-Shift-Z was not quick")
            XCTAssertEqual(
                try rowSnapshot(), rowsAfterClick, "cycle \(cycle): redo rows differ from the click's (the redo wrote other ids or other text)")
            XCTAssertEqual(
                Self.headingIds(of: try rig.writerRig.rows()), clickHeadingIds, "cycle \(cycle): the redo's headings have other ids than the click's")
            try await assertRowsMatchPage("after the Cmd-Shift-Z of cycle \(cycle)")
        }
        XCTAssertEqual(
            rig.unifiedUndo.undoStack.filter { $0.id == opId }.count, 1, "the entry is on the timeline more than once after the redo (S10)")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 1, "the undo stack is not exactly the restore")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty)

        // The THIRD Cmd-Z, after a redo: the redo marked the entry's slot reserved (S2), so this one is quick again. The queued route
        // would write "markdown queued ..." and reserve a slow swap.
        try await press("undo", until: { $0 == pre }, "the third Cmd-Z did not bring back the text from before the restore")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 3, "the third Cmd-Z was not quick (start (quick, markdown) was not reached)")
        XCTAssertEqual(spy.count("markdownSlowSwapReserved"), 0, "the third Cmd-Z took the queued route (a markdown queued swap was reserved)")
        let queuedLines = (alwaysLog?.lines ?? []).filter { $0.contains("markdown queued") }
        XCTAssertTrue(queuedLines.isEmpty, "the third Cmd-Z wrote a markdown queued line: \(queuedLines)")
        assertQuiet("after the third Cmd-Z")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the third Cmd-Z left other rows than the ones before the restore")
        XCTAssertEqual(rig.unifiedUndo.redoStack.filter { $0.id == opId }.count, 1, "the entry is not on the redo stack exactly once")
        let held = try await heldPressCount()
        XCTAssertEqual(held, 0, "held count stuck (the page still holds a press)")
    }

    private static func headingIds(of rows: [Block]) -> [String] {
        rows.filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
    }

    // CLAIM (Restore Entire Project): Cmd-Z and Cmd-Shift-Z are QUICK (no notice, the quick route's steps are seen), the rows after the undo
    // are the rows before the restore (ids, text, status, tags, goal), the page after the redo is the page the click made, the rows after
    // the redo are the rows the click made (same ids), on both of TWO cycles; the entry is on the timeline once; a THIRD Cmd-Z after the
    // redo is quick again and never takes the queued route. The trace lines of the brief (`start (quick, markdown)`, no `markdown
    // queued`) have no test sink: the spy steps and the persisted line stand for them (see the file header).
    func testCmdZCmdShiftZOfAWholeRestoreAreQuickWithNoNoticeAndTheSameIdsComeBack() async throws {
        try await assertTheRestoreCyclesAreQuick(Self.book, editAfter: "Second chapter text.") { version in
            try await self.restoreProject(from: version)
        }
    }

    // CLAIM (Replace Current Section): the same.
    func testCmdZCmdShiftZOfAReplaceAreQuickWithNoNoticeAndTheSameIdsComeBack() async throws {
        try await assertTheRestoreCyclesAreQuick(Self.book, editAfter: "Second chapter text.") { version in
            try await self.replaceSection("Chapter 2", from: version)
        }
    }

    // CLAIM (Insert as New Section): the same; the undo takes the inserted section out, the redo brings it back with the SAME heading id.
    func testCmdZCmdShiftZOfAnInsertAsNewAreQuickWithNoNoticeAndTheSameIdsComeBack() async throws {
        try await assertTheRestoreCyclesAreQuick(Self.book, editAfter: "Second chapter text.") { version in
            try await self.insertAsNewSection("Chapter 3", from: version)
        }
    }

    // MARK: - U6

    // CLAIM: a second Cmd-Z pressed while the first one's reinsert is still queued is HELD (not refused, not run ahead of the reinsert) and
    // acts after the release: both restores are undone, the rows are the original rows, both entries are on the redo stack. Two restores
    // (Replace Chapter 2, then Replace Chapter 3) are on the timeline.
    func testASecondCmdZPressedWhileTheRestoresUndoWaitsIsHeldAndActs() async throws {
        try await startRig(Self.book, undo: true)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED2", after: "Second chapter text.")
        try await typeAndSave(" EDITED3", after: "Third chapter text.")
        let rowsBefore = try rowSnapshot()
        let pre = try await pageText()
        let first = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(first, .performed)
        try await settleAll()
        let second = try await replaceSection("Chapter 3", from: version)
        XCTAssertEqual(second, .performed)
        try await settleAll()
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 2, "premise: two restores are on the timeline")
        let afterBoth = try await pageText()
        XCTAssertNotEqual(afterBoth, pre, "premise: the restores changed the page")
        let hold = holdReinserts()

        try await keyPress("undo")   // takes the second restore out; its reinsert is held
        try await waitForPage { $0.contains("Third chapter text. EDITED3") }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the first undo's reinsert is held")
        let pageAfterFirstUndo = try await pageText()
        XCTAssertFalse(pageAfterFirstUndo.contains("EDITED2"), "premise: the first restore is still in place")

        try await keyPress("undo")   // the second press: must wait for the reinsert
        await waitForParkedCommand("the second Cmd-Z")   // a signal, not a pause: the command is in the writer's list of parked callers
        let whileHeld = try await pageText()
        XCTAssertEqual(whileHeld, pageAfterFirstUndo, "the second Cmd-Z ran before the reinsert (it acted while the first undo's job was held)")
        XCTAssertEqual(rig.toastLog.lines, [], "the second press was refused with a notice")

        // TWO releases: the hold is a semaphore and BOTH undos make a reinsert job that waits at it.
        hold.release()
        hold.release()
        try await waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()
        let pageAfterBoth = try await pageText()
        XCTAssertEqual(pageAfterBoth, pre, "the second Cmd-Z was lost: the held press was refused instead of carried out")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the rows are not the original rows after both undos")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 2, "both entries are not on the redo stack")
        let held = try await heldPressCount()
        XCTAssertEqual(held, 0, "held count stuck (the page still holds a press)")
        assertQuiet("after both undos")
    }

    // MARK: - U7

    // CLAIM: a Delete made BEFORE a restore stays quick-undoable: the Markdown restore click does not bump `structuralOutOfQueueGeneration`
    // (only the old body does). Delete Chapter 4, Replace Chapter 3, Cmd-Z twice: the restore goes quick, then the Delete's section comes
    // back quick.
    func testAnEarlierDeleteStaysQuickUndoableAfterARestore() async throws {
        try await startRig(Self.book, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Third chapter text.")
        let rowsBefore = try rowSnapshot()
        let pre = try await pageText()
        let chapter4 = try rig.section("Chapter 4")
        let deleteOutcome = try await performDelete(rootId: chapter4.id)
        XCTAssertEqual(deleteOutcome, .performed)
        try await settleAll()
        await syncSectionTable()   // the window syncs the table from the document when it opens
        let generation = rig.editorState.structuralOutOfQueueGeneration

        let restoreOutcome = try await replaceSection("Chapter 3", from: version)
        XCTAssertEqual(restoreOutcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the restore fell back to the old body")
        try await settleAll()

        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.first)
        XCTAssertEqual(deleteEntry.kind, .sectionDelete, "premise: the Delete is the older entry")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "the restore click bumped structuralOutOfQueueGeneration")
        XCTAssertTrue(rig.controller.quickUndoEligible(deleteEntry), "Delete not quick: the restore made the earlier Delete's Cmd-Z a slow one")

        try await press("undo", until: { $0.contains("EDITED") }, "the first Cmd-Z did not undo the restore")
        try await press("undo", until: { $0.contains("# Chapter 4") }, "the second Cmd-Z did not bring Chapter 4 back")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 2, "Delete not quick: a Cmd-Z took the slow route")
        assertQuiet("after both Cmd-Z")
        let pageAfterBoth = try await pageText()
        XCTAssertEqual(pageAfterBoth, pre, "the page is not the page from before the Delete")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the rows are not the original rows after both undos")
    }
}
