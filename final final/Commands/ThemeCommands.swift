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
                .keyboardShortcut(theme.keyboardShortcut)
            }
        }
    }
}
