//
//  MarkdownMovedHeadingMetadataTests.swift
//  final finalTests
//
//  t-b097670d: in Markdown mode a heading that is cut and pasted, dragged with selected text inside the editor, or deleted and brought
//  back with Cmd-Z keeps its status, tags and goals (the six fields `SectionMetadataCarry` holds). The whole path, through the REAL
//  writer and the REAL database
//  (`MarkdownWriterRig`; the rig fires the way the debounce does, one `fireAndSettle` per save): the pairing (`MarkdownBlockDiff`),
//  the writer's memory of deleted headings (`RemovedHeadingMemory`, kept across saves), and the copy inside the write transaction
//  (`applyBlockChangesFromEditor`, `processEditorInserts`).
//
//  A cut, a click and a paste usually fall in TWO saves (the save runs about a second after the last keystroke), and a deleted line that
//  was saved and then undone always does; the tests that cross saves are the ones that matter. Nothing here sleeps.
//
//  Base book: `# Alpha / a1 / a2 / # Beta / b1 / # Gamma / g1`, Alpha and Beta given all six fields, Gamma three of them.
//

import Foundation
import GRDB
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown moved heading keeps its metadata — Tier 2 (t-b097670d)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct MarkdownMovedHeadingMetadataTests {

    // MARK: - The book and its fields

    private static let base = "# Alpha\n\na1\n\na2\n\n# Beta\n\nb1\n\n# Gamma\n\ng1"
    /// Alpha cut out of `base`, and put back before Gamma.
    private static let withoutAlpha = "a1\n\na2\n\n# Beta\n\nb1\n\n# Gamma\n\ng1"
    private static let moved = "a1\n\na2\n\n# Beta\n\nb1\n\n# Alpha\n\n# Gamma\n\ng1"
    /// Beta's line deleted, its paragraph left.
    private static let withoutBeta = "# Alpha\n\na1\n\na2\n\nb1\n\n# Gamma\n\ng1"

    private static let alphaSix = SectionMetadataCarry(
        status: .review, tags: ["kept"], wordGoal: 500, goalType: .min, aggregateGoal: 3000, aggregateGoalType: .max)
    private static let betaSix = SectionMetadataCarry(
        status: .writing, tags: ["b"], wordGoal: 800, goalType: .max, aggregateGoal: 4000, aggregateGoalType: .min)
    private static let gammaSix = SectionMetadataCarry(
        status: .final_, tags: ["g", "last"], wordGoal: 900, goalType: .approx, aggregateGoal: nil, aggregateGoalType: .approx)

    /// A rig over `base` with the six fields of Alpha, Beta and Gamma stored (written straight to the database, as the sidebar does).
    private func makeRig() throws -> MarkdownWriterRig {
        let rig = try MarkdownWriterRig(content: Self.base)
        try setSix(Self.alphaSix, rig, heading: "Alpha")
        try setSix(Self.betaSix, rig, heading: "Beta")
        try setSix(Self.gammaSix, rig, heading: "Gamma")
        return rig
    }

    /// Writes all six fields onto the `occurrence`-th heading (in document order) whose text is `title`. The rig's own `setMetadata` sets three.
    private func setSix(_ six: SectionMetadataCarry, _ rig: MarkdownWriterRig, heading title: String, occurrence: Int = 0) throws {
        let pid = rig.pid
        try rig.db.write { database in
            let headings = try Block.filter(Block.Columns.projectId == pid)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.textContent == title)
                .order(Block.Columns.sortOrder).fetchAll(database)
            guard occurrence < headings.count else {
                Issue.record("premise: no heading \"\(title)\" number \(occurrence)")
                return
            }
            var heading = headings[occurrence]
            six.apply(to: &heading)
            try heading.update(database)
        }
    }

    /// Every field the carry holds, one expectation each, so a failure names the field that was lost.
    private func expectSix(
        _ row: Block?, _ six: SectionMetadataCarry, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let row else {
            Issue.record("no heading row for \(label)", sourceLocation: sourceLocation)
            return
        }
        #expect(row.status == six.status, "\(label): status", sourceLocation: sourceLocation)
        #expect(row.tags == six.tags, "\(label): tags", sourceLocation: sourceLocation)
        #expect(row.wordGoal == six.wordGoal, "\(label): wordGoal", sourceLocation: sourceLocation)
        #expect(row.goalType == six.goalType, "\(label): goalType", sourceLocation: sourceLocation)
        #expect(row.aggregateGoal == six.aggregateGoal, "\(label): aggregateGoal", sourceLocation: sourceLocation)
        #expect(row.aggregateGoalType == six.aggregateGoalType, "\(label): aggregateGoalType", sourceLocation: sourceLocation)
    }

    /// The headings with this text, in document order.
    private func headings(_ rig: MarkdownWriterRig, _ title: String) throws -> [Block] {
        try rig.rows().filter { $0.blockType == .heading && $0.textContent == title }
    }

    // MARK: - 1. In one save

    @Test("1. a heading moved in ONE save (selected text dragged inside the editor, or a cut and a paste in one pause): all six fields, old row gone")
    func movedInOneSaveKeepsAllSix() async throws {
        let rig = try makeRig()
        let oldAlpha = try #require(try rig.heading("Alpha"))
        try #require(oldAlpha.status == Self.alphaSix.status, "premise: the fields are stored")

        #expect(await rig.fireAndSettle(Self.moved) == .started)

        #expect(try rig.storedText() == Self.moved)
        #expect(try !rig.rows().contains { $0.id == oldAlpha.id }, "the old row was deleted")
        let alpha = try #require(try rig.heading("Alpha"), "the moved heading is stored")
        try #require(alpha.id != oldAlpha.id, "the moved heading is a new row")
        expectSix(alpha, Self.alphaSix, "Alpha")
        expectSix(try rig.heading("Beta"), Self.betaSix, "Beta")
        expectSix(try rig.heading("Gamma"), Self.gammaSix, "Gamma")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty, "the fields went straight to the moved row: nothing is remembered")
    }

    // MARK: - 2. Across two saves

    @Test("2. a cut saved on its own, then a paste in the next save: the pasted heading has all six fields, and the memory is used up")
    func cutInOneSavePastedInTheNextKeepsAllSix() async throws {
        let rig = try makeRig()

        #expect(await rig.fireAndSettle(Self.withoutAlpha) == .started)
        try #require(try rig.heading("Alpha") == nil, "premise: the cut was saved, the heading row is gone")
        #expect(rig.markdownWriter.removedHeadings.items.map(\.metadata) == [Self.alphaSix], "the cut heading's fields are remembered")

        #expect(await rig.fireAndSettle(Self.moved) == .started)

        #expect(try rig.storedText() == Self.moved)
        expectSix(try rig.heading("Alpha"), Self.alphaSix, "Alpha")
        expectSix(try rig.heading("Beta"), Self.betaSix, "Beta")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty, "the item was used by the write that minted the heading")
    }

    @Test("3. a heading deleted, the delete saved, then Cmd-Z (the old text comes back in a later save): the heading has all six fields of its own")
    func deletedThenUndoneInALaterSaveKeepsAllSix() async throws {
        let rig = try makeRig()

        #expect(await rig.fireAndSettle(Self.withoutBeta) == .started)
        try #require(try rig.heading("Beta") == nil, "premise: the delete was saved")

        #expect(await rig.fireAndSettle(Self.base) == .started, "what Cmd-Z gives")

        #expect(try rig.storedText() == Self.base)
        expectSix(try rig.heading("Beta"), Self.betaSix, "Beta")
        expectSix(try rig.heading("Alpha"), Self.alphaSix, "Alpha")
        expectSix(try rig.heading("Gamma"), Self.gammaSix, "Gamma")
    }

    // MARK: - 4. Two headings with the same line

    private static let twoScenes = "# A\n\n## Scene\n\ns1\n\n## Scene\n\ns2\n\n# B\n\nb1"
    private static let sceneOneSix = SectionMetadataCarry(
        status: .writing, tags: ["one"], wordGoal: 100, goalType: .min, aggregateGoal: 1000, aggregateGoalType: .max)
    private static let sceneTwoSix = SectionMetadataCarry(
        status: .waiting, tags: ["two"], wordGoal: 200, goalType: .max, aggregateGoal: 2000, aggregateGoalType: .min)
    private static let withoutFirstScene = "# A\n\ns1\n\n## Scene\n\ns2\n\n# B\n\nb1"
    private static let withoutSecondScene = "# A\n\n## Scene\n\ns1\n\ns2\n\n# B\n\nb1"
    private static let withoutEitherScene = "# A\n\ns1\n\ns2\n\n# B\n\nb1"

    private func makeSceneRig() throws -> MarkdownWriterRig {
        let rig = try MarkdownWriterRig(content: Self.twoScenes)
        try setSix(Self.sceneOneSix, rig, heading: "Scene", occurrence: 0)
        try setSix(Self.sceneTwoSix, rig, heading: "Scene", occurrence: 1)
        return rig
    }

    private func expectScenesBack(_ rig: MarkdownWriterRig) throws {
        #expect(try rig.storedText() == Self.twoScenes)
        let scenes = try headings(rig, "Scene")
        try #require(scenes.count == 2, "premise: both headings are back")
        expectSix(scenes[0], Self.sceneOneSix, "the first Scene")
        expectSix(scenes[1], Self.sceneTwoSix, "the second Scene")
    }

    @Test("4. two headings with the same line, removed in two saves (first one, then the other) and put back together: each has its own fields")
    func twoEqualTitlesRemovedAcrossSavesGetTheirOwn() async throws {
        let rig = try makeSceneRig()

        #expect(await rig.fireAndSettle(Self.withoutFirstScene) == .started)
        try #require(try headings(rig, "Scene").count == 1, "premise: one Scene is left")
        try #require(try headings(rig, "Scene").first?.status == Self.sceneTwoSix.status, "premise: the first one was the one removed")
        #expect(await rig.fireAndSettle(Self.withoutEitherScene) == .started)
        try #require(try headings(rig, "Scene").isEmpty, "premise: both are gone")
        #expect(rig.markdownWriter.removedHeadings.items.count == 2)

        #expect(await rig.fireAndSettle(Self.twoScenes) == .started, "both come back in one save")

        try expectScenesBack(rig)
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    @Test("4b. the LATER of two equal headings removed first, then the earlier, and both put back in one save: still each its own fields")
    func twoEqualTitlesRemovedLaterOneFirstAndPutBackTogetherGetTheirOwn() async throws {
        let rig = try makeSceneRig()

        #expect(await rig.fireAndSettle(Self.withoutSecondScene) == .started)
        try #require(try headings(rig, "Scene").first?.status == Self.sceneOneSix.status, "premise: the second one was the one removed")
        #expect(await rig.fireAndSettle(Self.withoutEitherScene) == .started)
        try #require(try headings(rig, "Scene").isEmpty, "premise: both are gone")
        let remembered = rig.markdownWriter.removedHeadings.items
        try #require(remembered.map(\.metadata) == [Self.sceneTwoSix, Self.sceneOneSix], "premise: recorded in the order they were deleted")
        try #require(remembered[0].sortOrder > remembered[1].sortOrder, "premise: the first one deleted sat LATER in the document")

        #expect(await rig.fireAndSettle(Self.twoScenes) == .started, "both come back in one save (two quick Cmd-Z)")

        try expectScenesBack(rig)
    }

    // MARK: - 5. Not the same line

    @Test("5. a heading with another title takes nothing and leaves the item; a later heading with the removed title takes it")
    func differentTitleTakesNothingAndLeavesTheMemory() async throws {
        let rig = try makeRig()
        #expect(await rig.fireAndSettle(Self.withoutBeta) == .started)
        try #require(rig.markdownWriter.removedHeadings.items.count == 1, "premise: Beta's fields are remembered")

        let revised = Self.withoutBeta.replacingOccurrences(of: "\n\n# Gamma", with: "\n\n# Beta revised\n\n# Gamma")
        #expect(await rig.fireAndSettle(revised) == .started)
        let other = try #require(try rig.heading("Beta revised"))
        #expect(other.status == nil, "a different title takes no status")
        #expect(other.tags == nil)
        #expect(other.wordGoal == nil)
        #expect(other.aggregateGoal == nil)
        #expect(other.goalType == .approx)
        #expect(other.aggregateGoalType == .approx)
        #expect(rig.markdownWriter.removedHeadings.items.count == 1, "the item was not used up by the wrong title")

        #expect(await rig.fireAndSettle(revised + "\n\n# Beta") == .started)
        expectSix(try rig.heading("Beta"), Self.betaSix, "Beta, typed at the end")
        #expect(try rig.heading("Beta revised")?.status == nil, "and the other heading still has nothing")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    @Test("6. a heading really deleted loses nothing else: the other headings keep their six, and no row has the deleted heading's status")
    func reallyDeletedHeadingLosesNothingElse() async throws {
        let rig = try makeRig()

        #expect(await rig.fireAndSettle(Self.withoutBeta) == .started)

        #expect(try rig.storedText() == Self.withoutBeta)
        expectSix(try rig.heading("Alpha"), Self.alphaSix, "Alpha")
        expectSix(try rig.heading("Gamma"), Self.gammaSix, "Gamma")
        #expect(try rig.rows().allSatisfy { $0.status != Self.betaSix.status }, "Beta's status is on no row")
    }

    // MARK: - 7. How long the memory lives

    @Test("7. a zoom or a mode switch (`reset`) keeps the memory; closing or switching the project forgets it")
    func zoomOrModeResetKeepsTheMemoryButProjectResetForgetsIt() async throws {
        let rig = try makeRig()
        #expect(await rig.fireAndSettle(Self.withoutBeta) == .started)
        try #require(rig.markdownWriter.removedHeadings.items.count == 1, "premise")

        rig.markdownWriter.reset()
        #expect(rig.markdownWriter.removedHeadings.items(for: rig.pid).count == 1, "the same document: still remembered")

        rig.editorState.resetForProjectSwitch()
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
        #expect(rig.markdownWriter.removedHeadings.projectId == nil)
    }

    // MARK: - 8. A write that does not land

    private func isParked(_ event: WriterEvent) -> Bool {
        if case .parked = event { return true }
        return false
    }

    @Test("8. a write refused for a stale epoch keeps the item; the retry carries it")
    func failedWriteKeepsTheItem() async throws {
        let rig = try makeRig()
        #expect(await rig.fireAndSettle(Self.withoutBeta) == .started)
        let remembered = try #require(rig.markdownWriter.removedHeadings.items.first)

        // Save 2 (Beta typed back) waits behind a held sequence; a direct write bumps the epoch before it applies.
        let held = rig.hold()
        let parkedBefore = rig.events.all.filter(isParked).count
        #expect(rig.fire(Self.base) == .started)
        var parkedSeen = false
        for _ in 0..<500 {   // bounded: 10 ms steps, 5 s at most
            if rig.events.all.filter(isParked).count > parkedBefore {
                parkedSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(parkedSeen, "the save never parked behind the held sequence within 5 s")
        try rig.db.bumpBlockWriteEpoch(projectId: rig.pid)
        await rig.release(held)
        await rig.settle()

        #expect(rig.ledger.markdownStaleEpochRejections == 1, "premise: the batch was refused whole")
        #expect(try rig.heading("Beta") == nil, "premise: the insert was not written")
        #expect(rig.markdownWriter.removedHeadings.items == [remembered], "the item is still remembered, with its own token")

        #expect(await rig.fireAndSettle(Self.base) == .started, "the retry")
        #expect(try rig.storedText() == Self.base)
        expectSix(try rig.heading("Beta"), Self.betaSix, "Beta, after the retry")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

}

// The rest of the suite, in an extension so the struct body stays under the type-body-length limit (it uses the helpers above).
extension MarkdownMovedHeadingMetadataTests {

    // MARK: - 11. A rename is never a move

    private func chapterBook(_ chapters: [(number: Int, body: String)]) -> String {
        chapters.map { "# Chapter \($0.number)\n\n\($0.body)" }.joined(separator: "\n\n")
    }

    @Test("11. delete Chapter 3, then rename 4 to 3 and 5 to 4 in separate saves: each section keeps its OWN six fields")
    func renamedChaptersAfterADeleteKeepTheirOwnSix() async throws {
        let rig = try MarkdownWriterRig(content: chapterBook([(1, "c1"), (2, "c2"), (3, "c3"), (4, "c4"), (5, "c5")]))
        let sixes = [
            "Chapter 3": SectionMetadataCarry(
                status: .review, tags: ["three"], wordGoal: 300, goalType: .min, aggregateGoal: 3000, aggregateGoalType: .max),
            "Chapter 4": SectionMetadataCarry(
                status: .writing, tags: ["four"], wordGoal: 400, goalType: .max, aggregateGoal: 4000, aggregateGoalType: .min),
            "Chapter 5": SectionMetadataCarry(
                status: .waiting, tags: ["five"], wordGoal: 500, goalType: .approx, aggregateGoal: 5000, aggregateGoalType: .approx)
        ]
        for (title, six) in sixes { try setSix(six, rig, heading: title) }
        let fourId = try #require(try rig.heading("Chapter 4")).id
        let fiveId = try #require(try rig.heading("Chapter 5")).id

        let deleted = chapterBook([(1, "c1"), (2, "c2"), (4, "c4"), (5, "c5")])
        let renamedFour = chapterBook([(1, "c1"), (2, "c2"), (3, "c4"), (5, "c5")])
        let renamedFive = chapterBook([(1, "c1"), (2, "c2"), (3, "c4"), (4, "c5")])
        #expect(await rig.fireAndSettle(deleted) == .started, "Chapter 3 deleted")
        #expect(await rig.fireAndSettle(renamedFour) == .started, "Chapter 4 renamed to Chapter 3")
        #expect(await rig.fireAndSettle(renamedFive) == .started, "Chapter 5 renamed to Chapter 4")

        let three = try #require(try rig.heading("Chapter 3"))
        let four = try #require(try rig.heading("Chapter 4"))
        #expect(three.id == fourId, "the renamed heading is the same row")
        #expect(four.id == fiveId, "the renamed heading is the same row")
        expectSix(three, try #require(sixes["Chapter 4"]), "the section now called Chapter 3 (it was Chapter 4)")
        expectSix(four, try #require(sixes["Chapter 5"]), "the section now called Chapter 4 (it was Chapter 5)")
        #expect(try rig.rows().allSatisfy { $0.status != .review }, "the deleted Chapter 3 status is on no row")
    }

    // MARK: - 12. A select-all delete of many headings

    @Test("12. select all and delete in a book of 210 headings, then Cmd-Z: every heading gets back its OWN word goal (the memory keeps all 210)")
    func selectAllDeleteThenUndoKeepsEveryHeading() async throws {
        let base = (1...210).map { "# Heading \($0)\n\nBody \($0)." }.joined(separator: "\n\n")
        let rig = try MarkdownWriterRig(content: base)
        let pid = rig.pid
        try rig.db.write { database in
            let headings = try Block.filter(Block.Columns.projectId == pid)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder).fetchAll(database)
            for (offset, var heading) in headings.enumerated() {
                heading.wordGoal = 1000 + offset + 1
                try heading.update(database)
            }
        }
        try #require(try headings(rig, "Heading 210").first?.wordGoal == 1210, "premise: the goals are stored")

        #expect(await rig.fireAndSettle("") == .started, "select all, delete")
        try #require(try rig.rows().isEmpty, "premise: everything was deleted")
        #expect(rig.markdownWriter.removedHeadings.items.count == 210, "the cap does not evict the headings of the same delete")

        #expect(await rig.fireAndSettle(base) == .started, "Cmd-Z")

        #expect(try rig.storedText() == base)
        let back = try rig.rows().filter { $0.blockType == .heading }
        try #require(back.count == 210, "premise: all 210 headings are back")
        for number in 1...210 {
            let heading = back.first { $0.textContent == "Heading \(number)" }
            #expect(heading?.wordGoal == 1000 + number, "Heading \(number): wordGoal")
        }
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    // MARK: - 9. The copy in the database

    private func carryInsert(from rowId: String, after anchorId: String, carried: SectionMetadataCarry? = nil) -> BlockInsert {
        BlockInsert(
            tempId: "temp-carry-1", blockType: "heading", textContent: "Alpha", markdownFragment: "# Alpha", headingLevel: 1,
            afterBlockId: anchorId, carryMetadataFromId: rowId, carriedMetadata: carried)
    }

    @Test("9. an insert that names a heading row the batch does NOT delete copies nothing: that row still exists and keeps its own fields")
    func carryFromARowNotDeletedInTheBatchCopiesNothing() throws {
        let rig = try makeRig()
        let alpha = try #require(try rig.heading("Alpha"))
        let anchor = try #require(try rig.rows().last)

        let result = try rig.db.applyBlockChangesFromEditor(
            BlockChanges(inserts: [carryInsert(from: alpha.id, after: anchor.id)]), for: rig.pid, stamp: .unguarded)

        let newId = try #require(result.idMapping["temp-carry-1"], "premise: the heading was inserted")
        let rows = try rig.rows()
        let inserted = try #require(rows.first { $0.id == newId })
        #expect(inserted.status == nil, "no fields were copied: the named row was not deleted")
        #expect(inserted.tags == nil)
        #expect(inserted.wordGoal == nil)
        #expect(inserted.aggregateGoal == nil)
        expectSix(rows.first { $0.id == alpha.id }, Self.alphaSix, "the original Alpha")
        #expect(result.deletedHeadings.isEmpty)
    }

    @Test("9b. the same insert with the delete of that row in the SAME batch copies all six, and the result names the deleted heading and its place")
    func carryFromARowDeletedInTheSameBatchCopiesAllSix() throws {
        let rig = try makeRig()
        let alpha = try #require(try rig.heading("Alpha"))
        let anchor = try #require(try rig.rows().last)

        let result = try rig.db.applyBlockChangesFromEditor(
            BlockChanges(inserts: [carryInsert(from: alpha.id, after: anchor.id)], deletes: [alpha.id]),
            for: rig.pid, stamp: .unguarded)

        let newId = try #require(result.idMapping["temp-carry-1"], "premise: the heading was inserted")
        let rows = try rig.rows()
        expectSix(rows.first { $0.id == newId }, Self.alphaSix, "the new Alpha")
        #expect(try !rows.contains { $0.id == alpha.id }, "the old row was deleted")
        #expect(result.deletedHeadings[alpha.id] == DeletedHeadingRecord(metadata: Self.alphaSix, sortOrder: alpha.sortOrder))
        #expect(result.deletedHeadings.count == 1)
    }

    @Test("9c. fields carried by value are copied onto the new heading, and onto nothing that is not a heading")
    func carriedFieldsAreCopiedOntoTheNewHeadingOnly() throws {
        let rig = try makeRig()
        let anchor = try #require(try rig.rows().last)
        let paragraph = BlockInsert(
            tempId: "temp-carry-2", blockType: "paragraph", textContent: "p", markdownFragment: "p", headingLevel: nil,
            afterBlockId: anchor.id, carriedMetadata: Self.betaSix)

        let result = try rig.db.applyBlockChangesFromEditor(
            BlockChanges(inserts: [carryInsert(from: "not-a-row", after: anchor.id, carried: Self.betaSix), paragraph]),
            for: rig.pid, stamp: .unguarded)

        let rows = try rig.rows()
        expectSix(rows.first { $0.id == result.idMapping["temp-carry-1"] }, Self.betaSix, "the heading")
        let inserted = try #require(rows.first { $0.id == result.idMapping["temp-carry-2"] })
        #expect(inserted.status == nil && inserted.wordGoal == nil, "a paragraph takes no section metadata")
    }

    // MARK: - 10. The wire

    @Test("10. an insert as Rich Text sends it (no carry fields) decodes with both nil; one with the fields round-trips")
    func insertJSONWithoutTheNewFieldsDecodes() throws {
        let json = ##"{"tempId":"temp-1","blockType":"heading","textContent":"A","markdownFragment":"# A","headingLevel":1,"afterBlockId":"x"}"##
        let insert = try JSONDecoder().decode(BlockInsert.self, from: Data(json.utf8))
        #expect(insert.carryMetadataFromId == nil)
        #expect(insert.carriedMetadata == nil)
        #expect(insert.afterBlockId == "x")
        #expect(insert.atDocumentStart == nil)

        let carried = BlockInsert(
            tempId: "temp-2", blockType: "heading", textContent: "B", markdownFragment: "# B", headingLevel: 1, afterBlockId: nil,
            atDocumentStart: true, carryMetadataFromId: "r1", carriedMetadata: SectionMetadataCarry(
                status: .final_, tags: ["x"], wordGoal: 5, goalType: .max, aggregateGoal: 50, aggregateGoalType: .min))
        let back = try JSONDecoder().decode(BlockInsert.self, from: JSONEncoder().encode(carried))
        #expect(back.carryMetadataFromId == "r1")
        #expect(back.carriedMetadata == carried.carriedMetadata)
        let moved = carried.reanchored(afterBlockId: "y", atDocumentStart: nil)
        #expect(moved.afterBlockId == "y" && moved.atDocumentStart == nil)
        #expect(moved.carryMetadataFromId == "r1" && moved.carriedMetadata == carried.carriedMetadata, "re-anchoring keeps the carry fields")
    }
}
