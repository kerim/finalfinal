//
//  MarkdownEditorFirstRestoreTests+Review.swift
//  final finalTests
//
//  t-4a8fd8af slice 4, round F2: the two tests the code review's rulings C1 and C2 asked for (judge-review-verdicts.md). An extension of the
//  class in MarkdownEditorFirstRestoreTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//   U18  testTheRedoOfARestoreWhosePlanVanishesBetweenTheResolveAndTheSwapStillStartsItsJobAndSettles   (C1)
//        BREAK: in `markdownQuickRedoComposedReplyTurn` read `efRestorePlans[opId]` again after the swap, and return early when it is nil
//        (the code before the fix) instead of using the `restorePlan` that `resolveMarkdownQuickPath` captured.
//        FAILS: "the redo's registry key never settled" (the redo returned after the page had swapped without starting its job)
//   U19  testABarrierThatLandsDuringTheRestoreClickIsNotRecordedAndTheRestoreStands   (C2)
//        BREAK: read `unifiedUndoService.generation` after the page call (the old position, just before `markdownRestoreReplyTurn`).
//        FAILS: "the click returned .performed" (the barrier is older than the epoch the click compares against, so the entry is recorded)
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstRestoreTests {

    // MARK: - U18 (C1): the redo's plan is captured at resolve time

    // CLAIM: a restore entry's plan is read ONCE, in `resolveMarkdownQuickPath`, and handed down to the quick redo. If the entry's plan is
    // gone from `efRestorePlans` between that read and the composed-redo reply turn (here: a hook that runs inside the redo's own
    // `prepareMarkdownPageForStructuralCommand`, after the resolve and before the page swap, clears it; in the app an Outline status or tag
    // edit, or an annotation toggle, drops the timeline entry there), the redo still starts its job from the captured plan and the redo's
    // registry key settles: the page shows the restored text again, the rows are the click's rows (the same ids), nothing stays unsettled
    // or held, and the entry is usable again (a third Cmd-Z is a quick undo). With the old code the redo returned after the page had
    // swapped and never started a job: the page showed the restored text, the rows did not, and the key never settled.
    //
    // The hook is set right before the redo is pressed and is ONE-SHOT (the quick undo calls the same function too).
    func testTheRedoOfARestoreWhosePlanVanishesBetweenTheResolveAndTheSwapStillStartsItsJobAndSettles() async throws {
        try await startRig(Self.book, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let pre = try await pageText()
        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        let post = try await pageText()
        let rowsAfterClick = try rowSnapshot()
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id, "premise: the restore is on the timeline")
        XCTAssertNotNil(rig.controller.efRestorePlans[opId], "premise: the entry has its plan")
        XCTAssertNotEqual(post, pre, "premise: the restore changed the page")

        try await press("undo", until: { $0 == pre }, "Cmd-Z did not bring back the text from before the restore")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 1, "premise: the Cmd-Z was quick")

        // The plan vanishes after `resolveMarkdownQuickPath` has read it and before the page swaps (one-shot).
        let controller = rig.controller
        rig.controller.testBeforeMarkdownPagePrepare = {
            controller.testBeforeMarkdownPagePrepare = nil
            controller.efRestorePlans[opId] = nil
        }
        try await keyPress("redo")
        try await waitForPage { $0 == post }
        let finished = await rig.waitUntil(10) {
            !self.rig.editorState.efJobRegistry.hasUnsettledWork && !self.rig.markdownWriter.isHeldForStructuralWork
        }
        XCTAssertTrue(
            finished,
            "the redo's registry key never settled, or the hold stayed up (the redo returned after the page had swapped without starting its job)")
        guard finished else { return }   // the settle below would only wait out its 15-second bound
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        try await settleAll()

        XCTAssertEqual(try rowSnapshot(), rowsAfterClick, "the rows after the redo are not the click's rows (the redo's job did not run)")
        try await assertRowsMatchPage("after the redo whose plan vanished")
        assertQuiet("after the redo whose plan vanished")
        XCTAssertEqual(rig.unifiedUndo.undoStack.filter { $0.id == opId }.count, 1, "the entry is not back on the undo stack exactly once")
        XCTAssertNotNil(rig.controller.efRestorePlans[opId], "the redo's reply turn did not put the captured plan back")

        // The entry is usable again: a third Cmd-Z is a quick undo.
        try await press("undo", until: { $0 == pre }, "the Cmd-Z after the redo did not bring back the text from before the restore")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 2, "the Cmd-Z after the redo was not quick")
        XCTAssertEqual(spy.count("markdownSlowSwapReserved"), 0, "the Cmd-Z after the redo took the queued route")
    }

    // MARK: - U19 (C2): the epoch is read right after the hold goes up

    // CLAIM: the click reads the timeline generation right after `beginStructuralHold()` (before anything suspends), as Rich Text does. A
    // barrier (`unifiedUndoService.invalidateAll`: an Outline status or tag edit, an annotation toggle, a hierarchy fix) that lands DURING the
    // click, here inside the click's own `prepareMarkdownPageForStructuralCommand` (after the epoch read, before the page call), therefore
    // moves the generation past the click's epoch and `recordRestoreEntry` refuses to record.
    //
    // WHAT THE CODE DOES THEN (read from `recordRestoreEntry`'s generation-moved branch and the click's tail, asserted below):
    //   - the restore itself still happened and is saved: the page shows the restored text, the job runs and the rows follow
    //     (the user has "restored, but cannot press Cmd-Z"); the hold goes down when the job ends; the sidebar overlay is lifted;
    //   - the click returns `.failedAfterCommit` (not `.performed`), and NO entry for the operation is on the undo or redo stack;
    //   - the Swift-side per-operation state is cleaned (`forgetQuickUndoState`: plan, kind, holder, job keys; the slot; the epoch);
    //   - `recordRestoreEntry` does NOT touch the page. A barrier that lands AFTER the page call has already cleared the page's registry
    //     (`UnifiedUndoService.clearStructuralRegistry`, wired by ContentView). This one landed BEFORE the page call, so the page records
    //     its entry for the operation after that clear, and nothing removes it: the page keeps a registry entry (and the undo descriptor
    //     `undoTopOpId`) for an operation Swift never recorded. The last assertion pins that CURRENT behaviour (the entry answers
    //     `changed`, not `noEntry`, to a redo probe, which changes nothing in the page). It is an observation, reported to the driver, not a
    //     requirement: flip it if the page side is ever cleaned up in that branch. The test wires `clearStructuralRegistry` the way
    //     ContentView does (the rig does not), so the barrier really does ask the page to clear its registry, before the page call.
    func testABarrierThatLandsDuringTheRestoreClickIsNotRecordedAndTheRestoreStands() async throws {
        try await startRig(Self.book, undo: true)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let hold = holdJobs()   // the job stays held, so the operation's id is still readable (the overlay is keyed by it) below
        let generationBefore = rig.unifiedUndo.generation
        let unifiedUndo = rig.unifiedUndo
        let controller = rig.controller
        let webView = rig.helper.webView
        unifiedUndo.clearStructuralRegistry = {   // as ContentView wires it
            webView.evaluateJavaScript("window.FinalFinal.clearStructuralUndoRegistry()") { _, _ in }
        }
        rig.controller.testBeforeMarkdownPagePrepare = {
            controller.testBeforeMarkdownPagePrepare = nil   // one-shot
            unifiedUndo.invalidateAll(reason: "test: a barrier lands during the restore click")
        }

        let outcome = try await replaceSection("Chapter 2", from: version)

        XCTAssertGreaterThan(rig.unifiedUndo.generation, generationBefore, "premise: the barrier ran during the click")
        XCTAssertEqual(
            outcome, .failedAfterCommit,
            "the click returned \(outcome) (the barrier is older than the epoch the click compares against, so the entry was recorded)")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.isEmpty, "an entry for the restore is on the timeline")
        XCTAssertTrue(rig.controller.efRestorePlans.isEmpty, "the entry's plan was kept")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the entry's kind was kept")
        XCTAssertTrue(rig.controller.efHolders.isEmpty, "the entry's payload holder was kept")
        XCTAssertTrue(rig.controller.efOpEpoch.isEmpty, "the operation's epoch was kept")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")
        let pageWhileHeld = try await pageText()
        XCTAssertFalse(pageWhileHeld.contains("EDITED"), "the page does not show the restore although the click went through")

        // Observation (see the CLAIM): what the page still holds for the operation. The overlay is keyed by the operation's id.
        let opId = try XCTUnwrap(rig.editorState.pendingRestoreSections.keys.first, "premise: the sidebar overlay is up while the job is held")
        let probe = try await bounded("asking the page about the operation", seconds: 10) {
            (try? await self.rig.helper.webView.evaluateJavaScript(
                "JSON.stringify(window.FinalFinal.markdownStructuralSwap('\(opId.uuidString)', 'redo'))")) as? String
        }
        XCTAssertTrue(
            probe?.contains("\"reason\":\"changed\"") == true,
            "the page's answer for the unrecorded operation was \(probe ?? "nil") "
                + "(observation: it keeps its entry; `noEntry` means the page side is now cleaned up)")

        hold.release()
        try await settleAll()
        let page = try await pageText()
        XCTAssertFalse(page.contains("EDITED"), "the restore did not stand on the page")
        XCTAssertFalse(try rig.writerRig.storedText().contains("EDITED"), "the restore did not reach the rows")
        try await assertRowsMatchPage("after the unrecorded restore")
        // The entry was forgotten, so `settleEverything` no longer tracks the job's settle: the overlay and the hidden leaders are lifted
        // by that settle, a moment after the hold is down. A state wait (bounded), not a pause.
        let lifted = await rig.waitUntil(10) {
            self.rig.editorState.pendingRestoreSections.isEmpty && self.rig.editorState.pendingRemovalIds.isEmpty
        }
        XCTAssertTrue(lifted, "the sidebar overlay of the unrecorded restore was not lifted, or the sidebar still hides a section")
        XCTAssertEqual(rig.controller.testShownAlerts, [], "an alert was shown for a restore that went through")
        assertQuiet("after the unrecorded restore")
    }
}
