//
//  NotesInsertFlagTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for `resolveInsertPlacement`'s Notes containment rule
//  (Database+BlocksInsert.swift): an insert anchored on an existing, non-heading `isNotes`
//  block is "inside" the Notes section -- full stop, no next-block requirement, unlike
//  bibliography's containment rule. This is safe because footnote content can only ever be
//  EXTENDED by typing into it: placing the cursor inside an existing footnote definition
//  (including at the end of its last paragraph) and continuing to type is, definitionally,
//  editing that footnote. A NEW footnote is never created this way -- it is always created
//  by an explicit insert-footnote command acting on body text elsewhere in the document,
//  never by typing directly into the Notes area. So the anchor alone is sufficient evidence,
//  unlike bibliography, where trailing content after the last reference is a normal,
//  legitimate place for the user to start something new and unrelated.
//

import Testing
import Foundation
@testable import final_final

@Suite("Notes Insert-Flag Containment — Tier 1: Silent Killers")
struct NotesInsertFlagTests {

    @Test("A paragraph typed after the LAST footnote definition (document end) IS flagged isNotes immediately")
    func trailingParagraphAfterLastFootnoteIsFlaggedImmediately() throws {
        // No bibliography section -- the footnote definition is genuinely the LAST
        // block in the whole document, exactly the shape a real multi-paragraph
        // footnote continuation takes when typed at the end of the document.
        let seed = """
        Some text with a footnote.[^1]

        # Notes

        [^1]: The footnote text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let notesBlocks = blocksBefore.filter { $0.isNotes && $0.blockType != .heading }
        let lastNotesBlock = try #require(notesBlocks.max { $0.sortOrder < $1.sortOrder })
        #expect(
            blocksBefore.max { $0.sortOrder < $1.sortOrder }?.id == lastNotesBlock.id,
            """
            Fixture sanity check: the footnote definition must be the LAST block in the \
            document (no bibliography after it) for this test to exercise the real shape
            """
        )

        // Simulates: cursor at the end of the footnote's text, press Enter, type its
        // second paragraph -- an ordinary footnote continuation, not a new section.
        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-trailing",
                blockType: "paragraph",
                textContent: "A second paragraph of the footnote.",
                markdownFragment: "A second paragraph of the footnote.",
                headingLevel: nil,
                afterBlockId: lastNotesBlock.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-trailing"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isNotes == true,
            """
            A paragraph typed immediately after an existing, non-heading Notes block must be \
            flagged isNotes at insert time -- there is no legitimate editing action that types \
            new content into the Notes area other than extending the footnote it's anchored on
            """
        )
    }

    @Test("A literal [^N]: definition line typed by the editor is still flagged isNotes (safety net unaffected)")
    func literalDefinitionLineStillFlagged() throws {
        let seed = """
        Some text with a footnote.[^1]

        # Notes

        [^1]: The footnote text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeading = try #require(blocksBefore.first { $0.isNotes && $0.blockType == .heading })

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-def",
                blockType: "paragraph",
                textContent: "[^2]: A second, editor-typed footnote definition.",
                markdownFragment: "[^2]: A second, editor-typed footnote definition.",
                headingLevel: nil,
                afterBlockId: notesHeading.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-def"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isNotes == true,
            """
            A literal '[^N]:' definition line is unambiguous machine-shaped content -- flagged \
            isNotes on sight independent of anchor-based containment, since the Notes heading \
            itself is not a valid containment anchor (headings suppress containment)
            """
        )
    }

    @Test("A heading typed after the last footnote definition is NOT flagged isNotes (containment suppressed)")
    func headingAfterLastFootnoteIsNotFlagged() throws {
        // Containment is anchor-based, but must still be suppressed for a heading insert --
        // starting a brand-new document section right after the footnotes must not inherit
        // isNotes from its anchor.
        let seed = """
        Some text with a footnote.[^1]

        # Notes

        [^1]: The footnote text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let notesBlocks = blocksBefore.filter { $0.isNotes && $0.blockType != .heading }
        let lastNotesBlock = try #require(notesBlocks.max { $0.sortOrder < $1.sortOrder })

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-heading",
                blockType: "heading",
                textContent: "Acknowledgements",
                markdownFragment: "## Acknowledgements",
                headingLevel: 2,
                afterBlockId: lastNotesBlock.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-heading"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isNotes == false,
            """
            A heading anchored after the last footnote must never inherit isNotes containment \
            -- it opens a new section, not a footnote continuation, matching bibliography's \
            identical heading-suppression rule
            """
        )
    }
}
