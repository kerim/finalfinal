//
//  NotesSectionFlagTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Section.isNotes had no production writer: every `isNotes: true` write constructed a
//  `Block`, never a `Section` -- SectionSyncService.parseHeaders detected the machine-managed
//  Notes heading (`header.title == notesHeaderName && existingNotesTitle != nil`) but latched
//  `inAutoNotes` on bare title equality alone, with no evidence and no closing condition,
//  swallowing every boundary from that heading to end-of-document rather than emitting a
//  flagged ParsedHeader. Combined with `replaceBlocks`' bibliography-only preservation path,
//  a single-section version-history restore permanently deleted the real Notes rows (heading,
//  labeled entries, and any unlabeled continuation text) with nothing in the freshly re-parsed
//  `blocks` to replace them -- real footnote TEXT loss, not just a placeholder.
//
//  FIX (mirrors the already-shipped isBibliography fix):
//  - `parseHeaders` now defers the "existingNotesTitle != nil" branch's decision instead of
//    latching immediately on bare title match (MUST-FIX 1): it adds the heading as an ordinary
//    boundary and only retroactively flags it `isNotes` once real footnote-definition evidence
//    ("[^N]:") is found beneath it, exactly like the pre-existing "existingNotesTitle == nil"
//    import-auto-detection branch already did. Headers after the candidate are never swallowed
//    either way, closing the unbounded-swallow bug (see test 6). The `selectBibliographyOpeningOffset`
//    pre-scan's own separate `inAutoNotes` copy is fixed too, via level-scoped closing (the
//    smaller, more surgical mirror given that function has no multi-line lookahead available).
//  - `SectionReconciler` routes flagged Notes headers through a dedicated match path
//    (`findNotesMatch`, mirroring `findBibliographyMatch` exactly -- no unbounded title tier,
//    no pure-proximity fallback) and a `notesGone` two-signal escape hatch mirroring
//    `bibliographyGone` (test not duplicated here; covered structurally by tests 3-4).
//  - `Database+BlocksReplace.swift`'s `replaceBlocks` now protects Notes on equal footing with
//    bibliography in its `preservingMachineManagedBlocks` path (test 1).
//  - `SnapshotService.rebuildContentFromSections` now excludes `isNotes` sections from the
//    markdown it re-parses into `blocks`, alongside `isBibliography` -- load-bearing: without
//    it, a restored `blocks` array would carry real Notes content again, colliding with the
//    replaceBlocks fix above.
//

import Testing
import Foundation
@testable import final_final

@Suite("Notes Section Flag — Tier 1: Silent Killers")
struct NotesSectionFlagTests {

    let reconciler = SectionReconciler()
    let projectId = "test-project-id"

    // MARK: - 1. Restore-path repro (most important): real footnote TEXT survives

    @Test("Restore-path repro: a single-section restore preserves real footnote TEXT, not just an empty placeholder")
    func restorePathPreservesRealFootnoteText() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let fullMarkdown = """
        # Intro

        Some intro text with a citation[^1].

        # Notes

        [^1]: A real, specific footnote about the archival method used.
        """

        let seedBlocks = BlockParser.parse(markdown: fullMarkdown, projectId: pid)
        try db.replaceBlocks(seedBlocks, for: pid)

        let notesBlocksBefore = try db.fetchBlocks(projectId: pid).filter { $0.isNotes }
        #expect(
            notesBlocksBefore.contains { $0.textContent.contains("A real, specific footnote") },
            "Precondition: the real footnote text exists before the restore"
        )

        // Simulate a single-section restore's freshly re-parsed `blocks`: rebuildContentFromSections
        // now excludes isNotes sections (Part 3), exactly like isBibliography ones, so this is
        // the PRODUCTION shape -- no Notes content at all, not a hand-built stand-in.
        let restoredMarkdown = """
        # Intro

        Some intro text with a citation[^1].
        """
        let newBlocks = BlockParser.parse(markdown: restoredMarkdown, projectId: pid)

        try db.replaceBlocks(newBlocks, for: pid, preservingMachineManagedBlocks: true)

        let notesBlocksAfter = try db.fetchBlocks(projectId: pid).filter { $0.isNotes }
        #expect(
            notesBlocksAfter.contains { $0.textContent.contains("A real, specific footnote about the archival method used.") },
            "The real footnote TEXT must survive the restore -- not deleted with nothing to replace it"
        )
    }

    // MARK: - 2. parseHeaders emits the Notes heading (previously dropped) when evidence exists

    @Test("parseHeaders emits the Notes heading as a flagged ParsedHeader when real footnote content is present")
    func parseHeadersEmitsFlaggedNotesHeader() {
        let markdown = """
        # Introduction

        Some intro text.

        # Notes

        [^1]: A real footnote with genuine evidence beneath the heading.
        """

        // existingNotesTitle: "Notes" exercises the specific branch MUST-FIX 1 fixes (the
        // "existingNotesTitle != nil" branch), not the import-auto-detection sibling.
        let headers = SectionSyncService.parseHeaders(from: markdown, existingNotesTitle: "Notes")

        let notesHeader = headers.first { $0.title == "Notes" }
        #expect(notesHeader != nil, "The Notes heading must be emitted as a ParsedHeader, not dropped from the output")
        #expect(notesHeader?.isNotes == true)

        // Sanity: the ordinary heading before it must NOT be flagged.
        let introHeader = headers.first { $0.title == "Introduction" }
        #expect(introHeader?.isNotes == false)
    }

    // MARK: - 3. reconcile() inserts a flagged Section when no notes row exists yet

    @Test("reconcile() inserts a Section flagged isNotes when no notes row exists yet")
    func reconcileInsertsFlaggedNotesSectionWhenNoneExists() {
        let header = ParsedHeader(
            position: 0, title: "Notes", level: 1, isPseudoSection: false, startOffset: 0,
            markdownContent: "# Notes\n\n[^1]: A footnote.", wordCount: 4, isNotes: true
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [], projectId: projectId)

        #expect(changes.count == 1)
        guard case .insert(let section) = changes.first else {
            Issue.record("Expected a single .insert change, got \(changes)")
            return
        }
        #expect(section.isNotes)
        #expect(section.title == "Notes")
    }

    // MARK: - 4. reconcile() self-heals an existing unflagged Notes row rather than duplicating it

    @Test("reconcile() self-heals an existing unflagged Notes row rather than duplicating it")
    func reconcileSelfHealsUnflaggedNotesRow() {
        let existingId = UUID().uuidString
        let existing = Section(
            id: existingId, projectId: projectId, sortOrder: 0, headerLevel: 1,
            isNotes: false, title: "Notes", markdownContent: "# Notes\n\n[^1]: A footnote.",
            wordCount: 4, startOffset: 0
        )
        let header = ParsedHeader(
            position: 0, title: "Notes", level: 1, isPseudoSection: false, startOffset: 0,
            markdownContent: "# Notes\n\n[^1]: A footnote.", wordCount: 4, isNotes: true
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [existing], projectId: projectId)

        #expect(changes.count == 1, "Exactly one change: the flag flip -- no insert, no delete, no duplicate row")
        guard case .update(let id, let updates) = changes.first else {
            Issue.record("Expected a single .update change, got \(changes)")
            return
        }
        #expect(id == existingId)
        #expect(updates.isNotes == true)
    }

    // MARK: - 5. MUST-FIX 3: zoomedExisting/bodyHeaders index alignment with a flagged Notes row

    @Test(
        """
        MUST-FIX 3: a zoomed section set that includes a flagged Notes row does not misalign the \
        index-paired zoomed sync and delete (or corrupt) an unrelated trailing section
        """
    )
    @MainActor
    func zoomedSyncExcludesNotesRowFromIndexAlignment() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let alpha = Section(
            projectId: pid, sortOrder: 0, headerLevel: 1,
            title: "Alpha", markdownContent: "# Alpha\n\nAlpha text.\n",
            wordCount: 2, startOffset: 0
        )
        let beta = Section(
            projectId: pid, sortOrder: 1, headerLevel: 1,
            title: "Beta", markdownContent: "# Beta\n\nBeta text.\n",
            wordCount: 2, startOffset: 30
        )
        let notes = Section(
            projectId: pid, sortOrder: 2, headerLevel: 1, isNotes: true,
            title: "Notes", markdownContent: "# Notes\n\n[^1]: Old footnote.\n",
            wordCount: 3, startOffset: 60
        )
        let gamma = Section(
            projectId: pid, sortOrder: 3, headerLevel: 1,
            title: "Gamma", markdownContent: "# Gamma\n\nGamma text.\n",
            wordCount: 2, startOffset: 90
        )
        try db.replaceSections([alpha, beta, notes, gamma], for: pid)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: pid)

        // Unlike the bibliography version of this test (bibliography content is structurally
        // excluded from zoom markdown), this zoomed content INCLUDES the real Notes heading
        // with genuine footnote-definition evidence -- this is what actually exercises the
        // `bodyHeaders` filter fix: without `!$0.isNotes` there, this flagged header would
        // stay in `bodyHeaders` while `zoomedExisting` (which already excludes isNotes rows)
        // would not, misaligning every subsequent index-paired comparison.
        let zoomedIds: Set<String> = [beta.id, notes.id, gamma.id]
        let editedZoomedMarkdown = """
        # Beta

        Beta text.

        # Notes

        [^1]: Old footnote.

        # Gamma

        Gamma text.
        """

        syncService.contentChanged(editedZoomedMarkdown, zoomedIds: zoomedIds)
        // contentChanged debounces for 500ms before syncing; leave generous headroom.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let sectionsAfter = try db.fetchSections(projectId: pid)
        #expect(sectionsAfter.count == 4, "No section may be spuriously deleted or inserted")

        let gammaAfter = try #require(sectionsAfter.first { $0.id == gamma.id })
        #expect(gammaAfter.title == "Gamma", "Gamma must survive the zoomed sync untouched")
        #expect(
            gammaAfter.markdownContent.contains("Gamma text."),
            "Gamma's content must not be dropped by a misaligned index pairing"
        )

        let notesAfter = try #require(sectionsAfter.first { $0.id == notes.id })
        #expect(notesAfter.isNotes, "The Notes row must remain flagged")
        #expect(
            notesAfter.markdownContent.contains("Old footnote."),
            "The Notes row's content must not be overwritten by an unrelated header (e.g. Gamma's) due to index misalignment"
        )
    }

    // MARK: - 6. MUST-FIX 1 regression guard: a heading AFTER a real Notes section survives

    @Test(
        """
        MUST-FIX 1 regression: a heading appearing AFTER a real Notes section still yields its own \
        boundary and Section row, not swallowed by the (previously unbounded) notes latch
        """
    )
    func headingAfterNotesSectionSurvives() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let markdown = """
        # Introduction

        Some intro text.

        # Notes

        [^1]: A real footnote.

        # Appendix

        Appendix content that must survive.
        """

        // First pass: no existing Notes title yet -- a real first-ever sync, exercising the
        // "existingNotesTitle == nil" import-auto-detection branch to establish the initial
        // Section rows (Notes flagged, Appendix an ordinary section).
        let firstHeaders = SectionSyncService.parseHeaders(from: markdown)
        let firstChanges = reconciler.reconcile(headers: firstHeaders, dbSections: [], projectId: pid)
        let firstSections: [Section] = firstChanges.compactMap {
            if case .insert(let section) = $0 { return section }
            return nil
        }
        try db.replaceSections(firstSections, for: pid)

        let notesRow = try #require(firstSections.first { $0.isNotes })
        #expect(notesRow.title == "Notes")
        let appendixRowBefore = try #require(firstSections.first { $0.title == "Appendix" })
        #expect(!appendixRowBefore.isNotes, "Appendix must not be swallowed into the notes latch on the first pass")

        // Second pass: existingNotesTitle is now non-nil ("Notes") -- this is the SPECIFIC
        // branch MUST-FIX 1 fixes. Before the fix, latching `inAutoNotes` here with no closing
        // condition would swallow every boundary from "# Notes" to end-of-document, so
        // `headers` would never contain an "Appendix" entry, and the reconciler's delete sweep
        // would remove its Section row entirely -- real, silent data loss.
        let dbSections = try db.fetchSections(projectId: pid)
        let existingNotesTitle = dbSections.first(where: { $0.isNotes })?.title
        #expect(existingNotesTitle == "Notes", "Precondition: existingNotesTitle must be non-nil to exercise MUST-FIX 1's branch")

        let secondHeaders = SectionSyncService.parseHeaders(from: markdown, existingNotesTitle: existingNotesTitle)
        let appendixHeader = secondHeaders.first { $0.title == "Appendix" }
        #expect(appendixHeader != nil, "The heading after Notes must still yield its own boundary, not be swallowed by the notes latch")
        #expect(appendixHeader?.isNotes == false)

        let secondChanges = reconciler.reconcile(headers: secondHeaders, dbSections: dbSections, projectId: pid)
        try db.applySectionChanges(secondChanges, for: pid)

        let sectionsAfter = try db.fetchSections(projectId: pid)
        let appendixAfter = sectionsAfter.first { $0.title == "Appendix" }
        #expect(appendixAfter != nil, "Appendix's Section row must survive the second reconcile pass")
    }
}
