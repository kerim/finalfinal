//
//  FootnoteUndoCheckpointTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Phase 3a-2 Step 5 (t-4a6e6414): deleting a footnote number removes its text under Notes about 3 seconds
//  later, and ⌘Z used to bring back the number with a BLANK definition. The service now keeps a session-only
//  "undo checkpoint" of every definition a debounced write deletes, and restores the text at once when a later
//  check sees exactly the document as it was before the delete. `flushPendingSync()` stands in for the 3 second
//  debounce firing, and also waits for a restore in flight (the restore counts as a running sync). The several
//  footnotes flow (U-F3) is an outcome test through the system writer, in the second suite below.
//
//  Document shapes used throughout: the editor serializes Notes as ordinary blocks, but after the removal push
//  it holds NO Notes; ⌘Z then puts back the body only (Notes are compared with the section stripped).
//

import Testing
import Foundation
@testable import final_final

private enum UndoDoc {
    // One footnote.
    static let single = "# A\n\nBody text[^1] end.\n\n# Notes\n\n[^1]: Kept definition."
    static let singleDeleted = "# A\n\nBody text end.\n\n# Notes\n\n[^1]: Kept definition."
    /// The user edits the deleted footnote's definition text inside the 3 second window after the delete.
    static let singleDeletedEdited = "# A\n\nBody text end.\n\n# Notes\n\n[^1]: Kept definition, now EDITED."
    /// After the removal push the editor has no Notes; undo puts the marker back into the body.
    static let singleUndone = "# A\n\nBody text[^1] end."

    // Two footnotes, the first one deleted: the survivor is renumbered 2 -> 1.
    static let pair = "# A\n\nFirst[^1] and second[^2].\n\n# Notes\n\n[^1]: First def.\n\n[^2]: Second def."
    static let pairDeleted = "# A\n\nFirst and second[^2].\n\n# Notes\n\n[^1]: First def.\n\n[^2]: Second def."
    /// The editor's own renumber (its own undo step) plus the Notes push that followed the write.
    static let pairRenumbered = "# A\n\nFirst and second[^1].\n\n# Notes\n\n[^1]: Second def."
    /// ⌘Z #1: the renumber is undone, so the body equals the post-delete body again.
    static let pairRenumberUndone = "# A\n\nFirst and second[^2].\n\n# Notes\n\n[^1]: Second def."
    /// ⌘Z #2: the delete is undone, so the body equals the pre-delete body again.
    static let pairUndone = "# A\n\nFirst[^1] and second[^2].\n\n# Notes\n\n[^1]: Second def. EDITED"
}

private func notesRows(_ db: ProjectDatabase) throws -> [Block] {
    try TestFixtureFactory.fetchBlocks(from: db).filter(\.isNotes)
}

private func definitionFragments(_ db: ProjectDatabase) throws -> [String] {
    try notesRows(db).filter { $0.blockType == .paragraph }.map(\.markdownFragment)
}

@Suite("Footnote undo checkpoint — ⌘Z after the definition was removed restores its text (t-4a6e6414)")
@MainActor
struct FootnoteUndoCheckpointTests {

    /// A service whose first write committed `lastKnownRefs == ["1"]`; `recordContent` then lets an ordinary
    /// keystroke (refs unchanged) record the document as last known. The delete follows, and the debounce
    /// "fires": the Notes rows are removed and a checkpoint is recorded.
    private func serviceAfterDelete(
        db: ProjectDatabase, projectId: String, recordContent: Bool = true, windowEdit: String? = nil
    ) async throws -> FootnoteSyncService {
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.single)
        await service.flushPendingSync()
        if recordContent {
            service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.single)
        }
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: UndoDoc.singleDeleted)
        if let windowEdit {
            // An edit inside the 3 second window re-schedules the debounce with the fresh content.
            service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: windowEdit)
        }
        await service.flushPendingSync()
        #expect(try notesRows(db).isEmpty, "the removal must have run (test setup)")
        #expect(service.undoCheckpoints.count == 1, "the applied removal must have recorded one checkpoint (test setup)")
        return service
    }

    private func expectKeptDefinitionRestored(_ db: ProjectDatabase) throws {
        let notes = try notesRows(db)
        #expect(notes.contains { $0.blockType == .heading }, "the # Notes heading must come back")
        let definitions = try definitionFragments(db)
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("Kept definition.") },
            "[^1] must read 'Kept definition.', not a blank row; got \(definitions)")
    }

    // MARK: - U-F2

    @Test("""
        U-F2: delete the only footnote reference, wait for the removal, then undo: the definition text comes back \
        at once (no 3 second wait), under a restored # Notes heading
        """)
    func undoAfterRemovalRestoresTheDefinition() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.singleUndone)
        #expect(!service.testHasPendingUpdate, "an undo restores directly; it must not wait on the debounce")
        await service.flushPendingSync()   // waits for the restore in flight

        try expectKeptDefinitionRestored(db)
        #expect(service.undoCheckpoints.count == 1, "Step 6: the used checkpoint is KEPT (only the cap, reset and /footnote drop it)")
    }

    @Test("""
        U-F2b: the delete is the FIRST edit after the open-time write (no keystroke recorded the document \
        before it): the checkpoint is still recorded and the undo still restores the text
        """)
    func undoWorksWhenTheDeleteIsTheFirstEditAfterTheOpenTimeWrite() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId, recordContent: false)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.singleUndone)
        await service.flushPendingSync()

        try expectKeptDefinitionRestored(db)
    }

    // MARK: - U-F2 variant: the restored text is the text as last seen before the write

    @Test("""
        U-F2 (edited in the window): the user edits the deleted footnote's definition text between the delete and \
        the write; the undo brings back the EDITED text, not the text from before the delete
        """)
    func undoBringsBackTheDefinitionAsEditedInsideTheDeleteWindow() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId, windowEdit: UndoDoc.singleDeletedEdited)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.singleUndone)
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("Kept definition, now EDITED.") },
            "[^1] must read the EDITED text; got \(definitions)")
    }

    // MARK: - U-F4 .. U-F7: nothing else ever inherits the old text

    @Test("""
        U-F4: a footnote added with /footnote after the delete starts blank: beginImmediateInsertion clears every \
        checkpoint, even if the document is byte-identical to the one before the delete when the next check arrives
        """)
    func slashFootnoteAfterTheDeleteStartsBlank() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId)

        let generation = service.beginImmediateInsertion()
        #expect(service.undoCheckpoints.isEmpty, "an explicit new footnote must clear the checkpoints")

        // The new reference sits exactly where the deleted one was, and a check lands before the insertion write.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.singleUndone)
        #expect(service.testHasPendingUpdate, "an ordinary debounced check, never a restore")
        _ = await service.commitImmediateInsertion(label: "1", projectId: projectId, generation: generation)
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(definitions.contains { $0.hasPrefix("[^1]:") }, "the new footnote has a definition row; got \(definitions)")
        #expect(!definitions.contains { $0.contains("Kept definition.") }, "the new footnote must start blank; got \(definitions)")
    }

    @Test("U-F5: a reference typed by hand somewhere else after the delete gets a blank definition, never the old text")
    func handTypedReferenceElsewhereStaysBlank() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId)

        service.checkAndUpdateFootnotes(
            footnoteRefs: ["1"], projectId: projectId, fullContent: "# A\n\nNew sentence[^1].\n\nBody text end.")
        #expect(service.testHasPendingUpdate, "a different body is not an undo: an ordinary debounce is scheduled")
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(definitions.contains { $0.hasPrefix("[^1]:") }, "the new reference gets a definition row; got \(definitions)")
        #expect(!definitions.contains { $0.contains("Kept definition.") }, "it must start blank; got \(definitions)")
    }

    @Test("U-F6: delete without undo stays deleted: no restore happens and the Notes stay gone")
    func deleteWithoutUndoStaysDeleted() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId)

        // The user keeps writing; the refs stay empty.
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: "# A\n\nBody text end. more")
        await service.flushPendingSync()

        #expect(try notesRows(db).isEmpty, "the definition must stay deleted")
        #expect(!service.testHasPendingUpdate)
        #expect(service.undoCheckpoints.count == 1, "the checkpoint waits for a possible undo")
    }

    @Test("U-F7: a completed close, switch or open (reset) clears the checkpoints; an undo-shaped check then gives a blank row")
    func resetClearsCheckpoints() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = try await serviceAfterDelete(db: db, projectId: projectId)

        service.reset()
        #expect(service.undoCheckpoints.isEmpty, "reset() must clear the checkpoints")

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.singleUndone)
        #expect(service.testHasPendingUpdate, "without a checkpoint this is an ordinary debounced check")
        await service.flushPendingSync()

        let definitions = try definitionFragments(db)
        #expect(definitions.contains { $0.hasPrefix("[^1]:") }, "the reference gets a definition row; got \(definitions)")
        #expect(!definitions.contains { $0.contains("Kept definition.") }, "the text is gone for good after a reset; got \(definitions)")
    }

    @Test("U-F8: only the 5 most recent checkpoints are kept")
    func checkpointsAreCappedAtFive() {
        let service = FootnoteSyncService()
        for index in 0..<6 {
            service.committedNotesWrite(undoCheckpoint: FootnoteUndoCheckpoint(
                bodyBefore: "before \(index)", refsBefore: ["1"], deletedDefinitions: ["1": "text"], appliedRenameMap: [:]))
        }
        #expect(service.undoCheckpoints.count == 5)
        #expect(service.undoCheckpoints.first?.bodyBefore == "before 1", "the oldest checkpoint is the one dropped")
        #expect(service.undoCheckpoints.last?.bodyBefore == "before 5")
    }
}

/// The same flows through the REAL writer (the production path): a checkpoint is recorded only when the deleting
/// write APPLIED, so a refused or failed delete leaves none; and the restore goes through one `.notesUpdate` write.
@Suite("Footnote undo checkpoint — through the system writer", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FootnoteUndoCheckpointWriterTests {

    @Test("U-F2 (writer path): the delete applies through the writer, a checkpoint is recorded, and the undo restores the text")
    func deleteAndUndoThroughTheWriter() async throws {
        let stack = try makeStack(content: UndoDoc.single)
        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: stack.pid, fullContent: UndoDoc.single)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: stack.pid, fullContent: UndoDoc.single)
        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: stack.pid, fullContent: UndoDoc.singleDeleted)
        await service.flushPendingSync()
        #expect(try notesRows(stack.db).isEmpty, "the removal must have applied through the writer (test setup)")
        #expect(service.undoCheckpoints.count == 1, "an applied delete records a checkpoint")

        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: stack.pid, fullContent: UndoDoc.singleUndone)
        await service.flushPendingSync()

        let definitions = try definitionFragments(stack.db)
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("Kept definition.") },
            "[^1] must read 'Kept definition.' after the undo; got \(definitions)")
    }

    @Test("""
        U-F2 (refused delete): when the writer REFUSES the deleting write, no checkpoint is recorded and nothing changed
        """)
    func refusedDeleteLeavesNoCheckpoint() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.single)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Setup through the direct path (no writer yet): lastKnownRefs == ["1"] and the content is recorded.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.single)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: UndoDoc.single)

        // A writer that belongs to ANOTHER project database: every Notes write is refused (.identityMismatch).
        let otherStack = try makeStack()
        service.systemWriter = SystemWriter(blockSync: otherStack.sync)

        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: projectId, fullContent: UndoDoc.singleDeleted)
        await service.flushPendingSync()

        #expect(service.undoCheckpoints.isEmpty, "a refused delete must leave no checkpoint")
        #expect(
            try definitionFragments(db).contains { $0.contains("Kept definition.") },
            "the refused write must not have removed anything")
        _ = otherStack   // keep the other writer's block-sync service alive for the whole test
    }

    @Test("""
        U-F2 (refused renumbering delete): the same on the RENUMBER path -- a deleting write that renumbers a survivor \
        and is refused by the writer leaves no checkpoint and changes nothing
        """)
    func refusedRenumberingDeleteLeavesNoCheckpoint() async throws {
        let db = try TestFixtureFactory.createTemporary(content: UndoDoc.pair)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)

        // Setup through the direct path (no writer yet): lastKnownRefs == ["1", "2"] and the content is recorded.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: UndoDoc.pair)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: UndoDoc.pair)

        // A writer that belongs to ANOTHER project database: every Notes write is refused (.identityMismatch).
        let otherStack = try makeStack()
        service.systemWriter = SystemWriter(blockSync: otherStack.sync)

        // Delete the FIRST reference: the survivor [^2] would be renumbered to [^1].
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: projectId, fullContent: UndoDoc.pairDeleted)
        await service.flushPendingSync()

        #expect(service.undoCheckpoints.isEmpty, "a refused renumbering delete must leave no checkpoint")
        let definitions = try definitionFragments(db)
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("First def.") }
                && definitions.contains { $0.hasPrefix("[^2]:") && $0.contains("Second def.") },
            "the refused write must not have changed anything; got \(definitions)")
        _ = otherStack   // keep the other writer's block-sync service alive for the whole test
    }

    @Test("""
        U-F3 (outcome, through the writer): several footnotes, delete the FIRST (the survivor is renumbered 2 -> 1) and \
        let the write apply, then undo twice with the usual debounce running in between: [^1] reads 'First def.' and \
        the survivor is back as [^2] with its CURRENT (edited) text
        """)
    func undoTwiceAfterDeletingTheFirstOfSeveralRestoresBoth() async throws {
        let stack = try makeStack(content: UndoDoc.pair)
        let service = FootnoteSyncService()
        service.configure(database: stack.db, projectId: stack.pid)
        service.systemWriter = SystemWriter(blockSync: stack.sync)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: UndoDoc.pair)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: UndoDoc.pair)

        // The delete (the survivor [^2] is renumbered to [^1] in the table) and the debounce firing.
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: stack.pid, fullContent: UndoDoc.pairDeleted)
        await service.flushPendingSync()
        #expect(try definitionFragments(stack.db) == ["[^1]: Second def."], "the table must hold the renumbered survivor only")
        #expect(service.undoCheckpoints.count == 1)

        // The editor's renumber arrives: refs equal the committed ["1"].
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: stack.pid, fullContent: UndoDoc.pairRenumbered)

        // Between the delete and the undos the user edits the surviving footnote's text under Notes.
        let notesBefore = try notesRows(stack.db)
        var survivor = try #require(notesBefore.first { $0.markdownFragment == "[^1]: Second def." })
        survivor.markdownFragment = "[^1]: Second def. EDITED"
        survivor.textContent = "Second def. EDITED"
        let edited = survivor
        try await stack.db.dbWriter.write { database in try edited.update(database) }

        // Undo #1 (the renumber): the body is the post-delete body again, with refs ["2"] against the committed
        // ["1"]. Step 6 supersedes the earlier "harmless, stays out of sequence" ruling: the undo of the editor's renumber
        // is a recorded state, so the survivor goes back to [^2] at once, keeping its CURRENT (edited) text.
        service.checkAndUpdateFootnotes(footnoteRefs: ["2"], projectId: stack.pid, fullContent: UndoDoc.pairRenumberUndone)
        await service.flushPendingSync()
        #expect(
            try definitionFragments(stack.db) == ["[^2]: Second def. EDITED"],
            "the first undo relabels the survivor to [^2] with its current text")

        // Undo #2 (the delete).
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: UndoDoc.pairUndone)
        await service.flushPendingSync()

        let definitions = try definitionFragments(stack.db)
        #expect(definitions.count == 2, "both definitions must be back; got \(definitions)")
        #expect(
            definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("First def.") },
            "[^1] must read 'First def.'; got \(definitions)")
        #expect(
            definitions.contains { $0.hasPrefix("[^2]:") && $0.contains("Second def. EDITED") },
            "[^2] must keep the survivor's CURRENT text, not be overwritten with the old one; got \(definitions)")
    }
}

// MARK: - Fixed deadline for a burst of reference changes (feedback round)

private enum BurstDoc {
    // Three footnotes; the last two are deleted one after the other inside one burst.
    static let triple = "# A\n\nOne[^1] two[^2] three[^3].\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
    static let lastDeleted = "# A\n\nOne[^1] two[^2] three.\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
    static let bothDeleted = "# A\n\nOne[^1] two three.\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
    /// Undo of the SECOND delete only: [^2] is back in the body; the editor's Notes hold only [^1] after the removal push.
    static let secondUndone = "# A\n\nOne[^1] two[^2] three.\n\n# Notes\n\n[^1]: First."
    /// Undo of the first delete too: the body is exactly the one before the burst (the Notes hold the blank row the
    /// in-between write made for [^2]).
    static let allUndone = "# A\n\nOne[^1] two[^2] three[^3].\n\n# Notes\n\n[^1]: First.\n\n[^2]: "
}

/// Counts the runs of `performFootnoteUpdate` that got past its entry guards (through `testInFlightHook`).
@MainActor
private final class RunCounter {
    var count = 0
}

@Suite("Footnote burst deadline — one fixed wait from the FIRST reference change, one write per burst", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FootnoteBurstDeadlineTests {

    /// A service whose first write committed `["1","2","3"]` and that recorded the content, with a shortened
    /// interval and a run counter installed AFTER that setup.
    private func serviceWithKnownTriple(
        db: ProjectDatabase, projectId: String, interval: TimeInterval, writer: SystemWriter? = nil
    ) async -> (service: FootnoteSyncService, runs: RunCounter) {
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)
        service.systemWriter = writer
        service.debounceInterval = interval
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: projectId, fullContent: BurstDoc.triple)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: projectId, fullContent: BurstDoc.triple)
        let runs = RunCounter()
        service.testInFlightHook = { runs.count += 1 }
        return (service, runs)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("""
        U-F9: two reference changes 0.4 s apart inside one burst (3 -> 2, then 2 -> 1), interval 0.8 s: the wait is a \
        fixed deadline from the FIRST change, so ONE write happens at about 0.8 s and removes both definitions, with \
        one checkpoint; the second change only replaces the snapshot and never restarts the timer
        """)
    func twoChangesInsideOneBurstGiveOneWriteAtTheFirstDeadline() async throws {
        let db = try TestFixtureFactory.createTemporary(content: BurstDoc.triple)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let (service, runs) = await serviceWithKnownTriple(db: db, projectId: projectId, interval: 0.8)

        let start = ContinuousClock.now
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: BurstDoc.lastDeleted)
        let firstTimer = service.debounceTask
        #expect(firstTimer != nil, "the first change of a burst starts the timer (test setup)")
        try await Task.sleep(for: .milliseconds(400))
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: BurstDoc.bothDeleted)
        #expect(service.debounceTask == firstTimer, "a later change inside the burst must NOT restart the timer")
        #expect(service.pendingUpdate?.refs == ["1"], "the waiting snapshot must be the latest one")

        let wrote = await waitUntil(timeout: 3) { runs.count >= 1 && service.state == .idle }
        let elapsed = ContinuousClock.now - start
        #expect(wrote, "the write must happen")
        #expect(elapsed < .milliseconds(1100), "the write must come about 0.8 s after the FIRST change, not the last; took \(elapsed)")

        try await Task.sleep(for: .milliseconds(500))
        #expect(runs.count == 1, "exactly one write for the whole burst; got \(runs.count)")
        #expect(try definitionFragments(db) == ["[^1]: First."], "both deleted definitions must be gone")
        #expect(service.undoCheckpoints.count == 1, "one checkpoint for the burst")
        #expect(service.undoCheckpoints.first?.refsBefore == ["1", "2", "3"])
        #expect(service.undoCheckpoints.first?.deletedDefinitions.keys.sorted() == ["2", "3"])
    }

    @Test("""
        U-F9b: as U-F9, but the second change returns the references to the committed set: the equal-refs branch \
        cancels the burst, so no write ever happens and the definitions stay (protects Step 2)
        """)
    func secondChangeBackToTheCommittedRefsCancelsTheBurst() async throws {
        let db = try TestFixtureFactory.createTemporary(content: BurstDoc.triple)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let (service, runs) = await serviceWithKnownTriple(db: db, projectId: projectId, interval: 0.3)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: BurstDoc.lastDeleted)
        #expect(service.testHasPendingUpdate, "the change must have started a burst (test setup)")
        try await Task.sleep(for: .milliseconds(100))
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: projectId, fullContent: BurstDoc.triple)
        #expect(!service.testHasPendingUpdate, "back at the committed refs the waiting snapshot must be dropped")
        #expect(service.debounceTask == nil, "and the timer cancelled")

        try await Task.sleep(for: .milliseconds(600))   // well past the first deadline
        #expect(runs.count == 0, "no write may happen")
        #expect(try definitionFragments(db).count == 3, "all three definitions must stay")
    }

    @Test("""
        U-F9c (through the writer): one burst removed two definitions, and a BLANK row for [^2] exists in the table when \
        the restore of the document exactly as before the burst runs (Step 6 restores each in-between step on its own, \
        so the blank row is put there directly): the restore must fill the blank row and bring BOTH texts back
        """)
    func undoOneAtATimeAfterABurstThatDeletedTwoRestoresBoth() async throws {
        let stack = try makeStack(content: BurstDoc.triple)
        let (service, _) = await serviceWithKnownTriple(
            db: stack.db, projectId: stack.pid, interval: 3.0, writer: SystemWriter(blockSync: stack.sync))

        // The burst: two changes, then the debounce firing (the flush runs the latest snapshot at once).
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: BurstDoc.lastDeleted)
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: stack.pid, fullContent: BurstDoc.bothDeleted)
        await service.flushPendingSync()
        #expect(try definitionFragments(stack.db) == ["[^1]: First."], "one write removed both definitions (test setup)")
        #expect(service.undoCheckpoints.count == 1)

        // A blank row for [^2] is in the table (the shape an unrecorded in-between undo used to leave).
        let blankRow = Block(
            projectId: stack.pid, sortOrder: 1000, blockType: .paragraph, textContent: "", markdownFragment: "[^2]: ", isNotes: true)
        try await stack.db.dbWriter.write { database in
            var row = blankRow
            try row.insert(database)
        }
        let blankLabelTwo = try definitionFragments(stack.db).contains {
            FootnoteSyncService.parseNotesLabel(from: $0).map { $0.label == "2" && $0.text.isEmpty } == true
        }
        #expect(blankLabelTwo, "the blank [^2] row must be there (test setup)")

        // Undo the first delete: the body is exactly the one before the burst.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: stack.pid, fullContent: BurstDoc.allUndone)
        await service.flushPendingSync()

        let definitions = try definitionFragments(stack.db)
        #expect(definitions.count == 3, "all three definitions must be back; got \(definitions)")
        #expect(definitions.contains { $0.hasPrefix("[^1]:") && $0.contains("First.") }, "[^1]; got \(definitions)")
        #expect(definitions.contains { $0.hasPrefix("[^2]:") && $0.contains("Second.") }, "[^2] must be filled, not left blank; got \(definitions)")
        #expect(definitions.contains { $0.hasPrefix("[^3]:") && $0.contains("Third.") }, "[^3]; got \(definitions)")
    }
}
