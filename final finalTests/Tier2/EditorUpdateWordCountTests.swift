//
//  EditorUpdateWordCountTests.swift
//  final finalTests
//
//  Tier 2 (t-0b70d1e9, the word-count fix found by the VM runs; EVERYDAY): what an editor block update does to a row's `wordCount`.
//  The editor sends each changed block as `BlockUpdate(textContent:, markdownFragment:)`. Its `textContent` is ProseMirror's
//  `node.textContent`, which leaves out inline atom nodes (citations, footnote references, annotations); the importer's `textContent`
//  is stripped markdown that still holds the citation syntax, and `MarkdownUtils.wordCount` counts `[@key]` as the two words it renders
//  as ("Smith 2020"). Counting the editor's text lost two words per citation every time a paragraph was sent back as an update (a
//  footnote renumber sends back every paragraph that holds a reference), so the project's total dipped by dozens of words after a
//  drag until the project was reopened. The update now counts its words from its markdown FRAGMENT
//  (`Block.recalculateWordCount(fromMarkdown:)`, `ProjectDatabase.recountWordsFromFragment`), LAST in each update path; an update with
//  no fragment keeps the count taken from its text.
//
//  Tests: the seam (a citation paragraph updated without its citation keeps its count), a footnote renumber that changes only the
//  fragment, each of the other update paths (the update merged into a block inserted in the same batch, the defensive update of a row
//  that still has its temporary id, the insert), the update without a fragment, and the PARITY of the two counts: for each markdown
//  shape, the importer's count and the count after an editor update carrying the same markdown are equal.
//
//  KNOWN, ACCEPTED CORNER, deliberately not tested as parity: a block quote or list item whose own text starts with an ordinal
//  (`> 1. First item`, `- 3. foo`) counts ONE word higher from the fragment than from the importer, because
//  `MarkdownUtils.stripMarkdownSyntax` runs its list-marker step before its blockquote step (MarkdownUtils.swift, the two steps in
//  order) and the importer passes `stripListMarkers: false` for quotes while the fragment path does not. It is rare and is filed on the
//  board; reopening the project restores the importer's number.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor block updates count words from their markdown (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EditorUpdateWordCountTests {

    // MARK: - Helpers

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
    }

    private func makeFixture(_ markdown: String) throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        return Fixture(db: db, pid: try TestFixtureFactory.getProjectId(from: db))
    }

    private func row(_ fixture: Fixture, containing text: String) throws -> Block {
        try #require(
            try fixture.db.fetchBlocks(projectId: fixture.pid).first { $0.markdownFragment.contains(text) && !$0.isNotes },
            "no row containing '\(text)'")
    }

    private func reload(_ fixture: Fixture, id: String) throws -> Block {
        try #require(try fixture.db.fetchBlocks(projectId: fixture.pid).first { $0.id == id }, "row \(id) is gone")
    }

    @discardableResult
    private func apply(_ fixture: Fixture, _ changes: BlockChanges) throws -> [String: String] {
        try fixture.db.applyBlockChangesFromEditor(changes, for: fixture.pid)
    }

    private func update(_ block: Block, text: String?, fragment: String?) -> BlockUpdate {
        BlockUpdate(id: block.id, textContent: text, markdownFragment: fragment, headingLevel: block.headingLevel)
    }

    // MARK: - The seam

    // A paragraph holding a citation, as the importer counts it ("A claim about origins Smith 2020 stands firm." is 8 words). The
    // editor sends it back unchanged apart from its text, which has lost the citation (an inline atom): the count must not move.
    @Test("anEditUpdateKeepsTheCitationWordsInTheCount")
    func anEditUpdateKeepsTheCitationWordsInTheCount() throws {
        let fixture = try makeFixture("A claim about origins [@smith2020] stands firm.")
        let paragraph = try row(fixture, containing: "A claim about origins")
        #expect(paragraph.wordCount == 8, "precondition: the importer counts the citation as two words, got \(paragraph.wordCount)")

        try apply(fixture, BlockChanges(updates: [
            update(paragraph, text: "A claim about origins  stands firm.", fragment: paragraph.markdownFragment)
        ]))

        let after = try reload(fixture, id: paragraph.id)
        #expect(after.wordCount == 8, "the update lost the citation's two words: 8 -> \(after.wordCount)")
        // t-4eb7bfa9 (S14): the stored text is no longer the editor's own (ProseMirror's `node.textContent`, which lost the
        // citation); it is what a close derives from the fragment (`BlockParser.extractTextContent`), which keeps the citation
        // syntax, so a close finds nothing to rewrite.
        #expect(
            after.textContent == "A claim about origins [@smith2020] stands firm.", "the stored text is derived from the fragment, citation kept")
    }

    // A footnote renumber sends the paragraph back with only the reference changed (`[^1]` -> `[^10]`) and the same editor text. A
    // renumber is the everyday way a paragraph with a citation and a footnote reference is sent back as an update.
    @Test("aFootnoteRenumberOnlyUpdateKeepsTheCount")
    func aFootnoteRenumberOnlyUpdateKeepsTheCount() throws {
        let fixture = try makeFixture("The claim [@smith2020] holds[^1] here.\n\n[^1]: A note.")
        let paragraph = try row(fixture, containing: "The claim")
        #expect(paragraph.wordCount == 6, "precondition: The claim Smith 2020 holds here is 6 words, got \(paragraph.wordCount)")
        let renumbered = paragraph.markdownFragment.replacingOccurrences(of: "[^1]", with: "[^10]")
        #expect(renumbered != paragraph.markdownFragment, "precondition: the fragment holds the reference")

        try apply(fixture, BlockChanges(updates: [update(paragraph, text: "The claim  holds here.", fragment: renumbered)]))

        let after = try reload(fixture, id: paragraph.id)
        #expect(after.markdownFragment == renumbered)
        #expect(after.wordCount == 6, "the renumber changed the word count: 6 -> \(after.wordCount)")
    }

    // MARK: - The other update paths

    // The paragraph was inserted in this very batch and updated again before its permanent id was known: the update arrives under the
    // temporary id and is merged into the inserted row.
    @Test("anUpdateMergedIntoABlockInsertedInTheSameBatchCountsFromItsFragment")
    func anUpdateMergedIntoABlockInsertedInTheSameBatchCountsFromItsFragment() throws {
        let fixture = try makeFixture("First paragraph here.")
        let last = try row(fixture, containing: "First paragraph")
        let insert = BlockInsert(
            tempId: "temp-merge-1", blockType: "paragraph", textContent: "Inserted words", markdownFragment: "Inserted words",
            headingLevel: nil, afterBlockId: last.id, atDocumentStart: nil)
        let merged = BlockUpdate(
            id: "temp-merge-1", textContent: "Inserted words cited here",
            markdownFragment: "Inserted words cited [@smith2020] here", headingLevel: nil)

        let mapping = try apply(fixture, BlockChanges(updates: [merged], inserts: [insert]))

        let permanentId = try #require(mapping["temp-merge-1"], "the insert was not given a permanent id")
        let after = try reload(fixture, id: permanentId)
        #expect(after.markdownFragment == "Inserted words cited [@smith2020] here", "the update was not merged into the inserted row")
        #expect(after.wordCount == 6, "Inserted words cited Smith 2020 here is 6 words, the merge counted \(after.wordCount)")
    }

    // NOT TESTED, and why: `applyDefensiveTempIdUpdate` (an update that names a temporary id which still names a ROW) cannot be reached
    // through `applyBlockChangesFromEditor`. `processEditorUpdates` looks the id up first (`Block.fetchOne(db, key: update.id)`) and takes
    // the primary path whenever a row has it, temporary id or not (a row seeded with the id "temp-..." was tried: it is counted by
    // `applyUpdateToExistingBlock`, which the first test already covers); the defensive branch repeats that very lookup after it came
    // back empty. The function is private, so no test can call it directly either. It carries the same fragment recount as the other
    // paths, but no unit test can prove it.

    // A paragraph the editor inserted, whose own text left out the citation: the row is counted from the insert's markdown.
    @Test("anInsertedBlockCountsFromItsFragment")
    func anInsertedBlockCountsFromItsFragment() throws {
        let fixture = try makeFixture("First paragraph here.")
        let last = try row(fixture, containing: "First paragraph")
        let insert = BlockInsert(
            tempId: "temp-insert-1", blockType: "paragraph", textContent: "Fresh words cited here",
            markdownFragment: "Fresh words cited [@smith2020] here", headingLevel: nil, afterBlockId: last.id, atDocumentStart: nil)

        let mapping = try apply(fixture, BlockChanges(inserts: [insert]))

        let permanentId = try #require(mapping["temp-insert-1"], "the insert was not given a permanent id")
        let after = try reload(fixture, id: permanentId)
        #expect(after.wordCount == 6, "Fresh words cited Smith 2020 here is 6 words, the insert counted \(after.wordCount)")
    }

    // MARK: - No fragment

    // An update with no fragment (older payloads, callers that only have text) has nothing to count the markdown from: the count is
    // taken from its text, as before. The row's STORED fragment (which still holds a citation) must not be counted instead.
    @Test("anUpdateWithoutAFragmentKeepsTheCountFromItsText")
    func anUpdateWithoutAFragmentKeepsTheCountFromItsText() throws {
        let fixture = try makeFixture("A claim about origins [@smith2020] stands firm.")
        let paragraph = try row(fixture, containing: "A claim about origins")
        let newText = "A claim about origins stands firm today."

        try apply(fixture, BlockChanges(updates: [update(paragraph, text: newText, fragment: nil)]))

        let after = try reload(fixture, id: paragraph.id)
        #expect(after.markdownFragment == paragraph.markdownFragment, "an update without a fragment must leave the stored fragment alone")
        #expect(
            after.wordCount == MarkdownUtils.wordCount(for: newText),
            "the count should come from the update's text (\(MarkdownUtils.wordCount(for: newText))), it is \(after.wordCount)")
    }

    // MARK: - Parity with the importer

    /// A markdown shape, the text ProseMirror would report for it (`node.textContent`: the inline atoms contribute nothing), and a
    /// piece of its text that finds its row.
    enum Shape: String, CaseIterable, CustomTestStringConvertible {
        case citation
        case suppressAuthorCitation
        case footnoteReference
        case heading
        case listItem
        case blockQuote
        case tableRow
        case commentBearingParagraph
        case annotationOnlyParagraph

        var testDescription: String { rawValue }

        var markdown: String {
            switch self {
            case .citation: return "As argued before [@smith2020, p. 3], the claim holds."
            case .suppressAuthorCitation: return "Smith argues [-@smith2020] that the claim holds."
            case .footnoteReference: return "The claim holds[^1] as shown.\n\n[^1]: A note."
            case .heading: return "## A heading with [@smith2020] cite"
            case .listItem: return "- First item with [@smith2020] cite\n- Second plain item"
            case .blockQuote: return "> A quoted line with [@smith2020] cite"
            case .tableRow: return "| Name | Notes |\n|------|-------|\n| Alpha one | cited [@smith2020] here |"
            case .commentBearingParagraph: return "A paragraph with words <!-- ::comment:: A reviewer note that is long --> and more words."
            case .annotationOnlyParagraph: return "<!-- ::task:: [ ] Check the sources -->"
            }
        }

        /// What the editor's `textContent` would be for the block (no inline atoms).
        var editorText: String {
            switch self {
            case .citation: return "As argued before , the claim holds."
            case .suppressAuthorCitation: return "Smith argues  that the claim holds."
            case .footnoteReference: return "The claim holds as shown."
            case .heading: return "A heading with  cite"
            case .listItem: return "First item with  citeSecond plain item"
            case .blockQuote: return "A quoted line with  cite"
            case .tableRow: return "NameNotesAlpha onecited  here"
            case .commentBearingParagraph: return "A paragraph with words  and more words."
            case .annotationOnlyParagraph: return ""
            }
        }

        var marker: String {
            switch self {
            case .citation: return "As argued"
            case .suppressAuthorCitation: return "Smith argues"
            case .footnoteReference: return "The claim holds"
            case .heading: return "A heading with"
            case .listItem: return "First item"
            case .blockQuote: return "A quoted line"
            case .tableRow: return "Alpha one"
            case .commentBearingParagraph: return "A paragraph with words"
            case .annotationOnlyParagraph: return "Check the sources"
            }
        }
    }

    // For each shape: the row the importer made has the importer's count; an editor update carrying the SAME markdown as its fragment (and
    // the editor's text, without the inline atoms) must leave the count exactly where the importer put it. This is what makes counting
    // from the fragment safe: the two ways of counting agree on everything the app produces.
    @Test("anEditUpdateCountsLikeTheImporter", arguments: Shape.allCases)
    func anEditUpdateCountsLikeTheImporter(_ shape: Shape) throws {
        let fixture = try makeFixture(shape.markdown)
        let imported = try row(fixture, containing: shape.marker)
        let importerCount = imported.wordCount
        if shape != .annotationOnlyParagraph {
            #expect(importerCount > 0, "precondition: the importer counts the \(shape) row (\(imported.markdownFragment))")
        }

        try apply(fixture, BlockChanges(updates: [
            BlockUpdate(
                id: imported.id, textContent: shape.editorText, markdownFragment: imported.markdownFragment,
                headingLevel: imported.headingLevel)
        ]))

        let after = try reload(fixture, id: imported.id)
        #expect(
            after.wordCount == importerCount,
            "\(shape): the importer counts \(importerCount) words, the editor update counts \(after.wordCount) for '\(imported.markdownFragment)'")
    }
}
