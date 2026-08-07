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

    // MARK: - Fix C: glued-fence detection (BlockParser+Splitting.swift consumeDisplayMath)
    //
    // consumeDisplayMath now also recognizes a GLUED `$$` fence — one sharing a
    // line with LaTeX content instead of sitting alone — as "prefix xor
    // suffix": a line starting with `$$` but NOT also ending with `$$` opens a
    // fence, and once open, a line ending with `$$` but NOT also starting with
    // `$$` closes it. This converges Swift's splitter with the JS math
    // tokenizer's own behavior on the same malformed shape (see
    // math-plugin.ts / math-paste-normalize.ts on the web side).

    @Test func gluedOpenAndGluedCloseAcrossMultipleLinesDetected() {
        // Open glued to the first line ("$$\begin{aligned}"), close glued to
        // the last line ("\end{aligned}$$") — the exact malformed shape from
        // the bug report this task fixes. Before Fix C this stayed an
        // ordinary (uncorrupted, but mistyped) paragraph; now it's recognized
        // as ONE display-math block.
        let markdown = "$$\\begin{aligned}\nx &= y \\\\\nz &= w\n\\end{aligned}$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
        #expect(blocks[0].markdownFragment.contains("x &= y"))
        #expect(blocks[0].markdownFragment.contains("\\end{aligned}"))
    }

    @Test func gluedOpenWithNoClosingFenceSwallowsToEOF() {
        // DECISION ON RECORD: a glued-open line ("$$content" — starts with
        // $$ but doesn't also end with $$) with NO matching close anywhere in
        // the document now opens a display-math fence that accumulates to
        // EOF, deliberately mirroring the JS math tokenizer's own
        // swallow-to-EOF behavior on the same malformed shape. This is a
        // known, accepted trade-off of converging with JS (see Fix C in the
        // task plan) — not a regression to "fix" later without revisiting
        // that decision.
        let markdown = "$$\\begin{aligned}\nx &= y\n\nAfter paragraph."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
        // The blank line and the trailing paragraph are swallowed into the
        // same block, not split off separately.
        #expect(blocks[0].markdownFragment.contains("After paragraph."))
    }

    @Test func lineBothPrefixAndSuffixInsideOpenFenceStaysContentNotClose() {
        // A line that is BOTH prefix and suffix ("$$x$$") arriving while a
        // (glued-open) fence is already open falls through as ordinary
        // content, not a close — "prefix xor suffix" deliberately does not
        // treat this shape as a closer, unchanged from pre-Fix-C behavior.
        let markdown = "$$\\begin{aligned}\n$$x$$\n\\end{aligned}$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
        #expect(blocks[0].markdownFragment.contains("$$x$$"))
    }

    // MARK: - Must-fix 1 (required fix round): glued-open predicate must not
    // false-positive on ordinary prose containing a second `$`
    //
    // opensGluedOnly now matches micromark's own math-flow "meta" state exactly:
    // it bails the instant it sees ANY further `$` character while scanning the
    // rest of the opening line, so a line only opens a fence when there is NO
    // other `$` anywhere after the leading `$$`. A prior version of this
    // predicate (hasOpenPrefix && !hasCloseSuffix) false-positived on both
    // shapes below, actively creating a genuinely unclosed fence on input that
    // never opens a fence at all under micromark's real rules.

    @Test func gluedOpenFalsePositiveOnEmbeddedClosingDollarsStaysParagraph() {
        // Starts with $$, has a legitimate closing $$ partway through, then
        // trailing prose. Must stay ONE ordinary paragraph, trailing content
        // intact — not get split into a bare "$$" opener that swallows to EOF.
        let markdown = "$$E = mc^2$$ is the famous equation."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .paragraph)
        #expect(blocks[0].textContent.contains("is the famous equation."))
    }

    @Test func gluedOpenFalsePositiveOnSecondDollarRunStaysParagraph() {
        // A line with two separate $-delimited runs must also not be
        // misclassified as a glued opener.
        let markdown = "$$a + $b$ c"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .paragraph)
    }

    @Test func emptyLatexUngluedRoundTripsAsOneMathDisplayBlock() {
        // The unglued empty-latex shape the JS serializer now emits for
        // `latex: ''` ($$\n\n$$, math-plugin.ts's toMarkdown) must survive
        // Swift's splitter/consumeDisplayMath as a single mathDisplay block.
        let markdown = "$$\n\n$$"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 1)
        #expect(blocks[0].blockType == .mathDisplay)
    }

    // MARK: - Non-Milkdown import path (CodeMirror paste, markdown import)
    //
    // math-paste-normalize.ts only wires into Milkdown's parserCtx and never runs
    // for content that reaches Swift's BlockParser.parse WITHOUT going through
    // Milkdown's JS at all — CodeMirror-paste and markdown import both land here
    // directly. Swift's own corrected glued-fence handling (consumeDisplayMath's
    // opensGluedOnly, above) is the de facto protection for those paths. This test
    // drives BlockParser.parse directly — never through any Milkdown JS — on the
    // canonical malformed/glued-fence repro from the bug report, proving the
    // non-Milkdown import path is actually protected, with evidence, not by argument.

    @Test func nonMilkdownImportPathBoundsGluedMathBlockAndPreservesTrailingParagraph() {
        let markdown = "$$x &= y \\\\\nz &= w\n\\end{aligned}$$\n\nTrailing paragraph."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "test")
        #expect(blocks.count == 2)
        #expect(blocks[0].blockType == .mathDisplay)
        #expect(blocks[0].markdownFragment.contains("x &= y"))
        #expect(blocks[0].markdownFragment.contains("\\end{aligned}"))
        // The math block must be BOUNDED — it must not have swallowed the
        // trailing paragraph the way the pre-fix behavior did.
        #expect(!blocks[0].markdownFragment.contains("Trailing paragraph"))
        #expect(blocks[1].blockType == .paragraph)
        #expect(blocks[1].textContent == "Trailing paragraph.")
    }
}
