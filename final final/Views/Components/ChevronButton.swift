//
//  ChevronButton.swift
//  final final
//

import SwiftUI

/// Chevron button with high-contrast circular background for sidebar collapse/expand
struct ChevronButton: View {
    enum Direction {
        case left, right

        var systemName: String {
            switch self {
            case .left: return "chevron.left"
            case .right: return "chevron.right"
            }
        }
    }

    let direction: Direction
    let action: () -> Void
    let helpText: String

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Button(action: action) {
            // 44x44 tappable area per HIG, with smaller visual element
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .overlay(chevronVisual)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var chevronVisual: some View {
        Image(systemName: direction.systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(themeManager.currentTheme.accentColor)
            )
            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
    }
}

#Preview {
    HStack(spacing: 20) {
        ChevronButton(
            direction: .left,
            action: { print("Left tapped") },
            helpText: "Show sidebar"
        )

        ChevronButton(
            direction: .right,
            action: { print("Right tapped") },
            helpText: "Hide sidebar"
        )
    }
    .padding()
    .environment(ThemeManager.shared)
}
