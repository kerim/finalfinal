//
//  ImageWidthRoundtripTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests that image width encoded as {width=N%} in markdown
//  survives all parse/assemble/reparse round-trips.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Image Width Roundtrip — Tier 1: Silent Killers")
struct ImageWidthRoundtripTests {

    // MARK: - BlockParser.parse() extracts width

    @Test("BlockParser extracts width from {width=50%}")
    func parseExtractsWidth() {
        let markdown = "![photo](media/test.jpg){width=50%}"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .image)
        #expect(blocks[0].imageWidth == 50)
        #expect(blocks[0].imageSrc == "media/test.jpg")
    }

    @Test("BlockParser returns nil width for bare image")
    func parseNilWidthForBareImage() {
        let markdown = "![photo](media/test.jpg)"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks.count == 1)
        #expect(blocks[0].imageWidth == nil)
    }

    // MARK: - assembleMarkdown preserves width in fragment

    @Test("assembleMarkdown preserves {width=50%} in fragment")
    func assemblePreservesWidth() {
        let block = Block(
            projectId: "test",
            sortOrder: 1.0,
            blockType: .image,
            markdownFragment: "![](media/x.jpg){width=50%}",
            imageSrc: "media/x.jpg",
            imageWidth: 50
        )
        let assembled = BlockParser.assembleMarkdown(from: [block])
        #expect(assembled.contains("{width=50%}"))
    }

    // MARK: - Full roundtrip

    @Test("Parse -> assemble -> reparse preserves width")
    func fullRoundtrip() {
        let markdown = "![photo](media/test.jpg){width=50%}"
        let blocks1 = BlockParser.parse(markdown: markdown, projectId: "test")
        let assembled = BlockParser.assembleMarkdown(from: blocks1)
        let blocks2 = BlockParser.parse(markdown: assembled, projectId: "test")

        #expect(blocks2.count == 1)
        #expect(blocks2[0].imageWidth == 50)
    }

    // MARK: - updateWidthInMarkdown helper

    @Test("updateWidthInMarkdown adds width to bare fragment")
    func addWidthToBareFragment() {
        let result = ProjectDatabase.updateWidthInMarkdown(
            "![alt](media/x.jpg)", width: 50
        )
        #expect(result == "![alt](media/x.jpg){width=50%}")
    }

    @Test("updateWidthInMarkdown updates existing width (no duplication)")
    func updateExistingWidth() {
        let result = ProjectDatabase.updateWidthInMarkdown(
            "![alt](media/x.jpg){width=30%}", width: 50
        )
        #expect(result == "![alt](media/x.jpg){width=50%}")
    }

    @Test("updateWidthInMarkdown on fragment with no image returns unchanged")
    func noImageReturnsUnchanged() {
        let fragment = "Just some text"
        let result = ProjectDatabase.updateWidthInMarkdown(fragment, width: 50)
        #expect(result == fragment)
    }

    @Test("updateWidthInMarkdown inserts into existing attrs without width")
    func insertIntoExistingAttrs() {
        let result = ProjectDatabase.updateWidthInMarkdown(
            "![alt](media/x.jpg){fig-alt=\"desc\"}", width: 50
        )
        #expect(result.contains("width=50%"))
        #expect(result.contains("fig-alt"))
        // Should not have duplicate braces
        let braceCount = result.filter { $0 == "{" }.count
        #expect(braceCount == 1)
    }

    // MARK: - replaceBlocks preserves width from markdown

    @Test("replaceBlocks preserves width when encoded in markdownFragment")
    func replaceBlocksPreservesWidth() throws {
        let content = "![photo](media/test.jpg){width=50%}"
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageWidth == 50)

        // Simulate round-trip: assemble -> reparse -> replace
        let assembled = BlockParser.assembleMarkdown(from: blocks)
        let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)
        try db.replaceBlocks(reparsed, for: pid)

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterImage = afterBlocks.first { $0.blockType == .image }
        #expect(afterImage?.imageWidth == 50, "Width should survive replaceBlocks round-trip")
    }

    // MARK: - Caption-comment fragment roundtrip

    @Test("Caption + image with width roundtrips correctly")
    func captionWithWidthRoundtrip() {
        let markdown = """
        <!-- caption: A photo -->

        ![alt](media/x.jpg){width=50%}
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageWidth == 50)

        let assembled = BlockParser.assembleMarkdown(from: blocks)
        let reparsed = BlockParser.parse(markdown: assembled, projectId: "test")
        let reparsedImage = reparsed.first { $0.blockType == .image }
        #expect(reparsedImage?.imageWidth == 50)
    }

    // MARK: - applyBlockChangesFromEditor paths

    @Test("applyBlockChangesFromEditor INSERT extracts width from fragment")
    func insertPathExtractsWidth() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Test")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let changes = BlockChanges(
            inserts: [BlockInsert(
                tempId: "temp-img-1",
                blockType: "image",
                textContent: "",
                markdownFragment: "![photo](media/test.jpg){width=60%}",
                headingLevel: nil,
                afterBlockId: nil
            )]
        )
        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageWidth == 60)
    }

    @Test("applyBlockChangesFromEditor UPDATE re-extracts width when fragment changes")
    func updatePathExtractsWidth() throws {
        // First create a block with an image
        let content = "![photo](media/test.jpg){width=40%}"
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }!

        // Now send an update with a different width
        let changes = BlockChanges(
            updates: [BlockUpdate(
                id: imageBlock.id,
                textContent: nil,
                markdownFragment: "![photo](media/test.jpg){width=70%}",
                headingLevel: nil
            )]
        )
        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let afterImage = afterBlocks.first { $0.blockType == .image }
        #expect(afterImage?.imageWidth == 70)
    }

    // MARK: - markdownForExport

    @Test("markdownForExport outputs {width=50%} not {width=50px}")
    func exportUsesPercentage() {
        var block = Block(
            projectId: "test",
            sortOrder: 1.0,
            blockType: .image,
            markdownFragment: "![photo](media/test.jpg){width=50%}",
            imageSrc: "media/test.jpg",
            imageAlt: "photo",
            imageWidth: 50
        )
        let exported = block.markdownForExport()
        #expect(exported.contains("width=50%"))
        #expect(!exported.contains("width=50px"))
    }
}
