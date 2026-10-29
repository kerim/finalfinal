//
//  MarkdownEditorFirstDuplicateTests+Chain.swift
//  final finalTests
//
//  t-4a8fd8af slice 3, round C2: what is pressed AT ONCE after a Markdown Duplicate (its job is still held), and what a poll, a save or
//  a flush does while it is held. An extension of the class in MarkdownEditorFirstDuplicateTests.swift. Real page, real rows, real writer.
//  The tests prove "held, then acts", never "refused": the second command waits for the first job's apply (the gate holds every next
//  command), with typing made in between, and then does what it says. Needs `cd web && pnpm build` first.
//
//  A shared job-body hold (`holdNextJob`) blocks EVERY job on the writer's thread, so a test with two jobs releases it twice.
//
//  Break patches: docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/swift-<TESTID>.patch. The failure
//  each shows:
//
//   U18  testDuplicatingTheSameSectionTwiceAtOnceGivesTheSameOrderOnPageAndInRows
//        BREAK: delete `await writer.awaitStructuralHoldReleased()` in the new click.   FAILS: "row order != page order" (and "refused")
//   U19  testDuplicatingTheCopyAtOnceIsHeldThenMakesACopyOfTheCopy
//        BREAK: the same line.   FAILS: "the second Duplicate was refused or took the old body"
//   U20  testDeletingTheCopyAtOnceIsHeldAndTwoCmdZBringItBackThenTakeItOut
//        BREAK: delete `efRecordedStructGeneration[opId] = ...` in the click.   FAILS: "slow route"
//   U21  testDraggingTheCopysCardAtOnceIsHeldThenMovesItInPageAndRows
//        BREAK: release the hold at the click (`hold.release()` after `beginStructuralHold()`): the wait this test depends on is the
//        Duplicate's own hold, the drag's wait itself is the reorder's (existing) code.   FAILS: "reorder fell back"
//   U22  testWhileTheDuplicateJobIsHeldAPollAndATypingSaveChangeNothingAndTheJobMakesOneCopy
//        BREAK: delete `writer.noteQueuedStructuralJob()` in `markdownDuplicateReplyTurn`.   FAILS: "two sets of copy rows"
//   U23  testALiveFlushWaitsForThePendingDuplicateJob   CONTROL (shared code, passes if the wait works; no break patch)
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstDuplicateTests {

    /// Two release signals: the shared job-body hold blocks the first job and then the second.
    private func releaseBothJobs(_ hold: MarkdownClickRig.JobHold) {
        hold.release()
        hold.release()
    }

    // MARK: - U18

    // CLAIM: the same section duplicated twice at once: the second Duplicate waits for the first job's apply (typing made in between is
    // kept), then acts; page order is X, copy 2, copy 1 and the rows have the same order and the copies' minted ids.
    func testDuplicatingTheSameSectionTwiceAtOnceGivesTheSameOrderOnPageAndInRows() async throws {
        try await startRig(Self.book4)
        let hold = holdJobs()
        let chapter2 = try rig.section("Chapter 2")
        let first = try await performDuplicate(rootId: chapter2.id)
        XCTAssertEqual(first, .performed)
        let pageAfterFirst = try await pageText()
        let firstId = try XCTUnwrap(Self.markerId(in: pageAfterFirst, headingTitled: "Chapter 2 copy"), "premise: the first copy has a marker")

        let secondDone = HoldTestFlag()
        let controller = rig.controller
        let second = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let outcome = await controller.performSectionDuplicate(rootId: chapter2.id)
            secondDone.value = true
            return outcome
        }
        await waitForParkedCommand("the second Duplicate")   // a signal, not a pause: the command is in the writer's list of parked callers
        XCTAssertFalse(secondDone.value, "the second Duplicate ran before the first job applied")
        try await userTypes(" tz9", after: "First chapter text.")   // typing made while the second command waits

        releaseBothJobs(hold)
        let outcome = try await finish(second, "the second command")
        XCTAssertEqual(outcome, .performed, "the second Duplicate was refused")
        XCTAssertEqual(rig.controller.efEditorKind.count, 2, "the second Duplicate took the old body (refused: leadersMismatch)")
        try await settleAll()
        try await finishReparse()
        try await settleWriter()

        let page = try await pageText()
        let pageIds = Self.markers(in: page).filter { Self.headingTitle(of: $0.line) == "Chapter 2 copy" }.map(\.id)
        XCTAssertEqual(pageIds.count, 2, "wanted two copies on the page, got \(pageIds.count)")
        XCTAssertEqual(pageIds.last, firstId, "the first copy is not the one next to the original (page order must be X, copy 2, copy 1)")
        let rowIds = try headingRows("Chapter 2 copy").map(\.id)
        XCTAssertEqual(rowIds, pageIds, "row order != page order (the rows of the two copies are in another order than the page's)")
        XCTAssertTrue(page.contains("tz9"), "the typing made while the second command waited was lost on the page")
        XCTAssertTrue(try rig.writerRig.storedText().contains("tz9"), "the typing made while the second command waited is not in the rows")
        try await assertRowsMatchPage("after two Duplicates of the same section")
    }

    // MARK: - U19

    // CLAIM: Duplicate the copy at once: the command waits for the first job (the copy's rows do not exist yet), then makes a copy OF THE
    // COPY right after it; page order and row order agree and each copy's marker is its row's id.
    func testDuplicatingTheCopyAtOnceIsHeldThenMakesACopyOfTheCopy() async throws {
        try await startRig(Self.book4)
        let hold = holdJobs()
        let chapter2 = try rig.section("Chapter 2")
        let first = try await performDuplicate(rootId: chapter2.id)
        XCTAssertEqual(first, .performed)
        let shown = await rig.waitUntil { self.card("Chapter 2 copy") != nil }
        XCTAssertTrue(shown, "premise: the sidebar shows the copy")
        let copyCardId = try XCTUnwrap(card("Chapter 2 copy")).id
        XCTAssertTrue(try headingRows("Chapter 2 copy").isEmpty, "premise: the copy's rows do not exist yet")

        let second = startDuplicate(rootId: copyCardId)
        await waitForParkedCommand("the Duplicate of the copy")   // a signal, not a pause: the command is in the writer's list of parked callers
        let pageWhileWaiting = try await pageText()
        XCTAssertFalse(pageWhileWaiting.contains("Chapter 2 copy copy"), "the second Duplicate changed the editor before the first job applied")

        releaseBothJobs(hold)
        let outcome = try await finish(second, "the second command")
        XCTAssertEqual(outcome, .performed, "the second Duplicate was refused")
        XCTAssertEqual(rig.controller.efEditorKind.count, 2, "the second Duplicate was refused or took the old body")
        try await settleAll()

        let page = try await pageText()
        let pageMarkers = Self.markers(in: page).compactMap { marker in Self.headingTitle(of: marker.line).map { (id: marker.id, title: $0) } }
        XCTAssertEqual(
            pageMarkers.map(\.title), ["Chapter 2 copy", "Chapter 2 copy copy"], "the copies are not in the page in this order: \(pageMarkers)")
        let titles = try rig.writerRig.rows().filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
        XCTAssertEqual(
            titles, ["Chapter 1", "Chapter 2", "Chapter 2 copy", "Chapter 2 copy copy", "Chapter 3", "Chapter 4"],
            "the rows' headings are not in the page's order")
        for marker in pageMarkers {
            XCTAssertEqual(try headingRows(marker.title).first?.id, marker.id, "\(marker.title): the marker is not the row's id")
        }
        try await assertRowsMatchPage("after the Duplicate of the copy")
    }

    // MARK: - U20

    // CLAIM: Duplicate Chapter 2, delete the copy at once (the Delete is held until the Duplicate's job applied), then Cmd-Z twice: the
    // first brings the copy back (QUICK), the second takes it out again (QUICK). The ids of the copy are the click's.
    func testDeletingTheCopyAtOnceIsHeldAndTwoCmdZBringItBackThenTakeItOut() async throws {
        try await startRig(Self.book4, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let rowsBefore = try rowSnapshot()
        let pre = try await pageText()
        let hold = holdJobs()
        let chapter2 = try rig.section("Chapter 2")
        let first = try await performDuplicate(rootId: chapter2.id)
        XCTAssertEqual(first, .performed)
        let pageAfterDuplicate = try await pageText()
        let clickId = try XCTUnwrap(Self.markerId(in: pageAfterDuplicate, headingTitled: "Chapter 2 copy"))
        let shown = await rig.waitUntil { self.card("Chapter 2 copy") != nil }
        XCTAssertTrue(shown, "premise: the sidebar shows the copy")
        let copyCardId = try XCTUnwrap(card("Chapter 2 copy")).id

        let deleteDone = HoldTestFlag()
        let controller = rig.controller
        let delete = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let outcome = await controller.performSectionDelete(rootId: copyCardId)
            deleteDone.value = true
            return outcome
        }
        await waitForParkedCommand("the Delete of the copy")   // a signal, not a pause: the command is in the writer's list of parked callers
        XCTAssertFalse(deleteDone.value, "the Delete of the copy ran before the Duplicate's job applied")
        releaseBothJobs(hold)
        let deleteOutcome = try await finish(delete, "the Delete of the copy")
        XCTAssertEqual(deleteOutcome, .performed, "the Delete of the copy was refused")
        try await settleAll()
        let pageAfterDelete = try await pageText()
        XCTAssertFalse(pageAfterDelete.contains("Chapter 2 copy"), "the copy is still on the page after its Delete")
        XCTAssertTrue(try headingRows("Chapter 2 copy").isEmpty, "the copy is still in the rows after its Delete")
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 2, "premise: the Duplicate and the Delete are on the timeline")
        let duplicateEntry = try XCTUnwrap(rig.unifiedUndo.undoStack.first)
        XCTAssertEqual(duplicateEntry.kind, .sectionDuplicate)
        XCTAssertTrue(rig.controller.quickUndoEligible(duplicateEntry), "the Duplicate's Cmd-Z took the slow route (slow route)")

        try await press("undo", until: { $0 == pageAfterDuplicate }, "the first Cmd-Z did not bring the copy back")
        XCTAssertEqual(try headingRows("Chapter 2 copy").map(\.id), [clickId], "the copy came back with another id than the click's")
        try await press("undo", until: { $0 == pre }, "the second Cmd-Z did not take the copy out")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 2, "a Cmd-Z took the slow route (slow route)")
        assertQuiet("after both Cmd-Z")
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "the rows are not the original rows after both undos")
    }

    // MARK: - U21

    // CLAIM: dragging the copy's card at once: the drag waits for the Duplicate's job, then moves the copy in the page AND in the rows
    // (editor-first, never the old body); the copy keeps its id.
    func testDraggingTheCopysCardAtOnceIsHeldThenMovesItInPageAndRows() async throws {
        try await startRig(Self.book4)
        let hold = holdJobs()
        let chapter1 = try rig.section("Chapter 1")
        let first = try await performDuplicate(rootId: chapter1.id)
        XCTAssertEqual(first, .performed)
        let shown = await rig.waitUntil { self.card("Chapter 1 copy") != nil }
        XCTAssertTrue(shown, "premise: the sidebar shows the copy")
        let cards = rig.editorState.sections
        let moved = try XCTUnwrap(cards.first { $0.title == "Chapter 1 copy" })
        let target = try XCTUnwrap(cards.first { $0.title == "Chapter 3" })
        let request = SectionReorderRequest(
            sectionId: moved.id, targetSectionId: target.id, newLevel: moved.headerLevel, newParentId: target.parentId)
        var plan = cards
        if case .plan(let planned) = SectionReorderPlanner.plan(request: request, in: cards, syncService: rig.sectionSync) { plan = planned }

        let controller = rig.controller
        let dragDone = HoldTestFlag()
        let drag = Task { @MainActor () -> (outcome: StructuralUndoController.StructuralOpOutcome, editorFirst: Bool) in
            let result = await controller.performSectionReorderDetailed(sections: plan, request: request)
            dragDone.value = true
            return result
        }
        await waitForParkedCommand("the drag of the copy")   // a signal, not a pause: the command is in the writer's list of parked callers
        XCTAssertFalse(dragDone.value, "the drag ran before the Duplicate's job applied")

        releaseBothJobs(hold)
        let result = try await finish(drag, "the drag of the copy")
        XCTAssertEqual(result.outcome, .performed, "the drag ended \(result.outcome)")
        XCTAssertTrue(result.editorFirst, "reorder fell back to the old body")
        try await settleAll()

        let page = try await pageText()
        let pageTitles = page.split(separator: "\n").compactMap { line -> String? in
            let stripped = line.replacingOccurrences(of: "<!-- @sid:[0-9A-Fa-f-]+ -->", with: "", options: .regularExpression)
            return Self.headingTitle(of: stripped)
        }
        let expected = ["Chapter 1", "Chapter 2", "Chapter 3", "Chapter 1 copy", "Chapter 4"]
        XCTAssertEqual(pageTitles, expected, "the page's order after the drag")
        let rowTitles = try rig.writerRig.rows().filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
        XCTAssertEqual(rowTitles, expected, "the rows' order after the drag (row order != page order)")
        XCTAssertEqual(try headingRows("Chapter 1 copy").first?.id, moved.id, "the copy lost its id in the drag")
        try await assertRowsMatchPage("after the drag of the copy")
    }

    // MARK: - U22

    // CLAIM: while the Duplicate's job is held, a re-parse (the debounced fire) and a typing save (the writer's fire) change NOTHING in
    // the rows (the writer is held; they would otherwise insert the copy's text as new rows), and when the job runs it makes exactly ONE
    // set of copy rows, with the ids the click minted.
    func testWhileTheDuplicateJobIsHeldAPollAndATypingSaveChangeNothingAndTheJobMakesOneCopy() async throws {
        try await startRig(Self.book)
        let rowsBefore = try rowSnapshot()
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let pageHeld = try await pageText()
        let mintedId = try XCTUnwrap(Self.markerId(in: pageHeld, headingTitled: "Chapter 3 copy"))
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")

        // The re-parse and a writer save, both with the content record the click adopted (the page's text with the copy).
        _ = rig.writerRig.schedule(rig.editorState.content)
        try await finishReparse()
        _ = rig.writerRig.fire(rig.editorState.content)
        try await settleWriter()
        XCTAssertEqual(try rowSnapshot(), rowsBefore, "a poll or a save changed the rows while the job was held")

        hold.release()
        try await settleAll()
        try await finishReparse()
        try await settleWriter()
        let copyRows = try headingRows("Chapter 3 copy")
        XCTAssertEqual(copyRows.count, 1, "two sets of copy rows (\(copyRows.count) copy headings)")
        XCTAssertEqual(copyRows.first?.id, mintedId, "the copy heading row does not have the id the click minted")
        let bodies = try rig.writerRig.rows().filter { $0.markdownFragment == "Third chapter text." }
        XCTAssertEqual(bodies.count, 2, "two sets of copy rows (the body paragraph is in the rows \(bodies.count) times, wanted 2)")
        try await assertRowsMatchPage("after the held job ran")
    }

    // MARK: - U23 (CONTROL)

    // CONTROL (the wait is shared code; passes if it works): a live flush (the idle backup, Save Version, export) called while the
    // Duplicate's job is held returns only after the job has applied, and the rows have one set of copy rows.
    func testALiveFlushWaitsForThePendingDuplicateJob() async throws {
        try await startRig(Self.book)
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)

        let flushDone = HoldTestFlag()
        let editorState = rig.editorState
        let pageOwner = rig!
        let flush = Task { @MainActor in
            await editorState.flushLiveContentToDatabase(currentContent: {
                (try? await pageOwner.pageText()).map { MarkdownLeaderMap.recordText(fromRaw: $0) }
            })
            flushDone.value = true
        }
        await waitForParkedCommand("the live flush")   // a signal, not a pause: the command is in the writer's list of parked callers
        XCTAssertFalse(flushDone.value, "flush before job: the live flush returned before the Duplicate's job applied")
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "premise: the job is still held")

        hold.release()
        try await finish(flush, "the live flush")
        XCTAssertTrue(flushDone.value)
        try await settleAll()
        XCTAssertEqual(try headingRows("Chapter 3 copy").count, 1, "wanted one set of copy rows after the flush")
        XCTAssertEqual(try rig.writerRig.rows().filter { $0.markdownFragment == "Third chapter text." }.count, 2)
    }
}
