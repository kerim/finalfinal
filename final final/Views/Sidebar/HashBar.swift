//
//  HashBar.swift
//  final final
//

import SwiftUI

/// Displays hierarchy indicator as ###□□□ pattern
/// - Filled # marks for header level
/// - Empty □ marks for remaining slots
struct HashBar: View {
    let level: Int  // 1-6 for headers (pseudo-sections inherit level from preceding)
    let isPseudoSection: Bool  // True for break markers
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...6, id: \.self) { position in
                Text(symbolFor(position: position))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(colorFor(position: position))
            }
            Spacer()
        }
    }

    private func symbolFor(position: Int) -> String {
        return "#"
    }

    private func colorFor(position: Int) -> Color {
        if position <= level {
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
        HashBar(level: 2, isPseudoSection: true)  // Pseudo-section at H2 level
    }
    .padding()
    .environment(ThemeManager.shared)
}
