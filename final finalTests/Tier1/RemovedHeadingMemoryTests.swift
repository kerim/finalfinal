//
//  RemovedHeadingMemoryTests.swift
//  final finalTests
//
//  t-b097670d: the writer's memory of the headings it deleted (`RemovedHeadingMemory`), as a plain value: order, tokens, the cap, the
//  project it belongs to, and what a write that used an item takes out. No database, no writer.
//

import Foundation
import Testing
@testable import final_final

@Suite("RemovedHeadingMemory — Tier 1 (t-b097670d)", .serialized, .timeLimit(.minutes(1)))
struct RemovedHeadingMemoryTests {

    private func removal(_ title: String, goal: Int, sortOrder: Double = 1) -> RemovedHeadingMemory.Removal {
        RemovedHeadingMemory.Removal(
            key: MarkdownBlockDiff.Key(blockType: .heading, headingLevel: 1, markdownFragment: "# \(title)"),
            metadata: SectionMetadataCarry(
                status: .review, tags: nil, wordGoal: goal, goalType: .min, aggregateGoal: nil, aggregateGoalType: .approx),
            sortOrder: sortOrder)
    }

    @Test("recording keeps the order, gives growing tokens, and keeps the key, the fields and the place of each row")
    func recordKeepsOrderAndTokens() {
        var memory = RemovedHeadingMemory()
        memory.record([removal("A", goal: 1, sortOrder: 5), removal("B", goal: 2, sortOrder: 6)], projectId: "p1")
        memory.record([removal("A", goal: 3, sortOrder: 7)], projectId: "p1")
        #expect(memory.items.map(\.metadata.wordGoal) == [1, 2, 3], "oldest first")
        #expect(memory.items.map(\.token) == [1, 2, 3])
        #expect(memory.items.map(\.sortOrder) == [5, 6, 7])
        #expect(memory.items.first?.key == MarkdownBlockDiff.Key(blockType: .heading, headingLevel: 1, markdownFragment: "# A"))
        #expect(memory.projectId == "p1")
    }

    @Test("past 200 items the oldest are dropped first: recording 205 one at a time leaves 200, the first five gone")
    func capacityDropsOldestFirst() {
        var memory = RemovedHeadingMemory()
        for number in 1...205 { memory.record([removal("H\(number)", goal: number)], projectId: "p1") }
        #expect(memory.items.count == 200)
        #expect(memory.items.first?.metadata.wordGoal == 6, "items 1 to 5 were dropped")
        #expect(memory.items.last?.metadata.wordGoal == 205)
    }

    @Test("the cap never evicts items recorded by the same call: a select-all delete of 300 keeps all 300, and a later small call trims back to 200")
    func oneLargeRecordKeepsEveryItemOfThatCall() {
        var memory = RemovedHeadingMemory()
        memory.record((1...150).map { removal("A\($0)", goal: $0) }, projectId: "p1")
        memory.record((1...300).map { removal("B\($0)", goal: 1000 + $0) }, projectId: "p1")
        #expect(memory.items.count == 300, "all 300 of the second call, and none of the first 150")
        #expect(memory.items.first?.metadata.wordGoal == 1001)
        #expect(memory.items.last?.metadata.wordGoal == 1300)
        memory.record([removal("C", goal: 5000)], projectId: "p1")
        #expect(memory.items.count == 200, "a later call trims back to the cap")
        #expect(memory.items.last?.metadata.wordGoal == 5000, "the newest item is there")
        #expect(memory.items.first?.metadata.wordGoal == 1102, "the oldest 101 are gone")
    }

    @Test("assign: the most recent items of a line are taken, then handed out in the order the rows sat; items of another line are left alone")
    func assignTakesMostRecentPerKeyInDocumentOrder() {
        func key(_ title: String) -> MarkdownBlockDiff.Key {
            MarkdownBlockDiff.Key(blockType: .heading, headingLevel: 2, markdownFragment: "## \(title)")
        }
        func item(_ token: Int, _ title: String, goal: Int, sortOrder: Double) -> RemovedHeadingMemory.Item {
            RemovedHeadingMemory.Item(
                token: token, key: key(title),
                metadata: SectionMetadataCarry(
                    status: .review, tags: nil, wordGoal: goal, goalType: .min, aggregateGoal: nil, aggregateGoalType: .approx),
                sortOrder: sortOrder)
        }
        let items = [
            item(1, "S", goal: 100, sortOrder: 1), item(2, "S", goal: 200, sortOrder: 2), item(3, "S", goal: 300, sortOrder: 3),
            item(4, "T", goal: 400, sortOrder: 4)
        ]
        // Candidates given out of index order on purpose: the lower index is the earlier heading.
        let assigned = RemovedHeadingMemory.assign(candidates: [(7, key("S")), (3, key("S")), (5, key("U"))], items: items)
        #expect(assigned.keys.sorted() == [3, 7], "the heading with no remembered line (U) gets nothing; T is not asked for")
        #expect(assigned[3]?.metadata.wordGoal == 200, "tokens 2 and 3 are the two most recent; the first heading takes the earlier row")
        #expect(assigned[7]?.metadata.wordGoal == 300)
        #expect(assigned.values.map(\.token).sorted() == [2, 3])
        // By place, not by time: the later-recorded item of the two sat earlier.
        let swapped = [item(1, "S", goal: 100, sortOrder: 20), item(2, "S", goal: 200, sortOrder: 10)]
        let byPlace = RemovedHeadingMemory.assign(candidates: [(1, key("S")), (2, key("S"))], items: swapped)
        #expect(byPlace[1]?.metadata.wordGoal == 200)
        #expect(byPlace[2]?.metadata.wordGoal == 100)
        #expect(RemovedHeadingMemory.assign(candidates: [], items: items).isEmpty)
        #expect(RemovedHeadingMemory.assign(candidates: [(1, key("S"))], items: []).isEmpty)
    }

    @Test("recording for another project clears the first project's items before it adds its own")
    func recordingForAnotherProjectClearsFirst() {
        var memory = RemovedHeadingMemory()
        memory.record([removal("A", goal: 1), removal("B", goal: 2)], projectId: "p1")
        memory.record([removal("C", goal: 3)], projectId: "p2")
        #expect(memory.projectId == "p2")
        #expect(memory.items.map(\.metadata.wordGoal) == [3])
        // An empty record changes nothing, whatever the project.
        memory.record([], projectId: "p3")
        #expect(memory.projectId == "p2")
        #expect(memory.items.count == 1)
    }

    @Test("consuming takes out only the items with those tokens")
    func consumeRemovesOnlyThoseTokens() {
        var memory = RemovedHeadingMemory()
        memory.record([removal("A", goal: 1), removal("B", goal: 2), removal("C", goal: 3)], projectId: "p1")
        memory.consume(tokens: [1, 3])
        #expect(memory.items.map(\.metadata.wordGoal) == [2])
        memory.consume(tokens: [99])
        #expect(memory.items.count == 1, "an unknown token takes nothing out")
        memory.consume(tokens: [])
        #expect(memory.items.count == 1)
        // Tokens keep growing after items left, so a token never names two items.
        memory.record([removal("D", goal: 4)], projectId: "p1")
        #expect(memory.items.map(\.token) == [2, 4])
    }

    @Test("forgetting empties it and drops the project")
    func forgetEmptiesIt() {
        var memory = RemovedHeadingMemory()
        memory.record([removal("A", goal: 1)], projectId: "p1")
        memory.forget()
        #expect(memory.items.isEmpty)
        #expect(memory.projectId == nil)
        #expect(memory.items(for: "p1").isEmpty)
    }

    @Test("the items for another project are empty; for the project they belong to, all of them")
    func itemsForAnotherProjectAreEmpty() {
        var memory = RemovedHeadingMemory()
        memory.record([removal("A", goal: 1), removal("B", goal: 2)], projectId: "p1")
        #expect(memory.items(for: "p1").count == 2)
        #expect(memory.items(for: "p2").isEmpty)
        #expect(RemovedHeadingMemory().items(for: "p1").isEmpty, "a new memory belongs to no project")
    }
}
