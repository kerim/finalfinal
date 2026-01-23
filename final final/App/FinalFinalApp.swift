//
//  FinalFinalApp.swift
//  final final
//

import SwiftUI

@main
struct FinalFinalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ThemeManager.shared)
        }
        .commands {
            ThemeCommands()
        }
    }
}
