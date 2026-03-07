//
//  VersionHistoryWindow.swift
//  final final
//
//  Standalone window for version history with resizable layout and full content display.
//

import SwiftUI

/// Standalone window for version history
struct VersionHistoryWindow: View {
    @Environment(\.dismiss) var dismiss
    @Environment(ThemeManager.self) var themeManager
    @Environment(VersionHistoryCoordinator.self) var coordinator

    @State var snapshots: [Snapshot] = []
    @State var selectedSnapshotId: String?
    @State var selectedSnapshotSections: [SnapshotSection] = []
    @State var showNamedOnly = false
    @State var isLoading = true
    @State var errorMessage: String?

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

    private var filteredSnapshots: [Snapshot] {
        if showNamedOnly {
            return snapshots.filter { $0.isNamed }
        }
        return snapshots
    }

    private var selectedSnapshot: Snapshot? {
        guard let id = selectedSnapshotId else { return nil }
        return snapshots.first { $0.id == id }
    }

    /// Check if we have valid state to work with
    private var hasValidState: Bool {
        coordinator.database != nil && coordinator.projectId != nil && !projectClosed
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Main content
            if projectClosed {
                projectClosedView
            } else if !hasValidState {
                invalidStateView
            } else if isLoading {
                ProgressView("Loading version history...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task {
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

            Spacer()

            // Filter toggle
            Picker("Filter", selection: $showNamedOnly) {
                Text("All versions").tag(false)
                Text("Named saves only").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            // Restore All button (only when snapshot selected and project open)
            if selectedSnapshot != nil && !projectClosed {
                Button {
                    showFullRestoreConfirmation = true
                } label: {
                    Label("Restore All", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        GeometryReader { geometry in
            let versionListWidth = min(geometry.size.width * 0.15, 200)
            let remainingWidth = geometry.size.width - versionListWidth
            let documentWidth = remainingWidth / 2

            HStack(spacing: 0) {
                // Left: Version list (~15% width, max 200)
                VersionListView(
                    snapshots: filteredSnapshots,
                    selectedSnapshotId: $selectedSnapshotId,
                    onSelectSnapshot: { snapshotId in
                        Task {
                            await loadSnapshotSections(snapshotId: snapshotId)
                        }
                    }
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
                        }
                    )
                    .frame(width: documentWidth)
                } else {
                    placeholderView
                        .frame(width: documentWidth)
                }
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
                dismiss()
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
                dismiss()
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
