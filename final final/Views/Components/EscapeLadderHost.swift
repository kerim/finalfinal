//
//  EscapeLadderHost.swift
//  final final
//
//  Registers a window's EscapeLadderContext with EscapeLadderRegistry for the lifetime of the
//  window, so AppDelegate's single app-wide Esc monitor can find the right context. Modeled on
//  Views/Sidebar/RightClickCatcher.swift's NSViewRepresentable-hosts-an-NSView pattern, but
//  installs NO event monitor of its own -- the one Esc monitor lives in AppDelegate.
//

import SwiftUI
import AppKit

/// Attach as `.background(EscapeLadderHost(context: escapeLadder))` on the editor container.
struct EscapeLadderHost: NSViewRepresentable {
    let context: EscapeLadderContext

    func makeNSView(context representableContext: Context) -> EscapeLadderHostView {
        let view = EscapeLadderHostView()
        view.context = context
        return view
    }

    func updateNSView(_ nsView: EscapeLadderHostView, context representableContext: Context) {
        nsView.context = context
    }
}

/// Invisible NSView whose only job is to notice which window it's in and register/unregister
/// the associated `EscapeLadderContext` with `EscapeLadderRegistry` accordingly.
@MainActor
final class EscapeLadderHostView: NSView {
    var context: EscapeLadderContext?
    private weak var registeredWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Unregister unconditionally, not only when `newWindow == nil`: a direct window-to-
        // window move (this view reparented straight from window A to window B, never passing
        // through a nil-window state in between) would otherwise leave window A's registry
        // entry behind forever -- `viewDidMoveToWindow` below re-registers against whichever
        // window this view ends up in, nil or not.
        unregister()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let context, let w = window {
            EscapeLadderRegistry.shared.register(context, for: w)
            registeredWindow = w
        }
    }

    /// Mirrors `RightClickCatcher.RightClickView.hitTest` -- this view has no visible content
    /// and exists only to observe window membership, so it must never intercept hit-testing
    /// (clicks, hover) meant for whatever it's layered under/over in the editor container.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    deinit {
        // deinit is always nonisolated even on an @MainActor type (see
        // MilkdownEditor.Coordinator.deinit for the same reasoning); NSView teardown reliably
        // happens on the main thread, so asserting isolation here is safe.
        MainActor.assumeIsolated {
            unregister()
        }
    }

    private func unregister() {
        if let w = registeredWindow {
            EscapeLadderRegistry.shared.unregister(for: w)
        }
        registeredWindow = nil
    }
}
