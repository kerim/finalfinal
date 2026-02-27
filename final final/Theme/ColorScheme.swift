//
//  ColorScheme.swift
//  final final
//
//  App color schemes using Radix UI 12-step color scales
//

import SwiftUI

/// Colors for section status indicators
struct StatusColors: Equatable, Sendable {
    let writing: Color
    let next: Color
    let waiting: Color
    let review: Color
    let final_: Color
    let goalWarning: Color   // Orange for word count warning state
    let goalNotMet: Color    // Red for word count not-met state
    let goalMet: Color       // Green for word count met state

    func color(for status: SectionStatus) -> Color {
        switch status {
        case .writing: return writing
        case .next: return next
        case .waiting: return waiting
        case .review: return review
        case .final_: return final_
        }
    }

    /// Light theme status colors using Radix scales
    static let light = StatusColors(
        writing: RadixScales.blue.step9,       // #0090ff - bright blue
        next: RadixScales.orange.step9,        // #f76b15 - vibrant orange
        waiting: RadixScales.yellow.step11,    // #9e6c00 - readable yellow-brown
        review: RadixScales.violet.step9,      // #6e56cf - purple
        final_: RadixScales.green.step9,       // #30a46c - green
        goalWarning: RadixScales.orange.step9, // #f76b15 - orange warning
        goalNotMet: RadixScales.red.step9,     // red not-met
        goalMet: RadixScales.green.step9       // #30a46c - green met
    )

    /// Dark theme status colors using Radix scales (brighter for visibility)
    static let dark = StatusColors(
        writing: RadixScales.blueDark.step10,    // #3b9eff - bright blue
        next: RadixScales.orangeDark.step10,     // #ff801f - bright orange
        waiting: RadixScales.yellowDark.step11,  // #f5e147 - bright yellow
        review: RadixScales.violetDark.step11,   // #baa7ff - bright violet
        final_: RadixScales.greenDark.step11,    // #3dd68c - bright green
        goalWarning: RadixScales.orangeDark.step10, // #ff801f - bright orange warning
        goalNotMet: RadixScales.redDark.step10,     // bright red not-met
        goalMet: RadixScales.greenDark.step11       // #3dd68c - bright green met
    )

    /// Nord-themed status colors (using slate-based muted tones)
    static let nord = StatusColors(
        writing: RadixScales.cyanDark.step9,     // #00a2c7 - cyan (nord frost)
        next: RadixScales.orangeDark.step11,     // #ffa057 - muted orange
        waiting: RadixScales.amberDark.step11,   // #ffca16 - amber
        review: RadixScales.violetDark.step11,   // #baa7ff - soft violet
        final_: RadixScales.greenDark.step11,    // #3dd68c - soft green
        goalWarning: RadixScales.amberDark.step11, // #ffca16 - soft amber warning
        goalNotMet: RadixScales.redDark.step10,    // red not-met
        goalMet: RadixScales.greenDark.step11      // #3dd68c - soft green met
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
    /// Light theme annotation colors using Radix scales
    static let light = AnnotationColors(
        task: RadixScales.amber.step11,          // #ab6400 - amber for tasks
        taskCompleted: RadixScales.green.step9,  // #30a46c - green for completed
        comment: RadixScales.blue.step9,         // #0090ff - blue for comments
        reference: RadixScales.violet.step9      // #6e56cf - violet for references
    )

    /// High contrast night annotation colors
    static let highContrastNight = AnnotationColors(
        task: RadixScales.amberDark.step9,         // #ffc53d - bright amber
        taskCompleted: RadixScales.greenDark.step11, // #3dd68c - bright green
        comment: RadixScales.blueDark.step10,      // #3b9eff - bright blue
        reference: RadixScales.violetDark.step11   // #baa7ff - bright violet
    )

    /// Nord-themed annotation colors
    static let nord = AnnotationColors(
        task: RadixScales.amberDark.step11,        // #ffca16 - soft amber
        taskCompleted: RadixScales.greenDark.step11, // #3dd68c - soft green
        comment: RadixScales.cyanDark.step11,      // #4ccce6 - cyan (nord8)
        reference: RadixScales.violetDark.step11   // #baa7ff - soft violet
    )
}

struct AppColorScheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sidebarBackground: Color
    let sidebarText: Color
    let sidebarTextSecondary: Color
    let sidebarSelectedBackground: Color
    let editorBackground: Color
    let editorText: Color
    let editorTextSecondary: Color
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
        --editor-text-secondary: \(editorTextSecondary.cssHex);
        --editor-selection: \(editorSelection.cssHexWithAlpha);
        --accent-color: \(accentColor.cssHex);
        --sidebar-bg: \(sidebarBackground.cssHex);
        --sidebar-text: \(sidebarText.cssHex);
        --sidebar-text-secondary: \(sidebarTextSecondary.cssHex);
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

    /// Whether this theme requires dark appearance for the app chrome (title bar, toolbar)
    /// High Contrast Day has a dark sidebar/title bar despite being a "day" theme
    var requiresDarkAppearance: Bool {
        isDarkTheme || id == "high-contrast-day"
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
    /// High Contrast Day - White editor with dark sidebar (Gray + Blue)
    /// Sidebar: grayDark.step1 bg, grayDark.step12 text
    /// Editor: gray.step1 bg (white), gray.step12 text
    /// Accent: blue.step9
    static let highContrastDay = AppColorScheme(
        id: "high-contrast-day",
        name: "High Contrast Day",
        sidebarBackground: RadixScales.grayDark.step1,           // #111111
        sidebarText: RadixScales.grayDark.step12,                // #eeeeee
        sidebarTextSecondary: RadixScales.grayDark.step11,       // #b4b4b4
        sidebarSelectedBackground: RadixScales.blue.step9.opacity(0.35),
        editorBackground: RadixScales.gray.step1,                // #fcfcfc
        editorText: RadixScales.gray.step12,                     // #202020
        editorTextSecondary: RadixScales.gray.step11,            // #646464
        editorSelection: RadixScales.blue.step9.opacity(0.25),
        accentColor: RadixScales.blue.step9,                     // #0090ff
        dividerColor: RadixScales.grayDark.step6,                // #3a3a3a
        statusColors: .dark,
        annotationColors: .light,
        highlightBackground: RadixScales.amber.step9.opacity(0.4),
        tooltipBackground: RadixScales.grayDark.step3,           // #222222
        tooltipText: RadixScales.grayDark.step12,                // #eeeeee
        shortcutKey: "1"
    )

    /// Low Contrast Day - Warm parchment tones (Custom Parchment + Amber)
    /// Sidebar: parchment.step2 bg, parchment.step12 text
    /// Editor: parchment.step1 bg, parchment.step12 text
    /// Accent: parchment.step9 (warm brown)
    static let lowContrastDay = AppColorScheme(
        id: "low-contrast-day",
        name: "Low Contrast Day",
        sidebarBackground: RadixScales.parchment.step3,          // #f3ece0 - visible distinction
        sidebarText: RadixScales.parchment.step12,               // #3d3425
        sidebarTextSecondary: RadixScales.parchment.step11,      // #6b5d42
        sidebarSelectedBackground: RadixScales.parchment.step9.opacity(0.25),
        editorBackground: RadixScales.parchment.step1,           // #fdfbf7
        editorText: RadixScales.parchment.step12,                // #3d3425
        editorTextSecondary: RadixScales.parchment.step11,       // #6b5d42
        editorSelection: RadixScales.parchment.step9.opacity(0.25),
        accentColor: RadixScales.parchment.step9,                // #a69676 - warm brown accent
        dividerColor: RadixScales.parchment.step6,               // #dcd0ba
        statusColors: .light,
        annotationColors: .light,
        highlightBackground: RadixScales.amber.step9.opacity(0.35),
        tooltipBackground: RadixScales.parchment.step12,         // #3d3425
        tooltipText: RadixScales.parchment.step1,                // #fdfbf7
        shortcutKey: "2"
    )

    /// High Contrast Night - OLED black with orange text (Gray Dark + Orange)
    /// Sidebar: grayDark.step1 bg, orangeDark.step9 text
    /// Editor: OLED black bg, orangeDark.step9 text
    /// Accent: orangeDark.step10
    static let highContrastNight = AppColorScheme(
        id: "high-contrast-night",
        name: "High Contrast Night",
        sidebarBackground: RadixScales.grayDark.step1,           // #111111
        sidebarText: RadixScales.orangeDark.step9,               // #f76b15
        sidebarTextSecondary: RadixScales.orangeDark.step11,     // #ffa057
        sidebarSelectedBackground: RadixScales.orangeDark.step10.opacity(0.30),
        editorBackground: RadixScales.oledBlack,                 // #0a0a0a
        editorText: RadixScales.orangeDark.step9,                // #f76b15
        editorTextSecondary: RadixScales.orangeDark.step11,      // #ffa057
        editorSelection: RadixScales.orangeDark.step10.opacity(0.30),
        accentColor: RadixScales.orangeDark.step10,              // #ff801f
        dividerColor: RadixScales.grayDark.step6,                // #3a3a3a
        statusColors: .dark,
        annotationColors: .highContrastNight,
        highlightBackground: RadixScales.orangeDark.step10.opacity(0.25),
        tooltipBackground: RadixScales.orangeDark.step9,         // inverted - orange bg
        tooltipText: RadixScales.oledBlack,                      // inverted - black text
        shortcutKey: "3"
    )

    /// Low Contrast Night - Nord-inspired palette (Slate Dark + Cyan)
    /// Sidebar: slateDark.step2 bg, slateDark.step11 text
    /// Editor: slateDark.step1 bg, slateDark.step11 text
    /// Accent: cyanDark.step9
    static let lowContrastNight = AppColorScheme(
        id: "low-contrast-night",
        name: "Low Contrast Night",
        sidebarBackground: RadixScales.slateDark.step2,          // #18191b
        sidebarText: RadixScales.slateDark.step11,               // #b0b4ba
        sidebarTextSecondary: RadixScales.slateDark.step10,      // #777b84
        sidebarSelectedBackground: RadixScales.cyanDark.step9.opacity(0.25),
        editorBackground: RadixScales.slateDark.step1,           // #111113
        editorText: RadixScales.slateDark.step11,                // #b0b4ba
        editorTextSecondary: RadixScales.slateDark.step10,       // #777b84
        editorSelection: RadixScales.cyanDark.step9.opacity(0.25),
        accentColor: RadixScales.cyanDark.step9,                 // #00a2c7
        dividerColor: RadixScales.slateDark.step6,               // #363a3f
        statusColors: .nord,
        annotationColors: .nord,
        highlightBackground: RadixScales.amberDark.step9.opacity(0.25),
        tooltipBackground: RadixScales.slateDark.step12,         // #edeef0
        tooltipText: RadixScales.slateDark.step1,                // #111113
        shortcutKey: "4"
    )

    static let all: [AppColorScheme] = [.highContrastDay, .lowContrastDay, .highContrastNight, .lowContrastNight]
}
