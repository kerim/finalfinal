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
            print("[AppDelegate] Database initialized successfully")
        } catch {
            print("[AppDelegate] Failed to initialize database: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Application terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
