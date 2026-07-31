//
//  FocusModeSettings.swift
//  final final
//
//  Settings model for focus mode configuration.
//  Stored in UserDefaults as a JSON blob.
//

import Foundation

/// Focus mode settings stored in UserDefaults
struct FocusModeSettings: Codable, Sendable {
    var hideLeftSidebar: Bool = true
    var hideRightSidebar: Bool = true
    var hideToolbar: Bool = true
    var hideStatusBar: Bool = true
    var enableParagraphHighlighting: Bool = true

    // MARK: - Defaults

    static let `default` = FocusModeSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let settingsKey = "com.kerim.final-final.focusModeSettings"
    }

    // MARK: - Persistence

    /// Load settings from UserDefaults.
    ///
    /// Routed through `AppDefaults.store` (`.standard` in production, an isolated test-only
    /// suite while any kind of test is running) rather than `UserDefaults.standard` directly —
    /// `com.kerim.final-final.focusModeSettings` is one of the eight keys
    /// `TestMode.clearTestState()` resets, and reading it straight from `.standard` would mean
    /// a unit test run reads (and, via `save()` below, could overwrite) the real user's
    /// persisted focus mode preferences. See `AppDefaults.swift`.
    static func load() -> FocusModeSettings {
        guard let data = AppDefaults.store.data(forKey: Keys.settingsKey),
              let settings = try? JSONDecoder().decode(FocusModeSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// Save settings to UserDefaults. See `load()` for why this goes through `AppDefaults.store`.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            AppDefaults.store.set(data, forKey: Keys.settingsKey)
        }
    }
}

// MARK: - Observable Settings Manager

/// Main-thread observable wrapper for focus mode settings
@MainActor
@Observable
final class FocusModeSettingsManager {

    /// Singleton instance
    static let shared = FocusModeSettingsManager()

    /// Current settings
    private(set) var settings: FocusModeSettings

    private init() {
        settings = FocusModeSettings.load()
    }

    /// Update settings and persist
    func update(_ block: (inout FocusModeSettings) -> Void) {
        block(&settings)
        settings.save()
    }

    /// Reset to defaults
    func resetToDefaults() {
        settings = .default
        settings.save()
    }

    /// Convenience accessors

    var hideLeftSidebar: Bool {
        get { settings.hideLeftSidebar }
        set { update { $0.hideLeftSidebar = newValue } }
    }

    var hideRightSidebar: Bool {
        get { settings.hideRightSidebar }
        set { update { $0.hideRightSidebar = newValue } }
    }

    var hideToolbar: Bool {
        get { settings.hideToolbar }
        set { update { $0.hideToolbar = newValue } }
    }

    var hideStatusBar: Bool {
        get { settings.hideStatusBar }
        set { update { $0.hideStatusBar = newValue } }
    }

    var enableParagraphHighlighting: Bool {
        get { settings.enableParagraphHighlighting }
        set { update { $0.enableParagraphHighlighting = newValue } }
    }
}
