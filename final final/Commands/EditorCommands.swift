//
//  EditorCommands.swift
//  final final
//

import SwiftUI

struct EditorCommands: Commands {
    var body: some Commands {
        // Find commands - replace default Find menu
        CommandGroup(replacing: .textEditing) {
            Button("Find...") {
                NotificationCenter.default.post(name: .showFindBar, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find and Replace...") {
                NotificationCenter.default.post(name: .showFindBar, object: nil, userInfo: ["showReplace": true])
            }
            .keyboardShortcut("h", modifiers: .command)

            Button("Find Next") {
                NotificationCenter.default.post(name: .findNext, object: nil)
            }
            .keyboardShortcut("g", modifiers: .command)

            Button("Find Previous") {
                NotificationCenter.default.post(name: .findPrevious, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button("Use Selection for Find") {
                NotificationCenter.default.post(name: .useSelectionForFind, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)

            Divider()
        }

        CommandGroup(after: .textEditing) {
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

    // Find commands
    static let showFindBar = Notification.Name("showFindBar")
    static let findNext = Notification.Name("findNext")
    static let findPrevious = Notification.Name("findPrevious")
    static let useSelectionForFind = Notification.Name("useSelectionForFind")
}
