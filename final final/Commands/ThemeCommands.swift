//
//  ThemeCommands.swift
//  final final
//

import SwiftUI

struct ThemeCommands: Commands {
    var body: some Commands {
        CommandMenu("Theme") {
            ForEach(AppColorScheme.all) { theme in
                Button(theme.name) {
                    // Reset all appearance overrides when selecting theme from menu
                    ThemeManager.shared.setThemeAndClearOverrides(byId: theme.id)
                }
                .keyboardShortcut(theme.keyboardShortcut)
            }
        }
    }
}
