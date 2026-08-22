//
//  RightClickCatcher.swift
//  final final
//

import SwiftUI
import AppKit

/// Generic NSViewRepresentable that detects right-click AND ctrl+left-click within its frame,
/// using a local AppKit event monitor that consumes the event before SwiftUI's own gesture and
/// context-menu system ever sees it.
///
/// This exists so a specific control inside a sidebar section card (StatusBadge, the word-count
/// label) can keep its own right-click behavior even though the card as a whole also carries a
/// `.contextMenu` for Duplicate/Delete Section (see SectionCardView's `.contextMenu`). Without
/// this guard, a right-click landing anywhere on the card -- including on top of one of these
/// controls -- is claimed by that card-wide context menu instead of reaching the control
/// underneath. Originally written (as a private, StatusBadge-only type) before that card-wide
/// context menu existed; extracted here, unchanged in mechanism, so word count can have the same
/// protection status already had.
///
/// Attach as a `.background(RightClickCatcher(onRightClick: ...))` on the control that needs to
/// own its own right-click.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

/// NSView subclass that detects right-click AND ctrl+left-click using a local event monitor.
/// Uses frame-based detection since `hitTest` returns nil to allow SwiftUI's own gestures
/// (left-click, hover, etc.) on the same region to keep working unimpeded.
class RightClickView: NSView {
    var onRightClick: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Always remove existing monitor to prevent duplicates
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if window != nil {
            // Monitor BOTH right-click AND ctrl+left-click
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]
            ) { [weak self] event in
                guard let self = self else { return event }

                // Check if it's a right-click OR ctrl+left-click
                let isRightClick = event.type == .rightMouseDown
                let isCtrlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)

                guard isRightClick || isCtrlClick else { return event }
                guard event.window === self.window else { return event }
                guard let superview = self.superview else { return event }

                let locationInWindow = event.locationInWindow
                let locationInSuperview = superview.convert(locationInWindow, from: nil)

                if self.frame.contains(locationInSuperview) {
                    DispatchQueue.main.async {
                        self.onRightClick?()
                    }
                    return nil  // Consume event to prevent click-through
                }
                return event
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Don't block hit testing - let events pass through to SwiftUI
        return nil
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
