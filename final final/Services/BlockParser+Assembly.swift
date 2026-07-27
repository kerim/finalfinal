//
//  BlockParser+Assembly.swift
//  final final
//
//  Reassembles blocks back into markdown, and derives the ProseMirror
//  top-level alignment arrays. Extracted from BlockParser.swift.
//

import Foundation

extension BlockParser {

    // MARK: - Assembly

    /// Assemble blocks back into markdown
    /// Uses tuple comparison for tie-breaking: headings sort before non-headings at same sortOrder
    static func assembleMarkdown(from blocks: [Block]) -> String {
        // MUST filter empty fragments — they produce no ProseMirror node
        let result = assemblySorted(blocks)
            .map { $0.markdownFragment }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")

        DebugLog.log(.sync, "[ASSEMBLE] \(blocks.count) blocks -> result length=\(result.count)")

        return result
    }

    /// Assemble blocks into Pandoc-compatible markdown for export.
    /// Uses `markdownForExport()` which includes fig-alt and width attributes for image blocks.
    static func assembleMarkdownForExport(from blocks: [Block]) -> String {
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        assemblySorted(blocks)
            .map { $0.markdownForExport() }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")
    }

    /// Assemble blocks into standard markdown for export (no Pandoc attributes).
    /// Uses `markdownForStandardExport()` which outputs plain markdown with captions as italic text.
    static func assembleStandardMarkdownForExport(from blocks: [Block]) -> String {
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        assemblySorted(blocks)
            .map { $0.markdownForStandardExport() }
            .filter { !isEmptyFragment($0) }
            .joined(separator: "\n\n")
    }

    /// Shared assembly ordering: by `sortOrder`, with headings ahead of non-headings
    /// at the same `sortOrder`. All three `assemble…` entry points MUST use this, or
    /// an export can disagree with the editor about block order.
    private static func assemblySorted(_ blocks: [Block]) -> [Block] {
        blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
    }

    // MARK: - ProseMirror Alignment

    /// Returns the node index (in ProseMirror alignment order) of the first bibliography
    /// block, or nil if no bibliography blocks exist.
    /// MUST stay in sync with idsForProseMirrorAlignment list-merging logic.
    static func firstBibliographyNodeIndex(_ blocks: [Block]) -> Int? {
        var nodeIndex = 0
        var prevListType: BlockType?

        for block in blocks {
            if isEmptyFragment(block.markdownFragment) { continue }

            let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)

            if isListBlock && block.blockType == prevListType {
                // Merged into previous list node — same index
                if block.isBibliography { return nodeIndex - 1 }
                continue
            }

            if block.isBibliography { return nodeIndex }
            nodeIndex += 1
            prevListType = isListBlock ? block.blockType : nil
        }
        return nil
    }

    /// Per-id ground-truth metadata handed to the JS side's optional `setBlockIdsForTopLevel`
    /// alignment check (see block-id-plugin.ts `ExpectedBlockMeta`). Kept as a separate
    /// Codable type (rather than reusing `Block`) so the JSON payload sent to JS is minimal
    /// and doesn't leak unrelated Block fields.
    struct BlockAlignmentMeta: Codable, Sendable {
        /// blockType: Swift BlockType.rawValue. nonEmpty: blankness ⟺ text.trim() == "" —
        /// SAME symmetric definition as the TS side (block-id-plugin.ts). Keep both in lockstep.
        let blockType: String
        let nonEmpty: Bool
    }

    /// Single source of truth for "which blocks get a top-level PM id, and what they're
    /// expected to be" — idsForProseMirrorAlignment delegates here TOTALLY (see below), so the
    /// id array and the metadata array cannot drift apart in count/order by construction.
    static func alignmentPairs(_ blocks: [Block]) -> [(id: String, meta: BlockAlignmentMeta)] {
        var result: [(id: String, meta: BlockAlignmentMeta)] = []
        var prevListType: BlockType?
        for block in blocks {
            if isEmptyFragment(block.markdownFragment) { continue }
            // The standalone auto-bibliography MARKER block (distinct from ordinary blocks
            // flagged isBibliography=true, which keep blockType .heading/.paragraph) parses to
            // the `auto_bibliography` PM atom, excluded from BLOCK_TYPES/isBlockType() on the JS
            // side, so it never consumes an index tick in setBlockIdsForTopLevel's walk.
            // Including its id here would shift every subsequent id one position early — so it
            // must contribute NEITHER an id NOR metadata, matching the JS-side exclusion exactly.
            if block.blockType == .bibliography { continue }
            let isListBlock = (block.blockType == .bulletList || block.blockType == .orderedList)
            if isListBlock && block.blockType == prevListType { continue }
            let nonEmpty = !block.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            result.append((block.id, BlockAlignmentMeta(blockType: block.blockType.rawValue, nonEmpty: nonEmpty)))
            prevListType = isListBlock ? block.blockType : nil
        }
        return result
    }

    /// Collapse consecutive same-type list block IDs for ProseMirror alignment.
    /// ProseMirror merges consecutive list items (separated by \n\n in assembleMarkdown)
    /// into a single list node. This produces an ID array matching PM's top-level node count.
    /// Delegates entirely to `alignmentPairs` — see that function for the filtering/merging rules.
    /// - Parameter blocks: Must be sorted by `sortOrder` ascending.
    static func idsForProseMirrorAlignment(_ blocks: [Block]) -> [String] {
        alignmentPairs(blocks).map { $0.id }
    }
}
