//
//  FullScreenManager.swift
//  final final
//

import AppKit

/// Thin AppKit-facing shell around `FullScreenTransitionModel`. Owns the single live model
/// instance, the main window's full-screen notification observers, and a watchdog that fails
/// the model open if AppKit never delivers the matching `did*` notification.
///
/// This is a namespace (no cases, no instances) — all state is static because there is exactly
/// one main window's full-screen transition to coordinate. Callers deal only in intents
/// (`request(_:)`, `isEffectivelyFullScreen()`); nothing outside this file calls
/// `window.toggleFullScreen(nil)` directly.
///
/// The permanent `.lifecycle` logging below is deliberate, not leftover: the failure modes it
/// covers (a request arriving with no window yet, a transition silently timing out, a pending
/// intent getting coalesced or dropped) are otherwise invisible — there is no other observable
/// signal when any of them happens.
@MainActor
enum FullScreenManager {
    private static var model = FullScreenTransitionModel()
    private static var observerTokens: [NSObjectProtocol] = []
    private static var watchdog: DispatchWorkItem?

    /// An intent requested before any window existed yet to bootstrap against (e.g. launch-time
    /// focus mode restoration racing window creation). Consumed by the next `bootstrap(window:)`
    /// call instead of being silently dropped.
    private static var pendingBootstrapIntent: FullScreenIntent?

    /// ~10x AppKit's real full-screen transition time (~500ms observed). Not derived from
    /// anything more precise than that — it exists purely to recover from a transition whose
    /// `did*` notification never arrives, not to model real transition timing.
    private static let watchdogInterval: TimeInterval = 5.0

    /// (Re)initializes the model and notification observers for `window`. Idempotent across
    /// different windows — safe to call every time a window is (re)captured, including the
    /// FB15577018 recovery path in `AppDelegate`.
    static func bootstrap(window: NSWindow) {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        watchdog?.cancel()
        watchdog = nil

        // No transition can be in flight for a window we're only just capturing, so seeding
        // directly from styleMask here is safe.
        let isFullScreen = window.styleMask.contains(.fullScreen)
        model = FullScreenTransitionModel(phase: .idle(isFullScreen: isFullScreen))

        let center = NotificationCenter.default
        let events: [(Notification.Name, TransitionEvent)] = [
            (NSWindow.willEnterFullScreenNotification, .willEnter),
            (NSWindow.didEnterFullScreenNotification, .didEnter),
            (NSWindow.willExitFullScreenNotification, .willExit),
            (NSWindow.didExitFullScreenNotification, .didExit)
        ]
        for (name, event) in events {
            // queue: nil delivers synchronously on the posting thread (AppKit's own main-thread
            // full-screen machinery), so the model update happens before anything else can
            // observe styleMask. queue: .main would hop async and risk reordering the model
            // update relative to the mask change that triggered the notification.
            let token = center.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated {
                    FullScreenManager.handle(event)
                }
            }
            observerTokens.append(token)
        }
        DebugLog.log(.lifecycle, "[FullScreenManager] observers re-registered for a new window, isFullScreen=\(isFullScreen)")

        if let intent = pendingBootstrapIntent {
            pendingBootstrapIntent = nil
            DebugLog.log(.lifecycle, "[FullScreenManager] intent replayed at bootstrap: \(intent)")
            apply(model.request(intent), window: window)
        }
    }

    /// Requests the given full-screen intent for the app's main window. If no window exists
    /// yet, stores the intent to be replayed at the next `bootstrap(window:)` instead of
    /// silently dropping it.
    static func request(_ intent: FullScreenIntent) {
        DebugLog.log(.lifecycle, "[FullScreenManager] request received: \(intent)")
        guard let window = AppDelegate.shared?.mainWindow else {
            pendingBootstrapIntent = intent
            DebugLog.log(.lifecycle, "[FullScreenManager] intent stored with no window: \(intent)")
            return
        }
        apply(model.request(intent), window: window)
    }

    /// Whether the window should currently be treated as full screen — destination semantics
    /// mid-transition. See `FullScreenTransitionModel.isEffectivelyFullScreen()`.
    static func isEffectivelyFullScreen() -> Bool {
        model.isEffectivelyFullScreen()
    }

    /// Whether the window is settled in full screen right now (not mid-transition either way).
    /// See `FullScreenTransitionModel.isSettledFullScreen()`.
    static func isSettledFullScreen() -> Bool {
        model.isSettledFullScreen()
    }

    /// Called by `AppDelegate`'s `NSWindowDelegate` fail-delegate methods
    /// (`windowDidFailToEnterFullScreen` / `windowDidFailToExitFullScreen`). There is no `did*`
    /// notification after a failed transition, so without this the watchdog would eventually
    /// fire and resync toward the DESTINATION (its whole design assumes an unconfirmed
    /// transition probably succeeded) — recording, say, `idle(isFullScreen: true)` for a window
    /// that is actually still windowed. After that, `request(.fullScreen)` reads as
    /// `.alreadySatisfied` forever and Focus Mode can never reach full screen again. See
    /// `TransitionEvent.transitionFailed`.
    static func notifyTransitionFailed() {
        handle(.transitionFailed)
    }

    /// Feeds one AppKit notification (or the watchdog, or a fail-delegate) into the model and
    /// applies the result.
    private static func handle(_ event: TransitionEvent) {
        switch event {
        case .willEnter, .willExit:
            // A transition just started -- whether FullScreenManager issued it (apply's
            // .issueToggle case already armed a watchdog for that call) or AppKit did on its
            // own (green button, Ctrl+Cmd+F, Mission Control), it must be covered: the whole
            // premise of this design is that did* delivery is untrustworthy, and that's just as
            // true for transitions Focus Mode never asked for. Re-arming here is a harmless
            // reset of the same timer for app-issued toggles, and the ONLY coverage at all for
            // user/system-issued ones.
            armWatchdog()
        case .didEnter, .didExit, .transitionFailed:
            watchdog?.cancel()
            watchdog = nil
        case .watchdogTimeout:
            break
        }

        let action = model.observe(event)
        switch action {
        case .issueToggle:
            DebugLog.log(.lifecycle, "[FullScreenManager] pending coalesced into a corrective toggle after \(event)")
            // Deferred hop: never re-enter toggleFullScreen from inside AppKit's own
            // did*-notification dispatch. Re-resolve the window here (rather than capturing it
            // from handle's caller) so a stale reference can't be used if the window changed --
            // or disappeared -- by the time this async block actually runs.
            DispatchQueue.main.async {
                guard let window = AppDelegate.shared?.mainWindow else {
                    DebugLog.log(.lifecycle, "[FullScreenManager] coalesced toggle dropped: no window at dispatch time")
                    return
                }
                apply(.issueToggle, window: window)
            }
        case .waitForCurrentTransition:
            break  // model.observe(_:) never returns this
        case .alreadySatisfied:
            switch event {
            case .didEnter, .didExit:
                DebugLog.log(.lifecycle, "[FullScreenManager] pending dropped as satisfied after \(event)")
            case .transitionFailed:
                DebugLog.log(.lifecycle, "[FullScreenManager] resynchronized after a failed transition (no corrective toggle)")
            default:
                break
            }
        }
    }

    /// Applies a `TransitionAction` against `window`. The only place in this file (and,
    /// modulo `AppDelegate`'s own bootstrap path, in the app) that calls
    /// `window.toggleFullScreen(nil)`.
    private static func apply(_ action: TransitionAction, window: NSWindow) {
        switch action {
        case .issueToggle:
            DebugLog.log(.lifecycle, "[FullScreenManager] toggle issued: window.toggleFullScreen(nil)")
            window.toggleFullScreen(nil)
            armWatchdog()
        case .waitForCurrentTransition:
            DebugLog.log(.lifecycle, "[FullScreenManager] request deferred: transition already in flight")
        case .alreadySatisfied:
            break
        }
    }

    private static func armWatchdog() {
        watchdog?.cancel()
        let workItem = DispatchWorkItem {
            DebugLog.log(.lifecycle, "[FullScreenManager] watchdog fired: no matching did* notification within \(watchdogInterval)s, failing open")
            FullScreenManager.handle(.watchdogTimeout)
        }
        watchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogInterval, execute: workItem)
    }

    /// Resets all static state for unit tests. `AppDelegate.shared` is nil under unit tests,
    /// so `request(_:)` always takes the "no window" branch there regardless — this exists so
    /// tests don't leak observers, a pending watchdog, or stored intents across runs.
    static func resetForTesting() {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        watchdog?.cancel()
        watchdog = nil
        model = FullScreenTransitionModel()
        pendingBootstrapIntent = nil
    }
}
