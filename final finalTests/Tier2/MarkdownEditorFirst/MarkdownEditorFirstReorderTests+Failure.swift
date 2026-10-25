//
//  MarkdownEditorFirstReorderTests+Failure.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder in Markdown mode), round 4: the
//  failure path. A drag's queued job that does not apply is put back by `putBackMarkdownJob` (StructuralUndoController+MarkdownSettle
//  .swift; the name is slice 1's, it now serves a Delete and a reorder): the page is swapped back to the text before the drag when
//  nothing was typed since, the sidebar's order overlay goes, the entry goes, and the user is told with the alert of the entry's KIND
//  ("Couldn't Move Section"). An extension of the class in MarkdownEditorFirstReorderTests.swift. Real page, real rows, real writer.
//  Needs `cd web && pnpm build` first.
//
//  T-R12 (the kill switch off: a Markdown drag takes the old body and bumps `structuralOutOfQueueGeneration`) is the existing pinned test
//  `EditorFirstReorderTests/markdownModeReorderTakesTheOldRoadAndLeavesTheContentStateIdle` (EditorFirstReorderTests.swift), which sets
//  `MarkdownEditorFirstSwitch.enabled = false` with the editor in Markdown mode and asserts the old body ran (`!isEditorFirst`, a snapshot
//  id on the entry, the generation up). Nothing is added for it here.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-R11   testAFailedDragIsSwappedBackAndTheUserIsToldTheSectionCouldNotBeMoved
//           BREAK: in `putBackMarkdownJob` put back `let alert = EditorFirstOpKind.sectionDelete.putBackAlert`.
//           FAILS: "alert was Couldn't Delete Section" (and, if the `liftPendingReorder` lines are removed instead: "the sidebar's order
//                  overlay stayed up").
//   T-R11b  testADragWhoseJobWasNeverReservedIsSwappedBackAndTheUserIsTold
//           BREAK: in `putBackMarkdownJob` keep only `if kind == .sectionDelete, let gate, !gate.swapAttempted {`.
//           FAILS: "page not swapped back".
//

import Foundation
import XCTest
@testable import final_final

/// A fault the reorder job's body raises on purpose (`testEFReorderJobBodyHold`).
private struct DragJobFault: Error {}

extension MarkdownEditorFirstReorderTests {

    private static let failedMoveAlert = "Couldn't Move Section"

    /// The state a failed drag must leave, whichever way the job failed: the page and the rows are the document from before the drag,
    /// the sidebar shows the earlier order with no overlay, the user was told once, and nothing is left behind.
    private func assertDragWasPutBack(before: String, titlesBefore: [String]) async throws {
        let alerts = rig.controller.testShownAlerts
        XCTAssertEqual(alerts, [Self.failedMoveAlert], "alert was \(alerts) (wanted exactly [\(Self.failedMoveAlert)])")
        XCTAssertNil(rig.editorState.pendingReorder, "the sidebar's order overlay stayed up after the failed drag")
        let page = try await rig.pageText()
        XCTAssertEqual(
            Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: page)), Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "page not swapped back to the text from before the drag")
        XCTAssertEqual(
            Self.contentLines(try rig.writerRig.storedText()), Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "the rows are not the document from before the drag")
        await rig.editorState.refreshSectionsAwaiting()
        XCTAssertEqual(rig.editorState.sections.map(\.title), titlesBefore, "the sidebar does not show the earlier order")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed drag's entry is still on the timeline")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed drag's entry kind was kept")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "the failed drag's step-8 gate was kept")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
    }

    // MARK: - T-R11: the job fails AFTER it reserved its place

    // The job's body raises (`testEFReorderJobBodyHold`, held until the test lets it go, so the overlay is seen while the job is
    // unapplied), the transaction rolls back and the rows keep their order. Step 8 swaps the page back (nothing was typed), the settle puts
    // the drag back: the alert is the MOVE alert, the sidebar overlay is gone, the page and rows are the pre-drag document.
    func testAFailedDragIsSwappedBackAndTheUserIsToldTheSectionCouldNotBeMoved() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let before = try await rig.pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let outOfQueue = rig.editorState.structuralOutOfQueueGeneration
        let hold = MarkdownClickRig.JobHold()
        rig.controller.testEFReorderJobBodyHold = {
            hold.wait()
            throw DragJobFault()
        }

        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        XCTAssertNotNil(rig.editorState.pendingReorder, "premise: the order overlay is up while the job is unapplied")
        let pageAfterClick = try await rig.pageText()
        XCTAssertNotEqual(pageAfterClick, before, "premise: the page already shows the dragged order")

        hold.release()
        await rig.settleEverything()

        try await assertDragWasPutBack(before: before, titlesBefore: titlesBefore)
        XCTAssertEqual(rig.editorState.structuralOutOfQueueGeneration, outOfQueue, "the failed drag bumped structuralOutOfQueueGeneration")
    }

    // MARK: - T-R11b: the job is never reserved

    // The writer is pointed at another project between the click's guards and its job (the project is switching away), so the job is
    // refused before it reserves anything (`.identityMismatch`): there is no job to fail, no step 8 and no continuation. The put-back
    // itself swaps the page back to the pre-drag text (nothing was typed since), then shows the same MOVE alert.
    func testADragWhoseJobWasNeverReservedIsSwappedBackAndTheUserIsTold() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let before = try await rig.pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let other = try TestFixtureFactory.createTemporary(content: "# Other project\n\nBody.")
        let otherPid = try TestFixtureFactory.getProjectId(from: other)
        let sync = rig.writerRig.sync
        let view = rig.helper.webView
        rig.controller.testBeforeMarkdownPagePrepare = {
            // After the click's guards (they compared the writer with this project), before its page call and its job.
            sync.configure(database: other, projectId: otherPid, webView: view)
        }

        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()

        try await assertDragWasPutBack(before: before, titlesBefore: titlesBefore)
    }
}
