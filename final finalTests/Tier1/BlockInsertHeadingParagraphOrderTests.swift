//
//  BlockInsertHeadingParagraphOrderTests.swift
//  final finalTests
//
//  Regression suite for the "heading sorts after its own paragraph" export-order bug
//  (leading-block insert with no anchor falling into the append-at-end fallback).
//
//  Four scenarios, mirroring BlockInsertAnchorTests' pattern but targeting the specific
//  heading+paragraph-pair shape reported in the bug. Scenario D is the fix's regression
//  test (cross-cycle leading insert); A/B/C document related, unaffected paths.
//

import Testing
import Foundation
@testable import final_final

@Suite("Heading+paragraph insert order (export-order-bug regression suite)")
struct BlockInsertHeadingParagraphOrderTests {

    private func fixture() throws -> (ProjectDatabase, String, Block, Block) {
        let content = """
        # Doc

        Intro paragraph.

        ## Tail

        Tail paragraph.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let docHeading = TestFixtureFactory.headingBlocks(blocksBefore).first { $0.textContent == "Doc" }!
        let tailHeading = TestFixtureFactory.headingBlocks(blocksBefore).first { $0.textContent == "Tail" }!
        return (db, pid, docHeading, tailHeading)
    }

    // MARK: - Scenario A: doc-order array (heading entry precedes paragraph entry)
    // This is what the JS diff SHOULD produce (snapshotBlocks traverses doc.forEach,
    // so pendingInserts accumulates in document-position order). Control case:
    // does the 78275ce anchor-mapping fix actually cover a mixed-type pair, not just
    // same-type chains?

    @Test("A: heading-then-paragraph, doc-order array — expect correct order")
    func docOrderHeadingThenParagraph() throws {
        let (db, pid, docHeading, tailHeading) = try fixture()

        let changes = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-h", blockType: "heading", textContent: "Section A",
                        markdownFragment: "## Section A", headingLevel: 2, afterBlockId: docHeading.id),
            BlockInsert(tempId: "temp-p", blockType: "paragraph", textContent: "Section A body.",
                        markdownFragment: "Section A body.", headingLevel: nil, afterBlockId: "temp-h")
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        let headingSO = blocksAfter.first { $0.id == mapping["temp-h"]! }!.sortOrder
        let paragraphSO = blocksAfter.first { $0.id == mapping["temp-p"]! }!.sortOrder
        let docSO = blocksAfter.first { $0.id == docHeading.id }!.sortOrder
        let tailSO = blocksAfter.first { $0.id == tailHeading.id }!.sortOrder

        print("SCOUT-A doc=\(docSO) heading=\(headingSO) paragraph=\(paragraphSO) tail=\(tailSO)")

        #expect(headingSO < paragraphSO, "Heading must sort before its own paragraph")
        #expect(docSO < headingSO && paragraphSO < tailSO, "Both must land strictly between Doc and Tail")
    }

    // MARK: - Scenario B: out-of-order array (paragraph entry precedes heading entry)
    // Simulates a hypothesized JS-side ordering gap (e.g. cross-cycle pendingInserts
    // accumulation) where the paragraph's insert is processed by Swift BEFORE the
    // heading's, even though the paragraph's afterBlockId names the heading's temp id.

    @Test("B: paragraph-then-heading, OUT-OF-ORDER array — does idMapping resolve?")
    func outOfOrderParagraphBeforeHeading() throws {
        let (db, pid, docHeading, tailHeading) = try fixture()

        let changes = BlockChanges(inserts: [
            // Paragraph appears FIRST in the array, anchored to the heading's temp id,
            // even though the heading (temp-h) hasn't been processed/mapped yet.
            BlockInsert(tempId: "temp-p", blockType: "paragraph", textContent: "Section A body.",
                        markdownFragment: "Section A body.", headingLevel: nil, afterBlockId: "temp-h"),
            BlockInsert(tempId: "temp-h", blockType: "heading", textContent: "Section A",
                        markdownFragment: "## Section A", headingLevel: 2, afterBlockId: docHeading.id)
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        let headingSO = blocksAfter.first { $0.id == mapping["temp-h"]! }!.sortOrder
        let paragraphSO = blocksAfter.first { $0.id == mapping["temp-p"]! }!.sortOrder
        let docSO = blocksAfter.first { $0.id == docHeading.id }!.sortOrder
        let tailSO = blocksAfter.first { $0.id == tailHeading.id }!.sortOrder

        print("SCOUT-B doc=\(docSO) heading=\(headingSO) paragraph=\(paragraphSO) tail=\(tailSO)")

        // This is the assertion of interest — report actual pass/fail, don't just assume.
        #expect(headingSO < paragraphSO,
                "Heading should sort before its own paragraph even if the JS array presented them out of order")
    }

    // MARK: - Scenario C: leading section insert at document start (no anchor at all)
    // Matches docs/deferred/block-sync-robustness.md item 7: a block at doc position 0
    // gets NO afterBlockId from JS. New heading + its paragraph both inserted as a brand
    // new FIRST section of the document.

    @Test("C: new heading+paragraph inserted at document start (heading has no anchor)")
    func leadingSectionInsertAtDocumentStart() throws {
        let (db, pid, docHeading, tailHeading) = try fixture()

        let changes = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-h", blockType: "heading", textContent: "New First Section",
                        markdownFragment: "## New First Section", headingLevel: 2, afterBlockId: nil),
            BlockInsert(tempId: "temp-p", blockType: "paragraph", textContent: "New first body.",
                        markdownFragment: "New first body.", headingLevel: nil, afterBlockId: "temp-h")
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        let headingSO = blocksAfter.first { $0.id == mapping["temp-h"]! }!.sortOrder
        let paragraphSO = blocksAfter.first { $0.id == mapping["temp-p"]! }!.sortOrder
        let docSO = blocksAfter.first { $0.id == docHeading.id }!.sortOrder
        let tailSO = blocksAfter.first { $0.id == tailHeading.id }!.sortOrder

        print("SCOUT-C doc=\(docSO) heading=\(headingSO) paragraph=\(paragraphSO) tail=\(tailSO)")

        // Relative order between the new pair should still hold...
        #expect(headingSO < paragraphSO, "New heading must sort before its own new paragraph")
        // ...but per item 7, expect them to land at the END of the doc, NOT the start
        // (documenting the known-but-separate leading-insert placement bug).
        #expect(headingSO > tailSO, "Known bug (item 7): leading insert with no anchor falls back to append-at-end, not start")
    }

    // MARK: - Scenario D: cross-cycle leading insert — heading lands AFTER its own paragraph
    //
    // Reproduces the reported export-order bug directly (not just "teleported past Tail"
    // like Scenario C): a paragraph typed FIRST becomes the document's current highest
    // sortOrder. The user then goes back and adds a heading BEFORE it. Because that
    // heading is genuinely the ProseMirror doc's position-0 block, block-sync-plugin.ts's
    // detectChanges (~line 729-737) never assigns it an afterBlockId at all (the `i > 0`
    // guard). Swift's insert branch (Database+Blocks.swift ~408-411) then falls back to
    // the shared `nextSortOrder` counter, which is seeded from MAX(sortOrder) at the START
    // of ITS OWN transaction — i.e. AFTER the paragraph's insert already committed in an
    // earlier, separate poll cycle. The heading is placed immediately after the paragraph
    // it was meant to introduce.
    //
    // This is deliberately modeled as TWO SEPARATE applyBlockChangesFromEditor calls
    // (two poll cycles), not one batch — see the comment inline for why a single batch
    // does NOT reproduce this (the shared in-batch counter assigns position-order-correct
    // values to same-batch nil-anchor inserts).

    @Test("D: paragraph committed in an earlier cycle, then a leading heading in a later cycle — heading lands AFTER paragraph")
    func crossCycleLeadingHeadingLandsAfterOwnParagraph() throws {
        // Minimal document: a single existing section, no other content, so the new
        // paragraph naturally becomes (and stays) the document's highest sortOrder.
        let content = "Existing paragraph."
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingParagraph = try TestFixtureFactory.fetchBlocks(from: db).first!

        // Cycle 1 (earlier poll): user types a brand-new paragraph at the very end of
        // the document (a real, resolvable anchor — nothing unusual about this insert).
        let cycle1 = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-p", blockType: "paragraph", textContent: "New body paragraph.",
                        markdownFragment: "New body paragraph.", headingLevel: nil,
                        afterBlockId: existingParagraph.id)
        ])
        let mapping1 = try db.applyBlockChangesFromEditor(cycle1, for: pid)
        let paragraphId = mapping1["temp-p"]!
        let paragraphSO = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == paragraphId }!.sortOrder

        // Cycle 2 (later, separate poll — the paragraph above is now a committed,
        // permanent-id row): user goes back to the very start of the new paragraph and
        // prepends a heading for it. From the JS doc's perspective this heading is at
        // position 0 (nothing precedes it), so detectChanges emits afterBlockId: nil.
        let cycle2 = BlockChanges(inserts: [
            BlockInsert(tempId: "temp-h", blockType: "heading", textContent: "New Section",
                        markdownFragment: "## New Section", headingLevel: 2, afterBlockId: nil,
                        atDocumentStart: true)
        ])
        let mapping2 = try db.applyBlockChangesFromEditor(cycle2, for: pid)
        let headingId = mapping2["temp-h"]!
        let headingSO = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == headingId }!.sortOrder

        print("SCOUT-D existing=\(existingParagraph.sortOrder) paragraph=\(paragraphSO) heading(no-anchor,later-cycle)=\(headingSO)")

        // This is the actual reported bug, reproduced end to end: the heading a user
        // just wrote to introduce "New body paragraph." sorts AFTER it, not before.
        #expect(headingSO < paragraphSO,
                "regression: heading with no cross-cycle anchor must land before its own paragraph (heading=\(headingSO), paragraph=\(paragraphSO)) — otherwise export would show the paragraph before its own heading")
    }
}
