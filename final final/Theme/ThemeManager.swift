//
//  ThemeManager.swift
//  final final
//

import SwiftUI
import AppKit

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var currentTheme: AppColorScheme = .highContrastDay
    private var hasLoadedFromDatabase = false

    private let settingsKey = "selectedThemeId"

    /// Migration map from old theme IDs to new ones
    private let themeMigrationMap: [String: String] = [
        "light": "high-contrast-day",
        "sepia": "low-contrast-day",
        "dark": "high-contrast-night",
        "solarized-dark": "low-contrast-night",
        "solarized-light": "low-contrast-day"
    ]

    private init() {
        // Don't load from database in init - database may not be ready yet
        // Theme will be loaded when first accessed or explicitly refreshed
    }

    /// Call this after database is confirmed ready (e.g., from AppDelegate.applicationDidFinishLaunching)
    func loadThemeIfNeeded() {
        guard !hasLoadedFromDatabase else { return }
        loadThemeFromDatabase()
        hasLoadedFromDatabase = true
    }

    func setTheme(_ theme: AppColorScheme) {
        currentTheme = theme
        saveThemeToDatabase()
        updateAppAppearance(for: theme)
        #if DEBUG
        print("[ThemeManager] Theme changed to: \(theme.name)")
        #endif
    }

    func setTheme(byId id: String) {
        if let theme = AppColorScheme.all.first(where: { $0.id == id }) {
            setTheme(theme)
        }
    }

    /// Set theme and clear appearance overrides (themes may have very different fonts/layouts)
    func setThemeAndClearOverrides(byId id: String) {
        if let theme = AppColorScheme.all.first(where: { $0.id == id }) {
            AppearanceSettingsManager.shared.resetToDefaults()
            setTheme(theme)
        }
    }

    /// Returns CSS variables string for web editor injection
    /// Includes appearance overrides appended after theme CSS (later declarations win)
    var cssVariables: String {
        let themeCSS = currentTheme.cssVariables
        let overrides = AppearanceSettingsManager.shared.cssOverrides
        if overrides.isEmpty {
            return themeCSS
        }
        return themeCSS + "\n" + overrides
    }

    // MARK: - Appearance

    /// Update the app appearance to match the theme (dark/light mode)
    private func updateAppAppearance(for theme: AppColorScheme) {
        NSApp.appearance = theme.requiresDarkAppearance
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    // MARK: - Persistence

    private func loadThemeFromDatabase() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[ThemeManager] Database not available, using default theme")
            #endif
            return
        }

        do {
            if let savedId = try database.getSetting(key: settingsKey) {
                // Check if this is an old theme ID that needs migration
                let themeId = themeMigrationMap[savedId] ?? savedId

                if let theme = AppColorScheme.all.first(where: { $0.id == themeId }) {
                    currentTheme = theme
                    updateAppAppearance(for: theme)
                    #if DEBUG
                    print("[ThemeManager] Loaded theme: \(theme.name)")
                    #endif

                    // If we migrated, save the new ID
                    if savedId != themeId {
                        #if DEBUG
                        print("[ThemeManager] Migrated theme from '\(savedId)' to '\(themeId)'")
                        #endif
                        try database.setSetting(key: settingsKey, value: themeId)
                    }
                } else {
                    #if DEBUG
                    print("[ThemeManager] Unknown theme ID '\(savedId)', using default")
                    #endif
                }
            } else {
                #if DEBUG
                print("[ThemeManager] No saved theme, using default")
                #endif
            }
        } catch {
            #if DEBUG
            print("[ThemeManager] Failed to load theme: \(error)")
            #endif
        }
    }

    private func saveThemeToDatabase() {
        guard let database = AppDelegate.shared?.database else {
            #if DEBUG
            print("[ThemeManager] Database not available, cannot save theme")
            #endif
            return
        }

        do {
            try database.setSetting(key: settingsKey, value: currentTheme.id)
            #if DEBUG
            print("[ThemeManager] Saved theme: \(currentTheme.name)")
            #endif
        } catch {
            #if DEBUG
            print("[ThemeManager] Failed to save theme: \(error)")
            #endif
        }
    }
}
