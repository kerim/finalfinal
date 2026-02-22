//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager
    let editorState: EditorViewState
    @AppStorage("isSpellingEnabled") private var spellingEnabled = true
    @AppStorage("isGrammarEnabled") private var grammarEnabled = true
    @State private var showProofingPopover = false
    @State private var showOutlinePopover = false

    var body: some View {
        HStack {
            Text(wordCountDisplay)
                .font(.caption)
                .accessibilityIdentifier("status-bar-word-count")
            Spacer()
            Text(editorState.currentSectionName.isEmpty ? "No section" : editorState.currentSectionName)
                .font(.caption)
            Spacer()

            // Document outline popover
            Button {
                showOutlinePopover.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Document outline")
            .popover(isPresented: $showOutlinePopover) {
                outlinePopover
            }
            .accessibilityIdentifier("status-bar-outline")

            // Proofing status indicator (only when LanguageTool is active)
            if ProofingSettings.shared.mode.isLanguageTool {
                proofingIndicator
                    .popover(isPresented: $showProofingPopover) {
                        proofingStatusPopover
                    }
            }

            // Spelling toggle
            Button {
                spellingEnabled.toggle()
                NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil)
            } label: {
                Text("Spelling")
                    .font(.caption)
                    .strikethrough(!spellingEnabled)
            }
            .buttonStyle(.plain)
            .foregroundColor(spellingEnabled
                ? themeManager.currentTheme.accentColor
                : themeManager.currentTheme.sidebarText.opacity(0.4))
            .help(spellingEnabled ? "Spelling: on (⌘;)" : "Spelling: off (⌘;)")
            .accessibilityIdentifier("status-bar-spelling")

            // Grammar toggle
            Button {
                grammarEnabled.toggle()
                NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil)
            } label: {
                Text("Grammar")
                    .font(.caption)
                    .strikethrough(!grammarEnabled)
            }
            .buttonStyle(.plain)
            .foregroundColor(grammarEnabled
                ? themeManager.currentTheme.accentColor
                : themeManager.currentTheme.sidebarText.opacity(0.4))
            .help(grammarEnabled ? "Grammar: on (⌘⇧;)" : "Grammar: off (⌘⇧;)")
            .accessibilityIdentifier("status-bar-grammar")

            // Clickable editor mode badge
            Button {
                NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
            } label: {
                Text(editorState.editorMode.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Toggle editor mode (⌘/)")
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

    // MARK: - Outline Popover

    private var outlinePopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if editorState.sections.isEmpty {
                    Text("No headings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(editorState.sections) { section in
                        Button {
                            showOutlinePopover = false
                            NotificationCenter.default.post(
                                name: .scrollToSection,
                                object: nil,
                                userInfo: ["sectionId": section.id]
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(for: section))
                                    .frame(width: 6, height: 6)
                                Text(section.title.isEmpty ? "Untitled" : section.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                            }
                            .padding(.leading, CGFloat((section.headerLevel - 1) * 16))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(
                                section.title == editorState.currentSectionName
                                    ? themeManager.currentTheme.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(4)
        }
        .frame(minWidth: 200, maxWidth: 300, maxHeight: 400)
    }

    private func statusColor(for section: SectionViewModel) -> Color {
        switch section.status {
        case .next:
            return .gray.opacity(0.3)
        case .writing:
            return .yellow
        case .waiting:
            return .orange
        case .review:
            return .blue
        case .final_:
            return .green
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
