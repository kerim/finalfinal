//
//  NotesH2DataLossTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Stage B (t-7f7e6ed2 / t-mtianjujt9ub, "notes-heading-scanner-unify"): every destructive
//  path Notes reconciliation can take, made safe BEFORE Stage C widens what gets recognized
//  as a Notes section. Per the plan's Test Discipline section:
//
//  - T1: at least one test proves the sweep still deletes a genuine orphan -- a no-op
//    sweep must NOT pass this test.
//  - T2: structural pre-conditions on every data-loss test -- assert the seeded row
//    actually satisfies the filter being exercised, before acting.
//  - T3: the blank-twin backstop test, in the specific non-vacuous shape the plan
//    requires (a plain paragraph, never a blockquote/fence).
//  - T4: idempotence across two reconcile passes.
//  - T6: per-run ordering -- two runs stay contiguous, userProse sorts last within its
//    own run (B4's new intended behavior).
//
//  Each test hand-constructs `Block` rows directly (bypassing markdown parse/BlockParser)
//  to isolate the exact shape under test, matching the established pattern in
//  FootnoteSyncTests.swift's `reconcileNotesBlocksCascadeDeleteExcludesBibliographyRows`.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Notes H2 Data Loss — Tier 1: Silent Killers")
struct NotesH2DataLossTests {

    // MARK: - B1: removeNotesBlock never mass-deletes user prose

    @Test("removeNotesBlock deletes only machine-owned rows, never the user's own prose (B1)")
    @MainActor
    func removeNotesBlockPreservesUserProseUnderNotesHeading() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        var heading = Block(
            projectId: projectId, sortOrder: 1, blockType: .heading, textContent: "Notes",
            markdownFragment: "# Notes", headingLevel: 1, isNotes: true
        )
        var userProse = Block(
            projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "My own commentary on these notes.",
            markdownFragment: "My own commentary on these notes.", isNotes: true
        )
        var definition = Block(
            projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "A real footnote.", markdownFragment: "[^1]: A real footnote.", isNotes: true
        )
        try db.write { database in
            try heading.insert(database)
            try userProse.insert(database)
            try definition.insert(database)
        }

        // T2: structural preconditions -- this row really is flagged AND really doesn't
        // parse as a footnote definition, i.e. it genuinely reaches the `.userProse`
        // branch this fix protects, not some other branch by accident.
        #expect(userProse.isNotes)
        #expect(FootnoteSyncService.parseNotesLabel(from: userProse.markdownFragment) == nil)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // No footnote reference anywhere -- refs.isEmpty legitimately, and B7's
        // independent scan of the raw document also finds none, so this genuinely
        // reaches removeNotesBlock (not refused by the B7 guard).
        await service.performFootnoteUpdate(
            refs: [], projectId: projectId, fullContent: "Just a plain document.", scheduledGeneration: 0
        )

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let survivingProse = try #require(after.first { $0.id == userProse.id })
        #expect(
            survivingProse.markdownFragment == "My own commentary on these notes.",
            "The user's own writing under the Notes heading must survive with its text intact"
        )
        #expect(!survivingProse.isNotes, "Retained prose is unflagged once its Notes section is gone")
        #expect(!after.contains { $0.id == definition.id }, "The machine-owned definition IS deleted")
        #expect(!after.contains { $0.id == heading.id }, "The machine-owned heading IS deleted")
    }

    // MARK: - T1: the sweep must still delete a genuine orphan

    @Test("deleteOrphanedFootnoteDefinitions still deletes a genuine identical-bodied orphan (T1)")
    @MainActor
    func deleteOrphanedFootnoteDefinitionsDeletesGenuineOrphan() throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        var heading = Block(
            projectId: projectId, sortOrder: 1, blockType: .heading, textContent: "Notes",
            markdownFragment: "# Notes", headingLevel: 1, isNotes: true
        )
        var twin = Block(
            projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "Duplicate text.", markdownFragment: "[^1]: Duplicate text.", isNotes: true
        )
        // Corruption from before isNotes propagation: an UNFLAGGED duplicate of [^1]
        // with the identical body, sitting outside the Notes section entirely.
        var orphan = Block(
            projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "Duplicate text.", markdownFragment: "[^1]: Duplicate text.", isNotes: false
        )
        try db.write { database in
            try heading.insert(database)
            try twin.insert(database)
            try orphan.insert(database)
        }

        // T2: structural preconditions -- the orphan really satisfies the candidate
        // filter (`isNotes == false`, `.paragraph`, parses as `[^N]:`).
        #expect(!orphan.isNotes)
        #expect(orphan.blockType == .paragraph)
        #expect(orphan.markdownFragment.hasPrefix("[^1]:"))

        try db.write { database in
            try FootnoteSyncService.deleteOrphanedFootnoteDefinitions(db: database, projectId: projectId)
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(
            !after.contains { $0.id == orphan.id },
            "A genuine identical-bodied orphan MUST still be deleted -- a no-op sweep must fail this test"
        )
        #expect(after.contains { $0.id == twin.id }, "The real (flagged) twin survives")
    }

    // MARK: - T3: the blank-twin backstop, non-vacuous shape

    @Test("a real definition never loses to a blank twin reconciliation just manufactured (T3)")
    @MainActor
    func blankTwinNeverWinsOverRealText() throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        // Non-vacuous shape, per the plan's Test Discipline (T3): the real definition is
        // a PLAIN PARAGRAPH -- never a blockquote/fence, which would fail to match
        // `[^N]:` at all and make this test pass vacuously without exercising the guard
        // -- sitting under an unrelated "## Appendix" heading, with an evidence-free
        // "## Notes" heading elsewhere. Pre-Stage-C, BlockParser only ever recognizes
        // literal H1 "# Notes", so NEITHER heading here is auto-flagged, and
        // `reconcileNotesBlocks` legitimately finds no existing Notes heading and
        // manufactures a brand-new "# Notes" heading plus a BLANK [^1]: twin -- exactly
        // the scenario this guard exists for.
        var bodyRef = Block(
            projectId: projectId, sortOrder: 1, blockType: .paragraph,
            textContent: "See the note[^1] below.", markdownFragment: "See the note[^1] below."
        )
        var appendixHeading = Block(
            projectId: projectId, sortOrder: 2, blockType: .heading, textContent: "Appendix",
            markdownFragment: "## Appendix", headingLevel: 2
        )
        var realDefinition = Block(
            projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "The real footnote text.", markdownFragment: "[^1]: The real footnote text."
        )
        var evidenceFreeNotesHeading = Block(
            projectId: projectId, sortOrder: 4, blockType: .heading, textContent: "Notes",
            markdownFragment: "## Notes", headingLevel: 2
        )
        try db.write { database in
            try bodyRef.insert(database)
            try appendixHeading.insert(database)
            try realDefinition.insert(database)
            try evidenceFreeNotesHeading.insert(database)
        }

        // T2: structural preconditions.
        #expect(!realDefinition.isNotes)
        #expect(realDefinition.blockType == .paragraph)
        #expect(realDefinition.markdownFragment.hasPrefix("[^1]:"))
        #expect(!realDefinition.markdownFragment.hasPrefix(">"), "must be a plain paragraph, not a blockquote")

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1"])
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let survivingReal = try #require(after.first { $0.id == realDefinition.id })
        #expect(
            survivingReal.markdownFragment == "[^1]: The real footnote text.",
            "The real, hand-typed definition must survive with its text intact"
        )

        let blankTwins = after.filter { block in
            block.isNotes && block.blockType == .paragraph && block.id != realDefinition.id &&
                FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label == "1"
        }
        #expect(
            !blankTwins.isEmpty,
            "reconcileNotesBlocks did manufacture a blank twin -- confirms this is a real defeat-shape, not a no-op"
        )
        #expect(blankTwins.allSatisfy {
            (FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.text ?? "not-blank")
                .trimmingCharacters(in: .whitespaces).isEmpty
        })
    }

    // MARK: - T4: idempotence

    @Test("reconcileNotesBlocks is idempotent across two consecutive passes (T4)")
    @MainActor
    func reconcileNotesBlocksIsIdempotent() throws {
        let seed = """
        Body[^1] and[^2].

        # Notes

        [^1]: First real text.

        [^2]: Second real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1", "2"])
        }
        let afterFirst = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1", "2"])
        }
        let afterSecond = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }

        #expect(afterFirst.count == afterSecond.count, "A stable second pass must not add or remove rows")
        let firstById = Dictionary(uniqueKeysWithValues: afterFirst.map { ($0.id, $0) })
        for block in afterSecond {
            let before = try #require(firstById[block.id], "No new row identities should appear on a second pass")
            #expect(block.markdownFragment == before.markdownFragment)
            #expect(block.sortOrder == before.sortOrder)
            #expect(block.updatedAt == before.updatedAt, "A stable second pass must not rewrite rows that already match")
        }
    }

    // MARK: - B4/T6: per-run ordering

    @Test("two Notes runs stay contiguous and userProse sorts last within its own run (B4/T6)")
    @MainActor
    func perRunOrderingKeepsRunsContiguousAndProseWithinItsOwnRun() throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }

        // Two separate, already-flagged Notes runs, plus a userProse row in run 1. If the
        // sort key doesn't carry run identity as its most-significant component, rows
        // across runs 1 and 2 interleave/fuse instead of staying contiguous per run.
        var heading1 = Block(projectId: projectId, sortOrder: 1, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true)
        var prose1 = Block(projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "My commentary in run 1.", markdownFragment: "My commentary in run 1.", isNotes: true)
        var def1 = Block(projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "First run's footnote.", markdownFragment: "[^1]: First run's footnote.", isNotes: true)
        var heading2 = Block(projectId: projectId, sortOrder: 4, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true)
        var def2 = Block(projectId: projectId, sortOrder: 5, blockType: .paragraph,
            textContent: "Second run's footnote.", markdownFragment: "[^2]: Second run's footnote.", isNotes: true)

        try db.write { database in
            try heading1.insert(database)
            try prose1.insert(database)
            try def1.insert(database)
            try heading2.insert(database)
            try def2.insert(database)
        }

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1", "2"])
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let orderedIds = after.map(\.id)

        #expect(
            after.filter { $0.blockType == .heading }.count == 2,
            "No new duplicate Notes heading is created when one is already flagged (B4's deterministic .order pick)"
        )

        let idx1 = try #require(orderedIds.firstIndex(of: heading1.id))
        let idxProse1 = try #require(orderedIds.firstIndex(of: prose1.id))
        let idxDef1 = try #require(orderedIds.firstIndex(of: def1.id))
        let idx2 = try #require(orderedIds.firstIndex(of: heading2.id))

        // Run 1's rows all sort before run 2's heading -- the two runs stay contiguous,
        // never interleaved/fused.
        #expect(idx1 < idx2, "Run 1's heading sorts before run 2's heading")
        #expect(idxDef1 < idx2, "Run 1's definition stays inside run 1, before run 2 begins")
        #expect(idxProse1 < idx2, "Run 1's user prose stays inside run 1, before run 2 begins")

        // Within run 1, userProse sorts LAST -- after the definition. B4's stated
        // behavior change: it used to sort last in the WHOLE Notes group; now it sorts
        // last WITHIN ITS OWN RUN.
        #expect(idxProse1 > idxDef1, "userProse sorts after the definition within its own run")
        #expect(idx1 < idxDef1, "The heading opens the run before its definition")
    }

    // MARK: - B2: dedup parks (never deletes) two genuinely differing bodies

    @Test("dedup parks two genuinely differing non-blank bodies instead of deleting either (B2)")
    @MainActor
    func dedupParksDifferingBodiesInsteadOfDeleting() throws {
        let db = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        try db.write { database in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(database)
        }
        var heading = Block(projectId: projectId, sortOrder: 1, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true)
        var defA = Block(projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "Version A of the text.", markdownFragment: "[^1]: Version A of the text.", isNotes: true)
        var defB = Block(projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "Version B, completely different.",
            markdownFragment: "[^1]: Version B, completely different.", isNotes: true)
        try db.write { database in
            try heading.insert(database)
            try defA.insert(database)
            try defB.insert(database)
        }

        // T2: preconditions -- both rows really do carry the SAME label with DIFFERENT
        // non-blank bodies, the exact ambiguous case this guard exists for.
        #expect(FootnoteSyncService.parseNotesLabel(from: defA.markdownFragment)?.label == "1")
        #expect(FootnoteSyncService.parseNotesLabel(from: defB.markdownFragment)?.label == "1")
        #expect(defA.markdownFragment != defB.markdownFragment)

        try db.write { database in
            try FootnoteSyncService.reconcileNotesBlocks(db: database, projectId: projectId, targetRefs: ["1"])
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.contains { $0.id == defA.id }, "Neither differing body may be deleted -- A survives")
        #expect(after.contains { $0.id == defB.id }, "Neither differing body may be deleted -- B survives")
    }

    // MARK: - B3: deferred to Stage C, documented rather than code-changed

    @Test("deleteBlocksInRange still protects ALL isNotes rows unconditionally -- B3's narrowing was tried and reverted (B3)")
    @MainActor
    func deleteBlocksInRangeStillProtectsAllNotesRowsUnconditionally() throws {
        // B3's first attempt narrowed `protectingNotes` to only machine-owned rows
        // (heading/definition/continuation), reasoning that non-machine-owned user prose
        // should be as deletable as any other body content. That regressed
        // MultiParagraphFootnoteReplaceTests.newContinuationNeverOverwritesLaterRunsUserProse:
        // `replaceBlocksInRange`'s range is not always exhaustive for every Notes run it
        // happens to overlap (an `endSortOrder: nil` call scoped to editing one Notes run
        // can mechanically sweep in a second, unrelated run purely by sort order), and a
        // row never reproduced in `newBlocks` for THAT reason looks identical, to this
        // function, to a row the user genuinely deleted. Reverted -- this test documents
        // and pins the reverted (original) behavior: `protectingNotes` still exempts every
        // non-heading `isNotes` row unconditionally, INCLUDING user prose, until C1(3)
        // (Stage C: never flag arbitrary user prose as isNotes in the first place) removes
        // the ambiguity this function cannot itself resolve.
        let projectDb = try TestFixtureFactory.createTemporary(content: "Just a plain document.")
        let projectId = try TestFixtureFactory.getProjectId(from: projectDb)

        try projectDb.write { db in
            try Block.filter(Block.Columns.projectId == projectId).deleteAll(db)
        }
        var heading = Block(projectId: projectId, sortOrder: 1, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true)
        var prose = Block(projectId: projectId, sortOrder: 2, blockType: .paragraph,
            textContent: "My own writing.", markdownFragment: "My own writing.", isNotes: true)
        var definition = Block(projectId: projectId, sortOrder: 3, blockType: .paragraph,
            textContent: "A real footnote.", markdownFragment: "[^1]: A real footnote.", isNotes: true)
        try projectDb.write { db in
            try heading.insert(db)
            try prose.insert(db)
            try definition.insert(db)
        }

        // T2: preconditions.
        #expect(prose.isNotes)
        #expect(FootnoteSyncService.parseNotesLabel(from: prose.markdownFragment) == nil)

        try projectDb.write { db in
            // `protectedHeadingIds: [heading.id]` -- deleteBlocksInRange never protects a
            // heading on its own; that is the CALLER's job (both real call sites compute
            // it via buildHeadingQueues before calling this). Passing it here is what a
            // realistic caller does, and isolates this test to protectingNotes's own
            // behavior rather than accidentally exercising a different mechanism.
            try projectDb.deleteBlocksInRange(
                db: db, projectId: projectId, startSortOrder: nil, endSortOrder: nil,
                protectedHeadingIds: [heading.id], protectingNotes: true
            )
        }

        let after = try TestFixtureFactory.fetchBlocks(from: projectDb)
        #expect(after.contains { $0.id == prose.id }, "User prose stays protected -- B3's narrowing is deferred to C1(3)")
        #expect(after.contains { $0.id == definition.id }, "The machine-owned definition is (still) protected")
        #expect(after.contains { $0.id == heading.id }, "The heading survives via the explicit protectedHeadingIds set")
    }

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
        #expect(notesHeadingsAfter.count == 1, "Exactly one Notes heading after reconciling with real-pipeline-derived refs -- no duplicate materialized")
    }
}
