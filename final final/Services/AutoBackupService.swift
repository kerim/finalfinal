//
//  AutoBackupService.swift
//  final final
//
//  Service for automatic backup creation based on idle time and lifecycle events.
//

import Foundation

/// Service for creating automatic backups based on idle time and lifecycle events.
/// Triggers auto-backup after 60 seconds of inactivity following changes,
/// with a minimum 5-minute interval between backups.
@MainActor
@Observable
final class AutoBackupService {

    /// Minimum time between auto-backups (5 minutes)
    private let minimumBackupInterval: TimeInterval = 5 * 60

    /// Idle time before triggering auto-backup (60 seconds)
    private let idleTimeout: TimeInterval = 60

    /// Whether there are unsaved changes since last backup
    private(set) var hasUnsavedChanges: Bool = false

    /// Timestamp of last auto-backup
    private var lastBackupTime: Date?

    /// Timer for idle detection
    private var idleTask: Task<Void, Never>?

    /// The snapshot service (set when project is opened)
    private var snapshotService: SnapshotService?

    /// Database and project info (for recreating service if needed)
    private weak var database: ProjectDatabase?
    private var projectId: String?

    // MARK: - Configuration

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
        self.projectId = projectId
        self.snapshotService = SnapshotService(database: database, projectId: projectId)
        self.lastBackupTime = nil
        self.hasUnsavedChanges = false
        cancelIdleTimer()
    }

    /// Reset when project is closed
    func reset() {
        cancelIdleTimer()
        snapshotService = nil
        database = nil
        projectId = nil
        hasUnsavedChanges = false
        lastBackupTime = nil
    }

    // MARK: - Content Change Tracking

    /// Called when content changes in the editor
    /// Starts/restarts the idle timer for auto-backup
    func contentDidChange() {
        hasUnsavedChanges = true
        restartIdleTimer()
    }

    /// Called when content is saved manually
    /// Resets the unsaved changes flag
    func contentDidSave() {
        hasUnsavedChanges = false
        cancelIdleTimer()
    }

    // MARK: - Lifecycle Events

    /// Called when project is about to close
    /// Creates auto-backup if there are unsaved changes
    func projectWillClose() async {
        await createBackupIfNeeded(reason: "project close")
    }

    /// Called when app is about to quit
    /// Creates auto-backup if there are unsaved changes
    func appWillQuit() async {
        await createBackupIfNeeded(reason: "app quit")
    }

    /// Called when switching to another project
    /// Creates auto-backup if there are unsaved changes
    func projectWillSwitch() async {
        await createBackupIfNeeded(reason: "project switch")
    }

    // MARK: - Private Methods

    /// Create a backup if conditions are met
    private func createBackupIfNeeded(reason: String) async {
        guard hasUnsavedChanges else {
            print("[AutoBackupService] No unsaved changes, skipping backup on \(reason)")
            return
        }

        guard canCreateBackup() else {
            print("[AutoBackupService] Too soon since last backup, skipping on \(reason)")
            return
        }

        await createAutoBackup(reason: reason)
    }

    /// Check if enough time has passed since last backup
    private func canCreateBackup() -> Bool {
        guard let lastBackup = lastBackupTime else { return true }
        return Date().timeIntervalSince(lastBackup) >= minimumBackupInterval
    }

    /// Actually create the auto-backup
    private func createAutoBackup(reason: String) async {
        guard let service = snapshotService else {
            print("[AutoBackupService] No snapshot service configured")
            return
        }

        do {
            let snapshot = try service.createAutoSnapshot()
            lastBackupTime = Date()
            hasUnsavedChanges = false
            print("[AutoBackupService] Created auto-backup on \(reason): \(snapshot.id)")

            // Prune old backups after creating new one
            try service.pruneAutoBackups()
        } catch {
            print("[AutoBackupService] Failed to create auto-backup: \(error)")
        }
    }

    /// Start or restart the idle timer
    private func restartIdleTimer() {
        cancelIdleTimer()

        idleTask = Task {
            do {
                try await Task.sleep(for: .seconds(idleTimeout))
                guard !Task.isCancelled else { return }
                await createBackupIfNeeded(reason: "idle timeout")
            } catch {
                // Task was cancelled, which is expected
            }
        }
    }

    /// Cancel the idle timer
    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }
}
