//
//  AppDelegate+QuitSequence.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C6 (slice-3a-1b-everyday.md section 4.5, coder obligations 9, 10 and 31, N3-N6):
//  QUIT. `applicationShouldTerminate` hands its whole body to `runQuitSequence(reply:)`, which takes the reply as
//  a closure so no test ever reaches `NSApp.reply(toApplicationShouldTerminate:)` (item 31).
//
//  The checks run in this order:
//
//  1. A quit is already running (`quitTask != nil`): return `.terminateLater` and start nothing. A second Cmd-Q
//     while the first is still saving is an everyday thing. What AppKit does with a second
//     `applicationShouldTerminate` while the first reply is pending was not found documented either way (item
//     10), so the proof is twofold: `LifecycleQuitSequenceTests` shows this function starts exactly one task and
//     replies once, and the end-to-end quit test shows the app really exits. Returning `.terminateCancel` would
//     risk cancelling the pending reply, so it is not used.
//  2. A close or project switch is running (`LifecycleEntry.current`): JOIN it (`joinQuit`), after `LifecycleEntry.noteQuitStarted()`
//     (t-eb07cd67: it drops a close or open held behind the running one, and every project command after it does nothing). The quit token
//     replaces the lifecycle's on its editor state, the shared deadline is tightened to the quit's, and ONE task
//     waits for the lifecycle's task, makes the automatic version if the lifecycle's tail did not, and replies.
//  3. Nothing to save: no editor state, or empty content with NO project open, means `.terminateNow`. The old
//     shortcut was just `content.isEmpty`, which skipped the save for a user who deleted everything and quit
//     inside the 2s block-sync debounce, so the deletion never reached the database and the old text came back
//     on reopen (review row C19). With a project open the sequence runs: F sends the deletion, and the empty
//     fetch is a valid answer (N28).
//  4. Otherwise quit's own sequence: arm the quit token, call `LifecycleEntry.noteQuitStarted()`, run the save sequence
//     (`flushForQuit`), make the automatic version, reply.
//
//  Rules, every path: the reply is ALWAYS `true` (A36); the automatic version is ALWAYS attempted (N40; the
//  5-minute throttle still applies); the writer barrier is held until the process exits; the version is made with
//  the backup service CAPTURED in the host (`LifecycleHost.backupForQuit`, N4), never
//  `AppDelegate.autoBackupService`, which the next ContentView overwrites (Getting Started). Quit takes as long as
//  its automatic version takes; there is no hard ceiling (P13).
//

import AppKit

extension AppDelegate {

    /// The whole quit decision and sequence (item 31). Returns what `applicationShouldTerminate` returns; when it
    /// is `.terminateLater`, `reply(true)` is called exactly once when the save and the automatic version are done.
    func runQuitSequence(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        // 1. A second Cmd-Q (item 10).
        if quitTask != nil {
            DebugLog.log(.lifecycle, "[Quit] a quit is already running: this request starts nothing (.terminateLater)")
            return .terminateLater
        }
        let env = LifecycleEntry.environment

        // 2. A close or project switch is running: join it.
        if let running = LifecycleEntry.current {
            // t-eb07cd67: a close or open held behind the running one is dropped, and so is every project command after this
            // one: the app is quitting.
            LifecycleEntry.noteQuitStarted()
            return joinQuit(to: running, bounds: env.bounds, reply: reply)
        }

        // 3. Nothing to save.
        guard let editorState else {
            DebugLog.log(.lifecycle, "[Quit] no editor state: terminating now")
            return .terminateNow
        }
        guard !editorState.content.isEmpty || env.hasOpenProject() else {
            DebugLog.log(.lifecycle, "[Quit] empty content and no open project: terminating now")
            return .terminateNow
        }
        guard let host = editorState.lifecycleHost else {
            // No mounted editor to save from. `applicationWillTerminate`'s direct flush is the safety net.
            DebugLog.log(.lifecycle, "[Quit] no editor host: terminating now")
            return .terminateNow
        }

        // 4. Quit's own sequence. The token is armed before this function returns, and `noteQuitStarted` makes a Cmd-W or Cmd-O
        // right behind the Cmd-Q do nothing (the app is quitting) instead of racing the quit for the editor.
        _ = editorState.armLifecycle(.quit, wasGettingStarted: env.isGettingStartedProject())
        guard let token = editorState.activeLifecycle, token.kind == .quit else {
            DebugLog.log(.lifecycle, "[Quit] could not arm a quit token: terminating now")
            return .terminateNow
        }
        LifecycleEntry.noteQuitStarted()
        let controller = env.structuralUndoController()
        let bounds = env.bounds
        let deadline = LifecycleDeadline(total: bounds.quitTotal)
        DebugLog.log(.lifecycle, "[Quit] own sequence: token=\(token.id), \(deadline.remaining)s")
        quitTask = Task { @MainActor in
            _ = await editorState.flushForQuit(
                token: token, host: host, structuralUndoController: controller, deadline: deadline, bounds: bounds)
            // N40: the automatic version is always attempted (the 5-minute throttle still applies), with this host's
            // own backup service (N4).
            await host.backupForQuit()
            editorState.lifecycleBackupDoneFor = token.id
            self.completeQuit(shouldTerminate: true, reply: reply)
        }
        return .terminateLater
    }

    // MARK: - Joining a close or project switch

    /// Joins the lifecycle running in `running` (plan section 4.5 check 2). The quit token replaces the
    /// lifecycle's on its editor state (the lifecycle's own clear becomes a no-op and every gate stays armed), the
    /// shared deadline is tightened to the quit's, and ONE task finishes the quit.
    private func joinQuit(
        to running: LifecycleEntry.Current,
        bounds: LifecycleBounds,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        let editorState = running.editorState
        _ = editorState.armLifecycle(.quit, wasGettingStarted: running.token.wasGettingStarted)
        guard let quitToken = editorState.activeLifecycle, quitToken.kind == .quit else {
            DebugLog.log(.lifecycle, "[Quit] could not join the running \(running.token.kind): terminating now")
            return .terminateNow
        }
        running.deadline.tighten(to: LifecycleDeadline(total: bounds.quitTotal))
        DebugLog.log(
            .lifecycle,
            "[Quit] joined \(running.token.kind) token=\(running.token.id) as \(quitToken.id), \(running.deadline.remaining)s left")
        quitTask = Task { @MainActor in
            await self.finishJoinedQuit(running: running, quitToken: quitToken, bounds: bounds)
            self.completeQuit(shouldTerminate: true, reply: reply)
        }
        return .terminateLater
    }

    /// What the joined quit does once it has joined:
    ///
    /// - waits for the joined lifecycle's task, but never past `remaining - quitBackupReserve`, so the automatic
    ///   version keeps its reserve. A lifecycle still running at that bound (a wedged `perform` or tail) is left
    ///   behind and logged; its save, if it was not finished, is counted as a lost whole-document write (item 15);
    /// - if the lifecycle ENDED without finishing its save (a close or switch that gave up on a section operation
    ///   before the quit's token replaced its own), runs quit's own sequence on that editor state with the
    ///   lifecycle's captured host and controller, against the shared (tightened) deadline;
    /// - makes the automatic version unless the lifecycle's tail already did (`lifecycleBackupDoneFor`), with the
    ///   backup service the lifecycle CAPTURED (N4), and always when no tail ran: a `perform` skipped for this quit
    ///   (N6) or a lifecycle that never reached its tail leaves the old project's service untouched.
    private func finishJoinedQuit(
        running: LifecycleEntry.Current,
        quitToken: LifecycleToken,
        bounds: LifecycleBounds
    ) async {
        let editorState = running.editorState
        let waitBound = running.deadline.bound(own: bounds.quitTotal, floor: bounds.quitBackupReserve)
        let ended: Bool
        switch await raceAgainstTimeout(.seconds(waitBound), { await running.task.value }) {
        case .finished: ended = true
        case .timedOut: ended = false
        }
        let saved = editorState.lifecycleFlushDoneFor == running.token.id
        if !ended {
            DebugLog.alwaysPersisted(
                "[Quit] the joined \(running.token.kind) (token=\(running.token.id)) was still running after \(waitBound)s: "
                    + "not waiting for it (its save was \(saved ? "done" : "NOT done"))")
            if !saved {
                editorState.blockSyncService?.reportLifecycleWholeDocumentLost(
                    reason: "quit exit: the joined \(running.token.kind)'s save had not finished")
            }
        } else if !saved {
            DebugLog.log(.lifecycle, "[Quit] the joined \(running.token.kind) ended without saving: running quit's own sequence")
            _ = await editorState.flushForQuit(
                token: quitToken,
                host: running.host,
                structuralUndoController: running.structuralUndoController,
                deadline: running.deadline,
                bounds: bounds
            )
        }
        if editorState.lifecycleBackupDoneFor != running.token.id {
            await running.host.backupForQuit()
        }
        editorState.lifecycleBackupDoneFor = running.token.id
    }

    // MARK: - Completing

    /// The one place a quit ends. The reply is always `true` today (A36); a path that ever replies otherwise must
    /// also let a later quit start again, so `quitTask` is reset for it.
    func completeQuit(shouldTerminate: Bool, reply: @MainActor (Bool) -> Void) {
        if shouldTerminate {
            didFlushForQuit = true
            removeEscapeKeyMonitor()
        } else {
            quitTask = nil
        }
        reply(shouldTerminate)
    }
}
