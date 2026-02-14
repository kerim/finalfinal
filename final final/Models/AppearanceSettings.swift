//
//  AppearanceSettings.swift
//  final final
//
//  Appearance settings that override theme defaults.
//  These persist separately from themes and are cleared when switching themes.
//

import SwiftUI
import AppKit

// MARK: - Column Width Preset

/// Column width preset options
enum ColumnWidthPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case extraWide = "extra-wide"
    case wide = "wide"
    case normal = "normal"
    case narrow = "narrow"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extraWide: return "Extra Wide"
        case .wide: return "Wide"
        case .normal: return "Normal"
        case .narrow: return "Narrow"
        }
    }

    /// Maximum width in pixels
    var maxWidth: Int {
        switch self {
        case .extraWide: return 900
        case .wide: return 750
        case .normal: return 650
        case .narrow: return 520
        }
    }

    /// Minimum width (same for all presets)
    static let minWidth = 400
}

// MARK: - Line Height Preset

/// Line height preset options
enum LineHeightPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case single
    case tight
    case normal
    case relaxed
    case loose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "1.15 (Single)"
        case .tight: return "1.4 (Tight)"
        case .normal: return "1.75 (Default)"
        case .relaxed: return "2.0 (Relaxed)"
        case .loose: return "2.25 (Loose)"
        }
    }

    /// CSS line-height value
    var value: Double {
        switch self {
        case .single: return 1.15
        case .tight: return 1.4
        case .normal: return 1.75
        case .relaxed: return 2.0
        case .loose: return 2.25
        }
    }

    /// The default preset that matches the CSS default
    static let `default`: LineHeightPreset = .normal
}

// MARK: - Codable Color

/// A Codable wrapper for Color that uses sRGB components
struct CodableColor: Codable, Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(color: Color) {
        let nsColor = NSColor(color)
        if let rgb = nsColor.usingColorSpace(.sRGB) {
            self.red = Double(rgb.redComponent)
            self.green = Double(rgb.greenComponent)
            self.blue = Double(rgb.blueComponent)
            self.alpha = Double(rgb.alphaComponent)
        } else {
            // Fallback to black
            self.red = 0
            self.green = 0
            self.blue = 0
            self.alpha = 1
        }
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// CSS hex string representation
    var cssHex: String {
        String(format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}

// MARK: - Appearance Settings

/// User appearance overrides that override theme defaults
struct AppearanceSettings: Codable, Sendable, Equatable {
    /// Font size in points (nil = theme default, 18px)
    var fontSize: CGFloat?

    /// Line height preset (nil = theme default, 1.75)
    var lineHeight: LineHeightPreset?

    /// Font family name (nil = theme default, system font)
    var fontFamily: String?

    /// Text color for body text (nil = theme default)
    var textColor: CodableColor?

    /// Header color (nil = same as text color)
    var headerColor: CodableColor?

    /// Accent color for links and selections (nil = theme default)
    var accentColor: CodableColor?

    /// Column width preset (nil = theme default, normal/650px)
    var columnWidth: ColumnWidthPreset?

    /// Default settings (all nil - use theme defaults)
    static let defaults = AppearanceSettings()

    /// Whether any setting is overridden
    var hasOverrides: Bool {
        fontSize != nil ||
        lineHeight != nil ||
        fontFamily != nil ||
        textColor != nil ||
        headerColor != nil ||
        accentColor != nil ||
        columnWidth != nil
    }
}

// MARK: - Appearance Preset

/// A saved preset that bundles a theme with appearance overrides
struct AppearancePreset: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var themeId: String
    var settings: AppearanceSettings
    var createdAt: Date

    init(name: String, themeId: String, settings: AppearanceSettings) {
        self.id = UUID()
        self.name = name
        self.themeId = themeId
        self.settings = settings
        self.createdAt = Date()
    }

    init(id: UUID, name: String, themeId: String, settings: AppearanceSettings) {
        self.id = id
        self.name = name
        self.themeId = themeId
        self.settings = settings
        self.createdAt = Date()
    }
}

// MARK: - Appearance Settings Manager

/// Manages appearance settings persistence and CSS generation
@MainActor
@Observable
final class AppearanceSettingsManager {
    static let shared = AppearanceSettingsManager()

    private(set) var settings: AppearanceSettings = .defaults
    private(set) var savedPresets: [AppearancePreset] = []

    private let settingsKey = "appearanceSettings"
    private let presetsKey = "appearancePresets"
    private var hasLoaded = false

    private init() {}

    /// Call this after database is confirmed ready
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        loadSettings()
        loadPresets()
        hasLoaded = true
    }

    // MARK: - Settings Updates

    /// Update settings and save
    func update(_ newSettings: AppearanceSettings) {
        settings = newSettings
        saveSettings()
        #if DEBUG
        print("[AppearanceSettings] Updated settings, hasOverrides: \(settings.hasOverrides)")
        #endif
    }

    /// Clear all overrides, returning to theme defaults
    func resetToDefaults() {
        settings = .defaults
        saveSettings()
        #if DEBUG
        print("[AppearanceSettings] Reset to defaults")
        #endif
    }

    /// Clear a specific setting
    func clearFontSize() {
        var updated = settings
        updated.fontSize = nil
        update(updated)
    }

    func clearLineHeight() {
        var updated = settings
        updated.lineHeight = nil
        update(updated)
    }

    func clearFontFamily() {
        var updated = settings
        updated.fontFamily = nil
        update(updated)
    }

    func clearTextColor() {
        var updated = settings
        updated.textColor = nil
        update(updated)
    }

    func clearHeaderColor() {
        var updated = settings
        updated.headerColor = nil
        update(updated)
    }

    func clearAccentColor() {
        var updated = settings
        updated.accentColor = nil
        update(updated)
    }

    func clearColumnWidth() {
        var updated = settings
        updated.columnWidth = nil
        update(updated)
    }

    // MARK: - Effective Values (override or theme default)

    /// Default font size when no override is set
    static let defaultFontSize: CGFloat = 18

    /// Default line height when no override is set
    static let defaultLineHeight: Double = 1.75

    /// Default font family when no override is set
    static let defaultFontFamily = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif"

    /// Effective font size (override or default)
    var effectiveFontSize: CGFloat {
        settings.fontSize ?? Self.defaultFontSize
    }

    /// Effective line height (override or default)
    var effectiveLineHeight: Double {
        settings.lineHeight?.value ?? Self.defaultLineHeight
    }

    /// Effective font family (override or default)
    var effectiveFontFamily: String {
        settings.fontFamily ?? Self.defaultFontFamily
    }

    /// Effective text color (override or theme default)
    func effectiveTextColor(theme: AppColorScheme) -> Color {
        settings.textColor?.color ?? theme.editorText
    }

    /// Effective header color (override, or text color override, or theme default)
    func effectiveHeaderColor(theme: AppColorScheme) -> Color {
        if let headerColor = settings.headerColor {
            return headerColor.color
        }
        // Fall back to text color override or theme default
        return settings.textColor?.color ?? theme.editorText
    }

    /// Effective accent color (override or theme default)
    func effectiveAccentColor(theme: AppColorScheme) -> Color {
        settings.accentColor?.color ?? theme.accentColor
    }

    /// Effective column width (override or default)
    var effectiveColumnWidth: ColumnWidthPreset {
        settings.columnWidth ?? .normal
    }

    // MARK: - Override Checks

    func isFontSizeOverridden() -> Bool { settings.fontSize != nil }
    func isLineHeightOverridden() -> Bool { settings.lineHeight != nil }
    func isFontFamilyOverridden() -> Bool { settings.fontFamily != nil }
    func isTextColorOverridden() -> Bool { settings.textColor != nil }
    func isHeaderColorOverridden() -> Bool { settings.headerColor != nil }
    func isAccentColorOverridden() -> Bool { settings.accentColor != nil }
    func isColumnWidthOverridden() -> Bool { settings.columnWidth != nil }

    // MARK: - CSS Generation

    /// CSS variables for overridden settings only (appended after theme CSS)
    var cssOverrides: String {
        var css: [String] = []

        if let fontSize = settings.fontSize {
            css.append("--font-size-body: \(Int(fontSize))px;")
        }

        if let lineHeight = settings.lineHeight {
            css.append("--line-height-body: \(lineHeight.value);")
        }

        if let fontFamily = settings.fontFamily {
            // Wrap in quotes if it contains spaces, otherwise use as-is
            let quotedFamily = fontFamily.contains(" ") ? "'\(fontFamily)'" : fontFamily
            css.append("--font-sans: \(quotedFamily), -apple-system, BlinkMacSystemFont, system-ui, sans-serif;")
        }

        if let textColor = settings.textColor {
            css.append("--editor-text: \(textColor.cssHex);")
        }

        if let headerColor = settings.headerColor {
            css.append("--editor-heading-text: \(headerColor.cssHex);")
            #if DEBUG
            print("[AppearanceSettings] Header color override: \(headerColor.cssHex)")
            #endif
        }

        if let accentColor = settings.accentColor {
            css.append("--accent-color: \(accentColor.cssHex);")
        }

        if let columnWidth = settings.columnWidth {
            css.append("--column-max-width: \(columnWidth.maxWidth)px;")
            css.append("--column-min-width: \(ColumnWidthPreset.minWidth)px;")
        }

        return css.joined(separator: "\n")
    }

    // MARK: - Presets

    /// Save current configuration as a preset
    func savePreset(name: String, themeId: String) {
        let preset = AppearancePreset(name: name, themeId: themeId, settings: settings)
        savedPresets.append(preset)
        savePresets()
        #if DEBUG
        print("[AppearanceSettings] Saved preset: \(name)")
        #endif
    }

    /// Restore a preset (returns the theme ID to switch to)
    func restorePreset(_ preset: AppearancePreset) -> String {
        settings = preset.settings
        saveSettings()
        #if DEBUG
        print("[AppearanceSettings] Restored preset: \(preset.name)")
        #endif
        return preset.themeId
    }

    /// Update an existing preset with current settings
    func updatePreset(_ preset: AppearancePreset, themeId: String) {
        guard let index = savedPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        let updated = AppearancePreset(id: preset.id, name: preset.name, themeId: themeId, settings: settings)
        savedPresets[index] = updated
        savePresets()
        #if DEBUG
        print("[AppearanceSettings] Updated preset: \(preset.name)")
        #endif
    }

    /// Delete a preset
    func deletePreset(_ preset: AppearancePreset) {
        savedPresets.removeAll { $0.id == preset.id }
        savePresets()
        #if DEBUG
        print("[AppearanceSettings] Deleted preset: \(preset.name)")
        #endif
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[AppearanceSettings] Database not available, using defaults")
            #endif
            return
        }

        do {
            if let json = try database.getSetting(key: settingsKey),
               let data = json.data(using: .utf8) {
                settings = try JSONDecoder().decode(AppearanceSettings.self, from: data)
                #if DEBUG
                print("[AppearanceSettings] Loaded settings, hasOverrides: \(settings.hasOverrides)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[AppearanceSettings] Failed to load settings: \(error)")
            #endif
        }
    }

    private func saveSettings() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[AppearanceSettings] Database not available, cannot save")
            #endif
            return
        }

        do {
            let data = try JSONEncoder().encode(settings)
            if let json = String(data: data, encoding: .utf8) {
                try database.setSetting(key: settingsKey, value: json)
            }
        } catch {
            #if DEBUG
            print("[AppearanceSettings] Failed to save settings: \(error)")
            #endif
        }
    }

    private func loadPresets() {
        guard let database = AppDelegate.shared?.database else { return }

        do {
            if let json = try database.getSetting(key: presetsKey),
               let data = json.data(using: .utf8) {
                savedPresets = try JSONDecoder().decode([AppearancePreset].self, from: data)
                #if DEBUG
                print("[AppearanceSettings] Loaded \(savedPresets.count) presets")
                #endif
            }
        } catch {
            #if DEBUG
            print("[AppearanceSettings] Failed to load presets: \(error)")
            #endif
        }
    }

    private func savePresets() {
        guard let database = AppDelegate.shared?.database else { return }

        do {
            let data = try JSONEncoder().encode(savedPresets)
            if let json = String(data: data, encoding: .utf8) {
                try database.setSetting(key: presetsKey, value: json)
            }
        } catch {
            #if DEBUG
            print("[AppearanceSettings] Failed to save presets: \(error)")
            #endif
        }
    }
}
