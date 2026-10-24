//
//  MarkdownManagedRegionPusherTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 4, O28/O30: the region-scoped push of the Notes and
//  Bibliography (`MarkdownManagedRegionPusher.pushRebuild`) against the REAL CodeMirror page (EditorTestHelper(editorType: .codemirror):
//  the built web bundle, main.ts's real extension set, the real `window.FinalFinal.markdownReplaceManagedRegion`). The record side of a
//  rebuild (`expectedOld`) and the rows side (`newText`) are made by the real `MarkdownManagedRegions.snapshot`; "what the page holds"
//  is set with `setContent` (the setup); the user's typing that follows is a user-origin transaction (`userTypes`, review C.F6).
//
//  What these tests pin, and the break patch (a 1-5 line change in production code) that must make each fail:
//
//   T-U12  a rebuild whose stamp went stale (a structural job is unapplied) pushes nothing: the deleted section's footnote text does not
//          come back. BREAK: delete `guard stillWanted() else { return .skipped }` in `MarkdownManagedRegionPusher.push`.
//          FAILS with: "deleted section back in editor".
//   T-U25 run 1  typing inside a footnote definition while a Notes rebuild runs: the push is REJECTED (the page's region is not what
//          the rebuild read), nothing is written, a re-push is owed, the typed definition text is kept. BREAK: in `pushRebuild` make
//          `case .stale, .noRegion, .failed:` set `report.wholeTextFallback = true; return report` (the caller then replaces the whole
//          document). FAILS with: "definition text lost".
//   T-U28 (pusher level)  typing in the body between the rebuild's read and its push: the Notes and Bibliography are replaced in place,
//          every typed letter stays, the page's reply is adopted. BREAK: in `pushRebuild` replace the loop body with
//          `report.wholeTextFallback = true; return report`. FAILS with: "typed text missing after rebuild".
//   plus  the first region (the record has none) takes the whole-text path and calls no JavaScript; a region the record has but the
//          page has lost is NEVER overwritten (only the owed re-push); a region the rows no longer have is removed in place.
//          BREAK: in `pushRebuild` change `guard let expectedOld else {` to `guard let expectedOld, false else {`.
//          FAILS with: "the first footnote must take the whole-text path".
//
//   T-U30 (review F1)  the first citation: the editor has no Bibliography region yet, so the rebuild would take the whole-text path;
//          while a Delete's job is unapplied (stale stamp) that path must not run either. The page keeps the delete AND the typing.
//          BREAK: in `pushRebuild`, remove the `guard stillWanted() else { ... }` block in front of `report.wholeTextFallback = true`.
//          FAILS with: "the whole-text path ran on a stale stamp".
//
//  The ContentView wiring (the stamp line, the idle hook, the coordinator drop callback) is thin and is shown by the VM run only.
//
//  Needs `cd web && pnpm build` first (the host tests load the built bundle). XCTest, because WKWebView requires a run loop.
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import XCTest
import WebKit
@testable import final_final

@MainActor
final class MarkdownManagedRegionPusherTests: XCTestCase {

    private var helper: EditorTestHelper!
    private var adopted: [String] = []
    private var evaluations = 0

    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)
        try await helper.loadAndWaitForReady()
        adopted = []
        evaluations = 0
    }

    // MARK: - Documents

    private static let chapters = "# Chapter one\n\nChapter one.[^1]\n\n# Chapter two\n\nChapter two.[^2]\n\n"
    private static let notes = "# Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n"
    private static let bibliography = "# Bibliography\n\nSmith, J. (2020). A book.\n\n"
    private static let endMarker = "<!-- ::auto-bibliography-end:: -->"

    /// The content record: no opening marker (`stripBibliographyMarker`), the end marker kept.
    private static let record = chapters + notes + bibliography + endMarker
    /// What the page holds: the same text with the bibliography opening marker glued to its heading.
    private static let page = chapters + notes + "<!-- ::auto-bibliography:: -->" + bibliography + endMarker

    private func snapshot(_ markdown: String) -> MarkdownRegionSnapshot {
        MarkdownManagedRegions.snapshot(
            markdown: markdown, projectId: "p", notesTitle: nil, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    private func pusher() -> MarkdownManagedRegionPusher {
        let webView = helper.webView
        return MarkdownManagedRegionPusher(
            evaluate: { [weak self] script in
                self?.evaluations += 1
                return (try? await webView.evaluateJavaScript(script)) as? String
            },
            adopt: { [weak self] raw in self?.adopted.append(raw) })
    }

    private func pageText() async throws -> String {
        let answer = try await helper.webView.evaluateJavaScript("window.FinalFinal.getContentRaw()")
        return try XCTUnwrap(answer as? String)
    }

    // MARK: - T-U12

    func testStaleStampPushesNothingAndTheDeletedSectionsFootnoteStaysGone() async throws {
        // The click removed Chapter two and its footnote text from the page; the rows (the job is unapplied) still have both.
        let afterClick = Self.page
            .replacingOccurrences(of: "# Chapter two\n\nChapter two.[^2]\n\n", with: "")
            .replacingOccurrences(of: "\n\n[^2]: Note two.", with: "")
        try await helper.setContent(afterClick)
        let read = snapshot(afterClick.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: ""))
        let fresh = snapshot(Self.record)
        XCTAssertNotNil(read.notes, "premise: the record has a Notes region")
        XCTAssertNotEqual(read.notes, fresh.notes, "premise: the rows' Notes differ from the editor's")

        let state = EditorViewState()
        state.pendingEditorFirstJobs = 1                 // the click's job is unapplied ...
        let stamp = state.stampRebuildRead()             // ... when the rebuild reads the rows
        let report = await pusher().pushRebuild(
            regions: [.notes], read: read, fresh: fresh, stillWanted: { state.rebuildPushStillWanted(stamp) })

        XCTAssertTrue(report.staleSkipped, "the stale stamp was not honoured")
        let after = try await pageText()
        XCTAssertEqual(after, afterClick, "deleted section back in editor")
        XCTAssertFalse(after.contains("Note two."), "deleted section back in editor")
        XCTAssertTrue(adopted.isEmpty, "nothing was pushed, so nothing is adopted")

        // Control: with a current stamp the very same push does go in, which is what the guard keeps out.
        let control = await pusher().pushRebuild(regions: [.notes], read: read, fresh: fresh, stillWanted: { true })
        XCTAssertEqual(control, MarkdownManagedRegionPusher.RebuildReport())
        let pushed = try await pageText()
        XCTAssertTrue(pushed.contains("[^2]: Note two."), "control: without the guard the stale Notes text is pushed")
    }

    // MARK: - T-U30 (review F1)

    func testAFirstCitationRebuildOnAStaleStampDoesNotTakeTheWholeTextPathOverAnUnappliedDelete() async throws {
        // The record and the rows both still have Chapter two (the Delete's job is unapplied); the page lost it to the click, and the
        // user has typed in Chapter one since. The document has no Bibliography yet: the rebuild's fresh text is the first to have one.
        let recordText = "# Chapter one\n\nChapter one.\n\n# Chapter two\n\nChapter two.\n\n"
        let rowsText = recordText + "# Bibliography\n\nSmith, J. (2020). A book.\n\n<!-- ::auto-bibliography-end:: -->"
        let afterClickAndTyping = "# Chapter one\n\nChapter one. kp5 typed after the delete\n\n"
        try await helper.setContent(afterClickAndTyping)
        let read = snapshot(recordText)
        let fresh = snapshot(rowsText)
        XCTAssertNil(read.bibliography, "premise: the editor has no Bibliography region yet")
        XCTAssertNotNil(fresh.bibliography, "premise: the rows have one")

        let state = EditorViewState()
        state.pendingEditorFirstJobs = 1                 // the click's job is unapplied ...
        let stamp = state.stampRebuildRead()             // ... when the rebuild reads the rows
        let report = await pusher().pushRebuild(
            regions: [.bibliography], read: read, fresh: fresh, stillWanted: { state.rebuildPushStillWanted(stamp) })
        if report.wholeTextFallback {
            // What the caller (`pushRebuildToMarkdownEditor`) does with that report: the rows' whole text replaces the page's.
            try await helper.setContent(rowsText)
        }

        XCTAssertFalse(report.wholeTextFallback, "the whole-text path ran on a stale stamp")
        XCTAssertTrue(report.staleSkipped, "the caller must be told to raise the re-push (noteStalePushSkipped)")
        XCTAssertEqual(evaluations, 0, "nothing is sent to the page")
        let after = try await pageText()
        XCTAssertEqual(after, afterClickAndTyping, "the page lost the delete or the typing")
        XCTAssertFalse(after.contains("Chapter two."), "the deleted section came back")
        XCTAssertTrue(after.contains("kp5 typed after the delete"), "typing made since the click was lost")

        // Control: with a current stamp the same rebuild takes the whole-text path (the first citation still gets its Bibliography).
        let control = await pusher().pushRebuild(regions: [.bibliography], read: read, fresh: fresh, stillWanted: { true })
        XCTAssertTrue(control.wholeTextFallback, "control: a current stamp keeps the first-region path")
        XCTAssertFalse(control.staleSkipped)
    }

    // MARK: - T-U25 run 1

    func testTypingInsideAFootnoteDefinitionDuringANotesRebuildRejectsThePushAndKeepsTheText() async throws {
        try await helper.setContent(Self.page)
        let read = snapshot(Self.record)
        // The rows' Notes now carry a third footnote (what the rebuild read).
        let fresh = snapshot(Self.record.replacingOccurrences(
            of: "[^2]: Note two.\n\n", with: "[^2]: Note two.\n\n[^3]: Note three.\n\n"))
        XCTAssertNotEqual(read.notes, fresh.notes, "premise: the rebuild has something to push")
        // The user types inside definition 1 while the rebuild runs; the content record never sees it.
        try await helper.userTypes(", TYPED", after: "[^1]: Note one")

        let report = await pusher().pushRebuild(regions: [.notes], read: read, fresh: fresh, stillWanted: { true })

        XCTAssertTrue(report.repushOwed, "a rejected push must owe a re-push")
        if report.wholeTextFallback {
            // What the caller does with that report: the rows' whole text replaces the page's.
            try await helper.setContent(Self.page.replacingOccurrences(of: "[^2]: Note two.", with: "[^2]: Note two.\n\n[^3]: Note three."))
        }
        let after = try await pageText()
        XCTAssertTrue(after.contains("[^1]: Note one, TYPED."), "definition text lost")
        XCTAssertFalse(after.contains("[^3]: Note three."), "the rejected push wrote anyway")
        XCTAssertTrue(adopted.isEmpty, "a rejected push adopts nothing")
    }

    // MARK: - T-U28 (pusher level)

    func testBodyTypingBetweenTheReadAndThePushStaysWhileNotesAndBibliographyAreReplacedInPlace() async throws {
        try await helper.setContent(Self.page)
        let read = snapshot(Self.record)
        let freshText = Self.record
            .replacingOccurrences(of: "Note one.", with: "Note one, revised.")
            .replacingOccurrences(of: "Smith, J. (2020). A book.", with: "Smith, J. (2020). A book.\n\nJones, K. (2021). Another.")
        let fresh = snapshot(freshText)
        XCTAssertNotNil(fresh.bibliography, "premise: the rows have a bibliography region")
        // The user keeps typing in the body after the rebuild read the rows.
        try await helper.userTypes(" kp4 and more typing", after: "Chapter one.[^1]")

        let report = await pusher().pushRebuild(regions: [.notes, .bibliography], read: read, fresh: fresh, stillWanted: { true })
        if report.wholeTextFallback {
            try await helper.setContent(freshText)   // what the old whole-text path does with the rows' text
        }

        let after = try await pageText()
        XCTAssertEqual(report, MarkdownManagedRegionPusher.RebuildReport(), "both regions are pushed with nothing owed")
        XCTAssertTrue(after.contains("Chapter one.[^1] kp4 and more typing"), "typed text missing after rebuild")
        XCTAssertTrue(after.contains("[^1]: Note one, revised."), "the Notes region was not replaced")
        XCTAssertTrue(after.contains("Jones, K. (2021). Another."), "the Bibliography region was not replaced")
        XCTAssertTrue(after.contains("<!-- ::auto-bibliography:: -->"), "the bibliography's own frame is kept")
        XCTAssertEqual(adopted.count, 2, "the page's reply is adopted after each region push (O30)")
        XCTAssertEqual(adopted.last, after, "the record takes the page's own text, never the rows' (O30)")
    }

    // MARK: - The other decisions

    func testTheFirstRegionTakesTheWholeTextPathAndCallsNoJavaScript() async throws {
        try await helper.setContent("# Chapter one\n\nChapter one.\n\n")
        let read = snapshot("# Chapter one\n\nChapter one.\n\n")
        XCTAssertNil(read.notes, "premise: the record has no Notes region")
        let fresh = snapshot("# Chapter one\n\nChapter one.[^1]\n\n# Notes\n\n[^1]: Note one.")
        XCTAssertNotNil(fresh.notes, "premise: the rows have one")

        let report = await pusher().pushRebuild(regions: [.notes], read: read, fresh: fresh, stillWanted: { true })

        XCTAssertTrue(report.wholeTextFallback, "the first footnote must take the whole-text path")
        XCTAssertEqual(evaluations, 0, "no JavaScript runs for a region the record does not have")
    }

    func testARegionTheRecordHasButThePageHasLostIsNeverOverwritten() async throws {
        let read = snapshot(Self.record)
        let fresh = snapshot(Self.record.replacingOccurrences(of: "Note one.", with: "Note one, revised."))
        // The user deleted the Notes heading and its definitions from the page; the record has not heard of it.
        let withoutNotes = Self.page.replacingOccurrences(of: Self.notes, with: "")
        try await helper.setContent(withoutNotes)

        let report = await pusher().pushRebuild(regions: [.notes], read: read, fresh: fresh, stillWanted: { true })

        XCTAssertFalse(report.wholeTextFallback, "a missing region must not be re-created by replacing the whole document")
        XCTAssertTrue(report.repushOwed)
        let after = try await pageText()
        XCTAssertEqual(after, withoutNotes)
    }

    func testARegionTheRowsNoLongerHaveIsRemovedInPlace() async throws {
        try await helper.setContent(Self.page)
        let read = snapshot(Self.record)
        let fresh = snapshot(Self.chapters + Self.bibliography + Self.endMarker)
        XCTAssertNil(fresh.notes, "premise: the rows have no Notes any more")

        let report = await pusher().pushRebuild(regions: [.notes], read: read, fresh: fresh, stillWanted: { true })

        XCTAssertEqual(report, MarkdownManagedRegionPusher.RebuildReport())
        let after = try await pageText()
        XCTAssertFalse(after.contains("# Notes"), "the Notes region was not removed")
        XCTAssertTrue(after.contains("# Chapter two"), "the body stays")
        XCTAssertTrue(after.contains("Smith, J. (2020). A book."), "the bibliography stays")
    }
}
