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

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    let onContentChange: (String) -> Void
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
        // Try preloaded view first for instant startup
        if let preloaded = EditorPreloader.shared.claimCodeMirrorView() {
            context.coordinator.registerMessageHandlers(on: preloaded.configuration.userContentController, includeTableInsertTruncated: false)

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
        context.coordinator.onContentAcknowledged = onContentAcknowledged
        context.coordinator.onSectionIdChange = onSectionIdChange
        context.coordinator.onSelectionChange = onSelectionChange

        let effectiveFocusMode = focusModeEnabled && FocusModeSettingsManager.shared.enableParagraphHighlighting
        if context.coordinator.lastFocusModeState != effectiveFocusMode {
            context.coordinator.lastFocusModeState = effectiveFocusMode
            context.coordinator.setFocusMode(effectiveFocusMode)
        }

        // Skip content/theme pushes during project reset to prevent empty flash
        guard !isResettingContent else { return }

        if context.coordinator.shouldPushContent(content) {
            context.coordinator.setContent(content)
        }

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

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        var contentBinding: Binding<String>
        var cursorPositionToRestoreBinding: Binding<CursorPosition?>
        var scrollToOffsetBinding: Binding<Int?>
        var scrollToAnnotationIndexBinding: Binding<Int?>
        var isResettingContentBinding: Binding<Bool>
        let onContentChange: (String) -> Void
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

        var lastThemeCss: String = ""
        var lastFocusModeState: Bool = false

        /// Current content state - used to suppress polling during transitions
        var contentState: EditorContentState = .idle

        /// Direct zoom flag passed from view through updateNSView.
        /// Used to control alphaValue hiding and scrollToStart option in setContent().
        /// This bypasses the race condition where contentState may be stale.
        var isZoomingContent: Bool = false

        /// Generation counter for stale poll detection
        var contentGeneration: Int = 0

        var isEditorReady = false
        var isCleanedUp = false
        var toggleObserver: NSObjectProtocol?
        var insertBreakObserver: NSObjectProtocol?
        var annotationDisplayModesObserver: NSObjectProtocol?
        var insertAnnotationObserver: NSObjectProtocol?
        var toggleHighlightObserver: NSObjectProtocol?
        var spellcheckStateObserver: NSObjectProtocol?
        var smartQuotesStateObserver: NSObjectProtocol?
        var proofingModeObserver: NSObjectProtocol?
        var proofingSettingsObserver: NSObjectProtocol?
        var insertFootnoteObserver: NSObjectProtocol?
        var renumberFootnotesObserver: NSObjectProtocol?
        var scrollToFootnoteDefObserver: NSObjectProtocol?
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
        var insertCitationObserver: NSObjectProtocol?

        /// Active spellcheck task (cancelled on new check or cleanup)
        var spellcheckTask: Task<Void, Never>?

        /// Last sent annotation display modes (to avoid redundant calls)
        var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// Callback invoked after content is confirmed set in WebView
        /// Used for acknowledgement-based synchronization during zoom transitions
        var onContentAcknowledged: (() -> Void)?

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            scrollToAnnotationIndex: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onSectionChange: @escaping (String) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onWebViewReady: ((WKWebView) -> Void)?
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.scrollToAnnotationIndexBinding = scrollToAnnotationIndex
            self.isResettingContentBinding = isResettingContent
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onSectionChange = onSectionChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onWebViewReady = onWebViewReady
            super.init()

            subscribeToEditorLifecycleNotifications()
            subscribeToAnnotationNotifications()
            subscribeToProofingNotifications()
            subscribeToFootnoteNotifications()
            subscribeToMediaNotifications()
            subscribeToFormattingCommandNotifications()
        }

        deinit {
            pollingTimer?.invalidate()
            if let observer = toggleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertBreakObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = annotationDisplayModesObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertAnnotationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = toggleHighlightObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = spellcheckStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = smartQuotesStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingSettingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertFootnoteObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = renumberFootnotesObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scrollToFootnoteDefObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = zoomFootnoteStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertImageObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertTableObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertEquationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            // Formatting command observers cleanup
            for observer in [toggleBoldObserver, toggleItalicObserver, toggleStrikethroughObserver,
                             setHeadingObserver, toggleBulletListObserver, toggleNumberListObserver,
                             toggleBlockquoteObserver, toggleCodeBlockObserver, toggleInlineCodeObserver,
                             insertLinkObserver, insertCitationObserver] {
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
        }
    }
}
