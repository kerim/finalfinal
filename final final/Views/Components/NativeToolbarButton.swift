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
    /// Tooltip text shown on hover (UX contract §6: "every toolbar button's tooltip
    /// shows its shortcut"). Required, not defaulted — every caller must decide its
    /// own tooltip rather than silently getting none.
    let helpText: String
    /// Supplementary VoiceOver hint (distinct from the visual tooltip in `helpText`).
    /// Set via `NSAccessibility`'s `accessibilityHelp`, not a SwiftUI `.accessibilityHint(...)`
    /// modifier — this view manages its own accessibility state manually (see
    /// `setAccessibilityLabel` below), and layering a SwiftUI-level accessibility modifier
    /// on top of an `NSViewRepresentable` that already does this can make SwiftUI wrap the
    /// represented view in its own accessibility element, dropping the manually-set label
    /// entirely. Optional — most toolbar buttons don't need one.
    let accessibilityHint: String?
    /// Stable UI-test/automation handle, independent of the AX label (which changes with
    /// button state). Set via `NSAccessibility`'s `accessibilityIdentifier`, not a SwiftUI
    /// `.accessibilityIdentifier(...)` trailing modifier on the call site — for the same
    /// reason `accessibilityHint` above is set at the AppKit level: a SwiftUI-level
    /// accessibility modifier on top of this NSViewRepresentable can make SwiftUI wrap the
    /// represented view in its own accessibility element, dropping the manually-set label
    /// and identifier. Optional — most toolbar buttons don't need one.
    let toolbarAccessibilityIdentifier: String?
    let action: @MainActor () -> Void

    init(
        systemSymbolName: String,
        accessibilityLabel: String,
        helpText: String,
        accessibilityHint: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.systemSymbolName = systemSymbolName
        self.accessibilityLabel = accessibilityLabel
        self.helpText = helpText
        self.accessibilityHint = accessibilityHint
        self.toolbarAccessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction  // Modern toolbar button style
        button.isBordered = true                  // Enables hover/click states

        // Use hierarchical rendering with labelColor to match native toolbar button brightness
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))

        let image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
        // In an NSToolbarItem-hosted NSViewRepresentable, AppKit/XCUITest derives the
        // exposed accessibility label from the SF Symbol image's own accessibilityDescription
        // rather than from `button.setAccessibilityLabel` below — set it on the final
        // configured image (after withSymbolConfiguration, which returns a new NSImage) so
        // the intended label actually reaches the element XCUITest queries.
        image?.accessibilityDescription = accessibilityLabel
        button.image = image

        button.title = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked)

        // Set accessibility on the button itself (not just the image)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp(accessibilityHint)
        button.setAccessibilityIdentifier(toolbarAccessibilityIdentifier)
        button.toolTip = helpText.isEmpty ? nil : helpText

        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        // Update image and accessibility label for state changes
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))

        let image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
        // See makeNSView: the symbol image's own accessibilityDescription, not
        // setAccessibilityLabel below, is what an NSToolbarItem-hosted representable
        // actually exposes to accessibility clients/XCUITest.
        image?.accessibilityDescription = accessibilityLabel
        nsView.image = image

        nsView.setAccessibilityLabel(accessibilityLabel)
        nsView.setAccessibilityHelp(accessibilityHint)
        nsView.setAccessibilityIdentifier(toolbarAccessibilityIdentifier)
        nsView.toolTip = helpText.isEmpty ? nil : helpText
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
