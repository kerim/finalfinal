//
//  SnapshotService.swift
//  final final
//
//  Service for creating, restoring, and pruning version snapshots.
//

import Foundation
import CryptoKit

/// Service for managing version snapshots (create, restore, prune)
@MainActor
final class SnapshotService {

    private let database: ProjectDatabase
    private let projectId: String

    init(database: ProjectDatabase, projectId: String) {
        self.database = database
        self.projectId = projectId
    }

    // MARK: - Create Snapshots

    /// Create a manual (named) snapshot of the current project state
    /// - Parameter name: User-provided name for the version
    /// - Returns: The created snapshot (always creates, never skipped)
    @discardableResult
    func createManualSnapshot(name: String) throws -> Snapshot {
        // Assemble fresh markdown from blocks (source of truth, avoids stale content.markdown)
        // assembleMarkdownForEditor (not plain assembleMarkdown): the snapshot's stored
        // previewMarkdown is reparsed via BlockParser.parse() on restore, so it must carry
        // the bibliography-end terminator when the doc ends in bibliography content — see
        // BlockParser.bibliographyEndMarker's doc comment.
        let blocks = try database.fetchBlocks(projectId: projectId)
        let assembledMarkdown = BlockParser.assembleMarkdownForEditor(from: blocks)

        // Save to content table to keep it in sync
        try database.saveContent(markdown: assembledMarkdown, for: projectId)

        // Re-fetch Content record (needed for createSnapshot's content: parameter)
        guard let content = try database.fetchContent(for: projectId) else {
            throw SnapshotError.noContent
        }

        let hash = Self.computeHash(assembledMarkdown)

        // Use actual sections from database (preserves real IDs for comparison tracking)
        let sections = try database.fetchSections(projectId: projectId)
        DebugLog.log(.backup, "[SnapshotService] createManualSnapshot: \(sections.count) sections from database, \(blocks.count) blocks")

        return try database.createSnapshot(
            projectId: projectId,
            name: name,
            isAutomatic: false,
            content: content,
            sections: sections,
            contentHash: hash
        )
    }

    /// Create an automatic backup snapshot
    /// - Returns: The created snapshot, or nil if content is identical to the latest snapshot
    @discardableResult
    func createAutoSnapshot() throws -> Snapshot? {
        // Assemble fresh markdown from blocks (source of truth, avoids stale content.markdown)
        // assembleMarkdownForEditor (not plain assembleMarkdown): see createManualSnapshot's
        // comment above.
        let blocks = try database.fetchBlocks(projectId: projectId)
        let assembledMarkdown = BlockParser.assembleMarkdownForEditor(from: blocks)

        let hash = Self.computeHash(assembledMarkdown)

        // Skip if content hasn't changed since last snapshot
        if let latestHash = try database.fetchLatestSnapshotHash(projectId: projectId),
           !latestHash.isEmpty,
           latestHash == hash {
            DebugLog.log(.backup, "[SnapshotService] Skipping auto-snapshot: content unchanged")
            return nil
        }

        // Save to content table to keep it in sync
        try database.saveContent(markdown: assembledMarkdown, for: projectId)

        // Re-fetch Content record (needed for createSnapshot's content: parameter)
        guard let content = try database.fetchContent(for: projectId) else {
            throw SnapshotError.noContent
        }

        // Use actual sections from database (preserves real IDs for comparison tracking)
        let sections = try database.fetchSections(projectId: projectId)
        DebugLog.log(.backup, "[SnapshotService] createAutoSnapshot: \(sections.count) sections from database, \(blocks.count) blocks")

        return try database.createSnapshot(
            projectId: projectId,
            name: nil,
            isAutomatic: true,
            content: content,
            sections: sections,
            contentHash: hash
        )
    }

    /// Create a snapshot for the unified undo timeline (plan §4.4 step 4 / §4.4 undo step 2).
    /// Unlike `createAutoSnapshot()`, this NEVER skips on unchanged-content hash: an undo/redo
    /// point snapshot must exist every time it's requested so the timeline's inverse payload is
    /// always available, even when the document is byte-identical to the latest auto-backup
    /// (e.g. two structural ops in a row with no user typing between them, or undo immediately
    /// followed by redo). `createAutoSnapshot()`'s dedup hash-skip only compares
    /// `content.markdown`, which ignores Section metadata (status/tags/wordGoal) entirely --
    /// reusing "the latest snapshot by hash" here could silently hand back a snapshot whose
    /// metadata predates a metadata-only edit, which is exactly the trap plan §2/§4.4 warns
    /// against ("never 'reuse latest by hash'").
    /// - Returns: The created snapshot's id, always non-nil (this never returns nil the way
    ///   `createAutoSnapshot()` can).
    @discardableResult
    func createUndoPointSnapshot() throws -> String {
        // Assemble fresh markdown from blocks (source of truth) -- same pattern as
        // createManualSnapshot/createAutoSnapshot above.
        let blocks = try database.fetchBlocks(projectId: projectId)
        let assembledMarkdown = BlockParser.assembleMarkdownForEditor(from: blocks)

        try database.saveContent(markdown: assembledMarkdown, for: projectId)

        guard let content = try database.fetchContent(for: projectId) else {
            throw SnapshotError.noContent
        }

        let hash = Self.computeHash(assembledMarkdown)
        let sections = try database.fetchSections(projectId: projectId)
        DebugLog.log(.undo, "[SnapshotService] createUndoPointSnapshot: \(sections.count) sections, \(blocks.count) blocks (no dedup skip)")

        let snapshot = try database.createSnapshot(
            projectId: projectId,
            name: nil,
            isAutomatic: true,
            content: content,
            sections: sections,
            contentHash: hash
        )
        // Pin immediately (plan §4.4/§9): every undo-point snapshot is referenced by a live
        // `StructuralEntry` on `UnifiedUndoService`'s stacks the instant this returns, so it
        // must never be silently pruned by `pruneAutoBackups()`'s Time-Machine-style retention
        // -- see `pinUndoPointSnapshot`'s doc comment for the full reasoning.
        Self.pinUndoPointSnapshot(snapshot.id)
        return snapshot.id
    }

    // MARK: - Undo-point pin set (plan §4.4/§9)

    /// In-memory set of undo/redo-point snapshot ids currently referenced by a live
    /// `StructuralEntry` somewhere on `UnifiedUndoService`'s undo/redo stacks. Exempts them
    /// from `pruneAutoBackups()` below. They are ordinary `isAutomatic` rows -- no schema
    /// change (plan §9: "no schema migration") -- indistinguishable from a regular auto-backup
    /// except by this in-memory set, so pinning (and unpinning, owned by `UnifiedUndoService`)
    /// is the only thing standing between a forced undo-point snapshot and normal pruning.
    ///
    /// Deliberately in-memory, never persisted: pins die with the session exactly like the
    /// undo timeline itself does (plan §4.8, no cross-relaunch persistence). This is why no
    /// separate "startup sweep" needs to delete anything at launch -- a relaunch starts with
    /// an EMPTY pin set (this is a `static var`, reset by process restart), so every row a
    /// prior session pinned simply rejoins the normal auto-backup population the next time
    /// `pruneAutoBackups()` runs and prunes on its usual schedule. `AutoBackupService.configure()`
    /// now also runs one prune pass on project open (in addition to the existing idle-timeout
    /// path) specifically so that "the next time it runs" isn't gated on 60s of user idle time
    /// after a relaunch.
    private static var pinnedUndoPointSnapshotIds: Set<String> = []

    static func pinUndoPointSnapshot(_ id: String) {
        pinnedUndoPointSnapshotIds.insert(id)
    }

    /// No-op if `id` isn't pinned (e.g. a snapshot that failed to create, or an id already
    /// unpinned by an earlier barrier) -- every call site treats this as idempotent cleanup.
    static func unpinUndoPointSnapshot(_ id: String) {
        pinnedUndoPointSnapshotIds.remove(id)
    }

    #if DEBUG
    /// Test-only accessor, mirroring `UnifiedUndoService`'s own `#if DEBUG` test hooks.
    static var pinnedUndoPointSnapshotIdsForTesting: Set<String> { pinnedUndoPointSnapshotIds }
    #endif

    // MARK: - Hash Computation

    /// Compute SHA256 hash of content for deduplication
    static func computeHash(_ content: String) -> String {
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fetch Snapshots

    /// Get all snapshots for this project
    func fetchAllSnapshots() throws -> [Snapshot] {
        try database.fetchSnapshots(projectId: projectId)
    }

    /// Get only named (manual) snapshots
    func fetchNamedSnapshots() throws -> [Snapshot] {
        try database.fetchNamedSnapshots(projectId: projectId)
    }

    /// Get snapshot sections for a specific snapshot
    func fetchSections(for snapshotId: String) throws -> [SnapshotSection] {
        try database.fetchSnapshotSections(snapshotId: snapshotId)
    }

    /// Get the most recent auto-backup
    func fetchMostRecentAutoSnapshot() throws -> Snapshot? {
        try database.fetchMostRecentAutoSnapshot(projectId: projectId)
    }

    // MARK: - Restore Operations

    /// Restore an entire project from a snapshot
    /// - Parameters:
    ///   - snapshotId: ID of the snapshot to restore
    ///   - createSafetyBackup: If true, creates an auto-backup of current state first
    func restoreEntireProject(from snapshotId: String, createSafetyBackup: Bool = true) throws {
        guard let snapshot = try database.fetchSnapshot(id: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }

        // Create safety backup of current state before restoring
        if createSafetyBackup {
            try createAutoSnapshot()
        }

        // Restore content.markdown
        try database.saveContent(markdown: snapshot.previewMarkdown, for: projectId)

        // Get snapshot sections and restore them
        let snapshotSections = try database.fetchSnapshotSections(snapshotId: snapshotId)

        // Delete all current sections and insert from snapshot
        try database.deleteAllSections(projectId: projectId)

        for snapshotSection in snapshotSections {
            let section = Section(
                projectId: projectId,
                sortOrder: snapshotSection.sortOrder,
                headerLevel: snapshotSection.headerLevel,
                title: snapshotSection.title,
                markdownContent: snapshotSection.markdownContent,
                status: snapshotSection.status ?? .next,
                tags: snapshotSection.tags,
                wordGoal: snapshotSection.wordGoal,
                wordCount: MarkdownUtils.wordCount(for: snapshotSection.markdownContent)
            )
            try database.insertSection(section)
        }

        // Rebuild blocks from restored content to keep blocks table in sync.
        // Build metadata from snapshot sections to preserve status/tags/wordGoal.
        var metadata: [String: SectionMetadata] = [:]
        for snapshotSection in snapshotSections {
            metadata[snapshotSection.title] = SectionMetadata(
                status: snapshotSection.status,
                tags: snapshotSection.tags.isEmpty ? nil : snapshotSection.tags,
                wordGoal: snapshotSection.wordGoal
            )
        }
        // C5: highest-stakes `BlockParser.parse` site (full snapshot restore) -- threads the
        // DB-resolved Notes title so an already-recognized, non-default-titled Notes heading
        // (see `fetchNotesHeadingTitle`'s doc comment) is still recognized after restore,
        // same as `bibliographyHeaderName` would be threaded if this call needed a custom
        // bibliography name (it doesn't; `ExportSettings.load()`'s default already covers it).
        let blocks = BlockParser.parse(
            markdown: snapshot.previewMarkdown,
            projectId: projectId,
            existingSectionMetadata: metadata.isEmpty ? nil : metadata,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )
        try database.replaceBlocks(blocks, for: projectId)
    }

    /// Restore a single section from a snapshot, replacing the current matching section
    /// - Parameters:
    ///   - snapshotSectionId: ID of the snapshot section to restore
    ///   - targetSectionId: ID of the current section to replace
    ///   - createSafetyBackup: If true, creates an auto-backup first
    func restoreSectionReplace(
        snapshotSectionId: String,
        targetSectionId: String,
        createSafetyBackup: Bool = true
    ) throws {
        guard let snapshotSection = try database.fetchSnapshotSection(id: snapshotSectionId) else {
            throw SnapshotError.sectionNotFound
        }

        guard var targetSection = try database.fetchSection(id: targetSectionId) else {
            throw SnapshotError.targetSectionNotFound
        }

        // Create safety backup
        if createSafetyBackup {
            try createAutoSnapshot()
        }

        // Replace content, preserving position and metadata
        targetSection.markdownContent = snapshotSection.markdownContent
        targetSection.title = snapshotSection.title
        targetSection.wordCount = MarkdownUtils.wordCount(for: snapshotSection.markdownContent)

        try database.updateSection(targetSection)

        // Rebuild content.markdown from sections
        try rebuildContentFromSections()

        // Rebuild blocks from the new content
        guard let contentRecord = try database.fetchContent(for: projectId) else { return }
        let sections = try database.fetchSections(projectId: projectId)
        var metadata: [String: SectionMetadata] = [:]
        for section in sections { metadata[section.title] = SectionMetadata(from: section) }
        // C5: see `restoreLatestFullSnapshot`'s matching call above for why this threads
        // `notesHeaderName`.
        let blocks = BlockParser.parse(
            markdown: contentRecord.markdown, projectId: projectId,
            existingSectionMetadata: metadata.isEmpty ? nil : metadata,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )
        // preservingMachineManagedBlocks: true -- rebuildContentFromSections (above) excludes
        // isBibliography AND isNotes sections from contentRecord.markdown, so `blocks` here has
        // NO bibliography or Notes content at all. An unconditional replaceBlocks would
        // permanently wipe the real bibliography (owned by BibliographySyncService) and the
        // real footnote text (owned by FootnoteSyncService) instead of leaving them alone --
        // see replaceBlocks' doc comment. This dependency is load-bearing: replaceBlocks'
        // preservation machinery here assumes `blocks` carries no machine-managed content at
        // all, so it never has to reconcile a fresh copy against the preserved rows.
        try database.replaceBlocks(blocks, for: projectId, preservingMachineManagedBlocks: true)
    }

    /// Restore a section from a snapshot as a new duplicate section
    /// - Parameters:
    ///   - snapshotSectionId: ID of the snapshot section to restore
    ///   - insertAfterSectionId: ID of the section after which to insert (nil = end of document)
    ///   - createSafetyBackup: If true, creates an auto-backup first
    func restoreSectionAsDuplicate(
        snapshotSectionId: String,
        insertAfterSectionId: String?,
        createSafetyBackup: Bool = true
    ) throws {
        guard let snapshotSection = try database.fetchSnapshotSection(id: snapshotSectionId) else {
            throw SnapshotError.sectionNotFound
        }

        // Create safety backup
        if createSafetyBackup {
            try createAutoSnapshot()
        }

        // Determine sort order for new section
        let allSections = try database.fetchSections(projectId: projectId)
        let newSortOrder: Int

        if let afterId = insertAfterSectionId,
           let afterSection = allSections.first(where: { $0.id == afterId }) {
            newSortOrder = afterSection.sortOrder + 1
            // Shift subsequent sections
            try shiftSectionsAfter(sortOrder: afterSection.sortOrder)
        } else {
            // Insert at end
            newSortOrder = (allSections.last?.sortOrder ?? -1) + 1
        }

        // Create new section from snapshot
        let newSection = Section(
            projectId: projectId,
            sortOrder: newSortOrder,
            headerLevel: snapshotSection.headerLevel,
            title: snapshotSection.title,
            markdownContent: snapshotSection.markdownContent,
            status: snapshotSection.status ?? .next,
            tags: snapshotSection.tags,
            wordGoal: snapshotSection.wordGoal,
            wordCount: MarkdownUtils.wordCount(for: snapshotSection.markdownContent)
        )

        try database.insertSection(newSection)

        // Rebuild content.markdown
        try rebuildContentFromSections()

        // Rebuild blocks from the new content
        guard let contentRecord = try database.fetchContent(for: projectId) else { return }
        let allSectionsAfter = try database.fetchSections(projectId: projectId)
        var metadataForBlocks: [String: SectionMetadata] = [:]
        for section in allSectionsAfter { metadataForBlocks[section.title] = SectionMetadata(from: section) }
        // C5: see `restoreLatestFullSnapshot`'s matching call above for why this threads
        // `notesHeaderName`.
        let blocks = BlockParser.parse(
            markdown: contentRecord.markdown, projectId: projectId,
            existingSectionMetadata: metadataForBlocks.isEmpty ? nil : metadataForBlocks,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )
        // preservingMachineManagedBlocks: true -- see restoreSectionReplace's matching call
        // for why (rebuildContentFromSections excludes bibliography AND Notes from this
        // markdown -- load-bearing, not cosmetic; see that function's doc comment).
        try database.replaceBlocks(blocks, for: projectId, preservingMachineManagedBlocks: true)
    }

    // MARK: - Pruning

    /// Prune old auto-backups using Time Machine-style retention:
    /// - Keep all from last 24 hours
    /// - Keep last one per day for past 7 days
    /// - Keep last one per week for past 4 weeks
    /// - Keep last one per month beyond that
    /// Named (manual) saves are never pruned.
    func pruneAutoBackups() throws {
        let autoSnapshots = try database.fetchAutoSnapshots(projectId: projectId)
        guard !autoSnapshots.isEmpty else { return }

        let now = Date()
        let calendar = Calendar.current

        var snapshotsToKeep = Set<String>()
        var snapshotsToDelete: [String] = []

        // Group snapshots by time period
        let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
        let oneWeekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let fourWeeksAgo = calendar.date(byAdding: .day, value: -28, to: now)!

        // Keep all from last 24 hours
        for snapshot in autoSnapshots where snapshot.createdAt >= oneDayAgo {
            snapshotsToKeep.insert(snapshot.id)
        }

        // Keep last one per day for past 7 days
        let pastWeek = autoSnapshots.filter { $0.createdAt < oneDayAgo && $0.createdAt >= oneWeekAgo }
        let byDay = Dictionary(grouping: pastWeek) { snapshot in
            calendar.startOfDay(for: snapshot.createdAt)
        }
        for (_, daySnapshots) in byDay {
            if let latest = daySnapshots.max(by: { $0.createdAt < $1.createdAt }) {
                snapshotsToKeep.insert(latest.id)
            }
        }

        // Keep last one per week for past 4 weeks
        let pastMonth = autoSnapshots.filter { $0.createdAt < oneWeekAgo && $0.createdAt >= fourWeeksAgo }
        let byWeek = Dictionary(grouping: pastMonth) { snapshot in
            calendar.component(.weekOfYear, from: snapshot.createdAt)
        }
        for (_, weekSnapshots) in byWeek {
            if let latest = weekSnapshots.max(by: { $0.createdAt < $1.createdAt }) {
                snapshotsToKeep.insert(latest.id)
            }
        }

        // Keep last one per month beyond 4 weeks
        let olderSnapshots = autoSnapshots.filter { $0.createdAt < fourWeeksAgo }
        let byMonth = Dictionary(grouping: olderSnapshots) { snapshot in
            let components = calendar.dateComponents([.year, .month], from: snapshot.createdAt)
            return "\(components.year ?? 0)-\(components.month ?? 0)"
        }
        for (_, monthSnapshots) in byMonth {
            if let latest = monthSnapshots.max(by: { $0.createdAt < $1.createdAt }) {
                snapshotsToKeep.insert(latest.id)
            }
        }

        // Collect IDs to delete -- excluding anything currently pinned as a live undo/redo-point
        // snapshot (plan §4.4/§9: forced undo-point snapshots must not be silently pruned like
        // automatic ones, even when the Time-Machine-style retention above would otherwise have
        // dropped them).
        for snapshot in autoSnapshots
        where !snapshotsToKeep.contains(snapshot.id) && !Self.pinnedUndoPointSnapshotIds.contains(snapshot.id) {
            snapshotsToDelete.append(snapshot.id)
        }

        // Delete old snapshots
        if !snapshotsToDelete.isEmpty {
            try database.deleteSnapshots(ids: snapshotsToDelete)
            DebugLog.log(.backup, "[SnapshotService] Pruned \(snapshotsToDelete.count) auto-backups")
        }
    }

    // MARK: - Private Helpers

    /// Shift all sections after a given sortOrder up by 1
    private func shiftSectionsAfter(sortOrder: Int) throws {
        let sections = try database.fetchSections(projectId: projectId)
        var changes: [SectionChange] = []

        for section in sections where section.sortOrder > sortOrder {
            changes.append(.update(
                id: section.id,
                updates: SectionUpdates(sortOrder: section.sortOrder + 1)
            ))
        }

        if !changes.isEmpty {
            try database.applySectionChanges(changes, for: projectId)
        }
    }

    /// Rebuild content.markdown from current sections
    ///
    /// Excludes `isBibliography`- and `isNotes`-flagged rows: that content is a frozen,
    /// potentially-stale mirror of the machine-managed bibliography/footnotes (the real
    /// content lives at the `block` level, owned by `BibliographySyncService`/
    /// `FootnoteSyncService`). Re-emitting it here on a version-history restore would
    /// resurrect a stale copy instead of leaving the real one alone.
    ///
    /// LOAD-BEARING, not cosmetic: both call sites below (`restoreSectionReplace`,
    /// `restoreSectionAsDuplicate`) re-parse the markdown this produces and feed the result
    /// into `replaceBlocks(..., preservingMachineManagedBlocks: true)`. That call's own
    /// preservation machinery depends on `blocks` containing NO isBibliography/isNotes
    /// content at these two call sites -- see `replaceBlocks`' doc comment. If this filter
    /// ever again excluded only `isBibliography`, a Notes row's real markdown (now that
    /// `Section.isNotes` has a production writer -- see `SectionReconciler`) would flow back
    /// into `blocks` here, colliding with `replaceBlocks`' own Notes preservation and
    /// duplicating footnote content on every single-section restore.
    private func rebuildContentFromSections() throws {
        let sections = try database.fetchSections(projectId: projectId)
        let markdown = sections
            .filter { !$0.isBibliography && !$0.isNotes }
            .map { MarkdownUtils.ensuringTrailingBlankLine($0.markdownContent) }
            .joined()

        try database.saveContent(markdown: markdown, for: projectId)
    }
}

// MARK: - Errors

enum SnapshotError: Error, LocalizedError {
    case noContent
    case snapshotNotFound
    case sectionNotFound
    case targetSectionNotFound

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "No content found for project"
        case .snapshotNotFound:
            return "Snapshot not found"
        case .sectionNotFound:
            return "Snapshot section not found"
        case .targetSectionNotFound:
            return "Target section not found in current project"
        }
    }
}
