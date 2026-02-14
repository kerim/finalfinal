//
//  PreferencesView+Actions.swift
//  final final
//

import SwiftUI

// MARK: - Actions

extension AppearancePreferencesPane {

    func loadCurrentSettings(preserveSelection: Bool = false) {
        let settings = appearanceManager.settings

        fontSize = settings.fontSize ?? AppearanceSettingsManager.defaultFontSize

        // Map line height value back to preset
        selectedLineHeight = settings.lineHeight ?? .normal

        selectedFontFamily = settings.fontFamily ?? ""

        textColor = settings.textColor?.color ?? themeManager.currentTheme.editorText
        headerColor = settings.headerColor?.color ?? textColor
        accentColor = settings.accentColor?.color ?? themeManager.currentTheme.accentColor

        selectedColumnWidth = settings.columnWidth ?? .normal

        if !preserveSelection {
            selectedPresetId = nil
        }
    }

    func updateFontSize(_ value: CGFloat) {
        var updated = appearanceManager.settings
        updated.fontSize = value
        appearanceManager.update(updated)
    }

    func updateLineHeight(_ preset: LineHeightPreset) {
        var updated = appearanceManager.settings
        updated.lineHeight = preset
        appearanceManager.update(updated)
    }

    func updateFontFamily(_ family: String) {
        var updated = appearanceManager.settings
        updated.fontFamily = family.isEmpty ? nil : family
        appearanceManager.update(updated)
    }

    func updateTextColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.textColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    func updateHeaderColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.headerColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    func updateAccentColor(_ color: Color) {
        var updated = appearanceManager.settings
        updated.accentColor = CodableColor(color: color)
        appearanceManager.update(updated)
    }

    func updateColumnWidth(_ preset: ColumnWidthPreset) {
        var updated = appearanceManager.settings
        updated.columnWidth = preset
        appearanceManager.update(updated)
    }

    func restorePreset(_ preset: AppearancePreset) {
        let themeId = appearanceManager.restorePreset(preset)
        themeManager.setTheme(byId: themeId)
        loadCurrentSettings(preserveSelection: true)
    }

    func saveCurrentPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        appearanceManager.savePreset(name: name, themeId: themeManager.currentTheme.id)
        showingSavePresetSheet = false
        newPresetName = ""
    }
}
