//
//  SectionReinsertJob.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (quick undo of an editor-first section delete; plan-v1 C3, plan-v2-addendum 5, plan-v3-addendum A1):
//  the queued database half of the quick undo. By the time this job gets its turn in the writer's queue the editor has already put
//  the section back on the screen (`undoSectionDeleteEditorFirst`, a few milliseconds) and everything typed up to the press has been
//  applied; the job makes the block table agree with the screen.
//
//  WHAT "AGREE" MEANS. The screen after the restore is the editor's pre-delete checkpoint, and the rows the delete job saw just
//  before it deleted (`SectionDeletePayloadHolder.preDeleteRows`, taken in the delete's own transaction, after the batch the click
//  consumed had applied) equal that checkpoint block for block. So the reinsert makes the PROJECT's rows EXACTLY equal to those
//  rows:
//    - every payload row that is missing is inserted, with its id, type, text, level, section metadata and sort order
//      (parents before children: `parentId` is a foreign key);
//    - every present payload row that differs is updated to the payload row (the derived rewrites since the delete: renumbered
//      footnote references, the cleaned Notes, a rewritten bibliography), EXCEPT for the sidebar-only fields (below);
//    - every present row that is not in the payload is deleted, managed (Notes and Bibliography) or not. After the restore the
//      screen shows none of them. A row of the user's that goes this way is logged `alwaysPersisted` with its text, except one that
//      only repeats a payload row under another id (the idle backup's whole-document rewrite gives most blocks fresh ids): that
//      carries no content the screen lacks, and is only counted; and except one the operation itself inserted
//      (`expectedRemovals`: a duplicate's copies, a restore's blocks), which is expected to go and is only counted.
//
//  SIDEBAR-ONLY FIELDS (plan-v3 D9, review rows N4 and S6). A row's status, tags, word goal, goal type and image width live on the
//  block row and in no undo entry: the sidebar (and the image panel) write them straight to the database, outside the document text
//  the editor's history and the routing check compare. For a row that is in BOTH the payload and the table, those five fields come
//  from the CURRENT row, so the reinsert never silently reverts an edit made after the operation; the payload still supplies
//  everything else, and supplies all of it for a row that has to be inserted again. (A row the idle backup re-identified is
//  deleted and re-inserted from the payload, so an edit on it is not carried: the matching is by id.)
//  The idle backup, Save Version and export write the post-delete editor text into the table outside the queue
//  (`flushLiveContentToDatabase`): the same exact-equality rule turns whatever they wrote back into the pre-delete rows
//  (plan-v3-addendum A1). The rows are scoped to the project (`Block.projectId`), like the delete job's read.
//
//  A system write: it stamps no rows and bumps no epoch (like `SectionDeleteJob`). Reservation order alone orders it behind every
//  batch reserved earlier and ahead of every later one. It reads ONLY the holder, never the slot, so a discard of the entry that
//  happens while the job waits (a text edit after the undo drops the redo branch) does not change what it writes.
//
//  `perform(on:identity:registry:key:onReserved:)` runs the job through `BlockSyncService.performSystemWrite` under a registry key
//  of its own (a fresh id per reinsert: `EFJobRegistry.register` hands back the record already there for a repeated id) and settles
//  that record on whatever outcome comes back.
//

import Foundation
import GRDB

struct SectionReinsertJob: Sendable {

    /// The delete entry this job puts back (the key of its slot and of its holder).
    let opId: UUID
    let projectId: String
    /// Where the rows the delete job saw are kept. Captured strongly: the controller may drop its own reference meanwhile.
    let holder: SectionDeletePayloadHolder
    let slots: SectionDeleteSlotStore
    /// Test seam (the same shape as `SectionDeleteJob.bodyHold`): runs first in the job's body and holds the writer's thread until it
    /// returns. Nil in production.
    var bodyHold: (@Sendable () -> Void)?
    /// The ids of the rows the operation being undone inserted itself (a duplicate's copies, a restore's new blocks): their removal is
    /// what the undo is for, so it is counted (`Output.deletedExpectedRows`) and never logged as "a row not in the document before".
    /// Empty for a delete, which inserts nothing.
    var expectedRemovals: Set<String> = []
    /// What the operation was, for the diagnostic log's wording: "delete", "duplicate" or "restore" ("... not in the pre-delete
    /// document"). The payload is the document as it was before that operation.
    var operationLabel: String = "delete"

    struct Output: Sendable, Equatable {
        /// False when the holder said the delete job had not applied (it failed, or has not run): nothing was written.
        var wroteRows: Bool = false
        var insertedIds: [String] = []
        var updatedIds: [String] = []
        var deletedIds: [String] = []
        /// How many of the deleted rows were the user's own (not Notes or Bibliography), and how many of those only repeated a
        /// payload row under another id. Rows in `expectedRemovals` are counted in neither.
        var deletedUserRows = 0
        var deletedReidentifiedRows = 0
        /// How many of the deleted rows were ids the operation itself inserted (`expectedRemovals`).
        var deletedExpectedRows = 0
    }

    enum JobError: Error, Equatable {
        /// A payload row names a parent that is neither present nor part of the payload: nothing is written (the transaction rolls
        /// back) and the caller falls back to writing the editor's own text.
        case brokenParentChain(String)
    }

    /// How many deleted user rows are logged one by one (the rest are counted): the idle backup can leave thousands of re-identified
    /// copies behind, and the point of the log is the rows whose text the screen lacks.
    private static let perRowLogCap = 50
    /// Deletes by key in groups of this size (a book's worth of ids in one `IN (...)` would run into the variable limit).
    private static let deleteChunk = 400

    // MARK: - The system-write body

    func run(db: Database) throws -> SystemWriteBody<Output> {
        bodyHold?()
        let startMs = Self.nowMs()
        let state = holder.snapshot()
        guard state.outcome == .applied else {
            // `.failed`: the delete never reached the database, the section is still there and the D6 put-back owns the screen.
            // `.pending` cannot happen once ticket order holds; either way there is nothing to put back.
            DebugLog.log(
                .undo, "[SectionReinsertJob] \(opId): the \(operationLabel) job's rows are not recorded (\(state.outcome)) -- nothing written")
            return SystemWriteBody(value: Output())
        }
        let payload = state.preDeleteRows
        let payloadIds = Set(payload.map(\.id))
        let current = try Block.filter(Block.Columns.projectId == projectId).order(Block.Columns.sortOrder).fetchAll(db)

        var output = Output(wroteRows: true)
        var anchors: [String: DeletedAnchor] = [:]
        // The rows a Duplicate Section job inserted are only known once it has run (the holder records them in its after-commit hook,
        // before this job's turn by ticket order), so they join the removals the caller named when it built this job.
        let expected = expectedRemovals.union(state.insertedBlockIds)
        try deleteRowsOutsidePayload(
            db: db, current: current, payload: payload, payloadIds: payloadIds, expected: expected,
            output: &output, anchors: &anchors)

        let currentPayloadRows = Dictionary(
            current.filter { payloadIds.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try insertMissingRows(db: db, payload: payload, present: currentPayloadRows, output: &output)
        for row in payload {
            guard let existing = currentPayloadRows[row.id] else { continue }
            let target = Self.carryingForwardSidebarFields(from: existing, into: row)
            guard existing != target else { continue }
            try target.update(db)
            output.updatedIds.append(row.id)
        }
        if output.wroteRows, !(output.insertedIds.isEmpty && output.updatedIds.isEmpty && output.deletedIds.isEmpty) {
            try ProjectDatabase.recomputeSectionParents(db: db, projectId: projectId)
        }

        // After-commit: only a transaction that really commits moves the slot on (`quickUndone` -> `reinserted`; a quick redo that
        // has already run leaves the slot alone).
        let opId = self.opId
        let slots = self.slots
        db.afterNextTransaction(onCommit: { _ in _ = slots.markReinserted(opId) })

        DebugLog.log(
            .undo,
            "[SectionReinsertJob] \(opId): payload=\(payload.count) rows, project had \(current.count): inserted=\(output.insertedIds.count) "
            + "updated=\(output.updatedIds.count) deleted=\(output.deletedIds.count) (user rows \(output.deletedUserRows), "
            + "re-identified \(output.deletedReidentifiedRows)) ms=\(Self.nowMs() - startMs) "
            + "expectedRemovals=\(output.deletedExpectedRows)")
        return SystemWriteBody(value: output, deletedAnchors: anchors)
    }

    /// The row to write for a payload row that is also in the table: the payload row, except that the sidebar-only fields (status,
    /// tags, word goal, goal type, image width -- see the file header) keep the value the table holds now. A sidebar edit saves
    /// `updatedAt` with the value, so when the carry changes anything the current row's stamp stays too: a row that differs from the
    /// payload only in those fields then equals its target and is not written at all.
    static func carryingForwardSidebarFields(from existing: Block, into payloadRow: Block) -> Block {
        var target = payloadRow
        target.status = existing.status
        target.tags = existing.tags
        target.wordGoal = existing.wordGoal
        target.goalType = existing.goalType
        target.imageWidth = existing.imageWidth
        if target != payloadRow { target.updatedAt = existing.updatedAt }
        return target
    }

    /// Deletes every row of the project that is not in the payload (see the file header) and records, for each, what it hung after,
    /// so a late editor insert anchored on one of them re-anchors (the same tombstone chain the delete job leaves).
    private func deleteRowsOutsidePayload( // swiftlint:disable:this function_parameter_count
        db: Database, current: [Block], payload: [Block], payloadIds: Set<String>, expected: Set<String>,
        output: inout Output, anchors: inout [String: DeletedAnchor]
    ) throws {
        var payloadContentKeys: Set<String>?
        var previousId: String?
        var loggedRows = 0
        for row in current {
            defer { previousId = row.id }
            guard !payloadIds.contains(row.id) else { continue }
            output.deletedIds.append(row.id)
            anchors[row.id] = previousId.map { DeletedAnchor.after($0) } ?? DeletedAnchor.documentStart
            if expected.contains(row.id) {
                output.deletedExpectedRows += 1
                continue
            }
            guard !row.isNotes, !row.isBibliography else { continue }
            output.deletedUserRows += 1
            let keys = payloadContentKeys ?? Set(payload.map { Self.contentKey($0) })
            payloadContentKeys = keys
            if keys.contains(Self.contentKey(row)) {
                output.deletedReidentifiedRows += 1
            } else if loggedRows < Self.perRowLogCap {
                loggedRows += 1
                DebugLog.alwaysPersisted(
                    "[SectionReinsertJob] reinsert removed a row not in the pre-\(operationLabel) document: id=\(row.id) "
                    + "type=\(row.blockType.rawValue) textLength=\(row.textContent.count)")   // length only: the diagnostic log must not carry document text
            }
        }
        if output.deletedUserRows - output.deletedReidentifiedRows > Self.perRowLogCap {
            DebugLog.alwaysPersisted(
                "[SectionReinsertJob] reinsert removed \(output.deletedUserRows - output.deletedReidentifiedRows - Self.perRowLogCap) more "
                + "row(s) not in the pre-\(operationLabel) document (only the first \(Self.perRowLogCap) are listed)")
        }
        var index = 0
        while index < output.deletedIds.count {
            let chunk = Array(output.deletedIds[index..<min(index + Self.deleteChunk, output.deletedIds.count)])
            _ = try Block.filter(keys: chunk).deleteAll(db)
            index += Self.deleteChunk
        }
    }

    /// Inserts every payload row that is not present, in an order in which each row's parent already exists (a list item hangs from
    /// its list). The payload is a consistent table, so the loop always ends; a row whose parent is nowhere is an error.
    private func insertMissingRows(
        db: Database, payload: [Block], present: [String: Block], output: inout Output
    ) throws {
        var remaining = payload.filter { present[$0.id] == nil }
        var available = Set(present.keys)
        while !remaining.isEmpty {
            var deferred: [Block] = []
            for row in remaining {
                if let parent = row.parentId, !available.contains(parent) {
                    deferred.append(row)
                    continue
                }
                var copy = row
                try copy.insert(db)
                available.insert(row.id)
                output.insertedIds.append(row.id)
            }
            guard deferred.count < remaining.count else {
                throw JobError.brokenParentChain(deferred.first?.id ?? "")
            }
            remaining = deferred
        }
    }

    private static func nowMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// What identifies a row's text for the "only repeats a payload row" check.
    private static func contentKey(_ row: Block) -> String {
        "\(row.blockType.rawValue)\u{1F}\(row.markdownFragment)"
    }

    // MARK: - Running it through the queue

    /// Reserves the job's place in the writer's queue, waits for its turn, runs `run(db:)` and settles `key`'s record in `registry` with
    /// whatever came back. `onReserved` runs synchronously once the job holds its place (`performSystemWrite`'s step 4), in the same
    /// MainActor turn: the quick undo uses it to know the reinsert is ordered before it lets typing be queued again. `stillWanted`
    /// is always true: the screen already shows the section, so the database follows whatever happens next.
    @MainActor
    func perform(
        on blockSync: BlockSyncService,
        identity: SystemWriteIdentity,
        registry: EFJobRegistry,
        key: UUID,
        onReserved: (() -> Void)? = nil
    ) async -> SystemWriteResult<Output> {
        registry.register(key)
        // Safety net for a path that leaves this function without settling (nothing does today): the record must resolve.
        defer { registry.resolve(key, .abandoned) }
        let job = self
        let result = await blockSync.performSystemWrite(
            identity: identity, kind: .sectionReinsert, stillWanted: { true }, onReserved: onReserved,
            body: { db in try job.run(db: db) })
        registry.settle(key, with: result.outcome)
        return result
    }
}
