//
//  MarkdownHeldPressTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 7b: the Swift side of the page's HELD presses and the
//  lifecycle's count of them (CodeMirrorCoordinator+MessageDispatch.swift, EditorViewState+Lifecycle.swift `heldUndoPressCountForLifecycle`),
//  and the pin that a Markdown -> Rich Text switch pressed right after a Delete waits for the unsettled job. REAL CodeMirror page, real
//  coordinator (`MarkdownClickRig` with `routesUndo`). Needs `cd web && pnpm build`. NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-U9    two quick Cmd-Z presses: both act end to end, the page holds none afterwards, the lifecycle's allowance is 0.
//           BREAK: in `userContentController` of the CodeMirror coordinator's `handleUndoMessage` delete the `"undoHeldPressSettled"` case.
//           FAILS: "held count stuck" (the settled-message test and the lifecycle test; the two-press test needs no handler).
//   notice  the page's `undoQueueDropped` shows the existing notice.
//           BREAK: in `handleDiagnosticMessage` delete the `undoQueueDropped` branch.   FAILS: "no notice".
//   isolation  every Markdown rig has its OWN toast center (a bare EditorViewState points at the process-wide `ToastCenter.shared`, where
//           the 9-second notice of the test above would stay and fail every later "no notice" check; round 7b, ten failures, one toast id).
//           BREAK: in `MarkdownClickRig.init` delete the line `writerRig.editorState.toastCenter = toastCenter`.
//           FAILS: "premise: the notice went to this rig's own toast center" and "premise: the rig's toast center is not the process-wide
//           one" in the notice test, and "a notice or progress toast is showing ..." in the quick/slow undo tests that run after it.
//   count   a press the page holds is counted for the lifecycle in Markdown, and settled when it ends without a request.
//           BREAK: put `editorMode == .wysiwyg,` back into `heldUndoPressCountForLifecycle`'s guard.   FAILS: "held count not read in Markdown".
//   held    the request of a held press carries `held: true` to the gate (a close lets exactly that many through).
//           BREAK: in `handleUndoMessage` pass `held: false` for `structuralUndoRequested`.   FAILS: "the held press was not let through".
//   T-U17   a Markdown -> Rich Text switch pressed right after a Delete is held until the delete's job and its follow-up work have ended.
//           BREAK: in `requestEditorModeToggle` replace `efJobRegistry.hasUnsettledWork` in `deleteWorkPending` by `false`.
//           FAILS: "the switch ran before the delete's job ended".
//

import Foundation
import XCTest
@testable import final_final

/// Counts `.willToggleEditorMode` posts and records whether the delete work was still unsettled at each.
@MainActor
private final class ToggleLog {
    /// One entry per post: was delete work still unsettled at that moment.
    private(set) var posts: [Bool] = []
    private var token: NSObjectProtocol?

    init(editorState: EditorViewState) {
        // The switch is requested on the main actor, and `queue: nil` runs the observer on the posting thread.
        token = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: nil) { [weak self, weak editorState] _ in
            MainActor.assumeIsolated { self?.posts.append(editorState?.efJobRegistry.hasUnsettledWork ?? false) }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

@MainActor
final class MarkdownHeldPressTests: XCTestCase {

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
    private static let droppedNotice = "Some undo or redo presses could not be carried out."

    private func startRig() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true, routesUndo: true)
    }

    private func deleteSection(_ title: String) async throws {
        let root = try rig.section(title)
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - T-U9

    func testTwoQuickCmdZPressesBothActAndNothingIsLeftHeld() async throws {
        try await startRig()
        let pre = try await rig.pageText()
        try await deleteSection("Chapter 4")
        try await deleteSection("Chapter 3")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 2, "premise: two deletes are on the timeline")

        try await rig.press("undo", times: 2)   // the second press is made while the first request is in flight: the page holds it
        let text = try await rig.waitForPage { $0 == pre }
        XCTAssertEqual(text, pre, "the two presses did not both act")
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()

        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 2, "both entries are not on the redo stack")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "held count stuck (the page still holds a press)")
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice is showing")
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(lines(try rig.writerRig.storedText()), lines(MarkdownLeaderMap.recordText(fromRaw: text)), "the rows differ from the editor")
    }

    func testTheSettledMessageLowersTheLifecyclesAllowance() async throws {
        try await startRig()
        rig.editorState.structuralGate.preBarrierAllowance = 2   // what a close would have counted
        try await rig.postPageMessage("undoHeldPressSettled", body: "{ count: 2 }")
        let settled = await rig.waitUntil { self.rig.editorState.structuralGate.preBarrierAllowance == 0 }
        XCTAssertTrue(settled, "held count stuck")
    }

    func testTheQueueDroppedMessageShowsTheExistingNotice() async throws {
        try await startRig()
        try await rig.postPageMessage("undoQueueDropped", body: "{ count: 2 }")
        let shown = await rig.waitUntil { self.rig.editorState.toastCenter.current?.message == Self.droppedNotice }
        XCTAssertTrue(shown, "no notice")
        XCTAssertTrue(rig.editorState.toastCenter === rig.toastCenter, "premise: the notice went to this rig's own toast center")
        XCTAssertFalse(rig.toastCenter === ToastCenter.shared, "premise: the rig's toast center is not the process-wide one")
        rig.editorState.toastCenter.dismissCurrent()   // clear what this test provoked (the center dies with the rig in any case)
    }

    // MARK: - The lifecycle's count

    func testAPressThePageHoldsIsCountedForTheLifecycleInMarkdownAndSettledWhenItEndsWithoutARequest() async throws {
        try await startRig()
        let hold = rig.holdNextJob()
        let root = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        XCTAssertEqual(outcome, .performed)

        try await rig.press("undo")   // a request: Swift holds it behind the delete's job
        let onGate = await rig.waitUntil { !self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(onGate, "premise: the first press is on the structural gate")
        try await rig.press("undo")   // the page holds this one behind its latch
        var held = 0
        for _ in 0..<100 where held == 0 {
            held = try await rig.heldPressCount()
            if held == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(held, 1, "premise: the page holds the second press")

        let host = QuitFlushTestSupport.host(webView: rig.helper.webView)
        let counted = await rig.editorState.heldUndoPressCountForLifecycle(host: host)
        XCTAssertEqual(counted, 1, "held count not read in Markdown")
        rig.editorState.structuralGate.preBarrierAllowance = counted   // what the close would now do

        hold.release()   // the first press is carried out; the held one finds nothing structural left and ends as a text undo
        let settled = await rig.waitUntil(10) { self.rig.editorState.structuralGate.preBarrierAllowance == 0 }
        XCTAssertTrue(settled, "held count stuck")
        await rig.settleEverything()
        let after = try await rig.heldPressCount()
        XCTAssertEqual(after, 0, "held count stuck (the page still holds a press)")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 1, "the first press was not carried out")
    }

    func testAHeldRequestIsLetThroughAClosedGateOnceForEachCountedPress() async throws {
        try await startRig()
        try await deleteSection("Chapter 3")
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id)
        // A close has placed its barrier and counted one press the page was holding.
        rig.editorState.structuralGate.isClosedToNewWork = true
        rig.editorState.structuralGate.preBarrierAllowance = 1
        defer { rig.editorState.structuralGate.isClosedToNewWork = false }

        // The page's request for that press carries `held: true` (here sent by hand, as the page does when it drains its queue).
        try await rig.postPageMessage("structuralUndoRequested", body: "{ opId: '\(opId.uuidString)', held: true }")
        let used = await rig.waitUntil { self.rig.editorState.structuralGate.preBarrierAllowance == 0 }
        XCTAssertTrue(used, "the held press was not let through")
    }

    // MARK: - T-U17

    func testTheSwitchToRichTextPressedRightAfterADeleteWaitsForTheUnsettledJob() async throws {
        try await startRig()
        let editorState = rig.editorState
        let log = ToggleLog(editorState: editorState)
        defer { log.stop() }
        let hold = rig.holdNextJob()
        let root = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(editorState.efJobRegistry.hasUnsettledWork, "premise: the delete's job has not ended")

        editorState.requestEditorModeToggle()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(log.posts.count, 0, "the switch ran before the delete's job ended")
        XCTAssertNotNil(editorState.heldModeToggleTask, "the press was dropped instead of held")
        XCTAssertEqual(editorState.editorMode, .source)

        hold.release()
        let ran = await rig.waitUntil(10) { log.posts.count == 1 }
        XCTAssertTrue(ran, "the held switch never ran after the job ended")
        XCTAssertEqual(log.posts, [false], "the switch started while the delete's follow-up work was unsettled")
        await rig.settleEverything()
    }
}
