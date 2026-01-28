//
//  HashBar.swift
//  final final
//

import SwiftUI

/// Displays hierarchy indicator as ###□□□ pattern
/// - Filled # marks for header level (1-6)
/// - Empty □ marks for remaining slots
/// - For H7+ (deep headers), shows ######+N suffix
struct HashBar: View {
    let level: Int  // 1-6+ for headers (pseudo-sections inherit level, H7+ are deep headers)
    let isPseudoSection: Bool  // True for break markers
    @Environment(ThemeManager.self) private var themeManager

    /// Number of levels beyond H6 (0 for H1-H6)
    private var overflowCount: Int {
        max(0, level - 6)
    }

    var body: some View {
        HStack(spacing: 2) {
            // Standard H1-H6 indicators
            ForEach(1...6, id: \.self) { position in
                Text("#")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(colorFor(position: position))
            }

            // Deep header suffix for H7+
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.accentColor)
            }

            Spacer()
        }
    }

    private func colorFor(position: Int) -> Color {
        // For deep headers (H7+), all 6 positions are filled
        let effectiveLevel = min(level, 6)
        if position <= effectiveLevel {
            return themeManager.currentTheme.accentColor
        }
        return themeManager.currentTheme.sidebarText.opacity(0.3)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        HashBar(level: 1, isPseudoSection: false)
        HashBar(level: 2, isPseudoSection: false)
        HashBar(level: 3, isPseudoSection: false)
        HashBar(level: 4, isPseudoSection: false)
        HashBar(level: 5, isPseudoSection: false)
        HashBar(level: 6, isPseudoSection: false)
        HashBar(level: 7, isPseudoSection: false)  // Deep header H7 (######+1)
        HashBar(level: 8, isPseudoSection: false)  // Deep header H8 (######+2)
        HashBar(level: 2, isPseudoSection: true)   // Pseudo-section at H2 level
    }
    .padding()
    .environment(ThemeManager.shared)
}
