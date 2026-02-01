//
//  ContentView.swift
//  final final
//

import SwiftUI

/// Line-based cursor position for cross-editor coordination.
/// Uses line/column instead of raw offsets because ProseMirror (tree-based)
/// and markdown (flat text) positions don't map 1:1.
struct CursorPosition: Equatable {
    let line: Int
    let column: Int

    static let start = CursorPosition(line: 1, column: 0)
}

// swiftlint:disable:next type_body_length
struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(VersionHistoryCoordinator.self) private var versionHistoryCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var editorState = EditorViewState()
    @State private var cursorPositionToRestore: CursorPosition?
    @State private var sectionSyncService = SectionSyncService()
    @State private var annotationSyncService = AnnotationSyncService()
    @State private var bibliographySyncService = BibliographySyncService()
    @State private var autoBackupService = AutoBackupService()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// Integrity alert state
    @State private var integrityReport: IntegrityReport?
    @State private var pendingProjectURL: URL?

    /// Version history dialog state
    @State private var showSaveVersionDialog = false
    @State private var saveVersionName = ""

    /// Getting Started close alert state
    @State private var showGettingStartedCloseAlert = false

    /// Editor preload ready state - blocks editor display until WebView is ready
    @State private var isEditorPreloadReady = false

    /// Callback when project is closed (to return to picker)
    var onProjectClosed: (() -> Void)?

    /// Use the shared DocumentManager for project lifecycle
    private var documentManager: DocumentManager { DocumentManager.shared }

    var body: some View {
        mainContentView
            .withEditorNotifications(editorState: editorState, cursorRestore: $cursorPositionToRestore)
            .withFileNotifications(
                editorState: editorState,
                syncService: sectionSyncService,
                onOpened: { await handleProjectOpened() },
                onClosed: { handleProjectClosed() },
                onIntegrityError: { report, url in
                    pendingProjectURL = url
                    integrityReport = report
                }
            )
            .withVersionNotifications(
                onSaveVersion: { showSaveVersionDialog = true },
                onShowHistory: {
                    // Prepare coordinator with current state before opening window
                    if let db = documentManager.projectDatabase,
                       let pid = documentManager.projectId {
                        versionHistoryCoordinator.prepareForOpen(
                            database: db,
                            projectId: pid,
                            sections: editorState.sections
                        )
                        openWindow(id: "version-history")
                    }
                }
            )
            .integrityAlert(
                report: $integrityReport,
                onRepair: { report in
                    Task { await handleRepair(report: report) }
                },
                onOpenAnyway: { report in
                    Task { await handleOpenAnyway(report: report) }
                },
                onCancel: {
                    handleIntegrityCancel()
                }
            )
            .alert("Save Version", isPresented: $showSaveVersionDialog) {
                TextField("Version name", text: $saveVersionName)
                Button("Cancel", role: .cancel) {
                    saveVersionName = ""
                }
                Button("Save") {
                    Task { await handleSaveVersion() }
                }
            } message: {
                Text("Enter a name for this version:")
            }
            .alert("Changes Not Saved", isPresented: $showGettingStartedCloseAlert) {
                Button("Discard") {
                    documentManager.closeProject()
                    onProjectClosed?()
                }
                Button("Create New Project") {
                    handleCreateFromGettingStarted()
                }
            } message: {
                Text("Changes to Getting Started aren't saved. Create a new project to keep your work.")
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        navigationSplitViewContent
            .withContentObservers(
                editorState: editorState,
                sectionSyncService: sectionSyncService,
                annotationSyncService: annotationSyncService,
                bibliographySyncService: bibliographySyncService,
                autoBackupService: autoBackupService,
                documentManager: documentManager
            )
            .withSidebarSync(
                editorState: editorState,
                sidebarVisibility: $sidebarVisibility
            )
    }

    @ViewBuilder
    private var navigationSplitViewContent: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebarView
        } detail: {
            detailView
        }
        .navigationTitle(documentManager.projectTitle ?? "Untitled")
        .toolbar { annotationPanelToolbar }
        .task {
            AppDelegate.shared?.editorState = editorState
            await initializeProject()
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Zoom breadcrumb when zoomed into a section
            if let zoomedSection = editorState.zoomedSection {
                ZoomBreadcrumb(
                    zoomedSection: zoomedSection,
                    onZoomOut: {
                        editorState.zoomOutSync()
                    }
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                zoomedSectionId: $editorState.zoomedSectionId,
                onScrollToSection: { sectionId in
                    scrollToSection(sectionId)
                },
                onSectionUpdated: { section in
                    updateSection(section)
                },
                onSectionReorder: { request in
                    reorderSection(request)
                },
                onZoomToSection: { sectionId in
                    Task {
                        await editorState.zoomToSection(sectionId)
                    }
                },
                onZoomOut: {
                    editorState.zoomOutSync()
                },
                onDragStarted: {
                    editorState.isObservationSuppressed = true
                    sectionSyncService.isSyncSuppressed = true
                    sectionSyncService.cancelPendingSync()
                },
                onDragEnded: {
                    editorState.isObservationSuppressed = false
                    sectionSyncService.isSyncSuppressed = false
                }
            )
        }
        .frame(minWidth: 250)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    /// Toolbar content for annotation panel toggle
    @ToolbarContentBuilder
    private var annotationPanelToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            NativeToolbarButton(
                systemSymbolName: "sidebar.right",
                accessibilityLabel: editorState.isAnnotationPanelVisible
                    ? "Hide annotations panel"
                    : "Show annotations panel"
            ) {
                editorState.toggleAnnotationPanel()
            }
            .help(editorState.isAnnotationPanelVisible
                  ? "Hide annotations panel (⌘])"
                  : "Show annotations panel (⌘])")
        }
    }

    private func scrollToSection(_ sectionId: String) {
        // Find section and get its start offset
        guard let section = editorState.sections.first(where: { $0.id == sectionId }) else { return }

        // Set the scroll offset - editors will react to this
        editorState.scrollTo(offset: section.startOffset)
    }

    private func updateSection(_ section: SectionViewModel) {
        // Save section metadata changes to database
        Task {
            do {
                try documentManager.saveSectionStatus(id: section.id, status: section.status)
                if let goal = section.wordGoal {
                    try documentManager.saveSectionWordGoal(id: section.id, goal: goal)
                }
                if !section.tags.isEmpty {
                    try documentManager.saveSectionTags(id: section.id, tags: section.tags)
                }
            } catch {
                print("[ContentView] Error saving section: \(error.localizedDescription)")
            }
        }
    }

    private func reorderSection(_ request: SectionReorderRequest) {
        print("[REORDER] === START ===")
        // swiftlint:disable:next line_length
        print("[REORDER] id=\(request.sectionId) target=\(request.targetSectionId ?? "nil") level=\(request.newLevel) parent=\(request.newParentId ?? "nil") subtree=\(request.isSubtreeDrag) children=\(request.childIds)")
        print("[REORDER] Current sections count: \(editorState.sections.count)")
        print("[REORDER] Section titles in order: \(editorState.sections.map { "\($0.title)[H\($0.headerLevel)]" })")

        sectionSyncService.cancelPendingSync()

        // Validate
        if request.newParentId == request.sectionId {
            print("[REORDER] ERROR: newParentId equals sectionId - circular reference prevented")
            return
        }
        guard let fromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else {
            print("[REORDER] ERROR: Section \(request.sectionId) not found in editorState.sections!")
            return
        }
        print("[REORDER] fromIndex=\(fromIndex)")

        // Use the target section ID passed from OutlineSidebar (stable across zoom/filtering)
        let targetSectionId = request.targetSectionId

        // Early return for self-drop at same position (no-op)
        if targetSectionId == request.sectionId {
            print("[REORDER] SKIP: Self-drop at same position")
            return
        }

        let sectionToMove = editorState.sections[fromIndex]
        let oldLevel = sectionToMove.headerLevel
        print("[REORDER] Moving section: '\(sectionToMove.title)' from index \(fromIndex), oldLevel=\(oldLevel)")

        if let targetId = targetSectionId,
           let targetSection = editorState.sections.first(where: { $0.id == targetId }) {
            print("[REORDER] Target section: '\(targetSection.title)' (insert AFTER this)")
        } else {
            print("[REORDER] Target section: nil (insert at beginning)")
        }

        // Branch: Subtree drag vs single-card drag
        if request.isSubtreeDrag && !request.childIds.isEmpty {
            reorderSubtree(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        } else {
            reorderSingleSection(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        }
    }

    /// Reorder a single section (original behavior, promotes orphaned children)
    private func reorderSingleSection(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId

        // Work with a local copy to batch all SwiftUI updates
        var sections = editorState.sections
        print("[REORDER-SINGLE] Working with local copy of \(sections.count) sections")

        // 1. Promote orphaned children (on local copy)
        print("[REORDER-SINGLE] Step 1: Promoting orphaned children...")
        promoteOrphanedChildrenInPlace(
            sections: &sections,
            movedSectionId: request.sectionId,
            targetSectionId: targetSectionId,
            oldLevel: oldLevel
        )

        // 2. Re-find section after promotions
        guard let currentFromIndex = sections.firstIndex(where: { $0.id == request.sectionId }) else {
            print("[REORDER-SINGLE] ERROR: Section disappeared after promotions!")
            return
        }
        print("[REORDER-SINGLE] Step 2: currentFromIndex after promotions = \(currentFromIndex)")

        // 3. Remove the section
        var removed = sections.remove(at: currentFromIndex)
        print("[REORDER-SINGLE] Step 3: Removed section '\(removed.title)' from index \(currentFromIndex)")

        // 4. Find insertion point
        var finalIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            finalIndex = targetIdx + 1
            print("[REORDER-SINGLE] Step 4: Found target at idx \(targetIdx), finalIndex = \(finalIndex)")
        } else {
            finalIndex = 0
            print("[REORDER-SINGLE] Step 4: No target, finalIndex = 0")
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
            print("[REORDER-SINGLE] Step 5: Updated level from \(oldLevel) to \(request.newLevel)")
        } else {
            removed = removed.withUpdates(parentId: request.newParentId)
        }

        // 6. Insert at calculated position
        sections.insert(removed, at: finalIndex)
        print("[REORDER-SINGLE] Step 6: Inserted '\(removed.title)' at finalIndex \(finalIndex)")

        // 7. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Reorder a subtree (parent + all children move together, levels adjusted relatively)
    private func reorderSubtree(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId
        let levelDelta = request.newLevel - oldLevel  // How much to shift all levels

        print("[REORDER-SUBTREE] levelDelta=\(levelDelta) (newLevel=\(request.newLevel) - oldLevel=\(oldLevel))")
        print("[REORDER-SUBTREE] Moving \(request.childIds.count + 1) sections together")

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
        print("[REORDER-SUBTREE] Step 1: Collected \(sectionsToMove.count) sections to move")

        // 2. Remove all sections being moved (in reverse order to maintain indices)
        let indicesToRemove = allIdsToMove.compactMap { id in
            sections.firstIndex(where: { $0.id == id })
        }.sorted().reversed()

        for idx in indicesToRemove {
            sections.remove(at: idx)
        }
        print("[REORDER-SUBTREE] Step 2: Removed \(allIdsToMove.count) sections from original positions")

        // 3. Find insertion point
        var insertionIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            insertionIndex = targetIdx + 1
            print("[REORDER-SUBTREE] Step 3: Found target at idx \(targetIdx), insertionIndex = \(insertionIndex)")
        } else {
            insertionIndex = 0
            print("[REORDER-SUBTREE] Step 3: No target, insertionIndex = 0")
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
                print("[REORDER-SUBTREE] Step 4: Parent '\(section.title)' H\(section.headerLevel) -> H\(newSectionLevel)")
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
                print("[REORDER-SUBTREE] Step 4: Child '\(section.title)' H\(section.headerLevel) -> H\(newSectionLevel)")
            }
        }

        // 5. Insert all sections at the insertion point
        for (offset, section) in adjustedSections.enumerated() {
            sections.insert(section, at: insertionIndex + offset)
        }
        print("[REORDER-SUBTREE] Step 5: Inserted \(adjustedSections.count) sections at index \(insertionIndex)")

        // 6. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Finalize section reorder - recalculate offsets, parent relationships, persist
    private func finalizeSectionReorder(sections: [SectionViewModel]) {
        var mutableSections = sections

        // Recalculate sort orders and offsets
        var currentOffset = 0
        for index in mutableSections.indices {
            mutableSections[index] = mutableSections[index].withUpdates(
                sortOrder: index,
                startOffset: currentOffset
            )
            currentOffset += mutableSections[index].markdownContent.count
        }
        print("[REORDER-FINALIZE] Recalculated sortOrders and offsets")

        // Single atomic update to trigger SwiftUI
        editorState.sections = mutableSections
        print("[REORDER-FINALIZE] Updated editorState.sections")
        print("[REORDER-FINALIZE] Final order: \(editorState.sections.map { "\($0.sortOrder):\($0.title)[H\($0.headerLevel)]" })")

        // Recalculate parent relationships and enforce hierarchy
        recalculateParentRelationships()
        enforceHierarchyConstraints()
        print("[REORDER-FINALIZE] Recalculated parent relationships and enforced hierarchy")

        // Rebuild document content (zoom-aware)
        rebuildDocumentContent()
        print("[REORDER-FINALIZE] Rebuilt document content")

        // Persist reordered sections to database
        print("[REORDER-FINALIZE] Dispatching persistReorderedSections()...")
        Task {
            await persistReorderedSections()
        }
        print("[REORDER] === END ===")
    }

    /// Persist current sections to database after reorder
    private func persistReorderedSections() async {
        print("[PERSIST] === START ===")
        print("[PERSIST] isObservationSuppressed: \(editorState.isObservationSuppressed)")

        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            print("[PERSIST] ERROR: Database or projectId is nil!")
            return
        }

        print("[PERSIST] Building changes for \(editorState.sections.count) sections")

        // Build change set for all sections with updated sortOrder and potentially new levels
        var changes: [SectionChange] = []

        for (index, viewModel) in editorState.sections.enumerated() {
            let updates = SectionUpdates(
                title: viewModel.title,
                headerLevel: viewModel.headerLevel,
                sortOrder: index,
                markdownContent: viewModel.markdownContent,
                startOffset: viewModel.startOffset,
                parentId: .some(viewModel.parentId)  // Use .some to explicitly set (even if nil)
            )
            changes.append(.update(id: viewModel.id, updates: updates))
            print("[PERSIST] Change \(index): '\(viewModel.title)' sortOrder=\(index), level=\(viewModel.headerLevel)")
        }

        do {
            try db.applySectionChanges(changes, for: pid)
            print("[PERSIST] SUCCESS: \(changes.count) changes applied to database")
            // ValueObservation will automatically update the sidebar
        } catch {
            print("[PERSIST] ERROR: \(error)")
        }
        print("[PERSIST] === END ===")
    }

    /// Promote orphaned children in-place on a local array (avoids multiple SwiftUI updates)
    /// Uses target section ID for stable position comparison
    private func promoteOrphanedChildrenInPlace(
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

    /// Rebuild document content based on zoom state (extracted for reuse)
    private func rebuildDocumentContent() {
        let sectionsToRebuild: [SectionViewModel]
        if let zoomedIds = editorState.zoomedSectionIds {
            sectionsToRebuild = editorState.sections
                .filter { zoomedIds.contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }
        } else {
            sectionsToRebuild = editorState.sections
        }

        editorState.content = sectionsToRebuild
            .map { section in
                var content = section.markdownContent
                if !content.hasSuffix("\n") { content += "\n" }
                return content
            }
            .joined()
    }

    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level
    private func recalculateParentRelationships() {
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
    private func findParentByLevel(at index: Int) -> String? {
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
    private func hasHierarchyViolations() -> Bool {
        Self.hasHierarchyViolations(in: editorState.sections)
    }

    /// Static version for use in closures
    private static func hasHierarchyViolations(in sections: [SectionViewModel]) -> Bool {
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
    private func enforceHierarchyConstraintsIfNeeded() {
        guard hasHierarchyViolations() else { return }
        enforceHierarchyConstraints()
        rebuildDocumentContent()
    }

    /// Static version for use in closures - enforces hierarchy on provided sections array
    private static func enforceHierarchyConstraintsStatic(
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

    /// Static version for use in closures - rebuilds document content from sections
    private static func rebuildDocumentContentStatic(editorState: EditorViewState) {
        let sectionsToRebuild: [SectionViewModel]
        if let zoomedIds = editorState.zoomedSectionIds {
            sectionsToRebuild = editorState.sections
                .filter { zoomedIds.contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }
        } else {
            sectionsToRebuild = editorState.sections
        }

        editorState.content = sectionsToRebuild
            .map { section in
                var content = section.markdownContent
                if !content.hasSuffix("\n") { content += "\n" }
                return content
            }
            .joined()
    }

    /// Async hierarchy enforcement with completion-based state clearing
    /// Uses contentState to block ValueObservation during enforcement, preventing race conditions
    @MainActor
    private static func enforceHierarchyAsync(
        editorState: EditorViewState,
        syncService: SectionSyncService
    ) async {
        // Set state to block observation updates during enforcement
        editorState.contentState = .hierarchyEnforcement
        defer {
            editorState.contentState = .idle
        }

        print("[HIERARCHY] Starting async enforcement")
        print("[HIERARCHY] Before: \(editorState.sections.map { "H\($0.headerLevel):\($0.title)" })")

        // Enforce hierarchy constraints
        enforceHierarchyConstraintsStatic(
            sections: &editorState.sections,
            syncService: syncService
        )

        print("[HIERARCHY] After enforcement: \(editorState.sections.map { "H\($0.headerLevel):\($0.title)" })")

        // Rebuild document content from corrected sections
        rebuildDocumentContentStatic(editorState: editorState)

        // Persist corrected sections to database (wait for completion)
        await persistEnforcedSections(editorState: editorState)

        print("[HIERARCHY] Enforcement complete, state reset to idle")
    }

    /// Persist enforced sections directly to database
    /// Called after hierarchy enforcement to ensure corrected levels are saved
    @MainActor
    private static func persistEnforcedSections(editorState: EditorViewState) async {
        guard let db = DocumentManager.shared.projectDatabase,
              let pid = DocumentManager.shared.projectId else {
            print("[HIERARCHY] Cannot persist: no database or project ID")
            return
        }

        print("[HIERARCHY] Persisting \(editorState.sections.count) enforced sections")

        var changes: [SectionChange] = []
        for (index, viewModel) in editorState.sections.enumerated() {
            let updates = SectionUpdates(
                headerLevel: viewModel.headerLevel,
                sortOrder: index,
                markdownContent: viewModel.markdownContent
            )
            changes.append(.update(id: viewModel.id, updates: updates))
        }

        do {
            try db.applySectionChanges(changes, for: pid)
            print("[HIERARCHY] Persisted \(changes.count) section updates")
        } catch {
            print("[HIERARCHY] Error persisting enforced sections: \(error)")
        }
    }

    /// Ensure no section is more than 1 level deeper than its predecessor
    /// Uses iterative transformation with already-processed predecessors for correct constraint checking
    private func enforceHierarchyConstraints() {
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

    @ViewBuilder
    private var detailView: some View {
        HSplitView {
            // Main editor area
            VStack(spacing: 0) {
                editorView
                StatusBar(editorState: editorState)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.editorBackground)

            // Annotation panel (conditionally shown)
            if editorState.isAnnotationPanelVisible {
                AnnotationPanel(
                    editorState: editorState,
                    onScrollToAnnotation: { offset in
                        editorState.scrollTo(offset: offset)
                    },
                    onToggleCompletion: { annotation in
                        toggleAnnotationCompletion(annotation)
                    },
                    onUpdateAnnotationText: { annotation, newText in
                        handleAnnotationTextUpdate(annotation, newText: newText)
                    }
                )
            }
        }
    }

    /// Toggle annotation completion and update both markdown and database
    private func toggleAnnotationCompletion(_ annotation: AnnotationViewModel) {
        // Toggle local state
        annotation.isCompleted.toggle()

        // Update markdown content
        editorState.content = annotationSyncService.updateTaskCompletion(
            in: editorState.content,
            at: annotation.charOffset,
            isCompleted: annotation.isCompleted
        )

        // Database will be updated via sync service when content changes
    }

    /// Handle annotation text update from sidebar editing
    private func handleAnnotationTextUpdate(_ annotation: AnnotationViewModel, newText: String) {
        // 1. Suppress sync to prevent feedback loop
        annotationSyncService.isSyncSuppressed = true

        // 2. Reconstruct markdown with new text
        let result = annotationSyncService.replaceAnnotationText(
            in: editorState.content,
            annotationId: annotation.id,
            oldCharOffset: annotation.charOffset,
            annotationType: annotation.type,
            oldText: annotation.text,
            newText: newText,
            isCompleted: annotation.isCompleted
        )

        // 3. Update database atomically (text + charOffset)
        if let db = documentManager.projectDatabase {
            do {
                try db.updateAnnotation(
                    id: annotation.id,
                    text: newText,
                    charOffset: result.newCharOffset
                )
            } catch {
                print("[ContentView] Error updating annotation: \(error.localizedDescription)")
            }
        }

        // 4. Update local view model
        annotation.text = newText
        annotation.charOffset = result.newCharOffset

        // 5. Push to editor
        editorState.content = result.markdown

        // 6. Re-enable sync after delay
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            annotationSyncService.isSyncSuppressed = false
        }
    }

    @ViewBuilder
    private var editorView: some View {
        // Wait for preload to complete before showing editor
        if !isEditorPreloadReady {
            // Minimal loading state - just a blank area with theme background
            Color.clear
                .task {
                    // Wait for preload with 2 second timeout
                    _ = await EditorPreloader.shared.waitUntilReady(timeout: 2.0)
                    isEditorPreloadReady = true
                }
        } else {
            switch editorState.editorMode {
            case .wysiwyg:
                MilkdownEditor(
                    content: $editorState.content,
                    focusModeEnabled: $editorState.focusModeEnabled,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    isResettingContent: $editorState.isResettingContent,
                    onContentChange: { _ in
                        // Content change handling - could trigger outline parsing here
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    }
                )
            case .source:
                CodeMirrorEditor(
                    content: $editorState.content,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    isResettingContent: $editorState.isResettingContent,
                    onContentChange: { _ in
                        // Content change handling - could trigger outline parsing here
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    }
                )
            }
        }
    }

    /// Initialize the project - configure for currently open project
    private func initializeProject() async {
        // Check if a project is already open (opened by FinalFinalApp)
        if documentManager.hasOpenProject {
            await configureForCurrentProject()
            return
        }

        // No project open - this shouldn't happen as FinalFinalApp handles launch state
        // but if it does, just wait for a project to be opened
        print("[ContentView] No project open at initialization")
    }

    /// Configure UI for the currently open project
    private func configureForCurrentProject() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId,
              let cid = documentManager.contentId else {
            return
        }

        // Configure sync services with database
        sectionSyncService.configure(database: db, projectId: pid)
        annotationSyncService.configure(database: db, contentId: cid)
        bibliographySyncService.configure(database: db, projectId: pid)
        autoBackupService.configure(database: db, projectId: pid)

        // Wire up hierarchy enforcement after sections are updated from database
        // This ensures slash commands that create new headings trigger rebalancing
        editorState.onSectionsUpdated = { [weak editorState, weak sectionSyncService] in
            guard let editorState = editorState,
                  let sectionSyncService = sectionSyncService else { return }
            // Skip during drag operations (which handle hierarchy separately)
            guard !sectionSyncService.isSyncSuppressed else { return }
            guard editorState.contentState == .idle else { return }

            // Check and enforce hierarchy constraints if violations exist
            if Self.hasHierarchyViolations(in: editorState.sections) {
                Task { @MainActor in
                    await Self.enforceHierarchyAsync(
                        editorState: editorState,
                        syncService: sectionSyncService
                    )
                }
            }
        }

        // Start reactive observation
        editorState.startObserving(database: db, projectId: pid)
        editorState.startObservingAnnotations(database: db, contentId: cid)

        // Load content
        do {
            let savedContent = try documentManager.loadContent()

            if let savedContent = savedContent, !savedContent.isEmpty {
                editorState.content = savedContent
            } else {
                // Empty project - set empty content
                editorState.content = ""
            }

            // Check if sections exist
            let existingSections = await sectionSyncService.loadSections()
            if existingSections.isEmpty && !editorState.content.isEmpty {
                await sectionSyncService.syncNow(editorState.content)
            }

            // Record initial content hash for Getting Started edit detection
            // This captures post-normalization content after sync
            if documentManager.isGettingStartedProject {
                // Wait for content to appear (max ~600ms instead of fixed 1000ms)
                var attempts = 0
                while attempts < 4 && editorState.content.isEmpty {
                    try? await Task.sleep(for: .milliseconds(150))
                    attempts += 1
                }
                documentManager.recordGettingStartedLoadedContent(editorState.content)
            }
        } catch {
            print("[ContentView] Failed to load content: \(error.localizedDescription)")
        }

        // Connect to Zotero (just verify it's available - search is on-demand)
        Task {
            await connectToZotero()
        }
    }

    /// Connect to Zotero (via Better BibTeX) - just verifies availability
    /// Search happens on-demand via JSON-RPC when user types /cite
    private func connectToZotero() async {
        let zotero = ZoteroService.shared

        do {
            try await zotero.connect()
            print("[ContentView] Zotero/BBT is available for citation search")
        } catch {
            print("[ContentView] Zotero connection failed: \(error.localizedDescription)")
            // Silent failure - Zotero is optional dependency
        }
    }

    /// Handle project opened notification
    private func handleProjectOpened() async {
        // Stop existing observation
        editorState.stopObserving()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        autoBackupService.reset()

        // Set flag to prevent polling from overwriting empty content during reset
        editorState.isResettingContent = true

        // Reset editor preload state so we wait for preload on new project
        isEditorPreloadReady = false

        // Reset state
        editorState.content = ""
        editorState.sections = []
        editorState.annotations = []
        editorState.zoomedSectionId = nil
        editorState.fullDocumentBeforeZoom = nil
        editorState.zoomedSectionIds = nil
        editorState.isCitationLibraryPushed = false

        // Configure for new project
        await configureForCurrentProject()

        // Clear the reset flag after project is configured
        editorState.isResettingContent = false
    }

    /// Handle project closed notification
    private func handleProjectClosed() {
        // Check if this is the Getting Started project with modifications
        if documentManager.isGettingStartedProject && documentManager.isGettingStartedModified() {
            showGettingStartedCloseAlert = true
            return
        }

        performProjectClose()
    }

    /// Actually close the project and reset state
    private func performProjectClose() {
        // Create auto-backup before closing if there are unsaved changes (not for Getting Started)
        if !documentManager.isGettingStartedProject {
            Task {
                await autoBackupService.projectWillClose()
            }
        }

        // Stop observation FIRST to prevent any further syncs
        editorState.stopObserving()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        autoBackupService.reset()

        // Reset zoom state (these don't trigger database writes)
        editorState.zoomedSectionId = nil
        editorState.fullDocumentBeforeZoom = nil
        editorState.zoomedSectionIds = nil

        // Clear sections, annotations and content (UI state only, observation is already stopped)
        editorState.sections = []
        editorState.annotations = []
        editorState.content = ""

        // Notify parent to show picker
        onProjectClosed?()
    }

    /// Handle "Create New Project" from Getting Started close alert
    private func handleCreateFromGettingStarted() {
        // Get current content before closing
        let currentContent = (try? documentManager.getCurrentContent()) ?? ""

        let savePanel = NSSavePanel()
        savePanel.title = "Save Your Work"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "Untitled"
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    try self.documentManager.newProject(at: url, title: title, initialContent: currentContent)
                    // No need to call onProjectOpened - we're replacing the current project
                    await self.handleProjectOpened()
                } catch {
                    print("[ContentView] Failed to create project from Getting Started: \(error)")
                }
            }
        }
    }

    // MARK: - Version History Handlers

    /// Handle save version command (Cmd+Shift+S)
    private func handleSaveVersion() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            print("[ContentView] Cannot save version: no project open")
            return
        }

        let name = saveVersionName.isEmpty ? nil : saveVersionName
        let service = SnapshotService(database: db, projectId: pid)

        do {
            if let versionName = name {
                let snapshot = try service.createManualSnapshot(name: versionName)
                print("[ContentView] Created manual snapshot: \(snapshot.displayName)")
            } else {
                let snapshot = try service.createAutoSnapshot()
                print("[ContentView] Created auto snapshot: \(snapshot.id)")
            }
        } catch {
            print("[ContentView] Failed to create snapshot: \(error)")
        }

        saveVersionName = ""
    }

    // MARK: - Integrity Alert Handlers

    /// Handle repair action from integrity alert
    /// Loops until all repairable issues are fixed or an unrepairable issue is encountered
    private func handleRepair(report: IntegrityReport) async {
        guard let url = pendingProjectURL else { return }

        var currentReport = report
        var repairAttempts = 0
        let maxRepairAttempts = 5  // Prevent infinite loops

        do {
            // Loop to repair all issues (some repairs reveal new issues)
            while currentReport.canAutoRepair && repairAttempts < maxRepairAttempts {
                repairAttempts += 1
                print("[ContentView] Repair attempt \(repairAttempts) for \(currentReport.issues.count) issue(s)")

                let result = try documentManager.repairProject(report: currentReport)
                print("[ContentView] Repair result: \(result.message)")

                guard result.success else {
                    // Repair failed - keep showing the alert with failure info
                    print("[ContentView] Repair failed for issues: \(result.failedIssues.map { $0.description })")
                    return
                }

                // Re-validate after repair to check for remaining/new issues
                currentReport = try documentManager.checkIntegrity(at: url)

                if currentReport.isHealthy {
                    break
                }
                // Loop continues if there are more repairable issues
            }

            if currentReport.isHealthy {
                try documentManager.openProject(at: url)
                await configureForCurrentProject()
                pendingProjectURL = nil
                integrityReport = nil
            } else if !currentReport.hasCriticalIssues {
                // Non-critical, non-repairable issues remain - force open with warning
                print("[ContentView] Opening with non-critical issues: \(currentReport.issues.map { $0.description })")
                try documentManager.forceOpenProject(at: url)
                await configureForCurrentProject()
                pendingProjectURL = nil
                integrityReport = nil
            } else {
                // Critical unrepairable issues remain - show updated alert
                integrityReport = currentReport
            }
        } catch {
            print("[ContentView] Repair failed: \(error.localizedDescription)")
            // Keep alert showing so user can cancel
        }
    }

    /// Handle "open anyway" action from integrity alert (unsafe)
    private func handleOpenAnyway(report: IntegrityReport) async {
        guard let url = pendingProjectURL else { return }

        print("[ContentView] Opening project despite integrity issues (user chose unsafe)")
        for issue in report.issues {
            print("[ContentView] Warning: \(issue.description)")
        }

        do {
            try documentManager.forceOpenProject(at: url)
            await configureForCurrentProject()
        } catch {
            print("[ContentView] Failed to force-open project: \(error.localizedDescription)")
        }

        pendingProjectURL = nil
        integrityReport = nil
    }

    /// Handle cancel action from integrity alert
    private func handleIntegrityCancel() {
        pendingProjectURL = nil
        // Could optionally open demo project or show welcome state
    }

}

// MARK: - Notification Extensions

extension View {
    /// Adds editor-related notification handlers
    func withEditorNotifications(editorState: EditorViewState, cursorRestore: Binding<CursorPosition?>) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
                editorState.toggleFocusMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode)) { _ in
                editorState.requestEditorModeToggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .didSaveCursorPosition)) { notification in
                if let position = notification.userInfo?["position"] as? CursorPosition {
                    cursorRestore.wrappedValue = position
                }
                editorState.toggleEditorMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleOutlineSidebar)) { _ in
                editorState.toggleOutlineSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationSidebar)) { _ in
                editorState.toggleAnnotationPanel()
            }
    }

    /// Adds file menu notification handlers
    @MainActor
    func withFileNotifications(
        editorState: EditorViewState,
        syncService: SectionSyncService,
        onOpened: @escaping () async -> Void,
        onClosed: @escaping () -> Void,
        onIntegrityError: @escaping (IntegrityReport, URL) -> Void
    ) -> some View {
        self
            // Note: .closeProject, .newProject, .openProject are handled at FinalFinalApp level
            // because those handlers don't need view state and the App-level handlers are stable
            .onReceive(NotificationCenter.default.publisher(for: .saveProject)) { _ in
                FileOperations.handleSaveProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importMarkdown)) { _ in
                FileOperations.handleImportMarkdown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportMarkdown)) { _ in
                FileOperations.handleExportMarkdown(content: editorState.content)
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { _ in
                Task { await onOpened() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidCreate)) { notification in
                Task {
                    await onOpened()
                    if let content = notification.userInfo?["content"] as? String {
                        editorState.content = content
                        await syncService.syncNow(content)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidClose)) { _ in
                onClosed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectIntegrityError)) { notification in
                if let report = notification.userInfo?["report"] as? IntegrityReport,
                   let url = notification.userInfo?["url"] as? URL {
                    onIntegrityError(report, url)
                }
            }
    }

    /// Adds version history notification handlers
    @MainActor
    func withVersionNotifications(
        onSaveVersion: @escaping () -> Void,
        onShowHistory: @escaping () -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .saveVersion)) { _ in
                onSaveVersion()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showVersionHistory)) { _ in
                onShowHistory()
            }
    }

    /// Adds content change observers for sync services
    @MainActor
    func withContentObservers(
        editorState: EditorViewState,
        sectionSyncService: SectionSyncService,
        annotationSyncService: AnnotationSyncService,
        bibliographySyncService: BibliographySyncService,
        autoBackupService: AutoBackupService,
        documentManager: DocumentManager
    ) -> some View {
        self
            .onChange(of: editorState.content) { _, newValue in
                guard editorState.contentState == .idle else { return }
                sectionSyncService.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds)
                annotationSyncService.contentChanged(newValue)

                // Check for citation changes and update bibliography if needed
                if let projectId = documentManager.projectId {
                    let citekeys = BibliographySyncService.extractCitekeys(from: newValue)
                    if !citekeys.isEmpty {
                        bibliographySyncService.checkAndUpdateBibliography(
                            currentCitekeys: citekeys,
                            projectId: projectId
                        )
                    }
                }

                // Trigger auto-backup timer on content change
                autoBackupService.contentDidChange()
            }
            .onChange(of: editorState.zoomedSectionId) { _, newValue in
                sectionSyncService.isContentZoomed = (newValue != nil)
            }
            .onChange(of: editorState.annotationDisplayModes) { _, newModes in
                // Notify editors when display modes change
                NotificationCenter.default.post(
                    name: .annotationDisplayModesChanged,
                    object: nil,
                    userInfo: [
                        "modes": newModes,
                        "isPanelOnly": editorState.isPanelOnlyMode,
                        "hideCompletedTasks": editorState.hideCompletedTasks
                    ]
                )
            }
            .onChange(of: editorState.isPanelOnlyMode) { _, newValue in
                // Notify editors when panel-only mode changes
                NotificationCenter.default.post(
                    name: .annotationDisplayModesChanged,
                    object: nil,
                    userInfo: [
                        "modes": editorState.annotationDisplayModes,
                        "isPanelOnly": newValue,
                        "hideCompletedTasks": editorState.hideCompletedTasks
                    ]
                )
            }
            .onChange(of: editorState.hideCompletedTasks) { _, newValue in
                // Notify editors when hide completed tasks filter changes
                NotificationCenter.default.post(
                    name: .annotationDisplayModesChanged,
                    object: nil,
                    userInfo: [
                        "modes": editorState.annotationDisplayModes,
                        "isPanelOnly": editorState.isPanelOnlyMode,
                        "hideCompletedTasks": newValue
                    ]
                )
            }
    }

    /// Adds sidebar visibility sync observers
    @MainActor
    func withSidebarSync(
        editorState: EditorViewState,
        sidebarVisibility: Binding<NavigationSplitViewVisibility>
    ) -> some View {
        self
            .onChange(of: editorState.isOutlineSidebarVisible) { _, newValue in
                // Sync editorState -> NavigationSplitView (from keyboard shortcut/menu)
                sidebarVisibility.wrappedValue = newValue ? .all : .detailOnly
            }
            .onChange(of: sidebarVisibility.wrappedValue) { _, newValue in
                // Sync NavigationSplitView -> editorState (from native chevron)
                editorState.isOutlineSidebarVisible = (newValue != .detailOnly)
            }
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
