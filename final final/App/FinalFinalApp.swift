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
            .environment(versionHistoryCoordinator)
            .task {
                await determineInitialState()
            }
            // Listen for project lifecycle notifications to sync state
            .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { _ in
                print("[FinalFinalApp] Received .projectDidOpen notification")
                handleProjectOpened()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidCreate)) { _ in
                print("[FinalFinalApp] Received .projectDidCreate notification")
                handleProjectOpened()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidClose)) { _ in
                print("[FinalFinalApp] Received .projectDidClose notification")
                handleProjectClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGettingStarted)) { _ in
                print("[FinalFinalApp] Received .openGettingStarted notification")
                openGettingStarted()
            }
            // Listen for command notifications (from menu)
            // Note: .newProject and .openProject are handled by AppDelegate only
            // to avoid duplicate panel creation that prevents dismissal
            .onReceive(NotificationCenter.default.publisher(for: .closeProject)) { _ in
                print("[FinalFinalApp] Received .closeProject command")
                FileOperations.handleCloseProject()
            }
            .onChange(of: appViewState) { oldState, newState in
                print("[FinalFinalApp] State changed: \(oldState) -> \(newState)")
            }
        }
        .commands {
            FileCommands()
            ViewCommands()
            ThemeCommands()
            EditorCommands()
            CitationCommands()
            ExportCommands()
            HelpCommands(onGettingStarted: {
                // Post notification to handle in view hierarchy
                NotificationCenter.default.post(name: .openGettingStarted, object: nil)
            })
        }
        .handlesExternalEvents(matching: ["open"])

        // Preferences window
        Settings {
            PreferencesView()
                .environment(ThemeManager.shared)
        }

        Window("Version History", id: "version-history") {
            VersionHistoryWindow()
                .environment(ThemeManager.shared)
                .environment(versionHistoryCoordinator)
        }
        .defaultSize(width: 1200, height: 800)
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
    }

    /// Determine the initial app state on launch
    @MainActor
    private func determineInitialState() async {
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
            print("[FinalFinalApp] Failed to restore last project: \(error)")
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
        print("[FinalFinalApp] Project opened, state: \(appViewState)")
    }

    /// Handle project closed notification - show picker
    @MainActor
    private func handleProjectClosed() {
        print("[FinalFinalApp] handleProjectClosed() called, hasOpenProject: \(documentManager.hasOpenProject)")
        // Only update state if no project is open
        // (avoids race conditions when switching projects)
        guard !documentManager.hasOpenProject else {
            print("[FinalFinalApp] handleProjectClosed() - skipping because hasOpenProject=true")
            return
        }
        appViewState = .picker
        print("[FinalFinalApp] Project closed, showing picker")
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
            print("[FinalFinalApp] Opened Getting Started")
        } catch {
            print("[FinalFinalApp] Failed to open Getting Started: \(error)")
            // Fall back to picker on error
            appViewState = .picker
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to open Getting Started (from Help menu)
    static let openGettingStarted = Notification.Name("openGettingStarted")
}
