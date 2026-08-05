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
    /// Returns the bare autosave name captured off `window` before it's cleared, so callers can
    /// thread it into the dead-key sweep's protected-name set (see
    /// `AppDelegate+AutosaveKeyTracking.swift`). Empty string if AppKit hadn't assigned one.
    @discardableResult
    func disableFrameAutosave(for window: NSWindow) -> String {
        let capturedName = window.frameAutosaveName
        DebugLog.log(
            .lifecycle,
            "[AppDelegate] window.frameAutosaveName before clearing: '\(capturedName)', "
                + "window.identifier: '\(window.identifier?.rawValue ?? "nil")'"
        )
        _ = window.setFrameAutosaveName("")
        return capturedName
    }

    /// Shared core of the two `mainWindow` capture sites in `applicationDidFinishLaunching`
    /// (the primary launch path and the FB15577018 recovery fallback) -- extracted so neither
    /// call site has to repeat it, and so `applicationDidFinishLaunching` itself stays under
    /// SwiftLint's cyclomatic-complexity limit. Each caller still does its own site-specific
    /// follow-up afterward (the primary path additionally logs the saved-frame comparison and
    /// handles the fullscreen-space-switch; the fallback has neither).
    func captureMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        // A launch-time Finder/`open(1)` double-click delivers its "open documents"
        // Apple Event around the same time as this capture, and the order between
        // the two is not guaranteed (see closeSpuriousFinderOpenWindows's doc comment).
        // application(_:open:) already calls closeSpuriousFinderOpenWindows() itself, but
        // that call no-ops via its `guard let mainWindow` when it happens to run BEFORE
        // this capture -- mainWindow isn't captured yet, so it can't tell the real window
        // from the spurious one, and (having already run) never gets a second chance to
        // clean up once mainWindow does exist. Sweeping again here, now that mainWindow
        // is finally known, closes that gap regardless of which of the two ran first.
        closeSpuriousFinderOpenWindows()
        capturedWindowFrameAutosaveName = disableFrameAutosave(for: window)
        if !TestMode.isTesting {
            SplitViewAutosaveNaming.stabilize(for: window)
        }
        scheduleAutosaveKeySweep()
        FullScreenManager.bootstrap(window: window)
        restoreFullScreenIfNeeded(window)
    }

    /// Closes the extra window AppKit spawns for every Finder/`open(1)`-delivered "open documents"
    /// event on this app. Root cause (confirmed via targeted window-count instrumentation): declaring
    /// `.ff` as an "Editor"-role `CFBundleDocumentTypes` entry, combined with using a plain
    /// `WindowGroup` (not `DocumentGroup`), makes AppKit create a brand-new WindowGroup window scene
    /// for every incoming open-document Apple Event — entirely independent of this method's own
    /// single-window state handling via `mainWindow`. Same cleanup pattern already used above for
    /// macOS-restored "version-history" windows.
    ///
    /// Timing relative to `application(_:open:)` is NOT reliable in either direction. It was once
    /// assumed the spurious window always exists by the time that method runs; CONFIRMED false via
    /// repeated same-app-instance `open`-while-running probes (CGWindowList, `onscreen=true`
    /// persisting for seconds): the window for a given Apple Event can just as easily materialize
    /// a moment AFTER `application(_:open:)`'s immediate call to this method already ran and found
    /// nothing. That's why `application(_:open:)` also schedules a short delayed re-sweep, not just
    /// the immediate one — see its call site.
    ///
    /// Also no-ops (by design, via the `guard let mainWindow` below) until `mainWindow` is
    /// captured — it can't tell the real window from a spurious one before then. That capture
    /// happens asynchronously (see `applicationDidFinishLaunching`'s `DispatchQueue.main.async`
    /// block and its FB15577018 recovery fallback), so a launch-time Finder double-click can call
    /// this method before `mainWindow` exists — CONFIRMED via a cold `open -a`-launched instance
    /// leaving 2 persistent windows (CGWindowList-verified) back when `application(_:open:)` was
    /// this method's only call site. Both `mainWindow`-capture sites now call this again right
    /// after setting `mainWindow`, so whichever ordering occurs, the second call (from a capture
    /// site, or from `application(_:open:)`, whichever runs with `mainWindow` already non-nil)
    /// catches the spurious window.
    ///
    /// Calling this repeatedly (immediate + delayed + both capture sites, across possibly several
    /// Finder-open events in a row) is safe: `window.close()` on an already-hidden spurious window
    /// is a harmless no-op, and observed evidence is that a closed spurious `NSWindow` stays
    /// enumerable in `NSApp.windows` (just `onscreen=false`) rather than being removed outright —
    /// so re-finding and re-closing the same one on a later sweep is expected, not a sign of a
    /// leak or a new duplicate.
    ///
    /// Not `private` -- called from `application(_:open:)` in `AppDelegate.swift`.
    func closeSpuriousFinderOpenWindows() {
        guard let mainWindow else {
            DebugLog.log(.lifecycle, "[FINDER-OPEN][DIAG] closeSpuriousFinderOpenWindows: mainWindow is nil, no-op")
            return
        }
        let allWindows = NSApp.windows
        // Building the summary needs a multi-line `.map`/`.joined`, which can't be written as a
        // single `@autoclosure` expression -- so gate it explicitly with `isEnabled` (exactly
        // what that API is for per its own doc comment: skipping work done OUTSIDE a log() call)
        // rather than paying for the map/joined on every sweep in every build.
        if DebugLog.isEnabled(.lifecycle) {
            let summary = allWindows.map { window in
                "(id=\(window.identifier?.rawValue ?? "nil") isMain=\(window === mainWindow) "
                    + "isVisible=\(window.isVisible) frame=\(window.frame) num=\(window.windowNumber))"
            }.joined(separator: ", ")
            DebugLog.log(.lifecycle, "[FINDER-OPEN][DIAG] sweep: \(allWindows.count) window(s): \(summary)")
        }

        for window in allWindows where window !== mainWindow
            && window.identifier?.rawValue.contains(SceneID.mainWindow) == true {
            let visibleBefore = window.isVisible
            DebugLog.always(
                "[FINDER-OPEN] Closing spurious duplicate window: id=\(window.identifier?.rawValue ?? "nil") "
                    + "visibleBefore=\(visibleBefore) frame=\(window.frame) "
                    + "releasedWhenClosed=\(window.isReleasedWhenClosed)"
            )
            // Plain `close()` is sufficient -- CONFIRMED (CGWindowList, matched by windowNumber,
            // plus the Window menu's own item list) that once this runs the window is not
            // user-perceivable: `isVisible` flips to false immediately, and the WindowServer's
            // on-screen bounds for it collapse to zero width/height (mathematically nothing to
            // render), even though CGWindowList's raw on-screen flag keeps reporting it as
            // present -- a harmless zero-area registration this app has no control over, not a
            // second visible window. An earlier attempt to also clear that raw registration via
            // `orderOut(nil)` and forcing `isReleasedWhenClosed = true` before closing was tried
            // and DISPROVEN (identical 0x0-but-registered outcome either way) -- removed rather
            // than left in, since `isReleasedWhenClosed = true` is actively dangerous here:
            // SwiftUI's WindowGroup deliberately keeps `isReleasedWhenClosed = false` because it
            // still holds and uses these windows for its own scene bookkeeping, and forcing
            // manual release while SwiftUI may still reference the same object risks a crash
            // later (next Finder open, window restoration, app termination) with no obvious link
            // back to this code.
            window.close()
            DebugLog.log(
                .lifecycle,
                "[FINDER-OPEN][DIAG] after close(): id=\(window.identifier?.rawValue ?? "nil") "
                    + "visibleAfter=\(window.isVisible) frameAfter=\(window.frame)"
            )
        }
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
