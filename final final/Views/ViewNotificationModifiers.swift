//
//  ViewNotificationModifiers.swift
//  final final
//
//  View extension modifiers for notification handling, content observers, and sidebar sync.
//

import SwiftUI

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
            .onReceive(NotificationCenter.default.publisher(for: .spellcheckTypeToggled)) { _ in
                // Sync from UserDefaults (written by @AppStorage in Commands)
                editorState.isSpellingEnabled = UserDefaults.standard.object(forKey: "isSpellingEnabled") == nil
                    ? true : UserDefaults.standard.bool(forKey: "isSpellingEnabled")
                editorState.isGrammarEnabled = UserDefaults.standard.object(forKey: "isGrammarEnabled") == nil
                    ? true : UserDefaults.standard.bool(forKey: "isGrammarEnabled")

                let anyEnabled = editorState.isSpellingEnabled || editorState.isGrammarEnabled
                NotificationCenter.default.post(
                    name: .spellcheckStateChanged,
                    object: nil,
                    userInfo: ["enabled": anyEnabled]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode)) { _ in
                // Clear find bar state when switching editors
                findBarState.clearSearch()

                // Toggle between WYSIWYG and Source mode with anchor injection/extraction
                if editorState.editorMode == .wysiwyg {
                    // Switching TO source mode - inject anchors
                    editorState.contentState = .editorTransition
                    DebugLog.log(.editor, "[SWITCH→CM] Starting. content length=\(editorState.content.count)")

                    // When zoomed, only inject anchors for zoomed sections
                    let sectionsToInject: [SectionViewModel]
                    if let zoomedIds = editorState.zoomedSectionIds {
                        sectionsToInject = editorState.sections.filter { zoomedIds.contains($0.id) }
                    } else {
                        sectionsToInject = editorState.sections
                    }

                    // Flush editor content to blocks DB before computing offsets.
                    // Without this, recently-inserted nodes (e.g. images via editor-first
                    // approach) may not be in the blocks table yet, causing wrong offsets
                    // and anchor injection corruption.
                    editorState.flushContentToDatabase()
                    DebugLog.log(.editor, "[SWITCH→CM] After flush")

                    // Compute offsets from blocks (same data that produced editorState.content)
                    var adjustedSections: [SectionViewModel] = []
                    if let db = editorState.projectDatabase,
                       let pid = editorState.currentProjectId {
                        do {
                            let fetchedBlocks: [Block]
                            if let zoomedIds = editorState.zoomedSectionIds {
                                let allBlocks = try db.fetchBlocks(projectId: pid)
                                fetchedBlocks = ContentView.filterBlocksForZoomStatic(
                                    allBlocks, zoomedIds: zoomedIds,
                                    zoomedBlockRange: editorState.zoomedBlockRange)
                            } else {
                                fetchedBlocks = try db.fetchBlocks(projectId: pid)
                            }
                            DebugLog.log(.editor, "[SWITCH→CM] Fetched \(fetchedBlocks.count) blocks")
                            let sorted = fetchedBlocks.sorted { a, b in
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
                            for section in sectionsToInject.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                                if let off = blockOffset[section.id] {
                                    adjustedSections.append(section.withUpdates(startOffset: off))
                                }
                            }
                            DebugLog.log(.editor, "[SWITCH→CM] Sections with offsets: \(adjustedSections.count)")
                        } catch {
                            DebugLog.log(.editor, "[SWITCH→CM] ERROR fetching blocks: \(error)")
                        }
                    }

                    let withAnchors = sectionSyncService.injectSectionAnchors(
                        markdown: editorState.content,
                        sections: adjustedSections
                    )
                    DebugLog.log(.editor, "[SWITCH→CM] After anchors: length=\(withAnchors.count)")
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
                    DebugLog.log(.editor, "[SWITCH→MW] Starting. sourceContent length=\(editorState.sourceContent.count)")
                    editorState.flushContentToDatabase()

                    // Extract anchors and strip bibliography marker
                    let (cleaned, anchors) = sectionSyncService.extractSectionAnchors(
                        markdown: editorState.sourceContent
                    )
                    DebugLog.log(.editor, "[SWITCH→MW] After extract: cleaned length=\(cleaned.count), anchors=\(anchors.count)")
                    editorState.sourceAnchors = anchors
                    // Also strip bibliography marker since Milkdown shouldn't see it
                    editorState.content = SectionSyncService.stripBibliographyMarker(from: cleaned)
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
                // Guard against rapid Cmd+/ -- if already transitioning, ignore
                guard editorState.contentState == .idle else { return }
                // Handle cursor position restoration during mode switch
                if let position = notification.userInfo?["position"] as? CursorPosition {
                    cursorRestore.wrappedValue = position
                }
                // Complete the two-phase toggle: cursor is saved, now do the actual switch
                NotificationCenter.default.post(name: .toggleEditorMode, object: nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleOutlineSidebar)) { _ in
                editorState.toggleOutlineSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationSidebar)) { _ in
                editorState.toggleAnnotationPanel()
            }
            .onAppear {
                // Push initial spellcheck state to editors on launch
                // (JS defaults to enabled, but UserDefaults may have it disabled)
                let anyEnabled = editorState.isSpellingEnabled || editorState.isGrammarEnabled
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(
                        name: .spellcheckStateChanged,
                        object: nil,
                        userInfo: ["enabled": anyEnabled]
                    )
                }
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
        onOpened: @escaping (_ isRestore: Bool) async -> Void,
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
            .onReceive(NotificationCenter.default.publisher(for: .exportMarkdownWithImages)) { _ in
                FileOperations.handleExportMarkdownWithImages()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportTextBundle)) { _ in
                FileOperations.handleExportTextBundle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { notification in
                let isRestore = notification.userInfo?["isRestore"] as? Bool ?? false
                Task { await onOpened(isRestore) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidCreate)) { notification in
                Task {
                    await onOpened(false)
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
        footnoteSyncService: FootnoteSyncService,
        autoBackupService: AutoBackupService,
        documentManager: DocumentManager
    ) -> some View {
        self
            .onChange(of: editorState.content) { _, newValue in
                guard editorState.contentState == .idle else { return }
                // BlockSyncService handles content -> block DB sync via polling
                // SectionSyncService syncs the section table (used by version history snapshots)
                sectionSyncService.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds)
                annotationSyncService.contentChanged(newValue)

                // When in source mode, re-parse blocks (BlockSyncService only works with Milkdown)
                if editorState.editorMode == .source {
                    if editorState.zoomedSectionId == nil {
                        // Non-zoomed: full document re-parse via replaceBlocks()
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            editorState.blockReparseTask?.cancel()
                            editorState.blockReparseGeneration += 1
                            let myGeneration = editorState.blockReparseGeneration
                            editorState.blockReparseTask = Task {
                                try? await Task.sleep(for: .milliseconds(1000))
                                guard !Task.isCancelled else { return }
                                guard editorState.blockReparseGeneration == myGeneration else { return }
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
                        editorState.blockReparseGeneration += 1
                        let myGeneration = editorState.blockReparseGeneration
                        editorState.blockReparseTask = Task {
                            try? await Task.sleep(for: .milliseconds(1000))
                            guard !Task.isCancelled else { return }
                            guard editorState.blockReparseGeneration == myGeneration else { return }
                            guard editorState.contentState == .idle,
                                  editorState.editorMode == .source else { return }
                            editorState.flushContentToDatabase()
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

                    // Check for footnote changes and update #Notes section
                    let footnoteRefs = FootnoteSyncService.extractFootnoteRefs(from: newValue)
                    footnoteSyncService.checkAndUpdateFootnotes(
                        footnoteRefs: footnoteRefs,
                        projectId: projectId,
                        fullContent: newValue
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
            DebugLog.log(.lifecycle, "[ContentView] Error saving document goal settings: \(error.localizedDescription)")
        }
    }

    /// Refreshes sidebar sections when contentState returns to idle,
    /// recovering any ValueObservation updates dropped during non-idle transitions.
    @MainActor
    func withContentStateRecovery(
        editorState: EditorViewState
    ) -> some View {
        self
            .onChange(of: editorState.contentState) { oldValue, newValue in
                if newValue == .idle && oldValue != .idle {
                    editorState.refreshSections()
                }
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
