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

    /// Async hierarchy enforcement using surgical heading level updates.
    /// Instead of reading all blocks from DB and replacing the entire editor document
    /// (which causes content discrepancy and data loss), this computes the heading level
    /// diff and applies it surgically via ProseMirror's setNodeMarkup.
    @MainActor
    static func enforceHierarchyAsync(
        editorState: EditorViewState,
        syncService: SectionSyncService
    ) async {
        #if DEBUG
        print("[SYNC-DIAG:Hierarchy] entry: \(editorState.sections.count) sections, contentState=\(editorState.contentState)")
        #endif

        editorState.contentState = .hierarchyEnforcement
        defer { editorState.contentState = .idle }

        // 1. Save original heading levels to compute diff
        let originalLevels = Dictionary(
            uniqueKeysWithValues: editorState.sections.map { ($0.id, $0.headerLevel) }
        )

        // 2. Enforce hierarchy constraints (modifies sections array)
        enforceHierarchyConstraintsStatic(
            sections: &editorState.sections, syncService: syncService
        )

        // 3. Compute which headings actually changed level
        var headingChanges: [(blockId: String, newLevel: Int)] = []
        for section in editorState.sections {
            if let oldLevel = originalLevels[section.id], oldLevel != section.headerLevel {
                headingChanges.append((blockId: section.id, newLevel: section.headerLevel))
            }
        }

        // 4. Persist changes to DB (sort orders + heading levels)
        await persistEnforcedSections(editorState: editorState)

        // 5. If no heading levels changed, nothing to push to editor
        guard !headingChanges.isEmpty else { return }

        #if DEBUG
        print("[SYNC-DIAG:Hierarchy] \(headingChanges.count) heading changes to push")
        #endif

        // 6. Push changes to editor
        if editorState.editorMode == .source {
            // SOURCE MODE FALLBACK: Milkdown WebView may not be active.
            // Apply heading changes via string replacement on editorState.content.
            applyHeadingChangesViaStringReplacement(
                editorState: editorState,
                headingChanges: headingChanges,
                originalLevels: originalLevels,
                syncService: syncService
            )
        } else {
            // WYSIWYG MODE: Surgical ProseMirror update
            guard let bss = editorState.blockSyncService else { return }
            if let updatedContent = await bss.updateHeadingLevels(headingChanges) {
                editorState.content = updatedContent
            } else {
                // Fallback if JS call fails (e.g., temp IDs not found)
                #if DEBUG
                print("[SYNC-DIAG:Hierarchy] updateHeadingLevels returned nil, falling back to string replacement")
                #endif
                applyHeadingChangesViaStringReplacement(
                    editorState: editorState,
                    headingChanges: headingChanges,
                    originalLevels: originalLevels,
                    syncService: syncService
                )
            }
        }
    }

    /// Fallback: Apply heading level changes via string replacement on editorState.content.
    /// Used in source mode (Milkdown unavailable) or when JS surgical update fails.
    @MainActor
    static func applyHeadingChangesViaStringReplacement(
        editorState: EditorViewState,
        headingChanges: [(blockId: String, newLevel: Int)],
        originalLevels: [String: Int],
        syncService: SectionSyncService
    ) {
        var content = editorState.content

        // Build lookup of changed blockId → newLevel
        let changeMap = Dictionary(uniqueKeysWithValues: headingChanges.map { ($0.blockId, $0.newLevel) })

        // Process in forward document order with searchFrom cursor to handle duplicate titles
        let changedSections = editorState.sections
            .filter { changeMap[$0.id] != nil }
            .sorted { $0.sortOrder < $1.sortOrder }

        var searchFrom = content.startIndex
        for section in changedSections {
            guard let oldLevel = originalLevels[section.id] else { continue }
            let oldPrefix = String(repeating: "#", count: oldLevel) + " "
            let newPrefix = String(repeating: "#", count: section.headerLevel) + " "

            let oldHeading = oldPrefix + section.title
            let newHeading = newPrefix + section.title
            if let range = content.range(of: oldHeading, range: searchFrom..<content.endIndex) {
                content.replaceSubrange(range, with: newHeading)
                // Advance searchFrom past the replacement
                searchFrom = content.index(range.lowerBound, offsetBy: newHeading.count)
            }
        }

        editorState.content = content

        // Update sourceContent if in source mode
        if editorState.editorMode == .source,
           let sectionSync = editorState.sectionSyncService {
            let sectionsForAnchors = editorState.sections
                .filter { !$0.isBibliography }
                .sorted { $0.sortOrder < $1.sortOrder }
            var adjusted: [SectionViewModel] = []
            var anchorSearchFrom = content.startIndex
            for section in sectionsForAnchors {
                let headingPrefix = String(repeating: "#", count: section.headerLevel) + " "
                let headingLine = headingPrefix + section.title
                if let range = content.range(of: headingLine, range: anchorSearchFrom..<content.endIndex) {
                    let offset = content.distance(from: content.startIndex, to: range.lowerBound)
                    adjusted.append(section.withUpdates(startOffset: offset))
                    anchorSearchFrom = range.upperBound
                }
            }
            let withAnchors = sectionSync.injectSectionAnchors(
                markdown: content, sections: adjusted)
            editorState.sourceContent = sectionSync.injectBibliographyMarker(
                markdown: withAnchors, sections: editorState.sections)
        }
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
            #if DEBUG
            print("[ContentView] Error persisting enforced sections: \(error)")
            #endif
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
