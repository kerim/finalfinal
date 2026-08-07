//
//  MathBlockParserTests.swift
//  final finalTests
//
//  Tests for math equation block parsing:
//  - BlockParser detects $$...$$ as .mathDisplay
//  - Word count for mathDisplay is 0
//  - MarkdownUtils word-count does not count inline math or dollar prices
//

import Testing
@testable import final_final

struct MathBlockParserTests {

    // MARK: - detectBlockType via parse()

    @Test func singleLineMathDisplayDetected() {
        let markdown = "$$E = mc^2$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
    }

    @Test func multiLineMathDisplayDetected() {
        let markdown = "$$\n\\int_0^1 x\\,dx\n$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
    }

    @Test func mathDisplayWordCountIsZero() {
        let markdown = "$$E = mc^2$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].wordCount == 0)
    }

    @Test func mathDisplayKeptAsOneBlock() {
        // Multi-line display math must NOT be split at the blank line inside
        let markdown = "$$\n\\int_0^1\n\nx\\,dx\n$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        // Should produce exactly 1 block (not split at the internal blank line)
        let mathBlocks = blocks.filter { $0.blockType == .mathDisplay }
        #expect(mathBlocks.count == 1)
        // The single block must contain the full multi-line body
        let body = mathBlocks.first?.markdownFragment ?? ""
        #expect(body.contains("\\int_0^1"))
        #expect(body.contains("x\\,dx"))
    }

    @Test func mathDisplayDoesNotAffectSurroundingBlocks() {
        let markdown = "First paragraph.\n\n$$x^2$$\n\nLast paragraph."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 3)
        #expect(blocks[0].blockType == .paragraph)
        #expect(blocks[1].blockType == .mathDisplay)
        #expect(blocks[2].blockType == .paragraph)
    }

    // MARK: - MarkdownUtils word count regressions

    @Test func dollarPriceNotCountedAsMath() {
        // "costs $50" has only one $ delimiter — not inline math
        let wordCount = MarkdownUtils.wordCount(for: "costs $50 today")
        // Should count "costs", "$50" (or "50"), "today" — roughly 3 words
        // Key: must NOT crash or return 0
        #expect(wordCount > 0)
    }

    @Test func inlineMathStrippedFromWordCount() {
        // Inline math $x^2$ should be stripped (contributes 0 words)
        let withMath = MarkdownUtils.wordCount(for: "See $x^2$ for proof.")
        let withoutMath = MarkdownUtils.wordCount(for: "See for proof.")
        // withMath should equal withoutMath (math stripped)
        #expect(withMath == withoutMath)
    }

    @Test func displayMathStrippedFromWordCount() {
        // Display math $$...$$ stripped from word count
        let withMath = MarkdownUtils.wordCount(for: "$$\\int_0^1 x\\,dx$$")
        #expect(withMath == 0)
    }

    // MARK: - BlockType rawValue matches web blockType string (CRITICAL)

    @Test func mathDisplayRawValueMatchesWebBlockType() {
        // The web side emits blockType: "math_display" in BlockInsert.
        // Swift maps via BlockType(rawValue:) ?? .paragraph.
        // This test ensures the rawValue is exactly "math_display".
        #expect(BlockType.mathDisplay.rawValue == "math_display")
    }

    // MARK: - Code-fence guard regressions (table/math syntax shown *inside* a code block)

    @Test func tableLineInsideCodeFenceStaysOneCodeBlock() {
        // A fenced code block whose body happens to show raw markdown table
        // syntax (e.g. documenting the table format) must stay one code block —
        // the `|`-prefixed lines must not be sniffed out as a real table.
        let markdown = """
        ```

        | Body | Temperature |
        |---|---|
        | Water | 100 |
        ```
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .codeBlock)
        #expect(blocks[0].markdownFragment.contains("| Body | Temperature |"))
        #expect(blocks.filter { $0.blockType == .table }.isEmpty)
    }

    @Test func mathFenceInsideCodeFenceStaysOneCodeBlock() {
        // A fenced code block whose body shows raw LaTeX display-math syntax
        // (a bare "$$" line) must stay one code block — the "$$" must not be
        // sniffed out as a real math-display fence.
        let markdown = """
        ```
        Display math example:
        $$
        \\int_0^1 x\\,dx
        $$
        ```
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .codeBlock)
        #expect(blocks.filter { $0.blockType == .mathDisplay }.isEmpty)
    }

    // MARK: - Table-then-fence guard regression (reverse-direction sibling of the above)

    @Test func tableImmediatelyFollowedByCodeFenceClosesTableFirst() {
        // A markdown table with NO blank line before an opening code fence must
        // close the table cleanly and let the fence start a fresh code block —
        // not glue the fence onto the table's fragment (mis-typing it) and leave
        // inTable stuck true, which used to corrupt every block after it.
        let markdown = """
        | Name | Age |
        |---|---|
        | Alice | 30 |
        ```
        let x = 1
        ```

        Next paragraph.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 3)

        #expect(blocks[0].blockType == .table)
        #expect(blocks[0].markdownFragment.contains("| Alice | 30 |"))
        // The fence must NOT have been absorbed into the table's fragment.
        #expect(!blocks[0].markdownFragment.contains("```"))

        #expect(blocks[1].blockType == .codeBlock)
        #expect(blocks[1].markdownFragment.contains("let x = 1"))
        // The fence must still be present to open the code block.
        #expect(blocks[1].markdownFragment.hasPrefix("```"))

        // Content after the fence must parse as an ordinary, uncorrupted paragraph.
        #expect(blocks[2].blockType == .paragraph)
        #expect(blocks[2].textContent == "Next paragraph.")
    }
}
