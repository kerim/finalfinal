//
//  MarkdownLegacyLooseListEditTests.swift
//  final finalTests
//
//  t-4eb7bfa9, review finding F11. An earlier version cut a loose list at every blank line, so a document saved by it holds ONE list
//  as several rows (`- a`, `- b`, `- c` as three rows). The parser now keeps a loose list in one row. When such a document is edited
//  in Markdown mode, the per-block writer (`MarkdownBlockDiff`, saved through `applyBlockChangesFromEditor`) compares the three stored
//  rows with the ONE block the new text parses to: the table must end up with exactly the rows the new text has, with nothing lost
//  (no item vanishes) and nothing duplicated (no item twice).
//
//  Pattern: the pure diff of `MarkdownBlockDiffTests` (stored rows keep their ids, the new blocks are a parse of the new text), then
//  the changes applied to a real table the way the Markdown writer applies them, then the table read back.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown mode: a legacy loose list stored as per-item rows collapses to one row (t-4eb7bfa9, F11)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct MarkdownLegacyLooseListEditTests {

    private func parse(_ markdown: String, projectId: String) -> [Block] {
        BlockParser.parse(
            markdown: markdown, projectId: projectId, bibliographyHeaderName: "Bibliography", graceNames: [], notesHeaderName: "Notes")
    }

    /// The rows an earlier parser wrote for `pieces` (each blank-line-separated piece its own row), with ids `legacy-1`, `legacy-2`, ...
    private func legacyRows(_ pieces: [String], projectId: String) -> [Block] {
        var rows: [Block] = []
        for piece in pieces {
            guard var row = parse(piece, projectId: projectId).first else { continue }
            row.id = "legacy-\(rows.count + 1)"
            row.sortOrder = Double(rows.count + 1)
            rows.append(row)
        }
        return rows
    }

    @Test("three per-item list rows, edited elsewhere in Markdown mode, become one list row: no item lost, none twice")
    func perItemRowsCollapseToOneRow() throws {
        // The database, as the earlier version left it: a heading, one list as THREE rows, a paragraph.
        let db = try TestFixtureFactory.createTemporary(content: "# Placeholder")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let stored = legacyRows(["# Title", "- a", "- b", "- c", "After"], projectId: pid)
        #expect(
            stored.map(\.blockType) == [.heading, .bulletList, .bulletList, .bulletList, .paragraph],
            "precondition: \(stored.map(\.blockType))")
        try db.deleteAllBlocks(projectId: pid)
        for row in stored { try db.insertBlock(row) }

        // The user switched to Markdown, typed at the end of the last paragraph. Markdown shows the rows joined by blank lines (the
        // list loose); the new text parses to ONE list block.
        let newText = "# Title\n\n- a\n\n- b\n\n- c\n\nAfter more"
        let newBlocks = parse(newText, projectId: pid)
        #expect(newBlocks.map(\.blockType) == [.heading, .bulletList, .paragraph], "the new text's rows: \(newBlocks.map(\.blockType))")
        #expect(newBlocks[1].markdownFragment == "- a\n\n- b\n\n- c")

        let result = MarkdownBlockDiff.diff(rows: stored, new: newBlocks, makeTempId: { "temp-md-1" })
        #expect(!result.changes.isEmpty, "the table differs from the text: it must be written")
        #expect(result.unaddressable == 0 && result.filtered.total == 0, "nothing may be filtered or unaddressable: \(result)")
        _ = try db.applyBlockChangesFromEditor(result.changes, for: pid)

        let after = BlockParser.assemblySorted(try TestFixtureFactory.fetchBlocks(from: db))
        let described = after.map { "\($0.id.prefix(8)) \($0.blockType.rawValue):\($0.markdownFragment.debugDescription)" }
        #expect(
            after.map { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) } == newBlocks.map(\.markdownFragment),
            "the table must hold exactly the rows of the new text: \(described)")
        #expect(after.map(\.blockType) == [.heading, .bulletList, .paragraph], "types: \(described)")
        // Nothing lost, nothing twice: each item's text is in exactly one row.
        let listRows = after.filter { $0.blockType == .bulletList }
        #expect(listRows.count == 1, "the three per-item rows must be one: \(described)")
        for item in ["a", "b", "c"] {
            let holders = after.filter { $0.markdownFragment.range(of: "- \(item)\\b", options: .regularExpression) != nil }
            #expect(holders.count == 1, "item \(item) must be in exactly one row, was in \(holders.count): \(described)")
        }
        // The rows the edit did not touch keep their ids; no temporary id was left behind.
        #expect(after.first?.id == "legacy-1", "the heading keeps its id: \(described)")
        #expect(after.last?.id == "legacy-5", "the edited paragraph keeps its id: \(described)")
        #expect(!after.contains { $0.id.hasPrefix("temp-") }, "a temporary id was written: \(described)")
        #expect(after.last?.markdownFragment == "After more")
        // The stored text of the list row is what a close derives from its fragment.
        #expect(listRows.first?.textContent == BlockParser.extractTextContent(from: "- a\n\n- b\n\n- c", blockType: .bulletList))
    }
}
