//
//  Database+BlockWriteStamp.swift
//  final final
//
//  Persisted (epoch, sequence) write stamp for editor-diff block writes.
//
//  Replaces BlockSyncService's in-memory `lastWriterStampByBlockId`. The stamp lives
//  next to the rows it protects, so the "is this batch older than what is already
//  there?" decision is atomic with the write and the stamp persists across a service
//  reset and a project reopen, which the in-memory map could not survive.
//
//  What invalidates a stale batch (the epoch barrier): the wholesale `replaceBlocks*`
//  rewrites (`replaceBlocks`, both its default and its preserving-machine-managed path,
//  and `replaceBlocksInRange`) and the `configure`/`reconfigure` epoch bump each advance
//  the project's epoch, so any batch fetched before them is refused. Native structural
//  writers (SectionOps delete/duplicate, reorder, bibliography/footnote sync,
//  SectionReconciler, `deleteAllBlocks`) do NOT bump the epoch and are OUT OF SCOPE for
//  this guard; rows they create land at the default (0, 0) stamp.
//
//  Comparison is lexicographic, epoch-major. A row stamped in an older epoch therefore
//  always compares below any batch carrying the current epoch, whatever their sequences.
//
//  DELIBERATELY raw SQL throughout: `Project` and `Block` must NOT declare these
//  columns. `updateProject` (Database+CRUD.swift) and `applyUpdateToExistingBlock`
//  (Database+Blocks.swift) both do full-column record writes, which would write a
//  possibly-stale decoded stamp back over a fresher one and silently defeat the guard.
//

import Foundation
import GRDB

/// The (epoch, sequence) coordinate a single editor-diff batch was fetched at.
struct BlockWriteStamp: Equatable, Sendable, Comparable {
    let epoch: Int64
    let sequence: Int64

    /// Sentinel for callers outside the poll pipeline (tests, and any future
    /// non-poll caller of the legacy 2-arg entry point): skip BOTH the batch-level
    /// and the per-row check, and do not stamp anything. Production never uses it -
    /// `BlockSyncService` is the only production caller and always passes a real stamp.
    static let unguarded = BlockWriteStamp(epoch: -1, sequence: -1)
    var isUnguarded: Bool { self == .unguarded }

    static func < (lhs: BlockWriteStamp, rhs: BlockWriteStamp) -> Bool {
        (lhs.epoch, lhs.sequence) < (rhs.epoch, rhs.sequence)
    }
}

/// What a stamped `applyBlockChangesFromEditor` actually wrote, so the caller can
/// report and account for it without keeping any parallel in-memory state.
struct EditorApplyResult: Sendable {
    /// Temp->permanent ids THIS write produced. EMPTY when the batch was rejected
    /// wholesale for a stale epoch - see `rejectedWholeBatchForStaleEpoch`.
    var idMapping: [String: String] = [:]
    var writtenUpdateIds: [String] = []
    var writtenInsertIds: [String] = []
    var writtenDeleteIds: [String] = []
    var droppedUpdateIds: [String] = []
    var droppedDeleteIds: [String] = []
    /// True when the batch's epoch was below the project's current epoch and the
    /// ENTIRE batch - inserts included - was refused.
    var rejectedWholeBatchForStaleEpoch = false

    var writtenCount: Int { writtenUpdateIds.count + writtenInsertIds.count + writtenDeleteIds.count }
    var droppedCount: Int { droppedUpdateIds.count + droppedDeleteIds.count }
}

extension ProjectDatabase {

    // MARK: - Migration

    /// Body of the `v17_block_write_stamp` migration (registered in `ProjectDatabase.migrate()`;
    /// it lives here, not inline, so the migrator function does not push the `ProjectDatabase`
    /// class body over the type-body-length cap -- same convention as
    /// `sweepOrphanedNotesDefinitionsAtV16`).
    ///
    /// Additive and NOT NULL DEFAULT 0, so every pre-existing row is already valid at the
    /// moment the column appears: 0 is the lowest possible stamp, so any batch written after
    /// this migration wins on its own merits rather than being refused against a null. No
    /// backfill is needed for the same reason. Raw schema DSL only, never decoded through
    /// `Block`/`Project` -- the v15 "never decode through current model types" discipline
    /// (a migration must keep working when those types later change), same as v1-v14.
    static func addBlockWriteStampColumnsAtV17(db: Database) throws {
        try db.alter(table: "project") { t in
            t.add(column: "blockWriteEpoch", .integer).notNull().defaults(to: 0)
        }
        try db.alter(table: "block") { t in
            t.add(column: "lastWriteEpoch", .integer).notNull().defaults(to: 0)
            t.add(column: "lastWriteSequence", .integer).notNull().defaults(to: 0)
        }
    }

    // MARK: - Epoch

    /// Current block-write epoch for the project. Raw SQL, never via `Project`.
    /// The `project` table holds exactly one row, so the `id` predicate is belt-and-braces.
    func currentBlockWriteEpoch(projectId: String) throws -> Int64 {
        try read { db in try Self.blockWriteEpoch(db: db, projectId: projectId) }
    }

    static func blockWriteEpoch(db: Database, projectId: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT blockWriteEpoch FROM project WHERE id = ?",
                           arguments: [projectId]) ?? 0
    }

    /// Bump the epoch and normalize every surviving row of the project to
    /// (newEpoch, 0), in ONE step, on the caller's OWN `db` handle.
    ///
    /// Why both halves must share the rewrite's transaction: the bump is the barrier
    /// and the restamp is what makes a stored stamp readable in the new epoch's terms.
    /// A crash or an interleaved read between them would expose a project whose epoch
    /// says "new" while its rows still claim high sequences from the old one.
    @discardableResult
    static func stampWholeProjectForRewrite(db: Database, projectId: String) throws -> Int64 {
        let next = try blockWriteEpoch(db: db, projectId: projectId) + 1
        try db.execute(sql: "UPDATE project SET blockWriteEpoch = ? WHERE id = ?",
                       arguments: [next, projectId])
        try db.execute(
            sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = 0 WHERE projectId = ?",
            arguments: [next, projectId])
        DebugLog.log(.data, "[BlockWriteStamp] project rewritten - epoch bumped to \(next)")
        return next
    }

    /// Bump used by the service-lifecycle call sites (`configure`/`reconfigure`),
    /// which have no enclosing transaction of their own.
    @discardableResult
    func bumpBlockWriteEpoch(projectId: String) throws -> Int64 {
        try write { db in try Self.stampWholeProjectForRewrite(db: db, projectId: projectId) }
    }

    // MARK: - Row stamps

    static func storedStamp(db: Database, blockId: String) throws -> BlockWriteStamp? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT lastWriteEpoch, lastWriteSequence FROM block WHERE id = ?",
            arguments: [blockId]) else { return nil }
        return BlockWriteStamp(epoch: row["lastWriteEpoch"], sequence: row["lastWriteSequence"])
    }

    /// Stamp ONLY rows this batch actually wrote. An update or delete that was
    /// dropped, or one the bibliography/notes safety nets refused, must not advance
    /// its row's stamp - or a later legitimate batch would be measured against a
    /// write that never happened.
    static func stamp(db: Database, blockIds: [String], stamp: BlockWriteStamp) throws {
        guard !stamp.isUnguarded, !blockIds.isEmpty else { return }
        let placeholders = databaseQuestionMarks(count: blockIds.count)
        try db.execute(
            sql: "UPDATE block SET lastWriteEpoch = ?, lastWriteSequence = ? WHERE id IN (\(placeholders))",
            arguments: StatementArguments([stamp.epoch, stamp.sequence] + blockIds.map { $0 as DatabaseValueConvertible }))
    }

    /// Apply an editor diff under the (epoch, sequence) write guard, in ONE transaction.
    ///
    /// Three rules, in order:
    ///   1. BATCH level - if the batch's epoch is below the project's current epoch, the
    ///      document has been wholesale rebuilt since this batch was fetched. Reject the
    ///      WHOLE batch, inserts included: their anchors, ids and ordering all belong to
    ///      a coordinate space that no longer exists.
    ///   2. ROW level - otherwise drop an update OR DELETE iff the row's STORED stamp is
    ///      strictly greater than the batch's. Within one epoch this is exactly the
    ///      fetch-ordinal comparison the removed in-memory map performed. THIS MUST GATE
    ///      DELETES TOO, not just updates - a stale delete of a block a newer batch owns
    ///      would destroy newer text, which is worse than the bug being fixed.
    ///   3. INSERTS are always processed when rule 1 did not fire: a temp id is unique to
    ///      the batch that minted it, so no newer batch can have written that block.
    /// Only rows actually written are stamped (rule 4, in `stamp(db:blockIds:stamp:)`).
    func applyBlockChangesFromEditor(
        _ changes: BlockChanges,
        for projectId: String,
        stamp batchStamp: BlockWriteStamp
    ) throws -> EditorApplyResult {
        var result = EditorApplyResult()

        try write { db in
            let currentEpoch = try Self.blockWriteEpoch(db: db, projectId: projectId)

            // RULE 1 - batch-level epoch reject.
            if !batchStamp.isUnguarded && batchStamp.epoch < currentEpoch {
                result.rejectedWholeBatchForStaleEpoch = true
                result.droppedUpdateIds = changes.updates.map(\.id)
                result.droppedDeleteIds = changes.deletes
                // `result.idMapping` stays EMPTY and `processEditorInserts` never runs.
                DebugLog.always(
                    "[BlockWriteStamp] REJECTED WHOLE BATCH: reason=staleEpoch "
                    + "batchEpoch=\(batchStamp.epoch) currentEpoch=\(currentEpoch) "
                    + "batchSequence=\(batchStamp.sequence) "
                    + "updatesDropped=\(result.droppedUpdateIds.count) "
                    + "deletesDropped=\(result.droppedDeleteIds.count) "
                    + "insertsDropped=\(changes.inserts.count)")
                return
            }

            // Defensive: a batch epoch ABOVE the stored one cannot happen - the epoch is
            // read from this same DB and only ever increases. Log and fall through to the
            // per-row rules rather than trapping.
            if !batchStamp.isUnguarded && batchStamp.epoch > currentEpoch {
                DebugLog.always(
                    "[BlockWriteStamp] ANOMALY: batch epoch \(batchStamp.epoch) exceeds current "
                    + "\(currentEpoch) - applying per-row rather than refusing")
            }

            var nextSortOrder = (try Double.fetchOne(db,
                sql: "SELECT MAX(sortOrder) FROM block WHERE projectId = ?",
                arguments: [projectId]) ?? 0) + 1.0

            // RULE 2 - filter deletes, then updates, against the stored row stamps.
            var deletesToApply: [String] = []
            for id in changes.deletes {
                if let stored = try Self.storedStamp(db: db, blockId: id),
                   !batchStamp.isUnguarded, stored > batchStamp {
                    result.droppedDeleteIds.append(id)
                } else {
                    deletesToApply.append(id)
                }
            }
            var updatesToApply: [BlockUpdate] = []
            for update in changes.updates {
                if let stored = try Self.storedStamp(db: db, blockId: update.id),
                   !batchStamp.isUnguarded, stored > batchStamp {
                    result.droppedUpdateIds.append(update.id)
                } else {
                    updatesToApply.append(update)
                }
            }
            if result.droppedCount > 0 {
                DebugLog.always(
                    "[BlockWriteStamp] REJECTED ROWS: reason=supersededByNewerWrite "
                    + "batchEpoch=\(batchStamp.epoch) batchSequence=\(batchStamp.sequence) "
                    + "currentEpoch=\(currentEpoch) "
                    + "updatesDropped=\(result.droppedUpdateIds.count) "
                    + "deletesDropped=\(result.droppedDeleteIds.count) wholeBatchRejected=false")
            }

            // Order preserved from the original: deletes, then inserts (so idMapping is
            // populated for temp-id updates), then updates.
            result.writtenDeleteIds = try processEditorDeletes(db: db, deletes: deletesToApply)

            // RULE 3 - inserts always run once rule 1 has not fired.
            try processEditorInserts(db: db, inserts: changes.inserts, projectId: projectId,
                                     nextSortOrder: &nextSortOrder, idMapping: &result.idMapping)
            result.writtenInsertIds = Array(result.idMapping.values)

            result.writtenUpdateIds = try processEditorUpdates(db: db, updates: updatesToApply,
                                                               idMapping: result.idMapping)

            // RULE 4 - stamp only what was written. Deletes are excluded: the row is gone,
            // and a later insert can never reuse its id.
            try Self.stamp(db: db, blockIds: result.writtenUpdateIds + result.writtenInsertIds,
                           stamp: batchStamp)

            try Self.recomputeSectionParents(db: db, projectId: projectId)
        }

        return result
    }
}
