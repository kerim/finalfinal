//
//  PreferencesView+Presets.swift
//  final final
//

import SwiftUI

// MARK: - Presets Column

extension AppearancePreferencesPane {

    @ViewBuilder
    var presetsColumn: some View {
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
                            appearanceManager.deletePreset(preset)
                            if selectedPresetId == preset.id {
                                selectedPresetId = nil
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
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

        Button("Reset All to Theme Defaults") {
            appearanceManager.resetToDefaults()
            loadCurrentSettings()
        }
        .disabled(!appearanceManager.settings.hasOverrides)
    }

    @ViewBuilder
    var savePresetSheet: some View {
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
