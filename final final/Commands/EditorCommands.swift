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

            Divider()

            // Highlight command
            Button("Toggle Highlight") {
                NotificationCenter.default.post(name: .toggleHighlight, object: nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            // Annotation commands
            Button("Insert Task") {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.task]
                )
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Insert Comment") {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.comment]
                )
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Insert Reference") {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.reference]
                )
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
    static let toggleEditorMode = Notification.Name("toggleEditorMode")
    static let insertSectionBreak = Notification.Name("insertSectionBreak")
}
