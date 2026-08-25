//
//  BibliographySectionFlagTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Section.isBibliography was never set true by any production writer:
//  SectionSyncService.parseHeaders detected the machine-managed bibliography heading
//  (`header.title == bibHeaderName && existingBibTitle != nil`) but dropped it from its
//  output entirely rather than emitting a flagged ParsedHeader, so the reconciler never
//  saw it and no Section row was ever created or updated with isBibliography = true.
//
//  FIX: parseHeaders now emits a boundary (and ParsedHeader) for the bibliography heading,
//  flagged isBibliography == true. SectionReconciler routes flagged headers through a
//  dedicated match path (findBibliographyMatch) that either matches an already-flagged row
//  directly, self-heals onto an unflagged evidence-bearing candidate (title+level or content
//  match -- NEVER pure sortOrder proximity, which would reintroduce the round-1 role-swap
//  bug through a different path), or inserts a fresh flagged row. SnapshotService's
//  rebuildContentFromSections excludes flagged rows so a version-history restore never
//  resurrects a stale bibliography copy from the section table.
//
//  This file covers the base isBibliography-flag mechanics and the Tier-2 role-swap fix
//  (tests 1-8). The Round 2 follow-up fixes -- snapshot-restore bibliography-block
//  preservation, flag-revocation two-signal delete sweep, and sync-back/staleness wiring
//  (tests 9-19) -- live in BibliographySectionFlagTests+DataIntegrity.swift, split out to
//  keep this struct's body under SwiftLint's type_body_length limit (400 lines).
//

import Testing
import Foundation
@testable import final_final

// handleBibliographySectionChangedSyncsSectionTableImmediately (in
// BibliographySectionFlagTests+DataIntegrity.swift) mutates the process-wide
// DocumentManager.shared singleton and holds it across a ~5-second polling window (same
// hazard BibliographySyncTests.swift and BibliographySourceModeFlushTests.swift guard against
// with .serialized). .serialized here only orders THIS suite's own tests (across both files)
// against each other -- it does NOT protect against a concurrently-running suite also
// touching DocumentManager.shared (Swift Testing runs suites in parallel; see
// DiagnosticLogFileTests.swift's seamSwapInvalidatesEnabledCache for the same caveat spelled
// out against a different singleton).
@Suite("Bibliography Section Flag — Tier 1: Silent Killers", .serialized)
struct BibliographySectionFlagTests {

    let reconciler = SectionReconciler()
    let projectId = "test-project-id"

    // MARK: - 1. parseHeaders emits the bibliography heading (previously dropped)

    @Test("parseHeaders emits the bibliography heading as a ParsedHeader flagged isBibliography == true")
    func parseHeadersEmitsFlaggedBibliographyHeader() {
        let markdown = """
        # Introduction

        Some intro text.

        # References

        Entry one.

        <!-- ::auto-bibliography-end:: -->
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "References")

        let bibHeader = headers.first { $0.title == "References" }
        #expect(bibHeader != nil, "The bibliography heading must be emitted as a ParsedHeader, not dropped from the output")
        #expect(bibHeader?.isBibliography == true)

        // Sanity: the ordinary heading before it must NOT be flagged.
        let introHeader = headers.first { $0.title == "Introduction" }
        #expect(introHeader?.isBibliography == false)
    }

    // MARK: - 2. Anti role-swap: no existingBibTitle means no flag, even for "References"

    @Test("parseHeaders does NOT flag a heading titled Bibliography when no existingBibTitle is known yet")
    func parseHeadersDoesNotFlagUnknownReferencesHeading() {
        let markdown = """
        # Introduction

        Some intro text.

        # Bibliography

        Entry one.
        """

        // existingBibTitle defaults to nil, so bibHeaderName falls back to fallbackBibTitle
        // ("Bibliography") -- which means the title clause (header.title == bibHeaderName)
        // DOES match here. That's the point: with a matching title, the only thing left to
        // stop this heading from being flagged is the `existingBibTitle != nil` guard. If a
        // heading titled "References" were used instead (as in a prior version of this test),
        // the title clause would already fail on its own, and deleting the guard entirely
        // would leave this test green -- defeating its purpose of pinning the anti-role-swap
        // protection down to that specific guard clause.
        let headers = SectionSyncService.parseHeaders(from: markdown)

        let bibliographyHeader = headers.first { $0.title == "Bibliography" }
        #expect(bibliographyHeader != nil, "The heading must still be parsed as an ordinary section")
        #expect(bibliographyHeader?.isBibliography == false)
    }

    // MARK: - Helper Factories (mirrors SectionReconcilerTests.swift's pattern)
    // Not `private`: BibliographySectionFlagTests+DataIntegrity.swift's extension also calls this.

    func makeHeader(
        position: Int,
        title: String,
        level: Int = 1,
        isPseudoSection: Bool = false,
        startOffset: Int = 0,
        markdownContent: String = "",
        wordCount: Int = 10,
        isBibliography: Bool = false
    ) -> ParsedHeader {
        ParsedHeader(
            position: position,
            title: title,
            level: level,
            isPseudoSection: isPseudoSection,
            startOffset: startOffset,
            markdownContent: markdownContent,
            wordCount: wordCount,
            isBibliography: isBibliography
        )
    }

    // MARK: - 3. MUST-FIX 2: flag flip must not be silently dropped by buildUpdates' nil case

    @Test("Reconcile flips isBibliography on an unflagged row even when every other field already matches")
    func reconcileFlipsBibliographyFlagOnSteadyStateMatch() {
        let content = "# References\n\nEntry one.\n"
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: content, wordCount: 10, isBibliography: true
        )
        let existingId = UUID().uuidString
        let existing = Section(
            id: existingId, projectId: projectId, sortOrder: 0, headerLevel: 1,
            isBibliography: false, title: "References", markdownContent: content,
            wordCount: 10, startOffset: 0
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [existing], projectId: projectId)

        #expect(changes.count == 1, "Exactly one change: the flag flip -- no insert, no delete")
        guard case .update(let id, let updates) = changes.first else {
            Issue.record("Expected a single .update change, got \(changes)")
            return
        }
        #expect(id == existingId)
        #expect(updates.isBibliography == true, "MUST-FIX 2: the flag flip must survive buildUpdates' nil short-circuit")
        #expect(updates.title == nil, "No other field may be touched")
        #expect(updates.headerLevel == nil)
        #expect(updates.sortOrder == nil)
        #expect(updates.markdownContent == nil)
        #expect(updates.wordCount == nil)
        #expect(updates.startOffset == nil)
    }

    // MARK: - 4. Steady state: already-flagged row produces zero changes on repeat passes

    @Test("Reconcile against an already-flagged bibliography row produces zero changes (no duplicate flip)")
    func reconcileNoOpWhenAlreadyFlaggedAndMatching() {
        let content = "# References\n\nEntry one.\n"
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: content, wordCount: 10, isBibliography: true
        )
        let existing = Section(
            projectId: projectId, sortOrder: 0, headerLevel: 1,
            isBibliography: true, title: "References", markdownContent: content,
            wordCount: 10, startOffset: 0
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [existing], projectId: projectId)

        #expect(changes.isEmpty, "An already-flagged, already-matching row must be a true no-op on repeat passes")
    }

    // MARK: - 5. Integration: legacy unflagged section row self-heals from the block table over two passes

    @Test("Second-pass integration: block-table bibliography + unflagged legacy section row self-heals and reaches steady state")
    func integrationSelfHealsLegacySectionRowOverTwoPasses() throws {
        // richTestContent's "References" heading is a real bibliography section at the BLOCK
        // level (BlockParser auto-detects it independent of section-level parsing) -- see
        // BibliographyTerminatorTests.swift, which asserts this same fixture yields 5
        // isBibliography blocks (heading + 4 entries).
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let markdown = TestFixtureFactory.richTestContent

        // Seed the "historical corpus" shape: section rows created back when bibliography
        // detection had never yet run for this project (existingBibTitle: nil), so
        // "References" landed as an ordinary, unflagged Section row -- exactly what the old,
        // buggy parseHeaders would also have produced once existingBibTitle became known,
        // since it dropped the heading from its output instead of updating this row.
        let legacyHeaders = SectionSyncService.parseHeaders(from: markdown)
        let legacySections = legacyHeaders.map { header in
            Section(
                projectId: pid, sortOrder: header.position, headerLevel: header.level,
                isPseudoSection: header.isPseudoSection, title: header.title,
                markdownContent: header.markdownContent, wordCount: header.wordCount,
                startOffset: header.startOffset
            )
        }
        try db.replaceSections(legacySections, for: pid)

        let referencesRowBefore = try #require(
            try db.fetchSections(projectId: pid).first { $0.title == "References" }
        )
        #expect(referencesRowBefore.isBibliography == false, "Precondition: the seeded legacy row must start unflagged")

        // Runs one reconcile pass exactly the way SectionSyncService's fixed call sites do:
        // block-table-first coalescing (step 6 of the plan) for existingBibTitle.
        func runPass() throws -> [SectionChange] {
            let dbSections = try db.fetchSections(projectId: pid)
            let existingBibTitle = try db.fetchBibliographyHeadingTitle(projectId: pid)
                ?? dbSections.first(where: { $0.isBibliography })?.title
            let existingNotesTitle = dbSections.first(where: { $0.isNotes })?.title
            let headers = SectionSyncService.parseHeaders(
                from: markdown, existingBibTitle: existingBibTitle,
                existingNotesTitle: existingNotesTitle
            )
            let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: pid)
            try db.applySectionChanges(changes, for: pid)
            return changes
        }

        // existingBibTitle must resolve from the block table even on the very first pass,
        // before any section row is flagged -- this is the "first citation ever" gap
        // fetchBibliographyHeadingTitle's doc comment describes.
        let blockTableTitle = try db.fetchBibliographyHeadingTitle(projectId: pid)
        #expect(blockTableTitle == "References", "Precondition: the block table must already know about the bibliography")

        let firstPassChanges = try runPass()
        let referencesRowAfterFirstPass = try #require(
            try db.fetchSections(projectId: pid).first { $0.title == "References" }
        )
        #expect(referencesRowAfterFirstPass.isBibliography == true, "Pass 1 must self-heal the flag onto the existing row")
        #expect(
            firstPassChanges.contains { if case .update(let id, _) = $0 { return id == referencesRowAfterFirstPass.id }; return false },
            "Pass 1 must produce an update for the References row (the flag flip), not a fresh insert"
        )

        let secondPassChanges = try runPass()
        let inserts = secondPassChanges.filter { if case .insert = $0 { return true }; return false }
        let deletes = secondPassChanges.filter { if case .delete = $0 { return true }; return false }
        #expect(inserts.isEmpty, "Pass 2 (steady state) must produce zero inserts")
        #expect(deletes.isEmpty, "Pass 2 (steady state) must produce zero deletes")

        // existingBibTitle must still resolve correctly after the section row is flagged.
        let dbSectionsAfter = try db.fetchSections(projectId: pid)
        let existingBibTitleAfter = try db.fetchBibliographyHeadingTitle(projectId: pid)
            ?? dbSectionsAfter.first(where: { $0.isBibliography })?.title
        #expect(existingBibTitleAfter == "References")
    }

    // MARK: - 6. MUST-FIX 1: no pure-proximity fallback for the bibliography match

    @Test("MUST-FIX 1: bibliography header does not steal an unrelated, evidence-less row via pure-proximity fallback")
    func reconcileDoesNotStealUnrelatedRowViaProximity() {
        let bibContent = "# References\n\nA brand new reference entry."
        let header = makeHeader(
            position: 0, title: "References", level: 1,
            markdownContent: bibContent, wordCount: 6, isBibliography: true
        )

        // An ordinary section, edited beyond recognition (no title or content overlap with
        // the bibliography header), left unmatched at the SAME sortOrder the bibliography
        // header now occupies -- exactly the shape that would satisfy findMatch's Tier-3
        // pure-proximity fallback (`related.isEmpty -> inRange`) if the reconciler reused
        // findMatch unmodified for bibliography headers.
        let unrelatedId = UUID().uuidString
        let unrelatedSection = Section(
            id: unrelatedId, projectId: projectId, sortOrder: 0, headerLevel: 2,
            isBibliography: false, title: "Some Unrelated Heading",
            markdownContent: "Completely unrelated content, edited beyond recognition.",
            wordCount: 20, startOffset: 500
        )

        let changes = reconciler.reconcile(headers: [header], dbSections: [unrelatedSection], projectId: projectId)

        let insertedBibliography = changes.contains {
            if case .insert(let section) = $0 { return section.isBibliography && section.title == "References" }
            return false
        }
        let deletedUnrelated = changes.contains {
            if case .delete(let id) = $0 { return id == unrelatedId }
            return false
        }
        let updatedUnrelatedIntoBibliography = changes.contains {
            if case .update(let id, let updates) = $0 { return id == unrelatedId && updates.isBibliography == true }
            return false
        }

        #expect(insertedBibliography, "A fresh bibliography Section must be inserted rather than reusing the unrelated row")
        #expect(deletedUnrelated, "The unrelated row must be deleted as genuinely unmatched, not silently repurposed")
        #expect(!updatedUnrelatedIntoBibliography, "The unrelated row must never be flipped into the bibliography via proximity alone")
    }

    // MARK: - 7. MUST-FIX 3: rebuildContentFromSections excludes flagged rows

    @Test("MUST-FIX 3: rebuildContentFromSections excludes isBibliography rows on a version-history section restore")
    @MainActor
    func rebuildContentFromSectionsSkipsBibliographyRows() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let introSection = Section(
            projectId: pid, sortOrder: 0, headerLevel: 1,
            title: "Intro", markdownContent: "# Intro\n\nBody one.\n",
            wordCount: 3, startOffset: 0
        )
        let bibSection = Section(
            projectId: pid, sortOrder: 1, headerLevel: 1, isBibliography: true,
            title: "References", markdownContent: "# References\n\nFROZEN STALE CONTENT.\n",
            wordCount: 3, startOffset: 100
        )
        try db.replaceSections([introSection, bibSection], for: pid)

        let snapshotService = SnapshotService(database: db, projectId: pid)
        let snapshot = try snapshotService.createManualSnapshot(name: "Before")

        let snapshotSections = try db.fetchSnapshotSections(snapshotId: snapshot.id)
        let introSnapshot = try #require(snapshotSections.first { $0.title == "Intro" })

        // A trivial no-op replace of the NON-bibliography section is enough to trigger
        // rebuildContentFromSections()'s concatenation path.
        try snapshotService.restoreSectionReplace(
            snapshotSectionId: introSnapshot.id,
            targetSectionId: introSection.id,
            createSafetyBackup: false
        )

        let rebuilt = try #require(db.fetchContent(for: pid)?.markdown)
        #expect(
            !rebuilt.contains("FROZEN STALE CONTENT"),
            """
            rebuildContentFromSections must exclude isBibliography rows -- that content is a frozen, \
            potentially-stale mirror; the real bibliography lives at the block level
            """
        )
        #expect(rebuilt.contains("Body one."), "Non-bibliography section content must still be included")
    }

    // MARK: - 8. MUST-FIX 2: zoomedExisting must exclude bibliography/notes rows

    @Test(
        """
        MUST-FIX 2: a zoomed section set that includes a flagged bibliography row does not \
        misalign the index-paired zoomed sync and delete (or corrupt) an unrelated trailing section
        """
    )
    @MainActor
    func zoomedSyncExcludesBibliographyRowFromIndexAlignment() async throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Four sections in document order: Beta and Gamma are ordinary sections either
        // side of a flagged bibliography row. `getDescendantIds` (EditorViewState+Zoom.swift)
        // can include a bibliography row's id in `zoomedSectionIds` in edge cases (e.g. via
        // the parentId transitive-children loop), so `zoomedIds` below deliberately includes
        // the bibliography row alongside Beta and Gamma -- exactly the shape the fix guards.
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
        let references = Section(
            projectId: pid, sortOrder: 2, headerLevel: 1, isBibliography: true,
            title: "References", markdownContent: "# References\n\nRef entry.\n",
            wordCount: 2, startOffset: 60
        )
        let gamma = Section(
            projectId: pid, sortOrder: 3, headerLevel: 1,
            title: "Gamma", markdownContent: "# Gamma\n\nGamma text.\n",
            wordCount: 2, startOffset: 90
        )
        try db.replaceSections([alpha, beta, references, gamma], for: pid)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: pid)

        // Mirrors zoomToSection's block-level content assembly, which excludes bibliography
        // blocks from the zoomed markdown even when the section id is in `zoomedIds`.
        let zoomedIds: Set<String> = [beta.id, references.id, gamma.id]
        let editedZoomedMarkdown = """
        # Beta

        Beta text.

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

        let referencesAfter = try #require(sectionsAfter.first { $0.id == references.id })
        #expect(referencesAfter.isBibliography, "The bibliography row must remain flagged")
        #expect(
            referencesAfter.markdownContent.contains("Ref entry."),
            "The bibliography row's content must not be overwritten by an unrelated header (e.g. Gamma's) due to index misalignment"
        )
    }
}
