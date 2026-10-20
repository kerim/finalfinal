//
//  SectionReorderManagedRegionsTests.swift
//  final finalTests
//
//  Tier 1 (t-0b70d1e9, review item C1, EVERYDAY): the Notes and Bibliography sections and a reorder that was planned a moment before
//  their rebuild committed. The footnote and bibliography rebuilds delete every Notes / Bibliography row and insert new ones under FRESH
//  ids. A plan made before that still names the OLD heading ids, which match no row any more, while the new headings are not in the
//  list at all; without a fix the new Notes and Bibliography headings join the previous leader's group (the last chapter) and travel
//  with it, so dragging the last chapter to the top takes the Notes and the Bibliography with it.
//
//  `ProjectDatabase.reorderAllBlocks(db:leaderIds:projectId:levels:)` therefore resolves the managed sections from the LIVE rows: any
//  listed id whose row is Notes or Bibliography is dropped, and the live Notes heading and then the live Bibliography heading are put
//  last. Both roads that end in it are covered: the queued job (`SectionReorderJob.run`) and the old whole-document path
//  (`reorderAllBlocks(sections:projectId:)`, which Markdown mode, zoomed and the fallbacks use).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The managed sections' rows are replaced the way a Notes / bibliography rebuild replaces them: deleted, and inserted again under fresh
/// ids with the same text and position. A plain (non-async) function: inside an `async` test `dbWriter.write` resolves to GRDB's async
/// overload.
@MainActor
private func rebuildManagedRows(_ db: ProjectDatabase, projectId: String) throws {
    _ = try db.dbWriter.write { database in
        let managed = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true || Block.Columns.isBibliography == true)
            .fetchAll(database)
        _ = try Block.filter(keys: managed.map(\.id)).deleteAll(database)
        for var row in managed {
            row.id = UUID().uuidString
            try row.insert(database)
        }
    }
}

@Suite("Reorder: Notes and Bibliography rebuilt before the reorder runs (Tier 1)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SectionReorderManagedRegionsTests {

    /// Three chapters, a footnote, a Notes section and a bibliography (the end marker flags `# References` and the entry as
    /// Bibliography). The last chapter is the one that carries the managed sections along when the fix is missing.
    private static let document = """
    # Alpha

    Alpha body[^1].

    # Bravo

    Bravo body.

    # Charlie

    Charlie body.

    # Notes

    [^1]: The footnote text.

    # References

    Smith, J. (2023). A cited source.

    <!-- ::auto-bibliography-end:: -->
    """

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let alpha: Block
        let bravo: Block
        let charlie: Block
        let notes: Block
        let bibliography: Block
    }

    private func makeFixture() throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: Self.document)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let headings = try db.fetchBlocks(projectId: pid).filter { $0.blockType == .heading }
        func heading(_ title: String) throws -> Block {
            try #require(headings.first { $0.textContent == title }, "the fixture has no heading '\(title)'")
        }
        let notes = try #require(headings.first { $0.isNotes }, "the fixture has no Notes heading")
        let bibliography = try #require(headings.first { $0.isBibliography }, "the fixture has no Bibliography heading")
        return Fixture(
            db: db, pid: pid, alpha: try heading("Alpha"), bravo: try heading("Bravo"), charlie: try heading("Charlie"),
            notes: notes, bibliography: bibliography)
    }

    /// The document must end with Notes, then the Bibliography, whatever was reordered: the headings in order, and no row of a managed
    /// section anywhere before the last row of an ordinary one.
    private func expectManagedSectionsLast(_ fixture: Fixture, chapters: [String], _ roadName: String) throws {
        let rows = BlockParser.assemblySorted(try fixture.db.fetchBlocks(projectId: fixture.pid))
        let headings = rows.filter { $0.blockType == .heading }.map(\.textContent)
        #expect(headings == chapters + ["Notes", "References"], "\(roadName): the headings are in the order \(headings)")
        let lastOrdinary = try #require(rows.lastIndex { !$0.isNotes && !$0.isBibliography })
        let firstManaged = try #require(rows.firstIndex { $0.isNotes || $0.isBibliography })
        #expect(
            lastOrdinary < firstManaged,
            "\(roadName): a Notes or Bibliography row sits before an ordinary row (\(lastOrdinary) vs \(firstManaged))")
        let notesIndex = try #require(rows.firstIndex { $0.isNotes && $0.blockType == .heading })
        let bibliographyIndex = try #require(rows.firstIndex { $0.isBibliography && $0.blockType == .heading })
        #expect(notesIndex < bibliographyIndex, "\(roadName): the Bibliography is not after the Notes")
        let outline = try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map(\.textContent)
        #expect(outline.suffix(2) == ["Notes", "References"], "\(roadName): the outline ends \(outline.suffix(2))")
    }

    // The queued job: Charlie (the last chapter) is dragged to the top; the plan lists the Notes and Bibliography headings by the ids they
    // had when it was made; their rebuild commits before the job runs. The new managed headings must still end the document.
    @Test("jobKeepsRebuiltNotesAndBibliographyLast")
    func jobKeepsRebuiltNotesAndBibliographyLast() async throws {
        let fixture = try makeFixture()
        let planned = [fixture.charlie.id, fixture.alpha.id, fixture.bravo.id, fixture.notes.id, fixture.bibliography.id]
        try rebuildManagedRows(fixture.db, projectId: fixture.pid)
        let liveIds = Set(try fixture.db.fetchBlocks(projectId: fixture.pid).map(\.id))
        #expect(!liveIds.contains(fixture.notes.id) && !liveIds.contains(fixture.bibliography.id), "precondition: the old managed ids are gone")

        let writer = DocumentWriter(database: fixture.db, projectId: fixture.pid)
        let slots = SectionDeleteSlotStore()
        defer { slots.removeAll() }
        let opId = UUID()
        slots.open(opId)
        let job = SectionReorderJob(
            opId: opId, projectId: fixture.pid, fallbackBibliographyTitle: "Bibliography", slots: slots, leaderIds: planned, levels: [:])
        let ticket = writer.reserveSystem()
        let identity = SystemWriteIdentity(projectId: fixture.pid, database: fixture.db)
        let outcome = await writer.applySystemWrite(ticket.seq, kind: .sectionReorder, identity: identity) { database, idMap in
            try job.run(db: database, idMap: idMap)
        }
        guard case .applied = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }

        try expectManagedSectionsLast(fixture, chapters: ["Charlie", "Alpha", "Bravo"], "the job")
    }

    // The old whole-document road (Markdown mode, zoomed, a fallback) is the same function behind `reorderAllBlocks(sections:)`: the same
    // plan (the sidebar's cards, Notes and Bibliography last, by their old ids), the same rebuild in between.
    @Test("oldPathKeepsRebuiltNotesAndBibliographyLast")
    func oldPathKeepsRebuiltNotesAndBibliographyLast() throws {
        let fixture = try makeFixture()
        let byId = Dictionary(
            try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cards = try [fixture.charlie, fixture.alpha, fixture.bravo, fixture.notes, fixture.bibliography].map { heading in
            SectionViewModel(from: try #require(byId[heading.id], "the outline has no card for \(heading.textContent)"))
        }
        try rebuildManagedRows(fixture.db, projectId: fixture.pid)

        try fixture.db.reorderAllBlocks(sections: cards, projectId: fixture.pid)

        try expectManagedSectionsLast(fixture, chapters: ["Charlie", "Alpha", "Bravo"], "the old path")
    }

    // Without any rebuild in between nothing changes for the ordinary case: the same call, the managed ids are current, and the document
    // still ends with Notes and the Bibliography.
    @Test("currentManagedIdsStillEndTheDocument")
    func currentManagedIdsStillEndTheDocument() throws {
        let fixture = try makeFixture()
        let cards = try fixture.db.fetchOutlineBlocks(projectId: fixture.pid).map { SectionViewModel(from: $0) }
        let wanted = ["Charlie", "Alpha", "Bravo", "Notes", "References"]
        let ordered = try wanted.map { title in try #require(cards.first { $0.title == title }, "no card '\(title)'") }

        try fixture.db.reorderAllBlocks(sections: ordered, projectId: fixture.pid)

        try expectManagedSectionsLast(fixture, chapters: ["Charlie", "Alpha", "Bravo"], "the old path (current ids)")
    }
}
