//
//  StructuralUndoController+MarkdownQuickUndo.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 7a: the QUICK Cmd-Z and Cmd-Shift-Z of a Markdown
//  Delete Section (plan v2 B5 and B6, plan v2.1 addendum sections 6 to 8, judge-plan-round3 O5/O19/O24 and the Q2 ruling). The switch
//  (`MarkdownEditorFirstSwitch`) is ON by default (round 7b flipped it).
//
//  WHERE IT RUNS. `resolveQuickPath` (StructuralUndoController+QuickUndo.swift) hands a Markdown entry (`efEditorKind == .markdown`) to
//  `resolveMarkdownQuickPath` after it has checked eligibility (`quickPathPossible`, whose one mode condition now asks the entry's kind),
//  INSIDE the structural gate. A nil answer sends the press down today's slow path.
//
//  A QUICK UNDO AND A QUICK REDO ARE STRUCTURAL COMMANDS EXACTLY LIKE THE DELETE: each waits for the previous Markdown job's apply
//  (`awaitStructuralHoldReleased`, A7), raises its OWN hold token (the same `defer { if !handedOff { hold.release() } }` and hand-off
//  discipline as the click), makes ONE call into the page, and in the REPLY TURN (the writer's last write awaited first) reserves the
//  typing batch up to the press (`prepareStructuralClick`), `noteQueuedStructuralJob`, adopts the page's text (`adoptMarkdownPageText`,
//  O11/O25) and starts the queued job. Then the hold is handed to the SAME step-8 continuation the click uses
//  (`startMarkdownHoldContinuation` / `runMarkdownStep8`), keyed by the job's registry key.
//
//  THE QUICK UNDO (`markdownQuickUndo`):
//    page call   `markdownStructuralSwap(opId, 'undo')`: setState(checkpoint), the live redo branch carried over, the carried state
//                re-applied. `{ok:false, reason:'changed'|'noEntry'|'midOp'}` (the user typed since the press, or an automatic push changed
//                the document) changes nothing on the screen: the counters and the footnote hold are put back, the press is answered
//                `failed` with the existing notice ("Some undo or redo presses could not be carried out."), one fresh settle runs
//                (`abandonQuickUndo`, the Rich Text quick undo's own). Typing stays.
//    reply turn  the typing batch, `noteQueuedStructuralJob`, the restored document adopted, the section shown again in the sidebar
//                (`showRestoredSections`, which reads the leaders from the payload holder the delete job filled), then the SAME
//                `SectionReinsertJob` the Rich Text quick undo starts (`startReinsert`), keyed by its own fresh reinsert key.
//    hand-off    the hold goes to the continuation keyed by that reinsert key (`swapsBackOnFailure: false`: a failed reinsert has nothing
//                to swap back; the flush writes the page's text into the rows instead).
//    timeline    the slot is `quickUndone`, the entry moves to the redo stack, the descriptor is pushed; a document that differs from the
//                restored one by now (typed during the press) drops the redo branch, as the Rich Text quick undo does.
//  A missing payload (the delete job's rows were never recorded) is NEVER undone wrongly: the press takes the slow path (nil).
//
//  THE QUICK REDO (`markdownQuickRedo`): the page re-runs the delete under the same opId on the document as it is NOW, with a FRESH request
//  built from the rows as the database holds them then (`markdownStructuralSwap(opId, 'redo', request)`). It waits for the quick undo's
//  hold first, i.e. for the reinsert to have applied, so the rows and the page agree and the leader match holds. Everything after the page
//  call is the click's own reply turn (`markdownDeleteReplyTurn`, shared): a fresh `SectionDeleteJob` under a fresh registry key, a gate,
//  and the hand-off. The bookkeeping matches the Rich Text quick redo (`performQuickRedoOfDelete`): epoch, restore generation, click
//  generation, the footnote checkpoint hold released, `efRecordedGeneration`/`efRecordedStructGeneration`, `performRedo(opId:)`.
//
//  THE NOTICE (acceptance F1, UX contract 4.2, floor 3). `resolveMarkdownQuickPath` starts ONE delayed "Finishing the last change…" the
//  moment the press reaches it and takes it down (by id, in a `defer`) when the press is over: it covers the wait for the previous job
//  AND the page swap and reply turn that follow, for the undo and the redo. Under a second nothing shows. (The gate's own notice,
//  `runStructuralCommand`, only exists for a press that had to QUEUE behind a running command; a Cmd-Z pressed after the Delete's click
//  has given the gate back is granted at once and waits on the writer's hold inside the body, which that notice never sees.)
//
//  KEYS. A gate and a continuation are keyed by the JOB's registry key, never by the entry's id alone: the click's delete uses the
//  entry's id, a quick redo's delete job its fresh redo key, a quick undo's reinsert its reinsert key. So two jobs of one entry never
//  share a gate, and a late settle of the earlier job can never drop the later one's.
//

import Foundation
import WebKit

extension EditorFirstEditorKind {
    /// The editor mode an entry of this kind lives in: `quickPathPossible` compares it with the mode the editor is in now.
    var mode: EditorMode {
        switch self {
        case .wysiwyg: return .wysiwyg
        case .markdown: return .source
        }
    }
}

extension StructuralUndoController {

    // MARK: - The route

    /// Called by `resolveQuickPath` for a Markdown entry, inside the gate, after the eligibility check. nil: the press takes the slow path.
    func resolveMarkdownQuickPath(_ entry: StructuralEntry, redo: Bool) async -> UndoResult? {
        guard let editorState, let unifiedUndoService, let blockSync = blockSyncService, let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId, let holder = efHolders[entry.id], activeWebView != nil,
              editorState.markdownWriter.isEnabled, editorState.activeLifecycle == nil,
              blockSync.writer?.database === db, blockSync.writer?.projectId == pid else { return nil }
        let opId = entry.id

        // A7: the previous Markdown job (the delete's, or the quick undo's reinsert) finishes first, and its step 8 has saved the typing.
        // The press is held, never refused. ONE notice belongs to the whole press (acceptance F1, floor 3): it is counted from the press,
        // not from the end of the wait, and it stays through the page swap and the reply turn that follow, for the undo and the redo
        // alike. A Cmd-Z pressed right after a Delete on a book waits ~0.8 s for the delete's save and then swaps for ~0.7 s: a notice
        // that went away when the wait ended showed nothing for those 1.5 s. Under a second nothing shows. The `defer` takes it down
        // by id on every way out: performed, refused by the page, failed, cancelled by a lifecycle, or sent to the slow path.
        let notice = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        await editorState.markdownWriter.awaitStructuralHoldReleased()
        // The wait is long enough for the world to change: a close began, the delete job failed and was put back, a barrier ran.
        if editorState.structuralGate.isClosedToNewWork { return .cancelled }
        let topId: UUID? = redo ? unifiedUndoService.redoStack.last?.id : unifiedUndoService.undoStack.last?.id
        let eligible: Bool = redo ? quickRedoEligible(entry) : quickUndoEligible(entry)
        guard topId == opId, eligible, !efPutBackOpIds.contains(opId), editorState.activeLifecycle == nil,
              holder.outcome == .applied, editorState.editorMode == .source, editorState.zoomedSectionId == nil else {
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown quick \(redo ? "redo" : "undo") of \(opId): not possible after the wait -- slow path")
            return nil
        }
        let context = MarkdownJobContext(editorState: editorState, blockSync: blockSync, database: db, projectId: pid)
        return redo
            ? await markdownQuickRedo(entry, holder: holder, context: context)
            : await markdownQuickUndo(entry, holder: holder, context: context)
    }

    // MARK: - The quick undo

    private func markdownQuickUndo(
        _ entry: StructuralEntry, holder: SectionDeletePayloadHolder, context: MarkdownJobContext
    ) async -> UndoResult {
        guard let unifiedUndoService else { return .failed }
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        let opId = entry.id
        let timelineEpoch = unifiedUndoService.generation
        let trace = StructTrace(label: "undo", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "undo", opId: trace.opId)
        trace.log("start (quick, markdown)")

        // The hold: this undo is a structural command (see the header). The `defer` releases it on every exit that did not hand it on.
        let hold = writer.beginStructuralHold()
        var handedOff = false
        defer { if !handedOff { hold.release() } }

        // 1. The Rich Text quick undo's first stretch: the entry's epoch and the restore generation up (a settle or rebuild that already
        // started finds itself superseded), the reinsert pending, the debounces cancelled, the footnote checkpoint hold, the unsettled
        // marker of the reinsert's fresh key (a flush that starts from here on waits for the reinsert).
        let epoch = bumpEpoch(opId)
        editorState.editorRestoreGeneration += 1
        editorState.pendingReinsertCount += 1
        footnoteSyncService?.cancelPendingDebounce()
        bibliographySyncService?.cancelPendingDebounce()
        let reinsertKey = UUID()
        footnoteSyncService?.holdUndoCheckpoints(token: reinsertKey)
        holder.setCheckpointHoldToken(reinsertKey)
        editorState.efJobRegistry.register(reinsertKey)
        efJobKeys[opId, default: []].append(reinsertKey)
        await prepareMarkdownPageForStructuralCommand()

        // 2. The page call.
        guard let reply = await sendMarkdownSwap(opId: opId, direction: "undo"), reply.succeeded,
              let preRaw = reply.preRaw, let postRaw = reply.postRaw else {
            let refused = await abandonQuickUndo(opId: opId, reinsertKey: reinsertKey, holder: holder, reason: "pageRefused", trace: trace)
            rearmMarkdownReparseAfterRefusedPress()   // F2: the typing made during the wait reaches the rows
            return refused
        }
        trace.log("quick restore done (markdown)")
        footnoteSyncService?.dropUndoCheckpoints(notIn: holder.snapshot().footnoteCheckpointMarker)
        forgetCommittedDerivedState()   // the restore brings the deleted footnotes and citations back

        // 3. The reply turn: the typing batch up to the swap is reserved BEFORE the reinsert, the restored document becomes the record.
        while let pending = writer.inFlight { await pending.value }
        writer.prepareStructuralClick(
            text: MarkdownLeaderMap.recordText(fromRaw: preRaw), database: context.database, projectId: context.projectId,
            service: context.blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        writer.noteQueuedStructuralJob()
        editorState.adoptMarkdownPageText(postRaw)   // O11/O25: the swap's text is the restored document
        let sidebarUpdate = showRestoredSections(
            opId: opId, reinsertKey: reinsertKey, epoch: epoch, holder: holder, restoredLeaderIds: [], database: context.database)
        sectionSyncService?.cancelPendingSync()
        sectionSyncService?.resetSyncTracking()   // A13: the section sync's tracking belongs to the post-delete document
        spy("quickUndoRestoreApplied")

        // 4. The reinsert, then the hand-off in the same synchronous turn as its reservation.
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[reinsertKey] = gate
        let reserved = startReinsert(
            opId: opId, reinsertKey: reinsertKey, epoch: epoch, holder: holder, database: context.database,
            projectId: context.projectId, sidebarUpdate: sidebarUpdate, operationLabel: entry.operationLabel, editorKind: .markdown)
        await reserved.wait()
        guard reserved.didReserve else {
            // No job will run, so no step 8 would flush: the flush alone makes the rows match the restored page.
            DebugLog.alwaysPersisted("[StructuralUndoController] markdown quick undo \(opId): the reinsert could not be reserved")
            handedOff = true   // `runMarkdownStep8`'s turn releases the hold
            await runMarkdownStep8(
                opId: opId, jobKey: reinsertKey, hold: hold, outcome: .failed("reinsert not reserved"), swapsBackOnFailure: false)
            return editorState.structuralGate.isClosedToNewWork ? .cancelled : .failed
        }
        handedOff = true
        startMarkdownHoldContinuation(hold: hold, opId: opId, jobKey: reinsertKey, swapsBackOnFailure: false)
        efSlots.markQuickUndone(opId)
        trace.log("reinsert reserved")
        spy("quickUndoReinsertReserved")

        // 5. The timeline and the reply.
        guard unifiedUndoService.generation == timelineEpoch, case .performed = unifiedUndoService.performUndo(opId: opId) else {
            let closed = editorState.structuralGate.isClosedToNewWork
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown quick undo \(opId): the timeline changed mid-sequence -- the section is back on "
                + "the screen and the reinsert is queued; reporting \(closed ? ".cancelled" : ".failed")")
            await pushDescriptor()
            if !closed { showUndoQueueDroppedWarning() }
            return closed ? .cancelled : .failed
        }
        await pushDescriptor()
        // Typing made while the press was being carried out (the hold wait is over, but the swap's reply turn can still suspend) is
        // text the redo branch does not know: it drops the branch, as the Rich Text quick undo does.
        if let live = await evalString("window.FinalFinal.getContentRaw()"), live != postRaw {
            unifiedUndoService.invalidateRedoBranch(reason: "typed during the quick undo")
            await pushDescriptor()
        }
        spy("quickUndoPerformed")
        trace.log("performed")
        return .performed
    }

    // MARK: - The quick redo

    private func markdownQuickRedo(
        _ entry: StructuralEntry, holder: SectionDeletePayloadHolder, context: MarkdownJobContext
    ) async -> UndoResult {
        guard let unifiedUndoService else { return .failed }
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        let opId = entry.id
        let timelineEpoch = unifiedUndoService.generation
        let trace = StructTrace(label: "redo", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "redo", opId: trace.opId)
        trace.log("start (quick, markdown)")

        let hold = writer.beginStructuralHold()
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }

        // The Rich Text quick redo's stretch: epoch and restore generation up, the rebuild stamp moves the click's way (a rebuild that
        // read the table before the redo's job must not push it over the editor), the debounces cancelled, the redo job's marker.
        bumpEpoch(opId)
        editorState.editorRestoreGeneration += 1
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true
        footnoteSyncService?.cancelPendingDebounce()
        bibliographySyncService?.cancelPendingDebounce()
        let redoKey = UUID()
        editorState.efJobRegistry.register(redoKey)
        efJobKeys[opId, default: []].append(redoKey)
        await prepareMarkdownPageForStructuralCommand()

        // The page call: a FRESH request from the rows as they are now (the reinsert has applied: the hold wait saw to that), with the
        // B1 flush-and-retry once.
        guard let attempt = await sendMarkdownDeleteWithRetry(
            opId: opId, rootId: holder.rootId, redo: true, database: context.database, projectId: context.projectId),
              attempt.reply.succeeded, let preRaw = attempt.reply.preRaw, let postRaw = attempt.reply.postRaw else {
            run.countHandedToJob = true   // `abandonQuickRedo` brings the pending count down itself
            let refused = await abandonQuickRedo(opId: opId, redoKey: redoKey, reason: "pageRefused", trace: trace, changedEpoch: true)
            rearmMarkdownReparseAfterRefusedPress()   // F2: the typing made during the wait reaches the rows
            return refused
        }
        if let token = holder.takeCheckpointHoldToken() { footnoteSyncService?.releaseUndoCheckpointHold(token: token) }
        forgetCommittedDerivedState()   // a redo pressed before the reinsert's settle: the redo's resync must not be skipped as done
        sectionSyncService?.cancelPendingSync()
        sectionSyncService?.resetSyncTracking()
        trace.log("quick removal done (markdown)")

        await markdownDeleteReplyTurn(
            opId: opId, rootId: holder.rootId, jobKey: redoKey, attempt: attempt, preRaw: preRaw, postRaw: postRaw, context: context,
            hold: hold, run: &run)
        spy("quickRedoJobReserved")
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration

        guard unifiedUndoService.generation == timelineEpoch, case .performed = unifiedUndoService.performRedo(opId: opId) else {
            // The same exit as the quick undo's (DR-6): the section is off the screen and its delete is queued, so the user is told the
            // press did not complete (unless the project is closing) and the editor's routing descriptor is brought up to date.
            let closed = editorState.structuralGate.isClosedToNewWork
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown quick redo \(opId): the timeline changed mid-sequence -- the section is off "
                + "the screen and its delete is queued; reporting \(closed ? ".cancelled" : ".failed")")
            await pushDescriptor()
            if !closed { showUndoQueueDroppedWarning() }
            return closed ? .cancelled : .failed
        }
        await pushDescriptor()
        spy("quickRedoPerformed")
        trace.log("performed")
        return .performed
    }

    // MARK: - The page call

    /// `markdownStructuralSwap(opId, direction)` without a request (the undo, and the redo of an entry the OLD body recorded). nil: no
    /// readable answer from the page. The redo of an editor-first Markdown Delete never uses this: it sends a FRESH request
    /// (`sendMarkdownDeleteWithRetry(... redo: true)`).
    func sendMarkdownSwap(opId: UUID, direction: String) async -> MarkdownStructuralReply? {
        guard let answer = await evalString("JSON.stringify(window.FinalFinal.markdownStructuralSwap('\(opId.uuidString)', '\(direction)'))"),
              let reply = try? JSONDecoder().decode(MarkdownStructuralReply.self, from: Data(answer.utf8)) else { return nil }
        return reply
    }
}
