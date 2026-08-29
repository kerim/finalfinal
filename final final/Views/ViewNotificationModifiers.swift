//
//  ViewNotificationModifiers.swift
//  final final
//
//  View extension modifiers for notification handling, content observers, and sidebar sync.
//

import SwiftUI

// MARK: - Notification Extensions

/// Groups the sync/persistence services threaded through the content-change
/// observer chain, so `withContentObservers` and friends stay under
/// SwiftLint's function-parameter-count limit.
@MainActor
struct ContentSyncServices {
    let sectionSync: SectionSyncService
    let annotationSync: AnnotationSyncService
    let bibliographySync: BibliographySyncService
    let footnoteSync: FootnoteSyncService
    let autoBackup: AutoBackupService
    let documentManager: DocumentManager
}

extension View {
    /// Adds editor-related notification handlers
    @MainActor
    func withEditorNotifications(
        editorState: EditorViewState,
        cursorRestore: Binding<CursorPosition?>,
        sectionSyncService: SectionSyncService,
        findBarState: FindBarState,
        unifiedUndoService: UnifiedUndoService
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
                handleEditorModeToggle(
                    editorState: editorState,
                    sectionSyncService: sectionSyncService,
                    findBarState: findBarState,
                    unifiedUndoService: unifiedUndoService
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .didSaveCursorPosition)) { notification in
                // Block toggle only during states that would cause data corruption.
                // .structuralUndo added in the Phase 3 review round: a mode toggle mid-
                // sequence would reassign the WebView StructuralUndoController is still
                // operating on (see docs/architecture/unified-undo.md's audited-sequences
                // section).
                switch editorState.contentState {
                case .projectSwitch, .zoomTransition, .structuralUndo:
                    return  // Content is being replaced — toggle could flush stale data
                default:
                    break  // Allow toggle during .idle, .editorTransition, .bibliographyUpdate, .annotationEdit, .dragReorder, .hierarchyEnforcement
                }
                // Handle cursor position restoration during mode switch
                if let position = notification.userInfo?["position"] as? CursorPosition {
                    let line = position.line
                    let column = position.column
                    let visible = position.cursorIsVisible
                    let topLine = position.topLine
                    DebugLog.log(.editor, "[CURSOR-SYNC] Relay: line=\(line) col=\(column) visible=\(visible) topLine=\(topLine)")
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
                // Push initial smart quotes state to editors on launch, same reasoning
                // (JS defaults to enabled, but UserDefaults may have it disabled)
                let smartQuotesEnabled = UserDefaults.standard.object(forKey: "isSmartQuotesEnabled") == nil
                    ? true : UserDefaults.standard.bool(forKey: "isSmartQuotesEnabled")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(
                        name: .spellcheckStateChanged,
                        object: nil,
                        userInfo: ["enabled": anyEnabled]
                    )
                    NotificationCenter.default.post(
                        name: .smartQuotesStateChanged,
                        object: nil,
                        userInfo: ["enabled": smartQuotesEnabled]
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

    // Note: unified-undo menu activation (see docs/architecture/unified-undo.md's
    // UndoRedoCommands entry in the Components table) is NOT wired through NotificationCenter
    // here. An earlier revision broadcast a notification
    // that every open project window's ContentView observed, so one Cmd-Z affected every open
    // window's WebView at once (review finding, round 1 must-fix). UndoRedoCommands.swift now
    // resolves the actually-focused WKWebView itself (via NSApp.keyWindow's first responder)
    // and calls evaluateJavaScript on it directly -- scoped to the key window by
    // construction, with no broadcast in between.

    /// Adds file menu notification handlers
    @MainActor
    func withFileNotifications(
        editorState: EditorViewState,
        syncService: SectionSyncService,
        onOpened: @escaping (_ isRestore: Bool) async -> Void,
        onClosed: @escaping () -> Void
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
            .onReceive(NotificationCenter.default.publisher(for: .exportMarkdownOnly)) { _ in
                Task { await FileOperations.handleExportMarkdownOnly() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportMarkdownWithImages)) { _ in
                Task { await FileOperations.handleExportMarkdownWithImages() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportTextBundle)) { _ in
                Task { await FileOperations.handleExportTextBundle() }
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
            .onReceive(NotificationCenter.default.publisher(for: .gettingStartedEdited)) { _ in
                editorState.showGettingStartedToast = true
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
        services: ContentSyncServices
    ) -> some View {
        contentSyncObservers(editorState: editorState, services: services)
            .annotationModeObservers(editorState: editorState)
            .goalPersistenceObservers(editorState: editorState, documentManager: services.documentManager)
    }

    /// Content, editor-mode, and zoom observers (split out to keep type-checking fast)
    @MainActor
    private func contentSyncObservers(
        editorState: EditorViewState,
        services: ContentSyncServices
    ) -> some View {
        self
            .onChange(of: editorState.content) { _, newValue in
                handleContentChange(newValue, editorState: editorState, services: services)
            }
            .onChange(of: editorState.editorMode) { _, _ in
                editorState.blockReparseTask?.cancel()
                editorState.blockReparseTask = nil
            }
            .onChange(of: editorState.zoomedSectionId) { _, newValue in
                services.sectionSync.isContentZoomed = (newValue != nil)
            }
    }

    /// Annotation display-mode observers (split out to keep type-checking fast)
    @MainActor
    private func annotationModeObservers(editorState: EditorViewState) -> some View {
        self
            .onChange(of: editorState.annotationDisplayModes) { _, newModes in
                // Notify editors when display modes change
                postAnnotationDisplayModes(
                    modes: newModes,
                    isPanelOnly: editorState.isPanelOnlyMode,
                    hideCompletedTasks: editorState.hideCompletedTasks
                )
            }
            .onChange(of: editorState.isPanelOnlyMode) { _, newValue in
                // Notify editors when panel-only mode changes
                postAnnotationDisplayModes(
                    modes: editorState.annotationDisplayModes,
                    isPanelOnly: newValue,
                    hideCompletedTasks: editorState.hideCompletedTasks
                )
            }
            .onChange(of: editorState.hideCompletedTasks) { _, newValue in
                // Notify editors when hide completed tasks filter changes
                postAnnotationDisplayModes(
                    modes: editorState.annotationDisplayModes,
                    isPanelOnly: editorState.isPanelOnlyMode,
                    hideCompletedTasks: newValue
                )
            }
    }

    /// Document goal settings persistence observers (split out to keep type-checking fast)
    @MainActor
    private func goalPersistenceObservers(
        editorState: EditorViewState,
        documentManager: DocumentManager
    ) -> some View {
        self
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

    /// Body of the editorState.content onChange handler.
    /// Extracted from the modifier chain to keep type-checking fast.
    @MainActor
    private func handleContentChange(
        _ newValue: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        guard editorState.contentState == .idle else { return }

        // P3 §4d (undo-mode-switch-focus second timing gap, M1 fix): this is the
        // content-sync consumer -- consumes its OWN one-shot flag on the shared token
        // (`consumedByContentSync`), independent of the hierarchy consumer's flag in
        // ContentView+ProjectLifecycle.swift's onSectionsUpdated handler. Hash-checked
        // against `newValue` (the content this call is actually about to act on): a stale
        // or since-superseded token must not suppress a genuinely different sync.
        var suppressReconcile = false
        if var token = editorState.reconcileSuppression, !token.isExpired, !token.consumedByContentSync {
            if token.contentHash == newValue.hashValue {
                suppressReconcile = true
            }
            token.consumedByContentSync = true
            editorState.reconcileSuppression = token.isFullyConsumed ? nil : token
        }

        // BlockSyncService handles content -> block DB sync via polling
        // SectionSyncService syncs the section table (used by version history snapshots)
        services.sectionSync.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds, suppressReconcile: suppressReconcile)
        services.annotationSync.contentChanged(newValue)

        // When in source mode, re-parse blocks (BlockSyncService only works with Milkdown)
        scheduleSourceModeReparse(newValue: newValue, editorState: editorState, services: services)

        // Skip bibliography sync when zoomed - we don't have full document context
        // Bibliography will be synced when user zooms out and full content is rebuilt
        guard editorState.zoomedSectionId == nil else { return }

        // Check for citation changes and update bibliography if needed
        // Always call even when citekeys is empty - this triggers bibliography removal
        syncCitationsAndFootnotes(newValue: newValue, services: services)

        // Trigger auto-backup timer on content change
        services.autoBackup.contentDidChange()
    }

    /// Dispatches the source-mode block re-parse to the zoomed or non-zoomed path.
    /// Extracted from `handleContentChange` to keep type-checking fast and its
    /// cyclomatic complexity down.
    @MainActor
    private func scheduleSourceModeReparse(
        newValue: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        guard editorState.editorMode == .source else { return }
        if editorState.zoomedSectionId == nil {
            // Non-zoomed: full document re-parse via replaceBlocks()
            scheduleFullDocumentReparse(newValue: newValue, editorState: editorState, services: services)
        } else if editorState.zoomedBlockRange != nil {
            // Zoomed: scoped re-parse via flushContentToDatabase()
            scheduleZoomedReparse(editorState: editorState)
        }
    }

    /// Non-zoomed source-mode re-parse: rebuilds the full block table from `newValue`,
    /// preserving existing heading metadata (status/tags/word goal).
    @MainActor
    private func scheduleFullDocumentReparse(
        newValue: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        guard let db = services.documentManager.projectDatabase,
              let pid = services.documentManager.projectId else { return }
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

    /// Zoomed source-mode re-parse: flushes the scoped CodeMirror content to the database.
    @MainActor
    private func scheduleZoomedReparse(editorState: EditorViewState) {
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

    /// Checks for citation and footnote changes in the (non-zoomed) full document
    /// content and updates the bibliography / #Notes section accordingly.
    @MainActor
    private func syncCitationsAndFootnotes(newValue: String, services: ContentSyncServices) {
        guard let projectId = services.documentManager.projectId else { return }
        let citekeys = BibliographySyncService.extractCitekeys(from: newValue)
        services.bibliographySync.checkAndUpdateBibliography(
            currentCitekeys: citekeys,
            projectId: projectId
        )

        // Check for footnote changes and update #Notes section
        let footnoteRefs = FootnoteSyncService.extractFootnoteRefs(from: newValue)
        services.footnoteSync.checkAndUpdateFootnotes(
            footnoteRefs: footnoteRefs,
            projectId: projectId,
            fullContent: newValue
        )
    }

    /// Posts the annotationDisplayModesChanged notification with explicit values.
    @MainActor
    private func postAnnotationDisplayModes(
        modes: [AnnotationType: AnnotationDisplayMode],
        isPanelOnly: Bool,
        hideCompletedTasks: Bool
    ) {
        NotificationCenter.default.post(
            name: .annotationDisplayModesChanged,
            object: nil,
            userInfo: [
                "modes": modes,
                "isPanelOnly": isPanelOnly,
                "hideCompletedTasks": hideCompletedTasks
            ]
        )
    }

    /// Toggle between WYSIWYG and Source mode with anchor injection/extraction.
    /// Extracted from the .toggleEditorMode onReceive closure to keep type-checking fast.
    @MainActor
    private func handleEditorModeToggle(
        editorState: EditorViewState,
        sectionSyncService: SectionSyncService,
        findBarState: FindBarState,
        unifiedUndoService: UnifiedUndoService
    ) {
        // Barrier (plan §4.5, Phase 5 backlog -- "neither is wired anywhere"): mode switch
        // destroys the outgoing editor's WebView and claims a fresh preloaded one for the
        // incoming mode (plan §2), so any structural entry's checkpoint/registry state tied to
        // the outgoing WebView is gone the instant this toggle completes. Timeline + descriptor
        // only, per plan §4.5 -- editor text-undo history is already inherently fresh after a
        // mode switch (a brand-new WebView), so there's nothing else to clear here.
        // Deliberately unguarded by `isPerforming` (MF-2, Phase 5 review round) -- do not "fix"
        // this by adding one; the forward path is already defended by
        // `StructuralUndoController`'s generation/epoch check (see its doc comment).
        unifiedUndoService.invalidateAll(reason: "mode switch")

        // Clear find bar state when switching editors
        findBarState.clearSearch()

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
            editorState.flushContentToDatabase(overrideContent: editorState.content)
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
            // DERIVED REFRESH (default) -- but not a gap: this writes the freshly-mounted
            // CodeMirror instance's OWN mount content, composed just before
            // toggleEditorMode() below actually mounts it. That new instance's
            // `lastLocalEditAt` starts (and is defensively reset to) `.distantPast` on its
            // own mount (CodeMirrorCoordinator.shouldPushContent's undo-mode-switch-focus
            // fix), so the settle-window guard can never suppress THIS push -- no
            // `forcedPushGeneration` bump needed here.
            editorState.sourceContent = withBibMarker
            editorState.toggleEditorMode()
            editorState.contentState = .idle
        } else {
            // Switching FROM source mode TO WYSIWYG - set state BEFORE flush
            editorState.contentState = .editorTransition
            DebugLog.log(.editor, "[SWITCH→MW] Starting. sourceContent length=\(editorState.sourceContent.count)")
            editorState.flushContentToDatabase(overrideContent: editorState.content)

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

    /// When a resetting-content window closes, triggers a fresh poll of pending
    /// JS-side changes (`pollBlockChangesNow()`), re-capturing any content push
    /// previously dropped by handleContentPush's isResettingContent guard while
    /// the window was open (e.g. right after a version-history restore).
    @MainActor
    func withResettingContentRecovery(
        editorState: EditorViewState
    ) -> some View {
        self
            .onChange(of: editorState.isResettingContent) { oldValue, newValue in
                if EditorViewState.shouldForcePollAfterResettingContent(
                    wasResetting: oldValue, isResetting: newValue, contentState: editorState.contentState
                ) {
                    Task { await editorState.blockSyncService?.pollBlockChangesNow() }
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
