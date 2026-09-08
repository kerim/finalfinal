//
//  FinalFinalApp.swift
//  final final
//

import SwiftUI

/// App state for tracking what view to show
enum AppViewState {
    case loading
    case picker
    case editor
    case gettingStarted
}

@main
struct FinalFinalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var versionHistoryCoordinator = VersionHistoryCoordinator()
    @State private var sparkleUpdater = SparkleUpdater()
    @State private var appViewState: AppViewState = .loading

    private var documentManager: DocumentManager { DocumentManager.shared }

    /// Root view for the main window, switched on app state.
    /// Extracted from body to keep type-checking fast.
    @ViewBuilder
    private var rootView: some View {
        switch appViewState {
        case .loading:
            loadingView
        case .picker:
            ProjectPickerView(
                onProjectOpened: {
                    appViewState = .editor
                },
                onGettingStartedRequested: {
                    openGettingStarted()
                }
            )
        case .editor:
            ContentView(
                onProjectClosed: {
                    documentManager.closeProject()
                    appViewState = .picker
                }
            )
        case .gettingStarted:
            ContentView(
                onProjectClosed: {
                    // After closing Getting Started, show picker
                    documentManager.closeProject()
                    appViewState = .picker
                }
            )
        }
    }

    var body: some Scene {
        WindowGroup(id: SceneID.mainWindow) {
            rootView
            .environment(ThemeManager.shared)
            .environment(GoalColorSettingsManager.shared)
            .environment(versionHistoryCoordinator)
            // Placement relative to the .environment(...) calls above does NOT
            // matter for correctness: ProjectOpenErrorHost.swift injects
            // .environment(ThemeManager.shared) directly on the sheet's presented
            // content (IntegrityAlertView reads @Environment(ThemeManager.self)),
            // rather than relying on modifier-chain ordering here -- which would
            // silently break again if this chain were ever reordered.
            .projectOpenErrorHost()
            .task {
                await determineInitialState()
            }
            // Listen for project lifecycle notifications to sync state
            .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { _ in
                handleProjectOpened()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidCreate)) { _ in
                handleProjectOpened()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidClose)) { _ in
                handleProjectClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGettingStarted)) { _ in
                openGettingStarted()
            }
            // Listen for command notifications (from menu)
            // Note: .newProject and .openProject are handled by AppDelegate only
            // to avoid duplicate panel creation that prevents dismissal
            .onReceive(NotificationCenter.default.publisher(for: .closeProject)) { _ in
                FileOperations.handleCloseProject()
            }
            .background { OpenExportPreferencesListener() }
            .onChange(of: appViewState) { oldState, newState in
                DebugLog.log(.lifecycle, "[FinalFinalApp] State changed: \(oldState) -> \(newState)")
                // Bug report (2026-09-06): the Outline sidebar's saved divider position didn't
                // restore on project reopen, only after switching to a different app and back.
                // Root cause -- AppDelegate.windowDidBecomeKey's own doc comment already
                // documents the assumption this breaks: SplitViewAutosaveNaming.stabilize(for:)
                // is retried "on every key-becomes event for the main window", relying on
                // "windowDidBecomeKey fires again once editor content has loaded". That holds
                // for the FIRST project of an app launch (the window becomes key once during
                // launch), but reopening a project swaps `.editor`/`.picker` content inside the
                // SAME already-key window (see the UX contract's "no second document window"
                // rule) -- no new becomeKey event ever fires, so the retry this relies on never
                // gets a second chance. `.editor`/`.gettingStarted` are exactly the states whose
                // `rootView` case constructs a fresh ContentView -- and therefore a fresh
                // NavigationSplitView/NSSplitView -- from scratch, so retry stabilization here
                // too, the same guarded way windowDidBecomeKey already does.
                //
                // Deferred one tick (DispatchQueue.main.async): the same technique AppDelegate's
                // own first `captureMainWindow` call already uses ("Use async to allow SwiftUI to
                // create the window first") -- `.onChange` fires as part of the SwiftUI render
                // pass that computes the new `rootView`, before that pass's resulting view diff
                // has actually been committed into `window.contentView`'s AppKit subview tree, so
                // stabilize(for:) would otherwise still find zero split views, same as the
                // original too-early call this is patterned on.
                if newState == .editor || newState == .gettingStarted {
                    DispatchQueue.main.async {
                        guard !TestMode.isTesting, let window = AppDelegate.shared?.mainWindow else { return }
                        guard SplitViewAutosaveNaming.currentTopLevelAutosaveName(in: window)
                                != SplitViewAutosaveNaming.stableName else { return }
                        SplitViewAutosaveNaming.stabilize(for: window)
                    }
                }
            }
        }
        .defaultWindowPlacement { _, context in
            // Restore the last-saved windowed frame directly into the window's initial
            // placement, rather than creating it at the default size/position and resizing
            // a moment later — the latter produced a visible flash-then-jump on launch.
            // WindowPlacement's position is top-left-based (Y measured down from the screen
            // top), while the saved frame is `window.frame` — AppKit's native bottom-left
            // convention (Y measured up from the screen bottom). Verified empirically via
            // diagnostic logging: passing the saved origin straight through restored X and
            // the window's size correctly but silently flipped Y. Converting requires the
            // *primary* screen's height, since that's what anchors AppKit's global coordinate
            // space (the screen whose origin is (0, 0), not necessarily `.screens.first`).
            if !TestMode.isTesting,
               let savedFrame = WindowFrameStore.load(),
               let primaryScreenHeight = (NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first)?.frame.height {
                if NSScreen.screens.contains(where: { $0.frame.intersects(savedFrame) }) {
                    let flippedY = primaryScreenHeight - savedFrame.origin.y - savedFrame.height
                    return WindowPlacement(CGPoint(x: savedFrame.origin.x, y: flippedY), size: savedFrame.size)
                }
            }

            // Target: usable area of a 13-inch laptop. On smaller displays the
            // min() clamps this to the visible area so the window fills the screen;
            // on larger displays it stays "13-inch sized" regardless of screen size.
            let target = CGSize(width: 1400, height: 900)
            let visible = context.defaultDisplay.visibleRect
            let size = CGSize(
                width: min(target.width, visible.width),
                height: min(target.height, visible.height)
            )
            let origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            return WindowPlacement(origin, size: size)
        }
        .commands {
            FileCommands()
            UndoRedoCommands()
            ViewCommands()
            EditorCommands()
            HelpCommands(
                onGettingStarted: {
                    // Post notification to handle in view hierarchy
                    NotificationCenter.default.post(name: .openGettingStarted, object: nil)
                },
                sparkleUpdater: sparkleUpdater
            )
        }
        // Preferences window
        Settings {
            PreferencesView()
                .environment(ThemeManager.shared)
                .environment(GoalColorSettingsManager.shared)
        }

        Window("Version History", id: "version-history") {
            VersionHistoryWindow()
                .environment(ThemeManager.shared)
                .environment(GoalColorSettingsManager.shared)
                .environment(versionHistoryCoordinator)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.suppressed)
    }

    /// Simple loading view while determining initial state
    @ViewBuilder
    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("loading-view")
    }

    /// Determine the initial app state on launch
    @MainActor
    private func determineInitialState() async {
        guard !documentManager.hasCompletedInitialOpen else { return }
        defer { documentManager.hasCompletedInitialOpen = true }

        // UI test mode: skip normal flow, open fixture directly
        if TestMode.isUITesting {
            TestMode.clearTestState(preservingLastProjectBookmark: TestMode.shouldExerciseRestoreLastProject)
            if let fixturePath = TestMode.testFixturePath {
                let url = URL(fileURLWithPath: fixturePath)
                do {
                    try documentManager.openProject(at: url)
                    appViewState = .editor
                } catch {
                    DebugLog.log(.lifecycle, "[TestMode] Failed to open fixture: \(error)")
                    appViewState = .picker
                }
            } else if TestMode.shouldExerciseRestoreLastProject {
                // Exercises the real cold-launch restore path -- see
                // TestMode.shouldExerciseRestoreLastProject's doc comment.
                do {
                    if try documentManager.restoreLastProject() {
                        appViewState = .editor
                        return
                    }
                } catch {
                    DebugLog.log(.lifecycle, "[TestMode] Failed to restore last project during test: \(error)")
                }
                appViewState = .picker
            } else {
                appViewState = .picker
            }
            return
        }

        // Unit test mode: skip normal flow (no project restoration, no Getting Started).
        // clearTestState() is intentionally not called on this path — not for the old safety
        // reason (unit tests no longer share the real UserDefaults.standard domain;
        // clearTestState() now targets the isolated AppDefaults.store while any kind of test
        // is running, see AppDefaults.swift), but because this path has no leftover test
        // state to clear before showing the picker.
        if TestMode.isUnitTesting {
            appViewState = .picker
            return
        }

        // Check if Finder launched us with a specific file
        if let url = AppDelegate.shared?.finderOpenURL {
            AppDelegate.shared?.finderOpenURL = nil
            do {
                try documentManager.openProject(at: url)
                appViewState = .editor
                return
            } catch {
                ProjectOpenErrorState.shared.report(error, url: url)
                // Fall through to the normal flow: your previous session still opens
                // (or Getting Started, or the picker), and the always-mounted host
                // above this state switch shows the failure over whatever we land on.
                // No modal runs on this path -- the failure is recorded as SwiftUI
                // state, not announced via NSAlert.runModal(), which would deadlock
                // inside this .task's async context.
            }
        }

        // Check if Getting Started should be shown (first launch or version update)
        if documentManager.shouldShowGettingStarted {
            documentManager.markGettingStartedSeen()
            openGettingStarted()
            return
        }

        // Try to restore last project
        do {
            if try documentManager.restoreLastProject() {
                appViewState = .editor
                return
            }
        } catch {
            DebugLog.log(.lifecycle, "[FinalFinalApp] Failed to restore last project: \(error)")
        }

        // Show project picker
        appViewState = .picker
    }

    /// Handle project opened notification - sync state
    @MainActor
    private func handleProjectOpened() {
        guard documentManager.hasOpenProject else { return }
        // Deliberately does NOT clear ProjectOpenErrorState.shared.pending here.
        // .projectDidOpen fires for every successful open -- including ones
        // completely unrelated to any currently-shown failure (e.g. a Version
        // History snapshot restore) -- so clearing it unconditionally would
        // silently dismiss a fresh, unseen error notice as a side effect of an
        // unrelated action. Persisting an unacknowledged error until the user
        // actually addresses it (Cancel/OK, or a Repair/Open Anyway that resolves
        // THIS failure -- see ProjectOpenErrorHost's own explicit clear() calls)
        // is the intended design.
        if documentManager.isGettingStartedProject {
            appViewState = .gettingStarted
        } else {
            appViewState = .editor
        }
        DebugLog.log(.lifecycle, "[FinalFinalApp] Project opened, state: \(appViewState)")
    }

    /// Handle project closed notification - show picker
    @MainActor
    private func handleProjectClosed() {
        DebugLog.log(.lifecycle, "[FinalFinalApp] handleProjectClosed() called, hasOpenProject: \(documentManager.hasOpenProject)")
        // Only update state if no project is open
        // (avoids race conditions when switching projects)
        guard !documentManager.hasOpenProject else {
            DebugLog.log(.lifecycle, "[FinalFinalApp] handleProjectClosed() - skipping because hasOpenProject=true")
            return
        }
        appViewState = .picker
    }

    /// Open the Getting Started project
    @MainActor
    private func openGettingStarted() {
        // Close any existing project first
        if documentManager.hasOpenProject {
            documentManager.closeProject()
        }

        do {
            try documentManager.openGettingStarted()
            appViewState = .gettingStarted
        } catch {
            DebugLog.log(.lifecycle, "[FinalFinalApp] Failed to open Getting Started: \(error)")
            // Fall back to picker on error
            appViewState = .picker
        }
    }
}

// MARK: - Open Export Preferences Helper

/// Invisible view that opens the Settings window when .showExportPreferences is posted.
/// Uses @Environment(\.openSettings) — the official SwiftUI API (macOS 14+).
private struct OpenExportPreferencesListener: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showExportPreferences)) { _ in
                openSettings()
                // Ensure the Settings window comes to front (e.g. when main window is fullscreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate()
                }
            }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to open Getting Started (from Help menu)
    static let openGettingStarted = Notification.Name("openGettingStarted")
}
