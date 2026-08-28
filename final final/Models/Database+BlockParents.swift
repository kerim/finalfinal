//
//  Database+BlockParents.swift
//  final final
//
//  Persists Block.sectionParentId -- the section-hierarchy parent that used to be a purely
//  derived in-memory value (EditorViewState.recalculateParentRelationships(), recomputed on
//  every observation tick) with nothing writing it to disk. Anything reading parent
//  relationships straight from the database, rather than through a live EditorViewState, got
//  stale or absent answers.
//

import Foundation
import GRDB

extension ProjectDatabase {

    /// Recomputes and persists `sectionParentId` for every outline block (heading or
    /// pseudo-section) in a project, using the exact same "nearest preceding entry with a
    /// strictly lower heading level" rule `EditorViewState.recalculateParentRelationships()`
    /// derives in memory -- both go through `SectionHierarchy.parentIds(for:)`, the one shared
    /// implementation of that rule.
    ///
    /// MUST be called from INSIDE an existing write transaction: takes `db: Database` (not a
    /// `ProjectDatabase`) and performs no `try write { }` of its own, precisely so callers that
    /// already hold a write transaction can call it as their last statement without nesting
    /// transactions. Called at the end of every DB write that can change section structure or
    /// document order: `reorderAllBlocks` and `normalizeSortOrders` (both
    /// Database+BlocksReorder.swift), `replaceBlocks` and `replaceBlocksInRange`
    /// (Database+BlocksReplace.swift), `applyBlockChangesFromEditor` (Database+Blocks.swift),
    /// and `deleteSections`/`duplicateSections` (Database+SectionOps.swift).
    ///
    /// NOT wired at the bibliography/footnote heading-insert paths --
    /// `BibliographySyncService.swift`, `FootnoteSyncService`/`FootnoteSyncService+
    /// Reconciliation.swift`, and `SectionSyncService+MiniNotes.swift` -- and that omission is
    /// only safe today because of two invariants those paths hold: every heading they insert is
    /// hardcoded `headingLevel: 1` (so it always has `parentId == nil`, regardless of document
    /// structure), and it's always inserted to sort LAST among non-bibliography content
    /// (`isBibliography.asc` is the primary sort key `fetchOutlineBlocks`/
    /// `recomputeSectionParents` use, so a bibliography heading can never become some other
    /// heading's computed parent either). If either invariant ever changes -- a
    /// non-level-1 synthetic heading, or one inserted somewhere other than the end -- this
    /// comment is the tripwire: recomputeSectionParents must be wired into that path too, or
    /// `sectionParentId` will silently go stale for it.
    ///
    /// Deliberately NOT called from `EditorViewState.recalculateParentRelationships()` itself:
    /// that method runs on every database observation tick (which can fire every keystroke) as
    /// the in-memory source of truth for the CURRENT tick, and a DB write there would set up a
    /// write-observe-write loop.
    ///
    /// Re-derives `fetchOutlineBlocks`'s exact filter (heading OR pseudo-section) and ordering
    /// (`isBibliography.asc, sortOrder.asc`) directly against `db`, rather than calling that
    /// function, because `fetchOutlineBlocks` wraps its own `read { }` and this must run inside
    /// the caller's already-open write transaction.
    ///
    /// Only updates rows whose stored `sectionParentId` actually differs from the freshly
    /// computed value -- an unconditional write-every-row would touch `updatedAt` (and fire
    /// every observer of every heading) on every qualifying write, for no reason.
    ///
    /// A `static` method (not an instance method) so it can also be called from
    /// `ProjectRepairService`, which only holds a raw `DatabaseQueue`/`Database`, not a
    /// `ProjectDatabase` instance, when repairing a `.driftedSectionParents` integrity issue
    /// (see `ProjectIntegrityChecker.checkSectionParentDrift`, the read-only reader this column
    /// otherwise has no other purpose for).
    static func recomputeSectionParents(db: Database, projectId: String) throws {
        let outlineBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(
                Block.Columns.blockType == BlockType.heading.rawValue ||
                Block.Columns.isPseudoSection == true
            )
            .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
            .fetchAll(db)

        // `?? 1` coalescing matches SectionViewModel.headerLevel's convention exactly -- see
        // SectionHierarchy.parentIds' doc comment for why both callers must agree on this.
        let entries = outlineBlocks.map { (id: $0.id, level: $0.headingLevel ?? 1) }
        let newParentIds = SectionHierarchy.parentIds(for: entries)

        for (block, newParentId) in zip(outlineBlocks, newParentIds) where block.sectionParentId != newParentId {
            try db.execute(
                sql: "UPDATE block SET sectionParentId = ? WHERE id = ?",
                arguments: [newParentId, block.id]
            )
        }
    }

}
