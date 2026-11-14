//
//  MarkdownUtilsEscapeAwareStrippingTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  t-4eb7bfa9 (Rich Text per-block save matches the whole-document save), W7/S3. The text a row stores for search and
//  titles (`BlockParser.extractTextContent`, which ends in `MarkdownUtils.stripMarkdownSyntax`) is now derived from the
//  Markdown of every edited block, so it must read the Markdown the way the editor writes it:
//
//    - the editor escapes only text that would otherwise read as formatting (`\$5`, `\_\_init\_\_`, `1\.`, `\#`), so a
//      backslash before ASCII punctuation is dropped;
//    - `snake_case_name` and `2 * 3 * 4` are written bare, so a `_` inside a word and a `*` with white space on both sides
//      are not emphasis (CommonMark: neither can open or close one);
//    - real emphasis (`*x*`, `_y_`, `**z**`) is still stripped, also around text that holds such a character.
//
//  A small word-count change that results (a row that used to lose the text between two intraword underscores) is a
//  correction, not a regression: `snake_case_name` is one word, and was counted as one word before as well.
//

import Foundation
import Testing
@testable import final_final

@Suite("MarkdownUtils.stripMarkdownSyntax reads escapes and emphasis the way the editor writes them (t-4eb7bfa9)")
struct MarkdownUtilsEscapeAwareStrippingTests {

    @Test("text with underscores inside a word keeps them")
    func intrawordUnderscoresStay() {
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "snake_case_name") == "snake_case_name")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "a_b and c_d") == "a_b and c_d")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "see file_name_2 now") == "see file_name_2 now")
    }

    @Test("a star with white space on both sides is text")
    func spacedStarsStay() {
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "2 * 3 * 4") == "2 * 3 * 4")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "a * b") == "a * b")
    }

    @Test("an escaped character loses its backslash, and what it protected is not read as formatting")
    func escapesAreDropped() {
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "\\$5") == "$5")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "Costs \\$5 and \\$10") == "Costs $5 and $10")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "\\_\\_init\\_\\_") == "__init__")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "\\*not italic\\*") == "*not italic*")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "1\\. not a list") == "1. not a list")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "\\# not a heading") == "# not a heading")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "\\[draft\\] and a \\\\ backslash") == "[draft] and a \\ backslash")
        // A backslash before a letter, or at the end of a line (a hard break), is not an escape and stays.
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "C:\\Users") == "C:\\Users")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "line one\\\nline two") == "line one\\\nline two")
    }

    @Test("text that needed no escape reads as it is")
    func plainSymbolsStay() {
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "Costs $5 [draft]") == "Costs $5 [draft]")
    }

    @Test("real emphasis is still stripped, also around text that holds an underscore or a spaced star")
    func realEmphasisIsStillStripped() {
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "*x* and _y_ and **z** and __w__") == "x and y and z and w")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "_snake_case_ here") == "snake_case here")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "*a * b* here") == "a * b here")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "2*3*4") == "234", "an asterisk inside a word still emphasises, as in CommonMark")
    }

    @Test("the same text through extractTextContent, which is what a row stores")
    func extractTextContentOfEditorShapes() {
        #expect(BlockParser.extractTextContent(from: "snake_case_name", blockType: .paragraph) == "snake_case_name")
        #expect(BlockParser.extractTextContent(from: "\\_\\_init\\_\\_", blockType: .paragraph) == "__init__")
        #expect(BlockParser.extractTextContent(from: "2 * 3 * 4", blockType: .paragraph) == "2 * 3 * 4")
        #expect(BlockParser.extractTextContent(from: "Costs \\$5", blockType: .paragraph) == "Costs $5")
        // A quote of two paragraphs, as the editor writes it, keeps the paragraphs apart.
        #expect(BlockParser.extractTextContent(from: "> first\n>\n> second", blockType: .blockquote) == "first\n\nsecond")
        // A list whose items hold a spaced star and a snake_case word.
        #expect(BlockParser.extractTextContent(from: "* 2 * 3\n* a_b_c", blockType: .bulletList) == "2 * 3\na_b_c")
    }

    // MARK: - F4: a backslash in a code block or in display math is literal

    @Test("a code block keeps its backslashes in the stored text; display math too; prose still loses its escapes")
    func codeAndDisplayMathKeepBackslashes() {
        let code = "```\na\\.b \\\\ \\{\n```"
        #expect(BlockParser.extractTextContent(from: code, blockType: .codeBlock) == "a\\.b \\\\ \\{")
        let math = "$$\n\\{ x \\}\n$$"
        #expect(BlockParser.extractTextContent(from: math, blockType: .mathDisplay) == "$$\n\\{ x \\}\n$$")
        // The same text as prose is unescaped (the control), and the unescape switch of `stripMarkdownSyntax` is what differs.
        #expect(BlockParser.extractTextContent(from: "a\\.b \\\\ \\{", blockType: .paragraph) == "a.b \\ {")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "a\\.b", unescaping: false) == "a\\.b")
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "a\\.b") == "a.b")

        // Through the parser: the rows a document holds.
        let rows = BlockParser.parse(
            markdown: code + "\n\n" + math, projectId: "escape-literal",
            bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
        #expect(rows.map(\.blockType) == [.codeBlock, .mathDisplay], "got \(rows.map(\.blockType))")
        #expect(rows.first?.textContent == "a\\.b \\\\ \\{")
        #expect(rows.last?.textContent == "$$\n\\{ x \\}\n$$")
    }

    // MARK: - F5: a node with no text has no stored text

    @Test("an empty list item has no text: a bare marker row")
    func bareListMarkerHasNoText() {
        #expect(BlockParser.extractTextContent(from: "*", blockType: .bulletList) == "")
        #expect(BlockParser.extractTextContent(from: "-", blockType: .bulletList) == "")
        #expect(BlockParser.extractTextContent(from: "1.", blockType: .orderedList) == "")
        #expect(BlockParser.extractTextContent(from: "1)", blockType: .orderedList) == "")
        #expect(BlockParser.extractTextContent(from: "*\n*", blockType: .bulletList) == "")
        // An empty item beside a full one keeps the full one.
        #expect(BlockParser.extractTextContent(from: "* a\n*", blockType: .bulletList) == "a")
    }

    @Test("an empty table (pipes, dashes, colons and spaces only) has no text; a table with a cell keeps it")
    func emptyTableHasNoText() {
        #expect(BlockParser.extractTextContent(from: "| | |\n| - | - |\n| | |", blockType: .table) == "")
        #expect(BlockParser.extractTextContent(from: "|  |  |\n| :- | -: |\n|  |  |", blockType: .table) == "")
        #expect(BlockParser.extractTextContent(from: "|", blockType: .table) == "")
        #expect(BlockParser.extractTextContent(from: "| a | b |\n| - | - |\n| 1 | 2 |", blockType: .table).contains("a"))
        #expect(BlockParser.extractTextContent(from: "|  | b |\n| - | - |\n|  |  |", blockType: .table).contains("b"))
    }

    @Test("a paragraph that is only a hard-break backslash has no text; a backslash after text is kept")
    func loneBackslashParagraphHasNoText() {
        #expect(BlockParser.extractTextContent(from: "\\", blockType: .paragraph) == "")
        #expect(BlockParser.extractTextContent(from: "line\\", blockType: .paragraph) == "line\\")
        #expect(BlockParser.extractTextContent(from: "line one\\\nline two", blockType: .paragraph) == "line one\\\nline two")
    }

    @Test("the alignment says an empty table and a lone-backslash paragraph are empty, as the editor's nodes are")
    func alignmentSeesEmptyNodesAsEmpty() {
        func nonEmpty(_ markdown: String) -> [Bool] {
            let rows = BlockParser.parse(
                markdown: markdown, projectId: "empty-nodes", bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
            return BlockParser.alignmentPairs(rows).map(\.meta.nonEmpty)
        }
        #expect(nonEmpty("| | |\n| - | - |\n| | |") == [false], "an empty table")
        #expect(nonEmpty("| a | b |\n| - | - |\n| 1 | 2 |") == [true], "a table with cells")
        #expect(nonEmpty("\\") == [false], "a paragraph holding only a hard break")
        #expect(nonEmpty("text\\") == [true])
    }

    @Test("word counts: one word stays one word, a spaced star counts the numbers around it")
    func wordCounts() {
        #expect(MarkdownUtils.wordCount(for: "snake_case_name") == 1)
        #expect(MarkdownUtils.wordCount(for: "\\_\\_init\\_\\_") == 1)
        #expect(MarkdownUtils.wordCount(for: "2 * 3 * 4") == 3)
        #expect(MarkdownUtils.wordCount(for: "Costs \\$5 and \\$10") == 4)
    }
}
