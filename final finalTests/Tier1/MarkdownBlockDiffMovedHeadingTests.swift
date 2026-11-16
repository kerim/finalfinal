//
//  MarkdownBlockDiffMovedHeadingTests.swift
//  final finalTests
//
//  t-b097670d: a heading moved (cut and pasted, or selected text dragged inside the editor) or put back (delete, then Cmd-Z) in Markdown
//  mode keeps its status, tags and
//  goals. The PURE half: which inserted heading takes the fields of which deleted heading row, in `MarkdownBlockDiff` (the same
//  save: `pairMovedHeadings`; a save later: `pairRememberedHeadings`, from the writer's memory). No database, no writer.
//
//  Vocabulary as in `MarkdownBlockDiffTests`: the stored rows are a parse of the OLD text with ids `r1`, `r2`, ... in document order;
//  the new blocks are a parse of the NEW text; temp ids come from a counter (`temp-md-1`, ...). Lines below are blocks joined by blank
//  lines (`blocks`). Each test `#require`s its alignment premise first, so a change in how the alignment picks its edits fails
//  loudly at the premise and not as a wrong carry.
//

import Foundation
import Testing
@testable import final_final

@Suite("MarkdownBlockDiff moved heading — Tier 1 (t-b097670d)", .serialized, .timeLimit(.minutes(2)))
struct MarkdownBlockDiffMovedHeadingTests {

    // MARK: - Helpers

    private static let pid = "p-md-diff-moved-heading"

    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: Self.pid, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    /// The stored rows of `markdown`: its parse, with ids `r1`, `r2`, ... in document order.
    private func storedRows(_ markdown: String) -> [Block] {
        var blocks = parse(markdown)
        for index in blocks.indices {
            blocks[index].id = "r\(index + 1)"
            blocks[index].sortOrder = Double(index + 1)
        }
        return blocks
    }

    private final class TempIds {
        var next = 0
        func make() -> String {
            next += 1
            return "temp-md-\(next)"
        }
    }

    /// Rows mode: the diff of the `new` text against the stored rows of the `old` text, with the writer's `remembered` items.
    private func diff(_ old: String, _ new: String, remembered: [RemovedHeadingMemory.Item] = []) -> MarkdownBlockDiff.Result {
        let ids = TempIds()
        return MarkdownBlockDiff.diff(rows: storedRows(old), new: parse(new), remembered: remembered, makeTempId: { ids.make() })
    }

    private func blocks(_ fragments: [String]) -> String { fragments.joined(separator: "\n\n") }

    private func meta(_ status: SectionStatus, goal: Int) -> SectionMetadataCarry {
        SectionMetadataCarry(
            status: status, tags: ["t\(goal)"], wordGoal: goal, goalType: .min, aggregateGoal: goal * 10, aggregateGoalType: .max)
    }

    private func headingKey(_ fragment: String, level: Int) -> MarkdownBlockDiff.Key {
        MarkdownBlockDiff.Key(blockType: .heading, headingLevel: level, markdownFragment: fragment)
    }

    /// A remembered item, as `RemovedHeadingMemory` would hold it.
    private func item(
        _ token: Int, _ fragment: String, level: Int, _ carry: SectionMetadataCarry, sortOrder: Double? = nil
    ) -> RemovedHeadingMemory.Item {
        RemovedHeadingMemory.Item(
            token: token, key: headingKey(fragment, level: level), metadata: carry, sortOrder: sortOrder ?? Double(token))
    }

    /// The book of tests 1, 5 and 7: `# A` first, moved to just before `# C`.
    private var movedFrom: String { blocks(["# A", "a1", "a2", "# B", "b1", "# C", "c1"]) }
    private func movedTo(_ line: String) -> String { blocks(["a1", "a2", "# B", "b1", line, "# C", "c1"]) }

    // MARK: - The same save

    @Test("1. a heading moved to another place in one save: the insert names the deleted row, and carries nothing by value")
    func movedHeadingInsertNamesItsRow() throws {
        let result = diff(movedFrom, movedTo("# A"))
        try #require(result.changes.deletes == ["r1"], "premise: the alignment deletes the old heading row")
        try #require(result.changes.inserts.map(\.markdownFragment) == ["# A"], "premise: the alignment inserts the heading once")
        #expect(result.changes.updates.isEmpty)
        let insert = try #require(result.changes.inserts.first)
        #expect(insert.afterBlockId == "r5", "after b1, the block before it")
        #expect(insert.carryMetadataFromId == "r1")
        #expect(insert.carriedMetadata == nil)
        #expect(
            result.removedHeadings == [MarkdownBlockDiff.RemovedHeadingRef(id: "r1", key: headingKey("# A", level: 1), carriedByTempId: "temp-md-1")],
            "the row is listed, marked as taken by the insert: the writer remembers it only if that insert was not minted")
        #expect(result.usedRemembered.isEmpty)
    }

    @Test("2. two equal headings both moved in one save are paired in document order: the first copy takes the earlier row")
    func twoEqualHeadingsBothMovedPairInDocumentOrder() throws {
        let old = blocks(["## S", "p1", "## S", "p2", "# B", "b1", "b2", "b3"])
        let new = blocks(["p1", "p2", "# B", "b1", "## S", "b2", "## S", "b3"])
        let result = diff(old, new)
        try #require(result.changes.deletes == ["r1", "r3"], "premise: both old rows are deleted")
        try #require(result.changes.inserts.map(\.markdownFragment) == ["## S", "## S"], "premise: both headings are inserts")
        #expect(result.changes.inserts.map(\.carryMetadataFromId) == ["r1", "r3"])
        #expect(result.changes.inserts.allSatisfy { $0.carriedMetadata == nil })
        #expect(result.removedHeadings.map(\.id) == ["r1", "r3"])
        #expect(result.removedHeadings.map(\.carriedByTempId) == ["temp-md-1", "temp-md-2"], "each row is marked with the insert that takes it")
    }

    @Test("3. one of two equal headings moved: the insert takes the row that was REMOVED, never the one that stayed")
    func oneOfTwoEqualHeadingsMovedTakesTheRemovedRowNotTheKeptOne() throws {
        let old = blocks(["# A", "## S", "s1", "s2", "# B", "## S", "t1", "# C", "c1"])
        let new = blocks(["# A", "s1", "s2", "# B", "## S", "t1", "## S", "# C", "c1"])
        let result = diff(old, new)
        try #require(result.changes.deletes == ["r2"], "premise: the FIRST ## S row is the one deleted")
        try #require(result.entries[4].id == "r6", "premise: the second ## S is the unchanged one")
        let insert = try #require(result.changes.inserts.first)
        #expect(result.changes.inserts.count == 1)
        #expect(insert.carryMetadataFromId == "r2")
        #expect(insert.carriedMetadata == nil)
    }

    @Test("4. a heading really deleted: a plain delete listed for the memory; a new heading typed elsewhere carries nothing")
    func reallyDeletedHeadingCarriesNothing() throws {
        let old = blocks(["# A", "a1", "# B", "b1", "# C", "c1"])
        let deleted = diff(old, blocks(["# A", "a1", "b1", "# C", "c1"]))
        try #require(deleted.changes.deletes == ["r3"], "premise")
        #expect(deleted.changes.inserts.isEmpty)
        #expect(
            deleted.removedHeadings == [MarkdownBlockDiff.RemovedHeadingRef(id: "r3", key: headingKey("# B", level: 1), carriedByTempId: nil)],
            "a plain delete: no insert takes it")

        let typed = diff(old, blocks(["# A", "a1", "b1", "# C", "c1", "# D"]))
        try #require(typed.changes.deletes == ["r3"], "premise")
        let insert = try #require(typed.changes.inserts.first)
        #expect(insert.markdownFragment == "# D")
        #expect(insert.carryMetadataFromId == nil)
        #expect(insert.carriedMetadata == nil)
        #expect(typed.removedHeadings.map(\.id) == ["r3"])
    }

    @Test("5. a heading renamed AND moved is not a move: the row is deleted, the insert carries nothing")
    func renamedAndMovedHeadingIsNotAMove() throws {
        let result = diff(movedFrom, movedTo("# A2"))
        try #require(result.changes.deletes == ["r1"], "premise")
        let insert = try #require(result.changes.inserts.first)
        try #require(insert.markdownFragment == "# A2", "premise")
        #expect(insert.carryMetadataFromId == nil)
        #expect(insert.carriedMetadata == nil)
        #expect(result.removedHeadings.map(\.id) == ["r1"], "the old row's fields are kept in the memory for a heading that comes back as it was")
    }

    @Test("6. a heading renamed in place keeps its id: one update, no insert, no delete, nothing to remember")
    func renameInPlaceStillKeepsTheId() throws {
        let result = diff(blocks(["# A", "a1", "# B", "b1", "# C", "c1"]), blocks(["# A", "a1", "# B2", "b1", "# C", "c1"]))
        #expect(result.changes.updates.map(\.id) == ["r3"])
        #expect(result.changes.updates.first?.markdownFragment == "# B2")
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
        #expect(result.removedHeadings.isEmpty)
    }

    @Test("7. a heading moved AND given another level is not a move (the level is part of the line)")
    func levelChangedWhileMovedIsNotAMove() throws {
        let result = diff(movedFrom, movedTo("## A"))
        try #require(result.changes.deletes == ["r1"], "premise")
        let insert = try #require(result.changes.inserts.first)
        try #require(insert.markdownFragment == "## A", "premise")
        #expect(insert.carryMetadataFromId == nil)
        #expect(insert.carriedMetadata == nil)
    }

    // MARK: - Across saves

    @Test("8. a heading that is not stored but remembered comes back carrying the remembered fields by value")
    func rememberedHeadingIsCarriedByValue() throws {
        let carry = meta(.review, goal: 500)
        let result = diff(
            blocks(["# A", "a1", "b1"]), blocks(["# A", "a1", "# B", "b1"]),
            remembered: [item(1, "# B", level: 1, carry)])
        try #require(result.changes.inserts.map(\.markdownFragment) == ["# B"], "premise")
        let insert = try #require(result.changes.inserts.first)
        #expect(insert.carriedMetadata == carry)
        #expect(insert.carryMetadataFromId == nil)
        #expect(result.usedRemembered == [MarkdownBlockDiff.UsedRemembered(tempId: "temp-md-1", token: 1)])
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("9. a same-save twin wins over a remembered item of the same line: the insert names the row, the item stays unused")
    func sameSaveTwinWinsOverRemembered() throws {
        let result = diff(movedFrom, movedTo("# A"), remembered: [item(1, "# A", level: 1, meta(.writing, goal: 100))])
        try #require(result.changes.deletes == ["r1"], "premise")
        let insert = try #require(result.changes.inserts.first)
        #expect(insert.carryMetadataFromId == "r1")
        #expect(insert.carriedMetadata == nil)
        #expect(result.usedRemembered.isEmpty)
    }

    @Test("10. with three remembered items of one line and two headings coming back, they take the two most recent, oldest of those first")
    func mostRecentItemsAreTakenOldestFirstInDocumentOrder() throws {
        let remembered = [
            item(1, "## S", level: 2, meta(.next, goal: 100)),
            item(2, "## S", level: 2, meta(.writing, goal: 200)),
            item(3, "## S", level: 2, meta(.review, goal: 300))
        ]
        let result = diff(blocks(["# A", "a1", "a2"]), blocks(["# A", "## S", "a1", "## S", "a2"]), remembered: remembered)
        try #require(result.changes.inserts.map(\.markdownFragment) == ["## S", "## S"], "premise")
        #expect(result.changes.inserts.map { $0.carriedMetadata?.wordGoal } == [200, 300])
        #expect(result.usedRemembered.map(\.token) == [2, 3])
        #expect(result.usedRemembered.map(\.tempId) == ["temp-md-1", "temp-md-2"])
    }

    @Test("10b. items of one line are handed out by where their rows sat, not by when they were deleted")
    func rememberedItemsAreHandedOutByWhereTheirRowsSat() throws {
        // Token 2 was recorded later, but its row sat EARLIER in the document (sortOrder 10 against 20): the later heading of the
        // two was deleted first, then the earlier one.
        let remembered = [
            item(1, "## S", level: 2, meta(.next, goal: 100), sortOrder: 20),
            item(2, "## S", level: 2, meta(.writing, goal: 200), sortOrder: 10)
        ]
        let result = diff(blocks(["# A", "a1", "a2"]), blocks(["# A", "## S", "a1", "## S", "a2"]), remembered: remembered)
        try #require(result.changes.inserts.map(\.markdownFragment) == ["## S", "## S"], "premise")
        #expect(result.changes.inserts.map { $0.carriedMetadata?.wordGoal } == [200, 100], "the first heading takes the earlier row's fields")
        #expect(result.usedRemembered.map(\.token) == [2, 1])
    }

    @Test("10c. the k most recent items are chosen first, and only then ordered by place: an older, earlier-placed item is not taken")
    func theMostRecentAreChosenBeforeTheyAreOrderedByPlace() throws {
        let remembered = [
            item(1, "## S", level: 2, meta(.next, goal: 100), sortOrder: 1),     // oldest: not among the two most recent
            item(2, "## S", level: 2, meta(.writing, goal: 200), sortOrder: 30),
            item(3, "## S", level: 2, meta(.review, goal: 300), sortOrder: 20)
        ]
        let result = diff(blocks(["# A", "a1", "a2"]), blocks(["# A", "## S", "a1", "## S", "a2"]), remembered: remembered)
        try #require(result.changes.inserts.count == 2, "premise")
        #expect(result.changes.inserts.map { $0.carriedMetadata?.wordGoal } == [300, 200])
        #expect(result.usedRemembered.map(\.token) == [3, 2])
    }

    @Test("11. an item of another line is not taken: a renamed heading and the same title at another level get nothing")
    func rememberedItemOfAnotherLineIsNotTaken() throws {
        let result = diff(
            blocks(["# A", "a1"]), blocks(["# A", "a1", "# B2", "## B"]),
            remembered: [item(1, "# B", level: 1, meta(.review, goal: 500))])
        try #require(result.changes.inserts.map(\.markdownFragment) == ["# B2", "## B"], "premise")
        #expect(result.changes.inserts.allSatisfy { $0.carriedMetadata == nil && $0.carryMetadataFromId == nil })
        #expect(result.usedRemembered.isEmpty)
    }

    // MARK: - Machine-managed rows and section breaks

    private let notesBook = "# Chapter One\n\nBody paragraph with a reference[^1] here.\n\n# Notes\n\n[^1]: Original definition text."

    @Test("12. a removed Notes heading row is never listed for the memory")
    func removedNotesHeadingRowIsNotRemembered() throws {
        let rows = storedRows(notesBook)
        try #require(rows.map(\.isNotes) == [false, false, true, true], "premise: the Notes heading and its definition are flagged")
        let result = diff(notesBook, "# Chapter One\n\nBody paragraph with a reference[^1] here.")
        try #require(result.filtered.notesDeletes >= 1, "premise: the Notes rows are refused deletes, not deletes")
        #expect(result.removedHeadings.isEmpty)
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("12b. a remembered heading is not taken by a heading the parse flags as the Notes heading")
    func rememberedItemIsNotTakenByANotesHeading() throws {
        let newText = "# Chapter One\n\nBody paragraph with a reference[^1] here.\n\n## Notes\n\n[^1]: Original definition text."
        try #require(parse(newText).contains { $0.blockType == .heading && $0.isNotes }, "premise: the parse flags ## Notes as the Notes heading")
        let result = diff(
            "# Chapter One\n\nBody paragraph with a reference[^1] here.", newText,
            remembered: [item(1, "## Notes", level: 2, meta(.review, goal: 500))])
        try #require(result.changes.inserts.contains { $0.markdownFragment == "## Notes" }, "premise: the heading is an insert")
        #expect(result.changes.inserts.allSatisfy { $0.carriedMetadata == nil && $0.carryMetadataFromId == nil })
        #expect(result.usedRemembered.isEmpty)
    }

    // MARK: - Guards: a rename is never a move, whatever was deleted before

    @Test("14. delete the Chapter 3 line, then rename 4 to 3 and 5 to 4 in later saves: plain updates on their own rows, none takes the item")
    func renamesAfterADeleteKeepTheirOwnRows() throws {
        // Only the heading LINE of Chapter 3 goes: its paragraph c3 stays.
        let original = ["# Chapter 1", "c1", "# Chapter 2", "c2", "# Chapter 3", "c3", "# Chapter 4", "c4", "# Chapter 5", "c5"]
        let afterDelete = ["# Chapter 1", "c1", "# Chapter 2", "c2", "c3", "# Chapter 4", "c4", "# Chapter 5", "c5"]
        let deleted = diff(blocks(original), blocks(afterDelete))
        try #require(deleted.changes.deletes == ["r5"], "premise: the Chapter 3 heading row (r5) is the only row deleted")
        try #require(deleted.changes.inserts.isEmpty && deleted.changes.updates.isEmpty, "premise: nothing else changes")
        let remembered = [item(1, "# Chapter 3", level: 1, meta(.review, goal: 300))]

        // Save 2: the Chapter 4 line becomes "# Chapter 3". In the text after save 1 the rows are r1 to r9: Chapter 4 is r6, Chapter 5 is r8.
        let renamedFirst = ["# Chapter 1", "c1", "# Chapter 2", "c2", "c3", "# Chapter 3", "c4", "# Chapter 5", "c5"]
        let first = diff(blocks(afterDelete), blocks(renamedFirst), remembered: remembered)
        #expect(first.changes.updates.map(\.id) == ["r6"], "Chapter 4 own row is renamed in place")
        #expect(first.changes.updates.first?.markdownFragment == "# Chapter 3")
        #expect(first.changes.inserts.isEmpty && first.changes.deletes.isEmpty)
        #expect(first.usedRemembered.isEmpty, "the deleted Chapter 3 item is not given to a renamed heading")
        #expect(first.removedHeadings.isEmpty)

        // Save 3: the Chapter 5 line becomes "# Chapter 4" (row r8 of the text after save 2).
        let renamedSecond = ["# Chapter 1", "c1", "# Chapter 2", "c2", "c3", "# Chapter 3", "c4", "# Chapter 4", "c5"]
        let second = diff(blocks(renamedFirst), blocks(renamedSecond), remembered: remembered)
        #expect(second.changes.updates.map(\.id) == ["r8"], "Chapter 5 own row is renamed in place")
        #expect(second.changes.inserts.isEmpty && second.changes.deletes.isEmpty)
        #expect(second.usedRemembered.isEmpty)
        #expect(second.removedHeadings.isEmpty)
    }

    @Test("15. a heading renamed to a line no removed row and no remembered item has keeps its id")
    func renameToANewLineStillKeepsTheId() throws {
        let result = diff(blocks(["# A", "a1", "## A1", "x", "# B", "b1"]), blocks(["# A", "a1", "## Q", "x", "# B", "b1"]))
        #expect(result.changes.updates.map(\.id) == ["r3"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
        #expect(result.removedHeadings.isEmpty)
    }

    @Test("13. a section break moved to another place carries nothing (every break marker is the same line, so it cannot be matched)")
    func movedSectionBreakCarriesNothing() throws {
        let marker = BlockParser.sectionBreakMarker
        let old = blocks(["# A", "a1", marker, "b1", "# C", "c1"])
        let new = blocks(["# A", "a1", "b1", "# C", marker, "c1"])
        try #require(parse(old).contains { $0.blockType == .sectionBreak }, "premise: the parse makes a section-break block")
        let result = diff(old, new)
        try #require(result.changes.inserts.contains { $0.blockType == BlockType.sectionBreak.rawValue }, "premise: the break is an insert")
        #expect(result.changes.inserts.allSatisfy { $0.carriedMetadata == nil && $0.carryMetadataFromId == nil })
        #expect(result.removedHeadings.isEmpty, "a section-break row is never listed for the memory")
    }
}
