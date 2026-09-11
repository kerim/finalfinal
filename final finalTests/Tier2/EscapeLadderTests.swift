//
//  EscapeLadderTests.swift
//  final finalTests
//
//  Tier 2: table-driven coverage of EscapeLadder.decide/decideAfterWebDeclined (pure, no
//  AppKit) and the EscapeLadderRegistry lifecycle (UX contract §6).
//

import XCTest
@testable import final_final

@MainActor
final class EscapeLadderTests: XCTestCase {

    // MARK: - EscapeLadder.shouldConsiderCandidate (auto-repeat guard + physical-event dedup)

    func testAutoRepeatEscapeIsNeverAConsideredCandidate() {
        // UX contract §6, "one press, one layer": AppDelegate.handleEscapeCandidate calls this
        // before doing anything else with a repeat keydown -- no registry lookup, no snapshot
        // built, no rung applied, no watchdog armed. A held Esc (or a synthesized repeat under
        // VM load) must therefore never be able to apply more than one ladder decision per
        // physical keypress.
        let stamp = EscapeLadder.EscapeEventStamp(timestamp: 1, windowNumber: 1)
        XCTAssertFalse(EscapeLadder.shouldConsiderCandidate(isRepeat: true, stamp: stamp, lastStamp: nil))
        XCTAssertTrue(EscapeLadder.shouldConsiderCandidate(isRepeat: false, stamp: stamp, lastStamp: nil))
    }

    func testSameStampBackToBackIsRejectedAsADuplicate() {
        // Root cause under test: WebKit's doneWithKeyEvent re-sends the exact same NSEvent
        // through [NSApp sendEvent:] when Escape comes back from the web layer unhandled. As of
        // the t-784ff3aa preventDefault() fix, the web layer's shared listener
        // (escape-ladder.ts) calls preventDefault() itself for every non-composing Escape, which
        // stops this resend in the common case -- the one case that still reaches it is IME
        // composition, where that listener deliberately returns before ever touching
        // preventDefault(). isARepeat is false on that resend either way, so only the stamp
        // comparison catches it -- the second call with the SAME stamp as the first must be
        // rejected even though isRepeat is false both times.
        let stamp = EscapeLadder.EscapeEventStamp(timestamp: 12345.678, windowNumber: 7)
        XCTAssertTrue(EscapeLadder.shouldConsiderCandidate(isRepeat: false, stamp: stamp, lastStamp: nil))
        XCTAssertFalse(
            EscapeLadder.shouldConsiderCandidate(isRepeat: false, stamp: stamp, lastStamp: stamp),
            "a resent NSEvent (same timestamp/windowNumber) must be rejected as a duplicate, not treated as a new press"
        )
    }

    func testDifferentStampIsAcceptedAsAGenuinelyNewPress() {
        // A second, genuinely separate physical Escape press produces a different `timestamp`,
        // so it must NOT be rejected by the dedup guard even though it immediately follows the
        // first press's stamp.
        let firstPress = EscapeLadder.EscapeEventStamp(timestamp: 100.0, windowNumber: 1)
        let secondPress = EscapeLadder.EscapeEventStamp(timestamp: 100.5, windowNumber: 1)
        XCTAssertTrue(EscapeLadder.shouldConsiderCandidate(isRepeat: false, stamp: secondPress, lastStamp: firstPress))

        // Also true when the window differs but the timestamp coincidentally doesn't (belt and
        // braces -- either field differing makes it a different physical event).
        let sameTimestampOtherWindow = EscapeLadder.EscapeEventStamp(timestamp: 100.0, windowNumber: 2)
        XCTAssertTrue(EscapeLadder.shouldConsiderCandidate(isRepeat: false, stamp: sameTimestampOtherWindow, lastStamp: firstPress))
    }

    func testIsRepeatIsAlwaysRejectedRegardlessOfStamp() {
        // The auto-repeat guard is checked first and short-circuits before the stamp comparison
        // even runs -- true even when the stamp is genuinely new (never seen as `lastStamp`),
        // and even when `lastStamp` is nil (nothing seen yet this session).
        let neverSeenStamp = EscapeLadder.EscapeEventStamp(timestamp: 999.0, windowNumber: 3)
        XCTAssertFalse(EscapeLadder.shouldConsiderCandidate(isRepeat: true, stamp: neverSeenStamp, lastStamp: nil))
        XCTAssertFalse(EscapeLadder.shouldConsiderCandidate(isRepeat: true, stamp: neverSeenStamp, lastStamp: neverSeenStamp))
    }

    // MARK: - EscapeLadder.decide / decideAfterWebDeclined

    func testFocusInWebViewWithAWebPopupOpenAlwaysWinsRegardlessOfOtherFlags() {
        // t-784ff3aa fix round: focus in the web view is no longer sufficient on its own --
        // `webPopupOpen` must ALSO be true (a web-owned popup must genuinely be open) for
        // `.webOwned` to win. This is the true half of that: with `webPopupOpen: true`, it wins
        // regardless of every other flag, exactly as the pre-fix test asserted focus alone did.
        let allFlagsSet = EscapeLadderSnapshot(
            focusInWebView: true,
            webPopupOpen: true,
            findBarVisible: true,
            findBarFieldFocused: false,
            annotationEditIds: ["a1", "a2"],
            focusedAnnotationEditId: nil,
            focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decide(allFlagsSet), .webOwned)

        let noOtherFlags = EscapeLadderSnapshot(
            focusInWebView: true,
            webPopupOpen: true,
            findBarVisible: false,
            findBarFieldFocused: false,
            annotationEditIds: [],
            focusedAnnotationEditId: nil,
            focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decide(noOtherFlags), .webOwned)
    }

    func testFocusInWebViewWithNoWebPopupOpenFallsThroughToTheNativeLadder() {
        // The false half of the t-784ff3aa fix: focus in the web view with NO popup open
        // (`webPopupOpen: false`, the default) must fall straight through to
        // `decideAfterWebDeclined`'s ladder -- Swift already knows there's nothing web-owned to
        // wait on, so `.webOwned` must never be returned here. Uses the same three shapes as
        // `testDecideAfterWebDeclinedOrderIsFindBarThenAnnotationEditThenFocusMode` below to
        // confirm `decide` and `decideAfterWebDeclined` agree exactly once webPopupOpen is false,
        // whether or not focusInWebView happens to be true.
        let findBarWins = EscapeLadderSnapshot(
            focusInWebView: true, webPopupOpen: false, findBarVisible: true, findBarFieldFocused: false,
            annotationEditIds: ["a1"], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decide(findBarWins), .findBar)

        let annotationEditWins = EscapeLadderSnapshot(
            focusInWebView: true, webPopupOpen: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: ["a1"], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decide(annotationEditWins), .annotationEdit(id: "a1"))

        let focusModeWins = EscapeLadderSnapshot(
            focusInWebView: true, webPopupOpen: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: [], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decide(focusModeWins), .focusMode)

        let none = EscapeLadderSnapshot(
            focusInWebView: true, webPopupOpen: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: [], focusedAnnotationEditId: nil, focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decide(none), .none)
    }

    func testDecideAfterWebDeclinedOrderIsFindBarThenAnnotationEditThenFocusMode() {
        // All three "open" -- find bar wins. Neither focus signal is set, so this exercises the
        // fixed fallback ladder (VISIBILITY/registration order), not the focus-priority checks
        // covered separately below.
        let allOpen = EscapeLadderSnapshot(
            focusInWebView: false, findBarVisible: true, findBarFieldFocused: false,
            annotationEditIds: ["a1"], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(allOpen), .findBar)

        // Find bar closed, annotation edit + focus mode open -- annotation edit wins.
        let annotationAndFocus = EscapeLadderSnapshot(
            focusInWebView: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: ["a1"], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(annotationAndFocus), .annotationEdit(id: "a1"))

        // Only focus mode open -- focus mode wins.
        let focusOnly = EscapeLadderSnapshot(
            focusInWebView: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: [], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(focusOnly), .focusMode)
    }

    func testAllClearSnapshotProducesNone() {
        let clear = EscapeLadderSnapshot(
            focusInWebView: false, findBarVisible: false, findBarFieldFocused: false,
            annotationEditIds: [], focusedAnnotationEditId: nil, focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decide(clear), .none)
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(clear), .none)
    }

    func testLIFOAmongMultipleAnnotationEditIdsPicksTheLastRegistered() {
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: false,
            findBarFieldFocused: false,
            annotationEditIds: ["first", "second", "third"],
            focusedAnnotationEditId: nil,
            focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(snapshot), .annotationEdit(id: "third"))
    }

    func testWebFocusWithAPopupOpenStillWinsOverFindBarAndAnnotationEditAndFocusMode() {
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: true, webPopupOpen: true, findBarVisible: true, findBarFieldFocused: false,
            annotationEditIds: ["a1"], focusedAnnotationEditId: nil, focusModeEnabled: true
        )
        XCTAssertEqual(EscapeLadder.decide(snapshot), .webOwned)
    }

    // MARK: - "Where you're typing wins" among native surfaces (focus beats plain visibility)

    func testFocusedAnnotationEditWinsOverMerelyOpenFindBar() {
        // The find bar is open (visible) but its own field is NOT focused; an annotation
        // card's edit field IS genuinely focused. "Where you're typing wins" (UX contract §6)
        // means the focused annotation edit wins here, even though the find bar would
        // otherwise come first in the fixed fallback ladder.
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: true,
            findBarFieldFocused: false,
            annotationEditIds: ["a1"],
            focusedAnnotationEditId: "a1",
            focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(snapshot), .annotationEdit(id: "a1"))
    }

    func testFocusedFindBarFieldWinsOverMerelyOpenAnnotationEdit() {
        // The find bar's own field IS genuinely focused; an annotation card is also open
        // (registered in `annotationEditIds`) but is NOT the focused surface. Focus wins for
        // whichever surface is ACTUALLY focused, so Esc closes the find bar, not the
        // annotation edit.
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: true,
            findBarFieldFocused: true,
            annotationEditIds: ["a1"],
            focusedAnnotationEditId: nil,
            focusModeEnabled: false
        )
        XCTAssertEqual(EscapeLadder.decideAfterWebDeclined(snapshot), .findBar)
    }

    // MARK: - EscapeLadderContext annotation-edit registry (LIFO ordering source)

    func testContextAnnotationEditOrderReflectsRegistrationOrderAndReRegistrationMovesToEnd() {
        let context = EscapeLadderContext()
        context.registerAnnotationEdit(id: "a", cancel: {})
        context.registerAnnotationEdit(id: "b", cancel: {})
        context.registerAnnotationEdit(id: "c", cancel: {})
        XCTAssertEqual(context.annotationEditOrder, ["a", "b", "c"])

        // Re-registering an already-registered id moves it to the end (most-recent-wins).
        context.registerAnnotationEdit(id: "a", cancel: {})
        XCTAssertEqual(context.annotationEditOrder, ["b", "c", "a"])

        context.unregisterAnnotationEdit(id: "c")
        XCTAssertEqual(context.annotationEditOrder, ["b", "a"])
    }

    func testContextCancelAnnotationEditInvokesTheRegisteredClosure() {
        let context = EscapeLadderContext()
        var cancelled = false
        context.registerAnnotationEdit(id: "a", cancel: { cancelled = true })
        context.cancelAnnotationEdit(id: "a")
        XCTAssertTrue(cancelled)
    }

    // MARK: - Escape watchdog (armEscapeWatchdog / resolvePendingEscape)

    /// t-784ff3aa fix round: `armEscapeWatchdog` is no longer the correctness mechanism for the
    /// web-owned rung (see its doc comment) -- it now defaults to a much longer
    /// `hangProtectionWatchdogDelay` (seconds, purely a last-resort hang-protection net) since
    /// nothing real is timed against it anymore. These tests pass an explicit short `delay:`
    /// (the parameter exists for exactly this) so they still cover the underlying
    /// arm/cancel/fire/resolve mechanics quickly, without waiting out the real production
    /// deadline or asserting anything about its specific value.
    private static let testWatchdogDelay: TimeInterval = 0.05
    private static let watchdogWaitMargin: TimeInterval = 0.2

    func testArmingANewWatchdogCancelsThePriorOne() {
        let context = EscapeLadderContext()
        var firstFired = false
        var secondFired = false

        context.armEscapeWatchdog(delay: Self.testWatchdogDelay) { firstFired = true }
        context.armEscapeWatchdog(delay: Self.testWatchdogDelay) { secondFired = true }

        let expectation = expectation(description: "watchdog window elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogWaitMargin) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Two rapid arms in succession only ever result in ONE action taken: the first
        // watchdog is cancelled the instant the second is armed, so only the most recent one
        // is ever still outstanding by the time either could fire.
        XCTAssertFalse(firstFired, "arming a new watchdog must cancel the prior one")
        XCTAssertTrue(secondFired, "the most recently armed watchdog should fire when nothing resolves it")
    }

    func testLateReportAfterWatchdogAlreadyFiredIsIgnored() {
        let context = EscapeLadderContext()
        var fireCount = 0
        context.armEscapeWatchdog(delay: Self.testWatchdogDelay) { fireCount += 1 }

        let expectation = expectation(description: "watchdog fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogWaitMargin) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(fireCount, 1)

        // A web-side report arriving AFTER the watchdog has already fired (and cleared its own
        // pending slot) must be a no-op -- resolvePendingEscape reports nothing was pending,
        // and critically the fallback must not run a second time.
        XCTAssertFalse(context.resolvePendingEscape(), "nothing should be pending once the watchdog already fired")
        XCTAssertEqual(fireCount, 1, "a late report must never cause the fallback to double-apply")
    }

    func testResolvingPendingEscapeCancelsTheWatchdogPreventingDoubleApply() {
        let context = EscapeLadderContext()
        var fallbackRunCount = 0
        context.armEscapeWatchdog(delay: Self.testWatchdogDelay) { fallbackRunCount += 1 }

        // The common case: a web-side report arrives well before the deadline and resolves the
        // watchdog.
        XCTAssertTrue(context.resolvePendingEscape())

        let expectation = expectation(description: "watchdog window elapses without firing")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogWaitMargin) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(fallbackRunCount, 0, "a resolved watchdog must never also fire its fallback later")
    }

    func testDefaultDelayIsTheGenerousHangProtectionValueNotAShortTimingDeadline() {
        // Confirms the production default (used by every real call site -- AppDelegate never
        // passes `delay:` explicitly) is the generous last-resort value, not something back in
        // old-timing-race territory. Doesn't assert an exact number (that would just be
        // re-asserting the constant against itself) -- asserts the shape: comfortably longer
        // than any deadline that could plausibly still be racing a document's block-sync pass.
        XCTAssertEqual(EscapeLadderContext.hangProtectionWatchdogDelay, 5.0)
        XCTAssertGreaterThan(EscapeLadderContext.hangProtectionWatchdogDelay, 1.0)
    }

    // MARK: - EscapeLadderRegistry lifecycle

    func testRegisterAndUnregisterLifecycle() {
        let registry = EscapeLadderRegistry.shared
        let window = NSWindow()
        let context = EscapeLadderContext()

        registry.register(context, for: window)
        XCTAssertTrue(registry.context(for: window) === context)

        registry.unregister(for: window)
        XCTAssertNil(registry.context(for: window))
    }

    func testDoubleRegisterForOneWindowLeavesExactlyOneEntry() {
        let registry = EscapeLadderRegistry.shared
        let window = NSWindow()
        let first = EscapeLadderContext()
        let second = EscapeLadderContext()

        registry.register(first, for: window)
        registry.register(second, for: window)

        // The second registration replaces the first -- exactly one entry for this window,
        // and it's the most recently registered context.
        XCTAssertTrue(registry.context(for: window) === second)

        registry.unregister(for: window)
        XCTAssertNil(registry.context(for: window))
    }

    func testNilWindowReturnsNilContext() {
        XCTAssertNil(EscapeLadderRegistry.shared.context(for: nil))
    }

    func testDeadWindowSweepDropsEntriesWhoseWindowHasBeenDeallocated() {
        let registry = EscapeLadderRegistry.shared
        let context = EscapeLadderContext()
        // Kept alive for the whole test (unlike the old version of this test, which registered
        // against a window scoped to an `autoreleasepool` and relied on ARC deallocating it by
        // the time the pool exits -- timing AppKit doesn't strictly guarantee). Simulating the
        // "dead" state by directly nilling `context.window` below tests the SAME production
        // condition (`sweepDeadEntries`'s `$0.value.window != nil` check) deterministically.
        let window = NSWindow()

        registry.register(context, for: window)
        XCTAssertTrue(registry.context(for: window) === context)

        // Simulate the window having deallocated by nilling the weak reference the production
        // sweep logic itself reads.
        context.window = nil

        // Trigger a sweep via an unrelated register call (register/unregister/context(for:) all
        // sweep -- see `sweepDeadEntries`'s doc comment).
        let otherWindow = NSWindow()
        let otherContext = EscapeLadderContext()
        registry.register(otherContext, for: otherWindow)

        // Assert the REGISTRY's own lookup reflects the sweep -- not just that Swift's `weak`
        // semantics nilled `context.window` (a real registry could get that part right while
        // still leaking the dictionary entry forever).
        XCTAssertNil(registry.context(for: window), "the dead entry should have been dropped by the sweep")
        XCTAssertTrue(registry.context(for: otherWindow) === otherContext, "the live entry must be unaffected")

        registry.unregister(for: otherWindow)
    }
}
