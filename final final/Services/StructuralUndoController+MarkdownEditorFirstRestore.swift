//
//  StructuralUndoController+MarkdownEditorFirstRestore.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 4: the three Version History restores (Restore Entire Project,
//  Replace Current Section, Insert as New Section) as editor-first commands in Markdown mode (plan-v1 D1 to D9, plan-v1-addendum; the
//  page's side is docs/architecture/write-queue-plan/phase4b-markdown/slice4-restores/page-contract.md). Today a Markdown restore writes
//  the database first and then pushes the whole document into the page (`setContent`): that push wipes typing, carries no section
//  markers (the Outline card click lands far away) and its Cmd-Z takes the slow "Undoing…" route. This click swaps the restored text into
//  the page in ONE CodeMirror transaction instead, and queues the Rich Text `StructuralReplaceJob` behind everything typed. Nothing is
//  pushed back over the page. It is the Duplicate's click (StructuralUndoController+MarkdownEditorFirstDuplicate.swift) with the
//  Rich Text restore's plan, job and sidebar.
//
//  THE IDEA: the plan's rows already carry the ids the job will write (`SnapshotService.wholeRestorePlan`, `sectionReplacePlan`,
//  `insertAfterPlan`). Swift writes them into the restored text as `<!-- @sid:ID -->` markers (`RestorePlan.markdownPageText`) BEFORE it
//  calls the page, so page text and rows name the same ids from the first moment.
//
//  THE CLICK (`performMarkdownEditorFirstRestore`, under the structural gate, called by the three `performEditorFirst…Restore…` functions
//  after their notice and their zoom-out):
//    1. guards: the kill switch, Markdown mode, a web view, the writer, no lifecycle, not zoomed. A nil return takes the old body;
//    2. await the earlier command's hold (`awaitStructuralHoldReleased`), THEN look again at the lifecycle, the zoom and the mode. The
//       ROWS ARE READ ONLY AFTER THIS WAIT (a restore pressed right after a Delete must see the rows the Delete's job left): the caller
//       hands a plan BUILDER, which runs below. The delayed "Finishing the last change…" notice is the perform function's own
//       (`DelayedProgressToast` at the top of each; it spans zoom-out, wait, page call and reply turn): this click makes no second one;
//    3. the hold, the TIMELINE EPOCH (`unifiedUndoService.generation`, read right after the hold goes up, as the Rich Text click reads it
//       before its click: a barrier that lands anywhere in the click is noticed when the entry is recorded), the click generation and
//       the pending-jobs count (the `defer` releases them on every exit that did not hand them on);
//    4. the pending re-parse is cancelled and the boundary hygiene is made (`prepareMarkdownPageForStructuralCommand`);
//    5. the plan is built (`build`), the leader map and the request made from the rows as they are then, ONE call into the page,
//       `markdownStructuralRestore(request)`. On `leadersMismatch` the typing is flushed and the call is made once more FROM A REBUILT
//       PLAN; any other refusal, a JavaScript error or no answer adopts the page's live text into the record and returns nil;
//    6. the reply turn (`markdownRestoreReplyTurn`, shared with the quick redo): the writer's last write is awaited, then in one
//       synchronous stretch the typing batch up to the click (when the writer reserves one: see the reply turn), the page's text adopted,
//       the plan and the sidebar, the step-8 gate and the job; only when the job reserved its place is the hold handed to the step-8
//       continuation, otherwise the click lets the hold go before it records the entry;
//    7. the entry, recorded HERE and only here (`recordRestoreEntry`): the reply turn never records, so a quick redo records nothing.
//       NO bump of `structuralOutOfQueueGeneration` (only the old body bumps it): an earlier Delete stays quick-undoable.
//
//  THE UNDO AND REDO of the entry are the Markdown quick route (+MarkdownQuickUndo.swift): the undo swaps the pre-op state back in and
//  the reinsert makes the rows equal "the rows before the op"; the redo asks the page for its composed redo (`markdownStructuralSwap(opId,
//  'redo')`, no request) and runs `markdownRestoreReplyTurn` again with the FIRST plan, so the same ids come back on every cycle.
//
//  TRACE (for the real-app tests): `[STRUCT-TRACE] <restoreProject|restoreSectionReplace|restoreSectionDuplicate> op=<id8> start
//  (editor-first) mode=markdown`, then on a successful page reply `…-editor-first opId=<id8> ok=true mode=markdown rows=<n>`, then
//  `performed`; or `fell back to the old sequence (...)`.
//

import Foundation
import WebKit

// MARK: - What the caller's plan builder came to

/// The answer of the plan BUILDER a perform function hands to `performMarkdownEditorFirstRestore`. The builder runs after the hold wait
/// (the rows must be read then) and again after a flush-and-retry, so it never keeps rows between two calls.
enum MarkdownRestoreBuild {
    /// The plan, and the id the page is told as `rootId`: the target heading of a section restore, the anchor leader (a heading) of an
    /// Insert as New Section, nil for a whole restore or an insert with no anchor.
    case ready(RestorePlan, rootId: String?)
    /// The press takes the old restore (the builder has logged why).
    case legacy
    /// The version no longer exists: the old restore's own precheck refusal.
    case refused
}

/// The page's answer to `markdownStructuralRestore` (web/codemirror/src/api-structural-markdown-restore.ts `MarkdownRestoreResult`). Only
/// the fields Swift reads (the page's `replaced` hull is not read: the decoder ignores it). `preRaw` and `postRaw` are the same two fields
/// the Delete's and the Duplicate's replies carry; `detail` goes into the fall-back log; `insertedLeaderIds` is a CROSS-CHECK for the
/// overlay Swift builds from the plan (the plan is authoritative).
struct MarkdownRestoreReply: Decodable, Equatable {
    let succeeded: Bool
    let reason: String?
    let detail: String?
    let preRaw: String?
    let postRaw: String?
    /// The `<!-- @sid:ID -->` markers the page found at the start of a line of the request's `text`, in order.
    let insertedLeaderIds: [String]?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case reason
        case detail
        case preRaw
        case postRaw
        case insertedLeaderIds
    }
}

extension StructuralUndoController {

    /// One page call's result.
    private enum MarkdownRestoreCall {
        case answered(MarkdownRestoreReply, RestorePlan)
        case legacy
        case refused
        /// The rows could not be read or no request could be built for the plan (a root that is no leader of these rows).
        case noRequest
        /// The page did not answer with readable JSON (a JavaScript error), or the retry's flush failed.
        case noAnswer
    }

    /// Whether this press takes the Markdown editor-first restore: Markdown mode with a page and a writer, the kill switch on, and neither
    /// the DEBUG switch nor the UI-test legacy flag asking for today's restore. The tests that pin the OLD Markdown restore body set
    /// `testForceLegacyStructural` (a fixture with no web view reaches the old body by itself).
    var takesTheMarkdownEditorFirstRestorePath: Bool {
        #if DEBUG
        if testForceLegacyStructural { return false }
        #endif
        guard MarkdownEditorFirstSwitch.enabled, !TestMode.isUITestingLegacyStructural, let editorState,
              editorState.editorMode == .source, activeWebView != nil, editorState.markdownWriter.isEnabled else { return false }
        return true
    }

    /// A Version History restore, Markdown, editor first. Called under the structural gate with the notice and the zoom-out already made.
    /// Returns nil, having changed nothing the old body cannot cope with, when this press has to take today's whole sequence (the switch
    /// is off, a lifecycle, a target or a version the editor-first path cannot take, a page that refused); `.refused` when the version no
    /// longer exists; otherwise the outcome the Version History window reports.
    func performMarkdownEditorFirstRestore(kind: EditorFirstOpKind, build: () async -> MarkdownRestoreBuild) async -> StructuralOpOutcome? {
        guard MarkdownEditorFirstSwitch.enabled else { return nil }
        #if DEBUG
        if testForceLegacyStructural { return nil }
        #endif
        let outcome = await runMarkdownEditorFirstRestore(kind: kind, build: build)
        guard outcome == nil || outcome == .refused else { return outcome }
        // The click is over and its `defer` has released the hold. The click cancelled the pending re-parse
        // (`prepareMarkdownPageForStructuralCommand`); the old body (or the refusal) follows, so the re-parse is scheduled again from the
        // record, and (O20, as the Delete and the Duplicate) a rebuild whose push the click's stamp skipped has left the Notes and
        // Bibliography as they were: with no job coming to put them in, they are re-posted.
        rearmMarkdownReparseAfterRefusedPress()
        if let editorState, editorState.managedRegionsNeedRepush {
            editorState.managedRegionsNeedRepush = false
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        }
        return outcome
    }

    private func runMarkdownEditorFirstRestore(kind: EditorFirstOpKind, build: () async -> MarkdownRestoreBuild) async -> StructuralOpOutcome? {
        // Step 1: the guards.
        guard let editorState, let unifiedUndoService, let blockSync = blockSyncService, let sectionSync = sectionSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, activeWebView != nil,
              editorState.editorMode == .source, editorState.zoomedSectionId == nil, editorState.markdownWriter.isEnabled,
              editorState.activeLifecycle == nil, !TestMode.isUITestingLegacyStructural,
              blockSync.writer?.database === db, blockSync.writer?.projectId == pid else { return nil }
        let writer = editorState.markdownWriter

        // Step 2: an earlier Markdown command finishes saving first. Held, never refused (the perform function's notice covers the wait).
        await writer.awaitStructuralHoldReleased()
        guard editorState.activeLifecycle == nil, editorState.zoomedSectionId == nil, editorState.editorMode == .source else { return nil }

        // Step 3: the hold, and the `defer` that releases it on every early exit. Nothing between the wait's return and this line suspends.
        let hold = writer.beginStructuralHold()
        // The timeline epoch of THIS click: read before anything below suspends, so a barrier (`invalidateAll`, which also clears the page's
        // registry) that lands during the hold-up, the build, the flush or the page call is noticed by `recordRestoreEntry`.
        let epoch = unifiedUndoService.generation
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true

        // Step 4: the pending re-parse is cancelled, and the boundary hygiene the old body does.
        await prepareMarkdownPageForStructuralCommand()

        // Step 5: the plan (read NOW, after the wait) and the page call. The per-op epoch starts at the click (the job reads it as
        // `epochAtClick`); every nil return clears it again.
        let opId = UUID()
        efOpEpoch[opId] = 1
        let trace = StructTrace(label: kind.logName, opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: kind.logName, opId: trace.opId)
        trace.log("start (editor-first) mode=markdown")
        let call = await sendMarkdownRestoreWithRetry(opId: opId, build: build, sectionSync: sectionSync, database: db, projectId: pid)
        let answer: MarkdownRestoreAnswer
        switch await markdownRestoreAnswer(from: call, kind: kind, opId: opId, projectId: pid, trace: trace) {
        case .success(let answered): answer = answered
        case .failure(let exit): return exit.outcome
        }
        let plan = answer.plan
        crossCheckMarkdownRestore(reply: answer.reply, plan: plan, opId: opId)
        DebugLog.log(
            .undo, "[STRUCT-TRACE] \(kind.logName)-editor-first opId=\(trace.opId) ok=true mode=markdown rows=\(plan.rows.count)")
        #if DEBUG
        testLastRestorePlan = plan
        #endif

        // Step 6: the reply turn (shared with the quick redo): the writer's last write is awaited, then nothing suspends until the job
        // holds its place and the hold is handed on.
        let context = MarkdownJobContext(editorState: editorState, blockSync: blockSync, database: db, projectId: pid)
        await markdownRestoreReplyTurn(
            opId: opId, jobKey: nil, plan: plan, preRaw: answer.preRaw, postRaw: answer.postRaw, context: context, hold: hold, run: &run)

        // A job that did not reserve its place has no continuation to release the hold: let it go NOW, before the entry is recorded
        // (`recordRestoreEntry` awaits the descriptor push, and a settle that starts the put-back meanwhile must not find the hold up).
        // The `defer` above stays: releasing twice is idempotent.
        if !run.handedOff { hold.release() }

        // Step 7: the entry, recorded here and only here. `efEditorKind` was set in the reply turn; it is set once more here, before the
        // entry goes on the timeline, so the entry is never recorded without it. `recordRestoreEntry` then checks the timeline generation
        // read in step 3 and, when it moved, cleans the entry up (which clears `efEditorKind` again: there is no entry). Nothing here
        // touches `structuralOutOfQueueGeneration`.
        efEditorKind[opId] = .markdown
        let outcome = await recordRestoreEntry(opId: opId, plan: plan, timelineEpoch: epoch, trace: trace)
        // No entry was recorded: nothing will ever bump this epoch, so it goes (the job's settle reads a missing epoch as unmoved). On
        // success it STAYS, as in every other editor-first kind: the quick undo's `bumpEpoch` starts from it, and a click job whose settle
        // is still running must see the epoch move.
        if outcome != .performed { efOpEpoch.removeValue(forKey: opId) }
        return outcome
    }

    // MARK: - What the page call came to

    /// A page call that succeeded, with the plan it was made from and the page's text before and after.
    private struct MarkdownRestoreAnswer {
        let reply: MarkdownRestoreReply
        let plan: RestorePlan
        let preRaw: String
        let postRaw: String
    }

    /// A page call that did not succeed: what the click returns (nil: the old body runs; `.refused`: the version is gone).
    private struct MarkdownRestoreExit: Error {
        let outcome: StructuralOpOutcome?
    }

    /// Turns the page call's result into the click's next step. Every way out but a success clears the per-op epoch, logs why (the
    /// persisted `[EF-STRUCT] ... fell back to the old path` line carries the page's reason AND its detail) and, when the old body is to
    /// run, takes the page's live text into the record first (the old body flushes the record, which lags the page by its debounce).
    private func markdownRestoreAnswer(
        from call: MarkdownRestoreCall, kind: EditorFirstOpKind, opId: UUID, projectId pid: String, trace: StructTrace
    ) async -> Result<MarkdownRestoreAnswer, MarkdownRestoreExit> {
        func oldPath(_ logged: String?, _ why: String) async -> Result<MarkdownRestoreAnswer, MarkdownRestoreExit> {
            efOpEpoch[opId] = nil
            if let logged { DebugLog.alwaysPersisted("[EF-STRUCT] \(kind.logName) fell back to the old path: \(logged) (project \(pid))") }
            trace.log("fell back to the old sequence (\(why))")
            if let editorState { await adoptPageTextForTheOldBody(editorState) }
            return .failure(MarkdownRestoreExit(outcome: nil))
        }
        switch call {
        case .answered(let reply, let plan):
            if reply.succeeded, let preRaw = reply.preRaw, let postRaw = reply.postRaw {
                return .success(MarkdownRestoreAnswer(reply: reply, plan: plan, preRaw: preRaw, postRaw: postRaw))
            }
            let why = reply.reason ?? "refused"
            let detail = reply.detail.map { " detail=\($0)" } ?? ""
            return await oldPath("page refused (\(why))\(detail)", "the page refused: \(why)")
        case .legacy:
            return await oldPath(nil, "the old restore takes this press")
        case .refused:
            efOpEpoch[opId] = nil
            trace.log("refused (the version no longer exists)")
            return .failure(MarkdownRestoreExit(outcome: .refused))
        case .noRequest:
            return await oldPath("no request built", "no request could be built")
        case .noAnswer:
            return await oldPath("page refused (no answer)", "no usable answer from the page")
        }
    }

    // MARK: - The page call

    /// One call of `markdownStructuralRestore`: the plan built now (after the hold wait, and again after a retry's flush), the leader map
    /// and the request made from the rows as they are then, the page asked.
    private func sendMarkdownRestore(
        opId: UUID, build: () async -> MarkdownRestoreBuild, sectionSync: SectionSyncService, database: ProjectDatabase, projectId: String
    ) async -> MarkdownRestoreCall {
        let plan: RestorePlan
        let rootId: String?
        switch await build() {
        case .ready(let built, let root):
            plan = built
            rootId = root
        case .legacy: return .legacy
        case .refused: return .refused
        }
        guard let rows = try? database.fetchBlocks(projectId: projectId) else { return .noRequest }
        let map = MarkdownLeaderMap(rows: rows)
        let text = plan.markdownPageText(sectionSync: sectionSync)
        guard let json = map.restoreRequest(opId: opId, mode: plan.mode, rootId: rootId, text: text)?.json else { return .noRequest }
        guard let answer = await evalString("JSON.stringify(window.FinalFinal.markdownStructuralRestore(\(json)))"),
              let reply = try? JSONDecoder().decode(MarkdownRestoreReply.self, from: Data(answer.utf8)) else { return .noAnswer }
        return .answered(reply, plan)
    }

    /// The page call with the B1 flush-and-retry once: a leader the page found does not match the rows (a heading typed or renamed a
    /// moment ago), so the typing is flushed and the call is made once more, from a REBUILT plan (the rows are different now, and a plan
    /// carries ids prepared against the rows it was built from). A second mismatch, any other refusal or a JavaScript error is returned as
    /// it is.
    private func sendMarkdownRestoreWithRetry(
        opId: UUID, build: () async -> MarkdownRestoreBuild, sectionSync: SectionSyncService, database: ProjectDatabase, projectId: String
    ) async -> MarkdownRestoreCall {
        var call = await sendMarkdownRestore(opId: opId, build: build, sectionSync: sectionSync, database: database, projectId: projectId)
        if case .answered(let reply, _) = call, reply.reason == "leadersMismatch" {
            guard await flushTypingForMarkdownRetry(projectId: projectId) else { return .noAnswer }
            call = await sendMarkdownRestore(opId: opId, build: build, sectionSync: sectionSync, database: database, projectId: projectId)
        }
        return call
    }

    /// The page's `insertedLeaderIds` against the markers Swift wrote (`RestorePlan.markedLeaderIds`): ids and order must be exactly
    /// those (a difference is a broken contract and is persisted in the log). The sidebar overlay always comes from the plan.
    private func crossCheckMarkdownRestore(reply: MarkdownRestoreReply, plan: RestorePlan, opId: UUID) {
        let pageIds = reply.insertedLeaderIds ?? []
        let sent = plan.markedLeaderIds
        if pageIds != sent {
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] markdown restore \(opId): the page found \(pageIds.count) section marker(s) in the text, "
                + "Swift wrote \(sent.count), or the order differs")
        }
    }

    // MARK: - The reply turn (the click and the quick redo)

    /// Step 6 of the click and of the quick redo: the writer's last write is awaited, then in ONE synchronous stretch the typing batch up to
    /// the command (`prepareStructuralClick` FROM `preRaw`, the page's text before the command, never from `postRaw`; never a whole-document
    /// write), `noteQueuedStructuralJob`, the page's text adopted into the content record
    /// (`adoptMarkdownPageText`, O11: from here the card click finds the restored markers in `sourceContent`), the plan and the sidebar
    /// (`showRestoreInSidebar`), the step-8 gate (made BEFORE the job starts: the settle may reach it at once) and the job through
    /// `startEditorFirstRestoreJob`. Once the starter has returned true the hold is HANDED OFF in the same synchronous turn (D2/O21): a
    /// continuation Task takes it and releases it in its own `defer`. When the job did not reserve its place there is no continuation:
    /// the gate is finished and the caller's `defer` releases the hold.
    ///
    /// WHAT THE TYPING BATCH COVERS. When `prepareStructuralClick` reserves a batch (disposition `.started`), what was typed before the
    /// call, inside the replaced part too, is in the rows before the job runs: the automatic version the job writes and the undo's
    /// reinsert hold it, and one Cmd-Z brings it back at the same place. When it reserves nothing (`.skippedOpenFence`: the caret is
    /// inside an unclosed code fence; `.refused`, `.unreadable`, `.noWriter`; the disposition is not inspected here, as in the Delete's
    /// and the Duplicate's reply turns) that typing is not in the rows yet. It is not lost: the page's checkpoint (the entry's pre-op
    /// state, taken from the live document before the swap) brings it back with the old text on Cmd-Z, and step 8's flush writes the
    /// live text into the rows after the job.
    ///
    /// NEVER records an entry (the click records its own once; a quick redo's entry is already on the timeline).
    ///
    /// `jobKey` is the quick redo's fresh registry key (nil for the click, whose job is keyed by the entry's id); it is also the key of the
    /// gate and of the continuation. A redo has marked its slot `reserved` right before the job starts (as the Duplicate's, and the Rich
    /// Text redo). `plan` is the FIRST click's plan on a redo, so the same ids come back.
    func markdownRestoreReplyTurn( // swiftlint:disable:this function_parameter_count
        opId: UUID, jobKey: UUID?, plan: RestorePlan, preRaw: String, postRaw: String, context: MarkdownJobContext,
        hold: MarkdownStructuralHold, run: inout MarkdownDeleteRun
    ) async {
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        while let pending = writer.inFlight { await pending.value }
        writer.prepareStructuralClick(
            text: MarkdownLeaderMap.recordText(fromRaw: preRaw), database: context.database, projectId: context.projectId,
            service: context.blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        writer.noteQueuedStructuralJob()
        editorState.adoptMarkdownPageText(postRaw)   // O11: the record takes the page's text in this turn; nothing is pushed back

        // A quick redo: the leaders the undo hid leave the removal filter now, AFTER the writer's last write was awaited (as the
        // Duplicate's reply turn), so the sidebar is not shown a half-way mix while that write finishes. The click has nothing to subtract.
        if jobKey != nil {
            editorState.pendingRemovalIds.subtract((efHolders[opId]?.snapshot().clickLeaderIds ?? []).union(plan.newLeaders.map(\.id)))
        }

        // The restored outline shows in the sidebar at once, kept by the overlay until the job has put the rows into the database.
        efRestorePlans[opId] = plan
        showRestoreInSidebar(opId: opId, plan: plan)

        run.countHandedToJob = true   // the job's task brings `pendingEditorFirstJobs` down once its future has resolved
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[jobKey ?? opId] = gate
        efEditorKind[opId] = .markdown
        if jobKey != nil { efSlots.markReserved(opId) }   // the quick redo's fresh job, as the Duplicate's and the Rich Text redo
        let reserved = await startEditorFirstRestoreJob(
            opId: opId, plan: plan, removedLeaders: Set(plan.previousLeaders.map(\.id)), database: context.database,
            projectId: context.projectId, jobKey: jobKey, ownsPendingJobCount: true)
        // D2/O21: the hand-off is the same synchronous turn as the starter's return, no `await` in between.
        if reserved {
            run.handedOff = true
            startMarkdownHoldContinuation(hold: hold, opId: opId, jobKey: jobKey)
        } else {
            gate.finish()   // no continuation will run step 8
        }
    }
}

// MARK: - The whole-project plan builder

extension StructuralUndoController {

    /// The plan builder of Restore Entire Project in Markdown: the same whole plan Rich Text builds (`restorePlan`), read when the
    /// click calls it (after the hold wait).
    func markdownWholeRestoreBuild(snapshotId: String, database: ProjectDatabase, projectId: String) -> MarkdownRestoreBuild {
        switch restorePlan(snapshotId: snapshotId, database: database, projectId: projectId) {
        case .plan(let built): return .ready(built, rootId: nil)
        case .legacy: return .legacy
        case .refused: return .refused
        }
    }
}
