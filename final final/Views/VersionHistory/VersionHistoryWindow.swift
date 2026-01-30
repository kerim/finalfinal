//
//  VersionHistoryWindow.swift
//  final final
//
//  Standalone window for version history with resizable layout and full content display.
//

import SwiftUI

/// Standalone window for version history
struct VersionHistoryWindow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @Environment(VersionHistoryCoordinator.self) private var coordinator

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

    /// Track if the project was closed while window is open
    @State private var projectClosed = false

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
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Project Closed View

    private var projectClosedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Project Closed")
                .font(.headline)
            Text("The project was closed. Restore operations are disabled.")
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text("No Project Data")
                .font(.headline)
            Text("Open a project and try again.")
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text("No Version History")
                .font(.headline)
            Text("Version history will appear here when you save versions or when auto-backups are created.")
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.orange)
            Text("Error Loading History")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
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
        guard !projectClosed else { return }

        // Convert back to SnapshotSection for restore
        guard let snapshotSection = selectedSnapshotSections.first(where: { $0.id == section.id }) else {
            return
        }

        pendingRestoreSection = snapshotSection
        pendingRestoreMode = mode

        if mode == .replace {
            // Check if original section still exists
            if let originalId = snapshotSection.originalSectionId,
               coordinator.currentSections.contains(where: { $0.id == originalId }) {
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

            List(coordinator.currentSections, id: \.id, selection: $targetSectionId) { section in
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
        guard let database = coordinator.database,
              let projectId = coordinator.projectId else {
            isLoading = false
            return
        }

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
        guard let database = coordinator.database else { return }

        do {
            selectedSnapshotSections = try database.fetchSnapshotSections(snapshotId: snapshotId)
        } catch {
            print("[VersionHistoryWindow] Error loading snapshot sections: \(error)")
            selectedSnapshotSections = []
        }
    }

    // MARK: - Restore Actions

    private func performSectionRestore() async {
        guard let database = coordinator.database,
              let projectId = coordinator.projectId,
              let section = pendingRestoreSection,
              let mode = pendingRestoreMode,
              !projectClosed else { return }

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
                let insertAfter = coordinator.currentSections.last?.id
                try service.restoreSectionAsDuplicate(
                    snapshotSectionId: section.id,
                    insertAfterSectionId: insertAfter,
                    createSafetyBackup: true
                )
            }

            // Notify main window to refresh
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)

            // Close window after successful restore
            dismiss()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }

        pendingRestoreSection = nil
        pendingRestoreMode = nil
        targetSectionId = nil
    }

    private func performFullRestore() async {
        guard let database = coordinator.database,
              let projectId = coordinator.projectId,
              let snapshotId = selectedSnapshotId,
              !projectClosed else { return }

        let service = SnapshotService(database: database, projectId: projectId)

        do {
            try service.restoreEntireProject(
                from: snapshotId,
                createSafetyBackup: createSafetyBackup
            )

            // Notify main window to refresh
            NotificationCenter.default.post(name: .projectDidOpen, object: nil)

            // Close window after successful restore
            dismiss()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
