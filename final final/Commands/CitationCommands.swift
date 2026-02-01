//
//  CitationCommands.swift
//  final final
//
//  Menu commands for citation management.
//

import SwiftUI

struct CitationCommands: Commands {
    var body: some Commands {
        CommandMenu("Citations") {
            Button("Refresh All Citations") {
                NotificationCenter.default.post(name: .refreshAllCitations, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let refreshAllCitations = Notification.Name("refreshAllCitations")
}
