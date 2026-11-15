//
//  SectionDuplicateJob.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 3 (round 1e-i; plan-v3 D4, D5, D16): the queued background half of an editor-first Duplicate Section in
//  Rich Text. By the time this job gets its turn in the writer's queue the editor has already inserted the copy and shown it, and its
//  pending batch (typing up to the click) has been applied; the job makes the database agree, and leaves behind what undo needs.
//  It is `SectionDeleteJob`'s twin.
//
//  ONE TRANSACTION, on the `Database` handle of a system write (`SystemWriteKind.sectionDuplicate`):
//    (a) the Version History snapshot of the whole document as it stands BEFORE the duplicate, written in every case. It is the
//        snapshot the SLOW undo of this entry restores from (the entry has no snapshot id of its own, like an editor-first delete);
//    (b) the section's rows copied (`ProjectDatabase.duplicateSections(db:rootId:projectId:copies:)`), section parents recomputed.
//        When the room after the section is used up, every saved position is re-spaced first, in this same transaction, and logged in
//        `renumberLog` on commit (t-bf66e4ee);
//        The copies carry the ids the EDITOR minted for its top-level nodes (D4), matched through the writer's temp-id map; the rows
//        the editor has no node for (a list's items) get fresh UUIDs minted here. A difference between the editor's copies and the
//        rows is returned in `Output.copiesMismatch` for the caller to log (`duplicateCopiesMismatch`), never thrown. The caller's
//        settle then pushes the database's block ids to the editor so both sides agree (round 1g-C, review A2:
//        `pushDatabaseBlockIdsAfterCopiesMismatch`);
//    (c) on commit, and only when the entry's slot is still live: the snapshot id recorded on the slot and the snapshot pinned
//        (`SectionDeleteSlotStore.recordApplied`), and the payload holder filled with "the rows before the op" (every row of the
//        project as the snapshot read them) and the ids of the rows inserted. The record is an after-commit hook, so a transaction
//        that fails to commit leaves no slot and no pin behind.
//
//  A system write: it stamps no rows and bumps no epoch (D5; like `SectionDeleteJob` and `SectionReorderJob`, and unlike the old
//  whole-document duplicate (zoomed, the fallbacks, and Markdown mode when the kill switch is off or the page refused), which writes
//  the table outside the queue and bumps
//  `structuralOutOfQueueGeneration`). Reservation order alone orders it behind every batch
//  reserved earlier and ahead of every later one. It never nests another system write: the resyncs that follow are queued
//  separately by the wiring.
//
//  The QUICK UNDO of a duplicate is the ordinary `SectionReinsertJob` (the holder's rows before the op are the payload: it makes the
//  table equal to them, which removes the copy). Its redo is a FRESH `SectionDuplicateJob` under a fresh registry key, with the
//  copies of the redo's own reply (their new ids are the first click's: S9).
//

import Foundation
import GRDB

/// One top-level block the editor copied (`duplicateSectionEditorFirst`, web/milkdown/src/api-section-duplicate.ts): the id the
/// SOURCE block had in the editor at the click (a temp id when Swift had not confirmed it yet; "" only when the editor held none),
/// and the permanent id the copy got.
struct DuplicatedBlock: Codable, Sendable, Equatable {
    let sourceId: String
    let newId: String
}

struct SectionDuplicateJob: Sendable {

    /// The structural entry's id: the key of the job's slot and (for the first job) of its `EFJobRecord`.
    let opId: UUID
    /// The id of the section's root leader row, as the click named it. May still be a temp id; the body resolves it through the
    /// writer's admission-time id map.
    let rootBlockId: String
    let projectId: String
    /// The bibliography heading name from settings, captured on the MainActor at the click (see `SectionDeleteJob`).
    let fallbackBibliographyTitle: String
    let slots: SectionDeleteSlotStore
    /// The editor's copies, one per copied top-level node in document order. Nil: every copy gets a fresh UUID (no editor).
    var copies: [DuplicatedBlock]?
    /// Test seam, the same shape as `SectionDeleteJob.bodyHold`: runs first in the job's body and holds the writer's thread.
    var bodyHold: (@Sendable () -> Void)?
    /// Where "the rows before the op" and the inserted ids are kept for the quick undo's reinsert (see `SectionDeletePayloadHolder`).
    var holder: SectionDeletePayloadHolder?
    /// The key this job's record has in the `EFJobRegistry`: nil means `opId` (the entry's first job); a redo's job registers under a
    /// fresh id, because `EFJobRegistry.register` hands back the record already there for a repeated id.
    var registryKey: UUID?
    /// The database's `sortOrderRenumberLog`. When the room after the section is used up the copy re-spaces every saved position first
    /// (t-bf66e4ee), and the numbers it replaced are logged here on commit, so a zoom range taken before still picks the same rows.
    /// Nil (a test with no database of its own): the re-spacing happens, nothing is logged.
    var renumberLog: SortOrderRenumberLog?

    struct Output: Sendable, Equatable {
        /// The Version History snapshot written before the duplicate. Pinned only when the slot was live at commit.
        let snapshotId: String
        /// Every row the job inserted, in document order.
        let copiedBlockIds: [String]
        /// Set when the editor's copies and the rows differ (`duplicateCopiesMismatch`). The caller logs it and its settle pushes the
        /// database's block ids to the editor; nothing else changes.
        var copiesMismatch: String?
    }

    enum JobError: Error, Equatable {
        /// The root is not a duplicable leader in the database (no such row, a Notes/Bibliography row, or part of the subtree is
        /// missing): nothing was copied, nothing was written, the transaction rolled back.
        case rootNotDuplicable(String)
    }

    // MARK: - The system-write body

    /// The transaction body: snapshot, copy, after-commit slot record. `idMap` is the writer's temp-id map as of admission.
    func run(db: Database, idMap: IdMap) throws -> SystemWriteBody<Output> {
        bodyHold?()
        // The snapshot first: it must hold the document the next statement copies a section of.
        let written = try SnapshotService.writeUndoPointSnapshot(
            db: db, projectId: projectId, fallbackBibliographyTitle: fallbackBibliographyTitle)

        let rootId = idMap[rootBlockId] ?? rootBlockId
        let resolvedCopies = copies?.map { (source: idMap[$0.sourceId] ?? $0.sourceId, new: $0.newId) }
        guard let duplicated = try ProjectDatabase.duplicateSections(
            db: db, rootId: rootId, projectId: projectId, copies: resolvedCopies, renumberLog: renumberLog
        ) else {
            // Rolls the whole transaction back, the snapshot included.
            throw JobError.rootNotDuplicable(rootId)
        }

        // After-commit: the slot record and the pin happen only if the transaction really commits, and only if the slot still
        // exists then. The holder first (a reinsert reads it, and the slot may already be gone), then the slot.
        let snapshotId = written.snapshot.id
        let opId = self.opId
        let slots = self.slots
        let holder = self.holder
        let rowsBefore = written.blocks
        let insertedIds = duplicated.copiedBlockIds
        db.afterNextTransaction(onCommit: { _ in
            holder?.fillForDuplicate(rows: rowsBefore, resolvedRootId: rootId, insertedIds: insertedIds)
            _ = slots.recordApplied(opId, snapshotId: snapshotId, removedSections: [])
        })

        return SystemWriteBody(
            value: Output(snapshotId: snapshotId, copiedBlockIds: insertedIds, copiesMismatch: duplicated.copiesMismatch))
    }

    // MARK: - Running it through the queue

    /// Reserves the job's place in the writer's queue, waits for its turn, runs `run(db:idMap:)` and settles the job's record in
    /// `registry` with whatever came back. The record is registered (idempotently) before the reservation. `onReserved` runs
    /// synchronously once the job holds its place (`performSystemWrite`'s step 4), in the same MainActor turn. `stillWanted` is always
    /// true: a duplicate the user already saw happen is never "not wanted" any more.
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
            identity: identity, kind: .sectionDuplicate, stillWanted: { true }, onReserved: onReserved,
            body: { db, idMap in try job.run(db: db, idMap: idMap) })
        if !JobOutcome(result.outcome).isApplied { holder?.markFailed() }
        registry.settle(key, with: result.outcome)
        return result
    }
}
