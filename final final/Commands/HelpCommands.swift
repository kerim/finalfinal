//
//  HelpCommands.swift
//  final final
//
//  Help menu commands including Getting Started guide access.
//

import SwiftUI

struct HelpCommands: Commands {
    var onGettingStarted: () -> Void
    var sparkleUpdater: SparkleUpdater

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Getting Started") {
                onGettingStarted()
            }

            Divider()

            Button("Check for Updates\u{2026}") {
                sparkleUpdater.checkForUpdates()
            }
            .disabled(!sparkleUpdater.canCheckForUpdates)

            Divider()

            Link("Report an Issue\u{2026}", destination: URL(string: "https://github.com/kerim/final-final/issues")!)
        }
    }
}
