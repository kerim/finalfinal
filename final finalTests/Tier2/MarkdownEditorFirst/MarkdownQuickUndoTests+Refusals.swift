//
//  MarkdownQuickUndoTests+Refusals.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, review-fix round: the tests of MarkdownQuickUndoTests that
//  are about a press the page or the timeline REFUSED, and two settles that overlap. An extension of that class (it shares its rig and
//  helpers); typing is user-origin (`userTypes`). Needs `cd web && pnpm build`. NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   refused (review C.F8 + F2)  Delete, Cmd-Z at once while the job applies, the user types during the wait AND in the moment between the
//          press's cancel of the pending re-parse and its page call: the page answers `changed`, the existing notice shows, the delete
//          stands, the typing is in the editor and (re-armed re-parse) in the rows, the hold is lowered, the entry stays on the undo stack.
//          BREAK: in `markdownQuickUndo` delete the `rearmMarkdownReparseAfterRefusedPress()` line.
//          FAILS: "rr9 typed while the press was being prepared never reached the rows".
//   DR-6   a quick redo whose timeline was cleared mid-press (a barrier) tells the user, like its quick-undo twin.
//          BREAK: in `markdownQuickRedo` delete the `if !closed { showUndoQueueDroppedWarning() }` line.
//          FAILS: "the redo failed mid-press without telling the user".
//   F9/M-5 two footnoted Deletes back to back, then Cmd-Z twice: the first Cmd-Z restores the second chapter (it is not a step that only
//          renumbers footnotes), the second restores the first.
//          BREAK: in `unmarkMarkdownSettle` send `setStructuralSettleOpId(null)` without the opId (overlapping settles clear each other).
//          FAILS: "the first Cmd-Z only renumbered" (when the two settles overlap; the deterministic check is the settle-flag test in
//          MarkdownSettleBranchTests).
//
import Foundation
import XCTest
@testable import final_final

extension MarkdownQuickUndoTests {

    // MARK: - A refused swap (C.F8 and F2)

    func testACmdZThatWaitsForTheDeleteIsRefusedWhenTheUserTypedAndTheTypingIsKeptInTheEditorAndTheRows() async throws {
        try await startRig(Self.book4)
        rig.installReparseHost()   // ContentView's wiring: a re-parse can be (re-)armed through the lifecycle host
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id)
        let post = try await rig.pageText()
        XCTAssertFalse(post.contains("Chapter 3"), "premise: the editor already shows the delete")

        // Cmd-Z at once: the page decides "structural" (the document still equals the post-Delete copy) and the press waits for the job.
        try await rig.press("undo")
        let waiting = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(waiting, "premise: the Cmd-Z reached the controller and waits for the delete's job")
        // The user types while the press waits: step 8's live read (after the release) carries this into the rows.
        try await rig.userTypes(" ww1", after: "First chapter text.")

        // The moment between the press cancelling the pending re-parse and asking the page to swap: the user types again, the page
        // reports it to the record, and ContentView (the rig, by hand) has armed a re-parse for it which the press then cancels.
        let rigRef: MarkdownClickRig = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await rigRef.userTypes(" rr9", after: "Fourth chapter text.")
            _ = await rigRef.waitUntil { rigRef.editorState.content.contains("rr9") }
            rigRef.editorState.sourceReparseDebounce = .seconds(30)
            _ = rigRef.writerRig.schedule(rigRef.editorState.content)
            rigRef.editorState.sourceReparseDebounce = .milliseconds(20)   // what the re-armed re-parse will use
        }

        hold.release()
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle && !self.rig.markdownWriter.isHeldForStructuralWork }
        await rig.settleEverything()

        // The press was refused with the existing notice, once; the delete stands; the typing is in the editor ...
        XCTAssertEqual(rig.editorState.toastCenter.current?.message, Self.droppedNotice, "the refused press showed no notice")
        XCTAssertEqual(rig.toastLog.lines.filter { $0.contains(Self.droppedNotice) }.count, 1, "the notice was shown more than once")
        let page = try await rig.pageText()
        XCTAssertFalse(page.contains("Chapter 3"), "the refused Cmd-Z undid the delete anyway")
        XCTAssertTrue(page.contains("ww1") && page.contains("rr9"), "typing made while the press was refused is gone from the editor")
        // ... and in the rows: ww1 by step 8's flush, rr9 only by the re-armed re-parse (nothing else arms one in this rig).
        let saved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("rr9")) == true }
        XCTAssertTrue(saved, "rr9 typed while the press was being prepared never reached the rows")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("ww1"), "ww1 typed while the press waited never reached the rows")
        XCTAssertFalse(stored.contains("Chapter 3"), "the chapter is back in the rows")

        // Nothing is stuck, and the entry is where it was.
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(rig.editorState.pendingReinsertCount, 0, "a reinsert is still pending")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "a step-8 gate was kept")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "the page still holds a press")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, opId, "the entry left the undo stack")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the entry moved to the redo stack although the press was refused")
        XCTAssertEqual(rig.controller.efEditorKind[opId], .markdown, "the entry's kind was dropped")
        let state = rig.controller.efSlots.slot(opId)?.state
        XCTAssertTrue(state != .quickUndone && state != .reinserted, "the slot says the undo happened (\(String(describing: state)))")
    }

    // MARK: - DR-6

    func testAQuickRedoWhoseTimelineWasClearedMidPressTellsTheUser() async throws {
        try await startRig(Self.book4)
        let (pre, post) = try await deleteSection("Chapter 3")
        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        assertQuiet("after the Cmd-Z")

        // A barrier (a zoom, a mode switch) lands while the Cmd-Shift-Z is being carried out: the timeline is cleared under it.
        let unifiedUndo = rig.unifiedUndo
        rig.controller.testOrderingSpy = { step in
            if step == "quickRedoJobReserved" { unifiedUndo.invalidateAll(reason: "test: a barrier mid-press") }
        }
        try await rig.press("redo")
        let shown = await rig.waitUntil { self.rig.editorState.toastCenter.current?.message == Self.droppedNotice }
        XCTAssertTrue(shown, "the redo failed mid-press without telling the user")

        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        // The section is off the screen and its delete was queued: the rows follow, and nothing is left half done.
        let page = try await rig.pageText()
        XCTAssertEqual(page, post, "the editor does not show the delete")
        try await assertRowsMatchPage("after the failed redo")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending")
    }

    // MARK: - F9/M-5

    func testTwoFootnotedDeletesBackToBackAreUndoneOneAtATimeWithNoStepThatOnlyRenumbers() async throws {
        try await startRig(Self.footnotedBook4)
        let original = try await rig.pageText()
        let chapter1 = try rig.section("Chapter 1")
        let chapter2 = try rig.section("Chapter 2")

        let first = await rig.controller.performSectionDelete(rootId: chapter1.id)
        XCTAssertEqual(first, .performed)
        let second = await rig.controller.performSectionDelete(rootId: chapter2.id)   // at once: it waits for the first job's apply
        XCTAssertEqual(second, .performed)
        await rig.settleEverything()
        let afterBoth = try await rig.pageText()
        XCTAssertFalse(afterBoth.contains("Chapter 1") || afterBoth.contains("Chapter 2"), "premise: both chapters are gone")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 2, "premise: two entries on the timeline")

        try await press(
            "undo", until: { $0.contains("Chapter 2") && !$0.contains("Chapter 1") },
            "the first Cmd-Z only renumbered: Chapter 2 is not back")
        try await press("undo", until: { $0.contains("Chapter 1") && $0.contains("Chapter 2") }, "the second Cmd-Z did not bring Chapter 1 back")
        assertQuiet("after both Cmd-Z")
        let page = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        XCTAssertEqual(lines(page), lines(MarkdownLeaderMap.recordText(fromRaw: original)), "the two Cmd-Z did not restore the original document")
        try await assertRowsMatchPage("after both Cmd-Z")
    }
}
