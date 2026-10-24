//
//  MarkdownEditorFirstDeleteTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5: the Markdown editor-first Delete Section click
//  (`StructuralUndoController.performMarkdownEditorFirstDelete`) against the REAL CodeMirror page, a real database and the real writer
//  (`MarkdownClickRig`). The switch (`MarkdownEditorFirstSwitch`) is on in every rig. Needs `cd web && pnpm build` first.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-U1   typing made just before the click is in the rows BEFORE the job runs: the click's own batch carries it (step 8's flush would
//          save it after the job, so the check is made while the job is held).
//          BREAK: in `markdownDeleteReplyTurn` pass `text: editorState.content` to `prepareStructuralClick` (not `recordText(fromRaw: preRaw)`).
//          FAILS: "typing lost: zq7 not in the rows before the job ran".
//   T-U2   typing made while the job is held is not overwritten by the click's own adopt, and when step 8 cannot flush (the page does not
//          answer its live read), the held re-parse's refire saves it after the release.
//          BREAK: in `MarkdownBlockWriter.prepare` delete the `holdFire(context.refire)` line (a held debounce fire keeps no refire).
//          FAILS: "kp4 not saved after the release".
//   T-U5   a heading renamed a moment ago: the first call mismatches, the flush makes the retry succeed, the click stays editor-first.
//          BREAK: delete the `if attempt?.reply.reason == "leadersMismatch" { ... }` block.   FAILS: "took old body after mismatch".
//   T-U14  typing right after the click's reply: the adopt leaves the coordinator knowing the page already holds the text. MECHANISM
//          ONLY: this rig has no SwiftUI `updateNSView`, so nothing here ever pushes `sourceContent` back into the page; whether the
//          typing survives in the app is shown by the VM run only (review C.F5).
//          BREAK: in `CodeMirrorEditor.Coordinator.adoptPageText` delete `lastPushedContent = raw`.   FAILS: "the view would push the
//          adopted text back into the page" (the record and the coordinator disagree).
//   T-U18  the word total after the delete equals a fresh parse of the same text.
//          BREAK: in the click skip the job (do not call `startEditorFirstJob`).   FAILS: "word total differs from a fresh parse".
//   gate   a second Delete pressed at once waits for the first job's apply and is never refused.
//          BREAK: delete `await writer.awaitStructuralHoldReleased()` (step 1).   FAILS: "the second delete ran before the first job applied".
//   DR-1   a second Delete that waits longer than the notice delay shows "Finishing the last change…" while it waits, and the notice is gone
//          when it has run.
//          BREAK: in `runMarkdownEditorFirstDelete` delete the `DelayedProgressToast(...)` line in front of `awaitStructuralHoldReleased()`.
//          FAILS: "no 'Finishing the last change…' notice while the second delete waited".
//   F5     the click's adopt cancels the deferred-push timer a suppressed derived push had armed: no recompute follows it.
//          BREAK: in `CodeMirrorEditor.Coordinator.adoptPageText` delete the `deferredPushTimer?.invalidate()` line.
//          FAILS: "a deferred recompute armed before the click fired after it".
//   OFF    with the switch off the click does nothing (no hold, no stamp, no page call) and performSectionDelete takes the old body.
//          BREAK: delete `guard MarkdownEditorFirstSwitch.enabled else { return nil }`.   FAILS: "the click ran with the switch off".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import XCTest
@testable import final_final

@MainActor
final class MarkdownEditorFirstDeleteTests: XCTestCase {

    private var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    private static let book = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text."
    private static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    // MARK: - T-U1

    func testTypingJustBeforeTheClickIsSavedWithIt() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        try await rig.userTypes(" zq7", after: "Second chapter text.")
        XCTAssertEqual(rig.editorState.content, Self.book, "premise: the content record lags the page (nothing reported the typing)")

        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        // The job is held: step 8's flush cannot have saved anything yet, so only the click's own typing batch (reserved ahead of the
        // job) can have put "zq7" into the rows.
        let batchSaved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("Second chapter text. zq7")) == true }
        XCTAssertTrue(batchSaved, "typing lost: zq7 not in the rows before the job ran")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Chapter 3"), "premise: the job has not run yet")

        hold.release()
        await rig.settleEverything()
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("Second chapter text. zq7"), "typing lost: zq7 not in the rows")
        XCTAssertFalse(stored.contains("Chapter 3"), "the deleted chapter is still in the rows")
        let page = try await rig.pageText()
        XCTAssertTrue(page.contains("zq7"))
        XCTAssertFalse(page.contains("Chapter 3"))
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the entry is not recorded as a Markdown editor-first entry")
    }

    // MARK: - T-U2

    func testTypingWhileTheJobIsHeldIsKeptAndSavedByTheReparseAfterTheRelease() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")

        // The user types while the job is held. The page reports it; the coordinator hands it to the content record.
        try await rig.userTypes(" kp4", after: "First chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("kp4") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        // The debounced re-parse comes due during the hold: it reserves nothing (the job has not applied) and keeps its refire.
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        XCTAssertFalse(try rig.writerRig.storedText().contains("kp4"), "premise: nothing was saved while the job was held")
        XCTAssertNotNil(rig.markdownWriter.structuralHoldState.heldRefire, "premise: the held fire kept its refire")
        let pageWhileHeld = try await rig.pageText()
        XCTAssertTrue(pageWhileHeld.contains("kp4"), "the click's adopt pushed the page's own text back over the typing")

        // Step 8 cannot read the page's live text (the web view does not answer): it flushes nothing and only releases the hold. The
        // typing is then saved by exactly one thing, the refire the held fire kept.
        rig.controller.activeWebView = nil
        hold.release()
        await rig.settleEverything()
        let saved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("kp4")) == true }
        XCTAssertTrue(saved, "kp4 not saved after the release")
        XCTAssertFalse(try rig.writerRig.storedText().contains("Chapter 3"))
        let pageAfter = try await rig.pageText()
        XCTAssertTrue(pageAfter.contains("kp4"), "the typing was overwritten")
    }

    // MARK: - T-U5

    func testHeadingRenamedAMomentAgoIsFlushedAndTheClickStaysEditorFirst() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        let chapter3 = try rig.section("Chapter 3")
        try await rig.userTypes(" Two", after: "# Chapter 2")   // the user renames the heading by typing

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed, "took old body after mismatch")
        await rig.settleEverything()

        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "took old body after mismatch")
        let stored = try rig.writerRig.storedText()
        XCTAssertTrue(stored.contains("# Chapter 2 Two"), "the flush did not save the renamed heading")
        XCTAssertFalse(stored.contains("Chapter 3"))
    }

    // MARK: - T-U14

    func testTypingRightAfterTheReplySurvivesAndNothingIsPushedBack() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let coordinator = try XCTUnwrap(rig.coordinator)
        XCTAssertEqual(
            coordinator.lastPushedContent, rig.editorState.sourceContent,
            "keys after reply overwritten: the view would push the adopted text back into the page")

        try await rig.userTypes(" abc", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("abc") }
        XCTAssertTrue(reported, "the typing made right after the reply never reached the content record")
        XCTAssertEqual(coordinator.lastPushedContent, rig.editorState.sourceContent, "the record and the coordinator disagree after typing")

        hold.release()
        await rig.settleEverything()
        // MECHANISM ONLY (see the header): the rig has no SwiftUI view to push `sourceContent` back, so no page check can fail here.
        XCTAssertEqual(coordinator.lastPushedContent, rig.editorState.sourceContent, "the record and the coordinator disagree after the settle")
    }

    // MARK: - The last chapter before the Notes and the Bibliography
    //
    // The document as the app really writes it: the content record has the generated bibliography WITHOUT the opening marker
    // (`BibliographySyncService` writes `# Bibliography` as a plain heading row), and the Markdown editor's text has the marker glued to
    // that heading (`injectBibliographyMarker`, "injected only for CodeMirror source mode"). The rows come from parsing the record; the
    // page is set to the source-view shape. BREAK (both lines together, a delete then runs into the managed rows): in `request` pass
    // `stopLine: nil`, and in `leader(of:)` return `managed: nil` for every leader. FAILS: "the delete ran into the Notes/Bibliography".

    private static let bibliographyEntries =
        "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
    private static let glueMarker = "<!-- ::auto-bibliography:: -->"

    private func deleteLastChapter(record: String, keeping kept: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        rig = try await MarkdownClickRig(markdown: record)
        let managedBefore = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes }.count
        XCTAssertGreaterThan(managedBefore, 0, "premise: the rows carry the managed regions", file: file, line: line)
        try await rig.type(record.replacingOccurrences(of: "# Bibliography", with: Self.glueMarker + "# Bibliography"))
        let lastChapter = try rig.section("Chapter 2")

        let outcome = await rig.controller.performSectionDelete(rootId: lastChapter.id)

        XCTAssertEqual(outcome, .performed, file: file, line: line)
        XCTAssertTrue(
            rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body (the page and the rows disagreed)",
            file: file, line: line)
        await rig.settleEverything()
        let page = try await rig.pageText()
        XCTAssertFalse(
            page.contains("Chapter 2") || page.contains("Second chapter text."), "the chapter is still in the page", file: file, line: line)
        let bibliographyTexts = [
            Self.glueMarker + "# Bibliography", "Smith, J. (2020). A book.", "Jones, K. (2021). Another.", "<!-- ::auto-bibliography-end:: -->"
        ]
        for text in kept + bibliographyTexts {
            XCTAssertTrue(
                page.contains(text), "the delete ran into the Notes/Bibliography: \(text) is gone from the page", file: file, line: line)
        }
        let stored = try rig.writerRig.storedText()
        XCTAssertFalse(stored.contains("Chapter 2"), "the chapter is still in the rows", file: file, line: line)
        let managedAfter = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes }.count
        XCTAssertEqual(managedAfter, managedBefore, "the delete ran into the Notes/Bibliography: managed rows were lost", file: file, line: line)
    }

    func testDeletingTheLastChapterBeforeNotesAndBibliographyKeepsBothAndStopsExactlyAtThem() async throws {
        try await deleteLastChapter(
            record: "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.\n\n## Notes\n\n[^1]: Note one.\n\n"
                + Self.bibliographyEntries,
            keeping: ["## Notes", "[^1]: Note one.", "First chapter text.[^1]"])
    }

    func testDeletingTheLastChapterBeforeTheBibliographyKeepsItAndStopsExactlyAtIt() async throws {
        try await deleteLastChapter(
            record: "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n" + Self.bibliographyEntries,
            keeping: ["# Chapter 1", "First chapter text."])
    }

    // MARK: - T-U18

    func testWordTotalAfterTheDeleteEqualsAFreshParseOfTheSameText() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book4)
        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()

        let rowsTotal = try rig.db.fetchBlocks(projectId: rig.pid).map(\.wordCount).reduce(0, +)
        let postText = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        let fresh = try TestFixtureFactory.createTemporary(content: postText)
        let freshTotal = try TestFixtureFactory.fetchBlocks(from: fresh).map(\.wordCount).reduce(0, +)
        XCTAssertEqual(rowsTotal, freshTotal, "word total differs from a fresh parse (\(rowsTotal) rows, \(freshTotal) fresh, 4 chapters minus 1)")
    }

    // MARK: - The gate

    func testASecondDeletePressedAtOnceWaitsForTheFirstJobAndIsNeverRefused() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book4)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let chapter4 = try rig.section("Chapter 4")
        let first = await rig.controller.performSectionDelete(rootId: chapter4.id)
        XCTAssertEqual(first, .performed)

        let secondDone = HoldTestFlag()
        let controller = rig.controller
        let second = Task { @MainActor () -> StructuralUndoController.StructuralOpOutcome in
            let outcome = await controller.performSectionDelete(rootId: chapter3.id)
            secondDone.value = true
            return outcome
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(secondDone.value, "the second delete ran before the first job applied")
        let pageWhileWaiting = try await rig.pageText()
        XCTAssertTrue(pageWhileWaiting.contains("# Chapter 3"), "the second delete changed the editor before the first job applied")

        hold.release()
        hold.release()   // the shared job-body hold blocks the second job too
        let outcome = await second.value
        XCTAssertEqual(outcome, .performed, "the second delete was refused")
        await rig.settleEverything()
        let stored = try rig.writerRig.storedText()
        XCTAssertFalse(stored.contains("Chapter 3") || stored.contains("Chapter 4"), "both chapters must be gone from the rows")
        let page = try await rig.pageText()
        XCTAssertFalse(page.contains("Chapter 3") || page.contains("Chapter 4"), "both chapters must be gone from the page")
    }

    // MARK: - DR-1

    func testASecondDeleteThatWaitsLongerThanTheNoticeDelayShowsTheFinishingNoticeAndTakesItDown() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book4)
        rig.shortenProgressDelay(.milliseconds(150))
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let chapter4 = try rig.section("Chapter 4")
        let first = await rig.controller.performSectionDelete(rootId: chapter4.id)
        XCTAssertEqual(first, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the first delete's job is unapplied, so its hold is up")

        // The first click gave the structural gate back, so the second delete is granted it at once and then waits for the hold.
        let controller = rig.controller
        let second = Task { @MainActor in await controller.performSectionDelete(rootId: chapter3.id) }
        let shown = await rig.waitUntil { self.rig.editorState.toastCenter.current?.message == DelayedProgressToast.finishingMessage }
        XCTAssertTrue(shown, "no 'Finishing the last change…' notice while the second delete waited")

        hold.release()
        hold.release()   // the shared job-body hold blocks the second job too
        let outcome = await second.value
        XCTAssertEqual(outcome, .performed, "the second delete was refused")
        await rig.settleEverything()
        XCTAssertNil(rig.editorState.toastCenter.current, "the notice is still showing after the second delete has run")
    }

    // MARK: - F5

    func testTheClicksAdoptCancelsTheDeferredPushTimerThatAHeldBackDerivedPushHadArmed() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book, observesPage: true)
        let coordinator = try XCTUnwrap(rig.coordinator)
        var recomputes = 0
        coordinator.onContentRecompute = { recomputes += 1 }
        // A keystroke just now: a derived push is held back by the settle window and a deferred recompute is armed for 0.6 s later.
        coordinator.lastLocalEditAt = Date()
        XCTAssertFalse(
            coordinator.shouldPushContent("derived text that differs from what the page holds"),
            "premise: the push is held back by the settle window")
        XCTAssertNotNil(coordinator.deferredPushTimer, "premise: a deferred recompute is armed")

        let chapter3 = try rig.section("Chapter 3")
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        try await Task.sleep(for: .milliseconds(900))   // past the timer's 0.6 s

        XCTAssertEqual(recomputes, 0, "a deferred recompute armed before the click fired after it")
        await rig.settleEverything()
    }

    // MARK: - The switch

    func testWithTheSwitchOffTheClickDoesNothing() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        MarkdownEditorFirstSwitch.enabled = false
        let chapter3 = try rig.section("Chapter 3")
        let pageBefore = try await rig.pageText()
        let generation = rig.editorState.editorFirstClickGeneration

        let outcome = await rig.controller.performMarkdownEditorFirstDelete(rootId: chapter3.id)

        XCTAssertNil(outcome, "the click ran with the switch off")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "the click ran with the switch off")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generation, "the click ran with the switch off")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0)
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty)
        let pageAfter = try await rig.pageText()
        XCTAssertEqual(pageAfter, pageBefore, "the page was changed with the switch off")
    }

    func testWithTheSwitchOffPerformSectionDeleteTakesTheOldBody() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)
        MarkdownEditorFirstSwitch.enabled = false
        let chapter3 = try rig.section("Chapter 3")
        let controller = rig.controller

        let outcome = await runWithin(30) { await controller.performSectionDelete(rootId: chapter3.id) }

        XCTAssertNotNil(outcome, "the old body did not finish within 30 s (premise of this test)")
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the click ran with the switch off")
        XCTAssertFalse(try rig.writerRig.storedText().contains("Chapter 3"), "the old body did not delete the section")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0)
    }
}
