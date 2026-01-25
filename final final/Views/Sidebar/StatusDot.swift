//
//  StatusDot.swift
//  final final
//

import SwiftUI
import AppKit

// MARK: - Status Menu Helper

/// Singleton class that shows an NSMenu for status selection.
/// Used by both long-press gesture and right-click/ctrl-click detection.
@MainActor
class StatusMenuHelper {
    static let shared = StatusMenuHelper()
    private var onSelect: ((SectionStatus) -> Void)?

    private init() {}

    func showMenu(
        for currentStatus: SectionStatus,
        themeManager: ThemeManager,
        onSelect: @escaping (SectionStatus) -> Void
    ) {
        self.onSelect = onSelect
        let menu = NSMenu()

        for option in SectionStatus.allCases {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(menuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.image = createColorDot(
                color: themeManager.currentTheme.statusColors.color(for: option)
            )
            if option == currentStatus {
                item.state = .on
            }
            menu.addItem(item)
        }

        // Show at current mouse location
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let status = sender.representedObject as? SectionStatus else { return }
        onSelect?(status)
    }

    /// Creates a small circular image filled with the given color
    private func createColorDot(color: Color) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Right-Click / Ctrl-Click Detection

/// NSViewRepresentable that detects right-click AND ctrl+left-click to show the status menu.
/// Uses local event monitor so it doesn't block SwiftUI gestures.
struct StatusMenuTrigger: NSViewRepresentable {
    @Binding var status: SectionStatus
    let themeManager: ThemeManager

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.onRightClick = { [status, themeManager] in
            StatusMenuHelper.shared.showMenu(
                for: status,
                themeManager: themeManager,
                onSelect: { newStatus in
                    DispatchQueue.main.async {
                        self.status = newStatus
                    }
                }
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickView)?.onRightClick = { [status, themeManager] in
            StatusMenuHelper.shared.showMenu(
                for: status,
                themeManager: themeManager,
                onSelect: { newStatus in
                    DispatchQueue.main.async {
                        self.status = newStatus
                    }
                }
            )
        }
    }
}

/// NSView subclass that detects right-click AND ctrl+left-click using local event monitor.
/// Uses frame-based detection since hitTest returns nil to allow SwiftUI gestures.
private class RightClickView: NSView {
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

// MARK: - StatusDot

/// Colored dot indicating section status
/// - Single click: Cycles to next status with animation
/// - Long press / Right-click / Ctrl-click: Shows NSMenu for direct selection
struct StatusDot: View {
    @Binding var status: SectionStatus
    @Environment(ThemeManager.self) private var themeManager
    @State private var isPressed = false
    @State private var brightness: Double = 0

    private var statusColor: Color {
        themeManager.currentTheme.statusColors.color(for: status)
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 14, height: 14)
            .brightness(brightness)
            .scaleEffect(isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.5), value: isPressed)
            .contentShape(Circle().size(width: 24, height: 24))
            .onTapGesture {
                // Immediate visual feedback
                withAnimation(.spring(response: 0.1, dampingFraction: 0.4)) {
                    isPressed = true
                    brightness = 0.3
                }
                // Change status immediately
                status = status.nextStatus
                // Spring back
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5).delay(0.05)) {
                    isPressed = false
                    brightness = 0
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                showStatusMenu()
            }
            .background(StatusMenuTrigger(status: $status, themeManager: themeManager))
            .help("Click to cycle status, hold or right-click for menu")
    }

    private func showStatusMenu() {
        StatusMenuHelper.shared.showMenu(
            for: status,
            themeManager: themeManager,
            onSelect: { newStatus in
                status = newStatus
            }
        )
    }
}

#Preview {
    @Previewable @State var status: SectionStatus = .next

    HStack(spacing: 16) {
        StatusDot(status: $status)
        Text(status.displayName)
    }
    .padding()
    .environment(ThemeManager.shared)
}
