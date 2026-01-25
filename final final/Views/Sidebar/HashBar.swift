//
//  HashBar.swift
//  final final
//

import SwiftUI

/// Displays hierarchy indicator as ###□□□ pattern
/// - Filled # marks for header level
/// - Empty □ marks for remaining slots
/// - § prefix for pseudo-sections (level 0)
struct HashBar: View {
    let level: Int  // 1-6 for headers, 0 for pseudo-sections
    @Environment(ThemeManager.self) private var themeManager

    private var effectiveLevel: Int {
        level == 0 ? 1 : level
    }

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
        if position == 1 && level == 0 {
            return "§"
        }
        return "#"
    }

    private func colorFor(position: Int) -> Color {
        if position <= effectiveLevel {
            return themeManager.currentTheme.accentColor
        }
        return themeManager.currentTheme.sidebarText.opacity(0.3)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        HashBar(level: 1)
        HashBar(level: 2)
        HashBar(level: 3)
        HashBar(level: 4)
        HashBar(level: 5)
        HashBar(level: 6)
        HashBar(level: 0)  // Pseudo-section
    }
    .padding()
    .environment(ThemeManager.shared)
}
