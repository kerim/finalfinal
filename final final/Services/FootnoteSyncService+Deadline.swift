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
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.fireBurst(deadline: deadline)
        }
    }

    /// The deadline arrived: runs the LATEST snapshot of the burst (read now, not captured when the burst began). Does
    /// nothing if the burst was ended in the meantime (the snapshot is gone).
    func fireBurst(deadline: ContinuousClock.Instant) async {
        guard let latest = pendingUpdate else { return }
        fnDiagBurstFired(deadline: deadline, generation: latest.generation)
        pendingUpdate = nil
        await performFootnoteUpdate(
            refs: latest.refs, projectId: latest.projectId, fullContent: latest.fullContent,
            scheduledGeneration: latest.generation)
    }
}
