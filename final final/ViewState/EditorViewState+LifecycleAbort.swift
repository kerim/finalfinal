//
//  EditorViewState+LifecycleAbort.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C5a (slice-3a-1b-everyday.md section 4.3): the ONE abort routine every exit
//  that does NOT reach a tail goes through, so the project stays open with everything intact and everything
//  running again. It replaces the two interim cleanup seams `LifecycleEntry` had after round C3b (the cancelled
//  sequence and the `perform`-threw catch).
//
//  Callers (all in `LifecycleEntry.execute`):
//    - the save sequence's section-operation wait timing out (close / switch);
//    - the writer refusing the barrier (`.cancelledBarrierRefused`);
//    - `perform` throwing (a moved recent project, an integrity failure, a failed Save As copy, Repair still
//      broken, `newProject` failing).
//
//  What the save sequence did that the abort undoes, in the order it undoes it (the order is the point: N14
//  re-pushes block ids BEFORE the editor's reports flow again, N23 lets them flow EVEN WHEN FB never applied):
//
//    1. stand-down: if a quit joined (the editor's token is no longer ours) the quit owns every gate; do nothing;
//    2. drop the Markdown content staged for the flush (`switchInProgressContent`);
//    3. release the writer barrier WITHOUT retiring (the project stays open);
//    4. if FB was started, learn whether it applied (await its own Task, bounded);
//    5. FB applied, Rich Text: re-push block ids to the editor, raced against a bound (FB's `replaceBlocks` is
//       not id-preserving, so every non-heading block id the editor holds is now dead);
//    6. `isResettingContent = false`, then ALWAYS let the editor's reports flow again (`releaseReportHold`; the common cancel
//       is the section-operation wait timing out BEFORE FB, which re-pushes nothing and has no hold to release, so this is harmless);
//    7. clear the token (see below), then Markdown's one catch-up re-parse, resume the sync services, re-post the
//       deferred rebuild requests;
//    8. forget that the flush was done, and show the cancel notice (section operation / refused barrier).
//
//  The token is cleared in a `defer` as the plan says, so no exit (including a push that never returns) can
//  wedge it (review row C8); AND once explicitly at step 7, before the catch-up re-parse. Resolution of the
//  ordering the C4 coder flagged: P5's schedule-time gate (`ViewNotificationModifiers.scheduleFullDocumentReparse`
//  / `scheduleZoomedReparse`) drops any re-parse scheduled while `activeLifecycle != nil`, so the token must be
//  gone before the host is asked to schedule. Everything from the explicit clear to the end of the routine is
//  synchronous (no `await`), so no gate can observe the cleared token before the editor is fully restored: the
//  awaits (FB wait, re-push) all happen with the token still armed.
//

import Foundation

/// Why a lifecycle left without reaching a tail.
enum LifecycleAbortReason {
    /// A close or switch gave up at step 1: a section operation never cleared inside its bound. `command` is what the user asked
    /// for (t-eb07cd67): the notice names it (`ToastFactory.lifecycleCancelled`).
    case sectionOperationRunning(command: LifecycleCommand)
    /// A close or switch could not take the writer barrier at step 8 (the writer refused it). `command` as above.
    case barrierRefused(command: LifecycleCommand)
    /// `perform` threw. The error itself is re-reported by `LifecycleEntry.run` (it rethrows it), exactly as
    /// before the entry existed; the abort shows no notice of its own.
    case performFailed(Error)

    var logDescription: String {
        switch self {
        case .sectionOperationRunning: "section operation still running"
        case .barrierRefused: "writer refused the barrier"
        case .performFailed(let error): "perform failed: \(error)"
        }
    }
}

extension LifecycleFBOutcome {
    /// FB replaced the block table with its own (non-id-preserving) write, either through the queue or directly.
    /// The editor's block ids are then stale and must be re-pushed (N14). A lost FB wrote nothing, and so did
    /// an unchanged one (checked FB, Phase 3a-2): the rows and their ids are exactly what the editor holds, so a
    /// cancelled close has nothing to re-push.
    fileprivate var replacedBlocks: Bool {
        switch self {
        case .applied, .appliedDirectly: true
        case .lost, .unchanged: false
        }
    }
}

extension EditorViewState {

    /// The abort routine (plan section 4.3). `host` is the one `LifecycleEntry` captured at arm (N26, never
    /// re-read from this state); `flush` is what the save sequence had done when the lifecycle gave up (its FB
    /// task and outcome, the editor mode it captured). Never throws; every wait inside it is bounded by
    /// `bounds.abortStep`, so it returns promptly even when the editor is wedged.
    func abortLifecycle(
        token: LifecycleToken,
        reason: LifecycleAbortReason,
        host: LifecycleHost,
        flush: LifecycleFlushResult,
        bounds: LifecycleBounds
    ) async {
        // 1. Stand-down: a quit that joined replaced the token. It owns the gates, the services' suspension,
        // the report hold and the barrier now, and (#18) none of it is ours to release.
        guard activeLifecycle?.id == token.id else {
            DebugLog.log(
                .lifecycle,
                "[LifecycleAbort] \(token.kind) token=\(token.id) (\(reason.logDescription)): a quit took over -- standing down")
            return
        }
        // Review row C8: whatever happens below, the token is cleared (a second close must be accepted).
        defer { clearLifecycle(token.id) }
        DebugLog.log(.lifecycle, "[LifecycleAbort] \(token.kind) token=\(token.id): \(reason.logDescription)")

        // 2. Markdown's step 5 staged the fresh text here; the editor stays open, so it must not outlive the
        // lifecycle (a later no-override flush would write it over new typing).
        switchInProgressContent = nil

        // 3. The barrier is released without retiring: the project stays open, and the editor's reports cannot flow again
        // (step 6) while a barrier would park their writes.
        releaseLifecycleBarrier()

        // 4 + 5. FB's whole-document write killed the editor's non-heading block ids: put them back.
        let mode = flush.capturedEditorMode ?? editorMode
        if mode == .wysiwyg, await fbReplacedBlocks(flush: flush, bounds: bounds) {
            await repushBlockIds(bounds: bounds)
        }

        // 6. ALWAYS let the editor's reports flow again (N23; it was the poll's restart until Phase 5 B4), after the re-push (N14)
        // and even when FB never applied. The save's live read held the reports (design 3.6); the project stays open.
        // Not awaited: nothing below waits on it, and step 7 stays one synchronous stretch.
        isResettingContent = false
        if mode == .wysiwyg, let blockSync = blockSyncService { Task { await blockSync.releaseReportHold(on: nil) } }

        // 7. Synchronous from here to the end: no gate can see the cleared token before the editor is restored.
        // The token goes first because P5 drops a Markdown re-parse scheduled while it is armed.
        clearLifecycle(token.id)
        if mode == .source {
            host.scheduleSourceModeReparse(content)
        }
        resumeSyncServicesForLifecycle()
        if pendingBibliographyRebuild || pendingNotesRebuild || !pendingFootnoteLabels.isEmpty {
            host.repostDeferredRebuilds()
        }

        // 8.
        lifecycleFlushDoneFor = nil
        showAbortNotice(reason)
    }

    // MARK: Steps 4 and 5

    /// Whether FB replaced the block table. Settled already (inside its race, or by the barrier step's grace
    /// wait) is read straight from the result. Still queued: FB's own Task is awaited, raced against
    /// `bounds.abortStep` (the plan's "await it", with no writer API: withdrawing an unsettled FB is parked P9,
    /// rare: it needs a stuck writer). A timeout is logged `alwaysPersisted` and counts as "not known to have
    /// applied", so nothing is pushed.
    private func fbReplacedBlocks(flush: LifecycleFlushResult, bounds: LifecycleBounds) async -> Bool {
        if let settled = flush.fbSettledOutcome { return settled.replacedBlocks }
        guard let fbTask = flush.fbTask else { return false }
        switch await raceAgainstTimeout(.seconds(bounds.abortStep), { await fbTask.value }) {
        case .finished(let outcome):
            return outcome.replacedBlocks
        case .timedOut:
            DebugLog.alwaysPersisted(
                "[LifecycleAbort] the whole-document save was still queued after \(bounds.abortStep)s: "
                    + "block ids are not re-pushed (it may still land)")
            return false
        }
    }

    /// `pushBlockIds` is an `evaluateJavaScript` with no timeout of its own, so it is raced: a wedged editor
    /// costs the abort `bounds.abortStep`, not forever. The push is left running as an orphan if it loses
    /// (accepted, as for every other race in the sequence).
    private func repushBlockIds(bounds: LifecycleBounds) async {
        guard let blockSync = blockSyncService else { return }
        let range = zoomedBlockRange
        let outcome = await raceAgainstTimeout(.seconds(bounds.abortStep)) {
            await blockSync.pushBlockIds(for: range)
        }
        if case .timedOut = outcome {
            DebugLog.alwaysPersisted(
                "[LifecycleAbort] re-pushing block ids did not return within \(bounds.abortStep)s -- continuing")
        }
    }

    // MARK: Step 8

    /// The cancel notice, through this window's toast center (item 38): a close or open that gave up on a section operation, or on a
    /// writer that refused the barrier (both mean an earlier change did not finish), naming the command that did not happen
    /// (`ToastFactory.lifecycleCancelled`, t-eb07cd67). A failed `perform` shows nothing here: `run` rethrows it and the caller
    /// reports it.
    private func showAbortNotice(_ reason: LifecycleAbortReason) {
        switch reason {
        case .sectionOperationRunning(let command), .barrierRefused(let command):
            toastCenter.show(ToastFactory.lifecycleCancelled(command))
        case .performFailed:
            break
        }
    }
}
