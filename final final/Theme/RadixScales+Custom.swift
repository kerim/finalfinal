//
//  RadixScales+Custom.swift
//  final final
//

import SwiftUI

// MARK: - Custom Colors (not in standard Radix)

extension RadixScales {

    /// OLED black for High Contrast Night editor background
    static let oledBlack = Color(hex: "#0a0a0a")

    // MARK: - Custom Parchment Scale (warmer than Radix Sand)

    /// Parchment light scale - warm cream/sepia tones for Low Contrast Day
    /// Based on Radix structure but with warmer yellow-brown undertones
    static let parchment = RadixScale(
        step1: Color(hex: "#fdfbf7"),   // Warm off-white
        step2: Color(hex: "#f9f5ed"),   // Light cream
        step3: Color(hex: "#f3ece0"),   // Cream
        step4: Color(hex: "#ebe3d3"),   // Light parchment
        step5: Color(hex: "#e4dac7"),   // Parchment
        step6: Color(hex: "#dcd0ba"),   // Warm tan
        step7: Color(hex: "#cfc2a8"),   // Light brown
        step8: Color(hex: "#bfaf91"),   // Medium brown
        step9: Color(hex: "#a69676"),   // Brown (accent)
        step10: Color(hex: "#978763"),  // Darker brown
        step11: Color(hex: "#6b5d42"),  // Dark brown (readable on light)
        step12: Color(hex: "#3d3425")   // Very dark brown (high contrast)
    )

    /// Parchment dark scale - warm dark tones (if needed for dark parchment theme)
    static let parchmentDark = RadixScale(
        step1: Color(hex: "#141210"),   // Warm black
        step2: Color(hex: "#1c1915"),   // Dark warm
        step3: Color(hex: "#262219"),   // Warmer dark
        step4: Color(hex: "#302a1f"),   // Dark parchment
        step5: Color(hex: "#3a3326"),   // Medium dark
        step6: Color(hex: "#463d2f"),   // Warm gray-brown
        step7: Color(hex: "#574b3a"),   // Light brown dark
        step8: Color(hex: "#6d5e48"),   // Medium brown
        step9: Color(hex: "#a69676"),   // Brown accent
        step10: Color(hex: "#b8a687"),  // Lighter brown
        step11: Color(hex: "#d4c4a8"),  // Light tan (readable on dark)
        step12: Color(hex: "#f0e6d2")   // Cream (high contrast)
    )
}

// MARK: - Color Hex Initializer

extension Color {
    /// Initialize a Color from a hex string (e.g., "#FF5500" or "FF5500")
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: // RGB
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // ARGB (ignore alpha, use RGB)
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}
