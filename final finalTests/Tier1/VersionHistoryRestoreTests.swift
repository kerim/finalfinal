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

    // MARK: - Unified Undo: createUndoPointSnapshot (docs/plans/patient-rewinding-clockwork.md §4.4)
    //
    // Unlike createAutoSnapshot, this must NEVER skip on unchanged content -- an undo/redo
    // point must exist every time the unified-undo op sequence asks for one.

    @Test("createUndoPointSnapshot never dedups, unlike createAutoSnapshot")
    func createUndoPointSnapshotBypassesDedup() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, _) = try createSnapshotService(db: db)

        // Baseline: createAutoSnapshot on unchanged content is a no-op the second time.
        _ = try service.createAutoSnapshot()
        #expect(try service.createAutoSnapshot() == nil, "sanity: createAutoSnapshot dedups on unchanged content")

        // createUndoPointSnapshot must create a real row every time, even back to back with
        // completely unchanged content -- the exact scenario two structural ops with no
        // user typing between them produce.
        let firstId = try service.createUndoPointSnapshot()
        let secondId = try service.createUndoPointSnapshot()
        #expect(firstId != secondId, "each call must create its own row, never reuse the latest by hash")

        let all = try service.fetchAllSnapshots()
        #expect(all.contains { $0.id == firstId })
        #expect(all.contains { $0.id == secondId })
    }

    @Test("createUndoPointSnapshot captures current section metadata (status/tags/wordGoal), not just markdown")
    func createUndoPointSnapshotCapturesSectionMetadata() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let (service, _) = try createSnapshotService(db: db)

        // TestFixtureFactory.createTemporary only parses the markdown into the Block table --
        // the Section table is populated by SectionSyncService in the real app, not by
        // fixture creation, so db.fetchSections(projectId:) is empty here unless a section is
        // inserted explicitly. Matches restoreSectionAsDuplicatePreservesHeader's pattern above.
        let target = Section(
            projectId: pid,
            sortOrder: 0,
            headerLevel: 1,
            title: "Test Document",
            markdownContent: "# Test Document\n\nThis is a test paragraph for automated testing.\n"
        )
        try db.insertSection(target)

        // Metadata-only change: same markdown/content hash, different status/tags/wordGoal --
        // exactly the case createAutoSnapshot's hash-based dedup is blind to (plan §2/§4.4:
        // "createAutoSnapshot's dedup hash-skip ... ignores Section metadata").
        var updated = target
        updated.status = .final_
        updated.tags = ["undo-point-metadata-test"]
        updated.wordGoal = 4242
        try db.updateSection(updated)

        let snapshotId = try service.createUndoPointSnapshot()
        let snapshotSections = try service.fetchSections(for: snapshotId)
        let snapshotSection = try #require(snapshotSections.first { $0.title == target.title })

        #expect(snapshotSection.status == .final_)
        #expect(snapshotSection.tags == ["undo-point-metadata-test"])
        #expect(snapshotSection.wordGoal == 4242)
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

    /// Backdate a snapshot's `createdAt` directly in the DB -- `createSnapshot`/`Snapshot`'s
    /// own initializer always stamps "now", so pruning's Time-Machine-style retention buckets
    /// (24h/day/week/month) can't otherwise be exercised without a real 2-month wait.
    private func backdateSnapshot(_ db: ProjectDatabase, id: String, to date: Date) throws {
        try db.write { grdbDb in
            guard var snapshot = try Snapshot.fetchOne(grdbDb, key: id) else { return }
            snapshot.createdAt = date
            try snapshot.update(grdbDb)
        }
    }

    @Test("Prune auto backups exempts a pinned undo-point snapshot that would otherwise be pruned (plan §4.4/§9)")
    func pruneAutoBackupsExemptsPinnedUndoPointSnapshot() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        let (service, pid) = try createSnapshotService(db: db)

        // Three old auto-backups in the SAME calendar-month retention bucket (>=4 weeks old,
        // so pruneAutoBackups' month-bucket dedup applies: normally only the LATEST survives).
        // A fixed reference date (day 15 of a month two months ago) keeps all three safely
        // inside one calendar month regardless of when this test happens to run.
        let refMonth = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        var comps = Calendar.current.dateComponents([.year, .month], from: refMonth)
        comps.day = 15
        let baseDate = try #require(Calendar.current.date(from: comps))
        let earliest = baseDate
        let middle = Calendar.current.date(byAdding: .hour, value: 1, to: baseDate)!
        let latest = Calendar.current.date(byAdding: .hour, value: 2, to: baseDate)!

        func makeAutoSnapshot(markdown: String) throws -> Snapshot {
            let blocks = BlockParser.parse(markdown: markdown, projectId: pid)
            try db.replaceBlocks(blocks, for: pid)
            return try #require(try service.createAutoSnapshot())
        }

        // plainUnpinned: earliest, ordinary auto-backup -- NOT the bucket's natural survivor,
        // and not pinned. Must be pruned.
        let plainUnpinned = try makeAutoSnapshot(markdown: "# Bucket 1\n\nContent one.")
        try backdateSnapshot(db, id: plainUnpinned.id, to: earliest)

        // undoPoint: middle, created via the exact production API a structural op uses (no
        // dedup skip, self-pinning per createUndoPointSnapshot's own doc comment). Also NOT
        // the bucket's natural survivor by recency -- only the pin should save it.
        let blocks = BlockParser.parse(markdown: "# Bucket 2 (undo point)\n\nContent two.", projectId: pid)
        try db.replaceBlocks(blocks, for: pid)
        let undoPointId = try service.createUndoPointSnapshot()
        try backdateSnapshot(db, id: undoPointId, to: middle)
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoPointId))

        // bucketKeeper: latest in the bucket -- survives naturally via the existing
        // Time-Machine retention logic, regardless of pinning. Present so the bucket has a
        // real "natural survivor" distinct from the two entries under test above.
        let bucketKeeper = try makeAutoSnapshot(markdown: "# Bucket 3 (keeper)\n\nContent three.")
        try backdateSnapshot(db, id: bucketKeeper.id, to: latest)

        try service.pruneAutoBackups()

        let remaining = try service.fetchAllSnapshots().map(\.id)
        #expect(remaining.contains(undoPointId), "Pinned undo-point snapshot must survive pruning even though it isn't the bucket's natural latest-survivor")
        #expect(remaining.contains(bucketKeeper.id), "The bucket's natural latest-survivor should still be kept as before")
        #expect(!remaining.contains(plainUnpinned.id), "An equally-old, UNPINNED plain auto-backup that also isn't the bucket's survivor should still be prunable -- confirms the exemption is pin-specific, not a blanket retention-window change")

        // Cleanup: unpin so this test's id doesn't linger in the process-lifetime static set.
        SnapshotService.unpinUndoPointSnapshot(undoPointId)
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

    // MARK: - Bibliography Terminator Round-Trip
    //
    // Coverage for the bibliography orphan bug's third fix attempt (see
    // BibliographyTerminatorTests.swift): the explicit `BlockParser.bibliographyEndMarker`
    // terminator, written into snapshots by createManualSnapshot/createAutoSnapshot's new
    // assembleMarkdownForEditor call, so a restored snapshot round-trips the "text typed
    // after the bibliography" scenario correctly. Deliberately built against a FRESH
    // snapshot created in-test (not a pre-existing fixture snapshot, which would predate
    // the terminator by construction and correctly NOT carry it — see
    // BlockParser.bibliographyEndMarker's doc comment for that disclosed, expected gap).

    @Test("A fresh snapshot of a bibliography-ending document carries the terminator, and restoring it lets a subsequent trailing paragraph resolve correctly")
    func freshSnapshotCarriesTerminatorAndRestoresTrailingTextCorrectly() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let (service, _) = try createSnapshotService(db: db)

        // richTestContent's References section is the LAST thing in the document — exactly
        // the shape BibliographySyncService.updateBibliographyBlock always produces.
        let snapshot = try service.createManualSnapshot(name: "Before Trailing Note")
        #expect(
            snapshot.previewMarkdown.contains(BlockParser.bibliographyEndMarker),
            "A fresh snapshot of a document ending in bibliography content must carry the terminator"
        )

        // Restore it — restoreEntireProject reparses snapshot.previewMarkdown via
        // BlockParser.parse(), which consumes the terminator (zero Blocks) as it closes
        // the section.
        try service.restoreEntireProject(from: snapshot.id, createSafetyBackup: false)

        let restoredBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let restoredBibBlocks = restoredBlocks.filter { $0.isBibliography }
        #expect(
            restoredBibBlocks.count == 5,
            "Restore must bring back all 5 real bibliography blocks (heading + 4 entries) correctly flagged"
        )

        // Simulate what the app does next: rebuild editorState.content from the restored
        // blocks (assembleMarkdownForEditor re-adds the terminator, since the last block is
        // still bibliography-flagged), then simulate the user typing a new trailing
        // paragraph followed by a full reparse (Source Mode's debounced reparse, or the
        // pre-export flush).
        let rebuiltContent = BlockParser.assembleMarkdownForEditor(from: restoredBlocks)
        #expect(
            rebuiltContent.hasSuffix(BlockParser.bibliographyEndMarker),
            "Rebuilding editor content from the restored blocks must re-add the terminator"
        )
        let withTrailingNote = rebuiltContent + "\n\nA note typed after restoring from the snapshot."

        let reparsed = BlockParser.parse(markdown: withTrailingNote, projectId: pid)
        let trailingBlock = try #require(
            reparsed.last { $0.markdownFragment.contains("A note typed after restoring") }
        )
        #expect(
            trailingBlock.isBibliography == false,
            "A paragraph typed after restoring a bibliography-ending snapshot must NOT be flagged isBibliography"
        )
    }
}
