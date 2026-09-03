//
//  ContentView.swift
//  final final
//

import SwiftUI
import WebKit

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
    @State internal var unifiedUndoService = UnifiedUndoService()
    @State internal var structuralUndoController = StructuralUndoController()
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

    // suppressBibliographyRebuildsDuringSwitch moved to EditorViewState -- round 4.1
    // (doc-open-blank-regression): a bare `@State Bool` here is correct for production (a
    // live SwiftUI view installs @State's storage normally) but is untestable in a unit
    // test that constructs ContentView() directly without a view graph -- @State's
    // `nonmutating set` silently no-ops without an installed location, so a test's write was
    // never observed by a later method call. See EditorViewState.swift's doc comment on the
    // property for the full mechanism.

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

    // pendingBibliographyRebuildAfterZoom moved to EditorViewState -- see its doc comment
    // there (near pendingSectionReorderRequest) for why a bare ContentView `@State` scalar
    // doesn't reliably commit on a bare-constructed, never-mounted ContentView() in tests.

    /// N2 (Phase B remediation plan): honest failure reporting for sidebar section
    /// delete/duplicate. Previously any refusal or failure just logged to DebugLog and showed
    /// nothing to the user -- the three-way `StructuralOpOutcome` protocol lets
    /// `deleteSectionFromSidebar`/`duplicateSectionFromSidebar` (ContentView+SectionOperations.swift)
    /// set this to a real, honest title+message (distinguishing "nothing happened" from "it
    /// happened but isn't undoable") instead of staying silent. Judge round 2 fix (must-fix
    /// 7): title and message must agree -- a single fixed "Section Operation Failed" title
    /// over a `.failedAfterCommit` body ("...but the change couldn't be added to Undo
    /// history") asserted two contradictory things in one alert, so the title is now part of
    /// this state too, chosen per outcome at the call site.
    @State internal var sectionOperationAlert: SectionOperationAlert?

    // MF-3's single-slot reorder-retry stash lives on `editorState.pendingSectionReorderRequest`
    // (a class property), not here -- see that property's doc comment for why a `ContentView`
    // `@State` property was root-caused as unreliable for this specific write-then-read-via-
    // Task-closure pattern.

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
        #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = DebugLog.log(.viewUpdates, "[ContentViewBody]")
        #endif
        mainContentView
            .withEditorNotifications(
                editorState: editorState,
                cursorRestore: $cursorPositionToRestore,
                sectionSyncService: sectionSyncService,
                findBarState: findBarState,
                unifiedUndoService: unifiedUndoService
            )
            .withFindNotifications(findBarState: findBarState)
            .withFileNotifications(
                editorState: editorState,
                syncService: sectionSyncService,
                // N9 (Phase B remediation plan): handleProjectOpened() no longer takes an
                // isRestore parameter -- see its own doc comment for why (no caller ever
                // passed true).
                onOpened: { _ in await handleProjectOpened() },
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
            .onReceive(NotificationCenter.default.publisher(for: .bibliographyHeaderNameChanged)) { notification in
                handleBibliographyHeaderNameChanged(notification)
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
            .onReceive(NotificationCenter.default.publisher(for: .zoomStateCleared)) { _ in
                handleZoomStateCleared()
            }
            .onReceive(NotificationCenter.default.publisher(for: .zoomHeadingClicked)) { notification in
                // Scoped to this window's own webview -- MilkdownCoordinator+MessageDispatch's
                // "zoomHeadingClicked" case posts with `object: message.webView` (not nil) for
                // exactly this: NotificationCenter.default is shared across every open project
                // window, so without this check a Cmd-click in a background window's editor
                // would zoom the window whose ContentView happens to receive this closure first.
                let notificationWebView = notification.object as? WKWebView
                guard notificationWebView === findBarState.activeWebView else {
                    let notificationID = notificationWebView.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                    let activeID = findBarState.activeWebView.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                    DebugLog.log(
                        .editor,
                        "[ZoomClick] dropped -- notification webview (\(notificationID)) != findBarState.activeWebView (\(activeID))"
                    )
                    return
                }
                DebugLog.log(.editor, "[ZoomClick] webview identity check passed, routing to handleZoomHeadingClicked")
                handleZoomHeadingClicked(notification)
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
            // N2 (Phase B remediation plan): honest sidebar section delete/duplicate failure
            // reporting -- see sectionOperationAlert's own doc comment. Judge round 2 fix
            // (must-fix 7): title is now outcome-dependent (bundled into the alert value
            // itself), not a single fixed string that could contradict the body.
            .alert(
                sectionOperationAlert?.title ?? "",
                isPresented: Binding(
                    get: { sectionOperationAlert != nil },
                    set: { if !$0 { sectionOperationAlert = nil } }
                )
            ) {
                Button("OK") { sectionOperationAlert = nil }
            } message: {
                Text(sectionOperationAlert?.message ?? "")
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        navigationSplitViewContent
            .focusedSceneValue(\.editorState, editorState)
            .focusedSceneValue(\.unifiedUndoService, unifiedUndoService)
            .withContentObservers(
                editorState: editorState,
                services: ContentSyncServices(
                    sectionSync: sectionSyncService,
                    annotationSync: annotationSyncService,
                    bibliographySync: bibliographySyncService,
                    footnoteSync: footnoteSyncService,
                    autoBackup: autoBackupService,
                    documentManager: documentManager
                )
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
            structuralUndoController.configure(
                editorState: editorState,
                blockSyncService: blockSyncService,
                sectionSyncService: sectionSyncService,
                bibliographySyncService: bibliographySyncService,
                footnoteSyncService: footnoteSyncService,
                annotationSyncService: annotationSyncService,
                unifiedUndoService: unifiedUndoService,
                findBarState: findBarState
            )
            DocumentManager.shared.structuralUndoController = structuralUndoController
            // Wired here rather than as `UnifiedUndoService` instance methods -- this service
            // has no business knowing about WebViews (see both closures' doc comments,
            // `UnifiedUndoService.swift`). `[weak controller]`, not `[weak self]`: capturing
            // the local `let` avoids retaining the whole ContentView struct's state back into
            // a long-lived `@State` object's closure property.
            let controller = structuralUndoController
            unifiedUndoService.clearEditorHistories = { [weak controller] evictedId in
                guard let webView = controller?.activeWebView else {
                    DebugLog.log(.undo, "[ContentView] clearEditorHistories: no active webview -- skipping clear for evicted entry \(evictedId)")
                    return
                }
                // MF-1 (Phase 5 review round): scoped to the ONE evicted entry, not a whole-
                // registry clear -- `record()` (UnifiedUndoService.swift) calls this as its
                // LAST step, after this same op's own registry entry may already have been
                // created and finalized elsewhere in the same tick; a whole-registry clear here
                // used to wipe that just-recorded entry too.
                webView.evaluateJavaScript("window.FinalFinal.clearStructuralUndoState('\(evictedId.uuidString)')") { _, error in
                    if let error {
                        DebugLog.log(.undo, "[ContentView] clearEditorHistories: clearStructuralUndoState failed: \(error.localizedDescription)")
                    }
                }
            }
            unifiedUndoService.clearStructuralRegistry = { [weak controller] in
                guard let webView = controller?.activeWebView else {
                    DebugLog.log(.undo, "[ContentView] clearStructuralRegistry: no active webview -- skipping barrier registry clear")
                    return
                }
                webView.evaluateJavaScript("window.FinalFinal.clearStructuralUndoRegistry()") { _, error in
                    if let error {
                        DebugLog.log(.undo, "[ContentView] clearStructuralRegistry: clearStructuralUndoRegistry " +
                            "failed: \(error.localizedDescription)")
                    }
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
                        // Barrier (see docs/architecture/unified-undo.md's Barriers section):
                        // a USER-initiated zoom out, hooked here rather than inside
                        // EditorViewState+Zoom.swift's zoomOut() itself -- the structural-op
                        // sequence already calls zoomOut() as its OWN internal housekeeping
                        // (StructuralUndoController's autoZoomOut policy), and hooking inside
                        // zoomOut() would make an op falsely invalidate its own just-recorded
                        // entry.
                        performUserZoomOut(reason: "user zoomed out (breadcrumb)")
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
                // Built fresh each body pass, by VALUE (not through the `$`-prefixed bindings
                // above) -- see `OutlineSidebarRenderKey`'s doc comment
                // (OutlineSidebar+Models.swift) for exactly why this exists: it's what lets
                // `OutlineSidebar`'s `.equatable()` below tell a keystroke that changed none of
                // these render-relevant values apart from one that did, instead of forcing
                // `OutlineSidebar.body` to re-run on every reconstruction regardless (bt
                // t-ef411da3).
                renderKey: OutlineSidebarRenderKey(
                    sections: editorState.sections,
                    statusFilter: editorState.statusFilter,
                    headerLevelFilter: editorState.headerLevelFilter,
                    zoomedSectionId: editorState.zoomedSectionId,
                    documentGoal: editorState.documentGoal,
                    documentGoalType: editorState.documentGoalType,
                    excludeBibliography: editorState.excludeBibliography
                ),
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
                    // Barrier -- user-initiated zoom in (see the breadcrumb onZoomOut's
                    // matching comment above for why this is hooked at the call site, not
                    // inside EditorViewState+Zoom.swift's zoomToSection()).
                    performUserZoomIn(sectionId, mode: mode, reason: "user zoomed in")
                },
                onZoomOut: {
                    // Barrier -- user-initiated zoom out from the sidebar (see the breadcrumb
                    // onZoomOut's matching comment above).
                    performUserZoomOut(reason: "user zoomed out (sidebar)")
                },
                onDragStarted: {
                    // MF-2 point 7 (Phase 7 review round): guard the contentState write the
                    // same way onDragEnded below is guarded -- if a PRIOR reorder's audited
                    // sequence is still mid-flight (isPerforming) when a NEW drag starts,
                    // don't stomp that sequence's own .structuralUndo contentState with
                    // .dragReorder. cancelPendingSync() stays unconditional: it's a cheap,
                    // idempotent debounce cancel with no ordering hazard either way.
                    if !structuralUndoController.isPerforming {
                        editorState.contentState = .dragReorder
                    }
                    sectionSyncService.cancelPendingSync()
                },
                onDragEnded: {
                    // MF-2 (Phase 7 review round, plan §7 -- corrects the prior round's factually
                    // wrong claim that onDrop and onDragEnded "run synchronously with no await
                    // between them"): this closure is ContentView's REAL onDragEnded target, but
                    // it is reached through exactly ONE of two decoupled paths per drag, and they
                    // are NOT interchangeable:
                    //
                    // Path A -- the drag SOURCE's own completion, `DraggableCardView.swift`'s
                    // `draggingSession(_:endedAt:operation:)`, wired above via
                    // `onDragEnded: { clearDragState(); onDragEnded?() }`. AppKit fires this
                    // almost immediately once a drop delegate's `performDrop` returns `true` --
                    // it does NOT wait for the drop target's own async `loadTransferable` work.
                    // Both `SectionDropDelegate` and `EndDropDelegate` (OutlineSidebar.swift's
                    // `sectionCard`/`sectionsList`) now wire their OWN `onDragEnded` parameter to
                    // a no-op ("already handled by DraggableCardView") specifically so Path A is
                    // the single source that ever reaches this closure -- see those call sites'
                    // comments; a prior asymmetry where EndDropDelegate wired the real closure
                    // directly meant an end-of-list drop invoked this guarded body TWICE.
                    //
                    // Path B -- the drop TARGET's async completion (`loadTransferable` ->
                    // `onDrop` -> `dispatchSectionReorder`'s `Task`), which is what actually
                    // spawns `StructuralUndoController.performSectionReorder`'s audited sequence.
                    // Path A is fully decoupled from Path B's timing: for the common case, Path A
                    // fires while `isPerforming` is STILL `false` (the reorder Task hasn't even
                    // started), so an isPerforming-only guard here does nothing and this closure
                    // would set contentState = .idle prematurely, re-arming the block-sync poll
                    // mid-reorder -- the normal case, not an edge case.
                    //
                    // `editorState.sectionDropInFlight` (set synchronously in `performDrop`,
                    // before AppKit can fire Path A -- see its own doc comment) closes exactly
                    // that gap: it's the "a reorder is about to start, or already stashed for
                    // retry" flag; `isPerforming` covers "a reorder's audited sequence already
                    // claimed the latch". Both are needed -- neither alone spans the whole window
                    // from drop-accepted to the reorder Task's own `defer` clearing the flag
                    // (`dispatchSectionReorder`, ContentView+SectionManagement.swift).
                    if !structuralUndoController.isPerforming && !editorState.sectionDropInFlight {
                        editorState.contentState = .idle
                    }
                },
                sectionDropInFlight: $editorState.sectionDropInFlight,
                onDuplicateSection: { sectionId in
                    duplicateSectionFromSidebar(sectionId)
                },
                onDeleteSection: { sectionId in
                    deleteSectionFromSidebar(sectionId)
                }
            )
            // The actual root-cause fix for bt t-ef411da3: `sidebarView` reconstructs
            // `OutlineSidebar` fresh on every `ContentView.body` pass (every keystroke), and
            // without `.equatable()` here SwiftUI has no way to distinguish that reconstruction
            // from a genuine content change -- `OutlineSidebar.body` re-ran unconditionally.
            // Paired with `OutlineSidebar: Equatable` (OutlineSidebar+Models.swift), this lets
            // SwiftUI skip re-invoking `OutlineSidebar.body` when `renderKey` and the other
            // compared fields are unchanged. Must stay directly on `OutlineSidebar` itself, not
            // on the enclosing `VStack` -- `.equatable()` compares the view value it's attached
            // to, not its container.
            .equatable()
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
