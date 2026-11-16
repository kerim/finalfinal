//
//  BlockSyncService+Markdown.swift
//  final final
//
//  t-94369a83 Phase 4a, plan v2 section 1(b) and 1(e), judge verdict 2 notes C1 and C2: BlockSyncService's side of
//  saving Markdown typing block by block through the ordered write queue. The pure half (what to write) is
//  `MarkdownBlockDiff`; this file is the part that talks to `DocumentWriter`.
//
//  THE ENTRY IS SPLIT IN TWO (judge note C1). The reservation must happen in the SAME main-actor turn as the
//  caller's gate check, with no suspension in between, because the lifecycle's step 0, its barrier and the
//  "a write reserved before the lifecycle armed lands before FB" argument all rely on it. A single
//  `Task { await applyMarkdownBatch(...) }` would reserve only when the Task is scheduled, after other main-actor
//  work (a lifecycle arming, a project switch) had a chance to run. So:
//
//    (i)  `reserveMarkdownTurn(database:projectId:)` is SYNCHRONOUS: identity check, the deferred-epoch-bump retry,
//         the epoch read, `reserve()`, `noteFetched()`. The fire and `writeNow` call it inline, BEFORE they create any
//         Task, and hold the returned turn.
//    (ii) `applyMarkdownTurn(_:_:)` is ASYNC: `waitForTurn()` -> apply -> result handling, all inside
//         `defer { ticket.settleIfOpen(.noBatch) }` so the sequence is settled on every exit (plan 1(b), M2).
//         It is the body of the Task the caller creates (or awaits, for `writeNow`).
//
//  Plan v2 section 1(b) named ONE entry, `applyMarkdownBatch(_:database:projectId:)`; judge note C1 split it into the
//  two functions above. There is deliberately NO combined `applyMarkdownBatch`: a caller that wrapped it in a Task
//  would quietly bring the C1 defect back.
//
//  WHY THIS ROUTE (plan 1(b), confirmed by the reviewers). It is the editor-batch path, the one Rich Text's reports
//  use (and the 2-second poll did, in the plan's time): per-row stamps and the project epoch refuse a batch that would land after
//  a newer direct whole-document write (zoom and the mode-switch flush were direct until Phase 5); the bibliography and Notes safety nets in the
//  database apply; sequences are one counter shared with system writes; `.nested` cannot be reached; and the
//  sequence is marked fetched at reservation, so the 3 s late-expiry never applies to it.
//

import Foundation

// MARK: - Result types

/// A reserved turn: the writer's ticket and the stamp the batch will be written at. Held by the caller from the
/// synchronous reservation until `applyMarkdownTurn` has returned.
struct MarkdownTurn: Sendable {
    let ticket: WriterTicket
    let stamp: BlockWriteStamp
}

/// Why no turn was reserved (nothing was reserved, so nothing needs settling), or why an apply was refused.
enum MarkdownRefusal: Sendable, Equatable {
    /// The service has no writer. The caller's fallback is the legacy whole-document write.
    case noWriter
    /// The writer belongs to another database or project than the one the caller captured.
    case identityMismatch
    /// The deferred epoch bump could not be retried, or the epoch could not be read: nothing was reserved.
    case epochUnavailable
    /// The writer's admission said it is not this sequence's turn after `waitForTurn` said go (settled as
    /// `.discarded(.outOfTurn)`, as `applyAndConfirm` does).
    case outOfTurn
}

enum MarkdownTurnReservation: Sendable {
    case reserved(MarkdownTurn)
    case refused(MarkdownRefusal)
}

/// What the Markdown batch came to. The five outcomes are distinct on purpose: the caller's baseline handling
/// differs for each (plan 1(d) step 6).
enum MarkdownBatchOutcome: Sendable {
    /// Written. Inspect `isClean`: a batch with any dropped update or delete, or any insert rejected for a missing
    /// anchor, is applied but not clean.
    case applied(EditorApplyResult)
    /// The database refused the WHOLE batch for a stale epoch (`rejectedWholeBatchForStaleEpoch`): a direct
    /// whole-document write, a lifecycle write or a `configure` bumped the epoch after this turn was reserved.
    /// Nothing was written (the inserts were dropped silently); counted in
    /// `LossLedger.markdownStaleEpochRejections`. The result carries the dropped update and delete ids.
    case staleEpoch(EditorApplyResult)
    /// Nothing was reserved, or the writer refused the apply.
    case refused(MarkdownRefusal)
    /// The writer skipped this sequence (a retire, a drain or a project switch reached it): nothing was written.
    /// `MarkdownBlockWriter` treats it like every other non-clean outcome (baseline back to rows, one retry); the
    /// `countsAsRefusal` helper below is used only by tests.
    case skipped
    /// The database write threw.
    case failed(Error)

    /// The batch was written and nothing in it was dropped or rejected.
    var isClean: Bool {
        guard case .applied(let result) = self else { return false }
        return result.droppedUpdateIds.isEmpty && result.droppedDeleteIds.isEmpty
            && result.rejectedStaleAnchorInserts.isEmpty
    }

    /// Refused, skipped and out-of-turn all mean "nothing of this batch was written". Used only by tests: production
    /// code (`MarkdownBlockWriter.verdict(for:prepared:)`) switches on the outcome itself.
    var countsAsRefusal: Bool {
        switch self {
        case .refused, .skipped: return true
        case .applied, .staleEpoch, .failed: return false
        }
    }
}

/// What `ensureWriter` did.
enum EnsureWriterOutcome: Sendable, Equatable {
    /// A new writer now exists for this database and project.
    case installed
    /// A live writer for this database and project already existed.
    case alreadyPresent
    /// A close, switch, quit or other lifecycle token is armed: never touch the writer under it (obligation N8).
    case skippedLifecycleActive
    /// The editor state's project is not the document manager's: a switch is between its open and its tail.
    case skippedProjectMismatch
}

extension BlockSyncService {

    // MARK: - (i) The synchronous reservation

    /// Judge note C1, part (i). SYNCHRONOUS: no `await`, no Task. Call it in the same main-actor turn as the gate
    /// check that decided to write, before creating any Task.
    ///
    /// Steps: the writer's identity must be the caller's database and project (`.identityMismatch` otherwise); then
    /// `reserveWriterTurn` (the reports' own body: retry a deferred `blockWriteEpoch` bump, read the epoch, `reserve()`);
    /// then `noteFetched()` (a Markdown batch is "fetched" the moment it is reserved: the text is already in Swift,
    /// so the writer's 3 s late-expiry must not apply to it).
    ///
    /// Nothing is reserved on a refusal, so the caller has nothing to settle.
    func reserveMarkdownTurn(database: ProjectDatabase, projectId: String) -> MarkdownTurnReservation {
        guard let writer else {
            DebugLog.log(.lifecycle, "[MdWrite] refused: no writer")
            return .refused(.noWriter)
        }
        guard writer.database === database, writer.projectId == projectId else {
            DebugLog.log(.lifecycle, "[MdWrite] refused: the writer belongs to another database or project")
            return .refused(.identityMismatch)
        }
        guard let (ticket, stamp) = reserveWriterTurn(database: database, projectId: projectId) else {
            DebugLog.log(.lifecycle, "[MdWrite] refused: the epoch is unavailable (deferred bump failed or epoch unreadable)")
            return .refused(.epochUnavailable)
        }
        ticket.noteFetched()
        return .reserved(MarkdownTurn(ticket: ticket, stamp: stamp))
    }

    // MARK: - (ii) The asynchronous apply

    /// Judge note C1, part (ii): `waitForTurn` -> apply -> result handling, ALL inside
    /// `defer { ticket.settleIfOpen(.noBatch) }`, so every exit settles the sequence (a no-op once the apply already
    /// settled it, S3).
    ///
    /// - A `.skipped` turn (at the wait or at admission) is `.skipped`: nothing written, counted by the writer's own
    ///   `skip()` call, treated as a refusal by the caller.
    /// - `.outOfTurn` is settled `.discarded(.outOfTurn)` (the phase entry is still open on that path; without this the
    ///   `defer` would settle it uncounted), exactly as `applyAndConfirm` does.
    /// - A stale-epoch rejection comes back from the writer as `.applied(result)` with
    ///   `rejectedWholeBatchForStaleEpoch` set (settled fact), so it is checked EXPLICITLY here (plan 1(d) step 6): it is
    ///   its own outcome, counted in `LossLedger.markdownStaleEpochRejections`.
    ///
    /// Every outcome is logged at `.lifecycle` with the batch's counts u/i/d.
    func applyMarkdownTurn(_ turn: MarkdownTurn, _ changes: BlockChanges) async -> MarkdownBatchOutcome {
        let ticket = turn.ticket
        defer { ticket.settleIfOpen(.noBatch) }
        let counts = "u/i/d=\(changes.updates.count)/\(changes.inserts.count)/\(changes.deletes.count)"

        guard await ticket.waitForTurn() == .go else {
            DebugLog.log(.lifecycle, "[MdWrite] skipped at the wait seq=\(ticket.seq) \(counts)")
            return .skipped
        }

        // `renumberSortOrdersIfCrowded: true` (plan 1(b), review M8; Rich Text's `applyAndConfirm` passes it too since t-75d20927).
        // `dedupImagesWithinBatch: false`: a Markdown document that holds the same image line twice keeps two rows; only Rich Text
        // de-duplicates same-src images within one batch.
        let outcome = await ticket.writer.applyEditorBatch(
            ticket.seq, changes, stamp: turn.stamp, renumberSortOrdersIfCrowded: true, dedupImagesWithinBatch: false)
        switch outcome {
        case .applied(let result):
            if result.rejectedWholeBatchForStaleEpoch {
                ticket.writer.noteMarkdownStaleEpochRejection(
                    updates: changes.updates.count, inserts: changes.inserts.count, deletes: changes.deletes.count)
                DebugLog.log(
                    .lifecycle,
                    "[MdWrite] stale epoch: whole batch refused seq=\(ticket.seq) \(counts) "
                    + "(batch epoch \(turn.stamp.epoch))")
                return .staleEpoch(result)
            }
            DebugLog.log(
                .lifecycle,
                "[MdWrite] applied seq=\(ticket.seq) \(counts) written=\(result.writtenCount) "
                + "droppedUpdates=\(result.droppedUpdateIds.count) droppedDeletes=\(result.droppedDeleteIds.count) "
                + "staleAnchorInserts=\(result.rejectedStaleAnchorInserts.count)")
            return .applied(result)
        case .refused(.skipped):
            DebugLog.log(.lifecycle, "[MdWrite] skipped at admission seq=\(ticket.seq) \(counts)")
            return .skipped
        case .refused(.outOfTurn):
            // The phase entry is still open on this path; give it its own counted outcome (see `applyAndConfirm`).
            ticket.settleIfOpen(.discarded(.outOfTurn))
            DebugLog.log(.lifecycle, "[MdWrite] refused out of turn seq=\(ticket.seq) \(counts)")
            return .refused(.outOfTurn)
        case .failed(let error):
            DebugLog.log(.lifecycle, "[MdWrite] FAILED seq=\(ticket.seq) \(counts): \(error)")
            return .failed(error)
        }
    }

    // MARK: - ensureWriter

    /// Plan v2 section 1(e), judge note C2: installs a writer for `database` and `projectId` when there is none, WITHOUT
    /// a WebView. Today a writer is created only by `configure` (Milkdown's `onWebViewReady`) or `reconfigure` (a
    /// project switch's open tail), so a path that reaches Markdown without either has no writer and its typing would
    /// take the legacy direct write. This is the guarded safety net for that (no real flow is known to need it: the app
    /// always starts in Rich Text and every project switch calls `reconfigure`); the caller (CodeMirror's
    /// `onWebViewReady`, through `ContentView.prepareMarkdownBlockWriter`) passes the facts as parameters so each rule is
    /// unit-testable.
    ///
    /// - No-op `.skippedLifecycleActive` while a lifecycle token is armed (`lifecycleActive`, i.e.
    ///   `editorState.activeLifecycle != nil`): never replace a writer a close, switch or quit holds (obligation N8).
    /// - No-op `.skippedProjectMismatch` unless `editorProjectId == projectId` (`editorState.currentProjectId` against
    ///   `documentManager.projectId`, M13): between a switch's open and its tail the editor state still names the old
    ///   project, and the tail's `reconfigure` creates the new writer.
    /// - No-op `.alreadyPresent` when a LIVE writer (not retired) already exists for this database and project.
    ///   `reconfigure` composes with this: before it, the mismatch rule makes this a no-op; after it, the writer exists.
    /// - Otherwise mirrors `configure`'s new-writer branch (both call `replaceWriter`): retire the old writer (`.writerReplaced`), continue the
    ///   sequence numbers, carry the DEBUG test knobs, bump the epoch (a failed bump sets `needsEpochBump`, retried by
    ///   `reserveMarkdownTurn` and the next reserved turn of any kind). It touches neither the WebView nor the editor's reports, and not
    ///   the service's own database/project fields (those stay `configure`'s, so Milkdown's later `configure` still sees a different
    ///   project and installs its own writer).
    @discardableResult
    func ensureWriter(
        database: ProjectDatabase, projectId: String, lifecycleActive: Bool, editorProjectId: String?
    ) -> EnsureWriterOutcome {
        guard !lifecycleActive else {
            DebugLog.log(.lifecycle, "[MdWrite] ensureWriter: no-op, a lifecycle token is armed")
            return .skippedLifecycleActive
        }
        guard editorProjectId == projectId else {
            DebugLog.log(.lifecycle, "[MdWrite] ensureWriter: no-op, the editor state names another project")
            return .skippedProjectMismatch
        }
        if let writer, !writer.isRetired, writer.database === database, writer.projectId == projectId {
            return .alreadyPresent
        }

        let next = replaceWriter(database: database, projectId: projectId, retiringOldWriterFor: .writerReplaced)
        do {
            _ = try database.bumpBlockWriteEpoch(projectId: projectId)
            needsEpochBump = false
        } catch {
            needsEpochBump = true
            DebugLog.alwaysPersisted(
                "[BlockSync] ensureWriter: could not bump blockWriteEpoch (\(error)) - the next Markdown write or poll will retry it")
        }
        DebugLog.log(.lifecycle, "[MdWrite] ensureWriter: installed a writer (first sequence \(next))")
        return .installed
    }
}
