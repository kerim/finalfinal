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

    /// Reference to auto-backup service for quit-time snapshot
    weak var autoBackupService: AutoBackupService?

    /// Reference to main window for close interception. Read by `FullScreenManager`, which
    /// resolves the window to act on via `AppDelegate.shared?.mainWindow`. Written only from
    /// `captureMainWindow` (`AppDelegate+WindowFramePersistence.swift`) -- not `private(set)`
    /// because that extraction lives in a sibling file, and Swift's `private` does not cross
    /// file boundaries even between extensions of the same type.
    var mainWindow: NSWindow?

    /// UserDefaults key for the manually-persisted main window frame. Not private: read by
    /// `FinalFinalApp`'s `.defaultWindowPlacement` too, so the window is created at the saved
    /// frame directly instead of being resized a moment after appearing (which produced a
    /// visible flash-then-jump). See `saveMainWindowFrame` for why this is hand-rolled instead
    /// of AppKit's frame autosave APIs.
    static let mainWindowFrameDefaultsKey = "com.kerim.final-final.mainWindowFrame"

    /// Whether the main window was in native full screen when last saved. Tracked separately
    /// from the frame itself: entering full screen resizes the window to the screen's bounds,
    /// which is not a real "windowed" frame to restore into — restoring just that rect would
    /// produce a maximized *window*, not true full screen (no dedicated Space, menu bar/Dock
    /// still present). See `windowDidEnterFullScreen`/`windowDidExitFullScreen`.
    private static let mainWindowWasFullScreenDefaultsKey = "com.kerim.final-final.mainWindowWasFullScreen"

    /// NSEvent monitor for Esc key to exit focus mode (works even when WKWebView has focus)
    private var escapeKeyMonitor: Any?

    /// Whether applicationShouldTerminate already flushed content (prevents redundant flush in applicationWillTerminate)
    private var didFlushForQuit = false

    /// Coalesces window-frame writes across a resize/move gesture's many per-tick notifications
    /// down to a single pending value. See `WindowFrameCoalescer` and `scheduleFrameFlush()`.
    /// Not private: read/written from `AppDelegate+WindowFramePersistence.swift`, and Swift's
    /// `private` is file-scoped.
    var frameCoalescer = WindowFrameCoalescer()

    /// Debounce timer for flushing the coalesced window frame to UserDefaults. See
    /// `scheduleFrameFlush()` for why it deliberately stays off `.common` run loop mode.
    /// Not private: read/written from `AppDelegate+WindowFramePersistence.swift`, and Swift's
    /// `private` is file-scoped.
    var frameFlushTimer: Timer?

    /// URL passed by Finder double-click; consumed by determineInitialState()
    var finderOpenURL: URL?

    /// Bare AppKit frame-autosave name captured off the main window BEFORE
    /// `disableFrameAutosave` clears it. Read by the one-time dead-key sweep in
    /// `AppDelegate+AutosaveKeyTracking.swift` to build its protected-name set. Not private:
    /// read/written from that extension file, and Swift's `private` is file-scoped.
    var capturedWindowFrameAutosaveName: String?

    /// Guards `scheduleAutosaveKeySweep()` against scheduling more than once — it's called from
    /// both places `disableFrameAutosave` is (the normal launch path and the FB15577018 recovery
    /// fallback). Not private: read/written from `AppDelegate+AutosaveKeyTracking.swift`.
    var autosaveKeySweepScheduled = false

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

        // Debug builds tint the Dock icon and label their windows with the
        // worktree (or branch) they came from — see DevBuildBadge.swift.
        #if DEBUG
            DevBuildBadge.install()
        #endif

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
                    await ExportOperations.handleExport(format: format)
                }
            }
        }

        // Handle print notifications (same reasoning as export above: AppDelegate
        // always exists, so Print menu items work even with zero windows)
        NotificationCenter.default.addObserver(
            forName: .printFormatted, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await PrintOperations.handlePrintFormatted()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .printRawMarkdown, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await PrintOperations.handlePrintRawMarkdown()
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
                self?.captureMainWindow(window)
                let savedFrame = UserDefaults.standard.string(forKey: Self.mainWindowFrameDefaultsKey) ?? "nil"
                DebugLog.log(
                    .lifecycle,
                    "[AppDelegate] Set window delegate for Cmd-W interception; "
                        + "actual frame at launch=\(window.frame), saved frame=\(savedFrame)"
                )

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
                            // See captureMainWindow's doc comment for what this covers and why.
                            self?.captureMainWindow(window)
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

    /// Re-enters true full screen (not just a maximized window) if that's how the main window
    /// was left at last quit. No-op otherwise, and on first launch (nothing saved yet).
    ///
    /// The windowed frame itself is restored earlier, at window *creation*, via
    /// `.defaultWindowPlacement` in `FinalFinalApp.swift` — full screen has no WindowPlacement
    /// equivalent, so that part still has to happen here, once the window exists.
    ///
    /// Frame persistence is hand-rolled UserDefaults read/write (`NSStringFromRect`/
    /// `NSRectFromString`) rather than AppKit's `NSWindow.setFrameAutosaveName`/
    /// `saveFrame(usingName:)`: a diagnostic-log-verified investigation (see
    /// `saveMainWindowFrame`) found that mechanism's UserDefaults write never actually lands for
    /// this window — even an in-process readback immediately after the call returns nil — most
    /// likely because `windowShouldClose` unconditionally returns `false` here (Cmd-W is
    /// intercepted to show the project picker instead of closing), and AppKit's autosave commit
    /// appears to be tied to the window actually closing, which never happens.
    ///
    /// Not `private` -- called from `captureMainWindow` in
    /// `AppDelegate+WindowFramePersistence.swift`, a sibling-file extension.
    func restoreFullScreenIfNeeded(_ window: NSWindow) {
        // Tests run against the same bundle ID as the real app (see TestMode.clearTestState()),
        // so restoring/saving here would let test runs clobber the user's real saved state.
        guard !TestMode.isTesting else { return }
        guard UserDefaults.standard.bool(forKey: Self.mainWindowWasFullScreenDefaultsKey),
              !window.styleMask.contains(.fullScreen) else { return }

        DebugLog.log(.lifecycle, "[AppDelegate] Restoring full screen")
        FullScreenManager.request(.fullScreen)
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

            // Exit focus mode. This monitor closure already runs on the main actor (its
            // enclosing class is @MainActor and NSEvent.addLocalMonitorForEvents's handler
            // parameter isn't @Sendable, so Swift infers the closure's isolation from context)
            // and exitFocusMode() is synchronous, so call it directly. Deferring via Task here
            // used to let a rapid next keystroke's synchronous toggleFocusMode() run BEFORE
            // this exit actually applied, ordering the two by main-queue scheduling instead of
            // by keypress order.
            editorState.exitFocusMode()

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

            await editorState.flushAllSync()

            // Create final auto-backup with timeout to avoid blocking termination
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.autoBackupService?.appWillQuit() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                _ = await group.next()
                group.cancelAll()
            }

            self.didFlushForQuit = true
            self.removeEscapeKeyMonitor()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log(.lifecycle, "[AppDelegate] Application terminating")

        // Unconditional and NOT gated on didFlushForQuit: that flag only tracks whether editor
        // content was already flushed by applicationShouldTerminate, and has no bearing on
        // whether a coalesced window-frame write is pending. It also isn't reliably set --
        // applicationShouldTerminate returns .terminateNow early, without ever setting it, when
        // there's no editorState or its content is empty (see above). So the frame flush has to
        // sit outside and independent of that gate, and run on every termination path, not just
        // the ones that happen to set didFlushForQuit.
        flushWindowFrame(trigger: "terminate")

        // Only flush if applicationShouldTerminate didn't already (safety net for force-quit)
        if !didFlushForQuit {
            editorState?.flushAllSyncCore()   // guaranteed synchronous — identical to today's behavior
            if let editorState {
                Task { @MainActor in
                    await editorState.flushPendingBibliographyAndFootnoteSync()   // best-effort only
                }
            }
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
        DebugLog.always(
            "[FINDER-OPEN] hasOpenProject=\(DocumentManager.shared.hasOpenProject) "
                + "hasCompletedInitialOpen=\(DocumentManager.shared.hasCompletedInitialOpen)"
        )

        // AppKit spawns an extra WindowGroup window for this event (see
        // closeSpuriousFinderOpenWindows's doc comment) — clean it up regardless of which
        // branch below fires. No-ops safely if mainWindow isn't captured yet.
        //
        // The immediate call catches it when AppKit's spurious window already exists by now
        // (the common case for a launch-time open, and for a later event cleaning up an
        // EARLIER event's straggler). But CONFIRMED via repeated `open`-while-running probes
        // (CGWindowList, onscreen=true persisting for seconds): AppKit does NOT reliably create
        // THIS event's own spurious window before this line runs — sometimes it materializes a
        // moment later, and for a request that returns early with no further work (e.g.
        // openProjectFromFinder's "same project already open" no-op below), nothing else ever
        // gets a second chance to sweep it. The staggered delayed re-sweeps below close that gap.
        // A single 0.5s retry was empirically sufficient in 5/5 repeated trials (including 3
        // rapid-fire same-project reopens) against the exact regression this fixes, but one
        // earlier trial (same code path, before this was instrumented to confirm why) still left
        // a visible duplicate past 4s with only that one retry -- unexplained, and not
        // reproduced since. Three staggered retries, not one, is deliberate insurance against
        // whatever that was: each is an idempotent no-op if there's nothing left to close (see
        // closeSpuriousFinderOpenWindows's doc comment), so the extra calls cost nothing when the
        // first retry already worked.
        DebugLog.log(.lifecycle, "[FINDER-OPEN][DIAG] immediate sweep")
        closeSpuriousFinderOpenWindows()
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                DebugLog.log(.lifecycle, "[FINDER-OPEN][DIAG] delayed sweep fired (scheduled +\(delay)s)")
                self?.closeSpuriousFinderOpenWindows()
            }
        }

        // If app is still launching (no project open yet), stash URL for
        // determineInitialState() to consume — avoids race where
        // restoreLastProject() overwrites Finder intent.
        if !DocumentManager.shared.hasCompletedInitialOpen {
            DebugLog.always("[FINDER-OPEN] Stashing URL for launch (no project open yet)")
            finderOpenURL = url
            return
        }

        if !DocumentManager.shared.hasOpenProject {
            // Launch already completed and no project is open (picker showing) —
            // open directly. There's no editor content to flush.
            DebugLog.always("[FINDER-OPEN] App running with no project open, opening directly")
            openProjectFromFinder(at: url)
            return
        }

        // App already running with a project open — flush pending editor content, then open
        DebugLog.always("[FINDER-OPEN] App running with project, flushing and opening")
        editorState?.flushContentToDatabase()
        openProjectFromFinder(at: url)
    }

    // closeSpuriousFinderOpenWindows() lives in AppDelegate+WindowFramePersistence.swift,
    // next to captureMainWindow (its main caller) -- moved there to keep this class's body
    // under SwiftLint's type_body_length limit.

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
        } catch {
            // openProject() validates before closing, so current project is preserved.
            // Record the failure for the always-mounted host to render; no modal runs
            // here, so this can never race with (or be dropped by) a state change.
            DebugLog.log(.lifecycle, "[AppDelegate] Failed to open from Finder: \(error)")
            ProjectOpenErrorState.shared.report(error, url: url)
        }
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

    /// Retries `SplitViewAutosaveNaming.stabilize(for:)` on every key-becomes event for the main
    /// window, until it succeeds. The first attempt (at window-capture time, alongside
    /// `disableFrameAutosave`) runs while `appViewState` is still `.loading` — before
    /// `NavigationSplitView` is anywhere in the view hierarchy — so it reliably finds zero split
    /// views and no-ops. `windowDidBecomeKey` fires again once editor content has loaded and the
    /// user is actually interacting with the window, by which point the split view exists. Once
    /// stabilization has taken effect (current name already equals `stableName`), this is a
    /// cheap no-op read on every subsequent call.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !TestMode.isTesting else { return }
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        guard SplitViewAutosaveNaming.currentTopLevelAutosaveName(in: window) != SplitViewAutosaveNaming.stableName else { return }
        SplitViewAutosaveNaming.stabilize(for: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // Force macOS to switch to this window's fullscreen Space.
        // Without this, programmatic fullscreen (e.g., focus mode restoration on launch)
        // creates the Space but doesn't switch to it.
        if let window = notification.object as? NSWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()

        if !TestMode.isTesting, (notification.object as? NSWindow) === mainWindow {
            UserDefaults.standard.set(true, forKey: Self.mainWindowWasFullScreenDefaultsKey)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if !TestMode.isTesting, (notification.object as? NSWindow) === mainWindow {
            UserDefaults.standard.set(false, forKey: Self.mainWindowWasFullScreenDefaultsKey)
        }
    }

    /// No `did*` notification follows a failed transition, so without this FullScreenManager's
    /// watchdog would eventually fire and resync toward the wrong side (it trusts an unconfirmed
    /// transition probably succeeded) — see `FullScreenManager.notifyTransitionFailed()`.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        FullScreenManager.notifyTransitionFailed()
    }

    /// See `windowDidFailToEnterFullScreen(_:)`.
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        FullScreenManager.notifyTransitionFailed()
    }

    // Resize/move persistence, the debounced flush, and applicationDidResignActive's flush
    // trigger live in AppDelegate+WindowFramePersistence.swift.
}
