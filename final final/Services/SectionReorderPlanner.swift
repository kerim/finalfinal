//
//  SectionReorderPlanner.swift
//  final final
//
//  Pure array-reordering algorithms for section drag-and-drop, extracted out of
//  ContentView+SectionManagement.swift's `reorderSection`/`reorderSingleSection`/
//  `reorderSubtree`/`promoteOrphanedChildrenInPlace` so the array math is unit-testable
//  without a database or the async, GRDB-backed structural-op machinery
//  `dispatchSectionReorder` dispatches into. (A bare `ContentView` was already directly
//  testable before this change -- see `ContentViewSectionReorderTests.swift` -- so the real
//  win here is skipping `StructuralUndoController`'s DB writes and `Task` scheduling, not
//  avoiding `ContentView` itself.) Namespace-only, matching the existing
//  `ContentView.enforceHierarchyConstraintsStatic(sections:syncService:)` precedent of taking
//  `sections`/`syncService` as explicit parameters rather than reading them off `self`.
//
//  Pure move: every function body below is the original ContentView extension method's body,
//  unchanged except for `editorState.sections` -> a `sections` parameter, `sectionSyncService`
//  -> a `syncService` parameter, and `promoteOrphanedChildrenInPlace`'s `inout` parameter
//  becoming a plain parameter + return value (SectionViewModel is a reference type whose
//  `withUpdates` already returns fresh instances, so this is a straight substitution with no
//  aliasing change). `ContentView.reorderSection(_:)` is now a thin wrapper around
//  `plan(request:in:syncService:)` + the untouched `dispatchSectionReorder`.
//

import Foundation

@MainActor
enum SectionReorderPlanner {
    /// Validate a reorder request against `sections` and compute the resulting array, or
    /// `nil` if the request is rejected. Absorbs `reorderSection`'s 3 validation guards
    /// (newParentId == sectionId; section not found; targetSectionId == sectionId) -- each
    /// returns `nil` here, exactly as it returned early with no dispatch before. A 4th
    /// early-return guard, `planSingleSection`'s own internal re-find-after-promotion check,
    /// stays inside `planSingleSection` itself rather than here (see its doc comment), but has
    /// the same nil-means-no-dispatch effect.
    static func plan(
        request: SectionReorderRequest,
        in sections: [SectionViewModel],
        syncService: SectionSyncService
    ) -> [SectionViewModel]? {
        // Validate
        if request.newParentId == request.sectionId {
            return nil
        }
        guard let fromIndex = sections.firstIndex(where: { $0.id == request.sectionId }) else {
            return nil
        }

        // Use the target section ID passed from OutlineSidebar (stable across zoom/filtering)
        let targetSectionId = request.targetSectionId

        // Early return for self-drop at same position (no-op)
        if targetSectionId == request.sectionId {
            return nil
        }

        let sectionToMove = sections[fromIndex]
        let oldLevel = sectionToMove.headerLevel

        // Branch: Subtree drag vs single-card drag
        if request.isSubtreeDrag && !request.childIds.isEmpty {
            return planSubtree(request: request, in: sections, oldLevel: oldLevel, syncService: syncService)
        } else {
            return planSingleSection(
                request: request, in: sections, oldLevel: oldLevel, syncService: syncService
            )
        }
    }

    /// Reorder a single section (original behavior, promotes orphaned children)
    static func planSingleSection(
        request: SectionReorderRequest,
        in sections: [SectionViewModel],
        oldLevel: Int,
        syncService: SectionSyncService
    ) -> [SectionViewModel]? {
        let targetSectionId = request.targetSectionId

        // Work with a local copy to batch all SwiftUI updates
        var sections = sections

        // 1. Promote orphaned children (on local copy)
        sections = promotingOrphanedChildren(
            in: sections,
            movedSectionId: request.sectionId,
            targetSectionId: targetSectionId,
            oldLevel: oldLevel,
            syncService: syncService
        )

        // 2. Re-find section after promotions
        guard let currentFromIndex = sections.firstIndex(where: { $0.id == request.sectionId }) else {
            return nil
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
            let newMarkdown = syncService.updateHeaderLevel(
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

        return sections
    }

    /// Reorder a subtree (parent + all children move together, levels adjusted relatively)
    static func planSubtree(
        request: SectionReorderRequest,
        in sections: [SectionViewModel],
        oldLevel: Int,
        syncService: SectionSyncService
    ) -> [SectionViewModel] {
        let targetSectionId = request.targetSectionId
        let levelDelta = request.newLevel - oldLevel  // How much to shift all levels

        // Work with a local copy
        var sections = sections

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
                let newMarkdown = syncService.updateHeaderLevel(
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
                let newMarkdown = syncService.updateHeaderLevel(
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

        return sections
    }

    /// Promote orphaned children on a copy of `sections`, returning the updated array.
    /// Uses target section ID for stable position comparison.
    static func promotingOrphanedChildren(
        in sections: [SectionViewModel],
        movedSectionId: String,
        targetSectionId: String?,  // ID of section that will be BEFORE the moved section
        oldLevel: Int,
        syncService: SectionSyncService
    ) -> [SectionViewModel] {
        guard let movedFromIndex = sections.firstIndex(where: { $0.id == movedSectionId }) else { return sections }

        var sections = sections

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
                let newMarkdown = syncService.updateHeaderLevel(
                    in: child.markdownContent,
                    to: newLevel
                )
                sections[childIndex] = child.withUpdates(
                    headerLevel: newLevel,
                    markdownContent: newMarkdown
                )
            }
        }

        return sections
    }
}
