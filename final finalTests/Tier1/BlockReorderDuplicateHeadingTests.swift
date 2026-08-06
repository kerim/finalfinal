//
//  BlockReorderDuplicateHeadingTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Split out of BlockReorderIntegrityTests.swift to stay under SwiftLint's
//  type_body_length cap — same suite, same test names/counts, just a second file.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension BlockReorderIntegrityTests {

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
