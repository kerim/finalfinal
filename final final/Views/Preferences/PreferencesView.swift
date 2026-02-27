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
    case focus
    case goals
    case proofing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .export: return "Export"
        case .appearance: return "Appearance"
        case .focus: return "Focus"
        case .goals: return "Goals"
        case .proofing: return "Proofing"
        }
    }

    var icon: String {
        switch self {
        case .export: return "square.and.arrow.up"
        case .appearance: return "paintbrush"
        case .focus: return "eye.slash"
        case .goals: return "target"
        case .proofing: return "textformat.abc"
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

            FocusPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.focus.title, systemImage: PreferencesTab.focus.icon)
                }
                .tag(PreferencesTab.focus)

            GoalPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.goals.title, systemImage: PreferencesTab.goals.icon)
                }
                .tag(PreferencesTab.goals)

            ProofingPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.proofing.title, systemImage: PreferencesTab.proofing.icon)
                }
                .tag(PreferencesTab.proofing)
        }
        .frame(width: 700, height: 550)
        .padding()
    }
}

/// Appearance preferences pane with theme and typography settings
struct AppearancePreferencesPane: View {
    @Environment(ThemeManager.self) var themeManager
    @State var appearanceManager = AppearanceSettingsManager.shared

    // Local state for editing
    @State var fontSize: CGFloat = AppearanceSettingsManager.defaultFontSize
    @State var selectedLineHeight: LineHeightPreset = .normal
    @State var selectedFontFamily: String = ""
    @State var textColor: Color = .primary
    @State var headerColor: Color = .primary
    @State var accentColor: Color = .blue
    @State var selectedColumnWidth: ColumnWidthPreset = .normal

    // Preset management
    @State var showingSavePresetSheet = false
    @State var newPresetName = ""
    @State var selectedPresetId: UUID?

    // Available fonts
    let availableFonts: [String]

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
                    label: "Header Color",
                    isOverridden: appearanceManager.isHeaderColorOverridden(),
                    onReset: {
                        appearanceManager.clearHeaderColor()
                        headerColor = appearanceManager.effectiveTextColor(theme: themeManager.currentTheme)
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

}

#Preview {
    PreferencesView()
        .environment(ThemeManager.shared)
}
