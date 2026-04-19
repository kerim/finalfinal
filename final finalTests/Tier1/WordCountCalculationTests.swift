//
//  WordCountCalculationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for MarkdownUtils.wordCount(for:). The word counter feeds the goal
//  UI, the status bar, and the per-section progress bars. A wrong count is
//  silently misleading — it never throws, never crashes, just misreports.
//  Every case below pins behavior the user actually sees.
//

import Testing
import Foundation
@testable import final_final

@Suite("Word Count Calculation — Tier 1: Silent Killers")
struct WordCountCalculationTests {

    // MARK: - Trivial / Whitespace

    @Test("Empty and whitespace-only input")
    func emptyAndWhitespace() {
        #expect(MarkdownUtils.wordCount(for: "") == 0)
        #expect(MarkdownUtils.wordCount(for: " ") == 0)
        #expect(MarkdownUtils.wordCount(for: "\n\n\n") == 0)
        #expect(MarkdownUtils.wordCount(for: "   \t  \n") == 0)
    }

    @Test("Plain prose")
    func plainProse() {
        #expect(MarkdownUtils.wordCount(for: "Hello world") == 2)
        #expect(MarkdownUtils.wordCount(for: "One two three four five") == 5)
        #expect(MarkdownUtils.wordCount(for: "  spaces  around  ") == 2)
    }

    // MARK: - Headings, Emphasis, Lists, Quotes

    @Test("Heading markers don't count")
    func headingMarkers() {
        #expect(MarkdownUtils.wordCount(for: "# Heading One") == 2)
        #expect(MarkdownUtils.wordCount(for: "### Sub heading here") == 3)
    }

    @Test("Emphasis markers don't count")
    func emphasisMarkers() {
        #expect(MarkdownUtils.wordCount(for: "**bold** *italic* ~~strike~~ text") == 4)
        #expect(MarkdownUtils.wordCount(for: "__also bold__ _also italic_") == 4)
    }

    @Test("List markers don't count")
    func listMarkers() {
        #expect(MarkdownUtils.wordCount(for: "- one\n- two\n- three") == 3)
        #expect(MarkdownUtils.wordCount(for: "1. one\n2. two\n3. three") == 3)
    }

    @Test("Blockquote markers don't count")
    func blockquoteMarkers() {
        #expect(MarkdownUtils.wordCount(for: "> quoted text here") == 3)
    }

    // MARK: - Links and Images

    @Test("Inline link text counts, URL doesn't")
    func inlineLinkText() {
        #expect(MarkdownUtils.wordCount(for: "[link text](https://example.com)") == 2)
        #expect(MarkdownUtils.wordCount(for: "see [here](https://x) for more") == 4)
    }

    @Test("Image alt text and caption don't count")
    func imageAltText() {
        #expect(MarkdownUtils.wordCount(for: "![alt text here](projectmedia://abc.png)") == 0)
        #expect(MarkdownUtils.wordCount(for: "![](projectmedia://x.png){width=50%}") == 0)
    }

    @Test("Reference-style link definitions don't count, inline form keeps text")
    func referenceLinkDefinitions() {
        let input = """
        See [the report][r1] for details.

        [r1]: https://example.com/report
        """
        // Inline `[the report][r1]` becomes `the report`; the [r1]: url line is dropped.
        // Final tokens: See, the, report, for, details. = 5
        #expect(MarkdownUtils.wordCount(for: input) == 5)
    }

    // MARK: - Code Blocks (the big one)

    @Test("Fenced code block content doesn't count")
    func fencedCodeBlock() {
        let input = """
        Before the code.

        ```swift
        let x = 42
        let y = "hello world"
        print(x, y)
        ```

        After the code.
        """
        #expect(MarkdownUtils.wordCount(for: input) == 6)
    }

    @Test("Tilde-fenced code block content doesn't count")
    func tildeFencedCodeBlock() {
        let input = """
        Words.

        ~~~
        not counted as words
        these are code
        ~~~

        More words.
        """
        #expect(MarkdownUtils.wordCount(for: input) == 3)
    }

    @Test("Inline code keeps text as words (after backtick stripping)")
    func inlineCode() {
        // `foo()` becomes "foo()" — one token after stripping backticks
        #expect(MarkdownUtils.wordCount(for: "Call `foo()` then `bar()`.") == 4)
    }

    // MARK: - Math

    @Test("Display math block doesn't count")
    func displayMath() {
        // After stripping $$...$$: "Result:  done." → "Result:" and "done." both have letters
        #expect(MarkdownUtils.wordCount(for: "Result: $$\\int_0^1 x^2 dx$$ done.") == 2)
    }

    @Test("Inline math doesn't count")
    func inlineMath() {
        #expect(MarkdownUtils.wordCount(for: "Where $E = mc^2$ holds true.") == 3)
        #expect(MarkdownUtils.wordCount(for: "If $x > 0$ then proceed.") == 3)
    }

    @Test("Currency dollar signs are NOT treated as math")
    func currencyNotMath() {
        // $5 and $10 should not match the math regex (digits stay as words)
        // Tokens: It, costs, $5, or, $10, today. = 6
        #expect(MarkdownUtils.wordCount(for: "It costs $5 or $10 today.") == 6)
    }

    // MARK: - Citations

    @Test("Pandoc citations use render-then-count policy")
    func pandocCitations() {
        // [@key] renders to "Name Year" → 2 words. Sentence: As, shown, CIT, CIT, elsewhere.
        #expect(MarkdownUtils.wordCount(for: "As shown [@smith2020] elsewhere.") == 5)
        // Three citations × 2 = 6; plus Multiple, sources, support, this. = 10 total.
        #expect(MarkdownUtils.wordCount(for: "Multiple sources [@a; @b; @c] support this.") == 10)
        // Citation + locator words: With, locator, CIT, CIT (comma attached), p., 5. = 6.
        #expect(MarkdownUtils.wordCount(for: "With locator [@jones, p. 5].") == 6)
        // [-@key] renders to "Year" → 1 word. Suppress, author, CIT (trailing . filtered) = 3.
        #expect(MarkdownUtils.wordCount(for: "Suppress author [-@brown].") == 3)
    }

    @Test("Bare inline @key counts as 2 words")
    func bareInlineCitation() {
        // As, CIT, CIT, argues = 4
        #expect(MarkdownUtils.wordCount(for: "As @smith2020 argues") == 4)
    }

    @Test("Bare inline @key at document start still matches (vacuous lookbehind)")
    func bareInlineCitationAtStart() {
        // CIT, CIT, argues. = 3 — pins intended Pandoc behavior for inline citations
        // that open a block. If this breaks, academic prose beginning with a citation
        // would silently undercount.
        #expect(MarkdownUtils.wordCount(for: "@smith2020 argues.") == 3)
    }

    @Test("Email address is NOT mistaken for a citation")
    func emailNotCitation() {
        // Lookbehind rejects because `r` precedes `@`. Tokens: Contact,
        // user@example.com (one token), for, access = 4.
        #expect(MarkdownUtils.wordCount(for: "Contact user@example.com for access") == 4)
    }

    @Test("Autolink <name@host> is stripped before citation pass runs")
    func autolinkNotCitation() {
        // HTML-tag strip removes <alice@host.org> entirely. Tokens: Write, to, today. = 3.
        #expect(MarkdownUtils.wordCount(for: "Write to <alice@host.org> today.") == 3)
    }

    @Test("Citation inside inline code still counts (backticks stripped first)")
    func citationInsideInlineCode() {
        // stripMarkdownSyntax removes backticks → [@smith] remains → substitution fires.
        // Tokens: See, CIT, CIT, literally, in, prose. = 6.
        #expect(MarkdownUtils.wordCount(for: "See `[@smith]` literally in prose.") == 6)
    }

    // MARK: - HTML

    @Test("HTML tags don't count")
    func htmlTags() {
        #expect(MarkdownUtils.wordCount(for: "<div>hello</div>") == 1)
        #expect(MarkdownUtils.wordCount(for: "before<br/>after") == 1)
        #expect(MarkdownUtils.wordCount(for: #"<span class="x">middle</span>"#) == 1)
    }

    @Test("HTML comments don't count")
    func htmlComments() {
        #expect(MarkdownUtils.wordCount(for: "before <!-- hidden text --> after") == 2)
        #expect(MarkdownUtils.wordCount(for: "<!-- ::task:: do this thing -->") == 0)
        #expect(MarkdownUtils.wordCount(for: "before <!-- ::comment:: anything --> after") == 2)
    }

    // MARK: - Frontmatter

    @Test("YAML frontmatter at start doesn't count")
    func yamlFrontmatter() {
        let input = """
        ---
        title: My Document
        author: Someone
        date: 2024-01-01
        ---

        Body starts here.
        """
        #expect(MarkdownUtils.wordCount(for: input) == 3)
    }

    @Test("Three dashes mid-document are still horizontal rule")
    func midDocumentDashes() {
        let input = """
        Words before.

        ---

        Words after.
        """
        #expect(MarkdownUtils.wordCount(for: input) == 4)
    }

    // MARK: - Footnotes

    @Test("Footnote references don't count")
    func footnoteReferences() {
        #expect(MarkdownUtils.wordCount(for: "Some text[^1] more.") == 3)
    }

    @Test("Footnote definition prefix doesn't count")
    func footnoteDefinition() {
        #expect(MarkdownUtils.wordCount(for: "[^1]: footnote body here") == 3)
    }

    // MARK: - Tables

    @Test("Table cells count, pipe separators don't")
    func tableCells() {
        let input = """
        | col a | col b | col c |
        |-------|-------|-------|
        | one   | two   | three |
        """
        #expect(MarkdownUtils.wordCount(for: input) == 9)
    }

    // MARK: - Task Checkboxes

    @Test("Task checkbox brackets don't count, item text does")
    func taskCheckboxes() {
        #expect(MarkdownUtils.wordCount(for: "- [ ] todo item") == 2)
        #expect(MarkdownUtils.wordCount(for: "- [x] completed task") == 2)
    }

    // MARK: - Pandoc Heading Attributes

    @Test("Pandoc heading anchor attribute doesn't count")
    func pandocHeadingAttribute() {
        #expect(MarkdownUtils.wordCount(for: "## Heading {#anchor-id}") == 1)
        #expect(MarkdownUtils.wordCount(for: "## Heading {.class-name}") == 1)
        #expect(MarkdownUtils.wordCount(for: "## Heading {key=value}") == 1)
    }

    // MARK: - Annotations

    @Test("Block annotations don't count as words")
    func blockAnnotations() {
        let input = "Real prose here. <!-- ::task:: [ ] do something later --> More prose."
        #expect(MarkdownUtils.wordCount(for: input) == 5)
    }

    // MARK: - Dashes and Punctuation

    @Test("Em-dash splits adjacent words")
    func emDashSplits() {
        #expect(MarkdownUtils.wordCount(for: "word\u{2014}word") == 2)
        #expect(MarkdownUtils.wordCount(for: "before \u{2014} after") == 2)
    }

    @Test("En-dash splits adjacent words")
    func enDashSplits() {
        #expect(MarkdownUtils.wordCount(for: "1\u{2013}10") == 2)
    }

    @Test("Hyphenated compounds count as single word")
    func hyphenatedCompounds() {
        #expect(MarkdownUtils.wordCount(for: "state-of-the-art well-known") == 2)
    }

    @Test("Contractions count as single word")
    func contractions() {
        #expect(MarkdownUtils.wordCount(for: "don't isn't they're") == 3)
    }

    // MARK: - Combined / Realistic

    @Test("Realistic academic paragraph with citations and inline math")
    func realisticAcademic() {
        let input = """
        Recent work [@smith2020; @jones2021] shows that the relationship \
        $E = mc^2$ holds in this domain. Further analysis is needed.
        """
        // Citations render-counted: each @key = 2 tokens, so 2 citations add 4 CIT tokens.
        // Inline math stripped. Tokens: Recent, work, CIT×4, shows, that, the,
        // relationship, holds, in, this, domain., Further, analysis, is, needed. = 18
        #expect(MarkdownUtils.wordCount(for: input) == 18)
    }

    @Test("Document with frontmatter + heading + body + code block")
    func mixedDocument() {
        let input = """
        ---
        title: Doc
        ---

        # Introduction

        Some prose here.

        ```python
        x = 1
        y = 2
        ```

        Closing thoughts.
        """
        // Words: Introduction (1) + Some, prose, here. (3) + Closing, thoughts. (2) = 6
        #expect(MarkdownUtils.wordCount(for: input) == 6)
    }
}
