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

    /// Identity of the last Escape keydown this monitor accepted as a genuine new candidate
    /// (see `EscapeLadder.shouldConsiderCandidate`'s doc comment). WebKit re-sends the same
    /// physical NSEvent through `[NSApp sendEvent:]` when it comes back from the web layer
    /// unhandled -- which re-runs this monitor a second time for one physical keypress, with
    /// `isARepeat` still false -- so this is compared against the incoming event's own stamp to
    /// catch that resend and reject it as a duplicate.
    private var lastEscapeStamp: EscapeLadder.EscapeEventStamp?

    /// Monotonic counter, incremented once per Escape keydown this monitor is asked to consider
    /// (before the dedup/repeat guard), purely to correlate this event's several diagnostic log
    /// lines together and to let a captured log show how many times the monitor fired for one
    /// physical keypress. Diagnostic only -- not read by any decision logic.
    private var escapeEventOrdinal: UInt64 = 0

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
        // Hermetic UI-test launches: wipe the ENTIRE persistent defaults domain, not a
        // hand-maintained key list. `TestMode.clearTestState()` clears nine known keys in
        // the isolated `AppDefaults.store` suite, but everything else the app persists —
        // window frame and fullscreen state, spelling/grammar/smart-quotes toggles,
        // proofing settings, @AppStorage keys — goes straight to `UserDefaults.standard`
        // and survives from one UI test's launch to the next. That leftover state is the
        // suite-order pollution class behind "fails in the full suite, passes solo"
        // (three of the four quarantines in scripts/vmtest/known-flaky.txt cite it).
        // Safe to wipe wholesale: test builds run under the separate
        // `com.kerim.final-final.testhost` bundle identity (project.yml, DebugTest
        // config), so this never touches the real app's domain, on the VM or a host.
        // The suite domain is wiped too — clearTestState()'s nine-key list stays for
        // in-process unit-test resets, where a whole-domain wipe could clobber state
        // other concurrently-running unit tests rely on.
        // (Read-before-write ordering is deliberate: the emptiness check avoids the
        // write-then-read cfprefsd re-merge stall documented at
        // AppDelegate+WindowFramePersistence.flushWindowFrame when nothing needs wiping.)
        if TestMode.isUITesting, let bundleID = Bundle.main.bundleIdentifier {
            let standardDomain = UserDefaults.standard.persistentDomain(forName: bundleID)
            if let standardDomain, !standardDomain.isEmpty {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
                DebugLog.log(.lifecycle,
                    "[AppDelegate] UI test mode: wiped \(standardDomain.count) persisted default(s) from \(bundleID)")
            }
            AppDefaults.wipeTestDomainForUITesting()
        }

        // Snapshot which split-view divider positions a PREVIOUS session saved. It has to be taken
        // here, before any window exists: once the split view lays out, AppKit writes its own
        // autosave key, and a snapshot taken any later can read THIS launch's write and wrongly
        // suppress the Outline sidebar's 300pt launch width (bt t-218cac62). A UI-test launch has
        // just wiped the domain, so it captures the empty set without reading it back.
        SplitViewAutosaveNaming.captureLaunchSplitViewFrameKeys(fromDomainNamed: Bundle.main.bundleIdentifier, domainWasWiped: TestMode.isUITesting)

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

    /// Set up NSEvent local monitor for the Esc-key layer ladder (UX contract §6): "where
    /// you're typing wins" first, then a fixed native ladder -- find bar, most-recently-opened
    /// annotation edit, Focus Mode. See `EscapeLadder.swift` for the pure decision logic and
    /// `EscapeLadderContext`/`EscapeLadderRegistry` for how a window's live state reaches here.
    private func setupEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NOT `self?.handleEscapeCandidate(event) ?? event`: optional chaining flattens a
            // nil RESULT (a legitimate "consume this event") down to the same `nil` produced
            // when `self` itself is nil, which `?? event` would then wrongly turn back into
            // "pass through" -- collapsing every consumed Esc into a pass-through. Unwrap
            // `self` first so a genuine nil return from `handleEscapeCandidate` stays nil.
            guard let self else { return event }
            return self.handleEscapeCandidate(event)
        }
    }

    /// Body of the Esc monitor, split out for readability. Returns the event to pass it
    /// through untouched, or nil to consume it.
    private func handleEscapeCandidate(_ event: NSEvent) -> NSEvent? {
        // keyCode 53 = Esc. Bail fast on every other key before touching anything else -- and
        // before the ordinal/stamp bookkeeping below, which is scoped to Escape only.
        guard event.keyCode == 53 else { return event }

        escapeEventOrdinal += 1
        let ordinal = escapeEventOrdinal
        DebugLog.log(
            .escape,
            "[Escape#\(ordinal)] keydown timestamp=\(event.timestamp) isARepeat=\(event.isARepeat) windowNumber=\(event.windowNumber)"
        )

        // Auto-repeat guard, now extended with physical-event-identity dedup (see
        // EscapeLadder.shouldConsiderCandidate's doc comment for why both are needed: WebKit
        // re-sends the very same NSEvent through [NSApp sendEvent:] when Escape comes back
        // unhandled from the web layer, which re-runs this monitor a second time for one
        // physical keypress with isARepeat still false). Placed before both the registry lookup
        // and the isComposing check below so it covers the web-focused pass-through branch too.
        // CRITICAL: a rejected duplicate must still pass the event through (`return event`),
        // never consume it -- consuming a resent event breaks the responder chain for anything
        // else listening (Version History's own window-level Escape handling, or any other
        // legitimate native listener).
        let stamp = EscapeLadder.EscapeEventStamp(timestamp: event.timestamp, windowNumber: event.windowNumber)
        guard EscapeLadder.shouldConsiderCandidate(isRepeat: event.isARepeat, stamp: stamp, lastStamp: lastEscapeStamp) else {
            return event
        }
        lastEscapeStamp = stamp

        // No registered window, no registered ladder context, or a stale/recycled registry
        // entry (compared as non-optional references -- not the old nil-equality bug) all
        // pass the event through untouched. This is what keeps Version History, Settings, any
        // sheet, any NSAlert.runModal(), and any native .popover's own transient window fully
        // out of this monitor's reach -- they keep their own existing Esc handling untouched.
        guard let win = event.window,
              let ctx = EscapeLadderRegistry.shared.context(for: win),
              ctx.window === win else {
            return event
        }

        // IME/composition guard (must run before any ladder/watchdog logic): some IMEs swallow
        // the Escape keydown that dismisses composition before it ever reaches the document, so
        // this is a positive signal pushed from the web side (compositionstart/compositionend),
        // never inferred from the absence of a report.
        guard !ctx.isComposing else { return event }

        let isWebFocused = focusIsInWebView(ctx)
        if isWebFocused {
            // t-784ff3aa fix round: `ctx.webPopupOpen` is pushed synchronously by the web layer
            // the instant a popup opens or closes (EscapeLadderContext.webPopupOpen), well
            // before any Escape keypress -- so by this point Swift already knows, with zero
            // round trip, whether the web layer will handle this Escape. Timing at
            // Escape-keydown time can no longer affect which branch runs.
            if ctx.webPopupOpen {
                // A web-owned popup is open right now -- don't consume the event; let WebKit
                // see the key. Arm ONLY a long last-resort hang-protection watchdog (see
                // `armEscapeWatchdog`'s doc comment) for the pathological case where the web
                // layer's JS thread is genuinely stuck and never reports back at all -- this is
                // NOT what makes the common case correct, only a safety net for an already-broken
                // one; correctness comes entirely from `webPopupOpen` having been true here.
                DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=true webPopupOpen=true rung=webOwned (arming hang-protection watchdog)")
                ctx.armEscapeWatchdog { [weak self] in
                    self?.applyWebDeclinedFallback(ctx)
                }
                return event
            }
            // No web-owned popup is open right now -- also a synchronously pushed fact, not an
            // inference from an Escape-time report -- so there is nothing to wait for: skip the
            // round trip and the watchdog entirely, and apply the native ladder immediately,
            // consuming the event. Reuses `applyWebDeclinedFallback` (rather than duplicating
            // its snapshot-build-and-apply logic here) so this immediate-apply site and the
            // watchdog-fires/web-declined-report call sites can never drift apart.
            DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=true webPopupOpen=false applying native ladder immediately")
            applyWebDeclinedFallback(ctx)
            return nil
        }

        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: ctx.findBarState?.isVisible ?? false,
            findBarFieldFocused: ctx.findBarFieldFocused,
            annotationEditIds: ctx.annotationEditOrder,
            focusedAnnotationEditId: ctx.focusedAnnotationEditId,
            focusModeEnabled: ctx.editorState?.focusModeEnabled ?? false
        )
        let rung = EscapeLadder.decide(snapshot)
        DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=false rung=\(rung)")
        guard rung != .none else { return event }  // Never a "consumed no-op".
        apply(rung, to: ctx)
        return nil
    }

    /// Walks up from the window's first responder looking for `ctx.activeWebView`. Returns
    /// false (not true-by-default) if there's no active web view or the first responder isn't
    /// an NSView -- `firstResponder` is `NSResponder`, not always `NSView`, so the `as? NSView`
    /// guard is load-bearing; do not force-cast it away.
    private func focusIsInWebView(_ ctx: EscapeLadderContext) -> Bool {
        guard let web = ctx.activeWebView, let first = ctx.window?.firstResponder as? NSView else { return false }
        var node: NSView? = first
        while let currentNode = node {
            if currentNode === web { return true }
            node = currentNode.superview
        }
        return false
    }

    /// Applies the native ladder starting at the find bar (skipping `.webOwned`, which no
    /// longer applies). Three call sites, all equally valid, none more "authoritative" than the
    /// others (t-784ff3aa fix round):
    ///   1. `handleEscapeCandidate`'s `isWebFocused` branch, immediately and synchronously, when
    ///      `ctx.webPopupOpen` is false -- the common case now that nothing web-owned needs to
    ///      be waited on. This is the call site that matters day to day.
    ///   2. The `escapeLadder` message handler (`handleEscapeLadderMessage`,
    ///      `EscapeLadder.swift`), when the web side's own report arrives with `handled == false`
    ///      -- the web layer had something open (`webPopupOpen` was true) but declined to act on
    ///      this specific Escape (e.g. `dismissTopLayer` found nothing left to close).
    ///   3. The hang-protection watchdog firing (`armEscapeWatchdog`'s fallback closure) -- only
    ///      reached if the web layer never reports back at all despite `webPopupOpen` being true;
    ///      a last resort for an already-pathological case, not a timing race with (1) or (2).
    /// Not private: called from both editors' `+MessageDispatch.swift` for site 2 above.
    func applyWebDeclinedFallback(_ ctx: EscapeLadderContext) {
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: ctx.findBarState?.isVisible ?? false,
            findBarFieldFocused: ctx.findBarFieldFocused,
            annotationEditIds: ctx.annotationEditOrder,
            focusedAnnotationEditId: ctx.focusedAnnotationEditId,
            focusModeEnabled: ctx.editorState?.focusModeEnabled ?? false
        )
        let rung = EscapeLadder.decideAfterWebDeclined(snapshot)
        apply(rung, to: ctx)
    }

    /// Applies a decided rung's native action. `.webOwned` and `.none` are no-ops here --
    /// `.webOwned` is handled by simply not consuming the event (see `handleEscapeCandidate`),
    /// and `.none` never reaches this function (guarded above / never produced meaningfully by
    /// the after-web-declined ladder needing a native action).
    private func apply(_ rung: EscapeRung, to ctx: EscapeLadderContext) {
        DebugLog.log(.escape, "[Escape] apply rung=\(rung)")
        switch rung {
        case .webOwned, .none:
            break
        case .findBar:
            ctx.findBarState?.hide()
        case .annotationEdit(let id):
            ctx.cancelAnnotationEdit(id: id)
        case .focusMode:
            // Synchronous, same reasoning as the previous implementation: this closure already
            // runs on the main actor, and calling directly (not deferring via Task) keeps a
            // rapid next keystroke ordered correctly behind this exit.
            ctx.editorState?.exitFocusMode()
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
    /// `disableFrameAutosave`) runs while `appViewState` is still `.loading` — before the
    /// window's `HSplitView` is anywhere in the view hierarchy (this said
    /// `NavigationSplitView` before the Outline sidebar's container swap) — so it reliably finds
    /// zero split views and no-ops. `windowDidBecomeKey` fires again once editor content has
    /// loaded and the user is actually interacting with the window, by which point the split view
    /// exists. Once
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

        // Resync Focus Mode's own flag with reality whenever the window has genuinely left full
        // screen (t-784ff3aa fix round, defense in depth). Before Fix 1 (escape-ladder.ts's
        // preventDefault()), the window could leave native full screen via a path that never
        // went through this app's own `exitFocusMode()` -- WebKit's default Escape handling
        // reaching AppKit directly, bypassing Swift's Focus Mode logic entirely -- leaving
        // `focusModeEnabled` stuck at `true` after the window was already windowed. The NEXT
        // Focus Mode toggle would then read that stale `true` and run `exitFocusMode()` instead
        // of `enterFocusMode()`, which is why the annotation/right sidebar failed to hide on
        // what the user experienced as "entering" Focus Mode. Safe to call unconditionally on
        // EVERY full-screen exit, not just an unexpected one: `exitFocusMode()` guards itself
        // with `guard focusModeEnabled else { return }`, so on the normal path -- where this
        // app's own `exitFocusMode()` already ran synchronously and set the flag false before
        // AppKit's asynchronous full-screen-exit animation even finishes -- this call is a
        // no-op; it only does real work on the leaked/unexpected case this fix targets (green
        // button, Ctrl+Cmd+F, Mission Control, or any future leak of this same class).
        editorState?.exitFocusMode()
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
