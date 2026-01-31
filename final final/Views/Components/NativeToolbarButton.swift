//
//  NativeToolbarButton.swift
//  final final
//

import SwiftUI
import AppKit

/// Native AppKit toolbar button that matches system sidebar toggle appearance.
/// Uses NSButton with `.accessoryBarAction` bezel style for modern toolbar look
/// with proper hover states and hierarchical symbol rendering.
struct NativeToolbarButton: NSViewRepresentable {
    let systemSymbolName: String
    let accessibilityLabel: String
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction  // Modern toolbar button style
        button.isBordered = true                  // Enables hover/click states

        // Use hierarchical rendering with labelColor to match native toolbar button brightness
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))

        button.image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)

        button.title = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked)

        // Set accessibility on the button itself (not just the image)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityRole(.button)

        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        // Update image and accessibility label for state changes
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))

        nsView.image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)

        nsView.setAccessibilityLabel(accessibilityLabel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    @MainActor
    class Coordinator: NSObject {
        let action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func buttonClicked() {
            action()
        }
    }
}
