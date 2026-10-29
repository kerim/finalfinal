//
//  MarkdownEditorFirstDuplicateTests+Hold.swift
//  final finalTests
//
//  t-4a8fd8af slice 3, round C2d: the judge's fix A (the writer's structural hold is waited for by the zoom, Save Version, export and the
//  idle backup) and its neighbours. An extension of the class in MarkdownEditorFirstDuplicateTests.swift. Real page, real rows, real
//  writer. Needs `cd web && pnpm build` first.
//
//  THE WINDOW THESE TESTS HOLD OPEN. A Markdown click changes the page first and registers its job only later; in between it awaits
//  (the page call, the rows read, the writer's last write). The page already holds the copy, the rows do not, and the job registry
//  knows nothing, so a caller that asked only the registry ("is a job unsettled?") ran in that window. The rig opens the window with
//  `parkTheClick`: a typing write is put in flight behind a held system sequence, so the click's reply turn waits for it
//  (`while let pending = writer.inFlight`) after the page has taken the copy. Releasing the sequence lets everything go on.
//
//  The zoom itself (`ContentView.performUserZoomIn`) needs a ContentView, which the rig does not have; the zoom's two steps are its
//  pre-check, `editorState.hasUnfinishedStructuralWork`, and its wait, `editorState.awaitPendingStructuralJobs()`. The tests ask and run
//  exactly those two.
//
//  Break patches: docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/swift-<TESTID>.patch. The failure
//  each shows (the first message that fires):
//
//   S1a  testAZoomPressedWhileTheDuplicateClickIsInItsAwaitsIsHeldAndRunsAfterTheInsertion
//        BREAK: `hasUnfinishedStructuralWork` leaves out `|| markdownWriter.isHeldForStructuralWork`.
//        FAILS: "hasUnfinishedStructuralWork is false while the click holds the writer"
//   S1b  testASaveVersionFlushAndTheIdleBackupWaitWhileTheClickIsInItsAwaits
//        BREAK: delete `await markdownWriter.awaitStructuralHoldReleased()` in `awaitPendingStructuralJobs`.
//        FAILS: "premise: the live flush is parked at the writer's hold" and "two sets of copy rows"
//   S1c  testADuplicateWithTypingAndALeadersMismatchRetryCompletesWithoutWaitingOnItsOwnHold and
//        testADeleteAndADragWithALeadersMismatchRetryStillCompleteWithTheWaitInPlace
//        BREAK: in `flushTypingForMarkdownRetry` pass `bypassingStructuralHold: false`.
//        FAILS: "stuck for 20 s: the Duplicate click (a hold that is never released?)"
//   S2   testADuplicateThatFallsBackAndIsRefusedByTheOldBodyStillSavesTheTypingMadeJustBefore
//        BREAK: delete the `rearmMarkdownReparseAfterRefusedPress()` line in `performMarkdownEditorFirstDuplicate`.
//        FAILS: "the re-parse was not re-armed"
//   S3   testTheFinishingNoticeStaysOnScreenUntilTheDuplicateClickHasFinished
//        BREAK: in `runMarkdownEditorFirstDuplicate` stop the notice right after the hold wait (`waiting.stop()` there, no `defer`).
//        FAILS: "no 'Finishing the last change…' notice while the click was in its reply turn"
//   C13 testTypingMadeWhileTheReplyTurnWaitsForTheWriterIsSavedAndSurvivesUndoAndRedo   (judge: kept only if proven; a regression guard,
//        no break patch)
//   U17  testDuplicatingAChapterWithSubsectionsGivesEveryCopiedLeaderTheMarkerOfItsRow   (moved here from
//        MarkdownEditorFirstDuplicateTests.swift, where the class body had outgrown the lint limit)
//        BREAK: rewrite only the root marker.   FAILS: "copied leaders carry"
//   U9   testDuplicatingTheLastChapterBeforeNotesAndBibliographyKeepsBoth   (moved here, as U17)
//        BREAK: ignore stopLine (page side).   see the patch
//   U10  testSectionBreakRootCopyHasNoSuffix   (moved here, as U17)
//        BREAK: always suffix.   FAILS: "the section break got a ' copy' suffix"
//

import Foundation
import XCTest
@testable import final_final

/// What the zoom's wait saw at the moment it was let through.
@MainActor
final class ZoomObservation {
    var ran = false
    var copyRows = -1
    var pageHasCopy = false
}

/// A Duplicate click parked in its awaits (see the file header).
struct ParkedClick {
    let ticket: SystemTicket
    let click: Task<StructuralUndoController.StructuralOpOutcome, Never>
    let copyId: String
}

extension MarkdownEditorFirstDuplicateTests {

    /// Waits until `count` commands are parked in `awaitStructuralHoldReleased()` (the writer keeps them in `structuralHoldState.waiters`)
    /// and records a failure if they never are. A SIGNAL for "the command reached its wait": the tests that follow it assert what has not
    /// happened yet without a pause.
    @discardableResult
    func waitForParkedCommand(_ what: String, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let parked = await rig.waitUntil(8) { self.rig.markdownWriter.structuralHoldState.waiters.count >= count }
        XCTAssertTrue(parked, "premise: \(what) is parked at the writer's hold", file: file, line: line)
        return parked
    }

    /// Opens the window: types `typing`, puts a write of it in flight behind a held system sequence, presses Duplicate on `rootId` and
    /// waits until the page holds the copy. From then on the click is in its reply turn, waiting for the write; its job is not registered.
    func parkTheClick(rootId: String, copyTitle: String, typing: (text: String, after: String)) async throws -> ParkedClick {
        try await userTypes(typing.text, after: typing.after)
        let reported = await rig.waitUntil { self.rig.editorState.content.contains(typing.text) }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        let ticket = rig.writerRig.hold()
        rig.writerRig.fire(rig.editorState.content)   // the typing write: reserved behind the held sequence, so it stays in flight
        XCTAssertNotNil(rig.markdownWriter.inFlight, "premise: a typing write is in flight behind the held sequence")
        let click = startDuplicate(rootId: rootId)

        var copyId: String?
        for _ in 0..<150 where copyId == nil {   // polling for a state, not waiting for a time
            copyId = Self.markerId(in: try await pageText(), headingTitled: copyTitle)
            if copyId == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let id = try XCTUnwrap(copyId, "premise: the click put the copy on the page")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the click holds the writer")
        XCTAssertFalse(rig.editorState.efJobRegistry.hasUnsettledWork, "premise: the click's job is not registered yet (the window)")
        XCTAssertTrue(try headingRows(copyTitle).isEmpty, "premise: the rows have no copy yet")
        return ParkedClick(ticket: ticket, click: click, copyId: id)
    }

    // MARK: - S1a: the zoom

    // CLAIM: a zoom pressed while the Duplicate click is in its awaits (the page holds the copy, the job is not registered) is HELD, not
    // refused and not run at once: its pre-check sees unfinished work, its wait does not return until the insertion is complete, and then
    // it runs. There is exactly ONE copy, no "Couldn't Duplicate Section" alert, and at the moment the zoom ran the rows already held the
    // copy (order asserted).
    func testAZoomPressedWhileTheDuplicateClickIsInItsAwaitsIsHeldAndRunsAfterTheInsertion() async throws {
        try await startRig(Self.book4)
        let chapter3 = try rig.section("Chapter 3")
        let parked = try await parkTheClick(rootId: chapter3.id, copyTitle: "Chapter 3 copy", typing: (" zq7", "First chapter text."))

        XCTAssertTrue(
            rig.editorState.hasUnfinishedStructuralWork,
            "hasUnfinishedStructuralWork is false while the click holds the writer (the zoom would run at once)")
        let seen = ZoomObservation()
        let editorState = rig.editorState
        let zoom = Task { @MainActor () -> Bool in
            await editorState.awaitPendingStructuralJobs()
            seen.ran = true
            seen.copyRows = (try? self.headingRows("Chapter 3 copy").count) ?? -1
            let page = (try? await self.rig.pageText()) ?? ""
            seen.pageHasCopy = Self.markerId(in: page, headingTitled: "Chapter 3 copy") != nil
            return true
        }
        await waitForParkedCommand("the zoom's wait")
        XCTAssertFalse(seen.ran, "the zoom ran while the click was still in its awaits")

        try await releaseTicket(parked.ticket)
        let outcome = try await finish(parked.click, "the Duplicate click")
        XCTAssertEqual(outcome, .performed, "the Duplicate that the zoom had to wait for was not carried out")
        _ = try await finish(zoom, "the zoom's wait")
        try await settleAll()

        XCTAssertTrue(seen.ran)
        XCTAssertEqual(seen.copyRows, 1, "the zoom ran before the copy's rows existed (wanted exactly one copy set when it ran)")
        XCTAssertTrue(seen.pageHasCopy, "the zoom ran without the copy on the page")
        XCTAssertTrue(rig.controller.testShownAlerts.isEmpty, "an alert was shown: \(rig.controller.testShownAlerts)")
        XCTAssertEqual(try headingRows("Chapter 3 copy").map(\.id), [parked.copyId], "wanted one copy set with the minted ids")
        XCTAssertEqual(try rig.writerRig.rows().filter { $0.markdownFragment == "Third chapter text." }.count, 2, "two sets of copy rows")
        try await assertRowsMatchPage("after the held zoom ran")
    }

    // MARK: - S1b: Save Version, export, the idle backup

    // CLAIM: `flushLiveContentToDatabase` (the flush before Save Version, export and the idle backup) and a bare
    // `awaitPendingStructuralJobs()` called while the click is in its awaits are held; after the release the rows hold exactly ONE copy
    // set with the minted ids (the flush does not write the page's copy into the rows ahead of the job, so the job does not copy it again).
    func testASaveVersionFlushAndTheIdleBackupWaitWhileTheClickIsInItsAwaits() async throws {
        try await startRig(Self.book4)
        let chapter3 = try rig.section("Chapter 3")
        let parked = try await parkTheClick(rootId: chapter3.id, copyTitle: "Chapter 3 copy", typing: (" zq7", "First chapter text."))

        let flushDone = HoldTestFlag()
        let backupDone = HoldTestFlag()
        let editorState = rig.editorState
        let pageOwner = rig!
        let flush = Task { @MainActor () -> Int in
            await editorState.flushLiveContentToDatabase(currentContent: {
                (try? await pageOwner.pageText()).map { MarkdownLeaderMap.recordText(fromRaw: $0) }
            })
            flushDone.value = true
            return (try? self.headingRows("Chapter 3 copy").count) ?? -1
        }
        let backup = Task { @MainActor () -> Int in
            await editorState.awaitPendingStructuralJobs()
            backupDone.value = true
            return (try? self.headingRows("Chapter 3 copy").count) ?? -1
        }
        await waitForParkedCommand("the live flush", count: 2)
        XCTAssertFalse(flushDone.value, "the live flush returned while the click was still in its awaits")
        XCTAssertFalse(backupDone.value, "the idle backup's wait returned while the click was still in its awaits")

        try await releaseTicket(parked.ticket)
        let outcome = try await finish(parked.click, "the Duplicate click")
        XCTAssertEqual(outcome, .performed)
        let rowsWhenFlushEnded = try await finish(flush, "the live flush")
        let rowsWhenBackupWaitEnded = try await finish(backup, "the idle backup's wait")
        try await settleAll()

        XCTAssertEqual(rowsWhenFlushEnded, 1, "the live flush ended before the copy's rows existed")
        XCTAssertEqual(rowsWhenBackupWaitEnded, 1, "the idle backup's wait ended before the copy's rows existed")
        XCTAssertEqual(try headingRows("Chapter 3 copy").map(\.id), [parked.copyId], "two sets of copy rows (or the copy lost its minted id)")
        XCTAssertEqual(try rig.writerRig.rows().filter { $0.markdownFragment == "Third chapter text." }.count, 2, "two sets of copy rows")
        try await assertRowsMatchPage("after the held flush ran")
    }

    // MARK: - S1c: no command waits on its own hold

    // CLAIM: the step-8 flush, the click's own retry flush (`flushTypingForMarkdownRetry`, which bypasses the hold), the job and the
    // settle never wait on the hold the click itself holds. A heading renamed by typing makes the first page call disagree with the
    // rows; the retry flushes the typing and the click stays editor-first and completes; typing made while the job is held is saved.
    func testADuplicateWithTypingAndALeadersMismatchRetryCompletesWithoutWaitingOnItsOwnHold() async throws {
        try await startRig(Self.book)
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")
        try await userTypes(" Two", after: "# Chapter 2")   // the user renames a heading: the rows do not have it yet

        let outcome = try await performDuplicate(rootId: chapter3.id)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click took the old body after the leaders mismatch")
        try await userTypes(" kk4", after: "# Chapter 3 copy\n\nThird chapter text.")   // typing made while the job is held
        hold.release()
        try await settleAll()
        try await finishReparse()
        try await settleWriter()

        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("# Chapter 2 Two"), "the retry flush did not save the renamed heading")
        XCTAssertEqual(
            stored.components(separatedBy: "Third chapter text. kk4").count - 1, 1, "the typing made during the held job is not in the rows once")
        XCTAssertEqual(try headingRows("Chapter 3 copy").count, 1, "the copy is not in the rows once")
        try await assertRowsMatchPage("after the retry and the typing")
        assertQuiet("after the Duplicate with a retry")
    }

    // CLAIM: the same for a Delete and a drag (slices 1 and 2): each completes with a leaders mismatch retry in the way, with the wait
    // in `awaitPendingStructuralJobs` in place. (Regression guard; the break of the test above shows here too.)
    func testADeleteAndADragWithALeadersMismatchRetryStillCompleteWithTheWaitInPlace() async throws {
        try await startRig(Self.book4)
        let chapter4 = try rig.section("Chapter 4")
        try await userTypes(" Two", after: "# Chapter 2")   // a renamed heading: the Delete's first page call disagrees with the rows
        let deleted = try await performDelete(rootId: chapter4.id)
        XCTAssertEqual(deleted, .performed, "the Delete did not complete")
        try await settleAll()
        XCTAssertFalse(try rig.writerRig.storedText().contains("Chapter 4"), "the Delete did not reach the rows")
        XCTAssertTrue(try rig.writerRig.storedText().contains("# Chapter 2 Two"), "the Delete's retry flush did not save the renamed heading")

        try await userTypes(" Three", after: "# Chapter 3")   // and again for the drag
        await rig.editorState.refreshSectionsAwaiting()
        let cards = rig.editorState.sections
        let moved = try XCTUnwrap(cards.first { $0.title == "Chapter 1" })
        let target = try XCTUnwrap(cards.first { $0.title == "Chapter 3" })
        let request = SectionReorderRequest(
            sectionId: moved.id, targetSectionId: target.id, newLevel: moved.headerLevel, newParentId: target.parentId)
        var plan = cards
        if case .plan(let planned) = SectionReorderPlanner.plan(request: request, in: cards, syncService: rig.sectionSync) { plan = planned }
        let controller = rig.controller
        let result = try await bounded("the drag click (a hold that is never released?)") {
            await controller.performSectionReorderDetailed(sections: plan, request: request)
        }
        XCTAssertEqual(result.outcome, .performed, "the drag ended \(result.outcome)")
        XCTAssertTrue(result.editorFirst, "the drag took the old body")
        try await settleAll()
        let titles = try rig.writerRig.rows().filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
        XCTAssertEqual(titles, ["Chapter 2 Two", "Chapter 3 Three", "Chapter 1"], "the drag did not move Chapter 1 to the end")
    }

    // MARK: - S2: the re-parse is re-armed when the click gives the press to the old body

    // CLAIM: the click cancels or never schedules the pending re-parse; when it then returns nil and the old body REFUSES before it
    // flushes, the typing made just before would sit only in the page. The click re-arms the re-parse (`rearmMarkdownReparseAfterRefusedPress`),
    // so the typing reaches the rows with no further keystroke. The refusal here is a Duplicate of the Notes heading, a root the
    // Outline never offers (its menu item is disabled for Notes and Bibliography, SectionCardView.swift) and the controller refuses
    // itself: the click returns nil at once and the old body's precheck refuses before flushing.
    func testADuplicateThatFallsBackAndIsRefusedByTheOldBodyStillSavesTheTypingMadeJustBefore() async throws {
        try await startRig("# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.\n\n## Notes\n\n[^1]: Note one.")
        rig.installReparseHost()
        rig.editorState.sourceReparseDebounce = .milliseconds(5)
        let notes = try XCTUnwrap(
            try rig.writerRig.rows().first { $0.isNotes && $0.blockType == .heading }, "premise: the document has a Notes heading")
        try await userTypes(" zq7", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("zq7") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        XCTAssertFalse(try rig.writerRig.storedText().contains("zq7"), "premise: nothing has saved the typing yet")

        let outcome = try await performDuplicate(rootId: notes.id)

        XCTAssertEqual(outcome, .refused, "the old body must refuse a Duplicate of the Notes")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "an editor-first entry was made for a Notes root")
        let saved = await rig.waitUntil(8) { (try? self.rig.writerRig.storedText().contains("Second chapter text. zq7")) == true }
        XCTAssertTrue(saved, "typing made just before the refused Duplicate never reached the rows (the re-parse was not re-armed)")
        let page = try await pageText()
        XCTAssertTrue(page.contains("zq7"), "the typing is gone from the page")
    }

    // MARK: - S3: the "Finishing the last change…" notice is for the whole click

    // CLAIM (acceptance ruling, floor 3): the delayed notice belongs to the whole click, not only to the wait for an earlier command's
    // hold. No earlier command holds the writer here, so that wait is over at once; the click is then parked in its reply turn (the page
    // has the copy, the typing's write is in flight behind a held system sequence). The notice (delayed by 30 ms in this test) is on
    // screen at that point, it was shown once, and it is gone when the click has returned.
    func testTheFinishingNoticeStaysOnScreenUntilTheDuplicateClickHasFinished() async throws {
        try await startRig(Self.book4)
        rig.shortenProgressDelay(.milliseconds(30))
        let chapter3 = try rig.section("Chapter 3")
        let parked = try await parkTheClick(rootId: chapter3.id, copyTitle: "Chapter 3 copy", typing: (" zq7", "First chapter text."))
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.waiters.isEmpty, "premise: the click waited for no earlier command's hold")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the click is still running (it holds the writer)")

        let shown = await rig.waitUntil(3) { self.rig.toastCenter.current?.message == DelayedProgressToast.finishingMessage }
        XCTAssertTrue(shown, "no 'Finishing the last change…' notice while the click was in its reply turn (taken down when the hold wait ended?)")

        try await releaseTicket(parked.ticket)
        let outcome = try await finish(parked.click, "the Duplicate click")
        XCTAssertEqual(outcome, .performed)
        XCTAssertNil(rig.toastCenter.current, "the notice is still showing after the click has returned")
        let shownLines = rig.toastLog.lines.filter { $0.contains(DelayedProgressToast.finishingMessage) }
        XCTAssertEqual(shownLines.count, 1, "the notice was shown \(shownLines.count) times, wanted once: \(shownLines)")
        try await settleAll()
    }

    // MARK: - C13: typing while the reply turn waits for the writer, on a larger document

    /// Twelve chapters of three paragraphs each: a document big enough that the writer has real work.
    static let largeBook: String = (1...12).map { chapter in
        (["# Chapter \(chapter)"] + (1...3).map { "Chapter \(chapter) paragraph \($0)." }).joined(separator: "\n\n")
    }.joined(separator: "\n\n")

    /// Waits (bounded) until the content record contains `typed` AND equals the page's text (anchors and the bibliography opening marker
    /// removed, as `ContentView`'s `onContentChange` makes it). The record follows the page through the page's own `contentChanged` report,
    /// which reaches Swift asynchronously, so after a page-driven change (a text Cmd-Shift-Z, a typed word) it can lag the page for a
    /// while on a loaded machine; the app's debounced re-parse reads the record when it fires, so a re-parse started by hand must not
    /// run before the record has caught up. A wait on a state, not a pause.
    func waitForContentRecordToCatchUp(containing typed: String, _ context: String) async throws {
        let page = MarkdownLeaderMap.recordText(fromRaw: try await pageText())
        let caughtUp = await rig.waitUntil { self.rig.editorState.content.contains(typed) && self.rig.editorState.content == page }
        XCTAssertTrue(caughtUp, "premise: the content record contains \(typed) and equals the page's text \(context)")
    }

    // CLAIM (judge C13): keystrokes typed into the copy while the click's reply turn waits for the writer's write in flight are in the
    // rows after everything settles (exactly once), and they survive Cmd-Z twice (the typing, then the Duplicate) and Cmd-Shift-Z twice
    // (the Duplicate, then the typing, inside the copy).
    func testTypingMadeWhileTheReplyTurnWaitsForTheWriterIsSavedAndSurvivesUndoAndRedo() async throws {
        try await startRig(Self.largeBook, undo: true)
        let chapter6 = try rig.section("Chapter 6")
        let parked = try await parkTheClick(rootId: chapter6.id, copyTitle: "Chapter 6 copy", typing: (" zq7", "Chapter 1 paragraph 1."))

        try await userTypes(" cd2", after: "# Chapter 6 copy\n\nChapter 6 paragraph 1.")   // into the copy, while the click waits
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("cd2") }
        XCTAssertTrue(reported, "premise: the typing in the copy reached the content record")

        try await releaseTicket(parked.ticket)
        let outcome = try await finish(parked.click, "the Duplicate click")
        XCTAssertEqual(outcome, .performed)
        try await settleAll()
        try await waitForContentRecordToCatchUp(containing: " cd2", "before the first re-parse")
        _ = rig.writerRig.schedule(rig.editorState.content)   // the app's debounced re-parse, by hand
        try await finishReparse()
        try await settleWriter()

        let page = try await pageText()
        XCTAssertEqual(page.components(separatedBy: " cd2").count - 1, 1, "the typing made while the click waited is not on the page exactly once")
        let stored = try rig.writerRig.storedText()
        XCTAssertEqual(stored.components(separatedBy: " cd2").count - 1, 1, "the typing made while the click waited is not in the rows exactly once")
        XCTAssertEqual(stored.components(separatedBy: " zq7").count - 1, 1, "the typing made before the click is not in the rows exactly once")
        XCTAssertEqual(try headingRows("Chapter 6 copy").map(\.id), [parked.copyId], "the copy's heading row does not have the minted id")
        try await assertRowsMatchPage("after the typing made during the wait settled")

        try await press("undo", until: { !$0.contains("cd2") }, "the first Cmd-Z did not undo the typing in the copy")
        try await press("undo", until: { !$0.contains("Chapter 6 copy") }, "the second Cmd-Z did not take the copy out")
        let afterUndo = try await pageText()
        XCTAssertTrue(afterUndo.contains("zq7"), "the typing made before the click was undone with the Duplicate")
        try await press("redo", until: { $0.contains("Chapter 6 copy") && !$0.contains("cd2") }, "the first Cmd-Shift-Z did not bring the copy back")
        try await press("redo", until: { $0.contains("cd2") }, "the second Cmd-Shift-Z did not bring the typing back inside the copy")
        try await waitForContentRecordToCatchUp(containing: " cd2", "after the redo, before the last re-parse")
        _ = rig.writerRig.schedule(rig.editorState.content)
        try await finishReparse()
        try await settleWriter()
        let finalStored = try rig.writerRig.storedText()
        XCTAssertEqual(finalStored.components(separatedBy: " cd2").count - 1, 1, "the typing is not in the rows once after undo and redo")
        try await assertRowsMatchPage("after undo and redo")
    }

    // MARK: - T4: the usual shapes of a document

    // CLAIM: a document that ends with a newline (or two), the usual shape, is duplicated through the Swift click with the copy before
    // the trailing newlines and exactly the text a plain insertion would give; rows and page agree.
    func testADocumentEndingWithOneNewlineGetsTheCopyBeforeIt() async throws {
        try await assertTrailingNewlines("\n")
    }

    func testADocumentEndingWithTwoNewlinesGetsTheCopyBeforeThem() async throws {
        try await assertTrailingNewlines("\n\n")
    }

    private func assertTrailingNewlines(_ trailing: String) async throws {
        try await startRig(Self.book + trailing)
        let pageBefore = try await pageText()
        XCTAssertEqual(pageBefore, Self.book + trailing, "premise: the page keeps the document's trailing newlines")
        let outcome = try await duplicate("Chapter 3")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        let page = try await pageText()
        let copyId = try XCTUnwrap(Self.markerId(in: page, headingTitled: "Chapter 3 copy"), "no marker in front of the copy heading")
        let expected = Self.book + "\n\n<!-- @sid:\(copyId) --># Chapter 3 copy\n\nThird chapter text." + trailing
        XCTAssertEqual(page, expected, "the copy is not before the document's trailing newlines, or the text is not a plain insertion")
        XCTAssertEqual(try headingRows("Chapter 3 copy").map(\.id), [copyId])
        try await assertRowsMatchPage("with a trailing newline")
    }

    // CLAIM: a Duplicate with a NON-EMPTY selection in the page (made with Shift-Right key presses inside the original chapter) leaves
    // a correct copy: one copy set, the page text is a plain insertion, rows and page agree. The page's own tests (WD20a to WD20c) pin
    // where the selection ends up; this checks that the Swift click copes with one. (The selection is made by key events; the test
    // cannot read it back, so a selection that did not form would make this a plain Duplicate.)
    func testADuplicateWithANonEmptySelectionLeavesACorrectCopy() async throws {
        try await startRig(Self.book)
        let pageBefore = try await pageText()
        _ = try await bounded("selecting text in the page", seconds: 10) {
            try? await self.rig.helper.webView.evaluateJavaScript(
                """
                (() => {
                  const ff = window.FinalFinal;
                  const doc = ff.getContentRaw();
                  const at = doc.indexOf('Second chapter text.');
                  const before = doc.slice(0, at);
                  ff.setCursorPosition({ line: before.split('\\n').length, column: 0 });
                  const el = document.querySelector('.cm-content');
                  for (let n = 0; n < 6; n++) {
                    el.dispatchEvent(new KeyboardEvent('keydown', {
                      key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, shiftKey: true, bubbles: true, cancelable: true
                    }));
                  }
                  return true;
                })()
                """)
        }

        let outcome = try await duplicate("Chapter 2")

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        let page = try await pageText()
        let copyId = try XCTUnwrap(Self.markerId(in: page, headingTitled: "Chapter 2 copy"))
        let expectedTail = "# Chapter 2\n\nSecond chapter text.\n\n<!-- @sid:\(copyId) --># Chapter 2 copy\n\nSecond chapter text.\n\n# Chapter 3"
        XCTAssertTrue(page.contains(expectedTail), "the text around the copy is not a plain insertion (the selection changed text)")
        XCTAssertEqual(MarkdownLeaderMap.recordText(fromRaw: page).count, pageBefore.count + "\n\n# Chapter 2 copy\n\nSecond chapter text.".count)
        XCTAssertEqual(try headingRows("Chapter 2 copy").map(\.id), [copyId])
        try await assertRowsMatchPage("after a Duplicate with a selection")
    }

    // MARK: - U17

    // CLAIM: duplicating a chapter with three sub-sections (one holding an image line) gives EVERY copied leader the marker of its own
    // row; the page order of the copy's leaders is the rows' order; the page text equals the rows' assembly; the image line is copied
    // once on each side.
    func testDuplicatingAChapterWithSubsectionsGivesEveryCopiedLeaderTheMarkerOfItsRow() async throws {
        try await startRig(Self.chaptersWithParts)
        let idsBefore = Set(try rig.writerRig.rows().map(\.id))
        let outcome = try await duplicate("Chapter 2")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()

        let page = try await pageText()
        let copied = Self.markers(in: page).map { (id: $0.id, title: Self.headingTitle(of: $0.line) ?? "") }
        XCTAssertEqual(
            copied.map(\.title), ["Chapter 2 copy", "Part 2.1", "Part 2.2", "Part 2.3"],
            "copied leaders carry the wrong markers (wanted one marker per copied leader, in page order): \(copied)")
        let newHeadings = try rig.writerRig.rows().filter { $0.blockType == .heading && !idsBefore.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(
            newHeadings.map(\.textContent), ["Chapter 2 copy", "Part 2.1", "Part 2.2", "Part 2.3"], "the copy's heading rows are not in order")
        for (marker, row) in zip(copied, newHeadings) {
            XCTAssertEqual(marker.id, row.id, "\(row.textContent) marker != row (the marker names another id than the copy row)")
        }
        XCTAssertEqual(copied.map(\.id), newHeadings.map(\.id), "page order != row order")
        XCTAssertEqual(page.components(separatedBy: "![A picture](picture.png)").count - 1, 2, "the image line is not on the page twice")
        XCTAssertEqual(
            try rig.writerRig.storedText().components(separatedBy: "![A picture](picture.png)").count - 1, 2,
            "the image line is not in the rows twice")
        XCTAssertEqual(
            MarkdownLeaderMap.recordText(fromRaw: page), try rig.writerRig.storedText(), "page != rows assembly (page text and rows differ)")
    }

    // MARK: - U9

    private static let bibliographyEntries =
        "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
    private static let glueMarker = "<!-- ::auto-bibliography:: -->"

    // CLAIM: duplicating the last chapter before the Notes and the Bibliography puts the copy BEFORE the Notes; the Notes and the
    // Bibliography rows (ids and text) and their text on the page are exactly as before.
    func testDuplicatingTheLastChapterBeforeNotesAndBibliographyKeepsBoth() async throws {
        let record = "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.\n\n## Notes\n\n[^1]: Note one.\n\n"
            + Self.bibliographyEntries
        try await startRig(record)
        let managedBefore = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes || $0.blockType == .bibliography }
        XCTAssertGreaterThan(managedBefore.count, 0, "premise: the rows carry the managed regions")
        let managedSnapshot = managedBefore.sorted { $0.sortOrder < $1.sortOrder }.map { "\($0.id)|\($0.markdownFragment)" }
        try await typeIntoPage(record.replacingOccurrences(of: "# Bibliography", with: Self.glueMarker + "# Bibliography"))
        let pageBefore = try await pageText()
        let tailBefore = String(pageBefore[try XCTUnwrap(pageBefore.range(of: "## Notes")).lowerBound...])

        let outcome = try await duplicate("Chapter 2")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body (the page and the rows disagreed)")
        try await settleAll()
        let page = try await pageText()
        let copyAt = try XCTUnwrap(page.range(of: "# Chapter 2 copy"), "the copy is not on the page")
        let notesAt = try XCTUnwrap(page.range(of: "## Notes"), "the Notes heading is gone from the page")
        XCTAssertLessThan(copyAt.lowerBound, notesAt.lowerBound, "copy after Notes: the copy was put behind the Notes")
        XCTAssertEqual(String(page[notesAt.lowerBound...]), tailBefore, "Notes region changed: the text from the Notes heading on is not what it was")
        XCTAssertEqual(page.components(separatedBy: Self.glueMarker).count - 1, 1, "the Bibliography opening marker is not on the page exactly once")
        let managedAfter = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes || $0.blockType == .bibliography }
        XCTAssertEqual(
            managedAfter.sorted { $0.sortOrder < $1.sortOrder }.map { "\($0.id)|\($0.markdownFragment)" }, managedSnapshot,
            "the Notes or Bibliography rows changed (managed rows lost or rewritten)")
        XCTAssertEqual(try headingRows("Chapter 2 copy").count, 1, "the copy is not in the rows exactly once")
    }

    // MARK: - U10

    // CLAIM: a section break as the root gets NO " copy" suffix (the page and the rows agree), its marker is the break row's id, and the
    // page text equals the rows' assembly.
    func testSectionBreakRootCopyHasNoSuffix() async throws {
        let marker = BlockParser.sectionBreakMarker
        try await startRig("# Chapter 1\n\nOne body.\n\n\(marker)\n\nBreak body.\n\n# Chapter 2\n\nTwo body.")
        let breakRow = try XCTUnwrap(try rig.writerRig.rows().first { $0.isPseudoSection }, "premise: the document has a section break row")

        let outcome = try await performDuplicate(rootId: breakRow.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()

        let page = try await pageText()
        XCTAssertFalse(page.contains(" copy"), "the section break got a ' copy' suffix on the page")
        let breakMarkers = Self.markers(in: page).filter { $0.line.hasPrefix(marker) }
        XCTAssertEqual(breakMarkers.count, 1, "wanted one marker in front of the copied break, got \(breakMarkers.count)")
        let breakRows = try rig.writerRig.rows().filter { $0.isPseudoSection }.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(breakRows.count, 2, "the copy of the break is not in the rows")
        XCTAssertEqual(breakRows.last?.id, breakMarkers.first?.id, "the copied break's marker is not its row's id")
        XCTAssertFalse(try rig.writerRig.storedText().contains(" copy"), "the section break got a ' copy' suffix in the rows")
        XCTAssertEqual(
            MarkdownLeaderMap.recordText(fromRaw: page), try rig.writerRig.storedText(), "page != rows (the page text and the rows' assembly differ)")
    }
}
