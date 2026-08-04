//
//  AppDelegate+WindowFramePersistence.swift
//  final final
//
//  Hand-rolled main-window frame persistence: coalesces the many per-tick resize/move
//  notifications a drag gesture produces down to a single debounced UserDefaults write. See
//  `WindowFrameCoalescer` and `saveMainWindowFrame`'s doc comment for why this exists instead
//  of AppKit's own frame-autosave mechanism.
//

import AppKit

extension AppDelegate {
    /// Disables AppKit's own classic frame-autosave mechanism (`NSWindow.setFrameAutosaveName`/
    /// `saveFrame(usingName:)`) for `window`, called right after the window is captured as
    /// `mainWindow`.
    ///
    /// This targets a distinct, independent write source from the hand-rolled frame persistence
    /// documented on `saveMainWindowFrame`/`restoreFullScreenIfNeeded`: SwiftUI's own window
    /// scene sets a frame-autosave name on the window it creates (confirmed below), so *even
    /// though* this app never calls `saveFrame(usingName:)` itself, AppKit may still fire its
    /// own `saveFrameUsingName:` on live-resize/move end for that autosave name -- a second,
    /// independent CFPreferences write that would compete for the same expensive cfprefsd merge
    /// cost `WindowFrameCoalescer` exists to avoid on this app's own writes. Clearing the name
    /// (`setFrameAutosaveName("")`) turns that mechanism off if it exists.
    ///
    /// CONFIRMED: a real diagnostic log capture from a running build showed
    /// `window.frameAutosaveName` as a non-empty SwiftUI-derived value (a
    /// `SwiftUI.ModifiedContent<...>-1-AppWindow-1`-shaped string) immediately before this
    /// method clears it. SwiftUI's window scene genuinely does assign an implicit autosave name
    /// here, and `setFrameAutosaveName("")` is disabling a real, active AppKit mechanism -- not
    /// a no-op guard against a hypothetical. The one-shot corroborating check that used to live
    /// in `windowDidEndLiveResize` (and its guarding flag) existed only to help confirm this and
    /// has been removed now that the log capture above settled it. The log line below is kept:
    /// unlike that one-shot check, it runs unconditionally on every launch, so it stays useful
    /// as an ongoing signal that this mechanism is still active (e.g. if a future macOS/SwiftUI
    /// change stops setting an autosave name here, or starts setting a different one).
    func disableFrameAutosave(for window: NSWindow) {
        DebugLog.log(.lifecycle, "[AppDelegate] window.frameAutosaveName before clearing: '\(window.frameAutosaveName)'")
        _ = window.setFrameAutosaveName("")
    }

    func windowDidResize(_ notification: Notification) {
        saveMainWindowFrame(from: notification, trigger: "resize")
    }

    func windowDidMove(_ notification: Notification) {
        saveMainWindowFrame(from: notification, trigger: "move")
    }

    /// Flushes immediately when a live resize gesture ends -- a latency win for the common case
    /// (frame lands in UserDefaults right away instead of waiting out the debounce), NOT the
    /// safety net for correctness. That's `applicationWillTerminate`'s unconditional flush; this
    /// one is best-effort on top of it.
    func windowDidEndLiveResize(_ notification: Notification) {
        flushWindowFrame(trigger: "endLiveResize")
    }

    func applicationDidResignActive(_ notification: Notification) {
        flushWindowFrame(trigger: "resignActive")
    }

    /// Notes the main window's current frame with the coalescer and schedules a debounced flush.
    /// See `restoreFullScreenIfNeeded` for why frame persistence bypasses AppKit's frame-autosave
    /// APIs entirely rather than using `saveFrame(usingName:)`.
    ///
    /// This no longer writes UserDefaults synchronously on every resize/move tick: a Time
    /// Profiler-verified investigation found that doing so during a live drag triggers a
    /// CFPreferences KVO-notification storm and cfprefsd daemon merge that dominates CPU. Writes
    /// are now coalesced to (at most) one per gesture via `WindowFrameCoalescer` and
    /// `scheduleFrameFlush()`.
    ///
    /// Accepted trade-off: before this change every tick wrote UserDefaults directly, so even an
    /// abnormal termination (crash, SIGKILL, force-quit, power loss) preserved the latest window
    /// frame; now, an abnormal termination that skips `applicationWillTerminate` can lose up to
    /// the in-progress gesture -- near-zero window for resizes (flushed immediately via
    /// `windowDidEndLiveResize`), up to the full gesture duration for moves (the debounce timer
    /// can't fire mid-drag -- it runs in `.default` run loop mode, which a live move's
    /// event-tracking loop doesn't service, see `scheduleFrameFlush()` -- so nothing flushes
    /// until the drag ends). If window position is ever reported lost after a crash, this is
    /// why -- it's an accepted cost of the performance fix, not a bug.
    private func saveMainWindowFrame(from notification: Notification, trigger: String) {
        guard !TestMode.isTesting else { return }
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // Entering/exiting full screen fires resize/move with the screen's own bounds — not a
        // real windowed frame. Skip so the last genuine windowed frame is left untouched;
        // full-screen state itself is tracked separately (see windowDidEnterFullScreen).
        guard !window.styleMask.contains(.fullScreen) else { return }

        frameCoalescer.note(NSStringFromRect(window.frame))
        scheduleFrameFlush()
    }

    /// Debounces the coalesced window-frame write: (re)starts a 0.5s one-shot timer on every
    /// call, so a burst of resize/move ticks collapses to a single flush after the gesture goes
    /// quiet.
    ///
    /// Deliberately left in the timer's default `.default` run loop mode (NOT added to
    /// `.common`): AppKit runs a live-resize/move drag's event tracking in
    /// `NSEventTrackingRunLoopMode`, which `.default`-mode timers don't fire in, so the timer sits
    /// overdue for as long as the drag continues (it's invalidated and recreated on every tick
    /// anyway, so it would rarely get the chance to fire mid-drag even under `.common` -- only if
    /// the gesture paused for more than 0.5s without a tick). The moment tracking ends and the run
    /// loop returns to `.default` mode, that overdue timer fires on the very next pass. That
    /// prompt fire is what gives window *moves* their flush-at-drag-end behavior: unlike resizes,
    /// which get an immediate flush from `windowDidEndLiveResize` (see above), there is no
    /// `windowDidEndLiveMove` delegate callback to flush from directly, so this debounce timer is
    /// the only thing that flushes a move once the drag ends.
    private func scheduleFrameFlush() {
        frameFlushTimer?.invalidate()
        frameFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushWindowFrame(trigger: "debounce")
            }
        }
    }

    /// Writes the coalesced window frame to UserDefaults, if anything is pending. Unconditional
    /// by design -- it does not re-check TestMode/mainWindow/fullScreen itself; correctness comes
    /// entirely from `saveMainWindowFrame`'s guards on the note side, since only values that
    /// already passed those guards ever reach the coalescer.
    func flushWindowFrame(trigger: String) {
        frameFlushTimer?.invalidate()
        frameFlushTimer = nil
        guard let value = frameCoalescer.takeValueToWrite() else { return }
        // Log BEFORE writing, not after -- and don't "clean this up" by moving it back below
        // WindowFrameStore.save(value). A Time Profiler-verified investigation (the same one that
        // motivated the coalescer above) found that DebugLog.log() here reads UserDefaults itself
        // (DiagnosticLogFile.isEnabled -> UserDefaults.bool(forKey:)), and doing that read
        // immediately after WE write to UserDefaults reliably triggered a ~5s hang: macOS's
        // cfprefsd appears to force a full, expensive domain re-merge on a read that follows a
        // write to the same domain moments earlier -- the exact CFPreferences cost this whole
        // mechanism exists to avoid. Logging first, while the domain is still clean/cached, sidesteps
        // the trap; logging after the write walks right back into it.
        DebugLog.log(.lifecycle, "[AppDelegate] Saving main window frame (trigger: \(trigger)): \(value)")
        WindowFrameStore.save(value)
    }
}
