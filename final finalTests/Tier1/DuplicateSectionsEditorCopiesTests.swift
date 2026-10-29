//
//  DuplicateSectionsEditorCopiesTests.swift
//  final finalTests
//
//  Tier 1 (t-18b7fa48 Phase 4b slice 3, round 1e-i, plan-v3 D4): `ProjectDatabase.duplicateSections(db:rootId:projectId:copies:)`, the
//  database half of an editor-first Duplicate Section. The EDITOR mints the ids of the copies it inserts, one per copied top-level
//  node; the job matches them against `BlockParser.alignmentPairs` of the section's rows, copies EVERY row (a row the editor has no
//  node for, a list's items, gets a fresh id and a parent remapped to the copy), and reports any difference instead of throwing.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Duplicate Section with the editor's copies — Tier 1 (t-18b7fa48 D4)")
struct DuplicateSectionsEditorCopiesTests {

    private static let content = """
    # Document

    ## Section X

    Paragraph X.

    ## Section Y

    Paragraph Y.
    """

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let root: Block
        /// The section's rows in document order, as the job reads them.
        let subtree: [Block]
        /// One pair per top-level editor node of the section.
        let nodeIds: [String]
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: Self.content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        // Two bullet-list rows one after the other, after Section X's paragraph: the editor shows them as ONE list node, so the
        // second row has no node of its own (`alignmentPairs` merges consecutive lists of one type).
        let paragraph = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent == "Paragraph X." })
        for (offset, text) in ["first item", "second item"].enumerated() {
            try db.insertBlock(Block(
                projectId: pid, sortOrder: paragraph.sortOrder + 0.1 * Double(offset + 1), blockType: .bulletList,
                textContent: text, markdownFragment: "- \(text)"))
        }
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let root = try #require(blocks.first { $0.textContent == "Section X" })
        let ids = try #require(try db.sectionBlockIds(rootId: root.id, projectId: pid))
        let byId = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let subtree = ids.compactMap { byId[$0] }
        return Fixture(db: db, pid: pid, root: root, subtree: subtree, nodeIds: BlockParser.alignmentPairs(subtree).map(\.id))
    }

    /// Runs the static form inside a write transaction. A plain (non-async) function on purpose: inside an `async` test
    /// `dbWriter.write` resolves to GRDB's async overload.
    @MainActor
    private func duplicate(
        _ fixture: Fixture, copies: [(source: String, new: String)]?
    ) throws -> ProjectDatabase.DuplicatedSubtree {
        let rootId = fixture.root.id
        let pid = fixture.pid
        return try #require(try fixture.db.dbWriter.write { database in
            try ProjectDatabase.duplicateSections(db: database, rootId: rootId, projectId: pid, copies: copies)
        })
    }

    @Test("the editor's ids go on the top-level copies; the row the editor has no node for is copied under a fresh id")
    @MainActor
    func editorIdsGoOnTheNodes() throws {
        let fixture = try makeFixture()
        #expect(fixture.nodeIds.count == 3, "a heading, a paragraph and a list are three editor nodes: \(fixture.nodeIds.count)")
        #expect(fixture.subtree.count == 4, "the section has four rows: \(fixture.subtree.count)")
        let copies = fixture.nodeIds.map { (source: $0, new: UUID().uuidString) }

        let result = try duplicate(fixture, copies: copies)

        #expect(result.copiesMismatch == nil, "got \(String(describing: result.copiesMismatch))")
        #expect(result.copiedBlockIds.count == fixture.subtree.count, "every row of the section is copied")
        #expect(Set(copies.map(\.new)).isSubset(of: Set(result.copiedBlockIds)), "the editor's ids are the copies' ids")
        #expect(Set(result.copiedBlockIds).count == fixture.subtree.count, "no id is used twice")
        let rows = Dictionary(try TestFixtureFactory.fetchBlocks(from: fixture.db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(result.copiedBlockIds.allSatisfy { rows[$0] != nil }, "every copied row is in the table")
        #expect(rows[copies[0].new]?.textContent == "Section X copy", "the root heading carries the suffix")
        let fresh = try #require(result.copiedBlockIds.last)
        #expect(!copies.map(\.new).contains(fresh), "the list's second row has no editor node, so its copy got a fresh id")
        #expect(rows[fresh]?.textContent == "second item", "and it is the copy of the second list row")
    }

    @Test("copies that do not match the section are reported, never thrown: every row is still copied")
    @MainActor
    func mismatchIsReportedNotThrown() throws {
        let fixture = try makeFixture()
        let result = try duplicate(fixture, copies: [(source: "not-a-row-of-the-section", new: UUID().uuidString)])

        #expect(result.copiesMismatch != nil, "one copy for three nodes must be reported")
        #expect(result.copiedBlockIds.count == fixture.subtree.count, "every row of the section is still copied")
        #expect(Set(result.copiedBlockIds).count == fixture.subtree.count)
    }

    @Test("sources the writer could not resolve are matched by position when the counts agree, and the difference is reported")
    @MainActor
    func unresolvedSourcesMatchByPosition() throws {
        let fixture = try makeFixture()
        let copies = fixture.nodeIds.indices.map { (source: "temp-\($0)", new: UUID().uuidString) }

        let result = try duplicate(fixture, copies: copies)

        #expect(Set(copies.map(\.new)).isSubset(of: Set(result.copiedBlockIds)), "matched by position")
        #expect(result.copiesMismatch?.contains("by position") == true, "got \(String(describing: result.copiesMismatch))")
    }

    @Test("a new id that is already a row of the table is never reused")
    @MainActor
    func takenIdsAreNotReused() throws {
        let fixture = try makeFixture()
        let taken = try #require(fixture.subtree.dropFirst().first).id   // the section's own first body row
        var copies = fixture.nodeIds.map { (source: $0, new: UUID().uuidString) }
        copies[1].new = taken

        let result = try duplicate(fixture, copies: copies)

        #expect(result.copiesMismatch?.contains("already a row") == true, "got \(String(describing: result.copiesMismatch))")
        #expect(Set(result.copiedBlockIds).count == fixture.subtree.count, "no id is used twice")
        #expect(!result.copiedBlockIds.contains(taken), "the existing row's id was not given to a copy")
        let remaining = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        #expect(remaining.filter { $0.id == taken }.count == 1, "the original row is untouched")
    }

    // The reply shapes the editor sends (web/milkdown/src/api-section-duplicate.ts, api-section-undo.ts), decoded by Swift.
    @Test("the duplicate's reply decodes: copies, leaders and snapshot on success; empty lists on a refusal; predecessorId is tolerated")
    func duplicateReplyDecodes() throws {
        let success = """
        {"batch":{"updates":[],"inserts":[],"deletes":[]},"ok":true,"copies":[{"sourceId":"a","newId":"b"},{"sourceId":"temp-1","newId":"c"}],\
        "insertedLeaderIds":["b"],"insertedSectionsSnapshot":[{"id":"b","kind":"heading","level":2,"title":"Section A copy"}],"predecessorId":"pa"}
        """
        let reply = try JSONDecoder().decode(EditorFirstDuplicateReply.self, from: Data(success.utf8))
        #expect(reply.succeeded && reply.reason == nil)
        #expect(reply.copies == [DuplicatedBlock(sourceId: "a", newId: "b"), DuplicatedBlock(sourceId: "temp-1", newId: "c")])
        #expect(reply.insertedLeaderIds == ["b"])
        #expect(reply.insertedSectionsSnapshot == [.init(id: "b", kind: "heading", level: 2, title: "Section A copy")])
        // (`predecessorId` is on the wire -- the JSON above carries it -- but no longer decoded: round 2d-i, review B4. The decode
        // above passing is what pins the reply staying tolerant of the key.)

        let refusal = """
        {"batch":{"updates":[],"inserts":[],"deletes":[]},"ok":false,"reason":"rootNotFound","copies":[],"insertedLeaderIds":[],\
        "insertedSectionsSnapshot":[],"predecessorId":null}
        """
        let refused = try JSONDecoder().decode(EditorFirstDuplicateReply.self, from: Data(refusal.utf8))
        #expect(!refused.succeeded && refused.reason == "rootNotFound")
        #expect(refused.copies.isEmpty && refused.insertedLeaderIds.isEmpty)
    }

    @Test("the quick undo's reply decodes the leaders it removed, and an older editor's reply without them")
    func quickUndoReplyDecodesRemovedLeaders() throws {
        let withRemoved = """
        {"batch":{"updates":[],"inserts":[],"deletes":[]},"ok":true,"restoredIds":[],"restoredLeaderIds":[],"removedLeaderIds":["b","c"]}
        """
        let reply = try JSONDecoder().decode(QuickUndoReply.self, from: Data(withRemoved.utf8))
        #expect(reply.removedLeaderIds == ["b", "c"])
        let older = """
        {"batch":{"updates":[],"inserts":[],"deletes":[]},"ok":true,"restoredIds":["x"],"restoredLeaderIds":["x"]}
        """
        #expect(try JSONDecoder().decode(QuickUndoReply.self, from: Data(older.utf8)).removedLeaderIds == nil)
    }

    @Test("with no editor copies every copy gets a fresh id, as the old duplicate did")
    @MainActor
    func noCopiesMeansFreshIds() throws {
        let fixture = try makeFixture()
        let result = try duplicate(fixture, copies: nil)

        #expect(result.copiesMismatch == nil)
        #expect(result.copiedBlockIds.count == fixture.subtree.count)
        #expect(Set(result.copiedBlockIds).isDisjoint(with: Set(fixture.subtree.map(\.id))))
    }

    // U15 (t-4a8fd8af slice 3, CONTROL: passes with the code as it is): the Markdown page gives only the section's LEADERS new ids, so the
    // job's `copies` hold one pair for the heading and none for the paragraph and the list rows. The heading's copy takes the pair's id,
    // every other row is copied under a fresh id (never one of the original ids, never repeated), and the difference is reported (the
    // Markdown click treats that report as normal: `copiesAreLeadersOnly`).
    @Test("leader-only copies: the heading's copy takes the editor's id, every other row gets a fresh one, and it is reported")
    @MainActor
    func testLeaderOnlyCopiesGiveLeadersTheirIdsAndOthersFreshIds() throws {
        let fixture = try makeFixture()
        let copies = [(source: fixture.root.id, new: UUID().uuidString)]

        let result = try duplicate(fixture, copies: copies)

        #expect(result.copiedBlockIds.count == fixture.subtree.count, "every row of the section is copied")
        #expect(result.copiedBlockIds.first == copies[0].new, "the heading's copy does not carry the editor's id")
        #expect(Set(result.copiedBlockIds).count == fixture.subtree.count, "no id is used twice")
        #expect(
            Set(result.copiedBlockIds.dropFirst()).isDisjoint(with: Set(fixture.subtree.map(\.id)).union([copies[0].new])),
            "the other rows must get fresh ids (never an original's id, never the heading copy's)")
        let rows = Dictionary(try TestFixtureFactory.fetchBlocks(from: fixture.db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(result.copiedBlockIds.allSatisfy { rows[$0] != nil }, "every copied row is in the table")
        #expect(rows[copies[0].new]?.textContent == "Section X copy", "the heading's copy carries the suffix")
        #expect(
            result.copiesMismatch?.contains("fresh id") == true,
            "the nodes without a pair are reported as getting a fresh id, got \(String(describing: result.copiesMismatch))")
    }
}
