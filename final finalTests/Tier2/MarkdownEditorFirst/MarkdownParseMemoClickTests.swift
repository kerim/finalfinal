//
//  MarkdownParseMemoClickTests.swift
//  final finalTests
//
//  t-2fbe4c9b Phase 4c job 3, round C1b: what the REAL Markdown clicks do with the parse memo and with the "Finishing the last change…"
//  notice, against the REAL CodeMirror page, a real database and the real writer (`MarkdownClickRig`). Needs `cd web && pnpm build`
//  first. NOT RUN by the coder: the driver builds and runs every Swift test.
//
//  STEP 8 AND THE MEMO (trigger iii). The Delete click's reply turn asks the memo to prepare the page's text after the delete
//  (`writer.prewarmParse(raw: postRaw, ...)`, StructuralUndoController+MarkdownEditorFirst.swift). Step 8 later flushes the page's live
//  text through `reserveStructuralFlush`, whose `prepare` looks it up. The job is held (`holdNextJob`), so the memo has all the time it
//  needs. The probe reads the memo's counters in the controller's ordering spy at `md8Read` (before step 8's synchronous turn) and
//  `md8Reserved` (after it): the difference is step 8's own lookup, and nothing else looks anything up in between.
//
//  THE NOTICE. Delete and the Outline drag keep the notice up for the whole click, as Duplicate already does. The click is PARKED in its
//  reply turn (the page has changed, a typing write is in flight behind a held system sequence, so the reply turn waits for it) and the
//  notice, delayed by 30 ms in these tests, must be on screen then, and gone once the click has returned. The Duplicate test is the
//  CONTROL: it passes on the code before this round too; if it fails the staging is wrong, not the notice.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   P3  testStep8HitsAfterPostRawPrewarm
//       BREAK: delete the `writer.prewarmParse(raw: postRaw, ...)` line in `markdownDeleteReplyTurn`.
//       FAILS: "step 8 did not hit the memo (live text == the text after the click)" (the first phase). The second phase asserts what
//       is required whatever the memo holds: the typing is in the rows and the deleted chapter is gone.
//   P4a testDeleteNoticeStaysUntilClickReturns
//       BREAK: in `runMarkdownEditorFirstDelete` put `waiting.stop()` back after `holdWaitSpan.end()` (and remove the `defer`).
//       FAILS: "no 'Finishing the last change…' notice while the click was in its reply turn".
//   P4b testDragNoticeStaysUntilClickReturns
//       BREAK: the same in `runMarkdownEditorFirstReorder`. FAILS with the same message.
//

import Foundation
import XCTest
@testable import final_final

/// A value a probe closure writes and the test reads (the ordering spy is not main-actor typed).
private final class CacheCounters {
    var before: (hits: Int, misses: Int)?
    var after: (hits: Int, misses: Int)?
}

private final class DoneFlag {
    var done = false
}

/// What step 8's own memo lookup found, and the rows afterwards.
private struct Step8Probe {
    let hit: Bool
    let miss: Bool
    let rows: String
}

@MainActor
final class MarkdownParseMemoClickTests: XCTestCase {

    private var rig: MarkdownClickRig!
    private var heldTicket: SystemTicket?

    override func tearDown() async throws {
        if let heldTicket, let rig { await rig.writerRig.release(heldTicket) }   // a failed test must not leave the writer held
        heldTicket = nil
        rig?.controller.testOrderingSpy = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."
    private static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    // MARK: - Step 8 and the memo (trigger iii)

    /// Deletes Chapter 3 with the job held, lets the memo settle, optionally types into the page, releases the job, and returns step 8's
    /// own memo lookup (the counters before and after its synchronous turn) and the rows afterwards.
    private func deleteAndProbeStep8(typedDuringTheJob typed: String?) async throws -> Step8Probe {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let cache = rig.markdownWriter.parseCache
        let counters = CacheCounters()
        rig.controller.testOrderingSpy = { step in
            if step == "md8Read" { counters.before = (cache.hitCount, cache.missCount) }
            if step == "md8Reserved" { counters.after = (cache.hitCount, cache.missCount) }
        }
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        if let typed { try await rig.userTypes(typed, after: "Second chapter text.") }
        await cache.settled()   // the reply turn's prewarm of the text after the delete is done (the job is held, so there is time)
        hold.release()
        await rig.settleEverything()
        let before = try XCTUnwrap(counters.before, "step 8 never read the page")
        let after = try XCTUnwrap(counters.after, "step 8 never reserved its flush")
        return Step8Probe(
            hit: after.hits - before.hits == 1, miss: after.misses - before.misses == 1, rows: try rig.writerRig.storedText())
    }

    func testStep8HitsAfterPostRawPrewarm() async throws {
        // Nothing typed: the live text is the text the reply turn prepared, so step 8's lookup is a hit.
        let untouched = try await deleteAndProbeStep8(typedDuringTheJob: nil)
        XCTAssertTrue(untouched.hit && !untouched.miss, "step 8 did not hit the memo (live text == the text after the click)")
        XCTAssertFalse(untouched.rows.contains("Chapter 3"), "the deleted chapter is still in the rows")
        XCTAssertTrue(untouched.rows.contains("Second chapter text."), "the rest of the document is missing from the rows")
        rig.restore()
        rig = nil

        // Typed while the job is held: whatever the memo holds, step 8 must write the typing into the rows, and the deleted chapter must
        // stay gone. (Whether step 8 hits or misses here is NOT asserted: in the app, typing followed by a pause of 300 ms or more
        // prepares the typed text through trigger (ii) and step 8 then hits; this rig sends no content changes to trigger (ii), so
        // `typed.hit` is false here only because of the rig.)
        let typed = try await deleteAndProbeStep8(typedDuringTheJob: " mn5")
        XCTAssertTrue(typed.rows.contains("Second chapter text. mn5"), "the typing is missing from the rows after step 8")
        XCTAssertFalse(typed.rows.contains("Chapter 3"), "the deleted chapter is still in the rows")
    }

    // MARK: - The notice stays until the click returns

    private func startNoticeRig() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true)
        rig.shortenProgressDelay(.milliseconds(30))
    }

    /// Types, then puts a write of the typing in flight behind a held system sequence: a click's reply turn waits for it.
    private func holdATypingWrite() async throws {
        try await rig.userTypes(" zq7", after: "First chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains(" zq7") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        heldTicket = rig.writerRig.hold()
        rig.writerRig.fire(rig.editorState.content)   // reserved behind the held sequence, so it stays in flight
        XCTAssertNotNil(rig.markdownWriter.inFlight, "premise: a typing write is in flight behind the held sequence")
    }

    /// The click is parked once `pageChanged` holds for the page's text (the page call is done, the reply turn waits for the write).
    /// The notice must be showing then and while the click still runs; once the writer is let go and the click has returned it is gone,
    /// shown exactly once.
    private func assertNoticeLastsForTheWholeClick(
        _ done: DoneFlag, pageChanged: (String) -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        var changed = false
        for _ in 0..<200 where !changed {   // polling for a state, not waiting for a time
            changed = pageChanged(try await rig.pageText())
            if !changed { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(changed, "premise: the \(what) click changed the page", file: file, line: line)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the \(what) click is still running", file: file, line: line)
        XCTAssertFalse(done.done, "premise: the \(what) click has not returned", file: file, line: line)

        let shown = await rig.waitUntil(3) { self.rig.toastCenter.current?.message == DelayedProgressToast.finishingMessage }
        XCTAssertTrue(
            shown, "no 'Finishing the last change…' notice while the \(what) click was in its reply turn (taken down when the hold wait ended?)",
            file: file, line: line)

        let ticket = try XCTUnwrap(heldTicket)
        heldTicket = nil
        await rig.writerRig.release(ticket)
        let returned = await rig.waitUntil(20) { done.done }
        XCTAssertTrue(returned, "the \(what) click never returned after the writer was let go", file: file, line: line)
        XCTAssertNil(rig.toastCenter.current, "the notice is still showing after the \(what) click has returned", file: file, line: line)
        let shownLines = rig.toastLog.lines.filter { $0.contains(DelayedProgressToast.finishingMessage) }
        XCTAssertEqual(shownLines.count, 1, "the notice was shown \(shownLines.count) times, wanted once: \(shownLines)", file: file, line: line)
        await rig.settleEverything()
    }

    func testDeleteNoticeStaysUntilClickReturns() async throws {
        try await startNoticeRig()
        let chapter3 = try rig.section("Chapter 3")
        try await holdATypingWrite()
        let done = DoneFlag()
        let controller = rig.controller
        let click = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let outcome = await controller.performSectionDelete(rootId: chapter3.id)
            done.done = true
            return outcome
        }
        try await assertNoticeLastsForTheWholeClick(done, pageChanged: { !$0.contains("# Chapter 3") }, "Delete")
        let outcome = await click.value
        XCTAssertEqual(outcome, .performed)
    }

    func testDragNoticeStaysUntilClickReturns() async throws {
        try await startNoticeRig()
        try await holdATypingWrite()
        // The request the sidebar sends when the card "Chapter 3" is dropped right after "Chapter 1", planned against the sidebar's list.
        let cards = rig.editorState.sections
        let moved = try XCTUnwrap(cards.first { $0.title == "Chapter 3" })
        let target = try XCTUnwrap(cards.first { $0.title == "Chapter 1" })
        let request = SectionReorderRequest(
            sectionId: moved.id, targetSectionId: target.id, newLevel: moved.headerLevel, newParentId: target.parentId)
        var plan = cards
        if case .plan(let planned) = SectionReorderPlanner.plan(request: request, in: cards, syncService: rig.sectionSync) { plan = planned }
        let done = DoneFlag()
        let controller = rig.controller
        let click = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let result = await controller.performSectionReorderDetailed(sections: plan, request: request)
            done.done = true
            return result.outcome
        }
        let movedFirst: (String) -> Bool = { page in
            guard let three = page.range(of: "# Chapter 3"), let two = page.range(of: "# Chapter 2") else { return false }
            return three.lowerBound < two.lowerBound
        }
        try await assertNoticeLastsForTheWholeClick(done, pageChanged: movedFirst, "drag")
        let outcome = await click.value
        XCTAssertEqual(outcome, .performed)
    }

    /// CONTROL: Duplicate already keeps the notice for the whole click (its own `defer`). Passes before and after this round.
    func testDuplicateNoticeStaysUntilClickReturnsControl() async throws {
        try await startNoticeRig()
        let chapter3 = try rig.section("Chapter 3")
        try await holdATypingWrite()
        let done = DoneFlag()
        let controller = rig.controller
        let click = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let outcome = await controller.performSectionDuplicate(rootId: chapter3.id)
            done.done = true
            return outcome
        }
        try await assertNoticeLastsForTheWholeClick(done, pageChanged: { $0.contains("# Chapter 3 copy") }, "Duplicate")
        let outcome = await click.value
        XCTAssertEqual(outcome, .performed)
    }
}
