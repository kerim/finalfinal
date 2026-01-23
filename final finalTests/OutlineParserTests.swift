//
//  OutlineParserTests.swift
//  final finalTests
//

import Testing
@testable import final_final

struct OutlineParserTests {

    @Test func parsesSimpleHeaders() {
        let markdown = """
        # Title

        Some content

        ## Chapter 1

        More content
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].title == "Title")
        #expect(nodes[0].headerLevel == 1)
        #expect(nodes[1].title == "Chapter 1")
        #expect(nodes[1].headerLevel == 2)
    }

    @Test func parsesNestedHeaders() {
        let markdown = """
        # Book
        ## Chapter 1
        ### Section 1.1
        ### Section 1.2
        ## Chapter 2
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 5)
        #expect(nodes[0].parentId == nil) // Book has no parent
        #expect(nodes[1].parentId == nodes[0].id) // Chapter 1 -> Book
        #expect(nodes[2].parentId == nodes[1].id) // Section 1.1 -> Chapter 1
        #expect(nodes[3].parentId == nodes[1].id) // Section 1.2 -> Chapter 1
        #expect(nodes[4].parentId == nodes[0].id) // Chapter 2 -> Book
    }

    @Test func calculatesCorrectOffsets() {
        let markdown = "# First\nContent\n# Second\nMore"
        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].startOffset == 0)
        #expect(nodes[1].startOffset == 16) // "# First\nContent\n" = 16 bytes
    }

    @Test func detectsPseudoSections() {
        let markdown = """
        ## Chapter 1
        ## Chapter 1-part 2
        ## Chapter 2 - continued
        ## Chapter 3
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes[0].isPseudoSection == false)
        #expect(nodes[1].isPseudoSection == true)
        #expect(nodes[2].isPseudoSection == true)
        #expect(nodes[3].isPseudoSection == false)
    }

    @Test func handlesEmptyContent() {
        let nodes = OutlineParser.parse(markdown: "", projectId: "test")
        #expect(nodes.isEmpty)
    }

    @Test func ignoresHeadersInCodeBlocks() {
        let markdown = """
        # Real Header

        ```
        # Not a header
        ## Also not
        ```

        ## Another Real Header
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].title == "Real Header")
        #expect(nodes[1].title == "Another Real Header")
    }

    @Test func extractsPreviewText() {
        let markdown = """
        # Title

        First line of content.
        Second line of content.
        Third line.
        Fourth line.
        Fifth line.
        """

        let preview = OutlineParser.extractPreview(from: markdown, startOffset: 0, endOffset: markdown.count, maxLines: 4)

        #expect(preview.contains("First line"))
        #expect(preview.contains("Fourth line"))
        #expect(!preview.contains("Fifth line"))
        #expect(!preview.contains("# Title"))
    }

    @Test func wordCountWorks() {
        #expect(OutlineParser.wordCount(in: "Hello world") == 2)
        #expect(OutlineParser.wordCount(in: "One two three four five") == 5)
        #expect(OutlineParser.wordCount(in: "") == 0)
        #expect(OutlineParser.wordCount(in: "   spaces   ") == 1)
    }
}
