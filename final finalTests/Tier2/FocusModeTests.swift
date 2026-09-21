//
//  FocusModeTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for EditorViewState focus mode: enter/exit, snapshot capture,
//  sidebar hiding per settings, and round-trip state preservation.
//

import Testing
import Foundation
@testable import final_final

@Suite("Focus Mode — Tier 2: Visible Breakage", .serialized)
struct FocusModeTests {

    // MARK: - Helpers

    /// Creates a fresh EditorViewState with test state cleared.
    /// CRITICAL: clearTestState() MUST be called BEFORE creating EditorViewState,
    /// because focusModeEnabled reads UserDefaults at property init time.
    /// Also resets FullScreenManager's static state so no observer/watchdog/pending
    /// intent leaks in from a previous test.
    /// (Internal, not private: FocusModeTests+InlineAnnotations.swift, an extension of this
    /// suite in another file, shares it. The suite is `.serialized` because those tests
    /// change the process-wide FocusModeSettingsManager singleton.)
    @MainActor
    func makeSUT() -> EditorViewState {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        return EditorViewState()
    }

    // MARK: - Enter Focus Mode

    @Test("enterFocusMode sets focusModeEnabled = true")
    @MainActor
    func enterSetsFocusModeEnabled() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()

        #expect(sut.focusModeEnabled == true)
    }

    @Test("enterFocusMode captures preFocusModeState snapshot")
    @MainActor
    func enterCapturesSnapshot() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite
        #expect(sut.preFocusModeState == nil)

        sut.enterFocusMode()

        #expect(sut.preFocusModeState != nil)
    }

    @Test("enterFocusMode hides sidebars per FocusModeSettingsManager settings")
    @MainActor
    func enterHidesSidebars() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = true

        // Default settings hide both sidebars
        sut.enterFocusMode()

        #expect(sut.isOutlineSidebarVisible == false)
        #expect(sut.isAnnotationPanelVisible == false)
    }

    // MARK: - Exit Focus Mode

    @Test("exitFocusMode restores sidebar visibility from snapshot")
    @MainActor
    func exitRestoresSidebars() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = true

        sut.enterFocusMode()
        #expect(sut.isOutlineSidebarVisible == false)

        sut.exitFocusMode()
        #expect(sut.isOutlineSidebarVisible == true)
        #expect(sut.isAnnotationPanelVisible == true)
    }

    @Test("exitFocusMode clears preFocusModeState")
    @MainActor
    func exitClearsSnapshot() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()
        #expect(sut.preFocusModeState != nil)

        sut.exitFocusMode()
        #expect(sut.preFocusModeState == nil)
    }

    @Test("exitFocusMode sets focusModeEnabled = false")
    @MainActor
    func exitDisablesFocusMode() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()
        #expect(sut.focusModeEnabled == true)

        sut.exitFocusMode()
        #expect(sut.focusModeEnabled == false)
    }

    // MARK: - Round-Trip

    @Test("Enter → exit round-trip preserves original sidebar state")
    @MainActor
    func roundTripPreservesSidebarState() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        // Start with custom sidebar state: left visible, right hidden
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = false

        sut.enterFocusMode()
        sut.exitFocusMode()

        #expect(sut.isOutlineSidebarVisible == true, "Left sidebar should be restored")
        // Right sidebar was already hidden, focus mode should not have captured it
        // (FocusModeSettingsManager.shared.hideRightSidebar -- "Hide Annotations Panel" --
        // is true by default, so the panel's visibility is captured: annotationPanelVisible
        // = false. That setting concerns the PANEL only; what happens to the annotations in
        // the text is the separate inlineAnnotations preference)
        #expect(sut.isAnnotationPanelVisible == false, "Right sidebar should remain hidden")
    }

    // MARK: - Guards

    @Test("Enter when already in focus mode is a no-op")
    @MainActor
    func enterWhenAlreadyInFocusModeIsNoOp() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()
        let snapshotAfterFirst = sut.preFocusModeState

        // Second enter should be guarded — snapshot should not change
        sut.enterFocusMode()
        #expect(sut.preFocusModeState?.wasInFullScreen == snapshotAfterFirst?.wasInFullScreen)
        #expect(sut.preFocusModeState?.outlineSidebarVisible == snapshotAfterFirst?.outlineSidebarVisible)
    }

    @Test("Exit when not in focus mode is a no-op")
    @MainActor
    func exitWhenNotInFocusModeIsNoOp() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite
        #expect(sut.focusModeEnabled == false)

        // Should not crash or change state
        sut.exitFocusMode()
        #expect(sut.focusModeEnabled == false)
        #expect(sut.preFocusModeState == nil)
    }

    // MARK: - Toolbar/StatusBar Flags

    @Test("enterFocusMode sets toolbar/statusBar hide flags per settings")
    @MainActor
    func enterSetsToolbarStatusBarFlags() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()

        // Default settings hide both
        #expect(sut.focusModeHidesToolbar == true)
        #expect(sut.focusModeHidesStatusBar == true)
    }

    @Test("exitFocusMode clears toolbar/statusBar hide flags")
    @MainActor
    func exitClearsToolbarStatusBarFlags() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }  // also reset after, not just before (makeSUT) -- protects the next suite

        sut.enterFocusMode()
        sut.exitFocusMode()

        #expect(sut.focusModeHidesToolbar == false)
        #expect(sut.focusModeHidesStatusBar == false)
    }
}

// The Outline sidebar's instant (snap) lock. Moved here from
// AnnotationDisplayPersistenceTests+FocusMode.swift to clear SwiftLint's file-length warning;
// same cases, same assertions. These mutate the process-wide FocusModeSettingsManager.shared
// and TestMode state, so they rely on this suite's `.serialized` marker.
extension FocusModeTests {

    // MARK: - The Outline sidebar's instant (snap) lock
    //
    // Focus Mode hides the Outline by assigning `isOutlineSidebarVisible` with no animation in
    // scope, and arms `isOutlineSidebarToggleInstant` so the pane's `.onChange` knows to snap
    // rather than animate. The flag is CONSUMED there -- but in a unit test there is no window
    // and no pane, so whatever Focus Mode armed stays set and is readable at the value site.
    // Every assertion below is a PAIR (flag + visibility): the pane's onChange only snaps if
    // BOTH are in the state the test asserts, and a flag armed without a matching flip is what
    // would wrongly de-animate the pane's next, unrelated toggle.

    /// A fresh window state with the test-only defaults cleared and FullScreenManager reset, and
    /// Focus Mode's "Hide Outline" preference set as given. Also returns the preference's
    /// previous value, for the caller to restore in a `defer` -- `FocusModeSettingsManager.shared`
    /// is a process-wide singleton, so a test must never leave it changed for the next one.
    @MainActor
    private func outlineWindow(hidingOutline hide: Bool) -> (state: EditorViewState, previousHide: Bool) {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        let previousHide = FocusModeSettingsManager.shared.hideLeftSidebar
        FocusModeSettingsManager.shared.hideLeftSidebar = hide
        return (EditorViewState(), previousHide)
    }

    // Case 1: the flip and its arm must land in the same call, or the pane has nothing to consume.
    @Test("Entering Focus Mode arms the Outline's instant flag together with the hide it makes")
    @MainActor
    func enterFocusModeArmsTheOutlineInstantFlagWithTheHide() {
        let (state, previousHide) = outlineWindow(hidingOutline: true)
        defer { TestMode.clearTestState() }   // registered first, so it runs last: the store back as found
        defer { FocusModeSettingsManager.shared.hideLeftSidebar = previousHide }
        defer { FullScreenManager.resetForTesting() }
        #expect(state.isOutlineSidebarVisible, "The outline starts visible, so Enter's hide is a real flip")

        state.enterFocusMode()

        #expect(state.isOutlineSidebarToggleInstant, "Armed in the same turn as the flip")
        #expect(state.isOutlineSidebarVisible == false, "and the flip happened")
    }

    // Case 2: arming with no flip would leave a flag nothing consumes, to de-snap a later toggle.
    @Test("Entering Focus Mode does not arm the Outline's instant flag when the outline is already hidden")
    @MainActor
    func enterFocusModeDoesNotArmWithoutAFlip() {
        let (state, previousHide) = outlineWindow(hidingOutline: true)
        defer { TestMode.clearTestState() }   // registered first, so it runs last: the store back as found
        defer { FocusModeSettingsManager.shared.hideLeftSidebar = previousHide }
        defer { FullScreenManager.resetForTesting() }
        state.isOutlineSidebarVisible = false   // the user hid the outline before entering

        state.enterFocusMode()

        #expect(state.isOutlineSidebarToggleInstant == false, "Nothing will consume an arm: the value cannot flip")
        #expect(state.isOutlineSidebarVisible == false)
    }

    // Case 3: the restore needs its own arm -- clear Enter's first, exactly as the pane's onChange
    // would have, so this proves EXIT arms rather than inheriting Enter's still-set flag.
    @Test("Leaving Focus Mode arms the Outline's instant flag together with the restore it makes")
    @MainActor
    func exitFocusModeArmsTheOutlineInstantFlagWithTheRestore() {
        let (state, previousHide) = outlineWindow(hidingOutline: true)
        defer { TestMode.clearTestState() }   // registered first, so it runs last: the store back as found
        defer { FocusModeSettingsManager.shared.hideLeftSidebar = previousHide }
        defer { FullScreenManager.resetForTesting() }
        state.enterFocusMode()
        #expect(state.isOutlineSidebarVisible == false)
        state.isOutlineSidebarToggleInstant = false   // the pane consumed Enter's arm

        state.exitFocusMode()

        #expect(state.isOutlineSidebarToggleInstant, "Armed in the same turn as the restore")
        #expect(state.isOutlineSidebarVisible, "and the restore happened")
    }

    // Case 4: the same "nothing to flip" guard on the way out -- once with the outline captured
    // but unchanged, once with the visibility not captured at all (the preference is off).
    @Test("Leaving Focus Mode does not arm the Outline's instant flag when there is no flip")
    @MainActor
    func exitFocusModeDoesNotArmWithoutAFlip() {
        let (state, previousHide) = outlineWindow(hidingOutline: true)
        defer { TestMode.clearTestState() }   // registered first, so it runs last: the store back as found
        defer { FocusModeSettingsManager.shared.hideLeftSidebar = previousHide }
        defer { FullScreenManager.resetForTesting() }
        state.isOutlineSidebarVisible = false
        state.enterFocusMode()                       // captures visible = false; nothing to flip
        state.isOutlineSidebarToggleInstant = false  // Enter armed nothing anyway: start Exit clean

        state.exitFocusMode()

        #expect(state.isOutlineSidebarToggleInstant == false, "The snapshot's value equals the current one")
        #expect(state.isOutlineSidebarVisible == false, "and nothing was restored, because nothing was hidden")

        // The preference off: Focus Mode captures no outline visibility at all, so Exit has no
        // value to write and must not arm either. clearTestState() first: `state` is still in
        // Focus Mode and persisted focusModeEnabled = true, which a fresh state would resume
        // straight into an enterFocusMode() no-op -- a test that asserts nothing.
        TestMode.clearTestState()
        FocusModeSettingsManager.shared.hideLeftSidebar = false
        let untouched = EditorViewState()
        #expect(untouched.focusModeEnabled == false, "Precondition: this state really will enter Focus Mode")
        untouched.enterFocusMode()
        #expect(untouched.isOutlineSidebarToggleInstant == false)
        #expect(untouched.isOutlineSidebarVisible, "Enter never touched the outline")

        untouched.exitFocusMode()

        #expect(untouched.isOutlineSidebarToggleInstant == false, "No captured value, so no arm")
        #expect(untouched.isOutlineSidebarVisible, "and no restore to make")
    }

    // Case 5: the plain ⌘[ path clears any arm on the way in, so Focus Mode's leftover can never
    // de-snap it. Both routes into an armed flag: Focus Mode's own, and one set directly.
    @Test("The plain outline toggle clears an armed instant flag and still flips the visibility")
    @MainActor
    func plainOutlineToggleClearsAnArmedInstantFlag() {
        let (state, previousHide) = outlineWindow(hidingOutline: true)
        defer { TestMode.clearTestState() }   // registered first, so it runs last: the store back as found
        defer { FocusModeSettingsManager.shared.hideLeftSidebar = previousHide }
        defer { FullScreenManager.resetForTesting() }
        state.enterFocusMode()
        #expect(state.isOutlineSidebarToggleInstant, "Precondition: Focus Mode's arm is still set, nothing consumed it")

        state.toggleOutlineSidebar()

        #expect(state.isOutlineSidebarToggleInstant == false, "Cleared, so this toggle keeps its normal animation")
        #expect(state.isOutlineSidebarVisible, "and the toggle flipped the hidden outline back on")

        // The same clear for a window that is NOT in Focus Mode but still carries a leftover arm
        // (set directly here, as an unconsumed Focus Mode arm would sit): the ordinary ⌘[ path.
        // clearTestState() first, or this state resumes Focus Mode from the store.
        TestMode.clearTestState()
        let plain = EditorViewState()
        #expect(plain.focusModeEnabled == false, "Precondition: the plain, non-Focus-Mode toggle")
        plain.isOutlineSidebarToggleInstant = true
        plain.toggleOutlineSidebar()

        #expect(plain.isOutlineSidebarToggleInstant == false)
        #expect(plain.isOutlineSidebarVisible == false, "The toggle still flipped the visible outline off")
    }
}
