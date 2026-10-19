//
//  StructuralReplaceJob.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 2, round 2d-i (plan-v3 D2, D5, D16): the queued background half of an editor-first Version History
//  restore in Rich Text. By the time this job gets its turn in the writer's queue the editor has already replaced its document with
//  the restored one and shown it, and its pending batch (typing up to the click) has been applied; the job makes the database agree
//  with the editor, and leaves behind what undo needs. It is `SectionDuplicateJob`'s sibling.
//
//  ONE JOB, ONE MODE PER PLAN (`RestorePlan.mode`): `whole` (restore the whole project, round 2d-i), `section` (replace one section's
//  flat range, round 2d-ii) and `insertAfter` (restore as duplicate, round 2d-ii). One transaction frame and one after-commit record
//  for all three; only step (b) differs.
//
//  ONE TRANSACTION, on the `Database` handle of a system write (`SystemWriteKind.structuralReplace`):
//    (a) the Version History snapshot of the whole document as it stands BEFORE the restore, written in every case
//        (`SnapshotService.writeUndoPointSnapshot(db:)`). It is the snapshot the SLOW undo of this entry restores from (the entry has no
//        snapshot id of its own, like an editor-first delete or duplicate), and the rows it read ("the rows before the op") are what the
//        quick undo's reinsert makes the table equal to;
//    (b) `whole`: `content.markdown` = the snapshot's Markdown, the `section` table = the snapshot's sections, and the project's rows =
//        EXACTLY `plan.rows` (`ProjectDatabase.replaceProjectRows`). The same five writes the legacy restore made, in one transaction
//        instead of five, and with the rows already prepared at the click so the editor and the database hold the same ids;
//        `section`: the target heading's FLAT range is deleted and `plan.rows` take its place (`replaceFlatSectionRange`); the range is
//        read NOW, inside the transaction, so a block typed next to it just before the click (applied before this job) is part of it,
//        exactly as it is in the editor; `insertAfter`: `plan.rows` go after the plan's anchor block, or after the last block that is
//        not Notes / Bibliography (`insertRows`). The two section modes write no `content` row and no `section` row, like the delete
//        and the duplicate: the settle's section sync derives both from the editor's text;
//    (c) on commit, and only when the entry's slot is still live: the snapshot id recorded on the slot and the snapshot pinned
//        (`SectionDeleteSlotStore.recordApplied`), and the payload holder filled with "the rows before the op" and the ids of the rows
//        the restore added. The record is an after-commit hook, so a transaction that fails to commit leaves no slot and no pin behind.
//
//  NO EPOCH BUMP, NO STAMP (D5). The job never calls `replaceBlocks`: that function ends in `stampWholeProjectForRewrite`, which bumps
//  the project's write epoch, and a batch the writer reserved before this job's commit but applies after it (the text the user types
//  right after the click is exactly that) would then be refused WHOLE for a stale epoch, without a message. `replaceProjectRows` moves
//  no epoch and restamps nothing, which is also why the unit test that types after the click can assert the epoch did not move.
//
//  The QUICK UNDO of a restore is the ordinary `SectionReinsertJob` (the holder's rows before the op are the payload; it makes the
//  table equal to them, which takes the restored rows out and puts the old ones back; `operationLabel` "restore"). Its redo is a FRESH
//  `StructuralReplaceJob` under a fresh registry key with the SAME plan, so the ids are the first click's (S9).
//
//  A system write: it never nests another system write (the resyncs that follow are queued separately by the wiring), and a failure
//  rolls the whole transaction back, so the database is left exactly as it was; the D6 put-back then gives the document back from it.
//

import Foundation
import GRDB

struct StructuralReplaceJob: Sendable {

    /// The structural entry's id: the key of the job's slot and (for the first job) of its `EFJobRecord`.
    let opId: UUID
    let projectId: String
    /// The bibliography heading name from settings, captured on the MainActor at the click (see `SectionDeleteJob`).
    let fallbackBibliographyTitle: String
    let slots: SectionDeleteSlotStore
    /// What to write (see `RestorePlan`).
    let plan: RestorePlan
    /// Test seam, the same shape as `SectionDuplicateJob.bodyHold`: runs first in the job's body and holds the writer's thread.
    var bodyHold: (@Sendable () -> Void)?
    /// Where "the rows before the op" and the inserted ids are kept for the quick undo's reinsert (see `SectionDeletePayloadHolder`).
    var holder: SectionDeletePayloadHolder?
    /// The key this job's record has in the `EFJobRegistry`: nil means `opId` (the entry's first job); a redo's job registers under a
    /// fresh id, because `EFJobRegistry.register` hands back the record already there for a repeated id.
    var registryKey: UUID?

    /// What the job is for. `restore`: a Version History restore (the default). `snapshotUndo` and `snapshotRedo` (t-18b7fa48 round 3c):
    /// the SLOW undo or redo of an entry, in Rich Text (`queuedSnapshotUndo`). The writes are the same (`whole` mode: the snapshot of the
    /// document before the change, then `content.markdown`, the `section` table and exactly `plan.rows`), and the snapshot is the
    /// entry's REDO snapshot after an undo and its fresh UNDO snapshot after a redo. They differ in what is recorded after the commit:
    /// a restore fills the payload holder and records the entry's slot (the quick undo's material); a snapshot swap touches neither
    /// (the entry keeps its slot and holder, and the quick path is closed for it), it only pins the new snapshot, and the controller
    /// attaches the id to the timeline when the job returns (`attachRedoSnapshot` / `replaceTopOfUndoStack`, on the MainActor).
    enum Kind: Sendable {
        case restore
        case snapshotUndo
        case snapshotRedo
    }

    var kind: Kind = .restore

    struct Output: Sendable, Equatable {
        /// The Version History snapshot written before the restore. Pinned only when the slot was live at commit.
        let snapshotId: String
        /// Every row the job wrote, in document order (`plan.rows`' ids).
        let writtenBlockIds: [String]
        /// The rows the restore added that the document before it did not have: what the quick undo removes (and counts as expected).
        let insertedBlockIds: [String]
    }

    enum JobError: Error, Equatable {
        /// `section`: the plan names no target heading, or the heading is no longer a heading or section break that is neither Notes
        /// nor Bibliography (deleted since the click, say). Nothing was written; the whole transaction rolled back.
        case rootNotReplaceable(String)
        /// `insertAfter`: the anchor block is gone or is Notes / Bibliography. Same outcome.
        case anchorNotUsable(String)
    }

    // MARK: - The system-write body

    /// The transaction body: snapshot, rows, after-commit record. `idMap` is the writer's temp-id map as of admission (the section
    /// modes resolve their target and anchor through it; `whole` replaces every row and needs it for nothing).
    func run(db: Database, idMap: IdMap) throws -> SystemWriteBody<Output> {
        bodyHold?()

        // The snapshot first: it must hold the document the next statements replace.
        let written = try SnapshotService.writeUndoPointSnapshot(
            db: db, projectId: projectId, fallbackBibliographyTitle: fallbackBibliographyTitle)

        try writeRows(db: db, idMap: idMap)

        // After-commit: the slot record and the pin happen only if the transaction really commits, and only if the slot still
        // exists then. The holder first (a reinsert reads it, and the slot may already be gone), then the slot.
        let snapshotId = written.snapshot.id
        let opId = self.opId
        let slots = self.slots
        let holder = self.holder
        let kind = self.kind
        let rowsBefore = written.blocks
        let idsBefore = Set(rowsBefore.map(\.id))
        let writtenIds = plan.rows.map(\.id)
        let insertedIds = writtenIds.filter { !idsBefore.contains($0) }
        let leadersBefore = SnapshotService.sidebarLeaders(of: rowsBefore)
        let anyOldRowId = rowsBefore.first?.id ?? ""
        db.afterNextTransaction(onCommit: { _ in
            switch kind {
            case .restore:
                holder?.fillForRestore(rows: rowsBefore, leaders: leadersBefore, resolvedRootId: anyOldRowId, insertedIds: insertedIds)
                _ = slots.recordApplied(opId, snapshotId: snapshotId, removedSections: [])
            case .snapshotUndo, .snapshotRedo:
                // Pinned the moment the transaction commits, so retention (`pruneAutoBackups`) can never take it between this hook and
                // the MainActor attaching it to the timeline. The controller unpins it again if the entry is gone by then.
                SnapshotService.pinUndoPointSnapshot(snapshotId)
            }
        })

        return SystemWriteBody(value: Output(snapshotId: snapshotId, writtenBlockIds: writtenIds, insertedBlockIds: insertedIds))
    }

    /// Step (b): the rows (and, for `whole`, the content row and the section table), by the plan's mode.
    private func writeRows(db: Database, idMap: IdMap) throws {
        switch plan.mode {
        case .whole:
            try ProjectDatabase.saveContent(db: db, markdown: plan.contentMarkdown, projectId: projectId)
            try ProjectDatabase.deleteAllSections(db: db, projectId: projectId)
            for section in plan.sections {
                try ProjectDatabase.insertSection(db: db, section)
            }
            try ProjectDatabase.replaceProjectRows(db: db, projectId: projectId, rows: plan.rows)
        case .section:
            let rootId = plan.rootBlockId.map { idMap[$0] ?? $0 } ?? ""
            guard try ProjectDatabase.replaceFlatSectionRange(db: db, projectId: projectId, headingId: rootId, rows: plan.rows) else {
                throw JobError.rootNotReplaceable(rootId)
            }
        case .insertAfter:
            let anchorId = plan.anchorBlockId.map { idMap[$0] ?? $0 }
            guard try ProjectDatabase.insertRows(db: db, projectId: projectId, afterBlockId: anchorId, rows: plan.rows) else {
                throw JobError.anchorNotUsable(anchorId ?? "(none)")
            }
        }
    }

    // MARK: - Running it through the queue

    /// Reserves the job's place in the writer's queue, waits for its turn, runs `run(db:idMap:)` and settles the job's record in
    /// `registry` with whatever came back. The record is registered (idempotently) before the reservation. `onReserved` runs
    /// synchronously once the job holds its place (`performSystemWrite`'s step 4), in the same MainActor turn. `stillWanted` is always
    /// true: a restore the user already saw happen is never "not wanted" any more.
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
            identity: identity, kind: .structuralReplace, stillWanted: { true }, onReserved: onReserved,
            body: { db, idMap in try job.run(db: db, idMap: idMap) })
        if !JobOutcome(result.outcome).isApplied { holder?.markFailed() }
        registry.settle(key, with: result.outcome)
        return result
    }

    // MARK: - Reserving in the caller's own turn (round 3c, requirement R3+)

    /// How `reserve` ended: the job holds its place in the writer's queue, or was refused before it reserved anything.
    typealias Reservation = SystemWriteReservationResult

    /// `perform`'s steps up to and including the reservation, as ONE synchronous call: the record is registered and the job takes its
    /// place in the writer's queue before this returns, with no suspension anywhere. The editor-first slow undo calls it inside the
    /// click's reply turn, so no other main-actor turn can come between the editor's answer and the job's place in the queue.
    /// `perform(reserved:...)` runs the reserved job later. `perform(on:identity:registry:onReserved:)` above is unchanged and still
    /// serves the restores.
    @MainActor
    func reserve(on blockSync: BlockSyncService, identity: SystemWriteIdentity, registry: EFJobRegistry) -> Reservation {
        registry.register(registryKey ?? opId)
        return blockSync.reserveSystemWriteNow(identity: identity)
    }

    /// Waits for the turn of a job `reserve` placed in the queue, runs `run(db:idMap:)` and settles the job's record in `registry`
    /// with whatever came back (a `refused` reservation settles it at once, without ever touching the database). The record resolves
    /// on every way out, as in `perform(on:identity:registry:onReserved:)`.
    @MainActor
    func perform(
        reserved: Reservation, on blockSync: BlockSyncService, identity: SystemWriteIdentity, registry: EFJobRegistry
    ) async -> SystemWriteResult<Output> {
        let key = registryKey ?? opId
        defer { registry.resolve(key, .abandoned) }
        let job = self
        let result: SystemWriteResult<Output>
        switch reserved {
        case .refused(let reason):
            result = SystemWriteResult(outcome: .refused(reason), prepareRan: false)
        case .held(let held):
            result = await blockSync.runReservedSystemWrite(
                held, kind: .structuralReplace, identity: identity, body: { db, idMap in try job.run(db: db, idMap: idMap) })
        }
        if !JobOutcome(result.outcome).isApplied { holder?.markFailed() }
        registry.settle(key, with: result.outcome)
        return result
    }
}
