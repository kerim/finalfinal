//
//  BlockInsertAnchorTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for `applyBlockChangesFromEditor`'s insert-anchor resolution. Before
//  this fix, an insert anchored to another insert's temp id from the SAME
//  batch would fail the `Block.fetchOne` lookup (the temp id has no row yet)
//  and silently fall back to append-at-end — scattering new content to the
//  bottom of the document instead of the intended position.
//

import Testing
import Foundation
@testable import final_final

@Suite("Block Insert Anchor Resolution — Tier 1: Silent Killers")
struct BlockInsertAnchorTests {

    @Test("Chained same-batch inserts land contiguously at the anchor point, not appended at the end")
    func chainedSameBatchInsertsLandContiguously() throws {
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
        let introParagraph = blocksBefore.first { $0.textContent == "Intro paragraph." }!

        // Three inserts in array order, each anchored to the previous insert's temp id —
        // mirrors the JS diff's ascending-document-offset ordering that guarantees an
        // earlier array entry's temp id is already in idMapping by the time a later
        // entry references it.
        let changes = BlockChanges(
            inserts: [
                BlockInsert(
                    tempId: "temp-a",
                    blockType: "heading",
                    textContent: "Section A",
                    markdownFragment: "## Section A",
                    headingLevel: 2,
                    afterBlockId: docHeading.id
                ),
                BlockInsert(
                    tempId: "temp-b",
                    blockType: "heading",
                    textContent: "Section B",
                    markdownFragment: "## Section B",
                    headingLevel: 2,
                    afterBlockId: "temp-a"
                ),
                BlockInsert(
                    tempId: "temp-c",
                    blockType: "heading",
                    textContent: "Section C",
                    markdownFragment: "## Section C",
                    headingLevel: 2,
                    afterBlockId: "temp-b"
                )
            ]
        )

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)

        #expect(mapping["temp-a"] != nil, "temp-a should be mapped to a permanent id")
        #expect(mapping["temp-b"] != nil, "temp-b should be mapped to a permanent id")
        #expect(mapping["temp-c"] != nil, "temp-c should be mapped to a permanent id")

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = TestFixtureFactory.headingBlocks(blocksAfter)
        let titles = headingsAfter.map { $0.textContent }

        #expect(titles == ["Doc", "Section A", "Section B", "Section C", "Tail"],
                "Chained inserts should land contiguously right after their anchor, not appended at the end")

        // All three new headings' sort orders must fall strictly between Doc and Tail.
        let docSortOrder = blocksAfter.first { $0.id == docHeading.id }!.sortOrder
        let tailSortOrder = blocksAfter.first { $0.id == tailHeading.id }!.sortOrder
        for tempId in ["temp-a", "temp-b", "temp-c"] {
            let permanentId = mapping[tempId]!
            let sortOrder = blocksAfter.first { $0.id == permanentId }!.sortOrder
            #expect(sortOrder > docSortOrder && sortOrder < tailSortOrder,
                    "\(tempId) should sort strictly between Doc and Tail")
        }

        // Full-document sortOrder must remain strictly monotonic.
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i - 1].sortOrder,
                    "Sort orders must increase: block[\(i - 1)]=\(blocksAfter[i - 1].sortOrder), block[\(i)]=\(blocksAfter[i].sortOrder)")
        }

        // Bonus: a single insert anchored to a real permanent id (not a temp id) must
        // still resolve correctly — the `idMapping[$0] ?? $0` fallthrough shouldn't
        // regress the pre-existing, already-working behavior.
        let secondChanges = BlockChanges(
            inserts: [
                BlockInsert(
                    tempId: "temp-d",
                    blockType: "paragraph",
                    textContent: "Second paragraph.",
                    markdownFragment: "Second paragraph.",
                    headingLevel: nil,
                    afterBlockId: introParagraph.id
                )
            ]
        )

        let secondMapping = try db.applyBlockChangesFromEditor(secondChanges, for: pid)
        #expect(secondMapping["temp-d"] != nil)

        let blocksFinal = try TestFixtureFactory.fetchBlocks(from: db)
        let introIndex = blocksFinal.firstIndex { $0.id == introParagraph.id }!
        let newParagraphId = secondMapping["temp-d"]!
        let newParagraphIndex = blocksFinal.firstIndex { $0.id == newParagraphId }!

        #expect(newParagraphIndex == introIndex + 1,
                "Insert anchored to a real permanent id should land immediately after it")
    }

    @Test("Insert anchored to a since-deleted row is rejected, not appended at document end")
    func staleAnchorInsertIsRejected() throws {
        // t-3904c457: a background poll's diff can straddle a structural rewrite
        // (the mode-toggle's `replaceBlocks` deletes and re-creates every row). The
        // straddling insert then anchors to a row that no longer exists. Before the
        // guard, it fell through to the shared counter and materialized a duplicate
        // row with a brand-new id at document end — the flaky-suite corruption
        // signature. It must be rejected outright instead.
        let content = """
        # Doc

        Intro paragraph.

        Closing paragraph.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let introParagraph = blocksBefore.first { $0.textContent == "Intro paragraph." }!

        // Simulate the structural rewrite landing first: the anchor row is deleted.
        _ = try db.applyBlockChangesFromEditor(
            BlockChanges(deletes: [introParagraph.id]), for: pid
        )
        let blocksAfterDelete = try TestFixtureFactory.fetchBlocks(from: db)

        // Now the stale snapshot's insert arrives, anchored to the deleted row.
        let mapping = try db.applyBlockChangesFromEditor(
            BlockChanges(inserts: [
                BlockInsert(
                    tempId: "temp-stale",
                    blockType: "paragraph",
                    textContent: "Straddling paragraph.",
                    markdownFragment: "Straddling paragraph.",
                    headingLevel: nil,
                    afterBlockId: introParagraph.id
                )
            ]),
            for: pid
        )

        #expect(mapping["temp-stale"] == nil,
                "A stale-anchored insert must not be assigned a permanent id")

        let blocksFinal = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(blocksFinal.count == blocksAfterDelete.count,
                "A stale-anchored insert must not add a row anywhere, least of all at document end")
        #expect(!blocksFinal.contains { $0.textContent == "Straddling paragraph." },
                "The stale fragment's content must not appear in the database")
    }
}
