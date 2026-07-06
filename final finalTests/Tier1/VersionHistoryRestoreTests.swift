//
//  VersionHistoryRestoreTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for snapshot creation, restore, hash deduplication, and pruning.
//  Broken snapshot restores silently destroy the user's work.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Version History Restore — Tier 1: Silent Killers")
@MainActor
struct VersionHistoryRestoreTests {

    // MARK: - Helpers

    private func createSnapshotService(db: ProjectDatabase) throws -> (SnapshotService, String) {
        let pid = try TestFixtureFactory.getProjectId(from: db)
        return (SnapshotService(database: db, projectId: pid), pid)
    }

    // MARK: - Create & Retrieve

    @Test("Manual snapshot is retrievable with correct name")
    func createManualSnapshotRetrievable() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try createSnapshotService(db: db)

        let snapshot = try service.createManualSnapshot(name: "Test Save")
        #expect(snapshot.name == "Test Save")
        #expect(snapshot.isAutomatic == false)

        let all = try service.fetchAllSnapshots()
        #expect(all.contains { $0.id == snapshot.id },
                "Created snapshot should be retrievable")
    }

    // MARK: - Auto Snapshot Deduplication

    @Test("Auto snapshot skips unchanged content")
    func autoSnapshotSkipsUnchangedContent() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try createSnapshotService(db: db)

        let first = try service.createAutoSnapshot()
        #expect(first != nil, "First auto snapshot should be created")

        let second = try service.createAutoSnapshot()
        #expect(second == nil, "Second auto snapshot should be skipped (same hash)")
    }

    // MARK: - Restore

    @Test("Restore entire project matches snapshot content")
    func restoreEntireProjectMatchesSnapshot() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try createSnapshotService(db: db)

        // Create snapshot of original
        let snapshot = try service.createManualSnapshot(name: "Original")

        // Modify content
        let newContent = "# Modified\n\nDifferent content entirely."
        let newBlocks = BlockParser.parse(markdown: newContent, projectId: pid)
        try db.replaceBlocks(newBlocks, for: pid)
        try db.saveContent(markdown: newContent, for: pid)

        // Restore
        try service.restoreEntireProject(from: snapshot.id, createSafetyBackup: false)

        // Verify content matches original
        guard let restored = try db.fetchContent(for: pid) else {
            Issue.record("Content should exist after restore")
            return
        }
        #expect(restored.markdown.contains("Test Document"),
                "Restored content should match original snapshot")
    }

    @Test("Restore creates automatic safety backup")
    func restoreCreatesAutomaticSafetyBackup() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try createSnapshotService(db: db)

        let snapshot = try service.createManualSnapshot(name: "Before")

        // Modify content so safety backup has a different hash than the manual snapshot
        let modifiedContent = "# Modified\n\nContent changed before restore."
        let blocks = BlockParser.parse(markdown: modifiedContent, projectId: pid)
        try db.replaceBlocks(blocks, for: pid)
        try db.saveContent(markdown: modifiedContent, for: pid)

        // Restore WITH safety backup (default) — safety backup captures modified state
        try service.restoreEntireProject(from: snapshot.id, createSafetyBackup: true)

        let all = try service.fetchAllSnapshots()
        // Should have: the manual snapshot + safety auto-backup
        #expect(all.count >= 2, "Should have at least 2 snapshots (manual + safety backup)")
        let autoSnapshots = all.filter { $0.isAutomatic }
        #expect(!autoSnapshots.isEmpty, "Safety backup should be an automatic snapshot")
    }

    // MARK: - Hash

    @Test("Hash computation is deterministic")
    func hashComputationDeterministic() {
        let content = "# Same Content\n\nIdentical text."
        let hash1 = SnapshotService.computeHash(content)
        let hash2 = SnapshotService.computeHash(content)
        #expect(hash1 == hash2, "Same content should produce same hash")

        let different = "# Different Content\n\nOther text."
        let hash3 = SnapshotService.computeHash(different)
        #expect(hash1 != hash3, "Different content should produce different hash")
    }

    // MARK: - Pruning

    @Test("Prune auto backups keeps manual snapshots")
    func pruneAutoBackupsKeepsManualSnapshots() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try createSnapshotService(db: db)

        // Create a manual snapshot
        let manual = try service.createManualSnapshot(name: "Keep Me")

        // Create an auto snapshot (modify content first to avoid hash dedup)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let modifiedContent = "# Modified\n\nChanged for auto snapshot."
        let blocks = BlockParser.parse(markdown: modifiedContent, projectId: pid)
        try db.replaceBlocks(blocks, for: pid)
        let auto = try service.createAutoSnapshot()
        #expect(auto != nil)

        // Prune
        try service.pruneAutoBackups()

        // Manual snapshot should survive
        let all = try service.fetchAllSnapshots()
        #expect(all.contains { $0.id == manual.id },
                "Manual snapshot should survive pruning")
    }

    // MARK: - Trailing Blank Line Regression (Outline Desync)
    //
    // Regression coverage for a bug where sections were joined end-to-end with no
    // separator. Whichever section sat last had no enforced trailing blank line, so
    // when another section's markdown was appended after it, the next header glued
    // onto the previous section's last sentence and the parser stopped recognizing
    // it as a heading — it silently vanished from the Outline sidebar.

    @Test("Restoring a section as duplicate preserves the restored header (SnapshotService)")
    func restoreSectionAsDuplicatePreservesHeader() throws {
        let db = try TestFixtureFactory.createTemporary()
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Existing section deliberately does NOT end in a trailing blank line
        let existingSection = Section(
            projectId: pid,
            sortOrder: 0,
            headerLevel: 1,
            title: "Existing Section",
            markdownContent: "# Existing Section\n\nSome body text with no trailing blank line."
        )
        try db.insertSection(existingSection)

        // Section that will be captured in a snapshot, then restored as a duplicate
        let toRestoreSection = Section(
            projectId: pid,
            sortOrder: 1,
            headerLevel: 1,
            title: "Restored Header",
            markdownContent: "# Restored Header\n\nRestored body text."
        )
        try db.insertSection(toRestoreSection)

        let (service, _) = try createSnapshotService(db: db)
        let snapshot = try service.createManualSnapshot(name: "Before Restore")

        let snapshotSections = try service.fetchSections(for: snapshot.id)
        guard let restoredSnapshotSection = snapshotSections.first(where: { $0.title == "Restored Header" }) else {
            Issue.record("Snapshot should contain the 'Restored Header' section")
            return
        }

        // Remove the live section so restoring it models a real "bring back a section
        // that's no longer present" restore-as-duplicate flow.
        try db.deleteSection(id: toRestoreSection.id, moveChildrenUp: false)

        try service.restoreSectionAsDuplicate(
            snapshotSectionId: restoredSnapshotSection.id,
            insertAfterSectionId: existingSection.id,
            createSafetyBackup: false
        )

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let headings = TestFixtureFactory.headingBlocks(blocks)

        #expect(headings.count == 2,
                "Restored Header should remain its own heading after restore-as-duplicate, not get glued into the previous section's paragraph")
        #expect(headings.contains { $0.textContent == "Restored Header" },
                "Restored Header text should be recognized as a heading block")
    }
}
