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

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?

    /// Whether the service is properly configured with database and project ID
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil
    }

    /// When true, suppresses sync operations
    /// Set during drag operations to prevent race conditions
    var isSyncSuppressed: Bool = false

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
    }

    /// Rebuild document markdown from sections in their current order
    /// Used after drag-drop reordering to sync sections back to document
    /// NOTE: Caller must pass sections in correct order - no sorting is performed
    func rebuildDocument(from sections: [Section]) -> String {
        sections
            .map { $0.markdownContent }
            .joined()  // Content already includes trailing newlines
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
        // Skip if suppressed (during drag operations)
        guard !isSyncSuppressed else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await syncContent(markdown, zoomedIds: zoomedIds)
        }
    }

    /// Reset sync tracking (call when manually setting content)
    func resetSyncTracking() {
        lastSyncedContent = ""
    }

    /// Force immediate sync (e.g., before app quit)
    func syncNow(_ markdown: String) async {
        debounceTask?.cancel()
        await syncContent(markdown)
    }

    /// Load sections from database as view models
    func loadSections() async -> [SectionViewModel] {
        guard let db = projectDatabase, let pid = projectId else { return [] }

        do {
            let sections = try db.fetchSections(projectId: pid)
            return sections.map { SectionViewModel(from: $0) }
        } catch {
            print("[SectionSyncService] Error loading sections: \(error.localizedDescription)")
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
    private func syncContent(_ markdown: String, zoomedIds: Set<String>? = nil) async {
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
            print("[SectionSyncService] Error: \(error)")
        }

        // Back on MainActor
        lastSyncedContent = markdown
        DocumentManager.shared.checkGettingStartedEdited(currentMarkdown: markdown)
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
                var changes: [SectionChange] = []
                let matchCount = min(headers.count, zoomedExisting.count)
                for index in 0..<matchCount {
                    let header = headers[index]
                    let existing = zoomedExisting[index]
                    var updates = SectionUpdates()
                    var hasChanges = false

                    if header.title != existing.title {
                        updates.title = header.title
                        hasChanges = true
                    }
                    if header.level != existing.headerLevel {
                        updates.headerLevel = header.level
                        hasChanges = true
                    }
                    if header.markdownContent != existing.markdownContent {
                        updates.markdownContent = header.markdownContent
                        updates.wordCount = header.wordCount
                        hasChanges = true
                    }
                    if header.startOffset != existing.startOffset {
                        updates.startOffset = header.startOffset
                        hasChanges = true
                    }
                    if hasChanges {
                        changes.append(.update(id: existing.id, updates: updates))
                    }
                }

                var updatedIds = zoomedIds

                // Handle NEW sections (user added headers while zoomed)
                if headers.count > zoomedExisting.count {
                    let newCount = headers.count - zoomedExisting.count
                    let lastZoomedSortOrder = zoomedExisting.last?.sortOrder ?? 0
                    let firstAfterZoomed = allSorted.first { $0.sortOrder > lastZoomedSortOrder && !zoomedIds.contains($0.id) }

                    if let firstAfter = firstAfterZoomed {
                        let sectionsToShift = allSorted.filter { $0.sortOrder >= firstAfter.sortOrder }
                        for section in sectionsToShift {
                            changes.append(.update(id: section.id, updates: SectionUpdates(sortOrder: section.sortOrder + newCount)))
                        }
                    }

                    for i in zoomedExisting.count..<headers.count {
                        let header = headers[i]
                        let newSortOrder = lastZoomedSortOrder + (i - zoomedExisting.count) + 1
                        let newSection = Section(
                            projectId: pid, sortOrder: newSortOrder, headerLevel: header.level,
                            isPseudoSection: header.isPseudoSection, title: header.title,
                            markdownContent: header.markdownContent, wordCount: header.wordCount,
                            startOffset: header.startOffset
                        )
                        changes.append(.insert(newSection))
                        updatedIds.insert(newSection.id)
                    }
                }

                // Handle DELETED sections (user removed headers while zoomed)
                if headers.count < zoomedExisting.count {
                    for i in headers.count..<zoomedExisting.count {
                        let removedSection = zoomedExisting[i]
                        changes.append(.delete(id: removedSection.id))
                        updatedIds.remove(removedSection.id)
                    }
                }

                if !changes.isEmpty {
                    try db.applySectionChanges(changes, for: pid)
                    return updatedIds
                }
                return nil
            }.value
        } catch {
            print("[SectionSyncService] Error updating zoomed sections: \(error)")
            return
        }

        // Back on MainActor — notify for UI refresh
        if let updatedIds = updatedZoomedIds {
            onZoomedSectionsUpdated?(updatedIds)
        }
    }

    // MARK: - Zoom Notes Helpers

    /// Strip the `<!-- ::zoom-notes:: -->` marker and everything after it from zoomed markdown.
    /// Returns the stripped markdown and the mini #Notes content (if any).
    static func stripZoomNotes(from markdown: String) -> (stripped: String, miniNotes: String?) {
        let marker = "<!-- ::zoom-notes:: -->"
        guard let range = markdown.range(of: marker) else {
            return (markdown, nil)
        }
        let stripped = String(markdown[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let miniNotes = String(markdown[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, miniNotes.isEmpty ? nil : miniNotes)
    }

    /// Public entry point for syncing mini Notes definitions back to DB.
    /// Called from handleZoomedFootnoteInsertion to preserve user edits before insertion.
    func syncMiniNotesBackPublic(_ miniNotesContent: String, projectId: String) {
        guard let db = projectDatabase else { return }
        syncMiniNotesBack(miniNotesContent, db: db, pid: projectId)
    }

    /// Sync edited mini #Notes definitions back to the main Notes block in the database.
    /// Called when zoomed content contains `<!-- ::zoom-notes:: -->` marker with definitions.
    private func syncMiniNotesBack(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        Self.syncMiniNotesBackImpl(miniNotesContent, db: db, pid: pid)
    }

    /// Static version of mini notes sync for use from detached tasks.
    nonisolated static func syncMiniNotesBackDetached(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        syncMiniNotesBackImpl(miniNotesContent, db: db, pid: pid)
    }

    /// Shared implementation for syncing mini notes back to DB.
    nonisolated private static func syncMiniNotesBackImpl(
        _ miniNotesContent: String,
        db: ProjectDatabase,
        pid: String
    ) {
        // Extract definitions from the mini #Notes content
        let editedDefs = FootnoteSyncService.extractFootnoteDefinitions(from: miniNotesContent)
        guard !editedDefs.isEmpty else { return }

        // Read current definitions from Block table (not Section table).
        let currentDefs: [String: String]
        do {
            let notesBlocks = try db.read { dbConn in
                try Block
                    .filter(Block.Columns.projectId == pid)
                    .filter(Block.Columns.isNotes == true)
                    .order(Block.Columns.sortOrder)
                    .fetchAll(dbConn)
            }
            guard !notesBlocks.isEmpty else { return }
            let notesMd = BlockParser.assembleMarkdown(from: notesBlocks)
            currentDefs = FootnoteSyncService.extractFootnoteDefinitions(from: notesMd)
        } catch {
            print("[SectionSyncService] Error reading notes blocks: \(error)")
            return
        }

        // Merge: edited definitions override current ones for matching labels
        var mergedDefs = currentDefs
        for (label, text) in editedDefs {
            mergedDefs[label] = text
        }

        guard mergedDefs != currentDefs else { return }

        let sortedLabels = mergedDefs.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }

        do {
            try db.write { dbConn in
                try Block.filter(Block.Columns.projectId == pid)
                    .filter(Block.Columns.isNotes == true)
                    .deleteAll(dbConn)

                let maxNonBibSort = try Block
                    .filter(Block.Columns.projectId == pid)
                    .filter(Block.Columns.isBibliography == false)
                    .order(Block.Columns.sortOrder.desc)
                    .fetchOne(dbConn)?.sortOrder ?? 0
                let baseSortOrder = maxNonBibSort + 0.5

                var heading = Block(
                    projectId: pid, sortOrder: baseSortOrder,
                    blockType: .heading, textContent: "Notes",
                    markdownFragment: "# Notes", headingLevel: 1,
                    status: .final_, isNotes: true
                )
                try heading.insert(dbConn)

                for (index, label) in sortedLabels.enumerated() {
                    let def = mergedDefs[label] ?? ""
                    var defBlock = Block(
                        projectId: pid, sortOrder: baseSortOrder + Double(index + 1),
                        blockType: .paragraph, textContent: def,
                        markdownFragment: "[^\(label)]: \(def)", isNotes: true
                    )
                    defBlock.recalculateWordCount()
                    try defBlock.insert(dbConn)
                }
            }
        } catch {
            print("[SectionSyncService] Error syncing mini notes back: \(error)")
        }
    }

}

/// Represents a mapping between a section ID and its header offset in markdown
struct SectionAnchorMapping: Equatable {
    let sectionId: String
    let headerOffset: Int
}
