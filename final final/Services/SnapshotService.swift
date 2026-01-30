//
//  SnapshotService.swift
//  final final
//
//  Service for creating, restoring, and pruning version snapshots.
//

import Foundation

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
    /// - Returns: The created snapshot
    @discardableResult
    func createManualSnapshot(name: String) throws -> Snapshot {
        guard let content = try database.fetchContent(for: projectId) else {
            throw SnapshotError.noContent
        }
        let sections = try database.fetchSections(projectId: projectId)

        return try database.createSnapshot(
            projectId: projectId,
            name: name,
            isAutomatic: false,
            content: content,
            sections: sections
        )
    }

    /// Create an automatic backup snapshot
    /// - Returns: The created snapshot
    @discardableResult
    func createAutoSnapshot() throws -> Snapshot {
        guard let content = try database.fetchContent(for: projectId) else {
            throw SnapshotError.noContent
        }
        let sections = try database.fetchSections(projectId: projectId)

        return try database.createSnapshot(
            projectId: projectId,
            name: nil,
            isAutomatic: true,
            content: content,
            sections: sections
        )
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

        // Collect IDs to delete
        for snapshot in autoSnapshots {
            if !snapshotsToKeep.contains(snapshot.id) {
                snapshotsToDelete.append(snapshot.id)
            }
        }

        // Delete old snapshots
        if !snapshotsToDelete.isEmpty {
            try database.deleteSnapshots(ids: snapshotsToDelete)
            print("[SnapshotService] Pruned \(snapshotsToDelete.count) auto-backups")
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
    private func rebuildContentFromSections() throws {
        let sections = try database.fetchSections(projectId: projectId)
        let markdown = sections
            .map { $0.markdownContent }
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
