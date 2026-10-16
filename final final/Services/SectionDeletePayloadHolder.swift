//
//  SectionDeletePayloadHolder.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (quick undo of an editor-first section delete; plan-v2-addendum 2.1, verdict-v1 item 8): the
//  rows a section delete saw just before it deleted, kept where the quick undo's queued job can read them whether or not the
//  entry's slot still exists.
//
//  WHY NOT THE SLOT. The slot (`SectionDeleteSlotStore`) is removed the moment the timeline discards the entry (a text edit after
//  the undo drops the redo branch, `UnifiedUndoService.invalidateRedoBranch` -> `discardEditorFirstEntry`), and a queued reinsert
//  that is still waiting for its turn must still apply: the editor already shows the section, so the database has to follow. The
//  holder is a small reference object created at the delete click and shared by the slot's owner (the controller's `efHolders`), the
//  delete job (fills it when its transaction commits) and every reinsert job (captures it strongly when it is reserved). A discard
//  removes the controller's reference and leaves the job's.
//
//  WHO WRITES IT. Only the delete job's after-commit hook (`fill`, on the writer's queue, before the job's `write` returns, so before
//  any later ticket runs) and `markFailed` (the job did not apply). A quick redo's new delete job fills it again with the rows it
//  saw. A reinsert reads `snapshot()` once, inside its own transaction: ticket order alone says which delete job's rows that is
//  (reinsert R1 was reserved before the redo's job J2, so it reads J1's rows; R2 was reserved after J2, so it reads J2's).
//
//  LOCKING. Touched from the MainActor (the controller) and from the writer's executor (the job hooks), so one unfair lock guards
//  every access.
//

import Foundation
import os

final class SectionDeletePayloadHolder: Sendable {

    /// How the delete job of this entry ended, as far as a reinsert is concerned.
    enum Outcome: Sendable, Equatable {
        /// The job has not committed (or failed) yet.
        case pending
        /// The job committed: `preDeleteRows` are every row of the project just before it deleted.
        case applied
        /// The job did not apply (the database still holds the section, the D6 put-back owns that case).
        case failed
    }

    struct State: Sendable {
        /// Every row of the project, in `sortOrder`, as the delete job's own transaction read them just before the delete. The
        /// reinsert makes the table EXACTLY equal to this.
        var preDeleteRows: [Block] = []
        /// The section's leader rows (headings and section breaks) among the deleted rows: what the sidebar shows again.
        var leaders: [Block] = []
        /// The database id of the deleted section's root (the job resolved the editor's id through the writer's temp-id map).
        var resolvedRootId: String?
        var outcome: Outcome = .pending
        /// Bumped by every `fill`: how many delete jobs of this entry have applied.
        var jobSerial = 0
        /// The leader ids the editor reported at the click (they may still be temp ids): what `pendingRemovalIds` holds for this entry.
        var clickLeaderIds: Set<String> = []
        /// The footnote undo checkpoints that existed when the delete was clicked (plan-v2 4.4): a quick undo drops every one
        /// recorded since.
        var footnoteCheckpointMarker: Set<UUID> = []
        /// The token of the footnote checkpoint hold the quick undo set (released by the reinsert's settle or a quick redo).
        var checkpointHoldToken: UUID?
    }

    let opId: UUID
    /// The section root the click named (a database id: the sidebar reads the outline from the database).
    let rootId: String
    let projectId: String

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(opId: UUID, rootId: String, projectId: String) {
        self.opId = opId
        self.rootId = rootId
        self.projectId = projectId
    }

    /// A copy of the current state (rows are copy-on-write, so this is cheap).
    func snapshot() -> State {
        lock.withLock { $0 }
    }

    var outcome: Outcome {
        lock.withLock { $0.outcome }
    }

    /// The delete job's after-commit record: the rows it saw, the leaders it removed, the id it resolved, outcome `applied`.
    func fill(rows: [Block], leaders: [Block], resolvedRootId: String) {
        lock.withLock { state in
            state.preDeleteRows = rows
            state.leaders = leaders
            state.resolvedRootId = resolvedRootId
            state.outcome = .applied
            state.jobSerial += 1
        }
    }

    /// The delete job did not apply. Never turns an applied holder into a failed one (a redo's job failing leaves the rows of the
    /// earlier job for a reinsert already reserved behind it, and the D6 put-back removes the entry anyway): only a pending
    /// holder fails.
    func markFailed() {
        lock.withLock { state in
            if state.outcome == .pending { state.outcome = .failed }
        }
    }

    func setClickLeaderIds(_ ids: Set<String>) {
        lock.withLock { $0.clickLeaderIds = ids }
    }

    func setFootnoteCheckpointMarker(_ marker: Set<UUID>) {
        lock.withLock { $0.footnoteCheckpointMarker = marker }
    }

    func setCheckpointHoldToken(_ token: UUID?) {
        lock.withLock { $0.checkpointHoldToken = token }
    }

    /// Returns the hold token and clears it (so a release happens once).
    func takeCheckpointHoldToken() -> UUID? {
        lock.withLock { state in
            let token = state.checkpointHoldToken
            state.checkpointHoldToken = nil
            return token
        }
    }
}
