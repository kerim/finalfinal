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
        }
    }
}

extension Notification.Name {
    static let toggleOutlineSidebar = Notification.Name("toggleOutlineSidebar")
    static let toggleAnnotationSidebar = Notification.Name("toggleAnnotationSidebar")
}
