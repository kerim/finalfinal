//
//  ColorScheme.swift
//  final final
//

import SwiftUI

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
        """
    }
}

// MARK: - Color CSS Hex Extension

extension Color {
    /// Converts Color to CSS hex string (e.g., "#FF5500")
    var cssHex: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        return String(format: "#%02X%02X%02X",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }

    /// Converts Color to CSS rgba string for colors with alpha
    var cssHexWithAlpha: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
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
    static let light = AppColorScheme(
        id: "light",
        name: "Light",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.2),
        editorBackground: Color.white,
        editorText: Color.black,
        editorSelection: Color.accentColor.opacity(0.3),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let dark = AppColorScheme(
        id: "dark",
        name: "Dark",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.3),
        editorBackground: Color(white: 0.15),
        editorText: Color.white,
        editorSelection: Color.accentColor.opacity(0.4),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let sepia = AppColorScheme(
        id: "sepia",
        name: "Sepia",
        sidebarBackground: Color(red: 0.96, green: 0.94, blue: 0.89),
        sidebarText: Color(red: 0.35, green: 0.30, blue: 0.25),
        sidebarSelectedBackground: Color(red: 0.85, green: 0.80, blue: 0.70),
        editorBackground: Color(red: 0.98, green: 0.96, blue: 0.91),
        editorText: Color(red: 0.35, green: 0.30, blue: 0.25),
        editorSelection: Color(red: 0.85, green: 0.80, blue: 0.70).opacity(0.5),
        accentColor: Color(red: 0.65, green: 0.45, blue: 0.20),
        dividerColor: Color(red: 0.80, green: 0.75, blue: 0.65)
    )

    static let solarizedLight = AppColorScheme(
        id: "solarized-light",
        name: "Solarized Light",
        sidebarBackground: Color(red: 0.99, green: 0.96, blue: 0.89),  // base3
        sidebarText: Color(red: 0.40, green: 0.48, blue: 0.51),        // base00
        sidebarSelectedBackground: Color(red: 0.93, green: 0.91, blue: 0.84),
        editorBackground: Color(red: 0.99, green: 0.96, blue: 0.89),
        editorText: Color(red: 0.40, green: 0.48, blue: 0.51),
        editorSelection: Color(red: 0.93, green: 0.91, blue: 0.84),
        accentColor: Color(red: 0.15, green: 0.55, blue: 0.82),        // blue
        dividerColor: Color(red: 0.93, green: 0.91, blue: 0.84)
    )

    static let solarizedDark = AppColorScheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        sidebarBackground: Color(red: 0.00, green: 0.17, blue: 0.21),  // base03
        sidebarText: Color(red: 0.51, green: 0.58, blue: 0.59),        // base0
        sidebarSelectedBackground: Color(red: 0.03, green: 0.21, blue: 0.26),
        editorBackground: Color(red: 0.00, green: 0.17, blue: 0.21),
        editorText: Color(red: 0.51, green: 0.58, blue: 0.59),
        editorSelection: Color(red: 0.03, green: 0.21, blue: 0.26),
        accentColor: Color(red: 0.15, green: 0.55, blue: 0.82),
        dividerColor: Color(red: 0.03, green: 0.21, blue: 0.26)
    )

    static let all: [AppColorScheme] = [.light, .dark, .sepia, .solarizedLight, .solarizedDark]
}
