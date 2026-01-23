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
    private var hasLoadedFromDatabase = false

    private let settingsKey = "selectedThemeId"

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
        #if DEBUG
        print("[ThemeManager] Theme changed to: \(theme.name)")
        #endif
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
            #if DEBUG
            print("[ThemeManager] Database not available, using default theme")
            #endif
            return
        }

        do {
            if let savedId = try database.getSetting(key: settingsKey),
               let theme = AppColorScheme.all.first(where: { $0.id == savedId }) {
                currentTheme = theme
                #if DEBUG
                print("[ThemeManager] Loaded theme: \(theme.name)")
                #endif
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
