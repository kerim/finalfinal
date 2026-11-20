//
//  MarkdownThematicBreakRoundTripTests.swift
//  final finalTests
//
//  t-5f2d2464. In Markdown mode a line of dashes ("---") and a YAML front-matter block made of `key: value` lines
//  ("---", "key: value", "---") are both text the user can type. They reach the database through the same per-block
//  writer as any other typing (`BlockSyncService.reserveMarkdownTurn` / `applyMarkdownTurn`, which end in
//  `applyBlockChangesFromEditor`), where `applyDetectedTypeFromContent` turns a paragraph row into a horizontal rule when
//  the row's whole trimmed fragment is dashes. This pins that neither text changes on its way to the database and back:
//
//    - a lone "---" line replaces an existing paragraph. `MarkdownBlockDiff` ordinarily pairs a removed and an inserted
//      block into an update only when their block types are equal (Notes footnote paragraphs pair by slot instead), and
//      the parse types the lone line a rule, so it ordinarily arrives as a delete plus an insert and the
//      paragraph-to-rule branch is not reached;
//    - front matter made only of `key: value` lines is ONE multi-line paragraph. The anchored pattern needs the whole
//      trimmed fragment to be dashes, so the block does not match, and the row keeps its text, its type and its id (an
//      update of the old paragraph). Front matter with list values is split into more than one block by the splitter;
//      this test does not cover it (see the board).
//
//  Rig: the same as `MarkdownBlockWriteTests.onlyChangedRowsWritten`. `makeStack` (Helpers/ScriptedJSSupport.swift)
//  builds a real temporary project database, a `BlockSyncService` configured on it (the real service entry and writer),
//  an idle `EditorViewState` and a `WKWebView` that never loads a page: no editor page, no debounce, no bibliography
//  flush.
//

import Foundation
import Testing
@testable import final_final

@Suite(
    "Markdown mode: a '---' line and YAML front matter save and reopen with the same text (t-5f2d2464)",
    .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownThematicBreakRoundTripTests {

    // MARK: - Helpers

    private func parse(_ markdown: String, projectId: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: projectId, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    private func rows(_ db: ProjectDatabase) throws -> [Block] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: db))
    }

    /// What must survive a save: the block's type and its text.
    private struct RowShape: Equatable, CustomStringConvertible {
        let blockType: BlockType
        let fragment: String

        init(_ block: Block) {
            blockType = block.blockType
            fragment = block.markdownFragment
        }

        var description: String { "\(blockType.rawValue):\(fragment.debugDescription)" }
    }

    // MARK: - The round trip

    @Test("a '---' line replacing a paragraph, and a front-matter block replacing another, save and reopen with the same text")
    func dashLineAndFrontMatterRoundTrip() async throws {
        // The "Preamble." paragraph becomes the front-matter paragraph (the same block type, so an update that keeps its id);
        // the "Middle." paragraph is replaced by a lone '---' line (a different block type, so a delete plus an insert).
        let oldText = "Preamble.\n\n# Alpha\n\nOne.\n\nMiddle.\n\nTwo."
        let newText = "---\ntitle: Draft\nauthor: Me\n---\n\n# Alpha\n\nOne.\n\n---\n\nTwo."
        let stack = try makeStack(content: oldText)
        let before = try rows(stack.db)
        try #require(before.map(\.markdownFragment) == ["Preamble.", "# Alpha", "One.", "Middle.", "Two."])

        // (1) Precondition: the parse types the front matter a paragraph and the lone '---' a rule.
        let parsed = parse(newText, projectId: stack.pid)
        try #require(parsed.count == 5)
        try #require(parsed[0].blockType == .paragraph && parsed[0].markdownFragment == "---\ntitle: Draft\nauthor: Me\n---")
        try #require(parsed[3].blockType == .horizontalRule && parsed[3].markdownFragment == "---")

        // (2) The shape of the batch.
        let diff = MarkdownBlockDiff.diff(rows: before, new: parsed)
        let counts = "\(diff.changes.updates.count) updates, \(diff.changes.inserts.count) inserts, \(diff.changes.deletes.count) deletes"
        #expect(
            diff.changes.updates.count == 1 && diff.changes.inserts.count == 1 && diff.changes.deletes.count == 1,
            "expected 1 update (front matter), 1 insert (rule), 1 delete (Middle.); got \(counts)")

        // (3) The batch applies, whole.
        let reservation = stack.sync.reserveMarkdownTurn(database: stack.db, projectId: stack.pid)
        guard case .reserved(let turn) = reservation else {
            Issue.record("expected a reserved turn, got \(reservation)")
            return
        }
        let outcome = await stack.sync.applyMarkdownTurn(turn, diff.changes)
        guard case .applied = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(outcome.isClean)

        // (4) Reopened, the text is the text that was typed.
        let after = try rows(stack.db)
        let reopened = BlockParser.assembleMarkdown(from: after)
        #expect(reopened == newText, "reopened text differs: \(reopened.debugDescription) vs \(newText.debugDescription)")

        // (5) Each stored row has the type and text a fresh parse of the typed text gives.
        let stored = after.map(RowShape.init)
        let expected = parsed.map(RowShape.init)
        #expect(stored == expected, "front matter row / rule row type or text changed: stored \(stored) vs expected \(expected)")

        // (5b) The update kept the Preamble row: the front-matter row is the same row, with the same id.
        #expect(after.first?.id == before.first?.id, "the front-matter update did not keep the Preamble row's id")

        // (6) The front-matter row has the words a fresh parse gives it (a rule stores no text).
        let frontMatterRow = try #require(after.first)
        let storedText = frontMatterRow.textContent.debugDescription
        let expectedText = parsed[0].textContent.debugDescription
        #expect(
            frontMatterRow.textContent == parsed[0].textContent,
            "front matter row text content differs: stored \(storedText) (\(frontMatterRow.blockType.rawValue)) vs expected \(expectedText)")
    }
}
