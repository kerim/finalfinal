//
//  FullScreenTransitionModelTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Pure, deterministic tests for FullScreenTransitionModel: the state machine that keeps
//  Focus Mode from wedging the window into "full screen with focus mode off" when a second
//  toggleFullScreen(nil) lands while a transition is already in flight (a real AppKit
//  behavior confirmed by a diagnostic probe: the second call is silently discarded — no
//  notification, no fail-delegate, nothing). No AppKit involved — the model is a pure value
//  type constructed fresh in every test.
//

import Testing
@testable import final_final

@Suite("Full Screen Transition Model — Tier 2: Visible Breakage")
struct FullScreenTransitionModelTests {

    @Test("request(.fullScreen) from idle(false) issues a toggle")
    func requestFullScreenFromIdleFalseIssuesToggle() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))

        let action = model.request(.fullScreen)

        #expect(action == .issueToggle)
        #expect(model.phase == .entering)
    }

    @Test("The wedge: a request mid-transition never issues a second toggle")
    func requestMidTransitionNeverIssuesSecondToggle() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))

        #expect(model.request(.fullScreen) == .issueToggle)
        #expect(model.observe(.willEnter) == .alreadySatisfied)

        let action = model.request(.windowed)

        #expect(action == .waitForCurrentTransition)
        #expect(model.phase == .entering, "Must never toggle mid-transition")
        #expect(model.pending == .windowed)
    }

    @Test("Continuing the wedge scenario: didEnter issues the coalesced corrective toggle")
    func didEnterIssuesCoalescedCorrectiveToggle() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        _ = model.request(.fullScreen)
        _ = model.observe(.willEnter)
        _ = model.request(.windowed)

        let action = model.observe(.didEnter)

        #expect(action == .issueToggle)
        #expect(model.pending == nil)
        #expect(model.phase == .exiting)
    }

    @Test("Coalescing: rapid requests during a transition still produce exactly one toggle")
    func coalescingProducesExactlyOneToggle() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        var toggleCount = 0

        if model.request(.fullScreen) == .issueToggle { toggleCount += 1 }
        _ = model.observe(.willEnter)
        _ = model.request(.windowed)
        _ = model.request(.fullScreen)
        let finalAction = model.observe(.didEnter)
        if finalAction == .issueToggle { toggleCount += 1 }

        #expect(finalAction == .alreadySatisfied)
        #expect(toggleCount == 1, "Coalesced requests must never produce more than one toggle")
    }

    @Test("Idle no-op: requesting the already-satisfied state is a no-op")
    func idleNoOpWhenAlreadySatisfied() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: true))

        let action = model.request(.fullScreen)

        #expect(action == .alreadySatisfied)
        #expect(model.pending == nil)
    }

    @Test("Watchdog fails open: never issues a corrective toggle, trusts the in-flight destination")
    func watchdogFailsOpen() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        _ = model.request(.fullScreen)
        _ = model.observe(.willEnter)
        _ = model.request(.windowed)
        #expect(model.pending == .windowed)

        let action = model.observe(.watchdogTimeout)

        #expect(action == .alreadySatisfied)
        #expect(model.pending == nil)
        #expect(model.phase == .idle(isFullScreen: true))
    }

    @Test("A late did* event after the watchdog already fired open is a benign no-op")
    func lateEventAfterWatchdogIsNoOp() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        _ = model.request(.fullScreen)
        _ = model.observe(.willEnter)
        _ = model.request(.windowed)
        _ = model.observe(.watchdogTimeout)
        // Sanity check on setup, not the point of this test: watchdogTimeout itself already
        // clears pending, so re-asserting pending == nil after the late didEnter below would be
        // tautological (nothing on the didEnter-with-nil-pending path could set it) and would
        // prove nothing about didEnter's own behavior.
        #expect(model.pending == nil)

        let action = model.observe(.didEnter)

        #expect(action == .alreadySatisfied)
        #expect(
            model.phase == .idle(isFullScreen: true),
            "A late did* must not disturb the phase the watchdog already resolved"
        )
    }

    @Test("didExit with a disagreeing pending clears pending without a stray toggle when satisfied")
    func didExitClearsPendingWhenSatisfied() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: true))
        _ = model.request(.windowed)
        _ = model.observe(.willExit)
        _ = model.request(.windowed)
        #expect(model.pending == .windowed)

        let action = model.observe(.didExit)

        #expect(action == .alreadySatisfied)
        #expect(model.pending == nil)
    }

    // MARK: - isEffectivelyFullScreen() — destination semantics, all phases

    @Test("isEffectivelyFullScreen(): idle(true) reads true")
    func isEffectivelyFullScreenIdleTrue() {
        let model = FullScreenTransitionModel(phase: .idle(isFullScreen: true))
        #expect(model.isEffectivelyFullScreen() == true)
    }

    @Test("isEffectivelyFullScreen(): idle(false) reads false")
    func isEffectivelyFullScreenIdleFalse() {
        let model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        #expect(model.isEffectivelyFullScreen() == false)
    }

    @Test("isEffectivelyFullScreen(): entering reads true (destination semantics)")
    func isEffectivelyFullScreenEntering() {
        let model = FullScreenTransitionModel(phase: .entering)
        #expect(model.isEffectivelyFullScreen() == true)
    }

    @Test("isEffectivelyFullScreen(): exiting reads false (destination semantics)")
    func isEffectivelyFullScreenExiting() {
        let model = FullScreenTransitionModel(phase: .exiting)
        #expect(model.isEffectivelyFullScreen() == false)
    }

    // MARK: - isSettledFullScreen() — no destination semantics, all phases

    @Test("isSettledFullScreen(): idle(true) reads true")
    func isSettledFullScreenIdleTrue() {
        let model = FullScreenTransitionModel(phase: .idle(isFullScreen: true))
        #expect(model.isSettledFullScreen() == true)
    }

    @Test("isSettledFullScreen(): idle(false) reads false")
    func isSettledFullScreenIdleFalse() {
        let model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))
        #expect(model.isSettledFullScreen() == false)
    }

    @Test("isSettledFullScreen(): entering reads false, unlike isEffectivelyFullScreen()")
    func isSettledFullScreenEntering() {
        let model = FullScreenTransitionModel(phase: .entering)
        #expect(model.isSettledFullScreen() == false)
        #expect(model.isEffectivelyFullScreen() == true, "isEffectivelyFullScreen()'s destination semantics must be unchanged")
    }

    @Test("isSettledFullScreen(): exiting reads false")
    func isSettledFullScreenExiting() {
        let model = FullScreenTransitionModel(phase: .exiting)
        #expect(model.isSettledFullScreen() == false)
    }

    // MARK: - Must-fix 3 scenario: a chained, interrupted focus-mode session must not read as
    // settled full screen just because it left an earlier session's transition still entering

    @Test("Must-fix 3: an entering phase caused by a chained, already-ended session's own request must not read as settled full screen")
    func chainedInterruptedSessionDoesNotReadAsSettledFullScreen() {
        var model = FullScreenTransitionModel(phase: .idle(isFullScreen: false))

        // Session 1: Cmd+Shift+F starts entering full screen.
        #expect(model.request(.fullScreen) == .issueToggle)
        _ = model.observe(.willEnter)

        // Session 1: Esc lands mid-transition, requesting windowed. Since a transition is still
        // in flight, this only records a pending intent -- it does NOT change phase.
        #expect(model.request(.windowed) == .waitForCurrentTransition)
        #expect(model.phase == .entering)

        // Session 2 begins here (a brand new Focus Mode session, taking its own entry snapshot)
        // while the model is still .entering purely because of session 1's own not-yet-resolved
        // request. isEffectivelyFullScreen() (destination semantics, unchanged/correct for UI
        // purposes) would say true; the snapshot must NOT use that reading, or exiting session 2
        // later would leave the user stranded in full screen they never independently asked for.
        #expect(model.isSettledFullScreen() == false)
        #expect(model.isEffectivelyFullScreen() == true)
    }
}
