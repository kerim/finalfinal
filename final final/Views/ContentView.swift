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

    /// Version history dialog state
    @State internal var showSaveVersionDialog = false
    @State internal var saveVersionName = ""

    /// Editor preload ready state - blocks editor display until WebView is ready
    @State internal var isEditorPreloadReady = false

    /// Find bar state
    @State internal var findBarState = FindBarState()

    /// Esc-ladder live state for this window (UX contract §6) -- see EscapeLadder.swift.
    @State internal var escapeLadder = EscapeLadderContext()

    // suppressBibliographyRebuildsDuringSwitch moved to EditorViewState -- round 4.1
    // (doc-open-blank-regression): a bare `@State Bool` here is correct for production (a
    // live SwiftUI view installs @State's storage normally) but is untestable in a unit
    // test that constructs ContentView() directly without a view graph -- @State's
    // `nonmutating set` silently no-ops without an installed location, so a test's write was
    // never observed by a later method call. See EditorViewState.swift's doc comment on the
    // property for the full mechanism.

    // pendingFootnoteLabels, pendingBibliographyRebuild and pendingNotesRebuild moved to EditorViewState
    // (t-94369a83 3a-1b round C4), and so did pendingBibliographyRebuildAfterZoom before them -- see their
    // doc comments there for why a bare ContentView `@State` value doesn't reliably commit on a
    // bare-constructed, never-mounted ContentView() in tests. They hold the rebuild requests a rebuild handler
    // could not run yet (editor busy, or a close / switch / quit holding it); the idle transition drains them.

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
        // bt t-63c521f5: constructed directly here (not via a `View` extension method chained
        // onto `mainContentView`) so `mainContentView` is passed UNEVALUATED in the trailing
        // closure below -- `ContentSyncObserverHost.body` is what actually evaluates it, inside
        // its own separate Observation-tracking scope, not this `body`'s. The win this buys: THIS
        // `body`'s own outer chain below (the `.onReceive`s, the two `.alert`s, the four
        // `with*Notifications` chains) no longer re-evaluates on every `editorState.content`
        // keystroke -- confirmed by ContentViewBody=0 in the e2e measurement. It does NOT stop the
        // wrapped subtree (`mainContentView` and everything under it) from rebuilding every
        // keystroke -- that still happens, just inside `ContentSyncObserverHost.body` now instead
        // of here. See `ContentSyncObserverHost`'s own doc comment (ViewNotificationModifiers.swift)
        // for the mechanism.
        ContentSyncObserverHost(
            editorState: editorState,
            services: contentSyncServices
        ) {
            mainContentView
        }
            .withEditorNotifications(
                editorState: editorState,
                cursorRestore: $cursorPositionToRestore,
                sectionSyncService: sectionSyncService,
                findBarState: findBarState,
                unifiedUndoService: unifiedUndoService
            )
            .withFindNotifications(findBarState: findBarState)
            // t-94369a83 3a-1b C8b: a project switch, create or managed close is run by the lifecycle's tail
            // (ContentView+LifecycleTails.swift); the only project post this view acts on itself is the Getting
            // Started close (nothing to save, no token).
            .withFileNotifications(
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
                                             "[VersionHistory]   first section: '\(DebugLog.docText(first.title))' " +
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
        editorSplitViewContent
            .focusedSceneValue(\.editorState, editorState)
            .focusedSceneValue(\.unifiedUndoService, unifiedUndoService)
            .withContentStateRecovery(editorState: editorState)
            .withResettingContentRecovery(editorState: editorState)
            .overlay(alignment: .bottom) {
                if let toast = ToastCenter.shared.current {
                    ToastView(toast: toast)
                        .padding(.bottom, Spacing.s24)
                }
            }
    }

    /// The main window's split container. Previously a `NavigationSplitView` with a
    /// `columnVisibility` binding; now an `HSplitView` whose sidebar pane stays mounted at all
    /// times (see `OutlineSidebarPane`, which animates its own width and never writes
    /// `isOutlineSidebarVisible`) -- the user's decision, so that dragging the Outline divider
    /// narrows the editor instead of growing the window, and so a divider drag or window resize
    /// can never silently hide the sidebar. There is deliberately NO `.withSidebarSync` here
    /// any more: with the pane always mounted there is no native chevron/visibility state left
    /// to sync.
    @ViewBuilder
    private var editorSplitViewContent: some View {
        HSplitView {
            sidebarView
            detailView
        }
        .navigationTitle(documentManager.projectTitle ?? "Untitled")
        // Backstop for the title, NOT a replacement for the `.navigationTitle` above: this
        // container is no longer a navigation container, so SwiftUI may stop routing that value
        // to `NSWindow.title`, and nothing else in the app sets the title. Both carry the same
        // string, so they cannot disagree while both are active -- see `WindowTitleHost`.
        .background(WindowTitleHost(title: documentManager.projectTitle ?? "Untitled"))
        // Registers this view's editor state with the window it lands in. The close / switch / quit lifecycle then
        // finds the MAIN window's state, never the extra window Finder creates for an open-document event (see
        // `EditorStateRegistry`).
        .background(HostWindowReader { window in
            AppDelegate.shared?.registerEditorState(editorState, in: window)
        })
        .toolbar { EditorToolbar(editorState: editorState) }
        // Hide window toolbar in focus mode for distraction-free writing
        .toolbar(editorState.focusModeHidesToolbar ? .hidden : .visible, for: .windowToolbar)
        .task {
            AppDelegate.shared?.autoBackupService = autoBackupService
            // First, before anything awaits: the close / switch / quit lifecycle finds this editor through
            // `AppDelegate.shared?.editorState` (registered per window by the `HostWindowReader` above) and calls back
            // through this host.
            installLifecycleHost()
            #if DEBUG
            installUITestingDeleteTrigger()   // UI tests only (gated on `TestMode.isUITesting` inside): a delete without a menu click
            #endif
            escapeLadder.findBarState = findBarState
            escapeLadder.editorState = editorState
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
            // t-94369a83 Phase 4b slice 2a (plan D6): an editor-first section delete whose background job did not apply is put
            // back and reported through the same alert the other section operations use. The binding is a reference to this
            // view's alert state, so the controller never holds the view struct itself.
            let alertBinding = $sectionOperationAlert
            structuralUndoController.presentAlert = { alert in alertBinding.wrappedValue = alert }
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
            // Re-enter focus mode to capture fresh pre-state and apply full screen. The project-open
            // sequence (initializeProject() above) has normally done this already, before its first
            // publish; this is then a no-op (a snapshot exists), and covers a launch with no project.
            editorState.reenterFocusModeIfRestored()
        }
        // Teardown (item 11): the host's closures reach this view's state, so drop them with the view. Only THIS view's
        // host: an extra window going away must not touch the main window's. A lifecycle already running keeps the
        // host it captured at arm; it never reads this property again.
        .onDisappear {
            EditorStateRegistry.contentViewDidDisappear(editorState)
            #if DEBUG
            UITestingDeleteTrigger.shared.remove(for: editorState)
            #endif
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        // Extracted to its own view, OutlineSidebarPane (bt t-fecee361): reads that used to
        // happen inline here (editorState.sections, .zoomedSection, .currentSectionId, the whole
        // OutlineSidebarRenderKey(...)) were dependencies of ContentView.body itself -- every
        // keystroke that moved the caret's section touched currentSectionId, which @Observable
        // treats as a dependency the instant it's read, regardless of whether the value actually
        // changed. See OutlineSidebarPane's own doc comment for the invariant that keeps this
        // fixed: its initializer takes only `editorState` as a non-closure parameter.
        OutlineSidebarPane(
            editorState: editorState,
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
                // Barrier -- user-initiated zoom in (see the breadcrumb onZoomOut's
                // matching comment below for why this is hooked at the call site, not
                // inside EditorViewState+Zoom.swift's zoomToSection()).
                performUserZoomIn(sectionId, mode: mode, reason: "user zoomed in")
            },
            onZoomOutFromSidebar: {
                // Barrier -- user-initiated zoom out from the sidebar (see the breadcrumb
                // onZoomOut's matching comment below).
                performUserZoomOut(reason: "user zoomed out (sidebar)")
            },
            onZoomOutFromBreadcrumb: {
                // Barrier (see docs/architecture/unified-undo.md's Barriers section):
                // a USER-initiated zoom out, hooked here rather than inside
                // EditorViewState+Zoom.swift's zoomOut() itself -- the structural-op
                // sequence already calls zoomOut() as its OWN internal housekeeping
                // (StructuralUndoController's autoZoomOut policy), and hooking inside
                // zoomOut() would make an op falsely invalidate its own just-recorded
                // entry.
                performUserZoomOut(reason: "user zoomed out (breadcrumb)")
            },
            onDragStarted: {
                handleSectionDragStarted()
            },
            onDragEnded: {
                handleSectionDragEnded()
            },
            onDuplicateSection: { sectionId in
                duplicateSectionFromSidebar(sectionId)
            },
            onDeleteSection: { sectionId in
                deleteSectionFromSidebar(sectionId)
            }
        )
    }
}

extension ContentView {
    /// A sidebar card drag began (t-0b70d1e9). Only the debounced section sync is cancelled (cheap, idempotent, no ordering hazard).
    /// `contentState` is deliberately NOT touched: the drag-time state it used to set (a `contentState` case, now removed) bumped
    /// `contentGeneration`, which discards a batch a routine poll had already fetched (finding M1: type, then drag at once, and the
    /// typing is lost), and the editor-first reorder it precedes needs no such state. Testable on its own: after it, `contentState`
    /// is still `.idle` and `contentGeneration` unchanged.
    func handleSectionDragStarted() {
        sectionSyncService.cancelPendingSync()
    }

    /// A sidebar card drag ended (t-0b70d1e9, G11): dropped on a target, or abandoned. It is reached from the drag SOURCE's own completion
    /// (`DraggableCardView.draggingSession(_:endedAt:operation:)`), which fires for every drag; the reorder itself runs later, from the
    /// drop TARGET's async completion (`dispatchSectionReorder`). The guarded `.idle` write that used to sit here (MF-2) went with
    /// the drag-time state. What it does now is give back what `handleSectionDragStarted` took: the debounced section sync is re-armed, so an
    /// abandoned drag does not leave the section table without the sync the user's last typing had scheduled. When a reorder does
    /// follow, the move's own content change replaces this debounce (and the old sequence and the settle sync again), so it is harmless.
    func handleSectionDragEnded() {
        rearmSectionSync()
    }

    /// Schedules the debounced section sync again for the editor's current text (`SectionSyncService.contentChanged`, which does nothing
    /// when that text is what was last synced). Called when a drag ends and by every drop exit that runs no reorder (a no-op, a failed
    /// plan, an unchanged order), because `handleSectionDragStarted` cancelled the one that was pending.
    func rearmSectionSync() {
        sectionSyncService.contentChanged(editorState.content, zoomedIds: editorState.zoomedSectionIds)
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
