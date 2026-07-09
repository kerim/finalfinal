//
//  SectionBreakOutlineSyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Regression coverage for a bug where `/break` correctly inserted a
//  section_break node in the editor (visible as "§") but the block never
//  showed up in the outline sidebar. Root cause: `applyBlockChangesFromEditor`
//  (Database+Blocks.swift) never set `isPseudoSection = true` when
//  materializing a section_break block from an editor diff — neither for a
//  genuinely new block (the INSERT branch, used by /break's "text before",
//  "text after", and "split" cases) nor for an in-place paragraph→section_break
//  conversion that keeps its existing block id (the UPDATE branch, used by
//  bare /break on an empty paragraph — see block-id-plugin.ts's
//  `phase1CanClaim`, which treats this as a legitimate non-atomic type
//  conversion at the same offset).
//
//  `observeOutlineBlocks`/`fetchOutlineBlocks` filter on
//  `Block.Columns.isPseudoSection == true`, not on `blockType`, so a block
//  with the correct `.sectionBreak` type but `isPseudoSection == false`
//  silently never appears in the outline — exactly the symptom reported:
//  the § renders in the editor (that's the ProseMirror node view, unrelated
//  to this flag) but no new section appears in the sidebar.
//

import Testing
import Foundation
@testable import final_final

@Suite("Section Break Outline Sync — Tier 1: Silent Killers")
struct SectionBreakOutlineSyncTests {

    @Test("A newly INSERTed section_break block is flagged as a pseudo-section and appears in the outline")
    func insertedSectionBreakAppearsInOutline() throws {
        let content = """
        # Doc

        Some notes paragraph.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let notesParagraph = blocksBefore.first { $0.textContent == "Some notes paragraph." }!

        // Mirrors what block-sync-plugin.ts sends for the /break "text before only"
        // case: a genuinely new top-level node, anchored after the paragraph that
        // still holds the text preceding the command.
        let changes = BlockChanges(
            inserts: [
                BlockInsert(
                    tempId: "temp-break",
                    blockType: "section_break",
                    textContent: "",
                    markdownFragment: "<!-- ::break:: -->",
                    headingLevel: nil,
                    afterBlockId: notesParagraph.id
                )
            ]
        )

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let permanentId = try #require(mapping["temp-break"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let breakBlock = try #require(blocksAfter.first { $0.id == permanentId })

        #expect(breakBlock.blockType == .sectionBreak)
        #expect(breakBlock.isPseudoSection == true,
                "inserted section_break block must be flagged as a pseudo-section for the outline filter")

        let outlineBlocks = try db.fetchOutlineBlocks(projectId: pid)
        #expect(outlineBlocks.contains { $0.id == permanentId },
                "fetchOutlineBlocks (and observeOutlineBlocks, which shares the same filter) must include the new section break")
    }

    @Test("A bare /break in-place paragraph→section_break conversion (same block id) is flagged and appears in the outline")
    func inPlaceConvertedSectionBreakAppearsInOutline() throws {
        let content = """
        # Doc

        Placeholder.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let placeholder = blocksBefore.first { $0.textContent == "Placeholder." }!

        // Mirrors what block-sync-plugin.ts sends for bare /break on an empty
        // paragraph: `tr.replaceWith` at the same offset keeps the paragraph's
        // existing block id (block-id-plugin.ts's phase1CanClaim allows the
        // non-atomic paragraph→section_break conversion), so this arrives as an
        // UPDATE to the existing id, not an INSERT.
        let changes = BlockChanges(
            updates: [
                BlockUpdate(
                    id: placeholder.id,
                    textContent: "",
                    markdownFragment: "<!-- ::break:: -->",
                    headingLevel: nil
                )
            ]
        )

        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let convertedBlock = try #require(blocksAfter.first { $0.id == placeholder.id })

        #expect(convertedBlock.blockType == .sectionBreak)
        #expect(convertedBlock.isPseudoSection == true,
                "in-place converted section_break block must be flagged as a pseudo-section for the outline filter")
        #expect(convertedBlock.headingLevel == nil)
        #expect(convertedBlock.wordCount == 0)

        let outlineBlocks = try db.fetchOutlineBlocks(projectId: pid)
        #expect(outlineBlocks.contains { $0.id == placeholder.id },
                "fetchOutlineBlocks (and observeOutlineBlocks, which shares the same filter) must include the converted section break")
    }
}
