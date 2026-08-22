//
//  MilkdownEditor.swift
//  final final
//
//  WKWebView wrapper for Milkdown WYSIWYG editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

// Shared configuration for localStorage persistence across editor toggles
private let sharedDataStore = WKWebsiteDataStore.default()

/// Captures uncaught JS errors/unhandled rejections and forwards them to the
/// native `errorHandler` message handler. Only ever needed for `MilkdownEditor`'s
/// fresh-view path in `makeNSView` — the preloaded view already has it installed.
private let errorCaptureScript = WKUserScript(
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

/// The JS→native message handler names both the preloaded-view and fresh-view
/// paths in `MilkdownEditor.makeNSView` register identically — factored out to
/// avoid keeping two copies of this list in sync by hand.
private func registerMilkdownMessageHandlers(on controller: WKUserContentController, coordinator: MilkdownEditor.Coordinator) {
    controller.add(coordinator, name: "contentChanged")
    controller.add(coordinator, name: "sectionChanged")
    controller.add(coordinator, name: "errorHandler")
    controller.add(coordinator, name: "searchCitations")
    controller.add(coordinator, name: "openCitationPicker")
    controller.add(coordinator, name: "resolveCitekeys")
    controller.add(coordinator, name: "paintComplete")
    controller.add(coordinator, name: "openURL")
    controller.add(coordinator, name: "spellcheck")
    controller.add(coordinator, name: "navigateToFootnote")
    controller.add(coordinator, name: "footnoteInserted")
    controller.add(coordinator, name: "pasteImage")
    controller.add(coordinator, name: "requestImagePicker")
    controller.add(coordinator, name: "updateImageMeta")
    controller.add(coordinator, name: "tableInsertTruncated")
    controller.add(coordinator, name: "openEquationDialog")
    controller.add(coordinator, name: "selectionChanged")
    // Unified-undo bridge (docs/architecture/unified-undo.md's registry/descriptor bridge
    // protocol section) -- Phase 3.
    controller.add(coordinator, name: "structuralUndoRequested")
    controller.add(coordinator, name: "structuralRedoRequested")
    controller.add(coordinator, name: "historyEdited")
    controller.add(coordinator, name: "structuralUndoRefused")
}

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var scrollToBlockId: String?
    @Binding var scrollToAnnotationIndex: Int?
    @Binding var isResettingContent: Bool

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement)
    var contentState: EditorContentState = .idle

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// When true, setContent() will hide the WebView and use scrollToStart option.
    var isZoomingContent: Bool = false

    /// Generation counter for stale poll detection
    var contentGeneration: Int = 0

    /// Bumped by `EditorViewState.resetForProjectSwitch()` on every project switch/close.
    /// `updateNSView` compares this against the Coordinator's last-seen value and, on
    /// change, clears the Coordinator's `lastPolled*` equality-guard caches -- see
    /// `EditorViewState.pollCacheResetGeneration`'s doc comment for why.
    var pollCacheResetGeneration: Int = 0

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    /// P3 §4d (undo-mode-switch-focus second timing gap): second parameter is `wasUndo` --
    /// true if the content push that produced this string was (or included, sticky-OR) an
    /// undo replay. Mirrors CodeMirrorEditor's matching property.
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

    func makeNSView(context: Context) -> WKWebView {
        // Try to use preloaded WebView for faster startup
        if let preloaded = EditorPreloader.shared.claimMilkdownView() {
            // Re-register message handlers with this coordinator
            registerMilkdownMessageHandlers(on: preloaded.configuration.userContentController, coordinator: context.coordinator)

            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded

            // Handle the preloaded view (navigation already finished)
            context.coordinator.handlePreloadedView()

            #if DEBUG
            preloaded.isInspectable = true
            #endif
            DebugLog.log(.sync, "[MilkdownEditor] Using preloaded WebView")

            return preloaded
        }

        // Fallback: create new WebView (preload wasn't ready)
        DebugLog.log(.sync, "[MilkdownEditor] Creating new WebView (preload not ready)")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore  // Persist localStorage across editor toggles
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")

        // === PHASE 4: Add error handler script to capture JS errors ===
        configuration.userContentController.addUserScript(errorCaptureScript)
        registerMilkdownMessageHandlers(on: configuration.userContentController, coordinator: context.coordinator)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        if let url = URL(string: "editor://milkdown/milkdown.html") {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update content state, zoom flag, generation, and callbacks for coordinator
        // IMPORTANT: isZoomingContent must be set BEFORE content check to avoid race condition
        context.coordinator.isZoomingContent = isZoomingContent
        context.coordinator.contentState = contentState
        context.coordinator.contentGeneration = contentGeneration
        context.coordinator.onContentAcknowledged = onContentAcknowledged
        context.coordinator.onSectionIdChange = onSectionIdChange
        context.coordinator.onSelectionChange = onSelectionChange

        // Project switch/close just ran -- drop the poll-equality-guard cache so the
        // next poll tick can't be suppressed by a value cached from the old project.
        if context.coordinator.lastPollCacheResetGeneration != pollCacheResetGeneration {
            context.coordinator.lastPollCacheResetGeneration = pollCacheResetGeneration
            context.coordinator.resetPollCache()
        }

        let effectiveFocusMode = focusModeEnabled && FocusModeSettingsManager.shared.enableParagraphHighlighting
        if context.coordinator.lastFocusModeState != effectiveFocusMode {
            context.coordinator.lastFocusModeState = effectiveFocusMode
            context.coordinator.setFocusMode(effectiveFocusMode)
        }

        // Track reset state for transition detection
        let wasResetting = context.coordinator.wasResettingContent
        context.coordinator.wasResettingContent = isResettingContent

        // Skip content/theme pushes during project reset to prevent empty flash
        guard !isResettingContent else {
            return
        }

        // If we just finished a content reset (e.g. after setContentWithBlockIds),
        // restore cursor position that was preserved during batchInitialize
        if wasResetting {
            context.coordinator.restoreCursorPositionIfNeeded()
        }

        // Theme FIRST — CSS variables must be set before content renders
        // (matches batchInitialize() order: setTheme → setContent)
        if context.coordinator.lastThemeCss != themeCSS {
            context.coordinator.lastThemeCss = themeCSS
            context.coordinator.setTheme(themeCSS)
        }

        if context.coordinator.shouldPushContent(content) {
            DebugLog.log(.sync, "[SYNC-DIAG:UpdateNSView] PUSHING content len=\(content.count) hasFigures=\(content.contains("!["))")
            context.coordinator.setContent(content)
        }

        // Handle scroll-to-offset requests from sidebar
        if let offset = scrollToOffset {
            context.coordinator.scrollToOffset(offset)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToOffset (was \(offset))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToOffset = nil")
                self.scrollToOffset = nil
            }
        }

        // Handle block-ID-based scroll requests (used for sections when images are present)
        if let blockId = scrollToBlockId {
            context.coordinator.scrollToBlock(blockId)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToBlockId (was \(blockId))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToBlockId = nil")
                self.scrollToBlockId = nil
            }
        }

        // Handle annotation-specific scroll requests (uses ordinal index, not charOffset)
        if let index = scrollToAnnotationIndex {
            context.coordinator.scrollToAnnotation(index: index)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToAnnotationIndex (was \(index))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToAnnotationIndex = nil")
                self.scrollToAnnotationIndex = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: $content,
            cursorPositionToRestore: $cursorPositionToRestore,
            scrollToOffset: $scrollToOffset,
            scrollToBlockId: $scrollToBlockId,
            isResettingContent: $isResettingContent,
            contentState: contentState,
            onContentChange: onContentChange,
            onStatsChange: onStatsChange,
            onSectionChange: onSectionChange,
            onCursorPositionSaved: onCursorPositionSaved,
            onContentAcknowledged: onContentAcknowledged,
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

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        var contentBinding: Binding<String>
        var cursorPositionToRestoreBinding: Binding<CursorPosition?>
        var scrollToOffsetBinding: Binding<Int?>
        var scrollToBlockIdBinding: Binding<String?>
        var isResettingContentBinding: Binding<Bool>
        /// P3 §4d: second parameter is `wasUndo` -- see MilkdownEditor's matching property.
        let onContentChange: (String, Bool) -> Void
        let onStatsChange: (Int, Int) -> Void
        let onSectionChange: (String) -> Void
        let onCursorPositionSaved: (CursorPosition) -> Void

        /// Callback for block-ID-based section tracking (blockId, title)
        var onSectionIdChange: ((String?, String) -> Void)?

        /// Callback for selection changes (selected text; empty = deselected)
        var onSelectionChange: ((String) -> Void)?

        var pollingTimer: Timer?
        var lastReceivedFromEditor: Date = .distantPast
        var lastPushedContent: String = ""
        var lastPushTime: Date = .distantPast

        /// P3 (4c/4d, undo-mode-switch-focus second timing gap): the most recent
        /// `contentChanged` message's `wasUndo` flag (sticky-OR across the JS-side 50ms
        /// debounce window -- see main.ts). Captured on every `contentChanged` dispatch;
        /// NOT YET consumed by `SectionSyncService`'s re-correction suppression (§4d) --
        /// that wiring is deferred, see this round's coder report.
        var lastContentChangeWasUndo: Bool = false

        var lastFocusModeState: Bool = false
        var lastThemeCss: String = ""
        var isEditorReady = false
        var isCleanedUp = false

        /// Current content state - used to suppress polling during transitions
        var contentState: EditorContentState = .idle

        /// Direct zoom flag passed from view through updateNSView.
        /// Used to control alphaValue hiding and scrollToStart option in setContent().
        /// This bypasses the race condition where contentState may be stale.
        var isZoomingContent: Bool = false

        /// Generation counter for stale poll detection
        var contentGeneration: Int = 0

        /// Last values delivered via pollContent() — guards onStatsChange/
        /// onSectionChange/onSectionIdChange against re-firing (and re-triggering
        /// an @Observable invalidation) when a tick reports the same value as before.
        var lastPolledWordCount: Int?
        var lastPolledCharacterCount: Int?
        var lastPolledSectionTitle: String?
        var lastPolledSectionBlockId: String?

        /// Last `pollCacheResetGeneration` value applied via `resetPollCache()` --
        /// compared against the incoming value in `updateNSView` to detect a fresh
        /// project switch/close exactly once per generation bump.
        var lastPollCacheResetGeneration: Int = 0

        /// Clears the poll-equality-guard cache above. Called from `updateNSView` when
        /// `pollCacheResetGeneration` changes (project switch/close) so a poll tick can't
        /// compare the next real value against a count/section left over from the
        /// previous project.
        func resetPollCache() {
            lastPolledWordCount = nil
            lastPolledCharacterCount = nil
            lastPolledSectionTitle = nil
            lastPolledSectionBlockId = nil
        }

        /// Callback invoked after content is confirmed set in WebView
        /// Used for acknowledgement-based synchronization during zoom transitions
        var onContentAcknowledged: (() -> Void)?

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        var toggleObserver: NSObjectProtocol?
        var insertBreakObserver: NSObjectProtocol?
        var annotationDisplayModesObserver: NSObjectProtocol?
        var insertAnnotationObserver: NSObjectProtocol?
        var toggleHighlightObserver: NSObjectProtocol?
        var citationLibraryObserver: NSObjectProtocol?
        var citationStyleObserver: NSObjectProtocol?
        var refreshAllCitationsObserver: NSObjectProtocol?
        var insertCitationObserver: NSObjectProtocol?
        var editorModeObserver: NSObjectProtocol?
        var spellcheckStateObserver: NSObjectProtocol?
        var smartQuotesStateObserver: NSObjectProtocol?
        var proofingModeObserver: NSObjectProtocol?
        var proofingSettingsObserver: NSObjectProtocol?
        var footnoteDefsObserver: NSObjectProtocol?
        var insertFootnoteObserver: NSObjectProtocol?
        var renumberFootnotesObserver: NSObjectProtocol?
        var scrollToFootnoteDefObserver: NSObjectProtocol?
        var blockSyncPushObserver: NSObjectProtocol?
        var zoomFootnoteStateObserver: NSObjectProtocol?
        var insertImageObserver: NSObjectProtocol?
        var insertTableObserver: NSObjectProtocol?
        var insertEquationObserver: NSObjectProtocol?

        // Formatting command observers
        var toggleBoldObserver: NSObjectProtocol?
        var toggleItalicObserver: NSObjectProtocol?
        var toggleStrikethroughObserver: NSObjectProtocol?
        var setHeadingObserver: NSObjectProtocol?
        var toggleBulletListObserver: NSObjectProtocol?
        var toggleNumberListObserver: NSObjectProtocol?
        var toggleBlockquoteObserver: NSObjectProtocol?
        var toggleCodeBlockObserver: NSObjectProtocol?
        var toggleInlineCodeObserver: NSObjectProtocol?
        var insertLinkObserver: NSObjectProtocol?

        /// Active spellcheck task (cancelled on new check or cleanup)
        var spellcheckTask: Task<Void, Never>?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// Last sent annotation display modes (to avoid redundant calls)
        var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        /// Tracks previous isResettingContent state to detect reset→idle transition
        var wasResettingContent = false

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            scrollToBlockId: Binding<String?>,
            isResettingContent: Binding<Bool>,
            contentState: EditorContentState,
            onContentChange: @escaping (String, Bool) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onSectionChange: @escaping (String) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onContentAcknowledged: (() -> Void)?,
            onWebViewReady: ((WKWebView) -> Void)?
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.scrollToBlockIdBinding = scrollToBlockId
            self.isResettingContentBinding = isResettingContent
            self.contentState = contentState
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onSectionChange = onSectionChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onContentAcknowledged = onContentAcknowledged
            self.onWebViewReady = onWebViewReady
            super.init()

            // Notification subscriptions are grouped by concern in
            // MilkdownCoordinator+NotificationObservers.swift to keep this
            // initializer's cyclomatic complexity low.
            subscribeToEditorLifecycleNotifications()
            subscribeToAnnotationNotifications()
            subscribeToCitationNotifications()
            subscribeToProofingNotifications()
            subscribeToFootnoteNotifications()
            subscribeToBlockSyncNotifications()
            subscribeToFormattingCommandNotifications()
            subscribeToMediaNotifications()
        }

        deinit {
            pollingTimer?.invalidate()

            // Observer removal must happen directly inside deinit, not via a called-out
            // method: deinit is always nonisolated even on this @MainActor type, and
            // Swift's isolated-stored-property access exemption for deinit applies only
            // to deinit's own body, not to a same-type method deinit merely calls.
            // removeObserverIfPresent (MilkdownCoordinator+NotificationObservers.swift)
            // is safe to call here because it only touches its own parameter.
            removeObserverIfPresent(toggleObserver)
            removeObserverIfPresent(insertBreakObserver)
            removeObserverIfPresent(annotationDisplayModesObserver)
            removeObserverIfPresent(insertAnnotationObserver)
            removeObserverIfPresent(toggleHighlightObserver)
            removeObserverIfPresent(citationLibraryObserver)
            removeObserverIfPresent(citationStyleObserver)
            removeObserverIfPresent(refreshAllCitationsObserver)
            removeObserverIfPresent(editorModeObserver)
            removeObserverIfPresent(spellcheckStateObserver)
            removeObserverIfPresent(smartQuotesStateObserver)
            removeObserverIfPresent(proofingModeObserver)
            removeObserverIfPresent(proofingSettingsObserver)
            removeObserverIfPresent(footnoteDefsObserver)
            removeObserverIfPresent(insertFootnoteObserver)
            removeObserverIfPresent(renumberFootnotesObserver)
            removeObserverIfPresent(scrollToFootnoteDefObserver)
            removeObserverIfPresent(blockSyncPushObserver)
            removeObserverIfPresent(zoomFootnoteStateObserver)
            removeObserverIfPresent(insertImageObserver)
            removeObserverIfPresent(insertTableObserver)
            removeObserverIfPresent(insertEquationObserver)

            // Formatting command observers cleanup
            for observer in [toggleBoldObserver, toggleItalicObserver, toggleStrikethroughObserver,
                             setHeadingObserver, toggleBulletListObserver, toggleNumberListObserver,
                             toggleBlockquoteObserver, toggleCodeBlockObserver, toggleInlineCodeObserver,
                             insertLinkObserver, insertCitationObserver] {
                removeObserverIfPresent(observer)
            }
        }
    }
}
