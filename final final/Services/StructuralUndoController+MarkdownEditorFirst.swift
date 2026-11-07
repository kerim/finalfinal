//
//  StructuralUndoController+MarkdownEditorFirst.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 5: Delete Section as an editor-first command in
//  Markdown mode (plan v2 B3 steps 1 to 7, plan v2.1 addendum sections 1 and 2). Delete only; behind `MarkdownEditorFirstSwitch`
//  (default ON since round 7b; the switch stays as the kill switch, and the UI-testing legacy flag takes the old body).
//
//  THE CLICK, under the structural gate (`performSectionDelete` calls `performMarkdownEditorFirstDelete` with the gate held):
//    1. wait for the previous Markdown job's apply (`awaitStructuralHoldReleased`, A7);
//    2. raise the writer's hold and the rebuild stamp (`editorFirstClickGeneration`, `pendingEditorFirstJobs`, so a rebuild that read
//       before the click is stale); the `defer` right after releases both on every early exit (O7);
//    3. cancel the pending re-parse;
//    4. the boundary hygiene the old body does (the page does NOT do it, judge D-7);
//    5. ONE call into the page, `markdownStructuralEditorFirst(request)`, the request built from the rows (`MarkdownLeaderMap`). On
//       `leadersMismatch` (a heading typed or renamed a moment ago) the typing is flushed through `writeNow(bypassingStructuralHold:)`
//       and the call is made ONCE more (B1). A second mismatch, a JavaScript error or any other failure returns nil: the old body runs
//       AFTER the `defer` has released the hold (O7, O20: the rebuilds a skipped push owed are re-posted after the release);
//    6. in the REPLY TURN, with no suspension after the writer's last write has been awaited: the typing batch up to the click
//       (`prepareStructuralClick`, never a whole-document write), `noteQueuedStructuralJob`, the page's text adopted into the content
//       record (`adoptMarkdownPageText`, O11), the sidebar overlay, and the job started through the existing `startEditorFirstJob`.
//       Once the starter has returned true the hold is HANDED OFF in the same synchronous turn (D2/O21): a continuation Task takes it
//       and releases it in its own `defer`;
//    7. the entry is recorded as editor-first (no snapshot id), with `efRecordedStructGeneration` and `efEditorKind[opId] = .markdown`.
//
//  The continuation's work (plan v2.1 addendum section 2: loop-await `inFlight`, the live read, `reserveStructuralFlush` and the release
//  in one turn, `await flush`, then the settle's resyncs) is `runMarkdownStep8` (StructuralUndoController+MarkdownSettle.swift). A FAILED
//  job's put-back is `putBackMarkdownJob` there, and the Cmd-Z and Cmd-Shift-Z of a Markdown entry are the quick route
//  (+MarkdownQuickUndo.swift) and the queued slow route (+MarkdownSlowUndo.swift).
//

import Foundation
import WebKit

/// Which editor an editor-first entry was made in (round 7: the undo routes ask it; `quickPathPossible` compares it with the mode).
enum EditorFirstEditorKind: Equatable {
    case wysiwyg
    case markdown
}

/// The page's answer to `markdownStructuralEditorFirst` (web/codemirror/src/api-structural-markdown.ts `MarkdownStructuralResult`).
struct MarkdownStructuralReply: Decodable, Equatable {
    let succeeded: Bool
    let reason: String?
    let detail: String?
    let preRaw: String?
    let postRaw: String?
    /// A reorder's reply only (`markdownStructuralReorder`): the order ids the page had no leader for. Absent in every other reply.
    let skippedIds: [String]?
    /// t-d2061b27: `true` (never `false`; absent otherwise) when the typing done while an undo or redo waited was put back on top of the
    /// swapped-in text, or, for the quick redo of a Delete, was already in the text the re-run worked on. Swift ends the redo branch
    /// (`endRedoAfterReplayedTyping`). Then `preRaw` is the document AT THE PRESS (no typing in it) for an undo or a composed redo, so the
    /// typing batch up to the swap finds nothing new to write: the replay is the typing's only carrier, saved by step 8's live read.
    let typingReplayed: Bool?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case reason
        case detail
        case preRaw
        case postRaw
        case skippedIds
        case typingReplayed
    }
}

extension StructuralUndoController {

    /// Delete Section, Markdown, editor first. Called under the structural gate. Returns nil, having changed nothing the old body cannot
    /// cope with, when this press has to take today's whole sequence; otherwise the outcome the sidebar reports.
    func performMarkdownEditorFirstDelete(rootId: String) async -> StructuralOpOutcome? {
        guard MarkdownEditorFirstSwitch.enabled else { return nil }
        let outcome = await runMarkdownEditorFirstDelete(rootId: rootId)
        // O20 (D6): the click is over and its `defer` has released the hold. A rebuild whose push the click's stamp skipped has left the
        // Notes and Bibliography as they were; with no job coming to put them in, they are re-posted before the old body runs.
        if outcome == nil, let editorState, editorState.managedRegionsNeedRepush {
            editorState.managedRegionsNeedRepush = false
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        }
        return outcome
    }

    private func runMarkdownEditorFirstDelete(rootId: String) async -> StructuralOpOutcome? {
        guard let editorState, let unifiedUndoService, let blockSync = blockSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, activeWebView != nil,
              editorState.editorMode == .source, editorState.zoomedSectionId == nil, editorState.markdownWriter.isEnabled,
              editorState.activeLifecycle == nil, !TestMode.isUITestingStructuralLegacyDelete,
              blockSync.writer?.database === db, blockSync.writer?.projectId == pid,
              editorFirstRootIsEligible(rootId: rootId, database: db, projectId: pid) else { return nil }
        let writer = editorState.markdownWriter

        // Round M1 measurement (MdSpeed.swift): the Markdown Delete had no timeline of its own; this starts it at the menu click, so every
        // `md-speed delete ...` span below reads its `+timeline=` offset from the click. Silent unless tracing is on.
        StructuralTrace.beginOp(label: "sectionDelete")
        MdSpeed.mark("entered")
        let clickSpan = MdSpeed.span("click")
        defer { clickSpan.end() }

        // Step 1 (A7): an earlier Markdown command finishes saving first. Delete, then Delete again at once, waits here (the gate came free
        // at the first one's step 7, its writer hold stays up until step 8), so past one second the existing notice shows (review DR-1,
        // UX contract 4.2: a held structural command shows "Finishing the last change…"). t-2fbe4c9b: ONE notice belongs to the whole
        // click, as for Duplicate: it stays through the page call and the reply turn (seconds on a book) and the `defer` takes it down.
        let waiting = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { waiting.stop() }
        let holdWaitSpan = MdSpeed.span("holdWait")
        await writer.awaitStructuralHoldReleased()
        holdWaitSpan.end()
        guard editorState.activeLifecycle == nil else { return nil }

        // Step 2 (O7): the hold, and the `defer` that releases it on every early exit.
        let hold = writer.beginStructuralHold()
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true

        // Steps 3 and 4: the pending re-parse is cancelled, and the boundary hygiene the old body does.
        await prepareMarkdownPageForStructuralCommand()

        // Step 5: the page call, with the B1 flush-and-retry once.
        let opId = UUID()
        StructuralTrace.noteOpId(String(opId.uuidString.prefix(8)))   // round M1: the timeline lines carry the op's short id
        let attempt = await sendMarkdownDeleteWithRetry(opId: opId, rootId: rootId, redo: false, database: db, projectId: pid)
        guard let attempt, attempt.reply.succeeded, let preRaw = attempt.reply.preRaw, let postRaw = attempt.reply.postRaw else {
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown editor-first delete: the page refused or failed "
                + "(\(attempt?.reply.reason ?? "no answer")) -- old path for this press")
            // The old body flushes the content record, which lags the page by its debounce: take the page's live text first.
            await adoptPageTextForTheOldBody(editorState)
            return nil
        }

        // Step 6: the reply turn (shared with the quick redo): the writer's last write is awaited, then nothing suspends until the job
        // holds its place and the hold is handed on.
        let epoch = unifiedUndoService.generation
        efOpEpoch[opId] = 1   // the per-op epoch starts at the click (as the Rich Text delete does)
        let context = MarkdownJobContext(editorState: editorState, blockSync: blockSync, database: db, projectId: pid)
        await markdownDeleteReplyTurn(
            opId: opId, rootId: rootId, jobKey: nil, attempt: attempt, preRaw: preRaw, postRaw: postRaw, context: context,
            hold: hold, run: &run)

        // Step 7: the entry.
        guard unifiedUndoService.generation == epoch else {
            DebugLog.log(.undo, "[StructuralUndoController] markdown editor-first delete: timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration
        efEditorKind[opId] = .markdown
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionDelete, title: "Delete Section", undoSnapshotId: nil))
        spy("efRecorded")
        let descriptorSpan = MdSpeed.span("pushDescriptor")
        await pushDescriptor()
        descriptorSpan.end()
        return .performed
    }

    // MARK: - The page call

    /// Steps 3 and 4 of every Markdown structural command (the click and the quick undo and redo): the pending re-parse is cancelled and
    /// the boundary hygiene the old body does is made (the page does NOT do it, judge D-7).
    func prepareMarkdownPageForStructuralCommand() async {
        guard let editorState else { return }
        let prepareSpan = MdSpeed.span("prepare")   // round M1 measurement: the whole step, and each page call inside it
        defer { prepareSpan.end() }
        #if DEBUG
        await testBeforeMarkdownPagePrepare?()
        #endif
        await TestMode.holdMarkdownPagePrepare()   // t-2fbe4c9b: UI-test knob; returns at once unless FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS is set
        editorState.blockReparseTask?.cancel()
        editorState.blockReparseTask = nil
        let cancelInsertionsSpan = MdSpeed.span("prepare.cancelPendingInsertions")
        await evalVoid("window.FinalFinal.cancelPendingInsertions?.()")
        cancelInsertionsSpan.end()
        let closePopupsSpan = MdSpeed.span("prepare.closeEditingPopups")
        await evalVoid("window.FinalFinal.closeEditingPopupsAndClearBoundaryState?.()")
        closePopupsSpan.end()
        findBarState?.clearSearch()
    }

    /// Review F2: `prepareMarkdownPageForStructuralCommand` cancelled the pending re-parse. When the page then REFUSES the press (the swap
    /// answered `changed`, `noEntry` or `midOp`, or did not answer) no job takes over and no typing batch was reserved, so what the user
    /// typed while the press waited would sit in the content record, not in the rows, until the next keystroke. The re-parse is scheduled
    /// again from the record, the same call the writer's own refire makes. Called by the quick undo, the quick redo and the slow route on
    /// every refusal; the scheduler applies its own gates (a lifecycle, zoom, the writer's hold).
    func rearmMarkdownReparseAfterRefusedPress() {
        guard let editorState, editorState.editorMode == .source, editorState.zoomedSectionId == nil,
              editorState.activeLifecycle == nil else { return }
        editorState.lifecycleHost?.scheduleSourceModeReparse(editorState.content)
    }

    /// One call of `markdownStructuralEditorFirst` (the click) or of `markdownStructuralSwap(opId, 'redo', request)` (the quick redo, round
    /// 7a: the page re-runs the delete under the same opId on the document as it is now), the request built from the rows as they are
    /// now. nil: the rows cannot be read, the root is no deletable leader, or the page did not answer with readable JSON (a JavaScript
    /// error).
    private func sendMarkdownDelete( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, rootReference: MarkdownLeaderMap.RootReference?, redo: Bool, database: ProjectDatabase,
        projectId: String
    ) async -> (reply: MarkdownStructuralReply, map: MarkdownLeaderMap)? {
        guard let rows = try? MdSpeed.timed("fetchBlocks", { try database.fetchBlocks(projectId: projectId) }) else { return nil }
        let map = MdSpeed.timed("leaderMap") { MarkdownLeaderMap(rows: rows) }
        // `rootReference`: the root is found again in the CURRENT rows by its heading line when its own id is gone (a slow undo
        // re-created the section's rows with fresh ids). nil: the id is trusted (the click, and the quick redo, whose reinsert restores
        // the ids).
        let currentRootId: String?
        if let rootReference { currentRootId = map.currentRootId(for: rootReference) } else { currentRootId = rootId }
        guard let currentRootId,
              let json = MdSpeed.timed("requestJson", { map.request(opId: opId, rootId: currentRootId)?.json }) else { return nil }
        let call = redo
            ? "markdownStructuralSwap('\(opId.uuidString)', 'redo', \(json))"
            : "markdownStructuralEditorFirst(\(json))"
        let pageCallSpan = MdSpeed.span("pageCall")
        let answer = await evalString("JSON.stringify(window.FinalFinal.\(call))")
        pageCallSpan.end("chars=\(answer?.utf16.count ?? 0)")
        guard let answer else { return nil }
        let decodeSpan = MdSpeed.span("replyDecode")
        let reply = answer.data(using: .utf8).flatMap { try? JSONDecoder().decode(MarkdownStructuralReply.self, from: $0) }
        decodeSpan.end()
        guard let reply else { return nil }
        return (reply, map)
    }

    /// The page call with the B1 flush-and-retry once: a leader the page found does not match the rows (a heading typed or renamed a
    /// moment ago), so the typing is flushed and the call is made once more. nil: no usable answer.
    func sendMarkdownDeleteWithRetry(
        opId: UUID, rootId: String, rootReference: MarkdownLeaderMap.RootReference? = nil, redo: Bool, database: ProjectDatabase,
        projectId: String
    ) async -> (reply: MarkdownStructuralReply, map: MarkdownLeaderMap)? {
        var attempt = await sendMarkdownDelete(
            opId: opId, rootId: rootId, rootReference: rootReference, redo: redo, database: database, projectId: projectId)
        if attempt?.reply.reason == "leadersMismatch" {
            guard await flushTypingForMarkdownRetry(projectId: projectId) else { return nil }
            attempt = await sendMarkdownDelete(
                opId: opId, rootId: rootId, rootReference: rootReference, redo: redo, database: database, projectId: projectId)
        }
        return attempt
    }

    // MARK: - The reply turn (the click and the quick redo)

    /// What a Markdown structural command has raised and handed on, for the `defer` that releases it on every early exit (O7).
    struct MarkdownDeleteRun {
        var countRaised = false
        /// `pendingEditorFirstJobs` now belongs to the job's task.
        var countHandedToJob = false
        /// The hold now belongs to the job-future continuation.
        var handedOff = false
    }

    /// The services a Markdown command checked at its first line and keeps for its whole run.
    struct MarkdownJobContext {
        let editorState: EditorViewState
        let blockSync: BlockSyncService
        let database: ProjectDatabase
        let projectId: String
    }

    /// Step 6 of the click and of the quick redo: the writer's last write is awaited, then in ONE synchronous stretch the typing batch up to
    /// the command (`prepareStructuralClick`, never a whole-document write), `noteQueuedStructuralJob`, the page's text adopted into the
    /// content record (`adoptMarkdownPageText`, O11), the sidebar, the step-8 gate (made BEFORE the job starts: the settle may reach it at
    /// once) and the job through the existing `startEditorFirstJob`. Once the starter has returned true the hold is HANDED OFF in the same
    /// synchronous turn (D2/O21): a continuation Task takes it and releases it in its own `defer`.
    ///
    /// `jobKey` is the quick redo's fresh registry key (nil for the click, whose job is keyed by the entry's id); it is also the key of the
    /// gate and of the continuation. A redo has marked its slot `reserved` before this runs (`efSlots.markReserved`, as the Rich Text redo).
    func markdownDeleteReplyTurn( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, jobKey: UUID?, attempt: (reply: MarkdownStructuralReply, map: MarkdownLeaderMap),
        preRaw: String, postRaw: String, context: MarkdownJobContext, hold: MarkdownStructuralHold, run: inout MarkdownDeleteRun
    ) async {
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        let replyTurnSpan = MdSpeed.span("replyTurn")   // round M1 measurement: the whole reply turn, and each step inside it
        defer { replyTurnSpan.end() }
        // t-2fbe4c9b trigger (iii): the parse memo prepares the post-click text in the background while the wait below runs; step 8 reads it.
        writer.prewarmParse(raw: postRaw, projectId: context.projectId, database: context.database)
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

        let sidebarSpan = MdSpeed.span("sidebar")
        let removedLeaders = Set(attempt.map.removedLeaderIds(rootId: rootId))
        editorState.pendingRemovalIds.formUnion(removedLeaders)
        editorState.pendingRestoreSections[opId] = nil
        dropFromSidebarOverlays(removedLeaders)
        var visibleSections = editorState.sections
        visibleSections.removeAll { removedLeaders.contains($0.id) }
        editorState.sections = visibleSections
        editorState.recalculateParentRelationships()
        sidebarSpan.end()

        run.countHandedToJob = true   // the job's task brings `pendingEditorFirstJobs` down once its future has resolved
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[jobKey ?? opId] = gate
        efEditorKind[opId] = .markdown
        if jobKey != nil { efSlots.markReserved(opId) }   // the quick redo's fresh job, as the Rich Text redo
        let jobStartSpan = MdSpeed.span("jobStart")
        let reserved = await startEditorFirstJob(
            opId: opId, rootId: rootId, removedLeaders: removedLeaders, editorRemovedIds: nil,
            database: context.database, projectId: context.projectId, jobKey: jobKey, ownsPendingJobCount: true)
        jobStartSpan.end()
        // D2/O21: the hand-off is the same synchronous turn as the starter's return, no `await` in between.
        if reserved {
            run.handedOff = true
            let handOffSpan = MdSpeed.span("holdHandOff")
            startMarkdownHoldContinuation(hold: hold, opId: opId, jobKey: jobKey)
            handOffSpan.end()
        } else {
            gate.finish()   // no continuation will run step 8
        }
    }

    /// B1: a leader the page found does not match the rows (a heading typed or renamed a moment ago). The page's LIVE text is read and
    /// adopted into the content record (O25: the writer's baseline moves to it), then written through the queue with the hold's bypass (this
    /// is the click's own flush, so it must not wait for the click's own hold). True when the text is in the rows.
    func flushTypingForMarkdownRetry(projectId: String) async -> Bool {   // internal: the drag-reorder click retries the same way
        guard let editorState, let raw = await evalString("window.FinalFinal.getContentRaw()") else { return false }
        editorState.adoptMarkdownPageText(raw)
        let writeNowSpan = MdSpeed.span("writer.writeNow.retryFlush")   // round M2: names the caller of this writeNow
        defer { writeNowSpan.end() }
        let outcome = await editorState.markdownWriter.writeNow(
            overrideContent: MarkdownLeaderMap.recordText(fromRaw: raw),
            editorState: editorState,
            bypassingStructuralHold: true,
            guardsHold: { [weak editorState] in
                guard let editorState else { return false }
                return editorState.activeLifecycle == nil && editorState.contentState == .idle && editorState.editorMode == .source
                    && editorState.zoomedSectionId == nil && editorState.currentProjectId == projectId
            },
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        return outcome == .proceeded
    }

    /// Internal: the Markdown settle (StructuralUndoController+MarkdownSettle.swift) reads the page too.
    func evalString(_ script: String) async -> String? {
        guard let activeWebView, let answer = try? await activeWebView.evaluateJavaScript(script) else { return nil }
        return answer as? String
    }

    // MARK: - The hand-off

    /// The job-future continuation. It takes the hold in the same synchronous turn as the starter's return and releases it in its OWN
    /// `defer`, however it exits: the job's future resolving, a cancel, a project switch. The Task is kept on the writer
    /// (`structuralHoldState.continuations[key]`); nothing outside the tests reaches it (the lifecycle never cancels it: it saves the live
    /// text itself and step 8 skips its flush while one is armed), so its cancel paths run only in the tests.
    ///
    /// Once the job's future has resolved it runs step 8 (`runMarkdownStep8`, StructuralUndoController+MarkdownSettle.swift): loop-await
    /// `inFlight`, the live `getContentRaw()`, then in ONE turn `reserveStructuralFlush`, the adopt and the release, `await flush`. The
    /// `defer` stays whatever step 8 does: the hold is released and the settle's gate finished on every exit (a cancel, no outcome).
    ///
    /// Round 7a: it serves any Markdown job that holds the writer. `jobKey` is the job's registry key, which is also the key of its gate
    /// and of this continuation: nil for the click's delete (the entry's id), the fresh key of a quick redo's delete job, or the reinsert's
    /// key for a quick undo (`swapsBackOnFailure: false`: a failed reinsert has nothing to swap back).
    @discardableResult
    func startMarkdownHoldContinuation(
        hold: MarkdownStructuralHold, opId: UUID, jobKey: UUID? = nil, swapsBackOnFailure: Bool = true
    ) -> Task<Void, Never>? {
        guard let editorState else { return nil }
        let writer = editorState.markdownWriter
        let registry = editorState.efJobRegistry
        let key = jobKey ?? opId
        // The job's own task says when it ended (`notifyMarkdownJobEnded`), through the gate made before the job started. The registry's
        // record is NOT waited on: a discard of the entry forgets it (typing after a quick undo drops the redo branch) and that would
        // wake this continuation while the job is still queued.
        let gate = writer.structuralHoldState.step8Gates[key]
        let task = Task { @MainActor [weak self, weak writer] in
            defer {
                hold.release()
                writer?.structuralHoldState.step8Gates[key]?.finish()
                writer?.structuralHoldState.continuations[key] = nil
            }
            if let gate {
                let jobEndedSpan = MdSpeed.span("jobEndedWait")   // round M1 measurement: hand-off to the job's end (queue wait + its write)
                await Self.awaitJobEndedOrCancellation(gate: gate)
                jobEndedSpan.end()
            } else {
                await Self.awaitJobOutcomeOrCancellation(registry: registry, opId: key)
            }
            guard !Task.isCancelled, let self else { return }
            await self.runMarkdownStep8(
                opId: opId, jobKey: jobKey, hold: hold, outcome: gate?.jobEnded.value ?? registry.record(for: key)?.outcome,
                swapsBackOnFailure: swapsBackOnFailure)
        }
        writer.structuralHoldState.continuations[key] = task
        return task
    }

    /// Waits for the job behind `gate` to end (its own task resolves `gate.jobEnded`), or for this Task to be cancelled, whichever first.
    private static func awaitJobEndedOrCancellation(gate: MarkdownStep8Gate) async {
        let signal = OneShotResume()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                signal.install(continuation)
                let ended = gate.jobEnded
                Task { _ = await ended.wait(); signal.fire() }
            }
        } onCancel: {
            signal.fire()
        }
    }

    /// Waits for the job of `opId` to end, or for this Task to be cancelled, whichever comes first.
    private static func awaitJobOutcomeOrCancellation(registry: EFJobRegistry, opId: UUID) async {
        let gate = OneShotResume()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.install(continuation)
                Task { _ = await registry.awaitOutcome(opId); gate.fire() }
            }
        } onCancel: {
            gate.fire()
        }
    }
}

/// Resumes one continuation, once, from whichever of two places gets there first.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        let pending = continuation
        continuation = nil
        fired = true
        lock.unlock()
        pending?.resume()
    }
}
