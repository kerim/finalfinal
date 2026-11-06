//
//  StructuralUndoController+MarkdownEditorFirstReorder.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 2 (the Outline sidebar's drag-reorder in Markdown mode), round 3a:
//  the Swift click (plan v2 "Round 3", plan v2.1 addendum A3). It is the Markdown Delete's twin (StructuralUndoController+MarkdownEditorFirst.swift)
//  with the Rich Text reorder's job (StructuralUndoController+EditorFirstReorder.swift): the PAGE moves the section's text in one CodeMirror
//  transaction (`window.FinalFinal.markdownStructuralReorder`, web/codemirror/src/api-structural-markdown-reorder.ts), taking the typing so
//  far and the caret with it; Swift adopts the page's text (never pushes it back), shows the new order in the sidebar overlay, and queues
//  the existing `SectionReorderJob` under the Markdown writer's hold. Step 8 (+MarkdownSettle.swift) flushes behind it and the shared
//  settle renumbers the footnotes.
//
//  THE CLICK, in order (`performSectionReorderDetailed` calls `performEditorFirstReorder`, which hands a Markdown press here under the
//  structural gate; a nil return falls through to the old whole-document body in the same gate turn):
//    1. guards, as the Delete has them, plus `MarkdownEditorFirstSwitch.enabled`. The dragged root is checked by the request builder
//       against the rows AFTER step 2 (a leader that is neither Notes nor Bibliography), not before the wait;
//    2. await the earlier command's hold (`awaitStructuralHoldReleased`), with the delayed "Finishing the last change…" toast;
//    3. re-check `activeLifecycle == nil`;
//    4. take the hold, with the `defer` that releases it (and the pending count) on every exit that did not hand them on (O7);
//    5. raise `editorFirstClickGeneration` and `pendingEditorFirstJobs`; `run.countRaised`;
//    6. `prepareMarkdownPageForStructuralCommand` (the pending re-parse is cancelled, the boundary hygiene);
//    7. allocate the `opId`; `efOpEpoch[opId] = 1` BEFORE the page call (the job reads it as `epochAtClick`); every nil return before
//       the job starts clears it again (A3 b);
//    8. the page call, with the `leadersMismatch` flush-and-retry once (a heading typed or renamed a moment ago). `rootNotFound`,
//       `planMismatch`, `managedMoved`, a second mismatch, a JavaScript error: nil (the old body runs; a refusal changed nothing; the
//       page's live text is adopted into the content record first, because the old body flushes the record, which lags the page);
//    9. the reply turn, one synchronous stretch after the writer's last write is awaited: the typing batch up to the click
//       (`prepareStructuralClick`), `noteQueuedStructuralJob`, `adoptMarkdownPageText(postRaw)` (O11), the sidebar overlay
//       (`showReorderInSidebar`, with the page's `skippedIds`), the step-8 gate, the job (`startEditorFirstReorderJob`). ONLY when the
//       job reserved its place is the hold handed to `startMarkdownHoldContinuation`, in the same synchronous turn (O21); otherwise
//       the gate is finished and the `defer` releases the hold (A3 c);
//   10. the timeline-generation check against the epoch captured before the reply turn (A3 a); `efRecordedGeneration`; the entry
//       `StructuralEntry(.sectionReorder, "Reorder Sections")`; the descriptor. NO bump of `structuralOutOfQueueGeneration` and NO
//       `efRecordedStructGeneration` (that is why an earlier Delete stays quick-undoable after a drag; `quickPathPossible` refuses the
//       kind before it looks at either);
//   11. a nil return re-posts the Notes and Bibliography rebuilds a skipped push owed, AFTER the hold is released (O20).
//
//  TRACE (the real-app tests assert these): the Swift sequence `[STRUCT-TRACE] ... sectionReorder op=<id8> start (editor-first) mode=markdown`
//  (a plain `start` is the old body), then on a successful page reply `[STRUCT-TRACE] reorder-editor-first opId=<id8> ok=true mode=markdown
//  skipped=<n> levels=<n>` (the line the Rich Text editor writes for its own reorder, here with `mode=markdown`), then `performed`; or
//  `fell back to the old sequence (...)` when the page declined.
//

import Foundation
import WebKit

extension StructuralUndoController {

    /// What the click knows about the drop it is carrying out.
    private struct MarkdownReorderClick {
        let opId: UUID
        let rootId: String
        /// The finished plan: every section leader in final order, Notes and Bibliography last.
        let plan: [SectionViewModel]
        /// Heading id -> new level, for the headings the plan re-levelled.
        let changedLevels: [String: Int]
    }

    /// Drag-reorder, Markdown, editor first. Called under the structural gate with the FINISHED plan (`performEditorFirstReorder`
    /// dispatches here when the editor is in Markdown mode). Returns nil, having changed nothing the old body cannot cope with, when this
    /// press has to take today's whole sequence; otherwise the outcome the sidebar reports.
    func performMarkdownEditorFirstReorder(plan: [SectionViewModel], changedLevels: [String: Int], rootId: String) async -> StructuralOpOutcome? {
        guard MarkdownEditorFirstSwitch.enabled else { return nil }
        let outcome = await runMarkdownEditorFirstReorder(plan: plan, changedLevels: changedLevels, rootId: rootId)
        // O20: the click is over and its `defer` has released the hold. A rebuild whose push the click's stamp skipped has left the
        // Notes and Bibliography as they were; with no job coming to put them in, they are re-posted before the old body runs.
        if outcome == nil, let editorState, editorState.managedRegionsNeedRepush {
            editorState.managedRegionsNeedRepush = false
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        }
        return outcome
    }

    private func runMarkdownEditorFirstReorder(
        plan: [SectionViewModel], changedLevels: [String: Int], rootId: String
    ) async -> StructuralOpOutcome? {
        // Step 1: the guards (the Delete's, minus its root check and its delete-only legacy flag; the Rich Text dispatcher has already
        // handled the UI-test legacy flag and the DEBUG force-legacy seam).
        guard let editorState, let unifiedUndoService, let blockSync = blockSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, activeWebView != nil,
              editorState.editorMode == .source, editorState.zoomedSectionId == nil, editorState.markdownWriter.isEnabled,
              editorState.activeLifecycle == nil,
              blockSync.writer?.database === db, blockSync.writer?.projectId == pid else { return nil }
        let writer = editorState.markdownWriter

        // The notice (UX contract 4.2: "Finishing the last change…" past one second). t-2fbe4c9b: ONE notice belongs to the whole click,
        // as for Duplicate: counted from the drop, it stays through the page wait below, the hold wait, the page call and the reply turn,
        // and the `defer` takes it down (`stop()` is idempotent) on every way out.
        let waiting = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { waiting.stop() }

        // t-633df056 (Phase 5 job A5): a drop right after View > Switch to Markdown, before the new page is mounted, waits for the page
        // here, before the click begins; a timed-out wait or a mode that changed gives it to the old body, as before.
        guard await awaitMarkdownPageForStructuralCommand(label: "editor-first reorder") else { return nil }

        // Round M1 measurement (MdSpeed.swift): the drag's timeline starts at the DROP (`ContentView.reorderSection` calls `beginOp`), so
        // nothing is begun here; `noteOpId` below gives it the op's short id. This mark says the gate turn reached the Markdown click.
        MdSpeed.mark("entered")
        let clickSpan = MdSpeed.span("click")
        defer { clickSpan.end() }

        // Step 2: an earlier Markdown command finishes saving first. Held, never refused; past one second the notice above shows.
        let holdWaitSpan = MdSpeed.span("holdWait")
        await writer.awaitStructuralHoldReleased()
        holdWaitSpan.end()

        // Step 3: the wait can span a lifecycle or a zoom (zoom is not on the structural gate): the page then holds the zoomed text, which
        // this click must not move; the old body, which knows the zoomed state, gets the press.
        guard editorState.activeLifecycle == nil, editorState.zoomedSectionId == nil else { return nil }

        // Step 4 (O7): the hold, and the `defer` that releases it on every early exit.
        let hold = writer.beginStructuralHold()
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }

        // Step 5: the rebuild stamp moves in this synchronous stretch (a rebuild that read before the click is stale).
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true

        // Step 6.
        await prepareMarkdownPageForStructuralCommand()

        // Step 7 (A3 b): the per-op epoch starts at the click; every nil return before the job starts clears it again.
        let opId = UUID()
        efOpEpoch[opId] = 1
        let click = MarkdownReorderClick(opId: opId, rootId: rootId, plan: plan, changedLevels: changedLevels)
        let trace = StructTrace(label: "sectionReorder", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.noteOpId(trace.opId)   // round M1: the timeline began at the drop (`reorderSection`), so only the id is given here
        trace.log("start (editor-first) mode=markdown")

        // Step 8: the page call, with the leadersMismatch flush-and-retry once.
        let reply = await sendMarkdownReorderWithRetry(click, database: db, projectId: pid)
        guard let reply, reply.succeeded, let preRaw = reply.preRaw, let postRaw = reply.postRaw else {
            efOpEpoch[opId] = nil
            let why = reply?.reason ?? "no answer"
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown editor-first reorder: the page refused or failed (\(why)) -- old path for this press")
            trace.log("fell back to the old sequence (the page refused or failed: \(why))")
            await adoptPageTextForTheOldBody(editorState)
            return nil
        }
        let skippedIds = reply.skippedIds ?? []
        DebugLog.log(
            .undo,
            "[STRUCT-TRACE] reorder-editor-first opId=\(trace.opId) ok=true mode=markdown skipped=\(skippedIds.count) levels=\(changedLevels.count)")

        // Step 9 (A3 a): the epoch is captured before the reply turn; the reply turn is one synchronous stretch.
        let epoch = unifiedUndoService.generation
        let context = MarkdownJobContext(editorState: editorState, blockSync: blockSync, database: db, projectId: pid)
        await markdownReorderReplyTurn(
            click, skippedIds: Set(skippedIds), preRaw: preRaw, postRaw: postRaw, context: context, hold: hold, run: &run)

        // Step 10: the entry. Nothing here touches `structuralOutOfQueueGeneration` or `efRecordedStructGeneration`.
        guard unifiedUndoService.generation == epoch else {
            DebugLog.log(.undo, "[StructuralUndoController] markdown editor-first reorder: timeline generation changed mid-click -- not recording")
            trace.log("timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efEditorKind[opId] = .markdown
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionReorder, title: "Reorder Sections", undoSnapshotId: nil))
        spy("efRecorded")
        let descriptorSpan = MdSpeed.span("pushDescriptor")
        await pushDescriptor()
        descriptorSpan.end()
        trace.log("performed")
        return .performed
    }

    /// The press goes to the old body. That body flushes the content RECORD, which lags the page by the page's own debounce (a heading edit
    /// typed while the retry waited for its flush is not in it yet), and then pushes the rows' text over the page: the edit would be lost.
    /// The page's live text becomes the record first, as the retry's own flush does. Nothing is changed on the page.
    func adoptPageTextForTheOldBody(_ editorState: EditorViewState) async {   // internal: the Delete's nil exit calls it too
        if let raw = await evalString("window.FinalFinal.getContentRaw()") { editorState.adoptMarkdownPageText(raw) }
    }

    // MARK: - The page call

    /// One call of `markdownStructuralReorder`, the request built from the rows as they are now. nil: the rows cannot be read, the root
    /// is no draggable leader, or the page did not answer with readable JSON (a JavaScript error).
    private func sendMarkdownReorder(
        _ click: MarkdownReorderClick, database: ProjectDatabase, projectId: String
    ) async -> MarkdownStructuralReply? {
        guard let rows = try? MdSpeed.timed("fetchBlocks", { try database.fetchBlocks(projectId: projectId) }) else { return nil }
        let map = MdSpeed.timed("leaderMap") { MarkdownLeaderMap(rows: rows) }
        guard let json = MdSpeed.timed("requestJson", {
            map.reorderRequest(opId: click.opId, rootId: click.rootId, order: click.plan.map(\.id), changedLevels: click.changedLevels)?.json
        }) else { return nil }
        let pageCallSpan = MdSpeed.span("pageCall")
        let answer = await evalString("JSON.stringify(window.FinalFinal.markdownStructuralReorder(\(json)))")
        pageCallSpan.end("chars=\(answer?.utf16.count ?? 0)")
        guard let answer else { return nil }
        let decodeSpan = MdSpeed.span("replyDecode")
        let reply = answer.data(using: .utf8).flatMap { try? JSONDecoder().decode(MarkdownStructuralReply.self, from: $0) }
        decodeSpan.end()
        return reply
    }

    /// The page call with the B1 flush-and-retry once, as the Delete's (`sendMarkdownDeleteWithRetry`): a leader the page found does not
    /// match the rows (a heading typed or renamed a moment ago), so the typing is flushed and the call is made once more. A stale root
    /// (`rootNotFound`) is NOT retried: the old body is given the press. nil: no usable answer.
    private func sendMarkdownReorderWithRetry(
        _ click: MarkdownReorderClick, database: ProjectDatabase, projectId: String
    ) async -> MarkdownStructuralReply? {
        var reply = await sendMarkdownReorder(click, database: database, projectId: projectId)
        if reply?.reason == "leadersMismatch" {
            guard await flushTypingForMarkdownRetry(projectId: projectId) else { return nil }
            reply = await sendMarkdownReorder(click, database: database, projectId: projectId)
        }
        return reply
    }

    // MARK: - The reply turn

    /// Step 9: the writer's last write is awaited, then in ONE synchronous stretch the typing batch up to the click
    /// (`prepareStructuralClick`, never a whole-document write), `noteQueuedStructuralJob`, the page's text adopted into the content
    /// record (`adoptMarkdownPageText`, O11), the sidebar overlay, the step-8 gate (made BEFORE the job starts: the settle may reach it
    /// at once) and the job through `startEditorFirstReorderJob`. Once the starter has returned true the hold is HANDED OFF in the same
    /// synchronous turn (O21): a continuation Task takes it and releases it in its own `defer`. When the job did not reserve its place
    /// there is no continuation: the gate is finished and the click's `defer` releases the hold (A3 c).
    private func markdownReorderReplyTurn( // swiftlint:disable:this function_parameter_count
        _ click: MarkdownReorderClick, skippedIds: Set<String>, preRaw: String, postRaw: String, context: MarkdownJobContext,
        hold: MarkdownStructuralHold, run: inout MarkdownDeleteRun
    ) async {
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        let replyTurnSpan = MdSpeed.span("replyTurn")   // round M1 measurement: the whole reply turn, and each step inside it
        defer { replyTurnSpan.end() }
        // t-2fbe4c9b trigger (iii): the parse memo prepares the post-click text in the background while the wait below runs; step 8 reads it.
        writer.prewarmParse(raw: postRaw, projectId: context.projectId, database: context.database)
        // What the sidebar shows at once: the planned order with the ids the page held no leader for taken out of the job's order. The
        // page has already moved, so this comes BEFORE the wait for the writer's last write (it can sit behind a book-length typing batch
        // or the previous command's flush for hundreds of ms: the card would snap back and sidebar and page would disagree). It needs
        // only the plan, the levels and the page's skippedIds; the put-back lifts it if the job fails.
        let sidebarSpan = MdSpeed.span("sidebar")
        let working = showReorderInSidebar(
            opId: click.opId, plan: click.plan, changedLevels: click.changedLevels, skippedIds: skippedIds)
        sidebarSpan.end()
        let inFlightSpan = MdSpeed.span("inFlightWait")
        while let pending = writer.inFlight { await pending.value }
        inFlightSpan.end()
        let preText = MdSpeed.timed("recordText.pre") { MarkdownLeaderMap.recordText(fromRaw: preRaw) }
        let prepareClickSpan = MdSpeed.span("prepareStructuralClick")
        writer.prepareStructuralClick(
            text: preText, database: context.database, projectId: context.projectId,
            service: context.blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        prepareClickSpan.end()
        writer.noteQueuedStructuralJob()
        let adoptSpan = MdSpeed.span("adopt")
        editorState.adoptMarkdownPageText(postRaw)   // O11: the record takes the page's text in this turn; nothing is pushed back
        adoptSpan.end()

        run.countHandedToJob = true   // the job's task brings `pendingEditorFirstJobs` down once its future has resolved
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[click.opId] = gate
        efEditorKind[click.opId] = .markdown
        let jobStartSpan = MdSpeed.span("jobStart")
        let reserved = await startEditorFirstReorderJob(
            opId: click.opId, rootId: click.rootId, leaderIds: working.leaderIds, levels: working.levels,
            database: context.database, projectId: context.projectId, ownsPendingJobCount: true)
        jobStartSpan.end()
        // O21: the hand-off is the same synchronous turn as the starter's return, no `await` in between.
        if reserved {
            run.handedOff = true
            let handOffSpan = MdSpeed.span("holdHandOff")
            startMarkdownHoldContinuation(hold: hold, opId: click.opId)
            handOffSpan.end()
        } else {
            gate.finish()   // no continuation will run step 8
        }
    }
}
