//
//  ContentView+HierarchyEnforcement.swift
//  final final
//
//  Hierarchy constraint enforcement: parent relationships, level validation, and persistence.
//

import SwiftUI

extension ContentView {
    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level
    func recalculateParentRelationships() {
        for index in editorState.sections.indices {
            let section = editorState.sections[index]
            let newParentId = findParentByLevel(at: index)

            // Only update if parentId changed
            if section.parentId != newParentId {
                editorState.sections[index] = section.withUpdates(parentId: newParentId)
            }
        }
    }

    /// Find the appropriate parent for a section at the given index
    /// Parent = nearest preceding section with a LOWER header level
    func findParentByLevel(at index: Int) -> String? {
        let section = editorState.sections[index]

        // H1 sections have no parent
        guard section.headerLevel > 1 else { return nil }

        // Look backwards for a section with lower level
        for i in stride(from: index - 1, through: 0, by: -1) {
            let candidate = editorState.sections[i]
            if candidate.headerLevel < section.headerLevel {
                return candidate.id
            }
        }

        return nil  // No valid parent found
    }

    /// Check if hierarchy constraints are violated (without modifying)
    /// Returns true if any section violates the hierarchy rules
    func hasHierarchyViolations() -> Bool {
        Self.hasHierarchyViolations(in: editorState.sections)
    }

    /// Static version for use in closures
    static func hasHierarchyViolations(in sections: [SectionViewModel]) -> Bool {
        for (index, section) in sections.enumerated() {
            let predecessorLevel = index > 0 ? sections[index - 1].headerLevel : 0

            // First section must be H1
            if index == 0 && section.headerLevel != 1 {
                return true
            }

            // Max level is predecessor + 1
            let maxLevel = predecessorLevel == 0 ? 1 : min(6, predecessorLevel + 1)
            if section.headerLevel > maxLevel {
                return true
            }
        }
        return false
    }

    /// Check and enforce hierarchy constraints only if violations exist
    /// This prevents infinite loops from onChange -> enforceHierarchy -> onChange
    func enforceHierarchyConstraintsIfNeeded() {
        guard hasHierarchyViolations() else { return }
        enforceHierarchyConstraints()
        rebuildDocumentContent()
    }

    /// Static version for use in closures - enforces hierarchy on provided sections array
    static func enforceHierarchyConstraintsStatic(
        sections: inout [SectionViewModel],
        syncService: SectionSyncService
    ) {
        var changed = true
        var passes = 0
        let maxPasses = 10

        while changed && passes < maxPasses {
            changed = false
            passes += 1

            var newSections: [SectionViewModel] = []

            for (index, section) in sections.enumerated() {
                let predecessorLevel = index > 0 ? newSections[index - 1].headerLevel : 0

                // First section must be H1
                if index == 0 && section.headerLevel != 1 {
                    changed = true
                    let newMarkdown = syncService.updateHeaderLevel(in: section.markdownContent, to: 1)
                    newSections.append(section.withUpdates(headerLevel: 1, markdownContent: newMarkdown))
                    continue
                }

                // Max level is predecessor + 1
                let maxLevel = predecessorLevel == 0 ? 1 : min(6, predecessorLevel + 1)
                if section.headerLevel > maxLevel {
                    changed = true
                    let newMarkdown = syncService.updateHeaderLevel(in: section.markdownContent, to: maxLevel)
                    newSections.append(section.withUpdates(headerLevel: maxLevel, markdownContent: newMarkdown))
                } else {
                    newSections.append(section)
                }
            }

            sections = newSections
        }
    }

    /// Static version for use in closures - rebuilds document content from DB blocks
    /// Reads ALL blocks from database (which now has correct sort orders after persist)
    /// and assembles markdown. Respects zoom state.
    static func rebuildDocumentContentStatic(editorState: EditorViewState) {
        #if DEBUG
        print("[rebuildDocumentContentStatic] Called. zoomed=\(editorState.zoomedSectionIds != nil), sections=\(editorState.sections.count)")
        #endif
        guard let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId else { return }

        do {
            let allBlocks = try db.fetchBlocks(projectId: pid)

            if let zoomedIds = editorState.zoomedSectionIds {
                let filtered = filterBlocksForZoomStatic(allBlocks, zoomedIds: zoomedIds, zoomedBlockRange: editorState.zoomedBlockRange)
                editorState.content = BlockParser.assembleMarkdown(from: filtered)
            } else {
                editorState.content = BlockParser.assembleMarkdown(from: allBlocks)
            }

            // Also update sourceContent when in source mode to prevent desync.
            // Without this, CodeMirror still shows old text and re-sends it,
            // creating duplicate blocks.
            if editorState.editorMode == .source,
               let syncService = editorState.sectionSyncService {
                let sectionsForAnchors = editorState.sections
                    .filter { !$0.isBibliography }
                    .sorted { $0.sortOrder < $1.sortOrder }

                // Compute offsets from blocks (same data that produced editorState.content)
                let blocksForOffsets: [Block]
                if let zoomedIds = editorState.zoomedSectionIds {
                    blocksForOffsets = filterBlocksForZoomStatic(
                        allBlocks, zoomedIds: zoomedIds,
                        zoomedBlockRange: editorState.zoomedBlockRange)
                } else {
                    blocksForOffsets = allBlocks
                }
                let sortedBlocks = blocksForOffsets.sorted { a, b in
                    let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                    let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                    return aKey < bKey
                }
                var blockOffset: [String: Int] = [:]
                var bOffset = 0
                for (i, block) in sortedBlocks.enumerated() {
                    if i > 0 { bOffset += 2 }
                    blockOffset[block.id] = bOffset
                    bOffset += block.markdownFragment.count
                }
                var adjusted: [SectionViewModel] = []
                for section in sectionsForAnchors {
                    if let off = blockOffset[section.id] {
                        adjusted.append(section.withUpdates(startOffset: off))
                    }
                }
                let withAnchors = syncService.injectSectionAnchors(
                    markdown: editorState.content, sections: adjusted)
                editorState.sourceContent = syncService.injectBibliographyMarker(
                    markdown: withAnchors, sections: editorState.sections)
            }
        } catch {
            print("[ContentView] Error rebuilding content from blocks: \(error)")
        }
    }

    /// Async hierarchy enforcement with completion-based state clearing
    /// Uses contentState to block ValueObservation during enforcement, preventing race conditions.
    /// Order: enforce constraints → persist to DB (all blocks) → rebuild from DB
    @MainActor
    static func enforceHierarchyAsync(
        editorState: EditorViewState,
        syncService: SectionSyncService
    ) async {
        // Set state to block observation updates during enforcement
        editorState.contentState = .hierarchyEnforcement
        defer {
            editorState.contentState = .idle
        }

        // Enforce hierarchy constraints
        enforceHierarchyConstraintsStatic(
            sections: &editorState.sections,
            syncService: syncService
        )

        // Persist FIRST (writes correct sort orders for all blocks including body)
        await persistEnforcedSections(editorState: editorState)

        // Then rebuild from DB (now has correct data including body blocks)
        rebuildDocumentContentStatic(editorState: editorState)
    }

    /// Persist enforced sections directly to database (both block and legacy section tables)
    /// Called after hierarchy enforcement to ensure corrected levels are saved.
    /// Uses reorderAllBlocks to move body blocks with their headings atomically.
    @MainActor
    static func persistEnforcedSections(editorState: EditorViewState) async {
        guard let db = DocumentManager.shared.projectDatabase,
              let pid = DocumentManager.shared.projectId else {
            return
        }

        do {
            // Persist to block table (headings + body blocks atomically)
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

            // Recalculate zoomedBlockRange after sort orders changed
            if editorState.zoomedBlockRange != nil,
               let zoomedIds = editorState.zoomedSectionIds {
                // Find the zoomed heading's new sort order
                let primaryId = zoomedIds.first ?? ""
                if let headingBlock = try db.fetchBlock(id: primaryId),
                   let headingLevel = headingBlock.headingLevel {
                    let allBlocks = try db.fetchBlocks(projectId: pid)
                    var endSortOrder: Double?
                    for block in allBlocks where block.sortOrder > headingBlock.sortOrder {
                        if block.blockType == .heading, let level = block.headingLevel, level <= headingLevel {
                            endSortOrder = block.sortOrder
                            break
                        }
                    }
                    editorState.zoomedBlockRange = (start: headingBlock.sortOrder, end: endSortOrder)
                } else {
                    // Heading not found — clear zoom range to prevent stale state
                    editorState.zoomedBlockRange = nil
                }
            }

            // Also persist to legacy section table
            var sectionChanges: [SectionChange] = []
            for (index, viewModel) in editorState.sections.enumerated() {
                let updates = SectionUpdates(
                    headerLevel: viewModel.headerLevel,
                    sortOrder: index,
                    markdownContent: viewModel.markdownContent
                )
                sectionChanges.append(.update(id: viewModel.id, updates: updates))
            }
            try db.applySectionChanges(sectionChanges, for: pid)
        } catch {
            print("[ContentView] Error persisting enforced sections: \(error)")
        }
    }

    /// Ensure no section is more than 1 level deeper than its predecessor
    /// Uses iterative transformation with already-processed predecessors for correct constraint checking
    func enforceHierarchyConstraints() {
        var sections = editorState.sections
        var changed = true
        var passes = 0
        let maxPasses = 10

        while changed && passes < maxPasses {
            changed = false
            passes += 1

            // CRITICAL: Create new array each pass so predecessors are up-to-date
            // Using map with sections[index-1] would check the ORIGINAL value, not the
            // already-processed value from earlier in THIS pass
            var newSections: [SectionViewModel] = []

            for (index, section) in sections.enumerated() {
                // Use newSections for predecessor (already processed in THIS pass)
                let predecessorLevel = index > 0 ? newSections[index - 1].headerLevel : 0

                // First section must be H1
                if index == 0 && section.headerLevel != 1 {
                    changed = true
                    let newMarkdown = sectionSyncService.updateHeaderLevel(in: section.markdownContent, to: 1)
                    newSections.append(section.withUpdates(headerLevel: 1, markdownContent: newMarkdown))
                    continue
                }

                // Max level is predecessor + 1
                let maxLevel = predecessorLevel == 0 ? 1 : min(6, predecessorLevel + 1)
                if section.headerLevel > maxLevel {
                    changed = true
                    let newMarkdown = sectionSyncService.updateHeaderLevel(in: section.markdownContent, to: maxLevel)
                    newSections.append(section.withUpdates(headerLevel: maxLevel, markdownContent: newMarkdown))
                } else {
                    newSections.append(section)
                }
            }

            sections = newSections
        }

        // Single atomic update
        editorState.sections = sections
    }
}
