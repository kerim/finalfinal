//
//  ZoomDataIntegrityCountMismatchTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Split out of the "Duplicate-Titled Headings" section of ZoomDataIntegrityTests.swift
//  (via ZoomDataIntegrityDuplicateHeadingTests.swift) to stay under SwiftLint's
//  type_body_length cap — same suite, same test names/counts, just a third file.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension ZoomDataIntegrityTests {

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
}
