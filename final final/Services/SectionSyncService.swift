//
//  SectionSyncService.swift
//  final final
//

import Foundation
import GRDB

/// Service to sync editor content with sections database
/// Uses position-based reconciliation with surgical database updates
@MainActor
@Observable
class SectionSyncService {
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(500)
    private let reconciler = SectionReconciler()
    private var debounceGeneration: Int = 0

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?

    /// Whether the service is properly configured with database and project ID
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil
    }

    /// Reference to editor state for checking content transitions
    weak var editorState: EditorViewState?

    /// When true, content is a zoomed subset - skip full document save to database
    var isContentZoomed: Bool = false

    /// Callback after zoomed sections are synced to database
    /// Passes the set of zoomed section IDs for targeted refresh
    var onZoomedSectionsUpdated: ((Set<String>) -> Void)?

    /// Content we last synced - prevents feedback loop from ValueObservation
    private var lastSyncedContent: String = ""

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
    }

    /// Verify the service is properly configured
    /// - Throws: SyncConfigurationError if not configured
    func verifyConfiguration() throws {
        if projectDatabase == nil {
            throw SyncConfigurationError.noDatabase
        }
        if projectId == nil {
            throw SyncConfigurationError.noProjectId
        }
    }

    /// Errors related to sync service configuration
    enum SyncConfigurationError: Error, LocalizedError {
        case noDatabase
        case noProjectId

        var errorDescription: String? {
            switch self {
            case .noDatabase:
                return "SectionSyncService not configured: no database"
            case .noProjectId:
                return "SectionSyncService not configured: no project ID"
            }
        }
    }

    /// Cancel any pending debounced sync operation
    /// Call this before starting drag operations to prevent race conditions
    func cancelPendingSync() {
        debounceTask?.cancel()
        debounceTask = nil
        debounceGeneration += 1
    }

    /// Update header level in markdown content
    /// Used when section level changes during drag-drop
    func updateHeaderLevel(in markdown: String, to newLevel: Int) -> String {
        guard newLevel > 0 else { return markdown }  // Pseudo-sections don't have headers

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return markdown }

        let lineStr = String(firstLine)
        // Check if first line is a header
        guard lineStr.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
            return markdown
        }

        // Replace the header prefix
        let newPrefix = String(repeating: "#", count: newLevel)
        var idx = lineStr.startIndex
        while idx < lineStr.endIndex && lineStr[idx] == "#" {
            idx = lineStr.index(after: idx)
        }
        // Skip space after #
        if idx < lineStr.endIndex && lineStr[idx] == " " {
            idx = lineStr.index(after: idx)
        }

        let title = String(lineStr[idx...])
        let newFirstLine = "\(newPrefix) \(title)"

        var result = [newFirstLine]
        if lines.count > 1 {
            result.append(contentsOf: lines.dropFirst().map { String($0) })
        }
        return result.joined(separator: "\n")
    }

    /// Called when editor content changes
    /// Debounces and triggers sync after delay
    /// - Parameters:
    ///   - markdown: The markdown content to sync
    ///   - zoomedIds: Optional set of zoomed section IDs (pass when zoomed to avoid replacing full array)
    func contentChanged(_ markdown: String, zoomedIds: Set<String>? = nil) {
        // Skip if content transition is in progress (drag, zoom, etc.)
        guard !(editorState?.isBusy ?? false) else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        debounceTask?.cancel()
        debounceGeneration += 1
        let myGeneration = debounceGeneration
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            // Double-check: if another contentChanged fired during sleep, skip
            guard self.debounceGeneration == myGeneration else { return }
            await syncContent(markdown, zoomedIds: zoomedIds, fromEditorChange: true)
        }
    }

    /// Reset sync tracking (call when manually setting content)
    func resetSyncTracking() {
        lastSyncedContent = ""
    }

    /// Force immediate sync (e.g., before app quit).
    /// - Parameter fromEditorChange: Pass `true` when this flush represents the user's real,
    ///   settled editor content (e.g. `handleSaveVersion`'s "flush before snapshot" — the
    ///   content is definitionally the user's current state at that point, not a
    ///   pre-round-trip programmatic sync) so Getting Started edit-detection sees it. Defaults
    ///   to `false` for programmatic/terminal syncs (initial load, version-history prep, etc.).
    func syncNow(_ markdown: String, fromEditorChange: Bool = false) async {
        debounceTask?.cancel()
        await syncContent(markdown, fromEditorChange: fromEditorChange)
    }

    /// Synchronous section sync for app termination / project close.
    /// Mirrors syncContent() logic but runs inline on @MainActor.
    func syncNowSync(_ markdown: String) {
        cancelPendingSync()

        // When zoomed, content is a subset — skip full reconciliation
        // (zoomed sections are already handled by flushContentToDatabase's range replace)
        guard !isContentZoomed else { return }

        guard let db = projectDatabase, let pid = projectId else { return }
        let fallbackBibTitle = ExportSettingsManager.shared.bibliographyHeaderName

        do {
            let dbSections = try db.fetchSections(projectId: pid)

            let existingBibTitle = dbSections.first(where: { $0.isBibliography })?.title
            let existingNotesTitle = dbSections.first(where: { $0.isNotes })?.title
            let headers = SectionSyncService.parseHeaders(
                from: markdown,
                existingBibTitle: existingBibTitle,
                existingNotesTitle: existingNotesTitle,
                fallbackBibTitle: fallbackBibTitle
            )
            guard !headers.isEmpty else { return }

            let changes = reconciler.reconcile(
                headers: headers,
                dbSections: dbSections,
                projectId: pid
            )

            if !changes.isEmpty {
                try db.applySectionChanges(changes, for: pid)
            }

            try db.saveContent(markdown: markdown, for: pid)
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] syncNowSync error: \(error)")
        }

        lastSyncedContent = markdown
    }

    /// Load sections from database as view models
    func loadSections() async -> [SectionViewModel] {
        guard let db = projectDatabase, let pid = projectId else { return [] }

        do {
            let sections = try db.fetchSections(projectId: pid)
            return sections.map { SectionViewModel(from: $0) }
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error loading sections: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse markdown and return sections without saving to database
    /// Used for initial sync when database has no sections yet
    func parseAndGetSections(from markdown: String) -> [SectionViewModel] {
        guard let pid = projectId else { return [] }
        let headers = SectionSyncService.parseHeaders(from: markdown)
        let sections = headers.map { header in
            Section(
                projectId: pid,
                sortOrder: header.position,
                headerLevel: header.level,
                title: header.title,
                markdownContent: header.markdownContent,
                wordCount: header.wordCount,
                startOffset: header.startOffset
            )
        }
        return sections.map { SectionViewModel(from: $0) }
    }

    // MARK: - Private Methods

    /// Core sync method using position-based reconciliation
    /// DB reads/writes are dispatched off the main thread via Task.detached
    /// - Parameter fromEditorChange: `true` only for content that came from the debounced
    ///   `contentChanged` path (genuinely settled editor content) or an explicitly-flagged
    ///   `syncNow` flush of the user's real current state. Gates Getting Started edit
    ///   detection so a programmatic/terminal sync never poisons or falsely trips it.
    private func syncContent(_ markdown: String, zoomedIds: Set<String>? = nil, fromEditorChange: Bool = false) async {
        guard let db = projectDatabase, let pid = projectId else { return }

        // When zoomed, update zoomed sections in-place
        // Trust zoomedIds directly - it's passed synchronously from editorState.zoomedSectionIds
        // which is the source of truth (not the reactive isContentZoomed property)
        if let zoomedIds = zoomedIds, !zoomedIds.isEmpty {
            await syncZoomedSections(from: markdown, zoomedIds: zoomedIds)
            return
        }

        // Capture @MainActor values before detaching
        let isZoomed = isContentZoomed
        let reconciler = self.reconciler
        let fallbackBibTitle = ExportSettingsManager.shared.bibliographyHeaderName

        do {
            try await Task.detached(priority: .utility) {
                // 1. Get current DB sections first (need to identify bibliography by title)
                let dbSections = try db.fetchSections(projectId: pid)

                // 2. Parse headers from markdown (pass existing bibliography/notes title for detection)
                let existingBibTitle = dbSections.first(where: { $0.isBibliography })?.title
                let existingNotesTitle = dbSections.first(where: { $0.isNotes })?.title
                let headers = SectionSyncService.parseHeaders(
                    from: markdown, existingBibTitle: existingBibTitle,
                    existingNotesTitle: existingNotesTitle, fallbackBibTitle: fallbackBibTitle)
                guard !headers.isEmpty else { return }

                // 3. Reconcile to find minimal changes
                let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: pid)

                // 4. Apply changes to database (if any)
                if !changes.isEmpty {
                    try db.applySectionChanges(changes, for: pid)
                }

                // 5. Save full content to database ONLY when not zoomed
                if !isZoomed {
                    try db.saveContent(markdown: markdown, for: pid)
                }
            }.value
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error: \(error)")
        }

        // Back on MainActor
        lastSyncedContent = markdown
        if fromEditorChange {
            // Detect the false -> true transition specifically (not "is it edited"), so the
            // toast fires exactly once per Getting Started session rather than re-posting on
            // every subsequent settle after the first real edit.
            let wasModified = DocumentManager.shared.isGettingStartedModified()
            DocumentManager.shared.checkGettingStartedEdited(currentMarkdown: markdown)
            if !wasModified && DocumentManager.shared.isGettingStartedModified() {
                // Posted rather than calling editorState directly: even though SectionSyncService
                // does hold a weak back-reference to EditorViewState (assigned in
                // ContentView+ProjectLifecycle.swift for the block-reparse flush), toast state
                // is a UI-layer concern and this sync service shouldn't reach into it directly --
                // NotificationCenter keeps that boundary decoupled.
                NotificationCenter.default.post(name: .gettingStartedEdited, object: nil)
            }
        }
    }

    /// Sync zoomed content without replacing the full sections array
    /// Updates zoomed sections in-place and saves only those to database
    /// Handles insertions (new headers) and deletions (removed headers) while zoomed
    private func syncZoomedSections(from markdown: String, zoomedIds: Set<String>) async {
        guard let db = projectDatabase, let pid = projectId else { return }

        // Capture @MainActor value before detaching
        let fallbackBibTitle = ExportSettingsManager.shared.bibliographyHeaderName

        // Strip mini #Notes section (zoom-notes marker) before parsing
        let (strippedMarkdown, miniNotesContent) = Self.stripZoomNotes(from: markdown)

        let updatedZoomedIds: Set<String>?
        do {
            updatedZoomedIds = try await Task.detached(priority: .utility) {
                // Fetch existing sections from database first (need bibliography title for detection)
                let existingSections = try db.fetchSections(projectId: pid)

                // Parse zoomed markdown to extract section content (pass bibliography/notes title for detection)
                let existingBibTitle = existingSections.first(where: { $0.isBibliography })?.title
                let existingNotesTitle = existingSections.first(where: { $0.isNotes })?.title
                let headers = SectionSyncService.parseHeaders(
                    from: strippedMarkdown, existingBibTitle: existingBibTitle,
                    existingNotesTitle: existingNotesTitle, fallbackBibTitle: fallbackBibTitle)

                // If mini #Notes was edited while zoomed, sync definitions back to main Notes block
                if let miniNotes = miniNotesContent {
                    SectionSyncService.syncMiniNotesBackDetached(miniNotes, db: db, pid: pid)
                }

                // Build lookup of zoomed sections by sortOrder within zoomed subset
                let zoomedExisting = existingSections
                    .filter { zoomedIds.contains($0.id) }
                    .sorted { $0.sortOrder < $1.sortOrder }

                let allSorted = existingSections.sorted { $0.sortOrder < $1.sortOrder }

                // Match parsed headers to existing zoomed sections by position and update
                var changes = SectionSyncService.zoomedUpdateChanges(headers: headers, zoomedExisting: zoomedExisting)

                var updatedIds = zoomedIds

                // Handle NEW sections (user added headers while zoomed)
                let insertions = SectionSyncService.zoomedInsertionChanges(
                    headers: headers, zoomedExisting: zoomedExisting,
                    allSorted: allSorted, zoomedIds: zoomedIds, pid: pid
                )
                changes.append(contentsOf: insertions.changes)
                updatedIds.formUnion(insertions.insertedIds)

                // Handle DELETED sections (user removed headers while zoomed)
                let deletions = SectionSyncService.zoomedDeletionChanges(headers: headers, zoomedExisting: zoomedExisting)
                changes.append(contentsOf: deletions.changes)
                updatedIds.subtract(deletions.removedIds)

                if !changes.isEmpty {
                    try db.applySectionChanges(changes, for: pid)
                    return updatedIds
                }
                return nil
            }.value
        } catch {
            DebugLog.log(.sync, "[SectionSyncService] Error updating zoomed sections: \(error)")
            return
        }

        // Back on MainActor — notify for UI refresh
        if let updatedIds = updatedZoomedIds {
            onZoomedSectionsUpdated?(updatedIds)
        }
    }

    // MARK: - Zoom Notes Helpers
    // Implementation moved to SectionSyncService+MiniNotes.swift (type_body_length cleanup).

    /// Public entry point for syncing mini Notes definitions back to DB.
    /// Called from handleZoomedFootnoteInsertion to preserve user edits before insertion.
    func syncMiniNotesBackPublic(_ miniNotesContent: String, projectId: String) {
        guard let db = projectDatabase else { return }
        syncMiniNotesBack(miniNotesContent, db: db, pid: projectId)
    }

}

/// Represents a mapping between a section ID and its header offset in markdown
struct SectionAnchorMapping: Equatable {
    let sectionId: String
    let headerOffset: Int
}
