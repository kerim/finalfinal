//
//  HelpCommands.swift
//  final final
//
//  Help menu commands including Getting Started guide access.
//

import SwiftUI

struct HelpCommands: Commands {
    /// Callback to open Getting Started
    var onGettingStarted: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Getting Started") {
                print("[HelpCommands] Getting Started button clicked")
                onGettingStarted()
                print("[HelpCommands] onGettingStarted callback completed")
            }

            Divider()

            Link("Report an Issue...", destination: URL(string: "https://github.com/kerim/final-final/issues")!)
        }
    }
}
