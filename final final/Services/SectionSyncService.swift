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

    /// P2 (undo-mode-switch-focus second timing gap, judge-review M2 fix): true while a
    /// content-triggered reconciliation is in flight -- spans BOTH the 500ms debounce +
    /// `syncContent` in THIS file, AND `ContentView.enforceHierarchyAsync` (ContentView+
    /// HierarchyEnforcement.swift). `CodeMirrorCoordinator.shouldPushContent` (via the
    /// `isReconciliationPending` closure) extends its settle-window suppression while
    /// this is true, capped at 2s there as a backstop against a leaked flag.
    ///
    /// Backed by a SET of tokens, not a plain Bool -- the earlier plain-Bool design had
    /// three unsynchronized writers (`contentChanged`'s debounce Task, `syncNow`'s direct
    /// path, `enforceHierarchyAsync`) coordinating through a shared
    /// `debounceGeneration`-matching scheme that didn't actually cover all three:
    /// `cancelPendingSync()` bumped the generation without touching the flag (a
    /// mid-flight task's defer then saw the mismatch and refused to clear, leaking `true`
    /// forever), while `syncNow` cancelled WITHOUT bumping the generation (so that SAME
    /// cancelled task's defer DID still match and clear -- possibly while `syncNow`'s own
    /// work was still in flight), and `enforceHierarchyAsync` cleared unconditionally
    /// with no gate at all. A token set sidesteps all of this: every acquirer gets a
    /// UNIQUE token via `acquireSyncPending()` and releases exactly that token via
    /// `releaseSyncPending(_:)` (idempotent, ignores an already-released/unknown token) --
    /// cancellation still runs a Task's own `defer`, which still only ever touches its
    /// own token, so no generation-matching bookkeeping is needed at all.
    private var activeSyncPendingTokens: Set<Int> = []
    private var nextSyncPendingToken: Int = 0

    var isSyncPending: Bool { !activeSyncPendingTokens.isEmpty }

    /// Acquire a reconciliation-in-flight token. Caller must release it (via
    /// `releaseSyncPending(_:)`, ideally in a `defer` wrapping the actual work scope)
    /// when done -- release is idempotent, so it's safe to call even if the work was
    /// cancelled partway through.
    @discardableResult
    func acquireSyncPending() -> Int {
        nextSyncPendingToken += 1
        let token = nextSyncPendingToken
        activeSyncPendingTokens.insert(token)
        return token
    }

    /// Idempotent: releasing an already-released (or never-acquired/foreign) token is a
    /// safe no-op -- it can never clear a DIFFERENT, still-active acquirer's token.
    func releaseSyncPending(_ token: Int) {
        activeSyncPendingTokens.remove(token)
    }

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
    func contentChanged(_ markdown: String, zoomedIds: Set<String>? = nil, suppressReconcile: Bool = false) {
        // Skip if content transition is in progress (drag, zoom, etc.)
        guard !(editorState?.isBusy ?? false) else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        // P2: the token must be acquired ONLY once a debounce is actually scheduled --
        // both early returns above must never acquire one (a skipped call means no
        // reconciliation work is actually pending).
        debounceTask?.cancel()
        debounceGeneration += 1
        let myGeneration = debounceGeneration
        let syncPendingToken = acquireSyncPending()
        debounceTask = Task {
            // M2: single owner via defer, releasing exactly the token THIS acquisition
            // got -- unconditional, no generation-matching needed (see isSyncPending's
            // doc comment for why the old generation-matching scheme was unsound).
            defer { self.releaseSyncPending(syncPendingToken) }
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            // Double-check: if another contentChanged fired during sleep, skip
            guard self.debounceGeneration == myGeneration else { return }
            await syncContent(markdown, zoomedIds: zoomedIds, fromEditorChange: true, suppressReconcile: suppressReconcile)
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
    /// - Parameter suppressReconcile: P3 §4d -- see `syncContent`'s matching parameter doc
    ///   comment. Exposed here too (not just the debounced `contentChanged` path) so any
    ///   caller can request suppression, and so this entry point is directly testable.
    func syncNow(_ markdown: String, fromEditorChange: Bool = false, suppressReconcile: Bool = false) async {
        // M2: this cancels any pending debounce task directly (cancellation still runs
        // THAT task's own `defer`, releasing only ITS OWN token -- see isSyncPending's
        // doc comment), then acquires its OWN token for its own work scope, wrapped in
        // `defer` here. No generation bookkeeping needed either way.
        debounceTask?.cancel()
        let syncPendingToken = acquireSyncPending()
        defer { releaseSyncPending(syncPendingToken) }
        await syncContent(markdown, fromEditorChange: fromEditorChange, suppressReconcile: suppressReconcile)
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

            // Falls back to the `block` table's own bibliography heading (the authoritative
            // signal) when `section` hasn't reconciled one yet -- see
            // `fetchBibliographyHeadingTitle`'s doc comment for why (the "first citation ever"
            // gap, 2026-08-22).
            let existingBibTitle = try dbSections.first(where: { $0.isBibliography })?.title
                ?? db.fetchBibliographyHeadingTitle(projectId: pid)
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
    /// - Parameter suppressReconcile: P3 §4d (undo-mode-switch-focus second timing gap).
    ///   When true, skips ONLY steps 3-4 below (reconcile + applySectionChanges) --
    ///   step 5 (the DB content-of-record persist) ALWAYS runs regardless, or undone
    ///   text would never reach the database and `updateSourceContentIfNeeded()` could
    ///   later resurrect stale content. Set true when the content that triggered this
    ///   sync came from an undo (the user just stepped back through an automatic
    ///   correction, per P3's undoable-derived-correction fix) -- reconciling immediately
    ///   would otherwise re-detect and re-apply the very correction just undone, before
    ///   the user's next Cmd-Z can reach their own original typing.
    private func syncContent(_ markdown: String, zoomedIds: Set<String>? = nil, fromEditorChange: Bool = false, suppressReconcile: Bool = false) async {
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

                // 2. Parse headers from markdown (pass existing bibliography/notes title for
                // detection). Falls back to the `block` table's own bibliography heading when
                // `section` hasn't reconciled one yet -- see `fetchBibliographyHeadingTitle`'s
                // doc comment for why (the "first citation ever" gap, 2026-08-22).
                let existingBibTitle = try dbSections.first(where: { $0.isBibliography })?.title
                    ?? db.fetchBibliographyHeadingTitle(projectId: pid)
                let existingNotesTitle = dbSections.first(where: { $0.isNotes })?.title
                let headers = SectionSyncService.parseHeaders(
                    from: markdown, existingBibTitle: existingBibTitle,
                    existingNotesTitle: existingNotesTitle, fallbackBibTitle: fallbackBibTitle)

                // 3-4. Reconcile + apply -- skipped entirely while suppressed (§4d). Guarded
                // on `!headers.isEmpty` same as before, only now nested under the
                // suppression check rather than an early return, since step 5 below must
                // still run even when headers is empty or suppression is active.
                if !suppressReconcile && !headers.isEmpty {
                    let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: pid)
                    if !changes.isEmpty {
                        try db.applySectionChanges(changes, for: pid)
                    }
                }

                // 5. Save full content to database ONLY when not zoomed -- ALWAYS runs,
                // suppression or not (content-of-record is never suppressed).
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

                // Parse zoomed markdown to extract section content (pass bibliography/notes
                // title for detection). Same `block`-table fallback as the non-zoomed path --
                // see `fetchBibliographyHeadingTitle`'s doc comment.
                let existingBibTitle = try existingSections.first(where: { $0.isBibliography })?.title
                    ?? db.fetchBibliographyHeadingTitle(projectId: pid)
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
