//
//  ViewNotificationModifiers.swift
//  final final
//
//  View extension modifiers for notification handling, content observers, and sidebar sync.
//

import SwiftUI

// MARK: - Notification Extensions

/// Groups the sync/persistence services threaded through the content-change
/// observer chain, so `ContentSyncObserverHost` and friends stay under
/// SwiftLint's function-parameter-count limit.
@MainActor
struct ContentSyncServices {
    let sectionSync: SectionSyncService
    let annotationSync: AnnotationSyncService
    let bibliographySync: BibliographySyncService
    let footnoteSync: FootnoteSyncService
    let autoBackup: AutoBackupService
    let documentManager: DocumentManager
    let scanMemo: MarkdownScanMemo   // t-2fbe4c9b: the editor's handler scan memo; no default, so a site that omits it does not compile
}

/// Hosts the content/editor-mode/zoom `.onChange` observers (plus the annotation-mode and
/// goal-persistence observers, folded in below) in their own `View` type. The actual win (bt
/// t-63c521f5): `ContentView.body`'s OWN outer modifier chain -- roughly 20 `.onReceive` handlers,
/// two `.alert` builders, and the four `with*Notifications` chains -- no longer re-evaluates on
/// every `editorState.content` keystroke, because those reads now live in this type's separate
/// Observation-tracking scope instead. This host's own `body` still re-evaluates once per
/// keystroke, same as before -- it's just far cheaper than `ContentView.body`'s old chain was. It
/// does NOT stop the wrapped subtree (`content()`'s result: navigationSplitViewContent ->
/// sidebarView -> detailView -> editorView -> MilkdownEditor(...)) from rebuilding on every
/// keystroke; that subtree still rebuilds here, one level removed from `ContentView.body`, exactly
/// as before -- see `content`'s doc comment below.
///
/// NOT `private` -- must be visible to `ContentView.swift`, which constructs this type directly
/// at the top of `ContentView.body`, wrapping `mainContentView` in a deferred trailing closure
/// (see `content`'s doc comment below).
@MainActor
struct ContentSyncObserverHost<Content: View>: View {
    let editorState: EditorViewState
    let services: ContentSyncServices
    // `ContentView.body` constructs this type directly and passes `mainContentView` UNEVALUATED
    // in a trailing closure -- not via a `View` extension method applied to an already-built
    // receiver, which would defeat the deferral (Swift fully evaluates an extension method's
    // receiver before the method is even called). Because `content` is a closure rather than a
    // stored `Content` value, evaluating `mainContentView` -- and everything it builds:
    // navigationSplitViewContent -> sidebarView -> detailView -> editorView ->
    // MilkdownEditor(...)'s whole init-argument list -- happens inside `body` below's call to
    // `content()`, in THIS type's own Observation-tracking scope rather than `ContentView.body`'s.
    // That subtree still rebuilds on every `editorState.content` keystroke -- this type's `body`
    // re-evaluates 1:1 with keystrokes, same as the removed `.onChange` handlers did before this
    // extraction. Moving the evaluation scope doesn't change how often the subtree rebuilds, only
    // whose Observation dependency set it's charged to. The actual win is that `ContentView.body`'s
    // own separate, much larger outer chain (onReceive handlers, alerts, with*Notifications) no
    // longer shares that dependency and stops re-evaluating on every keystroke.
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onChange(of: editorState.content) { _, newValue in
                Self.handleContentChange(newValue, editorState: editorState, services: services)
            }
            .onChange(of: editorState.editorMode) { _, newMode in
                // The pending re-parse and the Markdown writer's reset, then (for Markdown) the load prewarm again: all in the method.
                editorState.handleEditorModeChange(to: newMode, documentManager: services.documentManager)
            }
            .onChange(of: editorState.zoomedSectionId) { _, newValue in
                services.sectionSync.isContentZoomed = (newValue != nil)
            }
            // Moved here (were on the removed `withContentObservers` chain) for the same
            // Observation-scoping reason as the three `.onChange`s above: their `editorState.*`
            // reads now leave `ContentView.body`'s tracking scope too.
            .annotationModeObservers(editorState: editorState)
            .goalPersistenceObservers(editorState: editorState, documentManager: services.documentManager)
    }

    /// Body of the editorState.content onChange handler.
    /// Extracted from the modifier chain to keep type-checking fast.
    @MainActor
    private static func handleContentChange(
        _ newValue: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        #if DEBUG
        DebugLog.log(.viewUpdates, "[ContentSyncObserved]")
        #endif
        // Slice 0 measurement (StructuralTrace.swift): `start contentChange.handle` / `end contentChange.handle took=<n>ms`, only
        // while tracing is on and an op's window is open.
        let traceSpan = StructuralTrace.span("contentChange.handle")
        defer { traceSpan.end() }
        // Tells the citation-prefill scheduler the document changed -- all it does here is store the text and move a due time; the
        // scan for changed citations and the page work happen later, off this path. Before the idle guard below, so text assigned
        // during a transition (zoom in or out, project open or close) reaches the scheduler too and its next background fill never
        // works from an older text; and so a zoomed editor's text (the zoomed section, which is what a switch to Rich Text would
        // load) counts as well. (Round M1: each part of this handler is an `md-speed` span, MdSpeed.swift.)
        MdSpeed.timed("contentChange.noteDocumentChanged") { EditorPreloader.shared.noteDocumentChanged(newValue) }

        guard editorState.contentState == .idle else {
            FootnoteDiag.log("content change IGNORED by handleContentChange: contentState=\(editorState.contentState) length=\(newValue.utf8.count)")
            return
        }

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
        MdSpeed.timed("contentChange.sectionSync") {
            services.sectionSync.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds, suppressReconcile: suppressReconcile)
        }
        MdSpeed.timed("contentChange.annotationSync") { services.annotationSync.contentChanged(newValue) }

        // When in source mode, re-parse blocks (BlockSyncService only works with Milkdown)
        MdSpeed.timed("contentChange.scheduleSourceModeReparse") {
            scheduleSourceModeReparse(newValue: newValue, editorState: editorState, services: services)
        }

        // Skip bibliography sync when zoomed - we don't have full document context
        // Bibliography will be synced when user zooms out and full content is rebuilt
        guard editorState.zoomedSectionId == nil else {
            FootnoteDiag.log("content change: footnote and bibliography sync skipped while zoomed length=\(newValue.utf8.count)")
            return
        }

        // Check for citation changes and update bibliography if needed
        // Always call even when citekeys is empty - this triggers bibliography removal
        MdSpeed.timed("contentChange.syncCitationsAndFootnotes") { syncCitationsAndFootnotes(newValue: newValue, services: services) }

        // Trigger auto-backup timer on content change
        MdSpeed.timed("contentChange.autoBackup") { services.autoBackup.contentDidChange() }
    }

    /// Dispatches the source-mode block re-parse to the zoomed or non-zoomed path.
    /// Extracted from `handleContentChange` to keep type-checking fast and its
    /// cyclomatic complexity down. Internal rather than private: a cancelled lifecycle schedules its one
    /// catch-up re-parse through `LifecycleHost.scheduleSourceModeReparse` (ContentView+LifecycleHost.swift).
    @MainActor
    static func scheduleSourceModeReparse(
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

    /// Non-zoomed source-mode re-parse. Since Phase 4a (t-94369a83) it saves Markdown typing BLOCK BY BLOCK through the
    /// ordered write queue (`MarkdownBlockWriter`): the fire parses the editor's text, compares it with what is stored
    /// (the stored rows right after a load, the last written parse after a write) and sends only the changed blocks.
    /// Today's whole-document `replaceBlocks`, preserving heading metadata, is kept as `legacyWholeDocumentReparse`
    /// (the `FF_UI_TESTING_MD_LEGACY_REPARSE` arm, and the fallback when there is no writer).
    ///
    /// t-94369a83 3a-1b round C4, P5 (obligation 24): `db`/`pid` are read at SCHEDULE time. While a close / project
    /// switch / quit holds the editor (`activeLifecycle != nil`) it is therefore not scheduled at all, and one scheduled
    /// BEFORE the lifecycle armed does not write when it fires inside the window (the lifecycle's own whole-document
    /// save, FB, already carries the same text, and a write landing after FB or after the barrier is exactly what the
    /// queue exists to prevent). At fire time it also re-checks that the editor is still on the project it was
    /// scheduled for: a keystroke typed after `openProject` swapped `documentManager` to project B but before the tail
    /// reset the editor state would otherwise write A's text into B. Every one of those gates is unchanged, in both
    /// branches.
    ///
    /// Phase 4a (plan v2 section 1(d)): after the sleep the fire first waits for the write already in flight (a
    /// `while let` loop, because a `writeNow` can publish another while this one waits), then re-checks cancellation and
    /// the generation, then runs the gates above, then does ONE synchronous step (`runMarkdownReparseFire`): read the
    /// CURRENT text, parse, compare, reserve the turn and start the write (judge C1 and model ruling M1). The text is
    /// `editorState.content` read at fire time, never `newValue`: a push made while `contentState` is not `.idle` (a
    /// bibliography or Notes rebuild, a structural op, a zoom) does not restart a scheduled re-parse, so `newValue` can
    /// be older than the database. `newValue` is used only by the legacy branch.
    @MainActor
    private static func scheduleFullDocumentReparse(
        newValue: String,
        editorState: EditorViewState,
        services: ContentSyncServices
    ) {
        guard editorState.activeLifecycle == nil else {
            DebugLog.log(.lifecycle, "[SourceReparse] full re-parse not scheduled: a close/switch/quit holds the editor")
            return
        }
        guard let db = services.documentManager.projectDatabase, let pid = services.documentManager.projectId else { return }
        editorState.blockReparseTask?.cancel()
        editorState.blockReparseGeneration += 1
        let myGeneration = editorState.blockReparseGeneration
        let debounce = editorState.sourceReparseDebounce
        editorState.markdownWriter.prewarmParseAfterTypingPause(raw: editorState.content, projectId: pid, database: db)   // t-2fbe4c9b (ii)
        editorState.blockReparseTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            guard editorState.blockReparseGeneration == myGeneration else { return }
            if editorState.markdownWriter.isEnabled {
                // t-2fbe4c9b (C8): wait (at most 0.8 s) for this text's typing-pause parse, so the fire's step finds it; see `ensure`.
                await editorState.markdownWriter.parseCache.ensure(raw: editorState.content, projectId: pid, database: db)
                while let inFlight = editorState.markdownWriter.inFlight {
                    await inFlight.value
                }
                guard !Task.isCancelled, editorState.blockReparseGeneration == myGeneration else { return }
            }
            guard editorState.activeLifecycle == nil, editorState.currentProjectId == pid else {
                DebugLog.log(.lifecycle, "[SourceReparse] full re-parse dropped at fire time: lifecycle armed or project changed")
                return
            }
            guard editorState.contentState == .idle,
                  editorState.editorMode == .source,
                  editorState.zoomedSectionId == nil else {
                // t-4a8fd8af (O31): a fire discarded ONLY because the content state is busy owes the pull of the live text (the next
                // idle reads it, adopts it and re-arms this re-parse). Leaving Markdown mode and zoom owe nothing; every other exit
                // above (lifecycle, project change, cancel, newer generation) never reaches this guard.
                if MarkdownOwedPull.discardedFireOwesPull(
                    contentIsIdle: editorState.contentState == .idle, isSourceMode: editorState.editorMode == .source,
                    isZoomed: editorState.zoomedSectionId != nil) {
                    editorState.markdownWriter.notePullOwed("a re-parse fire was discarded: the content state was busy")
                }
                return
            }
            runMarkdownReparseFire(newValue: newValue, db: db, pid: pid, editorState: editorState, services: services)
        }
    }

    /// Zoomed source-mode re-parse: flushes the scoped CodeMirror content to the database. Gated like
    /// `scheduleFullDocumentReparse` (P5, obligation 24): not scheduled while a lifecycle holds the editor, and
    /// dropped at fire time if one armed since or the editor moved to another project (`pid` captured at
    /// schedule).
    @MainActor
    private static func scheduleZoomedReparse(editorState: EditorViewState) {
        guard editorState.activeLifecycle == nil else {
            DebugLog.log(.lifecycle, "[SourceReparse] zoomed re-parse not scheduled: a close/switch/quit holds the editor")
            return
        }
        editorState.blockReparseTask?.cancel()
        editorState.blockReparseGeneration += 1
        let myGeneration = editorState.blockReparseGeneration
        let pid = editorState.currentProjectId
        let debounce = editorState.sourceReparseDebounce
        editorState.blockReparseTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            guard editorState.blockReparseGeneration == myGeneration else { return }
            guard editorState.activeLifecycle == nil, editorState.currentProjectId == pid else {
                DebugLog.log(.lifecycle, "[SourceReparse] zoomed re-parse dropped at fire time: lifecycle armed or project changed")
                return
            }
            guard editorState.contentState == .idle,
                  editorState.editorMode == .source else { return }
            // Does not wait for a pending section-delete job (plan D7): Markdown mode only, and the switch into Markdown already
            // waited for every delete job (an editor-first delete cannot start in Markdown mode).
            editorState.flushContentToDatabase()
        }
    }

    /// Checks for citation and footnote changes in the (non-zoomed) full document
    /// content and updates the bibliography / #Notes section accordingly.
    @MainActor
    private static func syncCitationsAndFootnotes(newValue: String, services: ContentSyncServices) {
        guard let projectId = services.documentManager.projectId else { return }
        // t-2fbe4c9b: the scans come from the scan memo for this exact text (byte for byte), else it runs the same scan; same turn, same values.
        let citekeys = MdSpeed.timed("contentChange.extractCitekeys") { services.scanMemo.citekeys(for: newValue, projectId: projectId) }
        MdSpeed.timed("contentChange.checkAndUpdateBibliography") {
            services.bibliographySync.checkAndUpdateBibliography(currentCitekeys: citekeys, projectId: projectId)
        }

        // Check for footnote changes and update #Notes section
        let footnoteRefs = MdSpeed.timed("contentChange.extractFootnoteRefs") { services.scanMemo.footnoteRefs(for: newValue, projectId: projectId) }
        MdSpeed.timed("contentChange.checkAndUpdateFootnotes") {
            services.footnoteSync.checkAndUpdateFootnotes(
                footnoteRefs: footnoteRefs,
                projectId: projectId,
                fullContent: newValue
            )
        }
    }
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
                handleDidSaveCursorPosition(notification, editorState: editorState, cursorRestore: cursorRestore)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleOutlineSidebar)) { _ in
                editorState.toggleOutlineSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationSidebar)) { _ in
                editorState.toggleAnnotationPanel()
            }
            // `EditorViewState.clearZoomRestoringEditor()` just auto-recovered from the zoom
            // root's heading being deleted out from under an active zoom (see
            // `flushContentToDatabase`'s lost-root branch, EditorViewState+Zoom.swift). Same
            // undo-barrier + find-bar-reset treatment a user-initiated zoom-out already gets
            // via `performUserZoomOut` -- this path has no user gesture to hang those calls off
            // of, so they're hooked here instead. Added to THIS chain (not directly in
            // ContentView.body's own) deliberately: that chain is already at the type-checker's
            // per-expression time budget (see the `expression took ...ms to type-check` warnings
            // on ContentView.swift's body), and one more `.onReceive` there pushed a sibling
            // expression over into an outright "unable to type-check in reasonable time" error.
            //
            // Filtered by object identity (M4, judge fix round): `unifiedUndoService` and
            // `findBarState` are both per-window state, but `NotificationCenter.default` is
            // shared across every open project window -- an unfiltered post here would wipe
            // ANOTHER window's undo timeline and find-bar state in a multi-window session.
            // `EditorViewState.clearZoomRestoringEditor()` posts with `object: self` (itself)
            // for exactly this; mirrors `.zoomHeadingClicked`'s existing WKWebView-identity
            // filter just below, the established pattern for this in this file.
            .onReceive(NotificationCenter.default.publisher(for: .zoomExitedAfterRootLost)) { notification in
                guard notification.object as? EditorViewState === editorState else { return }
                unifiedUndoService.invalidateAll(reason: "zoom root heading removed")
                findBarState.clearSearch()
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
            // t-94369a83 3a-1b C5b/C8b: the three project lifecycle posts go through `LegacyProjectNotifications`.
            // A keyed post (a managed lifecycle's) is ignored because its tail does the work (the create seed is
            // `ContentView.seedCreatedProjectContent`, run by the create tail); the Getting Started close runs
            // `onClosed`; anything else is an unkeyed post (a missed call site), which is logged and counted.
            .onReceive(NotificationCenter.default.publisher(for: .projectDidOpen)) { notification in
                LegacyProjectNotifications.opened(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidCreate)) { notification in
                LegacyProjectNotifications.created(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .projectDidClose)) { notification in
                LegacyProjectNotifications.closed(notification, onClosed: onClosed)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gettingStartedEdited)) { _ in
                withAnimation {
                    ToastCenter.shared.show(ToastFactory.gettingStartedNotSaved())
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

    /// Annotation display-mode observers (split out to keep type-checking fast)
    @MainActor
    // `fileprivate`, not `private`: called from `ContentSyncObserverHost.body` below, which is a
    // member of a different type (not itself a `View` extension), so `private`'s
    // same-extension-family visibility rule doesn't reach it even within this file --
    // `fileprivate` grants the same-file access this cross-type call actually needs.
    fileprivate func annotationModeObservers(editorState: EditorViewState) -> some View {
        self
            .onChange(of: editorState.annotationDisplayModes) { _, newModes in
                // Notify editors when display modes change
                postAnnotationDisplayModes(
                    modes: newModes,
                    isPanelOnly: editorState.isPanelOnlyMode,
                    hideCompletedTasks: editorState.hideCompletedTasks,
                    windowToken: editorState.windowToken
                )
            }
            .onChange(of: editorState.isPanelOnlyMode) { _, newValue in
                // Notify editors when panel-only mode changes
                postAnnotationDisplayModes(
                    modes: editorState.annotationDisplayModes,
                    isPanelOnly: newValue,
                    hideCompletedTasks: editorState.hideCompletedTasks,
                    windowToken: editorState.windowToken
                )
            }
            .onChange(of: editorState.hideCompletedTasks) { _, newValue in
                // Notify editors when hide completed tasks filter changes
                postAnnotationDisplayModes(
                    modes: editorState.annotationDisplayModes,
                    isPanelOnly: editorState.isPanelOnlyMode,
                    hideCompletedTasks: newValue,
                    windowToken: editorState.windowToken
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusInlineAnnotationsChanged)) { _ in
                // The Focus pane's "Inline Annotations" choice changed (or was reset): if Focus
                // Mode is on, undo the armed override and re-arm for the new choice. Never
                // written; a no-op when Focus Mode is off.
                editorState.reconcileFocusInlineOverride()
            }
    }

    /// Document goal settings persistence observers (split out to keep type-checking fast)
    @MainActor
    // `fileprivate`, not `private` -- same reasoning as `annotationModeObservers` above.
    fileprivate func goalPersistenceObservers(
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

    /// Posts the annotationDisplayModesChanged notification with explicit values, scoped to the
    /// window that owns `windowToken` (see `AnnotationDisplayBroadcast`). `fileprivate`: the
    /// `.onChange` observers above are the only View-level poster; ContentView's explicit
    /// project-open pushes go through `AnnotationDisplayBroadcast.post` directly.
    @MainActor
    fileprivate func postAnnotationDisplayModes(
        modes: [AnnotationType: AnnotationDisplayMode],
        isPanelOnly: Bool,
        hideCompletedTasks: Bool,
        windowToken: UUID
    ) {
        AnnotationDisplayBroadcast.post(
            modes: modes,
            isPanelOnly: isPanelOnly,
            hideCompletedTasks: hideCompletedTasks,
            windowToken: windowToken
        )
    }

    /// Phase two of the two-phase editor-mode toggle: the editor has saved the cursor (`.didSaveCursorPosition`), so relay the position
    /// and ask for the switch itself (`.toggleEditorMode`). Extracted from the `.didSaveCursorPosition` onReceive closure so a unit
    /// test can drive it on a bare view (fix round 2a, the third round).
    ///
    /// Block the toggle only during states that would cause data corruption. `.structuralUndo` was added in the Phase 3 review round:
    /// a mode toggle mid-sequence would reassign the WebView StructuralUndoController is still operating on (see
    /// docs/architecture/unified-undo.md's audited-sequences section).
    ///   - `.structuralUndo` HOLDS the switch (the press already passed phase one, so the command must have started during the
    ///     cursor save, which is two web calls long): `holdModeToggleUntilStructuralWorkEnds` makes the request again from the top
    ///     when the command and everything queued behind it have finished. Dropping it here, as this receiver used to, left the
    ///     mode button on the old mode without a word (judge item 4: a switch pressed during a slow Cmd-Z is held, never dropped).
    ///   - `.projectSwitch` and `.zoomTransition` still drop it: the content is being replaced and the toggle could flush stale data.
    @MainActor
    func handleDidSaveCursorPosition(
        _ notification: Notification, editorState: EditorViewState, cursorRestore: Binding<CursorPosition?>
    ) {
        switch editorState.contentState {
        case .projectSwitch, .zoomTransition:
            return  // Content is being replaced — toggle could flush stale data
        case .structuralUndo:
            editorState.holdModeToggleUntilStructuralWorkEnds()
            return
        default:
            break  // Allow toggle during .idle, .editorTransition, .bibliographyUpdate, .annotationEdit, .hierarchyEnforcement
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

    /// Toggle between WYSIWYG and Source mode with anchor injection/extraction.
    /// Extracted from the .toggleEditorMode onReceive closure to keep type-checking fast.
    /// Internal (not private) so a unit test can drive the real handler on a bare view, with no view graph (fix round 2a, item 17).
    @MainActor
    func handleEditorModeToggle(
        editorState: EditorViewState,
        sectionSyncService: SectionSyncService,
        findBarState: FindBarState,
        unifiedUndoService: UnifiedUndoService
    ) {
        // t-94369a83 Phase 4b slice 2a (plan D7, addendum A2): the switch waits for pending editor-first delete jobs BEFORE it
        // changes anything (before the timeline barrier and before `contentState` leaves `.idle`), so the Rich Text editor stays
        // live during the wait and typing is saved normally. It enters through the structural gate, so a second toggle pressed
        // during the wait (or behind a held structural command) is held and runs afterwards: never in parallel, never dropped.
        // Nothing queued and no job pending (the normal case) runs the unchanged body right here, with no hop. The wait is the
        // only change: the switch itself stays off the writer's queue (that is Phase 5).
        editorState.runAfterPendingStructuralWork(label: "editor mode toggle") {
            performEditorModeToggle(
                editorState: editorState, sectionSyncService: sectionSyncService,
                findBarState: findBarState, unifiedUndoService: unifiedUndoService)
        }
    }

    /// The switch itself (everything `handleEditorModeToggle` did before the wait was added). Synchronous.
    @MainActor
    func performEditorModeToggle(
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
            // `skipUnchangedWrite`: when the stored rows already are what this flush would store (no edit since
            // the last save), nothing is written, so every row keeps its id. A zoomed flush ignores the flag.
            editorState.flushContentToDatabase(overrideContent: editorState.content, skipUnchangedWrite: true)
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
            // Phase 4a: Swift just handed the Markdown editor its text, assembled from the stored rows (the flush above wrote
            // them, or found them unchanged): the per-block writer compares with the stored rows from here. The editorMode
            // `onChange` resets it too at the next render; both leave the baseline on the rows, so their order does not matter.
            editorState.markdownWriter.noteLoaded(text: withBibMarker, pid: editorState.currentProjectId)
            editorState.contentState = .idle
        } else {
            // Switching FROM source mode TO WYSIWYG - set state BEFORE flush
            editorState.contentState = .editorTransition
            DebugLog.log(.editor, "[SWITCH→MW] Starting. sourceContent length=\(editorState.sourceContent.count)")
            // Extract the anchors and the bibliography marker from the text the Markdown editor holds NOW, save that text and hand it
            // to Rich Text. (It used to save `editorState.content`, which lags the page by its 50 ms push timer, so keys typed just
            // before the switch were not saved.)
            editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: sectionSyncService)
            editorState.toggleEditorMode()

            // No fixed wait here. contentState stays .editorTransition until the new Rich Text editor has been handed its
            // content: onWebViewReady (ContentView+EditorPresentation.swift) sets .idle right after setContentWithBlockIds
            // returns and before block polling starts. Backstop: the 5 s contentState watchdog (EditorViewState).
            // History: a 1.5 s Task.sleep stood here (added 2026-02-04 for a "missing # from headers" claim, no
            // reproduction on file); removed in the faster-switch work after VM runs showed headings survive without it.
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
}
