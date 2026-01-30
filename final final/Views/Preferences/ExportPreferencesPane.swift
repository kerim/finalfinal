//
//  ExportPreferencesPane.swift
//  final final
//
//  Export preferences pane for configuring Pandoc and export options.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExportPreferencesPane: View {
    @State private var settingsManager = ExportSettingsManager.shared
    @State private var pandocStatus: PandocStatus = .notFound
    @State private var isCheckingPandoc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Pandoc Configuration
            GroupBox("Pandoc") {
                VStack(alignment: .leading, spacing: 12) {
                    pandocStatusRow
                    pandocPathRow
                    installInstructionsRow
                }
                .padding(8)
            }

            // Zotero Integration
            GroupBox("Zotero Integration") {
                VStack(alignment: .leading, spacing: 12) {
                    luaScriptRow
                    referenceDocRow
                    zoteroWarningToggle
                }
                .padding(8)
            }

            // Default Export Format
            GroupBox("Defaults") {
                VStack(alignment: .leading, spacing: 12) {
                    defaultFormatPicker
                }
                .padding(8)
            }

            Spacer()
        }
        .padding()
        .task {
            await checkPandocStatus()
        }
    }

    // MARK: - Pandoc Rows

    @ViewBuilder
    private var pandocStatusRow: some View {
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
            .buttonStyle(.borderless)
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
    private var pandocPathRow: some View {
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
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var installInstructionsRow: some View {
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

    // MARK: - Zotero Rows

    @ViewBuilder
    private var luaScriptRow: some View {
        Toggle("Use custom Lua filter", isOn: $settingsManager.useCustomLuaScript)

        if settingsManager.useCustomLuaScript {
            HStack {
                TextField("Path to zotero.lua", text: Binding(
                    get: { settingsManager.customLuaScriptPath ?? "" },
                    set: { settingsManager.customLuaScriptPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    browseForLuaScript()
                }
                .buttonStyle(.borderless)
            }

            if !settingsManager.settings.isCustomLuaScriptValid {
                Text("File not found at specified path")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var referenceDocRow: some View {
        Toggle("Use custom reference document", isOn: $settingsManager.useCustomReferenceDoc)

        if settingsManager.useCustomReferenceDoc {
            HStack {
                TextField("Path to reference.docx", text: Binding(
                    get: { settingsManager.customReferenceDocPath ?? "" },
                    set: { settingsManager.customReferenceDocPath = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Button("Browse...") {
                    browseForReferenceDoc()
                }
                .buttonStyle(.borderless)
            }

            if !settingsManager.settings.isCustomReferenceDocValid {
                Text("File not found at specified path")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var zoteroWarningToggle: some View {
        Toggle("Warn when Zotero is not running", isOn: $settingsManager.showZoteroWarning)
    }

    // MARK: - Default Format

    @ViewBuilder
    private var defaultFormatPicker: some View {
        Picker("Default format", selection: $settingsManager.defaultFormat) {
            ForEach(ExportFormat.allCases) { format in
                Text(format.displayName).tag(format)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Actions

    private func checkPandocStatus() async {
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

    private func browseForLuaScript() {
        let panel = NSOpenPanel()
        panel.title = "Select Lua Filter"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "lua")!]

        if panel.runModal() == .OK, let url = panel.url {
            settingsManager.customLuaScriptPath = url.path
        }
    }

    private func browseForReferenceDoc() {
        let panel = NSOpenPanel()
        panel.title = "Select Reference Document"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "docx")!,
            .init(filenameExtension: "odt")!
        ]

        if panel.runModal() == .OK, let url = panel.url {
            settingsManager.customReferenceDocPath = url.path
        }
    }

    private func copyHomebrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(PandocLocator.homebrewCommand, forType: .string)

        // Show feedback (could use a toast, but for now just print)
        print("[ExportPreferencesPane] Copied to clipboard: \(PandocLocator.homebrewCommand)")
    }
}

#Preview {
    ExportPreferencesPane()
        .frame(width: 500, height: 400)
}
