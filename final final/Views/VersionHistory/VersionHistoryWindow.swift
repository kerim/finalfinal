//
//  VersionHistoryWindow.swift
//  final final
//
//  Standalone window for version history with resizable layout and full content display.
//

import SwiftUI

/// Standalone window for version history
struct VersionHistoryWindow: View {
    @Environment(\.dismissWindow) var dismissWindow
    @Environment(ThemeManager.self) var themeManager
    @Environment(VersionHistoryCoordinator.self) var coordinator

    @State var snapshots: [Snapshot] = []
    @State var snapshotItems: [SnapshotListItem] = []
    @State var selectedSnapshotId: String?
    @State var selectedSnapshotSections: [SnapshotSection] = []
    @State var showNamedOnly = false
    @State var isLoading = true
    @State var errorMessage: String?
    @State var comparisonMode: ComparisonMode = .vsCurrent
    @State var previousSnapshotSections: [SnapshotSection] = []

    /// For section restore confirmation
    @State var pendingRestoreSection: SnapshotSection?
    @State var pendingRestoreMode: SectionRestoreMode?
    @State var showRestoreConfirmation = false
    @State var showSectionPicker = false
    @State var targetSectionId: String?

    /// For full project restore confirmation
    @State var showFullRestoreConfirmation = false
    @State var createSafetyBackup = true

    /// Track if the project was closed while window is open
    @State var projectClosed = false

    private var filteredSnapshots: [SnapshotListItem] {
        if showNamedOnly {
            return snapshotItems.filter { $0.snapshot.isNamed }
        }
        return snapshotItems
    }

    private var selectedSnapshot: Snapshot? {
        guard let id = selectedSnapshotId else { return nil }
        return snapshots.first { $0.id == id }
    }

    /// Check if we have valid state to work with
    private var hasValidState: Bool {
        coordinator.database != nil && coordinator.projectId != nil && !projectClosed
    }

    private var currentSectionVMs: [SnapshotSectionViewModel] {
        coordinator.currentSections.map { SnapshotSectionViewModel(from: $0) }
    }

    private var backupAnalysis: (changes: [String: SectionChangeType], wordDeltas: [String: Int]) {
        computeBackupAnalysis(
            snapshotSections: selectedSnapshotSections,
            currentSections: currentSectionVMs,
            previousSections: previousSnapshotSections,
            comparisonMode: comparisonMode
        )
    }

    private var currentWordCount: Int {
        currentSectionVMs.reduce(0) { $0 + $1.wordCount }
    }

    private var currentSectionCount: Int {
        coordinator.currentSections.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Main content
            if isLoading {
                ProgressView("Loading version history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projectClosed {
                projectClosedView
            } else if !hasValidState {
                invalidStateView
            } else if let error = errorMessage {
                errorView(error)
            } else if snapshots.isEmpty {
                emptyStateView
            } else {
                mainContentView
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(themeManager.currentTheme.editorBackground)
        .task(id: coordinator.projectId) {
            guard coordinator.projectId != nil else {
                isLoading = false
                return
            }
            await loadSnapshots()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectDidClose)) { _ in
            projectClosed = true
        }
        .onDisappear {
            coordinator.close()
        }
        .confirmationDialog(
            "Restore Section",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            restoreConfirmationButtons
        } message: {
            if let section = pendingRestoreSection {
                Text("Restore \"\(section.title)\" from this backup?")
            }
        }
        .confirmationDialog(
            "Restore Entire Project",
            isPresented: $showFullRestoreConfirmation,
            titleVisibility: .visible
        ) {
            fullRestoreConfirmationButtons
        } message: {
            Text("This will replace all current content with the selected backup version.")
        }
        .sheet(isPresented: $showSectionPicker) {
            sectionPickerSheet
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Version History")
                .font(.headline)
                .foregroundStyle(themeManager.currentTheme.sidebarText)

            Spacer()

            if selectedSnapshot != nil && !projectClosed {
                Button {
                    showFullRestoreConfirmation = true
                } label: {
                    Label("Restore All", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Close") {
                dismissWindow(id: "version-history")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        GeometryReader { geometry in
            let _ = { // swiftlint:disable:this redundant_discardable_let
                DebugLog.log(.lifecycle,
                    "[VersionHistory] mainContent: current=\(coordinator.currentSections.count), backup=\(selectedSnapshotSections.count)")
            }()
            let versionListWidth = min(geometry.size.width * 0.15, 200)
            let remainingWidth = geometry.size.width - versionListWidth
            let documentWidth = remainingWidth / 2

            HStack(spacing: 0) {
                // Left: Version list (~15% width, max 200)
                VersionListView(
                    snapshots: filteredSnapshots,
                    selectedSnapshotId: $selectedSnapshotId,
                    showNamedOnly: $showNamedOnly,
                    onSelectSnapshot: { snapshotId in
                        Task {
                            await loadSnapshotSections(snapshotId: snapshotId)
                        }
                    },
                    comparisonMode: comparisonMode,
                    currentWordCount: currentWordCount,
                    currentSectionCount: currentSectionCount
                )
                .frame(width: versionListWidth)

                Divider()

                // Middle: Current document (half of remaining)
                DocumentPreviewView(
                    title: "Current",
                    sections: coordinator.currentSections.map { SnapshotSectionViewModel(from: $0) },
                    highlightedSectionId: nil,
                    onSectionTap: nil,
                    showFullContent: true
                )
                .frame(width: documentWidth)

                Divider()

                // Right: Selected backup (half of remaining)
                if selectedSnapshot != nil {
                    let analysis = backupAnalysis
                    DocumentPreviewView(
                        title: "Selected Backup",
                        sections: selectedSnapshotSections.map { SnapshotSectionViewModel(from: $0) },
                        highlightedSectionId: nil,
                        onSectionTap: { section in
                            handleSectionTap(section)
                        },
                        showRestoreButtons: !projectClosed,
                        showFullContent: true,
                        onRestoreSection: { section, mode in
                            handleRestoreRequest(section: section, mode: mode)
                        },
                        changeTypes: analysis.changes,
                        sectionWordDeltas: analysis.wordDeltas
                    ) {
                        Picker("Compare", selection: $comparisonMode) {
                            ForEach(ComparisonMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                    .frame(width: documentWidth)
                } else {
                    placeholderView
                        .frame(width: documentWidth)
                }
            }
        }
        .onChange(of: showNamedOnly) { _, _ in
            // Clear stale selection when filter changes
            if let selectedId = selectedSnapshotId,
               !filteredSnapshots.contains(where: { $0.snapshot.id == selectedId }) {
                selectedSnapshotId = nil
            }
        }
    }

    private var placeholderView: some View {
        VStack {
            Spacer()
            Text("Select a version to compare")
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
            Spacer()
        }
    }

    // MARK: - Project Closed View

    private var projectClosedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(themeManager.currentTheme.accentColor)
            Text("Project Closed")
                .font(.headline)
                .foregroundStyle(themeManager.currentTheme.editorText)
            Text("The project was closed. Restore operations are disabled.")
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Close Window") {
                dismissWindow(id: "version-history")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Invalid State View

    private var invalidStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
            Text("No Project Data")
                .font(.headline)
                .foregroundStyle(themeManager.currentTheme.editorText)
            Text("Open a project and try again.")
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
            Button("Close") {
                dismissWindow(id: "version-history")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
            Text("No Version History")
                .font(.headline)
                .foregroundStyle(themeManager.currentTheme.editorText)
            Text("Version history will appear here when you save versions or when auto-backups are created.")
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(themeManager.currentTheme.accentColor)
            Text("Error Loading History")
                .font(.headline)
                .foregroundStyle(themeManager.currentTheme.editorText)
            Text(message)
                .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
            Button("Try Again") {
                Task { await loadSnapshots() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
