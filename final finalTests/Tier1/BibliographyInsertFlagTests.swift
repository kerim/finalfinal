//
//  BibliographyInsertFlagTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for `resolveInsertPlacement`'s `isBibliography` containment rule (the
//  editor-diff insert path). Before this fix, EVERY editor-created block defaulted
//  `isBibliography = false` with no re-derivation — harmless for a block landing
//  inside ordinary body text, but for a block that (via a stale diff, a race, or any
//  other drift) actually lands inside the bibliography section, that block never gets
//  cleaned up: it survives every future regeneration as plain body text and gets
//  exported alongside the correctly-regenerated entry (duplicate citations in PDF
//  export). The containment rule (anchor AND next block both flagged) prevents the
//  ordinary, common case — a user typing a new trailing paragraph after the
//  bibliography, which BibliographySyncService always appends at the very end of the
//  document — from being misflagged `true`, which would be strictly worse: silently
//  dropped from every export and undeletable via the editor.
//

import Testing
import Foundation
@testable import final_final

@Suite("Bibliography Insert-Flag Containment — Tier 1: Silent Killers")
struct BibliographyInsertFlagTests {

    @Test("Insert anchored after the LAST bibliography entry is NOT flagged, and survives the export filter")
    func insertAfterLastBibliographyEntryIsNotFlagged() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }
        #expect(!bibBlocksBefore.isEmpty, "richTestContent must have a bibliography section for this test to be meaningful")
        let lastBibBlock = bibBlocksBefore.max { $0.sortOrder < $1.sortOrder }!

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-trailing",
                blockType: "paragraph",
                textContent: "A trailing note after the references.",
                markdownFragment: "A trailing note after the references.",
                headingLevel: nil,
                afterBlockId: lastBibBlock.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-trailing"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == false,
            """
            A paragraph anchored after the LAST bibliography block (no next block, or next \
            block unflagged) must never be flagged isBibliography — the ordinary case of a \
            user typing below the references
            """
        )

        // exportBlocks() is `blocks.filter { !$0.isBibliography }` (DocumentManager.swift) —
        // applying that same filter here proves this block would appear in every export,
        // not be silently dropped.
        let exportSurvivors = blocksAfter.filter { !$0.isBibliography }
        #expect(
            exportSurvivors.contains { $0.id == newId },
            "Trailing paragraph must survive the isBibliography export filter"
        )
    }

    @Test("Insert anchored mid-section, between two bibliography entries, IS flagged")
    func insertMidSectionBetweenEntriesIsFlagged() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        // richTestContent's References section is: heading, Carroll, Himmelmann, Smith, Wilkinson.
        // Anchor to Himmelmann (an entry, not the heading) so this exercises the
        // entry-to-entry case distinctly from the heading-fragment special case (tested
        // separately below).
        let himmelmann = try #require(
            bibBlocksBefore.first { $0.markdownFragment.contains("Himmelmann") },
            "richTestContent should contain a Himmelmann bibliography entry"
        )

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-mid",
                blockType: "paragraph",
                textContent: "Inserted mid-bibliography.",
                markdownFragment: "Inserted mid-bibliography.",
                headingLevel: nil,
                afterBlockId: himmelmann.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-mid"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == true,
            "An insert anchored between two flagged bibliography entries must itself be flagged — both anchor and next block are isBibliography == true"
        )
    }

    @Test("Non-bibliography heading inserted mid-section, between two bibliography entries, is NOT flagged")
    func nonBibliographyHeadingInsertMidSectionIsNotFlagged() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        // richTestContent's References section is: heading, Carroll, Himmelmann, Smith, Wilkinson.
        // Anchor to Himmelmann (an entry, not the heading) so both the anchor AND the next
        // block (Smith) are flagged — containment alone would resolve `true` here. The
        // suppression must override that.
        let himmelmann = try #require(
            bibBlocksBefore.first { $0.markdownFragment.contains("Himmelmann") },
            "richTestContent should contain a Himmelmann bibliography entry"
        )

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-discussion-heading",
                blockType: "heading",
                textContent: "Discussion",
                markdownFragment: "## Discussion",
                headingLevel: 2,
                afterBlockId: himmelmann.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-discussion-heading"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == false,
            """
            A non-bibliography-opening heading (e.g. "## Discussion") pasted between two \
            flagged bibliography entries must NOT inherit isBibliography from its \
            surroundings — containment alone would resolve true here (anchor and next block \
            both flagged), but the heading-insert suppression in resolveInsertPlacement must \
            force false, matching BlockParser.sectionFlagCarriedForward's rule that any \
            non-matching heading ends the section on a full reparse
            """
        )
    }

    @Test("Heading-fragment insert with no anchor at all is flagged regardless of placement")
    func headingFragmentInsertIsFlaggedRegardlessOfAnchor() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-heading",
                blockType: "heading",
                textContent: "References",
                markdownFragment: "# References",
                headingLevel: 1,
                afterBlockId: nil
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-heading"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == true,
            """
            A bibliography-opening heading fragment must be flagged even with no anchor \
            (falls through to the shared-counter placement, whose containment always \
            resolves false) — this is the independent heading-fragment special case, \
            OR'd with containment
            """
        )
    }

    @Test("Insert anchored where the anchor is flagged but the next block is explicitly unflagged is NOT flagged")
    func insertAnchorFlaggedNextBlockExplicitlyUnflaggedIsNotFlagged() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        let lastBibBlock = try #require(
            bibBlocksBefore.max { $0.sortOrder < $1.sortOrder },
            "richTestContent must have a bibliography section for this test to be meaningful"
        )

        // A non-bibliography block sitting immediately after the bibliography section —
        // the "next block present but explicitly unflagged" arm. richTestContent may or may
        // not already have trailing content; insert one explicitly so the arm is exercised
        // deterministically regardless of fixture content.
        let trailingId = "temp-trailing-anchor"
        let setupChanges = BlockChanges(inserts: [
            BlockInsert(
                tempId: trailingId,
                blockType: "paragraph",
                textContent: "Trailing unflagged paragraph.",
                markdownFragment: "Trailing unflagged paragraph.",
                headingLevel: nil,
                afterBlockId: lastBibBlock.id
            )
        ])
        let setupMapping = try db.applyBlockChangesFromEditor(setupChanges, for: pid)
        let trailingPermanentId = try #require(setupMapping[trailingId])
        let trailingBlock = try #require(try db.fetchBlock(id: trailingPermanentId))
        #expect(
            trailingBlock.isBibliography == false,
            "Setup precondition: the trailing anchor block must itself be unflagged"
        )

        // Now insert anchored to that same flagged lastBibBlock — its "next block" (by
        // sortOrder) is the trailing paragraph just inserted, which is present AND
        // explicitly unflagged. Containment (anchor flagged AND next flagged) must resolve
        // false here, distinctly from the next-block-nil arm tested above.
        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-anchor-flagged-next-unflagged",
                blockType: "paragraph",
                textContent: "Anchored to a flagged entry with an unflagged next block.",
                markdownFragment: "Anchored to a flagged entry with an unflagged next block.",
                headingLevel: nil,
                afterBlockId: lastBibBlock.id
            )
        ])
        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-anchor-flagged-next-unflagged"])

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == false,
            """
            Anchor flagged but next block present-and-explicitly-unflagged must resolve \
            isBibliography == false — containment requires BOTH anchor and next block \
            to be flagged, not just the anchor
            """
        )
    }
}
