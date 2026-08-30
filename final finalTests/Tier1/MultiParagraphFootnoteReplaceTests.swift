//
//  MultiParagraphFootnoteReplaceTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Regression coverage for three reviewer-found bugs in `handleMachineManagedBlock`'s
//  labelless-continuation branch and `buildNotesRowIndex` (Database+BlocksReplace.swift),
//  all confirmed by direct code inspection against the actual `replaceBlocksInRange`/
//  `replaceBlocks` machinery a zoomed reparse or section-restore drives:
//
//  1. SHRINK: the claiming loop only ever consumed preserved continuation rows
//     positionally -- it never deleted a row the incoming batch no longer claimed. A
//     multi-paragraph footnote losing a paragraph (the user deletes it) resurrected the
//     deleted paragraph on the next reparse, because nothing ever removed its now-unclaimed
//     preserved row.
//  2. GROW: a genuinely-new continuation (more incoming continuations than preserved rows)
//     fell through to a normal insert at the batch's own index-based sortOrder -- inside the
//     freshly-sequenced body-content region -- while its owning definition (a PRESERVED row)
//     only moved to its final position later, via `reanchorPreservedRows`. The new
//     continuation therefore sorted AHEAD of its own definition and got silently
//     misclassified as trailing content belonging to whichever footnote happened to be last.
//  3. RUN-BOUNDARY: `buildNotesRowIndex`'s ownership walk never reset at a Notes-opening
//     heading, so on a document with two independent "# Notes" runs, a later run's own
//     leading user prose (positioned right after the first run's last footnote once
//     non-Notes body content is filtered out of view) could be wrongly treated as an
//     available "continuation slot" for that earlier footnote -- and silently overwritten
//     with its text.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Multi-Paragraph Footnote Replace-Path Integrity — Tier 1: Silent Killers")
struct MultiParagraphFootnoteReplaceTests {

    @Test("A shrinking multi-paragraph footnote does not resurrect its deleted paragraph")
    @MainActor
    func shrinkingFootnoteDoesNotResurrectDeletedParagraph() throws {
        let content = """
        Body text with a footnote.[^1]

        # Notes

        [^1]: First paragraph.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeading = try #require(before.first { $0.isNotes && $0.blockType == .heading })
        let def1 = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })

        // Manually seed TWO continuation rows under [^1] -- exactly the shape several
        // rounds of "press Enter, type another paragraph" (followed by a reparse) already
        // produces in the DB -- bypassing the insert/reconciliation paths so this test
        // exercises ONLY replaceBlocksInRange's own claim/cleanup logic.
        var continuationA = Block(
            projectId: pid, sortOrder: def1.sortOrder + 0.1, blockType: .paragraph,
            textContent: "Second paragraph (A).", markdownFragment: "Second paragraph (A).", isNotes: true
        )
        var continuationB = Block(
            projectId: pid, sortOrder: def1.sortOrder + 0.2, blockType: .paragraph,
            textContent: "Third paragraph (B).", markdownFragment: "Third paragraph (B).", isNotes: true
        )
        try db.write { database in
            try continuationA.insert(database)
            try continuationB.insert(database)
        }

        // Reparsed content for the same range: [^1] plus only ONE continuation now -- the
        // user deleted "Third paragraph (B)."
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "[^1]: First paragraph.", markdownFragment: "[^1]: First paragraph.", isNotes: true),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Second paragraph (A).", markdownFragment: "Second paragraph (A).", isNotes: true)
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: notesHeading.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let notesParagraphs = after.filter { $0.isNotes && $0.blockType == .paragraph }

        #expect(
            !after.contains { $0.markdownFragment == "Third paragraph (B)." },
            "The deleted continuation paragraph must NOT be resurrected"
        )
        #expect(
            after.contains { $0.markdownFragment == "Second paragraph (A)." },
            "The surviving continuation must still be present"
        )
        #expect(
            notesParagraphs.count == 2,
            "Expected exactly [^1] plus ONE surviving continuation; got \(notesParagraphs.map(\.markdownFragment))"
        )
    }

    @Test("A genuinely-new continuation for footnote 1 lands adjacent to footnote 1, not misfiled after footnote 2")
    @MainActor
    func newContinuationLandsAdjacentToItsOwner() throws {
        let content = """
        Body[^1] and[^2].

        # Notes

        [^1]: First footnote.

        [^2]: Second footnote.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeading = try #require(before.first { $0.isNotes && $0.blockType == .heading })
        let def1Before = try #require(before.first { $0.markdownFragment.hasPrefix("[^1]:") })

        // [^1] carried forward unchanged, plus a BRAND-NEW second paragraph -- no preserved
        // row exists for it (this footnote had zero continuations before) -- then [^2]
        // unchanged. This is the "footnote grows a paragraph" shape.
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "[^1]: First footnote.", markdownFragment: "[^1]: First footnote.", isNotes: true),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "A brand-new second paragraph of footnote one.",
                  markdownFragment: "A brand-new second paragraph of footnote one.", isNotes: true),
            Block(projectId: pid, sortOrder: 2, blockType: .paragraph,
                  textContent: "[^2]: Second footnote.", markdownFragment: "[^2]: Second footnote.", isNotes: true)
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: notesHeading.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let def1Index = try #require(after.firstIndex { $0.markdownFragment.hasPrefix("[^1]:") })
        let continuationIndex = try #require(
            after.firstIndex { $0.markdownFragment == "A brand-new second paragraph of footnote one." }
        )
        let def2Index = try #require(after.firstIndex { $0.markdownFragment.hasPrefix("[^2]:") })

        #expect(after[def1Index].id == def1Before.id, "[^1] keeps its original id (merged in place, not re-inserted)")
        #expect(
            def1Index < continuationIndex && continuationIndex < def2Index,
            """
            The new continuation must land strictly between its owner ([^1]) and the NEXT \
            footnote ([^2]) -- not misfiled after [^2] as if it belonged to the last footnote \
            in the group. Order was: def1=\(def1Index), continuation=\(continuationIndex), \
            def2=\(def2Index)
            """
        )
    }

    @Test("A genuinely-new continuation for an EARLIER footnote never overwrites a LATER Notes run's own user prose")
    @MainActor
    func newContinuationNeverOverwritesLaterRunsUserProse() throws {
        let content = """
        Intro text with a footnote.[^1]

        # Notes

        [^1]: First run's footnote.

        # Middle

        Some middle content.

        # Notes

        My own prose before any definition in run two.

        [^2]: Second run's footnote.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeadings = before
            .filter { $0.isNotes && $0.blockType == .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(notesHeadings.count == 2, "Fixture sanity check: two independent Notes runs")
        let firstNotesHeading = try #require(notesHeadings.first)
        let userProseBefore = try #require(
            before.first { $0.markdownFragment == "My own prose before any definition in run two." }
        )

        // Range covers BOTH Notes runs (from run one's heading through the end of the
        // document). newBlocks carries [^1] forward plus a GENUINELY NEW second paragraph;
        // run two's own heading/prose/definition are deliberately NOT reproduced here --
        // they must survive via preservation, exactly as the single-run case already does
        // (see ZoomDataIntegrityNotesTests).
        let newBlocks = [
            Block(projectId: pid, sortOrder: 0, blockType: .paragraph,
                  textContent: "[^1]: First run's footnote.", markdownFragment: "[^1]: First run's footnote.", isNotes: true),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Second paragraph of footnote one.",
                  markdownFragment: "Second paragraph of footnote one.", isNotes: true),
            Block(projectId: pid, sortOrder: 2, blockType: .heading, textContent: "Middle",
                  markdownFragment: "# Middle", headingLevel: 1),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph, textContent: "Some middle content.",
                  markdownFragment: "Some middle content.")
        ]

        try db.replaceBlocksInRange(newBlocks, for: pid, startSortOrder: firstNotesHeading.sortOrder, endSortOrder: nil)

        let after = try TestFixtureFactory.fetchBlocks(from: db)

        #expect(
            after.contains { $0.markdownFragment == "Second paragraph of footnote one." },
            "Footnote one's genuinely new continuation must land somewhere as its own row"
        )

        let userProseAfter = try #require(after.first { $0.id == userProseBefore.id })
        #expect(
            userProseAfter.markdownFragment == "My own prose before any definition in run two.",
            """
            Run two's user prose row, by its ORIGINAL id, must keep its ORIGINAL content -- \
            proving it was never claimed/overwritten as if it were footnote one's \
            continuation. Before the fix, buildNotesRowIndex had no per-run ownership reset, \
            so this row was wrongly bucketed as an available "continuation slot" for footnote \
            one and silently overwritten.
            """
        )
        #expect(
            after.contains { $0.markdownFragment.hasPrefix("[^2]:") },
            "Run two's own footnote definition must also survive untouched"
        )
    }
}
