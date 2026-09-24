//
//  NotesH2DataLossFootnoteGuardTests.swift
//  final finalTests
//
//  Split out of NotesH2DataLossTests.swift to keep that file's struct body under SwiftLint's
//  type_body_length limit -- see the header comment there for the full Notes/H2 data-loss
//  background. This file covers the B7 refs.isEmpty independent guard, the C7 mini-Notes
//  heading-level/title preservation, the T5 Notes-run-extent/closing-boundary cases, and T12's
//  real-parse-pipeline-derived targetRefs reconciliation.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension NotesH2DataLossTests {

    // MARK: - B7: the refs.isEmpty branch is independently guarded

    @Test("documentContainsFootnoteReference finds a reference but not a definition (B7)")
    func documentContainsFootnoteReferenceDistinguishesRefsFromDefinitions() {
        #expect(FootnoteSyncService.documentContainsFootnoteReference("See[^1] the note.") == true)
        #expect(FootnoteSyncService.documentContainsFootnoteReference("[^1]: A definition only.") == false)
        #expect(FootnoteSyncService.documentContainsFootnoteReference("No references here at all.") == false)
    }

    @Test("performFootnoteUpdate refuses to remove the Notes section when the unstripped document still has a reference (B7)")
    @MainActor
    func b7GuardRefusesRemovalWhenUnstrippedDocumentHasReference() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }
        var heading = Block(projectId: projectId, sortOrder: 1, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true)
        var definition = Block(projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "Still referenced.", markdownFragment: "[^1]: Still referenced.", isNotes: true)
        try db.write { database in
            try heading.insert(database)
            try definition.insert(database)
        }

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // `refs` is empty (simulating a primary-scanner miss), but the RAW document
        // below still genuinely contains a `[^1]` reference in a Notes-adjacent region
        // -- the guard must refuse the destructive branch rather than trust `refs` alone.
        let unstrippedContent = """
        # Chapter

        ## Notes

        See[^1] the appendix.
        """
        await service.performFootnoteUpdate(
            refs: [], projectId: projectId, fullContent: unstrippedContent, scheduledGeneration: 0
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(
            after.contains { $0.id == heading.id },
            "The Notes heading must survive -- removeNotesBlock must never have run"
        )
        #expect(
            after.contains { $0.id == definition.id },
            "The definition must survive -- removeNotesBlock must never have run"
        )
    }

    // MARK: - C7: zoom mini-Notes rebuild preserves an adopted H2 heading's level

    @Test("syncMiniNotesBackImpl preserves an existing '## Notes' heading's level and title instead of downgrading it to H1 (C7)")
    @MainActor
    func miniNotesSyncPreservesH2HeadingLevelOnRebuild() throws {
        // C7: before this fix, the mini-Notes zoom-panel sync path unconditionally rebuilt the
        // Notes heading as `textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1`
        // on every edit -- a no-op pre-Stage-C (the only heading that could ever be flagged
        // `isNotes` WAS already H1 "# Notes"), but a real, silent heading-level downgrade now
        // that H2 recognition is live. This directly violates the plan's settled decision #2
        // ("heading level is kept as typed on adoption, never normalized").
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        var heading = Block(
            projectId: projectId, sortOrder: 1, blockType: .heading, textContent: "Notes",
            markdownFragment: "## Notes", headingLevel: 2, isNotes: true
        )
        var definition = Block(
            projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "Original text.", markdownFragment: "[^1]: Original text.", isNotes: true
        )
        try db.write { database in
            try heading.insert(database)
            try definition.insert(database)
        }

        // T2: precondition -- the fixture really is H2, not H1.
        #expect(heading.headingLevel == 2)

        // Simulate an edit made in the zoom mini-Notes panel: the same label, new text.
        let editedMiniNotes = "[^1]: Edited text from the mini-Notes panel."
        SectionSyncService.syncMiniNotesBackDetached(editedMiniNotes, db: db, pid: projectId)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let headingAfter = try #require(after.first { $0.blockType == .heading && $0.isNotes })
        #expect(headingAfter.headingLevel == 2, "The heading level must NOT be downgraded to H1")
        #expect(headingAfter.markdownFragment == "## Notes", "The heading's own markdown must stay H2")
        #expect(headingAfter.id == heading.id, "Scroll stability: the heading's block ID must be preserved")

        let defAfter = try #require(after.first {
            $0.isNotes && FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label == "1"
        })
        #expect(
            defAfter.markdownFragment.contains("Edited text from the mini-Notes panel"),
            "The edited text must actually be merged in"
        )
    }

    // MARK: - T5: run-extent -- what closes an H2 Notes run, and run isolation

    @Test("T5: an H2 Notes run is closed by an H2 sibling heading -- content after the sibling is never flagged")
    func h2NotesRunClosedByH2Sibling() throws {
        let markdown = """
        # Chapter

        A reference[^1].

        ## Notes

        [^1]: The real definition.

        ## Appendix

        Unrelated appendix prose that must never be flagged Notes.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let notesHeading = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" })
        #expect(notesHeading.isNotes == true, "The H2 Notes heading itself must be selected")
        let definition = try #require(blocks.first { $0.markdownFragment.contains("The real definition") })
        #expect(definition.isNotes == true, "The definition inside the run must be flagged")

        let appendixHeading = try #require(blocks.first { $0.textContent == "Appendix" })
        #expect(appendixHeading.isNotes == false, "The H2 sibling heading that closes the run must not itself be flagged")
        let appendixProse = try #require(blocks.first { $0.markdownFragment.contains("Unrelated appendix prose") })
        #expect(appendixProse.isNotes == false, "Content after the closing sibling must never be flagged")
    }

    @Test("T5: an H2 Notes run is closed by an H3 heading -- a DEEPER level still closes the run, not just a same-or-shallower one")
    func h2NotesRunClosedByH3() throws {
        let markdown = """
        # Chapter

        A reference[^1].

        ## Notes

        [^1]: The real definition.

        ### Sub-point

        Unrelated sub-point prose that must never be flagged Notes.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let notesHeading = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" })
        #expect(notesHeading.isNotes == true)
        let definition = try #require(blocks.first { $0.markdownFragment.contains("The real definition") })
        #expect(definition.isNotes == true)

        let subHeading = try #require(blocks.first { $0.textContent == "Sub-point" })
        #expect(subHeading.isNotes == false, "An H3 heading -- deeper, not shallower -- must still close the run")
        let subProse = try #require(blocks.first { $0.markdownFragment.contains("Unrelated sub-point prose") })
        #expect(subProse.isNotes == false, "Content after the H3 closer must never be flagged")
    }

    @Test("T5: a second Notes run after intervening body text does not merge with the first -- both stay independently correct")
    @MainActor
    func secondNotesRunAfterInterveningTextDoesNotMerge() throws {
        // Connects end-to-end to Stage B's B4 run-ordinal fix (`notesSortKey`'s run being its
        // MOST significant sort component) -- this test goes through the real
        // BlockParser.parse -> reconcileNotesBlocks chain, not just the sort-key comparator in
        // isolation, so it also proves C1's selector-based adoption keeps the two runs distinct
        // going in, not just that a correct sort key exists to keep them separate afterward.
        let markdown = """
        # Part One

        A reference[^1].

        ## Notes

        [^1]: First run's definition.

        # Part Two

        This is substantial intervening body text between the two runs, with no footnote \
        references of its own, that must never be mistaken for Notes content by either run.

        A second reference[^2].

        ## Notes

        [^2]: Second run's definition.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let notesHeadings = blocks.filter { $0.blockType == .heading && $0.textContent == "Notes" }
        #expect(notesHeadings.count == 2, "Both '## Notes' headings must exist as distinct blocks")
        #expect(notesHeadings.allSatisfy { $0.isNotes }, "Both runs must be independently selected")

        let interveningText = try #require(blocks.first { $0.markdownFragment.contains("substantial intervening body text") })
        #expect(interveningText.isNotes == false, "Intervening body text between the two runs must never be flagged")

        let def1 = try #require(blocks.first { $0.markdownFragment.contains("First run's definition") })
        let def2 = try #require(blocks.first { $0.markdownFragment.contains("Second run's definition") })
        #expect(def1.isNotes == true)
        #expect(def2.isNotes == true)

        // Reconcile through the real DB path and confirm the runs stay contiguous and
        // non-interleaved -- B4's per-run sort key exercised end-to-end, not in isolation.
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }
        try db.replaceBlocks(BlockParser.parse(markdown: markdown, projectId: projectId), for: projectId)

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1", "2"])
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let notesOnly = after.filter { $0.isNotes }
        let orderedFragments = notesOnly.map(\.markdownFragment)
        let firstHeadingIdx = try #require(orderedFragments.firstIndex(where: { $0.contains("Notes") }))
        let firstDefIdx = try #require(orderedFragments.firstIndex(where: { $0.contains("First run's definition") }))
        let secondHeadingIdx = try #require(
            orderedFragments.indices.dropFirst(firstDefIdx + 1).first { orderedFragments[$0].contains("Notes") }
        )
        let secondDefIdx = try #require(orderedFragments.firstIndex(where: { $0.contains("Second run's definition") }))

        #expect(firstHeadingIdx < firstDefIdx, "Run 1's heading precedes its own definition")
        #expect(firstDefIdx < secondHeadingIdx, "Run 1's definition stays before run 2's heading -- runs are contiguous, not interleaved")
        #expect(secondHeadingIdx < secondDefIdx, "Run 2's heading precedes its own definition")
    }

    // MARK: - T12: targetRefs derived from the real parse pipeline (not a hand-written literal)

    /// Every other `reconcileNotesBlocks` call site in this file and in `FootnoteSyncTests.swift`
    /// passes a hand-written literal (`targetRefs: ["1"]`, `["1", "2", "3"]`, ...). A literal
    /// array doesn't prove the REAL pipeline -- `extractFootnoteRefs`, which strips the Notes
    /// section via `stripNotesSection` before scanning the body for `[^N]` refs -- derives the
    /// same set for an H2-headed document, where Stage C's `NotesOpeningSelector` (not the old
    /// H1-only literal) decides where the Notes section starts. This test closes that gap: it
    /// derives `targetRefs` from `FootnoteSyncService.extractFootnoteRefs(from:)` against markdown
    /// parsed by the real `BlockParser.parse` pipeline (via `TestFixtureFactory.createFixture`),
    /// then reconciles with the derived set and confirms both existing H2-section definitions
    /// survive intact and no duplicate Notes heading gets materialized.
    @Test("targetRefs derived from extractFootnoteRefs against a real H2-headed parsed document reconciles without data loss (T12)")
    @MainActor
    func targetRefsDerivedFromRealParsePipelineForH2Document() async throws {
        let markdown = """
        Body text with a reference[^1] and another[^2] here.

        ## Notes

        [^1]: First derived definition.
        [^2]: Second derived definition.
        """

        // Derive targetRefs from the real pipeline -- never a hand-written literal.
        let derivedRefs = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        #expect(derivedRefs == ["1", "2"], "extractFootnoteRefs must find both body refs in an H2 document")

        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let beforeBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let notesHeadingBefore = try #require(
            beforeBlocks.first { $0.blockType == .heading && $0.isNotes },
            "Real BlockParser.parse must recognize '## Notes' as the machine-owned Notes heading (Stage C)"
        )
        #expect(notesHeadingBefore.headingLevel == 2, "The seeded heading is H2, and must be recognized at that level")

        try db.write { database in
            _ = try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: derivedRefs)
        }

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let def1 = try #require(afterBlocks.first { $0.markdownFragment.contains("First derived definition") })
        let def2 = try #require(afterBlocks.first { $0.markdownFragment.contains("Second derived definition") })
        #expect(def1.isNotes, "Definition 1 must stay flagged isNotes after reconciling with derived refs")
        #expect(def2.isNotes, "Definition 2 must stay flagged isNotes after reconciling with derived refs")

        let notesHeadingsAfter = afterBlocks.filter { $0.blockType == .heading && $0.isNotes }
        #expect(
            notesHeadingsAfter.count == 1,
            "Exactly one Notes heading after reconciling with real-pipeline-derived refs -- no duplicate materialized"
        )
    }
}
