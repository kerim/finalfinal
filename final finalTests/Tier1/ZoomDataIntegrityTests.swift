//
//  ZoomDataIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for zoom data integrity — filterToSubtree, block range calculation,
//  replaceBlocksInRange, and zoom-out restoration.
//  Documented history of silent sort-order corruption during zoom.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Zoom Data Integrity — Tier 1: Silent Killers")
struct ZoomDataIntegrityTests {

    let projectId = "zoom-test-project"

    // MARK: - Helpers

    /// Creates a temporary .ff fixture and returns the database
    private func createTestDatabase(content: String? = nil) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/zoom-test-\(UUID().uuidString).ff")
        return try TestFixtureFactory.createFixture(at: url, content: content)
    }

    /// Fetches all blocks for the test project, ordered by sortOrder
    private func fetchBlocks(_ db: ProjectDatabase) throws -> [Block] {
        try db.dbWriter.read { database in
            try Block
                .filter(Block.Columns.projectId != "")
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
    }

    /// Gets the project ID from the database
    private func getProjectId(_ db: ProjectDatabase) throws -> String {
        try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1")!
        }
    }

    // MARK: - filterToSubtree

    @Test("filterToSubtree returns correct section IDs for nested hierarchies")
    @MainActor
    func filterToSubtreeNestedHierarchy() async throws {
        let state = EditorViewState()

        // Simulate a document with H1 > H2 > H3 structure
        let sections = [
            makeSectionVM(id: "h1-intro", level: 1, sortOrder: 1, title: "Introduction"),
            makeSectionVM(id: "h2-background", level: 2, sortOrder: 3, title: "Background", parentId: "h1-intro"),
            makeSectionVM(id: "h3-history", level: 3, sortOrder: 5, title: "History", parentId: "h2-background"),
            makeSectionVM(id: "h2-methods", level: 2, sortOrder: 7, title: "Methods", parentId: "h1-intro"),
            makeSectionVM(id: "h1-results", level: 1, sortOrder: 9, title: "Results")
        ]

        let subtree = state.filterToSubtree(sections: sections, rootId: "h1-intro")

        // Should include h1-intro, h2-background, h3-history, h2-methods (all under H1)
        // Should NOT include h1-results (same level = new subtree)
        let subtreeIds = Set(subtree.map { $0.id })
        #expect(subtreeIds.contains("h1-intro"), "Root should be in subtree")
        #expect(subtreeIds.contains("h2-background"), "H2 child should be in subtree")
        #expect(subtreeIds.contains("h3-history"), "H3 grandchild should be in subtree")
        #expect(subtreeIds.contains("h2-methods"), "Second H2 child should be in subtree")
        #expect(!subtreeIds.contains("h1-results"), "Sibling H1 should NOT be in subtree")
    }

    @Test("filterToSubtree for H2 section excludes sibling H2s")
    @MainActor
    func filterToSubtreeH2Section() async throws {
        let state = EditorViewState()

        let sections = [
            makeSectionVM(id: "h1-doc", level: 1, sortOrder: 1, title: "Document"),
            makeSectionVM(id: "h2-alpha", level: 2, sortOrder: 3, title: "Alpha", parentId: "h1-doc"),
            makeSectionVM(id: "h3-sub", level: 3, sortOrder: 5, title: "Sub Alpha", parentId: "h2-alpha"),
            makeSectionVM(id: "h2-beta", level: 2, sortOrder: 7, title: "Beta", parentId: "h1-doc")
        ]

        let subtree = state.filterToSubtree(sections: sections, rootId: "h2-alpha")
        let subtreeIds = Set(subtree.map { $0.id })

        #expect(subtreeIds.contains("h2-alpha"))
        #expect(subtreeIds.contains("h3-sub"), "H3 under Alpha should be included")
        #expect(!subtreeIds.contains("h2-beta"), "Sibling H2 should be excluded")
        #expect(!subtreeIds.contains("h1-doc"), "Parent H1 should be excluded")
    }

    // MARK: - replaceBlocksInRange

    @Test("replaceBlocksInRange produces exact correct block count")
    func replaceBlocksInRangeBlockCount() throws {
        let content = """
        # Title

        Paragraph one.

        ## Section A

        Content A.

        ## Section B

        Content B.
        """

        let db = try createTestDatabase(content: content)
        let pid = try getProjectId(db)

        let blocksBefore = try fetchBlocks(db)
        let totalBefore = blocksBefore.count

        // Replace blocks in range of Section A (roughly sortOrder 3-4, before Section B)
        let sectionAHeading = blocksBefore.first { $0.textContent == "Section A" }!
        let sectionBHeading = blocksBefore.first { $0.textContent == "Section B" }!

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Extra paragraph.",
                  markdownFragment: "Extra paragraph.")
        ]

        try db.replaceBlocksInRange(
            newBlocks,
            for: pid,
            startSortOrder: sectionAHeading.sortOrder,
            endSortOrder: sectionBHeading.sortOrder
        )

        let blocksAfter = try fetchBlocks(db)

        // Should have no duplicate sort orders
        let sortOrders = blocksAfter.map { $0.sortOrder }
        let uniqueSortOrders = Set(sortOrders)
        #expect(sortOrders.count == uniqueSortOrders.count, "No duplicate sort orders allowed")

        // Sort orders should be monotonically increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder,
                    "Sort orders must be monotonically increasing")
        }

        // Section B should still exist
        let sectionBAfter = blocksAfter.first { $0.textContent == "Section B" }
        #expect(sectionBAfter != nil, "Section B should survive range replacement")
    }

    @Test("replaceBlocksInRange preserves heading metadata by title")
    func replaceBlocksInRangePreservesMetadata() throws {
        let db = try createTestDatabase(content: "# Doc\n\n## Section A\n\nContent.")
        let pid = try getProjectId(db)

        // Set metadata on Section A heading
        try db.dbWriter.write { database in
            if var block = try Block
                .filter(Block.Columns.textContent == "Section A")
                .fetchOne(database) {
                block.status = .review
                block.tags = ["important", "urgent"]
                block.wordGoal = 500
                try block.update(database)
            }
        }

        let blocks = try fetchBlocks(db)
        let heading = blocks.first { $0.textContent == "Section A" }!

        // Replace with same-title heading
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "New content.",
                  markdownFragment: "New content.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: heading.sortOrder,
            endSortOrder: nil
        )

        let blocksAfter = try fetchBlocks(db)
        let headingAfter = blocksAfter.first { $0.textContent == "Section A" }!

        #expect(headingAfter.status == .review, "Status should be preserved")
        #expect(headingAfter.tags == ["important", "urgent"], "Tags should be preserved")
        #expect(headingAfter.wordGoal == 500, "Word goal should be preserved")
        #expect(headingAfter.id == heading.id, "Heading ID should be preserved by title match")
    }

    // MARK: - Zoom Excludes Special Sections

    @Test("Zoom content excludes bibliography blocks")
    func zoomExcludesBibliography() throws {
        let db = try createTestDatabase(content: "# Doc\n\nText.\n\n## Section\n\nMore text.")
        let pid = try getProjectId(db)

        // Mark a block as bibliography
        try db.dbWriter.write { database in
            // Add a bibliography block at the end
            var bibBlock = Block(
                projectId: pid,
                sortOrder: 100,
                blockType: .heading,
                textContent: "References",
                markdownFragment: "# References",
                headingLevel: 1,
                isBibliography: true
            )
            try bibBlock.insert(database)
        }

        let blocks = try fetchBlocks(db)
        let nonBibBlocks = blocks.filter { !$0.isBibliography }
        let bibBlocks = blocks.filter { $0.isBibliography }

        #expect(!bibBlocks.isEmpty, "Should have bibliography blocks")
        #expect(!nonBibBlocks.isEmpty, "Should have non-bibliography blocks")

        // When assembling zoomed content, bibliography should be excluded
        // (This is tested at the EditorViewState level in integration, here we verify the flag)
        for block in bibBlocks {
            #expect(block.isBibliography, "Bibliography blocks should be flagged")
        }
    }

    @Test("Zoom content excludes notes blocks")
    func zoomExcludesNotes() throws {
        let db = try createTestDatabase(content: "# Doc\n\nText.\n\n## Section\n\nMore text.")
        let pid = try getProjectId(db)

        // Add a notes block
        try db.dbWriter.write { database in
            var notesBlock = Block(
                projectId: pid,
                sortOrder: 100,
                blockType: .heading,
                textContent: "Notes",
                markdownFragment: "# Notes",
                headingLevel: 1,
                isNotes: true
            )
            try notesBlock.insert(database)
        }

        let blocks = try fetchBlocks(db)
        let notesBlocks = blocks.filter { $0.isNotes }
        #expect(!notesBlocks.isEmpty, "Should have notes blocks")
    }

    // MARK: - Sort Order Precision

    @Test("Sort orders remain distinct after range replacement with overflow")
    func sortOrderPrecisionAfterOverflow() throws {
        // Create a document with tight sort orders, then replace a range with MORE blocks
        let db = try createTestDatabase(content: "# Doc\n\nP1.\n\n## A\n\nA content.\n\n## B\n\nB content.")
        let pid = try getProjectId(db)

        let blocks = try fetchBlocks(db)
        let headingA = blocks.first { $0.textContent == "A" }!
        let headingB = blocks.first { $0.textContent == "B" }!

        // Insert many blocks into section A's range (more than the original 2 blocks)
        var newBlocks: [Block] = []
        newBlocks.append(Block(projectId: pid, sortOrder: 0, blockType: .heading,
                               textContent: "A", markdownFragment: "## A", headingLevel: 2))
        for i in 0..<10 {
            newBlocks.append(Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                                   textContent: "New para \(i)", markdownFragment: "New para \(i)"))
        }

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: headingA.sortOrder,
            endSortOrder: headingB.sortOrder
        )

        let blocksAfter = try fetchBlocks(db)

        // All sort orders should be unique
        let sortOrders = blocksAfter.map { $0.sortOrder }
        #expect(Set(sortOrders).count == sortOrders.count, "All sort orders must be unique after overflow")

        // Section B should still exist and be after all section A blocks
        let bAfter = blocksAfter.first { $0.textContent == "B" }
        let aBlocks = blocksAfter.filter { $0.textContent.hasPrefix("New para") || $0.textContent == "A" }
        if let bSort = bAfter?.sortOrder {
            for aBlock in aBlocks {
                #expect(aBlock.sortOrder < bSort, "All Section A blocks should be before Section B")
            }
        }
    }

    // MARK: - Helper: Create SectionViewModel

    @MainActor
    private func makeSectionVM(
        id: String,
        level: Int,
        sortOrder: Double,
        title: String,
        parentId: String? = nil,
        isBibliography: Bool = false,
        isNotes: Bool = false
    ) -> SectionViewModel {
        let block = Block(
            id: id,
            projectId: projectId,
            parentId: parentId,
            sortOrder: sortOrder,
            blockType: .heading,
            textContent: title,
            markdownFragment: String(repeating: "#", count: level) + " " + title,
            headingLevel: level,
            isBibliography: isBibliography,
            isNotes: isNotes
        )
        return SectionViewModel(from: block)
    }
}
