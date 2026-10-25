//
//  MarkdownEditorFirstReorderTests+Page.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder in Markdown mode), round 3b, part 2:
//  the tests of what the click and the page do with a plan and a document that do not match perfectly (a heading renamed or typed a
//  moment ago, a Bibliography heading with a fresh id), with the levels a drop changes, and with the word totals. An extension of the
//  class in MarkdownEditorFirstReorderTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the
//  coder: the driver builds and runs every Swift test.
//
//  Break patches are in the driver's folder (scratchpad breaks-3b/index.md). The failure each shows:
//
//   T-R8a  testAHeadingRenamedAMomentAgoIsFlushedAndTheDragStillGoesEditorFirst
//          BREAK: in `sendMarkdownReorderWithRetry` (+MarkdownEditorFirstReorder.swift) never retry.
//          FAILS: "editor-first road not taken after one mismatch".
//   T-R8b  testASecondLeaderMismatchGivesThatPressToTheOldBodyAndReleasesTheHold
//          BREAK: in `runMarkdownEditorFirstReorder` answer `.refused` where the page refused (instead of nil).
//          FAILS: "the second mismatch did not give the press to the old body" (the outcome is .refused).
//   T-R9   testALevelChangingDragWritesTheSameHeadingLevelToTheRowsAndThePage
//          BREAK: in `MarkdownLeaderMap.reorderRequest` send no levels (`level: nil`).   FAILS: "level in page 1 != 2" and "level in rows 1 != 2"
//                 (step 8's flush heals the rows to the page's wrong level 1, so the rows no longer say 2 either).
//   T-R10  testWordTotalsAfterTheDragAndItsCmdZAndCmdShiftZEqualTheOriginalAndAFreshParse   (the web break, a bundle rebuild)
//          BREAK: the moved text loses its last word (api-structural-markdown-reorder.ts).   FAILS: "word total N != M" (N one less than M).
//   T-R14  testANewHeadingTypedJustBeforeADragBelongsToTheSameSectionInThePageAndTheRows
//          BREAK (Swift, the rows' side): `groupBlocksBySections` treats every heading row as a leader.   FAILS: "editor and rows disagree".
//          BREAK (web, the page's side): group by ALL leaders.   FAILS: "editor-first road not taken" (the page answers planMismatch).
//   T-R15  testABibliographyHeadingWithAFreshIdBetweenThePlanAndTheClickStillGoesEditorFirstAndStaysLast   (the web break)
//          BREAK: refuse when an order id has no leader (api-structural-markdown-reorder.ts).   FAILS: "planMismatch".
//

import Foundation
import XCTest
@testable import final_final

extension MarkdownEditorFirstReorderTests {

    // MARK: - T-R8: a heading renamed a moment ago

    // The user renames Bravo's heading ("# Bravo" becomes "# Bravo Two") and drags Charlie at once. The rows still say "# Bravo", so the
    // page's first answer is `leadersMismatch`. The click flushes the typing and asks again ONCE; the second answer is fine and the drag
    // takes the editor-first road with the renamed heading in the page and in the rows.
    func testAHeadingRenamedAMomentAgoIsFlushedAndTheDragStillGoesEditorFirst() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        try await rig.userTypes(" Two", after: "# Bravo")
        XCTAssertEqual(try rig.section("Bravo").markdownFragment, "# Bravo", "premise: the rows do not know the rename yet")

        let drag = try await drop("Charlie", after: "Alpha")

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "editor-first road not taken after one mismatch")
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "editor-first road not taken after one mismatch")
        await rig.settleEverything()
        let wanted = ["# Alpha", "Alpha body.", "# Charlie", "Charlie body.", "# Bravo Two", "Bravo body."]
        let pageLines = try await pageContentLines()
        XCTAssertEqual(pageLines, wanted, "the page is not in the dragged order with the renamed heading")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), wanted, "the rows differ from the page after the settle")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after settle")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the job's pending count was not brought down")
    }

    // A SECOND mismatch (the user changes a heading line again while the click waits for the flush) gives that press to the old body:
    // the outcome is `.performed`, the rows and the page end up in the dragged order with both renames, and the writer's hold is gone.
    // The hold is released BEFORE the old body runs: the old body's own flush of the editor (`writeNow`) waits for the writer's hold, so
    // if the click kept it the press would never finish. The flush's write is parked behind a held system sequence so that the second
    // rename lands between the first call and the retry, deterministically.
    func testASecondLeaderMismatchGivesThatPressToTheOldBodyAndReleasesTheHold() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        try await rig.userTypes(" Two", after: "# Bravo")
        let (plan, request) = try dropRequest("Charlie", after: "Alpha")
        let outOfQueueBefore = rig.editorState.structuralOutOfQueueGeneration
        let ticket = rig.writerRig.hold()
        let controller = rig.controller
        let dragTask = Task { @MainActor in await controller.performSectionReorderDetailed(sections: plan, request: request) }

        // The first call found the mismatch; the click's flush has reserved its write, which waits behind the held system sequence.
        let flushing = await rig.waitUntil { rig.markdownWriter.inFlight != nil }
        XCTAssertTrue(flushing, "premise: the click never reached its mismatch flush")
        try await rig.userTypes(" Three", after: "# Alpha")   // the second change, during the wait
        await rig.writerRig.release(ticket)

        let drag = await dragTask.value
        XCTAssertEqual(drag.outcome, .performed, "the second mismatch did not give the press to the old body: the outcome is \(drag.outcome)")
        XCTAssertFalse(drag.editorFirst, "premise: the second mismatch must not take the editor-first road")
        XCTAssertGreaterThan(
            rig.editorState.structuralOutOfQueueGeneration, outOfQueueBefore, "the old body did not run for the press (it bumps the generation)")
        await rig.settleEverything()
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer's hold is still up after the old body")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the editor-first pending count was not released")
        let wantedHeadings = ["# Alpha Three", "# Charlie", "# Bravo Two"]
        let pageLines = try await pageContentLines()
        XCTAssertEqual(pageLines.filter { $0.hasPrefix("# ") }, wantedHeadings, "the page is not in the dragged order with both renames")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the old body")
    }

    // MARK: - T-R9: a level-changing drop

    // Charlie, level 1, dropped under Alpha as its child at level 2: the row's `headingLevel`, its `#` text and the page's `#` count all
    // say 2. The page rewrites the `#` count from the plan's levels; the job sets the level in the rows from the same plan.
    func testALevelChangingDragWritesTheSameHeadingLevelToTheRowsAndThePage() async throws {
        let rig = try await MarkdownClickRig(
            markdown: "# One\n\nOne body.\n\n# Two\n\nTwo body.\n\n# Three\n\nThree body.", observesPage: true)
        self.rig = rig
        rig.installReparseHost()

        let drag = try await drop("Three", after: "One", level: 2, asChildOf: "One")

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        let pageLines = try await pageContentLines()
        XCTAssertEqual(
            pageLines, ["# One", "One body.", "## Three", "Three body.", "# Two", "Two body."],
            "the page is not in the dragged order with Three at level 2")
        let pageLevel = (pageLines.first { $0.hasSuffix("Three") } ?? "").prefix { $0 == "#" }.count
        let three = try rig.section("Three")
        // The wanted level is the DROP's (2), not "whatever the page says": step 8's flush writes the page's text into the rows after the
        // job, so rows and page would agree on a wrong level; the plan's level reaches the page only through the request.
        XCTAssertEqual(pageLevel, 2, "level in page \(pageLevel) != 2")
        XCTAssertEqual(three.headingLevel ?? 0, 2, "level in rows \(three.headingLevel ?? 0) != 2")
        XCTAssertEqual(three.headingLevel ?? 0, pageLevel, "level in rows \(three.headingLevel ?? 0) != \(pageLevel) in the page")
        XCTAssertEqual(three.markdownFragment, "## Three", "the '#' text in rows is '\(three.markdownFragment)', the page has '## Three'")
        XCTAssertEqual(try rig.section("Two").headingLevel, 1, "Two's level changed")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the settle")
    }

    // MARK: - T-R10: word totals

    /// The word total of the rows, and the word total of a fresh parse of the page's text (what a fresh open shows).
    private func assertWordTotals(expected: Int, context: String) async throws {
        let rowsTotal = try rig.db.fetchBlocks(projectId: rig.pid).map(\.wordCount).reduce(0, +)
        let pageText = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        let fresh = try TestFixtureFactory.createTemporary(content: pageText)
        let freshTotal = try TestFixtureFactory.fetchBlocks(from: fresh).map(\.wordCount).reduce(0, +)
        XCTAssertEqual(rowsTotal, freshTotal, "word total \(rowsTotal) != \(freshTotal) (the rows against a fresh parse of the page) \(context)")
        XCTAssertEqual(freshTotal, expected, "word total \(freshTotal) != \(expected) (a move adds and removes no word) \(context)")
    }

    // The LAST chapter dragged up (the separator case: a range that was last and lacks a trailing newline), then Cmd-Z, then Cmd-Shift-Z:
    // after each, the word total of the rows equals a fresh open of the page's text and equals the original document's total (a move adds
    // and removes no word). A heading glued to the line before it, or text lost in the move, would change one of them.
    func testWordTotalsAfterTheDragAndItsCmdZAndCmdShiftZEqualTheOriginalAndAFreshParse() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true, routesUndo: true)
        self.rig = rig
        rig.installReparseHost()
        let originalTotal = try rig.db.fetchBlocks(projectId: rig.pid).map(\.wordCount).reduce(0, +)
        XCTAssertGreaterThan(originalTotal, 0, "premise: the document has words")

        let drag = try await drop("Chapter 4", after: "Chapter 1")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        try await assertWordTotals(expected: originalTotal, context: "after the drag")

        try await pressAndSettle(
            "undo", until: { Self.headings(in: $0) == ["# Chapter 1", "# Chapter 2", "# Chapter 3", "# Chapter 4"] },
            "Cmd-Z did not put Chapter 4 back")
        try await assertWordTotals(expected: originalTotal, context: "after Cmd-Z")

        try await pressAndSettle(
            "redo", until: { Self.headings(in: $0) == ["# Chapter 1", "# Chapter 4", "# Chapter 2", "# Chapter 3"] },
            "Cmd-Shift-Z did not move Chapter 4 again")
        try await assertWordTotals(expected: originalTotal, context: "after Cmd-Shift-Z")
    }

    // MARK: - T-R14 (M4a): a heading typed a moment ago is not in the sidebar's plan

    // A new "## New heading" line is typed inside Bravo and Charlie is dragged at once: the sidebar's plan does not list the new heading
    // (the re-parse has not run). The page's call finds one leader more than the rows (`leadersMismatch`), the click flushes and asks
    // again, and now the new heading is a leader in the request but not in the plan's order. Both the page and the job group by the ORDER's
    // ids (`groupBlocksBySections(sectionIds:)`), so the heading is body text of the leader above it, Bravo, in both: it travels with Bravo.
    func testANewHeadingTypedJustBeforeADragBelongsToTheSameSectionInThePageAndTheRows() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        try await rig.userTypes("\n\n## New heading\n\nNew body.", after: "Bravo body.")
        XCTAssertNil(rig.editorState.sections.first { $0.title == "New heading" }, "premise: the sidebar does not know the new heading yet")

        let drag = try await drop("Charlie", after: "Alpha")

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "editor-first road not taken: a heading typed a moment ago is not in the sidebar's plan")
        await rig.settleEverything()
        let wanted = ["# Alpha", "Alpha body.", "# Charlie", "Charlie body.", "# Bravo", "Bravo body.", "## New heading", "New body."]
        let pageLines = try await pageContentLines()
        XCTAssertEqual(pageLines, wanted, "the page did not move the new heading with Bravo")
        let rowLines = Self.contentLines(try rig.writerRig.storedText())
        XCTAssertEqual(rowLines, pageLines, "editor and rows disagree about which section the new heading belongs to")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after settle")
    }

    // MARK: - T-R15 (M4b): the Bibliography heading gets a fresh id between the plan and the click

    private static let bibliographyEntries =
        "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
    private static let glueMarker = "<!-- ::auto-bibliography:: -->"

    // The bibliography rebuild deletes every bibliography row and inserts new ones under FRESH ids. If it commits between the sidebar's
    // plan and the click, the plan's last id (the Bibliography heading) matches no row. The page must not call that a `planMismatch`: the
    // id is simply skipped (`skippedIds`), the editor-first road is taken, and the Bibliography stays last, in the page and in the rows
    // (the job resolves the Bibliography from the live rows, not from the plan).
    func testABibliographyHeadingWithAFreshIdBetweenThePlanAndTheClickStillGoesEditorFirstAndStaysLast() async throws {
        let record = "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
            + Self.bibliographyEntries
        let rig = try await MarkdownClickRig(markdown: record, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        try await rig.type(record.replacingOccurrences(of: "# Bibliography", with: Self.glueMarker + "# Bibliography"))
        let managedBefore = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes }.count
        let bibliography = try XCTUnwrap(
            try rig.db.fetchBlocks(projectId: rig.pid).first { $0.isBibliography && $0.blockType == .heading },
            "premise: the rows carry a Bibliography heading")

        let (plan, request) = try dropRequest("Chapter 3", after: "Chapter 1")
        XCTAssertTrue(plan.contains { $0.id == bibliography.id }, "premise: the plan lists the Bibliography heading under its old id")
        let oldId = bibliography.id
        let freshId = "fresh-" + UUID().uuidString
        try rig.db.write { database in
            try database.execute(sql: "UPDATE block SET id = ? WHERE id = ?", arguments: [freshId, oldId])
        }

        let drag = await rig.controller.performSectionReorderDetailed(sections: plan, request: request)

        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "planMismatch: the editor-first road was not taken after the Bibliography heading got a fresh id")
        await rig.settleEverything()
        let page = try await rig.pageText()
        let chapter2 = try XCTUnwrap(page.range(of: "# Chapter 2"), "premise: Chapter 2 is in the page")
        let bibliographyAt = try XCTUnwrap(page.range(of: Self.glueMarker + "# Bibliography"), "the Bibliography heading is gone from the page")
        XCTAssertLessThan(chapter2.lowerBound, bibliographyAt.lowerBound, "the Bibliography is not last in the page")
        XCTAssertTrue(
            page.contains("Smith, J. (2020). A book.") && page.contains("Jones, K. (2021). Another.")
                && page.contains("<!-- ::auto-bibliography-end:: -->"),
            "the Bibliography's entries are not intact in the page")
        let headings = try rig.writerRig.rows().filter { $0.blockType == .heading }.map(\.textContent)
        XCTAssertEqual(
            headings, ["Chapter 1", "Chapter 3", "Chapter 2", "Bibliography"], "the rows are not in the dragged order with the Bibliography last")
        let managedAfter = try rig.db.fetchBlocks(projectId: rig.pid).filter { $0.isBibliography || $0.isNotes }.count
        XCTAssertEqual(managedAfter, managedBefore, "managed rows were lost")
        // The rows hold no row for the bibliography's end marker (`BlockParser` makes ZERO blocks of `<!-- ::auto-bibliography-end:: -->`:
        // it only closes the section and travels with the text), so the page's lines are compared without that one line. It is still
        // required, above, to be in the page, and here to be the page's last line.
        let endMarker = "<!-- ::auto-bibliography-end:: -->"
        let allPageLines = Self.contentLines(MarkdownLeaderMap.recordText(fromRaw: page))
        XCTAssertEqual(allPageLines.last, endMarker, "the bibliography's end marker is not the last line of the page")
        XCTAssertEqual(
            Self.contentLines(try rig.writerRig.storedText()), allPageLines.filter { $0 != endMarker },
            "the rows differ from the page after the settle")
    }
}
