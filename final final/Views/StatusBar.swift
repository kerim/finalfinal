//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager
    let editorState: EditorViewState
    @State private var showProofingPopover = false

    var body: some View {
        HStack {
            Text(wordCountDisplay)
                .font(.caption)
                .accessibilityIdentifier("status-bar-word-count")
            Spacer()
            Text(editorState.currentSectionName.isEmpty ? "No section" : editorState.currentSectionName)
                .font(.caption)
            Spacer()

            // Proofing status indicator (only when LanguageTool is active)
            if ProofingSettings.shared.mode.isLanguageTool {
                proofingIndicator
                    .popover(isPresented: $showProofingPopover) {
                        proofingStatusPopover
                    }
            }

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
        .onReceive(NotificationCenter.default.publisher(for: .proofingConnectionStatusChanged)) { _ in
            editorState.proofingConnectionStatus = SpellCheckService.shared.connectionStatus
        }
        .onReceive(NotificationCenter.default.publisher(for: .proofingModeChanged)) { _ in
            editorState.proofingConnectionStatus = SpellCheckService.shared.connectionStatus
        }
    }

    // MARK: - Proofing Indicator

    private var proofingIndicator: some View {
        Button {
            showProofingPopover.toggle()
        } label: {
            Circle()
                .fill(proofingStatusColor)
                .frame(width: 8, height: 8)
        }
        .buttonStyle(.plain)
        .help(proofingStatusText)
        .accessibilityIdentifier("status-bar-proofing")
    }

    private var proofingStatusColor: Color {
        switch editorState.proofingConnectionStatus {
        case .connected: .green
        case .checking: .yellow
        case .disconnected, .authError, .rateLimited: .red
        }
    }

    private var proofingStatusText: String {
        switch editorState.proofingConnectionStatus {
        case .connected: "LanguageTool connected"
        case .checking: "Checking..."
        case .disconnected: "LanguageTool disconnected"
        case .authError: "Invalid API key"
        case .rateLimited: "Rate limited"
        }
    }

    private var proofingStatusPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(proofingStatusColor)
                    .frame(width: 10, height: 10)
                Text(proofingStatusText)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Text(ProofingSettings.shared.mode.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Proofing Preferences...") {
                showProofingPopover = false
                NotificationCenter.default.post(name: .openProofingPreferences, object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(12)
        .frame(minWidth: 200)
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
