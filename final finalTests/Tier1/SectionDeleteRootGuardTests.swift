//
//  SectionDeleteRootGuardTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2a, fix round 12, speed). The editor-first delete asked `sectionBlockIds` whether the clicked
//  row is a deletable section root, and that fetched and decoded EVERY block row of the project (about 1,100 on the twelve-chapter
//  book) on the main thread, only to test the result for nil. `isDeletableSectionRoot` gives the same yes or no from the one row.
//
//    - The answer must be the same for every id: `isDeletableSectionRoot == (sectionBlockIds != nil)` (a Notes heading, a
//      Bibliography heading, a paragraph, a footnote definition, an unknown id, an id of another project, a normal chapter).
//    - The read must be ONE statement that looks the row up by its id, not the whole project in sort order.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// The SQL of every statement a traced connection ran, in order.
private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func record(_ sql: String) { lock.lock(); statements.append(sql); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return statements }
}

@Suite("Delete Section's root check reads one row — Phase 4b slice 2a fix round 12 (Tier 1)")
struct SectionDeleteRootGuardTests {

    /// A project parsed from the article fixture, with the Notes and Bibliography headings flagged as the app flags them.
    private struct Project {
        let db: ProjectDatabase
        let pid: String
        let blocks: [Block]
    }

    private func makeDatabase(_ markdown: String) throws -> Project {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        try db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE block SET isNotes = 1 WHERE blockType = 'heading' AND markdownFragment = '# Notes'")
            try database.execute(
                sql: "UPDATE block SET isBibliography = 1 WHERE blockType = 'heading' AND markdownFragment = '# Bibliography'")
        }
        return Project(db: db, pid: pid, blocks: try TestFixtureFactory.fetchBlocks(from: db))
    }

    @Test("The one-row check answers exactly what sectionBlockIds answers, for every block and for ids that are not blocks")
    func testGuardAgreesWithSectionBlockIdsForEveryBlock_article() throws {
        let project = try makeDatabase(ComplexDocumentFixture.article.editorMarkdown)
        let (db, pid, blocks) = (project.db, project.pid, project.blocks)
        let notesRow = blocks.first(where: { $0.isNotes })
        let bibliographyRow = blocks.first(where: { $0.isBibliography })
        let chapterRow = blocks.first(where: { $0.blockType == .heading && !$0.isNotes && !$0.isBibliography })
        let paragraphRow = blocks.first(where: { $0.blockType == .paragraph })
        let notes = try #require(notesRow, "the fixture has a Notes heading")
        let bibliography = try #require(bibliographyRow, "the fixture has a Bibliography heading")
        let chapter = try #require(chapterRow, "the fixture has a chapter")
        let paragraph = try #require(paragraphRow, "the fixture has a paragraph")

        // The four refusals and the one yes the controller's guard depends on.
        #expect(try db.isDeletableSectionRoot(rootId: notes.id, projectId: pid) == false, "a Notes heading is refused")
        #expect(try db.isDeletableSectionRoot(rootId: bibliography.id, projectId: pid) == false, "a Bibliography heading is refused")
        #expect(try db.isDeletableSectionRoot(rootId: "no-such-block", projectId: pid) == false, "a missing id is refused")
        #expect(try db.isDeletableSectionRoot(rootId: paragraph.id, projectId: pid) == false, "a body row is not a section root")
        #expect(try db.isDeletableSectionRoot(rootId: chapter.id, projectId: pid) == true, "a normal chapter is deletable")
        #expect(
            try db.isDeletableSectionRoot(rootId: chapter.id, projectId: "another-project") == false,
            "a block of another project is not this project's root")

        // And the same answer as the old whole-project read, for every row of the document.
        for block in blocks {
            let old = try db.sectionBlockIds(rootId: block.id, projectId: pid) != nil
            let new = try db.isDeletableSectionRoot(rootId: block.id, projectId: pid)
            #expect(new == old, "block \(block.id) (\(block.blockType), notes=\(block.isNotes), bib=\(block.isBibliography)): old \(old), new \(new)")
        }
        #expect(try db.sectionBlockIds(rootId: chapter.id, projectId: "another-project") == nil)
    }

    @Test("The one-row check runs ONE statement that looks the row up by id; the old check read the whole project in sort order")
    func testGuardReadsOneRowNotTheWholeProject_book6() throws {
        let project = try makeDatabase(ComplexDocumentFixture.book6.editorMarkdown)
        let (db, pid, blocks) = (project.db, project.pid, project.blocks)
        #expect(blocks.count > 100, "a book-length project: \(blocks.count) rows")
        let chapterRow = blocks.first(where: { $0.blockType == .heading && !$0.isNotes && !$0.isBibliography })
        let chapter = try #require(chapterRow, "the fixture has a chapter")

        let newLog = StatementLog()
        let oldLog = StatementLog()
        try db.dbWriter.read { database in
            database.trace(options: .statement) { event in
                if case .statement(let statement) = event { newLog.record(statement.sql) }
            }
            _ = try ProjectDatabase.isDeletableSectionRoot(db: database, rootId: chapter.id, projectId: pid)
            database.trace(options: .statement) { event in
                if case .statement(let statement) = event { oldLog.record(statement.sql) }
            }
            _ = try ProjectDatabase.resolveSectionSubtree(db: database, rootId: chapter.id, projectId: pid)
            database.trace(options: [])
        }

        // GRDB's own schema introspection (`PRAGMA table_xinfo` / `table_list`) shows up the first time a connection reads a table; it is
        // not a read of the project. Only the SELECTs that read the block table count.
        func blockSelects(_ log: StatementLog) -> [String] {
            log.all.filter { $0.hasPrefix("SELECT") && $0.contains("\"block\"") }
        }
        let newSQL = blockSelects(newLog)
        #expect(newSQL.count == 1, "one SELECT of the block table: \(newLog.all)")
        let statement = newSQL.first ?? ""
        #expect(statement.contains("\"id\" = ?"), "it looks the row up by its id: \(statement)")
        #expect(!statement.contains("ORDER BY"), "it does not read the project in sort order: \(statement)")
        #expect(!statement.contains("\"projectId\" = ?"), "it does not read every row of the project: \(statement)")

        // The control: the probe does see the whole-project read of the old check.
        let oldSQL = blockSelects(oldLog).first ?? ""
        #expect(oldSQL.contains("\"projectId\" = ?") && oldSQL.contains("ORDER BY"), "the old check read the project in order: \(oldLog.all)")
    }
}
