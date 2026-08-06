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
    let scrollFraction: Double
    let cursorIsVisible: Bool
    let topLine: Double

    init(line: Int, column: Int, scrollFraction: Double = 0, cursorIsVisible: Bool = true, topLine: Double = 1.0) {
        self.line = line
        self.column = column
        self.scrollFraction = scrollFraction
        self.cursorIsVisible = cursorIsVisible
        self.topLine = topLine
    }

    static let start = CursorPosition(line: 1, column: 0, scrollFraction: 0, cursorIsVisible: true, topLine: 1.0)
}

/// Toast notification with a fixed message, auto-dismisses after 3 seconds.
/// Shared by focus mode entry and the Getting Started first-edit notice.
struct EditorToast: View {
    let message: String
    @Binding var isShowing: Bool

    var body: some View {
        if isShowing {
            Text(message)
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
    @State internal var appearanceManager = AppearanceSettingsManager.shared
    @Environment(\.openWindow) private var openWindow
    @State internal var editorState = EditorViewState()
    @State internal var cursorPositionToRestore: CursorPosition?
    @State internal var sectionSyncService = SectionSyncService()
    @State internal var blockSyncService = BlockSyncService()
    @State internal var annotationSyncService = AnnotationSyncService()
    @State internal var bibliographySyncService = BibliographySyncService()
    @State internal var footnoteSyncService = FootnoteSyncService()
    @State internal var autoBackupService = AutoBackupService()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// Version history dialog state
    @State internal var showSaveVersionDialog = false
    @State internal var saveVersionName = ""

    /// Editor preload ready state - blocks editor display until WebView is ready
    @State internal var isEditorPreloadReady = false

    /// Find bar state
    @State internal var findBarState = FindBarState()

    /// Suppress the first bibliography notification after a project switch
    /// (it fires from the old project's debounced citekey check and is redundant)
    @State internal var suppressNextBibliographyRebuild = false

    /// Queue of footnote labels awaiting insertion while contentState != .idle.
    /// Drained one label per idle transition by drainNextPendingFootnoteIfPossible().
    /// internal (not private): reset() is called from the ContentView+ProjectLifecycle.swift
    /// extension on project switch, matching the other pending-rebuild flags below.
    @State internal var pendingFootnoteLabels = PendingFootnoteQueue()

    /// Queued bibliography/notes rebuild flags.
    /// If a rebuild notification arrives while contentState != .idle, store the flag
    /// and process it when contentState returns to .idle.
    @State internal var pendingBibliographyRebuild = false
    @State internal var pendingNotesRebuild = false

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
                onOpened: { isRestore in await handleProjectOpened(isRestore: isRestore) },
                onClosed: { handleProjectClosed() }
            )
            .withVersionNotifications(
                onSaveVersion: { showSaveVersionDialog = true },
                onShowHistory: {
                    if let db = documentManager.projectDatabase,
                       let pid = documentManager.projectId {
                        Task {
                            // Flush pending section sync — use full content (not zoomed subset)
                            let fullContent: String
                            if editorState.zoomedSectionId != nil,
                               let blocks = try? db.fetchBlocks(projectId: pid) {
                                fullContent = BlockParser.assembleMarkdown(from: blocks)
                            } else {
                                fullContent = editorState.content
                            }
                            await sectionSyncService.syncNow(fullContent)

                            // Guard against project change during await
                            guard documentManager.projectId == pid else { return }

                            // Use real DB sections with stable IDs (not parseAndGetSections which creates random UUIDs)
                            let sections = await sectionSyncService.loadSections()

                            DebugLog.log(.lifecycle, "[VersionHistory] prepareForOpen: \(sections.count) sections, projectId=\(pid)")
                            if let first = sections.first {
                                DebugLog.log(.lifecycle,
                                             "[VersionHistory]   first section: '\(first.title)' " +
                                             "id=\(first.id) content=\(first.markdownContent.count) chars")
                            }
                            versionHistoryCoordinator.prepareForOpen(
                                database: db,
                                projectId: pid,
                                sections: sections
                            )
                            openWindow(id: "version-history")
                        }
                    }
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: .bibliographySectionChanged)) { _ in
                handleBibliographySectionChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .notesSectionChanged)) { _ in
                handleNotesSectionChanged()
            }
            .onChange(of: editorState.contentState) { oldValue, newValue in
                handleContentStateChange(from: oldValue, to: newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .footnoteInsertedImmediate)) { notification in
                handleFootnoteInsertedImmediate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .didZoomOut)) { _ in
                handleDidZoomOut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToSection)) { notification in
                if let sectionId = notification.userInfo?["sectionId"] as? String {
                    scrollToSection(sectionId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .insertDocumentAnnotation)) { notification in
                if let type = notification.userInfo?["type"] as? AnnotationType {
                    createDocumentAnnotation(type: type)
                }
            }
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
    }

    @ViewBuilder
    private var mainContentView: some View {
        navigationSplitViewContent
            .focusedSceneValue(\.editorState, editorState)
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
            .withResettingContentRecovery(editorState: editorState)
            .withSidebarSync(
                editorState: editorState,
                sidebarVisibility: $sidebarVisibility
            )
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    EditorToast(
                        message: "Press Esc or Cmd+Shift+F to exit focus mode",
                        isShowing: $editorState.showFocusModeToast
                    )
                    EditorToast(
                        message: "Changes to the Getting Started guide aren't saved.",
                        isShowing: $editorState.showGettingStartedToast
                    )
                }
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
        .toolbar(editorState.focusModeHidesToolbar ? .hidden : .visible, for: .windowToolbar)
        .task {
            AppDelegate.shared?.editorState = editorState
            AppDelegate.shared?.autoBackupService = autoBackupService
            DocumentManager.shared.flushBeforeExport = { [weak editorState] in
                guard let editorState else { return }
                // See EditorViewState+Zoom.swift's flushLiveContentToDatabase(currentContent:)
                // for why a full re-parse (not the incremental block-sync diff) is needed
                // here -- it silently drops pure block moves.
                await editorState.flushLiveContentToDatabase {
                    await editorState.blockSyncService?.fetchContentFromWebView()
                }
            }
            await initializeProject()

            // Restore focus mode from previous session if needed. The launch race between
            // this and FullScreenManager.bootstrap(window:) is now structural, not timing-based:
            // whichever runs first, the requested full-screen intent survives (see
            // FullScreenManager.request(_:)'s "no window yet" path), so no artificial delay
            // is needed here.
            if editorState.focusModeEnabled && editorState.preFocusModeState == nil {
                // Re-enter focus mode to capture fresh pre-state and apply full screen
                editorState.focusModeEnabled = false  // Reset first
                editorState.enterFocusMode()
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
                        let savedSectionId = editorState.zoomedSectionId
                        findBarState.clearSearch()
                        editorState.contentState = .zoomTransition
                        Task {
                            await editorState.zoomOut()
                            await blockSyncService.pushBlockIds()
                            editorState.contentState = .idle
                            NotificationCenter.default.post(name: .didZoomOut, object: nil)
                            if let sectionId = savedSectionId {
                                scrollToSection(sectionId)
                            }
                        }
                    }
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                headerLevelFilter: $editorState.headerLevelFilter,
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
                currentSectionId: editorState.currentSectionId,
                onZoomToSection: { sectionId, mode in
                    findBarState.clearSearch()
                    editorState.contentState = .zoomTransition
                    Task {
                        await editorState.zoomToSection(sectionId, mode: mode)
                        await blockSyncService.pushBlockIds(for: editorState.zoomedBlockRange)
                        await annotationSyncService.syncNow(editorState.content)
                        editorState.contentState = .idle
                    }
                },
                onZoomOut: {
                    let savedSectionId = editorState.zoomedSectionId
                    findBarState.clearSearch()
                    editorState.contentState = .zoomTransition
                    Task {
                        await editorState.zoomOut()
                        await blockSyncService.pushBlockIds()
                        editorState.contentState = .idle
                        NotificationCenter.default.post(name: .didZoomOut, object: nil)
                        if let sectionId = savedSectionId {
                            scrollToSection(sectionId)
                        }
                    }
                },
                onDragStarted: {
                    editorState.contentState = .dragReorder
                    sectionSyncService.cancelPendingSync()
                },
                onDragEnded: {
                    editorState.contentState = .idle
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
