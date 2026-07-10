//
//  BlockParserAlignmentTests.swift
//  final finalTests
//
//  Tests for empty-fragment filtering in BlockParser to prevent
//  bibliography duplication caused by parity mismatch between
//  assembled markdown and block ID arrays.
//
//  The "Single-source-splice regression guards" tests below guard the
//  assembleMarkdown/idsForProseMirrorAlignment count+content invariants that
//  handleFootnoteInsertedImmediate now depends on by pushing result.markdown. They do
//  NOT and cannot prove the live WKWebView corruption is gone — see
//  docs/plans/single-source-splice.md Part 4 for the required live protocol.
//

import Testing
@testable import final_final

struct BlockParserAlignmentTests {

    // MARK: - isEmptyFragment helper

    @Test func isEmptyFragmentReturnsTrueForEmptyString() {
        #expect(BlockParser.isEmptyFragment(""))
    }

    @Test func isEmptyFragmentReturnsTrueForWhitespace() {
        #expect(BlockParser.isEmptyFragment("   "))
    }

    @Test func isEmptyFragmentReturnsTrueForNewlines() {
        #expect(BlockParser.isEmptyFragment("\n\n"))
    }

    @Test func isEmptyFragmentReturnsFalseForContent() {
        #expect(!BlockParser.isEmptyFragment("# Heading"))
    }

    @Test func isEmptyFragmentReturnsFalseForSectionBreak() {
        #expect(!BlockParser.isEmptyFragment("<!-- ::break:: -->"))
    }

    // MARK: - assembleMarkdown skips empty fragments

    @Test func assembleMarkdownSkipsEmptyFragments() {
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .sectionBreak,
                  textContent: "", markdownFragment: "",
                  headingLevel: nil, isPseudoSection: true),
            Block(projectId: "p1", sortOrder: 2, blockType: .heading,
                  textContent: "Test", markdownFragment: "# Test",
                  headingLevel: 1),
            Block(projectId: "p1", sortOrder: 3, blockType: .paragraph,
                  textContent: "Hello", markdownFragment: "Hello"),
        ]

        let result = BlockParser.assembleMarkdown(from: blocks)
        // Empty fragment should not produce leading "\n\n"
        #expect(result == "# Test\n\nHello")
    }

    // MARK: - idsForProseMirrorAlignment count matches non-empty fragments

    @Test func alignmentCountMatchesAssembledFragments() {
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .sectionBreak,
                  textContent: "", markdownFragment: "",
                  headingLevel: nil, isPseudoSection: true),
            Block(projectId: "p1", sortOrder: 2, blockType: .heading,
                  textContent: "Test", markdownFragment: "# Test",
                  headingLevel: 1),
            Block(projectId: "p1", sortOrder: 3, blockType: .paragraph,
                  textContent: "Body text", markdownFragment: "Body text"),
            Block(projectId: "p1", sortOrder: 4, blockType: .paragraph,
                  textContent: "Ref entry", markdownFragment: "Ref entry",
                  isBibliography: true),
        ]

        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        // 4 blocks total, but 1 is empty → 3 IDs
        let nonEmptyCount = blocks.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }.count
        #expect(ids.count == nonEmptyCount)
    }

    // MARK: - Empty filter and list merging coexist

    @Test func emptyFilterAndListMergingCoexist() {
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .sectionBreak,
                  textContent: "", markdownFragment: "",
                  headingLevel: nil, isPseudoSection: true),
            Block(projectId: "p1", sortOrder: 2, blockType: .bulletList,
                  textContent: "Item 1", markdownFragment: "- Item 1"),
            Block(projectId: "p1", sortOrder: 3, blockType: .bulletList,
                  textContent: "Item 2", markdownFragment: "- Item 2"),
            Block(projectId: "p1", sortOrder: 4, blockType: .paragraph,
                  textContent: "Para", markdownFragment: "Para"),
        ]

        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        // Empty block filtered → 3 blocks remain
        // Two bullet_list blocks merge → 1 ID for the list
        // Plus 1 ID for paragraph → 2 IDs total
        #expect(ids.count == 2)

        let assembled = BlockParser.assembleMarkdown(from: blocks)
        // Empty block filtered, then joined with \n\n
        #expect(assembled == "- Item 1\n\n- Item 2\n\nPara")
    }

    // MARK: - Single-source-splice regression guards
    //
    // These guard the assembleMarkdown/idsForProseMirrorAlignment invariants that
    // handleFootnoteInsertedImmediate now depends on by pushing result.markdown directly
    // (see docs/plans/single-source-splice.md). They do NOT and cannot prove the live
    // WKWebView positional-ID-assignment corruption is gone — that requires the live
    // protocol in that plan's Part 4.

    @Test func assembleMarkdownPreservesExistingFootnoteTextWhenNewFootnoteInserted() {
        // Models the exact bug scenario: a body paragraph, a Notes heading, an existing
        // footnote definition with real text, a newly-inserted (still-blank) second
        // footnote definition, and a bibliography block.
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text", markdownFragment: "Body text"),
            Block(projectId: "p1", sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes",
                  headingLevel: 1),
            Block(projectId: "p1", sortOrder: 3, blockType: .paragraph,
                  textContent: "real text", markdownFragment: "[^1]: real text",
                  isNotes: true),
            Block(projectId: "p1", sortOrder: 4, blockType: .paragraph,
                  textContent: "", markdownFragment: "[^2]: ",
                  isNotes: true),
            Block(id: "bib-block", projectId: "p1", sortOrder: 5, blockType: .paragraph,
                  textContent: "Smith (2020)", markdownFragment: "Smith (2020)",
                  isBibliography: true),
        ]

        let assembled = BlockParser.assembleMarkdown(from: blocks)
        // The existing definition's text must survive verbatim — never blanked by
        // assembling around a newly-inserted, still-empty sibling definition.
        #expect(assembled.contains("[^1]: real text"))
    }

    @Test func firstBibliographyNodeIndexPointsAtBibliographyAlignedIndex() {
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text", markdownFragment: "Body text"),
            Block(projectId: "p1", sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes",
                  headingLevel: 1),
            Block(projectId: "p1", sortOrder: 3, blockType: .paragraph,
                  textContent: "real text", markdownFragment: "[^1]: real text",
                  isNotes: true),
            Block(projectId: "p1", sortOrder: 4, blockType: .paragraph,
                  textContent: "", markdownFragment: "[^2]: ",
                  isNotes: true),
            Block(id: "bib-block", projectId: "p1", sortOrder: 5, blockType: .paragraph,
                  textContent: "Smith (2020)", markdownFragment: "Smith (2020)",
                  isBibliography: true),
        ]

        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let bibIndex = BlockParser.firstBibliographyNodeIndex(blocks)

        #expect(bibIndex != nil)
        if let bibIndex {
            // The index returned must line up with the bibliography block's own ID in the
            // same aligned array the fix pushes as `blockIds` — guards the cursorBoundary
            // the push relies on.
            #expect(ids[bibIndex] == "bib-block")
        }
    }

    // MARK: - alignmentPairs / setBlockIdsForTopLevel hardening

    @Test func alignmentPairsProducesCorrectTriplesForMixedTypeBlockList() {
        let blocks = [
            Block(id: "a", projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text", markdownFragment: "Body text"),
            Block(id: "b", projectId: "p1", sortOrder: 2, blockType: .heading,
                  textContent: "A Heading", markdownFragment: "# A Heading", headingLevel: 1),
            Block(id: "c", projectId: "p1", sortOrder: 3, blockType: .image,
                  textContent: "", markdownFragment: "![alt](img.png)"),
            Block(id: "d", projectId: "p1", sortOrder: 4, blockType: .codeBlock,
                  textContent: "let x = 1", markdownFragment: "```\nlet x = 1\n```"),
        ]

        let pairs = BlockParser.alignmentPairs(blocks)

        #expect(pairs.count == 4)
        #expect(pairs[0].id == "a")
        #expect(pairs[0].meta.blockType == "paragraph")
        #expect(pairs[0].meta.nonEmpty == true)
        #expect(pairs[1].id == "b")
        #expect(pairs[1].meta.blockType == "heading")
        #expect(pairs[1].meta.nonEmpty == true)
        #expect(pairs[2].id == "c")
        #expect(pairs[2].meta.blockType == "image")
        #expect(pairs[2].meta.nonEmpty == false)
        #expect(pairs[3].id == "d")
        #expect(pairs[3].meta.blockType == "code_block")
        #expect(pairs[3].meta.nonEmpty == true)
    }

    @Test func alignmentPairsCollapsesConsecutiveSameTypeListBlocksIntoOneEntry() {
        // Mirrors emptyFilterAndListMergingCoexist's fixture shape above.
        let blocks = [
            Block(projectId: "p1", sortOrder: 1, blockType: .sectionBreak,
                  textContent: "", markdownFragment: "",
                  headingLevel: nil, isPseudoSection: true),
            Block(id: "item1", projectId: "p1", sortOrder: 2, blockType: .bulletList,
                  textContent: "Item 1", markdownFragment: "- Item 1"),
            Block(id: "item2", projectId: "p1", sortOrder: 3, blockType: .bulletList,
                  textContent: "Item 2", markdownFragment: "- Item 2"),
            Block(id: "para", projectId: "p1", sortOrder: 4, blockType: .paragraph,
                  textContent: "Para", markdownFragment: "Para"),
        ]

        let pairs = BlockParser.alignmentPairs(blocks)

        // Empty section-break filtered; two bullet_list blocks merge into ONE entry
        // (keyed on the FIRST block's own id/nonEmpty); plus the paragraph → 2 entries total.
        #expect(pairs.count == 2)
        #expect(pairs[0].id == "item1")
        #expect(pairs[0].meta.blockType == "bullet_list")
        #expect(pairs[0].meta.nonEmpty == true)
        #expect(pairs[1].id == "para")
    }

    @Test func idsForProseMirrorAlignmentMatchesIndependentlyComputedExpectation() {
        // No-drift guard on the idsForProseMirrorAlignment → alignmentPairs delegation.
        // Expected id arrays below are HAND-COMPUTED from the fixture semantics (empty-fragment
        // filtering + consecutive-same-type-list merging + bibliography-marker exclusion), NOT
        // derived by calling alignmentPairs — comparing against alignmentPairs's own output here
        // would be a tautology given idsForProseMirrorAlignment is now a one-line delegation to it.
        let fixture1 = [
            Block(id: "a", projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "A", markdownFragment: "A"),
            Block(id: "b", projectId: "p1", sortOrder: 2, blockType: .sectionBreak,
                  textContent: "", markdownFragment: "", isPseudoSection: true),
            Block(id: "c", projectId: "p1", sortOrder: 3, blockType: .bulletList,
                  textContent: "Item 1", markdownFragment: "- Item 1"),
            Block(id: "d", projectId: "p1", sortOrder: 4, blockType: .bulletList,
                  textContent: "Item 2", markdownFragment: "- Item 2"),
            Block(id: "e", projectId: "p1", sortOrder: 5, blockType: .heading,
                  textContent: "End", markdownFragment: "# End", headingLevel: 1),
        ]
        #expect(BlockParser.idsForProseMirrorAlignment(fixture1) == ["a", "c", "e"])

        let fixture2 = [
            Block(id: "x", projectId: "p1", sortOrder: 1, blockType: .heading,
                  textContent: "Title", markdownFragment: "# Title", headingLevel: 1),
            Block(id: "marker", projectId: "p1", sortOrder: 2, blockType: .bibliography,
                  textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->"),
            Block(id: "y", projectId: "p1", sortOrder: 3, blockType: .paragraph,
                  textContent: "Ref", markdownFragment: "Ref", isBibliography: true),
        ]
        #expect(BlockParser.idsForProseMirrorAlignment(fixture2) == ["x", "y"])

        let fixture3 = [
            Block(id: "only", projectId: "p1", sortOrder: 1, blockType: .orderedList,
                  textContent: "One", markdownFragment: "1. One"),
        ]
        #expect(BlockParser.idsForProseMirrorAlignment(fixture3) == ["only"])
    }

    @Test func idsForProseMirrorAlignmentDelegatesToAlignmentPairsAndExcludesBibliographyMarker() {
        let blocks = [
            Block(id: "body-block", projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text", markdownFragment: "Body text"),
            Block(id: "marker-block", projectId: "p1", sortOrder: 2, blockType: .bibliography,
                  textContent: "", markdownFragment: "<!-- ::auto-bibliography:: -->"),
            Block(id: "heading-block", projectId: "p1", sortOrder: 3, blockType: .heading,
                  textContent: "References", markdownFragment: "# References", headingLevel: 1),
        ]

        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let pairs = BlockParser.alignmentPairs(blocks)

        #expect(ids == ["body-block", "heading-block"])
        #expect(pairs.map { $0.id } == ["body-block", "heading-block"])
        #expect(pairs.map { $0.meta.blockType } == ["paragraph", "heading"])
    }

    @Test func nonEmptyReflectsTrimmedTextContentForBlankVsNonBlankSameType() {
        let blocks = [
            // markdownFragment must NOT itself trim to empty, or isEmptyFragment() filters
            // this block out of alignmentPairs entirely (same long-standing filter used to
            // drop blocks that produce no ProseMirror node) — leaving `pairs` with only 1
            // entry and turning `pairs[1]` below into an out-of-bounds crash. "&nbsp;" survives
            // that filter (non-whitespace characters) while textContent stays blank, modeling a
            // paragraph that structurally exists but has no real text — the exact shape this
            // test is meant to check.
            Block(id: "blank", projectId: "p1", sortOrder: 1, blockType: .paragraph,
                  textContent: "   ", markdownFragment: "&nbsp;"),
            Block(id: "filled", projectId: "p1", sortOrder: 2, blockType: .paragraph,
                  textContent: "hi", markdownFragment: "hi"),
        ]

        let pairs = BlockParser.alignmentPairs(blocks)

        #expect(pairs.count == 2)
        #expect(pairs[0].id == "blank")
        #expect(pairs[0].meta.nonEmpty == false) // whitespace-only textContent trims to ""
        #expect(pairs[1].id == "filled")
        #expect(pairs[1].meta.nonEmpty == true)
    }

    // MARK: - Cross-language pin (mirrors block-id-alignment-cross-language.test.ts)

    /// Computes `alignmentPairs` over markdown parsed through the REAL BlockParser.parse
    /// pipeline (not hand-built Block fixtures), so this exercises the actual
    /// extractTextContent / MarkdownUtils.stripMarkdownSyntax extraction logic. Asserts each
    /// `nonEmpty` matches the same documented constants used in the TS-side cross-language
    /// fixture (block-id-alignment-cross-language.test.ts) — the safety net catching future
    /// drift in Swift's extraction logic relative to what the JS side assumes.
    @Test func crossLanguagePinMatchesTSFixtureNonEmptyConstants() {
        func nonEmpty(for markdown: String) -> Bool? {
            let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
            let pairs = BlockParser.alignmentPairs(blocks)
            return pairs.first?.meta.nonEmpty
        }

        // "Plain paragraph text." → TS: nonEmpty true
        #expect(nonEmpty(for: "Plain paragraph text.") == true)
        // "# Heading Text" → TS: nonEmpty true
        #expect(nonEmpty(for: "# Heading Text") == true)
        // "[@smith2020]" (citation-only) → TS: Swift-side nonEmpty true (citations never stripped)
        #expect(nonEmpty(for: "[@smith2020]") == true)
        // "[^3]" (bare footnote-ref-only) → TS: nonEmpty false (footnote-ref-removal regex strips it)
        #expect(nonEmpty(for: "[^3]") == false)
        // "[^1]: real text" (footnote-def, non-blank) → TS: nonEmpty true
        #expect(nonEmpty(for: "[^1]: real text") == true)
        // "[^2]: " (footnote-def, blank) → TS: nonEmpty false
        #expect(nonEmpty(for: "[^2]: ") == false)
    }
}
