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

    /// Whether applicationShouldTerminate already flushed content (prevents redundant flush in applicationWillTerminate)
    private var didFlushForQuit = false

    /// URL passed by Finder double-click; consumed by determineInitialState()
    var finderOpenURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // In test mode, clean saved application state from the CORRECT path.
        // The test runner can't do this because its NSHomeDirectory() is containerized
        // and points to the wrong location. The app's NSHomeDirectory() is the real user home.
        if TestMode.isTesting {
            let savedStatePath = NSHomeDirectory()
                + "/Library/Saved Application State/com.kerim.final-final.savedState"
            let exists = FileManager.default.fileExists(atPath: savedStatePath)
            DebugLog.log(.lifecycle, "[AppDelegate] Test mode: saved state at \(savedStatePath) exists=\(exists)")
            if exists {
                try? FileManager.default.removeItem(atPath: savedStatePath)
                DebugLog.log(.lifecycle, "[AppDelegate] Test mode: removed saved application state")
            }
        }

        // Start preloading editor WebView EARLY - before any windows/views are created
        // This gives the WebView time to load while database initializes
        EditorPreloader.shared.startPreloading()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        DebugLog.log(.lifecycle, "[FINAL|FINAL] Build: \(GitInfo.branch) (\(GitInfo.commit))")

        // Disable window tabbing - removes "Show Tab Bar" and "Show All Tabs" from View menu
        // This app doesn't use a tabbed interface
        NSWindow.allowsAutomaticWindowTabbing = false

        // Explicitly set activation policy to .regular so the app gets a dock icon
        // and creates windows. XCUITest's launch mechanism may not set this automatically.
        // Skip during unit tests to avoid Dock icon flicker.
        if !TestMode.isUnitTesting {
            NSApp.setActivationPolicy(.regular)
        }

        do {
            database = try TestMode.isUnitTesting ? AppDatabase.makeInMemory() : AppDatabase.makeDefault()
            DebugLog.log(.lifecycle, "[AppDelegate] Database initialized successfully")

            // Load theme and appearance settings now that database is ready
            ThemeManager.shared.loadThemeIfNeeded()
            AppearanceSettingsManager.shared.loadIfNeeded()
            GoalColorSettingsManager.shared.loadIfNeeded()
        } catch {
            DebugLog.log(.lifecycle, "[AppDelegate] Failed to initialize database: \(error)")
        }

        // Check for updates on launch (silent -- only alerts if update available)
        if !TestMode.isTesting {
            Task {
                let status = await UpdateChecker().check()
                if case .updateAvailable(let version, let url) = status {
                    UpdateChecker.showUpdateAlert(version: version, url: url)
                }
            }
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

        NotificationCenter.default.addObserver(
            forName: .saveProjectAs, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                FileOperations.handleSaveProjectAs()
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

        // Capture main window for Cmd-W interception
        // Use async to allow SwiftUI to create the window first
        DispatchQueue.main.async { [weak self] in
            // Close any version-history windows that macOS restored from saved state,
            // and mark them non-restorable to prevent future restoration.
            // SwiftUI assigns identifiers like "version-history-1" based on the Window id.
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("version-history") == true {
                DebugLog.log(.lifecycle, "[AppDelegate] Closing restored version-history window: id=\(window.identifier?.rawValue ?? "nil")")
                window.isRestorable = false  // must be set before close
                window.close()
            }

            // Now capture the main window (after closing restored secondary windows)
            if let window = NSApp.windows.first {
                self?.mainWindow = window
                window.delegate = self
                DebugLog.log(.lifecycle, "[AppDelegate] Set window delegate for Cmd-W interception")

                // If macOS restored the window to fullscreen (Saved Application State),
                // ensure we switch to that Space immediately
                if window.styleMask.contains(.fullScreen) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                }
            }
        }

        // Workaround for missing initial window (FB15577018):
        // Xcode's debug launcher and XCUIApplication.launch() bypass LaunchServices,
        // so SwiftUI's WindowGroup never receives the kAEOpenApplication event that
        // triggers initial window creation. Re-activate via LaunchServices to send
        // the proper Apple Events.
        if !TestMode.isUnitTesting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let hasVisibleWindow = NSApp.windows.contains(where: { $0.isVisible })
                DebugLog.log(.lifecycle, "[AppDelegate] Window check at 0.5s: hasVisibleWindow=\(hasVisibleWindow)")
                if !hasVisibleWindow {
                    DebugLog.log(.lifecycle, "[AppDelegate] No visible windows, re-activating via LaunchServices")
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(
                        at: Bundle.main.bundleURL,
                        configuration: config
                    ) { _, error in
                        if let error = error {
                            DebugLog.log(.lifecycle, "[AppDelegate] LaunchServices re-activation failed: \(error)")
                        }
                    }

                    // Capture window delegate after recovery
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        if let window = NSApp.windows.first, self?.mainWindow == nil {
                            self?.mainWindow = window
                            window.delegate = self
                        }
                    }
                }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editorState = editorState, !editorState.content.isEmpty else {
            return .terminateNow
        }

        Task { @MainActor in
            // Fetch fresh content from the active WebView with 2s timeout
            if let freshContent = await editorState.blockSyncService?.fetchContentFromWebView(),
               !freshContent.isEmpty {
                editorState.content = freshContent
            }

            editorState.flushAllSync()
            self.didFlushForQuit = true
            self.removeEscapeKeyMonitor()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log(.lifecycle, "[AppDelegate] Application terminating")
        // Only flush if applicationShouldTerminate didn't already (safety net for force-quit)
        if !didFlushForQuit {
            editorState?.flushAllSync()
        }
        removeEscapeKeyMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Finder File Open

    func application(_ application: NSApplication, open urls: [URL]) {
        DebugLog.always("[FINDER-OPEN] application(_:open:) called with \(urls.count) URLs")
        guard let url = urls.first, url.pathExtension == "ff" else {
            DebugLog.always("[FINDER-OPEN] Rejected: no .ff URL in \(urls)")
            return
        }
        DebugLog.always("[FINDER-OPEN] URL: \(url.path)")
        DebugLog.always("[FINDER-OPEN] hasOpenProject=\(DocumentManager.shared.hasOpenProject)")

        // If app is still launching (no project open yet), stash URL for
        // determineInitialState() to consume — avoids race where
        // restoreLastProject() overwrites Finder intent.
        if !DocumentManager.shared.hasOpenProject {
            DebugLog.always("[FINDER-OPEN] Stashing URL for launch (no project open yet)")
            finderOpenURL = url
            return
        }

        // App already running — flush pending editor content, then open
        DebugLog.always("[FINDER-OPEN] App running with project, flushing and opening")
        editorState?.flushContentToDatabase()
        openProjectFromFinder(at: url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard url.pathExtension == "ff" else { return false }
        DebugLog.always("[FINDER-OPEN] application(_:openFile:) called: \(filename)")
        application(sender, open: [url])
        return true
    }

    /// Open a .ff project from Finder, with error handling matching FileOperations.handleOpenProject()
    private func openProjectFromFinder(at url: URL) {
        let currentURL = DocumentManager.shared.projectURL?.resolvingSymlinksInPath()
        let incomingURL = url.resolvingSymlinksInPath()
        DebugLog.always("[FINDER-OPEN] openProjectFromFinder: current=\(currentURL?.path ?? "nil") incoming=\(incomingURL.path)")

        // Skip if this project is already open (duplicate Apple Events)
        guard currentURL != incomingURL else {
            DebugLog.always("[FINDER-OPEN] BLOCKED: same project already open")
            return
        }

        do {
            try DocumentManager.shared.openProject(at: url)
            DebugLog.always("[FINDER-OPEN] openProject succeeded, posting .projectDidOpen")
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)
        } catch let error as IntegrityError {
            // openProject() validates before closing, so current project is preserved.
            // Show integrity error UI without posting projectDidClose.
            if let report = error.integrityReport {
                NotificationCenter.default.post(
                    name: .projectIntegrityError, object: nil,
                    userInfo: ["report": report, "url": url]
                )
            } else {
                showFinderOpenError(error)
            }
        } catch {
            // Current project preserved — just show the error
            DebugLog.log(.lifecycle, "[AppDelegate] Failed to open from Finder: \(error)")
            showFinderOpenError(error)
        }
    }

    private func showFinderOpenError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Open Project"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        DebugLog.log(.lifecycle, "[AppDelegate] windowShouldClose called (Cmd-W intercepted)")

        // Call project close handler
        // This handles unsaved changes dialogs, Getting Started prompts, etc.
        FileOperations.handleCloseProject()

        // Return false to prevent window from actually closing
        // The project picker will be shown instead
        return false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // Force macOS to switch to this window's fullscreen Space.
        // Without this, programmatic fullscreen (e.g., focus mode restoration on launch)
        // creates the Space but doesn't switch to it.
        if let window = notification.object as? NSWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}
