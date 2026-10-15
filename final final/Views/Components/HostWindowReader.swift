//
//  HostWindowReader.swift
//  final final
//
//  Tells a callback which `NSWindow` the view tree it is attached to lands in. Used by `ContentView` to register its
//  editor state with ITS window (`AppDelegate.registerEditorState`), so the app's editor state is the main window's,
//  never an extra window's (see `EditorStateRegistry`).
//

import SwiftUI
import AppKit

/// Attach as `.background(HostWindowReader { window in ... })`.
///
/// Modeled on `WindowTitleHost` and `EscapeLadderHost` ("invisible NSView notices which window it is in"), rather than
/// reading `NSApp.windows` or `AppDelegate.mainWindow`, which cannot say which window THIS view is in. The callback runs
/// with the window each time the view lands in one; it is not called when the view leaves a window.
struct HostWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> HostWindowReaderView {
        let view = HostWindowReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: HostWindowReaderView, context: Context) {
        nsView.onWindow = onWindow
    }
}

/// Invisible NSView whose only job is to report the window it lands in.
@MainActor
final class HostWindowReaderView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }

    /// Never intercepts hit-testing (same rationale as `WindowTitleHostView.hitTest`).
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
