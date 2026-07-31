//
//  BlockParserSectionBreakClassificationTests.swift
//  final finalTests
//
//  Regression coverage for the break-marker-exact-match fix: section-break
//  marker detection (`<!-- ::break:: -->`) was tightened from substring
//  `.contains(...)` to `BlockParser.isSectionBreakMarker(_:)` (marker alone,
//  OR marker as a block's first line followed by body content) at
//  BlockParser.swift's `parse()`/`detectBlockType()` and
//  Database+Blocks.swift's in-place paragraph->section_break UPDATE branch.
//
//  Two failure modes were in play, and both need their own regression case:
//
//  1. Original bug (fixed by moving off `.contains`): a paragraph that only
//     CONTAINS the marker text as a substring, mid-sentence, must NOT be
//     classified as a section break.
//
//  2. Regression found in acceptance review of the FIRST fix attempt (whole-
//     string `trimmed == marker` equality): `RawBlockSplitter`
//     (BlockParser+Splitting.swift) only forces a block boundary right after
//     a marker line when the very next line looks like a list item (its
//     "list interrupts non-list content" guard, `consumeContentLine`). A
//     marker followed immediately by ordinary prose -- no blank line, not a
//     list -- is NOT split there, so it reaches classification as ONE
//     combined block string, e.g. `"<!-- ::break:: -->\nBody text"`.
//     `assembleMarkdown` always rejoins blocks with `"\n\n"`, so that shape
//     can't come from a pure DB round-trip -- but it's exactly what raw
//     typing/paste/import in Source Mode produces (traced via
//     `editorState.content`'s onChange handler in
//     ViewNotificationModifiers.swift, which re-parses the whole document
//     with `BlockParser.parse` on every CodeMirror edit). Whole-string
//     equality would silently drop `isPseudoSection`/`.sectionBreak` for
//     this real, reachable shape -- a section vanishing from the outline
//     sidebar the next time a user edited it. `isSectionBreakMarker`'s
//     first-line check fixes this while still rejecting case 1.
//

import Testing
@testable import final_final

struct BlockParserSectionBreakClassificationTests {

    // MARK: - isSectionBreakMarker (the shared classification predicate)

    @Test func markerAloneIsASectionBreak() {
        #expect(BlockParser.isSectionBreakMarker("<!-- ::break:: -->"))
    }

    @Test func markerFollowedByBodyOnTheNextLineIsASectionBreak() {
        // The regression case: no blank line between the marker and body,
        // so RawBlockSplitter never gets a chance to separate them -- this
        // whole string is what classification actually sees.
        #expect(BlockParser.isSectionBreakMarker("<!-- ::break:: -->\nBody text"))
    }

    @Test func markerFollowedByMultipleBodyLinesIsASectionBreak() {
        #expect(BlockParser.isSectionBreakMarker("<!-- ::break:: -->\nLine one\nLine two"))
    }

    @Test func markerEmbeddedMidSentenceIsNotASectionBreak() {
        // The ORIGINAL bug: a paragraph merely containing the marker text
        // must not match.
        #expect(!BlockParser.isSectionBreakMarker(
            "This is a test paragraph. <!-- ::break:: --> This continues the same paragraph."
        ))
    }

    @Test func markerAtEndOfParagraphIsNotASectionBreak() {
        #expect(!BlockParser.isSectionBreakMarker("Some text before the marker <!-- ::break:: -->"))
    }

    @Test func markerWithTrailingTextOnTheSameLineIsNotASectionBreak() {
        // No newline at all between marker and trailing text -- not "marker
        // as its own first line", so this correctly stays rejected.
        #expect(!BlockParser.isSectionBreakMarker("<!-- ::break:: -->extra"))
    }

    @Test func emptyStringIsNotASectionBreak() {
        #expect(!BlockParser.isSectionBreakMarker(""))
    }

    // MARK: - End-to-end through BlockParser.parse()

    @Test func parseClassifiesMarkerPlusAdjacentProseAsOneSectionBreakBlock() {
        // No blank line between the marker and "Body text" -- the exact
        // shape RawBlockSplitter does NOT split apart for non-list content.
        let markdown = "# Heading\n\n<!-- ::break:: -->\nBody text"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected heading + one combined section-break block. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        let breakBlock = blocks[1]
        #expect(breakBlock.blockType == .sectionBreak)
        #expect(breakBlock.isPseudoSection == true)
        #expect(breakBlock.markdownFragment == "<!-- ::break:: -->\nBody text")
    }

    @Test func parseDoesNotClassifyParagraphContainingMarkerSubstringAsSectionBreak() {
        let markdown = "# Heading\n\n" +
            "This is a test paragraph. <!-- ::break:: --> This continues the same paragraph after the marker text appears mid-sentence."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected heading + one ordinary paragraph. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        let paragraphBlock = blocks[1]
        #expect(paragraphBlock.blockType != .sectionBreak)
        #expect(paragraphBlock.isPseudoSection == false)
    }

    @Test func parseSplitsMarkerFollowedByAListItemIntoTwoBlocks() {
        // When the line right after the marker IS a list item,
        // RawBlockSplitter's own "list interrupts non-list content" guard
        // already separates them -- the marker block stays marker-only, so
        // this must keep working exactly as before.
        let markdown = "<!-- ::break:: -->\n- alpha one"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected the marker and the list item as separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].blockType == .sectionBreak)
        #expect(blocks[0].isPseudoSection == true)
        #expect(blocks[0].markdownFragment == "<!-- ::break:: -->")

        #expect(blocks[1].blockType == .bulletList)
        #expect(blocks[1].isPseudoSection == false)
    }
}
