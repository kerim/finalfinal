//
//  EditorCommands.swift
//  final final
//

import SwiftUI

struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Toggle Focus Mode") {
                NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle Editor Mode") {
                NotificationCenter.default.post(name: .toggleEditorMode, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Insert Section Break") {
                NotificationCenter.default.post(name: .insertSectionBreak, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleEditorMode = Notification.Name("toggleEditorMode")
    static let insertSectionBreak = Notification.Name("insertSectionBreak")
}
