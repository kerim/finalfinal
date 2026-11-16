//
//  StructuralUndoController+QuickUndo.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (plan-v1 C2, plan-v2-addendum 2-4, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 3): Cmd-Z and
//  Cmd-Shift-Z of an editor-first Delete Section that put the section back on the screen, and take it off again, AT ONCE. The
//  editor does the whole visible change in one JavaScript turn (`undoSectionDeleteEditorFirst`, `redoSectionDeleteEditorFirst`, a few
//  milliseconds); the database follows through the ordered write queue (`SectionReinsertJob`, then a normal `SectionDeleteJob`).
//
//  WHERE IT RUNS. `resolveOutcome` (StructuralUndoController.swift) asks `resolveQuickPath` first, INSIDE the structural gate: undo
//  and redo take the gate without the rebuild wait, the quick path waits for nothing, and anything that is not eligible returns nil
//  and takes today's path after it has waited for the running rebuilds. Eligibility is decided from fresh state after the gate is
//  granted and after a running backup/export flush has ended (the press is held, never refused).
//
//  THE QUICK UNDO, in order (`performQuickUndoOfDelete`):
//   1. ONE synchronous main-actor stretch, before the first suspension: the entry's epoch and the restore generation go up and the
//      pending-reinsert count goes up (a settle or rebuild that already started will find itself superseded), the footnote and
//      bibliography debounces are cancelled, the footnote undo checkpoints recorded since the click are dropped and a hold is put on
//      new ones, an unsettled marker is registered under the reinsert's fresh key (so a flush that starts later waits for the
//      reinsert), writer ticket N' is reserved and the restore's JavaScript is handed to the web view. Reservation order = submission
//      order = JavaScript execution order.
//   2. The reply: `ok:false` (the live document no longer matches the saved copy, the editor refused) changes nothing on the screen:
//      the counters and the marker are put back, the press is answered `failed` with the existing notice, one fresh settle puts back
//      the follow-up steps the epoch bump skipped (and one merge-guarded push, so a rebuild whose push the bump skipped cannot leave
//      the Notes half updated). `ok:true`: the batch the call consumed is applied (it always is), the sidebar shows the section.
//   3. The reinsert is reserved (`SectionReinsertJob`); once it holds its place the slot is `quickUndone`, and ONLY THEN is
//      block-sync let queue typing again (`resumeSyncAfterQuickUndo`: whatever was typed while it was paused is detected there and
//      queued behind the reinsert's ticket). Then the timeline's stack move, the descriptor push, the reply `performed`.
//   4. Behind the reply, `reinsertSettled` makes the derived content right (resyncs, section and annotation sync, the A20 push).
//  Every path replies exactly once (the caller sends the reply the body returns); the editor's resume call runs on every exit that
//  sent the restore.
//
//  THE QUICK REDO (`performQuickRedoOfDelete`) is a fresh editor-first delete of the CURRENT document under the same operation id
//  (`redoSectionDeleteEditorFirst`), its delete job queued behind the reinsert in ticket order, its snapshot written through the
//  slot's `recordApplied` (which unpins the one it replaces). A quick-undone entry is NEVER sent to the slow redo (`performRedo`).
//

import SwiftUI
import GRDB

/// The JavaScript reply of `undoSectionDeleteEditorFirst` (web/milkdown/src/api-section-undo.ts, web-api-published.md section 1).
struct QuickUndoReply: EditorFirstBatchReply {
    /// Present on EVERY path and ALWAYS applied: the pending changes the call consumed.
    let batch: BlockChanges
    let succeeded: Bool
    let reason: String?
    /// The ids of the blocks that came back, in document order, as the editor holds them now.
    let restoredIds: [String]
    /// The headings and section breaks among them: what the sidebar shows again.
    let restoredLeaderIds: [String]
    /// The section leaders the undo took OUT of the document (t-18b7fa48): empty for the undo of a delete (a delete only removes), the
    /// copy's leaders for the undo of a duplicate, which the sidebar hides at once. Absent in a reply from an older editor.
    let removedLeaderIds: [String]?
    /// t-d2061b27: `true` when the typing done while the press waited was put back on top of the restored document. Then `batch` is empty
    /// (the replay is the only carrier of that typing; `resumeSyncAfterQuickUndo` queues it behind the reinsert) and Swift ends the redo
    /// branch (`endRedoAfterReplayedTyping`). Absent otherwise, and from a reply of an older editor.
    let typingReplayed: Bool?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case restoredIds
        case restoredLeaderIds
        case removedLeaderIds
        case typingReplayed
    }
}

extension StructuralEntry {
    /// What an editor-first entry's operation is called in the quick undo's diagnostic log ("... not in the pre-<label> document").
    var operationLabel: String {
        switch kind {
        case .sectionDuplicate: return "duplicate"
        case .restoreProject, .restoreSectionReplace, .restoreSectionDuplicate: return "restore"
        default: return "delete"
        }
    }
}

extension StructuralUndoController {

    // MARK: - Bookkeeping

    /// Bumps the entry's epoch (plan-v2-addendum 2.2) and returns the new value.
    @discardableResult
    func bumpEpoch(_ opId: UUID) -> Int {
        let next = (efOpEpoch[opId] ?? 0) + 1
        efOpEpoch[opId] = next
        return next
    }

    /// What a discard of the entry (`discardEditorFirstEntry`, the D6 put-back, a failed click) removes besides the slot: the holder (a
    /// reinsert that is already reserved keeps its own reference and still applies), the latest-job key, the structural generation, the
    /// settle task, and the registry records of the fresh keys. NOT the epoch (a settle that is still running must find its own epoch
    /// unchanged by a discard) and NOT the sidebar overlay (the reinsert's settle clears it when the rows are back).
    func forgetQuickUndoState(_ opId: UUID) {
        efHolders[opId] = nil
        efLatestJobKey[opId] = nil
        efRecordedStructGeneration[opId] = nil
        efSettleTasks[opId] = nil
        efDuplicateCopies[opId] = nil   // t-18b7fa48: a duplicate entry's copies
        efRestorePlans[opId] = nil   // t-18b7fa48 round 2d-i: a restore entry's plan
        efSnapshotJobKeys[opId] = nil   // t-18b7fa48 round 3c: the latest slow undo or redo job's key
        efEditorKind[opId] = nil   // t-4a8fd8af round 7a: a Markdown entry's kind (only press-time routing reads it; no job or settle does)
        if let keys = efJobKeys.removeValue(forKey: opId) {
            for key in keys { editorState?.efJobRegistry.forget(key) }
        }
    }

    // MARK: - Eligibility (plan-v1 C4 as amended by plan-v3-addendum A1)

    /// Whether Cmd-Z of this editor-first delete may put the section back on the screen at once: in the editor it was made in (Rich
    /// Text unless `efEditorKind` says Markdown, t-4a8fd8af round 7a), not zoomed; the entry's
    /// slot and payload holder exist and the delete job has not failed; the slot is `reserved` or `applied` (the entry is on the undo
    /// stack); and no STRUCTURAL out-of-queue write (the old whole-document duplicate, restore or reorder -- in Markdown mode a
    /// Duplicate, a reorder or (since t-4a8fd8af slice 4) a restore takes it only when the kill switch is off or the page refused, and a
    /// restore also when its target or version cannot go through the editor-first path --, zoomed and fallbacks, or the old slow undo
    /// or redo) has touched the project since the entry was recorded. An editor-first duplicate,
    /// restore or reorder is a queued system write and does not count (t-0b70d1e9: a drag after a delete leaves the delete quick
    /// undoable). The idle backup, Save Version and export do not count either: the reinsert makes the
    /// rows equal the saved pre-delete rows whatever they wrote. NOT `outOfQueueWriteGeneration`. A reorder entry itself has no quick
    /// undo (`quickPathPossible` refuses the kind).
    func quickUndoEligible(_ entry: StructuralEntry) -> Bool {
        quickPathPossible(entry, redo: false)
    }

    /// The same for Cmd-Shift-Z: the slot is `quickUndone` or `reinserted` (the entry is on the redo stack and was undone the quick way).
    func quickRedoEligible(_ entry: StructuralEntry) -> Bool {
        quickPathPossible(entry, redo: true)
    }

    private func quickPathPossible(_ entry: StructuralEntry, redo: Bool) -> Bool {
        // A reorder (t-0b70d1e9) has no quick undo or redo: it deletes and inserts nothing, so there is nothing for a reinsert to put
        // back. Its undo and redo are the queued slow ones, from the snapshot its job wrote (the slot's). Checked first, redo included.
        guard entry.kind != .sectionReorder else { return false }
        guard entry.isEditorFirst, let editorState else { return false }
        guard editorState.editorMode == (efEditorKind[entry.id]?.mode ?? .wysiwyg), editorState.zoomedSectionId == nil else { return false }
        guard let slot = efSlots.slot(entry.id), let holder = efHolders[entry.id], holder.outcome != .failed else { return false }
        guard efRecordedStructGeneration[entry.id] == editorState.structuralOutOfQueueGeneration else { return false }
        switch (redo, slot.state) {
        case (false, .reserved), (false, .applied), (true, .quickUndone), (true, .reinserted): return true
        default: return false
        }
    }

    /// Called by `resolveOutcome`, inside the gate. Returns the reply when the press ran the quick way, nil when it must take the slow
    /// path. A running `flushLiveContentToDatabase` (the idle backup, Save Version, export) is waited for FIRST (verdict-v3 T1: it
    /// writes the post-delete screen into the table outside the queue and pushes the matching ids into the editor, so a restore must
    /// not run inside it), and eligibility is read after that wait.
    func resolveQuickPath(opId: UUID, direction: UndoDirection) async -> UndoResult? {
        guard let editorState, let unifiedUndoService, !efPutBackOpIds.contains(opId) else { return nil }
        let redo = direction == .redo
        func top() -> StructuralEntry? { redo ? unifiedUndoService.redoStack.last : unifiedUndoService.undoStack.last }
        guard let entry = top(), entry.id == opId, quickPathPossible(entry, redo: redo) else { return nil }
        await editorState.awaitRunningLiveFlush()
        guard let fresh = top(), fresh.id == opId, quickPathPossible(fresh, redo: redo) else { return nil }
        // A Markdown entry (t-4a8fd8af round 7a): its quick undo and redo live in StructuralUndoController+MarkdownQuickUndo.swift.
        if efEditorKind[opId] == .markdown { return await resolveMarkdownQuickPath(fresh, redo: redo) }
        // The redo branches by the entry's kind (t-18b7fa48): a duplicate's redo is a fresh editor-first duplicate with the first
        // click's copy ids; a delete's is a fresh editor-first delete. Every editor-first entry, of either kind, can take the quick
        // path and meets the slow-undo test seams below [S13].
        if redo {
            if fresh.kind == .sectionDuplicate { return await performQuickRedoOfDuplicate(fresh) }
            if fresh.isVersionRestore { return await performQuickRedoOfRestore(fresh) }
            return await performQuickRedoOfDelete(fresh)
        }
        #if DEBUG
        if testForceSlowDeleteUndo { return nil }
        #endif
        if TestMode.consumeSlowDeleteUndoSeam() {
            DebugLog.log(.undo, "[StructuralUndoController] quick undo of \(opId): forced slow by FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N")
            return nil
        }
        return await performQuickUndoOfDelete(fresh)
    }

    // MARK: - The quick undo

    /// What the quick undo must still do on its way out, whichever way it goes (the plan's `defer`: an `await` cannot sit in a `defer`).
    struct QuickUndoRun {
        /// The restore's JavaScript was (or may have been) sent: the editor's block-sync may be paused and must be resumed.
        var jsSent = false
        var resumed = false
    }

    func performQuickUndoOfDelete(_ entry: StructuralEntry) async -> UndoResult {
        guard let editorState, let blockSync = blockSyncService, let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId, let holder = efHolders[entry.id] else { return .failed }
        let trace = StructTrace(label: "undo", opId: String(entry.id.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "undo", opId: trace.opId)   // slice 0 measurement: the shared timeline
        trace.log("start (quick)")
        // UI-test seam FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS (see TestMode): the quick undo is one synchronous stretch and waits for nothing,
        // so the page's latch lasts a few milliseconds and a UI test cannot type into its wait. The hold stands for that wait. Before
        // anything is mutated (the click flag, the epoch, the counters, the registry, the writer ticket). No wait when unset.
        await TestMode.holdSlowUndoPress(opId: trace.opId)
        var run = QuickUndoRun()
        defer { blockSync.structuralClickPending = false }
        let result = await quickUndoBody(entry, holder: holder, database: db, projectId: pid, trace: trace, run: &run)
        if run.jsSent, !run.resumed { await resumeAfterQuickUndo(trace: trace) }
        return result
    }

    private func quickUndoBody( // swiftlint:disable:this function_parameter_count
        _ entry: StructuralEntry, holder: SectionDeletePayloadHolder, database db: ProjectDatabase, projectId pid: String,
        trace: StructTrace, run: inout QuickUndoRun
    ) async -> UndoResult {
        guard let editorState, let blockSync = blockSyncService, let unifiedUndoService,
              let opLiteral = Self.jsLiteral(entry.id.uuidString) else { return .failed }
        let opId = entry.id
        let registry = editorState.efJobRegistry
        let timelineEpoch = unifiedUndoService.generation
        let script = "JSON.stringify(window.FinalFinal.undoSectionDeleteEditorFirst(\(opLiteral)))"

        // 1. THE ONE SYNCHRONOUS STRETCH. Nothing below suspends until `submitEditorFirstDelete` hands the script to the web view
        // (reserve N' and evaluate are one stretch there too), so the order is: epoch, counters, cancels, marker, ticket, script.
        blockSync.structuralClickPending = true   // the editor's reports park (the click path does the same)
        findBarState?.clearSearch()   // code review B-M2: the boundary hygiene every slow structural path does (the JS side does its own)
        let epoch = bumpEpoch(opId)
        editorState.editorRestoreGeneration += 1
        editorState.pendingReinsertCount += 1
        footnoteSyncService?.cancelPendingDebounce()
        bibliographySyncService?.cancelPendingDebounce()
        let reinsertKey = UUID()
        footnoteSyncService?.holdUndoCheckpoints(token: reinsertKey)
        holder.setCheckpointHoldToken(reinsertKey)
        registry.register(reinsertKey)   // verdict-v3 T1c: a flush that starts from here on waits for the reinsert's settle
        efJobKeys[opId, default: []].append(reinsertKey)
        run.jsSent = true
        let submission = await blockSync.submitEditorFirstDelete(database: db, projectId: pid, script: script)

        // 2. The reply.
        guard let submission else {
            DebugLog.log(.undo, "[StructuralUndoController] quick undo: no writer turn available -- refused")
            return await abandonQuickUndo(opId: opId, reinsertKey: reinsertKey, holder: holder, reason: "noWriterTurn", trace: trace)
        }
        spy("quickUndoJS")
        guard let reply = consumeEditorFirstReply(
            submission, as: QuickUndoReply.self, blockSync: blockSync, database: db, projectId: pid
        ) else {
            return await abandonQuickUndo(opId: opId, reinsertKey: reinsertKey, holder: holder, reason: "unreadableReply", trace: trace)
        }
        guard reply.succeeded else {
            return await abandonQuickUndo(
                opId: opId, reinsertKey: reinsertKey, holder: holder, reason: reply.reason ?? "refused", trace: trace)
        }
        trace.log("quick restore done restored=\(reply.restoredIds.count) leaders=\(reply.restoredLeaderIds.count)")
        // Code review C-L3: the checkpoints recorded since the click go only once the restore has really happened (a refused restore
        // keeps them); the hold taken in the stretch already stops new ones.
        footnoteSyncService?.dropUndoCheckpoints(notIn: holder.snapshot().footnoteCheckpointMarker)
        forgetCommittedDerivedState()   // the restore brings the deleted footnotes and citations back: the resync's committed state is stale
        StructuralTrace.log("quick-undo lap: undo checkpoints dropped")   // laps: where the time between the restore and the reinsert goes
        let sidebarUpdate: Task<Void, Never>?
        if entry.kind == .sectionDuplicate {
            // The undo of a duplicate restores no section: it takes the copy out. Its leaders leave the sidebar at once.
            hideDuplicateInSidebar(opId: opId, removedLeaderIds: Set(reply.removedLeaderIds ?? []), holder: holder)
            sidebarUpdate = nil
        } else if entry.isVersionRestore {
            // The undo of a restore swaps the two documents: the restored outline leaves and the previous one comes back, at once
            // (t-18b7fa48 rounds 2d-i and 2d-ii). Both outlines are the plan's: a whole restore replaced the whole document, so "the
            // leaders the swap took out" is every leader of the restored document; a section replace swaps the leaders of the range;
            // a restore as duplicate takes out only its own leaders (the plan's, cut down to the ones the editor reports: A5).
            swapSidebarForQuickUndoOfRestore(opId: opId, holder: holder, editorRemovedLeaderIds: Set(reply.removedLeaderIds ?? []))
            sidebarUpdate = nil
        } else {
            sidebarUpdate = showRestoredSections(
                opId: opId, reinsertKey: reinsertKey, epoch: epoch, holder: holder,
                restoredLeaderIds: Set(reply.restoredLeaderIds), database: db)
        }
        StructuralTrace.log("quick-undo lap: showRestoredSections returned")
        // A13: the section sync's tracking belongs to the post-delete document.
        sectionSyncService?.cancelPendingSync()
        sectionSyncService?.resetSyncTracking()
        StructuralTrace.log("quick-undo lap: section sync reset")
        spy("quickUndoRestoreApplied")
        #if DEBUG
        await testQuickUndoAfterRestore?()
        #endif

        // 3. The reinsert, then the resume (only once the reinsert holds its place in the queue).
        await TestMode.holdQuickUndoResume(opId: trace.opId)   // UI-test seam, before the reinsert starts (see TestMode); no wait when off
        let reserved = startReinsert(
            opId: opId, reinsertKey: reinsertKey, epoch: epoch, holder: holder, database: db, projectId: pid,
            sidebarUpdate: sidebarUpdate, operationLabel: entry.operationLabel)
        StructuralTrace.log("quick-undo lap: reinsert task started")
        await reserved.wait()
        StructuralTrace.log("quick-undo lap: reinsert reservation wait returned (didReserve=\(reserved.didReserve))")
        guard reserved.didReserve else {
            // The reinsert could not be reserved (no writer, another project, the lifecycle barrier): its own settle writes the
            // editor's content to the database (C5) or leaves it to the closing save. The press is not carried out: no stack move.
            DebugLog.alwaysPersisted("[StructuralUndoController] quick undo \(opId): the reinsert could not be reserved")
            return editorState.structuralGate.isClosedToNewWork ? .cancelled : .failed
        }
        efSlots.markQuickUndone(opId)
        trace.log("reinsert reserved")
        spy("quickUndoReinsertReserved")
        #if DEBUG
        await testQuickUndoResumeHold?()
        #endif
        run.resumed = true
        await resumeAfterQuickUndo(trace: trace)
        spy("quickUndoResumed")

        // 4. The timeline and the reply.
        guard unifiedUndoService.generation == timelineEpoch, case .performed = unifiedUndoService.performUndo(opId: opId) else {
            // Code review G-F4/C-L4: a barrier (zoom, mode switch, project switch, hierarchy enforcement) landed between the restore and
            // the stack move. The Edit menu must stop saying "Undo Delete Section" for a section that is on the screen, and a barrier
            // is not a refusal: `.cancelled` when the gate is closed to new work, the notice only for a real `.failed`.
            let closed = editorState.structuralGate.isClosedToNewWork
            DebugLog.log(
                .undo, "[StructuralUndoController] quick undo \(opId): the timeline changed mid-sequence -- the section is back on the "
                + "screen and the reinsert is queued; reporting \(closed ? ".cancelled" : ".failed")")
            await pushDescriptor()
            if !closed { showUndoQueueDroppedWarning() }
            return closed ? .cancelled : .failed
        }
        await pushDescriptor()
        // t-d2061b27: typing done while the press WAITED was put back on top of the restored document by the page (`typingReplayed`). It
        // ends the redo branch by that flag, not by the text compare below: a replay that changes only text the compare ignores (a
        // bibliography entry, other derived content) would leave the redo standing. The page query is then not needed.
        // Code review G-F5/C-L10/B-L2: while this command held the gate `handleHistoryEdited` ignored every keystroke and the editor
        // posts `historyEdited` only once the descriptor shows a redo, so typing during the paused window never dropped the redo
        // branch. A live document that differs from the restored one (typed during the window: the paused edits are part of that) drops
        // it now; typing from here on follows the normal `historyEdited` path. (`pausedEdits > 0` implies this difference.)
        // (Ended by the flag: nothing typed later can be missed either, the branch is already gone.)
        let endedByReplay = await endRedoAfterReplayedTyping(reply.typingReplayed, opId: opId, trace: trace)
        if !endedByReplay, await evalBool("window.FinalFinal.quickUndoLiveDiffersFromRestored?.(\(opLiteral)) === true") {
            unifiedUndoService.invalidateRedoBranch(reason: "typed during the quick undo")
            await pushDescriptor()
        }
        spy("quickUndoPerformed")
        trace.log("performed")
        return .performed
    }

    /// The restore was refused (or its reply was lost): nothing changed on the screen. Puts back what the first stretch did, tells the
    /// user the press was not carried out (the existing notice: a command either does what it says or says why not), and starts the
    /// one fresh settle that restores the follow-up steps the epoch bump made a settle skip.
    func abandonQuickUndo(
        opId: UUID, reinsertKey: UUID, holder: SectionDeletePayloadHolder, reason: String, trace: StructTrace
    ) async -> UndoResult {
        guard let editorState else { return .failed }
        trace.log("refused (quick) reason=\(reason)")
        editorState.pendingReinsertCount = max(0, editorState.pendingReinsertCount - 1)
        footnoteSyncService?.releaseUndoCheckpointHold(token: reinsertKey)
        holder.setCheckpointHoldToken(nil)
        editorState.efJobRegistry.forget(reinsertKey)
        editorState.efJobRegistry.markSettled(reinsertKey)
        // Review F18 (UX contract 4.2: a press made while the project is being saved shows nothing): with the gate closed to new work
        // (a close, quit or switch has begun) the refusal is silent and the reply is `.cancelled`, as the stack-move exits answer a barrier.
        let closed = editorState.structuralGate.isClosedToNewWork
        if !closed { showUndoQueueDroppedWarning() }
        startFreshSettleAfterRefusedRestore(opId: opId)
        return closed ? .cancelled : .failed
    }

    /// `window.FinalFinal.resumeSyncAfterQuickUndo()`: ends the editor's pause and queues what was typed while it lasted (idempotent and
    /// harmless when no quick undo is waiting), then lets the editor's reports through again.
    private func resumeAfterQuickUndo(trace: StructTrace) async {
        await evalVoid("window.FinalFinal.resumeSyncAfterQuickUndo()")
        blockSyncService?.structuralClickPending = false
        trace.log("resumed")
    }

    // MARK: - The reinsert job

    /// Reserves the reinsert behind everything reserved so far (the click's batch N, the delete job, the restore's N') and spawns it.
    /// The returned signal fires when the job holds its place (`didReserve` true) or when it came back without reserving. The task
    /// that runs the job also runs everything after it (`reinsertSettled`) and is what the unsettled marker `reinsertKey` stands for.
    func startReinsert( // swiftlint:disable:this function_parameter_count
        opId: UUID, reinsertKey: UUID, epoch: Int, holder: SectionDeletePayloadHolder, database: ProjectDatabase, projectId: String,
        sidebarUpdate: Task<Void, Never>?, operationLabel: String, editorKind: EditorFirstEditorKind = .wysiwyg
    ) -> EFReservationSignal {
        let reserved = EFReservationSignal()
        guard let editorState, let blockSync = blockSyncService else {
            self.editorState?.pendingReinsertCount = max(0, (self.editorState?.pendingReinsertCount ?? 0) - 1)
            self.editorState?.efJobRegistry.forget(reinsertKey)
            self.editorState?.efJobRegistry.markSettled(reinsertKey)
            reserved.fire()
            return reserved
        }
        let registry = editorState.efJobRegistry
        var heldJob = SectionReinsertJob(opId: opId, projectId: projectId, holder: holder, slots: efSlots)
        heldJob.operationLabel = operationLabel   // "delete" or "duplicate": the wording of the job's diagnostic log
        #if DEBUG
        heldJob.bodyHold = testReinsertBodyHold
        #endif
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let trace = StructTrace(label: "reinsert", opId: String(opId.uuidString.prefix(8)))
        Task { @MainActor [weak self, weak weakBlockSync = blockSync, weak weakEditorState = editorState] in
            // The reinsert AND the work after it are over on every way out of here (the lifecycle's wait, the flushes, zoom, the mode
            // switch all wait for the marker).
            defer { registry.markSettled(reinsertKey) }
            guard let blockSync = weakBlockSync else {
                reserved.fire()
                registry.resolve(reinsertKey, .abandoned)
                self?.notifyMarkdownJobEnded(key: reinsertKey, outcome: .abandoned)
                weakEditorState?.pendingReinsertCount = max(0, (weakEditorState?.pendingReinsertCount ?? 0) - 1)
                return
            }
            let result = await job.perform(
                on: blockSync, identity: identity, registry: registry, key: reinsertKey,
                onReserved: { reserved.fireReserved() })
            reserved.fire()   // `perform` returned without reserving (refused before step 4): never leave the press waiting
            self?.notifyMarkdownJobEnded(key: reinsertKey, outcome: JobOutcome(result.outcome))   // a Markdown quick undo's hold continuation
            // The job's future has resolved: a rebuild that reads the database from here on reads the restored rows.
            weakEditorState?.pendingReinsertCount = max(0, (weakEditorState?.pendingReinsertCount ?? 0) - 1)
            // The sidebar update (it waits for the editor's paint) ends before the settle starts: the settle clears the overlay the
            // update sets, and this task is what the reinsert's unsettled marker stands for, so a close or a quit waits for both.
            await sidebarUpdate?.value
            await self?.reinsertSettled(
                opId: opId, key: reinsertKey, epoch: epoch, holder: holder, result: result, trace: trace, editorKind: editorKind)
        }
        return reserved
    }

    // MARK: - The quick redo

    func performQuickRedoOfDelete(_ entry: StructuralEntry) async -> UndoResult {
        guard let editorState, let blockSync = blockSyncService, let unifiedUndoService, let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId, let holder = efHolders[entry.id] else { return .failed }
        let opId = entry.id
        let trace = StructTrace(label: "redo", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "redo", opId: trace.opId)   // slice 0 measurement: the shared timeline
        trace.log("start (quick)")
        let timelineEpoch = unifiedUndoService.generation
        guard let built = editorFirstScript(
            function: "redoSectionDeleteEditorFirst", opId: opId, rootId: holder.rootId, database: db, projectId: pid
        ) else {
            return await abandonQuickRedo(opId: opId, reason: "managedIdsUnreadable", trace: trace, changedEpoch: false)
        }

        // THE ONE SYNCHRONOUS STRETCH (verdict-v3 D1, the same shape as the undo's): epoch and generation up, the debounces cancelled,
        // the redo job's unsettled marker registered under its fresh key (code review C-M3: a flush that starts from here on waits for
        // the redo's job and its settle, as it does for the undo's reinsert), ticket N'' reserved and the JavaScript handed to the web
        // view.
        blockSync.structuralClickPending = true
        defer { blockSync.structuralClickPending = false }
        findBarState?.clearSearch()   // code review B-M2: the boundary hygiene every slow structural path does
        bumpEpoch(opId)
        editorState.editorRestoreGeneration += 1
        // Round 1g-B, review A3: the rebuild stamp moves the click's way (see `performQuickRedoOfDuplicate`). A rebuild that stamps after
        // the redo's reply and reads a table that still holds the section (the redo's delete job has not committed) must not push
        // that table over the editor, which no longer shows the section. The job takes the count over (`ownsPendingJobCount`); the
        // exits below that reserve no job bring it down in `abandonQuickRedo`.
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        footnoteSyncService?.cancelPendingDebounce()
        bibliographySyncService?.cancelPendingDebounce()
        let redoKey = UUID()
        editorState.efJobRegistry.register(redoKey)
        efJobKeys[opId, default: []].append(redoKey)
        let submission = await blockSync.submitEditorFirstDelete(database: db, projectId: pid, script: built.script)

        guard let submission else {
            return await abandonQuickRedo(opId: opId, redoKey: redoKey, reason: "noWriterTurn", trace: trace, changedEpoch: true)
        }
        spy("quickRedoJS")
        guard let reply = consumeEditorFirstReply(
            submission, as: EditorFirstDeleteReply.self, blockSync: blockSync, database: db, projectId: pid
        ) else {
            return await abandonQuickRedo(opId: opId, redoKey: redoKey, reason: "unreadableReply", trace: trace, changedEpoch: true)
        }
        guard reply.succeeded else {
            return await abandonQuickRedo(
                opId: opId, redoKey: redoKey, reason: reply.reason ?? "refused", trace: trace, changedEpoch: true)
        }
        // Code review C-M3: the footnote checkpoint hold of the undo ends only now that the redo has really happened: a refused redo
        // leaves the reinsert pending, and a write that was scheduled before the undo must still record no checkpoint.
        if let token = holder.takeCheckpointHoldToken() { footnoteSyncService?.releaseUndoCheckpointHold(token: token) }
        forgetCommittedDerivedState()   // a redo pressed before the reinsert applied: the redo's resync must not be skipped as done
        trace.log("quick removal done removed=\(reply.removedIds?.count ?? 0) leaders=\(reply.removedLeaderIds?.count ?? 0)")

        // What the user sees: the leaders leave the sidebar and the outline results at once (the click's own steps).
        let removedLeaders = Set(reply.removedLeaderIds ?? [])
        editorState.pendingRemovalIds.formUnion(removedLeaders)
        editorState.pendingRestoreSections[opId] = nil
        var visibleSections = editorState.sections
        visibleSections.removeAll { removedLeaders.contains($0.id) }
        editorState.sections = visibleSections
        editorState.recalculateParentRelationships()
        sectionSyncService?.cancelPendingSync()
        sectionSyncService?.resetSyncTracking()

        // The new delete job goes behind every ticket reserved so far, a pending reinsert included (ticket order is what makes the
        // reinsert read the first job's rows and the new job write fresh ones). A fresh registry key: the first job's record resolved
        // long ago, and `register` hands back the record already there for a repeated id.
        efSlots.markReserved(opId)
        let reservedForReal = await startEditorFirstJob(
            opId: opId, rootId: holder.rootId, removedLeaders: removedLeaders, editorRemovedIds: reply.removedIds,
            database: db, projectId: pid, jobKey: redoKey, ownsPendingJobCount: true)
        blockSync.structuralClickPending = false   // as the click does, once the job holds its place
        trace.log("delete job reserved")
        spy("quickRedoJobReserved")
        if !reservedForReal {
            // The new job's own settle runs the D6 put-back (the section is put back from the database and the entry is dropped).
            DebugLog.alwaysPersisted("[StructuralUndoController] quick redo \(opId): the delete job could not be reserved")
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration

        guard unifiedUndoService.generation == timelineEpoch, case .performed = unifiedUndoService.performRedo(opId: opId) else {
            DebugLog.log(
                .undo, "[StructuralUndoController] quick redo \(opId): the timeline changed mid-sequence -- the section is off the "
                + "screen and its delete is queued; reporting .failed")
            return .failed
        }
        await pushDescriptor()
        // t-d2061b27 (review F4, parity with Markdown; round 6): typing done in the redo's wait ends the older redo entries too, and the
        // page says whether the user typed (`typed`), not the batch (see `performQuickRedoOfDuplicate`).
        await endRedoAfterReplayedTyping(reply.typed, opId: opId, trace: trace)
        spy("quickRedoPerformed")
        trace.log("performed")
        return .performed
    }

    /// The quick redo's refusal: the document is as it was (the section is on the screen), the press is answered `failed` with the
    /// notice. When the stretch had already moved the epoch and the generation (`changedEpoch`, which is also the one point at which
    /// the stretch raised `pendingEditorFirstJobs`, round 1g-B review A3), the count comes down FIRST (the fresh settle's own rebuilds
    /// must stamp as current, the rule of `runEditorFirstStructuralClick`) and one fresh settle puts the skipped steps back.
    func abandonQuickRedo(
        opId: UUID, redoKey: UUID? = nil, reason: String, trace: StructTrace, changedEpoch: Bool
    ) async -> UndoResult {
        trace.log("refused (quick) reason=\(reason)")
        if let redoKey {
            // The job was never started: its marker must not hold up a flush, a close or a quit.
            editorState?.efJobRegistry.forget(redoKey)
            editorState?.efJobRegistry.markSettled(redoKey)
        }
        showUndoQueueDroppedWarning()
        if changedEpoch {
            releasePendingEditorFirstJob()
            startFreshSettleAfterRefusedRestore(opId: opId)
        }
        return .failed
    }
}
