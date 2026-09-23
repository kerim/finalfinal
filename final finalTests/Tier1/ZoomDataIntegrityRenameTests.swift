//
//  ZoomDataIntegrityRenameTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Regression tests for the rename-while-zoomed data-loss bug: renaming a zoomed section's
//  root heading used to churn its id (title-based matching only), which corrupted the
//  position-paired `SectionSyncService.zoomedExistingSections` lookup and emptied the sidebar,
//  and could silently wipe the rest of the document on the next edit. Covers Step 1 of the
//  fix -- `replaceBlocksInRange`'s new `anchorHeadingId` parameter and the
//  `resolveAnchorHeading` position-based match it uses (Database+BlocksReplace.swift,
//  Database+BlocksReplace+Preservation.swift).
//
//  Extended as `extension ZoomDataIntegrityTests` to reuse its `makeSectionVM` helper and
//  suite context (see that file for the general zoom-integrity coverage this builds on).
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ZoomDataIntegrityTests {

    // MARK: - Rename-while-zoomed anchor fixture
    // `# Doc / ## Alpha / Body. / ### Child / Child body. / ## Beta / Beta body.`
    // Zoom range under test: Alpha through end-of-Alpha's-subtree (up to Beta).

    fileprivate static let renameFixtureMarkdown = """
    # Doc

    ## Alpha

    Body.

    ### Child

    Child body.

    ## Beta

    Beta body.
    """

    fileprivate struct RenameFixture {
        let db: ProjectDatabase
        let pid: String
        let alphaId: String
        let childId: String
        let betaId: String
    }

    fileprivate func makeRenameFixture() throws -> RenameFixture {
        let db = try TestFixtureFactory.createTemporary(content: Self.renameFixtureMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        return RenameFixture(
            db: db,
            pid: pid,
            alphaId: blocks.first { $0.textContent == "Alpha" }!.id,
            childId: blocks.first { $0.textContent == "Child" }!.id,
            betaId: blocks.first { $0.textContent == "Beta" }!.id
        )
    }

    /// Parses a range's replacement markdown the same way a zoomed flush does -- fresh
    /// parser-generated ids, no knowledge of what's already in the DB.
    fileprivate func parseRange(_ markdown: String, pid: String) -> [Block] {
        BlockParser.parse(markdown: markdown, projectId: pid)
    }

    // MARK: - 1. Anchor keeps root id + metadata on rename

    @Test("anchor keeps the zoom root's id and metadata when its heading is renamed")
    func anchorKeepsRootIdAndMetadataOnRename() throws {
        let fixture = try makeRenameFixture()
        try fixture.db.dbWriter.write { database in
            var block = try Block.fetchOne(database, key: fixture.alphaId)!
            block.status = .review
            block.tags = ["important", "urgent"]
            try block.update(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        let renamedMarkdown = """
        ## Alpha Renamed

        Body.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(renamedMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let renamedHeading = after.first { $0.textContent == "Alpha Renamed" }
        #expect(renamedHeading?.id == fixture.alphaId, "anchor should keep the original id across a rename")
        #expect(renamedHeading?.status == .review, "anchor should keep preserved status")
        #expect(renamedHeading?.tags == ["important", "urgent"], "anchor should keep preserved tags")
        let childAfter = after.first { $0.textContent == "Child" }
        #expect(childAfter?.id == fixture.childId, "Child's own id should be untouched")
    }

    @Test("without an anchor, a rename does NOT keep the old id -- proves the anchor test above is meaningful")
    func renameWithoutAnchorDoesNotKeepId() throws {
        let fixture = try makeRenameFixture()
        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        let renamedMarkdown = """
        ## Alpha Renamed

        Body.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(renamedMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: nil
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let renamedHeading = after.first { $0.textContent == "Alpha Renamed" }
        #expect(
            renamedHeading?.id != fixture.alphaId,
            "a title-only match must not keep the old id across a rename -- this is the original bug"
        )
    }

    // MARK: - 2. Anchor rename to child's title does not steal the child's id

    @Test("anchor rename to the child's own title does not steal the child's id")
    func anchorRenameToChildTitleDoesNotStealChildId() throws {
        let fixture = try makeRenameFixture()
        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        // Root renamed to "Child" (matching the real child's title), same level -- both
        // headings named "Child" appear in the new range.
        let renamedMarkdown = """
        ## Child

        Body.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(renamedMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let childTitled = after.filter { $0.textContent == "Child" }
        #expect(childTitled.count == 2, "both the renamed root and the real child should survive as two rows")
        let ids = Set(childTitled.map { $0.id })
        #expect(ids.contains(fixture.alphaId), "the renamed root should keep its own id")
        #expect(ids.contains(fixture.childId), "the real child should keep its own id")
        #expect(ids.count == 2, "no id collision/swap between the two same-titled headings")
    }

    // MARK: - 3. Anchor rename + demotion to a genuinely new title keeps metadata

    @Test("anchor rename and demotion to a genuinely new title keeps metadata (relaxed guard)")
    func anchorRenameAndDemoteToNewTitleKeepsMetadata() throws {
        let fixture = try makeRenameFixture()
        try fixture.db.dbWriter.write { database in
            var block = try Block.fetchOne(database, key: fixture.alphaId)!
            block.status = .writing
            try block.update(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        // `## Alpha` -> `### Alpha New`: demotion (level 2 -> 3) AND a genuinely new title that
        // collides with no other existing heading -- the relaxed guard's binding case.
        let renamedMarkdown = """
        ### Alpha New

        Body.

        #### Child

        Child body.
        """
        let newBlocks = parseRange(renamedMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let renamedHeading = after.first { $0.textContent == "Alpha New" }
        #expect(renamedHeading?.id == fixture.alphaId, "demotion to a new, non-colliding title should still bind")
        #expect(renamedHeading?.status == .writing, "metadata should be kept for the relaxed-guard case")
    }

    // MARK: - 4. Anchor declines when the root heading line is removed entirely

    @Test("anchor declines when the root heading line is removed entirely")
    func anchorDeclinesWhenRootHeadingLineRemoved() throws {
        let fixture = try makeRenameFixture()
        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        // First block is a paragraph, not a heading -- the root heading line was deleted.
        let newMarkdown = """
        Body without a heading line.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(newMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        #expect(after.first(where: { $0.id == fixture.alphaId }) == nil, "alphaId should no longer exist in the DB")
        let childAfter = after.first { $0.textContent == "Child" }
        #expect(childAfter?.id == fixture.childId, "Child should keep its own id via the title queue")
    }

    // MARK: - 5. Anchor declines for a Notes or Bibliography anchor row

    @Test("resolveAnchorHeading declines when the anchor row is isNotes or isBibliography")
    func anchorDeclinesForNotesOrBibliographyAnchor() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Doc\n\n## Alpha\n\nBody.")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        var alpha = try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent == "Alpha" }!

        let newHeading = Block(
            projectId: pid, sortOrder: 0, blockType: .heading,
            textContent: "Alpha Renamed", markdownFragment: "## Alpha Renamed", headingLevel: 2
        )

        alpha.isNotes = true
        #expect(
            db.resolveAnchorHeading(existing: [alpha], newBlocks: [newHeading], anchorId: alpha.id) == nil,
            "an isNotes anchor row must decline, matching the anchorHeadingId: nil baseline"
        )

        alpha.isNotes = false
        alpha.isBibliography = true
        #expect(
            db.resolveAnchorHeading(existing: [alpha], newBlocks: [newHeading], anchorId: alpha.id) == nil,
            "an isBibliography anchor row must decline, matching the anchorHeadingId: nil baseline"
        )
    }

    // MARK: - 6. Renaming the root to "Notes" does not disturb the real, machine-managed Notes

    @Test("renaming the zoom root to a plain heading titled \"Notes\" does not disturb the real machine-managed Notes section")
    func renameRootToNotesDoesNotDisturbMachineNotes() throws {
        let markdown = """
        # Doc

        ## Alpha

        Body.

        ### Child

        Child body.

        ## Beta

        Beta body.
        """
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let alphaId = blocks.first { $0.textContent == "Alpha" }!.id
        let betaId = blocks.first { $0.textContent == "Beta" }!.id

        // Add a real, machine-managed "Notes" heading + definition beyond the zoom range.
        var realNotesId = ""
        try db.dbWriter.write { database in
            var notesHeading = Block(
                projectId: pid, sortOrder: 1000, blockType: .heading,
                textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true
            )
            try notesHeading.insert(database)
            realNotesId = notesHeading.id
            var def = Block(
                projectId: pid, sortOrder: 1001, blockType: .paragraph,
                textContent: "[^1]: A footnote.", markdownFragment: "[^1]: A footnote.", isNotes: true
            )
            try def.insert(database)
        }

        let afterSetup = try TestFixtureFactory.fetchBlocks(from: db)
        let alpha = afterSetup.first { $0.id == alphaId }!
        let beta = afterSetup.first { $0.id == betaId }!

        // Root renamed to a PLAIN heading titled "Notes" -- same level, so the demotion guard
        // never engages; this heading is NOT itself isNotes.
        let renamedMarkdown = """
        ## Notes

        Body.

        ### Child

        Child body.
        """
        let newBlocks = BlockParser.parse(markdown: renamedMarkdown, projectId: pid)

        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let renamedRoot = after.first { $0.id == alphaId }
        #expect(renamedRoot?.textContent == "Notes", "root heading should now read 'Notes'")
        #expect(renamedRoot?.isNotes == false, "the renamed root must NOT pick up the machine isNotes flag")

        let realNotes = after.first { $0.id == realNotesId }
        #expect(realNotes != nil, "the real machine-managed Notes heading must survive untouched")
        #expect(realNotes?.isNotes == true, "the real Notes heading must keep its isNotes flag")

        let allNotesHeadings = after.filter { $0.isNotes && $0.blockType == .heading }
        #expect(allNotesHeadings.count == 1, "exactly one isNotes heading must exist afterward")
    }

    // MARK: - 7. replaceBlocksInRange returns the actually-inserted rows with final ids

    @Test("replaceBlocksInRange's return value's ids match what's actually in the DB for that range")
    func replaceBlocksInRangeReturnsInsertedRowsWithFinalIds() throws {
        let fixture = try makeRenameFixture()
        try fixture.db.dbWriter.write { database in
            var block = try Block.fetchOne(database, key: fixture.alphaId)!
            block.status = .review
            try block.update(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        let renamedMarkdown = """
        ## Alpha Renamed

        Body.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(renamedMarkdown, pid: fixture.pid)

        let inserted = try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        #expect(!inserted.isEmpty)
        let insertedIds = Set(inserted.map { $0.id })
        #expect(insertedIds.contains(fixture.alphaId), "the anchor's preserved id should appear in the returned rows")
        #expect(insertedIds.contains(fixture.childId), "the title-matched child's preserved id should appear too")

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let dbIdsInRange = Set(
            after.filter { $0.sortOrder >= alpha.sortOrder && $0.textContent != "Beta" && $0.textContent != "Doc" }
                .map { $0.id }
        )
        for id in insertedIds {
            #expect(dbIdsInRange.contains(id), "every returned id should actually be present in the DB afterward")
        }
    }

    // MARK: - 8. Anchor declines when a new heading is typed above the still-present, unchanged root (M8, judge fix round)

    /// M8 (judge fix round): if the user types a NEW heading above the zoom root within one
    /// debounce window (same level or shallower), the first non-empty block in the zoomed
    /// range is now that NEW heading, not the real root. Before this fix, `resolveAnchorHeading`
    /// bound the root's old id/metadata onto that new heading anyway (it only ever looked at
    /// POSITION), while the real root -- still present, unchanged, just pushed to a later
    /// index -- was excluded from the title-matching queue entirely (its own existing row had
    /// already been "claimed" by the anchor), so it received a completely fresh parser id and
    /// silently lost its own status/tags/goals. The fix declines the anchor bind whenever the
    /// anchor's OLD title+level still appear elsewhere among the new blocks.
    @Test("anchor declines when a new heading is typed above the still-present, unchanged root")
    func anchorDeclinesWhenNewHeadingTypedAboveUnchangedRoot() throws {
        let fixture = try makeRenameFixture()
        try fixture.db.dbWriter.write { database in
            var block = try Block.fetchOne(database, key: fixture.alphaId)!
            block.status = .review
            try block.update(database)
        }

        let blocks = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let alpha = blocks.first { $0.id == fixture.alphaId }!
        let beta = blocks.first { $0.id == fixture.betaId }!

        // A NEW heading typed above the (unchanged) root, same level, within one debounce
        // window -- the root's own heading text/level survive unchanged, just later.
        let newMarkdown = """
        ## New Heading

        New body.

        ## Alpha

        Body.

        ### Child

        Child body.
        """
        let newBlocks = parseRange(newMarkdown, pid: fixture.pid)

        try fixture.db.replaceBlocksInRange(
            newBlocks, for: fixture.pid,
            startSortOrder: alpha.sortOrder, endSortOrder: beta.sortOrder,
            anchorHeadingId: fixture.alphaId
        )

        let after = try TestFixtureFactory.fetchBlocks(from: fixture.db)
        let realAlpha = after.first { $0.textContent == "Alpha" }
        #expect(
            realAlpha?.id == fixture.alphaId,
            "the real, unchanged root must keep its own id -- must not be stolen by the new heading typed above it"
        )
        #expect(realAlpha?.status == .review, "the real root must keep its own metadata")

        let newHeading = after.first { $0.textContent == "New Heading" }
        #expect(newHeading?.id != fixture.alphaId, "the new heading above the root must NOT receive the root's id")

        let childAfter = after.first { $0.textContent == "Child" }
        #expect(childAfter?.id == fixture.childId, "Child should be unaffected, keeping its own id via the title queue")
    }
}
