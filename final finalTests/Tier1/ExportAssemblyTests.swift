//
//  ExportAssemblyTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for export assembly: bibliography placement, annotation preservation,
//  footnote preservation, and rich content roundtrip.
//  Export corruption silently destroys the user's shared output.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Export Assembly — Tier 1: Silent Killers")
struct ExportAssemblyTests {

    // MARK: - Export Tests

    @Test("Export places bibliography at end")
    func exportBibliographyPlacedAtEnd() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Find last heading — References should be the final H1
        guard let refsRange = exported.range(of: "# References") else {
            Issue.record("Export should contain # References heading")
            return
        }

        // Check no other H1 heading appears after References
        let afterRefs = String(exported[refsRange.upperBound...])
        let otherH1 = afterRefs.range(of: "\n# ", options: [])
        #expect(otherH1 == nil, "No H1 heading should appear after # References")
    }

    @Test("Export preserves annotation comments")
    func exportAnnotationsPresent() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        #expect(exported.contains("<!-- ::task::"), "Export should contain task annotations")
        #expect(exported.contains("<!-- ::comment::"), "Export should contain comment annotations")
    }

    @Test("Export preserves footnote refs and Notes section")
    func exportFootnotesPreserved() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        #expect(exported.contains("[^1]"), "Export should contain footnote references")
        #expect(exported.contains("[^2]"), "Export should contain footnote references")
        #expect(exported.contains("# Notes"), "Export should contain Notes section")
    }

    @Test("Export rich content roundtrip preserves key elements")
    func exportRichContentRoundtrip() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Headings
        #expect(exported.contains("# Research Paper Draft"), "Should preserve H1")
        #expect(exported.contains("## Background and Literature Review"), "Should preserve H2")
        #expect(exported.contains("### Archival Standards"), "Should preserve H3")

        // Citations
        #expect(exported.contains("@himmelmann1998"), "Should preserve citations")

        // Images
        #expect(exported.contains("media/methodology-workflow.png"), "Should preserve image references")

        // Highlights
        #expect(exported.contains("=="), "Should preserve highlight markers")
    }

    @Test("Export with captions formats correctly")
    func exportWithCaptionsFormatsCorrectly() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Image should be present
        #expect(exported.contains("![Methodology workflow diagram]") ||
                exported.contains("media/methodology-workflow.png"),
                "Export should contain image")

        // Caption annotation should be present
        #expect(exported.contains("Caption: Figure 1"),
                "Export should contain caption annotation")
    }

    // MARK: - Markdown Only Export (BlockParser.assembleMarkdownOnlyForExport)

    @Test("Markdown Only export leaves an image documented inside a fenced code block untouched")
    func markdownOnlyPreservesImageInsideCodeFence() {
        let markdown = """
        Here is how to add an image:

        ```
        ![example](fake.png)
        ```

        That's the syntax.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(
            exported.contains("![example](fake.png)"),
            "Image markup documented inside a code fence must survive untouched, not be stripped as a real image"
        )
    }

    @Test("Markdown Only export drops an image-only paragraph without leaving a blank-line crater")
    func markdownOnlyDropsImageOnlyParagraphWithoutBlankLineCrater() {
        let blocks = [
            Block(projectId: "test", sortOrder: 1.0, blockType: .paragraph, markdownFragment: "Paragraph one."),
            // A `.paragraph`-typed block whose entire fragment is image markup is a defensive
            // edge case: ordinary content of this shape is always classified `.image` by
            // BlockParser.parse (see `listTableOrMediaType`), but nothing in the `Block` type
            // itself enforces that invariant, so this shape is directly constructible -- and is
            // exactly the case the block-type filter in `assembleMarkdownOnlyForExport` can't
            // catch (it filters on blockType, not fragment content). Stripping the image here
            // turns this fragment into an empty string; since the per-fragment strip runs
            // BEFORE `isEmptyFragment` filters the result, this fragment is dropped entirely
            // rather than joined in as a hole that leaves a "\n\n\n\n" blank-line crater behind.
            Block(
                projectId: "test",
                sortOrder: 2.0,
                blockType: .paragraph,
                markdownFragment: "![standalone](media/photo.png)"
            ),
            Block(projectId: "test", sortOrder: 3.0, blockType: .paragraph, markdownFragment: "Paragraph two.")
        ]
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(!exported.contains("\n\n\n"), "Stripping an image-only paragraph must not leave a blank-line crater")
        #expect(exported == "Paragraph one.\n\nParagraph two.")
    }

    @Test("Markdown Only export drops a fragment that strips down to whitespace-only, not just exactly empty")
    func markdownOnlyDropsWhitespaceOnlyFragmentAfterStrip() {
        let blocks = [
            Block(projectId: "test", sortOrder: 1.0, blockType: .paragraph, markdownFragment: "Paragraph one."),
            // Same defensive shape as the image-only-paragraph case above, but with a leading
            // space that survives the image-removal regex match untouched. The fragment strips
            // down to a single space (" "), not exactly "" -- the case a bare `\n{3,}` collapse
            // pass over the whole assembled document could never catch, because a lone space
            // isn't a run of newlines. `isEmptyFragment` trims before checking, so this is
            // still recognized as empty and dropped, rather than surviving as a stray,
            // visible-looking blank line with trailing whitespace.
            Block(
                projectId: "test",
                sortOrder: 2.0,
                blockType: .paragraph,
                markdownFragment: " ![standalone](media/photo.png)"
            ),
            Block(projectId: "test", sortOrder: 3.0, blockType: .paragraph, markdownFragment: "Paragraph two.")
        ]
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(exported == "Paragraph one.\n\nParagraph two.",
                "A fragment stripping down to whitespace-only must be dropped, not joined in as a stray blank line")
    }

    @Test("Markdown Only export never collapses blank lines a user typed inside their own fenced code block")
    func markdownOnlyPreservesBlankLinesInsideCodeFence() {
        let markdown = """
        Here is a code sample with blank lines the user typed on purpose:

        ```
        line one


        line four
        ```

        That's the syntax.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(
            exported.contains("line one\n\n\nline four"),
            """
            Blank lines typed inside a fenced code block must survive exactly as typed -- Markdown Only export \
            must never run a whole-document blank-line collapse that can't tell code content from fragment joins
            """
        )
    }

    @Test("Markdown Only export strips an inline image embedded in prose that never got its own .image block")
    func markdownOnlyStripsInlineImageInProse() {
        // The motivating case for MarkdownUtils.strippingImages: an image reference typed
        // mid-sentence inside ordinary paragraph text is never itself classified `.image` by
        // BlockParser.parse (that requires the WHOLE trimmed fragment to start with `![` --
        // see `listTableOrMediaType`), so the block-type filter in
        // `assembleMarkdownOnlyForExport` can't catch it. Only the per-fragment
        // `strippingImages` call does.
        let markdown = "Some prose with an inline image ![diagram](x.png) sitting mid-sentence."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(!exported.contains("!["), "Inline image markup must be stripped even without its own .image block")
        #expect(exported.contains("Some prose with an inline image"), "Prose before the image must survive")
        #expect(exported.contains("sitting mid-sentence."), "Prose after the image must survive")
    }

    @Test("Markdown Only export strips an inline image embedded in a list item's text")
    func markdownOnlyStripsInlineImageInListItem() {
        let markdown = "- item featuring an inline photo ![diagram](x.png) here in the list"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(!exported.contains("!["), "Inline image markup must be stripped from list-item text")
        #expect(exported.contains("- item featuring an inline photo"), "List marker and text before the image must survive")
        #expect(exported.contains("here in the list"), "Text after the image must survive")
    }

    @Test("Markdown Only export preserves ordinary links")
    func markdownOnlyPreservesOrdinaryLinks() {
        let markdown = "See the [project homepage](https://example.com) for details."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(
            exported.contains("[project homepage](https://example.com)"),
            "Ordinary links must survive Markdown Only export -- only image syntax is stripped"
        )
    }

    @Test("Markdown Only export drops all image markup while preserving prose")
    func markdownOnlyDropsImagesPreservesProse() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownOnlyForExport(from: blocks)

        #expect(!exported.contains("!["), "No image markup should survive Markdown Only export")
        #expect(exported.contains("# Research Paper Draft"), "Should preserve headings")
        #expect(exported.contains("Himmelmann"), "Should preserve prose")
        #expect(exported.contains("@himmelmann1998"), "Should preserve citation markup, unaffected by image stripping")
    }
}
