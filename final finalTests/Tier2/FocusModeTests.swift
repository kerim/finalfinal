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

@Suite("Focus Mode — Tier 2: Visible Breakage")
struct FocusModeTests {

    // MARK: - Helpers

    /// Creates a fresh EditorViewState with test state cleared.
    /// CRITICAL: clearTestState() MUST be called BEFORE creating EditorViewState,
    /// because focusModeEnabled reads UserDefaults at property init time.
    @MainActor
    private func makeSUT() -> EditorViewState {
        TestMode.clearTestState()
        return EditorViewState()
    }

    // MARK: - Enter Focus Mode

    @Test("enterFocusMode sets focusModeEnabled = true")
    @MainActor
    func enterSetsFocusModeEnabled() async {
        let sut = makeSUT()

        await sut.enterFocusMode()

        #expect(sut.focusModeEnabled == true)
    }

    @Test("enterFocusMode captures preFocusModeState snapshot")
    @MainActor
    func enterCapturesSnapshot() async {
        let sut = makeSUT()
        #expect(sut.preFocusModeState == nil)

        await sut.enterFocusMode()

        #expect(sut.preFocusModeState != nil)
    }

    @Test("enterFocusMode hides sidebars per FocusModeSettingsManager settings")
    @MainActor
    func enterHidesSidebars() async {
        let sut = makeSUT()
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = true

        // Default settings hide both sidebars
        await sut.enterFocusMode()

        #expect(sut.isOutlineSidebarVisible == false)
        #expect(sut.isAnnotationPanelVisible == false)
    }

    // MARK: - Exit Focus Mode

    @Test("exitFocusMode restores sidebar visibility from snapshot")
    @MainActor
    func exitRestoresSidebars() async {
        let sut = makeSUT()
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = true

        await sut.enterFocusMode()
        #expect(sut.isOutlineSidebarVisible == false)

        await sut.exitFocusMode()
        #expect(sut.isOutlineSidebarVisible == true)
        #expect(sut.isAnnotationPanelVisible == true)
    }

    @Test("exitFocusMode clears preFocusModeState")
    @MainActor
    func exitClearsSnapshot() async {
        let sut = makeSUT()

        await sut.enterFocusMode()
        #expect(sut.preFocusModeState != nil)

        await sut.exitFocusMode()
        #expect(sut.preFocusModeState == nil)
    }

    @Test("exitFocusMode sets focusModeEnabled = false")
    @MainActor
    func exitDisablesFocusMode() async {
        let sut = makeSUT()

        await sut.enterFocusMode()
        #expect(sut.focusModeEnabled == true)

        await sut.exitFocusMode()
        #expect(sut.focusModeEnabled == false)
    }

    // MARK: - Round-Trip

    @Test("Enter → exit round-trip preserves original sidebar state")
    @MainActor
    func roundTripPreservesSidebarState() async {
        let sut = makeSUT()

        // Start with custom sidebar state: left visible, right hidden
        sut.isOutlineSidebarVisible = true
        sut.isAnnotationPanelVisible = false

        await sut.enterFocusMode()
        await sut.exitFocusMode()

        #expect(sut.isOutlineSidebarVisible == true, "Left sidebar should be restored")
        // Right sidebar was already hidden, focus mode should not have captured it
        // (FocusModeSettingsManager.shared.hideRightSidebar is true by default,
        // so it captures annotationPanelVisible = false)
        #expect(sut.isAnnotationPanelVisible == false, "Right sidebar should remain hidden")
    }

    // MARK: - Guards

    @Test("Enter when already in focus mode is a no-op")
    @MainActor
    func enterWhenAlreadyInFocusModeIsNoOp() async {
        let sut = makeSUT()

        await sut.enterFocusMode()
        let snapshotAfterFirst = sut.preFocusModeState

        // Second enter should be guarded — snapshot should not change
        await sut.enterFocusMode()
        #expect(sut.preFocusModeState?.wasInFullScreen == snapshotAfterFirst?.wasInFullScreen)
        #expect(sut.preFocusModeState?.outlineSidebarVisible == snapshotAfterFirst?.outlineSidebarVisible)
    }

    @Test("Exit when not in focus mode is a no-op")
    @MainActor
    func exitWhenNotInFocusModeIsNoOp() async {
        let sut = makeSUT()
        #expect(sut.focusModeEnabled == false)

        // Should not crash or change state
        await sut.exitFocusMode()
        #expect(sut.focusModeEnabled == false)
        #expect(sut.preFocusModeState == nil)
    }

    // MARK: - Toolbar/StatusBar Flags

    @Test("enterFocusMode sets toolbar/statusBar hide flags per settings")
    @MainActor
    func enterSetsToolbarStatusBarFlags() async {
        let sut = makeSUT()

        await sut.enterFocusMode()

        // Default settings hide both
        #expect(sut.focusModeHidesToolbar == true)
        #expect(sut.focusModeHidesStatusBar == true)
    }

    @Test("exitFocusMode clears toolbar/statusBar hide flags")
    @MainActor
    func exitClearsToolbarStatusBarFlags() async {
        let sut = makeSUT()

        await sut.enterFocusMode()
        await sut.exitFocusMode()

        #expect(sut.focusModeHidesToolbar == false)
        #expect(sut.focusModeHidesStatusBar == false)
    }
}
