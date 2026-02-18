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
    @Binding var isResettingContent: Bool

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement, drag)
    var contentState: EditorContentState = .idle

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// When true, setContent() will hide the WebView and use scrollToStart option.
    var isZoomingContent: Bool = false

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    /// Callback to provide the WebView reference (for find operations)
    var onWebViewReady: ((WKWebView) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        // Try preloaded view first for instant startup
        if let preloaded = EditorPreloader.shared.claimCodeMirrorView() {
            let controller = preloaded.configuration.userContentController
            controller.add(context.coordinator, name: "errorHandler")
            controller.add(context.coordinator, name: "openCitationPicker")
            controller.add(context.coordinator, name: "paintComplete")

            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded
            context.coordinator.handlePreloadedView()

            #if DEBUG
            preloaded.isInspectable = true
            print("[CodeMirrorEditor] Using preloaded WebView")
            #endif

            return preloaded
        }

        // Fallback: create fresh WebView (preload wasn't ready)
        #if DEBUG
        print("[CodeMirrorEditor] Creating new WebView (preload not ready)")
        #endif

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore  // Persist localStorage across editor toggles
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

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
        configuration.userContentController.add(context.coordinator, name: "errorHandler")
        configuration.userContentController.add(context.coordinator, name: "openCitationPicker")
        configuration.userContentController.add(context.coordinator, name: "paintComplete")

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
        // Update content state and zoom flag for coordinator (suppresses polling during transitions)
        // IMPORTANT: isZoomingContent must be set BEFORE content check to avoid race condition
        context.coordinator.isZoomingContent = isZoomingContent
        context.coordinator.contentState = contentState

        if context.coordinator.lastFocusModeState != focusModeEnabled {
            context.coordinator.lastFocusModeState = focusModeEnabled
            context.coordinator.setFocusMode(focusModeEnabled)
        }

        // Skip content/theme pushes during project reset to prevent empty flash
        guard !isResettingContent else { return }

        if context.coordinator.shouldPushContent(content) {
            context.coordinator.setContent(content)
        }

        if context.coordinator.lastThemeCss != themeCSS {
            context.coordinator.lastThemeCss = themeCSS
            context.coordinator.setTheme(themeCSS)
        }

        // Handle scroll-to-offset requests from sidebar
        if let offset = scrollToOffset {
            context.coordinator.scrollToOffset(offset)
            DispatchQueue.main.async {
                self.scrollToOffset = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: $content,
            cursorPositionToRestore: $cursorPositionToRestore,
            scrollToOffset: $scrollToOffset,
            isResettingContent: $isResettingContent,
            onContentChange: onContentChange,
            onStatsChange: onStatsChange,
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
        var isResettingContentBinding: Binding<Bool>
        let onContentChange: (String) -> Void
        let onStatsChange: (Int, Int) -> Void
        let onCursorPositionSaved: (CursorPosition) -> Void

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

        var isEditorReady = false
        var isCleanedUp = false
        var toggleObserver: NSObjectProtocol?
        var insertBreakObserver: NSObjectProtocol?
        var annotationDisplayModesObserver: NSObjectProtocol?
        var insertAnnotationObserver: NSObjectProtocol?
        var toggleHighlightObserver: NSObjectProtocol?

        /// Last sent annotation display modes (to avoid redundant calls)
        var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onWebViewReady: ((WKWebView) -> Void)?
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.isResettingContentBinding = isResettingContent
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onWebViewReady = onWebViewReady
            super.init()

            // Subscribe to toggle notification - save cursor before editor switches
            toggleObserver = NotificationCenter.default.addObserver(
                forName: .willToggleEditorMode,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.saveAndNotify()
            }

            // Subscribe to insert section break notification
            insertBreakObserver = NotificationCenter.default.addObserver(
                forName: .insertSectionBreak,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.insertSectionBreak()
            }

            // Subscribe to annotation display modes changes
            annotationDisplayModesObserver = NotificationCenter.default.addObserver(
                forName: .annotationDisplayModesChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let modes = notification.userInfo?["modes"] as? [AnnotationType: AnnotationDisplayMode] {
                    let isPanelOnly = notification.userInfo?["isPanelOnly"] as? Bool ?? false
                    let hideCompletedTasks = notification.userInfo?["hideCompletedTasks"] as? Bool ?? false
                    self?.setAnnotationDisplayModes(modes, isPanelOnly: isPanelOnly, hideCompletedTasks: hideCompletedTasks)
                }
            }

            // Subscribe to insert annotation notifications (keyboard shortcuts)
            insertAnnotationObserver = NotificationCenter.default.addObserver(
                forName: .insertAnnotation,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let type = notification.userInfo?["type"] as? AnnotationType {
                    self?.insertAnnotation(type: type)
                }
            }

            // Subscribe to toggle highlight notification (Cmd+Shift+H)
            toggleHighlightObserver = NotificationCenter.default.addObserver(
                forName: .toggleHighlight,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.toggleHighlight()
            }
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
        }
    }
}
