//
//  BlockUpdateTypeTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  t-94369a83 Phase 3a-2, Step 1 (plan-v2 U-B1). A paragraph the user turns into a list ("- ", "1. ", "> ",
//  three backticks) keeps its block id, but the per-edit update carried no type: the row stayed a paragraph
//  holding a list's text, and a reopen without the close-time rebuild then showed a second list beside the old
//  paragraph row (`BlockParser.alignmentPairs` withholds an id when the row's type does not match the editor
//  node). `BlockUpdate` now carries the editor's own `blockType`, and every update path applies it through one
//  shared helper (`applyEditorBlockType`).
//
//  Rules pinned here (review findings D3 and D4):
//  - the editor type moves a row only among paragraph, bullet list, ordered list, blockquote, code block and
//    table, and only when the row is already one of those (after the fragment transition ran), so it can never
//    undo a rule or section break the fragment just produced, and never turns a heading into something else;
//  - a Notes row never takes a type from the editor;
//  - the word count is recomputed AFTER the type change (code blocks count zero).
//

import Testing
import Foundation
@testable import final_final

@Suite("BlockUpdate carries the editor's block type — Tier 1: Silent Killers")
struct BlockUpdateTypeTests {

    private static let paragraphSeed = "# A\n\nconvert me."

    private struct Seeded {
        let db: ProjectDatabase
        let pid: String
        let row: Block
    }

    /// Seeds a project and returns it with the row `match` finds (default: the one body paragraph).
    private func seeded(
        _ content: String = BlockUpdateTypeTests.paragraphSeed,
        find match: (Block) -> Bool = { $0.textContent == "convert me." }
    ) throws -> Seeded {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let row = try #require(try TestFixtureFactory.fetchBlocks(from: db).first(where: match))
        return Seeded(db: db, pid: pid, row: row)
    }

    private func row(_ id: String, in db: ProjectDatabase) throws -> Block {
        try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == id })
    }

    // U-B1 (a)
    @Test("A paragraph updated with blockType bullet_list keeps its id and becomes a bullet list")
    func paragraphBecomesBulletList() throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)
        let rowCount = try TestFixtureFactory.fetchBlocks(from: db).count
        #expect(paragraph.blockType == .paragraph)

        let update = BlockUpdate(id: paragraph.id, textContent: "convert me.", markdownFragment: "- convert me.",
                                 headingLevel: nil, blockType: "bullet_list")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        let after = try row(paragraph.id, in: db)
        #expect(after.blockType == .bulletList, "the update's type must reach the row; got \(after.blockType)")
        #expect(after.markdownFragment == "- convert me.")
        #expect(try TestFixtureFactory.fetchBlocks(from: db).count == rowCount, "a type update adds and removes no rows")
    }

    // U-B1 (a), the other four types of the set
    @Test("A paragraph takes each other type of the editor's set", arguments: [
        ("ordered_list", BlockType.orderedList, "1. convert me."),
        ("blockquote", BlockType.blockquote, "> convert me."),
        ("code_block", BlockType.codeBlock, "```\nconvert me.\n```"),
        ("table", BlockType.table, "| convert me. |\n| --- |")
    ])
    func paragraphTakesEachEditorType(raw: String, expected: BlockType, fragment: String) throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)

        let update = BlockUpdate(id: paragraph.id, textContent: "convert me.", markdownFragment: fragment,
                                 headingLevel: nil, blockType: raw)
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        #expect(try row(paragraph.id, in: db).blockType == expected)
    }

    // U-B1 (b)
    @Test("blockType paragraph reverts a list row to a paragraph")
    func paragraphRevertsAListRow() throws {
        let seed = try seeded("# A\n\n- convert me.", find: { $0.blockType == .bulletList })
        let (db, pid, listRow) = (seed.db, seed.pid, seed.row)

        let update = BlockUpdate(id: listRow.id, textContent: "convert me.", markdownFragment: "convert me.",
                                 headingLevel: nil, blockType: "paragraph")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        #expect(try row(listRow.id, in: db).blockType == .paragraph, "the list was edited back to plain text")
    }

    @Test("An update without a blockType, or with one the editor set does not include, leaves the type alone")
    func absentOrUnknownTypeIsIgnored() throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)

        for raw in [nil, "no_such_type", "heading", "horizontal_rule", "image", "section_break", "math_display"] as [String?] {
            let update = BlockUpdate(id: paragraph.id, textContent: "convert me.", markdownFragment: "convert me.",
                                     headingLevel: nil, blockType: raw)
            _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)
            #expect(try row(paragraph.id, in: db).blockType == .paragraph, "blockType \(String(describing: raw)) must not move the row")
        }
    }

    // U-B1 (c)
    @Test("A Notes row never takes a type from the editor, though its text edit still applies")
    func notesRowIgnoresTheType() throws {
        let content = "Body[^2].\n\n# Notes\n\n[^2]: First real text."
        let seed = try seeded(content, find: { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]:") })
        let (db, pid, notes) = (seed.db, seed.pid, seed.row)
        let typeBefore = notes.blockType

        let update = BlockUpdate(id: notes.id, textContent: "Edited text.", markdownFragment: "[^2]: Edited text.",
                                 headingLevel: nil, blockType: "bullet_list")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        let after = try row(notes.id, in: db)
        #expect(after.markdownFragment == "[^2]: Edited text.", "the legitimate text edit still applies")
        #expect(after.isNotes)
        #expect(after.blockType == typeBefore, "a Notes row keeps its stored type; got \(after.blockType)")
    }

    // U-B1 (d), rule
    @Test("A paragraph row whose fragment became a rule ends as a rule even though the editor says paragraph (D3)")
    func ruleFragmentBeatsEditorParagraphType() throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)

        let update = BlockUpdate(id: paragraph.id, textContent: "---", markdownFragment: "---",
                                 headingLevel: nil, blockType: "paragraph")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        #expect(try row(paragraph.id, in: db).blockType == .horizontalRule,
                "the editor's 'paragraph' must not undo the rule the fragment just produced")
    }

    // U-B1 (d), section break
    @Test("A paragraph row whose fragment became a section break stays a section break and a pseudo-section (D3)")
    func sectionBreakFragmentBeatsEditorParagraphType() throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)

        let update = BlockUpdate(id: paragraph.id, textContent: "", markdownFragment: "<!-- ::break:: -->",
                                 headingLevel: nil, blockType: "paragraph")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        let after = try row(paragraph.id, in: db)
        #expect(after.blockType == .sectionBreak)
        #expect(after.isPseudoSection, "a paragraph typed row with isPseudoSection would show a § entry in the outline")
    }

    // U-B1 (e)
    @Test("The word count is recomputed after the type change: a paragraph made a code block counts zero (D4)")
    func wordCountFollowsTheNewType() throws {
        let seed = try seeded()
        let (db, pid, paragraph) = (seed.db, seed.pid, seed.row)
        #expect(paragraph.wordCount == 2)

        let update = BlockUpdate(id: paragraph.id, textContent: "convert me.", markdownFragment: "```\nconvert me.\n```",
                                 headingLevel: nil, blockType: "code_block")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        let after = try row(paragraph.id, in: db)
        #expect(after.blockType == .codeBlock)
        #expect(after.wordCount == 0, "code blocks count zero words; the count must follow the type, got \(after.wordCount)")
    }

    @Test("The word count is recomputed the other way too: a code block made a paragraph counts its words (D4)")
    func wordCountFollowsTheNewTypeBackToParagraph() throws {
        let seed = try seeded("# A\n\n```\ntwo words\n```", find: { $0.blockType == .codeBlock })
        let (db, pid, codeRow) = (seed.db, seed.pid, seed.row)
        #expect(codeRow.wordCount == 0)

        let update = BlockUpdate(id: codeRow.id, textContent: "two words", markdownFragment: "two words",
                                 headingLevel: nil, blockType: "paragraph")
        _ = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: pid)

        let after = try row(codeRow.id, in: db)
        #expect(after.blockType == .paragraph)
        #expect(after.wordCount == 2, "got \(after.wordCount)")
    }

    // The merge path: an update naming a temp id minted by an insert in the SAME batch.
    @Test("An update merged into an insert of the same batch carries its type onto the new row")
    func updateMergedIntoInsertedBlockCarriesTheType() throws {
        let seed = try seeded()
        let (db, pid, anchor) = (seed.db, seed.pid, seed.row)

        let insert = BlockInsert(tempId: "temp-bu-1", blockType: "paragraph", textContent: "fresh", markdownFragment: "fresh",
                                 headingLevel: nil, afterBlockId: anchor.id)
        let update = BlockUpdate(id: "temp-bu-1", textContent: "fresh item", markdownFragment: "- fresh item",
                                 headingLevel: nil, blockType: "bullet_list")
        let mapping = try db.applyBlockChangesFromEditor(BlockChanges(updates: [update], inserts: [insert]), for: pid)

        let permanentId = try #require(mapping["temp-bu-1"])
        let minted = try row(permanentId, in: db)
        #expect(minted.markdownFragment == "- fresh item")
        #expect(minted.blockType == .bulletList, "the merge path must apply the type too; got \(minted.blockType)")
    }

    // The Codable contract: an absent field decodes as nil and nil encodes by omission, so a payload from before
    // this change (and every existing call site) means "no type information".
    @Test("blockType is optional on the wire: a missing field decodes as nil and nil is omitted when encoding")
    func codableTreatsBlockTypeAsOptional() throws {
        let old = Data(#"{"id":"b1","textContent":"x","markdownFragment":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(BlockUpdate.self, from: old)
        #expect(decoded.id == "b1")
        #expect(decoded.blockType == nil)

        let withType = Data(#"{"id":"b1","blockType":"bullet_list"}"#.utf8)
        #expect(try JSONDecoder().decode(BlockUpdate.self, from: withType).blockType == "bullet_list")

        let encoded = try JSONEncoder().encode(BlockUpdate(id: "b1", textContent: nil, markdownFragment: nil, headingLevel: nil))
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("blockType"), "nil must be omitted, not written as null: \(json)")
    }
}
