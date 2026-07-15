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

    /// Pre-compiled regex for footnote reference extraction
    /// Matches [^N] where N is one or more digits, with negative lookahead for definition [^N]:
    nonisolated(unsafe) private static let footnoteRefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"\[\^(\d+)\](?!:)"#,
                options: []
            )
        } catch {
            fatalError("Invalid footnote regex pattern: \(error)")
        }
    }()

    /// Pre-compiled regex for footnote definition extraction
    /// Matches [^N]: at line start, capturing label and rest of line
    nonisolated(unsafe) private static let footnoteDefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"^\[\^(\d+)\]:\s*(.*)"#,
                options: [.anchorsMatchLines]
            )
        } catch {
            fatalError("Invalid footnote def regex pattern: \(error)")
        }
    }()

    /// Parse a single "[^N]: text" line/fragment into its label and definition text using
    /// `footnoteDefPattern`. Shared by `extractFootnoteDefinitions` (per line) and
    /// `reconcileNotesBlocks` (per Notes-block `markdownFragment`) — both previously carried
    /// their own copy of this same regex-match-and-extract logic. Note the underlying regex's
    /// `.` does not match newlines, so if `text` contains embedded "\n" (a multi-paragraph
    /// definition stored in one block), only the first line is captured — unchanged from the
    /// prior duplicated call sites.
    nonisolated static func parseNotesLabel(from text: String) -> (label: String, text: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = footnoteDefPattern.firstMatch(in: text, range: range),
              let labelRange = Range(match.range(at: 1), in: text),
              let textRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[labelRange]), String(text[textRange]))
    }

    /// Extract ordered unique footnote reference labels from markdown content
    /// Excludes the #Notes section content (definitions should not be counted as references)
    nonisolated static func extractFootnoteRefs(from markdown: String) -> [String] {
        // Strip the #Notes section before scanning
        let bodyContent = stripNotesSection(from: markdown)
        let range = NSRange(bodyContent.startIndex..., in: bodyContent)
        let matches = footnoteRefPattern.matches(in: bodyContent, range: range)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in matches {
            guard let labelRange = Range(match.range(at: 1), in: bodyContent) else { continue }
            let label = String(bodyContent[labelRange])
            if seen.insert(label).inserted {
                ordered.append(label)
            }
        }
        return ordered
    }

    /// Extract footnote definitions from the #Notes section content
    /// Returns a dictionary of label → definition text (including multi-paragraph)
    nonisolated static func extractFootnoteDefinitions(from notesContent: String) -> [String: String] {
        var definitions: [String: String] = [:]
        let lines = notesContent.components(separatedBy: "\n")

        var currentLabel: String?
        var currentText: [String] = []

        for line in lines {
            // Skip the heading line
            if line.hasPrefix("# ") { continue }

            if let parsed = parseNotesLabel(from: line) {
                // Save previous definition if any
                if let label = currentLabel {
                    definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                currentLabel = parsed.label
                currentText = [parsed.text]
            } else if currentLabel != nil {
                // Continuation line (4-space indented for multi-paragraph, or empty line)
                if line.hasPrefix("    ") {
                    currentText.append(String(line.dropFirst(4)))
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentText.append("")
                } else {
                    // Non-indented, non-empty line ends the current definition
                    // (unless it's another definition, handled above)
                    currentText.append(line)
                }
            }
        }

        // Save last definition
        if let label = currentLabel {
            definitions[label] = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return definitions
    }

    /// Strip the #Notes section from markdown content (returns body only)
    nonisolated static func stripNotesSection(from markdown: String) -> String {
        // Find "# Notes" heading (case-insensitive)
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var inNotes = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "# notes" {
                inNotes = true
                continue
            }
            // If we hit another H1 heading, we're out of the notes section
            if inNotes && trimmed.hasPrefix("# ") && trimmed.lowercased() != "# notes" {
                inNotes = false
            }
            if !inNotes {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

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

    /// Reconcile the Notes section's definition blocks toward `targetRefs`: renames,
    /// inserts, and deletes only the specific labels the delta requires — no
    /// delete-all-and-recreate. A block whose label is in neither `renameMap.keys` nor
    /// the insert set nor the delete set is never fetched-for-write and never has
    /// `.update(db)` called, so an unrelated footnote's block keeps the exact same `id`
    /// and `updatedAt` across a call that doesn't touch it. This is what makes a
    /// stale/overlapping rebuild safe: it can only destroy data for labels it explicitly
    /// says should change.
    ///
    /// Must be called from inside an existing `database.write { db in ... }` closure —
    /// this function does not open its own transaction, so the fetch-then-mutate sequence
    /// below is atomic with every other MainActor caller of `database.write`.
    ///
    /// - Parameters:
    ///   - targetRefs: the final set of definition labels that must exist once this call
    ///     returns (order doesn't matter — final display order is always numeric).
    ///   - renameMap: old label -> new label, applied in place (same block id, text
    ///     carried forward unless overridden) against a snapshot taken once at the top of
    ///     this call — safe for overlapping shifts (e.g. "2"->"3" and "3"->"4" in the same
    ///     call) because renames resolve against original identity, not by re-querying by
    ///     label mid-loop.
    ///   - definitionOverrides: new-label -> definition text, for a caller that already
    ///     knows the text a renamed-into or newly-inserted label should carry. Neither
    ///     current caller uses this (renames carry forward existing text; inserts default
    ///     to blank).
    static func reconcileNotesBlocks(
        db: Database,
        projectId: String,
        targetRefs: [String],
        renameMap: [String: String] = [:],
        definitionOverrides: [String: String] = [:]
    ) throws {
        // 1. Fetch current Notes paragraph blocks fresh; snapshot label -> Block ONCE
        //    before any writes. Defensively de-duplicate (keep most-recently-updated) in
        //    case pre-fix corruption left two rows claiming one label.
        let existingDefBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)

        var snapshot: [String: Block] = [:]
        for block in existingDefBlocks {
            guard let parsed = parseNotesLabel(from: block.markdownFragment) else { continue }
            if let existing = snapshot[parsed.label], existing.updatedAt > block.updatedAt {
                continue
            }
            snapshot[parsed.label] = block
        }
        // Rows not kept as the canonical block for their label are extra corruption from
        // before this fix (two rows claiming one label) — delete them outright.
        let keptIds = Set(snapshot.values.map(\.id))
        for block in existingDefBlocks where !keptIds.contains(block.id) {
            try Block.deleteOne(db, key: block.id)
        }

        // 2. Apply renames FIRST, against the snapshot above — never re-queried mid-loop
        //    — so overlapping shifts can't cross-contaminate each other.
        var renamedNewLabels: Set<String> = []
        for (oldLabel, newLabel) in renameMap {
            guard oldLabel != newLabel, var block = snapshot[oldLabel] else { continue }
            let existingText = parseNotesLabel(from: block.markdownFragment)?.text ?? ""
            let text = definitionOverrides[newLabel] ?? existingText
            block.markdownFragment = "[^\(newLabel)]: \(text)"
            block.textContent = text
            block.recalculateWordCount()
            try block.update(db)
            renamedNewLabels.insert(newLabel)
        }

        // 3. Insert-set and delete-set, computed AFTER the rename pass from the
        //    post-rename label set.
        let untouchedLabels = Set(snapshot.keys).subtracting(renameMap.keys)
        let presentLabels = untouchedLabels.union(renamedNewLabels)
        let targetSet = Set(targetRefs)
        let toInsert = targetRefs.filter { !presentLabels.contains($0) }
        let toDelete = untouchedLabels.subtracting(targetSet)

        // 4. Delete labels no longer wanted.
        for label in toDelete {
            if let block = snapshot[label] {
                try Block.deleteOne(db, key: block.id)
            }
        }

        // 5. Heading block: reuse existing id, leave completely untouched if already
        //    present (no more churn-on-every-insert).
        let existingHeading = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.heading.rawValue)
            .fetchOne(db)

        // Get max sort order from non-bibliography blocks. Notes should appear after
        // user content but before bibliography. This is only a placeholder for any
        // newly-inserted rows below — the renormalization pass in step 7 assigns real,
        // final sortOrder values.
        let maxNonBibSortOrder = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isBibliography == false)
            .order(Block.Columns.sortOrder.desc)
            .fetchOne(db)?.sortOrder ?? 0
        let baseSortOrder = maxNonBibSortOrder + 0.5

        if existingHeading == nil, !targetRefs.isEmpty {
            var headingBlock = Block(
                projectId: projectId,
                sortOrder: baseSortOrder,
                blockType: .heading,
                textContent: "Notes",
                markdownFragment: "# Notes",
                headingLevel: 1,
                status: .final_,
                isNotes: true
            )
            headingBlock.recalculateWordCount()
            try headingBlock.insert(db)
        }

        // 6. Insert brand-new labels.
        for (index, label) in toInsert.enumerated() {
            let text = definitionOverrides[label] ?? ""
            var defBlock = Block(
                projectId: projectId,
                sortOrder: baseSortOrder + Double(index + 1),
                blockType: .paragraph,
                textContent: text,
                markdownFragment: "[^\(label)]: \(text)",
                isNotes: true
            )
            defBlock.recalculateWordCount()
            try defBlock.insert(db)
        }

        // Clean up orphaned footnote definitions from before isNotes propagation fix
        try deleteOrphanedFootnoteDefinitions(db: db, projectId: projectId)

        // 7. Whole-project sortOrder renormalization. Within the Notes group
        //    specifically, order by PARSED NUMERIC LABEL rather than sortOrder — an
        //    untouched block's stale sortOrder can no longer be trusted for relative
        //    order once only some blocks in the group got fresh values from steps 2/6
        //    above. Content and bibliography groups are unaffected by this call, so they
        //    keep ordering by sortOrder exactly as before. Only writes (and only bumps
        //    updatedAt for) a block whose sortOrder actually changes — this is what
        //    keeps an untouched block's row byte-identical (same id, same updatedAt).
        let allBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        let sorted = allBlocks.sorted { a, b in
            let aGroup = a.isBibliography ? 2 : (a.isNotes ? 1 : 0)
            let bGroup = b.isBibliography ? 2 : (b.isNotes ? 1 : 0)
            if aGroup != bGroup { return aGroup < bGroup }
            if aGroup == 1 {
                return notesGroupSortKey(a) < notesGroupSortKey(b)
            }
            return a.sortOrder < b.sortOrder
        }

        let now = Date()
        for (index, var block) in sorted.enumerated() {
            let newSortOrder = Double(index + 1)
            if block.sortOrder != newSortOrder {
                block.sortOrder = newSortOrder
                block.updatedAt = now
                try block.update(db)
            }
        }
    }

    /// Sort key for a block within the Notes group: heading always first, then
    /// definition paragraphs ordered by their parsed numeric label (not sortOrder — see
    /// `reconcileNotesBlocks`).
    private static func notesGroupSortKey(_ block: Block) -> Int {
        guard block.blockType != .heading else { return -1 }
        guard let parsed = parseNotesLabel(from: block.markdownFragment),
              let labelInt = Int(parsed.label) else {
            return Int.max
        }
        return labelInt
    }

    /// Pre-compiled regex for orphaned footnote definition detection
    private static let orphanedDefPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^\[\^\d+\]:\s*"#)
        } catch {
            fatalError("Invalid orphaned def regex pattern: \(error)")
        }
    }()

    /// Delete orphaned footnote definition blocks (isNotes=false but contain [^N]: text)
    /// Cleans up corruption from before Fix 1 marked all Notes children with isNotes=true
    static func deleteOrphanedFootnoteDefinitions(db: Database, projectId: String) throws {
        let candidates = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)
        for block in candidates {
            let frag = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(frag.startIndex..., in: frag)
            if orphanedDefPattern.firstMatch(in: frag, range: range) != nil {
                try Block.deleteOne(db, key: block.id)
            }
        }
    }

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
