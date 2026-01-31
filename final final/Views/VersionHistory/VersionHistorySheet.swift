//
//  VersionHistorySheet.swift
//  final final
//
//  Modal sheet for browsing and restoring version history.
//

import SwiftUI

/// Main modal sheet for version history with three-column layout
struct VersionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager

    let database: ProjectDatabase
    let projectId: String
    let currentContent: String
    let currentSections: [SectionViewModel]

    /// Callback when restore completes (caller should refresh UI)
    let onRestoreComplete: () -> Void

    @State private var snapshots: [Snapshot] = []
    @State private var selectedSnapshotId: String?
    @State private var selectedSnapshotSections: [SnapshotSection] = []
    @State private var showNamedOnly = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// For section restore confirmation
    @State private var pendingRestoreSection: SnapshotSection?
    @State private var pendingRestoreMode: SectionRestoreMode?
    @State private var showRestoreConfirmation = false
    @State private var showSectionPicker = false
    @State private var targetSectionId: String?

    /// For full project restore confirmation
    @State private var showFullRestoreConfirmation = false
    @State private var createSafetyBackup = true

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
            if let _ = selectedSnapshot {
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

    // MARK: - Section Restore

    private func handleSectionTap(_ section: SnapshotSectionViewModel) {
        // Could show section details or highlight
    }

    private func handleRestoreRequest(section: SnapshotSectionViewModel, mode: SectionRestoreMode) {
        // Convert back to SnapshotSection for restore
        guard let snapshotSection = selectedSnapshotSections.first(where: { $0.id == section.id }) else {
            return
        }

        pendingRestoreSection = snapshotSection
        pendingRestoreMode = mode

        if mode == .replace {
            // Check if original section still exists
            if let originalId = snapshotSection.originalSectionId,
               currentSections.contains(where: { $0.id == originalId }) {
                // Can restore directly
                showRestoreConfirmation = true
            } else {
                // Need to pick target section
                showSectionPicker = true
            }
        } else {
            // Insert as duplicate - confirm placement
            showRestoreConfirmation = true
        }
    }

    @ViewBuilder
    private var restoreConfirmationButtons: some View {
        Button("Restore", role: .destructive) {
            Task {
                await performSectionRestore()
            }
        }
        Button("Cancel", role: .cancel) {
            pendingRestoreSection = nil
            pendingRestoreMode = nil
        }
    }

    @ViewBuilder
    private var fullRestoreConfirmationButtons: some View {
        Button("Restore Entire Project", role: .destructive) {
            Task {
                await performFullRestore()
            }
        }
        Toggle("Create safety backup first", isOn: $createSafetyBackup)
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Section Picker

    private var sectionPickerSheet: some View {
        VStack(spacing: 0) {
            Text("Select Target Section")
                .font(.headline)
                .padding()

            Divider()

            List(currentSections, id: \.id, selection: $targetSectionId) { section in
                HStack {
                    Text(String(repeating: "  ", count: section.headerLevel - 1))
                    Text(section.title)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    showSectionPicker = false
                    targetSectionId = nil
                }
                Spacer()
                Button("Replace Selected") {
                    showSectionPicker = false
                    if targetSectionId != nil {
                        showRestoreConfirmation = true
                    }
                }
                .disabled(targetSectionId == nil)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }

    // MARK: - Data Loading

    private func loadSnapshots() async {
        isLoading = true
        errorMessage = nil

        do {
            snapshots = try database.fetchSnapshots(projectId: projectId)
            if let firstSnapshot = snapshots.first {
                selectedSnapshotId = firstSnapshot.id
                await loadSnapshotSections(snapshotId: firstSnapshot.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadSnapshotSections(snapshotId: String) async {
        do {
            selectedSnapshotSections = try database.fetchSnapshotSections(snapshotId: snapshotId)
        } catch {
            print("[VersionHistorySheet] Error loading snapshot sections: \(error)")
            selectedSnapshotSections = []
        }
    }

    // MARK: - Restore Actions

    private func performSectionRestore() async {
        guard let section = pendingRestoreSection,
              let mode = pendingRestoreMode else { return }

        let service = SnapshotService(database: database, projectId: projectId)

        do {
            switch mode {
            case .replace:
                let targetId = targetSectionId ?? section.originalSectionId ?? ""
                try service.restoreSectionReplace(
                    snapshotSectionId: section.id,
                    targetSectionId: targetId,
                    createSafetyBackup: true
                )
            case .duplicate:
                // Insert after the last section
                let insertAfter = currentSections.last?.id
                try service.restoreSectionAsDuplicate(
                    snapshotSectionId: section.id,
                    insertAfterSectionId: insertAfter,
                    createSafetyBackup: true
                )
            }

            // Refresh snapshots list
            await loadSnapshots()

            // Notify parent to refresh
            onRestoreComplete()
            dismiss()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }

        pendingRestoreSection = nil
        pendingRestoreMode = nil
        targetSectionId = nil
    }

    private func performFullRestore() async {
        guard let snapshotId = selectedSnapshotId else { return }

        let service = SnapshotService(database: database, projectId: projectId)

        do {
            try service.restoreEntireProject(
                from: snapshotId,
                createSafetyBackup: createSafetyBackup
            )

            // Notify parent to refresh
            onRestoreComplete()
            dismiss()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}

/// Mode for restoring a section
enum SectionRestoreMode {
    case replace   // Replace existing section
    case duplicate // Insert as new section
}
