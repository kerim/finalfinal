//
//  FootnoteSyncService+UndoCheckpoint.swift
//  final final
//
//  t-94369a83 Phase 3a-2 Step 5 (t-4a6e6414) and Step 6: the "undo checkpoint". Deleting a footnote number removes
//  its definition under Notes about 3 seconds later (a burst of deletes is one write); ⌘Z used to bring the number
//  back with a BLANK definition, because `reconcileNotesBlocks` inserts a missing label with no text. When a write
//  deletes definitions, the service builds a checkpoint of the documents the user passed through (a CHAIN of undo
//  states, FootnoteSyncService+UndoStates.swift) and records it once the write has APPLIED. When a later check sees
//  exactly one of those documents again, that is the undo (the one other way to produce it is typing the deleted
//  reference back by hand so the whole document is identical, which is then treated the same, deliberately), and the
//  Notes rows are moved to that state at once (no 3 second wait) through one `.notesUpdate` write.
//
//  The checkpoint tracks the numbering of the stored rows explicitly: `committedRefs` and `committedNumbering` say
//  what THIS checkpoint last left in the table (its own write, or its last restore). It matches only while
//  `lastKnownRefs == committedRefs`, so an unrelated write makes it inert and a full linear undo of a newer one
//  re-enables it. A restore renames from the stored numbering to the target state's numbering. The checkpoint is KEPT
//  after a restore (undo, redo, undo again), and dropped only by the cap of 5, `reset()` and `/footnote`.
//
//  In memory only, like the editor's own undo history: closing, switching or reopening a project (`reset()`)
//  clears everything. The stored state (`undoCheckpoints`, `burstStates`, `lastChecked`,
//  `lastContentWithKnownRefs`) lives on the type, because an extension cannot hold stored properties. Design and
//  tests: plan-v3-feedback-footnote.md, plan-v4-feedback-per-step-undo.md, `FootnoteUndoCheckpointTests`,
//  `FootnotePerStepUndoTests`.
//

import Foundation
import GRDB

/// What one deleting write remembers so that ⌘Z can bring the deleted text back, step by step.
struct FootnoteUndoCheckpoint {
    let id = UUID()
    /// The documents the undo can land on: the burst's states (S0 first, the document the write was computed from
    /// last, all in the old numbering), then, once seen, the written state W (new numbering).
    var states: [FootnoteUndoState]
    /// The references the write committed (the new numbering).
    let refsAfter: [String]
    /// label -> text, for the labels (in the OLD numbering) that ended up with NO definition row: exactly the
    /// definitions the write deleted, as the editor showed them in the document the write was computed from (the
    /// latest text: every edit inside the 3 second window re-schedules the burst with fresh content). Used on a
    /// restore to an old-numbering state, for a label whose row is MISSING or has NO text (`fillBlankDefinitions`). A
    /// surviving, renumbered definition, or any row that has text, keeps its CURRENT text, which the user may have
    /// edited since.
    let deletedDefinitions: [String: String]
    /// The rename the write applied, old label -> new label (empty when no definition was renumbered).
    let appliedRenameMap: [String: String]
    /// Whether the written state W has been appended to `states`.
    var writtenStateRecorded = false
    /// What this checkpoint last left in the table: the references (set when its write applied and after each of its
    /// restores) and which numbering the rows are in.
    var committedRefs: [String]
    var committedNumbering: FootnoteUndoNumbering

    /// The document before the first change, and its references.
    var bodyBefore: String { states.first?.body ?? "" }
    var refsBefore: [String] { states.first?.refs ?? [] }

    init(states: [FootnoteUndoState], refsAfter: [String], deletedDefinitions: [String: String], appliedRenameMap: [String: String]) {
        self.states = states
        self.refsAfter = refsAfter
        self.deletedDefinitions = deletedDefinitions
        self.appliedRenameMap = appliedRenameMap
        committedRefs = refsAfter
        committedNumbering = appliedRenameMap.isEmpty ? .old : .new
    }

    /// One state only (no renumbering): the shape Step 5 had.
    init(bodyBefore: String, refsBefore: [String], deletedDefinitions: [String: String], appliedRenameMap: [String: String]) {
        self.init(
            states: [FootnoteUndoState(body: bodyBefore, refs: refsBefore, numbering: .old)], refsAfter: [],
            deletedDefinitions: deletedDefinitions, appliedRenameMap: appliedRenameMap)
    }
}

/// What one restore does: move the rows to `state` (from the stored numbering, with these overrides).
struct FootnoteRestorePlan {
    let checkpointId: UUID
    let state: FootnoteUndoState
    let rename: [String: String]
    let overrides: [String: String]
    /// The check's content (the document the undo or redo landed on).
    let content: String
}

extension FootnoteSyncService {
    /// The most recent checkpoints kept; older ones are dropped.
    static let undoCheckpointLimit = 5

    /// The form two documents are compared in: Notes stripped (the editor holds no Notes after the removal push,
    /// so they could never match otherwise) and surrounding whitespace trimmed (the stripped Notes leave a
    /// trailing blank line behind).
    nonisolated static func undoComparable(_ content: String) -> String {
        stripNotesSection(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the checkpoint for a write about to delete at least one definition. The states are the burst's
    /// (`burstStates`, consumed here: the burst is over once its write is built) closed by the document this write
    /// is computed from (`rawRefs` are its references, before the renumber). Without a usable first state (its
    /// references must equal the stored ones) the content last seen with the committed references stands in. The
    /// deleted definitions' text comes from `content` (deleted labels keep their label there: the editor has not
    /// renumbered yet). nil when the write deletes nothing, when no "before" document exists yet (the very first
    /// write after an open), or under `allowRenumber: false` (the close-time refresh). The caller records it with
    /// `committedNotesWrite` only once the write has applied.
    func makeUndoCheckpoint(
        raw rawRefs: [String], refs effectiveRefs: [String], renames: [String: String], content: String, allowRenumber: Bool
    ) -> FootnoteUndoCheckpoint? {
        var states = burstStates
        burstStates = []
        guard allowRenumber, Set(effectiveRefs).count < Set(lastKnownRefs).count else { return nil }
        if states.first?.refs != lastKnownRefs {
            states = []
            if let before = lastContentWithKnownRefs {
                states = [FootnoteUndoState(body: Self.undoComparable(before), refs: Self.extractFootnoteRefs(from: before), numbering: .old)]
            }
        }
        // The snapshot must really be of the state the database matches; a stale one makes no checkpoint.
        guard let first = states.first, first.refs == lastKnownRefs else { return nil }
        let last = FootnoteUndoState(body: Self.undoComparable(content), refs: rawRefs, numbering: .old)
        if states.last.map({ $0.refs == last.refs && $0.body == last.body }) != true { states.append(last) }
        if states.count > Self.undoStateLimit { states.removeSubrange(1..<(states.count - (Self.undoStateLimit - 1))) }
        // The labels that survive, in the old numbering: a renumbered survivor is looked up through the inverse.
        let inverse = Self.invertRenameMap(renames)
        let surviving = Set(effectiveRefs.map { inverse[$0] ?? $0 })
        let deleted = Self.extractFootnoteDefinitions(from: content)
            .filter { first.refs.contains($0.key) && !surviving.contains($0.key) }
        return FootnoteUndoCheckpoint(states: states, refsAfter: effectiveRefs, deletedDefinitions: deleted, appliedRenameMap: renames)
    }

    /// Called once a Notes write has APPLIED (never before: a refused or failed delete leaves no checkpoint).
    /// Records the checkpoint of a deleting write, capped at `undoCheckpointLimit`, with the table state it left
    /// (`committedRefs`, and the new numbering when it renamed something), and remembers the content the write was
    /// computed from as the last content seen with the committed refs, when that is true of it (a renumbering write's
    /// own content still carries the old labels), so the next delete has a "before" even if no keystroke has happened
    /// since the open-time write.
    ///
    /// `scheduledGeneration` (slice 2b, plan-v3 D2): the `syncGeneration` the write was scheduled under. While a quick undo's hold is
    /// active (`holdUndoCheckpoints`), a write scheduled at or below the generation the hold captured records no checkpoint: it is a
    /// delete's own resync, the section is back on the screen, and its checkpoint would bring a footnote's old text back over the
    /// restored one. A write scheduled after the quick undo records its checkpoint as always.
    func committedNotesWrite(undoCheckpoint: FootnoteUndoCheckpoint?, content: String? = nil, scheduledGeneration: Int? = nil) {
        if let content, Self.extractFootnoteRefs(from: content) == lastKnownRefs {
            lastContentWithKnownRefs = content
        }
        guard var checkpoint = undoCheckpoint else { return }
        if let hold = undoCheckpointHold, let scheduledGeneration, scheduledGeneration <= hold.belowOrAt {
            FootnoteDiag.log("checkpoint withheld: a quick undo's hold is active (write generation \(scheduledGeneration) <= \(hold.belowOrAt))")
            return
        }
        checkpoint.committedRefs = lastKnownRefs
        checkpoint.committedNumbering = checkpoint.appliedRenameMap.isEmpty ? .old : .new
        undoCheckpoints.append(checkpoint)
        if undoCheckpoints.count > Self.undoCheckpointLimit { undoCheckpoints.removeFirst() }
        FootnoteDiag.log("checkpoint recorded labelsBefore=\(FootnoteDiag.labels(checkpoint.refsBefore)) " +
            "states=\(checkpoint.states.count) refsAfter=\(FootnoteDiag.labels(checkpoint.refsAfter)) " +
            "deletedDefinitions=\(FootnoteDiag.labels(checkpoint.deletedDefinitions.keys.sorted())) " +
            "renameEntries=\(checkpoint.appliedRenameMap.count) stored=\(undoCheckpoints.count)")
    }

    /// `beginImmediateInsertion` (`/footnote`): a NEW footnote must never inherit a deleted one's text (labels are
    /// always reused), so every checkpoint is dropped, even when the document later looks identical to an earlier one.
    func discardUndoCheckpointsForNewFootnote() {
        FootnoteDiag.log("immediate insertion begins: pending=\(pendingUpdate != nil) checkpoints cleared=\(undoCheckpoints.count)")
        undoCheckpoints = []
    }

    /// A quick undo of a section delete (slice 2b, plan-v2-addendum 4.4): drops every checkpoint recorded since the delete was clicked
    /// (`marker` is the set of checkpoint ids that existed then). The restored text brings the deleted footnotes back, so the
    /// definitions the delete's resync removed are restored by the reinsert, and a checkpoint of that resync would only get in the way.
    func dropUndoCheckpoints(notIn marker: Set<UUID>) {
        let before = undoCheckpoints.count
        undoCheckpoints.removeAll { !marker.contains($0.id) }
        FootnoteDiag.log("quick undo: checkpoints dropped=\(before - undoCheckpoints.count) kept=\(undoCheckpoints.count)")
    }

    /// A queued job is about to rewrite EVERY Notes row from a snapshot or a version (the editor-first slow undo and redo, the
    /// whole-project restore; fix round F1, finding D): every checkpoint describes a table that is about to be gone, and one that
    /// matched the document the editor then shows (the swapped-in text equals a state of the checkpoint) would queue a footnote restore
    /// planned against the table as it was BEFORE the job, behind the job, renumbering rows the job has already put in order. All of
    /// them go, and so does the burst in progress (it describes a document that is replaced). Quick undo drops only the checkpoints
    /// recorded since the click (`dropUndoCheckpoints(notIn:)`) because its restored rows are exactly the ones those checkpoints started
    /// from; a snapshot is any older document, so nothing recorded earlier is safe either.
    func dropAllUndoCheckpoints() {
        let before = undoCheckpoints.count
        undoCheckpoints = []
        burstStates = []
        FootnoteDiag.log("queued Notes rewrite: checkpoints dropped=\(before) burst states cleared")
    }

    /// Starts the hold for `token` (plan-v3 D2): from now on a write scheduled at or below the current `syncGeneration` records no
    /// checkpoint when it commits (a delete-resync write that had already reserved before the quick undo commits after it).
    func holdUndoCheckpoints(token: UUID) {
        undoCheckpointHold = (token: token, belowOrAt: syncGeneration)
    }

    /// Ends the burst that is waiting for its deadline, if any (the three lines `checkAndUpdateFootnotes`' equal-refs branch runs),
    /// WITHOUT bumping `syncGeneration`. A quick undo calls this in its first synchronous stretch (plan-v3 D1): the burst was
    /// computed from the post-delete document, and the restored text will schedule its own.
    func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
    }

    /// The quick undo's reinsert puts the pre-delete Notes rows back without telling this service, so `lastRenumberedHash` (the hash of
    /// the refs the delete's resync committed, e.g. 1..45) no longer describes the table (1..54 again). A redo that deletes the same
    /// section again computes the same refs, hashes to the same value and `perform` returns at its `contentHash != lastRenumberedHash`
    /// guard: no renumber, the Notes keep all their definitions, for good. Called wherever the Notes rows have just been put back (the
    /// quick undo's restore, the reinsert's settle, the quick redo's first stretch, the C5 fallback's flush). It clears the hash and
    /// NOTHING else: `lastKnownRefs` stays (the checkpoint matcher and `makeUndoCheckpoint` were reviewed against it), and the next
    /// `perform` that applies commits both again.
    ///
    /// A section drag (`resyncNow(forgetCommittedHash:)`) calls it too and rewrites no rows: the order of the references changed but the set
    /// of labels did not (1...N before and after), so without the forget the hash guard would skip the settle's renumber.
    func forgetCommittedNotesState() {
        lastRenumberedHash = 0
        FootnoteDiag.log("committed Notes state forgotten (a structural job rewrote rows, or a drag reordered refs): lastRenumberedHash cleared")
    }

    /// Ends the hold started with `token`. A different token's hold (a later quick undo's) is left alone.
    func releaseUndoCheckpointHold(token: UUID) {
        guard undoCheckpointHold?.token == token else { return }
        undoCheckpointHold = nil
    }

    /// `reset()`: a completed close, switch or open ends the session the checkpoints belong to.
    func resetUndoState() {
        FootnoteDiag.log("reset (project closed, switched or opened): checkpoints cleared=\(undoCheckpoints.count) inFlight=\(inFlightCount)")
        undoCheckpointHold = nil
        undoCheckpoints = []
        burstStates = []
        lastChecked = nil
        lastContentWithKnownRefs = nil
    }

    /// The rename that moves the stored rows from the checkpoint's current numbering to the state's.
    func renameForRestore(_ checkpoint: FootnoteUndoCheckpoint, to state: FootnoteUndoState) -> [String: String] {
        switch (checkpoint.committedNumbering, state.numbering) {
        case (.new, .old): return Self.invertRenameMap(checkpoint.appliedRenameMap)
        case (.old, .new): return checkpoint.appliedRenameMap
        default: return [:]
        }
    }

    /// Called from `checkAndUpdateFootnotes` when the refs differ from the committed ones. Returns true when the
    /// check was consumed here, so nothing is scheduled: the document is exactly one of a checkpoint's states, which
    /// is the undo (or the redo of the editor's renumber), so the rows move to that state at once.
    ///
    /// A checkpoint is eligible only while `lastKnownRefs == committedRefs` (otherwise another write has moved the
    /// table on and it is inert). A state matches when its references and its body equal the check's exactly, and:
    /// it has MORE references than the table (an undo bringing footnotes back), or the SAME number (the undo of the
    /// editor's renumber), or it is the written state W (the redo of the renumber). A state with FEWER references is a
    /// redo that deletes again: it takes the ordinary burst and deadline, like any delete. Newest checkpoint first.
    /// Cheap by construction: the references are compared before any body, and the body is stripped once, only when a
    /// candidate state survives the reference and direction checks.
    func handleUndoCheckpoints(refs: [String], projectId: String, content: String) -> Bool {
        guard !undoCheckpoints.isEmpty else { return false }
        var comparable: String?
        for index in undoCheckpoints.indices.reversed() {
            let checkpoint = undoCheckpoints[index]
            guard checkpoint.committedRefs == lastKnownRefs else { continue }
            for state in checkpoint.states.reversed() where state.refs == refs {
                guard state.numbering == .new || state.refs.count >= lastKnownRefs.count else { continue }
                let body = comparable ?? Self.undoComparable(content)
                comparable = body
                guard state.body.utf8.count == body.utf8.count, state.body == body else { continue }
                startRestore(checkpoint, to: state, projectId: projectId, content: content)
                return true
            }
        }
        return false
    }

    /// A state matched: any restore ENDS the current burst (the waiting snapshot, its timer and the burst's states
    /// are dropped, and the generation moves on), then one write moves the rows to the state.
    private func startRestore(_ checkpoint: FootnoteUndoCheckpoint, to state: FootnoteUndoState, projectId: String, content: String) {
        let rename = renameForRestore(checkpoint, to: state)
        // The deleted texts are in the OLD numbering; the written state (new numbering) needs none.
        let overrides = state.numbering == .old ? checkpoint.deletedDefinitions : [:]
        FootnoteDiag.log("checkpoint matched: restore starts pendingCancelled=\(pendingUpdate != nil) " +
            "target=\(FootnoteDiag.labels(state.refs)) numbering=\(state.numbering) table=\(FootnoteDiag.labels(lastKnownRefs)) " +
            "tableNumbering=\(checkpoint.committedNumbering) renameEntries=\(rename.count) " +
            "restoredTexts=\(FootnoteDiag.labels(overrides.keys.sorted())) states=\(checkpoint.states.count)")
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        burstStates = []
        lastChecked = (content, state.refs)
        syncGeneration += 1
        let generation = syncGeneration
        // Counts as a running sync from here on: later checks wait, and `flushPendingSync` awaits the restore.
        inFlightCount += 1
        Task { [self] in
            // Clamped at zero: a `reset()` while the restore runs has already zeroed the count.
            defer { inFlightCount = max(0, inFlightCount - 1) }
            await restoreFromCheckpoint(
                FootnoteRestorePlan(checkpointId: checkpoint.id, state: state, rename: rename, overrides: overrides, content: content),
                projectId: projectId, generation: generation)
        }
    }

    /// Runs in the restore's transaction after the reconcile. A restore can find a BLANK row for a label it restores
    /// (the reconcile never overwrites an existing row with an override), so a restored label whose row exists with
    /// no text gets its text here. A row with ANY text is never overwritten.
    nonisolated static func fillBlankDefinitions(db: Database, projectId: String, texts: [String: String]) throws {
        guard !texts.isEmpty else { return }
        let rows = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)
        for var row in rows {
            guard let parsed = parseNotesLabel(from: row.markdownFragment),
                  let text = texts[parsed.label], !text.isEmpty,
                  parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            row.markdownFragment = "[^\(parsed.label)]: \(text)"
            row.textContent = text
            row.recalculateWordCount()
            try row.update(db)
        }
    }

    /// One `.notesUpdate` write: `targetRefs` = the state's references, `renameMap` = from the stored numbering to the
    /// state's (inverse of the delete's rename, the rename itself, or none), `definitionOverrides` = the deleted
    /// definitions for an old-numbering state. No renumber is posted to the editor: the undo or redo already set its
    /// labels. Commits the dedup state and tells the editor only once the write applied; a refused or failed restore
    /// changes nothing. The checkpoint is KEPT and now describes the table as this restore left it.
    func restoreFromCheckpoint(_ plan: FootnoteRestorePlan, projectId: String, generation: Int) async {
        guard let database else { return }
        let refs = plan.state.refs
        let (renames, overrides) = (plan.rename, plan.overrides)

        let started = FootnoteDiag.nowMs()
        let applied: Bool
        if let systemWriter {
            let diagMark = FootnoteDiagMark()
            let result = await systemWriter.perform(
                identity: SystemWriteIdentity(projectId: projectId, database: database), kind: .notesUpdate,
                stillWanted: { [weak self] in generation == self?.syncGeneration },
                body: { db in
                    diagMark.set()
                    let written = try FootnoteSyncService.writeNotesReconciliation(
                        db: db, projectId: projectId, targetRefs: refs, renameMap: renames, definitionOverrides: overrides)
                    try FootnoteSyncService.fillBlankDefinitions(db: db, projectId: projectId, texts: overrides)
                    return written
                }
            )
            fnDiagWriteDone("restore", diagMark, result)
            if case .applied = result.outcome { applied = true } else { applied = false }
        } else {
            DebugLog.log(.sync, "[SystemWrite] no writer - direct write")
            do {
                try database.write { db in
                    _ = try Self.reconcileNotesBlocks(
                        db: db, projectId: projectId, targetRefs: refs, renameMap: renames, definitionOverrides: overrides)
                    try Self.fillBlankDefinitions(db: db, projectId: projectId, texts: overrides)
                }
                applied = true
            } catch {
                FootnoteDiag.log("restore direct write failed: \(type(of: error))")
                applied = false
            }
        }
        FootnoteDiag.log("restore finished applied=\(applied) duration=\(FootnoteDiag.nowMs() - started)ms")
        guard applied else { return }

        lastKnownRefs = refs
        lastRenumberedHash = refs.joined(separator: ",").hashValue
        carriedRenameMap = [:]
        lastContentWithKnownRefs = plan.content
        if let index = undoCheckpoints.firstIndex(where: { $0.id == plan.checkpointId }) {
            undoCheckpoints[index].committedRefs = refs
            undoCheckpoints[index].committedNumbering = plan.state.numbering
        }
        NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
        // The content this check carried may have no Notes (the removal push took them out); tooltips come from the table.
        if let notes = buildNotesSectionMarkdown(projectId: projectId) { pushDefinitionsToEditor(fullContent: notes) }
    }
}
