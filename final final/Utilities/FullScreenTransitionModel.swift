//
//  FullScreenTransitionModel.swift
//  final final
//

/// Pure state machine coordinating native full screen transitions.
///
/// `NSWindow.toggleFullScreen(nil)` is asynchronous, and a diagnostic probe on the real app
/// confirmed a critical AppKit behavior: a second `toggleFullScreen(nil)` issued while a
/// transition is already in flight is **silently discarded** — no notification fires, no
/// fail-delegate method runs, nothing. Doing that reliably wedges the window (observed 4/4
/// times) into "full screen, with the app's own focus-mode state believing it exited."
///
/// This model exists to make that mistake structurally impossible: `request(_:)` never issues
/// a second toggle while `.entering`/`.exiting` is in progress. Instead it records the latest
/// desired intent in `pending` and coalesces it into a single corrective toggle — issued only
/// once the in-flight transition's matching `did*` event lands, and only if that intent still
/// disagrees with where the transition landed.
///
/// No AppKit import, no statics: this is pure value-type logic, constructible fresh and
/// exercised deterministically in tests without a real `NSWindow` or run loop.
/// `FullScreenManager` owns the single live instance and is the only thing that talks to AppKit.

/// The full screen state a caller wants the window to be in.
enum FullScreenIntent: Equatable, CustomStringConvertible {
    case fullScreen
    case windowed

    var description: String {
        switch self {
        case .fullScreen: return "fullScreen"
        case .windowed: return "windowed"
        }
    }
}

/// What the caller should do in response to `request(_:)` or `observe(_:)`.
enum TransitionAction: Equatable {
    /// Call `window.toggleFullScreen(nil)` now.
    case issueToggle
    /// A transition is already in flight; the intent has been recorded as `pending` and will
    /// be handled (if still necessary) when the current transition completes.
    case waitForCurrentTransition
    /// Nothing to do — the window already is, or is already headed toward, the desired state.
    case alreadySatisfied
}

/// The model's current understanding of the window's full screen state.
enum Phase: Equatable {
    case idle(isFullScreen: Bool)
    case entering
    case exiting
}

/// One AppKit full-screen notification, the watchdog firing in place of a missing one, or
/// AppKit's fail-delegate reporting a transition definitively did NOT happen.
enum TransitionEvent: Equatable, CustomStringConvertible {
    case willEnter
    case didEnter
    case willExit
    case didExit
    case watchdogTimeout
    case transitionFailed

    var description: String {
        switch self {
        case .willEnter: return "willEnter"
        case .didEnter: return "didEnter"
        case .willExit: return "willExit"
        case .didExit: return "didExit"
        case .watchdogTimeout: return "watchdogTimeout"
        case .transitionFailed: return "transitionFailed"
        }
    }
}

/// Pure value type coordinating full screen transitions. See the file doc comment above.
struct FullScreenTransitionModel: Equatable {
    private(set) var phase: Phase
    private(set) var pending: FullScreenIntent?

    init(phase: Phase = .idle(isFullScreen: false), pending: FullScreenIntent? = nil) {
        self.phase = phase
        self.pending = pending
    }

    /// Requests the given full-screen intent. Never toggles mid-transition — see the file doc
    /// comment for why a second toggle in that window would be silently dropped by AppKit.
    mutating func request(_ intent: FullScreenIntent) -> TransitionAction {
        switch phase {
        case .entering, .exiting:
            pending = intent
            return .waitForCurrentTransition
        case .idle(let isFullScreen):
            let satisfied = (intent == .fullScreen) == isFullScreen
            pending = nil
            if satisfied {
                return .alreadySatisfied
            }
            phase = (intent == .fullScreen) ? .entering : .exiting
            return .issueToggle
        }
    }

    /// Feeds one AppKit (or watchdog) event into the model. Total over all phases: every event
    /// is a benign state update, and only a `did*` event that disagrees with `pending` ever
    /// produces a corrective toggle.
    mutating func observe(_ event: TransitionEvent) -> TransitionAction {
        switch event {
        case .willEnter:
            phase = .entering
            return .alreadySatisfied
        case .willExit:
            phase = .exiting
            return .alreadySatisfied
        case .didEnter:
            phase = .idle(isFullScreen: true)
            return resolvePending(reachedFullScreen: true)
        case .didExit:
            phase = .idle(isFullScreen: false)
            return resolvePending(reachedFullScreen: false)
        case .watchdogTimeout:
            // FAIL-OPEN. This is the single most important detail in this type: a corrective
            // toggle here would re-create the exact wedge this model exists to prevent, because
            // we cannot tell from a timeout alone whether AppKit's transition is still genuinely
            // in flight (in which case a toggle would be silently dropped) or has already
            // finished with its notification lost for some other reason. Trust the destination
            // of whichever transition was in flight, stop waiting, and never touch the mask.
            resyncWithoutToggle(trustingDestination: true)
            return .alreadySatisfied
        case .transitionFailed:
            // AppKit told us definitively that whichever transition was in flight did NOT
            // happen (windowDidFailToEnter/ExitFullScreen). Opposite trust direction from
            // watchdogTimeout: there, an unconfirmed transition is assumed to have probably
            // succeeded; here, resync to the ORIGIN, because we know for a fact it didn't. Still
            // never issues a corrective toggle -- AppKit just rejected one transition, and
            // firing another immediately risks the same silent-discard problem this model
            // exists to prevent, so any pending intent is dropped rather than acted on.
            resyncWithoutToggle(trustingDestination: false)
            return .alreadySatisfied
        }
    }

    /// Shared resync logic for `.watchdogTimeout` and `.transitionFailed`: resolves an
    /// in-flight phase straight to `.idle` without ever issuing a corrective toggle, and always
    /// drops `pending` rather than acting on it (both callers explain why in their own doc
    /// comments above). `trustingDestination` picks which side of the transition to believe:
    /// `true` for the watchdog (an unconfirmed transition probably succeeded), `false` for a
    /// fail-delegate (AppKit told us it definitely didn't).
    private mutating func resyncWithoutToggle(trustingDestination: Bool) {
        switch phase {
        case .entering:
            phase = .idle(isFullScreen: trustingDestination)
        case .exiting:
            phase = .idle(isFullScreen: !trustingDestination)
        case .idle:
            break
        }
        pending = nil
    }

    /// Whether the window should be treated as full screen right now. Uses destination
    /// semantics mid-transition (`.entering` reads as full screen, `.exiting` reads as
    /// windowed) rather than waiting for the transition to land — this is intentional so
    /// dependent UI (e.g. focus mode's own full-screen snapshot) doesn't have to know about
    /// transitions at all.
    func isEffectivelyFullScreen() -> Bool {
        switch phase {
        case .idle(let isFullScreen): return isFullScreen
        case .entering: return true
        case .exiting: return false
        }
    }

    /// Whether the window is settled in full screen right now — unlike
    /// `isEffectivelyFullScreen()`, this does **not** use destination semantics: a transition
    /// that is still `.entering` reads as **not** full screen here, even though it is headed
    /// there.
    ///
    /// This is what Focus Mode's own entry snapshot needs. An `.entering` phase at the moment
    /// a new Focus Mode session takes its "was the window already full screen" snapshot might
    /// be that same window heading toward full screen only because an *earlier, already-ended*
    /// Focus Mode session's own request never got to resolve (e.g. interrupted mid-transition) —
    /// not a real pre-existing full-screen state the user set independently. Reading that as
    /// "yes, already full screen" via `isEffectivelyFullScreen()` is exactly what stranded users
    /// in full screen after exiting Focus Mode, having never asked for native full screen at
    /// all. See `FullScreenTransitionModelTests` for the traced scenario.
    func isSettledFullScreen() -> Bool {
        if case .idle(let isFullScreen) = phase {
            return isFullScreen
        }
        return false
    }

    /// Resolves `pending` against the state a transition just reached, clearing it either way.
    private mutating func resolvePending(reachedFullScreen: Bool) -> TransitionAction {
        guard let pending else { return .alreadySatisfied }
        let wantsFullScreen = (pending == .fullScreen)
        self.pending = nil
        guard wantsFullScreen != reachedFullScreen else {
            return .alreadySatisfied
        }
        phase = wantsFullScreen ? .entering : .exiting
        return .issueToggle
    }
}
