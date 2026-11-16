//
//  EditorViewState+Lifecycle.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md sections 2.1 and 5.2): the lifecycle TOKEN.
//  A close, a project switch or a quit takes one token on the editor state it runs against; everything the
//  later rounds gate (rebuild handlers, the Markdown re-parse, the sync services) reads it.
//  `LifecycleEntry.run` (Services/LifecycleEntry.swift) arms it; every close, open, create, repair and
//  Getting Started call reaches `run` through `ProjectCommands` since rounds C7a to C8b.
//
//  Round C3a (same file, below the token API): the FIRST HALF OF THE SAVE SEQUENCE for Rich Text,
//  `runLifecycleFlush` (plan section 4.2 steps 0-6), and `registerRebuildTask`, which the three database
//  rebuild handlers use to register their running Tasks so step 3 can await them.
//
//  Round C3b (same file): the SECOND HALF, steps 7-8 -- re-derive the bibliography and footnotes from the
//  fresh content AFTER FB (`allowRenumber: false`), then the writer barrier -- plus step 0's suspension of the
//  two sync services, the quit-with-an-operation-running path (F applied, no FB, no step 7), and the wiring of
//  the sequence into `LifecycleEntry.execute`, which now runs it before `perform`.
//
//  Precedence (quit > close > switch, plan section 2.1):
//    - nothing armed        -> the request arms a new token;
//    - the same kind again  -> a SILENT duplicate (a repeated Cmd-W, a repeated Cmd-Q; B15);
//    - a quit while a close or switch is armed -> JOINS: a new `.quit` token replaces the old one, so the
//      old lifecycle's own clear becomes a no-op (compare-and-clear) and the gates stay armed;
//    - a close or switch while anything else is armed -> `.refusedBusy` here. Since t-eb07cd67 `LifecycleEntry` never lets a close
//      or open reach this while another runs (it holds the request, `LifecycleEntry.withTurn`), so the only token it can still find
//      is the app's own quit, and it then does nothing.
//

import Foundation
import WebKit

/// Which lifecycle operation holds (or asks for) the editor.
enum LifecycleKind: Sendable, Equatable {
    case projectSwitch
    case close
    case quit
}

/// One armed lifecycle. `wasGettingStarted` is captured when the token is ARMED (N1): by the time a tail
/// runs after `perform`, `DocumentManager.isGettingStartedProject` already describes the NEW project.
struct LifecycleToken: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: LifecycleKind
    let wasGettingStarted: Bool

    init(kind: LifecycleKind, wasGettingStarted: Bool) {
        self.id = UUID()
        self.kind = kind
        self.wasGettingStarted = wasGettingStarted
    }
}

/// What `armLifecycle` did with a request.
enum ArmResult: Equatable {
    /// Nothing was armed: this request now holds the editor.
    case armed(LifecycleToken)
    /// A quit took over from the close or switch that was armed. The returned token replaced it.
    case joined(LifecycleToken)
    /// Another kind of lifecycle holds the editor; nothing changed. Carries the holder's kind (in practice the app's own quit:
    /// `LifecycleEntry` holds a close or open behind a running one before it gets here).
    case refusedBusy(active: LifecycleKind)
    /// The same kind already holds the editor; nothing changed and nothing is shown to the user.
    case duplicate
}

extension LifecycleKind {
    /// What a request of this kind does while a lifecycle of kind `active` already holds the editor. The one
    /// place the precedence rule lives: `armLifecycle` applies it to the editor's own token.
    enum Precedence: Equatable {
        case duplicate
        case joins
        case refused
    }

    func precedence(whileActive active: LifecycleKind) -> Precedence {
        if self == active { return .duplicate }
        if self == .quit { return .joins }
        return .refused
    }
}

extension EditorViewState {
    /// Arms a lifecycle of `kind`, or says why it could not. Synchronous: the caller learns the answer
    /// before any `await`, which is what makes a quick second Cmd-W a duplicate rather than a race.
    func armLifecycle(_ kind: LifecycleKind, wasGettingStarted: Bool) -> ArmResult {
        guard let active = activeLifecycle else {
            let token = LifecycleToken(kind: kind, wasGettingStarted: wasGettingStarted)
            activeLifecycle = token
            DebugLog.log(.lifecycle, "[Lifecycle] armed \(kind) token=\(token.id)")
            return .armed(token)
        }
        switch kind.precedence(whileActive: active.kind) {
        case .duplicate:
            DebugLog.log(.lifecycle, "[Lifecycle] duplicate \(kind) ignored (token=\(active.id))")
            return .duplicate
        case .joins:
            let token = LifecycleToken(kind: kind, wasGettingStarted: wasGettingStarted)
            activeLifecycle = token
            DebugLog.log(.lifecycle, "[Lifecycle] \(kind) joined \(active.kind) token=\(active.id) -> \(token.id)")
            return .joined(token)
        case .refused:
            DebugLog.log(.lifecycle, "[Lifecycle] \(kind) refused: \(active.kind) is running")
            return .refusedBusy(active: active.kind)
        }
    }

    /// Compare-and-clear: removes the active token only if it is the one with `id`. Returns whether it
    /// did. A lifecycle whose token a quit replaced calls this at its end and gets `false`: the quit's
    /// token (and the gates it holds) stay in place.
    @discardableResult
    func clearLifecycle(_ id: UUID) -> Bool {
        guard activeLifecycle?.id == id else { return false }
        activeLifecycle = nil
        DebugLog.log(.lifecycle, "[Lifecycle] cleared token=\(id)")
        return true
    }
}

// MARK: - The save sequence, steps 0-6 (round C3a)

/// How `runLifecycleFlush` ended.
enum LifecycleFlushOutcome: Equatable, Sendable {
    /// The sequence ran to its end (Rich Text: steps 0-8). Any step may have been skipped for a reason the
    /// result records (no watchdog-free fetch, an empty document, a running operation under a quit, no writer
    /// to hold a barrier on, ...).
    case flushed
    /// A CLOSE or SWITCH gave up at step 1: a section operation (delete, duplicate, version restore) was
    /// still running when the wait's bound passed. Nothing was captured, polled, fetched or reserved. Polling
    /// is still stopped: the abort routine (`abortLifecycle`, round C5a) restarts it (N23) and shows the cancel
    /// notice.
    case cancelledSectionOperation
    /// A CLOSE or SWITCH could not take the writer barrier at step 8: a writer exists but refused it (it is
    /// retired, or another barrier is already open). FB and step 7 had already run. The abort routine
    /// (`abortLifecycle`, round C5a) restores the editor; a QUIT never ends this way (it continues without the
    /// barrier).
    case cancelledBarrierRefused
}

/// What step 7 (re-derive) did for one service.
enum LifecycleRefreshStatus: Equatable, Sendable {
    /// The sequence never got there (a cancelled close, a quit whose operation was still running), or the
    /// service is not wired.
    case notRun
    /// Deliberately skipped: a zoomed editor's fresh content is a SUBSET of the document (refreshing from it
    /// would remove every definition and citation outside the zoom).
    case skipped
    case completed
    /// The refresh did not finish inside its bound (C22: Zotero not answering must not stall the close). The
    /// work is left running as an orphan: a system write it makes later is refused after `retire`, or held
    /// behind the barrier.
    case timedOut
}

/// What step 8 (the writer barrier) did.
enum LifecycleBarrierStatus: Equatable, Sendable {
    case notReached
    /// No writer (a launch straight into Markdown, plan #2): nothing to wait for; the sequence goes on.
    case skippedNoWriter
    /// A writer exists but refused the barrier. A close/switch cancels (`.cancelledBarrierRefused`); a quit
    /// goes on without one (logged `alwaysPersisted`).
    case refused
    /// The barrier was enqueued and waited on. `lifecycleBarrier` holds the handle unless the outcome was
    /// `.cancelled` (the barrier is gone).
    case waited(BarrierOutcome)
}

/// Set (once) when FB has reserved its place in the writer queue, or has finished without ever reserving.
/// Step 8 waits on it before enqueueing the barrier (N9): a barrier enqueued BEFORE FB reserved would park FB
/// behind itself, and FB could then never land before the barrier is reached.
@MainActor
final class LifecycleFBReservedSignal {
    private var isMarked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        guard !isMarked else { return }
        isMarked = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isMarked { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// What step 6 (FB, the queued whole-document write) did, or why it did not run.
enum LifecycleFBStatus: Equatable, Sendable {
    /// The sequence returned before step 6 (a cancelled close).
    case notReached
    /// FB's own Task was started (`LifecycleFlushResult.fbTask`). `fbOutcome` is set only if it settled
    /// inside its race.
    case started
    /// A quit whose section operation was still running: FB would undo the operation, so it is skipped
    /// (the typing still goes out through F).
    case skippedOpStillRunning
    /// Nothing to write: an empty document is not a write (`LifecycleWholeDocumentWrite.prepare` returns
    /// nil), and an empty fetch is a valid answer, not a failed one (N28).
    case skippedEmptyContent
    /// No block-sync service, database or project id to write against.
    case skippedNoWriteTarget
}

/// What FB did. A loss is also counted on the writer's ledger (item 15), except a direct-write failure
/// with no writer, which is only logged `alwaysPersisted`.
enum LifecycleFBOutcome: Equatable, Sendable {
    /// Written through the ordered write queue (`lifecycleWholeDocumentApplied` counted).
    case applied
    /// Checked FB (Phase 3a-2, "Option A, per the user's decision"): the FB job ran in the queue (so
    /// `lifecycleWholeDocumentApplied` counted it, which means "the job ran", not "it wrote"), compared the
    /// rows it would write with the stored rows, found them identical and WROTE NOTHING: no epoch bump, no
    /// new block ids, the editor's ids still valid. Not a loss, never counted in
    /// `lifecycleWholeDocumentLost`. This outcome is where the unchanged verdict is counted: the writer
    /// cannot see it (`applySystemWrite` is generic over the body's result), the lifecycle layer can.
    case unchanged
    /// Written straight to the database: there was no writer (`.refused(.noWriter)`, not a loss), or the
    /// writer belonged to another project (`.identityMismatch`, counted lost first, plan section 4.2 step 6).
    case appliedDirectly
    case lost(String)
}

/// What `runLifecycleFlush` found and did. Later rounds extend it (steps 7-8, the barrier).
struct LifecycleFlushResult {
    var outcome: LifecycleFlushOutcome = .flushed
    /// A quit whose section operation never cleared (step 1): F still ran, FB, 6b and step 7 did not.
    var opStillRunning = false
    /// The editor mode read AFTER the step-1 guard (N24); nil if the sequence never got that far.
    var capturedEditorMode: EditorMode?
    /// Step 3's wait for running rebuilds ran out of time (the rebuilds are accepted as orphans).
    var rebuildWaitTimedOut = false
    /// Step 4: the page did not answer `flushAndAck` (no page, or not within its bound), so the editor just proved wedged and the
    /// fetch is skipped. (The name is the poll watchdog's, which this replaced in Phase 5 B3/B4.)
    var watchdogHit = false
    /// Step 4: the page answered `flushAndAck`, but the writer did not decide every report up to its answer within the bound.
    var forcedPollTimedOut = false
    /// Step 5: what the editor answered. nil = no valid answer; `""` IS a valid answer (N28).
    var fetchedContent: String?
    /// Step 5: the content FB wrote came from `editorState.content`, not from the editor.
    var usedFallback = false
    var fbStatus: LifecycleFBStatus = .notReached
    /// FB's outcome, but ONLY if it settled inside its race (step 6). nil with `fbStatus == .started` means
    /// FB lost the race: not a failure and not a loss (E1) -- the barrier (round C3b) is what waits for it.
    var fbOutcome: LifecycleFBOutcome?
    /// FB's own Task. The race never cancels it; the abort routine and the barrier step read it.
    var fbTask: Task<LifecycleFBOutcome, Never>?
    /// FB's outcome as far as the sequence learned it: set inside the race, or by the barrier step once the
    /// barrier was reached (every sequence below it has settled, FB included) or the post-timeout grace wait
    /// saw it finish. nil = still unsettled when the sequence returned.
    var fbSettledOutcome: LifecycleFBOutcome?
    /// Step 7, per service.
    var bibliographyRefresh: LifecycleRefreshStatus = .notRun
    var footnoteRefresh: LifecycleRefreshStatus = .notRun
    /// Step 8.
    var barrier: LifecycleBarrierStatus = .notReached
    /// The barrier wait itself ran out AND FB had still not applied after the brief grace wait (E1: only then
    /// is an unapplied FB a loss; for a quit it is counted on the ledger).
    var fbUnappliedAfterBarrierTimeout = false
    /// Set when FB's Task is started; step 8 waits on it before enqueueing the barrier (N9).
    var fbReserved: LifecycleFBReservedSignal?
}

/// Everything step 2 captures, AFTER the step-1 guard (N24). Held in locals for the rest of the sequence:
/// `EditorViewState` keeps its services weakly, and the WebView must outlive a view swap.
struct LifecycleCapture {
    let webView: WKWebView?
    let editorMode: EditorMode
    let blockSync: BlockSyncService?
    let database: ProjectDatabase?
    let projectId: String?
    /// The zoom range with its place in the renumber log (`zoomedBlockRangeAnchor`), so the save, which runs after the page's last
    /// reports were applied, reads it in the numbers the rows have by then.
    let zoomedRange: AnchoredSortOrderRange?
    let zoomedSectionId: String?
    /// Asks the CAPTURED WebView (never the service's own weak one) for the editor's live document.
    let fetch: (@MainActor (TimeInterval) async -> String?)?
}

extension EditorViewState {

    /// How often step 1 re-reads "is a section operation running".
    static let sectionOperationPollInterval: Duration = .milliseconds(50)

    /// Registers a running database-rebuild Task (bibliography, Notes, footnote insertion) in
    /// `runningRebuildTasks` and removes it when it finishes (item 21: a collection, not one slot). Step 3 of
    /// the save sequence awaits every registered Task to completion, push included. Called in the same
    /// synchronous MainActor turn that creates the Task, so it is recorded before it can run. The removal
    /// is a separate watcher Task, so the handler's own Task body stays exactly as it was.
    func registerRebuildTask(_ task: Task<Void, Never>) {
        let id = UUID()
        runningRebuildTasks[id] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.runningRebuildTasks[id] = nil
        }
    }

    /// Waits until no database-rebuild Task is running (bibliography, Notes, footnote insertion: `runningRebuildTasks`), however many
    /// start while waiting (a rebuild's end can start the next one), for at most `bound`; gives up with an `alwaysPersisted` line.
    /// Returns at once when none runs. A rebuild the lifecycle DEFERRED has no Task yet and is not waited for.
    ///
    /// Fix round 5, part A (the VM's `testDeleteUndoAtOnce_article`): a rebuild reads the database, then pushes what it read into the
    /// editor some time later. One that started before a structural command's first change holds the document as it was then, and
    /// its push, landing after the command's own swap or removal, puts that older document back over the new one and sets
    /// `contentState` to `.idle` in the middle of the command, which lifts the command's own guard early. So the delete's settle ends
    /// only when the rebuilds it started have landed (`StructuralUndoController.resyncAfterEditorFirstDelete`), and every structural
    /// command waits for the rebuilds running at its entry (`StructuralUndoController.runStructuralCommand`). The Task a rebuild
    /// runs never waits for the structural gate (it waits for the writer to settle, which is bounded), so neither wait can deadlock
    /// with the command that holds the gate.
    ///
    /// `showsNotice`: after one second the wait says so ("Finishing the last change..."), dismissed by id on every way out. The settle's
    /// own wait is background work and shows nothing of its own.
    func awaitNoRunningRebuilds(label: String, bound: Duration = .seconds(15), showsNotice: Bool = true) async {
        guard !runningRebuildTasks.isEmpty else { return }
        let notice = showsNotice ? DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.finishingMessage) : nil
        defer { notice?.stop() }
        DebugLog.log(.lifecycle, "[EditorViewState] \(label): waiting for \(runningRebuildTasks.count) running rebuild(s)")
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: bound)
        while !runningRebuildTasks.isEmpty {
            if clock.now >= end {
                DebugLog.alwaysPersisted(
                    "[EditorViewState] \(label): gave up waiting for \(runningRebuildTasks.count) running rebuild(s) after \(bound)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The save sequence (plan section 4.2 steps 0-8), both editor modes. The caller (`LifecycleEntry`) has
    /// already armed `token` and captured `host` and the structural-undo controller into
    /// `LifecycleEntry.current`, and hands exactly those in (N26: never re-read from this state).
    ///
    /// 0. cancel the Markdown re-parse task (both modes), suspend the two sync services;
    /// 1. wait for a running section operation: close/switch cancel at the bound, a quit goes on with
    ///    `opStillRunning`;
    /// 2. capture the editor (after step 1, N24);
    /// 3. await every running rebuild Task to completion;
    /// 4. F: `flushAndAck` on the captured page (Phase 5 B3/B4: the page posts what it has, the save waits until the writer has
    ///    decided every report up to it). RICH TEXT ONLY. In Markdown there is no F: CodeMirror sends no block reports (they
    ///    belong to the Milkdown editor), its edits reach Swift only through the 50ms-debounced content push, and the debounced
    ///    re-parse that would have written them was cancelled at step 0. (A per-block Markdown write the
    ///    re-parse had ALREADY reserved before step 0 is not cancelled: it sits in the queue ahead of FB and lands
    ///    first, Phase 4a.) The fresh fetch at step 5 asks
    ///    CodeMirror for its live document itself, which is what F is for in Rich Text;
    /// 5. fresh fetch (skipped after a watchdog hit or with `opStillRunning`); nil falls back to
    ///    `content`, `""` is valid. Markdown: CodeMirror's own `getContent()` through the CAPTURED view, with
    ///    the bibliography marker stripped, and staged into `switchInProgressContent` (the pattern the old
    ///    project-switch flush, `flushAllPendingContent`, used; round C4);
    /// 6. FB: the queued whole-document write, started in its own Task and raced; losing the race is no
    ///    failure (E1). 6b: section and annotation sync, as the old `flushAllPendingContent` did;
    /// 7. re-derive the bibliography and footnotes from the fresh content (`allowRenumber: false`), each raced
    ///    against its bound (C22); skipped with a quit's operation still running and for a zoomed editor;
    ///    then `lifecycleFlushDoneFor = token.id`;
    /// 8. the writer barrier: enqueued AFTER FB reserved (N9), stored in `lifecycleBarrier` and left HELD for
    ///    the caller (`LifecycleEntry.execute`'s defer, or the tail's retire, releases it, N9/N12). No writer
    ///    -> skipped; an existing writer refusing it cancels a close/switch and not a quit.
    ///
    /// A quit whose section operation never cleared runs step 4 (F, Rich Text) and step 8 only: no FB, no 6b,
    /// no step 7. In Markdown that is step 8 alone (the typing since the operation began is not saved, parked P4).
    ///
    /// Markdown with NO writer (a launch straight into Markdown never mounted the Milkdown editor, so block-sync
    /// has no writer): FB runs the same body directly in `dbWriter.write` (`.refused(.noWriter)`) and step 8 is
    /// skipped, so the close/switch CONTINUES (#2, U7(c)).
    ///
    /// Never throws and never shows UI. A cancelled close/switch returns `.cancelledSectionOperation` (or
    /// `.cancelledBarrierRefused`) and leaves polling stopped and the sync services suspended for the abort
    /// routine (`abortLifecycle`, round C5a) to restore.
    func runLifecycleFlush(
        token: LifecycleToken,
        host: LifecycleHost,
        structuralUndoController: StructuralUndoController?,
        deadline: LifecycleDeadline,
        bounds: LifecycleBounds
    ) async -> LifecycleFlushResult {
        let isQuit = token.kind == .quit
        let floorBeforeFB = bounds.floorBeforeFB(quit: isQuit)
        var result = LifecycleFlushResult()
        DebugLog.log(.lifecycle, "[LifecycleFlush] \(token.kind) token=\(token.id): start, \(deadline.remaining)s left")

        // Step 0
        cancelReparseAndSuspendSyncForLifecycle()

        // Step 1 (t-94369a83 Phase 4b slice 2a, plan D8 and addendum A1/A21)
        //
        // The gate stops taking new work NOW: a Delete Section, Duplicate Section, Cmd-Z or Cmd-Shift-Z that arrives from this point
        // is cancelled, never run (A21). Commands queued BEFORE this point still run, inside the wait below. The flag stays up
        // through `perform`; the open and close tails clear it right after they retire the old writer, and `LifecycleEntry.finish`
        // clears it when the close or switch is cancelled (a quit never clears it).
        let barrierAlreadyPlaced = structuralGate.isClosedToNewWork
        structuralGate.isClosedToNewWork = true
        // Presses the Rich Text editor holds in its own queue are presses made BEFORE this barrier (a Cmd-Z pressed while an earlier
        // undo was still running is held there and sent only when that undo replies): count them now and let exactly that many through
        // the closed gate, so a Cmd-Z, Cmd-Z, Cmd-W is carried out as pressed (addenda A1/A21 as amended in fix round 5; the judge's
        // "allowance" ruling). The gate is closed FIRST and the editor asked straight after, with nothing in between but one hop to
        // the next MainActor turn (the call runs inside a one-second timeout race, so a wedged editor cannot stall the close), so the
        // window in which a press could be sent between the two is only the web view's message latency; the other order would let a
        // press through an open gate that the count then includes a second time. A count that cannot be read is 0, which is the old
        // behaviour. The wait below keeps waiting while the allowance is above zero
        // (`StructuralCommandGate.isIdle`), and `undoHeldPressSettled` lowers it for a held press that ends without a request.
        // A quit that joined a close or switch finds the barrier already placed: it keeps the allowance that first barrier took (a
        // second count could read 0 while a press already sent is still on its way to Swift, and would count presses made after the
        // first barrier as owed).
        if !barrierAlreadyPlaced {
            let held = await heldUndoPressCountForLifecycle(host: host)
            // Only while the barrier still stands: reopening the gate forgets the allowance, and a count that arrives after that
            // must not leave an owed press behind on an open gate.
            if structuralGate.isClosedToNewWork { structuralGate.preBarrierAllowance = held }
        }
        // The wait no longer has its own 3 s / 10 s cap: it ends when the gate queue is empty, no structural sequence is running
        // and every delete job has ended (no job outlives the writer's 5 s stall backstop, because every job's future resolves).
        // The bound is only what is left of the whole run's budget after the steps still to come (the quit's overall deadline
        // semantics are unchanged).
        let waitBound = deadline.bound(own: isQuit ? bounds.quitTotal : bounds.closeTotal, floor: floorBeforeFB)
        if await waitForSectionOperation(controller: structuralUndoController, bound: waitBound, token: token) == false {
            guard isQuit else {
                DebugLog.log(.lifecycle, "[LifecycleFlush] \(token.kind): section operation still running after \(waitBound)s -- cancelled")
                result.outcome = .cancelledSectionOperation
                return result
            }
            DebugLog.log(.lifecycle, "[LifecycleFlush] quit: section operation still running after \(waitBound)s -- going on without FB")
            result.opStillRunning = true
            // A quit gives up on whatever has not finished: waiters still queued are cancelled (a cancelled Cmd-Z or Cmd-Shift-Z
            // replies `cancelled` to the editor, which clears its undo latch and replays nothing, so no latch is left unanswered
            // and no text undo removes the user's last typing before the closing save) and the unfinished delete jobs' futures
            // resolve `.abandoned`, so nothing waits on a project that is going away.
            let cancelled = structuralGate.cancelWaiters()
            let abandoned = efJobRegistry.abandonAll()
            DebugLog.log(
                .lifecycle,
                "[LifecycleFlush] quit: cancelled \(cancelled) queued structural command(s), abandoned \(abandoned) delete job(s)")
        }

        // Step 2 (N24: after the guard)
        let capture = captureForLifecycle(host: host)
        result.capturedEditorMode = capture.editorMode

        // Step 3
        result.rebuildWaitTimedOut = await awaitRunningRebuilds(
            bound: deadline.bound(own: bounds.rebuildWait, floor: floorBeforeFB))

        // Step 4 (F): a quit sends the user's typing even with an operation running. Rich Text only: in
        // Markdown the fetch at step 5 is the read of CodeMirror's live document (see this function's doc).
        if capture.editorMode == .wysiwyg {
            await forceSendForLifecycle(
                capture: capture, deadline: deadline, bounds: bounds, floor: floorBeforeFB, result: &result)
        } else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] source mode: no F (CodeMirror is read directly at step 5)")
        }

        if result.opStillRunning {
            // A quit with an operation still running: FB would undo the operation, and nothing after it
            // (6b, step 7) may run either. In Rich Text the typing already went out through F.
            result.fbStatus = .skippedOpStillRunning
        } else {
            // Step 5
            let content = await freshContentForLifecycle(
                capture: capture, bound: deadline.bound(own: bounds.fetch, floor: floorBeforeFB), result: &result)

            // Step 6 (FB)
            await writeWholeDocumentForLifecycle(
                content: content,
                capture: capture,
                raceBound: deadline.bound(own: bounds.fbRace, floor: bounds.floorAfterFB(quit: isQuit)),
                result: &result
            )

            // Step 6b: as the old `flushAllPendingContent` did. Zoomed content is a subset (the reconciler would
            // delete every section outside the zoom) and an empty document is no content to reconcile.
            if capture.zoomedSectionId == nil, !content.isEmpty {
                let sectionSyncStarted = ContinuousClock.now
                await sectionSyncService?.syncNow(content)
                await annotationSyncService?.syncNow(content)
                let syncMilliseconds = Int((ContinuousClock.now - sectionSyncStarted) / .milliseconds(1))
                // Whether the text is contiguous UTF-8 is what decides if this step takes about a second or tens of seconds
                // on a book-length document (a bridged `NSString` makes `parseHeaders` quadratic).
                let contiguous = content.utf8.withContiguousStorageIfAvailable { _ in true } != nil
                DebugLog.log(
                    .lifecycle,
                    "[LifecycleFlush] 6b section+annotation sync: \(syncMilliseconds) ms, contiguousUTF8=\(contiguous), "
                        + "\(content.utf8.count) UTF-8 bytes")
            }

            // Step 7: re-derive the bibliography and footnotes from the fresh content, AFTER FB.
            let afterFBFloor = bounds.floorAfterFB(quit: isQuit)
            await rederiveForLifecycle(
                content: content,
                capture: capture,
                refreshBound: { deadline.bound(own: bounds.bibliographyRefresh, floor: afterFBFloor) },
                result: &result
            )
        }

        // The save sequence's data path is done (a quit that joins this lifecycle will not flush again, #10).
        lifecycleFlushDoneFor = token.id

        // Step 8: the writer barrier (Markdown with no writer skips it, #2).
        await holdBarrierForLifecycle(token: token, capture: capture, deadline: deadline, bounds: bounds, result: &result)

        DebugLog.log(
            .lifecycle,
            "[LifecycleFlush] \(token.kind): done (\(result.outcome)), fb=\(result.fbStatus), barrier=\(result.barrier), \(deadline.remaining)s left")
        return result
    }

    // MARK: Step 0

    /// Step 0's editor-side half: cancel the debounced Markdown re-parse (both modes). A Markdown write
    /// the re-parse already RESERVED (`MarkdownBlockWriter`, Phase 4a) is not cancelled: its sequence is in the queue before
    /// FB and the barrier, and lands first.
    /// The token and `LifecycleEntry.current` were set by `LifecycleEntry.run`.
    ///
    /// Step 0 also SUSPENDS the footnote and bibliography sync services (round C3b, reviews C6/C23): they
    /// cancel their debounce, clear `pendingUpdate`, bump `syncGeneration` (an older run's write is refused by
    /// its own generation check) and record "dirty" instead of scheduling while armed. A completed close or
    /// switch un-suspends them through the tail's `reset()`; a cancelled one through
    /// `resumeSyncServicesForLifecycle()`.
    private func cancelReparseAndSuspendSyncForLifecycle() {
        blockReparseTask?.cancel()
        blockReparseTask = nil
        footnoteSyncService?.suspendForLifecycle()
        bibliographySyncService?.suspendForLifecycle()
    }

    /// Un-suspends both sync services (each re-runs one check for whatever it recorded or had pending, C23).
    /// Called by the abort routine (`abortLifecycle`, plan section 4.3 step 7) for every lifecycle that does not
    /// reach a tail, so the services are never left suspended.
    func resumeSyncServicesForLifecycle() {
        footnoteSyncService?.resumeAfterLifecycle()
        bibliographySyncService?.resumeAfterLifecycle()
    }

    /// Releases the writer barrier the lifecycle holds, if any (N9/N12). Safe after any outcome and after a
    /// `retire` has already dropped it (`release()` is then a no-op).
    func releaseLifecycleBarrier() {
        guard let barrier = lifecycleBarrier else { return }
        lifecycleBarrier = nil
        barrier.release()
    }

    /// P6 (plan section 4.4, round C5b): the writer is RETIRED and the barrier RELEASED in ONE synchronous block
    /// -- no `await` between the two -- in this order, for a completed close or switch.
    ///
    /// The order is the point. `retire` skips every turn the writer still has reserved and resumes a system write
    /// parked above the held barrier `.skipped`, and it drops the barrier itself as a RELEASE (a barrier with no
    /// wait pending is never counted `barriersCancelled`). Releasing FIRST would let that parked write resume
    /// `.go` and apply against the project that is closing (or being switched away from), after the automatic
    /// version was made. After the retire the handle's own `release()` is a no-op (`DocumentWriter.releaseBarrierSync`
    /// returns at once for a barrier that is gone); it is still called so the handle is dropped on every path,
    /// including a writer that was never retired because this state has none (N9: one owner, one release).
    ///
    /// A system write that was parked keeps `systemWriteInFlight > 0` until it returns, which is what the
    /// content-state watchdog waits on; the skip resumes it at once (it returns on the next MainActor hop), so
    /// the watchdog's loop ends, and the tail's `resetForProjectSwitch()` then cancels the watchdog outright
    /// (N10, proof in the plan section 4.4).
    func retireForLifecycle(reason: SkipReason) {
        blockSyncService?.retireWriterForLifecycle(reason: reason)
        releaseLifecycleBarrier()
        DebugLog.log(.lifecycle, "[Lifecycle] writer retired (\(reason)) and barrier released")
    }

    // MARK: Step 1

    /// How many Cmd-Z / Cmd-Shift-Z presses the editor holds in its own queue (0 with no web view or when the editor does not answer).
    ///
    /// Asked ONLY while the structural gate is busy (fix round 5, after the first full run). The editor holds a press only while an
    /// earlier undo or redo request of ITS OWN is in flight (its latch), and a request is on the gate from the moment Swift takes it
    /// until it has run, so with the gate idle there is nothing to count; the one gap is the few milliseconds between Swift releasing
    /// the gate and the editor receiving its reply, which is the same "the editor sends the held press the instant the undo replies"
    /// assumption the model makes (README, "Cmd-Z, Cmd-Z, Cmd-W"). This also keeps the save sequence's obligation N24 intact on every
    /// ordinary close: the editor is touched only after the guard has cleared (`captureForLifecycle`), and the one earlier look,
    /// taken only when something is in flight, sets a counter and never fetches from or polls the view.
    func heldUndoPressCountForLifecycle(host: LifecycleHost) async -> Int {   // internal: a unit test reads the Markdown branch
        guard !structuralGate.isIdle else { return 0 }
        // Both editors hold presses in their own queue now (t-4a8fd8af round 7b: the Markdown page's undo coordinator does too), and both
        // pages answer the same `heldUndoPressCount()`; the script returns 0 for a page without the function.
        guard let webView = host.activeWebView(), let blockSync = blockSyncService else { return 0 }
        let count = await blockSync.heldUndoPressCount(webView: webView)
        if count > 0 {
            DebugLog.log(.lifecycle, "[LifecycleFlush] the editor holds \(count) undo/redo press(es): they count as made before the barrier")
        }
        return count
    }

    /// True when no section operation is running (the wait ended), false when `bound` seconds passed with
    /// one still running. "Running" = the captured controller's latch or the `.structuralUndo` content state.
    ///
    /// A close or switch whose token a quit has REPLACED while it waits (the quit joined it, `joinQuit`) stops waiting if the operation
    /// is still running and reports "gave up", exactly as the old fixed 3 s cap did in that case: it is saving nothing, and the quit
    /// then runs its OWN sequence on this editor with its own, full wait (`finishJoinedQuit`). Without this, the close's wait is
    /// now as long as the whole remaining deadline (addendum A1), the joined quit's wait for the close would end at about the same
    /// moment, and a quit pressed during a slow section operation could give up on the close's save, counting it lost.
    /// (If the operation ends before that, the close carries on and saves: the quit joins its flush, as before.)
    private func waitForSectionOperation(
        controller: StructuralUndoController?, bound: TimeInterval, token: LifecycleToken
    ) async -> Bool {
        // A1: running = a structural sequence is running, or a command is queued behind it, or a delete job has not ended, or the
        // work after an applied delete has not finished (the footnote and bibliography resyncs, and the push of the database's Notes
        // and Bibliography into the editor): until then the editor's Notes are half updated, and the save that follows this wait
        // would write them over the database's correct ones.
        func isRunning() -> Bool {
            controller?.isPerforming == true || contentState == .structuralUndo
                || !structuralGate.isIdle || efJobRegistry.hasUnsettledWork
        }
        guard isRunning() else { return true }
        DebugLog.log(.lifecycle, "[LifecycleFlush] section operation running: waiting up to \(bound)s")
        // After one second the wait says so ("Finishing the last change..."), and the toast is dismissed by id on every way out.
        let toast = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { toast.stop() }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(bound))
        while isRunning() {
            if Task.isCancelled || clock.now >= end { return false }
            if token.kind != .quit, activeLifecycle?.id != token.id {
                DebugLog.log(.lifecycle, "[LifecycleFlush] \(token.kind) token=\(token.id): a quit took over while waiting -- standing down")
                return false
            }
            try? await Task.sleep(for: Self.sectionOperationPollInterval)
        }
        return true
    }

    // MARK: Step 2

    func captureForLifecycle(host: LifecycleHost) -> LifecycleCapture {   // internal: a unit test takes the capture a close would take
        let webView = host.activeWebView()
        let blockSync = blockSyncService
        let fetch: (@MainActor (TimeInterval) async -> String?)?
        if let webView, let blockSync, editorMode == .wysiwyg {
            // Phase 5 job B3 (design 3.6): the live read also holds the reports, in the same page turn, and covers them.
            fetch = { bound in await blockSync.fetchContentHoldingReports(timeout: .seconds(bound), webView: webView) }
        } else if let webView, let blockSync {
            fetch = { bound in await blockSync.fetchContentFromWebView(timeout: .seconds(bound), webView: webView) }
        } else {
            fetch = nil
        }
        return LifecycleCapture(
            webView: webView,
            editorMode: editorMode,
            blockSync: blockSync,
            database: projectDatabase,
            projectId: currentProjectId,
            zoomedRange: zoomedBlockRangeAnchor,
            zoomedSectionId: zoomedSectionId,
            fetch: fetch
        )
    }

    // MARK: Step 3

    /// Awaits every registered rebuild Task to completion (the push included), up to `bound` seconds.
    /// True when the bound passed first: the rebuilds are left running as orphans.
    private func awaitRunningRebuilds(bound: TimeInterval) async -> Bool {
        let tasks = Array(runningRebuildTasks.values)
        guard !tasks.isEmpty else { return false }
        DebugLog.log(.lifecycle, "[LifecycleFlush] awaiting \(tasks.count) running rebuild(s), up to \(bound)s")
        let outcome = await raceAgainstTimeout(.seconds(bound)) {
            for task in tasks { await task.value }
        }
        guard case .timedOut = outcome else { return false }
        DebugLog.log(.lifecycle, "[LifecycleFlush] rebuild wait timed out after \(bound)s -- going on")
        return true
    }

    // MARK: Step 4 (F)

    /// F: `flushAndAck` on the CAPTURED WebView, so the user's last keystrokes are in the database before FB (Phase 5 B3/B4, design
    /// 3.4: the page posts what it has and the save waits until the writer has decided every report up to the number it answered).
    /// A page that does not answer counts as a watchdog hit: the fetch is then skipped.
    private func forceSendForLifecycle(
        capture: LifecycleCapture,
        deadline: LifecycleDeadline,
        bounds: LifecycleBounds,
        floor: TimeInterval,
        result: inout LifecycleFlushResult
    ) async {
        guard let blockSync = capture.blockSync else { return }
        // t-d2061b27 (judge D1): while a Cmd-Z or Cmd-Shift-Z is latched on the Rich Text editor, the page holds back the typing it
        // would report (the press's swap puts it back on top of the undone document). F must see that typing, so the hold is
        // released first, on the captured view, once. (Whole-document FB reads the editor's own content, so the typing reaches the
        // database either way; the release is what lets `flushAndAck` below post it too.) Markdown has no F.
        if let webView = capture.webView {
            await blockSync.releaseHeldTypingPushes(webView: webView, bound: deadline.bound(own: bounds.forcedPoll, floor: floor))
        }
        await flushAndAckForLifecycle(
            blockSync: blockSync, webView: capture.webView, bound: deadline.bound(own: bounds.forcedPoll, floor: floor), result: &result)
    }

    /// Step F (Phase 5 job B3, design 3.4): `flushAndAck` on the captured view. A bound passed with
    /// reports still undecided counts as the forced poll's timeout; a page that did not answer as a watchdog hit (the fetch is skipped).
    private func flushAndAckForLifecycle(
        blockSync: BlockSyncService, webView: WKWebView?, bound: TimeInterval, result: inout LifecycleFlushResult
    ) async {
        guard let webView else { return }
        switch await blockSync.flushAndAck(on: webView, bound: bound) {
        case .settled: break
        case .timedOut: result.forcedPollTimedOut = true
        case .pageSilent: result.watchdogHit = true
        }
        DebugLog.log(
            .lifecycle,
            "[LifecycleFlush] F: flushAndAck (timedOut=\(result.forcedPollTimedOut) pageSilent=\(result.watchdogHit))")
    }

    // MARK: Step 5

    /// The content FB writes: the editor's fresh answer when there is one (`""` included: an emptied
    /// document is a valid answer, N28), else `content` on hand. The fetch is skipped after a watchdog hit.
    ///
    /// Markdown (round C4): the fetch asks the CAPTURED view, which in source mode is CodeMirror's (never the
    /// block-sync service's own view, which is the Milkdown editor's). The fetch (`BlockSyncService.fetchContentScript`)
    /// strips the section anchors and, on a Markdown page, KEEPS the bibliography END marker (the page's own `getContent()`
    /// strips it, and a text parsed without it stores the bibliography as ordinary blocks; 2026-10-09) and, for a zoomed
    /// section, the zoom-notes marker (FB's `prepare` splits the mini-Notes off on it); the bibliography
    /// start marker is stripped here (`stripBibliographyMarker` is idempotent, and `content` on hand is already stripped,
    /// so both sources agree). The result is staged
    /// into `switchInProgressContent` exactly as the old `flushAllPendingContent` did, so a flush that reaches
    /// `flushContentToDatabase` with no override inside the window reads THIS content, never the stale
    /// `content`. An empty answer is staged as `""` on purpose: `flushContentToDatabase` refuses empty content,
    /// so such a flush then writes nothing instead of writing the stale document back. Every exit that does not
    /// reach a tail clears it again (the abort routine, `abortLifecycle`); the tail's
    /// `resetForProjectSwitch()` clears it on a completed close or switch.
    private func freshContentForLifecycle(
        capture: LifecycleCapture, bound: TimeInterval, result: inout LifecycleFlushResult
    ) async -> String {
        let isMarkdown = capture.editorMode == .source
        if isMarkdown, !content.isEmpty {
            // Narrows the debounce-race window as far left as possible, as the old `flushAllPendingContent` did.
            switchInProgressContent = content
        }
        let fresh: String
        if !result.watchdogHit, let fetch = capture.fetch, let fetched = await fetch(bound) {
            // `fetched` is already contiguous UTF-8 (`fetchContentFromWebView`); `replacingOccurrences` goes through
            // `NSString` and may hand back a bridged string again, so the Markdown result is made contiguous once more
            // (no copy when it already is). Step 6b's section sync is slow on a bridged string.
            fresh = isMarkdown ? SectionSyncService.stripBibliographyMarker(from: fetched).contiguousUTF8Copy : fetched
            result.fetchedContent = fresh
        } else {
            result.usedFallback = true
            DebugLog.log(
                .lifecycle,
                "[LifecycleFlush] fetch unavailable (watchdogHit=\(result.watchdogHit)): using content on hand (\(content.count) chars)")
            fresh = content
        }
        if isMarkdown { switchInProgressContent = fresh }
        return fresh
    }

    // MARK: Step 6 (FB)
    // (moved to EditorViewState+LifecycleFlush.swift, t-d2061b27 F24: `fbMaySkipWhenUnchanged`, `writeWholeDocumentForLifecycle`, FB's body)
}
