//
//  VersionHistoryWindow+Restore.swift
//  final final
//

import SwiftUI

/// Mode for restoring a section.
/// Formerly defined at the bottom of the now-deleted VersionHistorySheet.swift (dead sheet,
/// confirmed unreferenced) -- this enum itself was still live (VersionHistoryWindow.swift,
/// VersionHistoryWindow+Restore.swift, DocumentPreviewView.swift), so it moved here rather
/// than being deleted along with the sheet.
enum SectionRestoreMode {
    case replace   // Replace existing section
    case duplicate // Insert as new section
}

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
        .accessibilityIdentifier("version-history-restore-confirm")
        Button("Cancel", role: .cancel) {
            pendingRestoreSection = nil
            pendingRestoreMode = nil
        }
        .accessibilityIdentifier("version-history-restore-cancel")
    }

    @ViewBuilder
    var fullRestoreConfirmationButtons: some View {
        Button("Restore Entire Project", role: .destructive) {
            Task {
                await performFullRestore()
            }
        }
        .accessibilityIdentifier("version-history-full-restore-confirm")
        Toggle("Create safety backup first", isOn: $createSafetyBackup)
        Button("Cancel", role: .cancel) {}
            .accessibilityIdentifier("version-history-full-restore-cancel")
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
            snapshotItems = snapshots.map { SnapshotListItem(snapshot: $0) }
            DebugLog.log(.lifecycle, "[VersionHistory] loadSnapshots: \(snapshots.count) snapshots found")
            DebugLog.log(.lifecycle, "[VersionHistory] coordinator.currentSections: \(coordinator.currentSections.count)")
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
            DebugLog.log(.lifecycle, "[VersionHistory] loadSnapshotSections: \(selectedSnapshotSections.count) sections for snapshot \(snapshotId)")

            // Load previous snapshot's sections for "vs Previous" comparison
            if let prevSnapshot = try database.fetchPreviousSnapshot(before: snapshotId, projectId: projectId) {
                previousSnapshotSections = fetchOrParseSnapshotSections(snapshotId: prevSnapshot.id, database: database)
            } else {
                previousSnapshotSections = []
            }
        } catch {
            DebugLog.log(.lifecycle, "[VersionHistoryWindow] Error loading snapshot sections: \(error)")
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
                DebugLog.log(.lifecycle,
                    "[VersionHistory] fetchOrParse: fallback parsed \(sections.count) sections")
            }
            return sections
        } catch {
            DebugLog.log(.lifecycle, "[VersionHistory] fetchOrParseSnapshotSections ERROR for snapshot \(snapshotId): \(error)")
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

        switch mode {
        case .replace:
            // Routed as a REQUEST into the main-window StructuralUndoController (plan §4.4,
            // "main-window request handoff") -- NOT a direct SnapshotService call. The
            // controller runs the full audited op sequence (mode-aware flush, checkpoint
            // capture, forced undo-point snapshot, the existing restoreSectionReplace DB
            // mutation, forced bibliography/footnote resync, content push, timeline record)
            // and reports success/failure; this window only handles the UI side (error
            // display, dismiss). Restore-as-duplicate below is UNCHANGED this round -- it
            // still calls SnapshotService directly and posts .projectDidOpen, same as before
            // Phase 3 -- see the coder brief: only .replace is wired to the unified timeline
            // this round.
            let targetId = targetSectionId ?? section.originalSectionId ?? ""
            guard let controller = DocumentManager.shared.structuralUndoController else {
                errorMessage = "Restore failed: unified undo controller not available"
                pendingRestoreSection = nil
                pendingRestoreMode = nil
                targetSectionId = nil
                return
            }
            let ok = await controller.performSectionRestoreReplace(
                snapshotSectionId: section.id, targetSectionId: targetId, requestingProjectId: projectId
            )
            guard ok else {
                errorMessage = "Restore failed"
                pendingRestoreSection = nil
                pendingRestoreMode = nil
                targetSectionId = nil
                return
            }
            dismissWindow(id: "version-history")

        case .duplicate:
            let service = SnapshotService(database: database, projectId: projectId)
            do {
                // Insert after the last section
                let insertAfter = coordinator.currentSections.last?.id
                try service.restoreSectionAsDuplicate(
                    snapshotSectionId: section.id,
                    insertAfterSectionId: insertAfter,
                    createSafetyBackup: true
                )
                // Notify main window to refresh (skip flush — blocks already rebuilt)
                NotificationCenter.default.post(name: .projectDidOpen, object: nil, userInfo: ["isRestore": true])
                dismissWindow(id: "version-history")
            } catch {
                errorMessage = "Restore failed: \(error.localizedDescription)"
            }
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
