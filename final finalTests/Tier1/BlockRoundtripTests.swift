//
//  BlockRoundtripTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the block sync roundtrip pipeline.
//  Block ID misalignment causes wrong blocks to be updated;
//  caption duplication is silent and cumulative.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Block Roundtrip — Tier 1: Silent Killers")
struct BlockRoundtripTests {

    // MARK: - Block Parse → Assemble Roundtrip

    @Test("Parse and assemble roundtrip preserves block IDs")
    func parseAssemblePreservesBlockIds() throws {
        let content = """
        # Title

        First paragraph.

        ## Section

        Second paragraph.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Record original block IDs
        let originalIds = blocks.map { $0.id }

        // Assemble markdown from blocks
        let assembled = BlockParser.assembleMarkdown(from: blocks)

        // Re-parse (simulating what happens during sync)
        let reparsedBlocks = BlockParser.parse(markdown: assembled, projectId: pid)

        // Replace blocks (preserves IDs by title for headings)
        try db.replaceBlocks(reparsedBlocks, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // Heading IDs should be preserved
        let headingsBefore = blocks.filter { $0.blockType == .heading }
        let headingsAfter = blocksAfter.filter { $0.blockType == .heading }

        for before in headingsBefore {
            let matching = headingsAfter.first { $0.textContent == before.textContent }
            #expect(matching?.id == before.id,
                    "Heading '\(before.textContent)' ID should be preserved through roundtrip")
        }
    }

    @Test("Assemble markdown filters empty fragments")
    func assembleFiltersEmptyFragments() throws {
        let content = "# Title\n\nSome text.\n\n## Next\n\nMore text."
        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        let assembled = BlockParser.assembleMarkdown(from: blocks)

        // Should not have excessive blank lines from empty fragments
        #expect(!assembled.contains("\n\n\n\n"), "Should not have 4+ consecutive newlines")

        // Should still contain the actual content
        #expect(assembled.contains("Title"), "Should contain heading")
        #expect(assembled.contains("Some text"), "Should contain paragraph")
    }

    // MARK: - Caption-Image Block Duplication

    @Test("Caption comment paired with image does not duplicate after roundtrip")
    func captionImageNoDuplication() throws {
        let content = """
        # Document

        ![Workflow diagram](media/workflow.png)

        <!-- ::comment:: Caption: Figure 1. Overview of the methodology. -->

        Some following text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Count image blocks and annotation comments
        let imageBlocks = blocks.filter { $0.blockType == .image }
        let commentBlocks = blocks.filter { $0.markdownFragment.contains("::comment::") }

        let imageCountBefore = imageBlocks.count
        let commentCountBefore = commentBlocks.count

        // Simulate edit cycle: assemble → re-parse → replace
        let assembled = BlockParser.assembleMarkdown(from: blocks)
        let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)
        try db.replaceBlocks(reparsed, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlocksAfter = blocksAfter.filter { $0.blockType == .image }
        let commentBlocksAfter = blocksAfter.filter { $0.markdownFragment.contains("::comment::") }

        #expect(imageBlocksAfter.count == imageCountBefore,
                "Image block count should not change after roundtrip (was \(imageCountBefore), now \(imageBlocksAfter.count))")
        #expect(commentBlocksAfter.count == commentCountBefore,
                "Comment annotation count should not change after roundtrip (was \(commentCountBefore), now \(commentBlocksAfter.count))")
    }

    @Test("Multiple roundtrips do not accumulate caption copies")
    func multipleRoundtripsNoCaptionAccumulation() throws {
        let content = """
        # Doc

        ![Photo](media/photo.jpg)

        <!-- ::comment:: Caption: A beautiful photo taken during fieldwork. -->

        Text after image.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Run 5 roundtrips
        for _ in 0..<5 {
            let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            let assembled = BlockParser.assembleMarkdown(from: blocks)
            let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)
            try db.replaceBlocks(reparsed, for: pid)
        }

        let finalBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let commentBlocks = finalBlocks.filter { $0.markdownFragment.contains("::comment::") }

        #expect(commentBlocks.count <= 1,
                "Should have at most 1 caption comment after 5 roundtrips, found \(commentBlocks.count)")
    }

    // MARK: - Export Assembly

    @Test("Export assembly includes all sections in correct order")
    func exportAssemblyCorrectOrder() throws {
        let content = """
        # Title

        Intro.

        ## First Section

        First content.

        ## Second Section

        Second content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Find positions of headings in export
        guard let titleRange = exported.range(of: "# Title"),
              let firstRange = exported.range(of: "## First Section"),
              let secondRange = exported.range(of: "## Second Section") else {
            Issue.record("Export should contain all headings. Got: \(exported.prefix(200))")
            return
        }

        #expect(titleRange.lowerBound < firstRange.lowerBound, "Title should come before First Section")
        #expect(firstRange.lowerBound < secondRange.lowerBound, "First Section should come before Second Section")
    }

    @Test("Export assembly preserves image references")
    func exportPreservesImages() throws {
        let content = """
        # Doc

        ![Diagram](media/diagram.png)

        Text after.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        #expect(exported.contains("![Diagram]") || exported.contains("media/diagram.png"),
                "Export should preserve image references")
    }

    // MARK: - Block Parser

    @Test("Block parser detects correct block types")
    func blockParserDetectsTypes() throws {
        let content = """
        # Heading

        A paragraph.

        - List item 1
        - List item 2

        ```
        code block
        ```

        ---

        > Blockquote text.
        """

        let blocks = BlockParser.parse(markdown: content, projectId: "test")

        let types = blocks.map { $0.blockType }
        #expect(types.contains(.heading), "Should detect heading")
        #expect(types.contains(.paragraph), "Should detect paragraph")
        #expect(types.contains(.bulletList), "Should detect bullet list")
        #expect(types.contains(.codeBlock), "Should detect code block")
        #expect(types.contains(.blockquote), "Should detect blockquote")
        // horizontalRule or sectionBreak for ---
        #expect(types.contains(.horizontalRule) || types.contains(.sectionBreak),
                "Should detect horizontal rule or section break")
    }

    @Test("Block parser extracts heading levels correctly")
    func blockParserHeadingLevels() throws {
        let content = """
        # H1 Title

        ## H2 Section

        ### H3 Subsection
        """

        let blocks = BlockParser.parse(markdown: content, projectId: "test")
        let headings = blocks.filter { $0.blockType == .heading }

        #expect(headings.count == 3)
        #expect(headings[0].headingLevel == 1)
        #expect(headings[1].headingLevel == 2)
        #expect(headings[2].headingLevel == 3)
    }

    @Test("Block parser handles bibliography detection")
    func blockParserBibliography() throws {
        let content = """
        # Doc

        Text.

        # References

        Author. (2023). Title.
        """

        let blocks = BlockParser.parse(markdown: content, projectId: "test")
        let bibBlocks = blocks.filter { $0.isBibliography }

        #expect(!bibBlocks.isEmpty, "Should detect bibliography section (# References)")
    }
}
