//
//  FullScreenManager.swift
//  final final
//

import AppKit

/// Manages full screen state for focus mode.
/// NSWindow access is required because SwiftUI doesn't provide direct full screen control.
@MainActor
struct FullScreenManager {
    /// Check if the main window is currently in full screen mode
    static func isInFullScreen() -> Bool {
        NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
    }

    /// Enter full screen mode (if not already)
    /// Note: toggleFullScreen(_:) is animated (~500ms). Callers should await after calling.
    static func enterFullScreen() {
        guard let window = NSApp.mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// Exit full screen mode (if currently in full screen)
    /// Note: toggleFullScreen(_:) is animated (~500ms). Callers should await after calling.
    static func exitFullScreen() {
        guard let window = NSApp.mainWindow,
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
