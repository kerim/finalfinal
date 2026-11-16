//
//  StructuralUndoController+EditorFirstReorder.swift
//  final final
//
//  t-0b70d1e9 (plan-v2 decisions 1 to 4): the Outline sidebar's drag-reorder in Rich Text without the whole-document rewrite and
//  without losing what the user types around it. The EDITOR moves the section(s) first (one JavaScript call, a range move,
//  `reorderSectionsEditorFirst`, web/milkdown/src/api-section-reorder.ts); the database follows as a queued system-write job
//  (`SectionReorderJob`), behind everything the user typed. Nothing is pushed back over the user's text. It is the duplicate's twin
//  (StructuralUndoController+EditorFirstDuplicate.swift) and stands on the same shared click (`runEditorFirstStructuralClick`).
//
//    1. `performEditorFirstReorder(plan:changedLevels:rootId:)`: the click. Returns nil when this press must take today's whole
//       sequence instead (zoomed, no writer turn, the UI-test legacy flag, an editor that refuses: `planMismatch`, `managedMoved`,
//       `rootNotFound`, no document yet). In Markdown mode it hands the press to `performMarkdownEditorFirstReorder`
//       (StructuralUndoController+MarkdownEditorFirstReorder.swift, t-4a8fd8af slice 2), which uses `showReorderInSidebar` and
//       `startEditorFirstReorderJob` below as they are.
//    2. `showReorderInSidebar(...)`: what the sidebar shows at once, before the rows move: the planned list, and the order overlay
//       (`EditorViewState.pendingReorder`) every outline result is put into until the job's settle lifts it.
//    3. `startEditorFirstReorderJob(...)`: reserves the job and keeps the task that runs it and the work after it.
//
//  THE PLAN IS WORKED OUT BY THE CALLER, inside the structural gate, from the live sidebar list (`performSectionReorder`, in
//  StructuralUndoController.swift): re-planned, hierarchy-enforced, Notes and Bibliography clamped last, sort orders renumbered. This
//  file receives the finished plan and the headings whose level it changed.
//
//  NO QUICK UNDO, NO RECORDED SNAPSHOT ID. The entry is recorded with `undoSnapshotId: nil`; the job writes the Version History
//  snapshot (the document before the move) onto the entry's slot, and the undo and redo are the ordinary queued slow ones
//  (`queuedSnapshotUndo`). `quickPathPossible` refuses the kind. The editor-first path never touches `structuralOutOfQueueGeneration`
//  (the old body does, StructuralUndoController.swift step 5), so an earlier editor-first delete stays quick-undoable after a drag.
//
//  THE RESERVATION WINDOW is the duplicate's (see its header): the reply is read and the job reserved without waiting for anything
//  that can sit behind queued work. Typing into a moved section in the gap applies as an update to rows that exist (a reorder adds
//  and removes no rows), so unlike the duplicate there is no unknown-id case here.
//

import SwiftUI
import GRDB

// MARK: - The reply

/// The JavaScript reply of `reorderSectionsEditorFirst` (web/milkdown/src/api-section-reorder.ts). Only the fields Swift uses. On a
/// refusal `skippedIds` is empty.
struct EditorFirstReorderReply: EditorFirstOpReply {
    /// Present on EVERY path (even a failed one) and ALWAYS applied: the pending changes the call consumed.
    let batch: BlockChanges
    let succeeded: Bool
    let reason: String?
    /// Ids in the order Swift sent for which the editor holds no top-level node. They are not placed; Swift takes them out of the order
    /// it hands to its job. Their cards stay in the sidebar, placed by the overlay rule as unlisted leaders (right after the nearest
    /// listed leader before them in the current list, else first).
    let skippedIds: [String]
    /// How many top-level nodes changed place (0 when only levels changed).
    let moved: Int
    /// How many headings had their level set.
    let levelChanges: Int

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case skippedIds
        case moved
        case levelChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batch = try container.decode(BlockChanges.self, forKey: .batch)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        skippedIds = try container.decodeIfPresent([String].self, forKey: .skippedIds) ?? []
        moved = try container.decodeIfPresent(Int.self, forKey: .moved) ?? 0
        levelChanges = try container.decodeIfPresent(Int.self, forKey: .levelChanges) ?? 0
    }
}

/// One entry of the `order` argument: a section leader's id, and its new heading level when (and only when) the plan changed it.
struct ReorderOrderEntry: Encodable, Equatable {
    let id: String
    let level: Int?
}

// MARK: - The click

extension StructuralUndoController {

    /// Drag-reorder, editor first (plan-v2 decisions 1 and 2). Called under the structural gate with the FINISHED plan. Returns nil,
    /// having changed nothing, when this press has to take today's whole sequence; otherwise the outcome the sidebar reports.
    ///
    /// `plan` is every section leader in final order (Notes and Bibliography included, last). `changedLevels` is the id -> new level of
    /// the headings whose level the plan changed (never a section break, Notes or Bibliography). `rootId` is the section the user
    /// dragged (the editor finds the moved run from it).
    func performEditorFirstReorder(plan: [SectionViewModel], changedLevels: [String: Int], rootId: String) async -> StructuralOpOutcome? {
        guard let editorState, let unifiedUndoService, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return nil }
        #if DEBUG
        if testForceLegacyStructural { return nil }
        #endif
        // Not zoomed (a zoomed reorder keeps the whole-document body: t-b371d77a). A rootId the editor has no node for is answered by
        // the editor itself (`rootNotFound`), and falls back below.
        let guardStartMs = StructTrace.nowMs()
        guard !TestMode.isUITestingLegacyStructural, editorState.zoomedSectionId == nil else { return nil }
        // Markdown mode (t-4a8fd8af slice 2): the same drop, carried out by the CodeMirror page (a text move) instead of the Milkdown
        // editor; its own file. A nil from there (the switch is off, the page declined) continues in this gate turn with the old body.
        if editorState.editorMode == .source {
            return await performMarkdownEditorFirstReorder(plan: plan, changedLevels: changedLevels, rootId: rootId)
        }
        let guardMs = StructTrace.nowMs() - guardStartMs

        // Every id that goes in is an outline row the editor can carry: a heading, a section break, Notes or the Bibliography heading
        // (block-id-plugin.ts BLOCK_TYPES gives `heading` and `section_break` ids). One the editor lacks comes back as `skippedIds`.
        let entries = plan.map { ReorderOrderEntry(id: $0.id, level: changedLevels[$0.id]) }
        guard let orderLiteral = Self.jsLiteral(entries) else { return nil }

        let opId = UUID()
        efOpEpoch[opId] = 1   // the per-op epoch starts at the click, as the delete's and the duplicate's
        guard let built = editorFirstScript(
            function: "reorderSectionsEditorFirst", opId: opId, rootId: rootId, database: db, projectId: pid, logName: "reorder",
            extraArguments: [orderLiteral]
        ) else {
            efOpEpoch[opId] = nil
            return nil
        }
        let trace = StructTrace(label: "sectionReorder", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "sectionReorder", opId: trace.opId)
        trace.log("start (editor-first) guardMs=\(guardMs) managedIdsMs=\(built.managedIdsMs)")
        let epoch = unifiedUndoService.generation

        let outcome = await runEditorFirstStructuralClick(
            kind: .sectionReorder, opId: opId, script: built.script, replyType: EditorFirstReorderReply.self,
            database: db, projectId: pid, trace: trace
        ) { reply in
            // What the user sees changes NOW, in the reply's own main-actor turn (synchronous: no report is taken in inside it).
            let working = showReorderInSidebar(opId: opId, plan: plan, changedLevels: changedLevels, skippedIds: Set(reply.skippedIds))
            // Reserve the job and wait for its `onReserved` before the reports are let through again. The job takes over the raised
            // `pendingEditorFirstJobs` and brings it down when its future has resolved.
            await startEditorFirstReorderJob(
                opId: opId, rootId: rootId, leaderIds: working.leaderIds, levels: working.levels, database: db, projectId: pid,
                ownsPendingJobCount: true)
        }
        switch outcome {
        case .legacy, .declined:   // (`.declined` goes only to the slow undo, which hands `noCheckpoint` back: never here)
            // The old whole-document sequence runs next, in this same gate turn, and starts its own `sectionReorder` op in the trace:
            // this line marks this op (the editor-first attempt) as over, so a reader sees which of the two op starts carried the press.
            trace.log("fell back to the old sequence (the editor did not take the press)")
            efOpEpoch[opId] = nil
            return nil
        case .refused:
            trace.log("refused (the editor-first call failed or answered nothing readable)")
            efOpEpoch[opId] = nil   // the refused click never becomes an entry (the fresh settle holds its own copy)
            return .refused
        case .done:
            break
        }

        guard unifiedUndoService.generation == epoch else {
            // A barrier invalidated the timeline while the click ran: recording now would put an entry on a timeline that is no
            // longer this section's. The reorder happened (and is saved), but cannot be undone with Cmd-Z.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first reorder: timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        // Read by the slow undo's snapshot lookup (`resolveEditorFirstUndoSnapshot`: the slot is marked `fallback` only when something
        // else wrote the block table since), as for the other editor-first kinds. `efRecordedStructGeneration` is NOT recorded: its
        // only reader is the quick undo's `quickPathPossible`, which refuses this kind before it looks.
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionReorder, title: "Reorder Sections", undoSnapshotId: nil))
        spy("efRecorded")
        await pushDescriptor()
        trace.log("performed")
        return .performed
    }

    // MARK: - The sidebar

    /// Shows the new order in the sidebar before the database holds it: the order overlay (`pendingReorder`) is set, and the sidebar's
    /// CURRENT list (`editorState.sections` as it is now, not the plan made before the click's JavaScript ran) is put into the same
    /// order by the same rule (`SidebarReorderOverlay`), so a card or an update that arrived during the click's JavaScript window is
    /// kept. The overlay puts every outline result that arrives before the job commits into that order too; the job's settle lifts it
    /// (`editorFirstJobSettled`).
    ///
    /// Returns the order and the levels the JOB gets: the plan's ids with `skippedIds` (the ones the editor holds no node for) taken
    /// out, so the job's `leaderIds` equal the editor's working order. The card of a skipped id is NOT taken out of the sidebar: it is an
    /// unlisted leader to the overlay, which places it right after the nearest listed leader before it in the current list (first when
    /// none comes before it), so a skipped id never costs a sidebar card.
    ///
    /// The overlay's `levels` also carry over the pending levels of an earlier reorder that this one replaces in the single slot (this
    /// reorder's own levels win): that reorder's job may not have written its levels yet, and the outline results in between must keep
    /// showing them. The JOB's levels are only this reorder's own (G3).
    func showReorderInSidebar(
        opId: UUID, plan: [SectionViewModel], changedLevels: [String: Int], skippedIds: Set<String>
    ) -> (leaderIds: [String], levels: [String: Int]) {
        let leaderIds = plan.map(\.id).filter { !skippedIds.contains($0) }
        let levels = changedLevels.filter { !skippedIds.contains($0.key) }
        guard let editorState else { return (leaderIds, levels) }
        let overlayLevels = (editorState.pendingReorder?.levels ?? [:]).merging(levels) { _, new in new }
        let pending = PendingReorder(opId: opId, order: leaderIds, levels: overlayLevels)
        editorState.pendingReorder = pending
        editorState.sections = SidebarReorderOverlay.apply(pending, to: editorState.sections)
        editorState.recalculateParentRelationships()
        return (leaderIds, levels)
    }

    // MARK: - The job

    /// Opens the entry's slot, registers its job future, and spawns the job (`SectionReorderJob.perform`, a `.sectionReorder` system
    /// write). Returns once the job holds its place in the writer's queue (its `onReserved` fired, or it came back without reserving),
    /// never when it applies. The task that runs the job and the work after it is kept in `efSettleTasks`.
    ///
    /// `ownsPendingJobCount` (D6): the caller is an editor-first CLICK that raised `EditorViewState.pendingEditorFirstJobs`; the job's
    /// task brings it down as soon as the job's future has resolved, BEFORE the settle or the put-back starts (their rebuild stamps
    /// must see the count already lowered).
    @discardableResult
    func startEditorFirstReorderJob( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, leaderIds: [String], levels: [String: Int], database: ProjectDatabase, projectId: String,
        ownsPendingJobCount: Bool = false
    ) async -> Bool {
        guard let editorState else { return false }
        let setupSpan = MdSpeed.span("jobStart.setup")   // round M2: the synchronous setup on the main thread, up to the Task's creation
        efSlots.open(opId)
        let registry = editorState.efJobRegistry
        registry.register(opId)
        // Kept for `markFailed` and the footnote checkpoint marker only: a reorder deletes and inserts nothing, so no payload is filled.
        let holder = efHolders[opId] ?? SectionDeletePayloadHolder(opId: opId, rootId: rootId, projectId: projectId)
        efHolders[opId] = holder
        holder.setFootnoteCheckpointMarker(Set((footnoteSyncService?.undoCheckpoints ?? []).map(\.id)))
        let epochAtClick = efOpEpoch[opId] ?? 0
        var heldJob = SectionReorderJob(
            opId: opId, projectId: projectId,
            fallbackBibliographyTitle: ExportSettingsManager.shared.effectiveBibliographyHeaderName, slots: efSlots,
            leaderIds: leaderIds, levels: levels)
        heldJob.bodyHold = reorderJobBodyHold()
        heldJob.holder = holder
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let reserved = EFReservationSignal()
        let settleTask = Task { @MainActor [weak self, weak weakBlockSync = blockSyncService] in
            StructuralTrace.log("job task started")
            // D6: the pending-jobs count comes down once, when the job's future has resolved (or on the way out of here, whichever
            // comes first), and always BEFORE the settle or the put-back below starts.
            var pendingCountReleased = !ownsPendingJobCount
            @MainActor func releasePendingCount() {
                guard !pendingCountReleased else { return }
                pendingCountReleased = true
                self?.releasePendingEditorFirstJob()
            }
            // The job AND the work after it are over on every way out of here: whoever waits for the reorder (the close/quit wait,
            // the zoom, the switch to Markdown, Save Version, export) is let go only now, not when the job's future resolved.
            defer {
                releasePendingCount()
                registry.markSettled(opId)
            }
            guard let blockSync = weakBlockSync else {
                reserved.fire()
                registry.resolve(opId, .abandoned)
                self?.notifyMarkdownJobEnded(key: opId, outcome: .abandoned)   // a Markdown reorder's hold continuation (no-op in Rich Text)
                return
            }
            let performSpan = MdSpeed.span("job.perform")   // round M2: the job's whole run (steps 1 to 8 of the system write)
            let result = await job.perform(
                on: blockSync, identity: identity, registry: registry,
                onReserved: {
                    StructuralTrace.log("onReserved fired")
                    reserved.fireReserved()
                })
            performSpan.end()
            releasePendingCount()   // the job has ended: the settle's own rebuilds read the table after it and must stamp as current
            reserved.fire()   // `perform` returned without reserving (refused before step 4): never leave the click waiting
            // A Markdown reorder's hold continuation waits on this (a no-op for a job without a step-8 gate, i.e. every Rich Text job).
            // WITHOUT it the Markdown writer's hold would stay up for good (t-4a8fd8af slice 2).
            let notifySpan = MdSpeed.span("job.notifyEnded")   // synchronous: resolves the step-8 gate, whose waiter then needs the main thread
            self?.notifyMarkdownJobEnded(key: opId, outcome: JobOutcome(result.outcome))
            notifySpan.end()
            await self?.editorFirstJobSettled(
                opId: opId, outcome: JobOutcome(result.outcome), removedLeaders: [], epoch: epochAtClick, jobKey: nil,
                kind: .sectionReorder)
        }
        efSettleTasks[opId] = settleTask
        setupSpan.end()
        let reservedWaitSpan = MdSpeed.span("jobStart.reservedWait")   // await: the main thread is free; the job's Task runs meanwhile
        await reserved.wait()
        reservedWaitSpan.end()
        return reserved.didReserve
    }

    /// The hold on the reorder job's body: the DEBUG seam that may THROW (`testEFReorderJobBodyHold`, a unit test's way to fail a job
    /// that has no natural failure), else the shared one (`testEFJobBodyHold`, `FF_UI_TESTING_STRUCT_JOB_HOLD_MS`).
    func reorderJobBodyHold() -> (@Sendable () throws -> Void)? {
        #if DEBUG
        if let hold = testEFReorderJobBodyHold { return hold }
        #endif
        guard let hold = jobBodyHold() else { return nil }
        return { hold() }
    }
}
