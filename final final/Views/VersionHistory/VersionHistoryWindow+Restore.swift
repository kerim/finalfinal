//
//  VersionHistoryWindow+Restore.swift
//  final final
//

import SwiftUI

// MARK: - Section Restore

extension VersionHistoryWindow {

    func handleSectionTap(_ section: SnapshotSectionViewModel) {
        // Could show section details or highlight
    }

    func handleRestoreRequest(section: SnapshotSectionViewModel, mode: SectionRestoreMode) {
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
    var restoreConfirmationButtons: some View {
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
    var fullRestoreConfirmationButtons: some View {
        Button("Restore Entire Project", role: .destructive) {
            Task {
                await performFullRestore()
            }
        }
        Toggle("Create safety backup first", isOn: $createSafetyBackup)
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - Section Picker

    var sectionPickerSheet: some View {
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

    func loadSnapshots() async {
        guard let database = coordinator.database,
              let projectId = coordinator.projectId else {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            snapshots = try database.fetchSnapshots(projectId: projectId)
            #if DEBUG
            print("[VersionHistory] loadSnapshots: \(snapshots.count) snapshots found")
            print("[VersionHistory] coordinator.currentSections: \(coordinator.currentSections.count)")
            #endif
            if let firstSnapshot = snapshots.first {
                selectedSnapshotId = firstSnapshot.id
                await loadSnapshotSections(snapshotId: firstSnapshot.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadSnapshotSections(snapshotId: String) async {
        guard let database = coordinator.database,
              let projectId = coordinator.projectId else { return }

        do {
            selectedSnapshotSections = fetchOrParseSnapshotSections(snapshotId: snapshotId, database: database)
            #if DEBUG
            print("[VersionHistory] loadSnapshotSections: \(selectedSnapshotSections.count) sections for snapshot \(snapshotId)")
            #endif

            // Load previous snapshot's sections for "vs Previous" comparison
            if let prevSnapshot = try database.fetchPreviousSnapshot(before: snapshotId, projectId: projectId) {
                previousSnapshotSections = fetchOrParseSnapshotSections(snapshotId: prevSnapshot.id, database: database)
            } else {
                previousSnapshotSections = []
            }
        } catch {
            #if DEBUG
            print("[VersionHistoryWindow] Error loading snapshot sections: \(error)")
            #endif
            selectedSnapshotSections = []
            previousSnapshotSections = []
        }
    }

    /// Fetch snapshot sections with fallback to parsing from previewMarkdown
    private func fetchOrParseSnapshotSections(snapshotId: String, database: ProjectDatabase) -> [SnapshotSection] {
        do {
            var sections = try database.fetchSnapshotSections(snapshotId: snapshotId)
            if sections.isEmpty, let snapshot = try database.fetchSnapshot(id: snapshotId) {
                let headers = SectionSyncService.parseHeaders(from: snapshot.previewMarkdown)
                sections = headers.map { header in
                    SnapshotSection(
                        snapshotId: snapshotId,
                        originalSectionId: nil,
                        title: header.title,
                        markdownContent: header.markdownContent,
                        headerLevel: header.level,
                        sortOrder: header.position
                    )
                }
                #if DEBUG
                print("[VersionHistory] fetchOrParseSnapshotSections: fallback parsed \(sections.count) sections from previewMarkdown")
                #endif
            }
            return sections
        } catch {
            #if DEBUG
            print("[VersionHistory] fetchOrParseSnapshotSections ERROR for snapshot \(snapshotId): \(error)")
            #endif
            return []
        }
    }

    // MARK: - Restore Actions

    func performSectionRestore() async {
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

            // Notify main window to refresh (skip flush — blocks already rebuilt)
            NotificationCenter.default.post(name: .projectDidOpen, object: nil, userInfo: ["isRestore": true])

            // Close window after successful restore
            dismissWindow(id: "version-history")
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }

        pendingRestoreSection = nil
        pendingRestoreMode = nil
        targetSectionId = nil
    }

    func performFullRestore() async {
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

            // Notify main window to refresh (skip flush — blocks already rebuilt)
            NotificationCenter.default.post(name: .projectDidOpen, object: nil, userInfo: ["isRestore": true])

            // Close window after successful restore
            dismissWindow(id: "version-history")
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
