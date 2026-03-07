//
//  ViewCommands.swift
//  final final
//

import SwiftUI

struct ViewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Toggle Outline Sidebar") {
                NotificationCenter.default.post(name: .toggleOutlineSidebar, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Toggle Annotations Sidebar") {
                NotificationCenter.default.post(name: .toggleAnnotationSidebar, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Toggle Focus Mode") {
                NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle Editor Mode") {
                NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Refresh Citations") {
                NotificationCenter.default.post(name: .refreshAllCitations, object: nil)
            }

            Divider()

            Menu("Theme") {
                ForEach(AppColorScheme.all) { theme in
                    Button(theme.name) {
                        ThemeManager.shared.setThemeAndClearOverrides(byId: theme.id)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let toggleOutlineSidebar = Notification.Name("toggleOutlineSidebar")
    static let toggleAnnotationSidebar = Notification.Name("toggleAnnotationSidebar")
    static let refreshAllCitations = Notification.Name("refreshAllCitations")
}
