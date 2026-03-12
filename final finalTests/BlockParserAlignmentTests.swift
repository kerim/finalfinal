//
//  BlockParserAlignmentTests.swift
//  final finalTests
//
//  Tests for empty-fragment filtering in BlockParser to prevent
//  bibliography duplication caused by parity mismatch between
//  assembled markdown and block ID arrays.
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
}
