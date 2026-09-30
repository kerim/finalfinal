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

    /// Push footnote definitions to the editor for tooltip display.
    ///
    /// C4: migrated onto the shared `NotesOpeningSelector` (H1-or-H2 title match +
    /// `[^N]:` evidence beneath), same rule `stripNotesSection` migrated onto -- this
    /// was the "blank hover popup" caveat the rejected attempt 1 logged as a follow-up
    /// (left H1-only there); Stage C closes it. `notesHeaderName` defaults to the
    /// literal `"Notes"`, mirroring `stripNotesSection`'s own default.
    func pushDefinitionsToEditor(fullContent: String, notesHeaderName: String = "Notes") {
        let lines = fullContent.components(separatedBy: "\n")
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        // C4 fence fix -- see `stripNotesSection`'s matching comment: a heading-shaped or
        // evidence-shaped line inside a ``` fence must never be treated as real.
        var inCodeBlockForTokenizing = false
        let units = trimmedLines.map { trimmed -> NotesOpeningSelector.Unit in
            if trimmed.hasPrefix("```") {
                inCodeBlockForTokenizing.toggle()
                return NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: false)
            }
            guard !inCodeBlockForTokenizing else {
                return NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: false)
            }
            return NotesOpeningSelector.Unit(
                isCandidateHeading: BlockParser.isNotesHeading(trimmed, notesHeaderName: notesHeaderName),
                isAnyHeading: trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil,
                isEvidence: Self.parseNotesLabel(from: trimmed) != nil
            )
        }
        let openingIndices = Set(NotesOpeningSelector.select(units))

        var notesContent = ""
        var inNotes = false

        for (index, line) in lines.enumerated() {
            if openingIndices.contains(index) {
                inNotes = true
                notesContent += line + "\n"
                continue
            }
            // Any other heading of any level ends the run -- widened from the old
            // H1-only check; see `stripNotesSection`'s doc comment for the shared rule.
            if inNotes && units[index].isAnyHeading {
                break
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
    ///
    /// E1/E6: returns the real DB id of the definition row `reconcileNotesBlocks` inserted for
    /// `label` itself (the pivot) -- NOT just any freshly-inserted row: `pivot` is always a
    /// brand-new label by construction (every pre-existing label >= pivot was just renamed
    /// away from it above), so it is always present in `reconcileNotesBlocks`'s step-6
    /// `insertedIds` map on success. `nil` only when the write itself failed or the DB lookup
    /// legitimately found nothing (defensive -- should not happen given the above). Lets the
    /// caller (`handleFootnoteInsertedImmediate`) thread this id through to the
    /// `.scrollToFootnoteDefinition` notification's `userInfo["blockId"]` instead of it being
    /// silently discarded, as it previously was.
    @discardableResult
    func handleImmediateInsertion(label: String, projectId: String) -> String? {
        guard let database else {
            return nil
        }

        debounceTask?.cancel()
        debounceTask = nil
        syncGeneration += 1        // supersede any debounced rebuild scheduled before now

        state = .syncing
        defer { state = .idle }

        let pivot = Int(label) ?? 1
        var finalRefs: [String] = []
        var insertedBlockId: String?

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

                let insertedIds = try Self.reconcileNotesBlocks(
                    db: db,
                    projectId: projectId,
                    targetRefs: targetRefs,
                    renameMap: renameMap
                )
                insertedBlockId = insertedIds[String(pivot)]

                finalRefs = targetRefs
            }

            // Update state to prevent debounce re-trigger
            lastKnownRefs = finalRefs
            lastRenumberedHash = lastKnownRefs.joined(separator: ",").hashValue
            DebugLog.log(.footnotes, "[FootnoteSyncService] handleImmediateInsertion: label=\(label) " +
                "pivot=\(pivot) insertedBlockId=\(insertedBlockId ?? "nil")")
            return insertedBlockId
        } catch {
            DebugLog.log(.footnotes, "[FootnoteSyncService] Immediate insertion failed: \(error)")
            return nil
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
            // B7: `refs` was computed by `extractFootnoteRefs`, which strips the Notes
            // section (via `stripNotesSection`) before scanning -- so a bug in HOW that
            // scanner scopes the Notes run (wrong opening, or wrong extent) could make
            // `refs` read empty while the raw document still contains a genuine `[^N]`
            // reference somewhere. Before taking the destructive branch below, re-verify
            // independently against the UNSTRIPPED document -- this can never drift back
            // into depending on the very scanner it exists to catch a mistake in.
            guard !Self.documentContainsFootnoteReference(fullContent) else {
                DebugLog.log(.footnotes, "[FootnoteSyncService] performFootnoteUpdate: refs.isEmpty but " +
                    "unstripped document still contains a [^N] reference -- refusing removeNotesBlock (B7 guard)")
                return
            }
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

    // Notes-block reconciliation (`reconcileNotesBlocks`, `notesOwnershipMap`,
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

    /// Remove notes blocks when all footnotes are deleted.
    ///
    /// B1: this used to be an unguarded `.filter(isNotes == true).deleteAll(db)` --
    /// EVERY flagged row, no exceptions. Once a row can be flagged by adoption without
    /// being a definition itself (the user's own prose sitting inside a Notes run), that
    /// mass delete takes the user's own writing with it the moment the last footnote is
    /// removed. Now only MACHINE-OWNED rows (the heading, definitions, and their
    /// continuations -- classified via `notesOwnershipMap`, below) are deleted; anything
    /// else is unflagged (isNotes = false) and left in place, content untouched. This is
    /// safe specifically because this function only ever runs once ALL footnotes are
    /// gone from the WHOLE document -- a `.userProse` row found here is unambiguously
    /// orphaned, unlike the same distinction attempted (and reverted) in
    /// `deleteBlocksInRange`'s `protectingNotes` exemption; see that function's B3 doc
    /// comment for why the same narrowing doesn't work there.
    private func removeNotesBlock(projectId: String) async {
        guard let database else { return }

        DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: entry projectId=\(projectId)")

        // Hoisted above the write closure so the notification post below can be gated on
        // whether the sweep actually changed anything — a no-op sweep (nothing flagged
        // isNotes, e.g. a footnote-free document) must never post .notesSectionChanged.
        var deletedCount = 0
        var retainedCount = 0

        do {
            try database.write { db in
                // A dual-flagged (isBibliography) row is never this sweep's to touch --
                // it belongs to BibliographySyncService.
                let notesRows = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isNotes == true)
                    .filter(Block.Columns.isBibliography == false)
                    .fetchAll(db)
                let (ownership, _) = Self.notesOwnershipMap(for: notesRows)

                var deletedDefinitionTwins: [Block] = []
                for row in notesRows {
                    switch ownership[row.id] {
                    case .heading, .definition, .continuation:
                        if case .definition = ownership[row.id] {
                            // B6: this row is about to be deleted, so B5's sweep below
                            // (which runs in this SAME write, after every definition is
                            // already gone) can never find it as a "current" twin by a
                            // fresh query. Pass it along as a known-prior-twin -- it
                            // still carries a body, so B5's body comparison still
                            // applies rather than deleting-by-default on "no twin found".
                            deletedDefinitionTwins.append(row)
                        }
                        // B9: log the full fragment before it is destroyed.
                        DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: deleting " +
                            "id=\(row.id) blockType=\(row.blockType.rawValue) " +
                            "fragment=\"\(row.markdownFragment)\"")
                        try Block.deleteOne(db, key: row.id)
                        deletedCount += 1
                    case .userProse, nil:
                        // The user's own writing living inside the (now-removed) Notes
                        // run -- unflag it and leave the content exactly as it is. This
                        // is also a flag-only-adjacent write (content untouched), so no
                        // updatedAt restamp needed for correctness, but the row content
                        // itself isn't changing either way; stamping it here is fine
                        // since this is a real, user-visible state change (no longer
                        // part of a Notes section).
                        var unflagged = row
                        unflagged.isNotes = false
                        unflagged.updatedAt = Date()
                        try unflagged.update(db)
                        retainedCount += 1
                        DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: retaining " +
                            "id=\(row.id) fragment=\"\(row.markdownFragment)\" reason=user-prose-not-machine-owned")
                    }
                }
                DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: deleted=\(deletedCount) " +
                    "retained=\(retainedCount) of total=\(notesRows.count)")

                // Clean up orphaned footnote definitions from before isNotes propagation
                // fix -- B6: pass the definition rows just deleted above as known-prior-
                // twins, since with B1 landed every definition row is gone before this
                // sweep runs, and a fresh query would otherwise find "no twin" for every
                // candidate by construction.
                try Self.deleteOrphanedFootnoteDefinitions(
                    db: db, projectId: projectId, knownPriorTwins: deletedDefinitionTwins
                )
            }
            // Gate ONLY the notification on whether the sweep actually changed anything --
            // a footnote-free document (lastKnownRefs starts as []) can reach this function
            // with nothing flagged isNotes at all, and that no-op sweep must never post
            // .notesSectionChanged (which triggers a full document re-push that resets the
            // caret and destroys the web editor's own undo history).
            if deletedCount > 0 || retainedCount > 0 {
                NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            }
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
