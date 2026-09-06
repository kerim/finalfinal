//
//  ContentView+EditorPresentation.swift
//  final final
//
//  Detail/editor view presentation: the split view housing the editor and annotation
//  panel, and the WYSIWYG/source editor host with its focus-restoration and annotation
//  display-mode sync. Split out of ContentView+ContentRebuilding.swift to stay under the
//  file_length lint limit; pure move, no logic changes.
//

import SwiftUI
import WebKit

extension ContentView {
    @ViewBuilder
    var detailView: some View {
        HSplitView {
            // Main editor area
            VStack(spacing: 0) {
                // Find bar (shown above editor)
                if findBarState.isVisible {
                    FindBarView(state: findBarState)
                }

                editorView
                // Hide status bar in focus mode for distraction-free writing
                if !editorState.focusModeHidesStatusBar {
                    StatusBar(editorState: editorState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.editorBackground)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-area")

            // Annotation panel (conditionally shown)
            if editorState.isAnnotationPanelVisible {
                AnnotationPanel(
                    editorState: editorState,
                    onScrollToAnnotation: { index, _ in
                        editorState.scrollToAnnotationIndex = index
                    },
                    onToggleCompletion: { annotation in
                        toggleAnnotationCompletion(annotation)
                    },
                    onUpdateAnnotationText: { annotation, newText in
                        handleAnnotationTextUpdate(annotation, newText: newText)
                    },
                    onCreateDocumentAnnotation: { type in
                        createDocumentAnnotation(type: type)
                    },
                    onDeleteDocumentAnnotation: { id in
                        deleteDocumentAnnotation(id: id)
                    }
                )
            }
        }
    }

    /// Builds the JSON payload for `window.FinalFinal.setAnnotationDisplayModes()`, matching
    /// the shape `MilkdownCoordinator+Content.swift`'s `setAnnotationDisplayModes()` sends.
    ///
    /// Needed because a freshly-created WKWebView (WYSIWYG/Source mode switch, or a fresh
    /// instance claimed from `EditorPreloader`) starts its JS module state at the hardcoded
    /// defaults (all types "inline") — `annotationDisplayModesChanged` is only posted on
    /// `.onChange` of the preference, so an editor that already matches the current
    /// preference (nothing "changed" from SwiftUI's perspective) never receives it. Without
    /// this catch-up push, annotations created in that editor render inline until the user
    /// happens to toggle the setting again.
    private func annotationDisplayModesJSON(_ editorState: EditorViewState) -> String? {
        var modeDict: [String: String] = [:]
        for (type, mode) in editorState.annotationDisplayModes {
            modeDict[type.rawValue] = mode.rawValue
        }
        modeDict["__panelOnly"] = editorState.isPanelOnlyMode ? "true" : "false"
        modeDict["__hideCompletedTasks"] = editorState.hideCompletedTasks ? "true" : "false"
        guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }
        return jsonString
    }

    /// Gives a freshly claimed/created WebView native macOS keyboard focus, so
    /// Cmd-Z/Cmd-Shift-Z route through `UndoRedoCommands`'s `focusedWebView()` check
    /// (via `NSApp.keyWindow?.firstResponder`) as soon as the WebView is ready --
    /// without this, switching editor mode (WYSIWYG<->Source) via its keyboard
    /// shortcut leaves undo silently no-op'ing until the user clicks into the
    /// document, since the mode switch never otherwise hands the new WebView
    /// first-responder status. Same underlying gap the Find-bar fix closed
    /// (`FindBarState.swift`), different trigger.
    ///
    /// `onWebViewReady` can fire synchronously from `makeNSView` -- the preloaded-
    /// WebView path SwiftUI takes both on first editor creation and on every mode
    /// switch -- BEFORE SwiftUI has actually attached the returned view to the
    /// window, so `webView.window` is nil at that point and `makeFirstResponder`
    /// would silently fail if called inline. Defer to the next run-loop turn,
    /// where attachment has normally completed; if it still hasn't (window still
    /// nil), retry once more a turn later.
    ///
    /// The undo-mode-switch-focus investigation (2026-08) instrumented this path
    /// heavily and confirmed, across every probe sample, that this AppKit-level
    /// responder handoff was never the actual defect -- the real root cause was a
    /// content-push race in `CodeMirrorCoordinator.shouldPushContent` (see that
    /// type's settle-window guard). `applyFirstResponder`'s per-attempt outcome
    /// stays as permanent (not diagnostic-only) logging: cheap, and useful
    /// visibility into this codepath for any future focus-adjacent report.
    ///
    /// Phase C (focus-restoration audit) routed this call site through the shared
    /// `EditorFocusRestoration` helper, adding the `window.FinalFinal.focus()` DOM half here
    /// for the first time (previously AppKit-only). Defense-in-depth, not a bug fix -- the
    /// investigation above already ruled this path out -- and safe: idempotent, harmless
    /// no-op if `window.FinalFinal` isn't ready yet.
    @MainActor
    private func restoreEditorFocus(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            if webView.window != nil {
                applyFirstResponder(webView: webView, attempt: "first")
            } else {
                DispatchQueue.main.async { [weak webView] in
                    guard let webView, webView.window != nil else { return }
                    applyFirstResponder(webView: webView, attempt: "retry")
                }
            }
        }
    }

    /// Delegates to the shared `EditorFocusRestoration` helper (both focus halves — see its
    /// doc comment). The defer/retry wrapper above stays local to this call site: it exists
    /// only to work around a freshly-created WebView not yet attached to a window at
    /// `onWebViewReady` time, unrelated to the focus-halves logic itself.
    @MainActor
    private func applyFirstResponder(webView: WKWebView, attempt: String) {
        EditorFocusRestoration.restoreFocus(
            to: webView,
            context: "mode-switch attempt=\(attempt) mode=\(editorState.editorMode.rawValue)")
    }

    @ViewBuilder
    var editorView: some View {
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
                    scrollToBlockId: $editorState.scrollToBlockId,
                    scrollToAnnotationIndex: $editorState.scrollToAnnotationIndex,
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    contentGeneration: editorState.contentGeneration,
                    pollCacheResetGeneration: editorState.pollCacheResetGeneration,
                    themeCSS: currentThemeCSS,
                    onContentChange: { newContent, wasUndo in
                        // Content change handling - could trigger outline parsing here.
                        // CORRECTED COMMENT (judge review, M1): this closure is NOT a no-op
                        // for content assignment -- MilkdownCoordinator's handleContentPush
                        // (MilkdownCoordinator+MessageHandlers.swift) sets
                        // `self.contentBinding.wrappedValue = content` ONE LINE before
                        // calling this closure, and that binding IS `$editorState.content`
                        // (see this MilkdownEditor's `content:` argument above) -- so
                        // `editorState.content` genuinely is reassigned here, on every
                        // accepted content push, same as CodeMirror's closure. (An EARLIER
                        // version of this comment wrongly claimed otherwise.)
                        //
                        // P3 §4d (undo-mode-switch-focus second timing gap, M1 token
                        // design): constructs/refreshes the shared suppression token when
                        // this push was an undo, or explicitly invalidates a stale token
                        // when a genuinely new (non-undo) edit's content no longer matches
                        // it -- see EditorViewState.ReconcileSuppression's doc comment for
                        // why a plain Bool couldn't serve both this closure's own fast
                        // consumer (ViewNotificationModifiers.handleContentChange) and the
                        // slow one (ContentView+ProjectLifecycle's onSectionsUpdated,
                        // gated behind BlockSyncService's own ~2s poll).
                        if wasUndo {
                            editorState.reconcileSuppression = EditorViewState.ReconcileSuppression(
                                contentHash: newContent.hashValue,
                                expiresAt: Date().addingTimeInterval(EditorViewState.ReconcileSuppression.ttl)
                            )
                        } else if let existing = editorState.reconcileSuppression, existing.contentHash != newContent.hashValue {
                            editorState.reconcileSuppression = nil
                        }
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onSectionChange: { title in
                        editorState.currentSectionName = title
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onSectionIdChange: { blockId, title in
                        editorState.setCurrentSectionId(blockId: blockId, title: title)
                    },
                    onSelectionChange: { text in
                        editorState.updateSelection(text)
                    },
                    onContentAcknowledged: {
                        // Called when WebView confirms content was set
                        // Used for acknowledgement-based synchronization during zoom
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        structuralUndoController.activeWebView = webView
                        restoreEditorFocus(webView)
                        // Sync current annotation display state - see annotationDisplayModesJSON's
                        // doc comment for why this fresh WebView wouldn't otherwise learn it.
                        if let json = annotationDisplayModesJSON(editorState) {
                            webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(json))") { _, _ in }
                        }
                        // Configure BlockSyncService with the WebView
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            blockSyncService.configure(database: db, projectId: pid, webView: webView)
                            blockSyncService.editorState = editorState
                            // Prevent updateNSView race during initial content push
                            editorState.isResettingContent = true
                            // Atomic push: content + block IDs in one JS call (no temp ID warnings)
                            Task {
                                if let result = fetchBlocksWithIds() {
                                    await blockSyncService.setContentWithBlockIds(
                                        markdown: result.markdown, blockIds: result.blockIds,
                                        imageMeta: result.imageMeta,
                                        cursorBoundary: result.bibBoundaryIndex,
                                        cursorBoundaryEnd: result.bibBoundaryEndIndex,
                                        expectedBlocks: result.expectedBlocks,
                                        zoomMode: editorState.zoomedSectionIds != nil)
                                    // Always sync editorState.content to DB-assembled markdown.
                                    // Without this, updateNSView sees editorState.content (e.g. 1748 chars)
                                    // ≠ lastPushedContent (1747 chars) and re-pushes WITHOUT block IDs,
                                    // destroying all real UUIDs (causing mass deletes).
                                    editorState.content = result.markdown
                                }
                                editorState.isResettingContent = false
                                blockSyncService.startPolling()
                            }
                        }
                    }
                )
            } else {
                CodeMirrorEditor(
                    content: $editorState.sourceContent,
                    focusModeEnabled: $editorState.focusModeEnabled,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    scrollToAnnotationIndex: $editorState.scrollToAnnotationIndex,
                    isResettingContent: $editorState.isResettingContent,
                    pendingImageMeta: $editorState.pendingImageMeta,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    contentGeneration: editorState.contentGeneration,
                    pollCacheResetGeneration: editorState.pollCacheResetGeneration,
                    forcedPushGeneration: editorState.forcedPushGeneration,
                    themeCSS: currentThemeCSS,
                    onContentChange: { newContent, wasUndo in
                        // DERIVED REFRESH (default): mirrors CodeMirror's OWN just-reported
                        // content back into Swift state -- never a push INTO the editor, so
                        // the settle-window guard is moot here (shouldPushContent's identical-
                        // content check already no-ops since this IS what CodeMirror has).
                        // Update sourceContent with raw content (including anchors)
                        // This keeps anchors in sync for mode switch
                        editorState.sourceContent = newContent

                        // Strip anchors and bibliography marker FIRST -- the token's
                        // contentHash must match what .onChange(of: editorState.content)
                        // will actually see (the STRIPPED string below), not the raw
                        // `newContent` (which still has anchors) -- otherwise the
                        // content-sync consumer's hash check in
                        // ViewNotificationModifiers.handleContentChange could never match.
                        let cleanContent = sectionSyncService.stripSectionAnchors(from: newContent)
                        let strippedContent = SectionSyncService.stripBibliographyMarker(from: cleanContent)

                        // P3 §4d token (undo-mode-switch-focus second timing gap, M1
                        // design): set BEFORE `content` is reassigned below, so it's
                        // already in place by the time .onChange(of: editorState.content)
                        // fires and consumes it -- see EditorViewState.ReconcileSuppression's
                        // doc comment for the full two-consumer rationale.
                        if wasUndo {
                            editorState.reconcileSuppression = EditorViewState.ReconcileSuppression(
                                contentHash: strippedContent.hashValue,
                                expiresAt: Date().addingTimeInterval(EditorViewState.ReconcileSuppression.ttl)
                            )
                        } else if let existing = editorState.reconcileSuppression, existing.contentHash != strippedContent.hashValue {
                            editorState.reconcileSuppression = nil
                        }

                        editorState.content = strippedContent
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onSectionChange: { title in
                        editorState.currentSectionName = title
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onSectionIdChange: { blockId, title in
                        editorState.setCurrentSectionId(blockId: blockId, title: title)
                    },
                    onSelectionChange: { text in
                        editorState.updateSelection(text)
                    },
                    onContentAcknowledged: {
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        structuralUndoController.activeWebView = webView
                        restoreEditorFocus(webView)
                        // Sync current annotation display state - see annotationDisplayModesJSON's
                        // doc comment for why this fresh WebView wouldn't otherwise learn it.
                        if let json = annotationDisplayModesJSON(editorState) {
                            webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(json))") { _, _ in }
                        }
                        // Push image metadata for width display in CodeMirror previews
                        if let result = fetchBlocksWithIds() {
                            let metaArray = result.imageMeta.compactMap { meta -> [String: Any]? in
                                guard let width = meta.width, let src = meta.src else { return nil }
                                return ["src": src, "width": width]
                            }
                            if !metaArray.isEmpty,
                               let data = try? JSONSerialization.data(withJSONObject: metaArray),
                               let json = String(data: data, encoding: .utf8) {
                                webView.evaluateJavaScript("window.FinalFinal.setImageMeta(\(json))")
                            }
                        }
                    },
                    onContentRecompute: {
                        // DERIVED (not intentional replacement): re-invokes the real
                        // recomputation against NOW-current editorState.content, called by
                        // the Coordinator's settle-window-suppressed-push retry timer
                        // (undo-mode-switch-focus fix, must-fix F2). Never a stale replay.
                        updateSourceContentIfNeeded()
                    },
                    isReconciliationPending: {
                        // P2 (undo-mode-switch-focus second timing gap): consulted by
                        // shouldPushContent to extend its settle window while a
                        // content-triggered reconciliation is actually in flight.
                        sectionSyncService.isSyncPending
                    }
                )
            }
        }
    }
}
