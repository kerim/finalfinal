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
                    ThemeManager.shared.setTheme(theme)
                }
                .keyboardShortcut(keyboardShortcut(for: theme))
            }
        }
    }

    private func keyboardShortcut(for theme: AppColorScheme) -> KeyboardShortcut? {
        switch theme.id {
        case "light": return KeyboardShortcut("1", modifiers: [.command, .option])
        case "dark": return KeyboardShortcut("2", modifiers: [.command, .option])
        case "sepia": return KeyboardShortcut("3", modifiers: [.command, .option])
        case "solarized-light": return KeyboardShortcut("4", modifiers: [.command, .option])
        case "solarized-dark": return KeyboardShortcut("5", modifiers: [.command, .option])
        default: return nil
        }
    }
}
