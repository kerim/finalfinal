//
//  GoalColorSettings.swift
//  final final
//
//  Goal color thresholds and color overrides.
//  Persists to AppDatabase settings table.
//

import SwiftUI

// MARK: - Goal Thresholds

/// Configurable thresholds for three-tier word count goal colors
struct GoalThresholds: Codable, Sendable, Equatable {
    /// Minimum goal: warning (orange) starts at this percentage (default: 80%)
    var minWarningPercent: Double = 80

    /// Maximum goal: warning (orange) up to this percentage (default: 105%)
    var maxWarningPercent: Double = 105

    /// Approximate goal: green range as deviation percentage (default: ±5%)
    var approxGreenPercent: Double = 5

    /// Approximate goal: orange range as deviation percentage (default: ±8%)
    var approxOrangePercent: Double = 8

    static let defaults = GoalThresholds()
}

// MARK: - Goal Color Overrides

/// Optional color overrides for goal status indicators
struct GoalColorOverrides: Codable, Sendable, Equatable {
    /// Override for met/green color (nil = theme default)
    var metColor: CodableColor?

    /// Override for warning/orange color (nil = theme default)
    var warningColor: CodableColor?

    /// Override for not-met/red color (nil = theme default)
    var notMetColor: CodableColor?

    static let defaults = GoalColorOverrides()

    var hasOverrides: Bool {
        metColor != nil || warningColor != nil || notMetColor != nil
    }
}

// MARK: - Goal Color Settings

/// Combined goal color settings (thresholds + color overrides)
struct GoalColorSettings: Codable, Sendable, Equatable {
    var thresholds: GoalThresholds = .defaults
    var colorOverrides: GoalColorOverrides = .defaults

    static let defaults = GoalColorSettings()
}

// MARK: - Goal Color Settings Manager

/// Manages goal color settings persistence and effective color resolution
@MainActor
@Observable
final class GoalColorSettingsManager {
    static let shared = GoalColorSettingsManager()

    private(set) var settings: GoalColorSettings = .defaults

    private let settingsKey = "goalColorSettings"
    private var hasLoaded = false

    private init() {}

    /// Call this after database is confirmed ready
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        loadSettings()
        hasLoaded = true
    }

    // MARK: - Settings Updates

    /// Update settings and save
    func update(_ newSettings: GoalColorSettings) {
        settings = newSettings
        saveSettings()
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        settings = .defaults
        saveSettings()
    }

    // MARK: - Threshold Updates

    func updateThresholds(_ thresholds: GoalThresholds) {
        var updated = settings
        updated.thresholds = thresholds
        update(updated)
    }

    // MARK: - Color Override Updates

    func setMetColor(_ color: Color?) {
        var updated = settings
        updated.colorOverrides.metColor = color.map { CodableColor(color: $0) }
        update(updated)
    }

    func setWarningColor(_ color: Color?) {
        var updated = settings
        updated.colorOverrides.warningColor = color.map { CodableColor(color: $0) }
        update(updated)
    }

    func setNotMetColor(_ color: Color?) {
        var updated = settings
        updated.colorOverrides.notMetColor = color.map { CodableColor(color: $0) }
        update(updated)
    }

    // MARK: - Effective Colors

    /// Effective met (green) color: override or theme default
    func effectiveMetColor(theme: AppColorScheme) -> Color {
        settings.colorOverrides.metColor?.color ?? theme.statusColors.goalMet
    }

    /// Effective warning (orange) color: override or theme default
    func effectiveWarningColor(theme: AppColorScheme) -> Color {
        settings.colorOverrides.warningColor?.color ?? theme.statusColors.goalWarning
    }

    /// Effective not-met (red) color: override or theme default
    func effectiveNotMetColor(theme: AppColorScheme) -> Color {
        settings.colorOverrides.notMetColor?.color ?? theme.statusColors.goalNotMet
    }

    // MARK: - Override Checks

    func isMetColorOverridden() -> Bool { settings.colorOverrides.metColor != nil }
    func isWarningColorOverridden() -> Bool { settings.colorOverrides.warningColor != nil }
    func isNotMetColorOverridden() -> Bool { settings.colorOverrides.notMetColor != nil }

    // MARK: - Persistence

    private func loadSettings() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[GoalColorSettings] Database not available, using defaults")
            #endif
            return
        }

        do {
            if let json = try database.getSetting(key: settingsKey),
               let data = json.data(using: .utf8) {
                settings = try JSONDecoder().decode(GoalColorSettings.self, from: data)
                #if DEBUG
                print("[GoalColorSettings] Loaded settings")
                #endif
            }
        } catch {
            #if DEBUG
            print("[GoalColorSettings] Failed to load settings: \(error)")
            #endif
        }
    }

    private func saveSettings() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[GoalColorSettings] Database not available, cannot save")
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
            print("[GoalColorSettings] Failed to save settings: \(error)")
            #endif
        }
    }
}
