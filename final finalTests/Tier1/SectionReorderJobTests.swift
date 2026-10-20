//
//  SectionReorderJobTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, plan U8): the queued background half of an editor-first drag-reorder, `SectionReorderJob`, run as a
//  `SystemWriteKind.sectionReorder` system write on a real `DocumentWriter` and a temporary project database (no web view, no editor).
//  These start from "the editor has moved the section(s) and its pending batch has been applied" and pin what the job does with the rows:
//    - the Version History snapshot of the document as it stood BEFORE the move, in the same transaction (what the slow undo restores);
//    - every row renumbered 1, 2, 3... in the final order (a block is a leader if and only if its id is in the list);
//    - the level of a planned HEADING set, with the `#` prefix rebuilt from the LIVE row (a heading renamed a moment ago keeps its new
//      title; the sidebar's copy of the text can be a moment stale), a section break listed with a level left alone;
//    - section parents recomputed;
//    - a job that throws leaves NOTHING behind: no snapshot, no content change, no slot record.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// Makes every update of a block row abort, the way a database fault in the middle of the renumbering would: the job has written its
/// snapshot by then, so only a rollback of the whole transaction leaves the table as it was. A plain (non-async) function, like `renameRow`.
@MainActor
private func failEveryBlockUpdate(_ db: ProjectDatabase) throws {
    try db.dbWriter.write { database in
        try database.execute(sql: """
            CREATE TRIGGER failReorderUpdate BEFORE UPDATE ON block
            BEGIN SELECT RAISE(ABORT, 'forced reorder failure (test)'); END
            """)
    }
}

/// Renames a heading row the way a rename typed in the editor does once its batch is applied (text and fragment). A plain (non-async)
/// function on purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
@MainActor
private func renameRow(_ db: ProjectDatabase, id: String, to title: String, level: Int) throws {
    _ = try db.dbWriter.write { database in
        try Block.filter(key: id).updateAll(
            database,
            Block.Columns.textContent.set(to: title),
            Block.Columns.markdownFragment.set(to: String(repeating: "#", count: level) + " " + title))
    }
}

@Suite("SectionReorderJob — the queued half of an editor-first drag-reorder (Tier 1)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionReorderJobTests {

    // MARK: - Fixture

    private struct Rig {
        let db: ProjectDatabase
        let pid: String
        let writer: DocumentWriter
        let slots: SectionDeleteSlotStore
        var identity: SystemWriteIdentity { SystemWriteIdentity(projectId: pid, database: db) }
    }

    private func makeRig(markdown: String) throws -> Rig {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        return Rig(db: db, pid: pid, writer: DocumentWriter(database: db, projectId: pid), slots: SectionDeleteSlotStore())
    }

    private func makeJob(_ rig: Rig, opId: UUID, order: [String], levels: [String: Int] = [:]) -> SectionReorderJob {
        SectionReorderJob(
            opId: opId, projectId: rig.pid, fallbackBibliographyTitle: "Bibliography", slots: rig.slots, leaderIds: order, levels: levels)
    }

    /// Reserves the job's turn on the rig's writer and applies it (the job is the frontier: nothing else is open).
    private func apply(_ job: SectionReorderJob, on rig: Rig) async -> SystemWriteOutcome<SectionReorderJob.Output> {
        let ticket = rig.writer.reserveSystem()
        return await rig.writer.applySystemWrite(ticket.seq, kind: .sectionReorder, identity: rig.identity) { database, idMap in
            try job.run(db: database, idMap: idMap)
        }
    }

    private func row(_ rig: Rig, _ text: String) throws -> Block {
        try #require(try rig.db.fetchBlocks(projectId: rig.pid).first { $0.textContent == text })
    }

    /// A is a chapter with a sub-section B, then a second chapter C.
    private static let chapters = """
    Preamble paragraph before any heading.

    # A

    A body.

    ## B

    B body.

    # C

    C body.
    """

    // MARK: - U8

    // U8: the move puts C ahead of A, B becomes a chapter of its own, and B was renamed in the table a moment before ("## B renamed").
    // The planned level is applied to the LIVE row: the fragment is "# B renamed", not the sidebar's older "## B".
    @Test("headingFragmentRebuiltFromLiveRow")
    func headingFragmentRebuiltFromLiveRow() async throws {
        let rig = try makeRig(markdown: Self.chapters)
        defer { rig.slots.removeAll() }
        let b = try row(rig, "B")
        let a = try row(rig, "A")
        let cRow = try row(rig, "C")
        try renameRow(rig.db, id: b.id, to: "B renamed", level: 2)
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        #expect(before.first { $0.id == b.id }?.sectionParentId == a.id, "precondition: B starts as A's sub-section")
        let assembledBefore = BlockParser.assembleMarkdownForEditor(from: before)
        let snapshotsBefore = try rig.db.countSnapshots(projectId: rig.pid)
        let epochBefore = try rig.db.currentBlockWriteEpoch(projectId: rig.pid)

        let opId = UUID()
        rig.slots.open(opId)
        let outcome = await apply(makeJob(rig, opId: opId, order: [cRow.id, a.id, b.id], levels: [b.id: 1]), on: rig)
        guard case .applied(let output) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }

        let after = try rig.db.fetchBlocks(projectId: rig.pid)
        let bAfter = try #require(after.first { $0.id == b.id })
        #expect(bAfter.headingLevel == 1, "B's level was not set, got \(String(describing: bAfter.headingLevel))")
        #expect(bAfter.markdownFragment == "# B renamed", "the fragment must be rebuilt from the live row, got '\(bAfter.markdownFragment)'")
        #expect(bAfter.textContent == "B renamed")
        let aAfter = try #require(after.first { $0.id == a.id })
        #expect(aAfter.headingLevel == 1 && aAfter.markdownFragment == "# A", "A has no planned level and must be left alone")

        // Every row renumbered 1, 2, 3... in the final order: the preamble, C and its body, A and its body, B and its body.
        let sorted = after.sorted { $0.sortOrder < $1.sortOrder }
        #expect(
            sorted.map(\.textContent) == ["Preamble paragraph before any heading.", "C", "C body.", "A", "A body.", "B renamed", "B body."],
            "got \(sorted.map(\.textContent))")
        #expect(sorted.map(\.sortOrder) == (1...7).map(Double.init), "sort orders were not renumbered 1...7: \(sorted.map(\.sortOrder))")

        // Section parents recomputed: B is no longer A's sub-section.
        #expect(bAfter.sectionParentId == nil, "B's section parent was not recomputed, got \(String(describing: bAfter.sectionParentId))")
        #expect(after.first { $0.id == cRow.id }?.sectionParentId == nil)

        // The snapshot: one more, written from the rows as they were BEFORE the move, and recorded and pinned on the slot at commit.
        #expect(try rig.db.countSnapshots(projectId: rig.pid) == snapshotsBefore + 1)
        let snapshot = try #require(try rig.db.fetchSnapshot(id: output.snapshotId))
        #expect(snapshot.previewMarkdown == assembledBefore, "the snapshot must hold the document as it was before the move")
        let slot = try #require(rig.slots.slot(opId))
        #expect(slot.state == .applied && slot.snapshotId == output.snapshotId, "the slot did not record the snapshot")
        #expect(slot.removedSections.isEmpty, "a reorder removes nothing")
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(output.snapshotId))
        // A system write: no epoch bump (typing into a moved section after the click must still find its rows).
        #expect(try rig.db.currentBlockWriteEpoch(projectId: rig.pid) == epochBefore, "the job bumped the write epoch")
    }

    // A failed job rolls everything back: the snapshot it wrote first, the renumbering, the level change; the slot gets no record. The
    // failure is a database fault in the middle of the renumbering, i.e. AFTER the snapshot was written, so a missing rollback would leave
    // the snapshot, a half-renumbered table, or both.
    @Test("aJobThatFailsAfterItsSnapshotLeavesNothingBehind")
    func aJobThatFailsAfterItsSnapshotLeavesNothingBehind() async throws {
        let rig = try makeRig(markdown: Self.chapters)
        defer { rig.slots.removeAll() }
        let a = try row(rig, "A")
        let b = try row(rig, "B")
        let cRow = try row(rig, "C")
        let before = try rig.db.fetchBlocks(projectId: rig.pid)
        let snapshotsBefore = try rig.db.countSnapshots(projectId: rig.pid)
        let contentBefore = try rig.db.fetchContent(for: rig.pid)?.markdown
        try failEveryBlockUpdate(rig.db)

        let opId = UUID()
        rig.slots.open(opId)
        let outcome = await apply(makeJob(rig, opId: opId, order: [cRow.id, a.id, b.id], levels: [b.id: 1]), on: rig)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(try rig.db.fetchBlocks(projectId: rig.pid) == before, "the rows changed although the job failed")
        #expect(try rig.db.countSnapshots(projectId: rig.pid) == snapshotsBefore, "a snapshot survived the failed job")
        #expect(try rig.db.fetchContent(for: rig.pid)?.markdown == contentBefore)
        #expect(rig.slots.slot(opId)?.snapshotId == nil, "nothing may be recorded on the slot of a failed job")
    }

    // A section break (a pseudo-section leader) listed WITH a level is left alone: only heading rows take a planned level. Its place in the
    // order is still honoured.
    @Test("aSectionBreakListedWithALevelIsNotChanged")
    func aSectionBreakListedWithALevelIsNotChanged() async throws {
        let markdown = """
        # Part One

        The part one body.

        <!-- ::break:: -->

        # Part Two

        The part two body.
        """
        let rig = try makeRig(markdown: markdown)
        defer { rig.slots.removeAll() }
        let one = try row(rig, "Part One")
        let two = try row(rig, "Part Two")
        let breakRow = try #require(try rig.db.fetchBlocks(projectId: rig.pid).first { $0.isPseudoSection })

        let opId = UUID()
        rig.slots.open(opId)
        let outcome = await apply(
            makeJob(rig, opId: opId, order: [two.id, breakRow.id, one.id], levels: [breakRow.id: 2, two.id: 2]), on: rig)
        guard case .applied = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }

        let after = try rig.db.fetchBlocks(projectId: rig.pid)
        let breakAfter = try #require(after.first { $0.id == breakRow.id })
        #expect(breakAfter.headingLevel == breakRow.headingLevel, "the section break's level changed")
        #expect(breakAfter.markdownFragment == breakRow.markdownFragment, "the section break's text changed: '\(breakAfter.markdownFragment)'")
        let twoAfter = try #require(after.first { $0.id == two.id })
        #expect(twoAfter.headingLevel == 2 && twoAfter.markdownFragment == "## Part Two", "the heading in the same list did take its level")
        let titles = after.sorted { $0.sortOrder < $1.sortOrder }.filter { $0.blockType == .heading || $0.isPseudoSection }.map(\.id)
        #expect(titles == [two.id, breakRow.id, one.id], "the order was not applied")
    }
}
