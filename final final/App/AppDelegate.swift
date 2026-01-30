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

    /// Reference to editor state for cleanup on quit
    weak var editorState: EditorViewState?

    /// Notification observers for project lifecycle
    private var projectDidOpenObserver: Any?
    private var projectDidCreateObserver: Any?

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

        // Listen for project open completion to create window if needed
        // This fires AFTER the project is successfully opened (async dialog completed)
        projectDidOpenObserver = NotificationCenter.default.addObserver(
            forName: .projectDidOpen, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.createWindowIfNeeded()
            }
        }

        // Also listen for projectDidCreate (new projects)
        projectDidCreateObserver = NotificationCenter.default.addObserver(
            forName: .projectDidCreate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.createWindowIfNeeded()
            }
        }

        // Handle newProject and openProject when no windows exist
        // These notifications come from FileCommands when user clicks File > New/Open
        // AppDelegate always exists, so it can handle these even with zero windows
        NotificationCenter.default.addObserver(
            forName: .newProject, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                FileOperations.handleNewProject()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .openProject, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                FileOperations.handleOpenProject()
            }
        }

        // Handle export notifications
        NotificationCenter.default.addObserver(
            forName: .exportDocument, object: nil, queue: .main
        ) { notification in
            Task { @MainActor in
                if let format = notification.userInfo?["format"] as? ExportFormat {
                    ExportOperations.handleExport(format: format)
                }
            }
        }

        // Handle show export preferences
        NotificationCenter.default.addObserver(
            forName: .showExportPreferences, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Open Settings window and switch to Export tab
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    /// Check if a window is our app's SwiftUI content window (not a system window)
    private func isAppContentWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        guard let contentView = window.contentView else { return false }

        // SwiftUI WindowGroup creates windows with NSHostingView as content
        let viewType = String(describing: type(of: contentView))
        return viewType.contains("HostingView")
    }

    /// Create a window if none exists and a project is open
    private func createWindowIfNeeded() {
        #if DEBUG
        print("[AppDelegate] createWindowIfNeeded called")
        print("[AppDelegate] hasOpenProject: \(DocumentManager.shared.hasOpenProject)")
        print("[AppDelegate] projectId: \(DocumentManager.shared.projectId ?? "nil")")
        print("[AppDelegate] Window count: \(NSApp.windows.count)")
        for (i, window) in NSApp.windows.enumerated() {
            let contentType = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
            print("[AppDelegate] Window \(i): visible=\(window.isVisible), isAppContent=\(isAppContentWindow(window)), class=\(type(of: window)), contentView=\(contentType)")
        }
        #endif

        let hasContentWindow = NSApp.windows.contains { window in
            window.isVisible && isAppContentWindow(window)
        }

        guard !hasContentWindow else {
            #if DEBUG
            print("[AppDelegate] Skipping - content window already exists")
            #endif
            return
        }

        guard DocumentManager.shared.hasOpenProject else {
            #if DEBUG
            print("[AppDelegate] Skipping - no project open")
            #endif
            return
        }

        #if DEBUG
        print("[AppDelegate] Creating window for opened project")
        #endif

        NSApp.activate(ignoringOtherApps: true)

        // Try to show an existing hidden SwiftUI window first
        if let existingWindow = NSApp.windows.first(where: {
            !$0.isVisible && isAppContentWindow($0)
        }) {
            #if DEBUG
            print("[AppDelegate] Showing existing hidden SwiftUI window")
            #endif
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        #if DEBUG
        print("[AppDelegate] Opening new window via URL scheme")
        #endif
        // Use URL scheme to trigger SwiftUI WindowGroup to create window
        if let url = URL(string: "finalfinal://open") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        print("[AppDelegate] Application terminating")
        #endif

        // If zoomed, merge content back before quitting
        // This is fire-and-forget since we're terminating anyway
        if let state = editorState, state.zoomedSectionId != nil {
            Task { @MainActor in
                await state.zoomOut()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
