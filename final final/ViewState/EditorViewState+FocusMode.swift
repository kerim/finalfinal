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
        withAnimation(.easeInOut(duration: 0.3)) {
            if settings.hideLeftSidebar { isOutlineSidebarVisible = false }
            if settings.hideRightSidebar { isAnnotationPanelVisible = false }
        }

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
        showFocusModeToast = true
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
        withAnimation(.easeInOut(duration: 0.3)) {
            if let visible = snapshot.outlineSidebarVisible { isOutlineSidebarVisible = visible }
            if let visible = snapshot.annotationPanelVisible { isAnnotationPanelVisible = visible }
        }

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
