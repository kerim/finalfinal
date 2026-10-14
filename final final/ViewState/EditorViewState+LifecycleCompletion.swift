//
//  EditorViewState+LifecycleCompletion.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C3b (slice-3a-1b-everyday.md section 4.2 steps 7-8): the SECOND HALF of the
//  lifecycle save sequence, after FB. Split from `EditorViewState+Lifecycle.swift` (which holds the token API
//  and steps 0-6) to keep both files a sensible size; `runLifecycleFlush` calls these two.
//
//    - step 7 `rederiveForLifecycle`: re-derive the bibliography and footnotes from the FRESH content
//    - step 8 `holdBarrierForLifecycle`: the writer barrier, queued behind FB
//

import Foundation

extension EditorViewState {

    // MARK: Step 7 (re-derive)

    /// Re-derives the bibliography and the footnotes from the FRESH content, after FB (round C3b). FB wrote
    /// the editor's content, so definition TEXT the user typed is already saved; this adds a definition row for
    /// any reference without one and renumbers NOTHING (`allowRenumber: false`: references are kept as written,
    /// no `.renumberFootnotes` is posted, and the whole composed rename map is empty, E2). Each service is
    /// waited on until idle and then refreshed, raced against `bound(bibliographyRefresh, floor: after-FB)`
    /// (C22: Zotero connected but not answering must not stall the close). A refresh that loses its race is
    /// left running as an orphan: its system write is refused after `retire` (close/switch) or held behind the
    /// barrier (quit).
    ///
    /// Skipped for an empty document, in either mode (nothing was written, see the guard below).
    ///
    /// Skipped for a zoomed editor: its fresh content is a subset of the document, and a refresh from it would
    /// remove every definition and citation outside the zoom (6b skips for the same reason). FB's zoomed write
    /// already carries the zoom panel's footnote definitions (mini-Notes).
    ///
    /// `refreshBound` is asked afresh for each service, because the deadline keeps running between them.
    func rederiveForLifecycle(
        content: String,
        capture: LifecycleCapture,
        refreshBound: @MainActor () -> TimeInterval,
        result: inout LifecycleFlushResult
    ) async {
        guard let projectId = capture.projectId else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 7 skipped: no project id")
            return
        }
        // An empty document, in either mode: FB wrote nothing (an empty answer is not a write), so deriving
        // from "" would delete the database's footnote definitions and, with Zotero connected, its bibliography
        // while the body still holds the references. Skipping loses nothing: a real select-all-delete in Rich
        // Text goes through F, which deletes the Notes blocks itself.
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 7 skipped: empty document")
            return
        }
        guard capture.zoomedSectionId == nil else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 7 skipped: zoomed (the fresh content is a subset)")
            result.bibliographyRefresh = bibliographySyncService == nil ? .notRun : .skipped
            result.footnoteRefresh = footnoteSyncService == nil ? .notRun : .skipped
            return
        }
        if let bibliography = bibliographySyncService {
            let citekeys = BibliographySyncService.extractCitekeys(from: content)
            result.bibliographyRefresh = await refreshWhenIdle(
                bound: refreshBound(),
                isIdle: { bibliography.state == .idle },
                refresh: { await bibliography.resyncNow(citekeys: citekeys, projectId: projectId) }
            )
        }
        if let footnotes = footnoteSyncService {
            let refs = FootnoteSyncService.extractFootnoteRefs(from: content)
            result.footnoteRefresh = await refreshWhenIdle(
                bound: refreshBound(),
                isIdle: { footnotes.state == .idle },
                refresh: {
                    await footnotes.resyncNow(
                        footnoteRefs: refs, projectId: projectId, fullContent: content, allowRenumber: false)
                }
            )
        }
    }

    /// Waits (50ms polls) for a service to be idle, then runs its refresh, the whole thing raced against
    /// `bound`. Losing the race cancels the work Task, which stops the idle wait; a refresh already running
    /// carries on as an orphan.
    private func refreshWhenIdle(
        bound: TimeInterval,
        isIdle: @escaping @MainActor () -> Bool,
        refresh: @escaping @MainActor () async -> Void
    ) async -> LifecycleRefreshStatus {
        let outcome = await raceAgainstTimeout(.seconds(bound)) {
            while !isIdle() {
                if Task.isCancelled { return }
                try? await Task.sleep(for: Self.sectionOperationPollInterval)
            }
            if Task.isCancelled { return }
            await refresh()
        }
        if case .timedOut = outcome {
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 7: a refresh did not finish within \(bound)s -- going on")
            return .timedOut
        }
        return .completed
    }

    // MARK: Step 8 (the writer barrier)

    /// Enqueues the writer barrier AFTER FB reserved its place (N9) and waits for it. The handle is stored in
    /// `lifecycleBarrier` the moment it exists and is left HELD: the caller frees it (`LifecycleEntry`'s defer;
    /// the tail's `retire` drops it first on a completed close/switch), after EVERY outcome including
    /// `.timedOut`, which may already be held (N12). `drainForLifecycle`, `skip`, `skipAllReserved` and
    /// `configure`/`reconfigure` must not be called on this writer while it is open (N8).
    ///
    /// - No writer (a launch straight into Markdown): skipped, the sequence goes on (#2).
    /// - A writer that refuses it: a close/switch returns `.cancelledBarrierRefused`; a quit goes on.
    /// - The wait is `remaining` (close/switch) or `remaining - quitBackupReserve` (a quit, or a close a quit
    ///   joined), so the automatic version always keeps its reserve (A23).
    /// - `.reached`: every sequence below it has settled, FB included.
    /// - `.timedOut`: the editor sequences below were skipped by the writer; FB gets a brief, bounded grace
    ///   wait (`barrierFloor`) to land. Only if it still has not is it counted as lost (E1), and then only for a
    ///   quit, which exits holding the barrier; a close/switch's `retire` makes FB's own write report it.
    /// - `.cancelled`: the barrier is gone (`retire`/`skip` took it): the handle is dropped and the loss of
    ///   the guarantee is logged `alwaysPersisted`.
    func holdBarrierForLifecycle(
        token: LifecycleToken,
        capture: LifecycleCapture,
        deadline: LifecycleDeadline,
        bounds: LifecycleBounds,
        result: inout LifecycleFlushResult
    ) async {
        if let reserved = result.fbReserved { await reserved.wait() }
        let quitLike = token.kind == .quit || activeLifecycle?.kind == .quit
        guard let blockSync = capture.blockSync else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 8 skipped: no block-sync service, so no writer to hold a barrier on")
            result.barrier = .skippedNoWriter
            return
        }
        let handle: BarrierHandle
        switch blockSync.requestLifecycleBarrier() {
        case .noWriter:
            DebugLog.log(.lifecycle, "[LifecycleFlush] step 8 skipped: no writer yet (a launch straight into Markdown)")
            result.barrier = .skippedNoWriter
            return
        case .refused:
            result.barrier = .refused
            if quitLike {
                DebugLog.alwaysPersisted("[LifecycleFlush] quit: the writer refused the barrier -- continuing without one")
            } else {
                DebugLog.alwaysPersisted("[LifecycleFlush] \(token.kind): the writer refused the barrier -- cancelling")
                result.outcome = .cancelledBarrierRefused
            }
            return
        case .granted(let granted):
            handle = granted
        }
        lifecycleBarrier = handle
        let timeout = max(0, deadline.remaining - (quitLike ? bounds.quitBackupReserve : 0))
        let outcome = await handle.wait(timeout: timeout)
        result.barrier = .waited(outcome)
        switch outcome {
        case .reached:
            if let fbTask = result.fbTask, result.fbSettledOutcome == nil {
                result.fbSettledOutcome = await fbTask.value
            }
        case .timedOut(let skippedEditorSeqs, let skippedFetched):
            DebugLog.log(
                .lifecycle,
                "[LifecycleFlush] barrier wait timed out after \(timeout)s: "
                    + "\(skippedEditorSeqs.count) editor sequence(s) skipped (\(skippedFetched) already fetched)")
            await settleFBAfterBarrierTimeout(blockSync: blockSync, quitLike: quitLike, bounds: bounds, result: &result)
        case .cancelled:
            lifecycleBarrier = nil
            DebugLog.alwaysPersisted(
                "[LifecycleFlush] \(token.kind): the barrier was cancelled before it was reached "
                    + "-- the ordering guarantee is gone")
        }
    }

    /// After a timed-out barrier wait: a brief, bounded wait (`barrierFloor`, deliberately outside the deadline
    /// arithmetic -- every bound before it has been spent) for FB to land. E1: unapplied only counts as lost if
    /// it still has not.
    private func settleFBAfterBarrierTimeout(
        blockSync: BlockSyncService,
        quitLike: Bool,
        bounds: LifecycleBounds,
        result: inout LifecycleFlushResult
    ) async {
        guard let fbTask = result.fbTask, result.fbSettledOutcome == nil else { return }
        switch await raceAgainstTimeout(.seconds(bounds.barrierFloor), { await fbTask.value }) {
        case .finished(let outcome):
            result.fbSettledOutcome = outcome
        case .timedOut:
            result.fbUnappliedAfterBarrierTimeout = true
            if quitLike {
                blockSync.reportLifecycleWholeDocumentLost(reason: "quit exit with FB unapplied: the barrier wait ran out")
            }
        }
    }
}
