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
//  writers (SectionOps delete/duplicate, reorder, SectionReconciler, `deleteAllBlocks`)
//  do NOT bump the epoch and are OUT OF SCOPE for this guard; rows they create land at
//  the default (0, 0) stamp.
//
//  Bibliography/Notes/heading-level sync is DIFFERENT as of t-94369a83 Phase 2: those
//  writes route through `DocumentWriter`'s "system write" queue
//  (`BlockSyncService.performSystemWrite`, see docs/architecture/document-writer.md's
//  "System writes" section), so they now participate in ordering against a concurrent
//  editor batch -- just not through THIS guard. A system write (bar the ONE exception
//  below) still never bumps the epoch or writes an (epoch, sequence) stamp of its own
//  (rows it touches keep whatever stamp, including the default (0, 0), they already
//  carried); what arbitrates it against a concurrent editor batch instead is
//  reserve-time and apply-time identity plus the writer's own strict sequence ordering,
//  not this per-row stamp comparison.
//
//  ONE DELIBERATE EXCEPTION (t-94369a83 Phase 3a-1a, plan §2.3; obligation 16): the
//  `.lifecycleWholeDocument` system write (FB, the queued whole-document save a close, project
//  switch or quit takes, Phase 3a-1b step 6) DOES bump and restamp the epoch WHEN IT WRITES -- a
//  checked FB (Phase 3a-2, Option A per the user's decision) whose stored rows already match what it
//  would write writes nothing and bumps nothing -- inside its OWN
//  transaction, because its body runs the `replaceBlocks*` statics, which call
//  `stampWholeProjectForRewrite` on the writer's `Database`. It adds no second bump. A
//  whole-document rewrite is exactly what the epoch exists to invalidate stale batches for. An
//  editor batch reserved before FB's commit carries epoch E and is refused whole by rule 1 of
//  `applyBlockChangesFromEditor` below, but only if it applies AFTER FB's commit; a lower-numbered
//  batch that gets its turn before FB applies normally and is then replaced by FB's content.
//
//  Why that is safe: the lifecycle makes FB's content cover every batch that could still apply
//  after it (polling is stopped first, F drains the poll in flight and forces one more poll, FB
//  writes a fresh fetch of the editor), so the refusal only lands on a late or orphaned batch
//  holding OLDER content than FB's fetch; and because polling is stopped, no editor sequence is
//  reserved between FB's reservation and its commit (it would also read E and be refused
//  wholesale although the writer orders it after FB). Only when the editor does not answer (FB
//  falls back to `editorState.content`) can edits in flight be refused, lost and uncounted
//  (`rejectedWholeBatchForStaleEpoch` feeds no ledger counter, only the log line in rule 1): the
//  known hung-editor gap. Every other kind of system write still never stamps or bumps.
//
//  After a SKIPPED (unchanged) FB nothing is refused by the epoch, since none was bumped: a late batch
//  that applies afterwards is arbitrated by rule 2 below (a late update or delete on a row a newer batch
//  wrote is dropped), by the writer holding updates and deletes that name an unminted temp id, and by
//  FB's own comparison (content not yet applied makes the rows differ, so FB writes and bumps).
//
//  Bibliography rows and Notes-label renames are additionally covered by
//  `applyUpdateToExistingBlock`'s own refusal (Database+Blocks.swift) regardless.
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

/// Where a deleted block's anchor pointed, recorded at the moment a newer batch
/// deletes it -- addendum A2 (t-94369a83), §2. Lets a still-in-flight (late or
/// abandoned) insert whose own anchor turns out to be one of these deleted ids
/// re-anchor onto the anchor's own predecessor instead of being silently dropped.
enum DeletedAnchor: Sendable, Equatable {
    case after(String)
    case documentStart
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
    /// Addendum A2 §2: each row this write ACTUALLY deleted, keyed by its own id,
    /// recording what it was anchored after (or that it was the document's first
    /// block) at the moment it was deleted. Excludes any delete `processEditorDeletes`
    /// itself refused (its bibliography/notes safety net) -- only a row that really
    /// left the table gets a tombstone.
    var deletedAnchors: [String: DeletedAnchor] = [:]
    /// Temp ids whose insert re-anchored via the tombstone chain (§2(a)) instead of
    /// resolving directly against its own anchor -- telemetry, not loss.
    var reanchoredInserts: [String] = []
    /// Temp ids whose insert was rejected because its anchor was missing and the
    /// tombstone chain could not resolve it to a live row either -- a real,
    /// counted loss (`staleAnchorInsertsRejected`).
    var rejectedStaleAnchorInserts: [String] = []
    /// How many times this write re-spaced the project's `sortOrder`s (t-75d20927; see `renumberSortOrdersIfCrowded(db:projectId:)`).
    /// For logs and tests: the numbers themselves reach `ProjectDatabase.sortOrderRenumberLog` when the transaction commits.
    var sortOrderRenumbers = 0

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
    ///
    /// `renumberSortOrdersIfCrowded` (Phase 4a, plan v2 section 1(b), review M8; default OFF): the per-block Markdown writer
    /// passes `true`, and since t-75d20927 so does every editor batch that goes through `BlockSyncService.applyAndConfirm` (Rich
    /// Text reports, zoom and switch batches, editor-first click batches). The unguarded two-argument entry and the writer's held-op
    /// releases leave it off. See `renumberSortOrdersIfCrowded(db:projectId:)` for what it does, and for the answer to "does it
    /// restamp rows or bump the epoch" (no, neither).
    ///
    /// `dedupImagesWithinBatch` (only read when `renumberIfCrowded` is true; the plain path always de-duplicates): whether two
    /// image inserts of the same `src` in this batch become one row. Rich Text wants that (its poll race produced such pairs);
    /// the Markdown writer does not (a Markdown document may hold the same image line twice and must keep two rows).
    ///
    /// When the batch re-spaced the positions, the old numbers are handed to `ProjectDatabase.sortOrderRenumberLog` when (and
    /// only when) the transaction commits, still inside this call, so a zoom range read after the writer returns is already
    /// translated.
    func applyBlockChangesFromEditor(
        _ changes: BlockChanges,
        for projectId: String,
        stamp batchStamp: BlockWriteStamp,
        tombstones: [String: DeletedAnchor] = [:],
        renumberSortOrdersIfCrowded renumberIfCrowded: Bool = false,
        dedupImagesWithinBatch: Bool = true
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
                DebugLog.alwaysPersisted(
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
                DebugLog.alwaysPersisted(
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
                DebugLog.alwaysPersisted(
                    "[BlockWriteStamp] REJECTED ROWS: reason=supersededByNewerWrite "
                    + "batchEpoch=\(batchStamp.epoch) batchSequence=\(batchStamp.sequence) "
                    + "currentEpoch=\(currentEpoch) "
                    + "updatesDropped=\(result.droppedUpdateIds.count) "
                    + "deletesDropped=\(result.droppedDeleteIds.count) wholeBatchRejected=false")
            }

            // Addendum A2 §2: record each about-to-be-deleted row's own predecessor
            // WHILE it still exists (the SQL needs its sortOrder) -- before any row is
            // actually removed. `processEditorDeletes` below can still refuse some of
            // these (its bibliography/notes safety net), so this is filtered down to
            // `writtenDeleteIds` afterward; only a row that really left the table gets
            // a tombstone recorded in the result.
            var candidateDeletedAnchors: [String: DeletedAnchor] = [:]
            for id in deletesToApply {
                if let predecessorId = try String.fetchOne(db, sql: """
                        SELECT id FROM block WHERE projectId = ? \
                        AND sortOrder < (SELECT sortOrder FROM block WHERE id = ?) \
                        ORDER BY sortOrder DESC LIMIT 1
                        """, arguments: [projectId, id]) {
                    candidateDeletedAnchors[id] = .after(predecessorId)
                } else {
                    candidateDeletedAnchors[id] = .documentStart
                }
            }

            // Order preserved from the original: deletes, then inserts (so idMapping is
            // populated for temp-id updates), then updates.
            result.writtenDeleteIds = try processEditorDeletes(db: db, deletes: deletesToApply)
            // Efficiency (t-94369a83 addendum A2 v2, judge small fix): a `Set`
            // membership check is O(1); filtering with `Array.contains` directly
            // made this whole filter O(N*M) across candidate anchors x written
            // deletes.
            let writtenDeleteIdSet = Set(result.writtenDeleteIds)
            result.deletedAnchors = candidateDeletedAnchors.filter { writtenDeleteIdSet.contains($0.key) }

            // RULE 3 - inserts always run once rule 1 has not fired. Addendum A2 §2(a):
            // an insert whose anchor is missing at write time can re-anchor via the
            // tombstone chain instead of being silently dropped -- see
            // `processEditorInserts`'s own doc comment.
            var renumbers: [[Double]] = []
            if renumberIfCrowded {
                renumbers = try processEditorInsertsRenumberingIfCrowded(
                    db: db, inserts: changes.inserts, projectId: projectId,
                    options: InsertPassOptions(tombstones: tombstones, dedupImagesWithinBatch: dedupImagesWithinBatch),
                    result: &result)
            } else {
                var insertedImageSources: [String: String] = [:]
                try processEditorInserts(db: db, inserts: changes.inserts, projectId: projectId,
                                         nextSortOrder: &nextSortOrder, idMapping: &result.idMapping,
                                         tombstones: tombstones, reanchored: &result.reanchoredInserts,
                                         rejected: &result.rejectedStaleAnchorInserts,
                                         insertedImageSources: &insertedImageSources)
            }
            result.writtenInsertIds = Array(result.idMapping.values)

            result.writtenUpdateIds = try processEditorUpdates(db: db, updates: updatesToApply,
                                                               idMapping: result.idMapping)

            // RULE 4 - stamp only what was written. Deletes are excluded: the row is gone,
            // and a later insert can never reuse its id.
            try Self.stamp(db: db, blockIds: result.writtenUpdateIds + result.writtenInsertIds,
                           stamp: batchStamp)

            try Self.recomputeSectionParents(db: db, projectId: projectId)

            result.sortOrderRenumbers = renumbers.count
            logSortOrderRenumbersOnCommit(renumbers, db: db)
        }

        return result
    }

    // MARK: - Sort-order crowding (Phase 4a, plan v2 section 1(b), review M8)

    /// Two adjacent rows whose `sortOrder` values are closer than this (2^-30), or equal, are "crowded".
    ///
    /// Why it exists. `resolveInsertPlacement` puts an insert at the midpoint between its anchor and the next row,
    /// so a run of paragraphs added in ONE spot halves the gap every time: after about 50 of them a double has no
    /// room left, two rows get the SAME `sortOrder`, and their order is lost. Both editors send such a run as ONE batch of
    /// chained inserts after one anchor (a paste), or as a report per Enter (typing), so both pass `true` since
    /// t-75d20927: the Markdown writer and every Rich Text batch through `BlockSyncService.applyAndConfirm`. (Rich Text
    /// was left off until then, which let a 200-paragraph paste tie or reverse its last rows.)
    static let crowdedSortOrderGap: Double = 1.0 / 1_073_741_824.0

    /// Renumbers the project's `sortOrder`s as 1.0, 2.0, 3.0, ... in assembly order (`BlockParser.assemblySorted`:
    /// by `sortOrder`, a heading before a non-heading at the same value) when any two adjacent rows are crowded.
    /// Returns the OLD `sortOrder`s of the rows in that order (what `SortOrderRenumberLog` keeps) when it renumbered, nil when
    /// it did not. Runs on the caller's `db` handle, i.e. inside the batch's own transaction.
    ///
    /// RESOLVED VERIFY-FIRST (plan v2 section 1(b)): this restamps NOTHING and bumps NO epoch. It is a plain
    /// `UPDATE block SET sortOrder = ?`: `lastWriteEpoch`, `lastWriteSequence` and `project.blockWriteEpoch` are not
    /// touched (compare `stampWholeProjectForRewrite`, which does both). So no batch fetched earlier is refused
    /// because of it, and the per-row "newer write wins" rule is unaffected. The ORDER of the rows is unchanged;
    /// only the numbers move.
    ///
    /// What the numbers feed: nothing in the editor holds a `sortOrder` (a block is identified by its id; a report's
    /// anchors are ids), so an editor batch in flight is unaffected. What DOES observe the numbers re-reads once: the outline
    /// snapshot (`OutlineSnapshotPublisher`) and the section word counts (sums over `sortOrder` ranges, recomputed from the
    /// rows), because every row changed in one transaction (one re-emit). `recomputeSectionParents` runs after this in the
    /// same transaction and reads the new numbers. What keeps a row's OLD number across the batch is a zoom: its
    /// `[start, end)` range of raw numbers (`EditorViewState.zoomedBlockRange`), which is why every committed renumber is
    /// logged (`SortOrderRenumberLog`) and a zoom range is an `AnchoredSortOrderRange` that is carried through the log. The writers
    /// that re-space are logged: this one (a crowded editor batch), and, since t-bf66e4ee, the three that re-space before they
    /// place rows in a gap (`duplicateSections(db:...)`, `insertRows`, `replaceFlatSectionRange`, through
    /// `renumberAllSortOrders` and `logSortOrderRenumbersOnCommit`). The other `sortOrder` writers (`replaceBlocks`,
    /// `replaceBlocksInRange`, `reorderAllBlocks`, `normalizeSortOrders`, the section shifts, the whole-table undo restores) are not,
    /// and a native structural-undo restore of a deleted section's rows writes the whole table back at once.
    @discardableResult
    static func renumberSortOrdersIfCrowded(db: Database, projectId: String) throws -> [Double]? {
        let ordered = try assemblyOrderedSortOrders(db: db, projectId: projectId)
        guard zip(ordered, ordered.dropFirst()).contains(where: { $1.sortOrder - $0.sortOrder < crowdedSortOrderGap }) else {
            return nil
        }
        let old = try renumberAllSortOrders(db: db, projectId: projectId)
        DebugLog.log(.data, "[BlockWriteStamp] sort orders crowded - renumbered \(old.count) rows (no restamp, no epoch bump)")
        return old
    }

    /// Renumbers the project's `sortOrder`s as 1.0, 2.0, 3.0, ... in assembly order whether or not any two rows are crowded, and
    /// returns the OLD numbers in that order (what `SortOrderRenumberLog` keeps). The same plain `UPDATE block SET sortOrder`
    /// as `renumberSortOrdersIfCrowded`: no restamp, no epoch bump, the order of the rows unchanged. On the caller's `db` handle,
    /// so inside the caller's own transaction. For a writer that is about to put rows into a gap and sees that the gap would
    /// leave them less than `crowdedSortOrderGap` apart: the table is not crowded yet, but the rows it is about to add would be
    /// (t-bf66e4ee). The caller logs the result with `logSortOrderRenumbersOnCommit` and must READ AGAIN every `sortOrder` it
    /// fetched before this call (they are the old numbers now).
    static func renumberAllSortOrders(db: Database, projectId: String) throws -> [Double] {
        let ordered = try assemblyOrderedSortOrders(db: db, projectId: projectId)
        try rewriteSortOrders(db: db, orderedIds: ordered.map { $0.id })
        return ordered.map { $0.sortOrder }
    }

    /// The project's `(id, sortOrder)` pairs in assembly order.
    private static func assemblyOrderedSortOrders(db: Database, projectId: String) throws -> [(id: String, sortOrder: Double)] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, sortOrder, blockType FROM block WHERE projectId = ?", arguments: [projectId])
        let headingRaw = BlockType.heading.rawValue
        let items = rows.enumerated().map { offset, row in
            (offset: offset, id: row["id"] as String, sortOrder: row["sortOrder"] as Double,
             headingRank: (row["blockType"] as String) == headingRaw ? 0 : 1)
        }
        return items.sorted { lhs, rhs in
            (lhs.sortOrder, lhs.headingRank, lhs.offset) < (rhs.sortOrder, rhs.headingRank, rhs.offset)
        }.map { ($0.id, $0.sortOrder) }
    }

    private static func rewriteSortOrders(db: Database, orderedIds: [String]) throws {
        let statement = try db.cachedStatement(sql: "UPDATE block SET sortOrder = ? WHERE id = ?")
        for (index, id) in orderedIds.enumerated() {
            try statement.execute(arguments: [Double(index + 1), id])
        }
    }

    /// Whether inserting `insert` where it is anchored would leave a gap below `crowdedSortOrderGap` (the new
    /// row lands at the midpoint, so each side gets half of the gap that exists now). False for an append at the
    /// end (it lands a full 1.0 after the last row) and for an anchor that does not resolve (`processEditorInserts`
    /// rejects it or falls back as it always does).
    private static func insertWouldCrowd(
        db: Database, insert: BlockInsert, projectId: String, idMapping: [String: String]
    ) throws -> Bool {
        if let rawAfterId = insert.afterBlockId {
            let anchorId = idMapping[rawAfterId] ?? rawAfterId
            guard let anchor = try Double.fetchOne(
                db, sql: "SELECT sortOrder FROM block WHERE id = ?", arguments: [anchorId]),
                  let next = try Double.fetchOne(
                    db, sql: "SELECT MIN(sortOrder) FROM block WHERE projectId = ? AND sortOrder > ?",
                    arguments: [projectId, anchor]) else { return false }
            return (next - anchor) / 2.0 < crowdedSortOrderGap
        }
        if insert.atDocumentStart == true {
            guard let first = try Double.fetchOne(
                db, sql: "SELECT MIN(sortOrder) FROM block WHERE projectId = ?", arguments: [projectId]) else { return false }
            return first / 2.0 < crowdedSortOrderGap
        }
        return false
    }

    /// t-75d20927: tells `sortOrderRenumberLog` what this batch re-spaced, but only if the transaction really commits (a rollback logs
    /// nothing). The hook runs inside the batch's own `write` call, so the entries are in the log before the writer returns and a
    /// zoom range read after that is already translated. Does nothing when the batch re-spaced nothing.
    private func logSortOrderRenumbersOnCommit(_ renumbers: [[Double]], db: Database) {
        Self.logSortOrderRenumbersOnCommit(renumbers, to: sortOrderRenumberLog, db: db)
    }

    /// The body of the instance method above, for a writer that runs as a static on an open `Database` and is handed the log (the
    /// section jobs, t-bf66e4ee). Nothing when `renumbers` is empty or `log` is nil (a caller with no database of its own: a test).
    static func logSortOrderRenumbersOnCommit(_ renumbers: [[Double]], to log: SortOrderRenumberLog?, db: Database) {
        guard !renumbers.isEmpty, let log else { return }
        db.afterNextTransaction(onCommit: { _ in log.append(renumbers) })
    }

    /// What `processEditorInsertsRenumberingIfCrowded` needs besides the inserts themselves (bundled to keep its parameter list short).
    private struct InsertPassOptions {
        /// The writer's tombstones: a late insert whose anchor a newer batch deleted re-anchors through them.
        let tombstones: [String: DeletedAnchor]
        /// Whether one image map is shared across the batch (true) or every insert gets a fresh one (false); see the function's doc.
        let dedupImagesWithinBatch: Bool
    }

    /// `processEditorInserts` for a batch that re-spaces the positions: the inserts one at a time, with the crowding
    /// check BEFORE each (renumber first when this insert would crowd, so a batch of 80 chained inserts after one
    /// paragraph keeps every row distinct and in order), and one check after the last (any crowding left). Returns the old
    /// `sortOrder`s of every renumber it made, in the order it made them (the caller logs them when the transaction commits).
    ///
    /// The check cannot wait until after the batch: by then the chained inserts have halved the same gap 50+ times,
    /// rows share a `sortOrder`, and their order is already lost. One insert per call means `processEditorInserts` cannot
    /// keep its within-batch image de-duplication map by itself, so this function owns the map and hands it in:
    /// `dedupImagesWithinBatch` true shares one map across the whole batch (Rich Text: its poll race can send the same image
    /// twice, and the plain path de-duplicates); false gives every insert a fresh one, so a Markdown document that holds the
    /// same image line twice keeps two rows.
    private func processEditorInsertsRenumberingIfCrowded(
        db: Database,
        inserts: [BlockInsert],
        projectId: String,
        options: InsertPassOptions,
        result: inout EditorApplyResult
    ) throws -> [[Double]] {
        var renumbers: [[Double]] = []
        var insertedImageSources: [String: String] = [:]
        // Only the no-anchor fallback of `processEditorInserts` reads this; an editor insert nearly always carries an anchor, but
        // keep it truthful across a renumber (the end of the document is then `count + 1`).
        var nextSortOrder = (try Double.fetchOne(
            db, sql: "SELECT MAX(sortOrder) FROM block WHERE projectId = ?", arguments: [projectId]) ?? 0) + 1.0
        for insert in inserts {
            if try Self.insertWouldCrowd(db: db, insert: insert, projectId: projectId, idMapping: result.idMapping) {
                let old = try Self.renumberAllSortOrders(db: db, projectId: projectId)
                renumbers.append(old)
                nextSortOrder = Double(old.count) + 1.0
                DebugLog.log(.data, "[BlockWriteStamp] insert would crowd sort orders - renumbered \(old.count) rows first")
            }
            if !options.dedupImagesWithinBatch { insertedImageSources = [:] }
            try processEditorInserts(
                db: db, inserts: [insert], projectId: projectId, nextSortOrder: &nextSortOrder,
                idMapping: &result.idMapping, tombstones: options.tombstones, reanchored: &result.reanchoredInserts,
                rejected: &result.rejectedStaleAnchorInserts, insertedImageSources: &insertedImageSources)
        }
        if !inserts.isEmpty, let old = try Self.renumberSortOrdersIfCrowded(db: db, projectId: projectId) {
            renumbers.append(old)
        }
        return renumbers
    }
}
