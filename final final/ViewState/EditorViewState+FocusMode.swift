//
//  EditorViewState+FocusMode.swift
//  final final
//

import SwiftUI

// MARK: - Focus Mode

extension EditorViewState {

    /// Simple toggle for legacy callers (synchronous wrapper)
    func toggleFocusMode() {
        Task {
            if focusModeEnabled {
                await exitFocusMode()
            } else {
                await enterFocusMode()
            }
        }
    }

    /// Enter focus mode with configurable UI hiding based on preferences
    func enterFocusMode() async {
        guard !focusModeEnabled else { return }

        let settings = FocusModeSettingsManager.shared

        // 1. Capture pre-focus state — only for elements that will be modified
        preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: FullScreenManager.isInFullScreen(),
            outlineSidebarVisible: settings.hideLeftSidebar ? isOutlineSidebarVisible : nil,
            annotationPanelVisible: settings.hideRightSidebar ? isAnnotationPanelVisible : nil,
            annotationDisplayModes: settings.hideRightSidebar ? annotationDisplayModes : nil
        )

        // 2. Enter full screen (if not already)
        if !FullScreenManager.isInFullScreen() {
            FullScreenManager.enterFullScreen()
            // Wait for full screen animation to complete (~500ms, use 600ms for safety)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

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
    func exitFocusMode() async {
        guard focusModeEnabled else { return }

        guard let snapshot = preFocusModeState else {
            // No snapshot available - just disable focus mode
            focusModeEnabled = false
            focusModeHidesToolbar = false
            focusModeHidesStatusBar = false
            return
        }

        // 1. Exit full screen ONLY if focus mode entered it (respect user's original state)
        if FullScreenManager.isInFullScreen() && !snapshot.wasInFullScreen {
            FullScreenManager.exitFullScreen()
            // Wait for full screen exit animation to complete
            try? await Task.sleep(nanoseconds: 600_000_000)
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
