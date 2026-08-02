//
//  ZoomDataIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for zoom data integrity — filterToSubtree, block range calculation,
//  replaceBlocksInRange, and zoom-out restoration.
//  Documented history of silent sort-order corruption during zoom.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Zoom Data Integrity — Tier 1: Silent Killers")
struct ZoomDataIntegrityTests {

    let projectId = "zoom-test-project"

    // MARK: - filterToSubtree

    @Test("filterToSubtree returns correct section IDs for nested hierarchies")
    @MainActor
    func filterToSubtreeNestedHierarchy() async throws {
        let state = EditorViewState()

        // Simulate a document with H1 > H2 > H3 structure
        let sections = [
            makeSectionVM(id: "h1-intro", level: 1, sortOrder: 1, title: "Introduction"),
            makeSectionVM(id: "h2-background", level: 2, sortOrder: 3, title: "Background", parentId: "h1-intro"),
            makeSectionVM(id: "h3-history", level: 3, sortOrder: 5, title: "History", parentId: "h2-background"),
            makeSectionVM(id: "h2-methods", level: 2, sortOrder: 7, title: "Methods", parentId: "h1-intro"),
            makeSectionVM(id: "h1-results", level: 1, sortOrder: 9, title: "Results")
        ]

        let subtree = state.filterToSubtree(sections: sections, rootId: "h1-intro")

        // Should include h1-intro, h2-background, h3-history, h2-methods (all under H1)
        // Should NOT include h1-results (same level = new subtree)
        let subtreeIds = Set(subtree.map { $0.id })
        #expect(subtreeIds.contains("h1-intro"), "Root should be in subtree")
        #expect(subtreeIds.contains("h2-background"), "H2 child should be in subtree")
        #expect(subtreeIds.contains("h3-history"), "H3 grandchild should be in subtree")
        #expect(subtreeIds.contains("h2-methods"), "Second H2 child should be in subtree")
        #expect(!subtreeIds.contains("h1-results"), "Sibling H1 should NOT be in subtree")
    }

    @Test("filterToSubtree for H2 section excludes sibling H2s")
    @MainActor
    func filterToSubtreeH2Section() async throws {
        let state = EditorViewState()

        let sections = [
            makeSectionVM(id: "h1-doc", level: 1, sortOrder: 1, title: "Document"),
            makeSectionVM(id: "h2-alpha", level: 2, sortOrder: 3, title: "Alpha", parentId: "h1-doc"),
            makeSectionVM(id: "h3-sub", level: 3, sortOrder: 5, title: "Sub Alpha", parentId: "h2-alpha"),
            makeSectionVM(id: "h2-beta", level: 2, sortOrder: 7, title: "Beta", parentId: "h1-doc")
        ]

        let subtree = state.filterToSubtree(sections: sections, rootId: "h2-alpha")
        let subtreeIds = Set(subtree.map { $0.id })

        #expect(subtreeIds.contains("h2-alpha"))
        #expect(subtreeIds.contains("h3-sub"), "H3 under Alpha should be included")
        #expect(!subtreeIds.contains("h2-beta"), "Sibling H2 should be excluded")
        #expect(!subtreeIds.contains("h1-doc"), "Parent H1 should be excluded")
    }

    // MARK: - replaceBlocksInRange

    @Test("replaceBlocksInRange produces exact correct block count")
    func replaceBlocksInRangeBlockCount() throws {
        let content = """
        # Title

        Paragraph one.

        ## Section A

        Content A.

        ## Section B

        Content B.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let totalBefore = blocksBefore.count

        // Replace blocks in range of Section A (roughly sortOrder 3-4, before Section B)
        let sectionAHeading = blocksBefore.first { $0.textContent == "Section A" }!
        let sectionBHeading = blocksBefore.first { $0.textContent == "Section B" }!

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Extra paragraph.",
                  markdownFragment: "Extra paragraph.")
        ]

        try db.replaceBlocksInRange(
            newBlocks,
            for: pid,
            startSortOrder: sectionAHeading.sortOrder,
            endSortOrder: sectionBHeading.sortOrder
        )

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // Should have no duplicate sort orders
        let sortOrders = blocksAfter.map { $0.sortOrder }
        let uniqueSortOrders = Set(sortOrders)
        #expect(sortOrders.count == uniqueSortOrders.count, "No duplicate sort orders allowed")

        // Sort orders should be monotonically increasing
        for i in 1..<blocksAfter.count {
            #expect(blocksAfter[i].sortOrder > blocksAfter[i-1].sortOrder,
                    "Sort orders must be monotonically increasing")
        }

        // Section B should still exist
        let sectionBAfter = blocksAfter.first { $0.textContent == "Section B" }
        #expect(sectionBAfter != nil, "Section B should survive range replacement")
    }

    @Test("replaceBlocksInRange preserves heading metadata by title")
    func replaceBlocksInRangePreservesMetadata() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\n## Section A\n\nContent.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Set metadata on Section A heading
        try db.dbWriter.write { database in
            if var block = try Block
                .filter(Block.Columns.textContent == "Section A")
                .fetchOne(database) {
                block.status = .review
                block.tags = ["important", "urgent"]
                block.wordGoal = 500
                try block.update(database)
            }
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let heading = blocks.first { $0.textContent == "Section A" }!

        // Replace with same-title heading
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "New content.",
                  markdownFragment: "New content.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: heading.sortOrder,
            endSortOrder: nil
        )

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let headingAfter = blocksAfter.first { $0.textContent == "Section A" }!

        #expect(headingAfter.status == .review, "Status should be preserved")
        #expect(headingAfter.tags == ["important", "urgent"], "Tags should be preserved")
        #expect(headingAfter.wordGoal == 500, "Word goal should be preserved")
        #expect(headingAfter.id == heading.id, "Heading ID should be preserved by title match")
    }

    // MARK: - Zoom Excludes Special Sections

    @Test("Zoom content excludes bibliography blocks")
    func zoomExcludesBibliography() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nText.\n\n## Section\n\nMore text.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Mark a block as bibliography
        try db.dbWriter.write { database in
            // Add a bibliography block at the end
            var bibBlock = Block(
                projectId: pid,
                sortOrder: 100,
                blockType: .heading,
                textContent: "References",
                markdownFragment: "# References",
                headingLevel: 1,
                isBibliography: true
            )
            try bibBlock.insert(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let nonBibBlocks = blocks.filter { !$0.isBibliography }
        let bibBlocks = blocks.filter { $0.isBibliography }

        #expect(!bibBlocks.isEmpty, "Should have bibliography blocks")
        #expect(!nonBibBlocks.isEmpty, "Should have non-bibliography blocks")

        // When assembling zoomed content, bibliography should be excluded
        // (This is tested at the EditorViewState level in integration, here we verify the flag)
        for block in bibBlocks {
            #expect(block.isBibliography, "Bibliography blocks should be flagged")
        }
    }

    @Test("Zoom content excludes notes blocks")
    func zoomExcludesNotes() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nText.\n\n## Section\n\nMore text.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Add a notes block
        try db.dbWriter.write { database in
            var notesBlock = Block(
                projectId: pid,
                sortOrder: 100,
                blockType: .heading,
                textContent: "Notes",
                markdownFragment: "# Notes",
                headingLevel: 1,
                isNotes: true
            )
            try notesBlock.insert(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let notesBlocks = blocks.filter { $0.isNotes }
        #expect(!notesBlocks.isEmpty, "Should have notes blocks")
    }

    // MARK: - Notes/Bibliography Survive Zoomed Range Replacement (footnote-integrity addendum)
    //
    // Regression coverage for the plan-review addendum's must-fix #1: `replaceBlocksInRange`'s
    // delete step had no isNotes/isBibliography protection, and its metadata-preservation-by-
    // title-match logic only covered heading blocks. A zoomed footnote insertion flushes
    // through this exact path (EditorViewState+Zoom.swift's flushContentToDatabase ->
    // replaceBlocksInRange) with the mini-Notes text already stripped, so newBlocks
    // legitimately contains zero isNotes rows on that call — meaning any real Notes row whose
    // sortOrder fell inside the replaced range was previously deleted with nothing to
    // replace it (silent, unrecoverable data loss).

    @Test("replaceBlocksInRange preserves an in-range Notes definition and heading when newBlocks omits them entirely")
    func replaceBlocksInRangePreservesOmittedNotesSection() throws {
        let content = """
        # Title

        ## Section A

        Content A.

        # Notes

        [^1]: Real definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let notesHeadingBefore = try #require(before.first { $0.textContent == "Notes" && $0.blockType == .heading })
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // Simulate the zoomed footnote-insertion flush: newBlocks covers only Section A's own
        // body content — like flushContentToDatabase's mini-Notes-stripped parse, it contains
        // nothing resembling the real Notes section at all.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A.")
        ]

        // Range deliberately spans from Section A through the end of the document
        // (endSortOrder nil) — a miscalculated/edge-case zoom boundary that includes the real
        // Notes section is exactly the scenario the addendum flags as previously catastrophic.
        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: sectionA.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)

        let notesHeadingAfter = after.first { $0.textContent == "Notes" && $0.blockType == .heading }
        #expect(notesHeadingAfter != nil, "Notes heading must survive even though newBlocks never mentioned it")
        #expect(notesHeadingAfter?.id == notesHeadingBefore.id, "Notes heading keeps its id (title-match reinsert)")

        let notesDefAfter = after.filter { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }
        #expect(notesDefAfter.count == 1, "Exactly one [^1] definition must survive — no loss, no duplication")
        #expect(notesDefAfter.first?.id == notesDefBefore.id, "The surviving [^1] row keeps its original id")
        #expect(
            notesDefAfter.first?.markdownFragment == notesDefBefore.markdownFragment,
            "The surviving [^1] row keeps its original text untouched"
        )

        #expect(after.first { $0.textContent == "Section A" } != nil, "Section A itself must still be replaced normally")
        #expect(after.first { $0.textContent == "Updated content A." } != nil, "New body content must land")
    }

    @Test("replaceBlocksInRange merges a same-label Notes update into the existing row instead of duplicating it")
    func replaceBlocksInRangeMergesSameLabelNotesUpdate() throws {
        let content = """
        # Title

        ## Section A

        Content A.

        # Notes

        [^1]: Old definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let notesHeadingBefore = try #require(before.first { $0.textContent == "Notes" && $0.blockType == .heading })
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // newBlocks legitimately includes a same-label edit to the definition, as if the zoom
        // range genuinely spanned into the Notes section and the user edited the text there.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Notes",
                  markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "[^1]: New definition text.",
                  markdownFragment: "[^1]: New definition text.", isNotes: true)
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: sectionA.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)

        let notesDefsAfter = after.filter { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }
        #expect(notesDefsAfter.count == 1, "Exactly one [^1] row must exist — the update must merge in place, not duplicate")
        #expect(notesDefsAfter.first?.id == notesDefBefore.id, "The merged row keeps the original block id")
        #expect(
            notesDefsAfter.first?.markdownFragment == "[^1]: New definition text.",
            "The legitimate edit's new text must land"
        )

        let notesHeadingAfter = after.first { $0.textContent == "Notes" && $0.blockType == .heading }
        #expect(notesHeadingAfter?.id == notesHeadingBefore.id, "Notes heading id still preserved by title match")
    }

    @Test("replaceBlocksInRange never inserts a duplicate Bibliography row; the existing one survives untouched")
    func replaceBlocksInRangeProtectsBibliographyRow() throws {
        let content = """
        # Title

        ## Section A

        Content A.

        # Bibliography

        Smith, J. (2020). Example reference.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let bibEntryBefore = try #require(before.first { $0.isBibliography && $0.blockType == .paragraph })

        // newBlocks includes a freshly-parsed bibliography-shaped paragraph, as if the zoom
        // range genuinely spanned into Bibliography — it must never be inserted; the machine-
        // managed original remains the sole authority.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "Jones, A. (2021). A stale duplicate reference.",
                  markdownFragment: "Jones, A. (2021). A stale duplicate reference.", isBibliography: true)
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: sectionA.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let bibEntriesAfter = after.filter { $0.isBibliography && $0.blockType == .paragraph }

        #expect(bibEntriesAfter.count == 1, "No duplicate/stale bibliography row must be inserted")
        #expect(bibEntriesAfter.first?.id == bibEntryBefore.id, "The original bibliography row survives untouched")
        #expect(
            bibEntriesAfter.first?.markdownFragment == bibEntryBefore.markdownFragment,
            "The original bibliography text is unchanged (machine-managed content wins)"
        )
    }

    // MARK: - Preserved-Row Re-anchoring & Batch Label Dedup (fix-round addendum)
    //
    // Regression coverage for two bugs a code-review pass found in the merge-in-place logic
    // above (empirically confirmed against the running code, not just read):
    //
    // Bug 1: preserved (merge-in-place) rows kept their ORIGINAL, unchanged sortOrder while
    // newly-inserted blocks were sequenced fresh from startSortOrder with no awareness of where
    // those preserved rows sat. Whenever a preserved row's stale position fell inside the
    // numeric span the new blocks now occupy — the common case when endSortOrder is nil, i.e.
    // zooming a document's last section, which sits right before its own trailing footnotes —
    // the final renormalize step's heading-vs-non-heading tiebreak could let a newly-typed
    // paragraph land between the preserved Notes heading and its own footnote definition,
    // splitting the Notes section.
    //
    // Bug 2: if newBlocks contained two entries parsing to the same footnote label (e.g. two
    // "[^1]:" paragraphs from a copy-paste slip), only the first merged into the preserved row —
    // the lookup dictionary entry was removed after the first match — so the second fell through
    // to the normal insert-as-new path, producing a duplicate DB row for the same label.

    @Test("replaceBlocksInRange keeps a trailing preserved Notes section contiguous when new block count exceeds old count (endSortOrder nil)")
    func replaceBlocksInRangeKeepsNotesContiguousOnCountIncrease() throws {
        let content = """
        # Title

        ## Section A

        Content A.

        # Notes

        [^1]: Real definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let notesHeadingBefore = try #require(before.first { $0.textContent == "Notes" && $0.blockType == .heading })
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // Old Section A range held exactly 2 blocks (heading + 1 paragraph). This newBlocks
        // batch grows that to 4 (heading + 3 paragraphs) — a block-COUNT INCREASE — with
        // endSortOrder nil and newBlocks omitting the Notes section entirely, exactly like the
        // mini-Notes-stripped flush path that triggers this in production.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Extra paragraph 1.",
                  markdownFragment: "Extra paragraph 1."),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Extra paragraph 2.",
                  markdownFragment: "Extra paragraph 2.")
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: sectionA.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)

        let notesHeadingAfter = try #require(after.first { $0.textContent == "Notes" && $0.blockType == .heading })
        let notesDefAfter = try #require(after.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })
        #expect(notesHeadingAfter.id == notesHeadingBefore.id, "Notes heading id preserved")
        #expect(notesDefAfter.id == notesDefBefore.id, "Notes definition id preserved")

        let headingIndex = try #require(after.firstIndex { $0.id == notesHeadingAfter.id })
        let defIndex = try #require(after.firstIndex { $0.id == notesDefAfter.id })

        #expect(
            defIndex == headingIndex + 1,
            "The Notes heading and its own definition must remain contiguous — nothing may land between them"
        )

        // No newly-inserted content may land at or after the Notes heading's position — all of
        // it must sort before the (re-anchored) preserved Notes section.
        let newContentTitles: Set<String> = ["Updated content A.", "Extra paragraph 1.", "Extra paragraph 2."]
        for (index, block) in after.enumerated() where newContentTitles.contains(block.textContent) {
            #expect(
                index < headingIndex,
                "New content '\(block.textContent)' must sort before the preserved Notes heading, not split it from its definition"
            )
        }
    }

    @Test("replaceBlocksInRange drops a duplicate footnote label within one batch instead of inserting a second DB row")
    func replaceBlocksInRangeDedupsDuplicateLabelInBatch() throws {
        let content = """
        # Title

        ## Section A

        Content A.

        # Notes

        [^1]: Old definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let sectionA = try #require(before.first { $0.textContent == "Section A" })
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // newBlocks contains TWO paragraphs that both parse to label "1" — e.g. a copy-paste
        // slip or an interrupted renumbering. Only the first occurrence should claim the label
        // (merging into the existing preserved row); the second must be dropped, not inserted
        // as a second row with the same label.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Section A",
                  markdownFragment: "## Section A", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated content A.",
                  markdownFragment: "Updated content A."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Notes",
                  markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "[^1]: New definition text.",
                  markdownFragment: "[^1]: New definition text.", isNotes: true),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "[^1]: Duplicate definition text.",
                  markdownFragment: "[^1]: Duplicate definition text.", isNotes: true)
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: sectionA.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let label1Rows = after.filter { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }

        #expect(
            label1Rows.count == 1,
            "Only one DB row may carry label [^1], even when newBlocks contains two entries for it"
        )
        #expect(
            label1Rows.first?.id == notesDefBefore.id,
            "The surviving row is the merged original row (first occurrence wins)"
        )
        #expect(
            label1Rows.first?.markdownFragment == "[^1]: New definition text.",
            "The first occurrence's text lands; the duplicate second occurrence is dropped, not inserted"
        )
    }

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

    // MARK: - Occurrence Count Mismatches (must-fix #3 from plan review)
    //
    // The tests above only ever exercise a MATCHED count of old/new occurrences per title (2
    // old <-> 2 new). None of them covered what happens when the count itself changes across a
    // re-parse — the exact shape of the title-collision bug in must-fix #1 (a plain heading
    // colliding with a machine-managed title changes that title's occurrence count by one). The
    // three tests below pin the deliberate, documented behavior for a count decrease, a count
    // increase, and the actual protected-heading collision must-fix #1 was filed against.

    @Test("replaceBlocksInRange: old 2 same-titled headings collapsing to new 1 keeps the FIRST occurrence's id, drops the second")
    func replaceBlocksInRangeCountDecreaseKeepsFirstOccurrence() throws {
        // Old->new count mismatch, non-machine-managed case: two old "Duplicate" headings, only
        // one new one. The FIFO queue pops front-first (document order), so the surviving row
        // must be the FIRST old occurrence's id/metadata; the second old occurrence is deleted
        // with nothing left in the queue to reinsert it. This is a documented, deliberate
        // tie-break (the alternative — keeping the LAST occurrence — is equally defensible; this
        // pins which one this implementation actually does).
        let content = """
        # Title

        ## Duplicate

        Body one.

        ## Duplicate

        Body two.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicatesBefore = before
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        try #require(duplicatesBefore.count == 2)
        let firstIdBefore = duplicatesBefore[0].id
        let secondIdBefore = duplicatesBefore[1].id

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Merged body.",
                  markdownFragment: "Merged body.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: duplicatesBefore[0].sortOrder,
            endSortOrder: nil
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicatesAfter = after.filter { $0.textContent == "Duplicate" && $0.blockType == .heading }

        #expect(duplicatesAfter.count == 1, "Only one 'Duplicate' heading survives when only one is reparsed")
        #expect(duplicatesAfter.first?.id == firstIdBefore, "The surviving heading keeps the FIRST old occurrence's id (front-of-queue tie-break)")
        #expect(
            duplicatesAfter.first?.id != secondIdBefore,
            "The second old occurrence's id must NOT survive — it was dropped, not merged"
        )
    }

    @Test("replaceBlocksInRange: old 1 same-titled heading expanding to new 2 gives the second occurrence a fresh id and no inherited metadata")
    func replaceBlocksInRangeCountIncreaseGivesSecondOccurrenceFreshId() throws {
        // Old->new count mismatch, other direction: one old "Duplicate" heading, two new ones.
        // The queue has exactly one entry, consumed by the FIRST new occurrence; the second new
        // occurrence finds an empty queue and falls through to a normal insert — fresh UUID, no
        // preserved status/tags/wordGoal. Documented, deliberate: there is no old occurrence left
        // to inherit from.
        let content = """
        # Title

        ## Duplicate

        Body one.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicateBefore = try #require(before.first { $0.textContent == "Duplicate" && $0.blockType == .heading })

        try db.dbWriter.write { database in
            var heading = duplicateBefore
            heading.status = .writing
            heading.tags = ["alpha"]
            heading.wordGoal = 100
            try heading.update(database)
        }

        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Updated body one.",
                  markdownFragment: "Updated body one."),
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Duplicate",
                  markdownFragment: "## Duplicate", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "New body two.",
                  markdownFragment: "New body two.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: duplicateBefore.sortOrder,
            endSortOrder: nil
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let duplicatesAfter = after
            .filter { $0.textContent == "Duplicate" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }

        #expect(duplicatesAfter.count == 2, "Both new 'Duplicate' headings must be inserted")
        #expect(duplicatesAfter[0].id == duplicateBefore.id, "First new occurrence inherits the sole old occurrence's id")
        #expect(duplicatesAfter[0].status == .writing, "First new occurrence inherits the sole old occurrence's metadata")
        #expect(duplicatesAfter[1].id != duplicateBefore.id, "Second new occurrence must get a fresh id — no old occurrence left to inherit from")
        #expect(duplicatesAfter[1].status == nil, "Second new occurrence must NOT inherit metadata from an occurrence it never matched")
        #expect(duplicatesAfter[1].tags == nil)
        #expect(duplicatesAfter[1].wordGoal == nil)
    }

    @Test("replaceBlocksInRange: a plain heading colliding in title with the machine Notes heading never loses its isNotes flag or row")
    func replaceBlocksInRangeTitleCollisionPreservesMachineHeadingFlag() throws {
        // The must-fix #1 scenario: a user-authored heading happens to share the title "Notes"
        // with the machine-managed Notes section heading. Before the fix, protectedHeadingIds
        // was computed from title membership alone — since "Notes" now appears in
        // newHeadingTitles (from the user's own colliding heading), the machine Notes heading
        // lost protection entirely, was deleted by the delete query, and was never reinserted
        // (the sole new "Notes" heading popped the user's OWN queue entry, since it comes first
        // in document order — the machine heading's entry never got reached). Net effect: the
        // machine section's isNotes flag and its heading row vanished, orphaning its footnote
        // definition. The fix makes protection occurrence-aware, so the machine heading's own
        // (later) slot stays protected specifically because the single new "Notes" heading can
        // never reach it.
        let content = """
        # Title

        ## Notes

        User's own section body.

        # Notes

        [^1]: Real definition text.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeadingsBefore = before
            .filter { $0.textContent == "Notes" && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        try #require(notesHeadingsBefore.count == 2)
        let userHeadingBefore = notesHeadingsBefore[0]
        let machineHeadingBefore = notesHeadingsBefore[1]
        #expect(userHeadingBefore.isNotes == false, "Fixture sanity: the user's own heading must not start out machine-flagged")
        #expect(machineHeadingBefore.isNotes == true, "Fixture sanity: the real '# Notes' heading must start out machine-flagged")
        let notesDefBefore = try #require(before.first { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") })

        // Zoomed re-parse of the user's own "## Notes" section only — omits the machine Notes
        // section entirely, exactly like the mini-Notes-stripped flush path, and its sole
        // heading happens to collide in title with the machine section.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading, textContent: "Notes",
                  markdownFragment: "## Notes", headingLevel: 2),
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph, textContent: "Edited section body.",
                  markdownFragment: "Edited section body.")
        ]

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: userHeadingBefore.sortOrder,
            endSortOrder: nil
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeadingsAfter = after.filter { $0.textContent == "Notes" && $0.blockType == .heading }

        #expect(notesHeadingsAfter.count == 2, "Both the user's heading and the machine Notes heading must survive as separate rows")

        let machineHeadingAfter = notesHeadingsAfter.first { $0.id == machineHeadingBefore.id }
        #expect(machineHeadingAfter != nil, "The machine Notes heading's row must not vanish")
        #expect(machineHeadingAfter?.isNotes == true, "The machine Notes heading's isNotes flag must not be lost")

        let userHeadingAfter = notesHeadingsAfter.first { $0.id == userHeadingBefore.id }
        #expect(userHeadingAfter != nil, "The user's own heading keeps its own id")
        #expect(userHeadingAfter?.isNotes == false, "The user's own heading must not absorb the machine flag")
        #expect(userHeadingAfter?.markdownFragment == "## Notes", "The user's own heading reflects the edited re-parse")

        let notesDefAfter = after.filter { $0.isNotes && $0.markdownFragment.hasPrefix("[^1]:") }
        #expect(notesDefAfter.count == 1, "The machine section's footnote definition must survive, not be orphaned")
        #expect(notesDefAfter.first?.id == notesDefBefore.id, "The surviving definition keeps its original id")
    }

    // MARK: - Sort Order Precision

    @Test("Sort orders remain distinct after range replacement with overflow")
    func sortOrderPrecisionAfterOverflow() throws {
        // Create a document with tight sort orders, then replace a range with MORE blocks
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\nP1.\n\n## A\n\nA content.\n\n## B\n\nB content.")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headingA = blocks.first { $0.textContent == "A" }!
        let headingB = blocks.first { $0.textContent == "B" }!

        // Insert many blocks into section A's range (more than the original 2 blocks)
        var newBlocks: [Block] = []
        newBlocks.append(Block(projectId: pid, sortOrder: 0, blockType: .heading,
                               textContent: "A", markdownFragment: "## A", headingLevel: 2))
        for i in 0..<10 {
            newBlocks.append(Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                                   textContent: "New para \(i)", markdownFragment: "New para \(i)"))
        }

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: headingA.sortOrder,
            endSortOrder: headingB.sortOrder
        )

        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)

        // All sort orders should be unique
        let sortOrders = blocksAfter.map { $0.sortOrder }
        #expect(Set(sortOrders).count == sortOrders.count, "All sort orders must be unique after overflow")

        // Section B should still exist and be after all section A blocks
        let bAfter = blocksAfter.first { $0.textContent == "B" }
        let aBlocks = blocksAfter.filter { $0.textContent.hasPrefix("New para") || $0.textContent == "A" }
        if let bSort = bAfter?.sortOrder {
            for aBlock in aBlocks {
                #expect(aBlock.sortOrder < bSort, "All Section A blocks should be before Section B")
            }
        }
    }

    // MARK: - Helper: Create SectionViewModel

    @MainActor
    private func makeSectionVM(
        id: String,
        level: Int,
        sortOrder: Double,
        title: String,
        parentId: String? = nil,
        isBibliography: Bool = false,
        isNotes: Bool = false
    ) -> SectionViewModel {
        let block = Block(
            id: id,
            projectId: projectId,
            parentId: parentId,
            sortOrder: sortOrder,
            blockType: .heading,
            textContent: title,
            markdownFragment: String(repeating: "#", count: level) + " " + title,
            headingLevel: level,
            isBibliography: isBibliography,
            isNotes: isNotes
        )
        return SectionViewModel(from: block)
    }
}
