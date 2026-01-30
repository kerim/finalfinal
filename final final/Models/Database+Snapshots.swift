//
//  Database+Snapshots.swift
//  final final
//
//  Snapshot CRUD operations for ProjectDatabase.
//

import Foundation
import GRDB

// MARK: - ProjectDatabase Snapshot CRUD

extension ProjectDatabase {

    // MARK: - Fetch Operations

    /// Fetch all snapshots for a project, sorted by creation date (newest first)
    func fetchSnapshots(projectId: String) throws -> [Snapshot] {
        try read { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .order(Snapshot.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch only named (manual) snapshots for a project
    func fetchNamedSnapshots(projectId: String) throws -> [Snapshot] {
        try read { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .filter(Snapshot.Columns.name != nil)
                .order(Snapshot.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch only automatic snapshots for a project
    func fetchAutoSnapshots(projectId: String) throws -> [Snapshot] {
        try read { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .filter(Snapshot.Columns.isAutomatic == true)
                .order(Snapshot.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single snapshot by ID
    func fetchSnapshot(id: String) throws -> Snapshot? {
        try read { db in
            try Snapshot.fetchOne(db, key: id)
        }
    }

    /// Fetch the most recent auto-backup for a project
    func fetchMostRecentAutoSnapshot(projectId: String) throws -> Snapshot? {
        try read { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .filter(Snapshot.Columns.isAutomatic == true)
                .order(Snapshot.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }

    /// Count snapshots for a project
    func countSnapshots(projectId: String) throws -> Int {
        try read { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .fetchCount(db)
        }
    }

    // MARK: - SnapshotSection Operations

    /// Fetch all sections for a snapshot, sorted by sortOrder
    func fetchSnapshotSections(snapshotId: String) throws -> [SnapshotSection] {
        try read { db in
            try SnapshotSection
                .filter(SnapshotSection.Columns.snapshotId == snapshotId)
                .order(SnapshotSection.Columns.sortOrder)
                .fetchAll(db)
        }
    }

    /// Fetch a single snapshot section by ID
    func fetchSnapshotSection(id: String) throws -> SnapshotSection? {
        try read { db in
            try SnapshotSection.fetchOne(db, key: id)
        }
    }

    // MARK: - Insert Operations

    /// Create a snapshot with all its sections in a single transaction
    func createSnapshot(
        projectId: String,
        name: String?,
        isAutomatic: Bool,
        content: Content,
        sections: [Section]
    ) throws -> Snapshot {
        try write { db in
            // Create the snapshot
            var snapshot = Snapshot(
                projectId: projectId,
                name: name,
                isAutomatic: isAutomatic,
                previewMarkdown: content.markdown
            )
            try snapshot.insert(db)

            // Create snapshot sections from current sections
            for section in sections {
                var snapshotSection = SnapshotSection(from: section, snapshotId: snapshot.id)
                try snapshotSection.insert(db)
            }

            return snapshot
        }
    }

    // MARK: - Delete Operations

    /// Delete a snapshot (CASCADE deletes its sections)
    func deleteSnapshot(id: String) throws {
        try write { db in
            try Snapshot.deleteOne(db, key: id)
        }
    }

    /// Delete multiple snapshots by ID
    func deleteSnapshots(ids: [String]) throws {
        try write { db in
            try Snapshot
                .filter(ids.contains(Snapshot.Columns.id))
                .deleteAll(db)
        }
    }

    /// Delete all snapshots for a project
    func deleteAllSnapshots(projectId: String) throws {
        try write { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .deleteAll(db)
        }
    }

    /// Delete automatic snapshots older than a given date
    func deleteAutoSnapshotsOlderThan(_ date: Date, projectId: String) throws {
        try write { db in
            try Snapshot
                .filter(Snapshot.Columns.projectId == projectId)
                .filter(Snapshot.Columns.isAutomatic == true)
                .filter(Snapshot.Columns.createdAt < date)
                .deleteAll(db)
        }
    }

    // MARK: - Reactive Observation

    /// Returns an async sequence of snapshot updates for reactive UI
    func observeSnapshots(for projectId: String) -> AsyncThrowingStream<[Snapshot], Error> {
        let observation = ValueObservation
            .tracking { db in
                try Snapshot
                    .filter(Snapshot.Columns.projectId == projectId)
                    .order(Snapshot.Columns.createdAt.desc)
                    .fetchAll(db)
            }
            .removeDuplicates()

        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: .main)
            ) { error in
                continuation.finish(throwing: error)
            } onChange: { snapshots in
                continuation.yield(snapshots)
            }

            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
