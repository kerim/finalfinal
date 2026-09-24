//
//  ExportPreferencesPane+Pandoc.swift
//  final final
//
//  Pandoc status/path rows and their actions for ExportPreferencesPane, split out of
//  ExportPreferencesPane.swift to keep that struct's body under SwiftLint's
//  type_body_length limit. Mechanical move only -- no behavior change.
//

import SwiftUI
import AppKit

extension ExportPreferencesPane {
    // MARK: - Pandoc Rows

    @ViewBuilder
    var pandocStatusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            if isCheckingPandoc {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                pandocStatusBadge
            }
            Button("Refresh") {
                Task {
                    await checkPandocStatus()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isCheckingPandoc)
        }
    }

    @ViewBuilder
    private var pandocStatusBadge: some View {
        switch pandocStatus {
        case .found(_, let version):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("v\(version)")
                    .foregroundStyle(.secondary)
            }
        case .notFound:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Not installed")
                    .foregroundStyle(.secondary)
            }
        case .invalidPath(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .executionFailed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    var pandocPathRow: some View {
        HStack {
            Text("Custom Path")
            Spacer()
            TextField("Auto-detect", text: Binding(
                get: { settingsManager.customPandocPath ?? "" },
                set: { settingsManager.customPandocPath = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)

            Button("Browse...") {
                browseForPandoc()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    var installInstructionsRow: some View {
        if case .notFound = pandocStatus {
            VStack(alignment: .leading, spacing: 8) {
                Text("Install Pandoc to enable export:")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Button("Install via Homebrew") {
                        copyHomebrewCommand()
                    }
                    .buttonStyle(.bordered)

                    Button("Download Installer") {
                        NSWorkspace.shared.open(PandocLocator.downloadURL)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }

    }

    // MARK: - Pandoc Actions

    /// Not private: `body` in ExportPreferencesPane.swift calls this from `.task`, and
    /// Swift's `private` is file-scoped.
    func checkPandocStatus() async {
        isCheckingPandoc = true
        defer { isCheckingPandoc = false }

        let pandocLocator = PandocLocator()
        if let customPath = settingsManager.customPandocPath {
            await pandocLocator.setCustomPath(customPath)
        }
        pandocStatus = await pandocLocator.locate()
    }

    private func browseForPandoc() {
        let panel = NSOpenPanel()
        panel.title = "Select Pandoc Executable"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            settingsManager.customPandocPath = url.path
            Task {
                await checkPandocStatus()
            }
        }
    }

    private func copyHomebrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(PandocLocator.homebrewCommand, forType: .string)

        // Show feedback (could use a toast, but for now just print)
        DebugLog.log(.fileOps, "[ExportPreferencesPane] Copied to clipboard: \(PandocLocator.homebrewCommand)")
    }
}
