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
//     (BlockParser+Splitting.swift) only forced a block boundary right after
//     a marker line when the very next line looked like a list item (its
//     "list interrupts non-list content" guard, `consumeContentLine`). A
//     marker followed immediately by ordinary prose -- no blank line, not a
//     list -- was NOT split there, so it reached classification as ONE
//     combined block string, e.g. `"<!-- ::break:: -->\nBody text"`.
//     `isSectionBreakMarker`'s first-line check fixed classification for this
//     shape while still rejecting case 1 -- but that classification fix had a
//     side effect nobody had traced yet: `extractTextContent` forces
//     textContent="" for EVERY `.sectionBreak` block, no exceptions, so the
//     combined block above was classified correctly as `.sectionBreak` while
//     silently DROPPING "Body text" from textContent (word counts, previews,
//     search, the outline sidebar all read textContent, not markdownFragment)
//     -- a real data-loss bug, fixed by case 3 below.
//
//  3. break-marker-text-wipe fix (this file's current pass): rather than patch
//     around the text wipe after the fact, `RawBlockSplitter.consumeContentLine`
//     (BlockParser+Splitting.swift) now flushes the marker as its own complete
//     block the moment it sees the marker sitting ALONE in `currentBlock` with
//     a new line arriving behind it -- so `<!-- ::break:: -->\nBody text` (no
//     blank line) splits into TWO raw blocks before classification ever runs:
//     a marker-only `.sectionBreak` block, and an ordinary `.paragraph` block
//     that gets its textContent extracted normally, wipe-free. This means
//     `isSectionBreakMarker`'s first-line-match branch (added for case 2) no
//     longer fires on the `parse()` path at all -- the splitter now hands it
//     only the marker alone there. It's still load-bearing on the SEPARATE,
//     untouched editor-sync path (`Database+Blocks.swift`'s
//     `applyDetectedTypeFromContent`), where a single already-existing
//     ProseMirror block's own markdown fragment can still legitimately be
//     marker-plus-body as one string. Case 2's own test below
//     (`markerFollowedByBodyOnTheNextLineIsASectionBreak`) exercises the
//     predicate directly and is untouched -- only the END-TO-END `parse()`
//     test for the same shape changes, since the splitter now intercepts it
//     first. See `BlockParser.isSectionBreakMarker`'s doc comment for the full
//     two-call-site explanation.
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

    @Test func parseSplitsMarkerPlusAdjacentProseIntoMarkerAndParagraphBlocks() {
        // This assertion is INVERTED from its previous form (see case 2 vs. case 3
        // in the file header above). It used to assert the marker and "Body text"
        // merged into ONE combined `.sectionBreak` block -- which was itself the
        // bug: extractTextContent forces textContent="" for every `.sectionBreak`
        // block, so "Body text" silently vanished from textContent even though it
        // was still sitting right there in markdownFragment. RawBlockSplitter now
        // flushes the marker as its own block the moment ordinary content arrives
        // behind it with no blank line, so this markdown produces THREE blocks
        // (heading, marker, paragraph) -- and the paragraph's textContent is
        // extracted normally, with nothing wiped.
        let markdown = "# Heading\n\n<!-- ::break:: -->\nBody text"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 3, "Expected heading + marker + paragraph as three separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        let breakBlock = blocks[1]
        #expect(breakBlock.blockType == .sectionBreak)
        #expect(breakBlock.isPseudoSection == true)
        #expect(breakBlock.markdownFragment == "<!-- ::break:: -->")

        let bodyBlock = blocks[2]
        #expect(bodyBlock.blockType == .paragraph)
        #expect(bodyBlock.isPseudoSection == false)
        #expect(bodyBlock.markdownFragment == "Body text")
        #expect(bodyBlock.textContent == "Body text", "The text-wipe bug this fixes: textContent must NOT be empty.")
    }

    @Test func parseSplitsMarkerPlusTwoProseLinesIntoMarkerAndOneParagraphBlock() {
        // The paragraph's SECOND line has no blank line before it either, but it's
        // an ordinary content line (not another marker), so it just keeps
        // accumulating into the same paragraph block once the split has happened.
        let markdown = "<!-- ::break:: -->\nFirst line of body.\nSecond line of body."
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected marker + one paragraph holding both lines. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].blockType == .sectionBreak)
        #expect(blocks[0].markdownFragment == "<!-- ::break:: -->")

        #expect(blocks[1].blockType == .paragraph)
        #expect(blocks[1].markdownFragment == "First line of body.\nSecond line of body.")
        #expect(blocks[1].textContent == "First line of body.\nSecond line of body.")
    }

    @Test func parseSplitsMarkerFollowedByASubHeadingIntoTwoBlocks() {
        let markdown = "<!-- ::break:: -->\n## A Sub-Heading"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected marker + heading as two separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].blockType == .sectionBreak)
        #expect(blocks[0].markdownFragment == "<!-- ::break:: -->")

        #expect(blocks[1].blockType == .heading)
        #expect(blocks[1].headingLevel == 2)
        #expect(blocks[1].textContent == "A Sub-Heading")
    }

    // MARK: - Reverse shape (must-fix 3, disclosed follow-up in the task brief):
    // `Prose\n<!-- ::break:: -->` (marker arriving right after prose, no blank
    // line BEFORE the marker). This wasn't the specifically reported text-wipe bug
    // (the combined block stays typed `.paragraph`, so nothing gets forced to "" --
    // extractTextContent's `.sectionBreak` case never runs), but it shares the same
    // root cause and was fixed the same way: RawBlockSplitter.consumeContentLine
    // flushes whatever was accumulating the moment the marker line itself arrives,
    // splitting BEFORE the marker too, symmetric with the forward-case fix above.

    @Test func parseSplitsProseFollowedByMarkerIntoParagraphAndMarkerBlocks() {
        let markdown = "Some prose right before the break.\n<!-- ::break:: -->"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 2, "Expected paragraph + marker as two separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].blockType == .paragraph)
        #expect(blocks[0].markdownFragment == "Some prose right before the break.")
        #expect(blocks[0].textContent == "Some prose right before the break.")

        #expect(blocks[1].blockType == .sectionBreak)
        #expect(blocks[1].isPseudoSection == true)
        #expect(blocks[1].markdownFragment == "<!-- ::break:: -->")
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

    // MARK: - Must-fix (round 2 review): the two marker-boundary flush sites above
    // (forward and reverse cases in `consumeContentLine`) must reset `inFootnoteDef`,
    // same as every other mid-stream flush in `RawBlockSplitter`. Without the reset,
    // a footnote definition flushed at the marker boundary leaves the flag stuck
    // true, so the next blank line is wrongly treated as a footnote-continuation
    // blank and absorbed into the wrong block -- merging two blocks that should stay
    // separate.

    @Test func parseResetsFootnoteDefFlagAcrossReverseMarkerFlush() {
        // "[^1]: note text" opens a footnote def. The marker arrives right behind it
        // with no blank line (the reverse case), flushing the footnote-def block.
        // Then ordinary prose accumulates, followed by a blank line and a 4-space
        // indented line. Before the fix, the reverse-case flush left inFootnoteDef
        // stuck true, so the blank line's footnote-continuation lookahead (which
        // only checks "is the NEXT line 4-space indented") fired incorrectly,
        // absorbing the blank line and merging "Some paragraph text" with the
        // indented line into one block -- 3 blocks instead of the correct 4.
        let markdown = "[^1]: note text\n<!-- ::break:: -->\nSome paragraph text\n\n    indented line"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 4, "Expected footnote-def + marker + paragraph + indented-line as four separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].markdownFragment == "[^1]: note text")
        #expect(blocks[0].textContent == "note text")

        #expect(blocks[1].blockType == .sectionBreak)
        #expect(blocks[1].markdownFragment == "<!-- ::break:: -->")

        #expect(blocks[2].markdownFragment == "Some paragraph text")
        #expect(blocks[2].textContent == "Some paragraph text")

        #expect(blocks[3].markdownFragment == "indented line", "The indented line must stay its own block, not merged with the paragraph above via a wrongly-absorbed blank line.")
    }

    // MARK: - Must-fix (this branch's own review round): the reverse-case guard in
    // `consumeContentLine` originally matched on `trimmedLine`, i.e. an indentation-
    // stripped comparison, so an INDENTED marker sitting inside a list item (a
    // continuation line, not a new top-level line) was wrongly treated as the
    // reverse-case boundary and split the list into three blocks. The guard is now
    // anchored to the raw, unindented `line` — matching `sectionBreakMarker`'s own
    // documented exact-spacing discipline — so an indented marker stays glued to its
    // surrounding list, matching ProseMirror, which keeps an HTML comment inside a
    // list item as part of the same bullet_list node. The forward case (marker alone
    // in `currentBlock`, regardless of indentation) is intentionally untouched by
    // this fix and still needs its own coverage above.

    @Test func parseKeepsIndentedMarkerInsideListItemAsOneListBlock() {
        let markdown = "- Item one\n  <!-- ::break:: -->\n- Item two"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 1, "An indented marker inside a list item must not split the list. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].blockType == .bulletList)
        #expect(blocks[0].markdownFragment == "- Item one\n  <!-- ::break:: -->\n- Item two")
    }

    // MARK: - Optional coverage (disclosed, not required): the list-interruption
    // guard's own `inFootnoteDef = false` reset, added alongside the marker-boundary
    // resets above but on a different flush site — a list item interrupting an
    // open footnote definition. Same mechanism as
    // `parseResetsFootnoteDefFlagAcrossReverseMarkerFlush` above, exercised through
    // the list-interruption path instead of the marker-reverse path.

    @Test func parseResetsFootnoteDefFlagAcrossListInterruptionFlush() {
        // "[^1]: note text" opens a footnote def. A list item arrives right behind
        // it with no blank line, triggering the list-interruption guard (which
        // flushes the footnote-def block). Without the reset, inFootnoteDef stays
        // stuck true, so the following blank line's footnote-continuation lookahead
        // (which only checks "is the NEXT line 4-space indented") fires incorrectly,
        // absorbing the blank line and merging "- list item" with the indented line
        // into one block -- 2 blocks instead of the correct 3.
        let markdown = "[^1]: note text\n- list item\n\n    indented line"
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(blocks.count == 3, "Expected footnote-def + list item + indented-line as three separate blocks. Got: \(blocks.map { ($0.blockType, $0.markdownFragment) })")

        #expect(blocks[0].markdownFragment == "[^1]: note text")
        #expect(blocks[0].textContent == "note text")

        #expect(blocks[1].blockType == .bulletList)
        #expect(blocks[1].markdownFragment == "- list item")

        #expect(blocks[2].markdownFragment == "indented line", "The indented line must stay its own block, not merged with the list item above via a wrongly-absorbed blank line.")
    }
}
