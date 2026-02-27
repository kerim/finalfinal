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

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var isResettingContent: Bool

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement)
    var contentState: EditorContentState = .idle

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// When true, setContent() will hide the WebView and use scrollToStart option.
    var isZoomingContent: Bool = false

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onSectionChange: (String) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    /// Callback invoked when editor confirms content was set
    /// Used for acknowledgement-based sync during zoom transitions
    var onContentAcknowledged: (() -> Void)?

    /// Callback to provide the WebView reference (for find operations)
    var onWebViewReady: ((WKWebView) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        // Try to use preloaded WebView for faster startup
        if let preloaded = EditorPreloader.shared.claimMilkdownView() {
            // Re-register message handlers with this coordinator
            let controller = preloaded.configuration.userContentController
            controller.add(context.coordinator, name: "contentChanged")
            controller.add(context.coordinator, name: "errorHandler")
            controller.add(context.coordinator, name: "searchCitations")
            controller.add(context.coordinator, name: "openCitationPicker")
            controller.add(context.coordinator, name: "resolveCitekeys")
            controller.add(context.coordinator, name: "paintComplete")
            controller.add(context.coordinator, name: "openURL")
            controller.add(context.coordinator, name: "spellcheck")
            controller.add(context.coordinator, name: "navigateToFootnote")
            controller.add(context.coordinator, name: "footnoteInserted")

            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded

            // Handle the preloaded view (navigation already finished)
            context.coordinator.handlePreloadedView()

            #if DEBUG
            preloaded.isInspectable = true
            print("[MilkdownEditor] Using preloaded WebView")
            #endif

            return preloaded
        }

        // Fallback: create new WebView (preload wasn't ready)
        #if DEBUG
        print("[MilkdownEditor] Creating new WebView (preload not ready)")
        #endif

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore  // Persist localStorage across editor toggles
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        // === PHASE 4: Add error handler script to capture JS errors ===
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
        configuration.userContentController.add(context.coordinator, name: "contentChanged")
        configuration.userContentController.add(context.coordinator, name: "errorHandler")
        configuration.userContentController.add(context.coordinator, name: "searchCitations")
        configuration.userContentController.add(context.coordinator, name: "openCitationPicker")
        configuration.userContentController.add(context.coordinator, name: "resolveCitekeys")
        configuration.userContentController.add(context.coordinator, name: "paintComplete")
        configuration.userContentController.add(context.coordinator, name: "openURL")
        configuration.userContentController.add(context.coordinator, name: "spellcheck")
        configuration.userContentController.add(context.coordinator, name: "navigateToFootnote")
        configuration.userContentController.add(context.coordinator, name: "footnoteInserted")

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
        // Update content state, zoom flag, and callbacks for coordinator
        // IMPORTANT: isZoomingContent must be set BEFORE content check to avoid race condition
        context.coordinator.isZoomingContent = isZoomingContent
        context.coordinator.contentState = contentState
        context.coordinator.onContentAcknowledged = onContentAcknowledged

        let effectiveFocusMode = focusModeEnabled && FocusModeSettingsManager.shared.enableParagraphHighlighting
        if context.coordinator.lastFocusModeState != effectiveFocusMode {
            context.coordinator.lastFocusModeState = effectiveFocusMode
            context.coordinator.setFocusMode(effectiveFocusMode)
        }

        // Skip content/theme pushes during project reset to prevent empty flash
        guard !isResettingContent else { return }

        // Theme FIRST — CSS variables must be set before content renders
        // (matches batchInitialize() order: setTheme → setContent)
        if context.coordinator.lastThemeCss != themeCSS {
            context.coordinator.lastThemeCss = themeCSS
            context.coordinator.setTheme(themeCSS)
        }

        if context.coordinator.shouldPushContent(content) {
            context.coordinator.setContent(content)
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
        var isResettingContentBinding: Binding<Bool>
        let onContentChange: (String) -> Void
        let onStatsChange: (Int, Int) -> Void
        let onSectionChange: (String) -> Void
        let onCursorPositionSaved: (CursorPosition) -> Void

        var pollingTimer: Timer?
        var lastReceivedFromEditor: Date = .distantPast
        var lastPushedContent: String = ""
        var lastPushTime: Date = .distantPast

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
        var refreshAllCitationsObserver: NSObjectProtocol?
        var editorModeObserver: NSObjectProtocol?
        var spellcheckStateObserver: NSObjectProtocol?
        var proofingModeObserver: NSObjectProtocol?
        var proofingSettingsObserver: NSObjectProtocol?
        var footnoteDefsObserver: NSObjectProtocol?
        var insertFootnoteObserver: NSObjectProtocol?
        var renumberFootnotesObserver: NSObjectProtocol?
        var scrollToFootnoteDefObserver: NSObjectProtocol?
        var blockSyncPushObserver: NSObjectProtocol?
        var zoomFootnoteStateObserver: NSObjectProtocol?

        // Formatting command observers
        var toggleBoldObserver: NSObjectProtocol?
        var toggleItalicObserver: NSObjectProtocol?
        var toggleStrikethroughObserver: NSObjectProtocol?
        var setHeadingObserver: NSObjectProtocol?
        var toggleBulletListObserver: NSObjectProtocol?
        var toggleNumberListObserver: NSObjectProtocol?
        var toggleBlockquoteObserver: NSObjectProtocol?
        var toggleCodeBlockObserver: NSObjectProtocol?
        var insertLinkObserver: NSObjectProtocol?

        /// Active spellcheck task (cancelled on new check or cleanup)
        var spellcheckTask: Task<Void, Never>?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// Last sent annotation display modes (to avoid redundant calls)
        var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            contentState: EditorContentState,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onSectionChange: @escaping (String) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onContentAcknowledged: (() -> Void)?,
            onWebViewReady: ((WKWebView) -> Void)?
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.isResettingContentBinding = isResettingContent
            self.contentState = contentState
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onSectionChange = onSectionChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onContentAcknowledged = onContentAcknowledged
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

            // Subscribe to annotation display modes change notification
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

            // Subscribe to insert annotation notification (for keyboard shortcuts)
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

            // Subscribe to citation library updates from Zotero
            citationLibraryObserver = NotificationCenter.default.addObserver(
                forName: .citationLibraryChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let json = notification.userInfo?["json"] as? String {
                    self?.setCitationLibrary(json)
                }
            }

            // Subscribe to refresh all citations notification (Cmd+Shift+R)
            refreshAllCitationsObserver = NotificationCenter.default.addObserver(
                forName: .refreshAllCitations,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshAllCitations()
                }
            }

            // Subscribe to editor appearance mode changes (Phase C dual-appearance)
            editorModeObserver = NotificationCenter.default.addObserver(
                forName: .editorAppearanceModeChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let mode = notification.userInfo?["mode"] as? String {
                    self?.setEditorAppearanceMode(mode)
                }
            }

            // Subscribe to spellcheck toggle
            spellcheckStateObserver = NotificationCenter.default.addObserver(
                forName: .spellcheckStateChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let enabled = notification.userInfo?["enabled"] as? Bool {
                    self?.setSpellcheck(enabled)
                }
            }

            // Subscribe to proofing mode change (re-check with new mode)
            proofingModeObserver = NotificationCenter.default.addObserver(
                forName: .proofingModeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.triggerSpellcheck()
            }

            // Subscribe to proofing settings change (re-check with new settings)
            proofingSettingsObserver = NotificationCenter.default.addObserver(
                forName: .proofingSettingsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.triggerSpellcheck()
            }

            // Subscribe to footnote definitions updates (push to editor for tooltip display)
            footnoteDefsObserver = NotificationCenter.default.addObserver(
                forName: .footnoteDefinitionsReady,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let defs = notification.userInfo?["definitions"] as? [String: String] {
                    self?.setFootnoteDefinitions(defs)
                }
            }

            // Subscribe to insert footnote notification (Cmd+Shift+N)
            insertFootnoteObserver = NotificationCenter.default.addObserver(
                forName: .insertFootnote,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.insertFootnoteAtCursor()
            }

            // Subscribe to renumber footnotes notification
            renumberFootnotesObserver = NotificationCenter.default.addObserver(
                forName: .renumberFootnotes,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let mapping = notification.userInfo?["mapping"] as? [String: String] {
                    self?.renumberFootnotes(mapping: mapping)
                }
            }

            // Subscribe to scroll-to-footnote-definition notification
            scrollToFootnoteDefObserver = NotificationCenter.default.addObserver(
                forName: .scrollToFootnoteDefinition,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let label = notification.userInfo?["label"] as? String {
                    self?.scrollToFootnoteDefinition(label: label)
                }
            }

            // Subscribe to BlockSyncService content push — sync lastPushedContent to prevent
            // redundant updateNSView re-push that destroys block IDs
            blockSyncPushObserver = NotificationCenter.default.addObserver(
                forName: .blockSyncDidPushContent,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let markdown = notification.userInfo?["markdown"] as? String else { return }
                self?.lastPushedContent = markdown
                self?.lastPushTime = Date()
            }

            // Subscribe to formatting command notifications
            toggleBoldObserver = NotificationCenter.default.addObserver(
                forName: .toggleBold, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleBold") }

            toggleItalicObserver = NotificationCenter.default.addObserver(
                forName: .toggleItalic, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleItalic") }

            toggleStrikethroughObserver = NotificationCenter.default.addObserver(
                forName: .toggleStrikethrough, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleStrikethrough") }

            setHeadingObserver = NotificationCenter.default.addObserver(
                forName: .setHeading, object: nil, queue: .main
            ) { [weak self] notification in
                if let level = notification.userInfo?["level"] as? Int {
                    self?.executeFormatting("setHeading", argument: "\(level)")
                }
            }

            toggleBulletListObserver = NotificationCenter.default.addObserver(
                forName: .toggleBulletList, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleBulletList") }

            toggleNumberListObserver = NotificationCenter.default.addObserver(
                forName: .toggleNumberList, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleNumberList") }

            toggleBlockquoteObserver = NotificationCenter.default.addObserver(
                forName: .toggleBlockquote, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleBlockquote") }

            toggleCodeBlockObserver = NotificationCenter.default.addObserver(
                forName: .toggleCodeBlock, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("toggleCodeBlock") }

            insertLinkObserver = NotificationCenter.default.addObserver(
                forName: .insertLink, object: nil, queue: .main
            ) { [weak self] _ in self?.executeFormatting("insertLink") }

            // Subscribe to zoom footnote state changes
            zoomFootnoteStateObserver = NotificationCenter.default.addObserver(
                forName: .setZoomFootnoteState,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let zoomed = notification.userInfo?["zoomed"] as? Bool,
                   let maxLabel = notification.userInfo?["maxLabel"] as? Int {
                    self?.setZoomFootnoteState(zoomed: zoomed, maxLabel: maxLabel)
                }
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
            if let observer = citationLibraryObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = refreshAllCitationsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = editorModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = spellcheckStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingSettingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = footnoteDefsObserver {
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
            if let observer = blockSyncPushObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = zoomFootnoteStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            // Formatting command observers cleanup
            for observer in [toggleBoldObserver, toggleItalicObserver, toggleStrikethroughObserver,
                             setHeadingObserver, toggleBulletListObserver, toggleNumberListObserver,
                             toggleBlockquoteObserver, toggleCodeBlockObserver, insertLinkObserver] {
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
        }
    }
}
