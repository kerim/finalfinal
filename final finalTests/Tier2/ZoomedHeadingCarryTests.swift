//
//  ZoomedHeadingCarryTests.swift
//  final finalTests
//
//  t-b097670d: the ZOOMED Markdown save shares the writer's memory of deleted headings. A sub-heading cut and pasted, or deleted and
//  brought back with Cmd-Z, while a chapter is zoomed keeps its status, tags and goals; and because it is one memory per open project,
//  a heading cut unzoomed can be pasted zoomed and the other way round. The zoomed save is `EditorViewState.applyZoomedRangeWrite`
//  (the body the queued zoomed write and the direct flush both run), over the real database; the unzoomed save is the real
//  per-block writer (`MarkdownWriterRig.fireAndSettle`). Nothing here sleeps.
//
//  Book: `# Ch1 / ## S1 / s1 / ## S2 / s2 / # Ch2 / c2`, all six fields on S1 and S2, Ch1 zoomed.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Zoomed heading carry — Tier 2 (t-b097670d)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ZoomedHeadingCarryTests {

    // MARK: - The book

    private static let full = "# Ch1\n\n## S1\n\ns1\n\n## S2\n\ns2\n\n# Ch2\n\nc2"
    /// What the editor shows when Ch1 is zoomed.
    private static let zoomedFull = "# Ch1\n\n## S1\n\ns1\n\n## S2\n\ns2"
    private static let zoomedWithoutS1 = "# Ch1\n\ns1\n\n## S2\n\ns2"
    private static let zoomedS1AfterS2 = "# Ch1\n\ns1\n\n## S2\n\ns2\n\n## S1"
    private static let fullWithoutS1 = "# Ch1\n\ns1\n\n## S2\n\ns2\n\n# Ch2\n\nc2"

    private static let s1Six = SectionMetadataCarry(
        status: .review, tags: ["one"], wordGoal: 250, goalType: .min, aggregateGoal: 2500, aggregateGoalType: .max)
    private static let s2Six = SectionMetadataCarry(
        status: .writing, tags: ["two", "b"], wordGoal: 400, goalType: .max, aggregateGoal: 4000, aggregateGoalType: .min)

    private func makeRig() throws -> MarkdownWriterRig {
        let rig = try MarkdownWriterRig(content: Self.full)
        try setSix(Self.s1Six, rig, heading: "S1")
        try setSix(Self.s2Six, rig, heading: "S2")
        return rig
    }

    private func setSix(_ six: SectionMetadataCarry, _ rig: MarkdownWriterRig, heading title: String) throws {
        let pid = rig.pid
        try rig.db.write { database in
            guard var heading = try Block.filter(Block.Columns.projectId == pid)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.textContent == title).fetchOne(database) else {
                Issue.record("premise: no heading \"\(title)\"")
                return
            }
            six.apply(to: &heading)
            try heading.update(database)
        }
    }

    private func expectSix(_ row: Block?, _ six: SectionMetadataCarry, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
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

    /// Zooms into the chapter titled `title` the way a zoom in sets the state: the root, the ids, and the `[start, end)` range of the
    /// chapter's rows (up to the next heading of the same or a higher level).
    private func zoom(_ rig: MarkdownWriterRig, into title: String) throws {
        let rows = try rig.rows()
        let root = try #require(rows.first { $0.blockType == .heading && $0.textContent == title }, "premise: heading \(title)")
        let level = root.headingLevel ?? 1
        let next = rows.first { $0.sortOrder > root.sortOrder && $0.blockType == .heading && ($0.headingLevel ?? 1) <= level }
        rig.editorState.zoomedSectionId = root.id
        rig.editorState.zoomedSectionIds = [root.id]
        rig.editorState.zoomedBlockRange = (start: root.sortOrder, end: next?.sortOrder)
    }

    /// A zoom out, as far as these tests need it: the zoom state is gone.
    private func zoomOut(_ rig: MarkdownWriterRig) {
        rig.editorState.zoomedBlockRange = nil
        rig.editorState.zoomedSectionId = nil
        rig.editorState.zoomedSectionIds = nil
    }

    private func zoomedSave(_ rig: MarkdownWriterRig, _ text: String) throws {
        try rig.editorState.applyZoomedRangeWrite(text: text, db: rig.db, pid: rig.pid)
    }

    private func heading(_ rig: MarkdownWriterRig, _ title: String) throws -> Block? { try rig.heading(title) }

    // MARK: - Z1 to Z2: zoomed

    @Test("Z1. zoomed: a sub-heading deleted, the delete saved, then Cmd-Z in a later zoomed save: all six fields, memory used up")
    func zoomedDeleteThenUndoInALaterSaveKeepsAllSix() async throws {
        let rig = try makeRig()
        try zoom(rig, into: "Ch1")

        try zoomedSave(rig, Self.zoomedWithoutS1)
        try #require(try heading(rig, "S1") == nil, "premise: the delete was saved")
        #expect(rig.markdownWriter.removedHeadings.items.map(\.metadata) == [Self.s1Six], "the deleted sub-heading is remembered")

        try zoomedSave(rig, Self.zoomedFull)

        #expect(try rig.storedText() == Self.full)
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        expectSix(try heading(rig, "S2"), Self.s2Six, "S2")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty, "the item was used up")
    }

    @Test("Z2. zoomed: a sub-heading cut and saved, then pasted lower down in a later zoomed save: all six fields")
    func zoomedCutThenPasteInALaterSave() async throws {
        let rig = try makeRig()
        try zoom(rig, into: "Ch1")

        try zoomedSave(rig, Self.zoomedWithoutS1)
        try #require(try heading(rig, "S1") == nil, "premise: the cut was saved")
        try zoomedSave(rig, Self.zoomedS1AfterS2)

        #expect(try rig.storedText() == "# Ch1\n\ns1\n\n## S2\n\ns2\n\n## S1\n\n# Ch2\n\nc2")
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        expectSix(try heading(rig, "S2"), Self.s2Six, "S2")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    // MARK: - Z3 to Z4: between zoomed and unzoomed

    @Test("Z3. cut unzoomed (the per-block save), pasted zoomed (the zoomed save): all six fields")
    func cutUnzoomedPastedZoomed() async throws {
        let rig = try makeRig()

        #expect(await rig.fireAndSettle(Self.fullWithoutS1) == .started)
        try #require(try heading(rig, "S1") == nil, "premise: the unzoomed cut was saved")
        try zoom(rig, into: "Ch1")
        try zoomedSave(rig, Self.zoomedFull)

        #expect(try rig.storedText() == Self.full)
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    @Test("Z4. cut zoomed (the zoomed save), then zoom out and pasted unzoomed (the per-block save): all six fields")
    func cutZoomedPastedUnzoomed() async throws {
        let rig = try makeRig()
        try zoom(rig, into: "Ch1")

        try zoomedSave(rig, Self.zoomedWithoutS1)
        try #require(try heading(rig, "S1") == nil, "premise: the zoomed cut was saved")
        zoomOut(rig)
        #expect(await rig.fireAndSettle(Self.full) == .started)

        #expect(try rig.storedText() == Self.full)
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        expectSix(try heading(rig, "S2"), Self.s2Six, "S2")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }

    // MARK: - Z5 to Z6: what the memory must not do

    @Test("Z5. zoomed: two sub-headings swapped in one save keep their ids and fields by title match, and nothing is remembered")
    func zoomedTitleMatchStillWinsAndRecordsNothing() async throws {
        let rig = try makeRig()
        let s1Id = try #require(try heading(rig, "S1")).id
        let s2Id = try #require(try heading(rig, "S2")).id
        try zoom(rig, into: "Ch1")

        try zoomedSave(rig, "# Ch1\n\n## S2\n\ns2\n\n## S1\n\ns1")

        #expect(try heading(rig, "S1")?.id == s1Id, "S1 kept its row")
        #expect(try heading(rig, "S2")?.id == s2Id, "S2 kept its row")
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        expectSix(try heading(rig, "S2"), Self.s2Six, "S2")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty, "nothing was deleted, so nothing is remembered")
    }

    @Test("Z6. zoomed: renaming the zoom root binds it by position, so the root keeps its row and nothing is remembered")
    func zoomedRootIsNeverRecordedWhileBound() async throws {
        let rig = try makeRig()
        let rootId = try #require(try heading(rig, "Ch1")).id
        try zoom(rig, into: "Ch1")

        try zoomedSave(rig, "# Ch1 renamed\n\n## S1\n\ns1\n\n## S2\n\ns2")

        let root = try #require(try heading(rig, "Ch1 renamed"), "the root is stored under its new title")
        #expect(root.id == rootId, "the root kept its row")
        expectSix(try heading(rig, "S1"), Self.s1Six, "S1")
        expectSix(try heading(rig, "S2"), Self.s2Six, "S2")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty, "a bound root is never recorded")
    }

    // MARK: - Z7: the zoom root's own line removed

    private static let withSolo = "# Ch1\n\n## S1\n\ns1\n\n# Solo\n\nsolo1\n\n# Ch3\n\nc3"
    private static let soloSix = SectionMetadataCarry(
        status: .waiting, tags: ["solo"], wordGoal: 900, goalType: .min, aggregateGoal: 9000, aggregateGoalType: .max)

    @Test("Z7. zoomed into a chapter with no sub-headings, its own line removed (no heading survives), then restored unzoomed: all six fields back")
    func zoomedRootLineRemovedThenRestoredUnzoomedKeepsAllSix() async throws {
        let rig = try MarkdownWriterRig(content: Self.withSolo)
        try setSix(Self.soloSix, rig, heading: "Solo")
        try zoom(rig, into: "Solo")

        try zoomedSave(rig, "solo1")
        // The save found no heading left and started the lost-root recovery (a task); the zoom state is dropped here, as the recovery
        // would, before that task can run.
        zoomOut(rig)
        try #require(try heading(rig, "Solo") == nil, "premise: the zoom root row is gone")
        #expect(
            rig.markdownWriter.removedHeadings.items.map(\.metadata) == [Self.soloSix],
            "the unbound zoom root is remembered although the save took the early exit")

        #expect(await rig.fireAndSettle(Self.withSolo) == .started, "the restored text, unzoomed")

        #expect(try rig.storedText() == Self.withSolo)
        expectSix(try heading(rig, "Solo"), Self.soloSix, "Solo")
        #expect(rig.markdownWriter.removedHeadings.items.isEmpty)
    }
}
