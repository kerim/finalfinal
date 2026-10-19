//
//  DuplicateSectionsRealReplyTests.swift
//  final finalTests
//
//  Tier 1 (t-18b7fa48 Phase 4b slice 1, round 1g-C, code review T2 = the proof of A2): `ProjectDatabase.duplicateSections(db:rootId:
//  projectId:copies:)` fed a REAL reply of the web function.
//
//  The other tests of the matcher (DuplicateSectionsEditorCopiesTests) take the editor's `copies` from `BlockParser.alignmentPairs`, the
//  very function production matches them against, so none of them could see the real reply disagree with it. This one reads the file
//  `web/milkdown/src/__tests__/fixtures/duplicate-section-reply.json`, which the web test `V1-13` in duplicate-section-editor-first.test.ts
//  writes from the production `duplicateSectionEditorFirst` (vitest's file snapshot: a changed reply fails that test until the file is
//  regenerated, so the file cannot go stale). The document has a tight list, a loose list (two rows of the table, ONE node of the
//  editor), a figure and an empty paragraph the editor holds a confirmed id for (a row with an empty fragment, which
//  `BlockParser.alignmentPairs` skips). The reply is decoded by the type production decodes it with (`EditorFirstDuplicateReply`).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The file the web test writes: the rows the table holds for the section (ids equal to the editor's ids) and the editor's reply.
private struct RealDuplicateReplyFile: Decodable {
    struct Row: Decodable {
        let id: String
        let blockType: String
        let headingLevel: Int?
        let textContent: String
        let markdownFragment: String
    }

    let rootId: String
    let rows: [Row]
    let reply: EditorFirstDuplicateReply
}

@Suite("Duplicate Section with a real reply of the web function — Tier 1 (t-18b7fa48 round 1g-C, A2/T2)")
struct DuplicateSectionsRealReplyTests {

    private static func fixtureURL(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()   // Tier1
            .deletingLastPathComponent()   // final finalTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("web/milkdown/src/__tests__/fixtures/duplicate-section-reply.json")
    }

    private static func loadFile() throws -> RealDuplicateReplyFile {
        let url = fixtureURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RealDuplicateReplyFile.self, from: data)
    }

    private struct Fixture {
        let file: RealDuplicateReplyFile
        let db: ProjectDatabase
        let pid: String
    }

    /// A database holding a document heading and, after it, the rows the file describes (in order, ids as given).
    @MainActor
    private func makeFixture() throws -> Fixture {
        let file = try Self.loadFile()
        let db = try TestFixtureFactory.createTemporary(content: "# Document")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let base = (try TestFixtureFactory.fetchBlocks(from: db).map(\.sortOrder).max() ?? 0) + 1
        for (index, row) in file.rows.enumerated() {
            let type = try #require(BlockType(rawValue: row.blockType), "unknown block type \(row.blockType) in the file")
            try db.insertBlock(Block(
                id: row.id, projectId: pid, sortOrder: base + Double(index), blockType: type, textContent: row.textContent,
                markdownFragment: row.markdownFragment, headingLevel: row.headingLevel))
        }
        return Fixture(file: file, db: db, pid: pid)
    }

    /// A plain (non-async) function on purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    @MainActor
    private func duplicate(_ fixture: Fixture) throws -> ProjectDatabase.DuplicatedSubtree {
        let rootId = fixture.file.rootId
        let pid = fixture.pid
        let copies = fixture.file.reply.copies.map { (source: $0.sourceId, new: $0.newId) }
        return try #require(try fixture.db.dbWriter.write { database in
            try ProjectDatabase.duplicateSections(db: database, rootId: rootId, projectId: pid, copies: copies)
        })
    }

    // The file is a real reply: the editor's nodes are the aligned rows PLUS the empty paragraph, which the alignment skips. If this
    // fails, the rows and the editor no longer describe the same document, and the next test proves nothing.
    @Test("the rows in the file and the editor's copies describe the same document: the aligned nodes plus the empty paragraph")
    @MainActor
    func theFileDescribesOneDocument() throws {
        let fixture = try makeFixture()
        let rows = try TestFixtureFactory.fetchBlocks(from: fixture.db).filter { fixture.file.rows.map(\.id).contains($0.id) }
        let aligned = BlockParser.alignmentPairs(rows).map(\.id)
        let editorSources = fixture.file.reply.copies.map(\.sourceId)
        #expect(fixture.file.reply.succeeded, "the file holds a refusal, not a reply")
        #expect(editorSources.contains("sx-blank") && !aligned.contains("sx-blank"), "the empty paragraph must be an editor node the alignment skips")
        #expect(aligned == editorSources.filter { $0 != "sx-blank" }, "aligned: \(aligned), the editor's sources: \(editorSources)")
        #expect(
            fixture.file.rows.count == aligned.count + 2,
            "the loose list's second row and the empty paragraph are the two rows without an aligned node")
    }

    // A2 + T2: every copy the editor made lands on a row of the table under the id the editor gave it, the empty paragraph's copy
    // included; the copies agree with the rows, so nothing is reported (and no id push follows); typing into the copy of the empty
    // paragraph is an UPDATE of that id and lands.
    @Test("every editor copy gets its row under the editor's id (the empty paragraph's too); typing into that copy is saved")
    @MainActor
    func testARealWebReplyGivesEveryEditorCopyItsRow() throws {
        let fixture = try makeFixture()
        let result = try duplicate(fixture)

        let table = Dictionary(
            try TestFixtureFactory.fetchBlocks(from: fixture.db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for copy in fixture.file.reply.copies {
            let source = table[copy.sourceId]
            let row = table[copy.newId]
            #expect(row != nil, "the editor's copy \(copy.newId) of \(copy.sourceId) has no row under that id in the table")
            #expect(
                row?.blockType == source?.blockType,
                "the copy \(copy.newId) is a \(String(describing: row?.blockType)), its source a \(String(describing: source?.blockType))")
            if copy.sourceId != fixture.file.rootId {
                #expect(row?.textContent == source?.textContent, "the copy \(copy.newId) of \(copy.sourceId) has other text than its source")
            }
        }
        #expect(table[fixture.file.reply.copies[0].newId]?.textContent == "Section X copy", "the root heading carries the suffix")
        #expect(result.copiedBlockIds.count == fixture.file.rows.count, "every row of the section is copied, the loose list's second row too")
        #expect(Set(result.copiedBlockIds).count == fixture.file.rows.count, "no id is used twice")
        #expect(
            Set(fixture.file.reply.copies.map(\.newId)).isSubset(of: Set(result.copiedBlockIds)),
            "an id the editor holds is missing from the rows the job inserted")
        #expect(
            result.copiesMismatch == nil,
            "the editor and the table agree, so nothing may be reported: \(String(describing: result.copiesMismatch))")

        // Typing into the copy of the empty paragraph: the editor sends an update for ITS id for that node.
        let blankCopy = try #require(fixture.file.reply.copies.first { $0.sourceId == "sx-blank" }, "the file has no copy of the empty paragraph")
        let typed = "typed into the copy of the empty paragraph"
        _ = try fixture.db.applyBlockChangesFromEditor(
            BlockChanges(updates: [BlockUpdate(id: blankCopy.newId, textContent: typed, markdownFragment: typed, headingLevel: nil)]),
            for: fixture.pid)
        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        #expect(
            after.first { $0.id == blankCopy.newId }?.textContent == typed,
            "typing into the copy of the empty paragraph was not saved: the table has no row \(blankCopy.newId) to update")
        #expect(after.first { $0.id == "sx-blank" }?.textContent == "", "the original empty paragraph was changed by the update meant for its copy")
    }

    // A2: what is left over IS reported (and makes the settle push the database's ids): an editor copy that matches no row of the
    // section, here the copy of a node the table has no row for.
    @Test("an editor copy that matches no row is reported, so the settle pushes the database's ids")
    @MainActor
    func anUnmatchedEditorCopyIsReported() throws {
        let fixture = try makeFixture()
        let rootId = fixture.file.rootId
        let pid = fixture.pid
        var copies = fixture.file.reply.copies.map { (source: $0.sourceId, new: $0.newId) }
        copies.append((source: "", new: "an-id-only-the-editor-holds"))
        let result = try #require(try fixture.db.dbWriter.write { database in
            try ProjectDatabase.duplicateSections(db: database, rootId: rootId, projectId: pid, copies: copies)
        })

        #expect(result.copiesMismatch?.contains("matched no row") == true, "got \(String(describing: result.copiesMismatch))")
        #expect(result.copiedBlockIds.count == fixture.file.rows.count, "every row of the section is still copied")
        let table = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        #expect(!table.contains { $0.id == "an-id-only-the-editor-holds" }, "an id no row was matched with was written")
    }
}
