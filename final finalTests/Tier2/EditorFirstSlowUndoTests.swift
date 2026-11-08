//
//  EditorFirstSlowUndoTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 3, round 3c; plan tests U-S3-1 to U-S3-3, the judge's requirements R3+, R4, R5, R6, R7, R8, the
//  stale-rebuild cover, and the quick-path finding): the SLOW undo and redo in Rich Text, editor first. The scripted editor answers
//  `structuralSwapEditorFirst` (EditorFirstRig+SlowUndo.swift); the controller's side is StructuralUndoController+QueuedSnapshotUndo.swift.
//
//  "Slow" is forced with `testForceSlowDeleteUndo` (the quick path would otherwise take the undo of a fresh editor-first delete), or comes
//  from an entry that has no quick path (an entry the old duplicate recorded). The old body is reachable with `testForceLegacyStructural`.
//
//  Every typing test types into a block that holds NO footnote reference, and what is asserted is what the user sees: the text on the
//  screen (the stand-in editor's `editorText`), the rows in the database, the notice, the entry on the timeline.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// What the two suites of this file share.
@MainActor
fileprivate extension QuickUndoFixtures {

    /// The id of the plan's row with text `text`: the id the editor holds for it after a swap.
    func payloadId(_ rig: EditorFirstRig, of text: String) throws -> String {
        let plan = try #require(rig.controller.testLastRestorePlan)
        return try #require(plan.rows.first { $0.textContent == text }?.id)
    }

    /// A rig on `fourSections` (or `markdown`) whose undo is forced onto the slow path.
    func slowRig(_ markdown: String? = nil) throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: markdown ?? Self.fourSections)
        rig.controller.testForceSlowDeleteUndo = true
        return rig
    }

    /// The jobs pin the snapshots they write: unpin everything this rig's project holds when the test ends.
    static func unpinSnapshots(of rig: EditorFirstRig) {
        for snapshot in (try? SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots()) ?? [] {
            SnapshotService.unpinUndoPointSnapshot(snapshot.id)
        }
    }

    static var noticeText: String { "Some undo or redo presses could not be carried out." }

    /// The alert a slow undo whose job did not apply raises (UX contract 4.3).
    static var failedUndoMessage: String {
        "The undo couldn't be saved, so the document is back as it was before you pressed Undo. "
            + "Anything you typed in the text the undo brought back was removed with it."
    }
}

@Suite("Slow undo through the queue (t-18b7fa48 slice 3, round 3c, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstSlowUndoTests: QuickUndoFixtures {

    // MARK: - U-S3-1 to U-S3-3

    // U-S3-1: the slow undo swaps the saved checkpoint in an editor-first turn: no direct flush, no separate swap round-trip.
    // Predicted failure with the slow undo routed to the old body: "expected no separate checkpoint-swap call on the slow undo".
    @Test("U-S3-1: the slow undo is editor-first: one swap call, no flush before it, no separate checkpoint swap, no whole-document push")
    func testSlowUndoIsEditorFirst() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        let flushes = rig.getContentCalls
        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "expected no separate checkpoint-swap call on the slow undo")
        // The settle reads the editor's own text AFTER the job (D14), so the count is looked at the moment the swap was answered: nothing
        // was read from the live editor before it.
        let readsBeforeTheSwap = rig.getContentCallsAtSwap.map { $0 - flushes }
        #expect(readsBeforeTheSwap == 0, "expected no direct live-content flush before the swap, saw \(String(describing: readsBeforeTheSwap))")
        #expect(rig.scripts(containing: "structuralSwapEditorFirst").count == 1, "the editor was not asked exactly once")
        #expect(rig.scripts(containing: "cancelPendingInsertions").isEmpty, "the old sequence's boundary hygiene ran from Swift")
        #expect(rig.pushes.filter { !$0.preserveUserBlocks }.isEmpty, "the slow undo pushed the whole document into the editor")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "Section A is not back")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a fallback was logged: \(rig.persistedLog)")
        // The entry moved to the redo stack and holds the snapshot the job wrote (pinned).
        let entry = try #require(rig.unifiedUndo.redoStack.last)
        #expect(entry.id == deleted.entry.id)
        let redoSnapshot = try #require(entry.redoSnapshotId, "the job's snapshot was not attached to the entry")
        #expect(SnapshotService.isUndoPointSnapshotPinned(redoSnapshot), "the redo snapshot is not pinned")
        #expect(rig.editorState.pendingEditorFirstJobs == 0 && rig.editorState.pendingRemovalIds.isEmpty)
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the sidebar overlay was not lifted")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // U-S3-2 (D13, reworded for t-d2061b27): a slow undo the editor REFUSES (`docChanged`: the page found the document changed by an
    // automatic update it could not place the user's typing against, or a typed step with no place in the target document) hands back the
    // batch it consumed; the typing is saved, the entry stays, the notice shows. This is a HYGIENE test of Swift's handling of the
    // refusal against a STAND-IN editor: typing alone is no longer a reason to refuse (the page puts it back on top of the swap,
    // `typingReplayed`; see TypingAcrossUndoSwiftTests and the web tests). Assertions are unchanged.
    // Predicted failure with the swap applied on a changed document (the old body's overwrite): "typing during the slow undo was lost".
    @Test("U-S3-2: a slow undo the editor refused for an automatic change keeps the batch it consumed, leaves the entry, and shows the notice")
    func testSlowUndoRefusedForAnAutomaticChangeKeepsTheTypingBatchAndShowsTheNotice() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapLiveDiffers = true
        let para = try #require(rig.blocks().first { $0.textContent == "The B body." })
        rig.swapClickBatch = typing(para, to: "The B body typed.")
        _ = await rig.pressAndSettle(deleted.entry); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "undo failed", "got \(rig.replyWords())")
        let kept = await gateWaitUntil({ (try? rig.blocks().contains { $0.textContent == "The B body typed." }) == true })
        #expect(kept, "typing during the slow undo was lost")
        #expect(rig.toasts.current?.message == Self.noticeText, "got \(String(describing: rig.toasts.current?.message))")
        // R5: the entry stays recorded where it was, the document is as the user had it, and nothing is left running.
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id && rig.unifiedUndo.redoStack.isEmpty, "the entry moved")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the refused undo changed the document")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after the refusal")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "a job was queued for a refused press")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a refusal is not a fallback: \(rig.persistedLog)")
    }

    // U-S3-3 (#1, no checkpoint): an entry whose registry checkpoint is gone uses the whole replace from the snapshot.
    @Test("U-S3-3: a slow undo with no saved checkpoint uses slice 2's whole replace from the same plan")
    func testSlowUndoWithoutCheckpointUsesWholeReplace() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapAnswerNoCheckpoint = true
        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(!rig.scripts(containing: "replaceRangeEditorFirst").isEmpty, "the whole replace did not run")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "the old swap ran")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "Section A is not back")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        // It moves the existing entry; it records none of its own, and the redo snapshot is attached all the same.
        #expect(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.map(\.id) == [deleted.entry.id])
        #expect(rig.unifiedUndo.redoStack.last?.redoSnapshotId != nil, "no redo snapshot on the entry")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a fallback was logged: \(rig.persistedLog)")
    }

    // MARK: - R6: the redo

    // R6: slow undo then slow redo give the swapped-in document each time; the redo's snapshot becomes the entry's fresh undo snapshot.
    @Test("R6: the slow redo swaps the post-op document in with the same machinery, and the entry's undo snapshot is refreshed")
    func testSlowRedoMirrorsTheUndo() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        let firstSnapshot = try #require(rig.controller.efSlots.slot(deleted.entry.id)?.snapshotId)

        try await restorePress(rig, .undo)
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the undo did not bring the section back")
        try await restorePress(rig, .redo)

        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the redo did not take the section out again")
        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
        #expect(rig.swapScripts.count == 2, "expected one swap call per press, saw \(rig.swapScripts.count)")
        #expect(rig.swapScripts.first?.contains("\"undo\"") == true && rig.swapScripts.last?.contains("\"redo\"") == true)
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "the old swap ran")
        let entry = try #require(rig.unifiedUndo.undoStack.last, "the entry is not back on the undo stack")
        #expect(entry.id == deleted.entry.id && entry.redoSnapshotId == nil)
        let refreshed = try #require(rig.controller.efSlots.slot(entry.id)?.snapshotId)
        #expect(refreshed != firstSnapshot, "the redo must write a fresh undo snapshot id onto the slot")
        #expect(SnapshotService.isUndoPointSnapshotPinned(refreshed) && !SnapshotService.isUndoPointSnapshotPinned(firstSnapshot))
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a fallback was logged: \(rig.persistedLog)")
    }

    // R6: a slow redo the editor refuses (`docChanged`, an automatic change) keeps the batch it consumed and leaves the entry on the redo
    // stack. A HYGIENE test against the stand-in editor (typing alone no longer refuses a press: t-d2061b27); assertions are unchanged.
    @Test("R6: a slow redo the editor refused for an automatic change keeps the batch it consumed and keeps the entry on the redo stack")
    func testSlowRedoRefusedForAnAutomaticChangeKeepsTheTypingBatch() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        try await restorePress(rig, .undo)
        let para = try #require(rig.blocks().first { $0.textContent == "The B body." })
        rig.swapLiveDiffers = true
        rig.swapClickBatch = typing(para, to: "The B body typed.")

        try await restorePress(rig, .redo)

        #expect(rig.replyWords().last == "redo failed", "got \(rig.replyWords())")
        let kept = await gateWaitUntil({ (try? rig.blocks().contains { $0.textContent == "The B body typed." }) == true })
        #expect(kept, "typing during the slow redo was lost")
        #expect(rig.toasts.current?.message == Self.noticeText, "got \(String(describing: rig.toasts.current?.message))")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id && rig.unifiedUndo.undoStack.isEmpty, "the entry moved")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the refused redo changed the document")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
    }

    // R6 and R3 (U-S2-3 for the slow path): typing reserved after the click and applied after the job is KEPT; the job moves no epoch, so
    // no batch is refused for a stale one.
    @Test("R3/R6: the slow undo's and redo's job moves no write epoch and drops no typing made after the click", arguments: ["undo", "redo"])
    func testJobsMoveNoEpochAndKeepTypingAfterTheClick(_ direction: String) async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        if direction == "redo" { try await restorePress(rig, .undo) }
        let hold = try rig.holdQueue()   // the job is reserved but cannot run
        let epochBefore = try rig.projectWriteEpoch()
        let rejectionsBefore = rig.sync.testWriterLedger.debugRichTextStaleEpochRejections
        let systemWritesBefore = rig.sync.testWriterLedger.systemWritesApplied
        let reservedBefore = rig.spyLog.items.filter { $0 == "snapshotSwapJobReserved" }.count
        let press = rig.startPress(deleted.entry, direction == "undo" ? .undo : .redo)
        let reserved = await gateWaitUntil({ rig.spyLog.items.filter { $0 == "snapshotSwapJobReserved" }.count > reservedBefore })
        #expect(reserved, "the job was not reserved")

        let id = try payloadId(rig, of: "The B body.")   // the id the editor now holds for it
        rig.typingQueue.append(typing(id: id, to: "The B body typed."))
        let poll = rig.startReport()
        rig.release(hold)
        #expect(await rig.awaitRuns([press, poll]))
        _ = await rig.waitUntilSettled()

        #expect(try rig.blocks().contains { $0.id == id && $0.textContent == "The B body typed." }, "typing after the \(direction) was dropped")
        #expect(try rig.projectWriteEpoch() == epochBefore, "the \(direction)'s job bumped the write epoch")
        // Not vacuous (fix round F1, review C9d): the ledger read must be the rig's real writer's, which counted the swap's job.
        _ = try #require(rig.sync.testWriterHandle, "the rig has no writer: the ledger read below would be an empty one")
        #expect(
            rig.sync.testWriterLedger.systemWritesApplied > systemWritesBefore,
            "the ledger does not show the \(direction)'s job: it is not the rig's writer's")
        #expect(
            rig.sync.testWriterLedger.debugRichTextStaleEpochRejections == rejectionsBefore,
            "a batch was rejected for a stale epoch after the \(direction)")
    }

    // MARK: - R3+: the reservation window

    // The job is reserved in the click's reply turn. A main-actor turn that is already queued when the reply arrives (here: a task spawned
    // by the order spy at "efJS", i.e. right after the editor's call returned) must not get a place in the writer's queue BEFORE the job.
    // That task holds an editor ticket open; the job, reserved first, still runs and settles while it is held.
    // Predicted failure with the reservation moved into the spawned task (the restores' shape): "the job was queued behind a ticket ...".
    @Test("R3+: the job is reserved in the reply's own turn, ahead of any main-actor turn already queued")
    func testTheJobIsReservedInTheReplyTurn() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        final class TicketBox { var ticket: WriterTicket? }
        let box = TicketBox()
        var spawned = false
        rig.controller.testOrderingSpy = { [unowned rig] step in
            rig.spyLog.note(step)
            if step == "efJS", !spawned {
                spawned = true
                Task { @MainActor in box.ticket = try? rig.holdQueue() }   // queued BEFORE anything the reply turn would spawn
            }
        }
        let press = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([press]), "the press did not end")
        let interlopedIn = await gateWaitUntil({ box.ticket != nil })
        #expect(interlopedIn, "the interloping turn never ran")

        let settled = await rig.waitUntilSettled(iterations: 400)
        if let ticket = box.ticket { rig.release(ticket) }
        _ = await rig.waitUntilSettled()
        #expect(settled, "the job was queued behind a ticket reserved after the reply: it was not reserved in the reply turn")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the job did not apply")
    }

    // MARK: - R4: the managed regions

    // R4/R6: after the job the Notes and Bibliography regions are pushed from the database, for the undo and for the redo.
    @Test("R4/R6: after the slow undo's and redo's job the managed regions are pushed into the editor from the database", arguments: ["undo", "redo"])
    func testManagedRegionsArePushedAfterTheJob_book6(_ direction: String) async throws {
        let rig = try makeBookRig()
        rig.controller.testForceSlowDeleteUndo = true
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig)
        if direction == "redo" { try await restorePress(rig, .undo) }
        let repushes = { rig.spyLog.items.filter { $0 == "efRepushManagedRegions" }.count }
        let before = repushes()
        let pushesFrom = rig.pushes.count

        try await restorePress(rig, direction == "undo" ? .undo : .redo)

        #expect(repushes() == before + 1, "expected exactly one merge-guarded push of the database's regions after the \(direction)")
        let push = try #require(rig.pushes[pushesFrom...].last { $0.preserveUserBlocks })
        #expect(push.managedBlockIds == Set(try rig.db.fetchManagedBlockIds(projectId: rig.pid)), "the managed ids come from the database")
        #expect(rig.pushes[pushesFrom...].filter { !$0.preserveUserBlocks }.isEmpty, "a whole-document push reached the editor")
        let sectionIsThere = try rig.blocks().contains { $0.textContent == deleted.root.textContent }
        #expect(sectionIsThere == (direction == "undo"), "the \(direction) left the wrong document in the table")
    }

    // MARK: - R7: refused, then retried

    // R7, the Swift side only: a slow undo the editor refused (`docChanged`, an automatic change; the stand-in hands back a typing
    // batch) keeps the entry where it was and the batch in the database, and the SAME press, repeated on the quiet document, is carried
    // out. This test does NOT model the user's Cmd-Z taking the typing back (a text undo inside the editor, which Swift never sees):
    // `swapLiveDiffers` is single-shot, so the second press simply finds the document equal to the saved copy. That the editor really
    // routes the press (text undo first, then the structural one) is proven by the web test R2a (slow-swap.test.ts) and by the VM
    // end-to-end tests, not here. (Reworded for t-d2061b27: typing alone no longer refuses; assertions are unchanged.)
    @Test("R7: a slow undo refused for an automatic change, then the retry on the quiet document, is carried out; it never refuses twice")
    func testRefusedForAnAutomaticChangeThenRetriedIsCarriedOut() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        let para = try #require(rig.blocks().first { $0.textContent == "The B body." })
        rig.swapLiveDiffers = true
        rig.swapClickBatch = typing(para, to: "The B body typed.")

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()
        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        let kept = await gateWaitUntil({ (try? rig.blocks().contains { $0.textContent == "The B body typed." }) == true })
        #expect(kept, "the typing is not in the database after the refusal")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id, "the refusal removed the entry")

        // (The stand-in's refusal was single-shot: the document equals the saved copy again, and the same press is carried out.)
        try await restorePress(rig, .undo)
        #expect(rig.replyWords() == ["undo failed", "undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the retried undo did not bring the section back")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id)
        #expect(rig.editorState.structuralGate.isIdle && rig.editorState.pendingEditorFirstJobs == 0)
    }

    // MARK: - R8 and the fallbacks

    // R8: in Markdown the slow undo is the old body, unchanged.
    // Predicted failure with the Markdown test taken out of the routing: "expected the old body in Markdown mode".
    @Test("R8: in Markdown mode the slow undo runs the old body: no swap call to the Rich Text editor")
    func testMarkdownModeKeepsTheOldBody() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.editorState.editorMode = .source

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.swapScripts.isEmpty && rig.scripts(containing: "structuralSwapEditorFirst").isEmpty, "expected the old body in Markdown mode")
        #expect(!rig.scripts(containing: "cancelPendingInsertions").isEmpty, "the old body did not run")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the old body did not bring the section back")
    }

    // D7: the editor cannot fit the payload to its saved document (`idAlignment`): nothing was swapped, the batch was applied, and the OLD
    // body runs in the same gate turn, with the fallback logged under this rig's project id.
    @Test("D7: an idAlignment refusal falls back to the old body in the same turn, and the fallback is logged")
    func testIdAlignmentFallsBackToTheOldBody() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapAnswerIdAlignment = true

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        let line = "[EF-STRUCT] snapshotUndo fell back to the old path: idAlignment"
        #expect(rig.persistedLog.contains { $0.contains(line) }, "no fallback line in this rig's log: \(rig.persistedLog)")
        #expect(!rig.scripts(containing: "performStructuralSwap").isEmpty, "the old body did not run")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the old body did not bring the section back")
        #expect(rig.alerts.isEmpty && rig.toasts.current?.message != Self.noticeText, "a fallback is not a refusal")
        #expect(rig.editorState.pendingEditorFirstJobs == 0 && rig.editorState.efJobRegistry.outstandingCount == 0)
    }

}

@Suite("Slow undo through the queue: held presses, failures, the quick path, old entries, stale rebuilds (round 3c, Tier 2)",
       .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstSlowUndoGuardTests: QuickUndoFixtures {

    // MARK: - A press that arrives while a swap is being carried through

    // Floor item 2: the redo pressed right after the undo, before the undo's job has applied, is HELD (the snapshot it needs is the one the
    // job writes) and carried out afterwards, never refused.
    @Test("A redo pressed before the slow undo's job has applied is held and carried out, not refused")
    func testRedoPressedBeforeTheUndoJobAppliedIsHeld() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        let hold = try rig.holdQueue()   // the undo's job cannot run
        let undo = rig.startPress(deleted.entry, .undo)
        #expect(await gateWaitUntil({ undo.done }, iterations: 800), "the undo did not end")
        let redo = rig.startPress(deleted.entry, .redo)
        let answeredEarly = await gateWaitUntil({ redo.done }, iterations: 40)
        #expect(!answeredEarly, "the redo was answered before the undo's job had applied: \(rig.replyWords())")

        rig.release(hold)
        #expect(await rig.awaitRuns([undo, redo]))
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the redo did not take the section out again")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id)
    }

    // MARK: - What a failed job does

    // D13/D15: the editor already swapped when the job runs; a job that does not apply (a database fault) puts the document back from the
    // database, takes the entry off the timeline and tells the user. A later Cmd-Z for the entry is answered `failed`.
    @Test("A failed slow-undo job puts the document back from the database, drops the entry and tells the user")
    func testFailedJobPutsTheDocumentBack() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.modelsWholePushOnEditor = true
        rig.forceNextJobFailure = true

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.controller.testShownAlerts == ["Couldn't Undo"], "got \(rig.controller.testShownAlerts)")
        #expect(rig.alerts.first?.message == Self.failedUndoMessage, "got \(String(describing: rig.alerts.first?.message))")
        #expect(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.isEmpty, "the entry is still on the timeline")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the table does not hold the document from before the press")
        #expect(rig.editorText?.contains("Section A") == false, "the editor still shows the swapped-in document")
        #expect(rig.editorState.pendingEditorFirstJobs == 0 && rig.editorState.pendingRestoreSections.isEmpty)

        #expect(await rig.pressAndSettle(deleted.entry))
        #expect(rig.replyWords().last == "undo failed", "got \(rig.replyWords())")
    }

    // Fix round F4 (break patch S1-08: `detectPausedEdits: true` of the put-back's push, shared by every editor-first kind). The put-back's
    // push replaces the editor's whole document while its block sync is paused; keystrokes made in that window survive as pending changes
    // only when the push asks for `detectPausedEdits`. The slow undo's put-back had no such test (the duplicate's and the whole restore's
    // did). Predicted failure with the option switched off: "the put-back removed the typing made during its push from the editor".
    @Test("A failed slow-undo job's put-back keeps the typing made while its push is in flight")
    func testFailedJobPutBackKeepsTypingMadeDuringItsPush() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        let bBody = try #require(try rig.blocks().first { $0.textContent == "The B body." })
        rig.modelsWholePushOnEditor = true
        rig.typedDuringNextWholePush = (bBody, " LATER")   // typed while the put-back's push is in flight
        rig.forceNextJobFailure = true

        #expect(await rig.pressAndSettle(deleted.entry))
        await settleThenCarryRestoreTyping(rig)

        #expect(rig.controller.testShownAlerts == ["Couldn't Undo"], "got \(rig.controller.testShownAlerts)")
        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("The B body. LATER"), "the put-back removed the typing made during its push from the editor: \(screen)")
        #expect(!screen.contains("Section A"), "the editor still shows the swapped-in document: \(screen)")
        let wholePushes = rig.pushes.filter { !$0.preserveUserBlocks }
        #expect(wholePushes.contains { $0.detectPausedEdits }, "the put-back's push did not ask for detectPausedEdits")
        #expect(
            try rig.blocks().contains { $0.textContent == "The B body. LATER" },
            "the typing made during the put-back's push never reached the table")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the table does not hold the document from before the press")
    }

    // MARK: - The quick path after a slow swap

    // The web swap does not refresh the registry entry's id maps, so a quick undo after a slow undo and redo of the same entry would
    // restore op-time ids. The quick path is not offered for it: the next undo is slow again.
    // Predicted failure with `efRecordedStructGeneration[opId] = nil` removed: "the quick path was offered for a slow-swapped entry".
    @Test("The quick path is not offered for an entry that has been slow-swapped (slow undo, slow redo, undo again)")
    func testQuickPathIsClosedForASlowSwappedEntry() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        #expect(rig.controller.quickUndoEligible(deleted.entry), "precondition: before the swap the entry is eligible")

        try await restorePress(rig, .undo)
        try await restorePress(rig, .redo)
        rig.controller.testForceSlowDeleteUndo = false   // the third press is NOT forced slow

        let entry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(!rig.controller.quickUndoEligible(entry), "the quick path was offered for a slow-swapped entry")
        try await restorePress(rig, .undo)
        #expect(rig.quickUndoScripts.isEmpty, "the third press took the quick path")
        #expect(rig.swapScripts.count == 3, "expected three slow swaps, saw \(rig.swapScripts.count)")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" })
        #expect(rig.replyWords() == ["undo performed", "redo performed", "undo performed"], "got \(rig.replyWords())")
    }

    // MARK: - An entry the old duplicate recorded

    // The slow path is the road of every entry that has no quick path, an entry of the OLD duplicate included. Its snapshot ids live on
    // the entry (not on a slot): the redo snapshot is attached after the undo and replaced by a fresh undo snapshot after the redo, and
    // the pin set holds exactly the live ids all along (the unit test U20 for the editor-first slow path).
    @Test("An entry the old duplicate recorded: slow undo and redo through the editor, snapshot ids and pins as the old body left them")
    func testSlowUndoAndRedoOfAnOldDuplicateEntry() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        defer { Self.unpinSnapshots(of: rig) }
        rig.controller.testForceLegacyStructural = true
        #expect(await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id) == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(!entry.isEditorFirst && entry.undoSnapshotId != nil, "precondition: the old duplicate's entry carries its snapshot id")
        rig.controller.testForceLegacyStructural = false
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        func pinned() throws -> Set<String> {
            SnapshotService.pinnedUndoPointSnapshotIdsForTesting.intersection(Set(try snapshots.fetchAllSnapshots().map(\.id)))
        }

        try await restorePress(rig, .undo)
        #expect(rig.swapScripts.count == 1 && rig.scripts(containing: "performStructuralSwap").isEmpty, "the undo was not editor-first")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "the undo did not take the copy out")
        let undone = try #require(rig.unifiedUndo.redoStack.last)
        let live = Set([try #require(undone.undoSnapshotId), try #require(undone.redoSnapshotId)])
        #expect(try pinned() == live, "after the undo the pin set must hold exactly the entry's two snapshot ids")

        try await restorePress(rig, .redo)
        #expect(rig.swapScripts.count == 2, "the redo was not editor-first")
        #expect(try rig.blocks().contains { $0.textContent == "Section C copy" }, "the redo did not bring the copy back")
        let redone = try #require(rig.unifiedUndo.undoStack.last)
        #expect(redone.redoSnapshotId == nil && redone.undoSnapshotId != undone.undoSnapshotId, "the redo must give the entry a fresh undo snapshot")
        #expect(try pinned() == [try #require(redone.undoSnapshotId)], "after the redo the pin set must hold exactly the fresh undo snapshot")
        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
    }

    // MARK: - The stale-rebuild cover (D6)

    // A Notes or bibliography rebuild that READ the database before the click lands after it: its push is skipped and the editor still
    // shows the swapped-in document. The rebuild starts in the one gap the press does not wait for rebuilds in: after the snapshot was
    // found and before the click (`testAfterUndoSnapshotResolved`).
    @Test("A rebuild that read before the slow undo's click skips its push; the editor still shows the swapped-in document",
          arguments: ["article", "book6"])
    func testStaleRebuildReadBeforeTheClickDoesNotBringBackThePostOpDocument(_ doc: String) async throws {
        let rig = try makeRestoreRig(doc)
        rig.controller.testForceSlowDeleteUndo = true
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, doc == "article" ? Self.villageRegisters : nil)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        rig.controller.testAfterUndoSnapshotResolved = { [unowned rig] in
            self.startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the post-delete document
        }
        let pushesFrom = rig.pushes.count

        let press = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([press]), "the press did not end")
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the slow undo never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read before the click")
        try expectTheEditorKeepsTheSwappedInDocument(rig, root: deleted.root, pushesFrom: pushesFrom)
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
    }

    // The other order: a rebuild that read the database WHILE the job was pending (the table still holds the post-op document).
    @Test("A rebuild that read while the slow undo's job was pending skips its push; the editor still shows the swapped-in document",
          arguments: ["article", "book6"])
    func testStaleRebuildReadWhileTheJobWasPendingDoesNotBringBackThePostOpDocument(_ doc: String) async throws {
        let rig = try makeRestoreRig(doc)
        rig.controller.testForceSlowDeleteUndo = true
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, doc == "article" ? Self.villageRegisters : nil)
        let hold = try rig.holdQueue()   // the job is reserved but cannot run: the table still holds the post-delete document
        let pushesFrom = rig.pushes.count
        let press = rig.startPress(deleted.entry)
        #expect(await gateWaitUntil({ press.done }, iterations: 800), "the press did not end")
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the post-delete document, after the click, while the job pends

        rig.release(hold)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the slow undo never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read while pending")
        try expectTheEditorKeepsTheSwappedInDocument(rig, root: deleted.root, pushesFrom: pushesFrom)
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
    }

    /// What the user sees after a slow undo that met a stale rebuild: the editor's text is the swapped-in document and nothing pushed to
    /// the editor after the click lacks the section the undo brought back.
    private func expectTheEditorKeepsTheSwappedInDocument(_ rig: EditorFirstRig, root: Block, pushesFrom: Int) throws {
        let plan = try #require(rig.controller.testLastRestorePlan)
        let text = try #require(rig.editorText, "the editor holds no document")
        #expect(Self.ownText(of: text) == Self.ownText(of: plan.markdown), "the editor's text is not the swapped-in document")
        #expect(text.contains(root.textContent), "the section the undo brought back is not on the screen")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(
            pushes.allSatisfy { $0.markdown.contains(root.textContent) },
            "the stale rebuild pushed the post-op document (\(pushes.count) push(es) after the click)")
        #expect(Self.ownText(of: rig.editorState.content) == Self.ownText(of: plan.markdown), "content is not the swapped-in document")
        // Fix round F1, review C2: the push the stale rebuild skipped is made up for by the settle's closing push, so once everything has
        // settled the editor's Notes and Bibliography regions are the database's (`ownText` leaves them out of the comparison above).
        let databaseNotes = Self.notesRegion(of: try rig.assembledMarkdown())
        #expect(
            Self.notesRegion(of: text) == databaseNotes,
            "the editor's Notes were left behind: the skipped rebuild's push was not made up for after the slow undo")
    }
}
