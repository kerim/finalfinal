//
//  MarkdownSlowUndoTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 7b: the QUEUED SLOW undo and redo of a Markdown entry
//  (StructuralUndoController+MarkdownSlowUndo.swift), against the REAL CodeMirror page, a real database and the real writer
//  (`MarkdownClickRig` with `routesUndo`: a real keydown reaches the controller through the real coordinator, as in the app). The entry
//  is one the OLD body recorded in Markdown mode (its click keeps the old body in slice 1): made with the switch turned off for the
//  click, then the production default back for the presses. Typing is user-origin (`userTypes`). Needs `cd web && pnpm build`.
//  NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-U7b  Cmd-Z and Cmd-Shift-Z of an old-body Markdown entry: the page swapped, the replace job ran, the editor text and the rows are the
//          pre-op ones, and `structuralOutOfQueueGeneration` did not move.
//          BREAK: in `queuedSnapshotUndo` (StructuralUndoController+QueuedSnapshotUndo.swift) delete the first line
//          `if editorState?.editorMode == .source { return await markdownQueuedSnapshotUndo(...) }`.
//          FAILS: "generation bumped by undo" (the old body bumps it).
//   job    typing made while the replace job waits is kept and saved after the release.
//          BREAK: in `markdownQueuedSnapshotUndo` delete the `startMarkdownHoldContinuation(...)` line.   FAILS: "ss8 not saved after the release".
//   A12    an old-path click made BEFORE a Markdown Delete does not close the Delete's quick path, and the whole chain undoes and redoes in order.
//          BREAK: in `quickPathPossible` compare the generation to `0` (or bump the generation in `markdownQueuedSnapshotUndo`).
//          FAILS: "the quick path is closed by an old-path click made BEFORE the delete" / "generation bumped by undo".
//   switch the production default is ON.
//          BREAK: `MarkdownEditorFirstSwitch.productionDefault = false`.   FAILS: "the switch is off by default".
//   M-3    the slow-route REDO of an editor-first Markdown Delete sends a fresh request built from the rows as they are now: after an
//          old-path click closed the quick path, both undone, and the application renamed a heading (its row saved), Cmd-Shift-Z deletes
//          the section again with no notice.
//          The restored Chapter 3 has a FRESH row id (the slow undo replaced the rows from a snapshot), so the redo must also find the
//          root again by its heading line (`MarkdownLeaderMap.currentRootId(for:)`).
//          BREAK 1: in `sendMarkdownSlowSwap` build the request on `holder.rootId` instead of the root found through the reference (pass
//          `rootReference: nil` to `sendMarkdownDeleteWithRetry`).   FAILS: "Cmd-Shift-Z did not delete the chapter again (slow swap: no
//          request could be built for the root heading "# Chapter 3" ...)" (the id names no row, no request exists, the notice shows).
//          BREAK 2: take the `guard` branch for the redo too (send no request, so the page re-runs the request stored at the first
//          click).   FAILS: the same message, with "slow swap: plain swap, no request: ok=false reason=leadersMismatch".
//          BREAK 3 (the rows side): in `markdownStep8Turn` (StructuralUndoController+MarkdownSettle.swift) put `return nil` right after the
//          `guard ... else { ... }` block, so step 8 flushes nothing. The redo's job then leaves the snapshot's OLD heading in the rows.
//          FAILS: "the redo's snapshot job put the old heading back into the rows and nothing corrected it", "the old heading line is
//          still in the rows" and "the rows differ from the editor after the redo".
//   DR-2   a slow Cmd-Z whose wait for the earlier job passes the notice delay shows "Undoing…" until the swap: no "Finishing the last
//          change…" replaces it and the slot is not left empty while the press is still running.
//          BREAK: in `markdownQueuedSnapshotUndo` put back `let waiting = DelayedProgressToast(... finishingMessage)` before the
//          `awaitStructuralHoldReleased()` line and `waiting.stop()` after it.
//          FAILS: "'Finishing the last change…' replaced 'Undoing…'".
//

import Foundation
import XCTest
@testable import final_final

@MainActor
final class MarkdownSlowUndoTests: XCTestCase {

    private var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.controller.testEFJobBodyHold = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    private func startRig(_ markdown: String) async throws {
        rig = try await MarkdownClickRig(markdown: markdown, observesPage: true, routesUndo: true)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func rowLines() throws -> [String] { lines(try rig.writerRig.storedText()) }

    /// The same document, whatever the hidden section anchors say: an entry the OLD body recorded saw the editor's text pushed back
    /// through the database once, which may rewrite the anchors.
    private func sameDoc(_ first: String, _ second: String) -> Bool {
        lines(MarkdownLeaderMap.recordText(fromRaw: first)) == lines(MarkdownLeaderMap.recordText(fromRaw: second))
    }

    /// A Delete Section made by the OLD body (the switch off for the click only). Returns the page before and after.
    private func oldBodyDelete(_ title: String) async throws -> (pre: String, post: String) {
        let root = try rig.section(title)
        let pre = try await rig.pageText()
        MarkdownEditorFirstSwitch.enabled = false
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        MarkdownEditorFirstSwitch.enabled = MarkdownEditorFirstSwitch.productionDefault
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()
        return (pre, try await rig.pageText())
    }

    private func editorFirstDelete(_ title: String) async throws -> (pre: String, post: String) {
        let root = try rig.section(title)
        let pre = try await rig.pageText()
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()
        return (pre, try await rig.pageText())
    }

    @discardableResult
    private func press(_ direction: String, until condition: (String) -> Bool, _ message: String) async throws -> String {
        try await rig.press(direction)
        let text = try await rig.waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        return text
    }

    private func assertQuiet(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice or progress toast is showing \(context)", file: file, line: line)
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown \(context)", file: file, line: line)
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held \(context)", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending \(context)", file: file, line: line)
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "a step-8 gate was kept \(context)", file: file, line: line)
    }

    // MARK: - T-U7b

    func testCmdZAndCmdShiftZOfAnOldBodyEntryGoThroughTheQueuedRouteWithoutBumpingTheGeneration() async throws {
        try await startRig(Self.book4)
        let rowsBefore = try rowLines()
        let (pre, post) = try await oldBodyDelete("Chapter 3")
        let entry = try XCTUnwrap(rig.unifiedUndo.undoStack.last)
        XCTAssertFalse(entry.isEditorFirst, "premise: the old body recorded the entry")
        XCTAssertNotNil(entry.undoSnapshotId, "premise: the entry carries its undo snapshot")
        XCTAssertFalse(post.contains("Chapter 3"), "premise: the delete took the chapter out of the editor")
        let rowsAfter = try rowLines()
        let generation = rig.editorState.structuralOutOfQueueGeneration

        try await press("undo", until: { self.sameDoc($0, pre) }, "Cmd-Z did not restore the text from before the Delete")
        assertQuiet("after Cmd-Z")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "generation bumped by undo")
        XCTAssertEqual(try rowLines(), rowsBefore, "the rows are not the pre-op rows")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 1, "the entry did not move to the redo stack")
        XCTAssertNotNil(rig.unifiedUndo.redoStack.last?.redoSnapshotId, "the replace job did not attach the redo snapshot")

        try await press("redo", until: { self.sameDoc($0, post) }, "Cmd-Shift-Z did not delete the chapter again")
        assertQuiet("after Cmd-Shift-Z")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "generation bumped by redo")
        XCTAssertEqual(try rowLines(), rowsAfter, "the rows are not the post-op rows")
        XCTAssertTrue(rig.unifiedUndo.undoStack.count == 1 && rig.unifiedUndo.redoStack.isEmpty, "the entry did not move back to the undo stack")
    }

    func testTypingMadeWhileTheQueuedUndoJobWaitsIsKeptAndSaved() async throws {
        try await startRig(Self.book4)
        let (pre, _) = try await oldBodyDelete("Chapter 3")
        let hold = rig.holdNextJob()   // the replace job's body (`StructuralReplaceJob.bodyHold = jobBodyHold()`)

        try await rig.press("undo")
        try await rig.waitForPage { self.sameDoc($0, pre) }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the replace job is held, so the writer's hold is up")

        let typed = try await rig.userTypes(" ss8", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("ss8") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")

        hold.release()
        await rig.settleEverything()
        let saved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("ss8")) == true }
        XCTAssertTrue(saved, "ss8 not saved after the release")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Chapter 3"), "the chapter is not back in the rows")
        let page = try await rig.pageText()
        XCTAssertEqual(page, typed, "the typing was overwritten or the restored text was changed")
        assertQuiet("after the release")
    }

    // MARK: - M-3

    func testTheRedoOfAnEditorFirstDeleteTakesAFreshRequestSoAChangedHeadingDoesNotRefuseIt() async throws {
        try await startRig(Self.book4)
        let original = try await rig.pageText()
        let (_, post1) = try await editorFirstDelete("Chapter 3")
        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last)
        XCTAssertTrue(deleteEntry.isEditorFirst, "premise: the first delete was made editor-first")
        // An old-path click made AFTER the delete closes the delete's quick path, so its Cmd-Z and Cmd-Shift-Z take the slow route.
        _ = try await oldBodyDelete("Chapter 4")
        XCTAssertFalse(rig.controller.quickUndoEligible(deleteEntry), "premise: the old-path click closed the delete's quick path")

        try await press("undo", until: { self.sameDoc($0, post1) }, "the first Cmd-Z did not undo the old-path delete")
        try await press("undo", until: { self.sameDoc($0, original) }, "the second Cmd-Z did not undo the editor-first delete")
        XCTAssertEqual(rig.unifiedUndo.redoStack.last?.id, deleteEntry.id, "premise: the editor-first delete is the next redo")

        // The application changes a heading while the delete is undone (a rebuild, a hierarchy fix): an application push, which the page
        // follows with the entry's saved copy; the rows are saved. The request the page stored at the first click is stale now.
        try await rig.type(original.replacingOccurrences(of: "# Chapter 2", with: "# Chapter Two"))
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("# Chapter Two") }
        XCTAssertTrue(reported, "premise: the application's push reached the content record")
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()
        XCTAssertTrue(try rig.writerRig.storedText().contains("# Chapter Two"), "premise: the rows carry the changed heading")

        // The slow undo put Chapter 3 back by replacing the project's rows with a snapshot's, which gives its rows FRESH ids: the id the
        // Delete clicked on (`holder.rootId`) names no row now. The redo has to find the root again by its heading line.
        let holderRootId = try XCTUnwrap(rig.controller.efHolders[deleteEntry.id]?.rootId)
        let restoredRootId = try rig.section("Chapter 3").id
        let redoSnapshotAttached = rig.unifiedUndo.redoStack.last?.redoSnapshotId != nil

        try await rig.press("redo")
        let text = try await rig.waitForPage { !$0.contains("Chapter 3") && $0.contains("# Chapter Two") }
        let swapNote = rig.controller.testLastMarkdownSlowSwapNote ?? "no page call was made"
        XCTAssertTrue(
            !text.contains("Chapter 3") && text.contains("# Chapter Two"),
            "Cmd-Shift-Z did not delete the chapter again (slow swap: \(swapNote); the clicked root id \(holderRootId) "
                + (holderRootId == restoredRootId ? "is" : "is NOT") + " the id of the restored heading row; the entry "
                + (redoSnapshotAttached ? "has" : "has NO") + " a redo snapshot)")
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        assertQuiet("after Cmd-Shift-Z")
        XCTAssertTrue(text.contains("Chapter 4"), "the redo also took Chapter 4 out")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, deleteEntry.id, "the entry did not move back to the undo stack")

        // The rows. The redo's job writes the snapshot taken when the delete was undone, which still has the OLD heading; only step 8's
        // flush of the live text puts the renamed heading back. So the rows must say the new heading, not the old one, and equal the page.
        let stored = try rig.writerRig.storedText()
        XCTAssertFalse(stored.contains("Chapter 3"), "the chapter is still in the rows")
        XCTAssertTrue(stored.contains("# Chapter Two"), "the redo's snapshot job put the old heading back into the rows and nothing corrected it")
        XCTAssertFalse(stored.contains("# Chapter 2"), "the old heading line is still in the rows")
        let pageNow = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        XCTAssertEqual(try rowLines(), lines(pageNow), "the rows differ from the editor after the redo")
    }

    // MARK: - DR-2

    func testASlowCmdZThatWaitsLongerThanTheNoticeDelayShowsUndoingUntilTheSwapAndNothingElse() async throws {
        try await startRig(Self.book4)
        rig.shortenProgressDelay(.milliseconds(200))
        let original = try await rig.pageText()
        let (_, post1) = try await oldBodyDelete("Chapter 3")
        _ = try await oldBodyDelete("Chapter 4")
        rig.toastLog.lines = []
        let hold = rig.holdNextJob()   // the first slow undo's replace job stays unapplied, so the second press has to wait for it

        try await rig.press("undo")
        try await rig.waitForPage { self.sameDoc($0, post1) }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the first undo's job is unapplied, so the writer's hold is up")
        rig.toastLog.lines = []   // the first press may have shown its own notice; only the second press is looked at

        // The second Cmd-Z waits on the hold inside `performUndo`: its "Undoing…" shows after the delay, and the wait inside the route
        // used to put "Finishing the last change…" over it a moment later.
        try await rig.press("undo")
        let shown = await rig.waitUntil { self.rig.editorState.toastCenter.current?.message == DelayedProgressToast.undoingMessage }
        XCTAssertTrue(shown, "premise: the waiting press shows 'Undoing…'")
        try await Task.sleep(for: .milliseconds(700))   // well past the delay of the route's own wait
        XCTAssertEqual(
            rig.editorState.toastCenter.current?.message, DelayedProgressToast.undoingMessage,
            "'Finishing the last change…' replaced 'Undoing…' (or the slot went empty) while the press was still waiting")
        XCTAssertFalse(rig.toastLog.lines.contains { $0.contains(DelayedProgressToast.finishingMessage) }, "'Finishing the last change…' was shown")

        hold.release()
        hold.release()   // the shared job-body hold blocks the second undo's job too
        try await rig.waitForPage { self.sameDoc($0, original) }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice is still showing after the press")
        XCTAssertFalse(rig.toastLog.lines.contains { $0.contains(DelayedProgressToast.finishingMessage) }, "'Finishing the last change…' was shown")
    }

    // MARK: - R5-A12

    func testAnOldPathClickBeforeAMarkdownDeleteDoesNotCloseItsQuickPathAndTheChainUndoesAndRedoesInOrder() async throws {
        try await startRig(Self.book4)
        let original = try await rig.pageText()
        let rowsOriginal = try rowLines()
        let generation0 = rig.editorState.structuralOutOfQueueGeneration
        let (_, mid) = try await oldBodyDelete("Chapter 4")
        let generation = rig.editorState.structuralOutOfQueueGeneration
        XCTAssertGreaterThan(generation, generation0, "premise: the old-path click bumped the generation")
        let rowsMid = try rowLines()
        let (_, post) = try await editorFirstDelete("Chapter 3")
        let rowsPost = try rowLines()
        let deleteEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last)
        XCTAssertTrue(deleteEntry.isEditorFirst, "premise: the second delete was made editor-first")
        XCTAssertTrue(rig.controller.quickUndoEligible(deleteEntry), "the quick path is closed by an old-path click made BEFORE the delete")

        // Cmd-Z at once: the QUICK path (no "Undoing...", the slot says so), then the old-path entry's queued slow undo.
        try await press("undo", until: { self.sameDoc($0, mid) }, "the first Cmd-Z did not restore chapter 3")
        assertQuiet("after the first Cmd-Z")
        let slot = rig.controller.efSlots.slot(deleteEntry.id)?.state
        XCTAssertTrue(slot == .quickUndone || slot == .reinserted, "the delete's undo did not take the quick path (slot \(String(describing: slot)))")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "generation bumped by undo")
        XCTAssertEqual(try rowLines(), rowsMid, "the rows are not the mid rows after the quick undo")

        try await press("undo", until: { self.sameDoc($0, original) }, "the second Cmd-Z did not restore chapter 4")
        assertQuiet("after the second Cmd-Z")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "generation bumped by undo")
        XCTAssertEqual(try rowLines(), rowsOriginal, "the rows are not the original rows after the queued slow undo")

        try await press("redo", until: { self.sameDoc($0, mid) }, "the first Cmd-Shift-Z did not delete chapter 4 again")
        assertQuiet("after the first Cmd-Shift-Z")
        XCTAssertEqual(try rowLines(), rowsMid, "the rows are not the mid rows after the queued slow redo")
        try await press("redo", until: { self.sameDoc($0, post) }, "the second Cmd-Shift-Z did not delete chapter 3 again")
        assertQuiet("after the second Cmd-Shift-Z")
        XCTAssertEqual(try rowLines(), rowsPost, "the rows are not the post rows after the quick redo")
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, generation, "generation bumped by redo")
    }

    // MARK: - The production default

    func testTheSwitchIsOnByDefault() {
        XCTAssertTrue(MarkdownEditorFirstSwitch.productionDefault, "the switch is off by default")
        XCTAssertTrue(MarkdownEditorFirstSwitch.enabled, "the switch is off by default (a test left it off)")
    }
}
