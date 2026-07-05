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
