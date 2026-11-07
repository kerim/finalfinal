//
//  StructuralUndoController+MarkdownSlowUndo.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 7b: the QUEUED SLOW undo and redo of a Markdown entry
//  (plan v2 B5 slow route, B7; the Markdown counterpart of StructuralUndoController+QueuedSnapshotUndo.swift, whose header explains the
//  model: the editor swaps first, a queued job makes the database equal to the snapshot, nothing typed meanwhile is lost).
//
//  WHICH ENTRIES. Every Markdown entry whose Cmd-Z or Cmd-Shift-Z is not quick (`quickPathPossible`, or the quick path closed itself):
//    (a) entries the OLD body recorded in Markdown mode: a Version History restore, a Duplicate Section or a drag-reorder whose click
//        took the old body (the kill switch off, a page that refused, since slice 4 also a restore target the editor-first path cannot
//        take).
//        Their undo and redo go through here, so what the user typed after the click is never lost. The page recorded their registry
//        entry at the click (`beginStructuralOp` / `finalizeStructuralOpPostOpDoc`: the checkpoint state, the pre-op and post-op
//        documents), which is all `markdownStructuralSwap` needs;
//    (b) an editor-first Markdown Delete or Duplicate entry whose quick path is not open (the structural generation moved, ...). A
//        Duplicate's redo here is the page's plain composed redo (`markdownStructuralSwap(opId, 'redo')`, no request), as the quick
//        redo's.
//
//  THE PRESS (`markdownQueuedSnapshotUndo`), called by `queuedSnapshotUndo` for a Markdown session, under the structural gate, with the
//  snapshot to swap in already resolved by `performUndo` / `performRedo`:
//    1. nil (the OLD body runs, unchanged) for anything this route cannot do: zoomed, no page, no writer for the project, a lifecycle
//       armed, the legacy test flags, a snapshot with no blocks;
//    2. the previous Markdown job's apply is awaited (`awaitStructuralHoldReleased`, A7; no notice of its own: the "Undoing…" or
//       "Redoing…" toast of `performUndo` / `performRedo` covers the whole press), then this press raises its OWN hold with the
//       `defer` + hand-off discipline of the click and the quick undo, and the rebuild stamp moves (`editorFirstClickGeneration`,
//       `pendingEditorFirstJobs`, which the job takes over);
//    3. ONE call into the page, `markdownStructuralSwap(opId, 'undo'|'redo')`: undo = `setState(checkpoint)` with the live redo branch
//       carried over; redo = the saved post-op text swapped in as a minimal diff (an entry the old body recorded) or the command run
//       again with a FRESH request built from the rows as they are now (an editor-first Delete, `sendMarkdownDeleteWithRetry`, the quick
//       redo's own call). Typing done while the press waited is NOT a refusal (t-d2061b27): the page checks the document AS IT WAS AT THE
//       PRESS, swaps, and puts the typing back on top (`typingReplayed: true` in the reply; `preRaw` is then the document at the press,
//       so the typing batch below finds nothing new, and step 8's live read saves the typing, once). A refusal (`changed`, `noEntry`,
//       `midOp`, `unplaceable`: something that is not typing changed the document in the wait, the entry is gone, or a typed step has
//       no place in the target document) changes nothing on the screen: the existing notice "Some undo or redo presses could not be
//       carried out.", one fresh settle, `failed`; the typing stays;
//    4. the reply turn, with no suspension after the writer's last write has been awaited: the typing batch up to the swap
//       (`prepareStructuralClick`), `noteQueuedStructuralJob`, the swapped-in text adopted (`adoptMarkdownPageText`), the sidebar swap
//       (`showRestoreInSidebar`, the plan's leaders), a gate under the job's fresh key, and the job itself:
//       `StructuralReplaceJob(kind: .snapshotUndo / .snapshotRedo)` from the plan the EXISTING code reads from the snapshot
//       (`readSwapPlan`). The plan's Markdown text is not needed: the page swap has restored the editor, the job writes the rows;
//    5. the hold goes to the step-8 continuation keyed by the job's key (`swapsBackOnFailure: false`: a failed swap job cannot swap the
//       page back; the flush writes the page's text into the rows, so the editor and the rows agree), and the timeline moves
//       (`moveEntryAfterSwap`, which also closes the quick path for the entry); when the page put typing back on top
//       (`typingReplayed`), that typing then ends the redo branch (`endRedoAfterReplayedTyping`), still inside the gate.
//
//  NO `structuralOutOfQueueGeneration` BUMP (the R5 point): the old body bumped it on every undo, which closed the quick path of EVERY
//  other entry; this route writes through the queue (non-stamping `replaceProjectRows`) and touches nothing the other entries' quick
//  undos depend on.
//

import Foundation

extension StructuralUndoController {

    /// The slow undo (`direction` `.undo`) or redo (`.redo`) of a Markdown entry, editor first. nil: the press takes the old body.
    func markdownQueuedSnapshotUndo(entry: StructuralEntry, direction: UndoDirection, snapshotId: String) async -> UndoResult? {
        #if DEBUG
        if testForceLegacyStructural { return nil }
        #endif
        guard !TestMode.isUITestingLegacyStructural, let editorState, let unifiedUndoService, let blockSync = blockSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, activeWebView != nil,
              editorState.editorMode == .source, editorState.zoomedSectionId == nil, editorState.markdownWriter.isEnabled,
              editorState.activeLifecycle == nil, blockSync.writer?.database === db, blockSync.writer?.projectId == pid else { return nil }
        let isUndo = direction == .undo
        let kind: EditorFirstOpKind = isUndo ? .snapshotUndo : .snapshotRedo
        let opId = entry.id
        let label = isUndo ? "undo" : "redo"
        let writer = editorState.markdownWriter
        let timelineEpoch = unifiedUndoService.generation

        // A7: the previous Markdown job (a delete, a reinsert, another swap) finishes first; its step 8 has saved the typing. No notice of
        // its own here (review DR-2): this route only runs inside `performUndo` / `performRedo`, whose "Undoing…" / "Redoing…" toast
        // belongs to the whole press from its first line, and a second delayed toast would replace it and leave the slot empty when it
        // stopped. One notice per press.
        await writer.awaitStructuralHoldReleased()
        // UI-test seam FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS (see TestMode; the Rich Text slow route has the same one): widens the wait in
        // which the user can type between the press and the page's swap. It stands for the wait above, so it sits BEFORE the guards that
        // follow a real wait: a close, quit or switch that begins during it cancels the press exactly as it cancels one that waited for a
        // job (review F15). Before this press raises its own writer hold, so it is a plain suspension of the gate turn. No wait when off.
        await TestMode.holdSlowUndoPress(opId: String(entry.id.uuidString.prefix(8)))
        if editorState.structuralGate.isClosedToNewWork { return .cancelled }
        guard editorState.activeLifecycle == nil, editorState.editorMode == .source, editorState.zoomedSectionId == nil,
              unifiedUndoService.generation == timelineEpoch else { return nil }
        // The plan: the rows the job will write, read now that the previous job has applied (ids prepared against the rows in the table).
        guard let plan = readSwapPlan(snapshotId: snapshotId, kind: kind, database: db, projectId: pid) else { return nil }
        let trace = StructTrace(label: label, opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: label, opId: trace.opId)
        trace.log("start (markdown queued \(label)) rows=\(plan.rows.count)")

        let hold = writer.beginStructuralHold()
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }
        // D6: the rebuild stamp moves before the page is touched; the job takes the pending count over.
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true
        await prepareMarkdownPageForStructuralCommand()

        // The one page call. The redo of an editor-first Markdown Delete re-runs the delete on the document as it is NOW, so it carries a
        // FRESH request built from the rows as they are now (review M-3), exactly as the quick redo does; the request the page stored
        // at the click can be stale by now (a heading line or level changed since) and would be refused as `leadersMismatch`. If a fresh
        // request cannot be built the press is refused: there is no second fallback to the stored request.
        let reply = await sendMarkdownSlowSwap(entry: entry, isUndo: isUndo, database: db, projectId: pid)
        guard let reply, reply.succeeded, let preRaw = reply.preRaw, let postRaw = reply.postRaw else {
            return refuseMarkdownSlowSwap(opId: opId, label: label, trace: trace, run: &run)
        }

        // The reply turn.
        while let pending = writer.inFlight { await pending.value }
        writer.prepareStructuralClick(
            text: MarkdownLeaderMap.recordText(fromRaw: preRaw), database: db, projectId: pid, service: blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        writer.noteQueuedStructuralJob()
        editorState.adoptMarkdownPageText(postRaw)   // O11/O25: the swapped-in text is the record; nothing is pushed back
        showRestoreInSidebar(opId: opId, plan: plan)
        let jobKey = UUID()
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[jobKey] = gate
        run.countHandedToJob = true   // the job's task brings `pendingEditorFirstJobs` down once its future has resolved
        let reserved = startSnapshotSwapJob(
            opId: opId, kind: kind, plan: plan, removedLeaders: Set(plan.previousLeaders.map(\.id)), database: db, projectId: pid,
            jobKey: jobKey)
        run.handedOff = true
        if reserved {
            startMarkdownHoldContinuation(hold: hold, opId: opId, jobKey: jobKey, swapsBackOnFailure: false)
        } else {
            // No job will run, so no step 8 would flush: the flush alone makes the rows match the swapped-in page.
            DebugLog.alwaysPersisted("[StructuralUndoController] markdown queued \(label) \(opId): the job could not be reserved")
            await runMarkdownStep8(opId: opId, jobKey: jobKey, hold: hold, outcome: .failed("swap job not reserved"), swapsBackOnFailure: false)
        }
        spy("markdownSlowSwapReserved")
        return await moveMarkdownSlowEntryAndEndRedoBranch(
            opId: opId, kind: kind, timelineEpoch: timelineEpoch, typingReplayed: reply.typingReplayed, trace: trace)
    }

    /// The page refused the press (an extraction of `markdownQueuedSnapshotUndo`'s refusal branch: it keeps the order of the statements;
    /// the result changes as intended, review F18: when the window is closing, the gate being closed to new work, the refusal is silent
    /// and the reply is `.cancelled`, not the notice and `.failed`).
    /// R5: the editor is as it was (something that is not typing changed the document while the press waited, a typed step could
    /// not be placed in the target document, or the entry is gone): the entry stays where it is, any typing stays, the press is
    /// answered `failed` with the existing notice, one fresh settle puts back the steps.
    private func refuseMarkdownSlowSwap(opId: UUID, label: String, trace: StructTrace, run: inout MarkdownDeleteRun) -> UndoResult {
        trace.log("refused (markdown queued \(label)) by the page")
        run.countHandedToJob = true   // released here, not by the defer
        releasePendingEditorFirstJob()
        startFreshSettleAfterRefusedEditorFirstClick(opId: opId)
        // Review F18: a press made while the project is being saved shows nothing (UX contract 4.2); `.cancelled` then, as the
        // other exits of this route answer a barrier.
        let closed = editorState?.structuralGate.isClosedToNewWork ?? false
        if !closed { showUndoQueueDroppedWarning() }
        rearmMarkdownReparseAfterRefusedPress()   // F2: the typing made during the wait reaches the rows
        return closed ? .cancelled : .failed
    }

    /// The timeline step that ends the route (a mechanical extraction of `markdownQueuedSnapshotUndo`'s tail): the entry moves, and
    /// t-d2061b27: typing done while the press waited was put back on top of the swapped-in text by the page; it ends the redo branch,
    /// inside the gate, after the entry has moved (StructuralUndoController+TypingAcrossUndo.swift).
    private func moveMarkdownSlowEntryAndEndRedoBranch(
        opId: UUID, kind: EditorFirstOpKind, timelineEpoch: Int, typingReplayed: Bool?, trace: StructTrace
    ) async -> UndoResult {
        let result = await moveEntryAfterSwap(opId: opId, kind: kind, timelineEpoch: timelineEpoch, trace: trace)
        if result == .performed { await endRedoAfterReplayedTyping(typingReplayed, opId: opId, trace: trace) }
        return result
    }

    /// The slow route's one page call. The redo of an editor-first Markdown Delete carries a FRESH request built from the rows as they
    /// are now (review M-3), as the quick redo does; if none can be built (no holder, the root heading cannot be found again) the
    /// answer is nil and the press is refused. Every other swap (an undo, the redo of an entry the old body recorded, the redo of an
    /// editor-first Duplicate, which the page composes by itself) sends no request.
    ///
    /// The root is found in the CURRENT rows through a `RootReference` taken from the rows the delete job saw: the slow undo that
    /// preceded this redo put the section back by replacing the project's rows with a snapshot's, which gives the section's rows FRESH
    /// ids, so the id the Delete clicked on (`holder.rootId`) names no row now and a request built on it would not exist.
    private func sendMarkdownSlowSwap(
        entry: StructuralEntry, isUndo: Bool, database: ProjectDatabase, projectId: String
    ) async -> MarkdownStructuralReply? {
        let opId = entry.id
        guard !isUndo, entry.kind == .sectionDelete, efEditorKind[opId] == .markdown else {
            let reply = await sendMarkdownSwap(opId: opId, direction: isUndo ? "undo" : "redo")
            noteMarkdownSlowSwap(
                "plain swap, no request: ok=\(reply.map { String($0.succeeded) } ?? "no answer") reason=\(reply?.reason ?? "-")")
            return reply
        }
        guard let holder = efHolders[opId], holder.outcome == .applied,
              let reference = MarkdownLeaderMap(rows: holder.snapshot().preDeleteRows).rootReference(of: holder.rootId) else {
            noteMarkdownSlowSwap("no root reference: the delete's rows are not recorded")
            return nil
        }
        let attempt = await sendMarkdownDeleteWithRetry(
            opId: opId, rootId: holder.rootId, rootReference: reference, redo: true, database: database, projectId: projectId)
        noteMarkdownSlowSwap(
            attempt.map { "the page answered ok=\($0.reply.succeeded) reason=\($0.reply.reason ?? "-") detail=\($0.reply.detail ?? "-")" }
                ?? "no request could be built for the root heading \"\(reference.line)\", or the page did not answer")
        return attempt?.reply
    }

    /// What the last Markdown slow redo's page call came to, for the log and (DEBUG) for a test's failure message.
    private func noteMarkdownSlowSwap(_ note: String) {
        DebugLog.log(.undo, "[StructuralUndoController] markdown slow redo: \(note)")
        #if DEBUG
        testLastMarkdownSlowSwapNote = note
        #endif
    }
}
