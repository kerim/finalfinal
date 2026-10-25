//
//  MarkdownEditorFirstReorderTests+Review.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the sidebar drag-reorder in Markdown mode), review round
//  (judge-review1-brief.md, findings R1 to R10 and V1): the tests of what the reviewers found. An extension of the class in
//  MarkdownEditorFirstReorderTests.swift. Real page, real rows, real writer. Needs `cd web && pnpm build` first.
//
//  Break patches are in the driver's folder (scratchpad breaks-3d/index.md). The failure each shows:
//
//   R2   testTheSidebarOverlayIsShownBeforeTheWritersLastWriteHasFinished
//        BREAK: in `markdownReorderReplyTurn` move the `showReorderInSidebar` call back below the `while let pending = writer.inFlight` loop.
//        FAILS: "sidebar overlay not shown while the writer's write is in flight".
//   R1   testACardClickWhileAReorderJobIsPendingScrollsToThePagesOffsetNotTheRows (+ MarkdownScrollTargetTests below)
//        BREAK: in `markdownScrollTarget` ask the rows first (`rowsOffset() ?? markdownScrollOffset(...)`).
//        FAILS: "scrolled to the row offset, not the page offset".
//   R6   testAMarkdownDeleteSentToTheOldBodyByASecondMismatchKeepsTheSecondRename
//        BREAK: remove `await adoptPageTextForTheOldBody(editorState)` from the Delete click's nil exit.
//        FAILS: "page lacks the second rename".
//   R10  testTheClickGivesTheOldBodyThePressWhenTheProjectIsZoomedWhileItWaits
//        BREAK: remove `, editorState.zoomedSectionId == nil` from the click's step-3 guard.
//        FAILS: "the click went on after the project was zoomed".
//   V1   testTheSettleFlagCarriesTheNotesHeadingLineFromTheRows
//        BREAK: in `markMarkdownSettle` send `"null"` as the heading literal.   FAILS: "Notes heading line not sent with the settle flag".
//   R3   testTwoDragsInARowThenCmdZTwiceRestoreTheOriginalOrder   (break IDEA, not proven: remove `await writer.awaitStructuralHoldReleased()`
//        in the reorder click's step 2: the second click would run beside the first job.)
//   R4   testChaptersWithRealDocumentShapesMoveAsTheRowsAssembleThem   (a finding probe; see the test)
//

import Foundation
import XCTest
@testable import final_final

/// A page whose anchors are in the text: `<!-- @sid:ID --># Title` on each heading line, as the Markdown editor's text has them.
private func anchoredText(_ markdown: String, ids: [String: String]) -> String {
    var text = markdown
    for (title, id) in ids {
        text = text.replacingOccurrences(of: "# \(title)\n", with: "<!-- @sid:\(id) --># \(title)\n")
    }
    return text
}

// MARK: - R1: the scroll target (pure)

@MainActor
final class MarkdownScrollTargetTests: XCTestCase {

    private let text = "😀 intro\n\n<!-- @sid:AAA --># One\n\nbody\n\n<!-- @sid:BBB --># Two"

    func testThePageOffsetWinsOverTheRowsAndIsCountedInUTF16() {
        let anchorRange = text.range(of: "<!-- @sid:BBB -->")
        let before = anchorRange.map { text[..<$0.lowerBound] } ?? ""
        XCTAssertNotEqual(before.utf16.count, before.count, "premise: the emoji makes UTF-16 units and Characters differ")

        let target = ContentView.markdownScrollTarget(forSectionId: "BBB", sourceContent: text, rowsOffset: { 9_999 })

        XCTAssertNotEqual(target, 9_999, "scrolled to the row offset, not the page offset")
        XCTAssertEqual(target, before.utf16.count, "the offset counts Characters, not UTF-16 units (CodeMirror positions are UTF-16)")
    }

    func testATextWithoutTheAnchorFallsBackToTheRowsOffset() {
        XCTAssertEqual(
            ContentView.markdownScrollTarget(forSectionId: "ZZZ", sourceContent: text, rowsOffset: { 42 }), 42,
            "no anchor in the page: the rows' offset is the fallback")
        XCTAssertNil(
            ContentView.markdownScrollTarget(forSectionId: "ZZZ", sourceContent: text, rowsOffset: { nil }), "nothing to scroll to")
    }
}

extension MarkdownEditorFirstReorderTests {

    // MARK: - R2: the overlay does not wait for the writer

    // Typing is handed to the writer, whose write is parked behind a held system sequence (a book-length typing batch, or the previous
    // command's flush, in the app). The user drops a card: the page has moved at once, so the sidebar must show the new order at once too,
    // not after the writer's write has ended. Floor 3 (standard actions feel instant).
    func testTheSidebarOverlayIsShownBeforeTheWritersLastWriteHasFinished() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let raw = try await rig.userTypes(" kk", after: "Bravo body.")
        let ticket = rig.writerRig.hold()   // every writer sequence reserved from here on waits behind it
        let disposition = rig.writerRig.fire(MarkdownLeaderMap.recordText(fromRaw: raw))
        XCTAssertEqual(disposition, .started, "premise: the typing was handed to the writer")
        XCTAssertNotNil(rig.markdownWriter.inFlight, "premise: the writer's write is in flight")
        let (plan, request) = try dropRequest("Charlie", after: "Alpha")
        let controller = rig.controller
        let dragTask = Task { @MainActor in await controller.performSectionReorderDetailed(sections: plan, request: request) }

        let shown = await rig.waitUntil { rig.editorState.pendingReorder != nil }
        XCTAssertTrue(shown, "sidebar overlay not shown while the writer's write is in flight")
        XCTAssertNotNil(rig.markdownWriter.inFlight, "premise: the writer's write is still in flight when the overlay is looked at")
        XCTAssertEqual(
            rig.editorState.sections.map(\.title), ["Alpha", "Charlie", "Bravo"],
            "the sidebar still shows the old order while the write is in flight")

        await rig.writerRig.release(ticket)
        let drag = await dragTask.value
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()
        let pageLines = try await pageContentLines()
        XCTAssertEqual(
            pageLines, ["# Alpha", "Alpha body.", "# Charlie", "Charlie body.", "# Bravo", "Bravo body. kk"], "the page is not in the dragged order")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the settle")
        XCTAssertNil(rig.editorState.pendingReorder, "the sidebar overlay was not lifted by the settle")
    }

    // MARK: - R1: a card click while the job is pending

    // Reorder job HELD (the rows are still in the old order, the page is in the new one): the scroll target of Charlie's card is its place
    // in the PAGE text the click adopted (`sourceContent`), not the place the rows' arithmetic gives.
    func testACardClickWhileAReorderJobIsPendingScrollsToThePagesOffsetNotTheRows() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let titles = ["Alpha", "Bravo", "Charlie"]
        let ids = Dictionary(uniqueKeysWithValues: try titles.map { ($0, try rig.section($0).id) })
        let anchored = anchoredText(Self.book3, ids: ids)
        XCTAssertNotEqual(anchored, Self.book3, "premise: the anchors are in the text")
        try await rig.type(anchored)
        let hold = rig.holdNextJob()
        defer { hold.release() }

        let drag = try await drop("Charlie", after: "Alpha")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        let source = rig.editorState.sourceContent
        let charlie = try XCTUnwrap(ids["Charlie"])
        let marker = "<!-- @sid:\(charlie) -->"
        let inPage = try XCTUnwrap(source.range(of: marker), "premise: the page text the click adopted holds Charlie's anchor")
        let pageOffset = source.utf16.distance(from: source.startIndex, to: inPage.lowerBound)
        // What the rows say while the job is unapplied: Charlie still after Bravo, as in the text before the drag.
        let rowsOffset = (anchored as NSString).range(of: marker).location
        XCTAssertNotEqual(pageOffset, rowsOffset, "premise: the drag moved Charlie, so the page and the rows disagree about its place")

        let target = ContentView.markdownScrollTarget(forSectionId: charlie, sourceContent: source, rowsOffset: { rowsOffset })

        XCTAssertNotEqual(target, rowsOffset, "scrolled to the row offset, not the page offset")
        XCTAssertEqual(target, pageOffset, "the scroll target is not Charlie's place in the page")
    }

    // MARK: - R6: the Delete's old-body exit (slice 1 code)

    // The same press as T-R8b, for Delete Section: a heading renamed a moment ago, the page's first answer is `leadersMismatch`, the
    // flush's write waits behind a held system sequence, a SECOND heading change is typed meanwhile, and the retry mismatches again: the
    // press goes to the old body, which flushes the content RECORD. The click must take the page's live text into the record first or the
    // second rename is lost.
    func testAMarkdownDeleteSentToTheOldBodyByASecondMismatchKeepsTheSecondRename() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        try await rig.userTypes(" Two", after: "# Bravo")
        let charlie = try rig.section("Charlie")
        let ticket = rig.writerRig.hold()
        let controller = rig.controller
        let deleteTask = Task { @MainActor in await controller.performSectionDelete(rootId: charlie.id) }

        let flushing = await rig.waitUntil { rig.markdownWriter.inFlight != nil }
        XCTAssertTrue(flushing, "premise: the click never reached its mismatch flush")
        try await rig.userTypes(" Three", after: "# Alpha")   // the second change, during the wait
        await rig.writerRig.release(ticket)

        let outcome = await deleteTask.value
        XCTAssertEqual(outcome, .performed, "the Delete ended \(outcome)")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "premise: the Delete took the old body (no editor-first entry)")
        await rig.settleEverything()
        let pageLines = try await pageContentLines()
        XCTAssertEqual(
            pageLines.filter { $0.hasPrefix("# ") }, ["# Alpha Three", "# Bravo Two"], "page lacks the second rename (or the first): \(pageLines)")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after the old body")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer's hold is still up after the old body")
    }

    // MARK: - R10: a zoom during the click's wait

    // The click waits behind an earlier command's hold; the project is zoomed in the gap (zoom is not on the structural gate). The click
    // must hand the press to the old body (return nil) instead of moving the zoomed page's text. Called directly: the old body is not
    // part of what is pinned here.
    func testTheClickGivesTheOldBodyThePressWhenTheProjectIsZoomedWhileItWaits() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book3, observesPage: true)
        self.rig = rig
        rig.installReparseHost()
        let before = try await rig.pageText()
        let (plan, request) = try dropRequest("Charlie", after: "Alpha")
        let earlier = rig.markdownWriter.beginStructuralHold()   // an earlier Markdown command is still finishing
        let controller = rig.controller
        let sectionId = request.sectionId
        let task = Task { @MainActor in
            await controller.performMarkdownEditorFirstReorder(plan: plan, changedLevels: [:], rootId: sectionId)
        }
        let waiting = await rig.waitUntil { rig.markdownWriter.structuralHoldWaiterCount == 1 }
        XCTAssertTrue(waiting, "premise: the click does not wait for the earlier hold")
        rig.editorState.zoomedSectionId = request.sectionId   // zoom in, in the gap
        earlier.release()

        let outcome = await task.value
        rig.editorState.zoomedSectionId = nil

        XCTAssertNil(outcome, "the click went on after the project was zoomed (outcome \(String(describing: outcome)))")
        let after = try await rig.pageText()
        XCTAssertEqual(after, before, "the click moved the zoomed page's text")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the click kept the hold")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the click left its pending count up")
    }

    // MARK: - V1: the Notes heading line goes to the page with the settle flag

    // The page sorts the Notes definitions in the same transaction as the settle's renumber, but only when Swift hands it the Notes
    // heading line with the flag (`setStructuralSettleOpId(opId, notesHeadingLine)`). The page's function is wrapped to record what it is
    // called with; the line must be the one the rows have.
    func testTheSettleFlagCarriesTheNotesHeadingLineFromTheRows() async throws {
        let rig = try await makePrimedRig()
        _ = try await rig.helper.webView.evaluateJavaScript(
            """
            (() => {
              window.__setCalls = [];
              const ff = window.FinalFinal;
              const original = ff.setStructuralSettleOpId.bind(ff);
              ff.setStructuralSettleOpId = (id, second) => {
                window.__setCalls.push([id, second === undefined ? null : second]);
                return original(id, second);
              };
              return true;
            })()
            """)

        let drag = try await drop("Chapter Three", after: "Chapter One")
        XCTAssertEqual(drag.outcome, .performed, "the drag ended \(drag.outcome)")
        XCTAssertTrue(drag.editorFirst, "the drag took the old body")
        await rig.settleEverything()

        let json = try await rig.helper.webView.evaluateJavaScript("JSON.stringify(window.__setCalls)")
        let calls = try JSONDecoder().decode([[String?]].self, from: Data(try XCTUnwrap(json as? String).utf8))
        let sets = calls.filter { $0.first.flatMap { $0 } != nil }
        XCTAssertEqual(sets.count, 1, "the flag was set \(sets.count) times: \(calls)")
        let heading = sets.first.flatMap { $0.count > 1 ? $0[1] : nil }
        XCTAssertEqual(heading, "# Notes", "Notes heading line not sent with the settle flag: \(calls)")
    }

    // MARK: - R3: two drags in a row, then Cmd-Z twice

    // Drop A (its job held), drop B at once (it waits for A's hold and takes the overlay slot), release: page, rows and sidebar agree on
    // the order after both. Then Cmd-Z twice: the order after A, then the original order, in the page, the rows and the sidebar.
    // (Rich Text has the analogue testReorderEFTwiceThenUndo_book6.)
    func testTwoDragsInARowThenCmdZTwiceRestoreTheOriginalOrder() async throws {
        let rig = try await MarkdownClickRig(markdown: Self.book4, observesPage: true, routesUndo: true)
        self.rig = rig
        rig.installReparseHost()
        let hold = MarkdownClickRig.JobHold()
        rig.controller.testEFReorderJobBodyHold = { hold.wait() }
        let original = ["# Chapter 1", "# Chapter 2", "# Chapter 3", "# Chapter 4"]
        let afterFirst = ["# Chapter 1", "# Chapter 4", "# Chapter 2", "# Chapter 3"]
        let afterSecond = ["# Chapter 1", "# Chapter 3", "# Chapter 4", "# Chapter 2"]
        let originalLines = try await pageContentLines()

        let first = try await drop("Chapter 4", after: "Chapter 1")
        XCTAssertEqual(first.outcome, .performed, "the first drag ended \(first.outcome)")
        XCTAssertTrue(first.editorFirst, "the first drag took the old body")
        let (plan, request) = try dropRequest("Chapter 3", after: "Chapter 1")   // planned against the sidebar as the first drag left it
        let controller = rig.controller
        let secondTask = Task { @MainActor in await controller.performSectionReorderDetailed(sections: plan, request: request) }
        let waiting = await rig.waitUntil { rig.markdownWriter.structuralHoldWaiterCount == 1 }
        XCTAssertTrue(waiting, "premise: the second drag does not wait for the first one's hold")
        hold.release()   // the first job (the second job's body wait takes the next signal)
        hold.release()
        let second = await secondTask.value
        XCTAssertEqual(second.outcome, .performed, "the second drag ended \(second.outcome)")
        XCTAssertTrue(second.editorFirst, "the second drag took the old body")
        await rig.settleEverything()

        let page = try await rig.pageText()
        XCTAssertEqual(Self.headings(in: page), afterSecond, "the page is not in the order after both drags")
        let pageLines = try await pageContentLines()
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), pageLines, "the rows differ from the page after both drags")
        await rig.editorState.refreshSectionsAwaiting()
        XCTAssertEqual(
            rig.editorState.sections.map(\.title), ["Chapter 1", "Chapter 3", "Chapter 4", "Chapter 2"],
            "the sidebar is not in the order after both drags")
        XCTAssertNil(rig.editorState.pendingReorder, "the sidebar overlay stayed up")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after settle")
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up")

        try await pressAndSettle("undo", until: { Self.headings(in: $0) == afterFirst }, "the first Cmd-Z did not undo the second drag")
        try await pressAndSettle("undo", until: { Self.headings(in: $0) == original }, "the second Cmd-Z did not undo the first drag")
        let restored = try await pageContentLines()
        XCTAssertEqual(restored, originalLines, "the page is not the original document")
        XCTAssertEqual(Self.contentLines(try rig.writerRig.storedText()), originalLines, "the rows are not the original document")
        await rig.editorState.refreshSectionsAwaiting()
        XCTAssertEqual(
            rig.editorState.sections.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3", "Chapter 4"], "the sidebar is not in the original order")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "hold still up after the last Cmd-Z")
    }

    // MARK: - R4: real document shapes

    /// One probe: a document with three sections whose middle (or, for the break case, whole) shape is the thing under test.
    private struct ShapeProbe {
        let name: String
        let document: String
        /// A fragment of the title of the section that is dragged down (after the last card).
        let mover: String
        /// The section that is dragged up (to the top); nil: the same one.
        var upMover: String?
    }

    private static let shapeProbes: [ShapeProbe] = [
        ShapeProbe(
            name: "fence holding '# x' and a blank line",
            document: "# Alpha\n\nAlpha body.\n\n# Bravo\n\nBefore the fence.\n\n```\n# x in the fence\n\nstill in the fence\n```\n\nAfter the fence."
                + "\n\n# Zulu\n\nZulu body.",
            mover: "Bravo"),
        ShapeProbe(
            name: "$$ block holding '# c' and a blank line",
            document: "# Alpha\n\nAlpha body.\n\n# Bravo\n\n$$\na = b\n\n# c\n$$\n\nAfter the math.\n\n# Zulu\n\nZulu body.",
            mover: "Bravo"),
        ShapeProbe(
            name: "CJK heading",
            document: "# Alpha\n\nAlpha body.\n\n# 日本語の見出し\n\n本文です。これは段落です。\n\n# Zulu\n\nZulu body.",
            mover: "日本語"),
        ShapeProbe(
            name: "'#' + U+3000 heading",
            document: "# Alpha\n\nAlpha body.\n\n#\u{3000}Bravo\n\nBody of Bravo.\n\n# Zulu\n\nZulu body.",
            mover: "Bravo"),
        ShapeProbe(
            name: "in-body footnote definition with a 4-space continuation",
            document: "# Alpha\n\nAlpha body.\n\n# Bravo\n\nText with a note[^1].\n\n[^1]: First line of the note.\n\n"
                + "    Continuation paragraph of the note.\n\nAfter the note.\n\n# Zulu\n\nZulu body.",
            mover: "Bravo"),
        ShapeProbe(
            name: "table",
            document: "# Alpha\n\nAlpha body.\n\n# Bravo\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter the table.\n\n# Zulu\n\nZulu body.",
            mover: "Bravo"),
        ShapeProbe(
            name: "section break between two sections",
            document: "# Alpha\n\nAlpha body.\n\n# Bravo\n\nBravo body.\n\n<!-- ::break:: -->\n\n# Zulu\n\nZulu body.",
            mover: "Alpha", upMover: "Zulu")
    ]

    // A chapter whose body is a real document shape is dragged down (after the last card) and up (to the top) through the real click:
    // the editor-first road is taken and, after the job and its step 8, the page text equals the text `BlockParser` assembles from the
    // rows (anchors and the bibliography marker aside). Each shape in its own document; a shape that fails is reported by name, so one
    // run says which ones the page and the rows disagree about.
    func testChaptersWithRealDocumentShapesMoveAsTheRowsAssembleThem() async throws {
        for probe in Self.shapeProbes {
            for direction in ["down", "up"] {
                let label = "\(probe.name), dragged \(direction)"
                let rig = try await MarkdownClickRig(markdown: probe.document, observesPage: true)
                self.rig = rig
                rig.installReparseHost()
                let cards = rig.editorState.sections.map(\.title)
                let wanted = direction == "down" ? probe.mover : (probe.upMover ?? probe.mover)
                guard let moverTitle = cards.first(where: { $0.contains(wanted) }) else {
                    XCTFail("\(label): the rows make no card for it (cards: \(cards))")
                    rig.restore()
                    continue
                }
                let target: String? = direction == "down" ? cards.last : nil
                let drag = try await drop(moverTitle, after: target)
                XCTAssertEqual(drag.outcome, .performed, "\(label): the drag ended \(drag.outcome)")
                XCTAssertTrue(drag.editorFirst, "\(label): the editor-first road was not taken (the page refused: shape not understood)")
                await rig.settleEverything()

                let page = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
                let rows = try rig.writerRig.storedText()
                let pageTrimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
                var rowsTrimmed = rows.trimmingCharacters(in: .whitespacesAndNewlines)
                // A body `[^1]:` definition makes the footnote service add a "# Notes" section to the ROWS (the real app's Notes rebuild
                // would then push it into the page; this rig has no ContentView handler for that). The shape is judged on everything
                // before that section.
                if !pageTrimmed.contains("\n# Notes"), let notes = rowsTrimmed.range(of: "\n\n# Notes") {
                    rowsTrimmed = String(rowsTrimmed[..<notes.lowerBound])
                }
                XCTAssertEqual(
                    pageTrimmed, rowsTrimmed,
                    "\(label): the page and the assembled rows differ: \(Self.firstDifference(pageTrimmed, rowsTrimmed))")
                XCTAssertEqual(
                    pageTrimmed.count, probe.document.trimmingCharacters(in: .whitespacesAndNewlines).count,
                    "\(label): the move added or removed characters")
                rig.restore()
            }
        }
    }

    /// Where two texts first differ, as a short description for a failure message.
    private static func firstDifference(_ left: String, _ right: String) -> String {
        let leftLines = left.components(separatedBy: "\n")
        let rightLines = right.components(separatedBy: "\n")
        for index in 0..<max(leftLines.count, rightLines.count) {
            let leftLine = index < leftLines.count ? leftLines[index] : "<end>"
            let rightLine = index < rightLines.count ? rightLines[index] : "<end>"
            if leftLine != rightLine { return "line \(index + 1): page '\(leftLine)' / rows '\(rightLine)'" }
        }
        return "none"
    }
}
