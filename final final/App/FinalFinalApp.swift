//
//  FinalFinalApp.swift
//  final final
//

import SwiftUI

@main
struct FinalFinalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var versionHistoryCoordinator = VersionHistoryCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ThemeManager.shared)
                .environment(versionHistoryCoordinator)
        }
        .commands {
            FileCommands()
            ThemeCommands()
            EditorCommands()
            ExportCommands()
        }
        .handlesExternalEvents(matching: ["open"])

        // Preferences window
        Settings {
            PreferencesView()
                .environment(ThemeManager.shared)
        }

        Window("Version History", id: "version-history") {
            VersionHistoryWindow()
                .environment(ThemeManager.shared)
                .environment(versionHistoryCoordinator)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
