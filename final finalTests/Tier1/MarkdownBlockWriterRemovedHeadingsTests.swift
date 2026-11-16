//
//  MarkdownBlockWriterRemovedHeadingsTests.swift
//  final finalTests
//
//  t-b097670d: the writer's bookkeeping of the memory of deleted headings (`MarkdownBlockWriter.updateRemovedHeadings`), on a bare writer
//  with the diff's `Result` and the database's `EditorApplyResult` built by hand: which remembered items a write uses up, and which
//  deleted headings it remembers. No database, no editor.
//

import Foundation
import Testing
@testable import final_final

@Suite("Writer memory bookkeeping — Tier 1 (t-b097670d)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownBlockWriterRemovedHeadingsTests {

    private static let pid = "p-md-writer-memory"

    private func headingKey(_ fragment: String, level: Int = 1) -> MarkdownBlockDiff.Key {
        MarkdownBlockDiff.Key(blockType: .heading, headingLevel: level, markdownFragment: fragment)
    }

    private func carry(_ status: SectionStatus, goal: Int) -> SectionMetadataCarry {
        SectionMetadataCarry(status: status, tags: nil, wordGoal: goal, goalType: .min, aggregateGoal: nil, aggregateGoalType: .approx)
    }

    private func removal(_ fragment: String, goal: Int) -> RemovedHeadingMemory.Removal {
        RemovedHeadingMemory.Removal(key: headingKey(fragment, level: 2), metadata: carry(.review, goal: goal), sortOrder: Double(goal))
    }

    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: Self.pid, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    private func storedRows(_ markdown: String) -> [Block] {
        var blocks = parse(markdown)
        for index in blocks.indices {
            blocks[index].id = "r\(index + 1)"
            blocks[index].sortOrder = Double(index + 1)
        }
        return blocks
    }

    /// A diff result that names the temp ids and tokens given, and nothing else.
    private func result(used: [(String, Int)] = [], removed: [MarkdownBlockDiff.RemovedHeadingRef] = []) -> MarkdownBlockDiff.Result {
        MarkdownBlockDiff.Result(
            changes: BlockChanges(), entries: [], filtered: MarkdownBlockDiff.Filtered(), unaddressable: 0,
            removedHeadings: removed, usedRemembered: used.map { MarkdownBlockDiff.UsedRemembered(tempId: $0.0, token: $0.1) })
    }

    @Test("T1. only the remembered items whose insert the write minted are used up; an insert that was not minted keeps its item for the retry")
    func onlyMintedInsertsConsumeTheirItems() {
        let writer = MarkdownBlockWriter()
        writer.removedHeadings.record([removal("## S", goal: 100), removal("## S", goal: 200)], projectId: Self.pid)
        #expect(writer.removedHeadings.items.map(\.token) == [1, 2], "premise: two remembered items")
        var applied = EditorApplyResult()
        applied.idMapping = ["temp-md-1": "row-x"]   // the second insert was refused: no mapping for it

        writer.updateRemovedHeadings(
            from: result(used: [("temp-md-1", 1), ("temp-md-2", 2)]), projectId: Self.pid, applied: applied)

        #expect(writer.removedHeadings.items.map(\.token) == [2], "only the item of the minted insert is gone")
    }

    @Test("T3. a deleted heading whose same-save carrying insert was NOT minted is remembered; one whose insert was minted is not")
    func sameSaveSourceWhoseInsertWasNotMintedIsRemembered() throws {
        let old = "# A\n\na1\n\na2\n\n# B\n\nb1\n\n# C\n\nc1"
        let new = "a1\n\na2\n\n# B\n\nb1\n\n# A\n\n# C\n\nc1"
        var counter = 0
        let diff = MarkdownBlockDiff.diff(rows: storedRows(old), new: parse(new), makeTempId: {
            counter += 1
            return "temp-md-\(counter)"
        })
        let expected = MarkdownBlockDiff.RemovedHeadingRef(id: "r1", key: headingKey("# A"), carriedByTempId: "temp-md-1")
        try #require(diff.removedHeadings == [expected], "premise: r1 is deleted and the insert temp-md-1 takes its fields")
        var deleted = EditorApplyResult()
        deleted.deletedHeadings = ["r1": DeletedHeadingRecord(metadata: carry(.review, goal: 500), sortOrder: 1)]

        // The insert was not minted (refused for a stale anchor, say): the fields would be lost, so the row is remembered.
        let refused = MarkdownBlockWriter()
        refused.updateRemovedHeadings(from: diff, projectId: Self.pid, applied: deleted)
        #expect(refused.removedHeadings.items.map(\.key) == [headingKey("# A")])
        #expect(refused.removedHeadings.items.map(\.metadata) == [carry(.review, goal: 500)])

        // The insert was minted: the new row already has the fields, so nothing is remembered.
        let minted = MarkdownBlockWriter()
        var landed = deleted
        landed.idMapping = ["temp-md-1": "n1"]
        minted.updateRemovedHeadings(from: diff, projectId: Self.pid, applied: landed)
        #expect(minted.removedHeadings.items.isEmpty)
    }

    @Test("T3b. an ordinary delete (no insert takes it) is remembered with its fields and place; one the database did not delete is not")
    func ordinaryDeleteIsRememberedAsBefore() {
        let writer = MarkdownBlockWriter()
        let plain = result(removed: [
            MarkdownBlockDiff.RemovedHeadingRef(id: "r3", key: headingKey("# B"), carriedByTempId: nil),
            MarkdownBlockDiff.RemovedHeadingRef(id: "r9", key: headingKey("# Z"), carriedByTempId: nil)
        ])
        var applied = EditorApplyResult()
        applied.deletedHeadings = ["r3": DeletedHeadingRecord(metadata: carry(.writing, goal: 800), sortOrder: 3)]   // r9: delete dropped

        writer.updateRemovedHeadings(from: plain, projectId: Self.pid, applied: applied)

        #expect(writer.removedHeadings.items.count == 1)
        #expect(writer.removedHeadings.items.first?.key == headingKey("# B"))
        #expect(writer.removedHeadings.items.first?.metadata == carry(.writing, goal: 800))
        #expect(writer.removedHeadings.items.first?.sortOrder == 3)
        #expect(writer.removedHeadings.projectId == Self.pid)
    }

    @Test("a zoomed save's carry uses up the items its headings took and remembers the rows it deleted")
    func zoomedCarryIsRecorded() {
        let writer = MarkdownBlockWriter()
        writer.removedHeadings.record([removal("## S", goal: 100), removal("## T", goal: 200)], projectId: Self.pid)

        writer.recordZoomedHeadingCarry(
            ZoomedHeadingCarry(removed: [removal("## U", goal: 300)], usedTokens: [1]), projectId: Self.pid)

        #expect(writer.removedHeadings.items.map(\.key) == [headingKey("## T", level: 2), headingKey("## U", level: 2)])
        #expect(writer.removedHeadings.items.map(\.token) == [2, 3])
    }
}
