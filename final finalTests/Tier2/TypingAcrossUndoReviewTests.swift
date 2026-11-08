//
//  TypingAcrossUndoReviewTests.swift
//  final finalTests
//
//  Tier 2 (t-d2061b27, Phase 4c job 2, coder S round S2): the Swift tests the review round and the plan judge ordered, Rich Text, against the
//  scripted stand-in editor (`EditorFirstRig`; the page's own behaviour is the web tests' and the VM tests' business). Round S1's tests are in
//  TypingAcrossUndoSwiftTests.swift.
//
//    - F7   a press the OLD body takes releases the page's held typing first and sends it as batch N, once, before the old body runs
//    - F4   a quick redo (Delete, Duplicate, restore) whose reply carries the typing done in its wait ends the older redo entries too
//    - F14  a quick undo that replayed typing still sets the pending-restore overlay while the reinsert runs (the Outline card shows)
//    - F18  a refused press shows nothing when a close has begun (slow route and quick undo); with the gate open the notice shows
//    - F13  a slow-route `docChanged` that carries a typing batch is a refusal (failed, batch applied, notice), never the old body
//    - T-a / T-c  the lifecycle's release: the held typing is saved EXACTLY ONCE by a close; the release is asked once and bounded
//    - T-b  TA-1's premise: the stand-in honours `liveDiffersOverride`, so only the flag can end the branch (and the compare still can)
//
//  Break patches are in .claude/superdev/cmdz-waits-through-typing/break-patches/ (named in each test's comment). NOT RUN by the coder.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Typing across a waiting Cmd-Z, review round, Rich Text (t-d2061b27, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct TypingAcrossUndoReviewTests: QuickUndoFixtures {

    private static var noticeText: String { "Some undo or redo presses could not be carried out." }
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

    /// How many rows read exactly `text`.
    private func rowCount(_ rig: EditorFirstRig, _ text: String) throws -> Int {
        try rig.blocks().filter { $0.textContent == text }.count
    }

    /// The typing the user did in the B paragraph, as the batch the page would hand back.
    private func typedB(_ rig: EditorFirstRig) throws -> BlockChanges {
        typing(try #require(rig.blocks().first { $0.textContent == "The B body." }), to: Self.kept)
    }

    // MARK: - F7: the old body

    // The editor-first route hands the press to the old body (here `testForceLegacyStructural`, as a zoomed press or a missing plan does).
    // The page is still holding the user's typing back from the polls, so the controller releases it and sends the batch it takes FIRST,
    // once, before the old body's first call.
    // What the redo snapshot holds (found by the first run, S3): the old body's own flush (`flushLiveContentToDatabase`) writes the
    // editor's LIVE text (`getContent()`) into the rows before it takes its undo-point snapshot (the redo's). The real editor's live text
    // includes the typing whatever the hold does; the stand-in's does not unless told, so here it is told (`fetchAnswerProvider`). The
    // snapshot check therefore pins "no duplicate, no loss" (the batch update and the flush together leave the typing in the rows exactly
    // once); WHETHER the release was made is pinned by the call count and the order against the old body's first call.
    // Predicted failure with the release not made (`SW-F7-release-skipped.patch`): "the old body never asked the editor to release the
    // held typing".
    @Test("F7: a press the old body takes releases the page's held typing first and sends it as batch N, once")
    func testAPressTheOldBodyTakesReleasesTheHeldTypingFirst() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        rig.controller.testForceLegacyStructural = true
        let deleted = try await delete(rig, "Section A")
        rig.heldTypingBatch = try typedB(rig)
        let typedDocument = try rig.assembledMarkdown().replacingOccurrences(of: "The B body.", with: Self.kept)
        rig.fetchAnswerProvider = { typedDocument }   // the editor's live text includes the typing, as the real one's does

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.releaseAndGetBatchCalls == 1, "the old body never asked the editor to release the held typing (or asked more than once)")
        #expect(rig.heldTypingBatch == nil, "the held typing was not taken")
        let items = rig.events.items
        let release = items.firstIndex { $0.contains("releaseHeldTypingAndGetBatch") }
        let body = items.firstIndex { $0.contains("cancelPendingInsertions") || $0.contains("performStructuralSwap") }
        #expect(release != nil && body != nil && release! < body!, "the release did not come before the old body: \(items.prefix(12))")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        let redoSnapshot = try #require(rig.unifiedUndo.redoStack.last?.redoSnapshotId, "the old body left no redo snapshot")
        let plan = try #require(try SnapshotService.wholeRestorePlan(database: rig.db, projectId: rig.pid, snapshotId: redoSnapshot))
        #expect(plan.rows.filter { $0.textContent == Self.kept }.count == 1, "the typing is not in the redo snapshot exactly once (lost or doubled)")
    }

    // MARK: - F4: a quick redo with typing in its wait ends the older redo entries

    // Delete: two Deletes, both undone the quick way (the older entry on top of the redo stack), then the older one redone with the typing
    // done in its wait as the reply's batch and `typed: true` (`ok: true`, no `typingReplayed`; round 6: the page says whether the user
    // typed, the batch alone is no proof). The typing reaches the rows once and the NEWER entry, still waiting on the redo stack, is
    // ended: typing after a press ends the whole redo branch, as it does in Markdown. The control of round 6's
    // TypingAcrossUndoRound6Tests (`typed: false` with a non-empty batch keeps the branch).
    // Predicted failure with the call skipped (`SW-F4-quick-redo-delete-skips-end.patch`): "the older redo entry survived the typing".
    @Test("F4 (Delete): a quick redo whose reply says the user typed (and carries the typing as its batch) ends the older redo entries")
    func testQuickRedoOfDeleteWithTypingEndsTheOlderRedoEntries() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let older = try await delete(rig, "Section A")
        let newer = try await delete(rig, "Section C")
        #expect(await rig.pressAndSettle(newer.entry)); _ = await rig.waitUntilSettled()
        #expect(await rig.pressAndSettle(older.entry)); _ = await rig.waitUntilSettled()
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id, older.entry.id], "premise: two entries wait for a redo")
        try rig.setReply(.init(batch: try typedB(rig), removedLeaderIds: [older.root.id]), forRoot: older.root.id)
        rig.redoReplyTyped = true   // the page's own answer: the user typed since the key was pressed

        #expect(await rig.pressAndSettle(older.entry, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        let saved = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(saved, "the typing the redo handed back did not reach the rows exactly once")
        #expect(rig.unifiedUndo.undoStack.last?.id == older.entry.id, "the redone entry is not back on the undo stack")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the older redo entry survived the typing")
        let descriptor = rig.scripts(containing: "setUndoDescriptor").last
        #expect(
            descriptor != nil && descriptor?.contains("redoTopOpId") == false,
            "the editor still thinks a redo exists: \(String(describing: descriptor))")
    }

    // Duplicate: the same, for the quick redo of a Duplicate Section. Predicted failure with the call skipped
    // (`SW-F4-quick-redo-duplicate-skips-end.patch`): "the older redo entry survived the typing".
    @Test("F4 (Duplicate): a quick redo of a duplicate whose reply says the user typed (batch and `typed: true`) ends the older redo entries")
    func testQuickRedoOfDuplicateWithTypingEndsTheOlderRedoEntries() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading("Section C").id)
        #expect(outcome == .performed, "the duplicate ended \(outcome)")
        _ = await rig.waitUntilSettled()
        let older = try #require(rig.unifiedUndo.undoStack.last, "the duplicate recorded no entry")
        let newer = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(newer.entry)); _ = await rig.waitUntilSettled()
        #expect(await rig.pressAndSettle(older)); _ = await rig.waitUntilSettled()
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [newer.entry.id, older.id], "premise: two entries wait for a redo")
        rig.redoReplyBatch = try typedB(rig)
        rig.redoReplyTyped = true   // the page's own answer: the user typed since the key was pressed

        #expect(await rig.pressAndSettle(older, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        let saved = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(saved, "the typing the redo handed back did not reach the rows exactly once")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the older redo entry survived the typing")
    }

    // Restore: the same, for the quick redo of a Version History restore. It is a REPLACE CURRENT SECTION (Section C from the saved
    // version over the live one), and the typing is in Section B, outside what the redo takes out: that is the case where a quick redo of a
    // restore runs with the typing as its batch. (Round S3: with a whole-PROJECT restore every row is taken out, so the real page refuses
    // typing anywhere, `typingInRemovedSection`, and the redo job rewrites every row: the first version of this test was not a real case.)
    // Predicted failure with the call skipped (`SW-F4-quick-redo-restore-skips-end.patch`): "the older redo entry survived the typing".
    @Test("F4 (restore): a quick redo of a section restore whose reply says the user typed (batch and `typed: true`) ends the older redo entries")
    func testQuickRedoOfRestoreWithTypingEndsTheOlderRedoEntries() async throws {
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
        rig.redoReplyBatch = try typedB(rig)
        rig.redoReplyTyped = true   // the page's own answer: the user typed since the key was pressed

        #expect(await rig.pressAndSettle(older, .redo)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        let saved = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(saved, "the typing the redo handed back did not reach the rows exactly once")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the older redo entry survived the typing")
    }

    // MARK: - F14: the Outline card

    // A quick undo whose reply says the typing was put back on top: the redo branch ends at once, which forgets the entry's job keys
    // and their registry records. The restored section's sidebar update (it waits for the editor's paint) used to read "reinsert
    // resolved" from that missing record and skip the pending-restore overlay, so the card was missing until the reinsert's settle. It
    // now reads the pending-reinsert count. The paint is held until the press is over; the reinsert is held in the queue.
    // Predicted failure with the registry read back (`SW-F14-registry-read.patch`): "the pending-restore overlay was not set while the
    // reinsert runs".
    @Test("F14: a quick undo that replayed typing still sets the pending-restore overlay while the reinsert runs")
    func testQuickUndoThatReplayedTypingStillSetsThePendingRestoreOverlay_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let painted = LifecycleEntryHarness.Gate()
        defer { painted.open() }
        rig.controller.testNextPaintWait = { await painted.wait() }
        let blocker = try rig.holdQueue()   // the reinsert cannot apply
        defer { rig.release(blocker) }
        rig.quickUndoReplaysTyping = true
        rig.liveDiffersOverride = false

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        #expect(rig.unifiedUndo.redoStack.isEmpty, "premise: the typing ended the redo branch (and forgot the entry's job records)")
        #expect(rig.editorState.pendingReinsertCount > 0, "premise: the reinsert is still pending")
        painted.open()   // the editor has painted: the sidebar update runs now

        let set = await gateWaitUntil({ rig.editorState.pendingRestoreSections[deleted.entry.id] != nil })
        #expect(set, "the pending-restore overlay was not set while the reinsert runs: the restored section's card would be missing")
    }

    // MARK: - F18: nothing is shown while the project is being saved

    // Slow route: the editor refuses (`docChanged`, the typing as the batch) and a close has begun by then (the gate is closed to new
    // work). The refusal is silent: the reply is `cancelled`, no notice, no alert; the typing is kept.
    // Predicted failure with the check dropped (`SW-F18-slow-refusal-notice.patch`): "the refusal showed the notice although a close had begun".
    @Test("F18 (slow route): a refusal while a close has begun shows nothing")
    func testARefusedSlowUndoIsSilentWhenTheProjectIsBeingSaved() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig); rig.editorState.structuralGate.isClosedToNewWork = false }
        let deleted = try await delete(rig, "Section A")
        rig.swapLiveDiffers = true
        rig.swapClickBatch = try typedB(rig)
        rig.onSwapAnswered = { [unowned rig] in rig.editorState.structuralGate.isClosedToNewWork = true }

        _ = await rig.pressAndSettle(deleted.entry); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo cancelled"], "got \(rig.replyWords())")
        #expect(rig.toasts.current?.message != Self.noticeText, "the refusal showed the notice although a close had begun")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        let kept = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(kept, "the typing the refusal handed back did not reach the rows")
    }

    // Quick undo: the same for a quick undo the editor refuses. Predicted failure with the check dropped (`SW-F18-quick-refusal-notice.patch`).
    @Test("F18 (quick undo): a refusal while a close has begun shows nothing")
    func testARefusedQuickUndoIsSilentWhenTheProjectIsBeingSaved_book6() async throws {
        let rig = try makeBookRig()
        defer { rig.editorState.structuralGate.isClosedToNewWork = false }
        let deleted = try await delete(rig)
        rig.quickUndoAnswer = .refuse(reason: "docChanged")
        rig.quickUndoReplyHold = { [unowned rig] in rig.editorState.structuralGate.isClosedToNewWork = true }

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo cancelled"], "got \(rig.replyWords())")
        #expect(rig.toasts.current?.message != Self.noticeText, "the refusal showed the notice although a close had begun")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id, "the refused press moved the entry")
    }

    // MARK: - F13: a failed replay is a refusal, not the old body

    // The page answers `docChanged` with the typing in the batch when a replay fails after the dry run (Swift's `refusalFallsBackToLegacy`
    // must treat it as a refusal): the press is `failed`, the batch is applied, the notice shows, and the OLD body is NOT taken.
    // Predicted failure with `docChanged` made a fallback (`SW-F13-docchanged-falls-back.patch`): "the old body ran for a refusal".
    @Test("F13: a slow-route docChanged that carries the typing is a refusal: failed, batch applied, notice, the old body not taken")
    func testASlowRouteDocChangedWithTheTypingBatchIsARefusalNotAFallback() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapLiveDiffers = true
        rig.swapClickBatch = try typedB(rig)

        _ = await rig.pressAndSettle(deleted.entry); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        #expect(
            rig.scripts(containing: "performStructuralSwap").isEmpty && rig.scripts(containing: "cancelPendingInsertions").isEmpty,
            "the old body ran for a refusal")
        #expect(rig.persistedLog.allSatisfy { !$0.contains("[EF-STRUCT]") }, "a refusal was logged as a fallback: \(rig.persistedLog)")
        let kept = await gateWaitUntil({ (try? self.rowCount(rig, Self.kept)) == 1 })
        #expect(kept, "the typing the refusal handed back did not reach the rows exactly once")
        #expect(rig.toasts.current?.message == Self.noticeText, "got \(String(describing: rig.toasts.current?.message))")
        #expect(try !rig.blocks().contains { $0.textContent == "Section A" }, "the refused undo changed the document")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id, "the entry moved")
    }

    // MARK: - T-a / T-c: the lifecycle's release

    private func closeRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }
        return rig
    }

    // T-a: the page holds the user's typing for a waiting Cmd-Z. A close asks it to release the hold (once) before it drains and polls; the
    // forced poll then finds the typing and the close saves it: it is in the rows EXACTLY ONCE (the poll writes it, the whole-document write
    // after it finds the rows already equal).
    // Predicted failure with the release taken out (`SW-D1-release-removed.patch`): `("0") is not equal to ("1")` on the row count.
    @Test("T-a: a close releases the typing the page held for a waiting Cmd-Z, and the typing is in the rows exactly once")
    func testCloseSavesTheHeldTypingExactlyOnce() async throws {
        let rig = try closeRig()
        rig.heldTypingBatch = try typedB(rig)

        let result = await rig.runLifecycle(.close, bounds: .production)

        #expect(result.outcome == .flushed, "the close did not run to the end: \(result.outcome)")
        #expect(rig.releaseHeldPushesCalls == 1, "the release must be asked for once: \(rig.releaseHeldPushesCalls)")
        #expect(rig.heldTypingBatch == nil, "the held typing was never released")
        #expect(try rowCount(rig, Self.kept) == 1, "the held typing is in the rows \((try? rowCount(rig, Self.kept)) ?? -1) times, not once")
        #expect(try rowCount(rig, "The B body.") == 0, "the old text of the paragraph is still in the rows")
    }

    // T-c: the page does not answer the release in time (a busy or wedged editor). The close does not wait for it: the release is bounded
    // by the forced-poll bound, and the drain and the forced poll still run after it.
    // Predicted failure with the bound taken away (`SW-D1-release-unbounded.patch`): "the close waited for an editor that did not answer".
    @Test("T-c: a page that does not answer the release in time does not hold the close up; the forced poll still runs")
    func testCloseDoesNotWaitForAPageThatNeverAnswersTheRelease() async throws {
        let rig = try closeRig()
        rig.releaseHeldPushesHold = { try? await Task.sleep(for: .seconds(30)) }   // cancelled by the caller's bound
        var bounds = LifecycleBounds.production
        bounds.forcedPoll = 0.3
        let started = ContinuousClock.now

        let result = await rig.runLifecycle(.close, bounds: bounds)

        let elapsed = ContinuousClock.now - started
        #expect(result.outcome == .flushed, "the close did not run to the end: \(result.outcome)")
        #expect(elapsed < .seconds(8), "the close waited for an editor that did not answer the release (\(elapsed))")
        #expect(rig.releaseHeldPushesCalls == 1)
        #expect(rig.flushReportsCalls >= 1, "step F (flushAndAck) did not run after the release timed out")
    }

    // T-b: TA-1's premise. The stand-in editor honours `liveDiffersOverride`: with it false and NO flag, a quick undo keeps the redo branch
    // (so only the flag can end it); with it true and no flag, the old text compare ends it (typing made after the swap).
    // Predicted failure with the override ignored by the stand-in: either assertion flips.
    @Test("T-b: the stand-in honours liveDiffersOverride; the text compare still ends the branch for typing made after the swap")
    func testTheTextCompareStillEndsTheBranchForTypingAfterTheSwap_book6() async throws {
        let keeps = try makeBookRig()
        let first = try await delete(keeps)
        keeps.liveDiffersOverride = false
        #expect(await keeps.pressAndSettle(first.entry)); _ = await keeps.waitUntilSettled()
        #expect(keeps.unifiedUndo.redoStack.last?.id == first.entry.id, "an override of false must keep the redo branch")
        #expect(!keeps.scripts(containing: "quickUndoLiveDiffersFromRestored").isEmpty, "the compare was not asked although no flag came")

        let ends = try makeBookRig()
        let second = try await delete(ends)
        ends.liveDiffersOverride = true
        #expect(await ends.pressAndSettle(second.entry)); _ = await ends.waitUntilSettled()
        #expect(ends.unifiedUndo.redoStack.isEmpty, "typing made after the swap did not end the redo branch")
    }
}
