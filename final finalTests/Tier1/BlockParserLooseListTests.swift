//
//  BlockParserLooseListTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  t-4eb7bfa9 (Rich Text per-block save matches the whole-document save). Three BlockParser facts the close save
//  depends on, each stated in the shape the Rich Text editor actually writes:
//
//    1. A LOOSE list stays ONE row. The editor holds a list as one node and writes it as one row. A list read from
//       Markdown is written loose (`* a\n\n* b`) and an item with two paragraphs is written `* one\n\n  two\n* three`.
//       Cutting the text at every blank line made the close see several rows where the editor has one. A blank line
//       followed by an indented continuation, or by an item of the SAME list (same bullet character, same number
//       delimiter), continues the list; an item with a different bullet or delimiter starts a new list (CommonMark),
//       which is how the editor writes two lists in a row, so those stay two rows.
//    2. An ordered item may use `)` as its delimiter (`1) c`), which the editor writes for an ordered list that
//       directly follows another one.
//    3. A figure row `![](src){alt="..."}` (and the captioned form with a width) parses as an image row with its alt.
//
//  These are the Swift half of the Markdown-mode row splitting: CodeMirror's text goes through the same parse.
//

import Foundation
import Testing
@testable import final_final

@Suite("BlockParser: a loose list is one row, `)` ordered items, figure rows with an alt attribute (t-4eb7bfa9)")
struct BlockParserLooseListTests {

    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(
            markdown: markdown, projectId: "loose-list", bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
    }

    private func described(_ blocks: [Block]) -> [String] {
        blocks.map { "\($0.blockType.rawValue):\($0.markdownFragment.debugDescription)" }
    }

    // MARK: - 1. A loose list is one row

    @Test("a list written loose (a blank line between its items) is one bullet-list row")
    func looseBulletListIsOneRow() {
        let rows = parse("Intro\n\n* a\n\n* b\n\n* c\n\nOutro")
        #expect(rows.map(\.blockType) == [.paragraph, .bulletList, .paragraph], "got \(described(rows))")
        #expect(rows[1].markdownFragment == "* a\n\n* b\n\n* c", "got \(rows[1].markdownFragment.debugDescription)")
        #expect(rows[1].textContent == "a\n\nb\n\nc", "got \(rows[1].textContent.debugDescription)")
    }

    @Test("an item with two paragraphs keeps the whole list in one row")
    func twoParagraphItemIsOneRow() {
        let rows = parse("* one\n\n  two\n* three\n\nAfter")
        #expect(rows.map(\.blockType) == [.bulletList, .paragraph], "got \(described(rows))")
        #expect(rows[0].markdownFragment == "* one\n\n  two\n* three", "got \(rows[0].markdownFragment.debugDescription)")
        #expect(rows[0].textContent == "one\n\ntwo\nthree", "got \(rows[0].textContent.debugDescription)")
    }

    @Test("a loose ordered list is one row, and so is a nested list after a blank line")
    func looseOrderedAndNestedListsAreOneRow() {
        let ordered = parse("1. a\n\n2. b\n\n3. c")
        #expect(ordered.map(\.blockType) == [.orderedList], "got \(described(ordered))")
        #expect(ordered[0].markdownFragment == "1. a\n\n2. b\n\n3. c")

        let nested = parse("* a\n\n  * nested\n\n* b")
        #expect(nested.map(\.blockType) == [.bulletList], "got \(described(nested))")
        #expect(nested[0].markdownFragment == "* a\n\n  * nested\n\n* b")
    }

    @Test("two lists in a row, written with different markers, stay two rows")
    func adjacentListsWithDifferentMarkersStaySeparate() {
        // The editor writes a bullet list that directly follows another bullet list with the other bullet, and an ordered list
        // that directly follows an ordered list with the other delimiter. CommonMark reads each pair as two lists.
        let bullets = parse("* p\n\n- q")
        #expect(bullets.map(\.markdownFragment) == ["* p", "- q"], "got \(described(bullets))")
        let ordered = parse("1. a\n\n1) c")
        #expect(ordered.map(\.markdownFragment) == ["1. a", "1) c"], "got \(described(ordered))")
        #expect(ordered.map(\.blockType) == [.orderedList, .orderedList])
        // A bullet list followed by an ordered list is two lists too.
        let mixed = parse("* a\n\n1. b")
        #expect(mixed.map(\.blockType) == [.bulletList, .orderedList], "got \(described(mixed))")
    }

    @Test("a blank line followed by anything else still ends the list")
    func blankLineThenAParagraphEndsTheList() {
        // Not indented, indented less than the item's text, a figure, a heading, a quote: each starts its own row.
        let paragraph = parse("* a\n\nParagraph")
        #expect(paragraph.map(\.blockType) == [.bulletList, .paragraph], "got \(described(paragraph))")
        let shallow = parse("* a\n\n Paragraph")
        #expect(shallow.map(\.blockType) == [.bulletList, .paragraph], "got \(described(shallow))")
        let figure = parse("* Item 1\n\n![](projectmedia://test.png)\n\n* Item 2\n\n* Item 3")
        #expect(figure.map(\.blockType) == [.bulletList, .image, .bulletList], "got \(described(figure))")
        #expect(figure[2].markdownFragment == "* Item 2\n\n* Item 3", "got \(figure[2].markdownFragment.debugDescription)")
        let heading = parse("* a\n\n# Heading")
        #expect(heading.map(\.blockType) == [.bulletList, .heading], "got \(described(heading))")
        let quote = parse("1. a\n\n> quote")
        #expect(quote.map(\.blockType) == [.orderedList, .blockquote], "got \(described(quote))")
    }

    @Test("a thematic break written with spaces does not continue a list: list, rule, paragraph are three rows")
    func spacedThematicBreakDoesNotContinueAList() {
        // CommonMark reads `* * *` as a rule before it reads it as an item. (The existing classifier types such a row by its marker, as
        // it always did; what matters here is that the list and the rule are separate rows, as they are two editor nodes.)
        let star = parse("* a\n\n* * *\n\nParagraph")
        #expect(star.map(\.markdownFragment) == ["* a", "* * *", "Paragraph"], "got \(described(star))")
        let dash = parse("- a\n\n- - -\n\nParagraph")
        #expect(dash.map(\.markdownFragment) == ["- a", "- - -", "Paragraph"], "got \(described(dash))")
        // Two rules in a row are not a list either.
        let twoRules = parse("* * *\n\n* * *")
        #expect(twoRules.map(\.markdownFragment) == ["* * *", "* * *"], "got \(described(twoRules))")
        // And a real second item still continues the list.
        let items = parse("* a\n\n* b")
        #expect(items.map(\.markdownFragment) == ["* a\n\n* b"], "got \(described(items))")
        #expect(BlockParser.listMarkerSignature("* * *") == nil)
        #expect(BlockParser.isSpacedThematicBreak("* * *"))
        #expect(BlockParser.isSpacedThematicBreak("-  -  -"))
        #expect(BlockParser.isSpacedThematicBreak("___"))
        #expect(!BlockParser.isSpacedThematicBreak("* * a"))
        #expect(!BlockParser.isSpacedThematicBreak("* *"))
    }

    @Test("a paragraph is not a list: an indented line after its blank line is a paragraph of its own")
    func paragraphIsNotMistakenForAList() {
        let rows = parse("Intro text\n\n  indented text after a blank line")
        #expect(rows.map(\.blockType) == [.paragraph, .paragraph], "got \(described(rows))")
    }

    @Test("a loose list survives assemble and parse: the same rows come back")
    func looseListRoundTripsThroughAssembly() {
        let rows = parse("Intro\n\n* one\n\n  two\n\n* three\n\n- q\n\nOutro")
        let again = parse(BlockParser.assembleMarkdown(from: rows))
        #expect(again.map(\.markdownFragment) == rows.map(\.markdownFragment), "first \(described(rows)), again \(described(again))")
        #expect(again.map(\.blockType) == rows.map(\.blockType))
    }

    // MARK: - 2. Ordered items with a `)` delimiter

    @Test("a `1)` item is an ordered list: type, list marker kind, text content")
    func parenthesisOrderedItemIsAnOrderedList() {
        #expect(BlockParser.detectBlockType("1) a").0 == .orderedList)
        #expect(BlockParser.detectBlockType("12) a\n13) b").0 == .orderedList)
        #expect(BlockParser.listMarkerKind("1) a") == .orderedList)
        // No space after the delimiter: not a list item (the same rule `1.x` follows).
        #expect(BlockParser.detectBlockType("1)a").0 == .paragraph)
        #expect(BlockParser.listMarkerKind("1)a") == nil)

        let rows = parse("1) a\n2) b\n\nAfter")
        #expect(rows.map(\.blockType) == [.orderedList, .paragraph], "got \(described(rows))")
        #expect(rows[0].markdownFragment == "1) a\n2) b")
        #expect(rows[0].textContent == "a\nb", "got \(rows[0].textContent.debugDescription)")
        #expect(BlockParser.extractTextContent(from: "1) c", blockType: .orderedList) == "c")
        // The same row as it reads once the list marker is the only thing stripped.
        #expect(MarkdownUtils.stripMarkdownSyntax(from: "1) one\n2) two") == "one\ntwo")
    }

    @Test("a `1)` item directly after a paragraph interrupts it, as a `1.` item does")
    func parenthesisItemInterruptsAParagraph() {
        let rows = parse("Intro\n1) a")
        #expect(rows.map(\.blockType) == [.paragraph, .orderedList], "got \(described(rows))")
    }

    @Test("the marker signature tells lists apart: bullet character, number delimiter")
    func listMarkerSignature() {
        #expect(BlockParser.listMarkerSignature("* a") == "*")
        #expect(BlockParser.listMarkerSignature("- a") == "-")
        #expect(BlockParser.listMarkerSignature("+ a") == "+")
        #expect(BlockParser.listMarkerSignature("1. a") == ".")
        #expect(BlockParser.listMarkerSignature("10) a") == ")")
        #expect(BlockParser.listMarkerSignature("plain") == nil)
        #expect(BlockParser.listMarkerSignature("---") == nil)
    }

    // MARK: - 3. Figure rows

    @Test("a figure row with an alt attribute and no caption is an image row with its alt")
    func figureWithAltAttributeParsesAsImage() throws {
        let rows = parse("Before\n\n![](media/pic.png){alt=\"alt\"}\n\nAfter")
        #expect(rows.map(\.blockType) == [.paragraph, .image, .paragraph], "got \(described(rows))")
        let figure = rows[1]
        #expect(figure.imageSrc == "media/pic.png")
        #expect(figure.imageAlt == "alt")
        #expect((figure.imageCaption ?? "").isEmpty, "the bracket text is empty, so there is no caption: \(String(describing: figure.imageCaption))")
        #expect(figure.imageWidth == nil)
    }

    @Test("a figure row with a caption, an alt attribute and a width keeps all three")
    func figureWithCaptionAltAndWidthParsesAsImage() throws {
        let rows = parse("![A caption](media/x.png){alt=\"the alt text\" width=50%}")
        #expect(rows.map(\.blockType) == [.image], "got \(described(rows))")
        let figure = rows[0]
        #expect(figure.imageSrc == "media/x.png")
        #expect(figure.imageAlt == "the alt text")
        #expect(figure.imageCaption == "A caption")
        #expect(figure.imageWidth == 50)
    }
}
