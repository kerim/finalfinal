//
//  MarkdownEditorFirstDuplicateTests+Undo.swift
//  final finalTests
//
//  t-4a8fd8af slice 3, round C2: the tests of the Markdown Duplicate that involve a real Cmd-Z or Cmd-Shift-Z (`MarkdownClickRig` with
//  `routesUndo`: a real keydown reaches the controller through the real coordinator, as in the app). An extension of the class in
//  MarkdownEditorFirstDuplicateTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first.
//
//  HOW "QUICK" IS PROVEN. Not by timing. The controller's ordering spy (`testOrderingSpy`) sees `quickUndoRestoreApplied` once per
//  quick Cmd-Z and `quickRedoJobReserved` once per quick Cmd-Shift-Z (StructuralUndoController+MarkdownQuickUndo.swift); the slow
//  route passes neither. The rig's toast log must stay empty too (no "Undoing…" / "Redoing…" / "Finishing the last change…").
//
//  Break patches: docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/swift-<TESTID>.patch. The failure
//  each shows:
//
//   U5   testCmdZCmdShiftZOfADuplicateAreQuickWithNoNoticeAndTheCopyKeepsItsIds
//        BREAK A: fresh `UUID()` copies in `markdownQuickRedo`'s duplicate branch.   FAILS: "redo copy ids differ" (cycle 1)
//        BREAK B (patch swift-U5b): that branch returns nil, so the redo takes the slow route.   FAILS: "was not quick"
//   U5d  testCmdShiftZPressedWhileTheUndosJobIsHeldIsAppliedAfterwards (judge D3)
//        BREAK: delete `await editorState.markdownWriter.awaitStructuralHoldReleased()` in `resolveMarkdownQuickPath` (shared with the
//        undo and the Delete; the redo route has no wait of its own).   FAILS: "the redo ran before the undo's job applied"
//   U6   testASecondCmdZPressedWhileTheDuplicatesUndoWaitsIsHeldAndActs
//        BREAK: release the undo's hold before `startReinsert` in `markdownQuickUndo`.   FAILS: "the second Cmd-Z ran before the reinsert"
//   U7   testAnEarlierDeleteStaysQuickUndoableAfterADuplicate
//        BREAK: `editorState.structuralOutOfQueueGeneration &+= 1` in the click.   FAILS: "Delete not quick"
//   U20  testDeletingTheCopyAtOnceIsHeldAndTwoCmdZBringItBackThenTakeItOut   (in +Chain.swift)
//        BREAK: do not record `efRecordedStructGeneration[opId]` in the click.   FAILS: "slow route"
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstDuplicateTests {

    /// A real keydown; waits until the page's text satisfies `condition`, then until the structural gate and everything the press started
    /// have finished.
    @discardableResult @nonobjc   // internal on an XCTestCase: without `@nonobjc` its async ObjC thunk would capture the non-escaping closure
    func press(_ direction: String, until condition: @escaping (String) -> Bool, _ message: String) async throws -> String {
        try await keyPress(direction)
        let text = try await waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()
        return text
    }

    /// Duplicates `title` and lets everything the click started finish. Returns the page before and after.
    func duplicateAndSettle(_ title: String) async throws -> (pre: String, post: String) {
        let pre = try await pageText()
        let outcome = try await duplicate(title)
        XCTAssertEqual(outcome, .performed)
        try await settleAll()
        return (pre, try await pageText())
    }

    // MARK: - U5

    // CLAIM: Cmd-Z and Cmd-Shift-Z of a Markdown Duplicate are QUICK (no "Undoing…" / "Redoing…" notice, the quick route's steps are
    // seen), the rows after the undo are the rows before the Duplicate (ids, text, status, tags), the page after the redo is the page
    // the click made (markers included), and the redo's copy leader has the SAME id as the click's, on both of TWO full cycles.
    func testCmdZCmdShiftZOfADuplicateAreQuickWithNoNoticeAndTheCopyKeepsItsIds() async throws {
        try await startRig(Self.book4, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        try rig.writerRig.setMetadata(onHeading: "Chapter 3", status: .review, tags: ["alpha"], wordGoal: 500)
        let rowsBefore = try rowSnapshot()
        let (pre, post) = try await duplicateAndSettle("Chapter 3")
        let clickId = try XCTUnwrap(Self.markerId(in: post, headingTitled: "Chapter 3 copy"), "premise: the click's copy has a marker")
        XCTAssertEqual(try headingRows("Chapter 3 copy").map(\.id), [clickId], "premise: the copy row has the marker's id")

        for cycle in 1...2 {
            try await press("undo", until: { $0 == pre }, "cycle \(cycle): Cmd-Z did not take the copy out (the text from before the Duplicate)")
            assertQuiet("after the Cmd-Z of cycle \(cycle)")
            XCTAssertEqual(spy.count("quickUndoRestoreApplied"), cycle, "cycle \(cycle): the Cmd-Z was not quick")
            XCTAssertEqual(try rowSnapshot(), rowsBefore, "cycle \(cycle): rows after Cmd-Z differ from the rows before the Duplicate")
            try await assertRowsMatchPage("after the Cmd-Z of cycle \(cycle)")

            try await press("redo", until: { $0 == post }, "cycle \(cycle): Cmd-Shift-Z did not bring back the copy the click made")
            assertQuiet("after the Cmd-Shift-Z of cycle \(cycle)")
            XCTAssertEqual(spy.count("quickRedoJobReserved"), cycle, "cycle \(cycle): the Cmd-Shift-Z was not quick")
            XCTAssertEqual(
                try headingRows("Chapter 3 copy").map(\.id), [clickId],
                "cycle \(cycle): redo copy ids differ from the click's (the copy came back with another id)")
            let pageAfterRedo = try await pageText()
            XCTAssertEqual(
                Self.markerId(in: pageAfterRedo, headingTitled: "Chapter 3 copy"), clickId,
                "cycle \(cycle): the redo's page marker is not the click's id")
            try await assertRowsMatchPage("after the Cmd-Shift-Z of cycle \(cycle)")
        }
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 1, "the entry is not back on the undo stack")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty)
    }

    // MARK: - U5d (judge D3)

    // CLAIM: a Cmd-Shift-Z pressed while the undo's job is still HELD is applied afterwards: nothing is dropped, refused or announced.
    func testCmdShiftZPressedWhileTheUndosJobIsHeldIsAppliedAfterwards() async throws {
        try await startRig(Self.book4, undo: true)
        let (pre, post) = try await duplicateAndSettle("Chapter 3")
        let clickId = try XCTUnwrap(Self.markerId(in: post, headingTitled: "Chapter 3 copy"))
        let hold = holdReinserts()

        try await keyPress("undo")
        try await waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the undo's reinsert is held, so the writer's hold is up")

        try await keyPress("redo")
        await waitForParkedCommand("the Cmd-Shift-Z")   // a signal, not a pause: the command is in the writer's list of parked callers
        let whileHeld = try await pageText()
        XCTAssertEqual(whileHeld, pre, "the redo ran before the undo's job applied")
        XCTAssertEqual(rig.toastLog.lines, [], "the press was refused with a notice (shown and replaced)")
        XCTAssertNil(rig.editorState.toastCenter.current, "the press was refused with a notice")

        hold.release()
        try await waitForPage { $0 == post }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()
        let page = try await pageText()
        XCTAssertEqual(page, post, "the held Cmd-Shift-Z was lost instead of carried out")
        XCTAssertEqual(try headingRows("Chapter 3 copy").map(\.id), [clickId], "the redo's copy has another id than the click's")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 1, "the entry is not back on the undo stack")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the redo stack still holds the entry")
        let held = try await heldPressCount()
        XCTAssertEqual(held, 0, "held count stuck (the page still holds a press)")
        try await assertRowsMatchPage("after the held Cmd-Shift-Z")
        assertQuiet("after the held Cmd-Shift-Z")
    }

    // MARK: - U6

    // CLAIM: a second Cmd-Z pressed while the first one's reinsert is still queued is HELD (not refused, not run ahead of the reinsert)
    // and acts after the release: both copies are gone, the rows are the original rows. Two Duplicates are on the timeline.
    func testASecondCmdZPressedWhileTheDuplicatesUndoWaitsIsHeldAndActs() async throws {
        try await startRig(Self.book4, undo: true)
        let rowsBefore = try rowSnapshot()
        let pre = try await pageText()
        _ = try await duplicateAndSettle("Chapter 2")
        let (afterFirst, _) = try await duplicateAndSettle("Chapter 3")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 2, "premise: two Duplicates are on the timeline")
        let hold = holdReinserts()

        try await keyPress("undo")   // takes the copy of Chapter 3 out; its reinsert is held
        try await waitForPage { !$0.contains("Chapter 3 copy") }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the first undo's reinsert is held")
        let pageAfterFirstUndo = try await pageText()
        XCTAssertTrue(pageAfterFirstUndo.contains("Chapter 2 copy"), "premise: the copy of Chapter 2 is still there")

        try await keyPress("undo")   // the second press: must wait for the reinsert
        await waitForParkedCommand("the second Cmd-Z")   // a signal, not a pause: the command is in the writer's list of parked callers
        let whileHeld = try await pageText()
        XCTAssertEqual(whileHeld, pageAfterFirstUndo, "the second Cmd-Z ran before the reinsert (it acted while the first undo's job was held)")
        XCTAssertEqual(rig.toastLog.lines, [], "the second press was refused with a notice")

        // TWO releases: the hold is a semaphore and BOTH undos make a reinsert job that waits at it (round C2b: with one release the
        // second undo's reinsert blocked the writer for ever and the settle below never returned).
        hold.release()
        hold.release()
        try await waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()
        let pageAfterBoth = try await pageText()
        XCTAssertEqual(pageAfterBoth, pre, "the held second Cmd-Z was lost instead of carried out")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the rows are not the original rows after both undos")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 2, "both entries are not on the redo stack")
        let held = try await heldPressCount()
        XCTAssertEqual(held, 0, "held count stuck (the page still holds a press)")
        assertQuiet("after both undos")
        XCTAssertNotEqual(afterFirst, pre, "premise: the Duplicates changed the page")
    }

    // MARK: - U7

    // CLAIM: a Delete made BEFORE a Duplicate stays quick-undoable: the Duplicate click does not bump `structuralOutOfQueueGeneration`
    // (only the old body does). Delete A, Duplicate B, Cmd-Z twice: B's copy goes quick, then A returns quick.
    func testAnEarlierDeleteStaysQuickUndoableAfterADuplicate() async throws {
        try await startRig(Self.book4, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let rowsBefore = try rowSnapshot()
        let pre = try await pageText()
        let chapter1 = try rig.section("Chapter 1")
        let deleteOutcome = try await performDelete(rootId: chapter1.id)
        XCTAssertEqual(deleteOutcome, .performed)
        try await settleAll()
        let generation = rig.editorState.structuralOutOfQueueGeneration
        let (_, afterDuplicate) = try await duplicateAndSettle("Chapter 3")

        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.first)
        XCTAssertEqual(deleteEntry.kind, .sectionDelete, "premise: the Delete is the older entry")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "the Duplicate click bumped structuralOutOfQueueGeneration")
        XCTAssertTrue(rig.controller.quickUndoEligible(deleteEntry), "Delete not quick: the Duplicate made the earlier Delete's Cmd-Z a slow one")

        try await press("undo", until: { !$0.contains("Chapter 3 copy") }, "the first Cmd-Z did not take the copy out")
        try await press("undo", until: { $0.contains("# Chapter 1") }, "the second Cmd-Z did not bring Chapter 1 back")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 2, "Delete not quick: a Cmd-Z took the slow route (slow route)")
        assertQuiet("after both Cmd-Z")
        let pageAfterBoth = try await pageText()
        XCTAssertEqual(pageAfterBoth, pre, "the page is not the page from before the Delete")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the rows are not the original rows after both undos")
        XCTAssertNotEqual(afterDuplicate, pre, "premise: the Duplicate and the Delete changed the page")
    }
}
