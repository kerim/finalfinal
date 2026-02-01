//
//  PreferencesView.swift
//  final final
//
//  Main preferences window container with tab navigation.
//

import SwiftUI
import AppKit

/// Tab identifiers for preferences
enum PreferencesTab: String, CaseIterable, Identifiable {
    case export
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .export: return "Export"
        case .appearance: return "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .export: return "square.and.arrow.up"
        case .appearance: return "paintbrush"
        }
    }
}

/// Main preferences window view
struct PreferencesView: View {
    @State private var selectedTab: PreferencesTab = .export

    var body: some View {
        TabView(selection: $selectedTab) {
            ExportPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.export.title, systemImage: PreferencesTab.export.icon)
                }
                .tag(PreferencesTab.export)

            AppearancePreferencesPane()
                .tabItem {
                    Label(PreferencesTab.appearance.title, systemImage: PreferencesTab.appearance.icon)
                }
                .tag(PreferencesTab.appearance)
        }
        .frame(width: 500, height: 550)
        .padding()
    }
}

/// Appearance preferences pane with theme and typography settings
struct AppearancePreferencesPane: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var appearanceManager = AppearanceSettingsManager.shared

    // Local state for editing
    @State private var fontSize: CGFloat = AppearanceSettingsManager.defaultFontSize
    @State private var selectedLineHeight: LineHeightPreset = .oneAndHalf
    @State private var selectedFontFamily: String = ""
    @State private var textColor: Color = .primary
    @State private var headerColor: Color = .primary
    @State private var accentColor: Color = .blue
    @State private var selectedColumnWidth: ColumnWidthPreset = .normal

    // Preset management
    @State private var showingSavePresetSheet = false
    @State private var newPresetName = ""
    @State private var selectedPresetId: UUID?

    // Available fonts
    private let availableFonts: [String]

    init() {
        let fonts = NSFontManager.shared.availableFontFamilies.sorted()
        self.availableFonts = fonts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                themeSection
                typographySection
                colorsSection
                layoutSection
                presetsSection
                resetSection
            }
            .padding()
        }
        .onAppear {
            loadCurrentSettings()
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
                        // When changing themes, clear all appearance overrides
                        themeManager.setThemeAndClearOverrides(byId: newId)
                        loadCurrentSettings()
                    }
                )) {
                    ForEach(AppColorScheme.all) { scheme in
                        Text(scheme.name).tag(scheme.id)
                    }
                }
                .pickerStyle(.menu)

                Text("Changing theme clears all appearance overrides.")
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
                    }
                ) {
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
                }

                // Line Height
                settingRow(
                    label: "Line Height",
                    isOverridden: appearanceManager.isLineHeightOverridden(),
                    onReset: {
                        appearanceManager.clearLineHeight()
                        selectedLineHeight = .oneAndHalf
                    }
                ) {
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
                }

                // Font Family
                settingRow(
                    label: "Font",
                    isOverridden: appearanceManager.isFontFamilyOverridden(),
                    onReset: {
                        appearanceManager.clearFontFamily()
                        selectedFontFamily = ""
                    }
                ) {
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
                }
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
                    }
                ) {
                    ColorPicker("", selection: $textColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: textColor) { _, newValue in
                            updateTextColor(newValue)
                        }
                }

                // Header Color
                settingRow(
                    label: "Header Color",
                    isOverridden: appearanceManager.isHeaderColorOverridden(),
                    onReset: {
                        appearanceManager.clearHeaderColor()
                        headerColor = appearanceManager.effectiveTextColor(theme: themeManager.currentTheme)
                    }
                ) {
                    ColorPicker("", selection: $headerColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: headerColor) { _, newValue in
                            updateHeaderColor(newValue)
                        }
                }

                // Accent Color
                settingRow(
                    label: "Accent Color",
                    isOverridden: appearanceManager.isAccentColorOverridden(),
                    onReset: {
                        appearanceManager.clearAccentColor()
                        accentColor = themeManager.currentTheme.accentColor
                    }
                ) {
                    ColorPicker("", selection: $accentColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: accentColor) { _, newValue in
                            updateAccentColor(newValue)
                        }
                }
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
                    }
                ) {
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
                }
            }
            .padding(8)
        }
    }

    // MARK: - Presets Section

    @ViewBuilder
    private var presetsSection: some View {
        GroupBox("Presets") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Saved Preset", selection: $selectedPresetId) {
                        Text("Select a preset...").tag(nil as UUID?)
                        if !appearanceManager.savedPresets.isEmpty {
                            Divider()
                            ForEach(appearanceManager.savedPresets) { preset in
                                Text(preset.name).tag(preset.id as UUID?)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .onChange(of: selectedPresetId) { _, newValue in
                        if let presetId = newValue,
                           let preset = appearanceManager.savedPresets.first(where: { $0.id == presetId }) {
                            restorePreset(preset)
                        }
                    }

                    if let presetId = selectedPresetId,
                       let preset = appearanceManager.savedPresets.first(where: { $0.id == presetId }) {
                        Button(role: .destructive) {
                            appearanceManager.deletePreset(preset)
                            selectedPresetId = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete preset")
                    }
                }

                Button("Save Current as Preset...") {
                    showingSavePresetSheet = true
                }
                .disabled(!appearanceManager.settings.hasOverrides)
            }
            .padding(8)
        }
        .sheet(isPresented: $showingSavePresetSheet) {
            savePresetSheet
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

    // MARK: - Reset Section

    @ViewBuilder
    private var resetSection: some View {
        HStack {
            Spacer()
            Button("Reset All to Theme Defaults") {
                appearanceManager.resetToDefaults()
                loadCurrentSettings()
            }
            .disabled(!appearanceManager.settings.hasOverrides)
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
                .buttonStyle(.borderless)
                .help("Reset to theme default")
            } else {
                // Invisible placeholder to maintain alignment
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .opacity(0)
            }
        }
    }

    // MARK: - Actions

    private func loadCurrentSettings() {
        let settings = appearanceManager.settings

        fontSize = settings.fontSize ?? AppearanceSettingsManager.defaultFontSize

        // Map line height value back to preset
        if let lineHeightPreset = settings.lineHeight {
            selectedLineHeight = lineHeightPreset
        } else {
            // Default is 1.75 which doesn't map to a preset, use oneAndHalf as closest
            selectedLineHeight = .oneAndHalf
        }

        selectedFontFamily = settings.fontFamily ?? ""

        textColor = settings.textColor?.color ?? themeManager.currentTheme.editorText
        headerColor = settings.headerColor?.color ?? textColor
        accentColor = settings.accentColor?.color ?? themeManager.currentTheme.accentColor

        selectedColumnWidth = settings.columnWidth ?? .normal

        selectedPresetId = nil
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
        loadCurrentSettings()
    }

    private func saveCurrentPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        appearanceManager.savePreset(name: name, themeId: themeManager.currentTheme.id)
        showingSavePresetSheet = false
        newPresetName = ""
    }
}

#Preview {
    PreferencesView()
        .environment(ThemeManager.shared)
}
