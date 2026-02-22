//
//  EditorCommands.swift
//  final final
//

import SwiftUI

struct EditorCommands: Commands {
    @AppStorage("isSpellingEnabled") private var spellingEnabled = true
    @AppStorage("isGrammarEnabled") private var grammarEnabled = true

    var body: some Commands {
        // Format menu
        CommandMenu("Format") {
            Button("Bold") {
                NotificationCenter.default.post(name: .toggleBold, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Italic") {
                NotificationCenter.default.post(name: .toggleItalic, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Strikethrough") {
                NotificationCenter.default.post(name: .toggleStrikethrough, object: nil)
            }

            Divider()

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        NotificationCenter.default.post(
                            name: .setHeading,
                            object: nil,
                            userInfo: ["level": level]
                        )
                    }
                }
                Divider()
                Button("Paragraph") {
                    NotificationCenter.default.post(
                        name: .setHeading,
                        object: nil,
                        userInfo: ["level": 0]
                    )
                }
            }

            Divider()

            Button("Bullet List") {
                NotificationCenter.default.post(name: .toggleBulletList, object: nil)
            }

            Button("Numbered List") {
                NotificationCenter.default.post(name: .toggleNumberList, object: nil)
            }

            Button("Blockquote") {
                NotificationCenter.default.post(name: .toggleBlockquote, object: nil)
            }

            Button("Code Block") {
                NotificationCenter.default.post(name: .toggleCodeBlock, object: nil)
            }

            Divider()

            Button("Link") {
                NotificationCenter.default.post(name: .insertLink, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

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

            Toggle("Check Spelling", isOn: Binding(
                get: { spellingEnabled },
                set: { spellingEnabled = $0
                       NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil) }
            ))
            .keyboardShortcut(";", modifiers: .command)

            Toggle("Check Grammar", isOn: Binding(
                get: { grammarEnabled },
                set: { grammarEnabled = $0
                       NotificationCenter.default.post(name: .spellcheckTypeToggled, object: nil) }
            ))
            .keyboardShortcut(";", modifiers: [.command, .shift])

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

            // Footnote command
            Button("Insert Footnote") {
                NotificationCenter.default.post(name: .insertFootnote, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

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
    static let spellcheckTypeToggled = Notification.Name("spellcheckTypeToggled")
    static let proofingModeChanged = Notification.Name("proofingModeChanged")
    static let proofingSettingsChanged = Notification.Name("proofingSettingsChanged")
    static let openProofingPreferences = Notification.Name("openProofingPreferences")
    static let proofingConnectionStatusChanged = Notification.Name("proofingConnectionStatusChanged")
    static let insertSectionBreak = Notification.Name("insertSectionBreak")

    // Find commands
    static let showFindBar = Notification.Name("showFindBar")
    static let findNext = Notification.Name("findNext")
    static let findPrevious = Notification.Name("findPrevious")
    static let useSelectionForFind = Notification.Name("useSelectionForFind")
}
