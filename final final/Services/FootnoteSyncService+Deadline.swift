//
//  FootnoteSyncService+Deadline.swift
//  final final
//
//  t-94369a83 Phase 3a-2 Step 5 (fixed-deadline round): how long a footnote change waits before it is written.
//
//  Before: every change to the set of references RESTARTED a 3 second timer, so a chain of deletes each within 3 s of
//  the previous one kept postponing every removal (the user's log: the first deleted number's text vanished 6.15 s
//  after its delete, because a second delete restarted the timer 2.98 s in).
//
//  Now: a BURST starts with the first change of the references (nothing waiting, references differ from
//  `lastKnownRefs`). It fixes ONE deadline, `debounceInterval` later on a monotonic clock, and starts ONE timer task
//  that sleeps until it. Later changes inside the burst only REPLACE the waiting snapshot (`pendingUpdate`: latest
//  references, content and generation); they never cancel the timer and never move the deadline. When the timer
//  wakes it reads `pendingUpdate` at that moment, clears it, and runs `performFootnoteUpdate` once: one write and one
//  undo checkpoint per burst. The first change after that starts a new burst with its own deadline.
//
//  A burst ends early, with `pendingUpdate` cleared and the timer cancelled, in exactly these places: the equal-refs
//  branch of `checkAndUpdateFootnotes` (the references are back to the committed set), `handleUndoCheckpoints` (an
//  undo restore), `beginImmediateInsertion` (`/footnote`), `flushPendingSync` / `resyncNow` (which run the latest
//  snapshot at once), `suspendForLifecycle` (the snapshot moves to `deferredCheck`, replayed on resume as an ordinary
//  check, i.e. a new burst) and `reset()`.
//
//  Same transitions as before (schedule, cancel, fire); only the rule for WHEN the timer starts counting changed.
//

import Foundation

/// t-f1a22aa7 (Phase 4c): what the burst timer's stand-aside needs, kept in ONE stored property of the service (`standAside`) because
/// `FootnoteSyncService.swift` sits at SwiftLint's file-length limit; the service exposes the three fields under their own names (below).
struct FootnoteStandAside {
    /// Asked when a burst's deadline arrives; true while a section command still has work to do (nil: nothing to ask, the old behaviour).
    var workPending: (@MainActor () -> Bool)?
    /// How long a burst that stood aside waits before it asks again.
    var recheck: TimeInterval = 0.25
    #if DEBUG
    /// Every deadline that arrived while `workPending` said true (see `testBurstDueDuringStructuralWorkCount`).
    var dueCount = 0
    #endif
}

extension FootnoteSyncService {
    /// t-f1a22aa7 (Phase 4c): asked when a burst's deadline arrives. True while a section command (Delete, drag, Duplicate, Version
    /// History restore, or the undo of one) still has work to do, so the burst must NOT write: the command's own settle renumbers the
    /// references inside the editor's settle flag (one Cmd-Z step, Notes sorted), and a timer renumber arriving first is a Cmd-Z step of
    /// its own that also skips the sort. While it is true the timer stands aside and asks again `standAsideRecheck` later, keeping the
    /// waiting snapshot (`fireBurst`). Wired in `StructuralUndoController.configure`; nil (a service built without a controller, most
    /// unit tests) keeps the old behaviour.
    var structuralWorkPending: (@MainActor () -> Bool)? {
        get { standAside.workPending }
        set { standAside.workPending = newValue }
    }

    /// How long a burst that stood aside waits before it asks `structuralWorkPending` again. Fixed at a quarter of a second (a renumber
    /// that no settle took lands within this long of the command's work ending: a background update no user action waits on). Tests
    /// shorten it.
    var standAsideRecheck: TimeInterval {
        get { standAside.recheck }
        set { standAside.recheck = newValue }
    }

    #if DEBUG
    /// Test-only: how many times a burst's deadline arrived while `structuralWorkPending` said a section command was unfinished (every
    /// re-check counts, unlike the persisted `[FN-STANDASIDE]` line, which is written once per burst). Tests wait on it instead of
    /// sleeping. Incremented even when the burst then goes on to write (a break patch that switches the stand-aside off).
    var testBurstDueDuringStructuralWorkCount: Int {
        get { standAside.dueCount }
        set { standAside.dueCount = newValue }
    }
    #endif
}

extension FootnoteSyncService {
    /// Called for a change of the references that nothing else consumed. Starts a burst (fixing its deadline and
    /// starting the one timer) or, inside a burst, replaces the waiting snapshot.
    func scheduleBurst(refs: [String], projectId: String, fullContent: String) {
        // Slice 2b (code review C-M2): a quick undo's checkpoint hold withholds writes scheduled AT OR BELOW the generation it captured.
        // A burst scheduled after the quick undo must therefore carry a higher one (`state == .idle` here, so no write is in flight).
        if let hold = undoCheckpointHold, syncGeneration <= hold.belowOrAt { syncGeneration += 1 }
        let snapshot = PendingFootnoteUpdate(
            refs: refs, projectId: projectId, fullContent: fullContent, generation: syncGeneration)
        // A burst is waiting while there is a snapshot and a live (not cancelled) timer for it.
        let burstWaiting = pendingUpdate != nil && debounceTask?.isCancelled == false
        noteChangedRefsCheck(content: fullContent, refs: refs, newBurst: !burstWaiting)   // Step 6: the undo states of the burst
        if burstWaiting {
            fnDiagBurstReplaced(refs: refs, generation: snapshot.generation)
            pendingUpdate = snapshot
            return
        }
        let deadline = ContinuousClock.now + .seconds(debounceInterval)
        fnDiagDeadlineFixed(refs: refs, generation: snapshot.generation, deadline: deadline)
        pendingUpdate = snapshot
        startBurstTimer(deadline: deadline)
    }

    /// Cancels the burst's current timer (if any) and starts the one that wakes at `deadline`. Holds ONLY that: the diagnostics that
    /// belong to a burst's START (`fnDiagDeadlineFixed`, `noteChangedRefsCheck`, the waiting-burst test) stay in `scheduleBurst` and are
    /// not re-run when a burst that stood aside is re-armed (t-f1a22aa7).
    func startBurstTimer(deadline: ContinuousClock.Instant) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.fireBurst(deadline: deadline)
        }
    }

    /// The deadline arrived: runs the LATEST snapshot of the burst (read now, not captured when the burst began). Does
    /// nothing if the burst was ended in the meantime (the snapshot is gone).
    ///
    /// t-f1a22aa7 (Phase 4c): if a section command still has work to do (`structuralWorkPending`), the burst STANDS ASIDE: it writes
    /// nothing, keeps its waiting snapshot (`pendingUpdate`; later changes keep riding along, the burst stays "waiting") and re-arms the
    /// timer `standAsideRecheck` later. The command's own settle then renumbers the references inside the editor's settle flag (one
    /// Cmd-Z step, the Notes sorted) and its `resyncNow` ends this burst (cancels the timer, clears the snapshot); if nothing takes the
    /// burst, it writes on the first re-check after the command's work has ended. The write's `stillWanted` asks the same question again,
    /// but `fireBurst`'s check, the writer's step-2 `stillWanted` and, for a write that carries a rename map, its `prepare` post all run in
    /// one main-actor turn (assumed: nothing suspends between the check and the reserve), so it can change the answer only for a write
    /// without a rename (`prepare == nil`), which the writer re-checks after its wait for a turn (`BlockSyncService`, step 7). A refusal
    /// posts nothing to the page and leaves no wedge: the next change of the references starts a fresh burst. U-SA4 reaches the refusal
    /// arm only through the DEBUG `testInFlightHook`, which runs in that gap (between `fireBurst`'s check and the writer's step 2).
    func fireBurst(deadline: ContinuousClock.Instant) async {
        guard let latest = pendingUpdate else { return }
        let workUnfinished = structuralWorkPending?() == true
        noteBurstDueDuringStructuralWork(latest, unfinished: workUnfinished)   // a plain call: only the line below is the stand-aside
        if workUnfinished {
            // Cancels the very task that is running this method; safe because this branch returns at once.
            startBurstTimer(deadline: ContinuousClock.now + .seconds(standAsideRecheck))
            return
        }
        fnDiagBurstFired(deadline: deadline, generation: latest.generation)
        pendingUpdate = nil
        await performFootnoteUpdate(
            refs: latest.refs, projectId: latest.projectId, fullContent: latest.fullContent,
            scheduledGeneration: latest.generation,
            stillWanted: { [weak self] in self?.structuralWorkPending?() != true })
    }
}
