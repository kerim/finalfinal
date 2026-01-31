//
//  RadixScales.swift
//  final final
//
//  Radix UI 12-step color scale system
//  Reference: https://www.radix-ui.com/colors
//

import SwiftUI

/// A 12-step color scale following Radix UI conventions.
/// Steps 1-2: App/subtle backgrounds
/// Steps 3-5: Interactive component backgrounds (normal, hover, pressed)
/// Steps 6-8: Borders and separators
/// Steps 9-10: Solid backgrounds/accents (highest chroma)
/// Steps 11-12: Text (low/high contrast)
struct RadixScale: Sendable {
    let step1: Color
    let step2: Color
    let step3: Color
    let step4: Color
    let step5: Color
    let step6: Color
    let step7: Color
    let step8: Color
    let step9: Color
    let step10: Color
    let step11: Color
    let step12: Color

    /// Access steps by integer index (1-12)
    subscript(step: Int) -> Color {
        switch step {
        case 1: return step1
        case 2: return step2
        case 3: return step3
        case 4: return step4
        case 5: return step5
        case 6: return step6
        case 7: return step7
        case 8: return step8
        case 9: return step9
        case 10: return step10
        case 11: return step11
        case 12: return step12
        default: return step1
        }
    }
}

// MARK: - Neutral Scales

enum RadixScales {

    // MARK: Gray (Pure neutral)

    /// Gray light scale - pure neutral for light themes
    static let gray = RadixScale(
        step1: Color(hex: "#fcfcfc"),
        step2: Color(hex: "#f9f9f9"),
        step3: Color(hex: "#f0f0f0"),
        step4: Color(hex: "#e8e8e8"),
        step5: Color(hex: "#e0e0e0"),
        step6: Color(hex: "#d9d9d9"),
        step7: Color(hex: "#cecece"),
        step8: Color(hex: "#bbbbbb"),
        step9: Color(hex: "#8d8d8d"),
        step10: Color(hex: "#838383"),
        step11: Color(hex: "#646464"),
        step12: Color(hex: "#202020")
    )

    /// Gray dark scale - pure neutral for dark themes
    static let grayDark = RadixScale(
        step1: Color(hex: "#111111"),
        step2: Color(hex: "#191919"),
        step3: Color(hex: "#222222"),
        step4: Color(hex: "#2a2a2a"),
        step5: Color(hex: "#313131"),
        step6: Color(hex: "#3a3a3a"),
        step7: Color(hex: "#484848"),
        step8: Color(hex: "#606060"),
        step9: Color(hex: "#6e6e6e"),
        step10: Color(hex: "#7b7b7b"),
        step11: Color(hex: "#b4b4b4"),
        step12: Color(hex: "#eeeeee")
    )

    // MARK: Slate (Cool neutral with blue tint)

    /// Slate light scale - cool neutral for light themes
    static let slate = RadixScale(
        step1: Color(hex: "#fcfcfd"),
        step2: Color(hex: "#f9f9fb"),
        step3: Color(hex: "#f0f0f3"),
        step4: Color(hex: "#e8e8ec"),
        step5: Color(hex: "#e0e1e6"),
        step6: Color(hex: "#d9d9e0"),
        step7: Color(hex: "#cdced6"),
        step8: Color(hex: "#b9bbc6"),
        step9: Color(hex: "#8b8d98"),
        step10: Color(hex: "#80828d"),
        step11: Color(hex: "#60646c"),
        step12: Color(hex: "#1c2024")
    )

    /// Slate dark scale - cool neutral for dark themes (Nord-like)
    static let slateDark = RadixScale(
        step1: Color(hex: "#111113"),
        step2: Color(hex: "#18191b"),
        step3: Color(hex: "#212225"),
        step4: Color(hex: "#272a2d"),
        step5: Color(hex: "#2e3135"),
        step6: Color(hex: "#363a3f"),
        step7: Color(hex: "#43484e"),
        step8: Color(hex: "#5a6169"),
        step9: Color(hex: "#696e77"),
        step10: Color(hex: "#777b84"),
        step11: Color(hex: "#b0b4ba"),
        step12: Color(hex: "#edeef0")
    )

    // MARK: Sand (Warm neutral)

    /// Sand light scale - warm neutral for parchment themes
    static let sand = RadixScale(
        step1: Color(hex: "#fdfdfc"),
        step2: Color(hex: "#f9f9f8"),
        step3: Color(hex: "#f1f0ef"),
        step4: Color(hex: "#e9e8e6"),
        step5: Color(hex: "#e2e1de"),
        step6: Color(hex: "#dad9d6"),
        step7: Color(hex: "#cfceca"),
        step8: Color(hex: "#bcbbb5"),
        step9: Color(hex: "#8d8d86"),
        step10: Color(hex: "#82827c"),
        step11: Color(hex: "#63635e"),
        step12: Color(hex: "#21201c")
    )

    /// Sand dark scale - warm neutral for dark themes
    static let sandDark = RadixScale(
        step1: Color(hex: "#111110"),
        step2: Color(hex: "#191918"),
        step3: Color(hex: "#222221"),
        step4: Color(hex: "#2a2a28"),
        step5: Color(hex: "#31312e"),
        step6: Color(hex: "#3b3a37"),
        step7: Color(hex: "#494844"),
        step8: Color(hex: "#62605b"),
        step9: Color(hex: "#6f6d66"),
        step10: Color(hex: "#7c7b74"),
        step11: Color(hex: "#b5b3ad"),
        step12: Color(hex: "#eeeeec")
    )

    // MARK: - Accent Colors

    // MARK: Blue

    /// Blue light scale - primary accent for High Contrast Day
    static let blue = RadixScale(
        step1: Color(hex: "#fbfdff"),
        step2: Color(hex: "#f4faff"),
        step3: Color(hex: "#e6f4fe"),
        step4: Color(hex: "#d5efff"),
        step5: Color(hex: "#c2e5ff"),
        step6: Color(hex: "#acd8fc"),
        step7: Color(hex: "#8ec8f6"),
        step8: Color(hex: "#5eb1ef"),
        step9: Color(hex: "#0090ff"),
        step10: Color(hex: "#0588f0"),
        step11: Color(hex: "#0d74ce"),
        step12: Color(hex: "#113264")
    )

    /// Blue dark scale
    static let blueDark = RadixScale(
        step1: Color(hex: "#0d1520"),
        step2: Color(hex: "#111927"),
        step3: Color(hex: "#0d2847"),
        step4: Color(hex: "#003362"),
        step5: Color(hex: "#004074"),
        step6: Color(hex: "#104d87"),
        step7: Color(hex: "#205d9e"),
        step8: Color(hex: "#2870bd"),
        step9: Color(hex: "#0090ff"),
        step10: Color(hex: "#3b9eff"),
        step11: Color(hex: "#70b8ff"),
        step12: Color(hex: "#c2e6ff")
    )

    // MARK: Orange

    /// Orange light scale
    static let orange = RadixScale(
        step1: Color(hex: "#fefcfb"),
        step2: Color(hex: "#fff7ed"),
        step3: Color(hex: "#ffefd6"),
        step4: Color(hex: "#ffdfb5"),
        step5: Color(hex: "#ffd19a"),
        step6: Color(hex: "#ffc182"),
        step7: Color(hex: "#f5ae73"),
        step8: Color(hex: "#ec9455"),
        step9: Color(hex: "#f76b15"),
        step10: Color(hex: "#ef5f00"),
        step11: Color(hex: "#cc4e00"),
        step12: Color(hex: "#582d1d")
    )

    /// Orange dark scale - accent for High Contrast Night
    static let orangeDark = RadixScale(
        step1: Color(hex: "#17120e"),
        step2: Color(hex: "#1e160f"),
        step3: Color(hex: "#331e0b"),
        step4: Color(hex: "#462100"),
        step5: Color(hex: "#562800"),
        step6: Color(hex: "#66350c"),
        step7: Color(hex: "#7e451d"),
        step8: Color(hex: "#a35829"),
        step9: Color(hex: "#f76b15"),
        step10: Color(hex: "#ff801f"),
        step11: Color(hex: "#ffa057"),
        step12: Color(hex: "#ffe0c2")
    )

    // MARK: Cyan

    /// Cyan light scale
    static let cyan = RadixScale(
        step1: Color(hex: "#fafdfe"),
        step2: Color(hex: "#f2fafe"),
        step3: Color(hex: "#def7f9"),
        step4: Color(hex: "#caf1f6"),
        step5: Color(hex: "#b5e9f0"),
        step6: Color(hex: "#9ddde7"),
        step7: Color(hex: "#7dcedc"),
        step8: Color(hex: "#3db9cf"),
        step9: Color(hex: "#00a2c7"),
        step10: Color(hex: "#0797b9"),
        step11: Color(hex: "#107d98"),
        step12: Color(hex: "#0d3c48")
    )

    /// Cyan dark scale - accent for Low Contrast Night
    static let cyanDark = RadixScale(
        step1: Color(hex: "#0b161a"),
        step2: Color(hex: "#101b20"),
        step3: Color(hex: "#082c36"),
        step4: Color(hex: "#003848"),
        step5: Color(hex: "#004558"),
        step6: Color(hex: "#045468"),
        step7: Color(hex: "#12677e"),
        step8: Color(hex: "#11809c"),
        step9: Color(hex: "#00a2c7"),
        step10: Color(hex: "#23afd0"),
        step11: Color(hex: "#4ccce6"),
        step12: Color(hex: "#b6ecf7")
    )

    // MARK: Amber

    /// Amber light scale - accent for Low Contrast Day
    static let amber = RadixScale(
        step1: Color(hex: "#fefdfb"),
        step2: Color(hex: "#fefbe9"),
        step3: Color(hex: "#fff7c2"),
        step4: Color(hex: "#ffee9c"),
        step5: Color(hex: "#fbe577"),
        step6: Color(hex: "#f3d673"),
        step7: Color(hex: "#e9c162"),
        step8: Color(hex: "#e2a336"),
        step9: Color(hex: "#ffc53d"),
        step10: Color(hex: "#ffba18"),
        step11: Color(hex: "#ab6400"),
        step12: Color(hex: "#4f3422")
    )

    /// Amber dark scale
    static let amberDark = RadixScale(
        step1: Color(hex: "#16120c"),
        step2: Color(hex: "#1d180f"),
        step3: Color(hex: "#302008"),
        step4: Color(hex: "#3f2700"),
        step5: Color(hex: "#4d3000"),
        step6: Color(hex: "#5c3d05"),
        step7: Color(hex: "#714f19"),
        step8: Color(hex: "#8f6424"),
        step9: Color(hex: "#ffc53d"),
        step10: Color(hex: "#ffd60a"),
        step11: Color(hex: "#ffca16"),
        step12: Color(hex: "#ffe7b3")
    )

    // MARK: - Semantic Colors (Status & Annotations)

    // MARK: Green (Success, Final, Completed)

    /// Green light scale
    static let green = RadixScale(
        step1: Color(hex: "#fbfefb"),
        step2: Color(hex: "#f4fbf4"),
        step3: Color(hex: "#e6f6e6"),
        step4: Color(hex: "#d6f1d6"),
        step5: Color(hex: "#c4e8c4"),
        step6: Color(hex: "#addaad"),
        step7: Color(hex: "#8ec98e"),
        step8: Color(hex: "#5bb45b"),
        step9: Color(hex: "#30a46c"),
        step10: Color(hex: "#2b9a66"),
        step11: Color(hex: "#218358"),
        step12: Color(hex: "#193b2d")
    )

    /// Green dark scale
    static let greenDark = RadixScale(
        step1: Color(hex: "#0e1512"),
        step2: Color(hex: "#121b17"),
        step3: Color(hex: "#132d21"),
        step4: Color(hex: "#113b29"),
        step5: Color(hex: "#174933"),
        step6: Color(hex: "#20573e"),
        step7: Color(hex: "#28684a"),
        step8: Color(hex: "#2f7c57"),
        step9: Color(hex: "#30a46c"),
        step10: Color(hex: "#33b074"),
        step11: Color(hex: "#3dd68c"),
        step12: Color(hex: "#b1f1cb")
    )

    // MARK: Red (Errors)

    /// Red light scale
    static let red = RadixScale(
        step1: Color(hex: "#fffcfc"),
        step2: Color(hex: "#fff7f7"),
        step3: Color(hex: "#feebec"),
        step4: Color(hex: "#ffdbdc"),
        step5: Color(hex: "#ffcdce"),
        step6: Color(hex: "#fdbdbe"),
        step7: Color(hex: "#f4a9aa"),
        step8: Color(hex: "#eb8e90"),
        step9: Color(hex: "#e5484d"),
        step10: Color(hex: "#dc3e42"),
        step11: Color(hex: "#ce2c31"),
        step12: Color(hex: "#641723")
    )

    /// Red dark scale
    static let redDark = RadixScale(
        step1: Color(hex: "#191111"),
        step2: Color(hex: "#201314"),
        step3: Color(hex: "#3b1219"),
        step4: Color(hex: "#500f1c"),
        step5: Color(hex: "#611623"),
        step6: Color(hex: "#72232d"),
        step7: Color(hex: "#8c333a"),
        step8: Color(hex: "#b54548"),
        step9: Color(hex: "#e5484d"),
        step10: Color(hex: "#ec5d5e"),
        step11: Color(hex: "#ff9592"),
        step12: Color(hex: "#ffd1d9")
    )

    // MARK: Yellow (Warning, Waiting)

    /// Yellow light scale
    static let yellow = RadixScale(
        step1: Color(hex: "#fdfdf9"),
        step2: Color(hex: "#fefce9"),
        step3: Color(hex: "#fffab8"),
        step4: Color(hex: "#fff394"),
        step5: Color(hex: "#ffe770"),
        step6: Color(hex: "#f3d768"),
        step7: Color(hex: "#e4c767"),
        step8: Color(hex: "#d5ae39"),
        step9: Color(hex: "#ffe629"),
        step10: Color(hex: "#ffdc00"),
        step11: Color(hex: "#9e6c00"),
        step12: Color(hex: "#473b1f")
    )

    /// Yellow dark scale
    static let yellowDark = RadixScale(
        step1: Color(hex: "#14120b"),
        step2: Color(hex: "#1b180f"),
        step3: Color(hex: "#2d2305"),
        step4: Color(hex: "#362b00"),
        step5: Color(hex: "#433500"),
        step6: Color(hex: "#524202"),
        step7: Color(hex: "#665417"),
        step8: Color(hex: "#836a21"),
        step9: Color(hex: "#ffe629"),
        step10: Color(hex: "#ffff57"),
        step11: Color(hex: "#f5e147"),
        step12: Color(hex: "#f6eeb4")
    )

    // MARK: Violet (Review, Reference)

    /// Violet light scale
    static let violet = RadixScale(
        step1: Color(hex: "#fdfcfe"),
        step2: Color(hex: "#faf8ff"),
        step3: Color(hex: "#f4f0fe"),
        step4: Color(hex: "#ebe4ff"),
        step5: Color(hex: "#e1d9ff"),
        step6: Color(hex: "#d4cafe"),
        step7: Color(hex: "#c2b5f5"),
        step8: Color(hex: "#aa99ec"),
        step9: Color(hex: "#6e56cf"),
        step10: Color(hex: "#654dc4"),
        step11: Color(hex: "#6550b9"),
        step12: Color(hex: "#2f265f")
    )

    /// Violet dark scale
    static let violetDark = RadixScale(
        step1: Color(hex: "#14121f"),
        step2: Color(hex: "#1b1525"),
        step3: Color(hex: "#291f43"),
        step4: Color(hex: "#33255b"),
        step5: Color(hex: "#3c2e69"),
        step6: Color(hex: "#473876"),
        step7: Color(hex: "#56468b"),
        step8: Color(hex: "#6958ad"),
        step9: Color(hex: "#6e56cf"),
        step10: Color(hex: "#7d66d9"),
        step11: Color(hex: "#baa7ff"),
        step12: Color(hex: "#e2ddfe")
    )

    // MARK: - Custom Colors (not in standard Radix)

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
