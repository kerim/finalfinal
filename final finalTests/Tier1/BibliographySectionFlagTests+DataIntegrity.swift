//
//  BibliographySectionFlagTests+DataIntegrity.swift
//  final finalTests
//
//  Split out of BibliographySectionFlagTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit (400 lines). Same suite/fixture context applies -- see
//  the header comment in BibliographySectionFlagTests.swift for the full regression
//  background (Section.isBibliography's missing production writer, and the parseHeaders /
//  SectionReconciler / SnapshotService fix), and its @Suite comment for why `.serialized` is
//  applied (it guards handleBibliographySectionChangedSyncsSectionTableImmediately below,
//  which mutates the process-wide DocumentManager.shared singleton).
//
//  These tests cover Round 2's three judge-approved follow-up fixes: the same-titled-row
//  match-gate tightening (Issue 1), bibliography-block preservation during snapshot restores
//  (Issue 2), and the two-signal flagged-row delete sweep (Issue 3) -- plus the buildUpdates
//  content-refresh test and the handleBibliographySectionChanged sync-back/staleness wiring
//  test that round out the same "Round 2" comment block below.
//

import Testing
import Foundation
@testable import final_final

extension BibliographySectionFlagTests {

    // MARK: - Round 2: judge-approved follow-up fixes (3 issues)
    //
    // Issue 1: findBibliographyMatch had a second, UNBOUNDED, ungated "same title anywhere"
    // tier that could permanently convert a user's real, distant, same-titled section (e.g. a
    // chapter titled "References" in an edited volume) into the flagged bibliography row.
    // Removed -- passesMatchGate already treats title equality as evidence at both the exact
    // and ±3 in-range tiers, so no real coverage is lost.
    //
    // Issue 2: replaceBlocks' unconditional delete-and-replace permanently wiped the
    // bibliography during a section restore, since rebuildContentFromSections() excludes
    // isBibliography sections from the markdown that gets re-parsed into `blocks`. Fixed via
    // an opt-in `preservingMachineManagedBlocks` parameter, scoped to bibliography ONLY.
    // Notes gets no such protection because it needs none: Notes content is actually absent
    // from that re-parsed markdown too (Section.isNotes has no production writer, so
    // parseHeaders never emits a "Notes" section boundary), so there is nothing there to
    // protect or duplicate.
    //
    // Issue 3: a Section row flagged isBibliography was permanently exempt from the delete
    // sweep, even after the real bibliography was completely gone. Fixed via
    // `bibliographyExistsInBlocks`, a second signal broader than the heading-only
    // `fetchBibliographyHeadingTitle` query (an orphaned non-heading block could otherwise be
    // invisible to it) -- the row is only deleted when BOTH signals agree the bibliography is
    // gone.

    // MARK: - 9. Issue 1: a distant (8+ positions away) same-titled row must NOT self-heal

    @Test("Issue 1: a same-titled unflagged row 8+ positions away from the bibliography header is not matched")
    func findBibliographyMatchDoesNotHealDistantSameTitledRow() {
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: "# References\n\nBrand new entry.", wordCount: 4, isBibliography: true
        )
        let distantId = UUID().uuidString
        let distantSameTitledRow = Section(
            id: distantId, projectId: projectId, sortOrder: 8, headerLevel: 1,
            isBibliography: false, title: "References",
            markdownContent: "Some entirely different chapter that happens to share a title.",
            wordCount: 10, startOffset: 900
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [distantSameTitledRow], projectId: projectId)

        let updatedDistantIntoBibliography = changes.contains {
            if case .update(let id, let updates) = $0 { return id == distantId && updates.isBibliography == true }
            return false
        }
        let insertedBibliography = changes.contains {
            if case .insert(let section) = $0 { return section.isBibliography && section.title == "References" }
            return false
        }
        let deletedDistantRow = changes.contains {
            if case .delete(let id) = $0 { return id == distantId }
            return false
        }

        #expect(!updatedDistantIntoBibliography, "A same-titled row 8+ positions away must never be flipped into the bibliography by title alone")
        #expect(insertedBibliography, "A fresh bibliography Section must be inserted instead")
        #expect(
            deletedDistantRow,
            "The distant row, now matched by nothing (neither bibliography-flagged nor notes-flagged), must be swept by the normal delete sweep"
        )
    }

    // MARK: - 10. Issue 1: a nearby (within ±3) same-titled row still self-heals

    @Test("Issue 1: a same-titled unflagged row within ±3 of the bibliography header still self-heals via the bounded in-range tier")
    func findBibliographyMatchStillHealsNearbySameTitledRow() {
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: "# References\n\nBrand new entry.", wordCount: 4, isBibliography: true
        )
        let nearbyId = UUID().uuidString
        // Content deliberately unrelated (no prefix/suffix overlap) so the match can ONLY be
        // explained by passesMatchGate's title-equality clause, not contentRelated -- proving
        // the bounded ±3 tier alone (no separate unbounded title tier) still carries this case.
        let nearbySameTitledRow = Section(
            id: nearbyId, projectId: projectId, sortOrder: 3, headerLevel: 1,
            isBibliography: false, title: "References",
            markdownContent: "Completely unrelated stale content.",
            wordCount: 3, startOffset: 300
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [nearbySameTitledRow], projectId: projectId)

        #expect(changes.count == 1, "Exactly one change: the flag flip (plus whatever position update) on the nearby row -- no insert, no delete")
        guard case .update(let id, let updates) = changes.first else {
            Issue.record("Expected a single .update change, got \(changes)")
            return
        }
        #expect(id == nearbyId)
        #expect(updates.isBibliography == true, "The nearby same-titled row must still self-heal via the bounded ±3 tier")
    }

    // MARK: - 11. Issue 2: restoreSectionReplace preserves bibliography blocks

    @Test("Issue 2: restoreSectionReplace preserves bibliography block count and heading id (must fail before preservingMachineManagedBlocks)")
    @MainActor
    func restoreSectionReplacePreservesBibliographyBlocks() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // TestFixtureFactory.createTemporary only parses richTestContent into the Block table --
        // the Section table is populated by SectionSyncService in the real app, not by fixture
        // creation, so db.fetchSections(projectId:) is empty here unless sections are inserted
        // explicitly. Run the real parse+reconcile pipeline against an empty dbSections set (a
        // first-ever sync) to derive the Section rows richTestContent would actually produce,
        // including the flagged "References" bibliography row -- matches
        // VersionHistoryRestoreTests' documented pattern for this same gap.
        let headers = SectionSyncService.parseHeaders(from: TestFixtureFactory.richTestContent, existingBibTitle: "References")
        let sectionChanges = reconciler.reconcile(headers: headers, dbSections: [], projectId: pid)
        let sections: [Section] = sectionChanges.compactMap {
            if case .insert(let section) = $0 { return section }
            return nil
        }
        try db.replaceSections(sections, for: pid)

        let bibBlocksBefore = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        let bibHeadingBefore = try #require(bibBlocksBefore.first { $0.blockType == .heading })
        #expect(bibBlocksBefore.count == 5, "Precondition: richTestContent's References section is a heading + 4 entries")

        let snapshotService = SnapshotService(database: db, projectId: pid)
        let snapshot = try snapshotService.createManualSnapshot(name: "Before")
        let snapshotSections = try db.fetchSnapshotSections(snapshotId: snapshot.id)

        // A trivial no-op restore of the FIRST (non-bibliography) section is enough to trigger
        // rebuildContentFromSections -> BlockParser.parse -> replaceBlocks, the exact path
        // that used to wipe the bibliography entirely.
        let introSnapshot = try #require(snapshotSections.first { $0.title == "Research Paper Draft" })
        let introSection = try #require(try db.fetchSections(projectId: pid).first { $0.title == "Research Paper Draft" })

        try snapshotService.restoreSectionReplace(
            snapshotSectionId: introSnapshot.id,
            targetSectionId: introSection.id,
            createSafetyBackup: false
        )

        let bibBlocksAfter = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        #expect(bibBlocksAfter.count == bibBlocksBefore.count, "Bibliography block count must survive a single-section restore unchanged")
        let bibHeadingAfter = try #require(bibBlocksAfter.first { $0.blockType == .heading })
        #expect(bibHeadingAfter.id == bibHeadingBefore.id, "The bibliography heading's block id must be preserved, not recreated")
    }

    // MARK: - 12. Issue 2: restoreSectionAsDuplicate preserves bibliography blocks

    @Test("Issue 2: restoreSectionAsDuplicate preserves bibliography block count and heading id (must fail before preservingMachineManagedBlocks)")
    @MainActor
    func restoreSectionAsDuplicatePreservesBibliographyBlocks() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // TestFixtureFactory.createTemporary only parses richTestContent into the Block table --
        // the Section table is populated by SectionSyncService in the real app, not by fixture
        // creation, so db.fetchSections(projectId:) is empty here unless sections are inserted
        // explicitly. Run the real parse+reconcile pipeline against an empty dbSections set (a
        // first-ever sync) to derive the Section rows richTestContent would actually produce,
        // including the flagged "References" bibliography row -- matches
        // VersionHistoryRestoreTests' documented pattern for this same gap.
        let headers = SectionSyncService.parseHeaders(from: TestFixtureFactory.richTestContent, existingBibTitle: "References")
        let sectionChanges = reconciler.reconcile(headers: headers, dbSections: [], projectId: pid)
        let sections: [Section] = sectionChanges.compactMap {
            if case .insert(let section) = $0 { return section }
            return nil
        }
        try db.replaceSections(sections, for: pid)

        let bibBlocksBefore = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        let bibHeadingBefore = try #require(bibBlocksBefore.first { $0.blockType == .heading })
        #expect(bibBlocksBefore.count == 5, "Precondition: richTestContent's References section is a heading + 4 entries")

        let snapshotService = SnapshotService(database: db, projectId: pid)
        let snapshot = try snapshotService.createManualSnapshot(name: "Before")
        let snapshotSections = try db.fetchSnapshotSections(snapshotId: snapshot.id)

        let introSnapshot = try #require(snapshotSections.first { $0.title == "Research Paper Draft" })
        let introSection = try #require(try db.fetchSections(projectId: pid).first { $0.title == "Research Paper Draft" })

        try snapshotService.restoreSectionAsDuplicate(
            snapshotSectionId: introSnapshot.id,
            insertAfterSectionId: introSection.id,
            createSafetyBackup: false
        )

        let bibBlocksAfter = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        #expect(bibBlocksAfter.count == bibBlocksBefore.count, "Bibliography block count must survive a duplicate-as-section restore unchanged")
        let bibHeadingAfter = try #require(bibBlocksAfter.first { $0.blockType == .heading })
        #expect(bibHeadingAfter.id == bibHeadingBefore.id, "The bibliography heading's block id must be preserved, not recreated")
    }

    // MARK: - 13. Issue 2 regression: restoreEntireProject's default path is unaffected

    @Test(
        """
        Regression: restoreEntireProject's default (preservingMachineManagedBlocks: false) path \
        still fully reconstructs the bibliography from the snapshot's complete markdown
        """
    )
    @MainActor
    func restoreEntireProjectDefaultPathUnaffected() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let snapshotService = SnapshotService(database: db, projectId: pid)
        let snapshot = try snapshotService.createManualSnapshot(name: "Full snapshot")

        let bibBlocksBefore = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        #expect(bibBlocksBefore.count == 5)

        // Wipe current state entirely so the only way bibliography blocks can reappear is via
        // restoreEntireProject's default (preservingMachineManagedBlocks: false) full
        // rebuild-from-snapshot-markdown path -- proving that path is unaffected by the new
        // parameter's existence.
        try db.deleteAllBlocks(projectId: pid)
        try db.deleteAllSections(projectId: pid)

        try snapshotService.restoreEntireProject(from: snapshot.id, createSafetyBackup: false)

        let bibBlocksAfter = try db.fetchBlocks(projectId: pid).filter { $0.isBibliography }
        #expect(
            bibBlocksAfter.count == bibBlocksBefore.count,
            """
            restoreEntireProject's default path must still fully reconstruct the bibliography from the \
            snapshot's complete markdown, unaffected by preservingMachineManagedBlocks
            """
        )
    }

    // MARK: - 14. Issue 2 MUST-FIX: Notes is never protected by preservingMachineManagedBlocks

    @Test("Issue 2 MUST-FIX: preservingMachineManagedBlocks never protects Notes -- an unlabeled continuation body block is not duplicated")
    func replaceBlocksPreservingBibliographyDoesNotDuplicateNotesContinuation() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let introHeadingId = UUID().uuidString
        let notesHeadingId = UUID().uuidString
        let labeledEntryId = UUID().uuidString
        let continuationId = UUID().uuidString

        // Seed a Notes section shaped like a labeled entry PLUS an unlabeled continuation
        // paragraph -- the shape handleMachineManagedBlock's label-matching merge cannot dedupe
        // (it only prevents duplication when it can parse a "[^N]:" label from the incoming
        // block).
        let seedBlocks: [Block] = [
            Block(id: introHeadingId, projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text.", markdownFragment: "Body text."),
            Block(id: notesHeadingId, projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(id: labeledEntryId, projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "[^1]: Some footnote text.", markdownFragment: "[^1]: Some footnote text.",
                  isNotes: true),
            Block(id: continuationId, projectId: pid, sortOrder: 4, blockType: .paragraph,
                  textContent: "Continuation with no footnote label.",
                  markdownFragment: "Continuation with no footnote label.", isNotes: true)
        ]
        try db.replaceBlocks(seedBlocks, for: pid)

        let notesBlocksBefore = try db.fetchBlocks(projectId: pid).filter { $0.isNotes }
        #expect(notesBlocksBefore.count == 3, "Precondition: heading + labeled entry + unlabeled continuation")

        // Simulate a section-restore's freshly re-parsed `blocks`: brand-new Block instances
        // (fresh ids, as BlockParser.parse would produce) carrying the SAME Notes content.
        // This is a hand-built stand-in, not today's real shape: the actual
        // rebuildContentFromSections path never produces Notes content in `blocks` (Notes
        // has no production writer for Section.isNotes, so parseHeaders never emits a
        // "Notes" section boundary to re-parse). We construct it anyway to exercise the
        // theoretical duplication hazard the preservation code guards against -- this test
        // validates defense-in-depth, not a scenario that occurs in production yet.
        let newBlocks: [Block] = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text.", markdownFragment: "Body text."),
            Block(projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "[^1]: Some footnote text.", markdownFragment: "[^1]: Some footnote text.",
                  isNotes: true),
            Block(projectId: pid, sortOrder: 4, blockType: .paragraph,
                  textContent: "Continuation with no footnote label.",
                  markdownFragment: "Continuation with no footnote label.", isNotes: true)
        ]

        try db.replaceBlocks(newBlocks, for: pid, preservingMachineManagedBlocks: true)

        let notesBlocksAfter = try db.fetchBlocks(projectId: pid).filter { $0.isNotes }
        #expect(
            notesBlocksAfter.count == 3,
            """
            Notes must go through the normal delete-and-reinsert flow, not be preserved -- a count > 3 \
            means the unlabeled continuation was preserved AND its freshly-parsed duplicate also inserted
            """
        )

        let notesHeadingAfter = try #require(notesBlocksAfter.first { $0.blockType == .heading })
        #expect(
            notesHeadingAfter.id == notesHeadingId,
            """
            The Notes heading id is still preserved by the ordinary title-match queue -- \
            protectingNotes:false only removes its immortality from the delete sweep, not its eligibility to be popped
            """
        )
    }

    // MARK: - 15. Issue 3: flagged row deleted once BOTH signals agree the bibliography is gone

    @Test("Issue 3: a flagged bibliography row is deleted once BOTH signals agree the bibliography is gone")
    func reconcileDeletesFlaggedRowWhenBibliographyGoneByBothSignals() {
        let orphanedId = UUID().uuidString
        let orphanedFlaggedRow = Section(
            id: orphanedId, projectId: projectId, sortOrder: 5, headerLevel: 1,
            isBibliography: true, title: "References",
            markdownContent: "# References\n\nOld entry.", wordCount: 5, startOffset: 200
        )

        // No parsed header claims isBibliography (the heading is gone from the document) AND
        // bibliographyExistsInBlocks: false (no isBibliography block survives at all) --
        // both signals agree the bibliography is completely gone.
        let changes = reconciler.reconcile(
            headers: [], dbSections: [orphanedFlaggedRow], projectId: projectId,
            bibliographyExistsInBlocks: false
        )

        let deletedOrphan = changes.contains { if case .delete(let id) = $0 { return id == orphanedId }; return false }
        #expect(deletedOrphan, "Both signals agreeing the bibliography is gone must sweep the stale flagged row, not leave it immortal")
    }

    // MARK: - 16. Issue 3 MUST-FIX: flagged row survives when only the heading is gone

    @Test("Issue 3 MUST-FIX: a flagged row survives when the heading is gone but an orphaned block still carries the flag")
    func reconcileKeepsFlaggedRowWhenOrphanedBlockStillExists() {
        let orphanedId = UUID().uuidString
        let orphanedFlaggedRow = Section(
            id: orphanedId, projectId: projectId, sortOrder: 5, headerLevel: 1,
            isBibliography: true, title: "References",
            markdownContent: "# References\n\nOld entry.", wordCount: 5, startOffset: 200
        )

        // No parsed header claims isBibliography (the HEADING is gone) -- but
        // bibliographyExistsInBlocks: true simulates an orphaned entry/terminator block still
        // surviving at the block level, which the heading-only fetchBibliographyHeadingTitle
        // query could never see. This is the exact gap the must-fix closes: a caller that used
        // fetchBibliographyHeadingTitle alone (nil) would have wrongly reported "gone".
        let changes = reconciler.reconcile(
            headers: [], dbSections: [orphanedFlaggedRow], projectId: projectId,
            bibliographyExistsInBlocks: true
        )

        let deletedOrphan = changes.contains { if case .delete(let id) = $0 { return id == orphanedId }; return false }
        #expect(
            !deletedOrphan,
            """
            The block-level signal alone says the bibliography survives -- the row must stay immortal \
            despite the heading being gone from parsed headers
            """
        )
    }

    // MARK: - 17. Issue 3: two-signal AND -- a parsed header still claiming the flag protects an orphan too

    @Test(
        """
        Issue 3: two-signal AND -- a flagged row survives when a parsed header still carries the flag \
        even if the block-level check alone would say gone
        """
    )
    func reconcileKeepsOrphanedFlaggedRowWhenHeaderStillClaimsFlag() {
        // Two Section rows both flagged isBibliography (a contrived duplicate-row scenario,
        // used purely to isolate the boolean logic): the real one at sortOrder 0 will be
        // claimed by findBibliographyMatch's tier (a) (already-flagged match), leaving the
        // orphan at sortOrder 5 unmatched and reaching the delete-sweep check.
        let realId = UUID().uuidString
        let realRow = Section(
            id: realId, projectId: projectId, sortOrder: 0, headerLevel: 1,
            isBibliography: true, title: "References",
            markdownContent: "# References\n\nCurrent entry.", wordCount: 5, startOffset: 0
        )
        let orphanedId = UUID().uuidString
        let orphanedFlaggedRow = Section(
            id: orphanedId, projectId: projectId, sortOrder: 5, headerLevel: 1,
            isBibliography: true, title: "References",
            markdownContent: "# References\n\nStale duplicate entry.", wordCount: 5, startOffset: 500
        )

        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: "# References\n\nCurrent entry.", wordCount: 5, isBibliography: true
        )

        // bibliographyExistsInBlocks: false -- the block-level signal ALONE would say "gone"
        // (e.g. a stale/racy read) -- but a parsed header in THIS pass still carries the flag,
        // so the two-signal AND must keep bibliographyGone false.
        let changes = reconciler.reconcile(
            headers: [header], dbSections: [realRow, orphanedFlaggedRow], projectId: projectId,
            bibliographyExistsInBlocks: false
        )

        let deletedOrphan = changes.contains { if case .delete(let id) = $0 { return id == orphanedId }; return false }
        #expect(
            !deletedOrphan,
            "A parsed header still claiming isBibliography must protect the orphan even when the block-level check alone would say gone"
        )
    }

    // MARK: - 18. buildUpdates refreshes a stale flagged row's title/markdownContent/wordCount
    //
    // Distinct from test 3 in BibliographySectionFlagTests.swift (which pins the
    // flag-flip-alone case, everything else already matching): here the row is ALREADY
    // flagged, and the thing under test is that findBibliographyMatch's tier (a) direct match
    // ("already flagged -- match regardless of title/position drift") feeds into the SAME
    // buildUpdates() as every ordinary section, so a stale title/markdownContent/wordCount on
    // that row gets refreshed like any other field change -- this reconcile-through-
    // buildUpdates path never ran for the bibliography row at all before this task
    // (parseHeaders used to drop the heading from its output entirely).

    @Test("Reconcile refreshes an already-flagged bibliography row's stale title, markdownContent, and wordCount")
    func reconcileRefreshesStaleContentOnAlreadyFlaggedRow() {
        let existingId = UUID().uuidString
        let existing = Section(
            id: existingId, projectId: projectId, sortOrder: 0, headerLevel: 1,
            isBibliography: true, title: "Bibliography",
            markdownContent: "# Bibliography\n\nOld entry.", wordCount: 5, startOffset: 0
        )
        let newContent = "# References\n\nOld entry.\n\nNew entry just added.\n"
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: newContent, wordCount: 12, isBibliography: true
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [existing], projectId: projectId)

        #expect(
            changes.count == 1,
            """
            Exactly one change: the content refresh -- the row is matched directly via \
            findBibliographyMatch's already-flagged tier (a), regardless of the title drift
            """
        )
        guard case .update(let id, let updates) = changes.first else {
            Issue.record("Expected a single .update change, got \(changes)")
            return
        }
        #expect(id == existingId)
        #expect(updates.title == "References", "Stale title must be refreshed")
        #expect(updates.markdownContent == newContent, "Stale markdownContent must be refreshed")
        #expect(updates.wordCount == 12, "Stale wordCount must be refreshed")
        #expect(updates.isBibliography == nil, "Already-flagged -- the flip branch must not fire (no redundant write)")
    }

    // MARK: - 19. Wiring fix: handleBibliographySectionChanged must sync the section table
    // immediately, not only on the user's next keystroke
    //
    // handleBibliographySectionChanged() assigns `editorState.content = result.markdown` while
    // contentState == .bibliographyUpdate. In the real running app,
    // ViewNotificationModifiers.handleContentChange's `guard editorState.contentState == .idle
    // else { return }` silently drops the onChange(of: editorState.content) firing for that
    // exact assignment, so sectionSyncService never saw the fresh content -- the `section`
    // table stayed stale until the user's next keystroke re-triggered onChange. This test
    // exercises the REAL production code path (ContentView.handleBibliographySectionChanged(),
    // not a simulated stand-in): a bare, unmounted ContentView() never has SwiftUI's
    // .onChange(of:) modifier active regardless of contentState (same constraint established
    // by ContentViewSectionReorderTests.swift's doc comment), so this harness reproduces
    // exactly the "swallowed" condition production hits, and proves the fix -- an explicit
    // `sectionSyncService.syncNow(editorState.content)` call added right after contentState
    // returns to .idle -- actually closes the gap. Without that line, this test fails: nothing
    // else in the function's Task ever touches sectionSyncService.
    @Test(
        """
        MUST-FIX 2 (wiring): handleBibliographySectionChanged syncs the section table's bibliography row \
        immediately once contentState returns to idle
        """
    )
    @MainActor
    func handleBibliographySectionChangedSyncsSectionTableImmediately() async throws {
        let content1 = """
        # Introduction

        Some intro text citing prior work.

        # References

        Doe, J. (2020). An Early Paper.

        <!-- ::auto-bibliography-end:: -->
        """
        let content2 = """
        # Introduction

        Some intro text citing prior work.

        # References

        Doe, J. (2020). An Early Paper.

        Smith, A. (2021). A Later Paper.

        <!-- ::auto-bibliography-end:: -->
        """

        let db = try TestFixtureFactory.createTemporary(content: content1)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Bring the `section` table to steady state for content1 first -- mirrors
        // production's own reconcile pass (same pattern as
        // integrationSelfHealsLegacySectionRowOverTwoPasses above).
        func runReconcilePass(_ markdown: String) throws {
            let dbSections = try db.fetchSections(projectId: pid)
            let existingBibTitle = try db.fetchBibliographyHeadingTitle(projectId: pid)
                ?? dbSections.first(where: { $0.isBibliography })?.title
            let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: existingBibTitle)
            let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: pid)
            try db.applySectionChanges(changes, for: pid)
        }
        try runReconcilePass(content1)

        let bibRowBefore = try #require(try db.fetchSections(projectId: pid).first { $0.isBibliography })
        #expect(
            !bibRowBefore.markdownContent.contains("Smith"),
            "Precondition: section table starts at content1's (pre-regeneration) content"
        )

        // Simulate a bibliography regeneration that has already landed in the `block` table
        // (what BibliographySyncService does) but NOT yet in the `section` table -- exactly
        // the moment `.bibliographySectionChanged` fires in production.
        let newBlocks = BlockParser.parse(markdown: content2, projectId: pid)
        try db.replaceBlocks(newBlocks, for: pid)

        // DocumentManager.shared is a process-wide singleton -- save/restore (same pattern as
        // StructuralUndoBarrierTests.swift).
        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid
        defer {
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
        }

        let view = ContentView()
        view.editorState.content = content1
        view.editorState.contentState = .idle
        view.sectionSyncService.configure(database: db, projectId: pid)

        // handleBibliographySectionChanged() is not itself async -- it sets contentState
        // synchronously and kicks off a fire-and-forget Task, so poll for the DB write rather
        // than assuming it has landed by the time the call returns.
        view.handleBibliographySectionChanged()

        var sawFreshContent = false
        for _ in 0..<50 {
            if let row = try db.fetchSections(projectId: pid).first(where: { $0.isBibliography }),
               row.markdownContent.contains("Smith") {
                sawFreshContent = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(
            sawFreshContent,
            """
            The `section` table's bibliography row must reflect the fresh block-table content \
            immediately after handleBibliographySectionChanged() settles back to idle -- not only \
            after the user's next keystroke re-triggers onChange(of: editorState.content)
            """
        )
    }
}
