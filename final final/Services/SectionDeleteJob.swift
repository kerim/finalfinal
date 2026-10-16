//
//  SectionDeleteJob.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D2, addenda A8/A17/A18): the queued background half of an editor-first section delete
//  in Rich Text. By the time this job gets its turn in the writer's queue the editor has already removed the section from the
//  screen and its pending batch (typing up to the click) has been applied; the job makes the database agree, and leaves behind
//  what today's undo needs.
//
//  ONE TRANSACTION, on the `Database` handle of a system write (`SystemWriteKind.sectionDelete`):
//    (a) the Version History snapshot of the whole document as it stands BEFORE the delete, written in every case (A17);
//    (b) the section's rows deleted, section parents recomputed (the same body as `ProjectDatabase.deleteSections`);
//    (c) on commit, and only when the entry's slot is still live: the snapshot id and the delete's leader rows recorded on the
//        slot, and the snapshot pinned (`SectionDeleteSlotStore.recordApplied`). The record is an after-commit hook, so a
//        transaction that fails to commit leaves no slot and no pin behind (plan section 7, P7);
//    (d) `deletedAnchors` for the removed rows, so a late editor insert anchored inside the section still re-anchors.
//
//  A system write: it stamps no rows and bumps no epoch (obligation 16). Reservation order alone orders it behind every
//  batch reserved earlier and ahead of every later one (plan D1.3, D2.3). It never nests another system write: the
//  bibliography/footnote resyncs, section sync and the sidebar refresh that follow a delete are queued separately by the
//  wiring (D2.4).
//
//  `perform(on:identity:registry:onReserved:)` runs the job through `BlockSyncService.performSystemWrite` and settles the
//  job's `EFJobRegistry` record on whatever outcome comes back, so a waiter (D7, A1) never waits on a job that already
//  ended.
//

import Foundation
import GRDB

struct SectionDeleteJob: Sendable {

    /// The structural entry's id: the key of the job's slot and of its `EFJobRecord`.
    let opId: UUID
    /// The id of the section's root leader row, as the editor reported it. May still be a temp id (a heading typed a moment
    /// before the click whose insert batch has applied but whose confirmation the editor has not yet processed); the body
    /// resolves it through the writer's admission-time id map.
    let rootBlockId: String
    let projectId: String
    /// The bibliography heading name from settings, captured on the MainActor at the click (`parseHeaders` needs it when no
    /// bibliography heading exists in the rows; ExportSettingsManager is MainActor-only and the body is not).
    let fallbackBibliographyTitle: String
    let slots: SectionDeleteSlotStore
    /// Test seam (t-94369a83 Phase 4b slice 2a, plan A2/A20 tests and the UI-test flag `FF_UI_TESTING_STRUCT_JOB_HOLD_MS`): runs
    /// first in the job's body, when the job already has its place in the writer's queue and its turn has come, and holds the
    /// job there until it returns. Nil in production; the wiring sets it only under `TestMode.isUITesting` or a DEBUG test hook.
    /// It blocks the writer's thread for as long as it runs, which is the point: everything reserved after the job waits behind it.
    var bodyHold: (@Sendable () -> Void)?
    /// The ids the editor says its removal took out (`removedIds` in the editor's reply), if it said. The body maps them through the
    /// writer's id map and compares them with the rows it deleted; a difference is reported in `Output.removedIdsMismatch` and
    /// changes nothing else (fix round 2a, item 10). Nil: the editor sent none, no comparison.
    var editorRemovedIds: [String]?
    /// Slice 2b (quick undo): where the rows the body saw just before it deleted are kept for a reinsert (plan-v2-addendum 2.1).
    /// Filled by the after-commit hook BEFORE the slot is written, whether or not the slot still exists. Nil in a job that no quick
    /// undo can reach (every pre-slice-2b caller).
    var holder: SectionDeletePayloadHolder?
    /// The key this job's record has in the `EFJobRegistry`: nil means `opId` (the entry's first job); a redo's job registers under a
    /// fresh id, because `EFJobRegistry.register` hands back the record already there for a repeated id (verdict-v1 S6).
    var registryKey: UUID?

    /// How the editor's removed ids and the rows the job deleted differ (both mapped to database ids).
    struct RemovedIdsMismatch: Sendable, Equatable {
        /// Removed by the editor, but not deleted by the job.
        let editorOnly: [String]
        /// Deleted by the job, but still on screen in the editor.
        let jobOnly: [String]
    }

    struct Output: Sendable, Equatable {
        /// The Version History snapshot written before the delete. Pinned only when the slot was live at commit.
        let snapshotId: String
        /// Every row the job deleted, in document order (the section's leaders, their body rows and their descendants).
        let deletedBlockIds: [String]
        /// Set when the editor reported its removed ids and they differ from `deletedBlockIds`. The caller logs it; nothing else
        /// changes (the two rules are meant to agree, so a difference means the screen and the database are drifting apart).
        var removedIdsMismatch: RemovedIdsMismatch?
    }

    enum JobError: Error, Equatable {
        /// The root is not a deletable leader in the database (no such row, a Notes/Bibliography row, or part of the subtree
        /// is missing): nothing was deleted, nothing was written, the transaction rolled back.
        case rootNotDeletable(String)
    }

    // MARK: - The system-write body

    /// The transaction body: snapshot, delete, anchors, after-commit slot record. `idMap` is the writer's temp-id map as of
    /// admission (`DocumentWriter.applySystemWrite`'s `(Database, IdMap)` overload).
    func run(db: Database, idMap: IdMap) throws -> SystemWriteBody<Output> {
        bodyHold?()
        // The snapshot first: it must hold the section that the next statement deletes.
        let written = try SnapshotService.writeUndoPointSnapshot(
            db: db, projectId: projectId, fallbackBibliographyTitle: fallbackBibliographyTitle)

        let rootId = idMap[rootBlockId] ?? rootBlockId
        guard let subtree = try ProjectDatabase.deleteSections(db: db, rootId: rootId, projectId: projectId) else {
            // Rolls the whole transaction back, the snapshot included.
            throw JobError.rootNotDeletable(rootId)
        }

        // For each removed row, what it hung after, taken from the rows the snapshot holds (all of them still present at
        // this point in the snapshot's own read): the first removed row hangs after the surviving row before the section,
        // each later one after its predecessor, which is itself removed and itself tombstoned, so a late insert anchored on
        // any of them resolves through the chain exactly as it does for the editor's own batch deletes.
        let removed = Set(subtree.blockIds)
        var anchors: [String: DeletedAnchor] = [:]
        var deletedInOrder: [String] = []
        var removedLeaders: [Block] = []
        var previousId: String?
        for block in written.blocks {
            if removed.contains(block.id) {
                anchors[block.id] = previousId.map { DeletedAnchor.after($0) } ?? DeletedAnchor.documentStart
                deletedInOrder.append(block.id)
                if block.blockType == .heading || block.isPseudoSection { removedLeaders.append(block) }
            }
            previousId = block.id
        }

        // After-commit (plan section 7, P7): the slot record and the pin happen only if the transaction really commits, and
        // only if the slot still exists then (A17). Runs on the writer's queue, before `write` returns, so the job's outcome
        // is never reported before the slot holds the snapshot id.
        let snapshotId = written.snapshot.id
        let opId = self.opId
        let slots = self.slots
        let leaders = removedLeaders
        let holder = self.holder
        let preDeleteRows = written.blocks
        db.afterNextTransaction(onCommit: { _ in
            // Slice 2b: the holder first (a reinsert reads it, and the slot may already be gone), then the slot.
            holder?.fill(rows: preDeleteRows, leaders: leaders, resolvedRootId: rootId)
            _ = slots.recordApplied(opId, snapshotId: snapshotId, removedSections: leaders)
        })

        var mismatch: RemovedIdsMismatch?
        if let editorRemovedIds {
            let editorSet = Set(editorRemovedIds.map { idMap[$0] ?? $0 })
            let jobSet = Set(deletedInOrder)
            if editorSet != jobSet {
                mismatch = RemovedIdsMismatch(
                    editorOnly: editorSet.subtracting(jobSet).sorted(), jobOnly: jobSet.subtracting(editorSet).sorted())
            }
        }

        return SystemWriteBody(
            value: Output(snapshotId: snapshotId, deletedBlockIds: deletedInOrder, removedIdsMismatch: mismatch),
            deletedAnchors: anchors)
    }

    // MARK: - Running it through the queue

    /// Reserves the job's place in the writer's queue, waits for its turn, runs `run(db:idMap:)` and settles the job's record
    /// in `registry` with whatever came back (applied, failed, or any refusal). The record is registered (idempotently)
    /// before the reservation, so a waiter that looks the id up from the moment the job reserved always finds a record.
    ///
    /// `onReserved` runs synchronously once the job holds its place (`performSystemWrite`'s step 4), in the same MainActor
    /// turn: the click path uses it to know the job is ordered before it releases the structural gate. `stillWanted` is always
    /// true: a delete the user already saw happen is never "not wanted" any more.
    @MainActor
    func perform(
        on blockSync: BlockSyncService,
        identity: SystemWriteIdentity,
        registry: EFJobRegistry,
        onReserved: (() -> Void)? = nil
    ) async -> SystemWriteResult<Output> {
        let key = registryKey ?? opId
        registry.register(key)
        // Safety net for a path that leaves this function without settling (nothing does today): the record must resolve.
        defer { registry.resolve(key, .abandoned) }
        let job = self
        let result = await blockSync.performSystemWrite(
            identity: identity, kind: .sectionDelete, stillWanted: { true }, onReserved: onReserved,
            body: { db, idMap in try job.run(db: db, idMap: idMap) })
        if !JobOutcome(result.outcome).isApplied { holder?.markFailed() }
        registry.settle(key, with: result.outcome)
        return result
    }
}
