//
//  FootnoteSyncService+SystemWrite.swift
//  final final
//
//  Phase 2 (t-94369a83), §2.3: the Notes write/removal bodies, routed through
//  `DocumentWriter`'s system-write queue (§1) instead of writing directly. Both are
//  thin `nonisolated static func` wrappers around the (now `nonisolated`, inout-anchor-
//  taking) reconciliation helpers in `FootnoteSyncService+Reconciliation.swift` --
//  surfacing their tombstone anchors through `SystemWriteBody.deletedAnchors` rather
//  than duplicating any of that logic here.
//

import Foundation
import GRDB

extension FootnoteSyncService {
    /// The Notes-update system-write body: `performFootnoteUpdate`'s own `prepare`
    /// closure already posted `.renumberFootnotes` for the composed rename map before
    /// this runs (see that function) -- this is purely the DB write,
    /// `reconcileNotesBlocks`'s inout-anchor overload, with its tombstones surfaced.
    nonisolated static func writeNotesReconciliation(
        db: Database, projectId: String, targetRefs: [String], renameMap: [String: String],
        definitionOverrides: [String: String] = [:]
    ) throws -> SystemWriteBody<[String: String]> {
        var deletedAnchors: [String: DeletedAnchor]? = [:]
        let insertedIds = try reconcileNotesBlocks(
            db: db, projectId: projectId, targetRefs: targetRefs, renameMap: renameMap,
            definitionOverrides: definitionOverrides, deletedAnchors: &deletedAnchors)
        return SystemWriteBody(value: insertedIds, deletedAnchors: deletedAnchors ?? [:])
    }

    /// Convenience overload for parity with `reconcileNotesBlocks`/
    /// `deleteOrphanedFootnoteDefinitions`'s own wrapper pattern (Swift disallows a
    /// default value on an `inout` parameter). Review fix (finding #13): checked --
    /// still not dead. No PRODUCTION call site needs the no-anchors form (the one real
    /// caller, `removeNotesBlock`'s system-write body, always wants anchors and calls
    /// the other overload directly), but `DocumentWriterSystemWriteTests`'s own
    /// every-`SystemWriteKind`-applies smoke test does use this exact overload (it
    /// doesn't care about anchors for that generic check) -- kept for that real, if
    /// test-only, caller.
    nonisolated static func writeNotesRemoval(
        db: Database, projectId: String
    ) throws -> (deletedCount: Int, retainedCount: Int) {
        var discardedAnchors: [String: DeletedAnchor]?
        return try writeNotesRemoval(db: db, projectId: projectId, deletedAnchors: &discardedAnchors)
    }

    /// Phase 2 (t-94369a83), §2.4: the immediate-insertion system-write body, called by
    /// both `FootnoteSyncService.commitImmediateInsertion` (the system-write path) and
    /// its own `.noWriter` fallback -- a plain `nonisolated static func` (not a nested
    /// closure inside the instance method) specifically so it is callable from the
    /// `@Sendable (Database) throws -> SystemWriteBody<R>` shape `performSystemWrite`
    /// requires; a nested function declared inside a `@MainActor` instance method would
    /// itself be MainActor-isolated by inference and would not satisfy that shape.
    /// Mirrors footnote-plugin.ts's `insertFootnote` shift rule: every existing DB
    /// label >= `pivot` shifts up by one; everything below is untouched.
    nonisolated static func writeImmediateInsertion(
        db: Database, projectId: String, pivot: Int
    ) throws -> SystemWriteBody<(finalRefs: [String], insertedBlockId: String?)> {
        let existingDefBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.blockType == BlockType.paragraph.rawValue)
            .fetchAll(db)

        let existingLabels: Set<Int> = Set(existingDefBlocks.compactMap { block in
            parseNotesLabel(from: block.markdownFragment).flatMap { Int($0.label) }
        })

        // Shift every existing label >= pivot up by one; labels below pivot are
        // untouched. When pivot == existingMax + 1 (append), this is empty by
        // construction and the call degenerates to a pure insertion.
        var renameMap: [String: String] = [:]
        for oldInt in existingLabels where oldInt >= pivot {
            renameMap[String(oldInt)] = String(oldInt + 1)
        }

        let targetLabels = Set(existingLabels.map { $0 >= pivot ? $0 + 1 : $0 }).union([pivot])
        let targetRefs = targetLabels.sorted().map(String.init)

        var deletedAnchors: [String: DeletedAnchor]? = [:]
        let insertedIds = try reconcileNotesBlocks(
            db: db, projectId: projectId, targetRefs: targetRefs, renameMap: renameMap,
            deletedAnchors: &deletedAnchors)
        let insertedBlockId = insertedIds[String(pivot)]

        return SystemWriteBody(value: (targetRefs, insertedBlockId), deletedAnchors: deletedAnchors ?? [:])
    }

    /// Moved near-verbatim from `removeNotesBlock`'s own write-closure body (every
    /// existing comment/log line preserved) -- only machine-owned rows (heading,
    /// definitions, and their continuations; classified via `notesOwnershipMap`) are
    /// deleted; the user's own prose living inside the (now-removed) Notes run is
    /// unflagged and left untouched. Phase 2 (t-94369a83), §2.3 point 4: the WHOLE set
    /// of machine-owned rows this sweep is about to delete is anchor-resolved (via
    /// `resolveTombstoneChain`, so a predecessor that is itself in this same delete set
    /// is walked past) BEFORE any row in it is actually deleted.
    nonisolated static func writeNotesRemoval(
        db: Database, projectId: String, deletedAnchors: inout [String: DeletedAnchor]?
    ) throws -> (deletedCount: Int, retainedCount: Int) {
        // A dual-flagged (isBibliography) row is never this sweep's to touch -- it
        // belongs to BibliographySyncService.
        let notesRows = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.isNotes == true)
            .filter(Block.Columns.isBibliography == false)
            .fetchAll(db)
        let (ownership, _) = notesOwnershipMap(for: notesRows)

        if deletedAnchors != nil {
            var idsToDelete: Set<String> = []
            for row in notesRows {
                switch ownership[row.id] {
                case .heading, .definition, .continuation:
                    idsToDelete.insert(row.id)
                case .userProse, nil:
                    break
                }
            }
            if !idsToDelete.isEmpty {
                let chainAnchors = try resolveTombstoneChain(db: db, projectId: projectId, deletedIds: idsToDelete)
                for (id, anchor) in chainAnchors { deletedAnchors?[id] = anchor }
            }
        }

        var deletedCount = 0
        var retainedCount = 0
        var deletedDefinitionTwins: [Block] = []
        for row in notesRows {
            switch ownership[row.id] {
            case .heading, .definition, .continuation:
                if case .definition = ownership[row.id] {
                    // B6: this row is about to be deleted, so the orphan sweep below
                    // (which runs in this SAME write, after every definition is
                    // already gone) can never find it as a "current" twin by a fresh
                    // query. Pass it along as a known-prior-twin -- it still carries a
                    // body, so the body-comparison rule still applies rather than
                    // deleting-by-default on "no twin found".
                    deletedDefinitionTwins.append(row)
                }
                // B9: log the full fragment before it is destroyed.
                DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: deleting " +
                    "id=\(row.id) blockType=\(row.blockType.rawValue) " +
                    "fragment=\"\(row.markdownFragment)\"")
                try Block.deleteOne(db, key: row.id)
                deletedCount += 1
            case .userProse, nil:
                // The user's own writing living inside the (now-removed) Notes run --
                // unflag it and leave the content exactly as it is.
                var unflagged = row
                unflagged.isNotes = false
                unflagged.updatedAt = Date()
                try unflagged.update(db)
                retainedCount += 1
                DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: retaining " +
                    "id=\(row.id) fragment=\"\(row.markdownFragment)\" reason=user-prose-not-machine-owned")
            }
        }
        DebugLog.log(.footnotes, "[FootnoteSyncService] removeNotesBlock: deleted=\(deletedCount) " +
            "retained=\(retainedCount) of total=\(notesRows.count)")

        // Clean up orphaned footnote definitions from before isNotes propagation fix --
        // B6: pass the definition rows just deleted above as known-prior-twins, since
        // with B1 landed every definition row is gone before this sweep runs, and a
        // fresh query would otherwise find "no twin" for every candidate by
        // construction.
        try deleteOrphanedFootnoteDefinitions(
            db: db, projectId: projectId, knownPriorTwins: deletedDefinitionTwins, deletedAnchors: &deletedAnchors)

        return (deletedCount, retainedCount)
    }
}
