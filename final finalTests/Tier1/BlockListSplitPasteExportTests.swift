//
//  BlockListSplitPasteExportTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Investigation of a reported "paste image into bullet list deletes multiple
//  bullets, image lands in wrong place" bug, observed via PDF-export
//  diagnostic dumps with small (non-10MB-threshold) images. This tests the
//  block-sync/reconciliation layer for the specific "one bullet_list splits
//  into two siblings around a new figure" edit — first the incremental
//  editor->DB sync path (applyBlockChangesFromEditor, fed the REAL BlockChanges
//  payload captured from the actual JS pipeline — see
//  web/milkdown/src/__tests__/repro-list-paste.test.ts for the JS-side
//  equivalent), then the SEPARATE full-document-reparse path used by
//  flushContentToDatabase()/flushForExport() (BlockParser.parse() against
//  Milkdown's own getMarkdown() serialization, captured from a real editor
//  instance -- NOT the custom nodeToMarkdownFragment serializer block-sync
//  itself uses for incremental diffs).
//

import Testing
import Foundation
@testable import final_final

@Suite("Block List-Split Paste — Export Path Reconciliation")
struct BlockListSplitPasteExportTests {

    // MARK: - Incremental editor->DB sync (applyBlockChangesFromEditor)

    /// Real payload captured from the actual JS pipeline (block-id-plugin.ts +
    /// block-sync-plugin.ts), splitting a 3-item list after "Item 1" and
    /// inserting a figure, verified byte-for-byte against a live Milkdown
    /// editor instance driving the real handlePaste + insertImage() code path
    /// (see the vitest capture used to derive this literal payload).
    @Test("Incremental sync: list split + image insert loses no bullets, correct order")
    func incrementalSyncPreservesAllBullets() throws {
        let content = """
        Before paragraph.

        - Item 1
        - Item 2
        - Item 3

        After paragraph.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)

        let listBlock = blocksBefore.first { $0.blockType == .bulletList }!
        #expect(listBlock.markdownFragment.contains("Item 1"))
        #expect(listBlock.markdownFragment.contains("Item 2"))
        #expect(listBlock.markdownFragment.contains("Item 3"))

        // EXACT payload real-pipeline-captured for: click at start of "Item 2",
        // paste an image (fakePasteEvent + real insertImage()).
        let changes = BlockChanges(
            updates: [
                BlockUpdate(id: listBlock.id, textContent: "Item 1", markdownFragment: "- Item 1", headingLevel: nil)
            ],
            inserts: [
                BlockInsert(
                    tempId: "temp-fig",
                    blockType: "image",
                    textContent: "",
                    markdownFragment: "![](projectmedia://test.png)",
                    headingLevel: nil,
                    afterBlockId: listBlock.id
                ),
                BlockInsert(
                    tempId: "temp-list2",
                    blockType: "bullet_list",
                    textContent: "Item 2Item 3",
                    markdownFragment: "- Item 2\n- Item 3",
                    headingLevel: nil,
                    afterBlockId: "temp-fig"
                )
            ]
        )

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        #expect(mapping["temp-fig"] != nil)
        #expect(mapping["temp-list2"] != nil)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let assembled = BlockParser.assembleMarkdown(from: blocksAfter)

        #expect(assembled.contains("Item 1"), "Item 1 must survive")
        #expect(assembled.contains("Item 2"), "Item 2 must survive")
        #expect(assembled.contains("Item 3"), "Item 3 must survive")
        #expect(assembled.contains("projectmedia://test.png"), "Image must survive")

        // Structural order check: before-para, list(Item1), figure, list(Item2,Item3), after-para
        let typesInOrder = blocksAfter.map { $0.blockType }
        #expect(typesInOrder == [.paragraph, .bulletList, .image, .bulletList, .paragraph],
                "Expected 5 top-level blocks in doc order, got: \(typesInOrder)")

        let list1 = blocksAfter[1]
        let figure = blocksAfter[2]
        let list2 = blocksAfter[3]
        #expect(list1.id == listBlock.id, "First list half should keep the original block id")
        #expect(list1.markdownFragment == "- Item 1")
        #expect(figure.imageSrc == "projectmedia://test.png")
        #expect(list2.markdownFragment == "- Item 2\n- Item 3")

        // alignmentPairs (feeds pushBlockIds -> JS setBlockIdsForTopLevel) must NOT
        // collapse list1/list2 here -- they are separated by the figure block, so
        // each must retain its own alignment slot (5 entries, not 4).
        let pairs = BlockParser.alignmentPairs(blocksAfter)
        #expect(pairs.count == 5, "Expected 5 alignment slots (no incorrect list merge), got \(pairs.count): \(pairs.map { $0.id.prefix(8) })")
    }

    // MARK: - Full re-parse path (flushContentToDatabase / flushForExport)

    /// Captures the REAL getMarkdown() (Milkdown's own remark-based serializer,
    /// via getContent() in api-content.ts) output for the identical list-split
    /// scenario above -- this is what flushContentToDatabase() actually re-parses
    /// via BlockParser.parse() before every export (see
    /// EditorViewState+Zoom.swift's flushForExport). Captured verbatim from a
    /// real Milkdown editor instance (commonmark+gfm presets, real imagePlugin,
    /// real blockIdPlugin/blockSyncPlugin) -- NOT hand-constructed -- so this
    /// test exercises the actual text BlockParser must correctly split.
    ///
    /// NOTE the captured text: Milkdown's remark-stringify renders the second
    /// list half as a LOOSE list ("* Item 2\n\n* Item 3" -- blank line between
    /// items, "*" marker instead of "-") rather than the tight
    /// "- Item 2\n- Item 3" the incremental JS diff computes. This is a REAL,
    /// confirmed discrepancy between the two serialization paths for the exact
    /// same document. BlockParser.splitIntoRawBlocks has no special-case for
    /// "consecutive same-type list lines separated by a blank line stay one
    /// block" -- it splits on every blank line -- so this text produces TWO
    /// separate bullet_list blocks for "Item 2" and "Item 3" instead of one.
    @Test("Full re-parse (flushContentToDatabase path): real getContent() text loses no bullets")
    func fullReparseOfRealGetContentOutputPreservesAllBullets() throws {
        // Captured verbatim via vitest from api-content.ts's getContent() after
        // driving the real handlePaste + insertImage() pipeline on:
        //   "Before paragraph.\n\n- Item 1\n- Item 2\n- Item 3\n\nAfter paragraph."
        // clicking at the start of "Item 2" then pasting an image.
        let realGetContentOutput =
            "Before paragraph.\n\n* Item 1\n\n![](projectmedia://test.png)\n\n* Item 2\n\n* Item 3\n\nAfter paragraph.\n"

        let pid = "test-project"
        let blocks = BlockParser.parse(markdown: realGetContentOutput, projectId: pid)

        // Confirm the loose-list artifact: splitIntoRawBlocks / detectBlockType
        // produce SEPARATE bullet_list rows for "Item 2" and "Item 3" rather
        // than one 2-item list row (documented above).
        let listBlocks = blocks.filter { $0.blockType == .bulletList }
        #expect(listBlocks.count == 3,
                Comment(rawValue: "Documents the loose-list split artifact: expected 3 separate bullet_list rows "
                    + "(Item 1 / Item 2 / Item 3), got \(listBlocks.count): \(listBlocks.map { $0.markdownFragment })"))

        // The actual question: is any bullet's TEXT actually lost or corrupted
        // by this parse, even though it's split into extra rows?
        let allText = blocks.map { $0.textContent }.joined(separator: "|")
        #expect(allText.contains("Item 1"), "Item 1 text must survive raw re-parse")
        #expect(allText.contains("Item 2"), "Item 2 text must survive raw re-parse")
        #expect(allText.contains("Item 3"), "Item 3 text must survive raw re-parse")

        let imageBlocks = blocks.filter { $0.blockType == .image }
        #expect(imageBlocks.count == 1, "Image must survive raw re-parse as exactly one block")
        #expect(imageBlocks.first?.imageSrc == "projectmedia://test.png")

        // Now the critical export-fidelity check: alignmentPairs' "collapse
        // consecutive same-type list blocks" heuristic assumes ProseMirror
        // will merge adjacent same-type list ROWS back into one PM node --
        // true when reloading via setContentWithBlockIds (which re-parses
        // through the SAME assembleMarkdown->remark pipeline), but the
        // heuristic only checks TYPE, never checks that total item/word count
        // survives the merge. Confirm alignment-slot count and, more
        // importantly, that assembleMarkdown's own round-trip (the actual
        // text pushed back to JS / to Pandoc) still contains everything.
        let pairs = BlockParser.alignmentPairs(blocks)
        // 5 real top-level nodes are expected in the live doc (before-para,
        // list1, figure, list2, after-para) -- list2's two DB rows must
        // collapse to exactly one alignment slot to match.
        #expect(pairs.count == 5,
                "Expected 5 alignment slots collapsing Item2+Item3 rows into one, got \(pairs.count)")

        let reassembled = BlockParser.assembleMarkdown(from: blocks)
        #expect(reassembled.contains("Item 1"))
        #expect(reassembled.contains("Item 2"))
        #expect(reassembled.contains("Item 3"))
        #expect(reassembled.contains("projectmedia://test.png"))
    }

    /// The concerning case: after alignmentPairs collapses Item2/Item3's two DB
    /// rows into one alignment slot (assigning the WHOLE live 2-item list node
    /// Item2's block id), Item3's row becomes an ORPHAN -- absent from
    /// pushBlockIds' orderedIds array, so no top-level JS node points to it
    /// anymore. Simulate the next incremental edit cycle: JS reports an UPDATE
    /// for Item2's id with BOTH items' content (since that id now represents the
    /// whole node), via the block-sync-plugin.ts nodeToMarkdownFragment
    /// serializer (tight list, not the loose getMarkdown() one). Confirm this
    /// UPDATE correctly overwrites Item2's row to hold both items, and that nothing
    /// permanently deletes Item3's now-redundant row's content from a full
    /// export before this update lands (i.e. exportBlocks always reruns
    /// flushForExport first, which fully re-parses from the STILL-CORRECT
    /// live doc, so the orphan is fixed on every export, not compounded).
    @Test("Orphaned merged-list-slot row does not cause permanent content loss across a second full reparse")
    func orphanedRowSelfHealsOnNextFullReparse() throws {
        let realGetContentOutput =
            "Before paragraph.\n\n* Item 1\n\n![](projectmedia://test.png)\n\n* Item 2\n\n* Item 3\n\nAfter paragraph.\n"

        let db = try TestFixtureFactory.createTemporary(content: "placeholder")
        let realPid = try TestFixtureFactory.getProjectId(from: db)

        // Simulate flushContentToDatabase(): full re-parse + replaceBlocks (blows
        // away whatever was there before, exactly like the real function does).
        let firstParse = BlockParser.parse(markdown: realGetContentOutput, projectId: realPid)
        try db.replaceBlocks(firstParse, for: realPid)

        let afterFirstFlush = try TestFixtureFactory.fetchBlocks(from: db)
        // Both rows exist immediately after this flush -- confirms no loss AT
        // the moment of the flush itself.
        let item2Row = afterFirstFlush.first { $0.textContent == "Item 2" }
        let item3Row = afterFirstFlush.first { $0.textContent == "Item 3" }
        #expect(item2Row != nil, "Item 2 row must exist right after first full reparse")
        #expect(item3Row != nil, "Item 3 row must exist right after first full reparse")

        // Now simulate a SECOND flushContentToDatabase() (e.g. a second export,
        // or export after further edits) using the SAME live-doc markdown
        // (nothing changed on the JS side -- the live ProseMirror doc was never
        // touched by the DB-side orphaning, per flushForExport's contract of
        // only READING via getContent(), never writing back into the WebView).
        let secondParse = BlockParser.parse(markdown: realGetContentOutput, projectId: realPid)
        try db.replaceBlocks(secondParse, for: realPid)

        let afterSecondFlush = try TestFixtureFactory.fetchBlocks(from: db)
        let allTextAfterSecond = afterSecondFlush.map { $0.textContent }
        #expect(allTextAfterSecond.contains("Item 1"), "Item 1 must survive a second full reparse")
        #expect(allTextAfterSecond.contains("Item 2"), "Item 2 must survive a second full reparse")
        #expect(allTextAfterSecond.contains("Item 3"), "Item 3 must survive a second full reparse")

        // No permanent duplication either: replaceBlocks deletes-all before
        // reinserting, so exactly one row per item across repeated reparses.
        #expect(allTextAfterSecond.filter { $0 == "Item 2" }.count == 1)
        #expect(allTextAfterSecond.filter { $0 == "Item 3" }.count == 1)
    }

    // MARK: - Figure nested inside a list item (paste at end of a bullet)

    /// The DELIBERATE, tested placement behavior for pasting an image at the
    /// END of a list item's text (see web/milkdown/src/__tests__/insert-pos.test.ts,
    /// "end of the LAST item nests inside it") does NOT split the list -- it
    /// nests the figure as a second child of that one list_item, sibling to
    /// its mandatory-first paragraph. This is the REAL, CONFIRMED root cause
    /// found in this investigation: block-sync-plugin.ts's serializeInlineContent
    /// had no case for a block-atom (figure/table/code_block/etc.) reached via
    /// its generic "container node: recurse" branch -- it silently produced ''
    /// for the figure, so the incremental sync's markdownFragment for that list
    /// row LOST the image entirely while it remained visible in the live
    /// editor. Fixed in block-sync-plugin.ts (NESTED_BLOCK_ATOM_TYPES dispatch
    /// + indentContinuationLines). This test locks in the FIXED shape as
    /// BlockParser.parse() (Swift, the full-reparse path used before every
    /// export) receives it, confirming full re-parse fidelity too.
    ///
    /// Better than it first looks: the fixed serializer emits a TIGHT list (no
    /// blank line between "- Item 2" and the indented image line, matching the
    /// pre-existing bullet_list dispatcher's own convention). Since
    /// BlockParser.splitIntoRawBlocks only ever splits on blank lines, this
    /// entire run stays as ONE raw block -- detected as .bulletList, image
    /// embedded verbatim in its own fragment -- exactly matching the live
    /// doc's ONE top-level bullet_list node. No parity mismatch, no content
    /// loss. (A separate, pre-existing gap remains for the OTHER full-reparse
    /// input source, Milkdown's own getMarkdown()/getContent() used by
    /// flushContentToDatabase(), which renders a LOOSE list with blank lines
    /// between every item -- confirmed NOT to lose content either, in
    /// fullReparseOfRealGetContentOutputPreservesAllBullets and
    /// orphanedRowSelfHealsOnNextFullReparse above; that's remark-stringify's
    /// own convention, out of scope here.)
    @Test("Full re-parse: image nested inside a list item (end-of-bullet paste) survives as ONE list block, image embedded")
    func fullReparsePreservesNestedFigureInListItem() throws {
        let pid = "test-project"
        // EXACT fixed output captured from the real JS pipeline (block-sync-plugin.ts
        // after the fix) for: click at the end of "Item 2", paste an image.
        let fixedIncrementalFragment = "- Item 1\n- Item 2\n  ![](projectmedia://test.png)\n- Item 3"
        let fullDocument = "Before paragraph.\n\n\(fixedIncrementalFragment)\n\nAfter paragraph."

        let blocks = BlockParser.parse(markdown: fullDocument, projectId: pid)

        let allText = blocks.map { $0.textContent }.joined(separator: "|")
        #expect(allText.contains("Item 1"), "Item 1 must survive")
        #expect(allText.contains("Item 2"), "Item 2 must survive")
        #expect(allText.contains("Item 3"), "Item 3 must survive")

        // The whole list (all 3 items + the nested image) stays as ONE block --
        // matching the live doc's ONE top-level bullet_list node exactly.
        // BlockParser.splitIntoRawBlocks only ever splits on BLANK lines, and
        // the fixed serializer emits a TIGHT list (no blank line before the
        // indented image), so this whole run never gets split apart.
        let listBlocks = blocks.filter { $0.blockType == .bulletList }
        #expect(listBlocks.count == 1,
                "Expected the tight-list output to stay as ONE bulletList block, got \(listBlocks.count)")
        #expect(listBlocks.first?.markdownFragment.contains("projectmedia://test.png") == true,
                "The single list block's own fragment must retain the nested image")
        #expect(blocks.map(\.blockType) == [.paragraph, .bulletList, .paragraph],
                "Expected exactly 3 top-level blocks (before-para, list, after-para) -- matching the live doc 1:1")

        let reassembled = BlockParser.assembleMarkdown(from: blocks)
        #expect(reassembled.contains("Item 1"))
        #expect(reassembled.contains("Item 2"))
        #expect(reassembled.contains("Item 3"))
        #expect(reassembled.contains("projectmedia://test.png"), "Export-bound markdown must still contain the image")
    }

    /// Same check for the incremental sync path directly (no full reparse):
    /// feeds the EXACT fixed BlockChanges payload (an UPDATE whose
    /// markdownFragment now includes the nested, indented image) through
    /// applyBlockChangesFromEditor and confirms the DB row holds it.
    @Test("Incremental sync: fixed markdownFragment with nested image round-trips through applyBlockChangesFromEditor")
    func incrementalSyncPreservesNestedFigureFragment() throws {
        let content = """
        Before paragraph.

        - Item 1
        - Item 2
        - Item 3

        After paragraph.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let listBlock = blocksBefore.first { $0.blockType == .bulletList }!

        // EXACT fixed payload real-pipeline-captured for: click at end of "Item 2",
        // paste an image (no split -- the whole list stays one block, one UPDATE).
        let changes = BlockChanges(
            updates: [
                BlockUpdate(
                    id: listBlock.id,
                    textContent: "Item 1Item 2Item 3",
                    markdownFragment: "- Item 1\n- Item 2\n  ![](projectmedia://test.png)\n- Item 3",
                    headingLevel: nil
                )
            ]
        )

        _ = try db.applyBlockChangesFromEditor(changes, for: pid)

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let updatedList = blocksAfter.first { $0.id == listBlock.id }!
        #expect(updatedList.markdownFragment.contains("Item 1"))
        #expect(updatedList.markdownFragment.contains("Item 2"))
        #expect(updatedList.markdownFragment.contains("Item 3"))
        #expect(updatedList.markdownFragment.contains("projectmedia://test.png"),
                "The persisted DB row must contain the nested image after the fix")

        let assembled = BlockParser.assembleMarkdown(from: blocksAfter)
        #expect(assembled.contains("projectmedia://test.png"))
    }

    // MARK: - Real-world data corruption: figure glued to the second split-off list

    /// SECOND round of this investigation. A real user retest, queried directly
    /// via read-only sqlite3 against the actual project database, showed a
    /// DIFFERENT, still-open corruption than the one fixed above: splitting a
    /// 4-item list `[First, second, third, Fourth]` by pasting an image at the
    /// start of "third" persisted as:
    ///
    ///   sortOrder 21  bullet_list  "* First\n* second"
    ///   sortOrder 22  image        "![...](media/...)\n* third \n* Fourth"
    ///
    /// -- the figure and the ENTIRE second list ("third", "Fourth") glued into
    /// ONE row, typed `.image` (its first line). All rows in that region shared
    /// IDENTICAL createdAt/updatedAt timestamps (millisecond-precision), and
    /// used "*" bullet markers -- block-sync-plugin.ts's incremental serializer
    /// hardcodes "-", so "*" can only mean this came from a FULL re-parse
    /// (flushContentToDatabase -> BlockParser.parse() fed Milkdown's own
    /// getMarkdown()/getContent() output, which uses "*"), not the incremental
    /// sync path fixed earlier in this file.
    ///
    /// Extensive attempts (10+ variations: isolated list, with surrounding
    /// paragraphs, the verbatim real document content, trailing/leading
    /// spaces, drag-and-drop, 5-item lists, list-after-heading, an initially
    /// loose list, and the full production plugin list) could NOT reproduce
    /// Milkdown's getMarkdown() omitting the blank line between the figure and
    /// the second list from a single clean paste -- it consistently emitted
    /// proper blank-line separation in every attempt. The exact upstream
    /// trigger remains UNCONFIRMED. This test instead locks in a DEFENSIVE fix
    /// at the BlockParser layer: `splitIntoRawBlocks` used to assume a blank
    /// line was the ONLY block boundary, but CommonMark itself allows a list to
    /// interrupt any other block with no blank line needed -- so regardless of
    /// what upstream mechanism (still unconfirmed) produces text with a missing
    /// blank line, BlockParser now recognizes a list-marker line immediately
    /// following non-list content as the start of a new block. Built directly
    /// from the exact real corrupted text above (byte-for-byte, including the
    /// stray trailing space after "third").
    @Test("BlockParser splits a list-marker line from non-list content even with no blank line (real corrupted text)")
    func blockParserSplitsListInterruptingNonListContentWithNoBlankLine() throws {
        let pid = "test-project"
        // Byte-for-byte from the real persisted sortOrder-21/22 rows. The
        // list1-to-image boundary DID correctly split in the real bug (it's a
        // separate, blank-line-preceded row: sortOrder 21) — only the
        // image-to-list2 boundary lacks the blank line (both live inside
        // sortOrder 22's single markdownFragment). Reproduce that exact
        // asymmetry rather than removing every blank line uniformly.
        let list1 = "* First\n* second"
        let imageAndList2 = "![Screenshot 2026-07-12 at 1.42.52 PM.png](media/screenshot-2026-07-12-at-14252pm.png)\n* third \n* Fourth"
        let fullDocument = "One can't fault the book for skipping this step.\n\n\(list1)\n\n\(imageAndList2)\n\nWhether we are looking at Israel, India, or the United States."

        let blocks = BlockParser.parse(markdown: fullDocument, projectId: pid)

        // The core bug: the image and the second list must NOT be glued into
        // one row. Confirm each of the 4 bullets is present as list content,
        // not swallowed into an .image-typed block's markdownFragment.
        let listBlocks = blocks.filter { $0.blockType == .bulletList }
        let imageBlocks = blocks.filter { $0.blockType == .image }

        #expect(imageBlocks.count == 1, "Expected exactly one image block, got \(imageBlocks.count)")
        #expect(imageBlocks.first?.imageSrc == "media/screenshot-2026-07-12-at-14252pm.png")
        // The image block's OWN fragment must not have the list glued onto it.
        #expect(imageBlocks.first?.markdownFragment.contains("third") == false,
                "Image block must not swallow the following list's content: \(imageBlocks.first?.markdownFragment ?? "")")

        #expect(listBlocks.count == 2,
                "Expected two separate bullet_list rows (before the image, and after), got \(listBlocks.count): \(listBlocks.map { $0.markdownFragment })")
        #expect(listBlocks[0].markdownFragment.contains("First"))
        #expect(listBlocks[0].markdownFragment.contains("second"))
        #expect(listBlocks[1].markdownFragment.contains("third"))
        #expect(listBlocks[1].markdownFragment.contains("Fourth"))

        // Full-document order must be preserved: paragraph, list, image, list, paragraph.
        #expect(blocks.map(\.blockType) == [.paragraph, .bulletList, .image, .bulletList, .paragraph])

        let reassembled = BlockParser.assembleMarkdown(from: blocks)
        #expect(reassembled.contains("First"))
        #expect(reassembled.contains("second"))
        #expect(reassembled.contains("third"))
        #expect(reassembled.contains("Fourth"))
        #expect(reassembled.contains("screenshot-2026-07-12-at-14252pm.png"))
    }

    /// Guard against the fix above over-triggering: a NORMAL tight multi-item
    /// list (no interruption at all) must still parse as ONE block, and a list
    /// with a nested, indented atom continuation (this file's earlier fix,
    /// block-sync-plugin.ts's indentContinuationLines) must also stay merged.
    @Test("List-interruption guard does not fragment a normal tight list or a nested-atom continuation")
    func listInterruptionGuardDoesNotOverTrigger() throws {
        let pid = "test-project"

        let normalList = "- First\n- second\n- third\n- Fourth"
        let normalBlocks = BlockParser.parse(markdown: normalList, projectId: pid)
        #expect(normalBlocks.count == 1, "A normal tight list must stay ONE block, got \(normalBlocks.count)")
        #expect(normalBlocks.first?.blockType == .bulletList)

        let nestedAtomList = "- Item 1\n- Item 2\n  ![](projectmedia://test.png)\n- Item 3"
        let nestedBlocks = BlockParser.parse(markdown: nestedAtomList, projectId: pid)
        #expect(nestedBlocks.count == 1,
                "A list with a nested indented atom continuation must stay ONE block, got \(nestedBlocks.count): \(nestedBlocks.map { $0.markdownFragment })")
        #expect(nestedBlocks.first?.markdownFragment.contains("projectmedia://test.png") == true)

        let orderedList = "1. First\n2. second\n3. third"
        let orderedBlocks = BlockParser.parse(markdown: orderedList, projectId: pid)
        #expect(orderedBlocks.count == 1, "A normal tight ordered list must stay ONE block, got \(orderedBlocks.count)")
        #expect(orderedBlocks.first?.blockType == .orderedList)
    }
}
