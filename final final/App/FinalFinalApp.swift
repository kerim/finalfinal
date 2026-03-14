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
    @State private var appViewState: AppViewState = .loading

    private var documentManager: DocumentManager { DocumentManager.shared }

    var body: some Scene {
        WindowGroup {
            Group {
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
            .environment(ThemeManager.shared)
            .environment(GoalColorSettingsManager.shared)
            .environment(versionHistoryCoordinator)
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
            }
        }
        .commands {
            FileCommands()
            ViewCommands()
            EditorCommands()
            HelpCommands(onGettingStarted: {
                // Post notification to handle in view hierarchy
                NotificationCenter.default.post(name: .openGettingStarted, object: nil)
            })
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

        // Test mode: skip normal flow, open fixture directly
        if TestMode.isUITesting {
            TestMode.clearTestState()
            if let fixturePath = TestMode.testFixturePath {
                let url = URL(fileURLWithPath: fixturePath)
                do {
                    try documentManager.openProject(at: url)
                    appViewState = .editor
                } catch {
                    DebugLog.log(.lifecycle, "[TestMode] Failed to open fixture: \(error)")
                    appViewState = .picker
                }
            } else {
                appViewState = .picker
            }
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
                DebugLog.log(.lifecycle, "[FinalFinalApp] Failed to open Finder URL: \(error)")
                // Fall through to normal flow (picker).
                // Cannot show NSAlert here — runModal() deadlocks inside .task async context.
                // User will see the picker and can try opening the file from there,
                // which goes through FileOperations with proper error handling.
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
