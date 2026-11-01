//
//  TypingAcrossUndoRound6Tests.swift
//  final finalTests
//
//  Tier 2 (t-d2061b27, Phase 4c job 2, coder S round 6): the two Swift fixes the plan judge ordered after the second-look review, Rich Text,
//  against the scripted stand-in editor (`EditorFirstRig`); the page's own behaviour is the web tests' and the VM tests' business.
//
//    - S-1 (N1)  the older redo entries end after a successful QUICK REDO only when the reply says `typed: true` (the page's own answer),
//                not for any non-empty `batch`: the batch can hold a rewrite the previous command's settle left, and ending the branch for
//                it would lose a second Cmd-Shift-Z in a row. One test per route (Delete, Duplicate, restore). The `typed: true` controls
//                are the F4 tests of TypingAcrossUndoReviewTests (their stubbed replies carry `typed: true` since this round).
//    - S-2 (N3)  a slow undo with no saved checkpoint (the `noCheckpoint` whole-replace road) whose call consumed pending typing is
//                REFUSED with the existing notice before any whole replace: the replace would take the typing off the screen and its job
//                would overwrite the rows. The typing is already sent as batch N and stays. (An empty batch still takes the whole replace:
//                U-S3-3 in EditorFirstSlowUndoTests.)
//
//  Break patches are in .claude/superdev/cmdz-waits-through-typing/break-patches/ (SW-R8-N1-*, SW-R8-N3-*), named in each test's comment.
//  NOT RUN by the coder.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Typing across a waiting Cmd-Z, round 6, Rich Text (t-d2061b27, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct TypingAcrossUndoRound6Tests: QuickUndoFixtures {

    private static var noticeText: String { "Some undo or redo presses could not be carried out." }
    private static let rewritten = "The B body. REWRITTEN BY A SETTLE"
    private static let kept = "The B body. KEPT"

    private func slowRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.controller.testForceSlowDeleteUndo = true
        return rig
    }

    private static func unpinSnapshots(of rig: EditorFirstRig) {
        for snapshot in (try? SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots()) ?? [] {
            SnapshotService.unpinUndoPointSnapshot(snapshot.id)
        }
    }

    private func rowCount(_ rig: EditorFirstRig, _ text: String) throws -> Int {
        try rig.blocks().filter { $0.textContent == text }.count
    }

    /// A rewrite of the B paragraph that is NOT the user's typing (what the previous command's settle can leave in a redo's batch).
    private func settleRewriteOfB(_ rig: EditorFirstRig) throws -> BlockChanges {
        typing(try #require(rig.blocks().first { $0.textContent == "The B body." }), to: Self.rewritten)
    }

    // MARK: - S-1: the older redo entries end only when the page says the user typed

    // Delete: two Deletes undone the quick way, the older one redone with a NON-EMPTY batch (the rewrite) and `typed: false`. The batch is
    // still applied (the rows hold it), but the NEWER entry stays on the redo stack, so a second Cmd-Shift-Z in a row is performed.
    // Predicted failure with the condition put back to `!reply.batch.isEmpty` (`SW-R8-N1-delete-batch-condition.patch`), on the assertion
    // "a non-typing batch ended the redo branch" (the redo stack is empty after the first redo).
    @Test("S-1 (Delete): a quick redo whose reply has a non-empty batch but `typed: false` keeps the older redo entries; a second redo runs")
    func testQuickRedoOfDeleteWithANonTypingBatchKeepsTheOlderRedoEntries() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let older = try await delete(rig, "Section A")
        let newer = try await delete(rig, "Section C")
        #expect(await rig.pressAndSettle(newer.entry)); _ = await rig.waitUntilSettled()
        #expect(await rig.pressAndSettle(older.entry)); _ = await rig.waitUntilSettled()
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id, older.entry.id], "premise: two entries wait for a redo")
        try rig.setReply(.init(batch: try settleRewriteOfB(rig), removedLeaderIds: [older.root.id]), forRoot: older.root.id)
        rig.redoReplyTyped = false

        #expect(await rig.pressAndSettle(older.entry, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        let applied = await gateWaitUntil({ (try? self.rowCount(rig, Self.rewritten)) == 1 })
        #expect(applied, "the batch the redo handed back was not sent as batch N")
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id], "a non-typing batch ended the redo branch")

        // The second Cmd-Shift-Z in a row.
        #expect(await rig.pressAndSettle(newer.entry, .redo)); _ = await rig.waitUntilSettled()
        #expect(rig.replyWords().suffix(2) == ["redo performed", "redo performed"], "the second redo found no redo: \(rig.replyWords())")
        #expect(rig.unifiedUndo.undoStack.map(\.id) == [older.entry.id, newer.entry.id], "the second redo did not move its entry")
        #expect(rig.unifiedUndo.redoStack.isEmpty)
    }

    // Duplicate: the same for the quick redo of a Duplicate Section. Predicted failure with the condition put back
    // (`SW-R8-N1-duplicate-batch-condition.patch`): "a non-typing batch ended the redo branch".
    @Test("S-1 (Duplicate): a quick redo of a duplicate whose reply has a non-empty batch but `typed: false` keeps the older redo entries")
    func testQuickRedoOfDuplicateWithANonTypingBatchKeepsTheOlderRedoEntries() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        #expect(outcome == .performed, "the duplicate ended \(outcome)")
        _ = await rig.waitUntilSettled()
        let older = try #require(rig.unifiedUndo.undoStack.last, "the duplicate recorded no entry")
        let newer = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(newer.entry)); _ = await rig.waitUntilSettled()
        #expect(await rig.pressAndSettle(older)); _ = await rig.waitUntilSettled()
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id, older.id], "premise: two entries wait for a redo")
        rig.redoReplyBatch = try settleRewriteOfB(rig)
        rig.redoReplyTyped = false

        #expect(await rig.pressAndSettle(older, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id], "a non-typing batch ended the redo branch")
        #expect(await rig.pressAndSettle(newer.entry, .redo)); _ = await rig.waitUntilSettled()
        #expect(rig.replyWords().suffix(2) == ["redo performed", "redo performed"], "the second redo found no redo: \(rig.replyWords())")
    }

    // Restore: the same for the quick redo of a section restore. Predicted failure with the condition put back
    // (`SW-R8-N1-restore-batch-condition.patch`): "a non-typing batch ended the redo branch".
    @Test("S-1 (restore): a quick redo of a section restore whose reply has a non-empty batch but `typed: false` keeps the older redo entries")
    func testQuickRedoOfRestoreWithANonTypingBatchKeepsTheOlderRedoEntries() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        try rig.rewriteText(ofBlock: try blockWithText(rig, "The C body.").id, to: Self.editedBody)   // so the restore changes something
        try await rig.fillSectionTable()
        #expect(await rig.performRestore("replace", from: version, section: "Section C") == .performed)
        _ = await rig.waitUntilSettled()
        let older = try #require(rig.unifiedUndo.undoStack.last, "the restore recorded no entry")
        let newer = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(newer.entry)); _ = await rig.waitUntilSettled()
        #expect(await rig.pressAndSettle(older)); _ = await rig.waitUntilSettled()
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id, older.id], "premise: two entries wait for a redo")
        rig.redoReplyBatch = try settleRewriteOfB(rig)
        rig.redoReplyTyped = false

        #expect(await rig.pressAndSettle(older, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id], "a non-typing batch ended the redo branch")
        #expect(await rig.pressAndSettle(newer.entry, .redo)); _ = await rig.waitUntilSettled()
        #expect(rig.replyWords().suffix(2) == ["redo performed", "redo performed"], "the second redo found no redo: \(rig.replyWords())")
    }

    // MARK: - S-2: no checkpoint and pending typing

    // The editor has no saved state for the entry (`noCheckpoint`) and the call consumed typing (the batch). The press is REFUSED with the
    // existing notice BEFORE the whole replace: no `replaceRangeEditorFirst` is sent, the typing (already sent as batch N) is in the rows,
    // the document is as it was, the entry stays where it is, and nothing is left running.
    // Predicted failure with the guard removed (`SW-R8-N3-no-checkpoint-guard-removed.patch`): on the first assertion, the reply is
    // "undo performed" (the whole replace ran) instead of "undo failed"; the replace script and the lost typing fail after it.
    @Test("S-2: a slow undo with no saved checkpoint and typing in the wait is refused before the whole replace; the typing stays")
    func testNoCheckpointWithPendingTypingIsRefusedBeforeTheWholeReplace() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapAnswerNoCheckpoint = true
        rig.swapClickBatch = typing(try #require(rig.blocks().first { $0.textContent == "The B body." }), to: Self.kept)

        _ = await rig.pressAndSettle(deleted.entry); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        #expect(rig.scripts(containing: "replaceRangeEditorFirst").isEmpty, "the whole replace was issued although typing was pending")
        #expect(rig.toasts.current?.message == Self.noticeText, "got \(String(describing: rig.toasts.current?.message))")
        let kept = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(kept, "the typing the call consumed is not in the rows exactly once")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the refused undo changed the document")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id && rig.unifiedUndo.redoStack.isEmpty, "the entry moved")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after the refusal")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0, "a job was queued for a refused press")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a refusal was logged as a fallback: \(rig.persistedLog)")
    }
}
