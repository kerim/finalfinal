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

    // MARK: - Helpers

    private func createTestDatabase(content: String) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/reorder-test-\(UUID().uuidString).ff")
        return try TestFixtureFactory.createFixture(at: url, content: content)
    }

    private func fetchBlocks(_ db: ProjectDatabase) throws -> [Block] {
        try db.dbWriter.read { database in
            try Block
                .filter(Block.Columns.projectId != "")
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
    }

    private func getProjectId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }
    }

    private func headingBlocks(_ blocks: [Block]) -> [Block] {
        blocks.filter { $0.blockType == .heading }
    }

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

        let db = try createTestDatabase(content: content)
        let pid = try getProjectId(db)
        let blocks = try fetchBlocks(db)

        // Build SectionViewModels from heading blocks
        let headings = headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Move Section A (index 1) to after Section C (index 3)
        // New order: Document, Section B, Section C, Section A
        let sectionA = sections.remove(at: 1)  // Remove "Section A"
        sections.append(sectionA)               // Append at end

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try fetchBlocks(db)
        let headingsAfter = headingBlocks(blocksAfter)

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

        let db = try createTestDatabase(content: content)
        let pid = try getProjectId(db)
        let blocks = try fetchBlocks(db)
        let headings = headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Move Gamma (last) to position 1 (after Document)
        let gamma = sections.removeLast()
        sections.insert(gamma, at: 1)

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try fetchBlocks(db)
        let headingsAfter = headingBlocks(blocksAfter)
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

        let db = try createTestDatabase(content: content)
        let pid = try getProjectId(db)
        let blocks = try fetchBlocks(db)
        let headings = headingBlocks(blocks)
        var sections = headings.map { SectionViewModel(from: $0) }

        // Reverse the section order: B then A
        sections.reverse()

        try db.reorderAllBlocks(sections: sections, projectId: pid)

        let blocksAfter = try fetchBlocks(db)

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

        let db = try createTestDatabase(content: content)
        let pid = try getProjectId(db)
        let blocks = try fetchBlocks(db)
        let headings = headingBlocks(blocks)
        let sections = headings.map { SectionViewModel(from: $0) }

        // Promote Section A to H1 and demote Section B to H3
        let sectionAId = sections.first { $0.title == "Section A" }!.id
        let sectionBId = sections.first { $0.title == "Section B" }!.id

        let headingUpdates: [String: HeadingUpdate] = [
            sectionAId: HeadingUpdate(markdownFragment: "# Section A", headingLevel: 1),
            sectionBId: HeadingUpdate(markdownFragment: "### Section B", headingLevel: 3)
        ]

        try db.reorderAllBlocks(sections: sections, projectId: pid, headingUpdates: headingUpdates)

        let blocksAfter = try fetchBlocks(db)
        let headingsAfter = headingBlocks(blocksAfter)

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
        let db = try createTestDatabase(content: "# Title\n\nP1.\n\n## End\n\nEnd text.")
        let pid = try getProjectId(db)

        // Insert 60 blocks between the first two
        let blocks = try fetchBlocks(db)
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

        let blocksAfter = try fetchBlocks(db)
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
        let db = try createTestDatabase(content: "# Doc\n\nText.")
        let pid = try getProjectId(db)

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

        let blocks = try fetchBlocks(db)
        #expect(blocks.count == 2)

        // Heading should sort before paragraph at same original sortOrder
        #expect(blocks[0].blockType == .heading, "Heading should come first after normalize")
        #expect(blocks[1].blockType == .paragraph, "Paragraph should come second after normalize")
        #expect(blocks[0].sortOrder < blocks[1].sortOrder, "Sort orders should be distinct")
    }

    // MARK: - replaceBlocks Full Document

    @Test("replaceBlocks preserves heading IDs by title match (first-match-wins)")
    func replaceBlocksPreservesIDs() throws {
        let db = try createTestDatabase(content: "# Doc\n\n## Section A\n\nText.\n\n## Section B\n\nMore.")
        let pid = try getProjectId(db)

        let blocksBefore = try fetchBlocks(db)
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

        let blocksAfter = try fetchBlocks(db)
        let aAfter = blocksAfter.first { $0.textContent == "Section A" }
        let bAfter = blocksAfter.first { $0.textContent == "Section B" }

        #expect(aAfter?.id == sectionAId, "Section A ID should be preserved across re-parse")
        #expect(bAfter?.id == sectionBId, "Section B ID should be preserved across re-parse")
    }

    @Test("replaceBlocks preserves image metadata by src match")
    func replaceBlocksPreservesImageMetadata() throws {
        let db = try createTestDatabase(content: "# Doc\n\n![Alt text](media/photo.png)\n\nText.")
        let pid = try getProjectId(db)

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

        let blocksAfter = try fetchBlocks(db)
        let imageAfter = blocksAfter.first { $0.blockType == .image }

        #expect(imageAfter?.imageCaption == "Figure 1: A test image", "Image caption should be preserved")
        #expect(imageAfter?.imageWidth == 640, "Image width should be preserved")
    }
}
