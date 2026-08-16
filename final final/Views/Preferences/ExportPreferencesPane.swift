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

    /// Local draft of the custom-CSL-style path text field, separate from
    /// `settingsManager.customCSLStylePath`. Typing here does NOT push to `settingsManager`
    /// on every keystroke -- see `commitCSLStylePathDraft()`'s doc comment for why that
    /// matters for this specific field (unlike the plain-persistence sibling fields below).
    @State private var cslStylePathDraft: String = ""
    @FocusState private var isCSLStylePathFieldFocused: Bool

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
                    cslStyleRow
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
        .onAppear {
            cslStylePathDraft = settingsManager.customCSLStylePath ?? ""
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
    private var cslStyleRow: some View {
        Toggle("Use custom citation style (CSL)", isOn: $settingsManager.useCustomCSLStyle)

        if settingsManager.useCustomCSLStyle {
            HStack {
                TextField("Path to style.csl", text: $cslStylePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isCSLStylePathFieldFocused)
                    .onSubmit { commitCSLStylePathDraft() }
                    .onChange(of: isCSLStylePathFieldFocused) { _, isFocused in
                        if !isFocused { commitCSLStylePathDraft() }
                    }

                Button("Browse...") {
                    browseForCSLStyle()
                }
                .buttonStyle(.borderless)
            }

            if let caption = settingsManager.settings.customCSLStyleCaption {
                Text(caption)
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

    private func browseForCSLStyle() {
        let panel = NSOpenPanel()
        panel.title = "Select CSL Citation Style"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "csl")!]

        if panel.runModal() == .OK, let url = panel.url {
            settingsManager.customCSLStylePath = url.path
            // Keep the draft in sync -- Browse commits immediately (a discrete pick, not a
            // keystroke), and the text field is now bound to the draft, not the setting.
            cslStylePathDraft = url.path
        }
    }

    /// Commit the CSL-style-path draft to `settingsManager` (only on Return or losing focus,
    /// never per keystroke -- see the call sites in `cslStyleRow`).
    ///
    /// This field is deliberately NOT wired the way the plain-persistence sibling fields
    /// above (`customLuaScriptPath`, `customReferenceDocPath`) are, where the `TextField`
    /// binds `settingsManager` directly and every keystroke writes straight through: those
    /// fields only persist to `UserDefaults`. This one is different -- `customCSLStylePath`'s
    /// setter (`ExportSettingsManager`) posts `.citationStyleChanged`, which every open
    /// editor window's `MilkdownCoordinator` observes by re-reading the file from disk,
    /// re-parsing it as XML (main thread), and rebuilding its citeproc engine
    /// (`pushCitationStyle` -> `setCitationStyle`). Pushed through on every character while
    /// the user is mid-typing a path, that's a full file read + XML parse + citeproc rebuild
    /// per keystroke, per open editor window -- visibly janky. Committing only when the user
    /// finishes (Return or blur) keeps that expensive path to exactly one push per actual
    /// change.
    private func commitCSLStylePathDraft() {
        settingsManager.customCSLStylePath = cslStylePathDraft.isEmpty ? nil : cslStylePathDraft
    }

    private func copyHomebrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(PandocLocator.homebrewCommand, forType: .string)

        // Show feedback (could use a toast, but for now just print)
        DebugLog.log(.fileOps, "[ExportPreferencesPane] Copied to clipboard: \(PandocLocator.homebrewCommand)")
    }
}

#Preview {
    ExportPreferencesPane()
        .frame(width: 500, height: 400)
}
