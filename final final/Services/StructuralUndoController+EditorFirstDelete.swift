//
//  StructuralUndoController+EditorFirstDelete.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D1, D1.0-D1.3, D6, D2.4, addenda A5-A7, A10, A18, A20, A21): "Delete Section" in Rich Text
//  without the freeze. The EDITOR takes the section off the screen first (one JavaScript call, a few milliseconds); the
//  database follows as a queued system-write job (`SectionDeleteJob`), behind everything the user typed. Nothing is read back
//  out of the editor and nothing is pushed back over the user's text.
//
//  This file is the controller's wiring of the two finished halves (the web side, `deleteSectionEditorFirst`; the database
//  side, `SectionDeleteJob`, `SectionDeleteSlotStore`, `EFJobRegistry`):
//
//    1. `performEditorFirstDelete(rootId:)`: the click. Runs under the structural gate. Returns nil when this press must take
//       today's whole sequence instead (Markdown mode, zoomed, no writer, the UI-test legacy flag, an undeletable root).
//    2. `editorFirstJobSettled(...)`: what happens when the job ends. Applied: the trailing resyncs. Anything else: the D6
//       put-back, which gives the section back from the database and tells the user.
//    3. `resolveEditorFirstUndoSnapshot(for:)`: under option (b) (quick undo is a later build) Cmd-Z of an editor-first delete
//       runs today's snapshot-based undo; this waits for the job and finds the snapshot id the job recorded on the entry's slot.
//    4. `repushManagedRegionsFromDatabase(_:)`: addendum A20, the last step of the slow undo's settle.
//
//  The slow-undo branches themselves live in `performUndo`/`performRedo` (StructuralUndoController.swift).
//

import SwiftUI
import WebKit
import GRDB

// MARK: - Small helpers

extension ProjectDatabase {
    /// The ids of the rows flagged Notes or Bibliography, read at the click and handed to the editor (plan D1.0: the editor never
    /// trusts its own managed set, because a rebuild's replace-wholesale can leave it stale). A small indexed read.
    func fetchManagedBlockIds(projectId: String) throws -> [String] {
        try read { db in
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == true || Block.Columns.isNotes == true)
                .select(Column("id"), as: String.self)
                .fetchAll(db)
        }
    }
}

extension ToastFactory {
    /// Addendum A4: the editor's undo coordinator gave up on queued Cmd-Z / Cmd-Shift-Z presses (its 30 s safety net, which needs a
    /// hung app). A notice-only warning (UX contract 4.1 and the 4.3 row for this notice): no action, and it fades after 9 seconds so
    /// it does not hold the one warning slot (fix round 2a, item 8; the same shape as the annotation display settings warnings).
    static func undoQueueDropped() -> Toast {
        Toast(style: .warning, message: "Some undo or redo presses could not be carried out.", fadeDelayOverride: .seconds(9))
    }
}

/// What `resolveEditorFirstUndoSnapshot` found (see there).
enum EditorFirstUndoResolution: Equatable {
    case snapshot(String)
    case gone
    case cancelled
}

/// Resumes the click path once the delete job holds its place in the writer's queue (plan D1.3 step 5, finding M3). One-shot and
/// MainActor-only: `fire()` may be called any number of times (the job's `onReserved` and the safety net after `perform` returns).
@MainActor
final class EFReservationSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation in
            if fired {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }
}

/// The JavaScript reply of `deleteSectionEditorFirst` (web/milkdown/src/api-section-delete.ts). Only the fields Swift uses.
struct EditorFirstDeleteReply: Decodable {
    /// Present on EVERY path (even a failed one) and ALWAYS applied: the pending changes the call consumed.
    let batch: BlockChanges
    /// The editor's `ok`: false means the document is unchanged or restored and no registry entry was left.
    let succeeded: Bool
    let reason: String?
    /// The headings and section breaks the removal took out, in document order: what the sidebar must stop showing.
    let removedLeaderIds: [String]?
    /// Every block id the removal transaction actually deleted, in document order. Absent (an older editor, a failed call): the
    /// job makes no comparison (fix round 2a, item 10).
    let removedIds: [String]?

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case removedLeaderIds
        case removedIds
    }
}

// MARK: - The click

extension StructuralUndoController {

    /// Delete Section, editor first (plan D1). Called under the structural gate. Returns nil, having changed nothing, when this
    /// press has to take today's whole sequence; otherwise the outcome the sidebar reports.
    func performEditorFirstDelete(rootId: String) async -> StructuralOpOutcome? {
        guard let editorState, let unifiedUndoService, let blockSync = blockSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return nil }
        #if DEBUG
        if testForceLegacyDelete { return nil }
        #endif
        // Rich Text, not zoomed, and a root the database agrees is a deletable leader (a Notes or Bibliography row, an unknown id
        // or a missing subtree row is today's refusal, which the old sequence reports exactly as before).
        //
        // The root check is ONE indexed row (`isDeletableSectionRoot`): the same yes or no `sectionBlockIds` gives, without fetching
        // and decoding every block row of the project on the main thread, which cost real time before the editor was even called
        // on a book-length document (fix round 12). `JobError.rootNotDeletable` and the put-back still cover anything stranger.
        let guardStartMs = StructTrace.nowMs()
        guard !TestMode.isUITestingStructuralLegacyDelete,
              editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              (try? db.isDeletableSectionRoot(rootId: rootId, projectId: pid)) == true else { return nil }
        let guardMs = StructTrace.nowMs() - guardStartMs

        let opId = UUID()
        guard let built = editorFirstScript(opId: opId, rootId: rootId, database: db, projectId: pid) else { return nil }
        let script = built.script
        let trace = StructTrace(label: "sectionDelete", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "sectionDelete", opId: trace.opId)
        trace.log("start (editor-first) guardMs=\(guardMs) managedIdsMs=\(built.managedIdsMs)")
        let epoch = unifiedUndoService.generation

        // D1.2: routine polls step aside from here until the job holds its place. `contentState` is NOT touched (that would bump
        // `contentGeneration` and discard a batch some routine cycle already fetched, finding M1).
        blockSync.structuralClickPending = true
        defer { blockSync.structuralClickPending = false }
        #if DEBUG
        if testEFBumpGenerationAtClick {
            // Addendum A10: U14's "old shape". Sets `contentState` non-idle and back before reserving, which bumps
            // `contentGeneration` the way the old whole-document sequence did.
            editorState.contentState = .structuralUndo
            editorState.contentState = .idle
        }
        spy("efClickStart")
        #endif

        // D1.3 and D1.4: reserve ticket N and submit the one call in ONE synchronous stretch, then apply whatever batch came back.
        guard let submission = await blockSync.submitEditorFirstDelete(database: db, projectId: pid, script: script) else {
            DebugLog.log(.undo, "[StructuralUndoController] editor-first delete: no writer turn available -- old path for this press")
            return nil
        }
        spy("efJS")
        trace.log("after the editor-first JS call")
        guard let reply = consumeEditorFirstReply(submission, blockSync: blockSync, database: db, projectId: pid) else {
            return .refused
        }
        guard reply.succeeded else {
            // `noEditor`: the editor had no document yet (a click in the first moment after a project opened). Nothing was consumed,
            // so this press takes today's whole sequence. That sequence finds no editor either (its `beginStructuralOp` answers
            // false), so it ends `.refused` and the user sees the same "Couldn't Delete Section" alert as for any refusal: this
            // branch removes no alert (fix round 2a, R2). It only keeps the editor-first path from reporting a refusal of its own.
            if reply.reason == "noEditor" {
                DebugLog.log(.undo, "[StructuralUndoController] editor-first delete: the editor was not ready -- old path for this press")
                return nil
            }
            // The editor refused or failed and put everything back: the section is still on screen.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first delete refused by the editor: \(reply.reason ?? "no reason")")
            return .refused
        }

        // What the user sees changes NOW (before the job is even reserved, so no outline tick can bring the section back):
        // the removed leaders leave the sidebar and are filtered out of every outline result until the job applies (D1.6, Q10).
        let removedLeaders = Set(reply.removedLeaderIds ?? [])
        editorState.pendingRemovalIds.formUnion(removedLeaders)
        var visibleSections = editorState.sections
        visibleSections.removeAll { removedLeaders.contains($0.id) }
        editorState.sections = visibleSections
        editorState.recalculateParentRelationships()

        // D1.5: reserve job N+1 and wait for its `onReserved` (M3) before the pause is lifted.
        await startEditorFirstJob(
            opId: opId, rootId: rootId, removedLeaders: removedLeaders, editorRemovedIds: reply.removedIds,
            database: db, projectId: pid)
        blockSync.structuralClickPending = false
        spy("efReservedJob")
        trace.log("after the job reserved its turn")

        // D1.6: record the entry (the Edit menu says "Undo Delete Section" at once) and push the descriptor.
        guard unifiedUndoService.generation == epoch else {
            // A barrier invalidated the timeline while the click ran: recording now would put an entry on a timeline that is no
            // longer this section's. The delete happened (and is saved), but cannot be undone with Cmd-Z.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first delete: timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionDelete, title: "Delete Section", undoSnapshotId: nil))
        spy("efRecorded")
        await pushDescriptor()
        trace.log("performed")
        return .performed
    }

    /// The one JavaScript expression of the click: `deleteSectionEditorFirst(opId, rootBlockId, managedIds)`, with the managed ids
    /// (Notes and Bibliography rows) read from the database now. Nil when they cannot be read. `managedIdsMs` is how long that read took
    /// (a trace figure only).
    private func editorFirstScript(
        opId: UUID, rootId: String, database: ProjectDatabase, projectId: String
    ) -> (script: String, managedIdsMs: Int)? {
        let managedIds: [String]
        let readStartMs = StructTrace.nowMs()
        do {
            managedIds = try database.fetchManagedBlockIds(projectId: projectId)
        } catch {
            DebugLog.log(.undo, "[StructuralUndoController] editor-first delete: reading the managed ids failed (\(error)) -- old path")
            return nil
        }
        let managedIdsMs = StructTrace.nowMs() - readStartMs
        guard let opLiteral = Self.jsLiteral(opId.uuidString), let rootLiteral = Self.jsLiteral(rootId),
              let managedLiteral = Self.jsLiteral(managedIds) else { return nil }
        let script = "JSON.stringify(window.FinalFinal.deleteSectionEditorFirst(\(opLiteral), \(rootLiteral), \(managedLiteral)))"
        return (script, managedIdsMs)
    }

    /// Plan D1.4: reads the editor's reply and settles ticket N. A returned batch is ALWAYS applied, whether the removal succeeded
    /// or not (the editor consumed it and nothing else will write it); an empty one settles the ticket `.empty`. A bridge call that
    /// threw, or a reply that cannot be read, may or may not have consumed the pending changes: the ticket settles
    /// `.discarded(.bridgeFailed)` and the loss is logged `alwaysPersisted`. Returns nil in those two cases.
    private func consumeEditorFirstReply(
        _ submission: BlockSyncService.EditorFirstSubmission, blockSync: BlockSyncService,
        database: ProjectDatabase, projectId: String
    ) -> EditorFirstDeleteReply? {
        let ticket = submission.ticket
        let json: String?
        switch submission.result {
        case .failure(let error):
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] editor-first delete: the JavaScript call threw (\(error)). Ticket settled as "
                + "discarded(bridgeFailed); typing from the last two seconds may not be saved until the next edit.")
            return nil
        case .success(let value):
            json = value
        }
        guard let json, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(EditorFirstDeleteReply.self, from: data) else {
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] editor-first delete: the editor's reply could not be read. Ticket settled as "
                + "discarded(bridgeFailed).")
            return nil
        }
        if reply.batch.isEmpty {
            ticket.settleIfOpen(.empty)
        } else if let webView = blockSync.webView {
            ticket.noteFetched()
            let changes = reply.batch
            let stamp = submission.stamp
            Task { @MainActor [weak blockSync] in
                defer { ticket.settleIfOpen(.noBatch) }
                await blockSync?.applyFetchedBatch(
                    ticket: ticket, changes: changes, stamp: stamp, webView: webView,
                    database: database, projectId: projectId, force: false)
            }
        } else {
            ticket.settleIfOpen(.discarded(.bridgeFailed))
        }
        return reply
    }

    /// Plan D1.5: opens the entry's slot, registers its job future, and spawns the job (`SectionDeleteJob.perform`, a
    /// `.sectionDelete` system write that reserves job N+1). Returns once the job holds its place in the writer's queue (its
    /// `onReserved` fired, or it came back without reserving), never when it applies. The task that runs the job and the work
    /// after it is kept in `efSettleTasks`.
    private func startEditorFirstJob( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, removedLeaders: Set<String>, editorRemovedIds: [String]?,
        database: ProjectDatabase, projectId: String
    ) async {
        guard let editorState else { return }
        efSlots.open(opId)
        let registry = editorState.efJobRegistry
        registry.register(opId)
        var heldJob = SectionDeleteJob(
            opId: opId, rootBlockId: rootId, projectId: projectId,
            fallbackBibliographyTitle: ExportSettingsManager.shared.effectiveBibliographyHeaderName, slots: efSlots)
        heldJob.bodyHold = jobBodyHold()
        heldJob.editorRemovedIds = editorRemovedIds
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let reserved = EFReservationSignal()
        let settleTask = Task { @MainActor [weak self, weak weakBlockSync = blockSyncService] in
            StructuralTrace.log("job task started")   // slice 0 measurement: when the task actually got its turn on the main actor
            // The job AND the work after it are over on every way out of here: whoever waits for the delete (the close/quit wait, the
            // zoom, the switch to Markdown, Save Version, export) is let go only now, not when the job's future resolved.
            defer { registry.markSettled(opId) }
            guard let blockSync = weakBlockSync else {
                reserved.fire()
                registry.resolve(opId, .abandoned)
                return
            }
            let result = await job.perform(
                on: blockSync, identity: identity, registry: registry,
                onReserved: {
                    StructuralTrace.log("onReserved fired")   // slice 0 measurement
                    reserved.fire()
                })
            reserved.fire()   // `perform` returned without reserving (refused before step 4): never leave the click waiting
            if case .applied(let output) = result.outcome, let mismatch = output.removedIdsMismatch {
                // The editor and the database disagree about which rows belong to the section (fix round 2a, item 10): the rules are
                // meant to be identical, so this means the screen and the saved copy are drifting apart. Log only: no behaviour change.
                DebugLog.alwaysPersisted(
                    "[StructuralUndoController] editor-first delete \(opId): the editor removed \(mismatch.editorOnly.count) row(s) "
                    + "the job did not delete (\(mismatch.editorOnly.prefix(5))), and the job deleted \(mismatch.jobOnly.count) row(s) "
                    + "the editor kept (\(mismatch.jobOnly.prefix(5)))")
            }
            await self?.editorFirstJobSettled(opId: opId, outcome: JobOutcome(result.outcome), removedLeaders: removedLeaders)
        }
        efSettleTasks[opId] = settleTask
        await reserved.wait()
    }

    /// The test/UI hold on the queued job's body (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS`, or the DEBUG seam a unit test sets).
    private func jobBodyHold() -> (@Sendable () -> Void)? {
        #if DEBUG
        if let hold = testEFJobBodyHold { return hold }
        #endif
        let milliseconds = TestMode.uiTestingStructuralJobHoldMs
        guard milliseconds > 0 else { return nil }
        return { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }
    }

    /// A JSON value as a JavaScript expression (JSON is a subset of JavaScript literals).
    private static func jsLiteral<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - After the job

    /// The job's future has resolved with `outcome`. Applied: the rows are gone and the Version History copy exists, so the
    /// removed leaders stop being filtered and the derived content catches up (plan D2.4: each step on its own, no nesting).
    /// Anything else: D6, the put-back.
    func editorFirstJobSettled(opId: UUID, outcome: JobOutcome, removedLeaders: Set<String>) async {
        defer { efSettleTasks[opId] = nil }
        guard let editorState else { return }
        spy("efJobSettled")
        switch outcome {
        case .applied:
            editorState.pendingRemovalIds.subtract(removedLeaders)
            #if DEBUG
            await testEFSettleHold?()
            #endif
            await resyncAfterEditorFirstDelete(editorState: editorState)
        case .abandoned:
            // The lifecycle barrier resolved the future before the job reported: the project is closing or switching.
            editorState.pendingRemovalIds.subtract(removedLeaders)
            DebugLog.log(.lifecycle, "[StructuralUndoController] editor-first delete \(opId): job abandoned by the lifecycle")
        case .failed, .refused:
            DebugLog.alwaysPersisted("[StructuralUndoController] editor-first delete \(opId): the job did not apply (\(outcome))")
            await putBackAfterFailedDelete(opId: opId, removedLeaders: removedLeaders)
        }
    }

    /// Plan D2.4: bibliography and footnote resyncs, section sync, annotation sync and a sidebar refresh, queued one after the
    /// other so none nests inside another system write. Reads `editorState.content`, which the editor's own removal updates when
    /// its `contentChanged` message arrives, through the editor's 50 ms debounce. That is normally earlier than the job's whole
    /// transaction ends, but on a small document the job can finish first, and then these resyncs read the text from before the
    /// delete. The next change to the document runs them again on the right text, so the effect is a short delay in the footnote
    /// and bibliography update, nothing lost.
    ///
    /// Last step, only while a close, quit or project switch holds the editor: the database's Notes and Bibliography go into the editor
    /// (`pushManagedRegionsWhileClosing`). The footnote resync renumbers the references in the editor (28-54 become 19-45) but cannot
    /// take the deleted chapter's definitions out of the editor's Notes, so the editor's Notes are half updated; the usual cure, the
    /// Notes rebuild that pushes the database's Notes into the editor, is held back while a lifecycle is armed. The lifecycle's
    /// whole-document save would then write the editor's half-updated Notes over the database's correct ones. The lifecycle waits for
    /// this whole settle (`EditorViewState.waitForSectionOperation` reads `efJobRegistry.hasUnsettledWork`), so the push has landed
    /// before the save captures the editor.
    private func resyncAfterEditorFirstDelete(editorState: EditorViewState) async {
        let content = editorState.content
        let projectId = editorState.currentProjectId
        if let pid = projectId {
            await bibliographySyncService?.resyncNow(
                citekeys: BibliographySyncService.extractCitekeys(from: content), projectId: pid)
            await footnoteSyncService?.resyncNow(
                footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: content), projectId: pid, fullContent: content)
        }
        if DocumentManager.shared.projectId == editorState.currentProjectId {
            await sectionSyncService?.syncNow(editorState.content)
        }
        await annotationSyncService?.syncNow(editorState.content)
        editorState.refreshSections()
        // The resyncs above write the database's Notes and Bibliography and so start the background rebuilds that carry them into the
        // editor. The settle is over only when those have landed (fix round 5, part A1): the undo, the close and quit wait, and the
        // zoom, mode-switch, Save Version and export waits all wait for the settle, and a rebuild whose push lands after they have
        // started would put the post-delete document back over theirs. (A rebuild the lifecycle deferred has no Task to wait for.)
        await editorState.awaitNoRunningRebuilds(label: "delete follow-up", showsNotice: false)
        await pushManagedRegionsWhileClosing(editorState: editorState, projectId: projectId)
    }

    /// The footnote and bibliography resyncs above wrote the database's Notes and Bibliography. While a lifecycle is armed the
    /// handlers that normally carry them into the editor are deferred (`ContentView.handleNotesSectionChanged` and its bibliography
    /// twin return early while `activeLifecycle != nil`), so push them here with the same merge-guarded push the slow undo's settle
    /// uses (addendum A20): the regions and their ids come from the database, typing in user blocks survives. Nothing to do outside a
    /// lifecycle (the normal rebuild runs), in Markdown (no delete is editor-first there), while zoomed, or when the project is
    /// no longer the one the resync ran for.
    ///
    /// It does what the normal Notes rebuild (`ContentView.handleNotesSectionChanged`) does, in the same order (fix round 6; the VM's
    /// `testQuitRightAfterDeleteNumbering_book6` saved 45 references on their ORIGINAL numbers with the notes on the wrong numbers):
    /// 1. First the ORDERED forced poll (`pollBlockChangesNowForDatabaseRebuild`: it also waits for a batch the routine poll has
    ///    already fetched and not yet applied) carries the editor's pending changes into the database. The footnote resync renumbers
    ///    the references IN THE EDITOR with the content push suppressed, so that renumber (like any typing the poll has not carried)
    ///    is an unsent edit that only a poll takes to the database; lifecycle step 0 has stopped the routine poll. Reading the
    ///    database before this poll gave stale references with already-renumbered Notes.
    /// 2. Then the database is read, and `isResettingContent` stays set from the moment `content` is assigned until the merge push
    ///    has returned: without it the view pushes `content` (which the merge push has not yet been allowed to update, about a
    ///    second) into the editor and replaces its user blocks. With the poll done the database text carries the editor's edits, so
    ///    `content` is what the editor holds, and what the whole-document save falls back to when it cannot fetch (`FB` reads
    ///    `editorState.content` then) is the renumbered text, not a stale one.
    /// 3. The merge-guarded push keeps whatever the editor still holds in its user blocks and takes the database's Notes and
    ///    Bibliography.
    private func pushManagedRegionsWhileClosing(editorState: EditorViewState, projectId: String?) async {
        guard editorState.activeLifecycle != nil, editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              let pid = projectId, editorState.currentProjectId == pid else { return }
        // A flush that did not complete (the editor did not answer within the poll's watchdog, or the writer did not settle) may have
        // left the editor's pending edits out of the database: reading it then would assign an OLDER document to `content` (which the
        // whole-document save falls back to when it cannot fetch) and push it. So nothing is assigned or pushed then; the lifecycle's
        // own forced poll (F) and the save fetch the editor's live text afterwards (fix round 8, F6).
        guard await blockSyncService?.pollBlockChangesNowForDatabaseRebuild() ?? true else {
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] closing push skipped: the forced poll did not complete (watchdog or unsettled writer)")
            return
        }
        // The poll suspended: look again (a cancelled lifecycle hands the rebuild back to the handlers, a switch changes the project).
        guard editorState.activeLifecycle != nil, editorState.currentProjectId == pid, let db = editorState.projectDatabase,
              let result = fetchFullBlocksWithIds(db: db, pid: pid) else { return }
        let wasResettingContent = editorState.isResettingContent
        editorState.isResettingContent = true
        defer { editorState.isResettingContent = wasResettingContent }
        // As the rebuild handlers and the undo's settle do: `content` first (the view cannot push it meanwhile: the flag above);
        // `repushManagedRegionsFromDatabase` then replaces it with the merged text when that differs.
        editorState.content = result.markdown
        await repushManagedRegionsFromDatabase(result)
    }

    // MARK: - D6: the job did not apply

    /// Plan D6: the database still holds the section plus every applied batch, so it is the truth. Put the document back from it
    /// with a whole-content push (deliberately NOT the merge-guarded one: the removal must be undone everywhere), drop the entry,
    /// its slot and its pin, and tell the user (UX contract 4.3: a modal alert for a section delete that did not happen).
    /// A put-back can overwrite typing from the last poll window (parked as rare, plan section 7, P9).
    private func putBackAfterFailedDelete(opId: UUID, removedLeaders: Set<String>) async {
        guard let editorState, let unifiedUndoService else { return }
        defer {
            editorState.pendingRemovalIds.subtract(removedLeaders)
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            efRecordedGeneration[opId] = nil
        }
        unifiedUndoService.removeEntry(opId: opId)
        // Remembered so that a Cmd-Z for this entry that was already on its way (held on the gate while this ran) is answered
        // `failed`, not `fallback`: the section was put back, and a plain text undo now would remove the user's last typing
        // (fix round 2a, item 12; see `resolveOutcome`).
        efPutBackOpIds.insert(opId)
        // A project that is closing has nothing to put back into: its content is saved by the lifecycle's own whole-document write.
        guard !editorState.structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[StructuralUndoController] D6 put-back skipped: the project is closing or switching")
            return
        }
        await evalVoid("window.FinalFinal.clearFailedStructuralOpEntry?.('\(opId.uuidString)')")
        if let db = editorState.projectDatabase, let pid = editorState.currentProjectId,
           let result = fetchFullBlocksWithIds(db: db, pid: pid) {
            editorState.content = result.markdown
            editorState.isResettingContent = true
            await blockSyncService?.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex, cursorBoundaryEnd: result.bibBoundaryEndIndex,
                detectPausedEdits: true,
                expectedBlocks: result.expectedBlocks,
                managedBlockIds: result.managedBlockIds
            )
            editorState.isResettingContent = false
            NotificationCenter.default.post(
                name: .blockSyncDidPushContent, object: nil, userInfo: ["markdown": result.markdown]
            )
        } else {
            DebugLog.alwaysPersisted("[StructuralUndoController] D6 put-back: could not read the document back from the database")
        }
        await pushDescriptor()
        editorState.pendingRemovalIds.subtract(removedLeaders)
        editorState.refreshSections()
        presentAlert?(SectionOperationAlert(
            title: "Couldn't Delete Section",
            message: "The delete couldn't be saved, so the section has been put back. If you typed in the last moments, "
                + "check that your text is still there."
        ))
    }

    // MARK: - Option (b): undo of an editor-first delete

    /// Under option (b) (quick undo is slice 2b) Cmd-Z of an editor-first delete runs today's snapshot-based undo with the snapshot
    /// id the delete job recorded on the entry's slot (plan D5c, A18). Waits for the job (its future always resolves) and for
    /// its trailing resyncs, so the undo never overlaps them. The "Undoing..." toast is the CALLER's (`performUndo`), so it
    /// covers the restore and the settle too (fix round 2a, item 1).
    ///
    /// The answer says what the caller replies to the editor: `.snapshot` (go on), `.gone` (the job did not apply, so D6 has
    /// already put the section back and taken the entry away, or the slot is gone: the caller replies `failed`, because a plain
    /// text undo now would remove the user's typing, item 12) or `.cancelled` (the lifecycle abandoned the job: the project is
    /// closing, the caller replies `cancelled`).
    func resolveEditorFirstUndoSnapshot(for entry: StructuralEntry) async -> EditorFirstUndoResolution {
        guard let editorState else { return .gone }
        let outcome = await editorState.efJobRegistry.awaitOutcome(entry.id)
        if outcome == .abandoned { return .cancelled }
        if let settle = efSettleTasks[entry.id] { await settle.value }
        guard outcome == .applied else {
            DebugLog.log(
                .undo, "[StructuralUndoController] undo of editor-first delete \(entry.id): job outcome "
                + "\(String(describing: outcome)) -- nothing to undo from")
            return .gone
        }
        guard let slot = efSlots.slot(entry.id), let snapshotId = slot.snapshotId else {
            DebugLog.log(.undo, "[StructuralUndoController] undo of editor-first delete \(entry.id): no slot or no snapshot -- nothing to undo from")
            return .gone
        }
        // Addendum A18: another kind of write touched the block table since this entry was recorded (or an earlier undo already
        // took the snapshot path): from here every undo and redo of this entry is today's snapshot path, and the slot says so.
        if efRecordedGeneration[entry.id] != editorState.outOfQueueWriteGeneration || slot.state == .fallback {
            efSlots.markFallback(entry.id)
        }
        return .snapshot(snapshotId)
    }

    /// Addendum A20: after the slow undo/redo of an editor-first delete has put the checkpoint back, the editor's Notes and
    /// Bibliography may be older than the database's (a rebuild can reserve a writer ticket between the click's ticket and the
    /// job). Push the DATABASE's managed regions into the editor with the same merge-guarded push a rebuild uses, so typing in
    /// user blocks survives. `result` is the settle's own database read (`fetchFullBlocksWithIds`), so the regions and the
    /// managed ids both come from the database, never from the editor's text.
    func repushManagedRegionsFromDatabase(_ result: ContentView.BlockFetchResult) async {
        guard let blockSyncService else { return }
        let merged = await blockSyncService.setContentWithBlockIds(
            markdown: result.markdown, blockIds: result.blockIds,
            imageMeta: result.imageMeta,
            cursorBoundary: result.bibBoundaryIndex, cursorBoundaryEnd: result.bibBoundaryEndIndex,
            expectedBlocks: result.expectedBlocks,
            managedBlockIds: result.managedBlockIds,
            preserveUserBlocks: true)
        spy("efRepushManagedRegions")
        DebugLog.log(.undo, "[StructuralUndoController] A20: re-pushed the database's Notes and Bibliography (merged=\(merged != nil))")
        // Fix round 2a, item 6: the merge-guarded push hands back the markdown the editor ACTUALLY holds now (the database's managed
        // regions plus whatever the user typed in user blocks). Like the three rebuild handlers (ContentView+NotificationHandlers
        // and +FootnoteHandlers), reflect it into `editorState.content` when it differs from the database text: the settle just set
        // `content` to the database text, the push set the coordinator's last-pushed text to the merged one, and leaving the two
        // different would make the next view update push the database text over the editor again (the "re-push wipes the swap"
        // hazard), overwriting typing in the short tail after the undo.
        if let merged, merged != result.markdown {
            DebugLog.log(
                .undo,
                "[StructuralUndoController] A20: the editor's merged text differs from the database text "
                + "(\(merged.count) vs \(result.markdown.count) characters) -- keeping the merged text as the content")
            editorState?.content = merged
        }
    }

    // MARK: - Messages and lifecycle

    /// Addendum A4: the editor's 30 s safety net dropped queued undo/redo presses.
    func showUndoQueueDroppedWarning() {
        editorState?.toastCenter.show(ToastFactory.undoQueueDropped())
    }

    /// Fix round 5, part B (judge ruling "allowance"): `count` presses the editor held in its own queue ended WITHOUT a request to
    /// Swift (a plain text undo took them, or they were dropped: the editor's `undoHeldPressSettled` message). A close or quit that
    /// counted them at its barrier stops waiting for them. The editor sends this message for every way a held press can end without
    /// a request, the dropped-presses warning's path included (it posts `undoQueueDropped` AND this message with the same count), so
    /// the warning's handler does not settle anything itself: that would count the same presses twice.
    func settleHeldPresses(_ count: Int) {
        editorState?.structuralGate.settleHeldPresses(count)
        DebugLog.log(.undo, "[StructuralUndoController] \(count) held press(es) ended without a request")
    }
}

/// Multi-window guard for the `undoQueueDropped` message, mirroring `routeHistoryEdited`: the warning goes to the window that
/// posted it, never to whichever controller the global slot holds.
@MainActor
func routeUndoQueueDropped(from requestingWebView: WKWebView?, editorLabel: String) {
    guard let controller = DocumentManager.shared.structuralUndoController,
          controller.activeWebView === requestingWebView else {
        DebugLog.log(.undo, "[\(editorLabel)] undoQueueDropped from a non-active window -- ignoring")
        return
    }
    controller.showUndoQueueDroppedWarning()
}

/// Multi-window guard for the `undoHeldPressSettled` message, the same shape as `routeUndoQueueDropped`: the count goes to the window
/// that posted it, never to whichever controller the global slot holds.
@MainActor
func routeUndoHeldPressSettled(count: Int, from requestingWebView: WKWebView?, editorLabel: String) {
    guard let controller = DocumentManager.shared.structuralUndoController,
          controller.activeWebView === requestingWebView else {
        DebugLog.log(.undo, "[\(editorLabel)] undoHeldPressSettled from a non-active window -- ignoring")
        return
    }
    controller.settleHeldPresses(count)
}
