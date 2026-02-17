//
//  Typography.swift
//  final final
//
//  Unified typography system for accessible, consistent text across SwiftUI and web editors.
//

import SwiftUI

// MARK: - Type Scale

/// Centralized type scale constants
/// Minimum size of 11px ensures WCAG accessibility compliance
enum TypeScale {
    // Heading sizes (matches CSS custom properties)
    static let h1: CGFloat = 28
    static let h2: CGFloat = 24
    static let h3: CGFloat = 20
    static let h4: CGFloat = 17
    static let h5: CGFloat = 15
    static let h6: CGFloat = 14

    // Body and UI sizes
    static let body: CGFloat = 14
    static let caption: CGFloat = 12

    // Minimum accessible size (WCAG 2.1 floor)
    static let minimum: CGFloat = 11

    // Small UI elements (tags, badges, indicators)
    static let smallUI: CGFloat = 11

    /// Returns the size for a given header level (1-6)
    static func heading(_ level: Int) -> CGFloat {
        switch level {
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        default: return h6
        }
    }
}

// MARK: - Line Height

/// Line height multipliers for different contexts
enum LineHeight {
    /// Compact line height for headings
    static let heading: CGFloat = 1.2

    /// Standard line height for body text
    static let body: CGFloat = 1.5

    /// Relaxed line height for long-form reading
    static let relaxed: CGFloat = 1.75
}

// MARK: - Font Extensions

extension Font {
    /// Standard UI body font with minimum size enforcement
    static var uiBody: Font {
        .system(size: max(TypeScale.body, TypeScale.minimum))
    }

    /// Caption font for secondary information
    static var uiCaption: Font {
        .system(size: max(TypeScale.caption, TypeScale.minimum))
    }

    /// Small UI font for tags, badges, and indicators
    static var uiSmall: Font {
        .system(size: TypeScale.smallUI, weight: .medium)
    }

    /// Monospace font with minimum size enforcement
    /// - Parameter size: Desired font size (will be clamped to minimum)
    static func uiMono(size: CGFloat = TypeScale.caption) -> Font {
        .system(size: max(size, TypeScale.minimum), design: .monospaced)
    }

    /// Monospace font with weight for UI elements like word counts
    static func uiMono(size: CGFloat = TypeScale.caption, weight: Font.Weight = .regular) -> Font {
        .system(size: max(size, TypeScale.minimum), weight: weight, design: .monospaced)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Group {
            Text("H1 - 28px")
                .font(.system(size: TypeScale.h1, weight: .light))
            Text("H2 - 24px")
                .font(.system(size: TypeScale.h2, weight: .regular))
            Text("H3 - 20px")
                .font(.system(size: TypeScale.h3, weight: .regular))
            Text("H4 - 17px")
                .font(.system(size: TypeScale.h4, weight: .medium))
            Text("H5 - 15px")
                .font(.system(size: TypeScale.h5, weight: .semibold))
            Text("H6 - 14px")
                .font(.system(size: TypeScale.h6, weight: .bold))
        }

        Divider()

        Group {
            Text("Body - 14px")
                .font(.uiBody)
            Text("Caption - 12px")
                .font(.uiCaption)
            Text("Small UI - 11px")
                .font(.uiSmall)
            Text("Mono - 12px")
                .font(.uiMono())
        }
    }
    .padding()
}
