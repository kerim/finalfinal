//
//  RichTextSortOrderSpacingTests.swift
//  final finalTests
//
//  t-75d20927: in Rich Text, many paragraphs inserted in one spot (a paste, or a run of Enters) used to halve the gap to the next row
//  each time until positions tied with or passed that row, so a zoom, a Cmd-/ switch or a reopen showed the end of the paste below the
//  paragraph that had followed it. These drive the REAL Rich Text entries (a report through `applyReportBatch`, a zoom/switch batch
//  through `writeTransitionBatch`) and the real writer and database, plus the two places that keep a zoom range across a renumber.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Rich Text keeps saved positions apart when many paragraphs go in one spot (t-75d20927)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct RichTextSortOrderSpacingTests {
    static let count = 200
    /// How many paragraphs each paste of the zoom tests carries: enough that each one crosses at least two re-spacings, few enough to stay fast.
    static let zoomedPasteCount = 100
    static let lastChapterPasteCount = 80
    static let threeBlocks = "# Chapter\n\nMiddle paragraph.\n\nLast paragraph."
    static let threeChapters = """
    # Chapter One

    One body.

    # Chapter Two

    Two body.

    Two closing.

    # Chapter Three

    Three body.
    """

    /// Like `threeChapters`, but the last chapter has a second paragraph, so a paste after its first one has a row to crowd against.
    static let lastChapterBook = """
    # Chapter One

    One body.

    # Chapter Two

    Two body.

    Two closing.

    # Chapter Three

    Three body.

    Three closing.
    """

    static func pasted(_ number: Int) -> String { String(format: "Pasted %03d.", number) }

    // MARK: - Helpers

    private func rig(_ content: String) throws -> TestStack {
        let stack = try makeStack(content: content)
        let js = ScriptedJSEvaluator()
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }
        stack.editorState.projectDatabase = stack.db
        stack.editorState.currentProjectId = stack.pid
        return stack
    }

    private func rows(_ db: ProjectDatabase) throws -> [Block] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: db))
    }

    private func row(_ db: ProjectDatabase, startingWith prefix: String) throws -> Block {
        try #require(try rows(db).first { $0.markdownFragment.hasPrefix(prefix) })
    }

    /// Flags the fixture's Bibliography the way production has it: the "# Bibliography" heading and every row after it carry
    /// `isBibliography`. A bare "# Bibliography" heading in parsed text is NOT flagged (the parser wants a marker or an end marker as
    /// evidence), so the rows are flagged after the fixture is built, as `SectionDeleteRootGuardTests` does.
    private func flagBibliography(_ db: ProjectDatabase) throws {
        let ordered = try rows(db)
        let start = try #require(ordered.firstIndex { $0.markdownFragment.hasPrefix("# Bibliography") }, "the fixture has a Bibliography heading")
        let ids = ordered[start...].map(\.id)
        try db.write { database in
            for id in ids {
                try database.execute(sql: "UPDATE block SET isBibliography = 1 WHERE id = ?", arguments: [id])
            }
        }
    }

    private func insert(_ number: Int, after anchorId: String) -> BlockInsert {
        let text = Self.pasted(number)
        return BlockInsert(tempId: "temp-rt-\(number)", blockType: "paragraph", textContent: text, markdownFragment: text,
                           headingLevel: nil, afterBlockId: anchorId, atDocumentStart: nil)
    }

    /// One paste: paragraph `first` after `anchorId`, every later one after the paragraph before it (the page's own chain).
    private func chain(_ count: Int, startingAt first: Int = 1, after anchorId: String) -> BlockChanges {
        BlockChanges(inserts: (first..<(first + count)).map { insert($0, after: $0 == first ? anchorId : "temp-rt-\($0 - 1)") })
    }

    /// Takes a zoom range on `title`'s chapter from freshly read rows (up to the heading `nextTitle`, or to the end of the document when
    /// nil), as a zoom-in does: the range is stamped at the log's length of THIS moment. Returns the zoom root.
    @discardableResult
    private func zoomInto(_ stack: TestStack, _ title: String, before nextTitle: String?) throws -> Block {
        let root = try row(stack.db, startingWith: title)
        let next = try nextTitle.map { try row(stack.db, startingWith: $0) }
        stack.editorState.zoomedBlockRange = (start: root.sortOrder, end: next?.sortOrder)
        stack.editorState.zoomedSectionId = root.id
        return root
    }

    /// The rows the range selects, in assembly order: `sortOrder >= start` and, when there is an end, `< end` (what every reader does).
    private func rows(in range: (start: Double, end: Double?), _ db: ProjectDatabase) throws -> [String] {
        try rows(db).filter { block in
            block.sortOrder >= range.start && (range.end.map { block.sortOrder < $0 } ?? true)
        }.map(\.markdownFragment)
    }

    private final class Minted { var ids: [String: String] = [:] }

    /// One report through the real Rich Text report path (applyReportBatch -> applyFetchedBatch -> applyAndConfirm -> the writer).
    private func applyReport(_ stack: TestStack, _ changes: BlockChanges) async throws -> [String: String] {
        let (ticket, stamp) = try #require(stack.sync.reserveWriterTurn(database: stack.db, projectId: stack.pid))
        ticket.noteFetched()
        let minted = Minted()
        await stack.sync.applyReportBatch(
            ticket: ticket, stamp: stamp, changes: changes, abandonAfterTurn: { false }, onApplied: { minted.ids = $0 })
        ticket.settleIfOpen(.noBatch)
        return minted.ids
    }

    /// The pasted run reads 1...count, right after the anchor and right before the follower; every saved position strictly increases.
    private func expectPastedRun(
        _ db: ProjectDatabase, count: Int, after anchorPrefix: String, before followerPrefix: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let all = try rows(db)
        let fragments = all.map(\.markdownFragment)
        guard let anchorIndex = fragments.firstIndex(where: { $0.hasPrefix(anchorPrefix) }) else {
            Issue.record("no row starts with \(anchorPrefix)", sourceLocation: sourceLocation)
            return
        }
        let following = Array(fragments[(anchorIndex + 1)...].prefix(count + 1))
        let inOrder = following.count == count + 1
            && Array(following.prefix(count)) == (1...count).map(Self.pasted)
            && following.last?.hasPrefix(followerPrefix) == true
        #expect(inOrder, "rows read back in insert order, all before the block that followed", sourceLocation: sourceLocation)
        let orders = all.map(\.sortOrder)
        #expect(zip(orders, orders.dropFirst()).allSatisfy { $0 < $1 }, "saved positions strictly increase",
                sourceLocation: sourceLocation)
    }

    // MARK: - The bug (T1 to T4)

    @Test("T1: 200 chained inserts in ONE report after the middle block keep insert order, before the block that followed")
    func twoHundredChainedInsertsInOneReport() async throws {
        let stack = try rig(Self.threeBlocks)
        let anchor = try row(stack.db, startingWith: "Middle paragraph.")
        _ = try await applyReport(stack, chain(Self.count, after: anchor.id))
        try expectPastedRun(stack.db, count: Self.count, after: "Middle paragraph.", before: "Last paragraph.")
    }

    @Test("T2: 200 chained inserts as 200 SEPARATE reports (typing Enter after Enter) keep insert order")
    func twoHundredChainedInsertsAsSeparateReports() async throws {
        let stack = try rig(Self.threeBlocks)
        var anchorId = try row(stack.db, startingWith: "Middle paragraph.").id
        for number in 1...Self.count {
            let minted = try await applyReport(stack, BlockChanges(inserts: [insert(number, after: anchorId)]))
            anchorId = try #require(minted["temp-rt-\(number)"], "report \(number) minted its row")
        }
        try expectPastedRun(stack.db, count: Self.count, after: "Middle paragraph.", before: "Last paragraph.")
    }

    @Test("T3: 200 chained inserts in one zoom/switch transition batch keep insert order")
    func twoHundredChainedInsertsInOneTransitionBatch() async throws {
        let stack = try rig(Self.threeBlocks)
        let anchor = try row(stack.db, startingWith: "Middle paragraph.")
        guard let seq = stack.sync.writeTransitionBatch(chain(Self.count, after: anchor.id)) else {
            Issue.record("the transition batch got no writer turn")
            return
        }
        #expect(await stack.sync.awaitTransitionBarrier(through: seq, timeout: 15))
        try expectPastedRun(stack.db, count: Self.count, after: "Middle paragraph.", before: "Last paragraph.")
    }

    @Test("T4a: 200 paragraphs typed one report at a time right above the Bibliography stay in order and stay out of it")
    func paragraphsTypedAboveBibliographyKeepOrder() async throws {
        let stack = try rig("# Chapter\n\nLast body paragraph.\n\n# Bibliography\n\nSmith, J. 2020. A book.")
        try flagBibliography(stack.db)
        #expect(try rows(stack.db).contains { $0.isBibliography }, "premise: the fixture has a Bibliography")
        var anchorId = try row(stack.db, startingWith: "Last body paragraph.").id
        for number in 1...Self.count {
            let minted = try await applyReport(stack, BlockChanges(inserts: [insert(number, after: anchorId)]))
            anchorId = try #require(minted["temp-rt-\(number)"])
        }
        try expectPastedRun(stack.db, count: Self.count, after: "Last body paragraph.", before: "# Bibliography")
        #expect(try rows(stack.db).filter { $0.markdownFragment.hasPrefix("Pasted") }.allSatisfy { !$0.isBibliography && !$0.isNotes })
    }

    @Test("T4b: 200 paragraphs typed one report at a time right above Notes stay in order and stay out of it")
    func paragraphsTypedAboveNotesKeepOrder() async throws {
        let stack = try rig("# Chapter\n\nLast body paragraph.[^1]\n\n# Notes\n\n[^1]: A note.")
        #expect(try rows(stack.db).contains { $0.isNotes }, "premise: the fixture has a Notes section")
        var anchorId = try row(stack.db, startingWith: "Last body paragraph.").id
        for number in 1...Self.count {
            let minted = try await applyReport(stack, BlockChanges(inserts: [insert(number, after: anchorId)]))
            anchorId = try #require(minted["temp-rt-\(number)"])
        }
        try expectPastedRun(stack.db, count: Self.count, after: "Last body paragraph.", before: "# Notes")
        #expect(try rows(stack.db).filter { $0.markdownFragment.hasPrefix("Pasted") }.allSatisfy { !$0.isNotes })
    }

    // MARK: - The zoom range across a re-spacing (T5, T6)

    @Test("T5: a paste that re-spaces the positions while zoomed: the zoom range still covers exactly the zoomed chapter")
    func zoomRangeFollowsTheRespacing() async throws {
        let stack = try rig(Self.threeChapters)
        let two = try row(stack.db, startingWith: "# Chapter Two")
        let three = try row(stack.db, startingWith: "# Chapter Three")
        let anchor = try row(stack.db, startingWith: "Two body.")
        stack.editorState.zoomedBlockRange = (start: two.sortOrder, end: three.sortOrder)

        _ = try await applyReport(stack, chain(Self.count, after: anchor.id))

        let range = try #require(stack.editorState.zoomedBlockRange)
        let inRange = try rows(stack.db).filter { block in
            block.sortOrder >= range.start && (range.end.map { block.sortOrder < $0 } ?? true)
        }
        let expected = ["# Chapter Two", "Two body."] + (1...Self.count).map(Self.pasted) + ["Two closing."]
        #expect(inRange.map(\.markdownFragment) == expected, "the zoom range covers exactly the zoomed chapter after the re-spacing")
    }

    @Test("T6: a close while zoomed, after a paste that re-spaced the positions, replaces exactly the chapter, once")
    func zoomedCloseAfterRespacingReplacesExactlyTheChapter() async throws {
        let stack = try rig(Self.threeChapters)
        let two = try row(stack.db, startingWith: "# Chapter Two")
        let three = try row(stack.db, startingWith: "# Chapter Three")
        let anchor = try row(stack.db, startingWith: "Two body.")
        stack.editorState.zoomedBlockRange = (start: two.sortOrder, end: three.sortOrder)
        // What the close copies at its step 2, BEFORE its flush applies the page's last report: the real capture, not a hand-built anchor.
        let capture = stack.editorState.captureForLifecycle(host: QuitFlushTestSupport.host(webView: nil))
        let captured = try #require(capture.zoomedRange, "the capture carries the zoom range")

        _ = try await applyReport(stack, chain(Self.count, after: anchor.id))

        let chapter = ["# Chapter Two", "Two body."] + (1...Self.count).map(Self.pasted) + ["Two closing.", "Typed just before the close."]
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: chapter.joined(separator: "\n\n"), database: stack.db, projectId: stack.pid,
            zoomedRange: captured, zoomedSectionId: two.id))
        let body = LifecycleWholeDocumentWrite.body(prepared)
        _ = try stack.db.write { try body($0) }   // the synchronous helper: `dbWriter.write` picks its async overload in an async test

        let expected = ["# Chapter One", "One body."] + chapter + ["# Chapter Three", "Three body."]
        #expect(try rows(stack.db).map(\.markdownFragment) == expected,
                "the close replaced exactly the zoomed chapter: nothing doubled, nothing of the other chapters lost")
    }

}

// The range follows a re-spacing through the write paths that read it, and the image de-duplication per entry. (An extension of the suite,
// so the suite's own body stays inside the lint limit; the helpers above are private to this file, which the extension shares.)
extension RichTextSortOrderSpacingTests {
    // MARK: - A range stamped after an earlier re-spacing, the write paths that read it (M1 to M4)

    @Test("M2: a zoom range taken AFTER an earlier re-spacing still follows the next one: it covers exactly the zoomed chapter")
    func zoomRangeStampedAfterAnEarlierRespacingFollowsTheNext() async throws {
        let stack = try rig(Self.threeChapters)
        let log = stack.db.sortOrderRenumberLog
        try zoomInto(stack, "# Chapter Two", before: "# Chapter Three")
        _ = try await applyReport(stack, chain(Self.zoomedPasteCount, after: try row(stack.db, startingWith: "Two body.").id))
        #expect(log.generation > 0, "premise: the first paste re-spaced the positions")

        // Taken again from the fresh rows: now stamped after the first re-spacing, in the numbers it left.
        try zoomInto(stack, "# Chapter Two", before: "# Chapter Three")
        let generationAfterFirst = log.generation
        let lastOfFirst = try row(stack.db, startingWith: Self.pasted(Self.zoomedPasteCount))
        let second = chain(Self.zoomedPasteCount, startingAt: Self.zoomedPasteCount + 1, after: lastOfFirst.id)
        _ = try await applyReport(stack, second)
        #expect(log.generation > generationAfterFirst, "premise: the second paste re-spaced the positions again")

        let range = try #require(stack.editorState.zoomedBlockRange)
        let expected = ["# Chapter Two", "Two body."] + (1...(2 * Self.zoomedPasteCount)).map(Self.pasted) + ["Two closing."]
        #expect(try rows(in: range, stack.db) == expected,
                "the zoom range, taken after an earlier re-spacing, covers exactly the zoomed chapter after the next one")
    }

    @Test("M3b: a close after two re-spacings, with the range captured after the first, replaces exactly the chapter, once")
    func closeAfterTwoRespacedPastesReplacesExactlyTheChapter() async throws {
        let stack = try rig(Self.threeChapters)
        let log = stack.db.sortOrderRenumberLog
        try zoomInto(stack, "# Chapter Two", before: "# Chapter Three")
        _ = try await applyReport(stack, chain(Self.zoomedPasteCount, after: try row(stack.db, startingWith: "Two body.").id))
        #expect(log.generation > 0, "premise: the first paste re-spaced the positions")

        let two = try zoomInto(stack, "# Chapter Two", before: "# Chapter Three")
        // What the close copies at its step 2, BEFORE its flush applies the page's last report.
        let capture = stack.editorState.captureForLifecycle(host: QuitFlushTestSupport.host(webView: nil))
        let captured = try #require(capture.zoomedRange, "the capture carries the zoom range")
        let generationAtCapture = log.generation
        let lastOfFirst = try row(stack.db, startingWith: Self.pasted(Self.zoomedPasteCount))
        _ = try await applyReport(stack, chain(Self.zoomedPasteCount, startingAt: Self.zoomedPasteCount + 1, after: lastOfFirst.id))
        #expect(log.generation > generationAtCapture, "premise: the second paste re-spaced the positions again")

        let chapter = ["# Chapter Two", "Two body."] + (1...(2 * Self.zoomedPasteCount)).map(Self.pasted)
            + ["Two closing.", "Typed just before the close."]
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: chapter.joined(separator: "\n\n"), database: stack.db, projectId: stack.pid,
            zoomedRange: captured, zoomedSectionId: two.id))
        let body = LifecycleWholeDocumentWrite.body(prepared)
        _ = try stack.db.write { try body($0) }

        let expected = ["# Chapter One", "One body."] + chapter + ["# Chapter Three", "Three body."]
        #expect(try rows(stack.db).map(\.markdownFragment) == expected,
                "the close after two re-spacings replaced exactly the zoomed chapter: nothing doubled, the other chapters untouched")
    }

    @Test("M3c: a close in the LAST chapter (open end) after a re-spacing replaces exactly the chapter, once, and the end stays open")
    func closeInTheLastChapterAfterARespacedPasteKeepsTheOpenEnd() async throws {
        let stack = try rig(Self.lastChapterBook)
        let three = try zoomInto(stack, "# Chapter Three", before: nil)
        let capture = stack.editorState.captureForLifecycle(host: QuitFlushTestSupport.host(webView: nil))
        let captured = try #require(capture.zoomedRange, "the capture carries the zoom range")
        let anchor = try row(stack.db, startingWith: "Three body.")

        _ = try await applyReport(stack, chain(Self.lastChapterPasteCount, after: anchor.id))
        #expect(stack.db.sortOrderRenumberLog.generation > 0, "premise: the paste re-spaced the positions")

        let chapter = ["# Chapter Three", "Three body."] + (1...Self.lastChapterPasteCount).map(Self.pasted)
            + ["Three closing.", "Typed just before the close."]
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: chapter.joined(separator: "\n\n"), database: stack.db, projectId: stack.pid,
            zoomedRange: captured, zoomedSectionId: three.id))
        let range = try #require(prepared.range, "the prepared write carries the zoom range")
        #expect(range.end == nil, "the last chapter's range stays open-ended after the re-spacing")
        let body = LifecycleWholeDocumentWrite.body(prepared)
        _ = try stack.db.write { try body($0) }

        let expected = ["# Chapter One", "One body.", "# Chapter Two", "Two body.", "Two closing."] + chapter
        #expect(try rows(stack.db).map(\.markdownFragment) == expected,
                "the close in the last chapter replaced exactly that chapter: nothing doubled or lost, the other chapters untouched")
    }

    @Test("M1: the zoomed range write after a re-spacing replaces exactly the chapter (the range is translated inside the write)")
    func zoomedRangeWriteAfterARespacingReplacesExactlyTheChapter() async throws {
        let stack = try rig(Self.threeChapters)
        let two = try zoomInto(stack, "# Chapter Two", before: "# Chapter Three")
        let anchor = try row(stack.db, startingWith: "Two body.")
        // The range as taken, BEFORE the report: raw numbers that the paste's re-spacing is about to change.
        let rawEnd = try #require(stack.editorState.zoomedBlockRangeAnchor).range.end

        _ = try await applyReport(stack, chain(Self.zoomedPasteCount, after: anchor.id))
        #expect(stack.db.sortOrderRenumberLog.generation > 0, "premise: the paste re-spaced the positions")
        #expect(try #require(stack.editorState.zoomedBlockRange).end != rawEnd, "premise: the raw numbers the range was taken at are stale")

        let chapter = ["# Chapter Two", "Two body."] + (1...Self.zoomedPasteCount).map(Self.pasted)
            + ["Two closing.", "Typed just before the write."]
        try stack.editorState.applyZoomedRangeWrite(text: chapter.joined(separator: "\n\n"), db: stack.db, pid: stack.pid)

        let expected = ["# Chapter One", "One body."] + chapter + ["# Chapter Three", "Three body."]
        #expect(try rows(stack.db).map(\.markdownFragment) == expected,
                "the zoomed range write after a re-spacing replaced exactly the zoomed chapter: nothing doubled or lost")
        #expect(try row(stack.db, startingWith: "# Chapter Two").id == two.id, "the zoom root kept its id")
        let range = try #require(stack.editorState.zoomedBlockRange)
        #expect(try rows(in: range, stack.db) == chapter, "the range the write left covers exactly the zoomed chapter")
    }

    @Test("A batch that re-spaces reports how many times, and the log holds exactly those renumbers")
    func renumberCountIsReportedAndLogged() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.threeBlocks)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let anchor = try row(db, startingWith: "Middle paragraph.")
        let before = db.sortOrderRenumberLog.generation
        let result = try db.applyBlockChangesFromEditor(
            chain(Self.count, after: anchor.id), for: pid, stamp: .unguarded, renumberSortOrdersIfCrowded: true)
        #expect(result.sortOrderRenumbers > 0, "200 chained inserts in one spot re-space at least once")
        #expect(db.sortOrderRenumberLog.generation == before + result.sortOrderRenumbers,
                "every renumber the batch reports is in the log, and nothing else is")
    }

    // MARK: - Image de-duplication per entry (M4)

    private func twoCopiesOfOneImage(_ prefix: String) -> BlockChanges {
        BlockChanges(inserts: (1...2).map { number in
            BlockInsert(tempId: "\(prefix)-\(number)", blockType: "image", textContent: "",
                        markdownFragment: "![alt](media/photo.jpg)", headingLevel: nil, afterBlockId: nil)
        })
    }

    private func imageRows(_ db: ProjectDatabase) throws -> [Block] {
        try TestFixtureFactory.fetchBlocks(from: db).filter { $0.blockType == .image }
    }

    @Test("M4a: a Markdown batch that holds the same image line twice keeps both rows (the Markdown entry does not de-duplicate)")
    func markdownEntryKeepsBothCopiesOfTheSameImage() async throws {
        let stack = try makeStack(content: "# Test")
        guard case .reserved(let turn) = stack.sync.reserveMarkdownTurn(database: stack.db, projectId: stack.pid) else {
            Issue.record("no Markdown turn was reserved")
            return
        }
        let outcome = await stack.sync.applyMarkdownTurn(turn, twoCopiesOfOneImage("temp-md-img"))
        guard case .applied = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(try imageRows(stack.db).count == 2, "a Markdown document that holds the same image line twice keeps two rows")
    }

    @Test("M4b: a Rich Text report that carries the same image twice is de-duplicated to one row by applyAndConfirm")
    func richTextReportDeduplicatesTheSameImage() async throws {
        let stack = try rig("# Test")
        let minted = try await applyReport(stack, twoCopiesOfOneImage("temp-rt-img"))
        #expect(try imageRows(stack.db).count == 1, "a Rich Text report that sends the same image twice makes one row")
        #expect(minted["temp-rt-img-1"] != nil && minted["temp-rt-img-1"] == minted["temp-rt-img-2"],
                "both temp ids are confirmed to the one row")
    }

    // MARK: - Pieces

    @Test("The translation gives each value the number the renumber gives the first row at or after it")
    func renumberedValueMatchesTheRewrite() {
        let old: [Double] = [1.0, 1.5, 1.5, 2.0]
        #expect(SortOrderRenumberLog.renumbered(0.5, old) == 1)
        #expect(SortOrderRenumberLog.renumbered(1.0, old) == 1)
        #expect(SortOrderRenumberLog.renumbered(1.2, old) == 2)
        #expect(SortOrderRenumberLog.renumbered(1.5, old) == 2)
        #expect(SortOrderRenumberLog.renumbered(2.0, old) == 4)
        #expect(SortOrderRenumberLog.renumbered(3.0, old) == 5)
    }

    @Test("Same-src image inserts in one batch are still de-duplicated on the Rich Text path (guard on)")
    func imageDedupKeptWithTheGuardOn() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Test")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let changes = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-img-1", blockType: "image", textContent: "",
                        markdownFragment: "![alt](media/photo.jpg){width=50%}", headingLevel: nil, afterBlockId: nil),
            BlockInsert(tempId: "temp-img-2", blockType: "image", textContent: "",
                        markdownFragment: "![alt](media/photo.jpg){width=75%}", headingLevel: nil, afterBlockId: nil)
        ])
        _ = try db.applyBlockChangesFromEditor(changes, for: pid, stamp: .unguarded, renumberSortOrdersIfCrowded: true)
        let images = try TestFixtureFactory.fetchBlocks(from: db).filter { $0.blockType == .image }
        #expect(images.count == 1, "Same-src image inserts are still de-duplicated on the Rich Text path")
    }
}
