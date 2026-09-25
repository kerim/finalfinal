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
