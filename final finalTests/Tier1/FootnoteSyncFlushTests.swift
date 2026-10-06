//
//  FootnoteSyncFlushTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for FootnoteSyncService.flushPendingSync() — forcing an already-scheduled but
//  not-yet-fired debounced footnote update to run immediately (e.g. on quit). Split out of
//  FootnoteSyncTests.swift to keep that suite under SwiftLint's type_body_length limit.
//

import Testing
import Foundation
@testable import final_final

@Suite("Footnote Sync — flushPendingSync (force pending debounce to run immediately, e.g. on quit)")
struct FootnoteSyncFlushTests {

    @Test("flushPendingSync forces a scheduled debounce to run immediately, without waiting 3s")
    @MainActor
    func flushPendingSyncForcesScheduledUpdate() async throws {
        let seed = "Body text[^2] out of order, no [^1]."
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Schedules the 3s debounce — this call sets pendingUpdate synchronously, before
        // the sleep even starts.
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: projectId, fullContent: seed)

        // Force it through immediately instead of waiting for the real 3s debounce.
        await service.flushPendingSync()

        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(defs.count == 1, "Expected the out-of-order [^2] to be renumbered and written immediately")
        #expect(defs.first?.markdownFragment.hasPrefix("[^1]:") == true, "Single footnote renumbers down to [^1]")
    }

    @Test("flushPendingSync with nothing pending is a prompt no-op")
    @MainActor
    func flushPendingSyncNoOpWhenNothingPending() async throws {
        let seed = "Body text, no footnotes."
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        let before = try TestFixtureFactory.fetchBlocks(from: db)

        // Fresh service — checkAndUpdateFootnotes was never called, so nothing is pending.
        await service.flushPendingSync()

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.count == before.count, "flushPendingSync with nothing pending must make no DB writes")
    }

    @Test("Two scheduling calls before a flush: only the latest pending snapshot is applied")
    @MainActor
    func flushPendingSyncAppliesOnlyLatestScheduledSnapshot() async throws {
        let contentWithOne = "Body text[^1]."
        let contentWithBoth = "Body text[^1] and[^2]."
        let db = try TestFixtureFactory.createTemporary(content: contentWithOne)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Schedule twice in a row without ever flushing in between — the second call must
        // supersede (not queue alongside) the first.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: contentWithOne)
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: contentWithBoth)

        await service.flushPendingSync()

        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let labels = Set(defs.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(labels == Set(["1", "2"]), "Only the second (latest) pending snapshot — refs [1,2] — should have been applied")
    }

    @Test("Repeated schedule-then-flush cycles never lose a newly-scheduled update")
    @MainActor
    func repeatedFlushCyclesPickUpFreshWork() async throws {
        let contentWithOne = "Body text[^1]."
        let contentWithBoth = "Body text[^1] and[^2]."
        let db = try TestFixtureFactory.createTemporary(content: contentWithOne)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Cycle 1: schedule refs=["1"], flush — applies A.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: contentWithOne)
        await service.flushPendingSync()

        let afterA = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        #expect(afterA.count == 1, "First cycle should have written just [^1]")

        // Cycle 2: immediately schedule refs=["1","2"], flush again — no real delay between
        // cycles. This is the closest deterministic proxy for "a flush call must not lose a
        // pending update it hasn't applied yet" achievable without a test-only seam into
        // `state` (see plan's testability-limit callout: neither service's update path has a
        // real internal suspension point, so the literal "caught mid-.syncing" interleaving
        // can't be forced from a test).
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: contentWithBoth)
        await service.flushPendingSync()

        let afterB = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let labelsB = Set(afterB.compactMap { FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment)?.label })
        #expect(labelsB == Set(["1", "2"]), "Second cycle must reflect B ([1,2]), not just leftover A")
    }

    @Test("""
        flushPendingSync replays a stale pending snapshot with its STORED generation, so an intervening immediate insertion's \
        guard correctly rejects it
        """)
    @MainActor
    func flushPendingSyncStoredGenerationRejectsStaleSnapshotAfterImmediateInsertion() async throws {
        let seed = """
        Body text[^1] here.

        # Notes

        [^1]: Real definition one.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Schedule a pending debounced update at generation 0 (matching
        // immediateInsertionSupersedesStaleDebounce's setup) — refs=["1"].
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: seed)

        // An immediate insertion happens before the flush: bumps syncGeneration 0 -> 1.
        // Phase 2 (t-94369a83), §2.4: `handleImmediateInsertion` split into begin/commit;
        // `beginImmediateInsertion` now also clears `pendingUpdate` synchronously (per the
        // plan), so `flushPendingSync` below now short-circuits on its own
        // `pendingUpdate == nil` guard rather than reaching the stale-generation guard this
        // test's assertions were originally written to exercise -- the DB end-state this
        // test actually asserts on is unchanged either way ([^1]'s real text survives,
        // [^2] from the immediate insertion is present), so the assertions below still hold.
        let insertionGeneration = service.beginImmediateInsertion()
        _ = await service.commitImmediateInsertion(label: "2", projectId: projectId, generation: insertionGeneration)

        // The stale pending snapshot (captured generation 0) must be rejected by
        // performFootnoteUpdate's scheduledGeneration == syncGeneration guard (0 != 1), not
        // applied — proving it was replayed with the STORED generation, not a freshly-read
        // syncGeneration (which would trivially match and let the stale replay through).
        await service.flushPendingSync()

        let defs = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
        let frags = defs.map(\.markdownFragment)
        #expect(defs.count == 2, "Expected exactly [^1] and [^2] surviving; got \(frags)")
        #expect(frags.contains { $0.hasPrefix("[^1]:") && $0.contains("Real definition one.") }, "[^1] real text preserved")
        #expect(frags.contains { $0.hasPrefix("[^2]:") }, "[^2] from the immediate insertion must not have been deleted by the stale replay")
    }

    // MARK: - Undo of a deleted reference (t-e8821953, Phase 3a-2 Step 2)

    @Test("""
        Delete the only footnote reference, then undo it (refs are back to what the Notes already match): \
        the removal scheduled by the delete is dropped, so it can never fire and delete the definition
        """)
    @MainActor
    func undoOfDeletedOnlyReferenceDropsStalePendingRemoval() async throws {
        let seed = "Body text[^1].\n\n# Notes\n\n[^1]: Kept definition."
        let afterDelete = "Body text.\n\n# Notes\n\n[^1]: Kept definition."
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Setup: the document's refs reach the service and the flush writes them, which commits
        // `lastKnownRefs == ["1"]` (no writer is configured here, so this is the direct-write path).
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: seed)
        await service.flushPendingSync()

        // The delete: refs [] differ from the committed ["1"], so a 3s removal is scheduled.
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: afterDelete)
        #expect(service.testHasPendingUpdate, "The delete must have scheduled a debounced removal (test setup)")

        // The undo, inside the 3s window: refs equal the committed ["1"] again.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: seed)
        #expect(!service.testHasPendingUpdate, "The undo must drop the removal the delete scheduled")

        // Stands in for the debounce firing: before the fix this replayed the delete's snapshot and
        // removed the heading and the definition while the reference was back in the editor.
        await service.flushPendingSync()

        let notes = try TestFixtureFactory.fetchBlocks(from: db).filter(\.isNotes)
        let definitions = notes.filter { $0.blockType == .paragraph }.map(\.markdownFragment)
        #expect(notes.contains { $0.blockType == .heading }, "The # Notes heading must survive the undo")
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("Kept definition.") },
            "[^1]'s definition must survive; got \(definitions)")
    }

    @Test("""
        With several footnotes: delete the FIRST reference, then undo it. The stale snapshot would renumber \
        [^2] to [^1] and replace [^1]'s definition; it is dropped, so both definitions keep their own text
        """)
    @MainActor
    func undoOfDeletedFirstOfSeveralReferencesDropsStalePendingUpdate() async throws {
        let seed = "First[^1] and second[^2].\n\n# Notes\n\n[^1]: First definition.\n\n[^2]: Second definition."
        let afterDelete = "First and second[^2].\n\n# Notes\n\n[^1]: First definition.\n\n[^2]: Second definition."
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: seed)
        await service.flushPendingSync()

        // The delete leaves ["2"], which would renumber to ["1"] if its snapshot ever ran.
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: projectId, fullContent: afterDelete)
        #expect(service.testHasPendingUpdate, "The delete must have scheduled a debounced update (test setup)")

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: seed)
        await service.flushPendingSync()

        let frags = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType == .paragraph }
            .map(\.markdownFragment)
        #expect(frags.count == 2, "Both definitions must survive; got \(frags)")
        #expect(frags.contains { $0.hasPrefix("[^1]:") && $0.contains("First definition.") }, "[^1] keeps its own text; got \(frags)")
        #expect(frags.contains { $0.hasPrefix("[^2]:") && $0.contains("Second definition.") }, "[^2] keeps its own text; got \(frags)")
    }
}
