//
//  SectionSyncSuppressReconcileTests.swift
//  final finalTests
//
//  Tier 2: SectionSyncService.syncContent's P3 §4d suppression (undo-mode-switch-focus
//  second timing gap): when `suppressReconcile` is true (content that arrived from an
//  undo), reconcile + applySectionChanges (steps 3-4) must be skipped, but the DB
//  content-of-record persist (step 5, db.saveContent) and `lastSyncedContent` tracking
//  must ALWAYS run regardless -- or undone text never reaches the database, and
//  `updateSourceContentIfNeeded()` could later resurrect stale content.
//

import Testing
import Foundation
@testable import final_final

@Suite("SectionSyncService suppressReconcile — P3 §4d")
struct SectionSyncSuppressReconcileTests {

    @Test("db.saveContent always runs and lastSyncedContent is always set, even while reconcile/applySectionChanges are skipped")
    @MainActor
    func suppressReconcileSkipsReconcileButAlwaysPersists() async throws {
        let originalContent = "# Original Heading\n\nOriginal body."
        let db = try TestFixtureFactory.createTemporary(content: originalContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let syncService = SectionSyncService()
        syncService.configure(database: db, projectId: pid)

        // Establish a known baseline: a normal (non-suppressed) sync populates the legacy
        // sections table from the original heading -- `TestFixtureFactory.createTemporary`
        // only populates the BLOCKS table, not the legacy sections table `reconcile`
        // reads/writes, so this call is what actually seeds it.
        await syncService.syncNow(originalContent)
        let baselineSections = try db.fetchSections(projectId: pid)
        #expect(baselineSections.map(\.title) == ["Original Heading"])

        // Simulates content that just arrived from an undo of an automatic correction --
        // a DIFFERENT heading than what the (still-stale, about-to-be-reconciled-if-not-
        // suppressed) sections table says.
        let newContent = "# Changed Heading\n\nChanged body -- simulates content from an undo."

        await syncService.syncNow(newContent, suppressReconcile: true)

        // Step 5 must ALWAYS run: the DB content-of-record must reflect the new markdown,
        // suppression or not.
        let persisted = try db.fetchContent(for: pid)
        #expect(persisted?.markdown == newContent, "db.saveContent must always run even while suppressReconcile is true.")

        // Steps 3-4 must be SKIPPED while suppressed: the legacy sections table must still
        // reflect the ORIGINAL heading, not the new one -- reconcile never ran.
        let sectionsAfterSuppressed = try db.fetchSections(projectId: pid)
        #expect(
            sectionsAfterSuppressed.map(\.title) == ["Original Heading"],
            "reconcile()/applySectionChanges must be skipped while suppressReconcile is true -- the sections table must not pick up the new heading yet."
        )

        // lastSyncedContent must still have been updated to `newContent`, even though
        // reconcile was skipped -- verified indirectly via contentChanged's own idempotent
        // guard (`guard markdown != lastSyncedContent else { return }`): if lastSyncedContent
        // were stale, this call would incorrectly think newContent hasn't been synced yet
        // and schedule a fresh debounce (isSyncPending would flip true).
        syncService.contentChanged(newContent)
        #expect(
            syncService.isSyncPending == false,
            "lastSyncedContent must be set to the suppressed sync's content even though reconcile was skipped, or this identical-content call would incorrectly re-schedule work."
        )

        // Sanity: a SUBSEQUENT non-suppressed sync (the user typing normally again) DOES
        // reconcile -- proves suppression is a per-call flag consulted fresh each time, not
        // a state that gets stuck on.
        await syncService.syncNow(newContent + "\nMore text.", suppressReconcile: false)
        let sectionsAfterUnsuppressed = try db.fetchSections(projectId: pid)
        #expect(
            sectionsAfterUnsuppressed.map(\.title) == ["Changed Heading"],
            "A subsequent non-suppressed sync must reconcile normally -- suppression must not leak into later calls."
        )
    }
}
