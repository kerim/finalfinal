//
//  AppDelegate.swift
//  final final
//

import AppKit
import GRDB

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static shared reference - required because NSApp.delegate casting
    /// doesn't work with @NSApplicationDelegateAdaptor
    static var shared: AppDelegate?

    /// The application's database connection
    var database: AppDatabase?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        do {
            database = try AppDatabase.makeDefault()
            #if DEBUG
            print("[AppDelegate] Database initialized successfully")
            #endif

            // Load theme now that database is ready
            ThemeManager.shared.loadThemeIfNeeded()
        } catch {
            #if DEBUG
            print("[AppDelegate] Failed to initialize database: \(error)")
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        print("[AppDelegate] Application terminating")
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
