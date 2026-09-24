//
//  StatusBar+Popovers.swift
//  final final
//
//  The Outline popover and the LanguageTool proofing indicator/popover for StatusBar, split
//  out of StatusBar.swift to keep that struct's body under SwiftLint's type_body_length
//  limit. Mechanical move only -- no behavior change.
//

import SwiftUI

extension StatusBar {
    // MARK: - Outline Popover

    var outlinePopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if editorState.outlineSections.isEmpty {
                    Text("No headings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(editorState.outlineSections) { section in
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
                            .contentShape(Rectangle())
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

    var proofingIndicator: some View {
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

    var proofingStatusPopover: some View {
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
}
