//
//  AppearancePreferencesPane.swift
//  final final
//
//  Appearance preferences pane with theme and typography settings.
//

import SwiftUI
import AppKit

/// Appearance preferences pane with theme and typography settings
struct AppearancePreferencesPane: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var appearanceManager = AppearanceSettingsManager.shared

    // Local state for editing
    @State private var fontSize: CGFloat = AppearanceSettingsManager.defaultFontSize
    @State private var selectedLineHeight: LineHeightPreset = .normal
    @State private var selectedFontFamily: String = ""
    @State private var textColor: Color = .primary
    @State private var headerColor: Color = .primary
    @State private var accentColor: Color = .blue
    @State private var selectedColumnWidth: ColumnWidthPreset = .normal

    // Preset management
    @State private var showingSavePresetSheet = false
    @State private var newPresetName = ""
    @State private var selectedPresetId: UUID?

    // Destructive-confirmation state (see DestructiveConfirmation.swift).
    @State private var showingResetConfirmation = false
    @State private var presetPendingDeletion: AppearancePreset?

    // Available fonts
    private let availableFonts: [String]

    init() {
        let fonts = NSFontManager.shared.availableFontFamilies.sorted()
        self.availableFonts = fonts
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left column: Presets
            VStack(alignment: .leading, spacing: 16) {
                presetsColumn
            }
            .frame(width: 200)
            .padding()

            Divider()

            // Right column: Settings
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    themeSection
                    typographySection
                    colorsSection
                    layoutSection
                }
                .padding()
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .sheet(isPresented: $showingSavePresetSheet) {
            savePresetSheet
        }
    }

    // MARK: - Theme Section

    @ViewBuilder
    private var themeSection: some View {
        GroupBox("Theme") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Theme", selection: Binding(
                    get: { themeManager.currentTheme.id },
                    set: { newId in
                        // Preserve appearance overrides when changing theme via Settings
                        themeManager.setTheme(byId: newId)
                        loadCurrentSettings()
                    }
                )) {
                    ForEach(AppColorScheme.all) { scheme in
                        Text(scheme.name).tag(scheme.id)
                    }
                }
                .pickerStyle(.menu)

                Text("Appearance overrides are preserved. Use View → Theme menu to reset to defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Typography Section

    @ViewBuilder
    private var typographySection: some View {
        GroupBox("Typography") {
            VStack(alignment: .leading, spacing: 12) {
                // Font Size
                settingRow(
                    label: "Font Size",
                    isOverridden: appearanceManager.isFontSizeOverridden(),
                    onReset: {
                        appearanceManager.clearFontSize()
                        fontSize = AppearanceSettingsManager.defaultFontSize
                    },
                    content: {
                    HStack {
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                        Stepper("", value: $fontSize, in: 12...32, step: 1)
                            .labelsHidden()
                            .onChange(of: fontSize) { _, newValue in
                                updateFontSize(newValue)
                            }
                    }
                })

                // Line Height
                settingRow(
                    label: "Line Height",
                    isOverridden: appearanceManager.isLineHeightOverridden(),
                    onReset: {
                        appearanceManager.clearLineHeight()
                        selectedLineHeight = .normal
                    },
                    content: {
                    Picker("", selection: $selectedLineHeight) {
                        ForEach(LineHeightPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .labelsHidden()
                    .onChange(of: selectedLineHeight) { _, newValue in
                        updateLineHeight(newValue)
                    }
                })

                // Font Family
                settingRow(
                    label: "Font",
                    isOverridden: appearanceManager.isFontFamilyOverridden(),
                    onReset: {
                        appearanceManager.clearFontFamily()
                        selectedFontFamily = ""
                    },
                    content: {
                    Picker("", selection: $selectedFontFamily) {
                        Text("System Font").tag("")
                        Divider()
                        ForEach(availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .labelsHidden()
                    .onChange(of: selectedFontFamily) { _, newValue in
                        updateFontFamily(newValue)
                    }
                })
            }
            .padding(8)
        }
    }

    // MARK: - Colors Section

    @ViewBuilder
    private var colorsSection: some View {
        GroupBox("Colors") {
            VStack(alignment: .leading, spacing: 12) {
                // Text Color
                settingRow(
                    label: "Text Color",
                    isOverridden: appearanceManager.isTextColorOverridden(),
                    onReset: {
                        appearanceManager.clearTextColor()
                        textColor = themeManager.currentTheme.editorText
                    },
                    content: {
                    ColorPicker("", selection: $textColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: textColor) { _, newValue in
                            updateTextColor(newValue)
                        }
                })

                // Header Color
                settingRow(
                    label: "Heading Color",
                    isOverridden: appearanceManager.isHeaderColorOverridden(),
                    onReset: {
                        appearanceManager.clearHeaderColor()
                        headerColor = themeManager.currentTheme.editorHeaderText
                    },
                    content: {
                    ColorPicker("", selection: $headerColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: headerColor) { _, newValue in
                            updateHeaderColor(newValue)
                        }
                })

                // Accent Color
                settingRow(
                    label: "Accent Color",
                    isOverridden: appearanceManager.isAccentColorOverridden(),
                    onReset: {
                        appearanceManager.clearAccentColor()
                        accentColor = themeManager.currentTheme.accentColor
                    },
                    content: {
                    ColorPicker("", selection: $accentColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: accentColor) { _, newValue in
                            updateAccentColor(newValue)
                        }
                })
            }
            .padding(8)
        }
    }

    // MARK: - Layout Section

    @ViewBuilder
    private var layoutSection: some View {
        GroupBox("Layout") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    label: "Column Width",
                    isOverridden: appearanceManager.isColumnWidthOverridden(),
                    onReset: {
                        appearanceManager.clearColumnWidth()
                        selectedColumnWidth = .normal
                    },
                    content: {
                    Picker("", selection: $selectedColumnWidth) {
                        ForEach(ColumnWidthPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .labelsHidden()
                    .onChange(of: selectedColumnWidth) { _, newValue in
                        updateColumnWidth(newValue)
                    }
                })
            }
            .padding(8)
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func settingRow<Content: View>(
        label: String,
        isOverridden: Bool,
        onReset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            Spacer()
            content()
            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Reset to theme default")
            } else {
                // Invisible placeholder to maintain alignment
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .opacity(0)
            }
        }
    }

}

// MARK: - Actions

extension AppearancePreferencesPane {

    private func loadCurrentSettings(preserveSelection: Bool = false) {
        let settings = appearanceManager.settings

        fontSize = settings.fontSize ?? AppearanceSettingsManager.defaultFontSize

        // Map line height value back to preset
        selectedLineHeight = settings.lineHeight ?? .normal

        selectedFontFamily = settings.fontFamily ?? ""

        textColor = settings.textColor?.color ?? themeManager.currentTheme.editorText
        headerColor = settings.headerColor?.color ?? themeManager.currentTheme.editorHeaderText
        accentColor = settings.accentColor?.color ?? themeManager.currentTheme.accentColor

        selectedColumnWidth = settings.columnWidth ?? .normal

        if !preserveSelection {
            selectedPresetId = nil
        }
    }

    private func updateFontSize(_ value: CGFloat) {
        var updated = appearanceManager.settings
        updated.fontSize = value
        appearanceManager.update(updated)
    }

    private func updateLineHeight(_ preset: LineHeightPreset) {
        var updated = appearanceManager.settings
        updated.lineHeight = preset
        appearanceManager.update(updated)
    }

    private func updateFontFamily(_ family: String) {
        var updated = appearanceManager.settings
        updated.fontFamily = family.isEmpty ? nil : family
        appearanceManager.update(updated)
    }

    private func updateTextColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.textColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    private func updateHeaderColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.headerColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    private func updateAccentColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.accentColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    private func updateColumnWidth(_ preset: ColumnWidthPreset) {
        var updated = appearanceManager.settings
        updated.columnWidth = preset
        appearanceManager.update(updated)
    }

    private func restorePreset(_ preset: AppearancePreset) {
        let themeId = appearanceManager.restorePreset(preset)
        themeManager.setTheme(byId: themeId)
        loadCurrentSettings(preserveSelection: true)
    }

    private func saveCurrentPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        appearanceManager.savePreset(name: name, themeId: themeManager.currentTheme.id)
        showingSavePresetSheet = false
        newPresetName = ""
    }
}

// MARK: - Presets Column

extension AppearancePreferencesPane {

    @ViewBuilder
    private var presetsColumn: some View {
        Text("Saved Presets")
            .font(.headline)

        if appearanceManager.savedPresets.isEmpty {
            Text("No saved presets")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else {
            List(selection: $selectedPresetId) {
                ForEach(appearanceManager.savedPresets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button {
                            presetPendingDeletion = preset
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .destructiveConfirmation(
                            .deletePreset(named: preset.name),
                            isPresented: Binding(
                                get: { presetPendingDeletion?.id == preset.id },
                                set: { isPresented in
                                    if !isPresented { presetPendingDeletion = nil }
                                }
                            )
                        ) {
                            // Review round fix: clear the state driving `isPresented` FIRST.
                            // `appearanceManager.deletePreset(preset)` removes the row from the
                            // ForEach that hosts this Button/`.destructiveConfirmation` pair --
                            // doing that before `presetPendingDeletion = nil` tore down the view
                            // hosting the in-flight dialog presentation mid-presentation.
                            presetPendingDeletion = nil
                            if selectedPresetId == preset.id {
                                selectedPresetId = nil
                            }
                            appearanceManager.deletePreset(preset)
                        }
                    }
                    .tag(preset.id as UUID?)
                }
            }
            .listStyle(.inset)
            .frame(height: 200)
            .onChange(of: selectedPresetId) { _, newValue in
                if let presetId = newValue,
                   let preset = appearanceManager.savedPresets.first(where: { $0.id == presetId }) {
                    restorePreset(preset)
                }
            }
        }

        Spacer()

        if let presetId = selectedPresetId,
           let preset = appearanceManager.savedPresets.first(where: { $0.id == presetId }) {
            Button("Update \"\(preset.name)\"") {
                appearanceManager.updatePreset(preset, themeId: themeManager.currentTheme.id)
            }
            .disabled(!appearanceManager.settings.hasOverrides)
        }

        Button("Save as New Preset...") {
            showingSavePresetSheet = true
        }
        .disabled(!appearanceManager.settings.hasOverrides)

        Divider()

        Button("Reset Appearance Settings") {
            showingResetConfirmation = true
        }
        .disabled(!appearanceManager.settings.hasOverrides)
        .destructiveConfirmation(.resetPane(.appearance), isPresented: $showingResetConfirmation) {
            appearanceManager.resetToDefaults()
            loadCurrentSettings()
        }
    }

    @ViewBuilder
    private var savePresetSheet: some View {
        VStack(spacing: 16) {
            Text("Save Preset")
                .font(.headline)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingSavePresetSheet = false
                    newPresetName = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveCurrentPreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}
