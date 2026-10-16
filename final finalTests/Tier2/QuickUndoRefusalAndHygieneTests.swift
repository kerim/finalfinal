//
//  QuickUndoRefusalAndHygieneTests.swift
//  final finalTests/Tier2
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b, the code-review round: verdict-code-v1.md section (iii), S2 items for S1-4 ... S1-12): the guards
//  of the review fixes that concern refusals, lifecycle edges and hygiene, each reddened by its own break (swift-break-map.md):
//    - U-Q30 (S1-5, sw57)   a reinsert a drain refused with no lifecycle armed is written through the C5 flush
//    - U-Q32 (S1-4, sw56)   the fresh settle after a refused restore starts with a live read
//    - U-Q33 (S1-6, sw58)   a barrier mid quick undo replies cancelled, pushes the descriptor, shows the notice only on failed
//    - U-Q34 (S1-8, sw60)   the quick repush leaves `isResettingContent` true while a rebuild runs
//    - U-Q35 (S1-9, sw61)   a refused restore keeps the footnote checkpoints
//    - U-Q36 (S1-11, sw62)  a supersede logs through `.undo`, not `alwaysPersisted`
//    - U-Q37 (S1-12, sw63)  the find bar is cleared by the quick undo, the quick redo and the delete click
//  Shared helpers: QuickUndoFixtures.swift; the rig: EditorFirstRig+QuickUndo.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: refusals, lifecycle edges and hygiene (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoRefusalAndHygieneTests: QuickUndoFixtures {

    // MARK: - U-Q30 (S1-5)

    @Test("U-Q30 (G-F6): a reinsert a drain timeout refused, with no lifecycle armed, takes the C5 flush: the section reaches the table")
    func testReinsertRefusedByDrainTimeoutWithNoLifecycleArmedFlushesTheEditor_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let blocker = try rig.holdQueue()   // the reinsert waits behind this
        defer { rig.release(blocker) }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        #expect(rig.editorState.activeLifecycle == nil, "precondition: no lifecycle is armed")
        #expect(try rig.presentRowCount(deleted.subtree) == 0, "precondition: the table still lacks the section")

        // The close that was draining gave up on the reserved sequences and was then cancelled: the reinsert is skipped.
        rig.sync.testWriterHandle?.skipAllReserved(reason: .drainTimeout)
        rig.release(blocker)
        let settled = await rig.waitUntilSettled(iterations: 1200)

        #expect(settled)
        let texts = Set(try rig.blocks().map(\.textContent))
        #expect(
            texts.contains(deleted.root.textContent),
            "expected the database to hold the restored section's rows after the flush, got the post-delete table")
        #expect(rig.controller.efSlots.slot(deleted.entry.id)?.state == .fallback, "the slot fell back")
    }

    // MARK: - U-Q32 (S1-4)

    @Test("U-Q32 (G-F2): after a refused restore the fresh settle starts with a read of the editor's own text")
    func testFreshSettleAfterRefusedRestoreReadsTheEditorsText_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let sentinel = "LIVE-TEXT-OF-U-Q32"
        rig.fetchAnswerProvider = { sentinel }
        let adopted = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .blockSyncDidPushContent, object: nil, queue: .main) { note in
            let text = (note.userInfo?["markdown"] as? String) ?? ""
            MainActor.assumeIsolated { adopted.note(text) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        rig.quickUndoAnswer = .refuse(reason: "docChanged")

        #expect(await rig.pressAndSettle(deleted.entry))

        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        #expect(
            adopted.items.contains(sentinel),
            "expected the footnote and bibliography resync to use the editor's text after a refused restore, got the older content")
    }

    // MARK: - U-Q33 (S1-6)

    private func firstDescriptorIndexAfterRestore(_ rig: EditorFirstRig) -> Int? {
        let events = rig.events.items
        guard let restore = events.lastIndex(where: { $0.contains("undoSectionDeleteEditorFirst") }) else { return nil }
        return events[restore...].firstIndex { $0.contains("setUndoDescriptor") }
    }

    @Test("U-Q33 (G-F4): a barrier that lands between the restore and the stack move replies cancelled, pushes the descriptor, shows no notice")
    func testBarrierMidQuickUndoRepliesCancelledAndPushesDescriptor_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        defer { rig.editorState.structuralGate.isClosedToNewWork = false }
        rig.controller.testQuickUndoResumeHold = { [weak rig] in
            rig?.editorState.structuralGate.isClosedToNewWork = true   // a close, quit or project switch has begun
            rig?.unifiedUndo.invalidateAll(reason: "a barrier mid quick undo")
        }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))

        #expect(
            rig.replyWords() == ["undo cancelled"],
            "expected the reply .cancelled when the structural gate is closed to new work, got \(rig.replyWords())")
        #expect(firstDescriptorIndexAfterRestore(rig) != nil, "the Edit menu is told: the descriptor was pushed after the restore")
        #expect(rig.toasts.current?.message != ToastFactory.undoQueueDropped().message, "a barrier is not a refusal: no notice")
        _ = await rig.waitUntilSettled()
    }

    @Test("U-Q33 (second case): the timeline changed with the gate open is a refusal: reply failed, the notice, the descriptor pushed")
    func testTimelineChangeMidQuickUndoWithTheGateOpenRepliesFailedWithNotice_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.controller.testQuickUndoResumeHold = { [weak rig] in rig?.unifiedUndo.invalidateAll(reason: "a barrier mid quick undo") }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))

        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        #expect(firstDescriptorIndexAfterRestore(rig) != nil, "the descriptor was pushed after the restore")
        #expect(rig.toasts.current?.message == ToastFactory.undoQueueDropped().message, "the notice is shown for a real refusal")
        _ = await rig.waitUntilSettled()
    }

    // MARK: - U-Q34 (S1-8)

    @Test("U-Q34 (C-L1): the quick repush leaves isResettingContent true while a rebuild runs, and clears it when none does")
    func testQuickRepushLeavesResettingContentWhileARebuildRuns_book6() async throws {
        let rig = try makeBookRig()
        rig.editorState.isResettingContent = false
        await rig.controller.quickRepushManagedRegions(editorState: rig.editorState)
        #expect(!rig.editorState.isResettingContent, "with no rebuild running the push clears the flag it set")

        let rebuildMayEnd = LifecycleEntryHarness.Gate()
        defer { rebuildMayEnd.open() }
        rig.editorState.registerRebuildTask(Task { @MainActor in await rebuildMayEnd.wait() })
        #expect(!rig.editorState.runningRebuildTasks.isEmpty, "precondition: a rebuild is running")

        await rig.controller.quickRepushManagedRegions(editorState: rig.editorState)

        #expect(
            rig.editorState.isResettingContent,
            "expected isResettingContent true while a rebuild started during the quick repush is still running, got false")
        rebuildMayEnd.open()
        rig.editorState.isResettingContent = false
    }

    // MARK: - U-Q35 (S1-9)

    private func checkpoint() -> FootnoteUndoCheckpoint {
        FootnoteUndoCheckpoint(
            bodyBefore: "Text [^1] and [^2].", refsBefore: ["1", "2"], deletedDefinitions: ["2": "Second note"], appliedRenameMap: [:])
    }

    @Test("U-Q35 (C-L3): the checkpoints a delete's resync recorded survive a REFUSED quick undo and go when the restore really happened")
    func testRefusedQuickUndoKeepsTheFootnoteCheckpoints_book6() async throws {
        let refused = try makeBookRig()
        let deletedOne = try await delete(refused)
        refused.footnotes.undoCheckpoints.append(checkpoint())   // recorded after the click: the delete's own resync write
        refused.quickUndoAnswer = .refuse(reason: "docChanged")

        #expect(await refused.pressAndSettle(deletedOne.entry))

        #expect(
            refused.footnotes.undoCheckpoints.count == 1,
            "expected the footnote undo checkpoints recorded since the delete to survive a refused quick undo, got none")

        let performed = try makeBookRig()
        let deletedTwo = try await delete(performed)
        performed.footnotes.undoCheckpoints.append(checkpoint())

        #expect(await performed.pressAndSettle(deletedTwo.entry))

        #expect(performed.footnotes.undoCheckpoints.isEmpty, "a quick undo that restored the section drops them")
    }

    // MARK: - U-Q36 (S1-11)

    @Test("U-Q36 (G-F8): a bibliography resync superseded by a quick undo is logged through .undo, not written to the persisted log")
    func testSupersededBibliographyResyncLogsThroughUndoNotAlwaysPersisted() async throws {
        let rig = try EditorFirstRig(markdown: "# Chapter\n\nThe chapter body.")
        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        await rig.bibliography.resyncNow(citekeys: [], projectId: rig.pid, stillWanted: { false })

        let persisted = capture.captured.filter { $0.contains("[BibliographySyncService] resyncNow") }
        #expect(
            persisted.isEmpty,
            "expected the supersede line in the .undo category and nothing from this resync in the persisted log, got it persisted: \(persisted)")
        #expect(rig.bibliography.state == .idle)
    }

    // MARK: - U-Q37 (S1-12)

    @Test("U-Q37 (B-M2): the delete click, the quick undo and the quick redo each clear the find bar's search")
    func testQuickUndoRedoAndTheDeleteClickClearTheFindBar_book6() async throws {
        let rig = try makeBookRig()
        func armSearch() {
            rig.findBar.searchQuery = "needle"
            rig.findBar.totalMatches = 3
        }
        armSearch()
        let deleted = try await delete(rig)
        let afterClick = rig.findBar.searchQuery.isEmpty && rig.findBar.totalMatches == 0

        armSearch()
        #expect(await rig.pressAndSettle(deleted.entry))
        let afterUndo = rig.findBar.searchQuery.isEmpty && rig.findBar.totalMatches == 0

        armSearch()
        #expect(await rig.pressAndSettle(deleted.entry, .redo))
        let afterRedo = rig.findBar.searchQuery.isEmpty && rig.findBar.totalMatches == 0

        let cleared = "the click (\(afterClick)), the quick undo (\(afterUndo)) and the quick redo (\(afterRedo))"
        #expect(afterClick && afterUndo && afterRedo, "expected the find bar's search to be cleared by \(cleared)")
    }
}
