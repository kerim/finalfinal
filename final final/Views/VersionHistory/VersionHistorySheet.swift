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
    @State var snapshotItems: [SnapshotListItem] = []
    @State var selectedSnapshotId: String?
    @State var selectedSnapshotSections: [SnapshotSection] = []
    @State private var showNamedOnly = false
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

    private var backupAnalysis: (changes: [String: SectionChangeType], wordDeltas: [String: Int]) {
        let displayed = selectedSnapshotSections.map { SnapshotSectionViewModel(from: $0) }
        let comparison: [SnapshotSectionViewModel]
        switch comparisonMode {
        case .vsCurrent:
            comparison = currentSections.map { SnapshotSectionViewModel(from: $0) }
        case .vsPrevious:
            comparison = previousSnapshotSections.map { SnapshotSectionViewModel(from: $0) }
        }
        return computeSectionAnalysis(displayed: displayed, comparison: comparison)
    }

    private var currentWordCount: Int {
        currentSections.reduce(0) { $0 + $1.wordCount }
    }

    private var currentSectionCount: Int {
        currentSections.count
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

            if selectedSnapshot != nil {
                Button {
                    showFullRestoreConfirmation = true
                } label: {
                    Label("Restore All", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        HSplitView {
            // Left: Version list
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
            .frame(minWidth: 200, idealWidth: 220)

            // Middle: Current document
            DocumentPreviewView(
                title: "Current",
                sections: currentSections.map { SnapshotSectionViewModel(from: $0) },
                highlightedSectionId: nil,
                onSectionTap: nil,
                showFullContent: true
            )
            .frame(minWidth: 250)

            // Right: Selected backup
            if selectedSnapshot != nil {
                let analysis = backupAnalysis
                DocumentPreviewView(
                    title: "Selected Backup",
                    sections: selectedSnapshotSections.map { SnapshotSectionViewModel(from: $0) },
                    highlightedSectionId: nil,
                    onSectionTap: { section in
                        handleSectionTap(section)
                    },
                    showRestoreButtons: true,
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
                .frame(minWidth: 250)
            } else {
                placeholderView
                    .frame(minWidth: 250)
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
