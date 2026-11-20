//
//  MarkdownBlockWriter+StructuralHold.swift
//  final final
//
//  t-4a8fd8af (the Markdown-mode structural commands go editor-first), slice 1, round 3: the Markdown writer's HOLD.
//  Plan v2 sections A.2-A.4, B3 (steps 1-8) and B4; plan v2.1 addendum sections 1 and 2; judge round 3 D2, D3, O7, O9, O21,
//  O22; model README block "Markdown editor-first (t-4a8fd8af)" (the held re-parse that stays armed, `MdEFPostApplyFlush`
//  reserving the flush and lowering the hold in ONE step).
//
//  WHY A HOLD. In Markdown mode a structural click changes the EDITOR first (the page text) and queues a background job that
//  makes the DATABASE agree. Between the editor change and the job's apply the editor text and the rows differ by exactly the
//  command. Any other Markdown save that diffs the editor text against the rows in that window (the 1-second re-parse, the
//  bibliography flush) would write the command itself: a Duplicate's copy inserted twice, a Delete's rows removed before the
//  job runs (the job then finds nothing and rolls back). So while a structural command is unapplied the writer is HELD:
//
//    - the debounced re-parse fire (`Trigger.debounceFire`) reserves nothing; `prepare` answers `.heldForStructuralWork` and
//      STORES the `refire` closure the debounce handed in. A held fire stays armed: releasing the hold (or `requestRefire()`)
//      runs the closure, which schedules a normal debounce fire (every gate runs again, on the text as it is then);
//    - `writeNow` (the bibliography flush hook) waits for the release BEFORE it reserves anything (O22);
//    - the two BYPASS triggers belong to the command itself and ignore the hold: `Trigger.structuralClick` (the typing batch up
//      to the click) and `Trigger.structuralFlush` (the post-apply flush of the live text, plan step 8).
//
//  THE TOKEN. `beginStructuralHold()` raises `structuralHoldCount` and returns a `MarkdownStructuralHold`; `release()` lowers it
//  once. The hold is released by exactly one owner on every exit, so the count can never stay raised:
//
//      await writer.awaitStructuralHoldReleased()          // step 1: an earlier command finishes first
//      let hold = writer.beginStructuralHold()             // step 2
//      var handedOff = false
//      defer { if !handedOff { hold.release() } }          // IMMEDIATELY after step 2: every early exit releases
//      ... JS call, mismatch flush, reply turn ...
//      // after the job starter returned true, in the SAME synchronous turn (no `await` in between):
//      handedOff = true; efMarkdownHolds[opId] = hold      // the job-future continuation releases it in ITS own `defer`
//
//  There is deliberately NO `deinit` safety net: `deinit` of a main-actor object does not run on the main actor, and a token
//  that is dropped without a release is a bug in a caller that the next command would only hit as a hang. The contract is the
//  callers' `defer` (the callers are the Markdown click, the quick undo and redo and the slow route, each with the same `defer` and
//  hand-off; their tests are T-U19 and the D3 test, which drive this token directly). `release()` is idempotent, and the writer
//  reference is weak, so a token that outlives its writer is inert.
//
//  NEVER A WHOLE-DOCUMENT WRITE. The two structural triggers go through `prepare` unchanged (the same diff and alignment). On
//  `.skippedOpenFence`, `.refused`, `.unreadable` or `.noWriter` they reserve nothing and return that outcome; they never fall
//  back to `flushContentToDatabase` (plan A17).
//
//  SO THE TYPING BEFORE A CLICK IS NOT ALWAYS SAVED BEFORE THE CLICK. After one of those four outcomes (the one a user reaches is
//  `.skippedOpenFence`: the text ends inside a code fence or `$$` block with no closing line) that typing is not in the rows when the
//  command's job runs. The callers ignore the outcome on purpose. Nothing is lost: the text is still in the page, and step 8's
//  post-apply flush writes the live text after the job. That flush goes through the same open-fence check, so while the live text
//  still ends inside the open fence it is skipped too, and the next save writes it (the re-parse once the fence is closed, or the
//  whole-document save of a close, quit or project switch).
//

import Foundation

// MARK: - The writer's hold state

/// The structural hold's state. A stored property of `MarkdownBlockWriter` only because an extension cannot add one; nothing
/// outside this file writes it.
struct StructuralHoldState {
    /// How many tokens are out. The writer is held while it is above zero.
    var count = 0
    /// The newest `refire` a held debounce fire handed in. Each one means "schedule a normal debounce fire", so the newest wins.
    var heldRefire: (@MainActor () -> Void)?
    /// Callers parked in `awaitStructuralHoldReleased()`, oldest first.
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// What the last `reserveStructuralFlush` decided (it returns only a Task, which is nil for every outcome but `.started`).
    var lastFlushDisposition: MarkdownBlockWriter.Disposition?
    /// O29/O31 (t-4a8fd8af round 4): the editor holds text the content record may not (a Source-mode `contentChanged` was dropped, or
    /// a re-parse fire was discarded because the content state was busy). The next idle pulls the live text (`MarkdownOwedPull`).
    var pullOwed = false
    /// Why the pull is owed, for the log and the tests.
    var pullOwedReason: String?
    /// One-shot closures run when the hold falls to zero, after the waiters and the kept refire (round 4: the hierarchy-enforcement
    /// handler skipped while the hold was up re-runs itself this way).
    var afterRelease: [@MainActor () -> Void] = []
    /// Round 5: the job-future continuation that owns a Markdown command's hold, by the JOB's key (`startMarkdownHoldContinuation`).
    /// Only the tests reach the Task here (to cancel it and watch the hold fall): nothing in the app does. The lifecycle does not cancel
    /// it (a close, quit or switch saves the live text itself, and step 8 skips its flush while a lifecycle is armed), so the
    /// cancellation paths of the continuation never run in production. The Task removes itself when it ends.
    var continuations: [UUID: Task<Void, Never>] = [:]
    /// Round 6: the per-entry awaitable the settle waits on (`MarkdownStep8Gate`). The continuation finishes it after step 8's flush has
    /// applied; the settle's resyncs may not start before (model `fq`).
    var step8Gates: [UUID: MarkdownStep8Gate] = [:]
    /// Round 6 (B5/O10): every call that set (`opId`) or cleared (`nil`) the page's structural-settle flag, in order. DEBUG builds only
    /// append to it; a test reads it.
    var settleFlagLog: [String?] = []
}

/// The awaitable between a Markdown click's step 8 and the Rich Text settle that follows the same job (round 6). The click makes one
/// before it starts the job; the job-future continuation `finish()`es it on EVERY exit (its own `defer`), once the flush has applied (or
/// at once when there was nothing to flush); `editorFirstJobSettled` waits for it before it starts its resyncs. `wait` is bounded so a
/// hung writer cannot hold the settle for ever.
@MainActor
final class MarkdownStep8Gate {
    private(set) var finished = false
    /// B8: the failed job's section was put back in the editor (the page's undo swap succeeded). The put-back reads it to decide the alert.
    var swappedBack = false
    /// The swap-back was tried (by step 8, or by the put-back for a job that never held its place in the queue).
    var swapAttempted = false
    /// Round 7a: how the job ended, resolved by the job's own task (`notifyMarkdownJobEnded`). The hold continuation waits on THIS, not on
    /// the registry's record: a discard of the entry (typing after a quick undo drops the redo branch) forgets the record, which would
    /// wake the continuation `.abandoned` while the reinsert is still queued and let the next save run ahead of it.
    let jobEnded = JobOutcomeFuture()

    func finish() {
        finished = true
    }

    /// Returns once `finish()` has been called, or after `bound` (the same 15 s `EFJobRegistry.awaitAllSettled` and
    /// `EditorViewState.awaitRunningLiveFlush` use). Polls every 5 ms, like those do.
    func wait(bound: Duration = .seconds(15)) async {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: bound)
        while !finished {
            if clock.now >= end {
                DebugLog.alwaysPersisted("[MdWrite] the settle gave up waiting for step 8 of a Markdown delete after \(bound)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - The token

/// A raised structural hold. `release()` lowers the writer's count once (idempotent), resumes everyone waiting for the release and
/// runs the held refire. See the file header for the contract every owner follows.
@MainActor
final class MarkdownStructuralHold {
    private weak var writer: MarkdownBlockWriter?
    private(set) var released = false

    fileprivate init(writer: MarkdownBlockWriter) {
        self.writer = writer
    }

    func release() {
        guard !released else { return }
        released = true
        writer?.lowerStructuralHold()
    }
}

// MARK: - The hold

extension MarkdownBlockWriter {

    /// True while a structural command is unapplied (`structuralHoldCount > 0`).
    var isHeldForStructuralWork: Bool { structuralHoldState.count > 0 }
    var structuralHoldCount: Int { structuralHoldState.count }
    /// How many callers are parked in `awaitStructuralHoldReleased()` (tests wait on it instead of sleeping).
    var structuralHoldWaiterCount: Int { structuralHoldState.waiters.count }
    /// What the last `reserveStructuralFlush` decided; nil before the first.
    var lastStructuralFlushDisposition: Disposition? { structuralHoldState.lastFlushDisposition }

    /// Raises the hold. The returned token MUST be released by its owner (see the file header: `defer` right after this call).
    func beginStructuralHold() -> MarkdownStructuralHold {
        structuralHoldState.count += 1
        DebugLog.log(.lifecycle, "[MdWrite] structural hold raised (count \(structuralHoldState.count))")
        return MarkdownStructuralHold(writer: self)
    }

    /// Returns once no hold is up. A second structural command parks here (plan B3 step 1) until the earlier one has applied;
    /// the caller must `beginStructuralHold()` in the same synchronous turn that this returns in, so nothing slips in between.
    func awaitStructuralHoldReleased() async {
        while isHeldForStructuralWork {
            await withCheckedContinuation { structuralHoldState.waiters.append($0) }
        }
    }

    /// What `writeNow` waits for before it reserves anything (O22): the structural hold (unless `bypassingStructuralHold`), then the
    /// write in flight, repeated until both are quiet in the same turn. `writeNow` is never `inFlight` while it waits here, so step
    /// 8's `while let inFlight` loop-await cannot deadlock on it. The caller runs on with no suspension after this returns.
    func awaitQuietWriter(bypassingStructuralHold: Bool) async {
        repeat {
            if !bypassingStructuralHold { await awaitStructuralHoldReleased() }
            while let pending = inFlight {
                await pending.value
            }
        } while !bypassingStructuralHold && isHeldForStructuralWork
    }

    /// Runs the stored refire of a held debounce fire, if there is one and the hold is down. Called by the release itself; also
    /// the entry for the owed pull (`MarkdownOwedPull`, a dropped content push) so it re-arms the save the same way. No-op while held.
    func requestRefire() {
        guard !isHeldForStructuralWork, let refire = structuralHoldState.heldRefire else { return }
        structuralHoldState.heldRefire = nil
        DebugLog.log(.lifecycle, "[MdWrite] running the refire a structural hold kept")
        refire()
    }

    /// `prepare`'s answer to a debounce fire during the hold: keep the closure so the release can re-arm the fire.
    func holdFire(_ refire: @escaping @MainActor () -> Void) {
        structuralHoldState.heldRefire = refire
        DebugLog.log(.lifecycle, "[MdWrite] held: a structural command is unapplied; the fire waits for the release")
    }

    /// The token's release: lowers the count; at zero resumes the waiters (oldest first, each resumes on the main actor after
    /// this turn) and runs the held refire.
    fileprivate func lowerStructuralHold() {
        guard structuralHoldState.count > 0 else { return }
        structuralHoldState.count -= 1
        DebugLog.log(.lifecycle, "[MdWrite] structural hold released (count \(structuralHoldState.count))")
        guard structuralHoldState.count == 0 else { return }
        let waiters = structuralHoldState.waiters
        structuralHoldState.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
        requestRefire()
        let actions = structuralHoldState.afterRelease
        structuralHoldState.afterRelease = []
        for action in actions {
            action()
        }
    }

    // MARK: - The owed pull (O29, O31)

    /// True when the editor may hold text the content record lacks; the next idle pulls it (`MarkdownOwedPull.runIfOwed`).
    var isPullOwed: Bool { structuralHoldState.pullOwed }
    var pullOwedReason: String? { structuralHoldState.pullOwedReason }

    /// O29: a Source-mode `contentChanged` was dropped (state not idle, a rebuild's reset, or the 150 ms grace). O31: a re-parse fire
    /// was discarded only because the content state was not idle. Both owe the same pull.
    func notePullOwed(_ reason: String) {
        structuralHoldState.pullOwed = true
        structuralHoldState.pullOwedReason = reason
        DebugLog.log(.lifecycle, "[MdWrite] a pull of the live editor text is owed: \(reason)")
    }

    /// Clears the flag and returns whether it was set. The pull clears it BEFORE it reads, so a drop that happens during the read
    /// sets it again.
    func takePullOwed() -> Bool {
        let owed = structuralHoldState.pullOwed
        structuralHoldState.pullOwed = false
        structuralHoldState.pullOwedReason = nil
        return owed
    }

    /// Runs `action` once, when the hold is next released to zero; at once when no hold is up.
    func afterNextRelease(_ action: @escaping @MainActor () -> Void) {
        guard isHeldForStructuralWork else {
            action()
            return
        }
        structuralHoldState.afterRelease.append(action)
    }

    // MARK: - The two bypass triggers

    /// The click's typing batch (plan B3 step 5a): the text up to the click, `prepare`'s own diff against the baseline, reserved as
    /// the typing turn that comes before the command's job. Ignores the hold. Synchronous: parse, alignment, diff, reservation
    /// and the start of the apply Task are one main-actor turn, as for the debounce fire.
    ///
    /// Never a whole-document write, so the typing is NOT always saved before the click: `.skippedOpenFence` (the text ends inside an
    /// unclosed code fence or `$$` block), `.refused`, `.unreadable` and `.noWriter` reserve nothing and are returned as they are.
    /// Only a `.started` batch puts the pre-click typing into the rows before the job runs (`.nothingToWrite` and `.stayedRows` mean
    /// there was none to write). The callers ignore the outcome on purpose: the typing is still in the page, and the command's
    /// post-apply flush (step 8) writes the live text after the job; that flush is skipped too while the text still ends inside the
    /// open fence, and the next save writes it. The caller follows a reserved batch with
    /// `noteQueuedStructuralJob()` (a baseline that names rows the job is about to delete must never be installed).
    @discardableResult
    func prepareStructuralClick(
        text: String,
        database: ProjectDatabase,
        projectId: String,
        service: BlockSyncService?,
        refire: @escaping @MainActor () -> Void
    ) -> Disposition {
        guard let service else { return noServiceForStructuralSave() }
        return prepare(Context(
            trigger: .structuralClick, text: text, database: database, projectId: projectId, service: service, refire: refire))
    }

    /// The post-apply flush (plan v2.1 addendum section 2, step 8): the live text diffed against the rows the job left, reserved
    /// in the same synchronous turn in which the owner then releases its hold. Returns the started apply Task (the awaitable the
    /// settle waits on), or nil when nothing was reserved: the text equals what is stored, only filtered changes were left, or
    /// one of the outcomes above. `lastStructuralFlushDisposition` says which. Ignores the hold; never a whole-document write.
    func reserveStructuralFlush(
        text: String,
        database: ProjectDatabase,
        projectId: String,
        service: BlockSyncService?,
        refire: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        let disposition: Disposition
        if let service {
            disposition = prepare(Context(
                trigger: .structuralFlush, text: text, database: database, projectId: projectId, service: service, refire: refire))
        } else {
            disposition = noServiceForStructuralSave()
        }
        structuralHoldState.lastFlushDisposition = disposition
        return disposition == .started ? inFlight : nil
    }

    private func noServiceForStructuralSave() -> Disposition {
        DebugLog.log(.lifecycle, "[MdWrite] no block-sync service: nothing reserved for the structural command's save")
        return .noWriter
    }
}
