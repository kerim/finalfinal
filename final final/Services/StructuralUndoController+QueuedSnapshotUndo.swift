//
//  StructuralUndoController+QueuedSnapshotUndo.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 3, round 3c (plan-v3 D2, D5, D6, D6a, D7, D9, D13, D15, D16, C4; README "Requirements the model puts on
//  rounds 3b and 3c", items 1 to 11; round-verdicts-3a.md R1 to R8): the SLOW undo and redo (`performUndo` and `performRedo`, the road
//  every entry takes when the quick path is not open: a reorder, a Markdown-mode operation, an entry whose quick path was closed, a
//  duplicate or restore after a reorder, the forced-slow test seams) in Rich Text without the freeze and without losing what the user
//  types around it.
//
//  Today's body flushes the editor, reads the saved snapshot copy, swaps the editor's saved state in (`performStructuralSwap`), restores the
//  database from the snapshot and pushes ids and content back (`settleAfterDBRestore`); typing made between the flush and the end is lost
//  (`StructOpUndo` in the model). Here the EDITOR swaps first, in ONE JavaScript turn (`structuralSwapEditorFirst`, web/milkdown/src/
//  api-structural-swap.ts, round 3b) that consumes the typing so far as batch N, re-checks that the live document still equals the saved
//  copy the press was routed against, swaps the entry's checkpoint in with the ids the database is about to hold, and re-baselines; the
//  database follows as a queued system-write job (`StructuralReplaceJob`, kind `snapshotUndo` or `snapshotRedo`) behind everything the
//  user typed. Nothing is pushed back over the user's text.
//
//    1. `queuedSnapshotUndo(entry:direction:snapshotId:)`: the press. Called by `performUndo` / `performRedo` under the structural gate
//       once the snapshot to swap in is known. Returns the reply for the press, or nil when this press must take the old body (Markdown
//       mode, zoomed, the legacy test flags, no plan, no writer turn, an editor that cannot take the swap: D7).
//    2. `startSnapshotSwapJob(...)`: reserves the job SYNCHRONOUSLY (requirement R3+, see below) and keeps the task that runs it and the
//       work after it.
//    3. `awaitPendingSnapshotSwap(opId:)`: a press that arrives while an earlier slow undo or redo is still being carried through waits for
//       it (held, never refused): the redo needs the snapshot the undo's job writes, and every plan reads the table. Since fix round F1 it
//       also waits for every other unsettled editor-first job (a pending quick undo's reinsert), and the "Undoing..." notice is created
//       before the wait (`performUndo`, `performRedo`).
//
//  WHAT THE SWAP LEAVES FOR SWIFT, AND WHAT SWIFT DOES (each is a requirement of the model, a code review checks them):
//    R1. The click never sets `contentState`, never bumps `contentGeneration`, runs no `modeAwareFlush` and sets no `.structuralUndo`: the
//        editor's own 50 ms `contentChanged` push is accepted while the job waits. (None of these appears below; the shared click
//        `runEditorFirstStructuralClick` only pauses routine polls.) Because nothing sets `contentState`, the footnote undo checkpoints
//        are guarded explicitly in the reply turn (`guardFootnoteCheckpointsForNotesRewrite`, fix round F1, finding D): see
//        StructuralUndoController+FootnoteCheckpointGuard.swift.
//    R3. The job writes EXACTLY the payload's rows: no epoch bump, no restamp (`replaceProjectRows`, the restore job's whole mode).
//    R3+. The job is reserved in the click's REPLY TURN, with no suspension point between the reply and the reservation.
//        `startEditorFirstRestoreJob` (the restores) creates a `Task` and suspends once at `await reserved.wait()`; the job's
//        reservation happens in that Task's first statements, i.e. one main-actor hop after the reply. Here the reservation is
//        `StructuralReplaceJob.reserve`, a plain synchronous call (`BlockSyncService.reserveSystemWriteNow`: steps 1 to 4 of
//        `performSystemWrite`), made inside `afterReply` before anything can suspend, and `startSnapshotSwapJob` is NOT `async`, so the
//        compiler guarantees it. The Task it spawns only WAITS for the turn and applies (`perform(reserved:...)`).
//    R4 and R4+. After the job the settle re-derives Notes, bibliography, sections and annotations from the swapped-in text
//        (`resyncAfterEditorFirstDelete`: the legacy `forceResyncDerivedContent` and `annotationSyncService.syncNow`) and then pushes
//        the database's Notes and Bibliography regions into the editor, merge-guarded (`quickRepushManagedRegions`). The push is the
//        shared settle tail's (`settleManagedRegionsAtEndOfEditorFirstSettle`): `snapshotSwapJobSettled` raises
//        `managedRegionsNeedRepush` when the job applied, and the tail pushes once no editor-first job is pending.
//    R5. A refusal (`docChanged`) applies the returned batch (`consumeEditorFirstReply`, always) and leaves the entry where it was.
//    R6. The redo is the same call and job in the other direction.
//    R8. Markdown keeps the legacy body (`takesTheEditorFirstPath` is Rich Text only).
//
//  WHAT A FAILED JOB DOES (D13, D15). The editor has already swapped when the job runs, so a job that does not apply (a database fault:
//  the transaction rolled back and the table still holds the document from before the press) is handled exactly as a failed restore job
//  is: `editorFirstJobSettled` -> `putBackAfterFailedEditorFirstOp`. The document goes back to the database's from the editor (whole
//  push, `detectPausedEdits`), the entry is taken off the timeline, and the user is told (UX contract 4.3; the wording is in
//  `EditorFirstOpKind.putBackAlert`: "Couldn't Undo" / "Couldn't Redo"). The old body, for comparison, left the editor swapped and the
//  database possibly half restored, and answered `failed`.
//
//  THE QUICK PATH IS CLOSED FOR AN ENTRY THAT HAS BEEN SLOW-SWAPPED. The web swap does not refresh the registry entry's `idMap`,
//  `typeMap`, `confirmLog` and `tempIds` (the old swap did not either), so a quick undo after a slow undo and redo of the same entry would
//  restore op-time ids. `quickPathPossible` requires `efRecordedStructGeneration[entry.id] == structuralOutOfQueueGeneration`; a slow
//  swap removes the entry's recorded value (`efRecordedStructGeneration[opId] = nil`, an Optional that never equals an Int), and nothing
//  sets it again for that entry. The redo is closed on its own: it needs slot state `quickUndone` or `reinserted`, which only a quick
//  undo sets. (The old body bumped `structuralOutOfQueueGeneration` itself, which closed the path for EVERY entry; no new path bumps it,
//  D1, and a swap's job reinserts nothing the other entries' quick undos depend on.) A reorder entry (t-0b70d1e9) never had a quick path
//  to close: `quickPathPossible` refuses the kind, so its first undo and its redo always come through here.
//
//  THE SIDEBAR. The leaders the document stops showing and the ones it now shows are the PLAN's (`plan.previousLeaders`,
//  `plan.newLeaders`: the rows the job writes and the rows it replaces), through the overlay the restores use (`showRestoreInSidebar` ->
//  `swapSidebarLeaders`, anchored at the start of the outline; it also clears a reorder's order overlay, `pendingReorder`, which referred
//  to the document before the swap). The editor's reply lists the leaders of its own document; the sidebar lists the Notes and
//  Bibliography headings too (`fetchOutlineBlocks`), but the plan's leaders leave them out, so the reply is not compared.
//  `editorFirstJobSettled` lifts the overlay once an outline read after the job's commit shows the real rows, and only while the
//  entry's epoch has not moved and this is still the entry's latest job (rules A4/A5 of slice 1).
//

import SwiftUI
import GRDB

/// What `awaitPendingSnapshotSwap` found.
enum PendingSnapshotSwapResult: Equatable {
    /// Nothing was pending, or what was pending has ended: the press goes on.
    case proceed
    /// The entry's slow undo or redo job did not apply and the D6 put-back removed the entry: the press is answered `failed`.
    case putBack
}

extension StructuralUndoController {

    // MARK: - The press

    /// The slow undo (`direction` `.undo`: restore from the entry's undo snapshot) or slow redo (`.redo`: from its redo snapshot) of
    /// `entry`, editor first. Called under the structural gate with `snapshotId` already resolved. Returns the reply for the editor's
    /// latch, or nil when this press has to take the old body (nothing has been changed that the old body would not do itself).
    ///
    /// t-d2061b27 (judge D1, review F7): while this press is latched on the Rich Text page, the page HOLDS the typing it would report to the
    /// polls. When the press goes to the old body (zoomed, no plan, `noCheckpoint`, an editor refusal that falls back, the legacy flags)
    /// the old body's own flush would find that typing held back, so the hold is released and the released batch is sent as batch N
    /// FIRST (`releaseHeldTypingForOldBody`, StructuralUndoController+TypingAcrossUndo.swift), once, before the old body runs.
    func queuedSnapshotUndo(entry: StructuralEntry, direction: UndoDirection, snapshotId: String) async -> UndoResult? {
        let result = await queuedSnapshotUndoRoute(entry: entry, direction: direction, snapshotId: snapshotId)
        if result == nil { await releaseHeldTypingForOldBody() }
        return result
    }

    /// The editor-first route of `queuedSnapshotUndo` (its body before t-d2061b27 F7 wrapped it): the reply, or nil for the old body.
    private func queuedSnapshotUndoRoute(entry: StructuralEntry, direction: UndoDirection, snapshotId: String) async -> UndoResult? {
        // Markdown (t-4a8fd8af round 7b): its own queued route, StructuralUndoController+MarkdownSlowUndo.swift; nil there = the old body.
        if editorState?.editorMode == .source { return await markdownQueuedSnapshotUndo(entry: entry, direction: direction, snapshotId: snapshotId) }
        // (A sync service with no web view has no editor to swap: the click would find no writer turn and send the press to the old body
        // anyway, after reading the plan; this skips the read.)
        guard takesTheEditorFirstPath, let editorState, editorState.zoomedSectionId == nil, let unifiedUndoService,
              let blockSync = blockSyncService, blockSync.webView != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return nil }
        let isUndo = direction == .undo
        let kind: EditorFirstOpKind = isUndo ? .snapshotUndo : .snapshotRedo
        let opId = entry.id
        let label = isUndo ? "undo" : "redo"

        // 1. The plan: the rows the job will write (the snapshot's document, ids prepared against the rows now in the table, D2) and the
        // payload the editor aligns its saved state to. Read now, in the press's synchronous stretch.
        guard let plan = readSwapPlan(snapshotId: snapshotId, kind: kind, database: db, projectId: pid) else { return nil }
        guard let swapScript = Self.swapScript(opId: opId, direction: direction, plan: plan) else { return nil }
        #if DEBUG
        testLastRestorePlan = plan   // so a unit test can type into the swapped-in document by the ids the editor now holds
        #endif

        let trace = StructTrace(label: label, opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: label, opId: trace.opId)   // slice 0 measurement: the shared timeline
        trace.log("start (editor-first \(label)) rows=\(plan.rows.count)")
        let timelineEpoch = unifiedUndoService.generation
        let removedLeaders = Set(plan.previousLeaders.map(\.id))
        // UI-test seam (FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS, see TestMode): widens the window between the plan and the click in which the
        // user can type, so the click meets typing done during the wait the way it does after a real wait (the page puts that typing back
        // on top of the swapped-in document: `typingReplayed`). Swift side only; no wait when off.
        await TestMode.holdSlowUndoPress(opId: trace.opId)

        // 2. The click: ONE editor call (`structuralSwapEditorFirst`), the sidebar swap, the job's reservation. The same function that
        // Delete, Duplicate and the restores use. By its reply the click ends `.done` (swapped), `.refused` (docChanged, or the bridge
        // failed: the document is as it was), `.legacy` (the old body runs next, in this gate turn; the persisted fallback line was
        // written) or `.declined` (no saved state for the entry: `noCheckpoint`).
        func click(script: String) async -> EditorFirstClickOutcome<EditorFirstReplaceReply> {
            await runEditorFirstStructuralClick(
                kind: kind, opId: opId, script: script, replyType: EditorFirstReplaceReply.self,
                database: db, projectId: pid, trace: trace
            ) { _ in
                // What the user sees changes NOW, in the reply's own main-actor turn (synchronous: no poll task runs inside it).
                self.showRestoreInSidebar(opId: opId, plan: plan)
                // R3+: reserve the job with no suspension point between the reply and the reservation.
                self.startSnapshotSwapJob(
                    opId: opId, kind: kind, plan: plan, removedLeaders: removedLeaders, database: db, projectId: pid)
            }
        }
        var outcome = await click(script: swapScript)
        if case .declined(let declinedReply) = outcome {
            // `noCheckpoint` (U-S3-3): the editor has no saved state for this entry (or, for a redo, no redo checkpoint), so there is
            // nothing to swap and nothing was changed. Slice 2's whole replace puts the snapshot's document in from the same plan. It
            // runs under a FRESH operation id, so the editor's registry entry for this one (if it has any) is left alone; it records
            // no entry of its own (this press moves the existing entry). There is no re-check on this road (RARE, plan-v3 section 6).
            //
            // Round 6 (N3): there is no replay on this road either. When the call consumed pending edits (`batch` non-empty: the
            // typing done in the wait), the whole replace would take them off the screen and its job would overwrite their rows, a
            // silent loss. So the press is REFUSED with the existing notice before any replace: the batch has been applied (the typing
            // stays on the screen and goes to the rows), the entry stays where it is, and the fresh settle puts back the steps the
            // click's epoch bump skipped. With an empty batch the whole replace runs as before.
            if !declinedReply.batch.isEmpty {
                startFreshSettleAfterRefusedEditorFirstClick(opId: opId)
                DebugLog.log(
                    .undo, "[StructuralUndoController] editor-first \(kind.logName): no checkpoint and pending typing -- refused "
                    + "before the whole replace, which would overwrite it")
                return answerRefusedSlowSwap(label: label, trace: trace)
            }
            guard let replaceScript = plan.script(function: "replaceRangeEditorFirst", opId: UUID()) else { return nil }
            DebugLog.log(.undo, "[StructuralUndoController] editor-first \(kind.logName): no checkpoint -- whole replace from the snapshot")
            outcome = await click(script: replaceScript)
        }
        var typingReplayed: Bool?
        switch outcome {
        case .legacy, .declined:
            return nil
        case .refused:
            // R5 (Phase 4c job 2: typing is NOT a reason any more -- the page puts it back on top of the swap, see `.done`): the page
            // found the document changed by something that is not typing while the press waited, or it could not place a typed step in
            // the target document (`docChanged`), or the bridge failed. The editor is as it was, the batch it consumed has been applied
            // (any typing is on the screen and goes to the database), the entry stays where it is, and the press is answered `failed`
            // with the existing notice. The next Cmd-Z takes the typing back (text undo) and the one after it finds the document equal
            // to the saved copy again (R7).
            // Review F18 (UX contract 4.2: a press made while the project is being saved shows nothing, the window is going away): with
            // the gate closed to new work (a close, quit or switch has begun) the refusal is silent and the reply is `.cancelled`, as
            // `moveEntryAfterSwap` answers a barrier.
            return answerRefusedSlowSwap(label: label, trace: trace)
        case .done(let reply):
            typingReplayed = reply.typingReplayed
        }

        // 3. The timeline. The editor shows the swapped-in document and the job holds its place in the queue. When the page put the typing
        // done during the wait back on top of it (`typingReplayed`), that typing ends the redo branch: inside the gate, after the entry
        // has moved (StructuralUndoController+TypingAcrossUndo.swift).
        return await moveEntryAndEndRedoBranch(
            opId: opId, kind: kind, timelineEpoch: timelineEpoch, typingReplayed: typingReplayed, trace: trace)
    }

    /// The answer to a refused slow press (an extraction of `queuedSnapshotUndoRoute`'s `.refused` branch, which keeps its statements in
    /// the same order; round 6 reuses it for the `noCheckpoint` refusal): trace line, then, with the gate closed to new work (review F18,
    /// a close, quit or switch has begun), silence and `.cancelled`; otherwise the existing notice and `.failed`.
    private func answerRefusedSlowSwap(label: String, trace: StructTrace) -> UndoResult {
        trace.log("refused (editor-first \(label))")
        if editorState?.structuralGate.isClosedToNewWork == true { return .cancelled }
        showUndoQueueDroppedWarning()
        return .failed
    }

    /// The timeline step that ends the editor-first route (a mechanical extraction of `queuedSnapshotUndoRoute`'s tail): the entry moves
    /// (`moveEntryAfterSwap`), and when the page put the typing back on top of the swapped-in document that typing ends the redo branch,
    /// still inside the gate (t-d2061b27).
    private func moveEntryAndEndRedoBranch(
        opId: UUID, kind: EditorFirstOpKind, timelineEpoch: Int, typingReplayed: Bool?, trace: StructTrace
    ) async -> UndoResult {
        let result = await moveEntryAfterSwap(opId: opId, kind: kind, timelineEpoch: timelineEpoch, trace: trace)
        if result == .performed { await endRedoAfterReplayedTyping(typingReplayed, opId: opId, trace: trace) }
        return result
    }

    /// Reads the plan of a snapshot swap, or nil (logged) when the press has to take the old body: the snapshot has no blocks, or does not
    /// exist any more (the old body would meet the same and say so itself).
    func readSwapPlan(snapshotId: String, kind: EditorFirstOpKind, database: ProjectDatabase, projectId: String) -> RestorePlan? {
        do {
            guard let plan = try SnapshotService.wholeRestorePlan(database: database, projectId: projectId, snapshotId: snapshotId) else {
                DebugLog.log(.undo, "[StructuralUndoController] editor-first \(kind.logName): the snapshot has no blocks -- old path")
                return nil
            }
            return plan
        } catch {
            DebugLog.log(.undo, "[StructuralUndoController] editor-first \(kind.logName): no plan (\(error)) -- old path")
            return nil
        }
    }

    /// The swap happened and the job holds its place: close the quick path for the entry, move it to the other stack, tell the editor.
    /// The snapshot the job writes is attached to the entry when the job has committed (`recordSnapshotOnTimeline`).
    func moveEntryAfterSwap(opId: UUID, kind: EditorFirstOpKind, timelineEpoch: Int, trace: StructTrace) async -> UndoResult {
        guard let editorState, let unifiedUndoService else { return .failed }
        efRecordedStructGeneration[opId] = nil   // the quick path is closed for this entry from here on (see the file header)
        var moved = false
        if unifiedUndoService.generation == timelineEpoch {
            let outcome = kind == .snapshotUndo ? unifiedUndoService.performUndo(opId: opId) : unifiedUndoService.performRedo(opId: opId)
            if case .performed = outcome { moved = true }
        }
        guard moved else {
            // A barrier (zoom, mode switch, project switch, hierarchy enforcement) landed between the click and the stack move: the
            // timeline is gone. The swap happened and its job is queued; the Edit menu must stop saying "Undo ..." for it. A barrier
            // is not a refusal: `.cancelled` when the gate is closed to new work, the notice only for a real `.failed`.
            let closed = editorState.structuralGate.isClosedToNewWork
            DebugLog.log(
                .undo, "[StructuralUndoController] editor-first \(kind.logName) \(opId): the timeline changed mid-sequence -- the swapped-in "
                + "document is on the screen and its job is queued; reporting \(closed ? ".cancelled" : ".failed")")
            await pushDescriptor()
            if !closed { showUndoQueueDroppedWarning() }
            return closed ? .cancelled : .failed
        }
        await pushDescriptor()
        spy("snapshotSwapPerformed")
        trace.log("performed")
        return .performed
    }

    /// `JSON.stringify(window.FinalFinal.structuralSwapEditorFirst("<opId>", "undo"|"redo", {payload}))`. The payload is the restore's
    /// (`RestorePayload`, mode `whole`): the editor reads `blockIds`, `expectedBlocks` and `managedBlockIds` and ignores the rest.
    private static func swapScript(opId: UUID, direction: UndoDirection, plan: RestorePlan) -> String? {
        guard let opLiteral = jsLiteral(opId.uuidString), let directionLiteral = jsLiteral(direction == .undo ? "undo" : "redo"),
              let payloadLiteral = jsLiteral(plan.payload) else { return nil }
        return "JSON.stringify(window.FinalFinal.structuralSwapEditorFirst(\(opLiteral), \(directionLiteral), \(payloadLiteral)))"
    }

    // MARK: - The job

    /// Reserves the job for entry `opId` and spawns the task that runs it and the work after it. NOT `async`, on purpose (R3+): the
    /// reservation (`StructuralReplaceJob.reserve`) is a synchronous call, so nothing can come between the editor's reply and the job's
    /// place in the writer's queue. Called from `afterReply` of the click, which hands this job the raised `pendingEditorFirstJobs`:
    /// the task brings it down as soon as the job's future has resolved, BEFORE the settle or the put-back starts (D6). Returns whether
    /// the job really holds its place (false: refused before it reserved; the task still runs the settle, which puts the document
    /// back).
    ///
    /// The job's registry key is FRESH (`EFJobRegistry.register` hands back the record already there for a repeated id, and the entry's
    /// own id is its first job's): the entry's `efLatestJobKey` and `efSnapshotJobKeys` name it, and the close, quit, zoom, mode-switch,
    /// Save Version and export waits wait for its unsettled marker.
    @discardableResult
    func startSnapshotSwapJob( // swiftlint:disable:this function_parameter_count
        opId: UUID, kind: EditorFirstOpKind, plan: RestorePlan, removedLeaders: Set<String>, database: ProjectDatabase, projectId: String,
        jobKey: UUID = UUID()   // a Markdown press (round 7b) makes the key first: its gate is keyed by it and exists before the job does
    ) -> Bool {
        guard let editorState, let blockSync = blockSyncService else {
            releasePendingEditorFirstJob()
            return false
        }
        let registry = editorState.efJobRegistry
        registry.register(jobKey)
        efJobKeys[opId, default: []].append(jobKey)
        efLatestJobKey[opId] = jobKey
        efSnapshotJobKeys[opId] = jobKey
        let epochAtClick = efOpEpoch[opId] ?? 0
        var heldJob = StructuralReplaceJob(
            opId: opId, projectId: projectId,
            fallbackBibliographyTitle: ExportSettingsManager.shared.effectiveBibliographyHeaderName, slots: efSlots, plan: plan)
        heldJob.kind = kind == .snapshotUndo ? .snapshotUndo : .snapshotRedo
        heldJob.bodyHold = jobBodyHold()
        heldJob.registryKey = jobKey
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)

        // THE RESERVATION: synchronous (see the file header, R3+).
        let reservation = job.reserve(on: blockSync, identity: identity, registry: registry)
        spy("snapshotSwapJobReserved")
        // Fix round F1, finding D: the job rewrites every Notes row from the snapshot, so every footnote undo checkpoint describes a
        // table that is about to be gone. Dropped here, in the reply turn, before the editor's content push (about 50 ms later) can
        // match one (StructuralUndoController+FootnoteCheckpointGuard.swift); released when the job's task is over.
        guardFootnoteCheckpointsForNotesRewrite(token: jobKey)

        let settleTask = Task { @MainActor [weak self] in
            StructuralTrace.log("job task started")
            var pendingCountReleased = false
            @MainActor func releasePendingCount() {
                guard !pendingCountReleased else { return }
                pendingCountReleased = true
                self?.releasePendingEditorFirstJob()
            }
            // The job AND the work after it are over on every way out of here: whoever waits for the swap (a press for the same entry,
            // the close/quit wait, the zoom, the switch to Markdown, Save Version, export) is let go only now.
            defer {
                releasePendingCount()
                self?.releaseFootnoteCheckpointGuard(token: jobKey)
                registry.markSettled(jobKey)
                if self?.efSnapshotJobKeys[opId] == jobKey { self?.efSnapshotJobKeys[opId] = nil }
            }
            let result = await job.perform(reserved: reservation, on: blockSync, identity: identity, registry: registry)
            releasePendingCount()   // the job has ended: the settle's own rebuilds read the table after it and must stamp as current
            self?.notifyMarkdownJobEnded(key: jobKey, outcome: JobOutcome(result.outcome))   // a Markdown press's hold continuation
            await self?.snapshotSwapJobSettled(
                opId: opId, kind: kind, result: result, removedLeaders: removedLeaders, epoch: epochAtClick, jobKey: jobKey)
        }
        efSettleTasks[opId] = settleTask
        return reservation.isHeld
    }

    /// The job's future has resolved. Applied: the snapshot the job wrote goes onto the timeline (the entry's redo snapshot after an
    /// undo, its fresh undo snapshot after a redo, exactly what the old body did at this point), then the shared settle
    /// (`editorFirstJobSettled`: the resyncs, the sidebar, the re-push of the managed regions). Anything else: the shared settle's D6
    /// put-back.
    private func snapshotSwapJobSettled( // swiftlint:disable:this function_parameter_count
        opId: UUID, kind: EditorFirstOpKind, result: SystemWriteResult<StructuralReplaceJob.Output>, removedLeaders: Set<String>,
        epoch: Int, jobKey: UUID
    ) async {
        if case .applied(let output) = result.outcome {
            recordSnapshotOnTimeline(opId: opId, kind: kind, snapshotId: output.snapshotId)
            // The job replaced the Notes and Bibliography rows (and every other row) with the snapshot's without telling the two
            // services whose dedup hash describes the table as it was before (the quick undo's reinsert settle does the same). A resync
            // that hashes to the value they last committed would be skipped as "already done" and leave the table as the snapshot put it.
            forgetCommittedDerivedState()
            // R4: a rebuild may have reserved a writer ticket between the click and the job, and the snapshot then put an OLDER Notes or
            // Bibliography into the table; the editor's regions must become the database's. The shared settle tail
            // (`settleManagedRegionsAtEndOfEditorFirstSettle`) pushes them, merge-guarded (`quickRepushManagedRegions`), when this flag
            // is up and no editor-first job is pending: the LAST settle of a run of back-to-back operations is the one that does it, and
            // a close or quit that holds the editor gets its closing push instead. The settle's resyncs run first, from the swapped-in
            // text (R4+: the legacy `forceResyncDerivedContent` and annotation sync).
            editorState?.managedRegionsNeedRepush = true
        }
        await editorFirstJobSettled(
            opId: opId, outcome: JobOutcome(result.outcome), removedLeaders: removedLeaders, epoch: epoch, jobKey: jobKey, kind: kind)
    }

    /// Hands the snapshot the job pinned at its commit to the entry. MainActor, no suspension: the entry is looked up and written in
    /// one stretch. When the entry is no longer where it should be (the redo branch was dropped by typing, a new operation cleared it, a
    /// barrier wiped the timeline) the pin the job took is released, or the pin set would grow by one snapshot per swap.
    private func recordSnapshotOnTimeline(opId: UUID, kind: EditorFirstOpKind, snapshotId: String) {
        guard let unifiedUndoService else {
            SnapshotService.unpinUndoPointSnapshot(snapshotId)
            return
        }
        switch kind {
        case .snapshotUndo:
            // The entry is on the redo stack now: the snapshot of the document just before the undo is what a redo restores.
            unifiedUndoService.attachRedoSnapshot(opId: opId, redoSnapshotId: snapshotId)
            if unifiedUndoService.redoStack.last(where: { $0.id == opId })?.redoSnapshotId != snapshotId {
                SnapshotService.unpinUndoPointSnapshot(snapshotId)
            }
        case .snapshotRedo:
            // The entry is back on the undo stack: the snapshot of the document just before the redo is its fresh undo snapshot.
            // Addendum A18: an editor-first entry keeps it on its slot (writing it unpins the id it replaces).
            guard let top = unifiedUndoService.undoStack.last, top.id == opId else {
                SnapshotService.unpinUndoPointSnapshot(snapshotId)
                return
            }
            if top.isEditorFirst {
                efSlots.snapshotIdWrite(opId, snapshotId)
                if efSlots.slot(opId)?.snapshotId != snapshotId { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
            }
            unifiedUndoService.replaceTopOfUndoStack(opId: opId, freshUndoSnapshotId: snapshotId)
        default:
            break
        }
    }

    // MARK: - A press that arrives while a swap is being carried through

    /// Waits for every slow undo or redo whose job (or the work after it) has not ended. A redo needs the snapshot the undo's job
    /// writes; any press builds its plan from the rows in the table, and the table is the previous swap's until its job has applied;
    /// the legacy body was entirely synchronous, so the press that followed always found everything done. The press is HELD, never
    /// refused (floor item 2). Costs nothing when nothing is pending.
    ///
    /// `.putBack` when the press's own entry lost its swap job meanwhile (the D6 put-back removed it): the press is answered `failed`,
    /// as `resolveOutcome` does for an entry the put-back took before the press began.
    ///
    /// Fix round F1 (review B2/A2): not only the earlier slow swaps. EVERY editor-first job still being carried through is waited for
    /// (`efJobRegistry.awaitAllSettled`, as the old body did through `awaitPendingStructuralJobs`) before the plan is read: a quick
    /// undo's reinsert that is still in the writer's queue has not put its section's rows into the table yet, and a plan prepared
    /// against the rows now in the table gives that section's heading a FRESH id (`wholeRestorePlan` keeps ids by title), so the
    /// reinsert's heading and the snapshot's would be two rows and the entry's quick redo would find neither. The press keeps its
    /// place at the gate for the wait ("Undoing..." shows from one second: the callers create the toast before they call this).
    func awaitPendingSnapshotSwap(opId: UUID) async -> PendingSnapshotSwapResult {
        guard let editorState else { return .proceed }
        for (entryId, key) in efSnapshotJobKeys {
            _ = await editorState.efJobRegistry.awaitOutcome(key)
            if let settle = efSettleTasks[entryId] { await settle.value }
        }
        if editorState.efJobRegistry.hasUnsettledWork { await editorState.efJobRegistry.awaitAllSettled() }
        return efPutBackOpIds.remove(opId) != nil ? .putBack : .proceed
    }
}
