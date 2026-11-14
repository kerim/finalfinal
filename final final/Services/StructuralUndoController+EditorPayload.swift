//
//  StructuralUndoController+EditorPayload.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2b: the editor payload builder, factored out of `fetchFullBlocksWithIds`
//  (StructuralUndoController.swift) so that ANY set of block rows can be turned into the payload the editor receives, not only the
//  rows the database holds right now.
//
//  Why it is needed. The editor-first Version History restores (rounds 2c to 2d) work out the rows they WILL write before the
//  database holds them (`ProjectDatabase.preparedRowsForWholeReplace` for a whole document, `BlockParser.parse` of a snapshot
//  section for a section), and hand the editor the Markdown and the ids those rows have. The ids must line up with the editor's own
//  top-level nodes exactly the way a whole-document push lines up, so the one function that decides that lives here and every caller
//  uses it: `alignmentPairs` merges consecutive rows of one list type AND marker into one node (a list directly after another with the
//  other bullet or delimiter is its own node), skips an empty fragment and skips the
//  auto-bibliography marker, and `assembleMarkdownForEditor` writes the Markdown the editor parses. A payload built somewhere else
//  would drift from that rule (a loose list, an empty paragraph, the bibliography marker each shift every later id by one).
//
//  `fetchFullBlocksWithIds` is now "read the rows, call this", and its output is unchanged (unit test U-S2-P1 compares the two field
//  by field on the article and the six-chapter book).
//

import Foundation

extension StructuralUndoController {

    /// The editor payload for `rows`: the Markdown the editor parses, the id of each top-level node it will hold (and what each is
    /// expected to be), the image metadata, the bibliography span and the managed ids. This is exactly what
    /// `ContentView.fetchBlocksWithIds()`'s non-zoomed path builds from the table, for rows that need not be in the table yet.
    ///
    /// `rows` are put in assembly order here (`BlockParser.assemblySorted`: by `sortOrder`, a heading before a non-heading at one
    /// value), so a caller may pass them in any order. The rows are read, never written.
    static func editorPayload(for rows: [Block]) -> ContentView.BlockFetchResult {
        let sorted = BlockParser.assemblySorted(rows)
        // assembleMarkdownForEditor (not plain assembleMarkdown): this markdown becomes editorState.content, which
        // flushContentToDatabase() reparses before every PDF export; it carries the bibliography-end terminator when the
        // document ends in bibliography content.
        let markdown = BlockParser.assembleMarkdownForEditor(from: sorted)
        // One call produces both the id array and its expected-metadata array from the SAME iteration, so the two cannot drift
        // apart in count or order (see alignmentPairs).
        let pairs = BlockParser.alignmentPairs(sorted)
        let imageMeta = sorted
            .filter { $0.blockType == .image }
            .map { ContentView.ImageBlockMeta(id: $0.id, width: $0.imageWidth, caption: $0.imageCaption, alt: $0.imageAlt, src: $0.imageSrc) }
        return ContentView.BlockFetchResult(
            markdown: markdown, blockIds: pairs.map { $0.id }, imageMeta: imageMeta,
            bibBoundaryIndex: BlockParser.firstBibliographyNodeIndex(sorted),
            bibBoundaryEndIndex: BlockParser.lastBibliographyNodeIndex(sorted),
            expectedBlocks: pairs.map { $0.meta },
            managedBlockIds: Set(sorted.filter { $0.isBibliography || $0.isNotes }.map { $0.id })
        )
    }
}
