//
//  BlockParserAdjacentListAlignmentTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  t-4eb7bfa9, review finding F1. `BlockParser.alignmentPairs` (and with it `idsForProseMirrorAlignment`) hands the editor ONE id per
//  top-level node, and merged ANY consecutive same-type list rows into one slot. The Rich Text editor now writes a list directly
//  after another list with the OTHER marker (`* a` then `- b`; `1.` then `1)`), Milkdown reads that as TWO list nodes, and the
//  splitter keeps them as two rows, so one slot for both shifted every later id by one and typing could land in the wrong row.
//
//  The rule: a list row joins the list node before it only when it has the same list type AND the same marker signature (bullet
//  character, or number delimiter). Rows of one list written one per item by an earlier version (`- a`, `- b`, `- c`) share a
//  signature and still merge. `firstBibliographyNodeIndex` and `lastBibliographyNodeIndex` count nodes the same way.
//
//  Every expectation below is the node count Milkdown has for the same text, counted by hand: the editor's top-level nodes of
//  `Intro\n\n* a\n\n- b\n\nOutro` are paragraph, list, list, paragraph.
//

import Foundation
import Testing
@testable import final_final

@Suite("BlockParser alignment: lists with different markers are different nodes (t-4eb7bfa9, F1)")
struct BlockParserAdjacentListAlignmentTests {

    private func row(_ order: Double, _ type: BlockType, _ fragment: String, text: String? = nil, bibliography: Bool = false) -> Block {
        var block = Block(
            projectId: "adjacent-lists", sortOrder: order, blockType: type, textContent: text ?? fragment, markdownFragment: fragment)
        block.isBibliography = bibliography
        return block
    }

    // MARK: - (a) the alignment pairs

    @Test("a bullet list directly after a bullet list with the other bullet gets its own slot")
    func differentBulletsAreTwoSlots() {
        let rows = [row(1, .bulletList, "* a"), row(2, .bulletList, "- b"), row(3, .paragraph, "after")]
        let pairs = BlockParser.alignmentPairs(rows)
        #expect(pairs.count == 3, "hand count: list, list, paragraph = 3 editor nodes, got \(pairs.count)")
        #expect(pairs.map(\.id) == rows.map(\.id), "one id per row")
        #expect(pairs.map(\.meta.blockType) == ["bullet_list", "bullet_list", "paragraph"])
        #expect(BlockParser.idsForProseMirrorAlignment(rows) == rows.map(\.id))
    }

    @Test("an ordered list directly after an ordered list with the other delimiter gets its own slot")
    func differentDelimitersAreTwoSlots() {
        let rows = [row(1, .orderedList, "1. a"), row(2, .orderedList, "1) b")]
        let pairs = BlockParser.alignmentPairs(rows)
        #expect(pairs.count == 2, "list, list = 2 nodes, got \(pairs.count)")
        #expect(pairs.map(\.id) == rows.map(\.id))
    }

    @Test("rows of one list written one per item (an earlier version's loose list) still share ONE slot, under the first row's id")
    func perItemRowsOfOneListMerge() {
        let rows = [row(1, .bulletList, "- a"), row(2, .bulletList, "- b"), row(3, .bulletList, "- c")]
        let pairs = BlockParser.alignmentPairs(rows)
        #expect(pairs.count == 1, "one list node, got \(pairs.count)")
        #expect(pairs.first?.id == rows[0].id)
        let ordered = [row(1, .orderedList, "1. a"), row(2, .orderedList, "2. b")]
        #expect(BlockParser.alignmentPairs(ordered).map(\.id) == [ordered[0].id])
        // Per-item rows of a list, then a list with the other marker: two nodes.
        let mixed = [row(1, .bulletList, "* a"), row(2, .bulletList, "* b"), row(3, .bulletList, "- c")]
        #expect(BlockParser.alignmentPairs(mixed).map(\.id) == [mixed[0].id, mixed[2].id])
    }

    @Test("a list of the other type is a node of its own, as before")
    func bulletThenOrderedIsTwoSlots() {
        let rows = [row(1, .bulletList, "* a"), row(2, .orderedList, "1. b")]
        #expect(BlockParser.alignmentPairs(rows).count == 2)
    }

    @Test("what the parser writes for the editor's own text: one slot per editor node")
    func parsedEditorTextHasOneSlotPerNode() {
        // The editor's text for: paragraph, list, list (other bullet), paragraph, ordered list, ordered list (other delimiter).
        let markdown = "Intro\n\n* a\n\n- b\n\nOutro\n\n1. x\n\n1) y"
        let rows = BlockParser.parse(
            markdown: markdown, projectId: "adjacent-lists", bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
        #expect(rows.count == 6, "six rows, got \(rows.map(\.markdownFragment))")
        #expect(BlockParser.alignmentPairs(rows).count == 6, "six editor nodes: paragraph, list, list, paragraph, list, list")
    }

    // MARK: - (b) the bibliography node indexes

    @Test("the bibliography indexes count the second list as its own node")
    func bibliographyIndexesCountEachListNode() {
        // Editor nodes: paragraph 0, list 1, list 2, bibliography paragraph 3.
        let rows = [
            row(1, .paragraph, "Intro"), row(2, .bulletList, "* a"), row(3, .bulletList, "- b"),
            row(4, .paragraph, "Entry one.", bibliography: true)
        ]
        #expect(BlockParser.firstBibliographyNodeIndex(rows) == 3, "got \(String(describing: BlockParser.firstBibliographyNodeIndex(rows)))")
        #expect(BlockParser.lastBibliographyNodeIndex(rows) == 4, "one past the last bibliography node")
        #expect(BlockParser.alignmentPairs(rows).count == 4)
    }

    @Test("a bibliography flag on the second list's row is that list's own node")
    func bibliographyFlagOnTheSecondList() {
        // Editor nodes: paragraph 0, list 1, list 2 (flagged).
        let rows = [row(1, .paragraph, "Intro"), row(2, .bulletList, "* a"), row(3, .bulletList, "- b", bibliography: true)]
        #expect(BlockParser.firstBibliographyNodeIndex(rows) == 2)
        #expect(BlockParser.lastBibliographyNodeIndex(rows) == 3)
    }

    @Test("per-item rows of one list still count as one node before the bibliography")
    func bibliographyIndexesAfterPerItemRows() {
        // Editor nodes: paragraph 0, list 1, bibliography paragraph 2.
        let rows = [
            row(1, .paragraph, "Intro"), row(2, .bulletList, "- a"), row(3, .bulletList, "- b"),
            row(4, .paragraph, "Entry one.", bibliography: true)
        ]
        #expect(BlockParser.firstBibliographyNodeIndex(rows) == 2)
        #expect(BlockParser.lastBibliographyNodeIndex(rows) == 3)
        #expect(BlockParser.alignmentPairs(rows).count == 3)
    }
}
