//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager
    let editorState: EditorViewState

    var body: some View {
        HStack {
            Text(wordCountDisplay)
                .font(.caption)
                .accessibilityIdentifier("status-bar-word-count")
            Spacer()
            Text(editorState.currentSectionName.isEmpty ? "No section" : editorState.currentSectionName)
                .font(.caption)
            Spacer()
            Text(editorState.editorMode.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(themeManager.currentTheme.accentColor.opacity(0.2))
                .cornerRadius(4)
                .accessibilityIdentifier("status-bar-editor-mode")

            if editorState.focusModeEnabled {
                Text("Focus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.accentColor.opacity(0.3))
                    .cornerRadius(4)
                    .accessibilityIdentifier("status-bar-focus")
            }
        }
        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(themeManager.currentTheme.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-bar")
    }

    /// Word count display text: "X/Y words" if goal is set, otherwise "X words"
    /// Uses filteredTotalWordCount for consistency with sidebar (respects excludeBibliography)
    private var wordCountDisplay: String {
        let count = editorState.filteredTotalWordCount
        if let goal = editorState.documentGoal {
            return "\(count)/\(goal) words"
        }
        return "\(count) words"
    }
}

#Preview {
    StatusBar(editorState: EditorViewState())
        .environment(ThemeManager.shared)
}
