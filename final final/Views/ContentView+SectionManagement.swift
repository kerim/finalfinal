//
//  ContentView+SectionManagement.swift
//  final final
//
//  Section management: scrolling, updating, reordering, and promotion logic.
//

import SwiftUI

extension ContentView {
    func scrollToSection(_ sectionId: String) {
        if editorState.editorMode == .wysiwyg {
            // Milkdown: use block-ID-based scrolling (character offsets are wrong
            // when atom nodes like figures are present — nodeSize=1 vs markdown length)
            editorState.scrollToBlockId = sectionId
        } else {
            // CodeMirror: character offsets map correctly to positions
            guard let db = documentManager.projectDatabase,
                  let pid = documentManager.projectId else { return }

            do {
                let allBlocks = try db.fetchBlocks(projectId: pid)
                let blocks: [Block]
                if let zoomedIds = editorState.zoomedSectionIds {
                    blocks = filterBlocksForZoom(allBlocks, zoomedIds: zoomedIds,
                                                 zoomedBlockRange: editorState.zoomedBlockRange)
                } else {
                    blocks = allBlocks
                }
                // MUST stay in sync with BlockParser.assembleMarkdown filtering
                let nonEmpty = blocks.sorted { $0.sortOrder < $1.sortOrder }
                    .filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
                var offset = 0
                for block in nonEmpty {
                    if block.id == sectionId {
                        break
                    }
                    // In CodeMirror sourceContent, heading blocks are prefixed with
                    // section anchors: <!-- @sid:UUID -->
                    // These add characters not counted in markdownFragment
                    if block.blockType == .heading {
                        // "<!-- @sid:" (10) + id + " -->" (4) = 14 + id.count
                        offset += 14 + block.id.count
                    }
                    offset += block.markdownFragment.count
                    offset += 2  // Account for "\n\n" separator in assembleMarkdown
                }
                editorState.scrollTo(offset: offset)
            } catch {
                DebugLog.log(.outline, "[ContentView] Error computing scroll offset: \(error)")
            }
        }
    }

    func updateSection(_ section: SectionViewModel) {
        // Barrier (docs/plans/patient-rewinding-clockwork.md §4.5/H8, Decision 2 of the
        // Phase 3 review round): section metadata (status/tags/wordGoal) lives on the block
        // row, not in the document text the unified-undo routing guard compares -- a
        // metadata-only edit leaves that equality check satisfied, so without this a
        // structural undo would silently fire and wipe the edit along with reverting the
        // structural op. Invalidate the whole timeline rather than trying to special-case
        // "does this specific entry's snapshot predate this edit" -- the same fail-safe
        // posture every other H8 barrier in the plan's hazard catalog uses.
        //
        // EXCEPT when this call is an ECHO of a DB-driven section refresh rather than a
        // genuine user edit (review round MF-1, REWRITTEN in the round-4 pass per the judge's
        // finding): `mergeSections` mutates existing `SectionViewModel`s IN PLACE, so
        // `refreshSections()` at the end of every
        // performSectionRestoreReplace/performUndo/performRedo -- landing a restored/undone
        // snapshot's (routinely different) section status -- fires the SAME
        // `.onChange(of: section.status)` → `onSectionUpdated` path a real user edit would.
        // Without a guard, a structural op's own refresh would invalidate the very undo entry
        // it just recorded, degrading structural undo to a silent no-op.
        //
        // The ORIGINAL guard here was a flag (`EditorViewState.isRefreshingSections`, set
        // before the DB-driven merge and cleared a runloop turn later via
        // `DispatchQueue.main.async`) resting on an unverified assumption about exactly when
        // SwiftUI's `.onChange` fires relative to that queued clear -- a reviewer traced that
        // it could fail in EITHER direction (the flag still up when a genuine concurrent user
        // edit's `.onChange` fires, wrongly suppressing it; or already cleared before the
        // refresh's own `.onChange` fires, letting the original self-wipe bug back in), and
        // neither direction is verifiable by a unit test, since none of them construct a real
        // SwiftUI view hierarchy where `.onChange` timing could actually be observed.
        //
        // Replaced with a decidable check instead: compare the incoming section's
        // status/tags/wordGoal/goalType/aggregateGoal/aggregateGoalType against the block row
        // CURRENTLY persisted in the DB. They come out equal, field for field, exactly when
        // this call is an echo of a value the DB already holds (a DB-driven refresh handing
        // back what it just read); a genuine user edit is, by construction, changing at least
        // one of these fields, so the comparison is false and the barrier fires. No flag, no
        // runloop timing assumption, and it's directly unit-testable (unlike the flag it
        // replaces).
        guard let db = documentManager.projectDatabase else { return }
        let metadataUnchanged: Bool = {
            guard let existing = try? db.fetchBlock(id: section.id) else {
                // Can't determine whether this is an echo -- fail safe like every other H8
                // barrier and treat it as a real change.
                return false
            }
            return (existing.status ?? .writing) == section.status
                && (existing.tags ?? []) == section.tags
                && existing.wordGoal == section.wordGoal
                && existing.goalType == section.goalType
                && existing.aggregateGoal == section.aggregateGoal
                && existing.aggregateGoalType == section.aggregateGoalType
        }()
        if !metadataUnchanged {
            unifiedUndoService.invalidateAll(reason: "section metadata edited (status/tags/wordGoal)")
        }

        // Save all section metadata in a single atomic transaction to prevent
        // intermediate ValueObservation fires from resetting fields.
        let statusValue = section.status == .final_ ? "final" : section.status.rawValue
        let tagsString: String? = {
            let data = try? JSONEncoder().encode(section.tags)
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }()
        Task {
            do {
                try db.write { dbConn in
                    try dbConn.execute(
                        sql: """
                            UPDATE block SET
                                status = ?, wordGoal = ?, goalType = ?,
                                aggregateGoal = ?, aggregateGoalType = ?,
                                tags = ?, updatedAt = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            statusValue, section.wordGoal, section.goalType.rawValue,
                            section.aggregateGoal, section.aggregateGoalType.rawValue,
                            tagsString, Date(), section.id
                        ]
                    )
                }
            } catch {
                DebugLog.log(.outline, "[ContentView] Error saving section metadata: \(error.localizedDescription)")
            }
        }
    }

    func reorderSection(_ request: SectionReorderRequest) {
        sectionSyncService.cancelPendingSync()

        // Validate
        if request.newParentId == request.sectionId {
            return
        }
        guard let fromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else {
            return
        }

        // Use the target section ID passed from OutlineSidebar (stable across zoom/filtering)
        let targetSectionId = request.targetSectionId

        // Early return for self-drop at same position (no-op)
        if targetSectionId == request.sectionId {
            return
        }

        let sectionToMove = editorState.sections[fromIndex]
        let oldLevel = sectionToMove.headerLevel

        // Branch: Subtree drag vs single-card drag
        if request.isSubtreeDrag && !request.childIds.isEmpty {
            reorderSubtree(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        } else {
            reorderSingleSection(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        }
    }

    /// Reorder a single section (original behavior, promotes orphaned children)
    func reorderSingleSection(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId

        // Work with a local copy to batch all SwiftUI updates
        var sections = editorState.sections

        // 1. Promote orphaned children (on local copy)
        promoteOrphanedChildrenInPlace(
            sections: &sections,
            movedSectionId: request.sectionId,
            targetSectionId: targetSectionId,
            oldLevel: oldLevel
        )

        // 2. Re-find section after promotions
        guard let currentFromIndex = sections.firstIndex(where: { $0.id == request.sectionId }) else {
            return
        }

        // 3. Remove the section
        var removed = sections.remove(at: currentFromIndex)

        // 4. Find insertion point
        var finalIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            finalIndex = targetIdx + 1
        } else {
            finalIndex = 0
        }
        finalIndex = min(max(0, finalIndex), sections.count)

        // 5. Update section properties
        if removed.headerLevel != request.newLevel && request.newLevel > 0 {
            let newMarkdown = sectionSyncService.updateHeaderLevel(
                in: removed.markdownContent,
                to: request.newLevel
            )
            removed = removed.withUpdates(
                parentId: request.newParentId,
                headerLevel: request.newLevel,
                markdownContent: newMarkdown
            )
        } else {
            removed = removed.withUpdates(parentId: request.newParentId)
        }

        // 6. Insert at calculated position
        sections.insert(removed, at: finalIndex)

        // 7. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Reorder a subtree (parent + all children move together, levels adjusted relatively)
    func reorderSubtree(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId
        let levelDelta = request.newLevel - oldLevel  // How much to shift all levels

        // Work with a local copy
        var sections = editorState.sections

        // 1. Collect all sections to move (parent + children) in order
        let allIdsToMove = [request.sectionId] + request.childIds
        var sectionsToMove: [SectionViewModel] = []

        for id in allIdsToMove {
            if let section = sections.first(where: { $0.id == id }) {
                sectionsToMove.append(section)
            }
        }

        // 2. Remove all sections being moved (in reverse order to maintain indices)
        let indicesToRemove = allIdsToMove.compactMap { id in
            sections.firstIndex(where: { $0.id == id })
        }.sorted().reversed()

        for idx in indicesToRemove {
            sections.remove(at: idx)
        }

        // 3. Find insertion point
        var insertionIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            insertionIndex = targetIdx + 1
        } else {
            insertionIndex = 0
        }
        insertionIndex = min(max(0, insertionIndex), sections.count)

        // 4. Apply level delta to all sections being moved
        var adjustedSections: [SectionViewModel] = []
        for (idx, section) in sectionsToMove.enumerated() {
            let newSectionLevel = section.headerLevel + levelDelta
            // Note: H7+ are allowed in data model (no clamping to 6)

            if idx == 0 {
                // Parent section - use the new parent from request
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: section.markdownContent,
                    to: newSectionLevel
                )
                let adjusted = section.withUpdates(
                    parentId: request.newParentId,
                    headerLevel: newSectionLevel,
                    markdownContent: newMarkdown
                )
                adjustedSections.append(adjusted)
            } else {
                // Child section - apply delta but parent will be recalculated later
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: section.markdownContent,
                    to: newSectionLevel
                )
                let adjusted = section.withUpdates(
                    headerLevel: newSectionLevel,
                    markdownContent: newMarkdown
                )
                adjustedSections.append(adjusted)
            }
        }

        // 5. Insert all sections at the insertion point
        for (offset, section) in adjustedSections.enumerated() {
            sections.insert(section, at: insertionIndex + offset)
        }

        // 6. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Finalize section reorder - recalculate offsets, parent relationships, persist via blocks
    func finalizeSectionReorder(sections: [SectionViewModel]) {
        // Barrier (docs/plans/patient-rewinding-clockwork.md §4.5, plan §7 Phase 4): a drag
        // reorder renumbers sortOrder wholesale via `reorderAllBlocks` below
        // (`persistBlocksBeforeRebuild()`), which the snapshot-inverse design tolerates fine
        // for content, but the structural timeline's checkpoint/postOpDoc equality guard has
        // no way to distinguish "user reordered sections" from "nothing changed" -- a
        // structural undo landing after a reorder could restore content whose section order
        // no longer matches what's on screen. Fail safe like every other content-mutating
        // barrier: wipe the timeline rather than special-case it.
        unifiedUndoService.invalidateAll(reason: "sidebar drag reorder")

        // Set content state to suppress polling during rebuild
        // NOTE: No defer — contentState is managed by the persist Task below
        editorState.contentState = .dragReorder

        var mutableSections = recalculateSortOrders(sections)
        mutableSections = applyComputedOffsets(to: mutableSections)

        // Single atomic update to trigger SwiftUI
        editorState.sections = mutableSections

        // Recalculate parent relationships and enforce hierarchy
        editorState.recalculateParentRelationships()
        enforceHierarchyConstraints()

        // Persist blocks to database BEFORE rebuilding content
        // (rebuildDocumentContent reads from DB, so DB must be current)
        persistBlocksBeforeRebuild()

        // Rebuild document content (now reads correct order from DB)
        rebuildDocumentContent()

        // Async: push block IDs + legacy section persist
        scheduleAsyncReorderPersistTasks()
    }

    /// Recalculate sequential sort orders after a reorder.
    func recalculateSortOrders(_ sections: [SectionViewModel]) -> [SectionViewModel] {
        var mutableSections = sections
        for index in mutableSections.indices {
            mutableSections[index] = mutableSections[index].withUpdates(
                sortOrder: Double(index)
            )
        }
        return mutableSections
    }

    /// Compute offsets from blocks (consistent with updateSourceContentIfNeeded) and apply
    /// them to the given sections. Returns the sections unchanged if the database is unavailable
    /// or the offset computation fails.
    func applyComputedOffsets(to sections: [SectionViewModel]) -> [SectionViewModel] {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            return sections
        }

        var mutableSections = sections
        do {
            let fetchedBlocks: [Block]
            if let zoomedIds = editorState.zoomedSectionIds {
                let allBlocks = try db.fetchBlocks(projectId: pid)
                fetchedBlocks = filterBlocksForZoom(
                    allBlocks, zoomedIds: zoomedIds,
                    zoomedBlockRange: editorState.zoomedBlockRange)
            } else {
                fetchedBlocks = try db.fetchBlocks(projectId: pid)
            }
            let blockOffset = computeBlockOffsets(fetchedBlocks)
            for index in mutableSections.indices {
                if let off = blockOffset[mutableSections[index].id] {
                    mutableSections[index] = mutableSections[index].withUpdates(startOffset: off)
                }
            }
        } catch { }

        return mutableSections
    }

    /// Compute per-block character offsets in document order (headings sort before body
    /// blocks at the same sortOrder). Mirrors BlockParser.assembleMarkdown's filtering.
    func computeBlockOffsets(_ blocks: [Block]) -> [String: Int] {
        let sorted = blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        let nonEmpty = sorted.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (i, block) in nonEmpty.enumerated() {
            if i > 0 { offset += 2 }
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
        }
        return blockOffset
    }

    /// Persist blocks to database BEFORE rebuilding content
    /// (rebuildDocumentContent reads from DB, so DB must be current).
    func persistBlocksBeforeRebuild() {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            return
        }

        do {
            var headingUpdates: [String: HeadingUpdate] = [:]
            for vm in editorState.sections {
                headingUpdates[vm.id] = HeadingUpdate(
                    markdownFragment: vm.markdownContent,
                    headingLevel: vm.headerLevel
                )
            }
            try db.reorderAllBlocks(
                sections: editorState.sections,
                projectId: pid,
                headingUpdates: headingUpdates
            )
        } catch {
            DebugLog.log(.outline, "[ContentView] Error persisting reordered blocks: \(error)")
        }
    }

    /// Kick off async follow-up work after a reorder: push block IDs to the web editor,
    /// then fire-and-forget the legacy section table persist.
    func scheduleAsyncReorderPersistTasks() {
        editorState.currentPersistTask?.cancel()
        editorState.currentPersistTask = Task {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await blockSyncService.pushBlockIds()
            editorState.contentState = .idle
        }

        // Legacy section persist (fire-and-forget, non-critical)
        Task { await persistReorderedBlocks_legacySections() }
    }

    /// Persist legacy section table after reorder (fire-and-forget, non-critical)
    func persistReorderedBlocks_legacySections() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            return
        }

        do {
            var sectionChanges: [SectionChange] = []
            for (index, viewModel) in editorState.sections.enumerated() {
                let updates = SectionUpdates(
                    title: viewModel.title,
                    headerLevel: viewModel.headerLevel,
                    sortOrder: index,
                    markdownContent: viewModel.markdownContent,
                    startOffset: viewModel.startOffset,
                    parentId: .some(viewModel.parentId)
                )
                sectionChanges.append(.update(id: viewModel.id, updates: updates))
            }
            try db.applySectionChanges(sectionChanges, for: pid)
        } catch {
            DebugLog.log(.outline, "[ContentView] Error persisting legacy sections: \(error)")
        }
    }

    /// Promote orphaned children in-place on a local array (avoids multiple SwiftUI updates)
    /// Uses target section ID for stable position comparison
    func promoteOrphanedChildrenInPlace(
        sections: inout [SectionViewModel],
        movedSectionId: String,
        targetSectionId: String?,  // ID of section that will be BEFORE the moved section
        oldLevel: Int
    ) {
        guard let movedFromIndex = sections.firstIndex(where: { $0.id == movedSectionId }) else { return }

        // Find direct children of the section being moved
        let childIndices = sections.enumerated()
            .filter { $0.element.parentId == movedSectionId }
            .map { $0.offset }

        for childIndex in childIndices {
            let child = sections[childIndex]

            // After parent removal, where will the child be?
            let childFinalIndex = childIndex > movedFromIndex ? childIndex - 1 : childIndex

            // After parent removal, where will the target be? Parent inserts AFTER target.
            let parentFinalIndex: Int
            if let targetId = targetSectionId,
               let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
                // Target shifts down if it was after the removed section
                let targetFinalIndex = targetIdx > movedFromIndex ? targetIdx - 1 : targetIdx
                parentFinalIndex = targetFinalIndex + 1  // Parent goes AFTER target
            } else {
                parentFinalIndex = 0  // No target = insert at beginning
            }

            // Child is orphaned if it ends up BEFORE the parent in document order
            if childFinalIndex < parentFinalIndex {
                let newLevel = oldLevel
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: child.markdownContent,
                    to: newLevel
                )
                sections[childIndex] = child.withUpdates(
                    headerLevel: newLevel,
                    markdownContent: newMarkdown
                )
            }
        }
    }
}
