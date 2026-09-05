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

    // MARK: - reason-less paintComplete (paintcomplete-zoom-reason): must never cross reasons

    /// Pins cross-reason isolation (reworded, review round 3 -- the previous "The real guard"
    /// wording overstated this test's role: it passes against the UNFIXED, pre-paintcomplete-
    /// zoom-reason code too, since a reason-less body was never routed toward `.mount`/
    /// `.projectReset` even under the old `.zoom`-defaulting fallback this change replaced. The
    /// test that actually pins THIS round's own fix is
    /// `testReasonlessPaintCompleteCannotReleaseAZoomCloakButItsOwnTokenCan` below): a
    /// reason-less `paintComplete` body -- what every one of
    /// `BlockSyncService.setContentWithBlockIds`'s 9 call sites posts on every ordinary paint --
    /// can never release a `.mount` or `.projectReset` cloak it doesn't own.
    func testReasonlessPaintCompleteCannotReleaseAMountOrProjectResetCloak() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let mountToken = coordinator.beginCloak(.mount)
        let resetToken = coordinator.beginCloak(.projectReset)
        XCTAssertEqual(webView.alphaValue, 0, "two unrelated cloaks outstanding")

        coordinator.handlePaintComplete(body: ["scrollHeight": 100, "timestamp": 1])

        XCTAssertEqual(webView.alphaValue, 0,
            "a reason-less paintComplete must not release the mount or projectReset cloak -- " +
            "it has no `.zoom` token to resolve to and must be a no-op")

        coordinator.endCloak(mountToken)
        XCTAssertEqual(webView.alphaValue, 0, "projectReset cloak is still outstanding")

        coordinator.endCloak(resetToken)
        XCTAssertEqual(webView.alphaValue, 1, "both cloaks explicitly released -- now revealed")
    }

    /// The must-fix this whole round exists for: a reason-less `paintComplete` can no longer
    /// release a `.zoom` cloak (round 1's regression -- deleting `beginCloak(.zoom)` outright
    /// was rejected because the branch IS reachable via two error-guard paths in
    /// `BlockSyncService.setContentWithBlockIds`, and its normal path is correctly paired: JS's
    /// `setContent` now posts its own `reason: "zoom"` body carrying the exact token this
    /// mints, echoed back). Only that explicit token/reason pairing may release it.
    func testReasonlessPaintCompleteCannotReleaseAZoomCloakButItsOwnTokenCan() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let zoomToken = coordinator.beginCloak(.zoom)
        XCTAssertEqual(webView.alphaValue, 0, "zoom cloak outstanding")

        coordinator.handlePaintComplete(body: ["scrollHeight": 100, "timestamp": 1])
        XCTAssertEqual(webView.alphaValue, 0,
            "a reason-less paintComplete must not release the .zoom cloak -- it has no explicit " +
            "token and resolveCloakToken's reason fallback no longer defaults to .zoom")

        coordinator.handlePaintComplete(body: ["reason": "zoom", "token": zoomToken, "scrollHeight": 100, "timestamp": 2])
        XCTAssertEqual(webView.alphaValue, 1,
            "the explicit reason: \"zoom\" + echoed token body must release exactly this cloak")
    }

    /// Must-fix #4 (review round 3): closes a narrower rerun of the exact reason-vs-token
    /// ambiguity this whole change removes -- `cloakReason` still maps `"zoom"` to `.zoom`
    /// (needed intact for `isZoomAcknowledgement`, must-fix #5), so a naive reason-only
    /// fallback in `resolveCloakToken` would resolve a `reason: "zoom"` body with NO explicit
    /// `token` to "whatever `.zoom` cloak happens to be outstanding". `resolveCloakToken`'s
    /// fallback must apply only to `.mount`/`.projectReset`, never `.zoom`.
    func testReasonZoomWithNoExplicitTokenDoesNotResolveViaReasonOnlyFallback() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        let zoomToken = coordinator.beginCloak(.zoom)
        XCTAssertEqual(webView.alphaValue, 0, "zoom cloak outstanding")

        coordinator.handlePaintComplete(body: ["reason": "zoom", "scrollHeight": 100, "timestamp": 1])
        XCTAssertEqual(webView.alphaValue, 0,
            "a reason: \"zoom\" body with no token must not release the outstanding .zoom cloak by reason alone")

        coordinator.endCloak(zoomToken)
        XCTAssertEqual(webView.alphaValue, 1, "the explicit release still works normally")
    }

    // MARK: - handlePaintComplete's onContentAcknowledged gate (isZoomAcknowledgement)

    /// Acknowledgement fires for a reason-less body (every ordinary setContentWithBlockIds
    /// paint) and for an explicit `reason: "zoom"` body (setContent's own cloaked zoom push) --
    /// but not for `"mount"` or `"projectReset"`, which must not resume a zoom transition's own
    /// continuation via an unrelated signal (Must-fix #2, review round 2).
    func testAcknowledgementFiresForReasonlessAndZoomButNotMountOrProjectReset() {
        let coordinator = makeCoordinator()
        let webView = WKWebView(frame: .zero)
        coordinator.webView = webView

        func acknowledgementFires(for body: [String: Any]) -> Bool {
            var fired = false
            coordinator.onContentAcknowledged = { fired = true }
            coordinator.handlePaintComplete(body: body)
            return fired
        }

        XCTAssertTrue(acknowledgementFires(for: ["scrollHeight": 100, "timestamp": 1]),
            "a reason-less body must acknowledge (ordinary setContentWithBlockIds paints)")
        XCTAssertTrue(acknowledgementFires(for: ["reason": "zoom", "scrollHeight": 100, "timestamp": 2]),
            "an explicit reason: \"zoom\" body must acknowledge")
        XCTAssertFalse(acknowledgementFires(for: ["reason": "mount", "scrollHeight": 100, "timestamp": 3]),
            "a \"mount\" body must NOT acknowledge -- it must not resume a zoom in flight")
        XCTAssertFalse(acknowledgementFires(for: ["reason": "projectReset", "scrollHeight": 100, "timestamp": 4]),
            "a \"projectReset\" body must NOT acknowledge -- it must not resume a zoom in flight")
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
