//
//  SnapshotSectionParityTests.swift
//  final finalTests
//
//  Tier 1: addendum A8 of the section-delete plan (t-94369a83 Phase 4b, test U17). The Version History snapshot a
//  `SectionDeleteJob` writes inside its own transaction takes its section list from the block rows
//  (`SnapshotService.derivedSnapshotSections`), where `createUndoPointSnapshot()` takes it from `fetchSections()`. A8: for the
//  documents the app is tested on, the two lists must be equal field for field, for every field `SnapshotSection(from:)` copies
//  (originalSectionId = the section's id, title, markdownContent, headerLevel, sortOrder, status, tags, wordGoal) and for the
//  rest of `Section` too except the two timestamps.
//
//  How the `section` table is filled here: through the production entry point `SectionSyncService.syncNow`, fed the text the
//  EDITOR holds (the fixture's editor-form Markdown), while the derived list is computed from the text assembled from the block
//  rows (fix round 2a, item 17: they used to share one `parseHeaders` call, so the test compared the derivation with a copy of its
//  own logic). Then a few rows get non-default status, tags and goals so that the fields the derived list must read from the table
//  are not all defaults.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Snapshot section list — Tier 1: derived from block rows equals fetchSections() (A8, U17)", .serialized)
@MainActor
struct SnapshotSectionParityTests {

    // MARK: - Fixture

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        /// The whole document assembled from the block rows, the text the snapshot is taken from.
        let assembled: String
    }

    /// A database holding `markdown` as block rows, its `section` table filled the way the section sync fills it, and a few
    /// rows given non-default metadata.
    private func makeFixture(_ markdown: String) async throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try db.fetchBlocks(projectId: pid)
        let assembled = BlockParser.assembleMarkdownForEditor(from: blocks)

        // The `section` table is filled by the real production entry point, `SectionSyncService.syncNow`, fed the text the EDITOR
        // holds (`markdown`, the editor's own form), not the text the derived list is computed from (`assembled`, rebuilt from the
        // block rows). Before fix round 2a (item 17) both came from the same `parseHeaders` call on the same assembled text, so the
        // test compared the derivation with a copy of its own logic.
        let sectionSync = SectionSyncService()
        sectionSync.configure(database: db, projectId: pid)
        await sectionSync.syncNow(markdown)

        let seeded = try db.fetchSections(projectId: pid)
        for (index, section) in seeded.enumerated() where index % 7 == 3 && !section.isNotes && !section.isBibliography {
            try db.updateSectionStatus(id: section.id, status: .review)
            try db.updateSectionTags(id: section.id, tags: ["alpha", "beta-\(index)"])
            try db.updateSectionWordGoal(id: section.id, goal: 500 + index)
        }
        return Fixture(db: db, pid: pid, assembled: assembled)
    }

    /// Non-async on purpose: in an async test `dbWriter.read` resolves to GRDB's async overload.
    private func derived(_ fixture: Fixture, markdown: String? = nil) throws -> [Section] {
        try fixture.db.dbWriter.read { database in
            try SnapshotService.derivedSnapshotSections(
                db: database, projectId: fixture.pid, markdown: markdown ?? fixture.assembled, fallbackBibliographyTitle: "Bibliography")
        }
    }

    /// The names of the fields on which two sections differ (timestamps excluded: `SnapshotSection(from:)` does not copy them).
    private func differingFields(_ lhs: Section, _ rhs: Section) -> [String] {
        let checks: [(name: String, same: Bool)] = [
            ("id", lhs.id == rhs.id), ("projectId", lhs.projectId == rhs.projectId), ("parentId", lhs.parentId == rhs.parentId),
            ("sortOrder", lhs.sortOrder == rhs.sortOrder), ("headerLevel", lhs.headerLevel == rhs.headerLevel),
            ("isPseudoSection", lhs.isPseudoSection == rhs.isPseudoSection), ("isBibliography", lhs.isBibliography == rhs.isBibliography),
            ("isNotes", lhs.isNotes == rhs.isNotes), ("title", lhs.title == rhs.title),
            ("markdownContent", lhs.markdownContent == rhs.markdownContent), ("status", lhs.status == rhs.status),
            ("tags", lhs.tags == rhs.tags), ("wordGoal", lhs.wordGoal == rhs.wordGoal), ("goalType", lhs.goalType == rhs.goalType),
            ("aggregateGoal", lhs.aggregateGoal == rhs.aggregateGoal),
            ("aggregateGoalType", lhs.aggregateGoalType == rhs.aggregateGoalType),
            ("wordCount", lhs.wordCount == rhs.wordCount), ("startOffset", lhs.startOffset == rhs.startOffset)
        ]
        return checks.filter { !$0.same }.map(\.name)
    }

    private func assertParity(_ markdown: String, label: String) async throws {
        let fixture = try await makeFixture(markdown)
        let fetched = try fixture.db.fetchSections(projectId: fixture.pid)
        let derivedList = try derived(fixture)

        #expect(fetched.count > 5, "\(label): the fixture produces a real section list (\(fetched.count))")
        #expect(derivedList.count == fetched.count, "\(label): same number of sections (\(derivedList.count) vs \(fetched.count))")
        #expect(fetched.contains { $0.isNotes } && fetched.contains { $0.isBibliography },
                "\(label): the list includes the machine-managed Notes and Bibliography sections")
        #expect(fetched.contains { $0.status == .review && $0.tags.first == "alpha" && $0.wordGoal != nil },
                "\(label): the table-sourced fields are not all defaults in this fixture")

        for (index, pair) in zip(derivedList, fetched).enumerated() {
            let differing = differingFields(pair.0, pair.1)
            #expect(differing.isEmpty, "\(label): section \(index) (\(pair.1.title)) differs in \(differing)")
        }
    }

    // MARK: - U17

    @Test("testDerivedEqualsFetchSections_book6")
    func testDerivedEqualsFetchSections_book6() async throws {
        try await assertParity(ComplexDocumentFixture.book6.editorMarkdown, label: "book6")
    }

    @Test("testDerivedEqualsFetchSections_article")
    func testDerivedEqualsFetchSections_article() async throws {
        try await assertParity(ComplexDocumentFixture.article.editorMarkdown, label: "article")
    }

    @Test("testDerivedFollowsBlockRowsWhenSectionTableLags: a heading renamed in the rows since the last section sync is listed under its new title")
    func testDerivedFollowsBlockRowsWhenSectionTableLags() async throws {
        let fixture = try await makeFixture(ComplexDocumentFixture.article.editorMarkdown)
        let before = try fixture.db.fetchSections(projectId: fixture.pid)
        let target = try #require(before.first { !$0.isNotes && !$0.isBibliography && !$0.isPseudoSection && $0.headerLevel == 2 })
        let headingBlock = try #require(try fixture.db.fetchBlocks(projectId: fixture.pid).first {
            $0.blockType == .heading && $0.textContent == target.title
        })

        var renamed = headingBlock
        renamed.textContent = "A brand new heading title"
        renamed.markdownFragment = String(repeating: "#", count: target.headerLevel) + " A brand new heading title"
        try fixture.db.updateBlock(renamed)
        let assembled = BlockParser.assembleMarkdownForEditor(from: try fixture.db.fetchBlocks(projectId: fixture.pid))

        let derivedList = try derived(fixture, markdown: assembled)

        #expect(derivedList.contains { $0.title == "A brand new heading title" }, "the snapshot follows the block rows")
        #expect(!derivedList.contains { $0.title == target.title }, "the old title is gone from the derived list")
        let stale = try fixture.db.fetchSections(projectId: fixture.pid)
        #expect(stale.contains { $0.title == target.title }, "the legacy table still has the old title: that is what lagging means")
        let renamedSection = try #require(derivedList.first { $0.title == "A brand new heading title" })
        #expect(renamedSection.sortOrder == target.sortOrder, "it sits at the same position")
    }
}
