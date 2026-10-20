//
//  SectionReorderJob.swift
//  final final
//
//  t-0b70d1e9 (plan-v2 decision 4): the queued background half of an editor-first drag-reorder in the Outline sidebar, in Rich Text. By
//  the time this job gets its turn in the writer's queue the editor has already moved the section(s) and shown them, and its pending
//  batch (typing up to the click) has been applied; the job makes the database agree, and leaves behind what undo needs. It is
//  `SectionDuplicateJob`'s twin.
//
//  ONE TRANSACTION, on the `Database` handle of a system write (`SystemWriteKind.sectionReorder`):
//    (a) the Version History snapshot of the whole document as it stands BEFORE the reorder, written in every case. It is the snapshot
//        the SLOW undo of this entry restores from (the entry has no snapshot id of its own, like an editor-first delete or duplicate);
//    (b) every row renumbered into the final order (`ProjectDatabase.reorderAllBlocks(db:leaderIds:projectId:levels:)`), the level of
//        each heading the plan changed set with its `#` prefix rebuilt from the LIVE row, section parents recomputed;
//    (c) on commit, and only when the entry's slot is still live: the snapshot id recorded on the slot and the snapshot pinned
//        (`SectionDeleteSlotStore.recordApplied`). The record is an after-commit hook, so a transaction that fails to commit leaves no
//        slot and no pin behind.
//
//  `leaderIds` is the editor's WORKING order: every section leader in final order, with the ids the editor held no node for already
//  taken out (the reply's `skippedIds`), Notes and Bibliography last. A block is a leader if and only if its id is in the list.
//
//  A system write: it stamps no rows and bumps no epoch (like `SectionDuplicateJob`, and unlike today's whole-document reorder, which
//  writes the table outside the queue and bumps `structuralOutOfQueueGeneration`). Reservation order alone orders it behind every
//  batch reserved earlier and ahead of every later one, so typing into a moved section after the click still finds its rows. It never
//  nests another system write: the resyncs that follow are queued separately by the wiring.
//
//  NO QUICK UNDO. A reorder deletes nothing and inserts nothing, so there is nothing for a reinsert to put back: its undo is the
//  ordinary slow undo (`queuedSnapshotUndo`) from the snapshot this job wrote. The payload holder is created, as the duplicate's is, for
//  `markFailed` and the footnote checkpoint marker, and is never filled with rows.
//

import Foundation
import GRDB

struct SectionReorderJob: Sendable {

    /// The structural entry's id: the key of the job's slot and of its `EFJobRegistry` record.
    let opId: UUID
    let projectId: String
    /// The bibliography heading name from settings, captured on the MainActor at the click (see `SectionDeleteJob`).
    let fallbackBibliographyTitle: String
    let slots: SectionDeleteSlotStore
    /// Every section leader in final order (ids may still be temp ids the writer has not confirmed: the body resolves them through the
    /// writer's admission-time id map).
    let leaderIds: [String]
    /// The headings whose level the plan changed, by id: id -> new level. Only a `heading` row is touched.
    let levels: [String: Int]
    /// Test seam, the same shape as `SectionDeleteJob.bodyHold` (runs first in the job's body and holds the writer's thread), except that
    /// it may THROW: a reorder deletes and inserts nothing, so unlike a duplicate (whose root can be removed while the job is held) it
    /// has no natural way to fail, and a test of the put-back needs one. A non-throwing hold (`jobBodyHold()`) converts as it is.
    var bodyHold: (@Sendable () throws -> Void)?
    /// Kept for `markFailed` and the footnote checkpoint marker only; a reorder never fills it with rows.
    var holder: SectionDeletePayloadHolder?
    /// The key this job's record has in the `EFJobRegistry`: nil means `opId`.
    var registryKey: UUID?

    struct Output: Sendable, Equatable {
        /// The Version History snapshot written before the reorder. Pinned only when the slot was live at commit.
        let snapshotId: String
    }

    // MARK: - The system-write body

    /// The transaction body: snapshot, reorder, after-commit slot record. `idMap` is the writer's temp-id map as of admission.
    func run(db: Database, idMap: IdMap) throws -> SystemWriteBody<Output> {
        try bodyHold?()
        // The snapshot first: it must hold the document the next statement reorders.
        let written = try SnapshotService.writeUndoPointSnapshot(
            db: db, projectId: projectId, fallbackBibliographyTitle: fallbackBibliographyTitle)

        let resolvedLeaderIds = leaderIds.map { idMap[$0] ?? $0 }
        let resolvedLevels = Dictionary(levels.map { (idMap[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        // A throw here rolls the whole transaction back, the snapshot included.
        try ProjectDatabase.reorderAllBlocks(
            db: db, leaderIds: resolvedLeaderIds, projectId: projectId, levels: resolvedLevels)

        // After-commit: the slot record and the pin happen only if the transaction really commits, and only if the slot still
        // exists then. No rows to remove, so the slot's `removedSections` stays empty.
        let snapshotId = written.snapshot.id
        let opId = self.opId
        let slots = self.slots
        db.afterNextTransaction(onCommit: { _ in
            _ = slots.recordApplied(opId, snapshotId: snapshotId, removedSections: [])
        })

        return SystemWriteBody(value: Output(snapshotId: snapshotId))
    }

    // MARK: - Running it through the queue

    /// Reserves the job's place in the writer's queue, waits for its turn, runs `run(db:idMap:)` and settles the job's record in
    /// `registry` with whatever came back. The record is registered (idempotently) before the reservation. `onReserved` runs
    /// synchronously once the job holds its place (`performSystemWrite`'s step 4), in the same MainActor turn. `stillWanted` is always
    /// true: a reorder the user already saw happen is never "not wanted" any more.
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
            identity: identity, kind: .sectionReorder, stillWanted: { true }, onReserved: onReserved,
            body: { db, idMap in try job.run(db: db, idMap: idMap) })
        if !JobOutcome(result.outcome).isApplied { holder?.markFailed() }
        registry.settle(key, with: result.outcome)
        return result
    }
}
