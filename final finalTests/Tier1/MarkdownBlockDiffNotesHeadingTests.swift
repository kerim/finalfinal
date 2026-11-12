//
//  MarkdownBlockDiffNotesHeadingTests.swift
//  final finalTests
//
//  t-e3c7105f: a stored Notes HEADING row follows its heading, in `MarkdownBlockDiff`.
//
//  The bug (found by the real-app test `FootnoteCursorPlacementE2ETests/testH1ToH2Flip...`, its app log read 2026-11-12):
//  in Markdown mode, in a book with a Notes section, select all, delete, and type a replacement document. The first save (editor
//  empty) deletes every row the writer may delete and leaves the Notes heading and its definition. The next save compared
//  "# Chapter One" and a paragraph with a baseline of just those two Notes rows, and the pairing by block type alone gave the Notes
//  heading row to "# Chapter One". The update was accepted (a heading has no footnote label to differ) and the row kept its Notes
//  flag, so the document's first heading was flagged as a Notes heading beside the real "## Notes" heading.
//
//  Vocabulary as in `MarkdownBlockDiffTests`: the stored rows are a parse of the OLD text with ids r1, r2, ... in document order.
//

import Foundation
import Testing
@testable import final_final

@Suite("MarkdownBlockDiff Notes heading — Tier 1 (t-e3c7105f)", .serialized, .timeLimit(.minutes(2)))
struct MarkdownBlockDiffNotesHeadingTests {

    // MARK: - Helpers

    private static let pid = "p-md-diff-notes-heading"

    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: Self.pid, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    /// The stored rows of `markdown`: its parse, with ids `r1`, `r2`, ... in document order and `sortOrder` 1, 2, ...
    private func storedRows(_ markdown: String) -> [Block] {
        var blocks = parse(markdown)
        for index in blocks.indices {
            blocks[index].id = "r\(index + 1)"
            blocks[index].sortOrder = Double(index + 1)
        }
        return blocks
    }

    private final class TempIds {
        var next = 0
        func make() -> String {
            next += 1
            return "temp-md-\(next)"
        }
    }

    private func diff(rows: [Block], new: String) -> MarkdownBlockDiff.Result {
        let ids = TempIds()
        return MarkdownBlockDiff.diff(rows: rows, new: parse(new), makeTempId: { ids.make() })
    }

    private func updates(_ changes: BlockChanges) -> [String] {
        changes.updates.map { "\($0.id)|\($0.markdownFragment ?? "nil")|\($0.headingLevel.map(String.init) ?? "-")" }
    }

    private func insertedFragments(_ changes: BlockChanges) -> [String] { changes.inserts.map(\.markdownFragment) }

    /// How many stored heading rows carry the Notes flag.
    private func notesHeadingCount(_ rows: [Block]) -> Int { rows.filter { $0.blockType == .heading && $0.isNotes }.count }

    private let bodyLine = "Body paragraph with a reference[^1] here."
    private let definition = "[^1]: Original definition text."

    private var book: String { "# Chapter One\n\n\(bodyLine)\n\n# Notes\n\n\(definition)" }

    /// The rows the writer leaves after the first save of a select-all-and-delete: the Notes heading and its definition. (The
    /// writer deletes the rows it may delete; a Notes row is never deleted by it.)
    private func rowsAfterSelectAllDelete() -> [Block] {
        let rows = storedRows(book)
        return rows.filter { $0.isNotes }
    }

    // MARK: - The bug

    @Test("premise: the book's rows carry the Notes flag on the Notes heading and its definition only")
    func bookFlags() throws {
        let rows = storedRows(book)
        try #require(rows.count == 4)
        #expect(rows.map(\.isNotes) == [false, false, true, true])
        #expect(rows.map(\.blockType) == [.heading, .paragraph, .heading, .paragraph])
    }

    @Test("a first typed heading never takes the stored Notes heading row (the row keeps the Notes section; the heading is an insert)")
    func firstTypedHeadingDoesNotTakeTheNotesHeadingRow() throws {
        let rows = rowsAfterSelectAllDelete()
        try #require(rows.map(\.id) == ["r3", "r4"])
        let result = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine.prefix(20))")
        #expect(!result.changes.updates.contains { $0.id == "r3" }, "the Notes heading row must not be updated with another heading's text")
        #expect(insertedFragments(result.changes).contains("# Chapter One"))
        #expect(result.filtered.notesDeletes >= 1, "the Notes heading row is left alone as a refused delete")
        #expect(result.baselineAfterWriteMustBeRows)
    }

    @Test("a replacement document with the Notes heading flipped to H2: the Notes row follows the new Notes heading, the first heading is an insert")
    func typedOverDocumentGivesTheNotesRowToTheNotesHeading() throws {
        let rows = rowsAfterSelectAllDelete()
        let result = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine)\n\n## Notes\n\n\(definition)")
        #expect(updates(result.changes) == ["r3|## Notes|2"], "r3 takes the \"## Notes\" heading (level 2) and nothing else")
        #expect(insertedFragments(result.changes) == ["# Chapter One", bodyLine])
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.total == 0, "the definition row is unchanged, so nothing was refused")
    }

    @Test("the whole sequence, written twice like the saver: one Notes heading, and the first heading is not it")
    func selectAllDeleteThenTypeEndsWithOneNotesHeading() throws {
        var rows = storedRows(book)
        // Save 1: the editor is empty.
        let first = diff(rows: rows, new: "")
        rows = MarkdownDiffWriteSimulator.rowsAfter(first.changes, rows: rows)
        try #require(rows.map(\.id) == ["r3", "r4"], "only the Notes rows survive the empty save")
        // Save 2: the first lines of the new document.
        let second = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine.prefix(20))")
        rows = MarkdownDiffWriteSimulator.rowsAfter(second.changes, rows: rows)
        let firstHeading = try #require(rows.sorted { $0.sortOrder < $1.sortOrder }.first { $0.blockType == .heading })
        #expect(firstHeading.markdownFragment == "# Chapter One")
        #expect(!firstHeading.isNotes, "the document's first heading must not carry the Notes flag")
        // Save 3: the whole document.
        let third = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine)\n\n## Notes\n\n\(definition)")
        rows = MarkdownDiffWriteSimulator.rowsAfter(third.changes, rows: rows)
        let notesHeadings = rows.filter { $0.blockType == .heading && $0.isNotes }
        #expect(notesHeadings.count == 1)
        #expect(notesHeadings.first?.markdownFragment == "## Notes")
    }

    // MARK: - The heading still follows its own section

    @Test("H1 to H2 flip of the Notes heading with its definition under it: the same row, now level 2")
    func flipKeepsTheRow() {
        let rows = storedRows(book)
        let result = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine)\n\n## Notes\n\n\(definition)")
        #expect(updates(result.changes) == ["r3|## Notes|2"])
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("a renamed Notes heading with its definitions under it keeps its row (a custom Notes title)")
    func renamedNotesHeadingKeepsItsRow() {
        let rows = storedRows(book)
        let result = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine)\n\n# Endnotes\n\n\(definition)")
        #expect(updates(result.changes) == ["r3|# Endnotes|1"])
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("the Notes heading retitled while no definition is under it yet still pairs by its own title")
    func notesTitleWithoutDefinitionYetKeepsItsRow() throws {
        // The editor shows the Notes heading with its definitions cut away (the writer never deletes those rows, so they stay).
        let rows = rowsAfterSelectAllDelete()
        let result = diff(rows: rows, new: "# Chapter One\n\n\(bodyLine)\n\n## Notes")
        #expect(result.changes.updates.contains { $0.id == "r3" && $0.markdownFragment == "## Notes" })
        #expect(!result.changes.updates.contains { $0.id == "r3" && $0.markdownFragment == "# Chapter One" })
    }

    @Test("a half-typed ordinary heading ahead of the Notes row cannot take the heading the Notes row is waiting for")
    func halfTypedHeadingDoesNotTakeTheNotesHeading() throws {
        // Stored: Chapter One, body, a half-typed "## No", then the Notes section.
        let stored = storedRows("# Chapter One\n\n\(bodyLine)\n\n## No\n\n# Notes\n\n\(definition)")
        try #require(stored.map(\.id) == ["r1", "r2", "r3", "r4", "r5"])
        try #require(stored.map(\.isNotes) == [false, false, false, true, true])
        let result = diff(rows: stored, new: "# Chapter One\n\n\(bodyLine)\n\n## Notes\n\n\(definition)")
        #expect(updates(result.changes) == ["r4|## Notes|2"], "the Notes heading row takes the Notes heading")
        #expect(result.changes.deletes == ["r3"], "the half-typed heading row goes")
        #expect(result.changes.inserts.isEmpty)
    }

    @Test("a Notes heading row with no heading of its own in the new text stays, and every new block is an insert")
    func unclaimedNotesHeadingRowStays() {
        let rows = rowsAfterSelectAllDelete()
        let result = diff(rows: rows, new: "# Chapter One")
        #expect(result.changes.updates.isEmpty)
        #expect(insertedFragments(result.changes) == ["# Chapter One"])
        #expect(result.changes.inserts.first?.atDocumentStart == true)
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("without a Notes heading row the pairing is the one it always was")
    func ordinaryRowsPairAsBefore() {
        let rows = storedRows("# Chapter One\n\n\(bodyLine)")
        let result = diff(rows: rows, new: "# Chapter Uno\n\n\(bodyLine)")
        #expect(updates(result.changes) == ["r1|# Chapter Uno|1"])
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
    }
}
