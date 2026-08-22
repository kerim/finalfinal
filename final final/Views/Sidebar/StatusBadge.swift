//
//  StatusBadge.swift
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

// MARK: - StatusBadge

/// Colored text label indicating section status
/// - Single click: Cycles to next status with animation
/// - Long press / Right-click / Ctrl-click: Shows NSMenu for direct selection
struct StatusBadge: View {
    @Binding var status: SectionStatus
    @Environment(ThemeManager.self) private var themeManager
    @State private var opacity: Double = 1.0
    /// Drives the subtle hover highlight below -- separate from `opacity` (the click-feedback
    /// dim/fade), and separate from the card's own whole-row hover background, so this control
    /// visibly calls out that it has its own right-click/ctrl-click behavior.
    @State private var isHovering = false

    private var statusColor: Color {
        themeManager.currentTheme.statusColors.color(for: status)
    }

    var body: some View {
        Text(status.displayName)
            .font(.system(size: TypeScale.smallUI, weight: .medium))
            .foregroundColor(statusColor)
            .frame(minWidth: 48, alignment: .trailing)
            .opacity(opacity)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(themeManager.currentTheme.accentColor.opacity(isHovering ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Immediate visual feedback: dim
                withAnimation(.easeOut(duration: 0.08)) {
                    opacity = 0.4
                }
                // Change status immediately
                status = status.nextStatus
                // Fade back
                withAnimation(.easeIn(duration: 0.15).delay(0.05)) {
                    opacity = 1.0
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                showStatusMenu()
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovering = hovering
                }
            }
            .background(RightClickCatcher(onRightClick: showStatusMenu))
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
    @Previewable @State var statuses: [SectionStatus] = SectionStatus.allCases

    VStack(alignment: .trailing, spacing: 8) {
        ForEach(Array(statuses.enumerated()), id: \.offset) { index, _ in
            StatusBadge(status: $statuses[index])
        }
    }
    .padding()
    .environment(ThemeManager.shared)
}
