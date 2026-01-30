//
//  ExportSettings.swift
//  final final
//
//  Settings model for export configuration.
//  Stored in UserDefaults with type-safe keys.
//

import Foundation

/// Export format options
enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case word = "docx"
    case pdf = "pdf"
    case odt = "odt"

    var id: String { rawValue }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .word: return "Word (.docx)"
        case .pdf: return "PDF"
        case .odt: return "OpenDocument (.odt)"
        }
    }

    /// File extension
    var fileExtension: String {
        rawValue
    }

    /// Pandoc output format argument
    var pandocFormat: String {
        rawValue
    }

    /// UTType identifier for save panel
    var contentTypeIdentifier: String {
        switch self {
        case .word: return "org.openxmlformats.wordprocessingml.document"
        case .pdf: return "com.adobe.pdf"
        case .odt: return "org.oasis-open.opendocument.text"
        }
    }
}

/// Export settings stored in UserDefaults
struct ExportSettings: Codable, Sendable {

    /// Custom Pandoc path (nil = auto-detect)
    var customPandocPath: String?

    /// Use custom Lua filter for Zotero citations
    var useCustomLuaScript: Bool = false

    /// Path to custom Lua filter (nil = use bundled)
    var customLuaScriptPath: String?

    /// Use custom reference document
    var useCustomReferenceDoc: Bool = false

    /// Path to custom reference document (nil = use bundled)
    var customReferenceDocPath: String?

    /// Show Zotero warning when not running
    var showZoteroWarning: Bool = true

    /// Default export format
    var defaultFormat: ExportFormat = .word

    // MARK: - Defaults

    static let `default` = ExportSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let settingsKey = "com.kerim.final-final.exportSettings"
    }

    // MARK: - Persistence

    /// Load settings from UserDefaults
    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.settingsKey),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Save settings to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Keys.settingsKey)
        }
    }

    // MARK: - Computed Properties

    /// Effective Lua script path (custom or bundled)
    var effectiveLuaScriptPath: String? {
        if useCustomLuaScript, let custom = customLuaScriptPath, !custom.isEmpty {
            return custom
        }
        return Bundle.main.url(forResource: "zotero", withExtension: "lua", subdirectory: "Export")?.path
    }

    /// Effective reference document path (custom or bundled)
    var effectiveReferenceDocPath: String? {
        if useCustomReferenceDoc, let custom = customReferenceDocPath, !custom.isEmpty {
            return custom
        }
        return Bundle.main.url(forResource: "reference", withExtension: "docx", subdirectory: "Export")?.path
    }

    /// Check if custom Lua script path is valid
    var isCustomLuaScriptValid: Bool {
        guard useCustomLuaScript, let path = customLuaScriptPath, !path.isEmpty else {
            return true  // Not using custom, so valid
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Check if custom reference doc path is valid
    var isCustomReferenceDocValid: Bool {
        guard useCustomReferenceDoc, let path = customReferenceDocPath, !path.isEmpty else {
            return true  // Not using custom, so valid
        }
        return FileManager.default.fileExists(atPath: path)
    }
}

// MARK: - Observable Settings Manager

/// Main-thread observable wrapper for export settings
@MainActor
@Observable
final class ExportSettingsManager {

    /// Singleton instance
    static let shared = ExportSettingsManager()

    /// Current settings
    private(set) var settings: ExportSettings

    private init() {
        settings = ExportSettings.load()
    }

    /// Update settings and persist
    func update(_ block: (inout ExportSettings) -> Void) {
        block(&settings)
        settings.save()
    }

    /// Reset to defaults
    func resetToDefaults() {
        settings = .default
        settings.save()
    }

    /// Convenience accessors

    var customPandocPath: String? {
        get { settings.customPandocPath }
        set { update { $0.customPandocPath = newValue } }
    }

    var useCustomLuaScript: Bool {
        get { settings.useCustomLuaScript }
        set { update { $0.useCustomLuaScript = newValue } }
    }

    var customLuaScriptPath: String? {
        get { settings.customLuaScriptPath }
        set { update { $0.customLuaScriptPath = newValue } }
    }

    var useCustomReferenceDoc: Bool {
        get { settings.useCustomReferenceDoc }
        set { update { $0.useCustomReferenceDoc = newValue } }
    }

    var customReferenceDocPath: String? {
        get { settings.customReferenceDocPath }
        set { update { $0.customReferenceDocPath = newValue } }
    }

    var showZoteroWarning: Bool {
        get { settings.showZoteroWarning }
        set { update { $0.showZoteroWarning = newValue } }
    }

    var defaultFormat: ExportFormat {
        get { settings.defaultFormat }
        set { update { $0.defaultFormat = newValue } }
    }
}
