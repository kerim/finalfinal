//
//  ThemeManager.swift
//  final final
//

import SwiftUI

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var currentTheme: AppColorScheme = .light

    private let settingsKey = "selectedThemeId"

    private init() {
        loadThemeFromDatabase()
    }

    func setTheme(_ theme: AppColorScheme) {
        currentTheme = theme
        saveThemeToDatabase()
        print("[ThemeManager] Theme changed to: \(theme.name)")
    }

    func setTheme(byId id: String) {
        if let theme = AppColorScheme.all.first(where: { $0.id == id }) {
            setTheme(theme)
        }
    }

    /// Returns CSS variables string for web editor injection
    var cssVariables: String {
        currentTheme.cssVariables
    }

    // MARK: - Persistence

    private func loadThemeFromDatabase() {
        guard let database = AppDelegate.shared?.database else {
            print("[ThemeManager] Database not available, using default theme")
            return
        }

        do {
            if let savedId = try database.getSetting(key: settingsKey),
               let theme = AppColorScheme.all.first(where: { $0.id == savedId }) {
                currentTheme = theme
                print("[ThemeManager] Loaded theme: \(theme.name)")
            } else {
                print("[ThemeManager] No saved theme, using default")
            }
        } catch {
            print("[ThemeManager] Failed to load theme: \(error)")
        }
    }

    private func saveThemeToDatabase() {
        guard let database = AppDelegate.shared?.database else {
            print("[ThemeManager] Database not available, cannot save theme")
            return
        }

        do {
            try database.setSetting(key: settingsKey, value: currentTheme.id)
            print("[ThemeManager] Saved theme: \(currentTheme.name)")
        } catch {
            print("[ThemeManager] Failed to save theme: \(error)")
        }
    }
}
