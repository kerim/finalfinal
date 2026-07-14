//
//  ImageCaptionAltSeparationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the caption/alt separation fix (image-placement plan, Part B):
//  bracket text is the visible caption, a self-marking {alt="..."} attribute
//  carries the accessibility alt text — instead of every image showing its
//  auto-filled filename as a visible "Figure N: filename.jpg" caption, and a
//  user's real typed caption never surviving into any export.
//
//  Covers BlockParser.parseImageFragmentMeta/parse() (new-format detection +
//  old-format backward compatibility), Database+Blocks.swift's
//  applyBlockChangesFromEditor INSERT path, and Block.markdownForExport()'s
//  corrected caption-first/alt-attribute serialization.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Image Caption/Alt Separation — Tier 1: Silent Killers")
struct ImageCaptionAltSeparationTests {

    // MARK: - BlockParser.parse() / parseImageFragmentMeta: new format

    @Test("New format: bracket is caption, {alt=...} is alt")
    func parseNewFormatBasic() {
        let markdown = #"![My caption](media/x.png){alt="my-alt" width=30%}"#
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .image)
        #expect(blocks[0].imageCaption == "My caption")
        #expect(blocks[0].imageAlt == "my-alt")
        #expect(blocks[0].imageWidth == 30)
        #expect(blocks[0].imageSrc == "media/x.png")
    }

    @Test("New format, alt=... attribute order doesn't matter (width before alt)")
    func parseNewFormatAttributeOrderIndependent() {
        let markdown = #"![Caption text](media/x.png){width=30% alt="my-alt"}"#
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks[0].imageCaption == "Caption text")
        #expect(blocks[0].imageAlt == "my-alt")
        #expect(blocks[0].imageWidth == 30)
    }

    @Test("Judge-required case: empty alt but a real caption is preserved, not misread as old format")
    func parseEmptyAltButHasCaption() {
        let markdown = #"![A real typed caption](media/x.png){alt=""}"#
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks[0].imageCaption == "A real typed caption")
        #expect(blocks[0].imageAlt == "")
    }

    @Test("New format, no caption, real alt: empty bracket, alt attribute present")
    func parseNoCaptionRealAlt() {
        let markdown = #"![](media/x.png){alt="my-photo.jpg"}"#
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks[0].imageCaption == "")
        #expect(blocks[0].imageAlt == "my-photo.jpg")
    }

    @Test("New format with escaped quote in alt and escaped bracket in caption")
    func parseEscapedQuoteAndBracket() {
        // Exact bytes as produced by image-plugin.ts's toMarkdown for
        // alt = `a "quoted" alt`, caption = `a ] bracketed caption` (captured
        // from a real getMarkdown() run — see image-caption-alt.test.ts).
        let fragment = #"![a \] bracketed caption](media/x.png){alt="a \\"quoted\\" alt" width=25%}"#
        let meta = BlockParser.parseImageFragmentMeta(from: fragment)

        #expect(meta.caption == "a ] bracketed caption")
        #expect(meta.alt == #"a "quoted" alt"#)
        #expect(meta.src == "media/x.png")
    }

    // MARK: - BlockParser.parse(): old-format backward compatibility

    @Test("Old format unaffected: bracket is alt, no caption (no alt= attribute at all)")
    func parseOldFormatUnaffected() {
        let markdown = "![alt text](media/x.png)"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks[0].imageAlt == "alt text")
        #expect(blocks[0].imageCaption == nil)
    }

    @Test("Old format with width, no alt attribute: width still parses, no caption")
    func parseOldFormatWithWidth() {
        let markdown = "![alt](media/x.jpg){width=50%}"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks[0].imageAlt == "alt")
        #expect(blocks[0].imageCaption == nil)
        #expect(blocks[0].imageWidth == 50)
    }

    @Test("Old-format caption+image fragment (comment absorbed into same block) still classifies as image, caption not extracted by BlockParser itself")
    func parseOldFormatCaptionCommentFragment() {
        // BlockParser.parse() intentionally leaves imageCaption nil here — the
        // <!-- caption: ... --> comment is recovered by
        // Database+BlocksReorder.swift's gap-fill during replaceBlocks/
        // replaceBlocksInRange, not by BlockParser itself. This fragment shape
        // must still classify as .image (not .paragraph) and extract alt/src.
        let markdown = """
        <!-- caption: A photo -->

        ![alt](media/x.jpg){width=50%}
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")

        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .image)
        #expect(blocks[0].imageAlt == "alt")
        #expect(blocks[0].imageWidth == 50)
    }

    // MARK: - Full round-trip (parse -> assemble -> reparse) preserves new format

    @Test("New format survives a parse -> assemble -> reparse cycle")
    func newFormatFullRoundtrip() {
        let markdown = #"![My caption](media/x.png){alt="my-alt" width=40%}"#
        let blocks1 = BlockParser.parse(markdown: markdown, projectId: "test")
        let assembled = BlockParser.assembleMarkdown(from: blocks1)
        let blocks2 = BlockParser.parse(markdown: assembled, projectId: "test")

        #expect(blocks2[0].imageCaption == "My caption")
        #expect(blocks2[0].imageAlt == "my-alt")
        #expect(blocks2[0].imageWidth == 40)
    }

    // MARK: - Database+BlocksReorder.swift gap-fill: unaffected, still old-format-only

    @Test("replaceBlocks gap-fill still recovers imageCaption from the legacy comment for old-format documents")
    func replaceBlocksGapFillStillWorksForOldFormat() throws {
        let content = """
        <!-- caption: An old caption -->

        ![my-photo.jpg](media/x.jpg)
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageCaption == "An old caption", "Gap-fill should recover the legacy caption comment")
        #expect(imageBlock?.imageAlt == "my-photo.jpg")
    }

    @Test("replaceBlocks gap-fill does NOT override a new-format document's own (possibly empty) caption")
    func replaceBlocksGapFillDoesNotOverrideNewFormat() throws {
        // First save: new-format image with a real caption.
        let content = #"![Real caption](media/x.jpg){alt="my-photo.jpg"}"#
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        var blocks = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocks.first { $0.blockType == .image }?.imageCaption == "Real caption")

        // Simulate a reparse (e.g. CodeMirror toggle) where the SAME image is
        // re-typed with an EMPTY caption in the new format. The gap-fill must
        // NOT resurrect the stale "Real caption" value — the new format's
        // explicit alt="..." presence is unambiguous, so "" wins.
        let newContent = #"![](media/x.jpg){alt="my-photo.jpg"}"#
        let reparsed = BlockParser.parse(markdown: newContent, projectId: pid)
        try db.replaceBlocks(reparsed, for: pid)

        blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageCaption == "", "New format's explicit empty caption must not be gap-filled from stale DB state")
    }

    // MARK: - Database+Blocks.swift: applyBlockChangesFromEditor INSERT path

    @Test("applyBlockChangesFromEditor INSERT extracts caption/alt from new-format fragment")
    func insertPathExtractsNewFormatCaptionAlt() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Test")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let changes = BlockChanges(
            inserts: [BlockInsert(
                tempId: "temp-img-1",
                blockType: "image",
                textContent: "",
                markdownFragment: #"![My caption](media/test.jpg){alt="test.jpg" width=60%}"#,
                headingLevel: nil,
                afterBlockId: nil
            )]
        )
        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageCaption == "My caption")
        #expect(imageBlock?.imageAlt == "test.jpg")
        #expect(imageBlock?.imageWidth == 60)
    }

    @Test("applyBlockChangesFromEditor INSERT: a freshly-inserted image (no caption yet, auto-filled alt) gets empty caption, real alt")
    func insertPathFreshImageNoCaptionYet() throws {
        // Mirrors exactly what MilkdownCoordinator's insertImageBlock -> JS
        // insertImage -> toMarkdown produces for a brand new image: empty
        // bracket (no caption typed yet), alt="..." unconditionally present.
        let db = try TestFixtureFactory.createTemporary(content: "# Test")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let changes = BlockChanges(
            inserts: [BlockInsert(
                tempId: "temp-img-1",
                blockType: "image",
                textContent: "",
                markdownFragment: #"![](media/my-photo.jpg){alt="my-photo.jpg"}"#,
                headingLevel: nil,
                afterBlockId: nil
            )]
        )
        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageCaption == "", "Fresh insert should have an explicit empty caption, not nil")
        #expect(imageBlock?.imageAlt == "my-photo.jpg")
    }

    @Test("applyBlockChangesFromEditor INSERT: old-format fragment still treats bracket as alt")
    func insertPathOldFormatUnaffected() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Test")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let changes = BlockChanges(
            inserts: [BlockInsert(
                tempId: "temp-img-1",
                blockType: "image",
                textContent: "",
                markdownFragment: "![photo.jpg](media/photo.jpg)",
                headingLevel: nil,
                afterBlockId: nil
            )]
        )
        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let imageBlock = blocks.first { $0.blockType == .image }
        #expect(imageBlock?.imageAlt == "photo.jpg")
        #expect(imageBlock?.imageCaption == nil)
    }

    // MARK: - Block.markdownForExport(): the actual PDF/DOCX/ODT export serialization

    @Test("markdownForExport: no caption produces an EMPTY bracket, not a filename fallback")
    func exportNoCaptionEmptyBracket() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/my-photo.jpg",
            imageAlt: "my-photo.jpg",
            imageCaption: nil
        )
        let exported = block.markdownForExport()
        #expect(exported.hasPrefix("![](media/my-photo.jpg)"),
                "Bracket text must be empty, not the alt/filename fallback — got: \(exported)")
        #expect(exported.contains(#"alt="my-photo.jpg""#))
    }

    @Test("markdownForExport: real caption produces caption in brackets, alt in {alt=...} attribute")
    func exportRealCaptionSeparatesFromAlt() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/my-photo.jpg",
            imageAlt: "my-photo.jpg",
            imageCaption: "A real caption"
        )
        let exported = block.markdownForExport()
        #expect(exported.hasPrefix("![A real caption](media/my-photo.jpg)"))
        #expect(exported.contains(#"alt="my-photo.jpg""#))
        #expect(!exported.contains("my-photo.jpg]"), "Filename must not leak into the caption bracket")
    }

    @Test("markdownForExport: judge-required empty-alt-but-has-caption case")
    func exportEmptyAltHasCaption() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/x.png",
            imageAlt: "",
            imageCaption: "A real caption"
        )
        let exported = block.markdownForExport()
        #expect(exported.hasPrefix("![A real caption](media/x.png)"))
        // No alt attribute needed when alt is empty — this markdown is
        // consumed once by Pandoc and never read back, so there is no
        // self-marking/round-trip-disambiguation requirement here (unlike
        // the persisted editor format in image-plugin.ts).
        #expect(!exported.contains("alt="))
    }

    @Test("markdownForExport: escapes a bracket in the caption and a quote in the alt")
    func exportEscapesBracketAndQuote() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/x.png",
            imageAlt: #"alt with "quotes""#,
            imageCaption: "caption with ] bracket"
        )
        let exported = block.markdownForExport()
        #expect(exported.contains(#"caption with \] bracket"#), "Bracket in caption must be escaped: \(exported)")
        #expect(exported.contains(#"alt="alt with \"quotes\"""#), "Quotes in alt must be escaped: \(exported)")
    }

    @Test("markdownForExport: escapes a literal backslash BEFORE the delimiter, in both caption and alt")
    func exportEscapesBackslashBeforeDelimiter() {
        // Regression guard: a trailing unescaped backslash immediately before the real closing
        // delimiter (`]` for caption, `"` for alt) makes Pandoc's markdown reader treat that
        // delimiter as escaped (a literal character), not as the terminator — corrupting the
        // markup so badly the whole image can silently disappear from export. Backslash MUST be
        // escaped first, same order as the JS side's escapeAltAttr
        // (web/milkdown/src/image-plugin.ts). See ImageCaptionExportTests's real-pandoc
        // verification of exactly this scenario.
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/x.png",
            imageAlt: #"alt with "quotes" and trailing backslash\"#,
            imageCaption: #"caption with ] bracket and trailing backslash\"#
        )
        let exported = block.markdownForExport()
        #expect(exported.contains(#"caption with \] bracket and trailing backslash\\"#),
                "Backslash must be escaped before the bracket delimiter: \(exported)")
        #expect(exported.contains(#"alt="alt with \"quotes\" and trailing backslash\\""#),
                "Backslash must be escaped before the closing quote delimiter: \(exported)")
    }

    @Test("markdownForExport: combines alt and width in a single attribute block")
    func exportCombinesAltAndWidth() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/x.png",
            imageAlt: "my-photo.jpg",
            imageCaption: "Caption",
            imageWidth: 50
        )
        let exported = block.markdownForExport()
        let braceCount = exported.filter { $0 == "{" }.count
        #expect(braceCount == 1, "alt and width must share a single {...} block, got: \(exported)")
        #expect(exported.contains(#"alt="my-photo.jpg""#))
        #expect(exported.contains("width=50%"))
    }

    @Test("markdownForExport: no caption, no alt, no width produces a completely bare image")
    func exportBareImageNoAttrsAtAll() {
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/x.png"
        )
        let exported = block.markdownForExport()
        #expect(exported == "![](media/x.png)")
    }
}
