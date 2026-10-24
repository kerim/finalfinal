//
//  MarkdownClickHoldReleaseTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5, T-U19 AIMED AT THE PRODUCTION CLICK (judge D2/O7/
//  O21; the token contract itself is `MarkdownWriterStructuralHoldTests`). Four runs drive
//  `StructuralUndoController.performMarkdownEditorFirstDelete` itself on the REAL CodeMirror page (`MarkdownClickRig`). After each run:
//  `isHeldForStructuralWork == false`, and a bibliography-flush `writeNow` started afterwards completes within 2 s.
//
//   run 1  a mismatch the flush cannot fix: a heading was renamed on the page, and the flush's guard refuses (the content state is busy),
//          so the click gives up and returns nil: the old body would run next, after the `defer` has released the hold.
//          BREAK: delete `if !handedOff { hold.release() }` from the click's `defer`.
//          FAILS: "hold still raised after fallback" and "writeNow did not complete (deadlock)".
//   run 2  a JavaScript error: the page has no editor (a blank web view), so the call throws and the click returns nil. Same break, same failure.
//   run 3  a failed job: the queued job cannot delete (a trigger aborts the delete), the hold was handed to the continuation, and the job's
//          future resolves with a failure. Two lines release the hold on this path, the continuation's `defer` and step 8's turn (a
//          failed job has an outcome, so step 8 runs), so the break removes BOTH.
//          BREAK: delete `hold.release()` from the continuation's `defer` (startMarkdownHoldContinuation) AND `defer { hold.release() }`
//          from `markdownStep8Turn` (StructuralUndoController+MarkdownSettle.swift).
//          FAILS: "hold still raised after a failed job".
//   run 4  the continuation is cancelled while the job is still held: step 8 never runs, so only the continuation's own `defer` releases.
//          BREAK: delete `hold.release()` from the continuation's `defer` (startMarkdownHoldContinuation).
//          FAILS: "hold still raised after the continuation was cancelled".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import WebKit
import XCTest
@testable import final_final

@MainActor
final class MarkdownClickHoldReleaseTests: XCTestCase {

    private var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."

    /// After a run: the hold is down, and a bibliography flush started now is not left waiting. A leaked hold is forced down afterwards so
    /// a failing run cannot leave a parked caller behind.
    private func assertReleased(_ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        let writer = rig.markdownWriter
        XCTAssertFalse(writer.isHeldForStructuralWork, "hold still raised after \(label)", file: file, line: line)
        rig.editorState.contentState = .idle
        let rigForFlush = rig.writerRig
        let outcome = await runWithin(2) { await rigForFlush.writeNow() }
        XCTAssertNotNil(outcome, "writeNow did not complete (deadlock) after \(label)", file: file, line: line)
        if writer.isHeldForStructuralWork {
            let parked = writer.structuralHoldState.waiters
            writer.structuralHoldState.waiters = []
            writer.structuralHoldState.count = 0
            parked.forEach { $0.resume() }
        }
    }

    // MARK: - run 1

    func testRun1_AMismatchTheFlushCannotFixTakesTheOldBodyAndReleasesTheHold() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let chapter3 = try rig.section("Chapter 3")
        try await rig.userTypes(" Two", after: "# Chapter 2")   // the user renames the heading by typing
        rig.editorState.contentState = .bibliographyUpdate   // the flush's guard refuses a busy content state

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertNil(outcome, "the click must give up so the old body runs")
        let pageAfter = try await rig.pageText()
        XCTAssertTrue(pageAfter.contains("# Chapter 3"), "a click that gave up must leave the page as it was")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the rebuild stamp's job count was not undone on the early exit")
        await assertReleased("fallback (mismatch)")
    }

    // MARK: - run 2

    func testRun2_AJavaScriptErrorReleasesTheHold() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let chapter3 = try rig.section("Chapter 3")
        rig.controller.activeWebView = WKWebView()   // no editor in it: every call into window.FinalFinal throws

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertNil(outcome, "the click must give up so the old body runs")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the rebuild stamp's job count was not undone on the early exit")
        await assertReleased("fallback (JavaScript error)")
    }

    // MARK: - run 3

    func testRun3_AFailedJobReleasesTheHoldThroughTheContinuationsOwnDefer() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let chapter3 = try rig.section("Chapter 3")
        try rig.db.write { database in
            try database.execute(sql: "CREATE TRIGGER forced_block_delete_failure BEFORE DELETE ON block BEGIN SELECT RAISE(ABORT, 'forced'); END")
        }

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertEqual(outcome, .performed, "the click itself succeeds: the editor changed and the job was queued")
        let released = await rig.waitUntil(10) { !self.rig.markdownWriter.isHeldForStructuralWork }
        XCTAssertTrue(released, "hold still raised after a failed job")
        await rig.settleEverything()
        await assertReleased("a failed job")
    }

    // MARK: - run 4

    func testRun4_ACancelledContinuationStillReleasesTheHold() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let hold = rig.holdNextJob()   // the job stays unapplied, so the continuation is waiting on it
        let chapter3 = try rig.section("Chapter 3")

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the continuation owns the hold while the job is held")
        let continuation = try XCTUnwrap(rig.markdownWriter.structuralHoldState.continuations.values.first, "no continuation was kept")
        continuation.cancel()
        await continuation.value

        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still raised after the continuation was cancelled")
        await assertReleased("the continuation was cancelled")
        hold.release()
        await rig.settleEverything()
    }
}
