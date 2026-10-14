//
//  Database+SectionOps.swift
//  final final
//
//  Forward DB ops for sidebar section delete/duplicate (right-click/control-click context
//  menu on a sidebar card). Ported from the parked `sidebar-section-delete-dup` worktree
//  for Phase 4 of the unified chronological undo system
//  (docs/architecture/unified-undo.md).
//
//  Unlike that worktree's original single-slot verbatim-inverse design, these are FORWARD
//  ops only -- there is no `restoreDeletedBlocks`/`deleteBlocks`/`canUndoSectionOperation`/
//  `SectionOperationRecord` here. Undo of `.sectionDelete`/`.sectionDuplicate` is handled the
//  same way as every other structural op: `StructuralUndoController` captures a forced
//  undo-point snapshot BEFORE calling into this file, and undoes by restoring that snapshot
//  wholesale (see docs/architecture/unified-undo.md's audited-sequences section, "one
//  implementation used by all six ops" / snapshot-inverse design). See
//  `StructuralUndoController.performSectionDelete`/
//  `performSectionDuplicate`.
//
//  Duplicate = a verbatim deep copy of every Block row in the section's subtree, fresh UUIDs,
//  placed via fractional sortOrder midpoints so no OTHER row's sortOrder is ever touched.
//  Bibliography/notes sections refuse both operations entirely -- they're machine-managed by
//  BibliographySyncService/FootnoteSyncService, not the user.
//
//  Known limitation (by design, not a bug): both operations refuse while zoomed into a
//  section (`StructuralUndoController`'s `.refuseIfZoomed` policy) -- the zoom range is
//  itself a DB structural concept (`zoomedBlockRange`); reconciling it against a concurrent
//  delete/duplicate is out of scope for this feature.
//

import Foundation
import GRDB

// MARK: - Section Subtree Resolution

extension ProjectDatabase {

    /// Resolve the ordered block ids making up a section's full subtree: the leader block
    /// (heading or section-break/pseudo-section) itself, its own body blocks, and every
    /// deeper-level descendant leader (+ its own body blocks) that immediately follows it in
    /// document order -- stopping at the first sibling-or-shallower leader.
    ///
    /// Mirrors two existing pieces of the codebase rather than inventing a third: the
    /// leader/body grouping `reorderAllBlocks` uses (`groupBlocksBySections` in
    /// Database+BlocksReorder.swift), and the level-based parent/child rule
    /// `EditorViewState.findParentByLevel`/`filterToSubtree` use to build `SectionViewModel`
    /// parent chains for zoom. A pseudo-section's effective level is `headingLevel ?? 1`, the
    /// same convention `SectionCardView.SectionViewModel.init(from block:)` uses -- kept
    /// consistent here so "the section's children" means the same thing in the sidebar and in
    /// this delete/duplicate path.
    ///
    /// Returns `nil` when `rootId` isn't a leader block, or is a bibliography/notes section --
    /// both refuse delete/duplicate entirely.
    func sectionBlockIds(rootId: String, projectId: String) throws -> [String]? {
        try read { db in
            try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId)?.blockIds
        }
    }

    /// Ordered block ids of a section's subtree, plus the root leader's display title.
    struct SectionSubtree {
        let blockIds: [String]
        let rootTitle: String
    }

    static func resolveSectionSubtree(db: Database, rootId: String, projectId: String) throws -> SectionSubtree? {
        let allBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        // Same leader predicate as fetchOutlineBlocks (Database+Blocks.swift): heading OR
        // pseudo-section. Order is preserved by filtering the already-sortOrder-sorted array.
        let leaders = allBlocks.filter { $0.blockType == .heading || $0.isPseudoSection }
        guard let rootIndex = leaders.firstIndex(where: { $0.id == rootId }) else { return nil }
        let root = leaders[rootIndex]
        guard !root.isBibliography, !root.isNotes else { return nil }
        let rootLevel = root.headingLevel ?? 1

        var subtreeLeaders = [root]
        for leader in leaders[(rootIndex + 1)...] {
            let level = leader.headingLevel ?? 1
            guard level > rootLevel else { break }
            subtreeLeaders.append(leader)
        }

        // Group non-leader blocks under whichever leader precedes them -- identical shape to
        // `groupBlocksBySections`, just scoped to this file so we don't have to widen that
        // helper's `private` visibility for a one-call reuse.
        let leaderIds = Set(leaders.map(\.id))
        var bodyByLeader: [String: [Block]] = [:]
        var currentLeaderId: String?
        for block in allBlocks {
            if leaderIds.contains(block.id) {
                currentLeaderId = block.id
            } else if let leaderId = currentLeaderId {
                bodyByLeader[leaderId, default: []].append(block)
            }
        }

        var result: [String] = []
        for leader in subtreeLeaders {
            result.append(leader.id)
            result.append(contentsOf: (bodyByLeader[leader.id] ?? []).map(\.id))
        }
        return SectionSubtree(blockIds: result, rootTitle: root.outlineTitle)
    }
}

// MARK: - Delete / Duplicate (forward ops only -- see file header)

extension ProjectDatabase {

    /// Delete a section's full subtree (heading + descendants). Refuses (`nil`) for
    /// bibliography/notes sections or an unresolvable root id. All-or-nothing in a single
    /// write transaction. Returns the deleted root section's display title on success, for use
    /// as a `StructuralEntry` title.
    ///
    /// Does NOT touch the legacy `section` table (a real production bug, found and fixed
    /// 2026-08-22 via Phase D's e2e suite -- this file's own header comment above previously,
    /// wrongly, claimed this function "also removes the legacy `section` table row"). `section`
    /// is a SEPARATE table from `block`, keyed by its own independently-generated UUID
    /// (`SectionReconciler.reconcile()`'s `Section(...)` construction, `Section.swift`'s
    /// `id: String = UUID().uuidString` default) -- there is no shared ID space and no DB
    /// cascade between them. A `Section.filter(keys: blockIds).deleteAll(db)` here (the removed
    /// code) matched zero rows every single time, silently -- the stale `section` row for the
    /// deleted heading survived every sidebar delete, and `Snapshot.swift`'s direct
    /// `section.sortOrder` reads (Version History) were reading a table that didn't actually
    /// reflect the delete. `section`-table convergence is `SectionReconciler`'s job, driven by
    /// `SectionSyncService`, reconciling parsed headers against existing rows by content/position
    /// -- never by a caller passing a `block` id directly. `StructuralUndoController.performStructuralOp`
    /// now forces that resync after this DB mutation lands (see its own "Step 7c" comment).
    @discardableResult
    func deleteSections(rootId: String, projectId: String) throws -> String? {
        try write { db in
            guard let subtree = try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId) else {
                return nil
            }
            let orderedIds = subtree.blockIds
            guard !orderedIds.isEmpty else { return nil }

            let fetched = try Block.filter(keys: orderedIds).fetchAll(db)
            guard fetched.count == orderedIds.count else { return nil }

            try Block.filter(keys: orderedIds).deleteAll(db)

            // Deleting a section's subtree can change which heading precedes which --
            // re-persist sectionParentId to match. See Database+BlockParents.swift.
            try Self.recomputeSectionParents(db: db, projectId: projectId)

            return subtree.rootTitle
        }
    }

    /// Duplicate a section's full subtree: every Block row in it is deep-copied verbatim with a
    /// fresh UUID, placed immediately after the original via fractional sortOrder midpoints
    /// between the subtree's last block and whatever follows it -- so no other row's sortOrder
    /// ever changes. The `" copy"` suffix is applied to the top heading's title/fragment only;
    /// descendant headings and body content are copied unchanged. Refuses (`nil`) for
    /// bibliography/notes sections or an unresolvable root id. Returns the new (suffixed) title
    /// on success, for use as a `StructuralEntry` title.
    ///
    /// Does NOT touch the legacy `section` table (a real production bug, found and fixed
    /// 2026-08-22 via Phase D's e2e suite -- see `deleteSections`'s doc comment for the shared
    /// root cause). The removed code inserted a `Section(id: copy.id, ...)` row keyed by the
    /// COPY's fresh `block` id -- since `block` and `section` share no ID space, and every real
    /// `section` row is minted with its OWN independently-generated UUID
    /// (`SectionReconciler.reconcile()`), that insert created a PERMANENT ORPHAN row no
    /// reconciler pass could ever find or prune by that id -- active, ongoing data corruption on
    /// every sidebar duplicate, not just a dead no-op like the delete side's bug. Section-table
    /// convergence is `SectionReconciler`'s job now; see `deleteSections`'s doc comment and
    /// `StructuralUndoController.performStructuralOp`'s "Step 7c" comment for the fix.
    @discardableResult
    func duplicateSections(rootId: String, projectId: String) throws -> String? {
        try write { db in
            guard let subtree = try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId) else {
                return nil
            }
            let orderedIds = subtree.blockIds
            guard !orderedIds.isEmpty else { return nil }

            let fetched = try Block.filter(keys: orderedIds).fetchAll(db)
            guard fetched.count == orderedIds.count else { return nil }
            let idOrder = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
            let orderedBlocks = fetched.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }

            guard let lastSortOrder = orderedBlocks.map(\.sortOrder).max() else { return nil }
            let nextBlock = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder > lastSortOrder)
                .order(Block.Columns.sortOrder)
                .fetchOne(db)
            // No following block (subtree is the last thing in the document): fabricate an
            // upper bound far enough past lastSortOrder to give every copy its own fractional
            // slot; there's nothing after it to collide with.
            let upperBound = nextBlock?.sortOrder ?? (lastSortOrder + Double(orderedBlocks.count) + 1.0)
            let step = (upperBound - lastSortOrder) / Double(orderedBlocks.count + 1)

            var idMap: [String: String] = [:]
            for block in orderedBlocks { idMap[block.id] = UUID().uuidString }

            var newTitle = subtree.rootTitle + " copy"
            for (index, original) in orderedBlocks.enumerated() {
                var copy = original
                copy.id = idMap[original.id] ?? UUID().uuidString
                // Remap intra-subtree parentId (list_item -> its containing list block, etc.)
                // to the COPY's parent, not the original's -- a block whose parent falls
                // outside the subtree (shouldn't happen structurally) drops the reference
                // rather than pointing at a block that was never duplicated.
                copy.parentId = original.parentId.flatMap { idMap[$0] }
                copy.sortOrder = lastSortOrder + step * Double(index + 1)
                copy.createdAt = Date()
                copy.updatedAt = Date()
                if index == 0, original.blockType == .heading {
                    copy.textContent += " copy"
                    copy.markdownFragment = Self.appendCopySuffix(toHeadingFragment: original.markdownFragment)
                    // `copy = original` above carries over the ORIGINAL's stored wordCount
                    // verbatim; appending " copy" to textContent without this call would persist
                    // a one-word-short count forever (wordCount is a stored column, not computed
                    // on read). Must run before `copy.insert(db)` below.
                    copy.recalculateWordCount()
                    newTitle = copy.outlineTitle
                }
                try copy.insert(db)
            }

            // The duplicated subtree inserts new heading rows -- re-persist sectionParentId
            // to match. See Database+BlockParents.swift.
            try Self.recomputeSectionParents(db: db, projectId: projectId)

            return newTitle
        }
    }

    /// Append " copy" to a heading's markdown fragment (single line: "#{1,6} title"),
    /// preserving anything after a literal newline defensively even though headings are not
    /// expected to contain one.
    private static func appendCopySuffix(toHeadingFragment fragment: String) -> String {
        if let newlineIndex = fragment.firstIndex(of: "\n") {
            return fragment[..<newlineIndex] + " copy" + fragment[newlineIndex...]
        }
        return fragment + " copy"
    }
}
