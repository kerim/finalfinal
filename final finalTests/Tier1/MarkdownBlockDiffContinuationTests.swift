//
//  MarkdownBlockDiffContinuationTests.swift
//  final finalTests
//
//  t-4a8fd8af (follow-up F1): moved Notes definitions WITH continuation paragraphs, for `MarkdownBlockDiff`.
//
//  A footnote with more than one paragraph is stored as one row per paragraph: the `[^N]:` definition, then each
//  further paragraph as its own label-less Notes row, unindented (`MultiParagraphFootnoteExportTests`; the export
//  indents them). The editor's text is those rows joined by blank lines, so a continuation is its own block with no
//  footnote label. After a renumber that swaps runs of numbers the editor lists the footnotes out of number order
//  while the rows are in order (see the (y) cases in `MarkdownBlockDiffTests`), so a moved footnote's continuation
//  is a removed row in one region and an inserted block in another. A continuation has no label to pair by, so it is
//  paired by (owner label, ordinal under that owner). Without that, each continuation was saved again on every fire,
//  and where a removed continuation and an inserted one of ANOTHER footnote met in one region the same-type pairing
//  wrote footnote 4's second paragraph into footnote 2's row.
//
//  Documents: "# Intro", "Body paragraph.", "# Notes", then the notes. Rows r1, r2, r3, then r4... in the OLD text order.
//

import Foundation
import Testing
@testable import final_final

/// What the writer does with a diff, so a test can fire twice: the updates, inserts and deletes applied to the rows.
/// An insert lands between its anchor and the next row (like the database's own placement) and is a Notes row when
/// it follows a Notes row or has the shape of a definition.
enum MarkdownDiffWriteSimulator {
    static func rowsAfter(_ changes: BlockChanges, rows: [Block]) -> [Block] {
        var next = rows
        for update in changes.updates {
            guard let index = next.firstIndex(where: { $0.id == update.id }) else { continue }
            if let fragment = update.markdownFragment { next[index].markdownFragment = fragment }
            if let text = update.textContent { next[index].textContent = text }
        }
        for insert in changes.inserts {
            let sorted = next.sorted { $0.sortOrder < $1.sortOrder }
            let anchor = sorted.first { $0.id == insert.afterBlockId }
            let sortOrder = anchor.map { anchorRow -> Double in
                let following = sorted.first { $0.sortOrder > anchorRow.sortOrder }?.sortOrder ?? anchorRow.sortOrder + 1
                return (anchorRow.sortOrder + following) / 2
            } ?? (sorted.first?.sortOrder ?? 1) - 1
            var row = Block(
                id: insert.tempId, projectId: "p-md-diff-sim", sortOrder: sortOrder,
                blockType: BlockType(rawValue: insert.blockType) ?? .paragraph, textContent: insert.textContent,
                markdownFragment: insert.markdownFragment, headingLevel: insert.headingLevel)
            row.isNotes = (anchor?.isNotes == true && anchor?.blockType != .heading) || insert.markdownFragment.hasPrefix("[^")
            next.append(row)
        }
        next.removeAll { changes.deletes.contains($0.id) }
        return next
    }
}

@Suite("MarkdownBlockDiff continuation paragraphs — Tier 1 (t-4a8fd8af F1)", .serialized, .timeLimit(.minutes(2)))
struct MarkdownBlockDiffContinuationTests {

    // MARK: - Helpers

    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: "p-md-diff-cont", bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    private func storedRows(_ markdown: String) -> [Block] {
        var blocks = parse(markdown)
        for index in blocks.indices { blocks[index].id = "r\(index + 1)" }
        return blocks
    }

    private final class TempIds {
        var next = 0
        func make() -> String {
            next += 1
            return "temp-md-\(next)"
        }
    }

    private func diff(_ old: String, _ new: String) -> MarkdownBlockDiff.Result {
        let ids = TempIds()
        return MarkdownBlockDiff.diff(rows: storedRows(old), new: parse(new), makeTempId: { ids.make() })
    }

    private func inserts(_ changes: BlockChanges) -> [String] {
        changes.inserts.map { "\($0.tempId)|after:\($0.afterBlockId ?? ($0.atDocumentStart == true ? "START" : "NIL"))|\($0.markdownFragment)" }
    }

    /// Note `number`: its definition, then its continuation paragraphs (by default one, "Second paragraph of note N.").
    private func note(_ number: Int, _ continuations: [String]? = nil) -> [String] {
        ["[^\(number)]: Body of note \(number)."] + (continuations ?? ["Second paragraph of note \(number)."])
    }

    private func notesDoc(_ order: [Int], extra: (Int) -> [String]? = { _ in nil }) -> String {
        (["# Intro", "Body paragraph.", "# Notes"] + order.flatMap { note($0, extra($0)) }).joined(separator: "\n\n")
    }

    // MARK: - The pairing

    @Test("(F1) premise: each continuation paragraph is its own block, flagged Notes, with no footnote label")
    func continuationIsItsOwnBlock() {
        let blocks = parse(notesDoc([1, 2, 3, 4]))
        #expect(blocks.count == 3 + 8)
        #expect(blocks.suffix(8).allSatisfy { $0.isNotes })
        let labels = blocks.suffix(8).map { MarkdownBlockDiff.notesLabel(of: $0.markdownFragment) }
        #expect(labels == ["1", nil, "2", nil, "3", nil, "4", nil])
    }

    @Test("(F1) two neighbouring swaps of notes that each have a second paragraph: nothing is inserted, updated or deleted")
    func neighbouringSwapsWithContinuationsArePaired() {
        let result = diff(notesDoc([1, 2, 3, 4]), notesDoc([2, 1, 4, 3]))
        #expect(result.changes.inserts.isEmpty, "a moved second paragraph must not be saved a second time")
        #expect(result.changes.updates.isEmpty, "no footnote's second paragraph may be written into another footnote's row")
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.notesMoves > 0)
        #expect(result.filtered.notesLabelChanges == 0)
        #expect(result.filtered.notesDeletes == 0)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    @Test("(F1) the real shape with second paragraphs: 54 notes, two runs of nine swapped (37..45 and 46..54)")
    func swappedRunsOfNineWithContinuationsArePaired() {
        let result = diff(notesDoc(Array(1...54)), notesDoc(Array(1...36) + Array(46...54) + Array(37...45)))
        #expect(result.changes.inserts.isEmpty, "a moved second paragraph must not be saved a second time")
        #expect(result.changes.updates.isEmpty)
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.notesMoves > 0)
        #expect(result.filtered.notesDeletes == 0)
        #expect(result.baselineAfterWriteMustBeRows)
    }

    @Test("(F1) an edit inside the second paragraph of a moved note is exactly one update, on that paragraph's own row")
    func editedContinuationOfMovedNoteIsOneUpdate() {
        let edited = "Second paragraph of note 2, edited."
        let result = diff(notesDoc([1, 2, 3, 4]), notesDoc([2, 1, 4, 3], extra: { $0 == 2 ? [edited] : nil }))
        // r1 # Intro, r2 body, r3 # Notes, then [^1] r4, its paragraph r5, [^2] r6, its paragraph r7.
        #expect(result.changes.updates.map(\.id) == ["r7"])
        #expect(result.changes.updates.map(\.markdownFragment) == [edited])
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.notesMoves > 0)
    }

    @Test("(F1) a moved note fired twice against the rows its first write left: the edited second paragraph is sent once, nothing grows")
    func movedNoteWithEditedContinuationIsIdempotent() {
        let new = notesDoc([2, 1, 4, 3], extra: { $0 == 2 ? ["Second paragraph of note 2, edited."] : nil })
        var rows = storedRows(notesDoc([1, 2, 3, 4]))
        let rowCount = rows.count
        for fire in 1...2 {
            let ids = TempIds()
            let result = MarkdownBlockDiff.diff(rows: rows, new: parse(new), makeTempId: { ids.make() })
            #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty, "fire \(fire): the rows must not grow")
            #expect(result.changes.updates.count == (fire == 1 ? 1 : 0), "fire \(fire): the edit is sent once")
            rows = MarkdownDiffWriteSimulator.rowsAfter(result.changes, rows: rows)
            #expect(rows.count == rowCount, "fire \(fire)")
        }
    }

    @Test("(F1) a swap next to a NEW note that has a second paragraph: both paragraphs of the new note are sent, chained, and no copy is saved")
    func swapNextToNewNoteWithContinuation() {
        // Notes 1..5; the editor lists 1, 2, 3, the new note 9, then 5 and 4 swapped. Rows: [^3] r8, its paragraph r9.
        let new = (["# Intro", "Body paragraph.", "# Notes"] + [1, 2, 3, 9, 5, 4].flatMap { note($0) }).joined(separator: "\n\n")
        let result = diff(notesDoc([1, 2, 3, 4, 5]), new)
        #expect(inserts(result.changes) == [
            "temp-md-1|after:r9|[^9]: Body of note 9.",
            "temp-md-2|after:temp-md-1|Second paragraph of note 9."
        ])
        #expect(result.changes.updates.isEmpty, "no footnote's second paragraph may be written into another footnote's row")
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.notesMoves > 0)
        #expect(result.filtered.notesLabelChanges == 0)
        #expect(result.filtered.notesDeletes == 0)
    }

    // MARK: - Guards: N3 still holds for a paragraph that has no row to take

    @Test("(F1) N3: a hand-typed extra paragraph under an unmoved note is one insert, after that note's last paragraph")
    func extraContinuationUnderUnmovedNoteIsOneInsert() {
        let result = diff(notesDoc([1, 2, 3]), notesDoc([1, 2, 3], extra: {
            $0 == 2 ? ["Second paragraph of note 2.", "Hand-typed extra paragraph."] : nil
        }))
        // [^2] is r6 and its paragraph r7.
        #expect(inserts(result.changes) == ["temp-md-1|after:r7|Hand-typed extra paragraph."])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
        #expect(result.filtered.total == 0)
        #expect(!result.baselineAfterWriteMustBeRows)
    }

    @Test("(F1) N3: a hand-typed extra paragraph under a MOVED note is one insert, and the moved paragraphs are still moves")
    func extraContinuationUnderMovedNoteIsOneInsert() {
        let result = diff(notesDoc([1, 2, 3, 4]), notesDoc([2, 1, 4, 3], extra: {
            $0 == 1 ? ["Second paragraph of note 1.", "Hand-typed extra paragraph."] : nil
        }))
        // [^1] is r4 and its paragraph r5: the extra paragraph is the second paragraph of note 1, and no row holds that.
        #expect(inserts(result.changes) == ["temp-md-1|after:r5|Hand-typed extra paragraph."])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
        #expect(result.filtered.notesMoves > 0)
        #expect(result.filtered.notesLabelChanges == 0)
    }
}
