//
//  EditorViewState+FocusMode.swift
//  final final
//

import SwiftUI

// MARK: - Focus Mode

extension EditorViewState {

    /// Simple toggle for legacy callers
    func toggleFocusMode() {
        if focusModeEnabled {
            exitFocusMode()
        } else {
            enterFocusMode()
        }
    }

    /// Enter focus mode with configurable UI hiding based on preferences
    func enterFocusMode() {
        guard !focusModeEnabled else { return }

        let settings = FocusModeSettingsManager.shared

        // 1. Capture pre-focus state — only for elements that will be modified.
        // wasInFullScreen deliberately uses isSettledFullScreen(), NOT isEffectivelyFullScreen():
        // an .entering phase here might be a still-unresolved request from an earlier,
        // already-ended Focus Mode session (e.g. one interrupted mid-transition), not a real
        // pre-existing full-screen state the user set independently. Treating that as "already
        // full screen" is what stranded users in full screen after exiting Focus Mode, having
        // never asked for native full screen at all. See FullScreenTransitionModel.isSettledFullScreen().
        preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: FullScreenManager.isSettledFullScreen(),
            outlineSidebarVisible: settings.hideLeftSidebar ? isOutlineSidebarVisible : nil,
            annotationPanelVisible: settings.hideRightSidebar ? isAnnotationPanelVisible : nil,
            annotationDisplayModes: settings.hideRightSidebar ? annotationDisplayModes : nil
        )

        // 2. Enter full screen. FullScreenManager coalesces this against any transition
        // already in flight, so it's always safe to call unconditionally — no need to check
        // current state first, and no need to wait for the animation here.
        FullScreenManager.request(.fullScreen)

        // 3. Conditionally hide sidebars with animation
        // t-784ff3aa: only set the instant-toggle flag when this will actually flip
        // isAnnotationPanelVisible (it may already be false, e.g. the user hid it before
        // entering Focus Mode) -- see the flag's doc comment in EditorViewState.swift for why
        // an unconsumed flag would otherwise corrupt a later, unrelated toggle.
        if settings.hideRightSidebar && isAnnotationPanelVisible {
            isAnnotationPanelToggleInstant = true
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            if settings.hideLeftSidebar { isOutlineSidebarVisible = false }
        }
        // t-784ff3aa: deliberately OUTSIDE the withAnimation block above (unlike
        // isOutlineSidebarVisible, which stays inside it) -- AnnotationPanel's `.frame` derives
        // minWidth/maxWidth directly from this property, so any ambient animation active while
        // it changes gets applied to those bounds by SwiftUI regardless of what `snapToggle`
        // does to `panelWidth`. Assigning it with no animation in scope is what actually makes
        // the panel's Focus Mode transition instant; see snapToggle's doc comment.
        if settings.hideRightSidebar { isAnnotationPanelVisible = false }

        // 4. Collapse annotations only if hiding right sidebar
        if settings.hideRightSidebar {
            for type in AnnotationType.allCases {
                annotationDisplayModes[type] = .collapsed
            }
        }

        // 5. Set runtime state for toolbar/status bar (read by views)
        focusModeHidesToolbar = settings.hideToolbar
        focusModeHidesStatusBar = settings.hideStatusBar

        // 6. Enable focus mode (triggers paragraph highlighting in editors)
        focusModeEnabled = true

        // 7. Show toast notification
        withAnimation {
            ToastCenter.shared.show(ToastFactory.focusModeHint())
        }
    }

    /// Exit focus mode, restoring only the elements that were modified on entry
    func exitFocusMode() {
        guard focusModeEnabled else { return }

        guard let snapshot = preFocusModeState else {
            // No snapshot available - just disable focus mode
            focusModeEnabled = false
            focusModeHidesToolbar = false
            focusModeHidesStatusBar = false
            return
        }

        // 1. Exit full screen ONLY if focus mode entered it (respect user's original state)
        if !snapshot.wasInFullScreen {
            FullScreenManager.request(.windowed)
        }

        // 2. Restore only elements that were captured (non-nil)
        // t-784ff3aa: same "only if it will actually change" guard as enterFocusMode() above --
        // if the panel's visibility never changed during Focus Mode (snapshot value already
        // matches current), there is nothing for AnnotationPanel's onChange to consume, and an
        // unconsumed flag would wrongly de-animate a later, unrelated toggle.
        if let visible = snapshot.annotationPanelVisible, visible != isAnnotationPanelVisible {
            isAnnotationPanelToggleInstant = true
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            if let visible = snapshot.outlineSidebarVisible { isOutlineSidebarVisible = visible }
        }
        // t-784ff3aa: deliberately OUTSIDE the withAnimation block above -- same reasoning as
        // enterFocusMode() above: this property drives AnnotationPanel's `.frame` bounds
        // directly, so it must land with no ambient animation in scope to actually be instant.
        if let visible = snapshot.annotationPanelVisible { isAnnotationPanelVisible = visible }

        // 3. Restore annotation display modes if they were captured
        if let modes = snapshot.annotationDisplayModes { annotationDisplayModes = modes }

        // 4. Clear runtime state
        focusModeHidesToolbar = false
        focusModeHidesStatusBar = false

        // 5. Disable focus mode (disables paragraph highlighting in editors)
        focusModeEnabled = false

        // 6. Clear snapshot
        preFocusModeState = nil
    }

}
