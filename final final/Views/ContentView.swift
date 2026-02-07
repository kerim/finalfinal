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

/// Toast notification shown when entering focus mode, auto-dismisses after 3 seconds
struct FocusModeToast: View {
    @Binding var isShowing: Bool

    var body: some View {
        if isShowing {
            Text("Press Esc or Cmd+Shift+F to exit focus mode")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation {
                        isShowing = false
                    }
                }
        }
    }
}

// swiftlint:disable:next type_body_length
struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(VersionHistoryCoordinator.self) private var versionHistoryCoordinator

    /// Observe appearance settings to trigger editor CSS updates when settings change
    @State private var appearanceManager = AppearanceSettingsManager.shared
    @Environment(\.openWindow) private var openWindow
    @State private var editorState = EditorViewState()
    @State private var cursorPositionToRestore: CursorPosition?
    @State private var sectionSyncService = SectionSyncService()
    @State private var blockSyncService = BlockSyncService()
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

    /// Find bar state
    @State private var findBarState = FindBarState()

    /// Callback when project is closed (to return to picker)
    var onProjectClosed: (() -> Void)?

    /// Use the shared DocumentManager for project lifecycle
    private var documentManager: DocumentManager { DocumentManager.shared }

    /// Theme CSS with appearance overrides - reading cssOverrides creates the SwiftUI dependency
    /// so that when any appearance setting changes, editors get updated
    private var currentThemeCSS: String {
        // Read cssOverrides to create dependency on ALL settings (not just hasOverrides)
        // This ensures any setting change triggers an editor update
        let overrides = appearanceManager.cssOverrides
        let themeCSS = themeManager.currentTheme.cssVariables
        if overrides.isEmpty {
            return themeCSS
        }
        return themeCSS + "\n" + overrides
    }

    var body: some View {
        mainContentView
            .withEditorNotifications(editorState: editorState, cursorRestore: $cursorPositionToRestore, sectionSyncService: sectionSyncService, findBarState: findBarState)
            .withFindNotifications(findBarState: findBarState)
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
            .onReceive(NotificationCenter.default.publisher(for: .bibliographySectionChanged)) { _ in
                // Bibliography section was updated in the database - rebuild editor content
                // Skip if zoomed into a section (bibliography update only affects full document view)
                guard editorState.zoomedSectionId == nil else { return }
                // Skip during any content transition (including editor switch)
                guard editorState.contentState == .idle else { return }
                editorState.contentState = .bibliographyUpdate
                blockSyncService.isSyncSuppressed = true
                rebuildDocumentContent()
                editorState.contentState = .idle
                // Push block IDs after bibliography rebuild
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await blockSyncService.pushBlockIds()
                    // pushBlockIds' defer clears isSyncSuppressed
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didZoomOut)) { _ in
                // Re-sync annotations with full document content after zoom-out.
                // During zoom, annotation reconciliation deletes annotations outside the zoomed
                // subset. Milkdown restores them via content normalization triggering onChange,
                // but CodeMirror returns content verbatim so onChange never fires.
                annotationSyncService.contentChanged(editorState.content)

                // Zoom-out completed - trigger bibliography sync with full document content
                // Citations added during zoom need to be processed now
                guard let projectId = documentManager.projectId else { return }
                let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
                bibliographySyncService.checkAndUpdateBibliography(
                    currentCitekeys: citekeys,
                    projectId: projectId
                )
            }
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
            .overlay(alignment: .top) {
                FocusModeToast(isShowing: $editorState.showFocusModeToast)
                    .padding(.top, 60)
            }
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
        // Hide window toolbar in focus mode for distraction-free writing
        .toolbar(editorState.focusModeEnabled ? .hidden : .visible, for: .windowToolbar)
        .task {
            AppDelegate.shared?.editorState = editorState
            await initializeProject()

            // Restore focus mode from previous session if needed
            // Wait 500ms for window to stabilize before entering full screen
            if editorState.focusModeEnabled && editorState.preFocusModeState == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Re-enter focus mode to capture fresh pre-state and apply full screen
                editorState.focusModeEnabled = false  // Reset first
                await editorState.enterFocusMode()
            }
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
                        blockSyncService.isSyncSuppressed = true
                        Task {
                            await editorState.zoomOut()
                            await blockSyncService.pushBlockIds()
                        }
                    }
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                zoomedSectionId: $editorState.zoomedSectionId,
                zoomedSectionIds: editorState.zoomedSectionIds,
                documentGoal: $editorState.documentGoal,
                documentGoalType: $editorState.documentGoalType,
                excludeBibliography: $editorState.excludeBibliography,
                onScrollToSection: { sectionId in
                    scrollToSection(sectionId)
                },
                onSectionUpdated: { section in
                    updateSection(section)
                },
                onSectionReorder: { request in
                    reorderSection(request)
                },
                onZoomToSection: { sectionId, mode in
                    findBarState.clearSearch()
                    blockSyncService.isSyncSuppressed = true
                    Task {
                        await editorState.zoomToSection(sectionId, mode: mode)
                        await blockSyncService.pushBlockIds(for: editorState.zoomedBlockRange)
                        // pushBlockIds' defer clears isSyncSuppressed
                    }
                },
                onZoomOut: {
                    findBarState.clearSearch()
                    blockSyncService.isSyncSuppressed = true
                    Task {
                        await editorState.zoomOut()
                        await blockSyncService.pushBlockIds()
                        // pushBlockIds' defer clears isSyncSuppressed
                    }
                },
                onDragStarted: {
                    editorState.isObservationSuppressed = true
                    sectionSyncService.isSyncSuppressed = true
                    sectionSyncService.cancelPendingSync()
                    blockSyncService.isSyncSuppressed = true
                },
                onDragEnded: {
                    editorState.isObservationSuppressed = false
                    sectionSyncService.isSyncSuppressed = false
                    blockSyncService.isSyncSuppressed = false
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

    private func updateSection(_ section: SectionViewModel) {
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

    private func reorderSection(_ request: SectionReorderRequest) {
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
    private func reorderSingleSection(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
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
    private func reorderSubtree(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
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
    private func finalizeSectionReorder(sections: [SectionViewModel]) {
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

        // Rebuild document content for immediate visual feedback
        rebuildDocumentContent()

        // Cancel any previous persist task (handles rapid successive reorders)
        editorState.currentPersistTask?.cancel()
        editorState.currentPersistTask = Task {
            await persistReorderedBlocks()          // Atomic block reorder (headings + body)
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
    private func persistReorderedBlocks() async {
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
    private func persistReorderedBlocks_legacySections() async {
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

    /// Rebuild document content from block database
    /// For zoom state, fetches only the zoomed range; otherwise fetches all blocks
    private func rebuildDocumentContent() {
        #if DEBUG
        print("[rebuildDocumentContent] Called. zoomed=\(editorState.zoomedSectionIds != nil), contentState=\(editorState.contentState)")
        #endif
        // Guard against rebuilding during editor transition
        guard editorState.contentState != .editorTransition else {
            return
        }
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else { return }

        do {
            let allBlocks: [Block]
            if let zoomedIds = editorState.zoomedSectionIds {
                // When zoomed, only include blocks in the zoomed range
                let blocks = try db.fetchBlocks(projectId: pid)
                // Filter to blocks that fall within zoomed heading ranges
                allBlocks = filterBlocksForZoom(blocks, zoomedIds: zoomedIds)
            } else {
                allBlocks = try db.fetchBlocks(projectId: pid)
            }

            editorState.content = BlockParser.assembleMarkdown(from: allBlocks)

            // Update sourceContent for CodeMirror (when in source mode)
            updateSourceContentIfNeeded()
        } catch {
            print("[ContentView] Error rebuilding content from blocks: \(error)")
        }
    }

    /// Filter blocks to only those within zoomed heading ranges
    private func filterBlocksForZoom(_ blocks: [Block], zoomedIds: Set<String>) -> [Block] {
        Self.filterBlocksForZoomStatic(blocks, zoomedIds: zoomedIds)
    }

    /// Static version of filterBlocksForZoom for use from static methods
    private static func filterBlocksForZoomStatic(_ blocks: [Block], zoomedIds: Set<String>) -> [Block] {
        let sortedBlocks = blocks.sorted { $0.sortOrder < $1.sortOrder }
        var includeBlocks: [Block] = []
        var inZoomedRange = false
        var currentZoomedLevel: Int?

        for block in sortedBlocks {
            if block.isOutlineHeading || block.isPseudoSection {
                if zoomedIds.contains(block.id) {
                    inZoomedRange = true
                    currentZoomedLevel = block.headingLevel
                    includeBlocks.append(block)
                    continue
                } else if inZoomedRange {
                    if let level = currentZoomedLevel, let blockLevel = block.headingLevel, blockLevel <= level {
                        inZoomedRange = false
                        currentZoomedLevel = nil
                        continue
                    }
                }
            }

            if inZoomedRange && !block.isBibliography {
                includeBlocks.append(block)
            }
        }

        return includeBlocks
    }

    /// Updates sourceContent from current content when in source mode
    /// Recalculates section offsets and injects anchors/bibliography markers
    private func updateSourceContentIfNeeded() {
        guard editorState.editorMode == .source else { return }

        // Get non-bibliography sections in sort order
        let sectionsForAnchors = editorState.sections
            .filter { !$0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }

        // Recalculate offsets for anchor injection
        var adjustedSections: [SectionViewModel] = []
        var adjustedOffset = 0
        for section in sectionsForAnchors {
            adjustedSections.append(section.withUpdates(startOffset: adjustedOffset))
            adjustedOffset += section.markdownContent.count
            if !section.markdownContent.hasSuffix("\n") {
                adjustedOffset += 1
            }
        }

        let withAnchors = sectionSyncService.injectSectionAnchors(
            markdown: editorState.content,
            sections: adjustedSections
        )
        editorState.sourceContent = sectionSyncService.injectBibliographyMarker(
            markdown: withAnchors,
            sections: editorState.sections
        )
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

    /// Static version for use in closures - rebuilds document content from DB blocks
    /// Reads ALL blocks from database (which now has correct sort orders after persist)
    /// and assembles markdown. Respects zoom state.
    private static func rebuildDocumentContentStatic(editorState: EditorViewState) {
        #if DEBUG
        print("[rebuildDocumentContentStatic] Called. zoomed=\(editorState.zoomedSectionIds != nil), sections=\(editorState.sections.count)")
        #endif
        guard let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId else { return }

        do {
            let allBlocks = try db.fetchBlocks(projectId: pid)

            if let zoomedIds = editorState.zoomedSectionIds {
                let filtered = filterBlocksForZoomStatic(allBlocks, zoomedIds: zoomedIds)
                editorState.content = BlockParser.assembleMarkdown(from: filtered)
            } else {
                editorState.content = BlockParser.assembleMarkdown(from: allBlocks)
            }
        } catch {
            print("[ContentView] Error rebuilding content from blocks: \(error)")
        }
    }

    /// Async hierarchy enforcement with completion-based state clearing
    /// Uses contentState to block ValueObservation during enforcement, preventing race conditions.
    /// Order: enforce constraints → persist to DB (all blocks) → rebuild from DB
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
    private static func persistEnforcedSections(editorState: EditorViewState) async {
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
                // Find bar (shown above editor)
                if findBarState.isVisible {
                    FindBarView(state: findBarState)
                }

                editorView
                // Hide status bar in focus mode for distraction-free writing
                if !editorState.focusModeEnabled {
                    StatusBar(editorState: editorState)
                }
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
            // Toggle between MilkdownEditor (WYSIWYG) and CodeMirrorEditor (source)
            // Anchors are injected when switching to source, extracted when switching back
            if editorState.editorMode == .wysiwyg {
                MilkdownEditor(
                    content: $editorState.content,
                    focusModeEnabled: $editorState.focusModeEnabled,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    themeCSS: currentThemeCSS,
                    onContentChange: { _ in
                        // Content change handling - could trigger outline parsing here
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onContentAcknowledged: {
                        // Called when WebView confirms content was set
                        // Used for acknowledgement-based synchronization during zoom
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        // Configure BlockSyncService with the WebView
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            blockSyncService.configure(database: db, projectId: pid, webView: webView)
                            // Push block IDs after content is set, then start polling
                            Task {
                                await blockSyncService.pushBlockIds()
                                blockSyncService.startPolling()
                            }
                        }
                    }
                )
            } else {
                CodeMirrorEditor(
                    content: $editorState.sourceContent,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    themeCSS: currentThemeCSS,
                    onContentChange: { newContent in
                        // Update sourceContent with raw content (including anchors)
                        // This keeps anchors in sync for mode switch
                        editorState.sourceContent = newContent

                        // Strip anchors and update content for sync/sidebar
                        let cleanContent = sectionSyncService.stripSectionAnchors(from: newContent)
                        editorState.content = cleanContent
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
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

        // Inject sectionSyncService reference for zoom sourceContent updates
        editorState.sectionSyncService = sectionSyncService

        // Wire up hierarchy enforcement after sections are updated from database
        // This ensures slash commands that create new headings trigger rebalancing
        editorState.onSectionsUpdated = { [weak editorState, weak sectionSyncService, weak blockSyncService] in
            guard let editorState = editorState,
                  let sectionSyncService = sectionSyncService else { return }

            #if DEBUG
            print("[onSectionsUpdated] contentState=\(editorState.contentState), syncSuppressed=\(sectionSyncService.isSyncSuppressed), zoomed=\(editorState.zoomedSectionIds != nil), hasViolations=\(Self.hasHierarchyViolations(in: editorState.sections))")
            #endif

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
                    // Wait for WebView to process new content before pushing IDs
                    try? await Task.sleep(for: .milliseconds(100))
                    if let blockSyncService = blockSyncService {
                        if let range = editorState.zoomedBlockRange {
                            try? await blockSyncService.pushBlockIds(for: range)
                        } else {
                            try? await blockSyncService.pushBlockIds()
                        }
                    }
                }
            }
        }

        // Check and normalize duplicate sort orders BEFORE starting observation
        do {
            let existingBlocks = try db.fetchBlocks(projectId: pid)
            if !existingBlocks.isEmpty {
                let sortOrders = existingBlocks.map { $0.sortOrder }
                if Set(sortOrders).count < sortOrders.count {
                    #if DEBUG
                    print("[ContentView] Duplicate sortOrders detected (\(sortOrders.count) blocks, \(Set(sortOrders).count) unique). Normalizing...")
                    #endif
                    try db.normalizeSortOrders(projectId: pid)
                }
            }
        } catch {
            print("[ContentView] Error checking/normalizing sort orders: \(error)")
        }

        // Start reactive observation (now uses blocks internally)
        editorState.startObserving(database: db, projectId: pid)
        editorState.startObservingAnnotations(database: db, contentId: cid)

        // Load document goal settings
        if let goalSettings = try? documentManager.loadDocumentGoalSettings() {
            editorState.documentGoal = goalSettings.goal
            editorState.documentGoalType = goalSettings.goalType
            editorState.excludeBibliography = goalSettings.excludeBibliography
        }

        // Load content from blocks (or fall back to legacy content table)
        do {
            let existingBlocks = try db.fetchBlocks(projectId: pid)

            if !existingBlocks.isEmpty {
                // Blocks exist - assemble markdown from blocks
                editorState.content = BlockParser.assembleMarkdown(from: existingBlocks)
                updateSourceContentIfNeeded()
            } else {
                // No blocks yet - load from legacy content table and parse into blocks
                let savedContent = try documentManager.loadContent()

                if let savedContent = savedContent, !savedContent.isEmpty {
                    let cleanContent = sectionSyncService.stripBibliographyMarker(from: savedContent)
                    editorState.content = cleanContent
                    updateSourceContentIfNeeded()

                    // Parse content into blocks for the new system
                    // Preserve existing section metadata if available
                    let existingSections = try db.fetchSections(projectId: pid)
                    var metadata: [String: SectionMetadata] = [:]
                    for section in existingSections {
                        metadata[section.title] = SectionMetadata(from: section)
                    }

                    let blocks = BlockParser.parse(
                        markdown: cleanContent,
                        projectId: pid,
                        existingSectionMetadata: metadata.isEmpty ? nil : metadata
                    )
                    try db.replaceBlocks(blocks, for: pid)
                } else {
                    editorState.content = ""
                    updateSourceContentIfNeeded()
                }
            }

            // Record initial content hash for Getting Started edit detection
            if documentManager.isGettingStartedProject {
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
        // Stop existing observation and services
        editorState.stopObserving()
        blockSyncService.stopPolling()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        autoBackupService.reset()

        // Set flag to prevent polling from overwriting empty content during reset
        editorState.isResettingContent = true

        // REMOVED: isEditorPreloadReady = false — WebView stays alive to avoid blank screen

        // Reset JS-side transient state (undo history, CAYW, search, block IDs)
        findBarState.activeWebView?.evaluateJavaScript(
            "window.FinalFinal.resetForProjectSwitch()"
        ) { _, _ in }

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

        // Configure for new project
        await configureForCurrentProject()

        // Reconfigure BlockSyncService with new DB (weak WebView ref still valid)
        if editorState.editorMode == .wysiwyg,
           let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            blockSyncService.reconfigure(database: db, projectId: pid)
            Task {
                await blockSyncService.pushBlockIds()
                blockSyncService.startPolling()
            }
        }

        // Clear the reset flag after project is configured
        // This triggers updateNSView → shouldPushContent sees new content → pushes it
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

        // Stop observation and services FIRST to prevent any further syncs
        editorState.stopObserving()
        blockSyncService.stopPolling()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        autoBackupService.reset()

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

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
    func withEditorNotifications(
        editorState: EditorViewState,
        cursorRestore: Binding<CursorPosition?>,
        sectionSyncService: SectionSyncService,
        findBarState: FindBarState
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
                editorState.toggleFocusMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode)) { _ in
                // Clear find bar state when switching editors
                findBarState.clearSearch()

                // Toggle between WYSIWYG and Source mode with anchor injection/extraction
                if editorState.editorMode == .wysiwyg {
                    // Switching TO source mode - inject anchors
                    editorState.contentState = .editorTransition

                    // When zoomed, only inject anchors for zoomed sections
                    let sectionsToInject: [SectionViewModel]
                    if let zoomedIds = editorState.zoomedSectionIds {
                        sectionsToInject = editorState.sections.filter { zoomedIds.contains($0.id) }
                    } else {
                        sectionsToInject = editorState.sections
                    }

                    // Recalculate offsets relative to current content (not full document)
                    var adjustedSections: [SectionViewModel] = []
                    var currentOffset = 0
                    for section in sectionsToInject.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                        adjustedSections.append(section.withUpdates(startOffset: currentOffset))
                        currentOffset += section.markdownContent.count
                    }

                    let withAnchors = sectionSyncService.injectSectionAnchors(
                        markdown: editorState.content,
                        sections: adjustedSections
                    )
                    // Also inject bibliography marker for source mode
                    let withBibMarker = sectionSyncService.injectBibliographyMarker(
                        markdown: withAnchors,
                        sections: sectionsToInject
                    )
                    editorState.sourceContent = withBibMarker
                    editorState.toggleEditorMode()
                    editorState.contentState = .idle
                } else {
                    // Switching FROM source mode TO WYSIWYG - set state BEFORE flush
                    editorState.contentState = .editorTransition
                    editorState.flushCodeMirrorSyncIfNeeded()

                    // Extract anchors and strip bibliography marker
                    let (cleaned, anchors) = sectionSyncService.extractSectionAnchors(
                        markdown: editorState.sourceContent
                    )
                    editorState.sourceAnchors = anchors
                    // Also strip bibliography marker since Milkdown shouldn't see it
                    editorState.content = sectionSyncService.stripBibliographyMarker(from: cleaned)
                    editorState.toggleEditorMode()

                    // CRITICAL: Delay returning to .idle to give Milkdown time to initialize
                    // Milkdown's first few polls can return corrupted content (missing # from headers)
                    // Keep .editorTransition active to suppress polling during this initialization window
                    // The 1.5s delay covers: WebView load + FinalFinal init + first stable poll cycle
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        editorState.contentState = .idle
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didSaveCursorPosition)) { notification in
                // Handle cursor position restoration during mode switch
                if let position = notification.userInfo?["position"] as? CursorPosition {
                    cursorRestore.wrappedValue = position
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleOutlineSidebar)) { _ in
                editorState.toggleOutlineSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationSidebar)) { _ in
                editorState.toggleAnnotationPanel()
            }
    }

    /// Adds find-related notification handlers
    func withFindNotifications(
        findBarState: FindBarState
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .showFindBar)) { notification in
                let showReplace = notification.userInfo?["showReplace"] as? Bool ?? false
                findBarState.show(withReplace: showReplace)
            }
            .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
                if findBarState.isVisible {
                    findBarState.findNext()
                } else {
                    findBarState.show()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
                if findBarState.isVisible {
                    findBarState.findPrevious()
                } else {
                    findBarState.show()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .useSelectionForFind)) { _ in
                findBarState.useSelectionForFind()
                if !findBarState.isVisible {
                    findBarState.show()
                }
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
                        // Parse initial content into blocks
                        if let db = DocumentManager.shared.projectDatabase,
                           let pid = DocumentManager.shared.projectId {
                            let blocks = BlockParser.parse(markdown: content, projectId: pid)
                            try? db.replaceBlocks(blocks, for: pid)
                        }
                        // Also sync to legacy sections (until fully retired)
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
                // BlockSyncService handles content -> block DB sync via polling
                // SectionSyncService contentChanged still needed for legacy section sync during transition
                annotationSyncService.contentChanged(newValue)

                // When in source mode, re-parse blocks (BlockSyncService only works with Milkdown)
                if editorState.editorMode == .source && !newValue.isEmpty {
                    if editorState.zoomedSectionId == nil {
                        // Non-zoomed: full document re-parse via replaceBlocks()
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            editorState.blockReparseTask?.cancel()
                            editorState.blockReparseTask = Task {
                                try? await Task.sleep(for: .milliseconds(1000))
                                guard !Task.isCancelled else { return }
                                guard editorState.contentState == .idle,
                                      editorState.editorMode == .source,
                                      editorState.zoomedSectionId == nil else { return }
                                let existing = try? db.fetchBlocks(projectId: pid)
                                var metadata: [String: SectionMetadata] = [:]
                                for block in existing ?? [] where block.blockType == .heading {
                                    metadata[block.textContent] = SectionMetadata(
                                        status: block.status,
                                        tags: block.tags?.isEmpty == false ? block.tags : nil,
                                        wordGoal: block.wordGoal
                                    )
                                }
                                let blocks = BlockParser.parse(
                                    markdown: newValue,
                                    projectId: pid,
                                    existingSectionMetadata: metadata.isEmpty ? nil : metadata
                                )
                                try? db.replaceBlocks(blocks, for: pid)
                            }
                        }
                    } else if editorState.zoomedBlockRange != nil {
                        // Zoomed: scoped re-parse via flushCodeMirrorSyncIfNeeded()
                        editorState.blockReparseTask?.cancel()
                        editorState.blockReparseTask = Task {
                            try? await Task.sleep(for: .milliseconds(1000))
                            guard !Task.isCancelled, editorState.contentState == .idle,
                                  editorState.editorMode == .source else { return }
                            editorState.flushCodeMirrorSyncIfNeeded()
                        }
                    }
                }

                // Skip bibliography sync when zoomed - we don't have full document context
                // Bibliography will be synced when user zooms out and full content is rebuilt
                guard editorState.zoomedSectionId == nil else { return }

                // Check for citation changes and update bibliography if needed
                // Always call even when citekeys is empty - this triggers bibliography removal
                if let projectId = documentManager.projectId {
                    let citekeys = BibliographySyncService.extractCitekeys(from: newValue)
                    bibliographySyncService.checkAndUpdateBibliography(
                        currentCitekeys: citekeys,
                        projectId: projectId
                    )
                }

                // Trigger auto-backup timer on content change
                autoBackupService.contentDidChange()
            }
            .onChange(of: editorState.editorMode) { _, _ in
                editorState.blockReparseTask?.cancel()
                editorState.blockReparseTask = nil
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
            // Document goal settings persistence
            .onChange(of: editorState.documentGoal) { _, _ in
                saveDocumentGoalSettings(editorState: editorState, documentManager: documentManager)
            }
            .onChange(of: editorState.documentGoalType) { _, _ in
                saveDocumentGoalSettings(editorState: editorState, documentManager: documentManager)
            }
            .onChange(of: editorState.excludeBibliography) { _, _ in
                saveDocumentGoalSettings(editorState: editorState, documentManager: documentManager)
            }
    }

    /// Helper to save document goal settings when any of them change
    @MainActor
    private func saveDocumentGoalSettings(editorState: EditorViewState, documentManager: DocumentManager) {
        do {
            try documentManager.saveDocumentGoalSettings(
                goal: editorState.documentGoal,
                goalType: editorState.documentGoalType,
                excludeBibliography: editorState.excludeBibliography
            )
        } catch {
            print("[ContentView] Error saving document goal settings: \(error.localizedDescription)")
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
