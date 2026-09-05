//
//  MilkdownEditorMountCloakTests.swift
//  final finalTests
//
//  Tier 2: Coordinator-level tests for the mount-flash fix's token-based cloak system
//  (beginCloak/endCloak/pollMountCloakReleaseForClaimedView, MilkdownCoordinator+
//  MessageHandlers.swift). Acceptance-review follow-up: the redesigned claimed-preloaded-view
//  cloak path had zero direct test coverage before this file -- not excused by the
//  TestMode.isTesting preloading gap that keeps the END-TO-END mount path untestable here,
//  since the cloak-token bookkeeping itself is fully unit-testable via the same seams
//  MilkdownEditorReadyGateTests.swift already uses: a bare Coordinator with `webView` set
//  directly and `editorReadyProbe` overridden, no real WKWebView JS engine round trip.
//
//  What this file deliberately does NOT cover: whether `pollMountCloakReleaseForClaimedView`'s
//  ready branch actually calls `window.FinalFinal.signalMountPaintComplete()` correctly on a
//  real WKWebView -- that would need a loaded page with a JS `window.FinalFinal` stub, which is
//  exactly the preloading gap acceptance review flagged as a known, accepted limitation. What
//  IS tested here is the branch's own Swift-side control flow: whether it stops polling on
//  ready, keeps polling on not-ready, and gives up (without itself releasing the token) once
//  the retry budget is exhausted. The JS-side release call itself is covered separately by
//  `signalMountPaintComplete()`'s own unit test (web/milkdown/src/__tests__/
//  mount-paint-signal.test.ts).
//

import WebKit
import XCTest
@testable import final_final

@MainActor
final class MilkdownEditorMountCloakTests: XCTestCase {

    private func makeCoordinator() -> MilkdownEditor.Coordinator {
        MilkdownEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil
        )
    }

    // MARK: - beginCloak/endCloak: reveal timing

    func testRevealOnlyHappensWhenLastOutstandingTokenClears() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let mountToken = coordinator.beginCloak(.mount)
        let zoomToken = coordinator.beginCloak(.zoom) // different reason -- both outstanding at once
        XCTAssertEqual(webView.alphaValue, 0, "two cloaks outstanding -- must stay hidden")

        coordinator.endCloak(mountToken)
        XCTAssertEqual(webView.alphaValue, 0,
            "releasing only ONE of two outstanding tokens must NOT reveal -- the zoom cloak is still live")

        coordinator.endCloak(zoomToken)
        XCTAssertEqual(webView.alphaValue, 1,
            "releasing the LAST outstanding token must reveal")
    }

    // MARK: - endCloak: stale/superseded token is a no-op

    func testEndCloakOnATokenThatWasNeverOutstandingDoesNotTouchAlphaValue() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        // Sentinel distinct from both 0 (cloaked) and 1 (revealed) -- if endCloak's guard were
        // missing, `outstandingCloaks.isEmpty` would read true (nothing was ever begun) and the
        // unconditional `webView?.alphaValue = 1` inside the empty-check would stomp this value.
        webView.alphaValue = 0.42

        coordinator.endCloak(999) // never minted by beginCloak

        XCTAssertEqual(webView.alphaValue, 0.42,
            "a release for a token that was never outstanding must be a pure no-op")
    }

    func testEndCloakOnAnAlreadyReleasedTokenIsANoOpAndDoesNotDoubleRelease() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let token = coordinator.beginCloak(.zoom)
        coordinator.endCloak(token) // normal release
        XCTAssertEqual(webView.alphaValue, 1)

        webView.alphaValue = 0.42 // sentinel -- distinguishes "left alone" from "re-set to 1"
        coordinator.endCloak(token) // stray duplicate release of the same token

        XCTAssertEqual(webView.alphaValue, 0.42,
            "a duplicate release of an already-cleared token must not touch alphaValue again")
    }

    func testEndCloakOnASupersededTokenDoesNotReleaseTheNewerToken() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let staleToken = coordinator.beginCloak(.zoom)
        let liveToken = coordinator.beginCloak(.zoom) // same reason -- supersedes staleToken internally
        XCTAssertEqual(webView.alphaValue, 0, "liveToken is still outstanding")

        coordinator.endCloak(staleToken) // stray late release of the token beginCloak already superseded

        XCTAssertEqual(webView.alphaValue, 0,
            "releasing the already-superseded token must not affect the still-live newer token")

        coordinator.endCloak(liveToken)
        XCTAssertEqual(webView.alphaValue, 1, "releasing the actually-live token must still reveal normally")
    }

    // MARK: - beginCloak: same-reason supersession must not strand the older token

    func testSameReasonSupersessionDoesNotStrandTheOlderToken() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let older = coordinator.beginCloak(.zoom)
        let newer = coordinator.beginCloak(.zoom) // same reason as `older` -- must supersede it
        XCTAssertNotEqual(older, newer)
        XCTAssertEqual(webView.alphaValue, 0, "newer is still outstanding")

        // If supersession failed to release `older`, it would remain in outstandingCloaks
        // forever (nothing will ever send a paintComplete naming it specifically -- reason-only
        // resolution only ever points at the LATEST token), so releasing ONLY `newer` would
        // never be enough to reveal. This is exactly the stuck-invisible-editor scenario
        // must-fix #5 exists to close.
        coordinator.endCloak(newer)

        XCTAssertEqual(webView.alphaValue, 1,
            "releasing the superseding token alone must reveal -- the superseded older token must not still count as outstanding")
    }

    // MARK: - pollMountCloakReleaseForClaimedView: the three branches

    func testPollStopsAfterProbeReportsReady() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        let token = coordinator.beginCloak(.mount)

        var probeCallCount = 0
        coordinator.editorReadyProbe = { _, completion in
            probeCallCount += 1
            completion(true) // ready immediately
        }

        coordinator.pollMountCloakReleaseForClaimedView(token: token)

        // The ready branch must not schedule another attempt. If it did, the probe (still wired
        // to report ready=true) would fire again ~50ms later and bump this count past 1.
        let expectation = expectation(description: "no further poll attempt is scheduled after ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(probeCallCount, 1, "a ready result must stop the poll, not schedule another attempt")
    }

    func testPollKeepsPollingWhenNotYetReady() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        let token = coordinator.beginCloak(.mount)

        var probeCallCount = 0
        coordinator.editorReadyProbe = { _, completion in
            probeCallCount += 1
            completion(false) // never ready
        }

        coordinator.pollMountCloakReleaseForClaimedView(token: token)
        XCTAssertEqual(probeCallCount, 1)

        let expectation = expectation(description: "poll retries ~50ms after a not-ready result")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertGreaterThanOrEqual(probeCallCount, 2,
            "a not-ready result must schedule another poll attempt, not give up")
    }

    func testPollGivesUpAfterTimeoutWithoutItselfReleasingTheToken() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView
        let token = coordinator.beginCloak(.mount)

        var probeCallCount = 0
        coordinator.editorReadyProbe = { _, completion in
            probeCallCount += 1
            completion(false)
        }

        // Enter directly at the >= 60 boundary (60 x 50ms = 3s), mirroring
        // MilkdownEditorReadyGateTests's testTimeoutPathFiresExactlyOnceAfterTheRetryBudget --
        // exercises the give-up branch deterministically without a real 3s wait or a
        // 60-iteration DispatchQueue.asyncAfter chain.
        coordinator.pollMountCloakReleaseForClaimedView(token: token, attempt: 60)

        XCTAssertEqual(probeCallCount, 0, "the give-up branch must return before ever probing again")
        XCTAssertTrue(coordinator.outstandingCloaks.contains(token),
            "giving up on the POLL must not itself release the cloak token -- per the doc comment, " +
            "only beginCloak's own independently-armed ~2.5s fallback timer may do that")
        XCTAssertEqual(webView.alphaValue, 0,
            "the editor must remain cloaked when the poll gives up -- release is left entirely to the fallback timer")
    }
}
