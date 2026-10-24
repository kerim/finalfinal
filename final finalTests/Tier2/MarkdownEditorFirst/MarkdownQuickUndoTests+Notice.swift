//
//  MarkdownQuickUndoTests+Notice.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), acceptance F1 (floor 3): the "Finishing the last change…" notice of a
//  quick Cmd-Z / Cmd-Shift-Z belongs to the WHOLE press. Real run: a Cmd-Z pressed about a second after a Delete on the 12-chapter book
//  took 1539 ms (813 ms waiting for the delete's save, 726 ms swapping the page) and showed nothing, because the notice was stopped as
//  soon as the wait ended. An extension of MarkdownQuickUndoTests (it shares its rig and helpers). Needs `cd web && pnpm build`.
//  NOT RUN by the coder.
//
//  The wait and the swap are made long enough to tell apart without a long test: the notice delay is shortened to 300 ms
//  (`shortenProgressDelay`, put back by `restore()`), the press waits for a held job, and the page swap is made 600 ms slow by the
//  controller's `testBeforeMarkdownPagePrepare` seam, which runs AFTER the wait and BEFORE the page call. The notice is read at the end
//  of that slow stretch, i.e. while the swap is still "running".
//
//  Break patch (a 1-5 line change in production code that must make the tests fail), and the failure each shows:
//
//   undo / redo  BREAK: in `resolveMarkdownQuickPath` (StructuralUndoController+MarkdownQuickUndo.swift) put `notice.stop()` back right after
//          the `awaitStructuralHoldReleased()` line (the old behaviour: the notice covers the wait only).
//          FAILS: "no 'Finishing the last change…' notice while the page swap ran" (undo and redo).
//   guard   passes with and without the break: a press that takes well under the (real, one second) delay shows nothing.
//

import Foundation
import XCTest
@testable import final_final

/// What the notice looked like at the end of the slow stretch the seam makes.
private final class NoticeProbe {
    var reachedSwap = false
    var noticeDuringSwap: String?
}

extension MarkdownQuickUndoTests {

    private func makeSwapSlow(by delay: Duration, probe: NoticeProbe) {
        let toastCenter = rig.toastCenter
        rig.controller.testBeforeMarkdownPagePrepare = {
            probe.reachedSwap = true
            try? await Task.sleep(for: delay)
            probe.noticeDuringSwap = toastCenter.current?.message
        }
    }

    private func assertOneNoticeForTheWholePress(_ probe: NoticeProbe, logBefore: Int, _ context: String) {
        XCTAssertTrue(probe.reachedSwap, "premise: the press got as far as the page swap (\(context))")
        XCTAssertEqual(
            probe.noticeDuringSwap, DelayedProgressToast.finishingMessage,
            "no 'Finishing the last change…' notice while the page swap ran (\(context))")
        XCTAssertNil(rig.editorState.toastCenter.current, "the notice is still showing after the press (\(context))")
        let shown = Array(rig.toastLog.lines.dropFirst(logBefore))
        XCTAssertEqual(
            shown.filter { $0.contains(DelayedProgressToast.finishingMessage) }.count, 1,
            "the press must show ONE 'Finishing the last change…' notice for its wait and its swap (\(context))")
        XCTAssertEqual(shown.count, 1, "another notice was shown during the press (\(context)): \(shown)")
    }

    // MARK: - Cmd-Z

    func testACmdZThatWaitsForTheDeleteAndThenSwapsShowsTheNoticeWhileItSwapsAndTakesItDownAfterwards() async throws {
        try await startRig(Self.book4)
        rig.shortenProgressDelay(.milliseconds(300))
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let pre = try await rig.pageText()
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let logBefore = rig.toastLog.lines.count
        let probe = NoticeProbe()
        makeSwapSlow(by: .milliseconds(600), probe: probe)

        // Cmd-Z at once: it waits for the delete's job (a short wait, under the notice delay), then swaps (a slow swap).
        try await rig.press("undo")
        let waiting = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(waiting, "premise: the Cmd-Z reached the controller and waits for the delete's job")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(probe.reachedSwap, "premise: the press is still waiting for the delete's job")
        hold.release()
        try await rig.waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()

        assertOneNoticeForTheWholePress(probe, logBefore: logBefore, "Cmd-Z")
        let after = try await rig.pageText()
        XCTAssertEqual(after, pre, "the held Cmd-Z did not bring the chapter back")
        try await assertRowsMatchPage("after the slow Cmd-Z")
    }

    func testACmdZThatTakesWellUnderASecondShowsNoNoticeEvenWithASlowishSwap() async throws {
        try await startRig(Self.book4)   // the real one-second delay
        let (pre, _) = try await deleteSection("Chapter 3")
        let probe = NoticeProbe()
        makeSwapSlow(by: .milliseconds(300), probe: probe)

        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        XCTAssertTrue(probe.reachedSwap, "premise: the press got as far as the page swap")
        XCTAssertNil(probe.noticeDuringSwap, "a notice showed for a press that took well under a second")
        assertQuiet("after a Cmd-Z that took well under a second")
    }

    // MARK: - Cmd-Shift-Z

    func testACmdShiftZThatWaitsForTheUndosReinsertAndThenSwapsShowsTheNoticeWhileItSwapsAndTakesItDownAfterwards() async throws {
        try await startRig(Self.book4)
        let (pre, post) = try await deleteSection("Chapter 3")
        rig.shortenProgressDelay(.milliseconds(300))
        let hold = rig.holdReinsert()
        try await rig.press("undo")
        try await rig.waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the undo's reinsert is held, so the writer's hold is up")
        let logBefore = rig.toastLog.lines.count
        let probe = NoticeProbe()
        makeSwapSlow(by: .milliseconds(600), probe: probe)

        // Cmd-Shift-Z while the reinsert is held: the quick redo waits for it (short wait), then swaps (slow swap).
        try await rig.press("redo")
        let waiting = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(waiting, "premise: the Cmd-Shift-Z reached the controller and waits for the reinsert")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(probe.reachedSwap, "premise: the press is still waiting for the reinsert")
        hold.release()
        try await rig.waitForPage { $0 == post }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()

        assertOneNoticeForTheWholePress(probe, logBefore: logBefore, "Cmd-Shift-Z")
        let after = try await rig.pageText()
        XCTAssertEqual(after, post, "the held Cmd-Shift-Z did not delete the chapter again")
        try await assertRowsMatchPage("after the slow Cmd-Shift-Z")
    }
}
