//
//  MarkdownEditorFirstRestoreTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 4, round C2: the three Version History restores in Markdown
//  mode (Restore Entire Project, Replace Current Section, Insert as New Section) as editor-first commands
//  (`StructuralUndoController.performMarkdownEditorFirstRestore`, StructuralUndoController+MarkdownEditorFirstRestore.swift) against the
//  REAL CodeMirror page, a real database and the real writer (`MarkdownClickRig`). This file holds the page-and-rows tests of the click;
//  Cmd-Z / Cmd-Shift-Z are in +Undo, the old body taken and the failed job in +Failure, typing around the click and the hold in
//  +Typing, the helpers in +Support. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  EVERY wait on a command, a job, a hold or a settle in these files is BOUNDED (`bounded`, `finish`, `settleAll` ...): a bug shows as a
//  red "stuck for N s: ..." test, not as a stuck run. A job-body hold (`holdJobs`, `holdReinserts`) is a semaphore, one `release()` per
//  job that reaches it; the tearDown frees whatever a test left.
//
//  THE TESTS AND THE PATCH EACH MUST FAIL UNDER (plan-v1-addendum section 11; the patch files are written in a later round). Every test
//  also fails on the base commit, where the symbols it needs do not exist ("does not compile / missing symbol").
//
//   U1   testWholeRestorePageTextIsTheRebuildsTextFromTheRowsAfterTheJob      (and ...Section..., ...InsertAfter..., ...Bibliography...)
//        BREAK (swift-U1.patch, all four): `injectSectionAnchors(... sections: [])`, no markers.   FAILS: "page != rebuild"
//        BREAK (swift-U1b.patch, the Bibliography test only): drop the `!isBibliography` filter in `markdownPageText`.
//        FAILS: "page != rebuild" (a marker in front of the bibliography)
//   U2   testTypingWhileTheRestoreJobIsHeldIsKeptAndSaved
//        BREAK (swift-U2.patch): in `markdownRestoreReplyTurn` replace `startMarkdownHoldContinuation(...)` with `hold.release(); gate.finish()`.
//        FAILS (shown by the driver's run): "premise: the job is held, so the hold is up", because the patch has already let the hold go
//        at the click. It does NOT fail through "typing saved while the job was held": the writer still orders the typing write behind
//        the held job, so that check alone would stay green under this patch.
//   U3   testTypingJustBeforeTheClickIsSavedFirstAndIsInTheAutomaticVersion
//        BREAK: delete the `writer.prepareStructuralClick(...)` call.   FAILS: "typing lost: zq7 not in the rows before the job ran"
//   U4   testTheOutlineCardTargetIsExactWhileTheJobIsHeldAndAfter...   (Replace and Insert as New)
//        BREAK: the request sends `plan.markdown` instead of `markdownPageText`.   FAILS: "card target is not the heading's marker"
//

import Foundation
import XCTest
@testable import final_final

@MainActor
final class MarkdownEditorFirstRestoreTests: XCTestCase {

    var rig: MarkdownClickRig!
    var alwaysLog: RestoreAlwaysLog?

    /// Every job-body hold this test made (`holdJobs`, `holdReinserts`); the tearDown signals each one generously so a bug shows as a red
    /// test and not as a stuck run.
    var heldJobs: [MarkdownClickRig.JobHold] = []

    /// `ZoteroService.shared.isConnected` as it was before a test pinned it to false (`keepTheBibliographyAwayFromZotero`); put back in
    /// the tearDown. The service is a process-wide singleton.
    var priorZoteroConnected: Bool?

    override func setUp() async throws {
        try await super.setUp()
        executionTimeAllowance = 120   // honoured when the run enables test timeouts; the bounded waits do not depend on it
    }

    override func tearDown() async throws {
        for hold in heldJobs { for _ in 0..<8 { hold.release() } }
        heldJobs = []
        alwaysLog?.stop()
        alwaysLog = nil
        if let priorZoteroConnected { ZoteroService.shared.isConnected = priorZoteroConnected }
        priorZoteroConnected = nil
        if let rig {
            rig.controller.testEFJobBodyHold = nil
            rig.controller.testReinsertBodyHold = nil
            rig.controller.testEFSettleHold = nil
            rig.controller.testOrderingSpy = nil
            rig.controller.testBeforeMarkdownPagePrepare = nil
            // The undo-point copies the restore jobs write are pinned in a process-wide set.
            let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
            for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) }
            rig.restore()
        }
        rig = nil
        try await super.tearDown()
    }

    // MARK: - U1: the page text is the rebuild's text

    /// Saves a version, changes the document after it (typing the rows then hold), puts the page in the state the app has it in (every
    /// heading carries its marker), presses the restore, lets everything settle. Returns the page and the text the rebuild's recipe makes
    /// from the rows NOW.
    private func restoreAndReadBothTexts(
        _ document: String, editAfter marker: String, replacesTheEditedText: Bool = true, keepsBibliographyAwayFromZotero: Bool = false,
        press: (Snapshot) async throws -> StructuralUndoController.StructuralOpOutcome
    ) async throws -> (page: String, rebuilt: String) {
        try await startRig(document)
        if keepsBibliographyAwayFromZotero { keepTheBibliographyAwayFromZotero() }
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: marker)
        try await putTheAppsMarkersOnThePage()
        let before = try await pageText()
        let outcome = try await press(version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        let page = try await pageText()
        XCTAssertNotEqual(page, before, "premise: the restore changed the page")
        if replacesTheEditedText {
            XCTAssertFalse(page.contains("EDITED"), "premise: the typing made after the version went with the restored text")
        }   // an Insert as New Section replaces nothing: the edited chapter stays, the version's section is added
        return (page, try rebuildRecipeText())
    }

    // CLAIM (Restore Entire Project): the page text the click put on the page (the page is the whole restored document) is the text the
    // rebuild makes from the rows AFTER the job settled: markers in front of every heading, byte for byte.
    func testWholeRestorePageTextIsTheRebuildsTextFromTheRowsAfterTheJob() async throws {
        let (page, rebuilt) = try await restoreAndReadBothTexts(Self.book, editAfter: "Second chapter text.") { version in
            try await self.restoreProject(from: version)
        }
        XCTAssertEqual(page, rebuilt, "page != rebuild (the page text the click sent is not the text the rebuild makes from the rows)")
        XCTAssertEqual(markers(in: page).count, 4, "wanted a marker in front of each of the four chapters")
    }

    // CLAIM (Replace Current Section): only the section changes on the page, and the whole page is the rebuild's text afterwards.
    func testSectionRestorePageTextIsTheRebuildsTextFromTheRowsAfterTheJob() async throws {
        let (page, rebuilt) = try await restoreAndReadBothTexts(Self.book, editAfter: "Second chapter text.") { version in
            try await self.replaceSection("Chapter 2", from: version)
        }
        XCTAssertEqual(page, rebuilt, "page != rebuild (the page text the click sent is not the text the rebuild makes from the rows)")
        XCTAssertEqual(markers(in: page).count, 4, "wanted a marker in front of each of the four chapters")
    }

    // CLAIM (Insert as New Section): the inserted section's marker names the id its heading row will get; the whole page is the rebuild's
    // text afterwards (the new section is last, after Chapter 4).
    func testInsertAfterRestorePageTextIsTheRebuildsTextFromTheRowsAfterTheJob() async throws {
        let (page, rebuilt) = try await restoreAndReadBothTexts(
            Self.book, editAfter: "Second chapter text.", replacesTheEditedText: false
        ) { version in
            try await self.insertAsNewSection("Chapter 2", from: version)
        }
        XCTAssertEqual(page, rebuilt, "page != rebuild (the page text the click sent is not the text the rebuild makes from the rows)")
        XCTAssertEqual(markerIds(in: page, headingTitled: "Chapter 2").count, 2, "wanted a marker in front of both Chapter 2 headings")
    }

    // CLAIM (Restore Entire Project of a version with Notes and a Bibliography): the page is the rebuild's text, the bibliography's opening
    // marker is on the page exactly once, the bibliography heading carries NO section marker (the rebuild marks `!isBibliography` only),
    // and the Notes rows are the version's.
    func testWholeRestoreOfAVersionWithABibliographyHasTheOpeningMarkerOnceAndNoSectionMarkerOnIt() async throws {
        let (page, rebuilt) = try await restoreAndReadBothTexts(
            Self.bibliographyBook, editAfter: "Second chapter text.", keepsBibliographyAwayFromZotero: true
        ) { version in
            try await self.restoreProject(from: version)
        }
        XCTAssertEqual(page, rebuilt, "page != rebuild (the page text the click sent is not the text the rebuild makes from the rows)")
        XCTAssertEqual(
            page.components(separatedBy: Self.openingBibliographyMarker).count - 1, 1,
            "the bibliography's opening marker is not on the page exactly once")
        XCTAssertEqual(page.components(separatedBy: "<!-- ::auto-bibliography-end:: -->").count - 1, 1, "the end marker is not there once")
        XCTAssertTrue(
            page.contains(Self.openingBibliographyMarker + "# Bibliography"), "the opening marker is not glued to the Bibliography heading")
        XCTAssertTrue(markerIds(in: page, headingTitled: "Bibliography").isEmpty, "the Bibliography heading got a section marker")
    }

    // MARK: - U2: the hold comes down when the job ends

    // CLAIM: typing made while the Replace's job is held is kept on the page, is NOT saved while the job is held (the writer is held), and
    // is saved after the release (step 8 behind the job): the typed text is in the rows once, and the rows of the other chapters did
    // not change.
    //
    // WHAT FAILS UNDER ITS PATCH (swift-U2.patch, `hold.release(); gate.finish()` at the click, shown by the driver's run): the PREMISE
    // below, "the job is held, so the hold is up" (the hold is already down), not the "typing saved while the job was held" check, which
    // alone would stay green because the writer orders the typing write behind the held job. So the test pins "the hold stays up while the
    // job is held" through that premise, and the typing checks after it pin the save after the release.
    func testTypingWhileTheRestoreJobIsHeldIsKeptAndSaved() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let originalIds = Set(try rig.writerRig.rows().map(\.id))
        let hold = holdJobs()

        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the job is held, so the hold is up")

        // The user types in the restored text and in another chapter.
        try await userTypes(" tx1", after: "Second chapter text.")
        try await userTypes(" tx2", after: "Fourth chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("tx1") && self.rig.editorState.content.contains("tx2") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        // The debounced re-parse comes due during the hold: it must reserve nothing.
        _ = rig.writerRig.schedule(rig.editorState.content)
        try await finishReparse()
        let storedWhileHeld = try rig.writerRig.storedText()
        XCTAssertFalse(storedWhileHeld.contains("tx1") || storedWhileHeld.contains("tx2"), "typing saved while the job was held")
        let pageWhileHeld = try await pageText()
        XCTAssertTrue(pageWhileHeld.contains("tx1") && pageWhileHeld.contains("tx2"), "typing was overwritten on the page while the job was held")

        hold.release()
        try await settleAll()
        try await finishReparse()
        try await settleWriter()
        let page = try await pageText()
        let stored = try rig.writerRig.storedText()
        for typed in ["tx1", "tx2"] {
            XCTAssertTrue(page.contains(typed), "\(typed) is not on the page after the release")
            XCTAssertEqual(stored.components(separatedBy: typed).count - 1, 1, "\(typed) must be in the rows exactly once")
        }
        XCTAssertFalse(stored.contains("EDITED"), "the typing made before the version's restore is still in the rows")
        let chapter1 = try headingRows("Chapter 1")
        XCTAssertTrue(originalIds.contains(chapter1.first?.id ?? ""), "Chapter 1's heading row got another id")
        try await assertRowsMatchPage("after the typing in the restored text was saved")
        assertQuiet("after the release")
    }

    // MARK: - U3: typing just before the click is saved first

    // CLAIM: typing made just before the click (the content record lags the page, nothing saved it) is saved WITH the click, before the
    // job: it is in the rows while the job is still held, and the automatic version the job writes holds it. The typing is in a chapter
    // the restore does not touch.
    func testTypingJustBeforeTheClickIsSavedFirstAndIsInTheAutomaticVersion() async throws {
        rig = try await MarkdownClickRig(markdown: Self.book)   // the record does not follow the page
        let version = try await saveVersion()
        let hold = holdJobs()
        try await userTypes(" zq7", after: "Third chapter text.")
        XCTAssertEqual(rig.editorState.content, Self.book, "premise: the content record lags the page (nothing reported the typing)")

        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        // The job is held: step 8's flush cannot have saved anything yet, so only the click's own typing batch can have put zq7 there.
        let batchSaved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("Third chapter text. zq7")) == true }
        XCTAssertTrue(batchSaved, "typing lost: zq7 not in the rows before the job ran")

        hold.release()
        try await settleAll()
        XCTAssertTrue(try rig.writerRig.storedText().contains("Third chapter text. zq7"), "typing lost: zq7 not in the rows")
        let automatic = try automaticVersions()
        XCTAssertEqual(automatic.count, 1, "wanted exactly one automatic version (the restore job's)")
        XCTAssertTrue(
            automatic.first?.previewMarkdown.contains("Third chapter text. zq7") == true,
            "typing lost: zq7 is not in the automatic version the job wrote (it was saved after the job's snapshot)")
        let page = try await pageText()
        XCTAssertTrue(page.contains("Third chapter text. zq7"), "the typing is gone from the page")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork)
    }

    // MARK: - U4: the Outline card target is exact

    /// The sidebar card titled `title` whose id is NOT one of `knownIds`, once it shows.
    private func newCard(_ title: String, notIn knownIds: Set<String>) async -> SectionViewModel? {
        _ = await rig.waitUntil { self.rig.editorState.sections.contains { $0.title == title && !knownIds.contains($0.id) } }
        return rig.editorState.sections.first { $0.title == title && !knownIds.contains($0.id) }
    }

    /// The card target (`ContentView.markdownScrollTarget`) of `cardId` is where that id's marker stands in `sourceContent`, and the
    /// heading line follows the marker at once.
    private func assertCardTargetIsTheMarker(
        _ cardId: String, title: String, _ phase: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let page = try await pageText()
        let source = rig.editorState.sourceContent
        XCTAssertEqual(source, page, "\(phase): premise: the record holds the page's text (the click adopted it)", file: file, line: line)
        let marker = "<!-- @sid:\(cardId) -->"
        let markerAt = (page as NSString).range(of: marker)
        XCTAssertNotEqual(markerAt.location, NSNotFound, "\(phase): premise: the page has the card's marker", file: file, line: line)
        let target = ContentView.markdownScrollTarget(forSectionId: cardId, sourceContent: source, rowsOffset: { nil })
        XCTAssertEqual(target, markerAt.location, "\(phase): card target is not the heading's marker", file: file, line: line)
        let afterMarker = (page as NSString).substring(from: markerAt.location + markerAt.length)
        XCTAssertTrue(afterMarker.hasPrefix("# \(title)"), "\(phase): the heading does not follow the marker", file: file, line: line)
    }

    // CLAIM (Replace Current Section): the replaced section's card lands on its heading's marker while the job is held and after it ran.
    // The page text carries the marker the card lookup needs; the target's id is unchanged.
    func testTheOutlineCardTargetIsExactAfterAReplaceWhileTheJobIsHeldAndAfter() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        try await putTheAppsMarkersOnThePage()
        let chapter2 = try rig.section("Chapter 2")
        let hold = holdJobs()

        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        try await assertCardTargetIsTheMarker(chapter2.id, title: "Chapter 2", "job held")
        XCTAssertTrue(rig.editorState.sections.contains { $0.id == chapter2.id && $0.title == "Chapter 2" }, "the sidebar lost the card")

        hold.release()
        try await settleAll()
        try await refreshSidebar()
        try await assertCardTargetIsTheMarker(chapter2.id, title: "Chapter 2", "after the job")
        XCTAssertEqual(try headingRows("Chapter 2").map(\.id), [chapter2.id], "the replaced heading got another id")
    }

    // CLAIM (Insert as New Section): the NEW section's card (the one whose id is not an original id) lands on the new heading's marker,
    // not on the original Chapter 2's, while the job is held and after it ran; the card's id is the heading row's id once the rows exist.
    func testTheOutlineCardTargetIsExactAfterAnInsertAsNewWhileTheJobIsHeldAndAfter() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await putTheAppsMarkersOnThePage()
        let original = try rig.section("Chapter 2")
        let knownIds = Set(try rig.writerRig.rows().filter { $0.blockType == .heading }.map(\.id))
        let hold = holdJobs()

        let outcome = try await insertAsNewSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        let heldCardOrNil = await newCard("Chapter 2", notIn: knownIds)
        let heldCard = try XCTUnwrap(heldCardOrNil, "job held: the inserted section has no sidebar card")
        XCTAssertNotEqual(heldCard.id, original.id, "job held: the new card has the original's id")
        try await assertCardTargetIsTheMarker(heldCard.id, title: "Chapter 2", "job held")
        XCTAssertTrue(try headingRows("Chapter 2").count == 1, "premise: the rows have no inserted heading yet")

        hold.release()
        try await settleAll()
        try await refreshSidebar()
        let rows = try headingRows("Chapter 2")
        XCTAssertEqual(rows.count, 2, "the inserted section is not in the rows")
        XCTAssertEqual(rows.last?.id, heldCard.id, "the card's id is not the new heading row's id after the job")
        let afterCardOrNil = await newCard("Chapter 2", notIn: knownIds)
        let afterCard = try XCTUnwrap(afterCardOrNil, "after the job: the inserted section lost its card")
        try await assertCardTargetIsTheMarker(afterCard.id, title: "Chapter 2", "after the job")
    }
}
