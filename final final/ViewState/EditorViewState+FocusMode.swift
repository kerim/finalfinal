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

    /// Enter focus mode with full screen, hidden sidebars, and paragraph highlighting
    func enterFocusMode() async {
        guard !focusModeEnabled else { return }

        // 1. Capture pre-focus state for restoration on exit
        preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: FullScreenManager.isInFullScreen(),
            outlineSidebarVisible: isOutlineSidebarVisible,
            annotationPanelVisible: isAnnotationPanelVisible,
            annotationDisplayModes: annotationDisplayModes
        )

        // 2. Enter full screen (if not already)
        if !FullScreenManager.isInFullScreen() {
            FullScreenManager.enterFullScreen()
            // Wait for full screen animation to complete (~500ms, use 600ms for safety)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 3. Hide sidebars with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            isOutlineSidebarVisible = false
            isAnnotationPanelVisible = false
        }

        // 4. Collapse all annotations
        for type in AnnotationType.allCases {
            annotationDisplayModes[type] = .collapsed
        }

        // 5. Enable focus mode (triggers paragraph highlighting in Milkdown)
        focusModeEnabled = true

        // 6. Show toast notification
        showFocusModeToast = true
    }

    /// Exit focus mode, restoring pre-focus state
    func exitFocusMode() async {
        guard focusModeEnabled else { return }

        guard let snapshot = preFocusModeState else {
            // No snapshot available - just disable focus mode
            focusModeEnabled = false
            return
        }

        // 1. Exit full screen ONLY if focus mode entered it (respect user's original state)
        if FullScreenManager.isInFullScreen() && !snapshot.wasInFullScreen {
            FullScreenManager.exitFullScreen()
            // Wait for full screen exit animation to complete
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 2. Restore sidebar visibility with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            isOutlineSidebarVisible = snapshot.outlineSidebarVisible
            isAnnotationPanelVisible = snapshot.annotationPanelVisible
        }

        // 3. Restore annotation display modes
        annotationDisplayModes = snapshot.annotationDisplayModes

        // 4. Disable focus mode (disables paragraph highlighting in Milkdown)
        focusModeEnabled = false

        // 5. Clear snapshot
        preFocusModeState = nil
    }

}
