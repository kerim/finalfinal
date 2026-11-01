//
//  MarkdownEditorFirstReorderTests+TypingAcrossUndo.swift
//  final finalTests
//
//  t-d2061b27 (Phase 4c, job 2, coder S round S1): the Swift side of "a Cmd-Z that waits keeps waiting when the user types, then runs on
//  the document as it was at the press with the typing put back on top" in MARKDOWN MODE, for the slow route of a sidebar drag
//  (StructuralUndoController+MarkdownSlowUndo.swift). An extension of MarkdownEditorFirstReorderTests (it has the drag helpers, `drop`,
//  `makeUndoRig`, `pressAndSettle`): the REAL CodeMirror page, a real database and writer, a real keydown through the real coordinator.
//
//  How the user types "during the wait": the controller's `testBeforeMarkdownPagePrepare` seam runs inside the press, AFTER the page
//  latched it (the keydown was routed as structural and the page posted its request) and BEFORE the page call that swaps. The page
//  records every change since the press, holds its typing pushes, and puts the typing back on top after the swap (`typingReplayed`).
//
//    - S1  testTypingDuringMarkdownDragUndoIsCarriedOutAndReachesTheRows
//    - S3  testReplayEndsRedoInsideTheGateAndASecondUndoWorks
//    - S4  testANonTypingChangeDuringTheWaitStillRefusesWithTheNotice
//
//  Break patches are in .claude/superdev/cmdz-waits-through-typing/break-patches/SW-<test name>.patch. Needs `cd web && pnpm build`.
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstReorderTests {

    static let dropNotice = "Some undo or redo presses could not be carried out."
    static let originalChapters = ["# Chapter 1", "# Chapter 2", "# Chapter 3", "# Chapter 4"]
    static let draggedChapters = ["# Chapter 1", "# Chapter 3", "# Chapter 2", "# Chapter 4"]

    /// How many times `needle` occurs in `text`.
    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - S1

    // A drag of Chapter 3 above Chapter 2, Cmd-Z, and the user types inside the moved chapter, with an Enter, while the press waits. The
    // press is CARRIED OUT: the chapters are back in their old order, the typing went back with its chapter (in one piece, where it was
    // typed), it is in the rows exactly once, no notice and no alert showed, and the typing ended the redo branch.
    // Predicted failure with the page-side fix taken out (docAtPress returns the live document): `XCTAssertTrue failed - Cmd-Z did not put
    // the chapters back in their old order`. Predicted failure with `endRedoAfterReplayedTyping` an empty body: `XCTAssertTrue failed -
    // typing in the wait must end the redo branch`.
    func testTypingDuringMarkdownDragUndoIsCarriedOutAndReachesTheRows() async throws {
        let rig = try await makeUndoRig(Self.book4)
        rig.editorState.sourceReparseDebounce = .milliseconds(20)
        let drag = try await drop("Chapter 3", after: "Chapter 1")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        let afterDrag = try await rig.pageText()
        XCTAssertEqual(Self.headings(in: afterDrag), Self.draggedChapters, "premise: the page shows the dragged order")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.kind, .sectionReorder, "premise: the drag is the top of the timeline")

        // Cmd-Z, and the user types inside the moved chapter while the press waits.
        let typist = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await typist.userTypes(" dont stop\n\nmore words", after: "Third chapter text.")
        }
        let page = try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == Self.originalChapters && $0.contains("more words") },
            "Cmd-Z did not put the chapters back in their old order with the typing")
        rig.controller.testBeforeMarkdownPagePrepare = nil

        // The typing went back with its chapter, in one piece, once.
        XCTAssertEqual(
            Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: page)),
            ["# Chapter 1", "First chapter text.", "# Chapter 2", "Second chapter text.", "# Chapter 3", "Third chapter text. dont stop",
             "more words", "# Chapter 4", "Fourth chapter text."],
            "the typing is not in one piece inside its chapter, or the chapters are not in their old order")
        XCTAssertEqual(Self.occurrences(of: "more words", in: page), 1, "the typing is in the editor more than once")

        // The rows: the typing is in them exactly once (the replay's only carrier is step 8's live read).
        let saved = await rig.waitUntil { Self.occurrences(of: "more words", in: (try? rig.writerRig.storedText()) ?? "") == 1 }
        XCTAssertTrue(saved, "the typing done during the wait never reached the rows exactly once")
        let stored = try rig.writerRig.storedText()
        XCTAssertEqual(
            Self.occurrences(of: "dont stop", in: stored), 1,
            "dont stop is in the rows \(Self.occurrences(of: "dont stop", in: stored)) times")
        let pageLines = try await pageContentLines()
        XCTAssertEqual(Self.contentLines(stored), pageLines, "the rows differ from the editor")

        // No notice, no alert; the typing ended the redo branch; nothing is left running.
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown for typing")
        XCTAssertNil(rig.editorState.toastCenter.current, "a toast is showing")
        XCTAssertEqual(rig.controller.testShownAlerts, [], "an alert was shown")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "typing in the wait must end the redo branch")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the drag's entry is still on the undo stack")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "the page still holds a press")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "a step-8 gate was kept")
    }

    // MARK: - S3

    // The M1 regression: the redo branch must end INSIDE the gate, after the entry has moved. Two drags, Cmd-Z with typing in the wait
    // (the second drag is undone, the typing is put back on top, and the redo branch ends at once), then Cmd-Z, Cmd-Z step by step:
    // the first takes the typing back (the editor's own history), the second undoes the first drag. Each is performed.
    // Predicted failure with `endRedoAfterReplayedTyping` an empty body: `XCTAssertTrue failed - the redo branch was not ended inside the gate`.
    func testReplayEndsRedoInsideTheGateAndASecondUndoWorks() async throws {
        let rig = try await makeUndoRig(Self.book4)
        let original = try await rig.pageText()
        let firstDrag = try await drop("Chapter 3", after: "Chapter 1")
        XCTAssertEqual(firstDrag.outcome, .performed)
        await rig.settleEverything()
        let dragOne = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the first drag recorded no entry")
        let secondDrag = try await drop("Chapter 4", after: "Chapter 1")
        XCTAssertEqual(secondDrag.outcome, .performed)
        await rig.settleEverything()
        let dragTwo = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the second drag recorded no entry")
        XCTAssertNotEqual(dragOne.id, dragTwo.id, "premise: two entries")
        let afterBoth = try await rig.pageText()
        XCTAssertEqual(Self.headings(in: afterBoth), ["# Chapter 1", "# Chapter 4", "# Chapter 3", "# Chapter 2"], "premise: both drags applied")

        let typist = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await typist.userTypes(" ss2", after: "Second chapter text.")
        }
        // The first Cmd-Z undoes the second drag with the typing put back on top of it.
        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == Self.draggedChapters && $0.contains("ss2") },
            "the first Cmd-Z did not undo the second drag with the typing")
        rig.controller.testBeforeMarkdownPagePrepare = nil
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the redo branch was not ended inside the gate (the second drag's entry is still redoable)")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, dragOne.id, "the first drag is not the next entry to undo")
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown")

        // Step by step: the second Cmd-Z takes the typing back (the page's own history), the third undoes the first drag.
        try await pressAndSettle("undo", until: { !$0.contains("ss2") }, "the second Cmd-Z did not take the typing back")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, dragOne.id, "the text undo moved the timeline")
        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == Self.originalChapters }, "the third Cmd-Z did not undo the first drag")
        XCTAssertEqual(rig.unifiedUndo.redoStack.last?.id, dragOne.id, "the first drag's entry is not on the redo stack")
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown")
        let finalPage = try await rig.pageText()
        XCTAssertEqual(
            Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: finalPage)),
            Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: original)),
            "the page is not the original document")
    }

    // MARK: - S4

    // Something that is NOT typing meets the waiting press: here the page's undo registry is cleared in the wait (a barrier, as
    // `clearStructuralUndoRegistry` does), so the page answers `noEntry` -- with the user's typing in the document as well. The press is
    // still refused with the existing notice (a command either does what it says or says why not): the notice shows once, the drag
    // stands, the entry stays where it was, and the typing stays and reaches the rows (the re-armed re-parse).
    // (A change the saved copy cannot follow, a rebuild that rewrote the typed text, refuses with `changed` the same way; the web tests
    // R11d and R12b cover the page's decision. This test is about Swift's handling of any refusal against the REAL page.)
    // Predicted failure with the notice taken out of the refusal branch (`showUndoQueueDroppedWarning` deleted in
    // `markdownQueuedSnapshotUndo`): `XCTAssertTrue failed - the refused press showed no notice`.
    func testANonTypingChangeDuringTheWaitStillRefusesWithTheNotice() async throws {
        let rig = try await makeUndoRig(Self.book4)
        rig.editorState.sourceReparseDebounce = .milliseconds(20)
        let drag = try await drop("Chapter 3", after: "Chapter 1")
        XCTAssertEqual(drag.outcome, .performed)
        await rig.settleEverything()
        let dragEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.last, "the drag recorded no entry")

        let typist = rig
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await typist.userTypes(" kept8", after: "Fourth chapter text.")
            _ = try? await typist.helper.webView.evaluateJavaScript("window.FinalFinal.clearStructuralUndoRegistry()")
        }
        try await rig.press("undo")
        let shown = await rig.waitUntil { rig.editorState.toastCenter.current?.message == Self.dropNotice }
        XCTAssertTrue(shown, "the refused press showed no notice")
        rig.controller.testBeforeMarkdownPagePrepare = nil
        _ = await rig.waitUntil(20) { rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()

        XCTAssertEqual(rig.toastLog.lines.filter { $0.contains(Self.dropNotice) }.count, 1, "the notice was not shown exactly once")
        let page = try await rig.pageText()
        XCTAssertEqual(Self.headings(in: page), Self.draggedChapters, "the refused press changed the chapters' order")
        XCTAssertTrue(page.contains("kept8"), "the typing is gone from the editor")
        let saved = await rig.waitUntil { (try? rig.writerRig.storedText().contains("kept8")) == true }
        XCTAssertTrue(saved, "the typing made while the press waited never reached the rows")
        XCTAssertEqual(rig.unifiedUndo.undoStack.last?.id, dragEntry.id, "the entry left the undo stack")
        XCTAssertTrue(rig.unifiedUndo.redoStack.isEmpty, "the entry moved to the redo stack although the press was refused")
        let held = try await rig.heldPressCount()
        XCTAssertEqual(held, 0, "the page still holds a press")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending")
    }
}
