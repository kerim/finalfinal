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
                onGettingStarted()
            }

            Divider()

            Button("Check for Updates...") {
                Task {
                    let status = await UpdateChecker().check()
                    switch status {
                    case .updateAvailable(let version, let url):
                        UpdateChecker.showUpdateAlert(version: version, url: url)
                    case .upToDate:
                        UpdateChecker.showUpToDateAlert()
                    case .error(let message):
                        UpdateChecker.showErrorAlert(message)
                    }
                }
            }

            Divider()

            Link("Report an Issue...", destination: URL(string: "https://github.com/kerim/final-final/issues")!)
        }
    }
}
