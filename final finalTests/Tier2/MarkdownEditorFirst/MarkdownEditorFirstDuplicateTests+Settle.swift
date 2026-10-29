//
//  MarkdownEditorFirstDuplicateTests+Settle.swift
//  final finalTests
//
//  t-4a8fd8af slice 3, round C2: the settle of a Markdown Duplicate (footnotes and citations, a stale Notes rebuild landing after the
//  click) and the failure path (a job that does not apply is put back). An extension of the class in
//  MarkdownEditorFirstDuplicateTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first.
//
//  Break patches: docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/break-patches/swift-<TESTID>.patch. The failure
//  each shows:
//
//   U8   testFootnotedChapterCopySharesItsDefinitionsAndNotesAreUnchanged
//        BREAK: `MarkdownLeaderMap.duplicateRequest` sends `stopLine: nil` and the Notes heading unmanaged, so the page's range would run
//        into the Notes (the page then refuses: copyIds count != range, and the old body runs).   FAILS: "the click fell back to the old body"
//   U25  testAStaleNotesRebuildLandingAfterADuplicateClickIsRepostedAndRowsEqualPage   (judge: REQUIRED)
//        BREAK: delete `editorState.editorFirstClickGeneration &+= 1` in the click: a rebuild that read before the click is no longer
//        stale, so its push lands over the editor.   FAILS: "the rebuild's stamp is not stale"
//   U11  testAFailedDuplicateJobTakesTheCopyOutClearsTheOverlayAndShowsTheAlert
//        BREAK: delete BOTH `editorState.pendingRestoreSections[opId] = nil` lines the slice added to `putBackMarkdownJob`.
//        FAILS: "the sidebar still shows the copy (the overlay stayed up)"
//   U11b testADuplicateWhoseJobWasNeverReservedIsSwappedBackAndTheUserIsTold
//        BREAK: delete `|| kind == .sectionDuplicate` in `putBackMarkdownJob`.   FAILS: "page not swapped back"
//
//  The tests of the OLD BODY taken (moved here from MarkdownEditorFirstDuplicateTests.swift, where the class body had outgrown the lint limit):
//
//   U13  testWithTheSwitchOffPerformSectionDuplicateTakesTheOldBody   CONTROL (no break patch)
//   U24  testWhileZoomedTheMarkdownDuplicateNeverReachesThePageAndIsRefused
//        BREAK: drop `zoomedSectionId == nil`.   FAILS: "markdownStructuralDuplicate called while zoomed"
//   U24b testTheZoomBeginningWhileTheClickWaitsForAHeldHoldRefusesTheDuplicate
//        (the zoom begins while the click waits for an earlier command's hold; no break patch)
//
//  The sidebar tests (moved here from MarkdownEditorFirstDuplicateTests.swift, as above):
//
//   U4   testTheCopysCardTargetIsTheCopyWhileTheJobIsHeldAndAfter
//        BREAK: `new = source` in the minted pairs.   FAILS: "card target is not the copy's heading"
//   U12  testTheSidebarShowsTheCopyBeforeItsRowsExistWithTheOriginalsStatusAndTags
//        BREAK: skip the overlay call.   FAILS: "card missing"
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstDuplicateTests {

    static let footnotedBook =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n"
        + "# Chapter 3\n\nThird chapter text.[^3] A source says so [@smith2020].\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three."

    private func notesRows() throws -> [String] {
        try rig.writerRig.rows().filter { $0.isNotes }.sorted { $0.sortOrder < $1.sortOrder }.map { "\($0.id)|\($0.markdownFragment)" }
    }

    // MARK: - U8

    // CLAIM: a chapter holding a footnote reference AND a citation is duplicated: the copy SHARES the original's footnote definitions
    // (the Notes rows are untouched, every definition is in the Notes exactly once, every reference on the page names one), the citation
    // text is copied, the click stays editor-first, and the page equals the rows.
    //
    // D5 (judge, Finding C t-53a9fb75): does the Duplicate send the editor into `bibliographyUpdate`? The rig has no ContentView, and
    // `contentState = .bibliographyUpdate` is set only by ContentView's rebuild handlers (ContentView+NotificationHandlers.swift,
    // +FootnoteHandlers.swift, +ContentRebuilding.swift), so a sampler of `contentState` could not see it in this rig and is not used.
    // What reaches those handlers is the `.bibliographySectionChanged` notification, so the test counts that post: an ordinary Duplicate
    // of a chapter that cites a source the copy shares changes no bibliography row and must post none. The Notes post is logged only.
    func testFootnotedChapterCopySharesItsDefinitionsAndNotesAreUnchanged() async throws {
        try await startRig(Self.footnotedBook)
        let notesBefore = try notesRows()
        XCTAssertGreaterThan(notesBefore.count, 3, "premise: the rows hold the Notes heading and three definitions")
        let counter = DuplicateNotificationCounter([.notesSectionChanged, .bibliographySectionChanged])
        defer { counter.stop() }

        let outcome = try await duplicate("Chapter 3")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()

        DebugLog.log(
            .lifecycle,
            "[D5] testFootnotedChapterCopyShares...: .bibliographySectionChanged posts \(counter.count(.bibliographySectionChanged)), "
                + ".notesSectionChanged posts \(counter.count(.notesSectionChanged)) during a Duplicate of a footnoted, cited chapter")
        XCTAssertEqual(
            counter.count(.bibliographySectionChanged), 0,
            "the Duplicate reaches the bibliography rebuild (D5 / Finding C t-53a9fb75): the copy shares the original's citations")

        let page = try await pageText()
        let stored = try rig.writerRig.storedText()
        XCTAssertEqual(try notesRows(), notesBefore, "the Notes rows changed (the copy must share the original's definitions, not copy them)")
        for (name, text) in [("page", page), ("rows", stored)] {
            for label in 1...3 {
                XCTAssertEqual(
                    text.components(separatedBy: "[^\(label)]: ").count - 1, 1, "Notes holds [^\(label)] twice (or not at all) in the \(name)")
            }
            XCTAssertEqual(text.components(separatedBy: "[@smith2020]").count - 1, 2, "the citation is not in the \(name) twice (original and copy)")
        }
        let refs = Set(FootnoteSyncService.extractFootnoteRefs(from: page))
        XCTAssertTrue(refs.isSubset(of: ["1", "2", "3"]), "a reference on the page names no definition: \(refs.sorted())")
        XCTAssertEqual(try headingRows("Chapter 3 copy").count, 1, "the copy is not in the rows exactly once")
        let copyAt = try XCTUnwrap(page.range(of: "# Chapter 3 copy"))
        XCTAssertLessThan(copyAt.lowerBound, try XCTUnwrap(page.range(of: "## Notes")).lowerBound, "the copy is not before the Notes")
        try await assertRowsMatchPage("after the footnoted chapter was duplicated")
    }

    // MARK: - U25

    // CLAIM (judge-required): a Notes rebuild that READ the rows before the Markdown Duplicate click and lands after it is recognised as
    // stale: its push is skipped, the editor's own text (with the typing done during the settle) is given back, the owed re-push of
    // the managed regions is posted by the settle, and afterwards the rows equal the page, the references in the rows are the page's,
    // and the typing is kept and saved. The chapter holds a footnote reference and a citation.
    // Mirrors MarkdownSettleBranchTests.testTypingMadeWhileTheSettleIsHeldOpenSurvivesAStaleRebuildTailAndIsSaved, with the stamp taken
    // BEFORE the click so the stale reading comes from the click's own bump of the click generation.
    func testAStaleNotesRebuildLandingAfterADuplicateClickIsRepostedAndRowsEqualPage() async throws {
        try await startRig(Self.footnotedBook)
        rig.editorState.lifecycleHost = QuitFlushTestSupport.host(webView: rig.helper.webView)
        rig.editorState.sourceReparseDebounce = .milliseconds(5)
        let counter = DuplicateNotificationCounter([.notesSectionChanged, .bibliographySectionChanged])
        defer { counter.stop() }
        let gate = LifecycleEntryHarness.Gate()
        let reached = GateOrderLog()
        rig.controller.testEFSettleHold = {
            reached.note("held")
            await gate.wait()
        }
        // A Notes rebuild reads the rows now, before the click.
        let stamp = rig.editorState.stampRebuildRead()
        let outcome = try await duplicate("Chapter 3")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        let held = await rig.waitUntil { reached.items == ["held"] }
        XCTAssertTrue(held, "the settle never reached its hold")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "premise: step 8 had released the hold before the settle's resyncs")

        // The user types into the copy while the settle is parked.
        try await userTypes(" pq8", after: "# Chapter 3 copy")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("pq8") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")

        // The stale rebuild lands: its handler had put the database's text into `content`; the stale tail must give the editor's own back.
        rig.editorState.content = try rig.writerRig.storedText()
        XCTAssertFalse(rig.editorState.content.contains("pq8"), "premise: the database's text lacks the typing")
        let stale = try await bounded("the stale rebuild tail") {
            await self.rig.editorState.skipStaleRebuildTail(stamp, kind: "notes", blockSync: self.rig.writerRig.sync)
        }
        XCTAssertTrue(stale, "the rebuild's stamp is not stale: the click did not move the click generation, so its push would land")
        XCTAssertTrue(rig.editorState.managedRegionsNeedRepush, "the skipped push owes the editor a re-push")
        XCTAssertTrue(rig.editorState.content.contains("pq8"), "pq8 overwritten by Notes rebuild")
        XCTAssertTrue(rig.editorState.sourceContent.contains("pq8"), "pq8 overwritten by Notes rebuild (the source copy)")

        gate.open()
        try await settleAll()
        // ContentView arms the re-parse when `content` changes; the rig does it by hand.
        _ = rig.writerRig.schedule(rig.editorState.content)
        try await finishReparse()
        try await settleWriter()

        let page = try await pageText()
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(page.contains("pq8"), "pq8 is not in the editor")
        XCTAssertTrue(stored.contains("pq8"), "pq8 is not in the rows")
        XCTAssertFalse(rig.editorState.managedRegionsNeedRepush, "the settle left the owed re-push standing")
        XCTAssertGreaterThanOrEqual(counter.count(.notesSectionChanged), 1, "the settle did not re-post the Notes rebuild")
        XCTAssertGreaterThanOrEqual(counter.count(.bibliographySectionChanged), 1, "the settle did not re-post the Bibliography rebuild")
        try await assertRowsMatchPage("after the stale rebuild and the settle")
        XCTAssertEqual(
            FootnoteSyncService.extractFootnoteRefs(from: stored), FootnoteSyncService.extractFootnoteRefs(from: page),
            "the references in the rows are not the page's (renumbering did not reach the rows)")
        for label in 1...3 {
            XCTAssertEqual(stored.components(separatedBy: "[^\(label)]: ").count - 1, 1, "Notes holds [^\(label)] twice (or not at all) in the rows")
        }
        XCTAssertEqual(try headingRows("Chapter 3 copy pq8").count + (try headingRows("Chapter 3 copy").count), 1, "two sets of copy rows")
    }

    // MARK: - U11

    // CLAIM: a Duplicate whose job FAILS after it reserved its place is put back: the editor is swapped back to the text before the
    // click (nothing was typed), the copy is out of the page, the rows and the sidebar (the overlay that showed it is lifted), the entry
    // is gone, nothing is left held, and the user is told once with the DUPLICATE alert. The job fails because its root row is removed
    // from the database while the job waits behind a held system sequence (the Delete's recipe, MarkdownSettleBranchTests).
    func testAFailedDuplicateJobTakesTheCopyOutClearsTheOverlayAndShowsTheAlert() async throws {
        try await startRig(Self.book)
        let before = try await pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let chapter3 = try rig.section("Chapter 3")
        let ticket = rig.writerRig.hold()

        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let afterClick = try await pageText()
        XCTAssertNotEqual(afterClick, before, "premise: the editor already shows the copy")
        // The overlay must be up now, or the checks at the end cannot tell a lifted overlay from one that never was (run this test
        // alone with swift-U11: swift-U12 removes the overlay call, which would make the end-state checks pass for the wrong reason).
        let overlayUp = await rig.waitUntil { !self.rig.editorState.pendingRestoreSections.isEmpty && self.card("Chapter 3 copy") != nil }
        XCTAssertTrue(overlayUp, "premise: the sidebar shows the copy while the job waits (the overlay is up)")
        let rootId = chapter3.id
        try rig.db.write { database in
            try database.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [rootId])
        }
        try await releaseTicket(ticket)
        try await settleAll()

        try await assertDuplicatePutBack(before: before, titlesBefore: titlesBefore)
    }

    // The job is never reserved: the writer is pointed at another project between the click's guards and its job (the project is
    // switching away), so the job is refused (`.identityMismatch`) before it reserves anything: no job, no step 8, no continuation. The
    // put-back itself swaps the page back (nothing was typed since) and shows the DUPLICATE alert.
    func testADuplicateWhoseJobWasNeverReservedIsSwappedBackAndTheUserIsTold() async throws {
        try await startRig(Self.book)
        let before = try await pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let other = try TestFixtureFactory.createTemporary(content: "# Other project\n\nBody.")
        let otherPid = try TestFixtureFactory.getProjectId(from: other)
        let sync = rig.writerRig.sync
        let view = rig.helper.webView
        rig.controller.testBeforeMarkdownPagePrepare = {
            // After the click's guards (they compared the writer with this project), before its page call and its job.
            sync.configure(database: other, projectId: otherPid, webView: view)
        }
        let chapter3 = try rig.section("Chapter 3")

        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        try await settleAll()

        try await assertDuplicatePutBack(before: before, titlesBefore: titlesBefore)
    }

    /// The state a failed Duplicate must leave, whichever way the job failed.
    private func assertDuplicatePutBack(before: String, titlesBefore: [String]) async throws {
        let alerts = rig.controller.testShownAlerts
        XCTAssertEqual(alerts, ["Couldn't Duplicate Section"], "alert was \(alerts) (wanted exactly [Couldn't Duplicate Section])")
        let page = try await pageText()
        XCTAssertEqual(
            lines(MarkdownLeaderMap.recordText(fromRaw: page)), lines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "page not swapped back to the text from before the Duplicate (copy still shown on the page)")
        XCTAssertFalse(page.contains("Chapter 3 copy"), "copy still shown on the page")
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "the copy is in the rows although its job failed")
        XCTAssertEqual(
            lines(try rig.writerRig.storedText()), lines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "the rows are not the document from before the Duplicate")
        try await refreshSidebar()
        XCTAssertEqual(rig.editorState.sections.map(\.title), titlesBefore, "the sidebar still shows the copy (the overlay stayed up)")
        XCTAssertTrue(rig.editorState.pendingRestoreSections.isEmpty, "the sidebar still shows the copy (the overlay stayed up)")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed Duplicate's entry is still on the timeline")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed Duplicate's entry kind was kept")
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "the failed Duplicate's step-8 gate was kept")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up")
        XCTAssertTrue(rig.editorState.pendingRemovalIds.isEmpty, "the sidebar still hides a section")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
    }

    // MARK: - U13 (CONTROL)

    // CONTROL : with the kill switch off the click does nothing and `performSectionDuplicate` takes the old body.
    func testWithTheSwitchOffPerformSectionDuplicateTakesTheOldBody() async throws {
        try await startRig(Self.book)
        MarkdownEditorFirstSwitch.enabled = false
        let chapter3 = try rig.section("Chapter 3")
        let pageBefore = try await pageText()
        let generation = rig.editorState.editorFirstClickGeneration

        let direct = await rig.controller.performMarkdownEditorFirstDuplicate(rootId: chapter3.id)
        XCTAssertNil(direct, "the click ran with the switch off")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "the click took a hold with the switch off")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generation, "the click ran with the switch off")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty)
        let pageUntouched = try await pageText()
        XCTAssertEqual(pageUntouched, pageBefore, "the page was changed with the switch off")

        let controller = rig.controller
        let outcome = await runWithin(30) { await controller.performSectionDuplicate(rootId: chapter3.id) }
        XCTAssertNotNil(outcome, "the old body did not finish within 30 s (premise of this test)")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the click ran with the switch off")
        XCTAssertEqual(try headingRows("Chapter 3 copy").count, 1, "the old body did not duplicate the section")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0)
    }

    // MARK: - U24

    // CLAIM: while the editor is zoomed the Markdown Duplicate never reaches the page and `performSectionDuplicate` gives the old
    // body's refusal. The page is unchanged, no hold was taken, no editor-first entry exists. (The old body refuses before it changes
    // anything.) NEW GUARD UNDER TEST: `zoomedSectionId == nil`, the first condition of the click.
    func testWhileZoomedTheMarkdownDuplicateNeverReachesThePageAndIsRefused() async throws {
        try await startRig(Self.book)
        let chapter3 = try rig.section("Chapter 3")
        let pageBefore = try await pageText()
        let generation = rig.editorState.editorFirstClickGeneration
        rig.editorState.zoomedSectionId = chapter3.id
        defer { rig.editorState.zoomedSectionId = nil }

        let outcome = try await performDuplicate(rootId: chapter3.id)

        XCTAssertEqual(outcome, .refused, "a Duplicate while zoomed must be refused by the old body")
        let pageAfter = try await pageText()
        XCTAssertEqual(pageAfter, pageBefore, "markdownStructuralDuplicate called while zoomed (the page text changed)")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "a hold was taken while zoomed")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generation, "the click's stretch ran while zoomed")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "an editor-first entry was made while zoomed")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "an entry was recorded for a refused Duplicate")
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "the copy reached the rows while zoomed")
        // With the break patch the click went through: leave the zoom and let its job and settle finish before the rig is torn down.
        rig.editorState.zoomedSectionId = nil
        try await settleAll()
    }

    // The zoom begins while the click waits for an earlier command's hold: the wait is long enough for it, and the click must look
    // again after the wait. The earlier command (a Duplicate of Chapter 1, its job held) is left alone; the second command, a
    // Duplicate of Chapter 3, is refused by the old body and its copy never reaches the page.
    func testTheZoomBeginningWhileTheClickWaitsForAHeldHoldRefusesTheDuplicate() async throws {
        try await startRig(Self.book)
        let hold = holdJobs()
        let chapter1 = try rig.section("Chapter 1")
        let chapter3 = try rig.section("Chapter 3")
        let first = try await performDuplicate(rootId: chapter1.id)
        XCTAssertEqual(first, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the first command's hold is up")

        let second = startDuplicate(rootId: chapter3.id)
        await waitForParkedCommand("the second Duplicate")   // a signal, not a pause: the command is in the writer's list of parked callers
        let pageWhileWaiting = try await pageText()
        XCTAssertFalse(pageWhileWaiting.contains("Chapter 3 copy"), "premise: the second command is waiting, not acting")
        rig.editorState.zoomedSectionId = chapter3.id   // the zoom begins during the wait
        hold.release()
        let outcome = try await finish(second, "the second command")
        rig.editorState.zoomedSectionId = nil

        XCTAssertEqual(outcome, .refused, "the Duplicate that waited across the start of a zoom was not refused")
        let page = try await pageText()
        XCTAssertFalse(page.contains("Chapter 3 copy"), "markdownStructuralDuplicate called while zoomed (the second copy reached the page)")
        XCTAssertEqual(rig.controller.efEditorKind.count, 1, "an editor-first entry was made for the second command")
        try await settleAll()
    }

    // MARK: - U4

    // CLAIM: the Outline card of the copy scrolls to the COPY's heading, both while the job is held and after it ran. The card click
    // looks for the literal marker of the card's id in the page text (`markdownScrollTarget`).
    // for the copy, so the lookup finds nothing (the app then falls back to row arithmetic and lands far away).
    func testTheCopysCardTargetIsTheCopyWhileTheJobIsHeldAndAfter() async throws {
        try await startRig(Self.book)
        try await putMarkersOnTheOriginalHeadings()
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)

        func assertTargetIsTheCopy(_ phase: String) async throws {
            let cardAppeared = await rig.waitUntil { self.card("Chapter 3 copy") != nil }
            XCTAssertTrue(cardAppeared, "\(phase): the copy has no sidebar card")
            let copyCard = try XCTUnwrap(card("Chapter 3 copy"))
            let page = try await pageText()
            let source = rig.editorState.sourceContent
            XCTAssertEqual(source, page, "\(phase): premise: the record holds the page's text (the click adopted it)")
            // Where the copy's heading line starts, worked out from the page itself: the marker comment sits in front of "# Chapter 3 copy".
            let headingRange = (page as NSString).range(of: "# Chapter 3 copy")
            XCTAssertNotEqual(headingRange.location, NSNotFound, "\(phase): premise: the copy heading is on the page")
            let expected = headingRange.location - "<!-- @sid:\(copyCard.id) -->".utf16.count
            let target = ContentView.markdownScrollTarget(forSectionId: copyCard.id, sourceContent: source, rowsOffset: { nil })
            XCTAssertEqual(target, expected, "\(phase): card target is not the copy's heading (target == original, or nothing was found)")
            let originalMarker = (page as NSString).range(of: "<!-- @sid:\(chapter3.id) -->")
            XCTAssertNotEqual(target, originalMarker.location, "\(phase): card target is the ORIGINAL's heading")
            XCTAssertNotEqual(copyCard.id, chapter3.id, "\(phase): the copy's card has the original's id")
        }
        try await assertTargetIsTheCopy("job held")

        hold.release()
        try await settleAll()
        try await assertTargetIsTheCopy("after the job")
        let copyRow = try XCTUnwrap(try headingRows("Chapter 3 copy").first)
        XCTAssertEqual(card("Chapter 3 copy")?.id, copyRow.id, "the card's id is not the copy row's id after the job")
    }

    // MARK: - U12

    // CLAIM: the sidebar shows the copy at once, BEFORE its rows exist, right after the original, with the original's status, tags and
    // goal; the card keeps its id (the page marker's id) when the rows arrive.
    func testTheSidebarShowsTheCopyBeforeItsRowsExistWithTheOriginalsStatusAndTags() async throws {
        try await startRig(Self.book4)
        try rig.writerRig.setMetadata(onHeading: "Chapter 3", status: .review, tags: ["alpha", "beta"], wordGoal: 300)
        try await refreshSidebar()
        let hold = holdJobs()
        let chapter3 = try rig.section("Chapter 3")

        let outcome = try await performDuplicate(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(try headingRows("Chapter 3 copy").isEmpty, "premise: the rows have no copy yet")
        let shown = await rig.waitUntil { self.card("Chapter 3 copy") != nil }
        XCTAssertTrue(shown, "card missing: the sidebar does not show the copy while its job is held")
        let copyCard = try XCTUnwrap(card("Chapter 3 copy"))
        XCTAssertEqual(copyCard.status, .review, "the copy's card lost the original's status")
        XCTAssertEqual(copyCard.tags, ["alpha", "beta"], "the copy's card lost the original's tags")
        XCTAssertEqual(copyCard.wordGoal, 300, "the copy's card lost the original's word goal")
        let titles = rig.editorState.sections.map(\.title)
        let originalAt = try XCTUnwrap(titles.firstIndex(of: "Chapter 3"))
        XCTAssertEqual(titles[originalAt + 1], "Chapter 3 copy", "the copy's card is not right after the original: \(titles)")
        let page = try await pageText()
        XCTAssertEqual(copyCard.id, Self.markerId(in: page, headingTitled: "Chapter 3 copy"), "the card's id is not the page marker's id")

        hold.release()
        try await settleAll()
        try await refreshSidebar()
        let after = try XCTUnwrap(card("Chapter 3 copy"), "the copy's card left the sidebar when its rows arrived")
        let copyRow = try XCTUnwrap(try headingRows("Chapter 3 copy").first)
        XCTAssertEqual(after.id, copyRow.id, "the card's id changed when the rows arrived")
        XCTAssertEqual(after.status, .review)
        XCTAssertEqual(after.tags, ["alpha", "beta"])
        XCTAssertTrue(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the copy was not lifted")
    }
}
