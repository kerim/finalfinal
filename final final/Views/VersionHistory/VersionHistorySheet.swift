//
//  VersionHistorySheet.swift
//  final final
//
//  Modal sheet for browsing and restoring version history.
//

import SwiftUI

/// Main modal sheet for version history with three-column layout
struct VersionHistorySheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let database: ProjectDatabase
    let projectId: String
    let currentContent: String
    let currentSections: [SectionViewModel]

    /// Callback when restore completes (caller should refresh UI)
    let onRestoreComplete: () -> Void

    @State var snapshots: [Snapshot] = []
    @State var selectedSnapshotId: String?
    @State var selectedSnapshotSections: [SnapshotSection] = []
    @State private var showNamedOnly = false
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Three-column layout
            if isLoading {
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

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        HSplitView {
            // Left: Version list
            VersionListView(
                snapshots: filteredSnapshots,
                selectedSnapshotId: $selectedSnapshotId,
                onSelectSnapshot: { snapshotId in
                    Task {
                        await loadSnapshotSections(snapshotId: snapshotId)
                    }
                }
            )
            .frame(minWidth: 200, idealWidth: 220)

            // Middle: Current document
            DocumentPreviewView(
                title: "Current",
                sections: currentSections.map { SnapshotSectionViewModel(from: $0) },
                highlightedSectionId: nil,
                onSectionTap: nil
            )
            .frame(minWidth: 250)

            // Right: Selected backup
            if selectedSnapshot != nil {
                DocumentPreviewView(
                    title: "Selected Backup",
                    sections: selectedSnapshotSections.map { SnapshotSectionViewModel(from: $0) },
                    highlightedSectionId: nil,
                    onSectionTap: { section in
                        handleSectionTap(section)
                    },
                    showRestoreButtons: true,
                    onRestoreSection: { section, mode in
                        handleRestoreRequest(section: section, mode: mode)
                    }
                )
                .frame(minWidth: 250)
            } else {
                placeholderView
                    .frame(minWidth: 250)
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

/// Mode for restoring a section
enum SectionRestoreMode {
    case replace   // Replace existing section
    case duplicate // Insert as new section
}
