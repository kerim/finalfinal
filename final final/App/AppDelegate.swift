//
//  AppDelegate.swift
//  final final
//

import AppKit
import GRDB

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Static shared reference - required because NSApp.delegate casting
    /// doesn't work with @NSApplicationDelegateAdaptor
    static var shared: AppDelegate?

    /// The application's database connection
    var database: AppDatabase?

    /// Reference to editor state for cleanup on quit
    weak var editorState: EditorViewState?

    /// Reference to main window for close interception
    private var mainWindow: NSWindow?

    /// NSEvent monitor for Esc key to exit focus mode (works even when WKWebView has focus)
    private var escapeKeyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Start preloading editor WebView EARLY - before any windows/views are created
        // This gives the WebView time to load while database initializes
        EditorPreloader.shared.startPreloading()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Disable window tabbing - removes "Show Tab Bar" and "Show All Tabs" from View menu
        // This app doesn't use a tabbed interface
        NSWindow.allowsAutomaticWindowTabbing = false

        do {
            database = try AppDatabase.makeDefault()
            #if DEBUG
            print("[AppDelegate] Database initialized successfully")
            #endif

            // Load theme and appearance settings now that database is ready
            ThemeManager.shared.loadThemeIfNeeded()
            AppearanceSettingsManager.shared.loadIfNeeded()
        } catch {
            #if DEBUG
            print("[AppDelegate] Failed to initialize database: \(error)")
            #endif
        }

        // Handle newProject and openProject from File menu
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

        // Capture main window for Cmd-W interception
        // Use async to allow SwiftUI to create the window first
        DispatchQueue.main.async { [weak self] in
            if let window = NSApp.windows.first {
                self?.mainWindow = window
                window.delegate = self
                #if DEBUG
                print("[AppDelegate] Set window delegate for Cmd-W interception")
                #endif
            }
        }

        // Set up Esc key monitor for exiting focus mode
        // This is necessary because WKWebView captures keyboard events and
        // SwiftUI's .onKeyPress(.escape) is unreliable when WebView has focus
        setupEscapeKeyMonitor()
    }

    /// Set up NSEvent local monitor for Esc key to exit focus mode
    private func setupEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 53 = Esc key
            guard event.keyCode == 53,
                  let editorState = self?.editorState,
                  editorState.focusModeEnabled else {
                return event  // Pass through if not Esc or not in focus mode
            }

            // Exit focus mode
            Task { @MainActor in
                await editorState.exitFocusMode()
            }

            // Consume the event to prevent other handlers
            return nil
        }
    }

    /// Remove Esc key monitor on termination
    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        print("[AppDelegate] Application terminating")
        #endif

        // Remove Esc key monitor
        removeEscapeKeyMonitor()

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

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        #if DEBUG
        print("[AppDelegate] windowShouldClose called (Cmd-W intercepted)")
        #endif

        // Call project close handler
        // This handles unsaved changes dialogs, Getting Started prompts, etc.
        FileOperations.handleCloseProject()

        // Return false to prevent window from actually closing
        // The project picker will be shown instead
        return false
    }
}
