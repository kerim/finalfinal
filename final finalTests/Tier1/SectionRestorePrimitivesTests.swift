//
//  SectionRestorePrimitivesTests.swift
//  final finalTests
//
//  Tier 1 (t-18b7fa48 Phase 4b, slice 2, round 2d-ii): the pieces the two editor-first SECTION Version History restores stand on, tested
//  without an editor.
//
//    U-S2-D8  `SnapshotService.resolveFlatSectionTarget`: the window names a section by its `section` table row; the plan needs the
//             document's block. A position decides (two sections that share a title are told apart), the title only checks that table and
//             document still agree, and anything else (a table that is behind, a section break) is unresolved, never guessed.
//    U-S2-W1  `ProjectDatabase.replaceFlatSectionRange(db:projectId:headingId:rows:)` replaces the heading and its own body ONLY: the
//             sub-sections below keep their rows, the new rows sit between the block before and the block after, a surviving row keeps
//             its write stamp, and no write epoch moves.
//    U-S2-W2  `ProjectDatabase.insertRows(db:projectId:afterBlockId:rows:)` puts rows after a named block, or after the last block that
//             is not Notes / Bibliography (so above the Notes), and refuses a managed or unknown anchor without writing.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@MainActor
@Suite("Section restore primitives — Tier 1 (t-18b7fa48 slice 2, round 2d-ii)")
struct SectionRestorePrimitivesTests {

    // MARK: - Builders

    private static func heading(_ id: String, _ level: Int, _ text: String, at sort: Double, notes: Bool = false) -> Block {
        Block(
            id: id, projectId: "p", sortOrder: sort, blockType: .heading,
            textContent: text, markdownFragment: String(repeating: "#", count: level) + " " + text, headingLevel: level, isNotes: notes)
    }

    private static func paragraph(_ id: String, _ text: String, at sort: Double, notes: Bool = false) -> Block {
        Block(id: id, projectId: "p", sortOrder: sort, blockType: .paragraph, textContent: text, markdownFragment: text, isNotes: notes)
    }

    private static func sectionRow(_ id: String, _ order: Int, _ level: Int, _ title: String, managed: Bool = false) -> Section {
        Section(
            id: id, projectId: "p", sortOrder: order, headerLevel: level, isBibliography: false, isNotes: managed, title: title,
            markdownContent: "", wordCount: 0)
    }

    /// A fresh database holding exactly `blocks` (inserted directly, so no heading-id carry-over renames an id).
    private func makeDatabase(_ blocks: [Block]) throws -> (db: ProjectDatabase, pid: String) {
        let db = try TestFixtureFactory.createTemporary(content: "# Seed")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var block in blocks {
                block.projectId = pid
                try block.insert(database)
            }
        }
        return (db, pid)
    }

    /// Chapter (H1) with its body, then Section A and Section B (H2), then a Notes heading with one definition.
    private static var document: [Block] {
        [
            heading("h-chapter", 1, "Chapter", at: 1.0), paragraph("p-chapter", "The chapter body.", at: 2.0),
            heading("h-a", 2, "Section A", at: 3.0), paragraph("p-a", "The A body.", at: 4.0),
            heading("h-b", 2, "Section B", at: 5.0), paragraph("p-b", "The B body.", at: 6.0),
            heading("h-notes", 1, "Notes", at: 7.0, notes: true), paragraph("p-note", "[^1]: A note.", at: 8.0, notes: true)
        ]
    }

    private func newRows(_ ids: String..., startingWithHeading headingId: String? = nil) -> [Block] {
        ids.enumerated().map { index, id in
            if index == 0, let headingId {
                return Self.heading(headingId, 1, "Restored heading", at: 0)
            }
            return Self.paragraph(id, "Restored \(id).", at: 0)
        }
    }

    // MARK: - U-S2-D8

    @Test("U-S2-D8: two sections that share a title are told apart by their position")
    func testTargetWithASharedTitleIsResolvedByPosition() {
        let blocks = [
            Self.heading("first", 2, "Introduction", at: 1.0), Self.paragraph("p1", "one", at: 2.0),
            Self.heading("second", 2, "Introduction", at: 3.0), Self.paragraph("p2", "two", at: 4.0)
        ]
        let sections = [Self.sectionRow("s0", 0, 2, "Introduction"), Self.sectionRow("s1", 1, 2, "Introduction")]
        guard case .resolved(let heading, let nodeIds) = SnapshotService.resolveFlatSectionTarget(
            sectionId: "s1", sections: sections, blocks: blocks) else {
            Issue.record("the second section was not resolved")
            return
        }
        #expect(heading.id == "second", "resolved the wrong one of two sections that share a title: \(heading.id)")
        #expect(nodeIds == ["second", "p2"], "got \(nodeIds)")
    }

    @Test("U-S2-D8: a heading with emphasis is told from a changed heading (the table keeps the marks, the block does not)")
    func testTargetWithInlineMarkdownInItsTitleIsResolved() {
        let blocks = [
            Self.heading("plain", 2, "Plain", at: 1.0),
            Block(
                id: "marked", projectId: "p", sortOrder: 2.0, blockType: .heading, textContent: "The Quiet Archive",
                markdownFragment: "## The *Quiet* Archive", headingLevel: 2)
        ]
        let sections = [Self.sectionRow("s0", 0, 2, "Plain"), Self.sectionRow("s1", 1, 2, "The *Quiet* Archive")]
        guard case .resolved(let heading, _) = SnapshotService.resolveFlatSectionTarget(sectionId: "s1", sections: sections, blocks: blocks) else {
            Issue.record("a heading with emphasis in its title was not resolved")
            return
        }
        #expect(heading.id == "marked")
        // A different title at the same position is still unresolved.
        let renamed = [Self.sectionRow("s0", 0, 2, "Plain"), Self.sectionRow("s1", 1, 2, "The *Loud* Archive")]
        if case .resolved = SnapshotService.resolveFlatSectionTarget(sectionId: "s1", sections: renamed, blocks: blocks) {
            Issue.record("a changed title was resolved")
        }
    }

    @Test("U-S2-D8: a table that is behind the document is unresolved, not guessed")
    func testTargetWhoseTableRowDisagreesIsUnresolved() {
        // The user typed a new heading since the last section sync: the document has one more section before "Section B".
        let blocks = [
            Self.heading("a", 2, "Section A", at: 1.0), Self.heading("new", 2, "A heading typed a moment ago", at: 2.0),
            Self.heading("b", 2, "Section B", at: 3.0)
        ]
        let sections = [Self.sectionRow("sa", 0, 2, "Section A"), Self.sectionRow("sb", 1, 2, "Section B")]
        guard case .unresolved(let reason) = SnapshotService.resolveFlatSectionTarget(sectionId: "sb", sections: sections, blocks: blocks) else {
            Issue.record("a table that is behind the document was resolved")
            return
        }
        #expect(reason.contains("position 1"), "got: \(reason)")
        // And a row the table does not have (or a managed one) is unresolved too.
        if case .resolved = SnapshotService.resolveFlatSectionTarget(sectionId: "nope", sections: sections, blocks: blocks) {
            Issue.record("an unknown section id was resolved")
        }
    }

    @Test("U-S2-D8: a section break is never resolved (its table title is not the block's)")
    func testSectionBreakIsUnresolved() {
        let breakBlock = Block(
            id: "brk", projectId: "p", sortOrder: 3.0, blockType: .sectionBreak, textContent: "", markdownFragment: "<!-- ::break:: -->",
            isPseudoSection: true)
        let blocks = [Self.heading("a", 2, "Section A", at: 1.0), Self.paragraph("pa", "a", at: 2.0), breakBlock]
        let sections = [Self.sectionRow("sa", 0, 2, "Section A"), Self.sectionRow("sbrk", 1, 2, "§ Section Break")]
        guard case .unresolved = SnapshotService.resolveFlatSectionTarget(sectionId: "sbrk", sections: sections, blocks: blocks) else {
            Issue.record("a section break was resolved")
            return
        }
        // The section before it still is.
        guard case .resolved(let heading, _) = SnapshotService.resolveFlatSectionTarget(sectionId: "sa", sections: sections, blocks: blocks) else {
            Issue.record("the section before the break was not resolved")
            return
        }
        #expect(heading.id == "a")
    }

    // MARK: - U-S2-W1

    @Test("U-S2-W1: replaceFlatSectionRange replaces the heading and its own body, not its sub-sections, and moves no epoch")
    func testReplaceFlatSectionRangeKeepsSubSectionsAndEpoch() throws {
        let (db, pid) = try makeDatabase(Self.document)
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)
        let stampedId = "h-chapter"
        try db.dbWriter.write { database in
            try database.execute(sql: "UPDATE block SET lastWriteEpoch = 5, lastWriteSequence = 9 WHERE id = ?", arguments: [stampedId])
        }
        let rows = newRows("h-chapter", "p-new-1", "p-new-2", startingWithHeading: "h-chapter")

        let replaced = try db.dbWriter.write { database in
            try ProjectDatabase.replaceFlatSectionRange(db: database, projectId: pid, headingId: "h-chapter", rows: rows)
        }
        #expect(replaced, "the heading was not a replaceable section")

        let after = BlockParser.assemblySorted(try db.fetchBlocks(projectId: pid))
        #expect(
            after.map(\.id) == ["h-chapter", "p-new-1", "p-new-2", "h-a", "p-a", "h-b", "p-b", "h-notes", "p-note"],
            "removed sub-sections or misplaced the new rows: \(after.map(\.id))")
        #expect(after.first?.textContent == "Restored heading", "the heading row was not written again")
        let order = after.map(\.sortOrder)
        #expect(order == order.sorted() && Set(order).count == order.count, "sort orders are not strictly increasing: \(order)")
        #expect(order[3] == 3.0 && order[4] == 4.0, "a row outside the range was renumbered: \(order)")
        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore, "the write bumped the project's write epoch")
        let stamp = try db.dbWriter.read { database in try ProjectDatabase.storedStamp(db: database, blockId: stampedId) }
        #expect(stamp == BlockWriteStamp(epoch: 5, sequence: 9), "a row that survives lost its write stamp: \(String(describing: stamp))")
        let parent = after.first { $0.id == "h-a" }?.sectionParentId
        #expect(parent == "h-chapter", "the section parents were not recomputed: \(String(describing: parent))")
    }

    @Test("U-S2-W1: replaceFlatSectionRange refuses a Notes heading and an unknown id without writing")
    func testReplaceFlatSectionRangeRefusesWhatIsNotASection() throws {
        let (db, pid) = try makeDatabase(Self.document)
        let before = try db.fetchBlocks(projectId: pid).map(\.id)
        for headingId in ["h-notes", "nope", "p-a"] {
            let replaced = try db.dbWriter.write { database in
                try ProjectDatabase.replaceFlatSectionRange(
                    db: database, projectId: pid, headingId: headingId, rows: [Self.paragraph("x-\(headingId)", "x", at: 0)])
            }
            #expect(!replaced, "\(headingId) was replaced")
        }
        #expect(try db.fetchBlocks(projectId: pid).map(\.id) == before, "a refused replace wrote rows")
    }

    // MARK: - U-S2-W2

    @Test("U-S2-W2: insertRows with no anchor puts the rows after the last block that is not Notes, above the Notes")
    func testInsertRowsWithoutAnAnchorGoesAboveTheNotes() throws {
        let (db, pid) = try makeDatabase(Self.document)
        let rows = newRows("c-1", "c-2", startingWithHeading: "c-1")

        let inserted = try db.dbWriter.write { database in
            try ProjectDatabase.insertRows(db: database, projectId: pid, afterBlockId: nil, rows: rows)
        }
        #expect(inserted)
        let ids = BlockParser.assemblySorted(try db.fetchBlocks(projectId: pid)).map(\.id)
        #expect(ids == ["h-chapter", "p-chapter", "h-a", "p-a", "h-b", "p-b", "c-1", "c-2", "h-notes", "p-note"], "got \(ids)")
    }

    @Test("U-S2-W2: insertRows after a named block puts the rows right after it; a managed or unknown anchor writes nothing")
    func testInsertRowsAfterAnAnchor() throws {
        let (db, pid) = try makeDatabase(Self.document)
        let rows = newRows("c-1", "c-2", startingWithHeading: "c-1")
        let inserted = try db.dbWriter.write { database in
            try ProjectDatabase.insertRows(db: database, projectId: pid, afterBlockId: "p-a", rows: rows)
        }
        #expect(inserted)
        let ids = BlockParser.assemblySorted(try db.fetchBlocks(projectId: pid)).map(\.id)
        #expect(ids == ["h-chapter", "p-chapter", "h-a", "p-a", "c-1", "c-2", "h-b", "p-b", "h-notes", "p-note"], "got \(ids)")

        for anchor in ["p-note", "h-notes", "nope"] {
            let refused = try db.dbWriter.write { database in
                try ProjectDatabase.insertRows(
                    db: database, projectId: pid, afterBlockId: anchor, rows: [Self.paragraph("y-\(anchor)", "y", at: 0)])
            }
            #expect(!refused, "an insert after \(anchor) was accepted")
        }
        #expect(try db.fetchBlocks(projectId: pid).count == 10, "a refused insert wrote rows")
    }
}
