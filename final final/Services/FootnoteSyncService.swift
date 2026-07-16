//
//  FootnoteSyncService.swift
//  final final
//
//  Service for managing the # Notes section based on footnote references in the document.
//  Creates/removes the section and pushes definition texts to the editor for popup display.
//  Modeled on BibliographySyncService.swift.
//

import Foundation
import GRDB

/// State machine for footnote sync to prevent race conditions
enum FootnoteSyncState: Sendable {
    case idle
    case syncing
    case userEditPending
}

/// Snapshot captured when a debounced footnote update is scheduled but not yet consumed.
/// The `generation` always travels with the rest of the snapshot — see `flushPendingSync()`
/// and `handleImmediateInsertion` for why it must be the one captured at schedule time,
/// not a freshly-read `syncGeneration`.
private struct PendingFootnoteUpdate {
    let refs: [String]
    let projectId: String
    let fullContent: String
    let generation: Int
}

@MainActor
@Observable
final class FootnoteSyncService {
    // MARK: - State

    /// Current sync state
    private(set) var state: FootnoteSyncState = .idle

    /// Last known footnote ref labels (to prevent unnecessary updates)
    private var lastKnownRefs: [String] = []

    /// Hash of last renumbered content (feedback loop breaker)
    private var lastRenumberedHash: Int = 0

    /// Debounce timer for footnote updates
    private var debounceTask: Task<Void, Never>?

    /// Monotonic counter bumped by every immediate insertion. A debounced rebuild
    /// captures this at schedule time; if an immediate insertion has bumped it since,
    /// the debounced rebuild is stale and must not run.
    private var syncGeneration: Int = 0

    /// Debounce interval (3 seconds — longer than bibliography to let Notes edits settle)
    private let debounceInterval: TimeInterval = 3.0

    /// Snapshot captured at the moment a debounced update was scheduled but not yet
    /// consumed by `performFootnoteUpdate`. Cleared inside the debounce closure immediately
    /// before it fires, so `pendingUpdate != nil` reliably means "there is unconsumed
    /// scheduled work".
    private var pendingUpdate: PendingFootnoteUpdate?

    // MARK: - Dependencies

    weak var database: ProjectDatabase?

    // MARK: - Static Helpers
    //
    // The pre-compiled regexes and pure static parsing/reconciliation helpers live in
    // FootnoteSyncService+Reconciliation.swift.

    /// Build the Notes section markdown from DB blocks (heading + definitions)
    /// Returns nil if no notes blocks exist
    func buildNotesSectionMarkdown(projectId: String) -> String? {
        guard let database else { return nil }
        do {
            let notesBlocks = try database.read { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isNotes == true)
                    .order(Block.Columns.sortOrder)
                    .fetchAll(db)
            }
            guard !notesBlocks.isEmpty else { return nil }
            return BlockParser.assembleMarkdown(from: notesBlocks)
        } catch {
            DebugLog.log(.editor, "[FootnoteSyncService] Error building notes markdown: \(error)")
            return nil
        }
    }

    // MARK: - Public Methods

    /// Configure the service with a database
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
    }

    /// Called from onChange(of: editorState.content) — checks if footnotes need updating
    func checkAndUpdateFootnotes(
        footnoteRefs: [String],
        projectId: String,
        fullContent: String
    ) {
        guard state == .idle else {
            return
        }

        // Check if refs have changed
        guard footnoteRefs != lastKnownRefs else {
            // Even if refs haven't changed, we should still push definitions
            // for tooltip display (definitions may have been edited in #Notes)
            pushDefinitionsToEditor(fullContent: fullContent)
            return
        }

        // Debounce the update
        let scheduledGeneration = syncGeneration
        pendingUpdate = PendingFootnoteUpdate(
            refs: footnoteRefs, projectId: projectId, fullContent: fullContent, generation: scheduledGeneration
        )
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: UInt64(3_000_000_000))

            guard !Task.isCancelled else { return }
            self?.pendingUpdate = nil
            await self?.performFootnoteUpdate(
                refs: footnoteRefs,
                projectId: projectId,
                fullContent: fullContent,
                scheduledGeneration: scheduledGeneration
            )
        }
    }

    /// Force any already-scheduled (but not yet fired) debounced footnote update to run
    /// immediately. Used on quit/project-close so the Notes section's footnote definitions
    /// aren't left stale/mismatched behind the 3s debounce.
    ///
    /// If a natural debounce fire is already in flight (`state == .syncing`), waits for it
    /// to finish rather than starting a second, overlapping update. After the wait (or
    /// immediately, if nothing was in flight), re-checks for pending work rather than
    /// unconditionally returning — a new update can become pending in the moments between
    /// the in-flight run finishing and this method's poll loop waking up, and that update
    /// must still be picked up rather than silently dropped right before the process quits.
    ///
    /// Replays using the STORED generation captured at schedule time, not a freshly-read
    /// `syncGeneration` — this is what lets `performFootnoteUpdate`'s existing
    /// `scheduledGeneration == syncGeneration` guard correctly reject a snapshot that
    /// `handleImmediateInsertion` has since superseded (see its doc comment).
    func flushPendingSync() async {
        if state == .syncing {
            let deadline = Date().addingTimeInterval(2.0)
            while state == .syncing, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard state == .idle, let pending = pendingUpdate else { return }

        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        await performFootnoteUpdate(
            refs: pending.refs,
            projectId: pending.projectId,
            fullContent: pending.fullContent,
            scheduledGeneration: pending.generation
        )
    }

    /// Push footnote definitions to the editor for tooltip display
    func pushDefinitionsToEditor(fullContent: String) {
        // Find the #Notes section content
        let lines = fullContent.components(separatedBy: "\n")
        var notesContent = ""
        var inNotes = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "# notes" {
                inNotes = true
                notesContent += line + "\n"
                continue
            }
            if inNotes && trimmed.hasPrefix("# ") && trimmed.lowercased() != "# notes" {
                break // Hit the next H1 heading
            }
            if inNotes {
                notesContent += line + "\n"
            }
        }

        guard !notesContent.isEmpty else { return }

        let definitions = Self.extractFootnoteDefinitions(from: notesContent)
        guard !definitions.isEmpty else { return }

        // Push to editor via notification (editor will call setFootnoteDefinitions)
        NotificationCenter.default.post(
            name: .footnoteDefinitionsReady,
            object: nil,
            userInfo: ["definitions": definitions]
        )
    }

    /// Reset service state (call when switching projects)
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        lastKnownRefs = []
        lastRenumberedHash = 0
        state = .idle
    }

    /// Handle immediate footnote insertion — bypasses 3s debounce.
    /// Called from ContentView when JS returns the label via evaluateJavaScript completion.
    ///
    /// Mirrors footnote-plugin.ts's `insertFootnote` shift rule instead of independently
    /// deriving a label from a DB row count: `label` is JS's live-document-scan-computed
    /// pivot, already fully authoritative. Every existing DB label >= that pivot shifts up
    /// by one to make room; everything below the pivot is untouched. Reads/writes go through
    /// `reconcileNotesBlocks`, so unrelated labels are never fetched-for-write.
    func handleImmediateInsertion(label: String, projectId: String) {
        guard let database else {
            return
        }

        debounceTask?.cancel()
        debounceTask = nil
        syncGeneration += 1        // supersede any debounced rebuild scheduled before now

        state = .syncing
        defer { state = .idle }

        let pivot = Int(label) ?? 1
        var finalRefs: [String] = []

        do {
            try database.write { db in
                let existingDefBlocks = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isNotes == true)
                    .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
                    .fetchAll(db)

                let existingLabels: Set<Int> = Set(existingDefBlocks.compactMap { block in
                    Self.parseNotesLabel(from: block.markdownFragment).flatMap { Int($0.label) }
                })

                // Shift every existing label >= pivot up by one; labels below pivot are
                // untouched. When pivot == existingMax + 1 (append), this is empty by
                // construction and the call degenerates to a pure insertion.
                var renameMap: [String: String] = [:]
                for oldInt in existingLabels where oldInt >= pivot {
                    renameMap[String(oldInt)] = String(oldInt + 1)
                }

                let targetLabels = Set(existingLabels.map { $0 >= pivot ? $0 + 1 : $0 })
                    .union([pivot])
                let targetRefs = targetLabels.sorted().map(String.init)

                try Self.reconcileNotesBlocks(
                    db: db,
                    projectId: projectId,
                    targetRefs: targetRefs,
                    renameMap: renameMap
                )

                finalRefs = targetRefs
            }

            // Update state to prevent debounce re-trigger
            lastKnownRefs = finalRefs
            lastRenumberedHash = lastKnownRefs.joined(separator: ",").hashValue
        } catch {
            DebugLog.log(.footnotes, "[FootnoteSyncService] Immediate insertion failed: \(error)")
        }
    }

    // MARK: - Private Methods

    /// Internal (not private) so the race-condition guard can be unit-tested directly.
    func performFootnoteUpdate(
        refs: [String],
        projectId: String,
        fullContent: String,
        scheduledGeneration: Int
    ) async {
        guard let database else { return }

        // Execution-time mutual exclusion: an immediate insertion (handleImmediateInsertion)
        // bumps syncGeneration and cancels the debounce. A debounced rebuild scheduled before
        // that insertion must NOT run against its now-stale refs/fullContent snapshot.
        guard !Task.isCancelled,
              scheduledGeneration == syncGeneration,
              state == .idle else { return }

        state = .syncing
        defer { state = .idle }

        // Remove #Notes section when no footnotes
        guard !refs.isEmpty else {
            lastKnownRefs = []
            await removeNotesBlock(projectId: projectId)
            return
        }

        // Check if renumbering is needed: labels should be sequential 1..N
        let renumberMapping = computeRenumberMapping(refs: refs)

        // Determine the effective refs (post-renumbering)
        let effectiveRefs: [String]
        if !renumberMapping.isEmpty {
            // Apply mapping to get new labels in document order
            effectiveRefs = refs.map { renumberMapping[$0] ?? $0 }
        } else {
            effectiveRefs = refs
        }

        // Update lastKnownRefs to post-renumbered values to prevent re-trigger
        lastKnownRefs = effectiveRefs

        // Check if refs actually changed (definitions are read from DB, not content)
        let contentHash = effectiveRefs.joined(separator: ",").hashValue
        guard contentHash != lastRenumberedHash else { return }
        lastRenumberedHash = contentHash

        // Post renumbering to web editor BEFORE updating DB
        // (editor content change will trigger another checkAndUpdate which lastKnownRefs catches)
        if !renumberMapping.isEmpty {
            NotificationCenter.default.post(
                name: .renumberFootnotes,
                object: nil,
                userInfo: ["mapping": renumberMapping]
            )
        }

        // Create individual notes blocks (1 heading + N definition paragraphs)
        do {
            try updateNotesBlock(
                effectiveRefs: effectiveRefs,
                originalRefs: refs,
                projectId: projectId,
                database: database
            )
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
        } catch {
            DebugLog.log(.footnotes, "[FootnoteSyncService] Failed to update notes section: \(error)")
        }

        // Push definitions to editor for tooltip display
        pushDefinitionsToEditor(fullContent: fullContent)
    }

    /// Thin wrapper around `reconcileNotesBlocks` for the debounced path: derives a
    /// rename map from the position-aligned original/effective ref pairs (only entries
    /// where the label actually changed), then reconciles toward `effectiveRefs`. An
    /// entry where `original == effective` is untouched — never fetched-for-write.
    private func updateNotesBlock(
        effectiveRefs: [String],
        originalRefs: [String],
        projectId: String,
        database: ProjectDatabase
    ) throws {
        var renameMap: [String: String] = [:]
        for (original, effective) in zip(originalRefs, effectiveRefs) where original != effective {
            renameMap[original] = effective
        }

        try database.write { db in
            try Self.reconcileNotesBlocks(
                db: db,
                projectId: projectId,
                targetRefs: effectiveRefs,
                renameMap: renameMap
            )
        }
    }

    // Notes-block reconciliation (`reconcileNotesBlocks`, `notesGroupSortKey`,
    // `orphanedDefPattern`, `deleteOrphanedFootnoteDefinitions`) lives in
    // FootnoteSyncService+Reconciliation.swift.

    /// Compute renumbering mapping if labels are not sequential 1..N
    /// Returns empty dictionary if no renumbering needed
    private func computeRenumberMapping(refs: [String]) -> [String: String] {
        // Check if already sequential 1..N
        let isSequential = refs.enumerated().allSatisfy { index, label in
            label == String(index + 1)
        }
        guard !isSequential else { return [:] }

        // Build old→new mapping based on document order (first appearance)
        var mapping: [String: String] = [:]
        for (index, oldLabel) in refs.enumerated() {
            let newLabel = String(index + 1)
            if oldLabel != newLabel {
                mapping[oldLabel] = newLabel
            }
        }
        return mapping
    }

    /// Remove notes blocks when all footnotes are deleted
    private func removeNotesBlock(projectId: String) async {
        guard let database else { return }

        do {
            try database.write { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isNotes == true)
                    .deleteAll(db)

                // Clean up orphaned footnote definitions from before isNotes propagation fix
                try Self.deleteOrphanedFootnoteDefinitions(db: db, projectId: projectId)
            }
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            lastRenumberedHash = 0
            lastKnownRefs = []
        } catch {
            DebugLog.log(.editor, "[FootnoteSyncService] Error removing notes section: \(error)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when footnote definitions are ready to be pushed to the editor
    static let footnoteDefinitionsReady = Notification.Name("footnoteDefinitionsReady")
}
