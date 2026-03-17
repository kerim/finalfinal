//
//  SectionOperationsTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for section-level database operations: insert heading,
//  delete heading, update heading content/level, add between sections.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Section Operations — Tier 2: Visible Breakage")
struct SectionOperationsTests {

    // MARK: - Insert Heading

    @Test("Insert heading block at specific sort order appears in correct position")
    func insertHeadingAtPosition() throws {
        let content = """
        # Document

        Intro text.

        ## Section A

        Content A.

        ## Section B

        Content B.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)

        // Find sort orders of Section A and Section B headings
        let sectionA = blocksBefore.first { $0.textContent == "Section A" }!
        let sectionB = blocksBefore.first { $0.textContent == "Section B" }!

        // Insert a heading between A and B
        let midSortOrder = (sectionA.sortOrder + sectionB.sortOrder) / 2.0

        try db.dbWriter.write { database in
            var newHeading = Block(
                projectId: pid,
                sortOrder: midSortOrder,
                blockType: .heading,
                textContent: "Section A.5",
                markdownFragment: "## Section A.5",
                headingLevel: 2
            )
            try newHeading.insert(database)
        }

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocksAfter)
        let titles = headings.map { $0.textContent }

        #expect(titles == ["Document", "Section A", "Section A.5", "Section B"])
    }

    // MARK: - Delete Heading

    @Test("Delete heading block — its body paragraphs become orphans")
    func deleteHeadingOrphansBody() throws {
        let content = """
        ## Section A

        Paragraph in A.

        ## Section B

        Paragraph in B.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = blocksBefore.first { $0.textContent == "Section A" }!
        let countBefore = blocksBefore.count

        // Delete Section A heading
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.id == sectionA.id).deleteAll(database)
        }

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocksAfter.count == countBefore - 1)

        // Section A's paragraph now precedes Section B heading
        let headings = TestFixtureFactory.headingBlocks(blocksAfter)
        #expect(headings.count == 1)
        #expect(headings[0].textContent == "Section B")

        // "Paragraph in A." is still in the document
        #expect(blocksAfter.contains { $0.textContent == "Paragraph in A." })
    }

    // MARK: - Update Heading Content

    @Test("Update heading block content (title change) persists in DB")
    func updateHeadingTitle() throws {
        let db = try TestFixtureFactory.createTemporary()
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let heading = blocks.first { $0.blockType == .heading }!

        try db.dbWriter.write { database in
            var updated = heading
            updated.textContent = "New Title"
            updated.markdownFragment = "# New Title"
            try updated.update(database)
        }

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let updatedHeading = blocksAfter.first { $0.id == heading.id }!
        #expect(updatedHeading.textContent == "New Title")
        #expect(updatedHeading.markdownFragment == "# New Title")
    }

    // MARK: - Heading Level Change

    @Test("Heading level change (H2→H1) via block content update reflects in DB")
    func headingLevelChange() throws {
        let content = """
        # Document

        Intro.

        ## Subsection

        Content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let subsection = blocks.first { $0.textContent == "Subsection" }!

        #expect(subsection.headingLevel == 2)

        try db.dbWriter.write { database in
            var updated = subsection
            updated.headingLevel = 1
            updated.markdownFragment = "# Subsection"
            try updated.update(database)
        }

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let promoted = blocksAfter.first { $0.id == subsection.id }!
        #expect(promoted.headingLevel == 1)
        #expect(promoted.markdownFragment == "# Subsection")
    }

    // MARK: - Add Section Between Existing

    @Test("Add new section between existing sections — sort orders remain valid")
    func addSectionBetweenExisting() throws {
        let content = """
        ## First

        Content 1.

        ## Third

        Content 3.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        let first = blocks.first { $0.textContent == "First" }!
        let third = blocks.first { $0.textContent == "Third" }!

        // Insert "Second" between First's last body block and Third heading
        let bodyAfterFirst = blocks.filter {
            $0.sortOrder > first.sortOrder && $0.sortOrder < third.sortOrder
        }
        let insertAfter = bodyAfterFirst.last ?? first
        let insertSortOrder = (insertAfter.sortOrder + third.sortOrder) / 2.0

        try db.dbWriter.write { database in
            var heading = Block(
                projectId: pid,
                sortOrder: insertSortOrder,
                blockType: .heading,
                textContent: "Second",
                markdownFragment: "## Second",
                headingLevel: 2
            )
            try heading.insert(database)

            var para = Block(
                projectId: pid,
                sortOrder: insertSortOrder + 0.1,
                blockType: .paragraph,
                textContent: "Content 2.",
                markdownFragment: "Content 2."
            )
            try para.insert(database)
        }

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocksAfter)
        let titles = headings.map { $0.textContent }

        #expect(titles == ["First", "Second", "Third"])

        // All sort orders should be strictly increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder,
                    "Sort orders must increase: [\(i-1)]=\(blocksAfter[i-1].sortOrder), [\(i)]=\(blocksAfter[i].sortOrder)")
        }
    }

    // MARK: - Section Title Update Persistence

    @Test("Section title update persists through DB read-back")
    func titleUpdatePersistsThroughReadBack() throws {
        let db = try TestFixtureFactory.createTemporary()
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let heading = blocks.first { $0.blockType == .heading }!

        let newTitle = "Updated Title \(UUID().uuidString)"
        try db.dbWriter.write { database in
            var updated = heading
            updated.textContent = newTitle
            updated.markdownFragment = "# \(newTitle)"
            try updated.update(database)
        }

        // Read back in a separate transaction
        let readBack = try db.dbWriter.read { database in
            try Block.filter(Block.Columns.id == heading.id).fetchOne(database)
        }

        #expect(readBack?.textContent == newTitle)
    }
}
