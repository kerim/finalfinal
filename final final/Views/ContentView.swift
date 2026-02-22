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

struct ContentView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(VersionHistoryCoordinator.self) private var versionHistoryCoordinator

    /// Observe appearance settings to trigger editor CSS updates when settings change
    @State var appearanceManager = AppearanceSettingsManager.shared
    @Environment(\.openWindow) private var openWindow
    @State var editorState = EditorViewState()
    @State var cursorPositionToRestore: CursorPosition?
    @State var sectionSyncService = SectionSyncService()
    @State var blockSyncService = BlockSyncService()
    @State var annotationSyncService = AnnotationSyncService()
    @State var bibliographySyncService = BibliographySyncService()
    @State var footnoteSyncService = FootnoteSyncService()
    @State var autoBackupService = AutoBackupService()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// Integrity alert state
    @State var integrityReport: IntegrityReport?
    @State var pendingProjectURL: URL?

    /// Version history dialog state
    @State var showSaveVersionDialog = false
    @State var saveVersionName = ""

    /// Getting Started close alert state
    @State var showGettingStartedCloseAlert = false

    /// Editor preload ready state - blocks editor display until WebView is ready
    @State var isEditorPreloadReady = false

    /// Find bar state
    @State var findBarState = FindBarState()

    /// Suppress the first bibliography notification after a project switch
    /// (it fires from the old project's debounced citekey check and is redundant)
    @State var suppressNextBibliographyRebuild = false

    /// Queued footnote label for double-insertion safety.
    /// If user presses Cmd+Shift+N while contentState != .idle, the label is stored
    /// here and processed when contentState returns to .idle.
    @State var pendingFootnoteLabel: String?

    /// Callback when project is closed (to return to picker)
    var onProjectClosed: (() -> Void)?

    /// Use the shared DocumentManager for project lifecycle
    var documentManager: DocumentManager { DocumentManager.shared }

    /// Theme CSS with appearance overrides - reading cssOverrides creates the SwiftUI dependency
    /// so that when any appearance setting changes, editors get updated
    var currentThemeCSS: String {
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
            .withEditorNotifications(
                editorState: editorState,
                cursorRestore: $cursorPositionToRestore,
                sectionSyncService: sectionSyncService,
                findBarState: findBarState
            )
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
                // Skip the first bibliography notification after a project switch
                // (it fires from the old project's debounced citekey check)
                // Skip rebuild when editor content is empty - no citations exist,
                // so rebuilding from blocks would restore stale content
                guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                guard !suppressNextBibliographyRebuild else {
                    suppressNextBibliographyRebuild = false
                    #if DEBUG
                    print("[ContentView] bibliographySectionChanged suppressed (post-project-switch)")
                    #endif
                    return
                }

                // Atomic content+IDs push to prevent temp ID race condition.
                // Without this, setContent() triggers assignBlockIds() which creates temp IDs,
                // and the 100ms-delayed pushBlockIds() arrives too late — block-sync reports
                // changes with temp IDs, Swift creates new blocks at maxSortOrder+1.
                editorState.contentState = .bibliographyUpdate
                blockSyncService.isSyncSuppressed = true
                editorState.isResettingContent = true  // prevent updateNSView → setContent()

                guard let result = fetchBlocksWithIds() else {
                    editorState.isResettingContent = false
                    editorState.contentState = .idle
                    blockSyncService.isSyncSuppressed = false
                    return
                }

                editorState.content = result.markdown  // sidebar sync (won't trigger WKWebView push)
                updateSourceContentIfNeeded()

                Task {
                    await blockSyncService.setContentWithBlockIds(
                        markdown: result.markdown, blockIds: result.blockIds)
                    editorState.isResettingContent = false
                    editorState.contentState = .idle
                    // setContentWithBlockIds' defer clears isSyncSuppressed
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .notesSectionChanged)) { _ in
                // Notes section was updated in the database - rebuild editor content
                guard editorState.zoomedSectionId == nil else { return }
                guard editorState.contentState == .idle else { return }
                guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                // Atomic content+IDs push (same pattern as bibliography)
                editorState.contentState = .bibliographyUpdate  // Reuse same state
                blockSyncService.isSyncSuppressed = true
                editorState.isResettingContent = true

                guard let result = fetchBlocksWithIds() else {
                    editorState.isResettingContent = false
                    editorState.contentState = .idle
                    blockSyncService.isSyncSuppressed = false
                    return
                }

                editorState.content = result.markdown
                updateSourceContentIfNeeded()

                Task {
                    await blockSyncService.setContentWithBlockIds(
                        markdown: result.markdown, blockIds: result.blockIds)
                    editorState.isResettingContent = false
                    editorState.contentState = .idle
                }
            }
            .onChange(of: editorState.contentState) { _, newValue in
                // Process queued footnote label when contentState returns to idle
                if newValue == .idle, let pending = pendingFootnoteLabel {
                    pendingFootnoteLabel = nil
                    NotificationCenter.default.post(
                        name: .footnoteInsertedImmediate,
                        object: nil,
                        userInfo: ["label": pending]
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .footnoteInsertedImmediate)) { notification in
                guard let label = notification.userInfo?["label"] as? String,
                      let projectId = documentManager.projectId else {
                    return
                }
                // Zoom-aware handling: use zoom-specific insertion path
                if editorState.zoomedSectionId != nil {
                    handleZoomedFootnoteInsertion(label: label, projectId: projectId)
                    return
                }

                // Rapid double-insertion safety: queue label if busy
                guard editorState.contentState == .idle else {
                    pendingFootnoteLabel = label
                    return
                }

                // Set sync suppression BEFORE DB write
                editorState.contentState = .bibliographyUpdate
                blockSyncService.isSyncSuppressed = true
                editorState.isResettingContent = true

                // editorState.content is fresh (coordinator synced via getContent before posting)
                // Strip old Notes section, preserving body and bibliography
                let stripped = FootnoteSyncService.stripNotesSection(from: editorState.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                footnoteSyncService.handleImmediateInsertion(label: label, projectId: projectId)

                // Build Notes section from freshly-created DB blocks
                let notesMarkdown = footnoteSyncService.buildNotesSectionMarkdown(projectId: projectId)

                // Insert Notes between body and bibliography (preserving correct block order)
                let combined: String
                if let notes = notesMarkdown {
                    // Find bibliography heading to insert Notes before it
                    let bibHeading = "# " + ExportSettingsManager.shared.bibliographyHeaderName
                    let lines = stripped.components(separatedBy: "\n")
                    if let bibIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == bibHeading }) {
                        let bodyPart = lines[..<bibIdx].joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let bibPart = lines[bibIdx...].joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        combined = bodyPart + "\n\n" + notes + "\n\n" + bibPart
                    } else {
                        combined = stripped + "\n\n" + notes
                    }
                } else {
                    combined = stripped
                }

                editorState.content = combined
                updateSourceContentIfNeeded()

                Task {
                    // Get block IDs from DB (count matches because slash commands
                    // don't add/remove blocks — they only replace text within one block)
                    guard let result = fetchBlocksWithIds() else {
                        editorState.isResettingContent = false
                        editorState.contentState = .idle
                        blockSyncService.isSyncSuppressed = false
                        return
                    }

                    // Push fresh content with real block IDs atomically
                    // (same pattern as bibliography — prevents temp ID race)
                    await blockSyncService.setContentWithBlockIds(
                        markdown: combined, blockIds: result.blockIds)

                    editorState.isResettingContent = false
                    editorState.contentState = .idle
                    // setContentWithBlockIds' defer clears isSyncSuppressed

                    await Task.yield()

                    // Navigate cursor to new definition
                    NotificationCenter.default.post(
                        name: .scrollToFootnoteDefinition,
                        object: nil,
                        userInfo: ["label": label]
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .didZoomOut)) { _ in
                // Re-sync annotations with full document content after zoom-out.
                // During zoom, annotation reconciliation deletes annotations outside the zoomed
                // subset. Milkdown restores them via content normalization triggering onChange,
                // but CodeMirror returns content verbatim so onChange never fires.
                annotationSyncService.contentChanged(editorState.content)

                // Catch hierarchy violations accumulated during zoom (Fix 1 skips enforcement
                // while zoomed). If onSectionsUpdated fires first, its enforcement pass finds
                // no violations and exits immediately.
                if editorState.contentState == .idle,
                   ContentView.hasHierarchyViolations(in: editorState.sections) {
                    Task { @MainActor in
                        await ContentView.enforceHierarchyAsync(
                            editorState: editorState,
                            syncService: sectionSyncService
                        )
                        updateSourceContentIfNeeded()
                    }
                }

                // Zoom-out completed - trigger bibliography sync with full document content
                // Citations added during zoom need to be processed now
                guard let projectId = documentManager.projectId else { return }
                let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
                bibliographySyncService.checkAndUpdateBibliography(
                    currentCitekeys: citekeys,
                    projectId: projectId
                )

                // Sync footnotes with full document content
                // Updates lastKnownRefs to prevent debounce from deleting definitions
                let footnoteRefs = FootnoteSyncService.extractFootnoteRefs(from: editorState.content)
                footnoteSyncService.checkAndUpdateFootnotes(
                    footnoteRefs: footnoteRefs,
                    projectId: projectId,
                    fullContent: editorState.content
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToSection)) { notification in
                if let sectionId = notification.userInfo?["sectionId"] as? String {
                    scrollToSection(sectionId)
                }
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
                footnoteSyncService: footnoteSyncService,
                autoBackupService: autoBackupService,
                documentManager: documentManager
            )
            .withContentStateRecovery(editorState: editorState)
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
        .toolbar { EditorToolbar(editorState: editorState) }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outline-sidebar")
    }

}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
