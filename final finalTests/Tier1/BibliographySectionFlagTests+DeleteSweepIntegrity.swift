//
//  BibliographySectionFlagTests+DeleteSweepIntegrity.swift
//  final finalTests
//
//  Split out of BibliographySectionFlagTests+DataIntegrity.swift to keep that file under
//  SwiftLint's file_length limit. Same suite/fixture context applies -- see the header
//  comment in BibliographySectionFlagTests.swift for the full regression background, and
//  BibliographySectionFlagTests+DataIntegrity.swift's header for Round 2's context.
//
//  Covers: replacement input coverage for bibliographyGone's header-derived clause after
//  Issue 3's test flipped (17b), and a DB-level integration test proving
//  applySectionChanges' .deleteDuplicate case actually reassigns annotations and migrates
//  fields in the database, not just in the emitted SectionChange value (17c).
//

import Testing
import Foundation
@testable import final_final

extension BibliographySectionFlagTests {
    // MARK: - 17b. Replacement coverage for bibliographyGone's header-derived clause
    //
    // The ORIGINAL "Issue 3" test above (before this task's fix) was the only place exercising
    // `!headers.contains { $0.isBibliography }` -- the header-derived half of `bibliographyGone`'s
    // two-signal AND -- as distinct from the block-level half (`!bibliographyExistsInBlocks`,
    // covered on its own by test 16 above). Flipping that test's assertion (17, above) removed
    // that coverage; this test restores INPUT coverage for the same combination
    // (`bibliographyExistsInBlocks: false` + a header still claiming `isBibliography`), but a
    // careful trace shows it can no longer be a true MUTATION-coverage test of that specific
    // clause, and this comment says so plainly rather than claiming otherwise:
    //
    // `findBibliographyMatch`'s tier (a) ("already flagged -- match regardless of title/position
    // drift") is UNCONDITIONAL whenever at least one unmatched isBibliography row exists --
    // `bestFlaggedCandidate` never returns nil for a non-empty candidate list. So whenever a
    // header this pass claims isBibliography AND at least one bibliography row exists, that
    // header ALWAYS matches one such row, which means `bibliographyRowMatched` (the NEW check
    // this task added) is ALSO always true in that same call. Since the delete-sweep's exemption
    // requires `!bibliographyGone && !bibliographyRowMatched` (both), and `!bibliographyRowMatched`
    // is already false whenever the header-clause fires, `bibliographyGone`'s own value stops
    // being able to change the sweep's outcome for any row of that type in that call -- deleting
    // the header-clause from `bibliographyGone`'s definition would NOT be caught by any
    // reconcile()-level test, single-row or duplicate-row, because in every case where it could
    // matter, `bibliographyRowMatched` already forces the same "not exempt" outcome by itself.
    // (Reported to the coordinator alongside this diff rather than silently claiming the gap is
    // closed.) What this test DOES verify, honestly: the realistic single-row input combination
    // behaves correctly end-to-end -- the row is matched (not deleted) via ordinary tier (a)
    // matching, exercising `bibliographyGone`'s computation without asserting it discriminates
    // anything on its own.

    @Test("A single already-flagged bibliography row is matched, not deleted, when a header still claims it despite the block signal saying gone")
    func reconcileMatchesSingleFlaggedRowWhenHeaderClaimsFlagDespiteBlockSignalGone() {
        let rowId = UUID().uuidString
        let row = Section(
            id: rowId, projectId: projectId, sortOrder: 5, headerLevel: 1,
            isBibliography: true, title: "Old Bibliography Title",
            markdownContent: "# Old Bibliography Title\n\nOld entry.", wordCount: 5, startOffset: 200
        )

        // Title and content both deliberately mismatch the row -- if tier (a)'s match were
        // ever gated by passesMatchGate (it isn't; that's the point), this would fail to match.
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: "# References\n\nBrand new entry, nothing shared with the old row.",
            wordCount: 6, isBibliography: true
        )

        let changes = reconciler.reconcile(
            headers: [header], dbSections: [row], projectId: projectId,
            bibliographyExistsInBlocks: false
        )

        let deleted = changes.contains { change in
            switch change {
            case .delete(let id): return id == rowId
            case .deleteDuplicate(let loserId, _, _): return loserId == rowId
            case .insert, .update: return false
            }
        }
        #expect(!deleted, "A header still claiming isBibliography must match the sole flagged row, not sweep it")

        let matched = changes.contains { if case .update(let id, _) = $0 { return id == rowId }; return false }
        #expect(matched, "The row should be updated in place (tier a's unconditional match), not inserted as a duplicate")
    }

    // MARK: - 17c. DB-level integration: .deleteDuplicate's annotation reassignment and
    // status/tags/wordGoal migration actually happen, and in the right order
    //
    // Every `.deleteDuplicate`-related test in SectionReconcilerTests.swift and above only
    // checks the emitted SectionChange VALUE (that `.deleteDuplicate` carries the right
    // loserId/survivorId/survivorUpdates) -- reconcile() is a pure function and never touches
    // the database. Nothing until this test actually runs `applySectionChanges` against a real
    // database and confirms the annotation row and the survivor's fields were genuinely
    // written. In particular, ordering matters: `annotation.sectionId` is
    // `onDelete: .setNull`, so if the loser were deleted BEFORE its annotations were
    // reassigned, the FK trigger would null them out instead -- this test's first assertion is
    // the one that would fail if that ordering bug were reintroduced.
    @Test("applySectionChanges' .deleteDuplicate reassigns the loser's annotation and migrates its fields onto the survivor")
    func applySectionChangesDeleteDuplicateMigratesAnnotationAndFields() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let contentId = try db.dbWriter.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM content LIMIT 1")!
        }

        let survivor = Section(
            projectId: pid, sortOrder: 0, headerLevel: 2, isNotes: true, title: "Notes"
            // status/tags/wordGoal left at Section's own defaults (.next/[]/nil), so the
            // loser's real values below have something to migrate onto.
        )
        let loser = Section(
            projectId: pid, sortOrder: 1, headerLevel: 2, isNotes: true, title: "Notes",
            status: .final_, tags: ["from-loser"], wordGoal: 400
        )
        try db.insertSection(survivor)
        try db.insertSection(loser)

        let annotation = Annotation(
            contentId: contentId, sectionId: loser.id, type: .comment,
            text: "A real user annotation attached to the loser row.", charOffset: 10
        )
        try db.insertAnnotation(annotation)

        let survivorUpdates = SectionUpdates(status: .final_, tags: ["from-loser"], wordGoal: 400)
        try db.applySectionChanges(
            [.deleteDuplicate(loserId: loser.id, survivorId: survivor.id, survivorUpdates: survivorUpdates)],
            for: pid
        )

        let migratedAnnotation = try #require(try db.fetchAnnotation(id: annotation.id))
        #expect(
            migratedAnnotation.sectionId == survivor.id,
            """
            The annotation must be reassigned onto the survivor, not left nil -- nil would mean \
            annotation.sectionId's onDelete: .setNull FK trigger fired before the reassignment \
            ran, i.e. the loser was deleted first
            """
        )

        let migratedSurvivor = try #require(try db.fetchSection(id: survivor.id))
        #expect(migratedSurvivor.status == .final_, "The loser's real status must have migrated onto the survivor")
        #expect(migratedSurvivor.tags == ["from-loser"], "The loser's real tags must have migrated onto the survivor")
        #expect(migratedSurvivor.wordGoal == 400, "The loser's real wordGoal must have migrated onto the survivor")

        let deletedLoser = try db.fetchSection(id: loser.id)
        #expect(deletedLoser == nil, "The loser row itself must be gone")
    }
}
