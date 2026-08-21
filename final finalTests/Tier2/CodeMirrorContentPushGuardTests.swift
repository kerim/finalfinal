//
//  CodeMirrorContentPushGuardTests.swift
//  final finalTests
//
//  Tier 2: Coordinator-level tests for CodeMirrorEditor.Coordinator.shouldPushContent's
//  settle-window guard (undo-mode-switch-focus fix).
//
//  Root cause (confirmed against the installed @codemirror/commands source and live probe
//  evidence during the investigation): updateSourceContentIfNeeded()
//  (ContentView+ContentRebuilding.swift) reassigns editorState.sourceContent at arbitrary,
//  sometimes notification-driven moments -- including mid-typing right after a mode switch.
//  shouldPushContent had no "is the user mid-edit" guard: any content differing from
//  lastPushedContent triggered a full setContent push, unconditionally. CodeMirror's
//  setContent computes a single contiguous minimal diff and dispatches it annotated
//  addToHistory: false; a non-history transaction doesn't clear history -- it REMAPS the
//  existing undo branch through the diff's changes, and DROPS history events whose changes
//  map away. A push that rewrites the exact span the user just typed into silently takes
//  that user's undo event with it.
//
//  These are pure Coordinator-state tests, not full WKWebView-lifecycle tests (unlike
//  ToggleStateRegressionTests.swift's RealCodeMirrorHarness, which needs a real page load to
//  prove JS-side state): shouldPushContent operates entirely on Coordinator-owned Swift
//  properties (lastPushedContent, lastLocalEditAt, forcedPushGeneration,
//  lastHonouredForcedPushGeneration), so setting them directly and calling the real function
//  is a faithful, much faster test than driving a real page load. The one exception is
//  testMountResetAllowsImmediatePushAfterEditorBecomesReady, which drives the real
//  handlePreloadedView() mount path (webView left nil so batchInitialize()/onWebViewReady/
//  applyPersistedToggleStates() all no-op harmlessly -- each guards on `let webView` --
//  isolating the assertion to the isEditorReady false->true reset this test targets).
//

import XCTest
@testable import final_final

@MainActor
final class CodeMirrorContentPushGuardTests: XCTestCase {

    private func makeCoordinator() -> CodeMirrorEditor.Coordinator {
        CodeMirrorEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil
        )
    }

    func testSuppressesDerivedPushWithinSettleWindowAfterLocalEdit() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastPushedContent = "original content"
        coordinator.lastLocalEditAt = Date()  // "just typed"

        XCTAssertFalse(
            coordinator.shouldPushContent("derived refresh content"),
            "A derived push landing inside the settle window right after a local edit must be " +
            "suppressed -- this is the exact undo-mode-switch-focus data-loss scenario."
        )
    }

    func testAllowsDerivedPushOutsideSettleWindow() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastPushedContent = "original content"
        coordinator.lastLocalEditAt = Date(timeIntervalSinceNow: -5.0)  // well past any settle window

        XCTAssertTrue(
            coordinator.shouldPushContent("derived refresh content"),
            "A derived push landing well outside the settle window should proceed normally."
        )
    }

    func testAllowsIntentionalReplacementRegardlessOfSettleWindow() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastPushedContent = "original content"
        coordinator.lastLocalEditAt = Date()  // "just typed" -- would normally suppress
        coordinator.forcedPushGeneration = 1  // caller bumped it (INTENTIONAL REPLACEMENT)

        XCTAssertTrue(
            coordinator.shouldPushContent("zoom transition content"),
            "An INTENTIONAL REPLACEMENT (forcedPushGeneration bumped) must be honoured even " +
            "inside the settle window -- zoom transitions, project switch, and structural " +
            "undo/redo restores must never be silently suppressed."
        )
    }

    func testMountResetAllowsImmediatePushAfterEditorBecomesReady() {
        let coordinator = makeCoordinator()
        // Simulate a stale "just typed" timestamp that would otherwise be carried over --
        // the mount-reset fix (2b) must overwrite this unconditionally on the isEditorReady
        // false->true transition, regardless of what was there before.
        coordinator.lastLocalEditAt = Date()
        coordinator.lastPushedContent = "stale outgoing content"

        coordinator.handlePreloadedView()

        XCTAssertTrue(coordinator.isEditorReady, "handlePreloadedView() should flip isEditorReady true.")
        XCTAssertTrue(
            coordinator.shouldPushContent("freshly mounted editor's real content"),
            "A freshly mounted editor's own legitimate mount push must never be suppressed by " +
            "a timestamp carried over from before the mount -- this is the must-not-regress " +
            "case 2b guards against: without the reset, the new editor would show empty/stale " +
            "content."
        )

        coordinator.pollingTimer?.invalidate()  // courtesy cleanup -- startPolling() ran above
    }

    func testForcedPushHonouredExactlyOncePerGenerationBump() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastLocalEditAt = Date()  // stays "just typed" for the whole test
        coordinator.forcedPushGeneration = 1

        // First updateNSView cycle after the bump: honoured, regardless of the settle window.
        coordinator.lastPushedContent = "before"
        XCTAssertTrue(
            coordinator.shouldPushContent("after generation 1"),
            "The first shouldPushContent call after a generation bump must be honoured."
        )
        // Mirrors what the real caller (setContent(), invoked because shouldPushContent
        // just returned true) does immediately afterward.
        coordinator.lastPushedContent = "after generation 1"

        // A second updateNSView cycle at the SAME forcedPushGeneration value (no new bump)
        // must fall through to the ordinary settle-window guard, not force through again --
        // otherwise a sticky flag would leak across every subsequent cycle instead of being
        // consumed exactly once per generation bump.
        XCTAssertFalse(
            coordinator.shouldPushContent("yet another derived refresh"),
            "A second push attempt at the SAME forcedPushGeneration value (no new bump) must " +
            "not be force-honoured again -- it should fall through to the ordinary " +
            "settle-window guard (still inside the window here, so suppressed)."
        )
    }

    /// Must-fix F1 (judge review round): the generation credit can "bank" and later force
    /// through an unrelated mid-typing push. Concrete confirmed path: `handleDidZoomOut`
    /// calls `updateSourceContentIfNeeded(intentionalReplacement: true)` right after
    /// `enforceHierarchyAsync` has already written the SAME recomputed string to
    /// `sourceContent` -- so the bump's own paired push is content-identical to
    /// `lastPushedContent` and returns false at the ordinary equality guard. Under the OLD
    /// ordering (generation consumed only AFTER that guard), the credit was never consumed,
    /// stayed "banked", and the NEXT differing-content push -- plausibly an ordinary derived
    /// one landing mid-typing -- got force-honoured with the settle window bypassed: the
    /// original bug, re-armed via a different path.
    ///
    /// This is the test `testForcedPushHonouredExactlyOncePerGenerationBump` above does NOT
    /// catch (it deliberately keeps content different on both legs, so the OLD buggy code
    /// would have consumed the credit correctly there too and passed regardless of the fix).
    /// This test's first leg is the missing identical-content case.
    func testForcedGenerationCreditDoesNotBankAcrossIdenticalContentPush() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastLocalEditAt = Date()  // stays "just typed" for the whole test
        coordinator.forcedPushGeneration = 1
        coordinator.lastPushedContent = "same content"

        // Leg 1 (the banking trap): a forced push whose content already matches
        // lastPushedContent. Must return false (nothing to push) -- but the generation
        // credit must still be consumed HERE, unconditionally, not deferred until some
        // later differing-content call.
        XCTAssertFalse(
            coordinator.shouldPushContent("same content"),
            "Identical content should never push, forced or not."
        )

        // Leg 2 (the actual regression): an unrelated DERIVED push (no new generation
        // bump) with genuinely different content, landing inside the settle window. If the
        // credit from leg 1 leaked forward (the pre-fix bug), this would be incorrectly
        // force-honoured, bypassing the settle window entirely.
        XCTAssertFalse(
            coordinator.shouldPushContent("a completely unrelated derived refresh"),
            "A differing-content push after an identical-content forced call must NOT be " +
            "force-honoured by banked credit from leg 1 -- it must fall through to the " +
            "ordinary settle-window guard (still inside the window here, so suppressed). " +
            "Without consuming the generation unconditionally at the top of " +
            "shouldPushContent (must-fix F1), this call would incorrectly bypass the " +
            "settle window and silently drop the user's undo history."
        )
    }

    /// Must-fix F2 (judge review round): the deferred recompute must RE-DERIVE fresh
    /// content when it fires, never replay the stale string that was suppressed (which, by
    /// retry time, may equal what the user has since typed -- `handleContentPush` sets both
    /// `lastPushedContent` and the content binding to the user's own typed content on every
    /// keystroke batch). Proves the retry actually calls `onContentRecompute` (wired from
    /// ContentView to `updateSourceContentIfNeeded()`) rather than silently dropping the
    /// suppressed derived payload or reading a binding the editor has since overwritten.
    func testDeferredRecomputeInvokesOnContentRecomputeAfterSettleWindow() async throws {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.contentState = .idle
        coordinator.lastPushedContent = "original"
        coordinator.lastLocalEditAt = Date()  // "just typed" -- forces suppression + defer

        var recomputeCallCount = 0
        coordinator.onContentRecompute = {
            recomputeCallCount += 1
        }

        XCTAssertFalse(
            coordinator.shouldPushContent("a derived refresh landing mid-edit"),
            "Should be suppressed inside the settle window, and schedule a deferred retry."
        )
        XCTAssertEqual(recomputeCallCount, 0, "Must not recompute synchronously -- only after the settle window elapses.")

        // Wait past the 0.6s settle window for the retry timer to fire.
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(
            recomputeCallCount, 1,
            "The deferred retry must call onContentRecompute to RE-DERIVE fresh content " +
            "against NOW-current editorState.content -- never silently drop the suppressed " +
            "push, and never replay the stale string captured at suppression time."
        )

        coordinator.deferredPushTimer?.invalidate()
    }

    // MARK: - P2 (undo-mode-switch-focus second timing gap): reconciliation-in-flight extension

    /// Even WELL OUTSIDE the ordinary 0.6s local-edit settle window, a push must still be
    /// suppressed while `isReconciliationPending` reports true -- this is the whole point of
    /// P2: the original settle window was structurally shorter than the real
    /// 500ms-debounce-plus-async-hierarchy-enforcement chain it was racing.
    func testSuppressesWhileReconciliationInFlightEvenOutsideOrdinarySettleWindow() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.contentState = .idle
        coordinator.lastPushedContent = "original"
        coordinator.lastLocalEditAt = Date(timeIntervalSinceNow: -5.0)  // well past the 0.6s window
        coordinator.isReconciliationPending = { true }

        XCTAssertFalse(
            coordinator.shouldPushContent("derived refresh while reconciliation is still running"),
            "A derived push must stay suppressed while reconciliation is in flight, even though " +
            "the ordinary local-edit settle window alone would have allowed it through."
        )

        coordinator.deferredPushTimer?.invalidate()
    }

    /// Once the flag clears (the real owner's `defer` fired), a push proceeds normally --
    /// proves this isn't a sticky suppression that outlives the flag itself.
    func testHonoursPushOnceReconciliationFlagClears() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastPushedContent = "original"
        coordinator.lastLocalEditAt = Date(timeIntervalSinceNow: -5.0)
        coordinator.isReconciliationPending = { false }

        XCTAssertTrue(
            coordinator.shouldPushContent("derived refresh after reconciliation finished"),
            "Once isReconciliationPending reports false, a push outside the ordinary settle " +
            "window must proceed normally -- P2 must not become a sticky suppression."
        )
    }

    /// Hard cap backstop: a flag that has been reporting true continuously for longer than
    /// the 2s cap is treated as stale/leaked and ignored, so a real owner's defer bug can
    /// never permanently wedge every future push.
    func testIgnoresStaleReconciliationFlagPastTheTwoSecondCap() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastPushedContent = "original"
        coordinator.lastLocalEditAt = Date(timeIntervalSinceNow: -5.0)
        coordinator.isReconciliationPending = { true }
        // Simulate the flag having ALREADY been observed true 2.5s ago -- past the 2s cap.
        coordinator.reconciliationPendingSince = Date(timeIntervalSinceNow: -2.5)

        XCTAssertTrue(
            coordinator.shouldPushContent("derived refresh despite a leaked in-flight flag"),
            "A reconciliation-in-flight flag that has been true for longer than the 2s hard " +
            "cap must be ignored (treated as stale/leaked), not honoured forever -- the cap " +
            "is a backstop against exactly this kind of leaked flag."
        )
    }

    /// The generation-scoped `forcedPushGeneration` bypass must keep overriding BOTH the
    /// ordinary settle window AND the new P2 in-flight extension -- an intentional
    /// replacement (zoom, project switch, structural undo/redo) is never suppressible by
    /// either.
    func testForcedPushStillBypassesReconciliationInFlightExtension() {
        let coordinator = makeCoordinator()
        coordinator.isEditorReady = true
        coordinator.lastLocalEditAt = Date()  // "just typed" -- would normally suppress
        coordinator.isReconciliationPending = { true }  // AND reconciliation in flight
        coordinator.forcedPushGeneration = 1

        XCTAssertTrue(
            coordinator.shouldPushContent("zoom transition content"),
            "An INTENTIONAL REPLACEMENT must be honoured even with BOTH the settle window " +
            "and the reconciliation-in-flight extension otherwise active."
        )
    }
}
