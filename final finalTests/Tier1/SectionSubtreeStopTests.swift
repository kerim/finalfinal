//
//  SectionSubtreeStopTests.swift
//  final finalTests
//
//  Tier 1: `ProjectDatabase.resolveSectionSubtree`'s stop at the first Notes / Bibliography row (t-94369a83 Phase 4b, plan
//  D1.0, test W1b). The editor-first delete's range rule in the Rich Text editor (web/milkdown, tests W1) and this database
//  rule must pick the same rows for the same document, because the queued delete job deletes by the database rule what the
//  editor already removed by its own. The cases are the web matrix's: a chapter followed by a section break, a section
//  break as the root, skipped heading levels, a final chapter followed by a Notes heading one level below it, and an `hr`.
//
//  Built from explicit rows (not parsed Markdown) so each row's type, level and flags are exactly what the case names.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Section subtree — Tier 1: stops at Notes and Bibliography (W1b)")
struct SectionSubtreeStopTests {

    // MARK: - Row builders

    private static func heading(_ level: Int, _ text: String, at sort: Double, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .heading,
            textContent: text, markdownFragment: String(repeating: "#", count: level) + " " + text, headingLevel: level,
            isBibliography: bibliography, isNotes: notes
        )
    }

    private static func paragraph(_ text: String, at sort: Double, notes: Bool = false, bibliography: Bool = false) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .paragraph,
            textContent: text, markdownFragment: text, isBibliography: bibliography, isNotes: notes
        )
    }

    private static func sectionBreak(_ text: String, at sort: Double) -> Block {
        Block(
            id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .sectionBreak,
            textContent: text, markdownFragment: "<!-- ::break:: -->", isPseudoSection: true
        )
    }

    private static func hr(_ text: String, at sort: Double) -> Block {
        Block(id: "id-\(text)", projectId: "p", sortOrder: sort, blockType: .horizontalRule, textContent: "", markdownFragment: "---")
    }

    /// A fresh database holding exactly `blocks` (their `projectId` replaced by the fixture's own).
    private func makeDatabase(_ blocks: [Block]) throws -> (db: ProjectDatabase, pid: String) {
        let db = try TestFixtureFactory.createTemporary(content: "# Seed")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        // Inserted directly (no `replaceBlocks`): its heading-id carry-over could rename the ids these cases name.
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)
            for var block in blocks {
                block.projectId = pid
                try block.insert(database)
            }
        }
        return (db, pid)
    }

    private func subtreeIds(_ db: ProjectDatabase, _ pid: String, root: String) throws -> [String]? {
        try db.sectionBlockIds(rootId: "id-\(root)", projectId: pid)
    }

    private func ids(_ names: String...) -> [String] { names.map { "id-\($0)" } }

    // MARK: - The matrix

    @Test("a chapter followed by a section break: the break is a leader at level 1, so the chapter ends before it")
    func chapterThenSectionBreak() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "A", at: 1), Self.paragraph("a body", at: 2),
            Self.sectionBreak("brk", at: 3), Self.paragraph("b body", at: 4),
            Self.heading(1, "B", at: 5)
        ])
        #expect(try subtreeIds(db, pid, root: "A") == ids("A", "a body"))
    }

    @Test("a section break as the root takes the deeper headings after it and stops at the next level-1 leader")
    func sectionBreakRoot() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "A", at: 1), Self.paragraph("a body", at: 2),
            Self.sectionBreak("brk", at: 3), Self.paragraph("b body", at: 4),
            Self.heading(2, "C", at: 5), Self.paragraph("c body", at: 6),
            Self.heading(1, "B", at: 7)
        ])
        #expect(try subtreeIds(db, pid, root: "brk") == ids("brk", "b body", "C", "c body"))
    }

    @Test("skipped heading levels: every deeper heading belongs to the root, whatever the gap")
    func skippedLevels() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(2, "X", at: 1), Self.paragraph("x body", at: 2),
            Self.heading(4, "Y", at: 3), Self.paragraph("y body", at: 4),
            Self.heading(3, "Z", at: 5), Self.paragraph("z body", at: 6),
            Self.heading(2, "W", at: 7)
        ])
        #expect(try subtreeIds(db, pid, root: "X") == ids("X", "x body", "Y", "y body", "Z", "z body"))
    }

    @Test("a final chapter followed by a Notes heading one level below it does not take the Notes heading or its rows")
    func finalChapterThenNotesHeading() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.heading(2, "Notes", at: 3, notes: true), Self.paragraph("the footnote", at: 4, notes: true)
        ])
        // Without the stop, the Notes H2 (2 > 1) joined the chapter, and its footnote rows hang under it as its body.
        #expect(try subtreeIds(db, pid, root: "Ch") == ids("Ch", "ch body"))
    }

    @Test("a final chapter followed by a Bibliography heading below it does not take the Bibliography rows")
    func finalChapterThenBibliographyHeading() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.heading(2, "References", at: 3, bibliography: true), Self.paragraph("an entry", at: 4, bibliography: true)
        ])
        #expect(try subtreeIds(db, pid, root: "Ch") == ids("Ch", "ch body"))
    }

    @Test("an hr is never a leader: it stays inside the section and does not end it")
    func hrIsNotALeader() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(2, "A", at: 1), Self.paragraph("a body", at: 2),
            Self.hr("rule", at: 3), Self.paragraph("after the rule", at: 4),
            Self.heading(2, "B", at: 5)
        ])
        #expect(try subtreeIds(db, pid, root: "A") == ids("A", "a body", "rule", "after the rule"))
    }

    // MARK: - The two callers that share the rule

    @Test("deleteSections of a final chapter leaves the Notes heading and its footnote rows in place")
    func deleteLeavesNotesRowsAlone() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.heading(2, "Notes", at: 3, notes: true), Self.paragraph("the footnote", at: 4, notes: true)
        ])

        let title = try db.deleteSections(rootId: "id-Ch", projectId: pid)

        #expect(title == "Ch")
        let remaining = try db.fetchBlocks(projectId: pid).map(\.id)
        #expect(remaining == ids("Notes", "the footnote"))
    }

    @Test("duplicateSections of a final chapter does not copy the Notes heading or its footnote rows")
    func duplicateLeavesNotesRowsAlone() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.heading(2, "Notes", at: 3, notes: true), Self.paragraph("the footnote", at: 4, notes: true)
        ])

        _ = try db.duplicateSections(rootId: "id-Ch", projectId: pid)

        let rows = try db.fetchBlocks(projectId: pid)
        #expect(rows.filter(\.isNotes).count == 2, "still exactly one Notes heading and one footnote row")
        #expect(rows.count == 6, "the chapter heading and its body were copied, nothing else")
    }

    // MARK: - The bibliography's opening marker (fix round 2a, item 10)

    /// The bibliography's opening marker as `BlockParser` stores it: its own `.bibliography` row (not a heading), flagged, sitting
    /// between the last chapter and the bibliography heading.
    private static func bibliographyMarker(at sort: Double) -> Block {
        Block(
            id: "id-marker", projectId: "p", sortOrder: sort, blockType: .bibliography,
            textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->", isBibliography: true
        )
    }

    private static let documentWithBibliography: [Block] = [
        SectionSubtreeStopTests.heading(1, "Ch", at: 1), SectionSubtreeStopTests.paragraph("ch body", at: 2),
        SectionSubtreeStopTests.bibliographyMarker(at: 3),
        SectionSubtreeStopTests.heading(1, "Bibliography", at: 4, bibliography: true),
        SectionSubtreeStopTests.paragraph("an entry", at: 5, bibliography: true)
    ]

    @Test("the LAST chapter of a document with a bibliography does not take the bibliography's opening marker row")
    func lastChapterThenStandaloneBibliographyMarker() throws {
        let (db, pid) = try makeDatabase(Self.documentWithBibliography)
        // Without the stop on non-leader managed rows, the marker row was filed under the chapter before it: the editor's range
        // (which stops at the first managed row) kept it while the database job deleted it.
        #expect(try subtreeIds(db, pid, root: "Ch") == ids("Ch", "ch body"))
    }

    @Test("deleteSections of the last chapter leaves the bibliography's marker row, heading and entries in place")
    func deleteLeavesTheBibliographyMarkerAlone() throws {
        let (db, pid) = try makeDatabase(Self.documentWithBibliography)

        let title = try db.deleteSections(rootId: "id-Ch", projectId: pid)

        #expect(title == "Ch")
        #expect(try db.fetchBlocks(projectId: pid).map(\.id) == ids("marker", "Bibliography", "an entry"))
    }

    @Test("a headingless bibliography run after the last chapter is not part of that chapter either")
    func lastChapterThenHeadinglessBibliographyRun() throws {
        let (db, pid) = try makeDatabase([
            Self.heading(1, "Ch", at: 1), Self.paragraph("ch body", at: 2),
            Self.paragraph("entry one", at: 3, bibliography: true), Self.paragraph("entry two", at: 4, bibliography: true)
        ])
        #expect(try subtreeIds(db, pid, root: "Ch") == ids("Ch", "ch body"))
    }
}
