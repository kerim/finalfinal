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
//       today's whole sequence instead (Markdown mode, zoomed, no writer, the UI-test legacy flag, an undeletable root). The
//       stretch it shares with every editor-first operation (poll pause, rebuild stamp, the one JavaScript call, the refusal
//       exits) is `runEditorFirstStructuralClick` (t-18b7fa48 round 1b, StructuralUndoController+EditorFirstStructural.swift).
//    2. `editorFirstJobSettled(...)`: what happens when the job ends. Applied: the trailing resyncs. Anything else: the D6
//       put-back (`putBackAfterFailedEditorFirstOp`, in the shared file), which gives the section back from the database and
//       tells the user.
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
    /// Slice 2b: true only when the job's `onReserved` fired (the job really holds its place in the queue), not when `fire()` was
    /// the safety net after `perform` returned without reserving.
    private(set) var didReserve = false

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    /// The job's `onReserved`: it holds its place in the queue.
    func fireReserved() {
        didReserve = true
        fire()
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

/// A reply of an editor-first call (the delete, the quick undo, the quick redo) that carries the pending changes the call consumed.
/// Every such call's batch is ALWAYS applied, whether the call succeeded or not (`consumeEditorFirstReply`).
protocol EditorFirstBatchReply: Decodable {
    var batch: BlockChanges { get }
}

/// The JavaScript reply of `deleteSectionEditorFirst` (web/milkdown/src/api-section-delete.ts). Only the fields Swift uses.
struct EditorFirstDeleteReply: EditorFirstBatchReply {
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
        guard let editorState, let unifiedUndoService, blockSyncService != nil,
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
        // A leader the sidebar shows through an overlay whose rows are still queued (the copy of the duplicate just made, a section
        // a quick undo just put back) is accepted too (round 1g-A, review A1; `editorFirstRootIsEligible`).
        let guardStartMs = StructTrace.nowMs()
        guard !TestMode.isUITestingStructuralLegacyDelete,
              editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              editorFirstRootIsEligible(rootId: rootId, database: db, projectId: pid) else { return nil }
        let guardMs = StructTrace.nowMs() - guardStartMs

        let opId = UUID()
        efOpEpoch[opId] = 1   // slice 2b: the per-op epoch starts at the click (plan-v2-addendum 2.2)
        guard let built = editorFirstScript(opId: opId, rootId: rootId, database: db, projectId: pid) else {
            efOpEpoch[opId] = nil
            return nil
        }
        let script = built.script
        let trace = StructTrace(label: "sectionDelete", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "sectionDelete", opId: trace.opId)
        trace.log("start (editor-first) guardMs=\(guardMs) managedIdsMs=\(built.managedIdsMs)")
        let epoch = unifiedUndoService.generation

        // D1.2 to D1.5: the shared click (StructuralUndoController+EditorFirstStructural.swift) pauses the routine polls, moves the
        // rebuild stamp (D6), reserves ticket N and submits the one call, applies the batch it returns, and calls back with the reply
        // while the poll pause is still up.
        let outcome = await runEditorFirstStructuralClick(
            kind: .sectionDelete, opId: opId, script: script, replyType: EditorFirstDeleteReply.self,
            database: db, projectId: pid, trace: trace
        ) { reply in
            // What the user sees changes NOW (before the job is even reserved, so no outline tick can bring the section back):
            // the removed leaders leave the sidebar and are filtered out of every outline result until the job applies (D1.6, Q10).
            let removedLeaders = Set(reply.removedLeaderIds ?? [])
            editorState.pendingRemovalIds.formUnion(removedLeaders)
            dropFromSidebarOverlays(removedLeaders)   // round 1g-A, review A1: an earlier job's overlay must not show them again
            var visibleSections = editorState.sections
            visibleSections.removeAll { removedLeaders.contains($0.id) }
            editorState.sections = visibleSections
            editorState.recalculateParentRelationships()

            // D1.5: reserve job N+1 and wait for its `onReserved` (M3) before the pause is lifted. The job takes over the raised
            // `pendingEditorFirstJobs` and brings it down when its future has resolved.
            await startEditorFirstJob(
                opId: opId, rootId: rootId, removedLeaders: removedLeaders, editorRemovedIds: reply.removedIds,
                database: db, projectId: pid, ownsPendingJobCount: true)
        }
        switch outcome {
        case .legacy, .declined:   // (`.declined` goes only to the slow undo, which hands `noCheckpoint` back: never here)
            efOpEpoch[opId] = nil   // round 2d-i, review B1: the old body runs under its own op id
            return nil
        case .refused:
            efOpEpoch[opId] = nil   // round 2d-i, review B1: the refused click never becomes an entry (the fresh settle holds its own copy)
            return .refused
        case .done: break
        }

        // D1.6: record the entry (the Edit menu says "Undo Delete Section" at once) and push the descriptor.
        guard unifiedUndoService.generation == epoch else {
            // A barrier invalidated the timeline while the click ran: recording now would put an entry on a timeline that is no
            // longer this section's. The delete happened (and is saved), but cannot be undone with Cmd-Z.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first delete: timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)   // round 2d-i, review B1: the entry's job record would otherwise stay for the session
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionDelete, title: "Delete Section", undoSnapshotId: nil))
        spy("efRecorded")
        await pushDescriptor()
        trace.log("performed")
        return .performed
    }

    /// The one JavaScript expression of the click: `deleteSectionEditorFirst(opId, rootBlockId, managedIds)`, with the managed ids
    /// (Notes and Bibliography rows) read from the database now. Nil when they cannot be read. `managedIdsMs` is how long that read took
    /// (a trace figure only).
    ///
    /// `function` (slice 2b): the editor call to make; the quick redo's `redoSectionDeleteEditorFirst` takes the same three arguments.
    func editorFirstScript(
        function: String = "deleteSectionEditorFirst", opId: UUID, rootId: String, database: ProjectDatabase, projectId: String,
        logName: String = "delete", extraArguments: [String] = []
    ) -> (script: String, managedIdsMs: Int)? {
        let managedIds: [String]
        let readStartMs = StructTrace.nowMs()
        do {
            managedIds = try database.fetchManagedBlockIds(projectId: projectId)
        } catch {
            DebugLog.log(.undo, "[StructuralUndoController] editor-first \(logName): reading the managed ids failed (\(error)) -- old path")
            return nil
        }
        let managedIdsMs = StructTrace.nowMs() - readStartMs
        guard let opLiteral = Self.jsLiteral(opId.uuidString), let rootLiteral = Self.jsLiteral(rootId),
              let managedLiteral = Self.jsLiteral(managedIds) else { return nil }
        // `extraArguments` (t-18b7fa48): further arguments, each already a JavaScript literal (the duplicate's quick redo passes the
        // first click's `copies`).
        let arguments = ([opLiteral, rootLiteral, managedLiteral] + extraArguments).joined(separator: ", ")
        let script = "JSON.stringify(window.FinalFinal.\(function)(\(arguments)))"
        return (script, managedIdsMs)
    }

    /// Plan D1.4: reads the editor's reply and settles ticket N. A returned batch is ALWAYS applied, whether the removal succeeded
    /// or not (the editor consumed it and nothing else will write it); an empty one settles the ticket `.empty`. A bridge call that
    /// threw, or a reply that cannot be read, may or may not have consumed the pending changes: the ticket settles
    /// `.discarded(.bridgeFailed)` and the loss is logged `alwaysPersisted`. Returns nil in those two cases.
    ///
    /// Slice 2b: generic over the reply type, so the quick undo's own reply (`QuickUndoReply`) takes exactly the same road.
    func consumeEditorFirstReply<Reply: EditorFirstBatchReply>(
        _ submission: BlockSyncService.EditorFirstSubmission, as replyType: Reply.Type, blockSync: BlockSyncService,
        database: ProjectDatabase, projectId: String, logName: String = "delete"
    ) -> Reply? {
        let ticket = submission.ticket
        let json: String?
        switch submission.result {
        case .failure(let error):
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] editor-first \(logName): the JavaScript call threw (\(error)). Ticket settled as "
                + "discarded(bridgeFailed); typing from the last two seconds may not be saved until the next edit.")
            return nil
        case .success(let value):
            json = value
        }
        guard let json, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            ticket.settleIfOpen(.discarded(.bridgeFailed))
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] editor-first \(logName): the editor's reply could not be read. Ticket settled as "
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
    ///
    /// Slice 2b: also the quick redo's way to queue its fresh delete job (`jobKey` set: a fresh registry key, because
    /// `EFJobRegistry.register` returns the record already there for a repeated id). Creates the entry's payload holder at the first
    /// click, hands it to the job, and captures the entry's epoch NOW (the settle belongs to the click or redo that started it, not to
    /// whatever the epoch is when the job ends).
    /// Returns whether the job really holds its place in the queue (`onReserved` fired).
    ///
    /// `ownsPendingJobCount` (t-18b7fa48 D6): the caller is an editor-first CLICK that raised `EditorViewState.pendingEditorFirstJobs`
    /// in its stretch (`runEditorFirstStructuralClick`); the job's task brings it down as soon as the job's future has resolved, BEFORE
    /// the settle or the put-back starts (their rebuild stamps must see the count already lowered). The quick redo raises the count in
    /// its own stretch too (round 1g-B, review A3) and passes true.
    @discardableResult
    func startEditorFirstJob( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, removedLeaders: Set<String>, editorRemovedIds: [String]?,
        database: ProjectDatabase, projectId: String, jobKey: UUID? = nil, ownsPendingJobCount: Bool = false
    ) async -> Bool {
        guard let editorState else { return false }
        efSlots.open(opId)
        let registry = editorState.efJobRegistry
        let registryKey = jobKey ?? opId
        registry.register(registryKey)
        let holder = efHolders[opId] ?? SectionDeletePayloadHolder(opId: opId, rootId: rootId, projectId: projectId)
        efHolders[opId] = holder
        holder.setClickLeaderIds(removedLeaders)
        holder.setFootnoteCheckpointMarker(Set((footnoteSyncService?.undoCheckpoints ?? []).map(\.id)))
        // The quick redo's caller has already listed the key in `efJobKeys` (round 2d-i, review B1: it used to be appended twice).
        if let jobKey { efLatestJobKey[opId] = jobKey }
        let epochAtClick = efOpEpoch[opId] ?? 0
        var heldJob = SectionDeleteJob(
            opId: opId, rootBlockId: rootId, projectId: projectId,
            fallbackBibliographyTitle: ExportSettingsManager.shared.effectiveBibliographyHeaderName, slots: efSlots)
        heldJob.bodyHold = jobBodyHold()
        heldJob.editorRemovedIds = editorRemovedIds
        heldJob.holder = holder
        heldJob.registryKey = jobKey
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let reserved = EFReservationSignal()
        let settleTask = Task { @MainActor [weak self, weak weakBlockSync = blockSyncService] in
            StructuralTrace.log("job task started")   // slice 0 measurement: when the task actually got its turn on the main actor
            // D6: the rebuild guard's pending-jobs count comes down once, when the job's future has resolved (or on the way out of
            // here, whichever comes first), and always BEFORE the settle or the put-back below starts.
            var pendingCountReleased = !ownsPendingJobCount
            @MainActor func releasePendingCount() {
                guard !pendingCountReleased else { return }
                pendingCountReleased = true
                self?.releasePendingEditorFirstJob()
            }
            // The job AND the work after it are over on every way out of here: whoever waits for the delete (the close/quit wait, the
            // zoom, the switch to Markdown, Save Version, export) is let go only now, not when the job's future resolved.
            defer {
                releasePendingCount()
                registry.markSettled(registryKey)
            }
            guard let blockSync = weakBlockSync else {
                reserved.fire()
                registry.resolve(registryKey, .abandoned)
                self?.notifyMarkdownJobEnded(key: registryKey, outcome: .abandoned)
                return
            }
            let result = await job.perform(
                on: blockSync, identity: identity, registry: registry,
                onReserved: {
                    StructuralTrace.log("onReserved fired")   // slice 0 measurement
                    reserved.fireReserved()
                })
            releasePendingCount()   // the job has ended: the settle's own rebuilds read the table after it and must stamp as current
            reserved.fire()   // `perform` returned without reserving (refused before step 4): never leave the click waiting
            self?.notifyMarkdownJobEnded(key: registryKey, outcome: JobOutcome(result.outcome))   // a Markdown job's hold continuation
            if case .applied(let output) = result.outcome, let mismatch = output.removedIdsMismatch {
                // The editor and the database disagree about which rows belong to the section (fix round 2a, item 10): the rules are
                // meant to be identical, so this means the screen and the saved copy are drifting apart. Log only: no behaviour change.
                DebugLog.alwaysPersisted(
                    "[StructuralUndoController] editor-first delete \(opId): the editor removed \(mismatch.editorOnly.count) row(s) "
                    + "the job did not delete (\(mismatch.editorOnly.prefix(5))), and the job deleted \(mismatch.jobOnly.count) row(s) "
                    + "the editor kept (\(mismatch.jobOnly.prefix(5)))")
            }
            await self?.editorFirstJobSettled(
                opId: opId, outcome: JobOutcome(result.outcome), removedLeaders: removedLeaders, epoch: epochAtClick, jobKey: jobKey)
        }
        efSettleTasks[opId] = settleTask
        await reserved.wait()
        return reserved.didReserve
    }

    /// The test/UI hold on the queued job's body (`FF_UI_TESTING_STRUCT_JOB_HOLD_MS`, or the DEBUG seam a unit test sets). With
    /// `FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N` only the first N jobs of the launch get the hold (`TestMode.consumeStructuralJobHold`).
    func jobBodyHold() -> (@Sendable () -> Void)? {
        #if DEBUG
        if let hold = testEFJobBodyHold { return hold }
        #endif
        let milliseconds = TestMode.uiTestingStructuralJobHoldMs
        guard milliseconds > 0, TestMode.consumeStructuralJobHold() else { return nil }
        return { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }
    }

    /// A JSON value as a JavaScript expression (JSON is a subset of JavaScript literals).
    static func jsLiteral<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - After the job

    /// The job's future has resolved with `outcome`. Applied: the rows are gone and the Version History copy exists, so the
    /// removed leaders stop being filtered and the derived content catches up (plan D2.4: each step on its own, no nesting).
    /// Anything else: D6, the put-back.
    ///
    /// Slice 2b: `epoch` is the entry's epoch as it stood when this job was started (nil: read it now); `jobKey` is the job's registry
    /// key (nil: the entry's first job). A settle whose epoch has moved (a quick undo or redo has taken the entry since) skips its
    /// resyncs and pushes (`resyncAfterEditorFirstDelete`) and leaves the sidebar's pending-removal filter to whoever owns it now.
    ///
    /// `kind` (t-18b7fa48 round 1e-i): which operation's job this was. It words the logs, picks the put-back alert, and for a
    /// duplicate lifts the sidebar overlay that showed the copy before its rows existed (`pendingRestoreSections`), once an
    /// outline read that follows the job's commit has put the copy's rows into the list.
    ///
    /// `pushesDatabaseBlockIds` (round 1g-C, review A2): the duplicate job applied and reported that the editor's copies and its rows
    /// differ; before the resyncs the settle puts the database's block ids onto the editor (`pushDatabaseBlockIdsAfterCopiesMismatch`).
    func editorFirstJobSettled(
        opId: UUID, outcome: JobOutcome, removedLeaders: Set<String>, epoch: Int? = nil, jobKey: UUID? = nil,
        kind: EditorFirstOpKind = .sectionDelete, pushesDatabaseBlockIds: Bool = false
    ) async {
        // Only the entry's latest job clears the slot (a quick redo's job has replaced the first one's).
        defer { if efLatestJobKey[opId] == jobKey { efSettleTasks[opId] = nil } }
        guard let editorState else { return }
        let epoch = epoch ?? (efOpEpoch[opId] ?? 0)
        spy("efJobSettled")
        // Markdown only (t-4a8fd8af round 6; a no-op for any other entry): nothing of the settle starts before step 8 has flushed the typing.
        await awaitMarkdownStep8(opId: opId, jobKey: jobKey, keepsGateForPutBack: !outcome.isApplied)
        // (Round 2d-i, review A15: the registry's `.abandoned` outcome never arrives here -- both callers pass `JobOutcome(result.outcome)`
        // of the system write, which is applied, failed or refused -- so there is no arm for it.)
        guard outcome.isApplied else {
            DebugLog.alwaysPersisted("[StructuralUndoController] editor-first \(kind.logName) \(opId): the job did not apply (\(outcome))")
            await putBackAfterFailedEditorFirstOp(kind: kind, opId: opId, removedLeaders: removedLeaders, jobKey: jobKey)
            return
        }
        await settleReorderOverlay(kind: kind, editorState: editorState, opId: opId)
        // Not when a quick redo has queued a newer job for the entry: it has put the leaders back into the filter and its own settle
        // takes them out. And, for a kind that shows an overlay, not when a quick undo or redo has taken the entry since the job was
        // started (the epoch moved): the sidebar then belongs to that operation (a restore's quick undo shows the PREVIOUS document's
        // leaders through this same overlay entry until its reinsert has applied, round 2d-i), the way `reinsertSettled` guards its
        // own clear (round 1g-A, review A4).
        //
        // Fix round F1 (review B1): an entry that has been DISCARDED meanwhile (typing after a slow Cmd-Z drops the redo branch, a sidebar
        // status edit drops the timeline: `forgetQuickUndoState` clears its latest-job key) has no newer job to leave the sidebar to,
        // so this settle is still the one that lifts. Without it the overlay and the hidden leaders stayed for the session and the
        // hierarchy enforcement waited for them for ever. The epoch condition stays: a discard does not move the epoch.
        func isLatestJob() -> Bool {
            let latest = efLatestJobKey[opId]
            return latest == jobKey || latest == nil
        }
        let epochUnmoved = (efOpEpoch[opId] ?? epoch) == epoch
        let sidebarIsOurs = isLatestJob() && (epochUnmoved || !kind.usesSidebarOverlay)
        if sidebarIsOurs { editorState.pendingRemovalIds.subtract(removedLeaders) }
        if kind.usesSidebarOverlay, sidebarIsOurs {
            await editorState.refreshSectionsAwaiting()
            if isLatestJob(), (efOpEpoch[opId] ?? epoch) == epoch { editorState.pendingRestoreSections[opId] = nil }
        }
        #if DEBUG
        await testEFSettleHold?()
        #endif
        if pushesDatabaseBlockIds, kind == .sectionDuplicate, efLatestJobKey[opId] == jobKey {
            await pushDatabaseBlockIdsAfterCopiesMismatch(editorState: editorState, opId: opId, epoch: epoch)
        }
        var restoreGeneration: Int?
        if kind.replacesDocumentText {
            // The document text changed (the whole document, a section's range, a section added, or a snapshot swapped in), so
            // `content` (the editor's own `contentChanged` pushes it a moment after the change) may
            // still be the pre-restore text; the resyncs below derive Notes, bibliography, sections and annotations from it, and
            // would derive the OLD document's (D14). The editor's own text is read first, and a quick undo or redo that starts
            // meanwhile takes over (it runs its own settle from a fresh read).
            let generation = editorState.editorRestoreGeneration
            if let blockSync = blockSyncService { await editorState.adoptLiveEditorText(blockSync: blockSync, why: "the restore settle") }
            guard editorState.editorRestoreGeneration == generation, (efOpEpoch[opId] ?? epoch) == epoch else {
                DebugLog.log(.undo, "[StructuralUndoController] restore settle \(opId): skipped (a quick undo or redo took the entry)")
                editorState.refreshSections()
                return
            }
            restoreGeneration = generation
        }
        await resyncAfterEditorFirstDelete(editorState: editorState, opId: opId, epoch: epoch, restoreGeneration: restoreGeneration)
    }

    /// The first step of `editorFirstJobSettled` that only a reorder takes (t-0b70d1e9); nothing for any other kind.
    ///
    /// The job has renumbered the rows, so an outline read that follows its commit shows the new order by itself and the reorder overlay
    /// (`pendingReorder`) is no longer needed. It is lifted for THIS operation's id only (a newer reorder, or a slow undo, that has taken
    /// the slot keeps its own), and UNCONDITIONALLY: whatever the entry's epoch, latest job or discard state, nobody else will lift it (the
    /// hierarchy check waits for it for ever). Called before the `replacesDocumentText` block of the settle, whose early return must not
    /// skip it. The read lands BEFORE the lift so no result computed meanwhile shows the old order; the refresh after it is the one the
    /// settle's resyncs expect.
    private func settleReorderOverlay(kind: EditorFirstOpKind, editorState: EditorViewState, opId: UUID) async {
        guard kind == .sectionReorder else { return }
        await editorState.refreshSectionsAwaiting()
        editorState.liftPendingReorder(opId: opId)
        editorState.refreshSections()
        // The footnote resync that follows in the settle must not be skipped as "already done". A move changes the ORDER of the
        // references in the text but not which labels there are: the renumber the resync would make ends in 1..N, the same list
        // the footnote service last committed, so `performFootnoteUpdate` returned at its `contentHash != lastRenumberedHash` guard
        // (FootnoteSyncService.swift, "perform returned early: lastRenumberedHash guard" in the app log) and neither the references
        // (10..18, 1..9, ...) nor the Notes were renumbered, for good. A delete or a duplicate changes the label list, so the hash
        // differs and they never met this. Only the footnote hash is forgotten: the move rewrites no Notes or Bibliography rows, and
        // the bibliography's own guard (the generated content) already differs when the citation order matters to the style.
        footnoteSyncService?.forgetCommittedNotesState()
    }

    /// Plan D2.4: bibliography and footnote resyncs, section sync, annotation sync and a sidebar refresh, queued one after the
    /// other so none nests inside another system write. Reads `editorState.content`, which the editor's own removal updates when
    /// its `contentChanged` message arrives, through the editor's 50 ms debounce. That is normally earlier than the job's whole
    /// transaction ends, but on a small document the job can finish first, and then these resyncs read the text from before the
    /// delete. The next change to the document runs them again on the right text, so the effect is a short delay in the footnote
    /// and bibliography update, nothing lost.
    ///
    /// Last step (`settleManagedRegionsAtEndOfEditorFirstSettle`, shared by every editor-first settle): while a close, quit or project
    /// switch holds the editor, the database's Notes and Bibliography go into the editor (`pushManagedRegionsWhileClosing`); otherwise
    /// they go in only when a rebuild's push was skipped for an editor-first reason and no editor-first job is pending any more
    /// (t-18b7fa48 round 1b-ii). The footnote resync renumbers the references in the editor (28-54 become 19-45) but cannot
    /// take the deleted chapter's definitions out of the editor's Notes, so the editor's Notes are half updated; the usual cure, the
    /// Notes rebuild that pushes the database's Notes into the editor, is held back while a lifecycle is armed. The lifecycle's
    /// whole-document save would then write the editor's half-updated Notes over the database's correct ones. The lifecycle waits for
    /// this whole settle (`EditorViewState.waitForSectionOperation` reads `efJobRegistry.hasUnsettledWork`), so the push has landed
    /// before the save captures the editor.
    ///
    /// Slice 2b (plan-v2-addendum 4.1, plan-v3 D1): runs under the entry's epoch `epoch`, captured when the job was started. Immediately
    /// before EACH step it reads `editorState.content` afresh and checks that the epoch has not moved; a step whose epoch has moved is
    /// skipped and logged (a quick undo or redo has taken the entry: the text is the restored document's and the reinsert's own settle
    /// re-derives everything). The two `resyncNow` calls also get the same check as their `stillWanted`. The sidebar refresh and the
    /// wait for running rebuilds always run.
    ///
    /// Code review G-F1/C-M1: the check also ends when ANY quick undo or redo (of another entry too) has bumped
    /// `editorState.editorRestoreGeneration` since `restoreGeneration` (the value the caller read before the text it works from; nil: now).
    /// Every such operation runs its own settle with a fresh live read and a full resync, so skipping here is safe.
    func resyncAfterEditorFirstDelete(editorState: EditorViewState, opId: UUID, epoch: Int, restoreGeneration: Int? = nil) async {
        let projectId = editorState.currentProjectId
        let restoreGen = restoreGeneration ?? editorState.editorRestoreGeneration
        let wanted: () -> Bool = { [weak self, weak editorState] in
            (self?.efOpEpoch[opId] ?? epoch) == epoch && editorState?.editorRestoreGeneration == restoreGen
        }
        func skipped(_ step: String) {
            DebugLog.log(.undo, "[StructuralUndoController] delete settle \(opId): \(step) skipped (a quick undo or redo took the entry)")
        }
        if let pid = projectId {
            if wanted() {
                let content = editorState.content
                await bibliographySyncService?.resyncNow(
                    citekeys: BibliographySyncService.extractCitekeys(from: content), projectId: pid, stillWanted: wanted)
            } else { skipped("bibliography resync") }
            if wanted() {
                let content = editorState.content
                markMarkdownSettle(opId: opId)   // Markdown only (B5/O10): the page's settle flag around the renumber this resync posts
                defer { unmarkMarkdownSettle(opId: opId) }
                await footnoteSyncService?.resyncNow(
                    footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: content), projectId: pid, fullContent: content,
                    stillWanted: wanted)
            } else { skipped("footnote resync") }
        }
        if wanted() {
            if DocumentManager.shared.projectId == editorState.currentProjectId {
                await sectionSyncService?.syncNow(editorState.content)
            }
        } else { skipped("section sync") }
        if wanted() { await annotationSyncService?.syncNow(editorState.content) } else { skipped("annotation sync") }
        editorState.refreshSections()
        // The resyncs above write the database's Notes and Bibliography and so start the background rebuilds that carry them into the
        // editor. The settle is over only when those have landed (fix round 5, part A1): the undo, the close and quit wait, and the
        // zoom, mode-switch, Save Version and export waits all wait for the settle, and a rebuild whose push lands after they have
        // started would put the post-delete document back over theirs. (A rebuild the lifecycle deferred has no Task to wait for.)
        await editorState.awaitNoRunningRebuilds(label: "delete follow-up", showsNotice: false)
        if wanted() {
            await settleManagedRegionsAtEndOfEditorFirstSettle(editorState: editorState, projectId: projectId)
        } else { skipped("managed-regions push") }
    }

    /// The footnote and bibliography resyncs above wrote the database's Notes and Bibliography. While a lifecycle is armed the
    /// handlers that normally carry them into the editor are deferred (`ContentView.handleNotesSectionChanged` and its bibliography
    /// twin return early while `activeLifecycle != nil`), so push them here with the same merge-guarded push the slow undo's settle
    /// uses (addendum A20): the regions and their ids come from the database, typing in user blocks survives. Nothing to do outside a
    /// lifecycle (the normal rebuild runs), in Markdown (the Markdown settle has its own tail, `settleMarkdownManagedRegions`, and a
    /// lifecycle there saves the page's live text itself), while zoomed, or when the project is
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
    ///
    /// Returns whether the push actually went through (the stamp was current and the editor answered); false for every early exit
    /// and for a push skipped as stale, which raises `managedRegionsNeedRepush` itself (t-18b7fa48 round 1b-ii).
    @discardableResult
    func pushManagedRegionsWhileClosing(editorState: EditorViewState, projectId: String?) async -> Bool {
        guard editorState.activeLifecycle != nil, editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              let pid = projectId, editorState.currentProjectId == pid else { return false }
        // A flush that did not complete (the editor did not answer within the poll's watchdog, or the writer did not settle) may have
        // left the editor's pending edits out of the database: reading it then would assign an OLDER document to `content` (which the
        // whole-document save falls back to when it cannot fetch) and push it. So nothing is assigned or pushed then; the lifecycle's
        // own forced poll (F) and the save fetch the editor's live text afterwards (fix round 8, F6).
        guard await blockSyncService?.pollBlockChangesNowForDatabaseRebuild() ?? true else {
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] closing push skipped: the forced poll did not complete (watchdog or unsettled writer)")
            return false
        }
        // The poll suspended: look again (a cancelled lifecycle hands the rebuild back to the handlers, a switch changes the project).
        guard editorState.activeLifecycle != nil, editorState.currentProjectId == pid, let db = editorState.projectDatabase else { return false }
        let stamp = editorState.stampRebuildRead()   // slice 2b: on the line before the database read, no `await` between
        guard let result = fetchFullBlocksWithIds(db: db, pid: pid) else { return false }
        let wasResettingContent = editorState.isResettingContent
        editorState.isResettingContent = true
        defer { editorState.isResettingContent = wasResettingContent }
        // As the rebuild handlers and the undo's settle do: `content` first (the view cannot push it meanwhile: the flag above);
        // `repushManagedRegionsFromDatabase` then replaces it with the merged text when that differs (or, when a quick undo or redo
        // started since the read, with the editor's own live text: the stamp).
        editorState.content = result.markdown
        return await repushManagedRegions(result, stamp: stamp).pushed
    }

    // The D6 put-back (the job did not apply) is `putBackAfterFailedEditorFirstOp(kind:)` in StructuralUndoController+EditorFirstStructural.swift.

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
        // Slice 2b: the entry's LATEST delete job (a quick redo's job has its own registry key; the first job's is the entry's id).
        let outcome = await editorState.efJobRegistry.awaitOutcome(efLatestJobKey[entry.id] ?? entry.id)
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
    ///
    /// Slice 2b (plan-v4-addendum 3.2, verdict-v4 V2): `stamp`, when given, is the stamp the caller took on the line before its database
    /// read (`stampRebuildRead`). The push is skipped when a quick undo or redo has started since (`stillWanted`), and then the
    /// editor's own live text goes into `content` instead (never the database's text over a restore). Returns the text the push left
    /// as the editor's (the merged text, or the live text after a skipped push), nil when neither could be had; the caller that
    /// assigned no database text beforehand adopts it into `content` itself.
    @discardableResult
    func repushManagedRegionsFromDatabase(_ result: ContentView.BlockFetchResult, stamp: RebuildReadStamp? = nil) async -> String? {
        await repushManagedRegions(result, stamp: stamp).text
    }

    /// `repushManagedRegionsFromDatabase` with one more answer: `pushed` is true when the push really reached the editor (the stamp
    /// was current and the editor handed back the merged text). A push skipped as stale answers false and, when an editor-first click
    /// is among the reasons, has raised `managedRegionsNeedRepush` (`noteStalePushSkipped`, t-18b7fa48 round 1b-ii); the settle tails
    /// clear the flag only on `pushed`.
    func repushManagedRegions(
        _ result: ContentView.BlockFetchResult, stamp: RebuildReadStamp? = nil
    ) async -> (text: String?, pushed: Bool) {
        guard let blockSyncService else { return (nil, false) }
        let merged = await blockSyncService.setContentWithBlockIds(
            markdown: result.markdown, blockIds: result.blockIds,
            imageMeta: result.imageMeta,
            cursorBoundary: result.bibBoundaryIndex, cursorBoundaryEnd: result.bibBoundaryEndIndex,
            expectedBlocks: result.expectedBlocks,
            managedBlockIds: result.managedBlockIds,
            preserveUserBlocks: true,
            stillWanted: stamp.map { stamp in { [weak editorState] in editorState?.rebuildPushStillWanted(stamp) ?? false } })
        spy("efRepushManagedRegions")
        if let stamp, let editorState, !editorState.rebuildPushStillWanted(stamp) {
            editorState.noteStalePushSkipped(stamp, kind: "managed-regions")
            let live = await editorState.adoptLiveEditorText(
                blockSync: blockSyncService, why: "a stale managed-regions push", requireUnchangedGeneration: false)
            return (live, false)
        }
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
        return (merged, merged != nil)
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
