//
//  WindowTitleHost.swift
//  final final
//
//  Keeps the main window's AppKit title in step with the SwiftUI value that names the document.
//

import SwiftUI
import AppKit

/// Attach as `.background(WindowTitleHost(title: ...))` on the editor container.
///
/// Why this exists, and why it is ADDITIVE rather than a replacement for `.navigationTitle`:
/// `ContentView`'s split container is a plain `HSplitView` with no navigation container around
/// it, so SwiftUI may stop routing `.navigationTitle` to `NSWindow.title`. Nothing else in the
/// app sets that title (`DevBuildBadge` writes only `window.subtitle`, and only in DEBUG), so the
/// failure mode would be a window silently titled with the generic app name. Both halves are kept
/// on purpose: `.navigationTitle` remains the SwiftUI-correct declaration (and is what any future
/// navigation container would read), while this host makes the SAME string explicit at the AppKit
/// level. Because both carry one value -- `documentManager.projectTitle ?? "Untitled"` -- there is
/// nothing for them to disagree about when both are active.
///
/// Modeled on `EscapeLadderHost`'s "invisible NSView notices which window it is in" pattern (the
/// codebase's existing way of reaching a hosting `NSWindow` from the view tree), rather than
/// observing `NSApp.windows` or reaching for `AppDelegate.mainWindow`, both of which can be stale
/// or wrongly scoped during launch.
struct WindowTitleHost: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleHostView {
        WindowTitleHostView()
    }

    /// Runs on first mount and again whenever `title` changes, so the window title tracks
    /// `documentManager.projectTitle` instead of being set once on appear.
    func updateNSView(_ nsView: WindowTitleHostView, context: Context) {
        nsView.title = title
    }
}

/// Invisible NSView whose only job is to put a title onto whichever window it lands in.
@MainActor
final class WindowTitleHostView: NSView {
    var title: String = "" {
        didSet { applyTitle() }
    }

    /// Also applies on window membership, so the title is set even when `updateNSView` ran before
    /// this view was in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTitle()
    }

    /// Never intercepts hit-testing -- this view has no visible content and exists only to reach
    /// its `NSWindow` (same rationale as `EscapeLadderHostView.hitTest`).
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func applyTitle() {
        // An empty title would blank the window; the caller always passes a fallback, so treat
        // empty as "nothing to say" rather than as an instruction to clear it.
        guard let window, !title.isEmpty else { return }
        window.title = title
    }
}
