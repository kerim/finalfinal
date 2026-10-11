//
//  MarkdownBlockDiffTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U1 (a)-(u) (+ (v), (w), (x) added by the coder): the PURE half of
//  saving Markdown typing block by block (`MarkdownBlockDiff`, plus `BlockParser.endsInsideOpenFenceOrMath`). No
//  database, no writer, no editor. Each case asserts the exact `BlockChanges`.
//
//  Vocabulary: the "stored rows" are a parse of the OLD text with ids `r1`, `r2`, ... in document order; the new
//  blocks are a parse of the NEW text; temp ids come from a counter (`temp-md-1`, `temp-md-2`, ...) so the exact
//  `BlockChanges` can be compared.
//

import Foundation
import Testing
@testable import final_final

@Suite("MarkdownBlockDiff — Tier 1 (t-94369a83 Phase 4a)", .serialized, .timeLimit(.minutes(2)))
struct MarkdownBlockDiffTests {

    // MARK: - Helpers

    private static let pid = "p-md-diff"

    /// A real parse, isolated from the process-wide `ExportSettings` (both bibliography names given explicitly).
    private func parse(_ markdown: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: Self.pid, bibliographyHeaderName: "Bibliography", graceNames: [])
    }

    /// The stored rows of `markdown`: its parse, with ids `r1`, `r2`, ... in document order.
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

    /// Rows mode: the diff of the `new` text against the stored rows of the `old` text.
    private func diff(_ old: String, _ new: String) -> MarkdownBlockDiff.Result {
        let ids = TempIds()
        return MarkdownBlockDiff.diff(rows: storedRows(old), new: parse(new), makeTempId: { ids.make() })
    }

    private func blocks(_ fragments: [String]) -> String { fragments.joined(separator: "\n\n") }

    private func updates(_ changes: BlockChanges) -> [String] {
        changes.updates.map { "\($0.id)|\($0.markdownFragment ?? "nil")|\($0.headingLevel.map(String.init) ?? "-")|\($0.blockType ?? "nil")" }
    }

    private func inserts(_ changes: BlockChanges) -> [String] {
        changes.inserts.map { insert in
            let anchor = insert.afterBlockId ?? (insert.atDocumentStart == true ? "START" : "NIL")
            return "\(insert.tempId)|after:\(anchor)|\(insert.markdownFragment)"
        }
    }

    /// No insert may be sent without an anchor or the document-start flag: it would land at the END of the document.
    private func expectEveryInsertAnchored(_ changes: BlockChanges, sourceLocation: SourceLocation = #_sourceLocation) {
        for insert in changes.inserts {
            #expect(insert.afterBlockId != nil || insert.atDocumentStart == true,
                    "insert \(insert.tempId) has neither an anchor nor atDocumentStart", sourceLocation: sourceLocation)
        }
    }

    private let intro = "# Title"
    private let one = "First paragraph here."
    private let two = "Second paragraph here."
    private let three = "Third paragraph here."

    private var base: String { blocks([intro, one, two, three]) }

    // MARK: - (a) edit inside a paragraph

    @Test("(a) an edit inside a paragraph is one update with the same id")
    func editInsideParagraph() {
        let result = diff(base, blocks([intro, one, "Second paragraph CHANGED.", three]))
        #expect(updates(result.changes) == ["r3|Second paragraph CHANGED.|-|paragraph"])
        #expect(result.changes.updates.first?.textContent == "Second paragraph CHANGED.")
        #expect(result.changes.inserts.isEmpty)
        #expect(result.changes.deletes.isEmpty)
        #expect(result.filtered.total == 0)
        #expect(!result.baselineAfterWriteMustBeRows)
    }

    // MARK: - (b) inserts at the start, in the middle and at the end

    @Test("(b) an insert at the start is anchored atDocumentStart, never with a nil anchor")
    func insertAtStart() {
        let result = diff(base, blocks(["Brand new opening.", intro, one, two, three]))
        #expect(inserts(result.changes) == ["temp-md-1|after:START|Brand new opening."])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
        expectEveryInsertAnchored(result.changes)
    }

    @Test("(b) an insert in the middle is anchored after the block before it")
    func insertInMiddle() {
        let result = diff(base, blocks([intro, one, "Inserted in the middle.", two, three]))
        #expect(inserts(result.changes) == ["temp-md-1|after:r2|Inserted in the middle."])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
    }

    @Test("(b) an insert at the end is anchored after the last block")
    func insertAtEnd() {
        let result = diff(base, blocks([intro, one, two, three, "Inserted at the end."]))
        #expect(inserts(result.changes) == ["temp-md-1|after:r4|Inserted at the end."])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
    }

    // MARK: - (c) deletes

    @Test("(c) deleting one block is one delete")
    func deleteOne() {
        let result = diff(base, blocks([intro, one, three]))
        #expect(result.changes.deletes == ["r3"])
        #expect(result.changes.updates.isEmpty && result.changes.inserts.isEmpty)
    }

    @Test("(c) deleting three adjacent blocks is three deletes, in order")
    func deleteThreeAdjacent() {
        let result = diff(base, intro)
        #expect(result.changes.deletes == ["r2", "r3", "r4"])
        #expect(result.changes.updates.isEmpty && result.changes.inserts.isEmpty)
    }

    // MARK: - (d) split, (e) merge, (f) move

    @Test("(d) a split keeps the id on the first half and inserts the second half after it")
    func split() {
        let old = blocks([intro, "Alpha sentence. Beta sentence.", three])
        let result = diff(old, blocks([intro, "Alpha sentence.", "Beta sentence.", three]))
        #expect(updates(result.changes) == ["r2|Alpha sentence.|-|paragraph"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r2|Beta sentence."])
        #expect(result.changes.deletes.isEmpty)
    }

    @Test("(e) a merge keeps the first block's id and deletes the second")
    func merge() {
        let old = blocks([intro, "Alpha sentence.", "Beta sentence.", three])
        let result = diff(old, blocks([intro, "Alpha sentence. Beta sentence.", three]))
        #expect(updates(result.changes) == ["r2|Alpha sentence. Beta sentence.|-|paragraph"])
        #expect(result.changes.deletes == ["r3"])
        #expect(result.changes.inserts.isEmpty)
    }

    @Test("(f) a moved block is a delete plus an insert with a new id")
    func move() {
        let old = blocks([intro, "Block A.", "Block B.", "Block C."])
        let result = diff(old, blocks([intro, "Block B.", "Block C.", "Block A."]))
        #expect(result.changes.deletes == ["r2"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r4|Block A."])
        #expect(result.changes.updates.isEmpty)
    }

    // MARK: - (g) headings

    @Test("(g) renaming a heading is an update that keeps the id and carries the new level and text")
    func headingRename() {
        let old = blocks(["# Title", "## Old section title", one])
        let result = diff(old, blocks(["# Title", "## New section title", one]))
        #expect(updates(result.changes) == ["r2|## New section title|2|heading"])
        #expect(result.changes.updates.first?.textContent == "New section title")
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    @Test("(g) changing a heading's level is an update that keeps the id")
    func headingLevelChange() {
        let old = blocks(["# Title", "## A section", one])
        let result = diff(old, blocks(["# Title", "### A section", one]))
        #expect(updates(result.changes) == ["r2|### A section|3|heading"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    // MARK: - (h) a type change is a delete plus an insert

    @Test("(h) paragraph to heading is a delete plus an insert")
    func paragraphToHeading() {
        let result = diff(blocks([intro, "Some text.", three]), blocks([intro, "# Some text.", three]))
        #expect(result.changes.deletes == ["r2"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r1|# Some text."])
        #expect(result.changes.updates.isEmpty)
    }

    @Test("(h) heading to paragraph is a delete plus an insert")
    func headingToParagraph() {
        let result = diff(blocks([intro, "## Some text.", three]), blocks([intro, "Some text.", three]))
        #expect(result.changes.deletes == ["r2"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r1|Some text."])
        #expect(result.changes.updates.isEmpty)
    }

    @Test("(h) paragraph to image is a delete plus an insert")
    func paragraphToImage() throws {
        let newText = blocks([intro, "![alt text](media/picture.png)", three])
        try #require(parse(newText)[1].blockType == .image, "premise: the image line parses as an image block")
        let result = diff(blocks([intro, "Some text.", three]), newText)
        #expect(result.changes.deletes == ["r2"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r1|![alt text](media/picture.png)"])
        #expect(result.changes.updates.isEmpty)
    }

    @Test("(h) paragraph to one-line display math is a delete plus an insert")
    func paragraphToOneLineMath() throws {
        let newText = blocks([intro, "$$x^2 + y^2$$", three])
        try #require(parse(newText)[1].blockType == .mathDisplay, "premise: a one-line $$...$$ parses as display math")
        let result = diff(blocks([intro, "Some text.", three]), newText)
        #expect(result.changes.deletes == ["r2"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r1|$$x^2 + y^2$$"])
        #expect(result.changes.updates.isEmpty)
    }

    // MARK: - (i) lists, (j) code fence, (l) table, (m) footnote definition

    @Test("(i) editing a list item, and adding one, are updates of the one list block")
    func listEditAndAdd() throws {
        let old = blocks([intro, "- one\n- two", three])
        try #require(parse(old).count == 3, "premise: a two-item list is one block")
        let edited = diff(old, blocks([intro, "- one\n- TWO", three]))
        #expect(updates(edited.changes) == ["r2|- one\n- TWO|-|bullet_list"])
        #expect(edited.changes.inserts.isEmpty && edited.changes.deletes.isEmpty)
        let added = diff(old, blocks([intro, "- one\n- two\n- three", three]))
        #expect(updates(added.changes) == ["r2|- one\n- two\n- three|-|bullet_list"])
        #expect(added.changes.inserts.isEmpty && added.changes.deletes.isEmpty)
    }

    @Test("(j) a code fence with blank lines inside is one block: an edit inside it is one update")
    func codeFenceWithInnerBlankLines() throws {
        let old = blocks([intro, "```\nline one\n\nline two\n```", three])
        try #require(parse(old).count == 3, "premise: the fence is one block despite the blank line")
        let result = diff(old, blocks([intro, "```\nline one\n\nline TWO\n```", three]))
        #expect(updates(result.changes) == ["r2|```\nline one\n\nline TWO\n```|-|code_block"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    @Test("(k) three chained inserts after one block anchor on each other's temp ids")
    func threeChainedInserts() {
        let result = diff(base, blocks([intro, one, two, "New one.", "New two.", "New three.", three]))
        #expect(inserts(result.changes) == [
            "temp-md-1|after:r3|New one.",
            "temp-md-2|after:temp-md-1|New two.",
            "temp-md-3|after:temp-md-2|New three."
        ])
        #expect(result.changes.updates.isEmpty && result.changes.deletes.isEmpty)
        expectEveryInsertAnchored(result.changes)
    }

    @Test("(l) editing a table cell is one update of the one table block")
    func tableCell() throws {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let old = blocks([intro, table, three])
        try #require(parse(old).count == 3, "premise: the table is one block")
        try #require(parse(old)[1].blockType == .table)
        let result = diff(old, blocks([intro, "| a | b |\n| --- | --- |\n| 1 | 22 |", three]))
        #expect(updates(result.changes) == ["r2|| a | b |\n| --- | --- |\n| 1 | 22 ||-|table"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    @Test("(m) a multi-paragraph footnote definition is one block: editing its second paragraph is one update")
    func multiParagraphFootnoteDefinition() throws {
        let definition = "[^1]: First paragraph of the note.\n\n    Second paragraph of the note."
        let old = blocks([intro, "Body text.[^1]", definition, three])
        try #require(parse(old).count == 4, "premise: the definition and its continuation are one block")
        let edited = "[^1]: First paragraph of the note.\n\n    Second paragraph of the note, edited."
        let result = diff(old, blocks([intro, "Body text.[^1]", edited, three]))
        #expect(updates(result.changes) == ["r3|\(edited)|-|paragraph"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    // MARK: - (n) citation, (o) Chinese

    @Test("(n) a citation group with a locator survives an edit byte for byte")
    func citation() {
        let old = blocks([intro, "See [@smith2020; @jones2021, 12] for details.", three])
        let result = diff(old, blocks([intro, "See [@smith2020; @jones2021, 14] for details.", three]))
        #expect(updates(result.changes) == ["r2|See [@smith2020; @jones2021, 14] for details.|-|paragraph"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    @Test("(o) Chinese text without spaces is one update")
    func chineseText() {
        let old = blocks(["# 标题", "这是一个没有空格的段落。", "结尾。"])
        let result = diff(old, blocks(["# 标题", "这是一个没有空格的段落，已经修改。", "结尾。"]))
        #expect(updates(result.changes) == ["r2|这是一个没有空格的段落，已经修改。|-|paragraph"])
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
    }

    // MARK: - (p) anchors never nil

    private func entry(_ id: String?, _ fragment: String) -> MarkdownBlockDiff.Entry {
        MarkdownBlockDiff.Entry(
            id: id, key: MarkdownBlockDiff.Key(blockType: .paragraph, headingLevel: nil, markdownFragment: fragment),
            isBibliography: false, isNotes: false, notesLabel: nil)
    }

    @Test("(p) an insert after a block with no known id anchors on the nearest earlier id")
    func insertAfterNilIdAnchorsOnNearestEarlierId() {
        let ids = TempIds()
        let baseline = [entry("a", "A."), entry(nil, "B."), entry("c", "C.")]
        let result = MarkdownBlockDiff.diff(baseline: baseline, new: parse(blocks(["A.", "B.", "X.", "C."])), makeTempId: { ids.make() })
        #expect(inserts(result.changes) == ["temp-md-1|after:a|X."])
        // The unknown block sits between the anchor and the new block in the database: say so, so the caller re-reads rows.
        #expect(result.unaddressable == 1)
        #expect(result.baselineAfterWriteMustBeRows)
        expectEveryInsertAnchored(result.changes)
    }

    @Test("(p) with no earlier id at all the insert is atDocumentStart, never a nil anchor")
    func insertWithNoEarlierIdIsDocumentStart() {
        let ids = TempIds()
        let baseline = [entry(nil, "N.")]
        let result = MarkdownBlockDiff.diff(baseline: baseline, new: parse(blocks(["N.", "X."])), makeTempId: { ids.make() })
        #expect(inserts(result.changes) == ["temp-md-1|after:START|X."])
        expectEveryInsertAnchored(result.changes)
    }

    @Test("(p) an id later in the document resets the unknown-block flag")
    func laterIdResetsTheUnknownBlockFlag() {
        let ids = TempIds()
        let baseline = [entry(nil, "N."), entry("a", "A.")]
        let result = MarkdownBlockDiff.diff(baseline: baseline, new: parse(blocks(["N.", "A.", "Y."])), makeTempId: { ids.make() })
        #expect(inserts(result.changes) == ["temp-md-1|after:a|Y."])
        #expect(result.unaddressable == 0)
    }

    @Test("(p) a baseline block with no id that was removed cannot be addressed")
    func removedNilIdIsUnaddressable() {
        let baseline = [entry("a", "A."), entry(nil, "B.")]
        let result = MarkdownBlockDiff.diff(baseline: baseline, new: parse("A."))
        #expect(result.changes.isEmpty)
        #expect(result.unaddressable == 1)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    // MARK: - (q) whitespace

    @Test("(q) a whitespace-only change is an empty diff")
    func whitespaceOnlyChange() {
        let messy = "\n\n# Title  \n\n\n\nFirst paragraph here.   \n\nSecond paragraph here.\n\n\n\n\nThird paragraph here.\n\n\n"
        let result = diff(base, messy)
        #expect(result.isEmpty)
        #expect(result.filtered.total == 0)
        #expect(!result.emptyOnlyBecauseFiltered)
        #expect(!result.baselineAfterWriteMustBeRows)
    }

}

// The rest of the suite (the pre-filter, rows mode, the guard, the round trips) lives in an extension so the struct body stays
// under the project's type-body-length limit.
extension MarkdownBlockDiffTests {

    // MARK: - (r) the pre-filter

    private var marker: String { BlockParser.bibliographyEndMarker }

    private var managed: [String] {
        [
            "# Intro", "Body paragraph.",
            "# Bibliography", "Smith 2020. First entry.", "Jones 2021. Second entry.", marker,
            "# Notes", "[^1]: First note.", "[^2]: Second note."
        ]
    }

    @Test("(r) premise: the managed document's rows carry the bibliography and Notes flags the cases below rely on")
    func managedDocumentFlags() throws {
        let rows = storedRows(blocks(managed))
        try #require(rows.count == 8, "the end marker produces no block")
        #expect(rows.map(\.isBibliography) == [false, false, true, true, true, false, false, false])
        #expect(rows.map(\.isNotes) == [false, false, false, false, false, true, true, true])
    }

    @Test("(r) a hand edit of a bibliography entry is dropped, and the diff is empty ONLY because of the filter (C4)")
    func bibliographyUpdateDropped() {
        var edited = managed
        edited[3] = "Smith 2020. First entry EDITED."
        let result = diff(blocks(managed), blocks(edited))
        #expect(result.changes.isEmpty)
        #expect(result.filtered.bibliographyUpdates == 1)
        #expect(result.emptyOnlyBecauseFiltered)
        #expect(result.baselineAfterWriteMustBeRows)
    }

    @Test("(r) deleting a bibliography entry is dropped")
    func bibliographyDeleteDropped() {
        var edited = managed
        edited.remove(at: 4)
        let result = diff(blocks(managed), blocks(edited))
        #expect(result.changes.isEmpty)
        #expect(result.filtered.bibliographyDeletes == 1)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    @Test("(r) a new paragraph the parse flags as bibliography is dropped")
    func bibliographyInsertDropped() {
        var edited = managed
        edited.insert("Brown 2022. Third entry.", at: 5)
        let result = diff(blocks(managed), blocks(edited))
        #expect(result.changes.isEmpty)
        #expect(result.filtered.bibliographyInserts == 1)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    @Test("(r) a Notes label change is dropped")
    func notesLabelChangeDropped() {
        var edited = managed
        edited[7] = "[^9]: First note."
        let result = diff(blocks(managed), blocks(edited))
        #expect(result.changes.isEmpty)
        #expect(result.filtered.notesLabelChanges == 1)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    @Test("(r) deleting a Notes definition is dropped")
    func notesDeleteDropped() {
        var edited = managed
        edited.remove(at: 8)
        let result = diff(blocks(managed), blocks(edited))
        #expect(result.changes.isEmpty)
        #expect(result.filtered.notesDeletes == 1)
        #expect(result.emptyOnlyBecauseFiltered)
    }

    @Test("(r) a Notes text edit with the label unchanged is KEPT")
    func notesTextEditKept() {
        var edited = managed
        edited[7] = "[^1]: First note, expanded."
        let result = diff(blocks(managed), blocks(edited))
        #expect(updates(result.changes) == ["r7|[^1]: First note, expanded.|-|paragraph"])
        #expect(result.filtered.total == 0)
        #expect(!result.emptyOnlyBecauseFiltered)
    }

    @Test("(r) N3: a new paragraph typed inside the Notes section is SENT, anchored after the last Notes row")
    func newParagraphInsideNotesIsSent() throws {
        var edited = managed
        edited.append("A new thought typed under the notes.")
        let newText = blocks(edited)
        // Premise: the parse flags it as part of the Notes run (so a pre-filter on the parse flag would have dropped it).
        try #require(parse(newText).last?.isNotes == true)
        let result = diff(blocks(managed), newText)
        #expect(inserts(result.changes) == ["temp-md-1|after:r8|A new thought typed under the notes."])
        #expect(result.filtered.total == 0)
        #expect(!result.baselineAfterWriteMustBeRows)
    }

    @Test("(r) the filter reads the ALIGNED ROW's flags, not the new parse's")
    func filterUsesTheRowsFlags() {
        var rows = storedRows(blocks(managed))
        rows[1].isBibliography = true   // the database holds "Body paragraph." as bibliography; the new parse does not
        var edited = managed
        edited[1] = "Body paragraph, edited."
        let ids = TempIds()
        let result = MarkdownBlockDiff.diff(rows: rows, new: parse(blocks(edited)), makeTempId: { ids.make() })
        #expect(result.changes.isEmpty)
        #expect(result.filtered.bibliographyUpdates == 1)
    }

    @Test("(r) a user edit and a bibliography hand edit together: the edit is sent, the bibliography edit is dropped, the baseline goes back to rows")
    func userEditSentBibliographyEditDropped() {
        var edited = managed
        edited[1] = "Body paragraph, edited."
        edited[3] = "Smith 2020. First entry EDITED."
        let result = diff(blocks(managed), blocks(edited))
        #expect(updates(result.changes) == ["r2|Body paragraph, edited.|-|paragraph"])
        #expect(result.filtered.bibliographyUpdates == 1)
        #expect(!result.emptyOnlyBecauseFiltered)
        #expect(result.baselineAfterWriteMustBeRows)
    }

    @Test("(r) an insert right after a dropped bibliography insert anchors on the last block that has an id, never on the dropped one")
    func insertNeverAnchorsOnADroppedInsert() throws {
        var edited = managed
        edited.insert("Brown 2022. Third entry.", at: 5)    // dropped: the parse flags it bibliography
        edited.insert("Closing paragraph.", at: 7)          // sent: after the end marker, so not bibliography
        let newText = blocks(edited)
        let parsed = parse(newText)
        try #require(parsed[5].isBibliography && !parsed[6].isBibliography, "premise: Brown is bibliography, the closing paragraph is not")
        let result = diff(blocks(managed), newText)
        #expect(result.filtered.bibliographyInserts == 1)
        #expect(inserts(result.changes) == ["temp-md-1|after:r5|Closing paragraph."])   // r5 = the last entry, not a temp id
    }

    // MARK: - (s) rows mode: the first fire after a load

    @Test("(s) the first fire after a load writes exactly the user's changes")
    func rowsModeFirstFireWritesExactlyTheChanges() {
        let full = ["# Intro", "Para one.", "Para two.", "Para three.", "# Bibliography",
                    "Smith 2020. First entry.", "Jones 2021. Second entry.", marker]
        let rows = storedRows(blocks(full))
        let loaded = BlockParser.assembleMarkdownForEditor(from: rows)

        // Control: nothing typed since the load is an empty diff, and every parsed block lines up with its row.
        let untouched = MarkdownBlockDiff.diff(rows: rows, new: parse(loaded))
        #expect(untouched.isEmpty && untouched.filtered.total == 0)
        #expect(MarkdownBlockDiff.align(parsed: parse(loaded), rows: rows) == rows.map { Optional($0.id) })

        // Typed: edit "Para one.", delete "Para three.", append a closing paragraph after the end marker.
        var parts = loaded.components(separatedBy: "\n\n")
        parts[1] = "Para one, edited."
        parts.remove(at: 3)
        parts.append("Closing paragraph.")
        let result = diff(blocks(full), parts.joined(separator: "\n\n"))
        #expect(updates(result.changes) == ["r2|Para one, edited.|-|paragraph"])
        #expect(result.changes.deletes == ["r4"])
        #expect(inserts(result.changes) == ["temp-md-1|after:r7|Closing paragraph."])
        #expect(result.filtered.total == 0)
    }

    // MARK: - (t) the open-fence / open-math guard

    @Test("(t) endsInsideOpenFenceOrMath: code fences")
    func openCodeFence() {
        #expect(BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n```swift\nlet x = 1\n"))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n```swift\nlet x = 1\n```\n\nOutro."))
        // Fences pair up from the top: an odd number of fence lines is open at the end, however many follow the opener.
        #expect(BlockParser.endsInsideOpenFenceOrMath("a\n\n```\nb\n\n```\nc\n\n```\nd"))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("a\n\n```\nb\n```\nc\n\n```\nd\n```"))
    }

    @Test("(t) endsInsideOpenFenceOrMath: display math, bare and glued")
    func openDisplayMath() {
        #expect(BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n$$\nx = 1"))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n$$\nx = 1\n$$\n\nOutro."))
        #expect(BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n$$\\begin{aligned}\nx &= 1"))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n$$\\begin{aligned}\nx &= 1\n\\end{aligned}$$\n\nOutro."))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("Intro.\n\n$$x^2 + y^2$$\n\nOutro."))
    }

    @Test("(t) endsInsideOpenFenceOrMath: ordinary text, and a fence-looking line inside math is not a new opener")
    func notOpen() {
        #expect(!BlockParser.endsInsideOpenFenceOrMath(""))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("# Heading\n\nJust text.\n\n- a list\n- of items"))
        #expect(!BlockParser.endsInsideOpenFenceOrMath("$$\n```\n$$"))
    }

    // MARK: - (u) round trip on generated documents

    private enum Fixtures {
        static let article = POCComplexGenerator.make(id: "article", title: "Article", chapters: 1)
        static let book6 = POCComplexGenerator.make(id: "book6", title: "Six chapters", chapters: 6)
    }

    private func expectRoundTripAligns(_ doc: POCComplexDoc) {
        let rows = storedRows(doc.markdown)
        let assembled = BlockParser.assembleMarkdownForEditor(from: rows)
        let parsed = parse(assembled)
        #expect(parsed.count == rows.count, "\(doc.id): the reassembled text parses to the same number of blocks (\(doc.counts.summary))")
        let ids = MarkdownBlockDiff.align(parsed: parsed, rows: rows)
        #expect(ids.allSatisfy { $0 != nil }, "\(doc.id): every parsed block has an aligned id")
        #expect(ids.compactMap { $0 } == rows.map(\.id), "\(doc.id): and it is its own row's id")
        let result = MarkdownBlockDiff.diff(rows: rows, new: parsed)
        #expect(result.isEmpty && result.filtered.total == 0 && result.unaddressable == 0, "\(doc.id): reloading without typing is an empty diff")
    }

    @Test("(u) round trip: assemble(rows) -> parse -> align gives an id for every block of the generated article")
    func roundTripArticle() {
        expectRoundTripAligns(Fixtures.article)
    }

    @Test("(u) round trip: the same for the generated six-chapter book")
    func roundTripBook() {
        expectRoundTripAligns(Fixtures.book6)
    }

    @Test("(u) the end-of-bibliography marker: it produces NO block (so it never needs an id), only flags the block before it")
    func endMarkerParsesToNoBlock() throws {
        let rows = storedRows(blocks(managed))
        let assembled = BlockParser.assembleMarkdownForEditor(from: rows)
        #expect(assembled.contains(marker), "the editor text carries the end marker after the last bibliography row")
        let parsed = parse(assembled)
        #expect(parsed.count == rows.count, "the marker is not a block, in the rows or in the parse")
        #expect(parsed.filter(\.endsBibliographyRun).count == 1)
        #expect(MarkdownBlockDiff.align(parsed: parsed, rows: rows).allSatisfy { $0 != nil })
        #expect(MarkdownBlockDiff.diff(rows: rows, new: parsed).isEmpty)
    }

    // MARK: - (v) book length, (w) shared assembly order and the key, (x) temp ids

    @Test("(v) at book length one typed sentence is exactly one update")
    func bookLengthOneEditIsOneUpdate() throws {
        let doc = Fixtures.book6
        let rows = storedRows(doc.markdown)
        var fragments = rows.map(\.markdownFragment)
        let target = try #require(rows.indices.first { $0 >= rows.count / 2 && rows[$0].blockType == .paragraph && !rows[$0].isNotes })
        fragments[target] += " One more sentence typed by the user."
        let result = MarkdownBlockDiff.diff(rows: rows, new: parse(blocks(fragments)))
        #expect(result.changes.updates.map(\.id) == ["r\(target + 1)"], "\(doc.counts.summary)")
        #expect(result.changes.inserts.isEmpty && result.changes.deletes.isEmpty)
        #expect(result.filtered.total == 0)
    }

    @Test("(w) the shared assembly order: heading before non-heading at equal sortOrder, empty fragments dropped")
    func assemblyOrder() {
        let blocksIn = [
            Block(id: "p", projectId: Self.pid, sortOrder: 2, blockType: .paragraph, textContent: "t", markdownFragment: "Text."),
            Block(id: "empty", projectId: Self.pid, sortOrder: 1, blockType: .paragraph, textContent: "", markdownFragment: "  \n"),
            Block(id: "h", projectId: Self.pid, sortOrder: 2, blockType: .heading, textContent: "H", markdownFragment: "# H", headingLevel: 1),
            Block(id: "first", projectId: Self.pid, sortOrder: 0.5, blockType: .paragraph, textContent: "f", markdownFragment: "First.")
        ]
        #expect(MarkdownBlockDiff.assemblyOrderedNonEmpty(blocksIn).map(\.id) == ["first", "h", "p"])
    }

    @Test("(w) the key ignores whitespace around a fragment and the level of a non-heading, not the type or a heading's level")
    func keyEquality() {
        func key(_ type: BlockType, _ level: Int?, _ text: String) -> MarkdownBlockDiff.Key {
            MarkdownBlockDiff.Key(blockType: type, headingLevel: level, markdownFragment: text)
        }
        #expect(key(.paragraph, nil, "  hi  \n") == key(.paragraph, nil, "hi"))
        #expect(key(.paragraph, 3, "hi") == key(.paragraph, nil, "hi"))
        #expect(key(.heading, 2, "## hi") != key(.heading, 3, "## hi"))
        #expect(key(.paragraph, nil, "hi") != key(.blockquote, nil, "hi"))
        #expect(key(.paragraph, nil, "hi") != key(.paragraph, nil, "hi there"))
    }

    @Test("(x) resolvingTempIds swaps the minted ids into the next baseline, and a temp id the write did not mint becomes nil")
    func resolvingTempIds() {
        let result = diff(base, blocks([intro, one, "New one.", two, "New two.", three]))
        let resolved = result.resolvingTempIds(["temp-md-1": "perm-1"])
        #expect(resolved.map(\.id) == ["r1", "r2", "perm-1", "r3", nil, "r4"])
    }
}
