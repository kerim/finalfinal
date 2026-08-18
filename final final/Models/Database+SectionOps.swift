//
//  Database+SectionOps.swift
//  final final
//
//  Forward DB ops for sidebar section delete/duplicate (right-click/control-click context
//  menu on a sidebar card). Ported from the parked `sidebar-section-delete-dup` worktree
//  (docs/plans/patient-rewinding-clockwork.md §6) for Phase 4 of the unified chronological
//  undo system.
//
//  Unlike that worktree's original single-slot verbatim-inverse design, these are FORWARD
//  ops only -- there is no `restoreDeletedBlocks`/`deleteBlocks`/`canUndoSectionOperation`/
//  `SectionOperationRecord` here. Undo of `.sectionDelete`/`.sectionDuplicate` is handled the
//  same way as every other structural op: `StructuralUndoController` captures a forced
//  undo-point snapshot BEFORE calling into this file, and undoes by restoring that snapshot
//  wholesale (plan §4.4's "one implementation used by all five ops" / snapshot-inverse
//  design, §6's "port the idea, generalized"). See `StructuralUndoController.performSectionDelete`/
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
    /// Also removes the legacy `section` table row for every deleted leader block, if one
    /// exists. There is no DB-level cascade from `block` to `section` (they're sibling tables,
    /// not parent/child) -- `Snapshot.swift` reads `section.sortOrder` directly, so leaving a
    /// stale row behind (pointing at a heading that no longer exists) would be read by any
    /// future snapshot/version-history pass. `annotation.sectionId` has `onDelete: .setNull`
    /// against `section`, which is the correct, harmless behavior for any legacy (pre-block-
    /// architecture) annotation still anchored to it -- it becomes unsectioned rather than
    /// dangling.
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
            try Section.filter(keys: orderedIds).deleteAll(db)

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
    /// Also creates the legacy `section` table row for every copied leader block (heading or
    /// pseudo-section), symmetric with `deleteSections` maintaining that table on its own side
    /// -- see `deleteSections`'s doc comment for why a stale/missing `section` row matters
    /// (`Snapshot.swift` reads `section.sortOrder` directly).
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
                    newTitle = copy.outlineTitle
                }
                try copy.insert(db)

                // Mirror deleteSections's legacy `section` table maintenance for the copy's own
                // leader rows. `parentId` is left nil, recomputed by
                // `EditorViewState.recalculateParentRelationships()` on the next observation
                // tick rather than stored authoritatively here.
                if copy.blockType == .heading || copy.isPseudoSection {
                    var section = Section(
                        id: copy.id,
                        projectId: projectId,
                        parentId: nil,
                        sortOrder: Int(copy.sortOrder),
                        headerLevel: copy.headingLevel ?? 1,
                        isPseudoSection: copy.isPseudoSection,
                        isBibliography: copy.isBibliography,
                        isNotes: copy.isNotes,
                        title: copy.outlineTitle,
                        markdownContent: copy.markdownFragment,
                        status: copy.status ?? .writing,
                        tags: copy.tags ?? [],
                        wordGoal: copy.wordGoal,
                        goalType: copy.goalType,
                        aggregateGoal: copy.aggregateGoal,
                        aggregateGoalType: copy.aggregateGoalType,
                        wordCount: copy.wordCount,
                        startOffset: 0,
                        createdAt: copy.createdAt,
                        updatedAt: copy.updatedAt
                    )
                    try section.insert(db)
                }
            }

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
