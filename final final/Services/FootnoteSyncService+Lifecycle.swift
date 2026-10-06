//
//  FootnoteSyncService+Lifecycle.swift
//  final final
//
//  t-94369a83 Phase 3a-1b (C3b): the footnote service's side of a close / project switch / quit -- suspend
//  scheduling for the length of the save sequence, resume (replaying the one recorded request) if the lifecycle
//  was cancelled. Split out of FootnoteSyncService.swift to keep that file and type within SwiftLint's length
//  limits; the stored state these methods use (`isSuspendedForLifecycle`, `deferredCheck`, `pendingUpdate`,
//  `debounceTask`, `syncGeneration`) stays on the type, because an extension cannot hold stored properties.
//

import Foundation

/// t-94369a83 Phase 3a-1b (C3b): the last `checkAndUpdateFootnotes` request recorded while the service was
/// suspended for a close/switch/quit, replayed by `resumeAfterLifecycle()`. Doubles as the "dirty" flag.
struct DeferredFootnoteCheck {
    let refs: [String]
    let projectId: String
    let fullContent: String
}

extension FootnoteSyncService {
    /// Phase 3a-1b (C3b), plan step 0 (C6, C23): a close/switch/quit holds the editor, so stop scheduling.
    /// Cancels the debounce, clears `pendingUpdate` (kept as the request to replay, C23), bumps
    /// `syncGeneration` (an OLDER run's write is refused by its own generation check) and makes
    /// `checkAndUpdateFootnotes` record instead of schedule. `resyncNow` (step 7) is NOT gated.
    func suspendForLifecycle() {
        fnDiagLifecycle("suspend: debounce cancelled, pending moves to deferredCheck")
        debounceTask?.cancel()
        debounceTask = nil
        if let pending = pendingUpdate, deferredCheck == nil {
            deferredCheck = DeferredFootnoteCheck(
                refs: pending.refs, projectId: pending.projectId, fullContent: pending.fullContent)
        }
        pendingUpdate = nil
        syncGeneration += 1
        isSuspendedForLifecycle = true
    }

    /// Phase 3a-1b (C3b): the lifecycle was cancelled. Clears the suspension and re-runs ONE check for the
    /// recorded request, if any. A completed close/switch's tail `reset()` clears the suspension instead.
    func resumeAfterLifecycle() {
        fnDiagLifecycle("resume (cancelled lifecycle): replays the deferred check if any")
        isSuspendedForLifecycle = false
        guard let check = deferredCheck else { return }
        deferredCheck = nil
        checkAndUpdateFootnotes(footnoteRefs: check.refs, projectId: check.projectId, fullContent: check.fullContent)
    }
}
