//
//  ImageImportErrorPresenter.swift
//  final final
//
//  Single Swift presenter for image-import errors, shared by both editor
//  coordinators (MilkdownCoordinator+Images.swift, CodeMirrorCoordinator+Images.swift)
//  -- see .claude/rules/ux-contract.md §4.4, "one error class, one presenter".
//

import AppKit
import WebKit

/// Presents the "Image Import Failed" alert both editors show, for both call
/// sites each (paste and native file picker), in one place instead of four
/// byte-for-byte-duplicated inline blocks.
@MainActor
enum ImageImportErrorPresenter {

    /// Show a native NSAlert for an image-import error.
    /// JS `alert()` is silently swallowed in WKWebView (no WKUIDelegate), so we must use
    /// native alerts.
    ///
    /// Resolves a window the same way every call site already did: `webView?.window ??
    /// NSApp.keyWindow`. When a window is found, this is an unchanged sheet with the
    /// existing wording, restoring focus on dismiss. When no window is found -- a rare
    /// timing situation, but a real one -- this now falls back to an app-modal `runModal()`
    /// alert instead of the previous silent `return`: the import still failed and the image
    /// still never appeared, but the user now actually sees why, instead of the app saying
    /// nothing at all.
    static func present(_ error: Error, restoringFocusTo webView: WKWebView?, context: String) {
        let alert = NSAlert()
        alert.messageText = "Image Import Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let window = webView?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in
                EditorFocusRestoration.restoreFocus(to: webView, context: context)
            }
        } else {
            // NSApp.keyWindow can be nil not just when there's truly no window but whenever
            // the app is simply backgrounded/inactive -- without this, runModal() below can
            // enter a nested modal loop while the app is invisible, blocking the main thread
            // with nothing visible until the user happens to click the app.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            // Reaching this branch means webView is nil, or webView.window is nil (the ??
            // above only falls through when both operands are nil) -- either way there is no
            // window for restoreFocus's AppKit half (`makeFirstResponder`) to target here, so
            // this call cannot meaningfully restore focus. Kept as a deliberate no-op
            // safeguard in case a future change to the window-resolution logic above makes a
            // window available by the time this runs.
            EditorFocusRestoration.restoreFocus(to: webView, context: context)
        }
    }
}
