//
//  ColorScheme.swift
//  final final
//

import SwiftUI

/// Colors for section status indicators
struct StatusColors: Equatable, Sendable {
    let writing: Color
    let next: Color
    let waiting: Color
    let review: Color
    let final_: Color

    func color(for status: SectionStatus) -> Color {
        switch status {
        case .writing: return writing
        case .next: return next
        case .waiting: return waiting
        case .review: return review
        case .final_: return final_
        }
    }

    /// Default status colors for light themes
    static let light = StatusColors(
        writing: Color(red: 0.15, green: 0.39, blue: 0.92),  // #2563eb
        next: Color(red: 0.92, green: 0.35, blue: 0.05),     // #ea580c
        waiting: Color(red: 0.79, green: 0.54, blue: 0.02),  // #ca8a04
        review: Color(red: 0.58, green: 0.20, blue: 0.92),   // #9333ea
        final_: Color(red: 0.09, green: 0.64, blue: 0.26)    // #16a34a
    )

    /// Brighter status colors for dark themes
    static let dark = StatusColors(
        writing: Color(red: 0.38, green: 0.65, blue: 0.98),  // #60a5fa
        next: Color(red: 0.98, green: 0.57, blue: 0.24),     // #fb923c
        waiting: Color(red: 0.99, green: 0.83, blue: 0.31),  // #fcd34d
        review: Color(red: 0.75, green: 0.52, blue: 0.99),   // #c084fc
        final_: Color(red: 0.29, green: 0.87, blue: 0.50)    // #4ade80
    )

    /// Nord-themed status colors
    static let nord = StatusColors(
        writing: Color(red: 0.51, green: 0.63, blue: 0.76),  // #81a1c1
        next: Color(red: 0.82, green: 0.53, blue: 0.44),     // #d08770
        waiting: Color(red: 0.92, green: 0.80, blue: 0.55),  // #ebcb8b
        review: Color(red: 0.71, green: 0.55, blue: 0.68),   // #b48ead
        final_: Color(red: 0.64, green: 0.75, blue: 0.55)    // #a3be8c
    )
}

/// Colors for annotation marks
struct AnnotationColors: Equatable, Sendable {
    let task: Color
    let taskCompleted: Color
    let comment: Color
    let reference: Color
}

extension AnnotationColors {
    /// Light theme annotation colors
    static let light = AnnotationColors(
        task: Color(red: 0.85, green: 0.47, blue: 0.02),     // #d97706
        taskCompleted: Color(red: 0.02, green: 0.59, blue: 0.41), // #059669
        comment: Color(red: 0.15, green: 0.39, blue: 0.92),  // #2563eb
        reference: Color(red: 0.49, green: 0.23, blue: 0.93) // #7c3aed
    )

    /// High contrast night annotation colors
    static let highContrastNight = AnnotationColors(
        task: Color(red: 0.98, green: 0.75, blue: 0.15),     // #fbbf24
        taskCompleted: Color(red: 0.20, green: 0.83, blue: 0.60), // #34d399
        comment: Color(red: 0.38, green: 0.65, blue: 0.98),  // #60a5fa
        reference: Color(red: 0.65, green: 0.55, blue: 0.98) // #a78bfa
    )

    /// Nord-themed annotation colors
    static let nord = AnnotationColors(
        task: Color(red: 0.92, green: 0.80, blue: 0.55),     // #ebcb8b
        taskCompleted: Color(red: 0.64, green: 0.75, blue: 0.55), // #a3be8c
        comment: Color(red: 0.53, green: 0.75, blue: 0.82),  // #88c0d0
        reference: Color(red: 0.71, green: 0.55, blue: 0.68) // #b48ead
    )
}

struct AppColorScheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sidebarBackground: Color
    let sidebarText: Color
    let sidebarSelectedBackground: Color
    let editorBackground: Color
    let editorText: Color
    let editorSelection: Color
    let accentColor: Color
    let dividerColor: Color

    /// Section status colors
    let statusColors: StatusColors

    /// Annotation colors
    let annotationColors: AnnotationColors

    /// Highlight background color
    let highlightBackground: Color

    /// Tooltip background color
    let tooltipBackground: Color

    /// Tooltip text color
    let tooltipText: Color

    /// Keyboard shortcut key for this theme (used with Cmd+Opt)
    let shortcutKey: Character?

    /// Generates CSS custom properties string for web editor injection
    var cssVariables: String {
        """
        --editor-bg: \(editorBackground.cssHex);
        --editor-text: \(editorText.cssHex);
        --editor-selection: \(editorSelection.cssHexWithAlpha);
        --accent-color: \(accentColor.cssHex);
        --sidebar-bg: \(sidebarBackground.cssHex);
        --sidebar-text: \(sidebarText.cssHex);
        --divider-color: \(dividerColor.cssHex);
        --annotation-task: \(annotationColors.task.cssHex);
        --annotation-task-completed: \(annotationColors.taskCompleted.cssHex);
        --annotation-comment: \(annotationColors.comment.cssHex);
        --annotation-reference: \(annotationColors.reference.cssHex);
        --highlight-bg: \(highlightBackground.cssHexWithAlpha);
        --tooltip-bg: \(tooltipBackground.cssHex);
        --tooltip-text: \(tooltipText.cssHex);
        \(typographyCssVariables)
        """
    }

    /// Typography CSS variables - adjusted weights for dark themes
    var typographyCssVariables: String {
        if isDarkTheme {
            return """
                --weight-heading: 500;
                --weight-body: 300;
                """
        }
        return """
            --weight-heading: 600;
            --weight-body: 400;
            """
    }

    /// Whether this is a dark theme (for typography weight adjustment)
    var isDarkTheme: Bool {
        id.contains("night")
    }

    /// Returns the keyboard shortcut for this theme, if defined
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = shortcutKey else { return nil }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
    }
}

// MARK: - Color CSS Hex Extension

extension Color {
    /// Converts Color to CSS hex string (e.g., "#FF5500")
    /// Uses sRGB color space for consistent cross-platform color representation
    var cssHex: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else {
            return "#000000"
        }
        return String(format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }

    /// Converts Color to CSS rgba string for colors with alpha
    /// Uses sRGB color space for consistent cross-platform color representation
    var cssHexWithAlpha: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else {
            return "rgba(0,0,0,0.3)"
        }
        let alpha = rgb.alphaComponent
        if alpha >= 0.99 {
            return cssHex
        }
        return String(format: "rgba(%d,%d,%d,%.2f)",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255),
            alpha
        )
    }
}

// MARK: - Theme Presets

extension AppColorScheme {
    /// High Contrast Day - White editor with black sidebar
    static let highContrastDay = AppColorScheme(
        id: "high-contrast-day",
        name: "High Contrast Day",
        sidebarBackground: Color(red: 0.10, green: 0.10, blue: 0.10),  // #1a1a1a (black)
        sidebarText: Color(red: 0.93, green: 0.93, blue: 0.93),        // #ededed (light)
        sidebarSelectedBackground: Color(red: 0, green: 0.40, blue: 0.80).opacity(0.35), // blue 35%
        editorBackground: Color.white,                                  // #ffffff
        editorText: Color(red: 0.10, green: 0.10, blue: 0.10),         // #1a1a1a
        editorSelection: Color(red: 0, green: 0.40, blue: 0.80).opacity(0.25),
        accentColor: Color(red: 0, green: 0.40, blue: 0.80),           // #0066cc
        dividerColor: Color(red: 0.25, green: 0.25, blue: 0.25),       // #404040 (dark divider)
        statusColors: .dark,  // brighter status colors for dark sidebar
        annotationColors: .light,
        highlightBackground: Color(red: 1, green: 0.92, blue: 0.23).opacity(0.4), // yellow 40%
        tooltipBackground: Color(red: 0.12, green: 0.16, blue: 0.22),  // #1f2937
        tooltipText: Color(red: 0.95, green: 0.96, blue: 0.96),        // #f3f4f6
        shortcutKey: "1"
    )

    /// Low Contrast Day - Warm parchment tones (reduced contrast)
    static let lowContrastDay = AppColorScheme(
        id: "low-contrast-day",
        name: "Low Contrast Day",
        sidebarBackground: Color(red: 0.91, green: 0.87, blue: 0.82),  // #e8ddd1 - darker parchment
        sidebarText: Color(red: 0.30, green: 0.28, blue: 0.25),        // #4d4740 - slightly lighter
        sidebarSelectedBackground: Color(red: 0.55, green: 0.45, blue: 0.33).opacity(0.25), // brown 25%
        editorBackground: Color(red: 0.94, green: 0.91, blue: 0.86),   // #f0e8db - darker parchment
        editorText: Color(red: 0.30, green: 0.28, blue: 0.25),         // #4d4740 - slightly lighter
        editorSelection: Color(red: 0.55, green: 0.45, blue: 0.33).opacity(0.25),
        accentColor: Color(red: 0.55, green: 0.45, blue: 0.33),        // #8b7355
        dividerColor: Color(red: 0.82, green: 0.78, blue: 0.71),       // #d1c7b5
        statusColors: .light,
        annotationColors: .light,
        highlightBackground: Color(red: 1, green: 0.76, blue: 0.03).opacity(0.35), // amber 35%
        tooltipBackground: Color(red: 0.30, green: 0.28, blue: 0.25),  // #4d4740
        tooltipText: Color(red: 0.94, green: 0.91, blue: 0.86),        // #f0e8db
        shortcutKey: "2"
    )

    /// High Contrast Night - OLED black with orange text
    static let highContrastNight = AppColorScheme(
        id: "high-contrast-night",
        name: "High Contrast Night",
        sidebarBackground: Color(red: 0.10, green: 0.10, blue: 0.10),  // #1a1a1a
        sidebarText: Color(red: 1.0, green: 0.65, blue: 0.30),         // #ffa64d (orange)
        sidebarSelectedBackground: Color(red: 1, green: 0.72, blue: 0.30).opacity(0.30), // orange 30%
        editorBackground: Color(red: 0.04, green: 0.04, blue: 0.04),   // #0a0a0a (OLED)
        editorText: Color(red: 1.0, green: 0.65, blue: 0.30),          // #ffa64d (orange)
        editorSelection: Color(red: 1, green: 0.72, blue: 0.30).opacity(0.30),
        accentColor: Color(red: 1, green: 0.72, blue: 0.30),           // #ffb74d
        dividerColor: Color(red: 0.20, green: 0.20, blue: 0.20),       // #333333
        statusColors: .dark,
        annotationColors: .highContrastNight,
        highlightBackground: Color(red: 1, green: 0.72, blue: 0.30).opacity(0.25), // orange 25%
        tooltipBackground: Color(red: 1.0, green: 0.65, blue: 0.30),   // inverted - orange bg
        tooltipText: Color(red: 0.04, green: 0.04, blue: 0.04),        // inverted - black text
        shortcutKey: "3"
    )

    /// Low Contrast Night - Nord palette
    static let lowContrastNight = AppColorScheme(
        id: "low-contrast-night",
        name: "Low Contrast Night",
        sidebarBackground: Color(red: 0.23, green: 0.26, blue: 0.32),  // #3b4252 (nord1)
        sidebarText: Color(red: 0.85, green: 0.87, blue: 0.91),        // #d8dee9 (nord4)
        sidebarSelectedBackground: Color(red: 0.53, green: 0.75, blue: 0.82).opacity(0.25), // cyan 25%
        editorBackground: Color(red: 0.18, green: 0.20, blue: 0.25),   // #2e3440 (nord0)
        editorText: Color(red: 0.85, green: 0.87, blue: 0.91),         // #d8dee9
        editorSelection: Color(red: 0.53, green: 0.75, blue: 0.82).opacity(0.25),
        accentColor: Color(red: 0.53, green: 0.75, blue: 0.82),        // #88c0d0 (nord8)
        dividerColor: Color(red: 0.30, green: 0.34, blue: 0.42),       // #4c566a (nord3)
        statusColors: .nord,
        annotationColors: .nord,
        highlightBackground: Color(red: 0.92, green: 0.80, blue: 0.55).opacity(0.25), // amber 25%
        tooltipBackground: Color(red: 0.93, green: 0.94, blue: 0.96),  // #eceff4 (nord6)
        tooltipText: Color(red: 0.18, green: 0.20, blue: 0.25),        // #2e3440 (nord0)
        shortcutKey: "4"
    )

    static let all: [AppColorScheme] = [.highContrastDay, .lowContrastDay, .highContrastNight, .lowContrastNight]
}
