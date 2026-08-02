//
//  BlockReorderIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for block reorder operations. Reorder is a direct DB write —
//  wrong sort orders = corrupt document in storage.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Block Reorder Integrity — Tier 1: Silent Killers")
struct BlockReorderIntegrityTests {

    // MARK: - Sort Order Correctness After Reorder

    @Test("Sort order is correct after moving section down")
    @MainActor
    func sortOrderAfterMoveDown() throws {
        let content = """
        # Document

        Intro text.

        ## Section A

        Content A.

        ## Section B

        Content B.

        ## Section C

        Content C.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Build SectionViewModels from heading blocks
        let headings = TestFixtureFactory.headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Move Section A (index 1) to after Section C (index 3)
        // New order: Document, Section B, Section C, Section A
        let sectionA = sections.remove(at: 1)  // Remove "Section A"
        sections.append(sectionA)               // Append at end

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)

        // Verify new heading order
        let titles = headingsAfter.map { $0.textContent }
        #expect(titles == ["Document", "Section B", "Section C", "Section A"],
                "Headings should be in reordered sequence")

        // Verify all sort orders are monotonically increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder,
                    "Sort orders must increase: block[\(i-1)]=\(blocksAfter[i-1].sortOrder), block[\(i)]=\(blocksAfter[i].sortOrder)")
        }
    }

    @Test("Sort order is correct after moving section up")
    @MainActor
    func sortOrderAfterMoveUp() throws {
        let content = """
        # Document

        Intro.

        ## Alpha

        Alpha content.

        ## Beta

        Beta content.

        ## Gamma

        Gamma content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Move Gamma (last) to position 1 (after Document)
        let gamma = sections.removeLast()
        sections.insert(gamma, at: 1)

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)
        let titles = headingsAfter.map { $0.textContent }

        #expect(titles == ["Document", "Gamma", "Alpha", "Beta"])
    }

    // MARK: - Body Blocks Follow Heading

    @Test("Body blocks follow their heading after reorder")
    @MainActor
    func bodyBlocksFollowHeading() throws {
        let content = """
        ## Section A

        Paragraph in A.

        ## Section B

        Paragraph in B.

        Another paragraph in B.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Reverse the section order: B then A
        sections.reverse()

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // Find Section B heading and verify its body follows
        let bHeadingIdx = blocksAfter.firstIndex { $0.textContent == "Section B" }!
        let aHeadingIdx = blocksAfter.firstIndex { $0.textContent == "Section A" }!

        #expect(bHeadingIdx < aHeadingIdx, "Section B should come before Section A")

        // Body blocks between B heading and A heading should be B's content
        let bBody = blocksAfter[(bHeadingIdx + 1)..<aHeadingIdx]
        let bBodyTexts = bBody.map { $0.textContent }

        #expect(bBodyTexts.contains("Paragraph in B."), "B's first paragraph should follow B's heading")
        #expect(bBodyTexts.contains("Another paragraph in B."), "B's second paragraph should follow B's heading")
        #expect(!bBodyTexts.contains("Paragraph in A."), "A's paragraph should NOT be under B")
    }

    // MARK: - Heading Level Changes

    @Test("Heading level changes applied during reorder")
    @MainActor
    func headingLevelChangesApplied() throws {
        let content = """
        ## Section A

        Content.

        ## Section B

        Content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)
        let sections = headings.map { SectionViewModel(from: $0) }

        // Promote Section A to H1 and demote Section B to H3
        let sectionAId = sections.first { $0.title == "Section A" }!.id
        let sectionBId = sections.first { $0.title == "Section B" }!.id

        let headingUpdates: [String: HeadingUpdate] = [
            sectionAId: HeadingUpdate(markdownFragment: "# Section A", headingLevel: 1),
            sectionBId: HeadingUpdate(markdownFragment: "### Section B", headingLevel: 3)
        ]

        try db.reorderAllBlocks(sections: sections, projectId: pid, headingUpdates: headingUpdates)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)

        let aAfter = headingsAfter.first { $0.textContent == "Section A" }!
        let bAfter = headingsAfter.first { $0.textContent == "Section B" }!

        #expect(aAfter.headingLevel == 1, "Section A should be promoted to H1")
        #expect(aAfter.markdownFragment == "# Section A")
        #expect(bAfter.headingLevel == 3, "Section B should be demoted to H3")
        #expect(bAfter.markdownFragment == "### Section B")
    }

    // MARK: - Sort Order Precision

    @Test("Sort-order precision: 60+ blocks between adjacent sort orders all distinct")
    func sortOrderPrecisionManyBlocks() throws {
        // Create a document, then do repeated reorderBlock operations
        let db = try TestFixtureFactory.createTemporary(content: "# Title\n\nP1.\n\n## End\n\nEnd text.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Insert 60 blocks between the first two
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        guard blocks.count >= 2 else {
            Issue.record("Need at least 2 blocks")
            return
        }

        for i in 0..<60 {
            try db.dbWriter.write { database in
                var block = Block(
                    projectId: pid,
                    sortOrder: Double(blocks[0].sortOrder) + Double(i + 1) * 0.001,
                    blockType: .paragraph,
                    textContent: "Inserted \(i)",
                    markdownFragment: "Inserted \(i)"
                )
                try block.insert(database)
            }
        }

        // Normalize to fix any precision issues
        try db.normalizeSortOrders(projectId: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let sortOrders = blocksAfter.map { $0.sortOrder }

        #expect(Set(sortOrders).count == sortOrders.count,
                "All \(sortOrders.count) sort orders must be distinct after normalization")

        // Verify monotonically increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder)
        }
    }

    // MARK: - Normalize Sort Orders

    @Test("Normalize resolves duplicate sort orders with heading priority")
    func normalizeHeadingPriority() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nText.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Manually create blocks with duplicate sort orders
        try db.dbWriter.write { database in
            try Block.filter(Block.Columns.projectId == pid).deleteAll(database)

            var heading = Block(projectId: pid, sortOrder: 1.0, blockType: .heading,
                               textContent: "Heading", markdownFragment: "## Heading", headingLevel: 2)
            try heading.insert(database)

            var paragraph = Block(projectId: pid, sortOrder: 1.0, blockType: .paragraph,
                                  textContent: "Body", markdownFragment: "Body")
            try paragraph.insert(database)
        }

        try db.normalizeSortOrders(projectId: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocks.count == 2)

        // Heading should sort before paragraph at same original sortOrder
        #expect(blocks[0].blockType == .heading, "Heading should come first after normalize")
        #expect(blocks[1].blockType == .paragraph, "Paragraph should come second after normalize")
        #expect(blocks[0].sortOrder < blocks[1].sortOrder, "Sort orders should be distinct")
    }

    // MARK: - replaceBlocks Full Document

    @Test("replaceBlocks preserves heading IDs by title match (first-match-wins)")
    func replaceBlocksPreservesIDs() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\n## Section A\n\nText.\n\n## Section B\n\nMore.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionAId = blocksBefore.first { $0.textContent == "Section A" }?.id
        let sectionBId = blocksBefore.first { $0.textContent == "Section B" }?.id

        #expect(sectionAId != nil)
        #expect(sectionBId != nil)

        // Re-parse with same titles
        let newBlocks = [
            Block(projectId: pid, sortOrder: 1, blockType: .heading, textContent: "Doc",
                  markdownFragment: "# Doc", headingLevel: 1),
            Block(projectId: pid, sortOrder: 2, blockType: .paragraph, textContent: "Updated intro.",
                  markdownFragment: "Updated intro."),
            Block(projectId: pid, sortOrder: 3, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 4, blockType: .paragraph, textContent: "Updated A.",
                  markdownFragment: "Updated A."),
            Block(projectId: pid, sortOrder: 5, blockType: .heading, textContent: "Section B",
                  markdownFragment: "## Section B", headingLevel: 2),
            Block(projectId: pid, sortOrder: 6, blockType: .paragraph, textContent: "Updated B.",
                  markdownFragment: "Updated B.")
        ]

        try db.replaceBlocks(newBlocks, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let aAfter = blocksAfter.first { $0.textContent == "Section A" }
        let bAfter = blocksAfter.first { $0.textContent == "Section B" }

        #expect(aAfter?.id == sectionAId, "Section A ID should be preserved across re-parse")
        #expect(bAfter?.id == sectionBId, "Section B ID should be preserved across re-parse")
    }

    // MARK: - Duplicate-Titled Headings (FIFO occurrence-index matching)
    //
    // Regression coverage for the heading-id-churn bug: `replaceBlocks` used to preserve a
    // heading's id via a title -> single-id dictionary (first-match-wins) while metadata used a
    // separate title -> single-metadata dictionary (last-match-wins, never cleared after use).
    // With two headings sharing a title, only the FIRST new occurrence ever got a preserved id
    // (the second got a fresh UUID on every re-parse, churning its `<!-- @sid:UUID -->` anchor),
    // and EVERY new occurrence with that title got the LAST existing occurrence's metadata
    // (cross-contaminating status/tags/word goals across same-titled headings). The fix replaces
    // both dictionaries with one title -> FIFO queue of (id, metadata) pairs, consumed in
    // document order, so the nth new occurrence of a title inherits from the nth old occurrence.

    @Test("replaceBlocks preserves both occurrences' IDs when two headings share a title")
    func replaceBlocksPreservesDuplicateTitleIDs() throws {
        let content = """
        # Doc

        ## Duplicate

        First occurrence body.

        ## Duplicate

        Second occurrence body.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsBefore = blocksBefore.filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
        #expect(duplicateHeadingsBefore.count == 2, "Fixture should have two headings titled 'Duplicate'")
        let firstIdBefore = duplicateHeadingsBefore[0].id
        let secondIdBefore = duplicateHeadingsBefore[1].id
        #expect(firstIdBefore != secondIdBefore, "The two occurrences must start with distinct ids")

        // Re-parse: same two same-titled headings, in the same order, with edited body text —
        // simulating a normal user edit flush, not a reorder.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 1, blockType: .heading, textContent: "Doc",
                  markdownFragment: "# Doc", headingLevel: 1),
            Block(projectId: pid, sortOrder: 2, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph, textContent: "Updated first body.",
                  markdownFragment: "Updated first body."),
            Block(projectId: pid, sortOrder: 4, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 5, blockType: .paragraph, textContent: "Updated second body.",
                  markdownFragment: "Updated second body.")
        ]

        try db.replaceBlocks(newBlocks, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsAfter = blocksAfter
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(duplicateHeadingsAfter.count == 2)
        #expect(duplicateHeadingsAfter[0].id == firstIdBefore, "First occurrence should keep its own original id")
        #expect(
            duplicateHeadingsAfter[1].id == secondIdBefore,
            "Second occurrence should keep its own original id — this is the id-churn bug: it used to get a fresh UUID every flush"
        )
    }

    @Test("replaceBlocks keeps duplicate-titled heading IDs stable across repeated flushes")
    func replaceBlocksDuplicateTitleIDsStableAcrossRounds() throws {
        let content = """
        # Doc

        ## Duplicate

        First body v0.

        ## Duplicate

        Second body v0.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsBefore = blocksBefore
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(duplicateHeadingsBefore.count == 2)
        let firstId = duplicateHeadingsBefore[0].id
        let secondId = duplicateHeadingsBefore[1].id

        // Flush 3-4 rounds in a row, as if the user kept editing and the document kept
        // re-parsing on every flush. Ids must remain pinned to their occurrence across all of them.
        for round in 1...4 {
            let newBlocks = [
                Block(projectId: pid, sortOrder: 1, blockType: .heading, textContent: "Doc",
                      markdownFragment: "# Doc", headingLevel: 1),
                Block(projectId: pid, sortOrder: 2, blockType: .heading, textContent: "Duplicate",
                      markdownFragment: "## Duplicate", headingLevel: 2),
                Block(projectId: pid, sortOrder: 3, blockType: .paragraph, textContent: "First body v\(round).",
                      markdownFragment: "First body v\(round)."),
                Block(projectId: pid, sortOrder: 4, blockType: .heading, textContent: "Duplicate",
                      markdownFragment: "## Duplicate", headingLevel: 2),
                Block(projectId: pid, sortOrder: 5, blockType: .paragraph, textContent: "Second body v\(round).",
                      markdownFragment: "Second body v\(round).")
            ]

            try db.replaceBlocks(newBlocks, for: pid)

            let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
            let duplicateHeadingsAfter = blocksAfter
                .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
                .sorted { $0.sortOrder < $1.sortOrder }

            #expect(duplicateHeadingsAfter.count == 2, "Round \(round): should still have exactly two 'Duplicate' headings")
            #expect(duplicateHeadingsAfter[0].id == firstId, "Round \(round): first occurrence id must stay pinned")
            #expect(duplicateHeadingsAfter[1].id == secondId, "Round \(round): second occurrence id must stay pinned")
        }
    }

    @Test("replaceBlocks pairs metadata to the matching occurrence, not last-write-wins across all duplicates")
    func replaceBlocksPairsMetadataToMatchingOccurrence() throws {
        let content = """
        # Doc

        ## Duplicate

        First occurrence body.

        ## Duplicate

        Second occurrence body.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Give each occurrence distinct, identifiable metadata.
        try db.dbWriter.write { database in
            let headings = try Block
                .filter(Block.Columns.textContent == "Duplicate")
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
            try #require(headings.count == 2)

            var first = headings[0]
            first.status = .writing
            first.tags = ["alpha"]
            first.wordGoal = 100
            try first.update(database)

            var second = headings[1]
            second.status = .final_
            second.tags = ["beta"]
            second.wordGoal = 200
            try second.update(database)
        }

        let newBlocks = [
            Block(projectId: pid, sortOrder: 1, blockType: .heading, textContent: "Doc",
                  markdownFragment: "# Doc", headingLevel: 1),
            Block(projectId: pid, sortOrder: 2, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph, textContent: "Updated first body.",
                  markdownFragment: "Updated first body."),
            Block(projectId: pid, sortOrder: 4, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 5, blockType: .paragraph, textContent: "Updated second body.",
                  markdownFragment: "Updated second body.")
        ]

        try db.replaceBlocks(newBlocks, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsAfter = blocksAfter
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(duplicateHeadingsAfter.count == 2)
        #expect(
            duplicateHeadingsAfter[0].status == .writing,
            "First occurrence should keep its OWN status, not the second's (last-write-wins would put .final_ here)"
        )
        #expect(duplicateHeadingsAfter[0].tags == ["alpha"])
        #expect(duplicateHeadingsAfter[0].wordGoal == 100)
        #expect(duplicateHeadingsAfter[1].status == .final_, "Second occurrence should keep its own status")
        #expect(duplicateHeadingsAfter[1].tags == ["beta"])
        #expect(duplicateHeadingsAfter[1].wordGoal == 200)
    }

    @Test("replaceBlocks preserves image metadata by src match")
    func replaceBlocksPreservesImageMetadata() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\n![Alt text](media/photo.png)\n\nText.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Set image metadata on the image block
        try db.dbWriter.write { database in
            if var block = try Block
                .filter(Block.Columns.blockType == BlockType.image.rawValue)
                .fetchOne(database) {
                block.imageCaption = "Figure 1: A test image"
                block.imageWidth = 640
                try block.update(database)
            }
        }

        // Re-parse with same image
        let newBlocks = [
            Block(projectId: pid, sortOrder: 1, blockType: .heading, textContent: "Doc",
                  markdownFragment: "# Doc", headingLevel: 1),
            Block(projectId: pid, sortOrder: 2, blockType: .image, textContent: "Alt text",
                  markdownFragment: "![Alt text](media/photo.png)", imageSrc: "media/photo.png",
                  imageAlt: "Alt text"),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph, textContent: "Text.",
                  markdownFragment: "Text.")
        ]

        try db.replaceBlocks(newBlocks, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let imageAfter = blocksAfter.first { $0.blockType == .image }

        #expect(imageAfter?.imageCaption == "Figure 1: A test image", "Image caption should be preserved")
        #expect(imageAfter?.imageWidth == 640, "Image width should be preserved")
    }
}
