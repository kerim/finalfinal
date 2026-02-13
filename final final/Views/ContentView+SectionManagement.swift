//
//  ContentView+SectionManagement.swift
//  final final
//
//  Section management: scrolling, updating, reordering, and promotion logic.
//

import SwiftUI

extension ContentView {
    func scrollToSection(_ sectionId: String) {
        // Compute character offset by assembling markdown up to the target block
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else { return }

        do {
            let allBlocks = try db.fetchBlocks(projectId: pid)
            let sorted = allBlocks.sorted { $0.sortOrder < $1.sortOrder }
            var offset = 0
            for block in sorted {
                if block.id == sectionId {
                    break
                }
                offset += block.markdownFragment.count
                offset += 2  // Account for "\n\n" separator in assembleMarkdown
            }
            editorState.scrollTo(offset: offset)
        } catch {
            print("[ContentView] Error computing scroll offset: \(error)")
        }
    }

    func updateSection(_ section: SectionViewModel) {
        // Save section metadata changes to block database
        guard let db = documentManager.projectDatabase else { return }
        Task {
            do {
                try db.updateBlockStatus(id: section.id, status: section.status)
                try db.updateBlockWordGoal(id: section.id, goal: section.wordGoal)
                try db.updateBlockGoalType(id: section.id, goalType: section.goalType)
                try db.updateBlockTags(id: section.id, tags: section.tags)
            } catch {
                print("[ContentView] Error saving section metadata: \(error.localizedDescription)")
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
        // Set content state to suppress polling during rebuild
        // NOTE: No defer — contentState is managed by the persist Task below
        editorState.contentState = .dragReorder

        var mutableSections = sections

        // Recalculate sort orders and offsets
        var currentOffset = 0
        for index in mutableSections.indices {
            mutableSections[index] = mutableSections[index].withUpdates(
                sortOrder: Double(index),
                startOffset: currentOffset
            )
            currentOffset += mutableSections[index].markdownContent.count
        }

        // Single atomic update to trigger SwiftUI
        editorState.sections = mutableSections

        // Recalculate parent relationships and enforce hierarchy
        recalculateParentRelationships()
        enforceHierarchyConstraints()

        // Persist blocks to database BEFORE rebuilding content
        // (rebuildDocumentContent reads from DB, so DB must be current)
        if let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
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
                print("[ContentView] Error persisting reordered blocks: \(error)")
            }
        }

        // Rebuild document content (now reads correct order from DB)
        rebuildDocumentContent()

        // Async: push block IDs + legacy section persist
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

    /// Persist current section order to block database after reorder.
    /// Uses reorderAllBlocks to move body blocks with their headings atomically.
    func persistReorderedBlocks() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            return
        }

        do {
            // Build heading updates from current section state
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
            print("[ContentView] Error persisting reordered blocks: \(error)")
        }
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
            print("[ContentView] Error persisting legacy sections: \(error)")
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
