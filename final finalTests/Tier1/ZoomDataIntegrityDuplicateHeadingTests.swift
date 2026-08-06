//
//  ZoomDataIntegrityDuplicateHeadingTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Split out of ZoomDataIntegrityTests.swift to stay under SwiftLint's
//  type_body_length / file_length caps — same suite, same test names/counts,
//  just a second file.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ZoomDataIntegrityTests {

    // MARK: - Duplicate-Titled Headings (FIFO occurrence-index matching)
    //
    // Regression coverage for the heading-id-churn bug on the zoomed-CodeMirror path:
    // `replaceBlocksInRange` had the identical bug as `replaceBlocks` — a title -> single-id
    // dictionary (first-match-wins, in-file comment: "preserves zoomedSectionId across
    // re-parses") plus a separate title -> single-metadata dictionary (last-match-wins). A
    // second heading sharing a title got a fresh id (and thus a churned zoomedSectionId) on
    // every zoomed flush, and metadata could cross-contaminate onto the wrong occurrence. The
    // fix consolidates both into one title -> FIFO queue of (id, metadata), consumed in document
    // order.

    @Test("replaceBlocksInRange preserves both occurrences' IDs when two headings share a title")
    func replaceBlocksInRangePreservesDuplicateTitleIDs() throws {
        let content = """
        # Doc

        ## Duplicate

        First occurrence body.

        ## Duplicate

        Second occurrence body.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsBefore = blocksBefore
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(duplicateHeadingsBefore.count == 2)
        let firstIdBefore = duplicateHeadingsBefore[0].id
        let secondIdBefore = duplicateHeadingsBefore[1].id
        #expect(firstIdBefore != secondIdBefore)

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated first body.",
                  markdownFragment: "Updated first body."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated second body.",
                  markdownFragment: "Updated second body.")
        ]

        // Zoom range covers both Duplicate sections (starting at the first Duplicate heading
        // itself), matching how a zoomed-in CodeMirror re-parse would flush its subtree.
        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: duplicateHeadingsBefore[0].sortOrder,
            endSortOrder: nil
        )

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsAfter = blocksAfter
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(duplicateHeadingsAfter.count == 2)
        #expect(duplicateHeadingsAfter[0].id == firstIdBefore, "First occurrence keeps its own id (and thus its zoomedSectionId identity)")
        #expect(duplicateHeadingsAfter[1].id == secondIdBefore, "Second occurrence keeps its own id — previously churned on every zoomed flush")
    }

    @Test("replaceBlocksInRange pairs metadata and isNotes/isBibliography flags to the matching occurrence only")
    func replaceBlocksInRangePairsMetadataToMatchingOccurrence() throws {
        let content = """
        # Doc

        ## Duplicate

        First occurrence body.

        ## Duplicate

        Second occurrence body.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let firstDuplicateSortOrderBefore = try #require(
            blocksBefore.filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
                .sorted { $0.sortOrder < $1.sortOrder }
                .first?.sortOrder
        )

        // Give each occurrence distinct, identifiable metadata — including isNotes, set on only
        // the FIRST occurrence, to explicitly verify machine-managed flags land on exactly the
        // right row and don't ride a last-write-wins dictionary onto the wrong one.
        try db.dbWriter.write { database in
            let headings = try Block
                .filter(Block.Columns.textContent == "Duplicate")
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
            try #require(headings.count == 2)

            var first = headings[0]
            first.status = .writing
            first.tags = ["alpha"]
            first.wordGoal = 100
            first.isNotes = true
            try first.update(database)

            var second = headings[1]
            second.status = .final_
            second.tags = ["beta"]
            second.wordGoal = 200
            second.isNotes = false
            try second.update(database)
        }

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated first body.",
                  markdownFragment: "Updated first body."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated second body.",
                  markdownFragment: "Updated second body.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: firstDuplicateSortOrderBefore,
            endSortOrder: nil
        )

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsAfter = blocksAfter
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(duplicateHeadingsAfter.count == 2)
        #expect(duplicateHeadingsAfter[0].status == .writing, "First occurrence keeps its OWN status (last-write-wins would put .final_ here)")
        #expect(duplicateHeadingsAfter[0].tags == ["alpha"])
        #expect(duplicateHeadingsAfter[0].wordGoal == 100)
        #expect(duplicateHeadingsAfter[0].isNotes == true, "isNotes must land on the occurrence that actually had it")
        #expect(duplicateHeadingsAfter[1].status == .final_, "Second occurrence keeps its own status")
        #expect(duplicateHeadingsAfter[1].tags == ["beta"])
        #expect(duplicateHeadingsAfter[1].wordGoal == 200)
        #expect(duplicateHeadingsAfter[1].isNotes == false, "isNotes must NOT bleed onto the occurrence that never had it")
    }

    @Test("replaceBlocksInRange keeps duplicate-titled headings paired alongside a protected Notes section")
    func replaceBlocksInRangeDuplicateTitlesWithProtectedNotesSection() throws {
        // Must-fix #1 from plan review, co-existence half: a disjoint-titled protected Notes
        // heading (its title is wholly absent from newBlocks, so every one of its occurrences is
        // beyond newHeadingCountByTitle for "Notes") must ride alongside an UNRELATED duplicate
        // title's FIFO queue without the two interfering — the "Duplicate" queue must still pair
        // by occurrence index, and the protected "Notes" heading must never be deleted or
        // reinserted through that queue at all. This does NOT cover a title COLLISION between a
        // plain heading and the protected heading itself (same title, count mismatch) — that is
        // the actual scenario must-fix #1 was filed against, and it is covered separately by
        // replaceBlocksInRangeTitleCollisionPreservesMachineHeadingFlag below, which asserts the
        // machine heading's id, isNotes flag, and row survival directly.
        let content = """
        # Title

        ## Duplicate

        Body one.

        ## Duplicate

        Body two.

        # Notes

        [^1]: Real definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateHeadingsBefore = before
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(duplicateHeadingsBefore.count == 2)
        let firstIdBefore = duplicateHeadingsBefore[0].id
        let secondIdBefore = duplicateHeadingsBefore[1].id
        let notesHeadingBefore = try #require(before.first { $0.textContent == "Notes" && $0.blockType == .heading })
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // Simulate the zoomed footnote-insertion flush: newBlocks covers only the two Duplicate
        // sections' own body content, omitting the real Notes section entirely (like
        // flushContentToDatabase's mini-Notes-stripped parse) — so "Notes" is NOT in
        // newHeadingTitles and its heading must be protected from deletion, while "Duplicate"'s
        // two occurrences must still be correctly paired by occurrence index.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated body one.",
                  markdownFragment: "Updated body one."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated body two.",
                  markdownFragment: "Updated body two.")
        ]

        // Range spans from the first Duplicate heading through the end of the document
        // (endSortOrder nil), the same edge-case boundary the addendum flags as previously
        // catastrophic for the real Notes section.
        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: duplicateHeadingsBefore[0].sortOrder,
            endSortOrder: nil
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)

        let duplicateHeadingsAfter = after
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(duplicateHeadingsAfter.count == 2, "Both Duplicate occurrences must survive")
        #expect(duplicateHeadingsAfter[0].id == firstIdBefore, "First Duplicate occurrence keeps its own id")
        #expect(
            duplicateHeadingsAfter[1].id == secondIdBefore,
            "Second Duplicate occurrence keeps its own id — not swapped with the first, not stolen by the Notes heading's queue"
        )

        let notesHeadingAfter = after.first { $0.textContent == "Notes" && $0.blockType == .heading }
        #expect(notesHeadingAfter != nil, "Protected Notes heading must survive untouched even with unrelated duplicate titles in the same batch")
        #expect(notesHeadingAfter?.id == notesHeadingBefore.id, "Notes heading id is completely unaffected by the Duplicate title's queue")

        let notesDefAfter = after.filter { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }
        #expect(notesDefAfter.count == 1, "Exactly one Notes definition must survive")
        #expect(notesDefAfter.first?.id == notesDefBefore.id, "The surviving Notes definition keeps its original id")
        #expect(
            notesDefAfter.first?.markdownFragment == notesDefBefore.markdownFragment,
            "The surviving Notes definition text is untouched"
        )
    }
}
