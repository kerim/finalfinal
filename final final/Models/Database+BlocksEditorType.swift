//
//  Database+BlocksEditorType.swift
//  final final
//
//  The editor's own block type in an update (`BlockUpdate.blockType`), applied by the three update paths of
//  applyBlockChangesFromEditor(). Split out of Database+Blocks.swift to keep that file under the project's
//  file-length limit (see .swiftlint.yml), like Database+BlocksInsert.swift.
//
//  t-94369a83 Phase 3a-2, Step 1. A paragraph the user turns into a list ("- ", "1. ", "> ", three backticks) keeps
//  its block id (block-id-plugin.ts phase1CanClaim), but the update used to carry only the new text and fragment, so
//  the row stayed a paragraph holding a list's text. A reopen without the close-time rebuild then aligned the row as
//  a paragraph against a list node (`BlockParser.alignmentPairs`), withheld its id, and the editor's next batch of changes
//  inserted the list a second time.
//

import Foundation

extension ProjectDatabase {

    /// The only types the editor's node type may move a row among (review finding D3). Heading, rule, section break,
    /// image, math and the bibliography marker are derived from the fragment (or machine-managed) and never come
    /// from, or go to, the editor's type.
    static let editorAuthoritativeTypes: Set<BlockType> = [
        .paragraph, .bulletList, .orderedList, .blockquote, .codeBlock, .table
    ]

    /// Moves `block` to the editor's node type `raw` when that is a legitimate editor-driven change, then recomputes
    /// the word count under the new type (review finding D4: code blocks count zero).
    ///
    /// Call it AFTER the fragment transition of the same update (`applyMarkdownFragmentTransition`, or
    /// `applyHorizontalRuleToggleAndImageMeta` on the temp-id paths). The check on the row's CURRENT type is what
    /// keeps a paragraph the fragment just made a rule or section break from being undone by the editor's
    /// "paragraph" (D3), and keeps a heading a heading. Never acts on a Notes row; ignores nil and unknown strings
    /// (an unknown string is logged once, by name, so a TypeScript/Swift naming mismatch shows up in the log
    /// instead of silently leaving every conversion a paragraph).
    func applyEditorBlockType(_ raw: String?, to block: inout Block) {
        if let raw, BlockType(rawValue: raw) == nil {
            DebugLog.log(.sync, "[Database+Blocks] editor sent an unknown block type \"\(raw)\" -- ignored (block \(block.id.prefix(8)))")
            return
        }
        guard let raw, !block.isNotes,
              let editorType = BlockType(rawValue: raw),
              Self.editorAuthoritativeTypes.contains(editorType),
              Self.editorAuthoritativeTypes.contains(block.blockType),
              editorType != block.blockType else { return }
        let oldType = block.blockType
        let oldWC = block.wordCount
        block.blockType = editorType
        // From the row's markdown (the same update's fragment was applied just before this call), so a citation keeps its two words
        // (t-0b70d1e9); a code block still counts zero.
        block.recalculateWordCount(fromMarkdown: block.markdownFragment)
        DebugLog.log(.data, "[Database+Blocks] editor type \(oldType.rawValue)→\(editorType.rawValue) block=\(block.id.prefix(8))")
        logWordCountChange(block: block, oldWordCount: oldWC, tag: "→\(editorType.rawValue)")
    }

    /// Sets `block.textContent` to what the whole-document write stores for the same markdown: `BlockParser.extractTextContent` of
    /// the trimmed fragment, read under the row's FINAL type (t-4eb7bfa9, plan step 5). The editor's own `textContent` is
    /// ProseMirror's `node.textContent`, which leaves out inline atoms and joins quote and table text with no separator, so a row
    /// kept by an edit used to differ from the row a close would write, and the close rebuilt it (the X1 rule in
    /// `LifecycleWholeDocumentWrite+Check`). One helper for all four paths that carry a fragment (`applyUpdateToExistingBlock`,
    /// `mergeUpdateIntoInsertedBlock`, `applyDefensiveTempIdUpdate`, `buildInsertedBlock`).
    ///
    /// Call it LAST, after the fragment step, `applyEditorBlockType` and the heading level, next to `recountWordsFromFragment`:
    /// the type it reads must be the one the row keeps. It leaves the word count alone (that is counted from the fragment).
    func applyTextContentFromFragment(_ block: inout Block, _ markdownFragment: String) {
        let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        block.textContent = BlockParser.extractTextContent(from: trimmed, blockType: block.blockType)
    }
}
