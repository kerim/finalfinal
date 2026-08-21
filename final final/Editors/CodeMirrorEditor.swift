//
//  CodeMirrorEditor.swift
//  final final
//
//  WKWebView wrapper for CodeMirror 6 source editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

// Shared configuration for localStorage persistence across editor toggles
private let sharedDataStore = WKWebsiteDataStore.default()

struct CodeMirrorEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var scrollToAnnotationIndex: Int?
    @Binding var isResettingContent: Bool
    @Binding var pendingImageMeta: [ContentView.ImageBlockMeta]?

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement, drag)
    var contentState: EditorContentState = .idle

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// When true, setContent() will hide the WebView and use scrollToStart option.
    var isZoomingContent: Bool = false

    /// Generation counter for stale poll detection
    var contentGeneration: Int = 0

    var pollCacheResetGeneration: Int = 0  // bumped by EditorViewState.resetForProjectSwitch()

    /// Bumped by every INTENTIONAL `sourceContent` replacement (zoom, project switch,
    /// structural undo/redo) -- see `EditorViewState.forcedPushGeneration`'s doc comment.
    /// Threaded into the coordinator every `updateNSView` cycle; `shouldPushContent`
    /// compares it against the last value it honoured to decide whether THIS push must
    /// bypass the settle-window guard (undo-mode-switch-focus fix).
    var forcedPushGeneration: Int = 0

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    /// P3 §4c/4d (undo-mode-switch-focus second timing gap): second parameter is
    /// `wasUndo` -- true if the content push that produced this string was (or included,
    /// sticky-OR) an undo replay. Threaded through so ContentView can suppress
    /// SectionSyncService's re-correction for content that was just undone.
    let onContentChange: (String, Bool) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onSectionChange: (String) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    /// Callback for block-ID-based section tracking (blockId, title)
    var onSectionIdChange: ((String?, String) -> Void)?

    /// Callback for selection changes (selected text; empty = deselected).
    /// Drives the status-bar selection word count.
    var onSelectionChange: ((String) -> Void)?

    /// Callback invoked when editor confirms content was set
    /// Used for acknowledgement-based sync during zoom transitions
    var onContentAcknowledged: (() -> Void)?

    /// Callback to provide the WebView reference (for find operations)
    var onWebViewReady: ((WKWebView) -> Void)?

    /// Re-invokes the real `updateSourceContentIfNeeded()` against NOW-current content.
    /// Called by the Coordinator's settle-window-suppressed-push retry timer (undo-mode-
    /// switch-focus fix) -- see `CodeMirrorEditor.Coordinator.scheduleDeferredRecompute()`.
    var onContentRecompute: (() -> Void)?

    /// P2 (undo-mode-switch-focus second timing gap): returns whether a content-triggered
    /// reconciliation (SectionSyncService's debounce+syncContent, or ContentView's
    /// `enforceHierarchyAsync`) is currently in flight. `shouldPushContent` extends its
    /// settle-window suppression while this returns true, capped at 2s as a backstop.
    var isReconciliationPending: (() -> Bool)?

    func makeNSView(context: Context) -> WKWebView {
        // Try preloaded view first for instant startup
        if let preloaded = EditorPreloader.shared.claimCodeMirrorView() {
            context.coordinator.registerMessageHandlers(on: preloaded.configuration.userContentController, includeTableInsertTruncated: true)

            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded
            context.coordinator.handlePreloadedView()

            #if DEBUG
            preloaded.isInspectable = true
            #endif
            DebugLog.log(.editor, "[CodeMirrorEditor] Using preloaded WebView")

            return preloaded
        }

        // Fallback: create fresh WebView (preload wasn't ready)
        DebugLog.log(.editor, "[CodeMirrorEditor] Creating new WebView (preload not ready)")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore  // Persist localStorage across editor toggles
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")

        // === Error handler script to capture JS errors ===
        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    window.webkit.messageHandlers.errorHandler.postMessage({
                        type: 'error',
                        message: msg,
                        url: url,
                        line: line,
                        column: col,
                        error: error ? error.toString() : null
                    });
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    window.webkit.messageHandlers.errorHandler.postMessage({
                        type: 'unhandledrejection',
                        message: 'Unhandled Promise Rejection: ' + e.reason,
                        url: '',
                        line: 0,
                        column: 0,
                        error: e.reason ? e.reason.toString() : null
                    });
                });
                console.log('[ErrorHandler] JS error capture installed');
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)
        context.coordinator.registerMessageHandlers(on: configuration.userContentController, includeTableInsertTruncated: true)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        if let url = URL(string: "editor://codemirror/codemirror.html") {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update content state, zoom flag, and generation for coordinator (suppresses polling during transitions)
        // IMPORTANT: isZoomingContent must be set BEFORE content check to avoid race condition
        context.coordinator.isZoomingContent = isZoomingContent
        context.coordinator.contentState = contentState
        context.coordinator.contentGeneration = contentGeneration
        context.coordinator.forcedPushGeneration = forcedPushGeneration
        context.coordinator.onContentAcknowledged = onContentAcknowledged
        context.coordinator.onContentRecompute = onContentRecompute
        context.coordinator.isReconciliationPending = isReconciliationPending
        context.coordinator.onSectionIdChange = onSectionIdChange
        context.coordinator.onSelectionChange = onSelectionChange

        context.coordinator.applyPollCacheReset(generation: pollCacheResetGeneration)

        let effectiveFocusMode = focusModeEnabled && FocusModeSettingsManager.shared.enableParagraphHighlighting
        if context.coordinator.lastFocusModeState != effectiveFocusMode {
            context.coordinator.lastFocusModeState = effectiveFocusMode
            context.coordinator.setFocusMode(effectiveFocusMode)
        }

        // Judge-review should-fix #3: called UNCONDITIONALLY (even while isResettingContent
        // is true) so a forcedPushGeneration bump landing during a reset still gets its
        // credit consumed on THIS cycle -- shouldPushContent itself now refuses to push
        // while resetting (see its own isResettingContent guard), so this is safe to call
        // before the "skip content/theme pushes during reset" guard below rather than
        // being skipped by it entirely, which used to leave the credit banked for
        // whatever unrelated push happened to run once the reset ended.
        if context.coordinator.shouldPushContent(content, isResettingContent: isResettingContent) {
            context.coordinator.setContent(content)
        }

        // Skip theme pushes (and anything below) during project reset to prevent empty flash
        guard !isResettingContent else { return }

        // Push pending image metadata for width display in previews
        // Guard behind isEditorReady to avoid losing metadata when JS runtime hasn't initialized yet
        if let meta = pendingImageMeta, context.coordinator.isEditorReady {
            DebugLog.log(.reentrancy, "[CodeMirrorEditor] updateNSView scheduling deferred nil-write: pendingImageMeta (was \(meta.count) items)")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[CodeMirrorEditor] deferred write firing: pendingImageMeta = nil")
                self.pendingImageMeta = nil
            }
            let metaArray = meta.compactMap { item -> [String: Any]? in
                guard let width = item.width, let src = item.src else { return nil }
                return ["src": src, "width": width]
            }
            if !metaArray.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: metaArray),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.FinalFinal.setImageMeta(\(json))")
            }
        }
        if pendingImageMeta != nil, !context.coordinator.isEditorReady {
            DebugLog.log(.editor, "[CodeMirrorEditor] Deferring pendingImageMeta push (isEditorReady=false)")
        }

        if context.coordinator.lastThemeCss != themeCSS {
            context.coordinator.lastThemeCss = themeCSS
            context.coordinator.setTheme(themeCSS)
        }

        // Handle scroll-to-offset requests from sidebar
        if let offset = scrollToOffset {
            context.coordinator.scrollToOffset(offset)
            DebugLog.log(.reentrancy, "[CodeMirrorEditor] updateNSView scheduling deferred nil-write: scrollToOffset (was \(offset))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[CodeMirrorEditor] deferred write firing: scrollToOffset = nil")
                self.scrollToOffset = nil
            }
        }

        // Handle annotation-specific scroll requests (uses ordinal index, not charOffset)
        if let index = scrollToAnnotationIndex {
            context.coordinator.scrollToAnnotation(index: index)
            DebugLog.log(.reentrancy, "[CodeMirrorEditor] updateNSView scheduling deferred nil-write: scrollToAnnotationIndex (was \(index))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[CodeMirrorEditor] deferred write firing: scrollToAnnotationIndex = nil")
                self.scrollToAnnotationIndex = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: $content,
            cursorPositionToRestore: $cursorPositionToRestore,
            scrollToOffset: $scrollToOffset,
            scrollToAnnotationIndex: $scrollToAnnotationIndex,
            isResettingContent: $isResettingContent,
            onContentChange: onContentChange,
            onStatsChange: onStatsChange,
            onSectionChange: onSectionChange,
            onCursorPositionSaved: onCursorPositionSaved,
            onWebViewReady: onWebViewReady
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Only save cursor if not already saved by Phase 1 toggle flow
        if coordinator.cursorPositionToRestoreBinding.wrappedValue == nil {
            coordinator.saveCursorPositionBeforeCleanup()
        }
        coordinator.cleanup()
    }

    // Coordinator's primary declaration (stored properties, init, deinit) lives in
    // CodeMirrorCoordinator+Core.swift -- see that file's header for why.
}
