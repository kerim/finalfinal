//
//  MarkdownQuickUndoTests+TypingAcrossUndo.swift
//  final finalTests
//
//  t-d2061b27 (Phase 4c, job 2, coder S round S1): the Swift side of "a Cmd-Z or Cmd-Shift-Z that waits keeps waiting when the user types,
//  then runs on the document as it was at the press with the typing put back on top" in MARKDOWN MODE, for the QUICK routes of a Delete
//  Section (StructuralUndoController+MarkdownQuickUndo.swift). An extension of MarkdownQuickUndoTests (it shares its rig and helpers): the
//  REAL CodeMirror page, a real database and writer, a real keydown through the real coordinator. Typing is user-origin (`userTypes`).
//
//  The user types "during the wait" in two places: while the press waits behind the delete's held job (before the job is released), and
//  through `testBeforeMarkdownPagePrepare`, which runs inside the press AFTER the page latched it and BEFORE the page's swap.
//
//    - testACmdZThatWaitsForTheDeleteIsCarriedOutWhenTheUserTypedAndTheTypingIsKeptInTheEditorAndTheRows   (the :33 test of
//      MarkdownQuickUndoTests+Refusals.swift, converted: it is carried out now; its refusal twin there uses `noEntry`)
//    - testAQuickRedoPressedWhileTheUserTypesElsewhereIsPerformedAndEndsTheRedoBranch                      (S5)
//    - testACloseRightAfterAWaitingCmdZAndTypingSavesTheTypingOnce                                           (D1, Markdown)
//
//  Break patches are in .claude/superdev/cmdz-waits-through-typing/break-patches/SW-<test name>.patch. Needs `cd web && pnpm build`.
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownQuickUndoTests {

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - The :33 test, converted

    // Delete Chapter 3 (its job held), Cmd-Z at once: the press waits for the job. The user types ww1 in Chapter 1 while it waits and rr9 in
    // Chapter 4 in the moment between the press's page preparation and its page call. The press is CARRIED OUT: Chapter 3 is back in the
    // editor and in the rows; ww1 and rr9 are in the editor and in the rows exactly once; no notice; the typing ended the redo branch (the
    // redo stack is empty and the slot says the undo happened); nothing is left held.
    // Predicted failure with the page-side fix taken out (docAtPress returns the live document): `XCTAssertFalse failed - the Cmd-Z did not
    // bring Chapter 3 back` and the notice. With `endRedoAfterReplayedTyping` an empty body: `XCTAssertTrue failed - typing in the wait must
    // end the redo branch`.
    func testACmdZThatWaitsForTheDeleteIsCarriedOutWhenTheUserTypedAndTheTypingIsKeptInTheEditorAndTheRows() async throws {
        try await startRig(Self.book4)
        rig.installReparseHost()   // ContentView's wiring: a re-parse can be (re-)armed through the lifecycle host
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id)
        let post = try await rig.pageText()
        XCTAssertFalse(post.contains("Chapter 3"), "premise: the editor already shows the delete")

        // Cmd-Z at once: the page decides "structural" and the press waits for the job.
        try await rig.press("undo")
        let waiting = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(waiting, "premise: the Cmd-Z reached the controller and waits for the delete's job")
        try await rig.userTypes(" ww1", after: "First chapter text.")
        let rigRef: MarkdownClickRig = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await rigRef.userTypes(" rr9", after: "Fourth chapter text.")
        }

        hold.release()
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle && !self.rig.markdownWriter.isHeldForStructuralWork }
        await rig.settleEverything()
        rig.controller.testBeforeMarkdownPagePrepare = nil

        // Carried out: no notice, Chapter 3 is back, the typing is in one piece in the editor and in the rows, once each.
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice or progress toast is showing")
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown for typing")
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("Chapter 3"), "the Cmd-Z did not bring Chapter 3 back")
        XCTAssertTrue(page.contains("First chapter text. ww1"), "ww1 is not where it was typed in the editor")
        XCTAssertTrue(page.contains("Fourth chapter text. rr9"), "rr9 is not where it was typed in the editor")
        XCTAssertEqual(occurrences(of: "ww1", in: page), 1, "ww1 is in the editor more than once")
        XCTAssertEqual(occurrences(of: "rr9", in: page), 1, "rr9 is in the editor more than once")
        let saved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("rr9")) == true }
        XCTAssertTrue(saved, "rr9 typed during the wait never reached the rows")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("Chapter 3"), "Chapter 3 is not back in the rows")
        XCTAssertEqual(occurrences(of: "ww1", in: stored), 1, "ww1 is in the rows \(occurrences(of: "ww1", in: stored)) times")
        XCTAssertEqual(occurrences(of: "rr9", in: stored), 1, "rr9 is in the rows \(occurrences(of: "rr9", in: stored)) times")
        try await assertRowsMatchPage("after the carried-out Cmd-Z")

        // The typing ended the redo branch; the slot says the undo happened; nothing is stuck.
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "typing in the wait must end the redo branch")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the entry stayed on the undo stack although the Cmd-Z was carried out")
        let state = rig.controller.efSlots.slot(opId)?.state
        XCTAssertTrue(
            state == .quickUndone || state == .reinserted || state == nil,
            "the slot says the undo did not happen (\(String(describing: state)))")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(rig.editorState.pendingReinsertCount, 0, "a reinsert is still pending")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "a step-8 gate was kept")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "the page still holds a press")
    }

    // MARK: - S5: the quick redo

    // Two Deletes (Chapter 4, then Chapter 3), both undone the quick way: two entries wait on the redo stack, the one for Chapter 4 on top.
    // Cmd-Shift-Z, and the user types in Chapter 1 (elsewhere than the text the redo takes out) while the press waits. The redo is
    // PERFORMED, the typing reaches the rows once, no notice, and the typing ended the WHOLE redo branch: the older entry (Chapter 3's)
    // is no longer redoable.
    // Predicted failure with `endRedoAfterReplayedTyping` taken out of `markdownQuickRedo`: `XCTAssertTrue failed - the older redo entry
    // survived the typing`. With the page-side fix taken out the redo is refused: `XCTAssertTrue failed - the redo did not delete Chapter 4 again`.
    func testAQuickRedoPressedWhileTheUserTypesElsewhereIsPerformedAndEndsTheRedoBranch() async throws {
        try await startRig(Self.book4)
        rig.installReparseHost()
        _ = try await deleteSection("Chapter 4")
        _ = try await deleteSection("Chapter 3")
        let chapter4Entry = try XCTUnwrap(rig.unifiedUndo.undoStack.first, "premise: the Delete of Chapter 4 recorded no entry")
        try await press("undo", until: { $0.contains("Chapter 3") && !$0.contains("Chapter 4") }, "the first Cmd-Z did not bring Chapter 3 back")
        try await press("undo", until: { $0.contains("Chapter 4") }, "the second Cmd-Z did not bring Chapter 4 back")
        XCTAssertEqual(rig.unifiedUndo.redoStack.count, 2, "premise: two entries wait for a redo")
        XCTAssertEqual(rig.unifiedUndo.redoStack.last?.id, chapter4Entry.id, "premise: Chapter 4's entry is the next redo")
        assertQuiet("before the redo")

        let rigRef: MarkdownClickRig = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await rigRef.userTypes(" rr9", after: "First chapter text.")
        }
        let page = try await press(
            "redo", until: { !$0.contains("Chapter 4") && $0.contains("rr9") }, "the redo did not delete Chapter 4 again with the typing kept")
        rig.controller.testBeforeMarkdownPagePrepare = nil

        XCTAssertTrue(page.contains("First chapter text. rr9"), "rr9 is not where it was typed")
        XCTAssertEqual(occurrences(of: "rr9", in: page), 1, "rr9 is in the editor more than once")
        let saved = await rig.waitUntil { self.occurrences(of: "rr9", in: (try? self.rig.writerRig.storedText()) ?? "") == 1 }
        XCTAssertTrue(saved, "the typing done during the redo's wait never reached the rows exactly once")
        let stored = try rig.writerRig.storedText()
        XCTAssertFalse(stored.contains("Chapter 4"), "Chapter 4 is still in the rows")
        try await assertRowsMatchPage("after the redo")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, chapter4Entry.id, "the redone entry is not back on the undo stack")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the older redo entry survived the typing")
        assertQuiet("after the redo")
    }

    // MARK: - D1: a close right after a waiting Cmd-Z and typing

    // Delete Chapter 3 (its job held), Cmd-Z at once (the press waits behind the job), the user types, with an Enter, and then closes the
    // project at once. The close places its barrier; when the job is released the waiting press finds the gate closed and is CANCELLED
    // (review F15: it is not carried out, no notice, the delete stands, the entry stays on the undo stack, the page clears its latch),
    // and the close saves: the typing is in the rows exactly once (the closing save pulls CodeMirror's live document through the captured
    // view, so the page's hold on its typing pushes does not hide the typing from it) and in the editor exactly once. The Rich Text twin
    // needs the page's `releaseHeldTypingPushes`, called by the lifecycle (TypingAcrossUndoReviewTests T-a).
    // Predicted failure if the closing save missed the typing: `XCTAssertEqual failed - ("0") is not equal to ("1")`.
    func testACloseRightAfterAWaitingCmdZAndTypingSavesTheTypingOnce() async throws {
        try await startRig(Self.book4)
        rig.installReparseHost()
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let deleteEntryId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id, "premise: the Delete recorded no entry")
        try await rig.press("undo")
        let waiting = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(waiting, "premise: the Cmd-Z reached the controller and waits for the delete's job")
        try await rig.userTypes(" dd4\n\nmore words", after: "First chapter text.")

        // Cmd-W at once.
        let close = Task { @MainActor in await self.runClose() }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isClosedToNewWork }
        hold.release()
        let result = await close.value
        await rig.settleEverything()

        XCTAssertEqual(result.outcome, .flushed, "the close did not run to the end: \(result.outcome)")
        // Round S4: the closing save carried the typing from the LIVE page text (step 5 pulls CodeMirror's document through the captured
        // view), not from the content record, which the page leaves stale while a press is latched. The rows assertions below would pass
        // even if step 5 fell back (the Delete's own step 8 reads the live text when its job ends, and the page's released push reaches
        // the record), so these two pin step 5 itself: SW-D1-markdown-close-typing-lost.patch (Markdown never takes the live fetch) fails them.
        XCTAssertFalse(result.usedFallback, "the closing save fell back to the content record instead of reading the live page text")
        XCTAssertEqual(
            result.fetchedContent.map { occurrences(of: "more words", in: $0) }, 1,
            "the text the closing save wrote does not hold the typing exactly once: \(String(describing: result.fetchedContent))")
        // The waiting press was cancelled by the close, not carried out: the delete stands, its entry is still the top of the undo stack,
        // nothing is redoable, no notice was shown, and the page holds nothing (the latch was cleared by the `cancelled` reply).
        let afterClose = try await rig.pageText()
        XCTAssertFalse(afterClose.contains("Chapter 3"), "the waiting Cmd-Z was carried out although a close had begun")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, deleteEntryId, "the waiting Cmd-Z moved the entry")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the entry moved to the redo stack")
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown for a press cancelled by a close")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "the page still holds a press")
        let stored = try rig.writerRig.storedText()
        XCTAssertEqual(occurrences(of: "more words", in: stored), 1, "the typing is in the rows \(occurrences(of: "more words", in: stored)) times")
        XCTAssertEqual(occurrences(of: "dd4", in: stored), 1, "dd4 is in the rows \(occurrences(of: "dd4", in: stored)) times")
        let page = try await rig.pageText()
        XCTAssertEqual(occurrences(of: "more words", in: page), 1, "the typing is in the editor \(occurrences(of: "more words", in: page)) times")
    }

    /// The close save sequence under an armed token (production bounds), then what `LifecycleEntry.finish` does afterwards.
    private func runClose() async -> LifecycleFlushResult {
        guard case .armed(let token) = rig.editorState.armLifecycle(.close, wasGettingStarted: false) else {
            XCTFail("the rig could not arm a close token")
            return LifecycleFlushResult()
        }
        let bounds = LifecycleBounds.production
        let result = await rig.editorState.runLifecycleFlush(
            token: token, host: QuitFlushTestSupport.host(webView: rig.helper.webView), structuralUndoController: rig.controller,
            deadline: LifecycleDeadline(total: bounds.closeTotal), bounds: bounds)
        rig.editorState.lifecycleBarrier?.release()
        rig.editorState.lifecycleBarrier = nil
        rig.editorState.structuralGate.isClosedToNewWork = false
        rig.editorState.clearLifecycle(token.id)
        return result
    }
}
