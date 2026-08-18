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

    /// Live editor state, used to flush fresh WebView content before an idle-timeout
    /// auto-backup reads the block table. Weak: this service doesn't own the editor's lifecycle.
    weak var editorState: EditorViewState?

    // MARK: - Configuration

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
        self.projectId = projectId
        self.snapshotService = SnapshotService(database: database, projectId: projectId)
        self.lastBackupTime = nil
        self.hasUnsavedChanges = false
        cancelIdleTimer()

        // Startup sweep (plan §4.4/§9, Phase 5): previously the only `pruneAutoBackups()` call
        // site was the 60s idle-timeout path below, so a project opened and closed within that
        // window (or opened right after a relaunch) could go arbitrarily long without a prune
        // pass. `SnapshotService`'s undo-point pin set is in-memory and always starts EMPTY on
        // a fresh launch (see `pinUndoPointSnapshot`'s doc comment) -- so there is no separate
        // "orphaned row" concept to detect or delete here: every undo-point snapshot a PRIOR
        // session pinned is, by definition, unpinned the moment this process starts, and this
        // ordinary `pruneAutoBackups()` call already treats it exactly like any other
        // auto-backup on its usual Time-Machine-style schedule. Best-effort (`try?`, matching
        // the idle-timeout call site) -- a failed prune here isn't worth surfacing to the user
        // on project open, and the idle-timeout path will retry later anyway.
        try? snapshotService?.pruneAutoBackups()
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

    // MARK: - Backup Creation
    // `createBackupIfNeeded`/`createAutoBackup` are `internal` (not `private`) so tests can
    // drive the idle-timeout path directly, matching `SnapshotService`'s create methods.

    /// Create a backup if conditions are met.
    /// - Parameter needsLiveFlush: When true (the idle-timeout path only), flushes fresh
    ///   WebView content into the block table before snapshotting -- see
    ///   `EditorViewState.flushLiveContentToDatabase(currentContent:)`. Placed after the
    ///   guards below so an idle timeout with nothing to back up doesn't pay a gratuitous
    ///   WebView round-trip. The lifecycle callers (close/quit/switch) default this to
    ///   false because each already has an equivalent flush upstream in its own caller.
    func createBackupIfNeeded(reason: String, needsLiveFlush: Bool = false) async {
        guard hasUnsavedChanges else {
            DebugLog.log(.backup, "[AutoBackupService] No unsaved changes, skipping backup on \(reason)")
            return
        }

        guard canCreateBackup() else {
            DebugLog.log(.backup, "[AutoBackupService] Too soon since last backup, skipping on \(reason)")
            return
        }

        await createAutoBackup(reason: reason, needsLiveFlush: needsLiveFlush)
    }

    /// Check if enough time has passed since last backup
    private func canCreateBackup() -> Bool {
        guard let lastBackup = lastBackupTime else { return true }
        return Date().timeIntervalSince(lastBackup) >= minimumBackupInterval
    }

    /// Actually create the auto-backup
    func createAutoBackup(reason: String, needsLiveFlush: Bool = false) async {
        guard let service = snapshotService else {
            DebugLog.log(.backup, "[AutoBackupService] No snapshot service configured")
            return
        }

        if needsLiveFlush, let editorState {
            await editorState.flushLiveContentToDatabase {
                await editorState.blockSyncService?.fetchContentFromWebView()
            }
        }

        do {
            if let snapshot = try service.createAutoSnapshot() {
                DebugLog.log(.backup, "[AutoBackupService] Created auto-backup on \(reason): \(snapshot.id)")
            } else {
                DebugLog.log(.backup, "[AutoBackupService] Skipped auto-backup on \(reason): content unchanged")
            }
            // Update state regardless — content is genuinely unchanged or saved
            lastBackupTime = Date()
            hasUnsavedChanges = false
        } catch {
            DebugLog.log(.backup, "[AutoBackupService] Failed to create auto-backup: \(error)")
        }
    }

    /// Start or restart the idle timer
    private func restartIdleTimer() {
        cancelIdleTimer()

        idleTask = Task {
            do {
                try await Task.sleep(for: .seconds(idleTimeout))
                guard !Task.isCancelled else { return }
                await createBackupIfNeeded(reason: "idle timeout", needsLiveFlush: true)
                // Prune old backups only on idle path to avoid slowing project switch/quit
                try? snapshotService?.pruneAutoBackups()
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
