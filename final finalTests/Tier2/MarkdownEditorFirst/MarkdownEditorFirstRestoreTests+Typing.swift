//
//  MarkdownEditorFirstRestoreTests+Typing.swift
//  final finalTests
//
//  t-4a8fd8af slice 4, round C2: typing around a Markdown restore click and the writer's hold. An extension of the class in
//  MarkdownEditorFirstRestoreTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  U15 IS ABOUT THE MOMENT OF THE PAGE CALL. Typing that reached the page BEFORE the call is the restore's base: if it lies in the part
//  being replaced it is replaced with it, it is saved to the rows first (the reply turn's batch, from `preRaw`), it is inside the
//  automatic version the job writes, and one Cmd-Z brings it back at the place it was typed. Typing that reaches the page AFTER the
//  call is kept (see U2 in MarkdownEditorFirstRestoreTests.swift). A test that cannot tell the two apart could pass with the text KEPT
//  instead of replaced; these tests tell them apart by what the page holds, and by the controller's `testLastRestorePlan`, which is set
//  only after the page's reply: the typing is on the page while it is still nil. (`[STRUCT-TRACE]` lines have no test sink, see
//  MarkdownEditorFirstRestoreTests+Support.swift.)
//
//   U15  testTypingInTheSectionWhileTheRestoreWaitsIsReplacedSavedInTheAutomaticVersionAndOneCmdZBringsItBack
//        A MUST-FAIL TEST FOR `preRaw` (the driver's run of swift-U15b.patch showed it fails; the earlier "CONTROL (code review T1)"
//        label was wrong). The typing arrives while an earlier Delete's job is held and the Replace waits at the hold. The Delete's own
//        step 8 does save the typing into the rows, but under the patch the Replace's reply-turn batch then writes the post-restore text
//        (`postRaw`, without the typing) over those rows BEFORE the restore's job starts, so the automatic version lacks it.
//   U15b testTypingInTheSectionDuringThePreparationIsReplacedSavedInTheAutomaticVersionAndOneCmdZBringsItBack   (the direct variant:
//        the window is not key during the click, so there is no earlier held command; the typing lands in the click's own preparation).
//        ALSO A MUST-FAIL TEST FOR `preRaw`: here only the reply turn's batch can put the typing into the rows before the job.
//        BOTH fail under the same patch (swift-U15b.patch; swift-U15.patch is a copy of it).
//        BREAK: in `markdownRestoreReplyTurn`, `prepareStructuralClick(text: MarkdownLeaderMap.recordText(fromRaw: postRaw), ...)`
//        instead of `preRaw`.   FAILS: "the automatic version the job wrote does not hold the typing"
//   U16  testAHeadingTypedJustBeforeReplaceOnItTakesTheNewPath
//        BREAK: delete the `flushTypingForMarkdownRetry` retry in `markdownSectionRestoreReplaceBuild`.
//        FAILS: "the click fell back to the old body (the target was unresolved)"
//   U17  testTheHoldComesDownWhenTheRestoreJobEndsNotAtTheSettleBound
//        BREAK: delete the `self?.notifyMarkdownJobEnded(key: registryKey, outcome: JobOutcome(result.outcome))` line after `reserved.fire()`.
//        FAILS: "stuck for 25 s: waiting for the zoom's wait to finish"
//

import Foundation
import XCTest
@testable import final_final

/// What the zoom stand-in of U17 saw.
@MainActor
final class RestoreZoomStamps {
    var zoomStartedAt: ContinuousClock.Instant?
}

extension MarkdownEditorFirstRestoreTests {

    /// The checks U15 and U15b share, after the restore has been carried out and everything settled: the typing is not on the page (it
    /// was replaced), exactly one automatic version holds it (the restore job's), and one Cmd-Z brings the page back to `typedPage`
    /// with the typing at the place it was typed, quick, and the rows have it after the settle.
    private func assertTheTypingWasReplacedSavedAndComesBack(
        typedPage: String, typed: String, spy: DuplicateSpyLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let page = try await pageText()
        XCTAssertFalse(
            page.contains(typed), "the typing in the replaced section is still on the page (kept instead of replaced)", file: file, line: line)
        let withTyping = try automaticVersions().filter { $0.previewMarkdown.contains(typed) }
        XCTAssertEqual(
            withTyping.count, 1, "the automatic version the job wrote does not hold the typing (or more than one does)", file: file, line: line)
        XCTAssertTrue(
            withTyping.first?.previewMarkdown.contains("Third chapter text.\(typed)") == true,
            "the automatic version holds the typing at another place", file: file, line: line)

        try await press("undo", until: { $0 == typedPage }, "one Cmd-Z did not bring the typing back exactly where it was typed")
        XCTAssertEqual(spy.count("quickUndoRestoreApplied"), 1, "the Cmd-Z was not quick", file: file, line: line)
        assertQuiet("after the Cmd-Z")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("Third chapter text.\(typed)"), "the rows do not have the typing back at its place", file: file, line: line)
        try await assertRowsMatchPage("after the Cmd-Z and the settle")
    }

    // MUST-FAIL for `preRaw` (shown by the driver's run of swift-U15b.patch; this was first labelled a CONTROL, which was wrong): under the
    // `postRaw` patch the reply-turn batch writes the post-restore text over the rows the Delete's step 8 had filled, so the typing is
    // gone from the rows, and from the automatic version, before the restore's job runs. U15b below is the same claim with no earlier
    // command held.
    //
    // CLAIM (U15): a Delete of another chapter holds the writer; Replace is pressed on Chapter 3 and waits at the hold (the page has not
    // been called: `testLastRestorePlan` is nil); the user types "QQQ" into Chapter 3 meanwhile; the Delete's job is released. The
    // restore then replaces Chapter 3's text with the version's: the page has no "QQQ" in it; the typing was saved to the rows BEFORE the
    // restore's job, so the one automatic version the restore wrote holds it; ONE Cmd-Z brings the page back to exactly the text with
    // the typing, and the rows (after the settle) have it too.
    func testTypingInTheSectionWhileTheRestoreWaitsIsReplacedSavedInTheAutomaticVersionAndOneCmdZBringsItBack() async throws {
        try await startRig(Self.book, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let version = try await saveVersion()
        let chapter4 = try rig.section("Chapter 4")
        let hold = holdJobs()   // the Delete's job body; the Replace's job reaches the same semaphore, so it is released twice below

        // The LAST chapter is deleted so the section table still lines up with the leaders (positions 0 to 2 are unchanged).
        let deleteOutcome = try await performDelete(rootId: chapter4.id)
        XCTAssertEqual(deleteOutcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the Delete's job is held, so its hold is up")
        let replace = try startReplace("Chapter 3", from: version)
        await waitForParkedCommand("the Replace")
        XCTAssertNil(rig.controller.testLastRestorePlan, "premise: the restore has not called the page yet (it waits for the Delete's hold)")

        try await userTypes(" QQQ", after: "Third chapter text.")
        let typedPage = try await pageText()
        XCTAssertTrue(typedPage.contains("Third chapter text. QQQ"), "premise: the typing is on the page")
        XCTAssertFalse(typedPage.contains("Chapter 4"), "premise: the Delete already took Chapter 4 off the page")
        XCTAssertNil(rig.controller.testLastRestorePlan, "premise: the page has still not been called when the typing landed")

        hold.release()
        hold.release()
        let outcome = try await finish(replace, "the Replace")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the Replace fell back to the old body")
        XCTAssertNotNil(rig.controller.testLastRestorePlan, "the editor-first click got no reply from the page")
        try await settleAll()

        try await assertTheTypingWasReplacedSavedAndComesBack(typedPage: typedPage, typed: " QQQ", spy: spy)
    }

    // CLAIM (U15b, the direct variant: no earlier command is held): the typing lands in the click's own preparation, after the click took
    // its hold and before it calls the page (`testBeforeMarkdownPagePrepare` is awaited right there). The same outcome: replaced, saved in
    // the automatic version, one Cmd-Z brings it back.
    func testTypingInTheSectionDuringThePreparationIsReplacedSavedInTheAutomaticVersionAndOneCmdZBringsItBack() async throws {
        try await startRig(Self.book, undo: true)
        let spy = DuplicateSpyLog()
        rig.controller.testOrderingSpy = { spy.note($0) }
        let version = try await saveVersion()
        let seen = RestoreHoldProbe()
        rig.controller.testBeforeMarkdownPagePrepare = {
            // ONE-SHOT. `prepareMarkdownPageForStructuralCommand` is shared: the quick Cmd-Z later calls it too (MarkdownQuickUndo.swift),
            // and a hook left in place typed " QQQ" a SECOND time between the keydown and the page's swap. The page's re-check then saw
            // a document that was no longer the entry's saved copy and refused the swap (`changed`), which shows the existing
            // "Some undo or redo presses could not be carried out." notice (the first run of this test).
            self.rig.controller.testBeforeMarkdownPagePrepare = nil
            seen.typedPage = try? await self.rig.userTypes(" QQQ", after: "Third chapter text.")
            seen.replyAlreadyThere = self.rig.controller.testLastRestorePlan != nil
        }

        let outcome = try await replaceSection("Chapter 3", from: version)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the Replace fell back to the old body")
        let typedPage = try XCTUnwrap(seen.typedPage, "the preparation hook never typed")
        XCTAssertEqual(seen.replyAlreadyThere, false, "the typing landed after the page's reply")
        XCTAssertTrue(typedPage.contains("Third chapter text. QQQ"), "premise: the typing is on the page")
        try await settleAll()
        try await assertTheTypingWasReplacedSavedAndComesBack(typedPage: typedPage, typed: " QQQ", spy: spy)
    }

    // MARK: - U16: a heading typed just before Replace

    // CLAIM: a heading typed a moment before Replace is pressed (the section table lists it because the window synced the table from the
    // page; the rows do not, because the typing is not saved yet) does not send the press down the old path: the click flushes the typing
    // ONCE, reads the rows and the table again, resolves the target, and goes editor-first. The typing (the new heading) is kept, the
    // text typed into the replaced section went with it, and no "target unresolved" line is written.
    func testAHeadingTypedJustBeforeReplaceOnItTakesTheNewPath() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)   // the record does not follow the page: the typing is unsaved
        let log = RestoreAlwaysLog()
        alwaysLog = log
        let version = try await saveVersion()
        try await userTypes("\n\n# Chapter 2b\n\nNew section text.", after: "Second chapter text.")
        try await userTypes(" EDITED", after: "Third chapter text.")
        let typed = MarkdownLeaderMap.recordText(fromRaw: try await pageText())
        await rig.sectionSync.syncNow(typed)   // opening the window syncs the table from the page's text
        XCTAssertTrue(try headingRows("Chapter 2b").isEmpty, "premise: the rows do not have the new heading (the typing is unsaved)")
        XCTAssertTrue(
            try rig.db.fetchSections(projectId: rig.pid).contains { $0.title == "Chapter 2b" }, "premise: the section table lists the new heading")

        let outcome = try await replaceSection("Chapter 3", from: version)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body (the target was unresolved)")
        XCTAssertNotNil(rig.controller.testLastRestorePlan, "the editor-first click got no reply from the page")
        XCTAssertFalse(
            log.lines.contains { $0.contains("restoreSectionReplace target unresolved") },
            "an unresolved line was written: \(log.lines.filter { $0.contains("EF-STRUCT") })")
        try await settleAll()
        let page = try await pageText()
        XCTAssertTrue(page.contains("# Chapter 2b"), "the heading typed before the press is gone from the page")
        XCTAssertFalse(page.contains("EDITED"), "the replaced section kept the text typed into it")
        XCTAssertEqual(try headingRows("Chapter 2b").count, 1, "the heading typed before the press did not reach the rows")
        try await assertRowsMatchPage("after the restore")
    }

    // MARK: - U17: the hold comes down when the job ends

    // CLAIM: the writer's hold falls when the restore JOB ends, not at the settle's 15-second bound. A zoom request (its two steps are
    // the pre-check and `awaitPendingStructuralJobs()`, as in the Duplicate's S1a) made while the job is held starts less than 2 seconds
    // after the job is let go. Without the job-ended signal the continuation waits for it for ever and the zoom waits with it.
    func testTheHoldComesDownWhenTheRestoreJobEndsNotAtTheSettleBound() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let hold = holdJobs()
        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")
        XCTAssertTrue(rig.editorState.hasUnfinishedStructuralWork, "premise: the zoom's pre-check sees unfinished work")

        let stamps = RestoreZoomStamps()
        let editorState = rig.editorState
        let zoom = Task { @MainActor in
            await editorState.awaitPendingStructuralJobs()
            stamps.zoomStartedAt = ContinuousClock.now
        }
        await waitForParkedCommand("the zoom's wait")
        let letGoAt = ContinuousClock.now
        hold.release()
        try await finish(zoom, "the zoom's wait", seconds: 25)

        let startedAt = try XCTUnwrap(stamps.zoomStartedAt, "the zoom never started")
        let waited = startedAt - letGoAt
        XCTAssertLessThan(
            waited, Duration.seconds(2),
            "the zoom started \(waited) after the job was let go (the hold came down at the settle's bound, not when the job ended)")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork)
        try await settleAll()
        XCTAssertFalse(try rig.writerRig.storedText().contains("EDITED"), "the restore did not reach the rows")
    }
}
