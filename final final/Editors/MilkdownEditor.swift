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

// MARK: - String Extension for JS Template Literal Escaping

extension String {
    /// Escapes string for use in JavaScript template literals
    var escapedForJSTemplateLiteral: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\r\n", with: "\n")  // Normalize Windows line endings
            .replacingOccurrences(of: "\r", with: "\n")    // Normalize old Mac line endings
            .replacingOccurrences(of: "\0", with: "")      // Remove null bytes
    }
}

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var isResettingContent: Bool

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement)
    var contentState: EditorContentState = .idle

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
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
            controller.add(context.coordinator, name: "errorHandler")
            controller.add(context.coordinator, name: "searchCitations")
            controller.add(context.coordinator, name: "openCitationPicker")
            controller.add(context.coordinator, name: "resolveCitekeys")

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
        configuration.userContentController.add(context.coordinator, name: "errorHandler")
        configuration.userContentController.add(context.coordinator, name: "searchCitations")
        configuration.userContentController.add(context.coordinator, name: "openCitationPicker")
        configuration.userContentController.add(context.coordinator, name: "resolveCitekeys")

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
        // Update content state and callbacks for coordinator
        context.coordinator.contentState = contentState
        context.coordinator.onContentAcknowledged = onContentAcknowledged

        if context.coordinator.lastFocusModeState != focusModeEnabled {
            context.coordinator.lastFocusModeState = focusModeEnabled
            context.coordinator.setFocusMode(focusModeEnabled)
        }

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
            contentState: contentState,
            onContentChange: onContentChange,
            onStatsChange: onStatsChange,
            onCursorPositionSaved: onCursorPositionSaved,
            onContentAcknowledged: onContentAcknowledged,
            onWebViewReady: onWebViewReady
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.saveCursorPositionBeforeCleanup()
        coordinator.cleanup()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        private var contentBinding: Binding<String>
        private var cursorPositionToRestoreBinding: Binding<CursorPosition?>
        private var scrollToOffsetBinding: Binding<Int?>
        private var isResettingContentBinding: Binding<Bool>
        private let onContentChange: (String) -> Void
        private let onStatsChange: (Int, Int) -> Void
        private let onCursorPositionSaved: (CursorPosition) -> Void

        private var pollingTimer: Timer?
        private var lastReceivedFromEditor: Date = .distantPast
        private var lastPushedContent: String = ""
        private var lastPushTime: Date = .distantPast

        var lastFocusModeState: Bool = false
        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false

        /// Current content state - used to suppress polling during transitions
        var contentState: EditorContentState = .idle

        /// Callback invoked after content is confirmed set in WebView
        /// Used for acknowledgement-based synchronization during zoom transitions
        var onContentAcknowledged: (() -> Void)?
        private var toggleObserver: NSObjectProtocol?
        private var insertBreakObserver: NSObjectProtocol?
        private var annotationDisplayModesObserver: NSObjectProtocol?
        private var insertAnnotationObserver: NSObjectProtocol?
        private var toggleHighlightObserver: NSObjectProtocol?
        private var citationLibraryObserver: NSObjectProtocol?
        private var refreshAllCitationsObserver: NSObjectProtocol?
        private var editorModeObserver: NSObjectProtocol?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        private var pendingCursorRestore: CursorPosition?

        /// Last sent annotation display modes (to avoid redundant calls)
        private var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            contentState: EditorContentState,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
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
        }

        func cleanup() {
            isCleanedUp = true
            pollingTimer?.invalidate()
            pollingTimer = nil
            if let observer = toggleObserver {
                NotificationCenter.default.removeObserver(observer)
                toggleObserver = nil
            }
            if let observer = insertBreakObserver {
                NotificationCenter.default.removeObserver(observer)
                insertBreakObserver = nil
            }
            if let observer = annotationDisplayModesObserver {
                NotificationCenter.default.removeObserver(observer)
                annotationDisplayModesObserver = nil
            }
            if let observer = insertAnnotationObserver {
                NotificationCenter.default.removeObserver(observer)
                insertAnnotationObserver = nil
            }
            if let observer = toggleHighlightObserver {
                NotificationCenter.default.removeObserver(observer)
                toggleHighlightObserver = nil
            }
            if let observer = citationLibraryObserver {
                NotificationCenter.default.removeObserver(observer)
                citationLibraryObserver = nil
            }
            if let observer = refreshAllCitationsObserver {
                NotificationCenter.default.removeObserver(observer)
                refreshAllCitationsObserver = nil
            }
            if let observer = editorModeObserver {
                NotificationCenter.default.removeObserver(observer)
                editorModeObserver = nil
            }
            webView = nil
        }

        func insertSectionBreak() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.insertBreak()") { _, _ in }
        }

        /// Set editor appearance mode (WYSIWYG or source) - Phase C dual-appearance
        /// This toggles between rich text and markdown syntax view without swapping WebViews
        func setEditorAppearanceMode(_ mode: String) {
            guard isEditorReady, let webView else { return }
            let jsMode = mode.lowercased() == "source" ? "source" : "wysiwyg"
            webView.evaluateJavaScript("window.FinalFinal.setEditorMode('\(jsMode)')") { _, _ in }
        }

        /// Set annotation display modes in the editor
        /// - Parameters:
        ///   - modes: Per-type display modes (inline/collapsed)
        ///   - isPanelOnly: Global toggle to hide all annotations from editor
        ///   - hideCompletedTasks: Filter to hide completed task annotations
        func setAnnotationDisplayModes(
            _ modes: [AnnotationType: AnnotationDisplayMode],
            isPanelOnly: Bool = false,
            hideCompletedTasks: Bool = false
        ) {
            guard isEditorReady, let webView else { return }

            // Convert to JSON-friendly format
            var modeDict: [String: String] = [:]
            for (type, mode) in modes {
                modeDict[type.rawValue] = mode.rawValue
            }
            // Add special keys for global settings
            modeDict["__panelOnly"] = isPanelOnly ? "true" : "false"
            modeDict["__hideCompletedTasks"] = hideCompletedTasks ? "true" : "false"

            guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let script = "window.FinalFinal.setAnnotationDisplayModes(\(jsonString))"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        /// Insert an annotation at the current cursor position
        func insertAnnotation(type: AnnotationType) {
            guard isEditorReady, let webView else { return }
            let script = "window.FinalFinal.insertAnnotation('\(type.rawValue)')"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        /// Toggle highlight mark on selected text (Cmd+Shift+H)
        func toggleHighlight() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.toggleHighlight()") { _, _ in }
        }

        /// Push citation library to the editor for search and formatting
        func setCitationLibrary(_ itemsJSON: String) {
            guard isEditorReady, let webView else { return }
            // Escape for JavaScript template literal:
            // 1. Backslashes first (to avoid double-escaping)
            // 2. Backticks (template delimiter)
            // 3. ${  (template interpolation)
            let escaped = itemsJSON
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")
            webView.evaluateJavaScript("window.FinalFinal.setCitationLibrary(JSON.parse(`\(escaped)`))") { _, _ in }
        }

        /// Set CSL style for citation formatting
        func setCitationStyle(_ styleXML: String) {
            guard isEditorReady, let webView else { return }
            let escaped = styleXML.replacingOccurrences(of: "`", with: "\\`")
            webView.evaluateJavaScript("window.FinalFinal.setCitationStyle(`\(escaped)`)") { _, _ in }
        }

        /// Get all citekeys used in the document (for bibliography generation)
        func getBibliographyCitekeys(completion: @escaping ([String]) -> Void) {
            guard isEditorReady, let webView else {
                completion([])
                return
            }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getBibliographyCitekeys())") { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let keys = try? JSONDecoder().decode([String].self, from: data) else {
                    completion([])
                    return
                }
                completion(keys)
            }
        }

        func saveCursorPositionBeforeCleanup() {
            guard isEditorReady, let webView, !isCleanedUp else { return }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { [weak self] result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let line = dict["line"] as? Int,
                      let column = dict["column"] as? Int else { return }
                self?.onCursorPositionSaved(CursorPosition(line: line, column: column))
            }
        }

        /// Save cursor and post notification for two-phase toggle
        /// IMPORTANT: Also syncs content to binding BEFORE cursor save to prevent content loss
        private func saveAndNotify() {
            guard isEditorReady, let webView, !isCleanedUp else {
                // Editor not ready - post notification with start position
                NotificationCenter.default.post(
                    name: .didSaveCursorPosition,
                    object: nil,
                    userInfo: ["position": CursorPosition.start]
                )
                return
            }

            // RACE CONDITION FIX: If we have a pending cursor restore that hasn't completed,
            // use that position instead of reading from the editor (which would return wrong value)
            if let pending = pendingCursorRestore {
                NotificationCenter.default.post(
                    name: .didSaveCursorPosition,
                    object: nil,
                    userInfo: ["position": pending]
                )
                return
            }

            // CONTENT SYNC: Fetch and save content BEFORE cursor to prevent content loss during toggle
            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] contentResult, contentError in
                guard let self, !self.isCleanedUp else {
                    self?.saveCursorAndNotify()
                    return
                }

                if let content = contentResult as? String {
                    // DEFENSIVE: Don't overwrite non-empty content with empty content
                    // This can happen when Milkdown fails to initialize (JS exception)
                    let existingContent = self.contentBinding.wrappedValue
                    if content.isEmpty && !existingContent.isEmpty {
                        // Skip - don't overwrite good content with empty
                    } else {
                        // Update binding immediately to ensure content is preserved
                        self.lastPushedContent = content
                        self.contentBinding.wrappedValue = content
                    }
                }

                // Now save cursor position
                self.saveCursorAndNotify()
            }
        }

        /// Internal: save cursor position and post notification
        private func saveCursorAndNotify() {
            guard let webView, !isCleanedUp else {
                NotificationCenter.default.post(
                    name: .didSaveCursorPosition,
                    object: nil,
                    userInfo: ["position": CursorPosition.start]
                )
                return
            }

            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, _ in
                var position = CursorPosition.start
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let line = dict["line"] as? Int,
                   let column = dict["column"] as? Int {
                    position = CursorPosition(line: line, column: column)
                }

                NotificationCenter.default.post(
                    name: .didSaveCursorPosition,
                    object: nil,
                    userInfo: ["position": position]
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isEditorReady = true
            batchInitialize()
            startPolling()

            // Push cached citation library to editor (ensures citations format correctly
            // when switching from CodeMirror where CSL items were fetched)
            pushCachedCitationLibrary()

            // Notify parent that WebView is ready (for find operations)
            onWebViewReady?(webView)
        }

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        /// Push cached CSL items from ZoteroService to the editor's citeproc engine
        private func pushCachedCitationLibrary() {
            let zotero = ZoteroService.shared
            let cachedJSON = zotero.cachedItemsJSON()

            // Only push if there are cached items
            if cachedJSON != "[]" {
                print("[MilkdownEditor] Pushing \(zotero.cachedItems.count) cached CSL items to editor")
                setCitationLibrary(cachedJSON)
            }
        }

        /// Called when using a preloaded WebView (navigation already finished)
        func handlePreloadedView() {
            isEditorReady = true
            batchInitialize()
            startPolling()
            pushCachedCitationLibrary()

            // Notify parent that WebView is ready (for find operations)
            if let webView = webView {
                onWebViewReady?(webView)
            }
        }

        /// Batch initialization - sends all setup data in a single JS call
        private func batchInitialize() {
            guard let webView else { return }

            let content = contentBinding.wrappedValue
            let theme = ThemeManager.shared.cssVariables
            let cursor = cursorPositionToRestoreBinding.wrappedValue

            #if DEBUG
            print("[MilkdownEditor] batchInitialize: content length=\(content.count)")
            #endif

            // First check if window.FinalFinal exists
            webView.evaluateJavaScript("typeof window.FinalFinal") { [weak self] result, error in
                guard let self else { return }

                #if DEBUG
                if let error {
                    print("[MilkdownEditor] FinalFinal check failed: \(error.localizedDescription)")
                } else {
                    print("[MilkdownEditor] FinalFinal type: \(result ?? "nil")")
                }
                #endif

                // If FinalFinal doesn't exist yet, schedule retry
                if result as? String != "object" {
                    #if DEBUG
                    print("[MilkdownEditor] FinalFinal not ready, scheduling retry in 100ms")
                    #endif
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.batchInitialize()
                    }
                    return
                }

                self.performBatchInitialize(content: content, theme: theme, cursor: cursor)
            }
        }

        /// Actually perform the batch initialization after verifying FinalFinal exists
        private func performBatchInitialize(content: String, theme: String, cursor: CursorPosition?) {
            guard let webView else { return }

            // Build options dictionary for JSON encoding
            // Using JSON instead of template literals handles ALL special characters safely
            var options: [String: Any] = [
                "content": content,
                "theme": theme
            ]
            if let pos = cursor {
                options["cursorPosition"] = ["line": pos.line, "column": pos.column]
            } else {
                options["cursorPosition"] = NSNull()
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: options),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                #if DEBUG
                print("[MilkdownEditor] Failed to encode options as JSON")
                #endif
                return
            }

            #if DEBUG
            print("[MilkdownEditor] Initialize with content length: \(content.count) chars")
            let preview = String(content.prefix(200))
            print("[MilkdownEditor] Content preview: \(preview)...")
            #endif

            // Pass JSON directly - JSON is valid JavaScript object literal syntax
            let script = "window.FinalFinal.initialize(\(jsonString))"

            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    #if DEBUG
                    print("[MilkdownEditor] Initialize error: \(error.localizedDescription)")
                    // Check if it's a parsing error by trying to set empty content
                    webView.evaluateJavaScript("window.FinalFinal.setContent('')") { _, err2 in
                        if let err2 {
                            print("[MilkdownEditor] Even empty setContent failed: \(err2.localizedDescription)")
                        } else {
                            print("[MilkdownEditor] Empty setContent worked - content may have parse issue")
                        }
                    }
                    #endif
                    // DEFENSIVE: If initialization failed, mark editor as NOT ready
                    // so polling won't try to read from broken editor
                    self?.isEditorReady = false
                } else {
                    #if DEBUG
                    print("[MilkdownEditor] Initialize successful")
                    #endif
                }
                self?.cursorPositionToRestoreBinding.wrappedValue = nil
            }
        }

        /// Focus the editor so user can start typing immediately
        private func focusEditor() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.focus()") { _, _ in }
        }

        private func restoreCursorPositionIfNeeded() {
            guard let position = cursorPositionToRestoreBinding.wrappedValue else { return }
            // Small delay to ensure content is fully loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setCursorPosition(position) {
                    // Scroll cursor to center after cursor is set
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.scrollCursorToCenter()
                    }
                }
                self?.cursorPositionToRestoreBinding.wrappedValue = nil
            }
        }

        func scrollCursorToCenter() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.scrollCursorToCenter()") { _, _ in }
        }

        // Handle JS messages from WKScriptMessageHandler
        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            #if DEBUG
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                print("[MilkdownEditor] JS \(msgType.uppercased()): \(errorMsg)")
            }
            #endif

            // Handle citation search requests from web editor (legacy)
            if message.name == "searchCitations", let query = message.body as? String {
                Task { @MainActor in
                    await self.handleCitationSearch(query)
                }
            }

            // Handle CAYW citation picker request from web editor
            if message.name == "openCitationPicker", let cmdStart = message.body as? Int {
                Task { @MainActor in
                    await self.handleOpenCitationPicker(cmdStart: cmdStart)
                }
            }

            // Handle lazy citation resolution request from web editor
            if message.name == "resolveCitekeys", let citekeys = message.body as? [String] {
                Task { @MainActor in
                    await self.handleResolveCitekeys(citekeys)
                }
            }
        }

        /// Handle citation search request from web editor
        /// Splits multi-term queries: first term goes to BBT, additional terms filter client-side
        @MainActor
        private func handleCitationSearch(_ query: String) async {
            guard let webView else { return }

            print("[MilkdownEditor] Citation search: '\(query)'")

            // Split query into terms (BBT search only supports single-term reliably)
            let terms = query.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }

            guard !terms.isEmpty else {
                sendCitationSearchCallback(webView: webView, json: "[]")
                return
            }

            // Use first term for BBT search
            let searchTerm = terms[0]
            let filterTerms = Array(terms.dropFirst()).map { $0.lowercased() }

            do {
                var items = try await ZoteroService.shared.search(query: searchTerm)

                // Client-side filtering for additional terms
                if !filterTerms.isEmpty {
                    items = items.filter { item in
                        let searchText = item.searchText.lowercased()
                        return filterTerms.allSatisfy { searchText.contains($0) }
                    }
                }

                print("[MilkdownEditor] Search returned \(items.count) results (filter terms: \(filterTerms))")

                // Encode results as JSON
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(items)
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    sendCitationSearchCallback(webView: webView, json: "[]")
                    return
                }

                sendCitationSearchCallback(webView: webView, json: jsonString)
            } catch {
                print("[MilkdownEditor] Citation search error: \(error.localizedDescription)")
                sendCitationSearchCallback(webView: webView, json: "[]")
            }
        }

        /// Send search results back to web editor via callback
        @MainActor
        private func sendCitationSearchCallback(webView: WKWebView, json: String) {
            // Escape for JavaScript template literal:
            // 1. Backslashes first (to avoid double-escaping)
            // 2. Backticks (template delimiter)
            // 3. ${  (template interpolation)
            let escaped = json
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")
            webView.evaluateJavaScript("window.FinalFinal.searchCitationsCallback(JSON.parse(`\(escaped)`))") { _, _ in }
        }

        /// Handle CAYW citation picker request from web editor
        /// Opens Zotero's native citation picker, returns parsed citation + CSL items
        @MainActor
        private func handleOpenCitationPicker(cmdStart: Int) async {
            guard let webView else {
                return
            }

            do {
                // Call CAYW picker - this blocks until user selects references
                let (parsed, items) = try await ZoteroService.shared.openCAYWPicker()

                // Bring app back to foreground after Zotero picker closes
                NSApp.activate(ignoringOtherApps: true)

                // Encode CSL items as JSON for web
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let itemsData = try encoder.encode(items)
                guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                    sendCitationPickerError(webView: webView, message: "Failed to encode citation data")
                    return
                }

                // Build callback data object
                let callbackData: [String: Any] = [
                    "rawSyntax": parsed.rawSyntax,
                    "citekeys": parsed.citekeys,
                    "locators": parsed.locatorsJSON,
                    "prefix": parsed.entries.first?.prefix ?? "",
                    "suppressAuthor": parsed.entries.first?.suppressAuthor ?? false,
                    "cmdStart": cmdStart
                ]

                guard let callbackJSON = try? JSONSerialization.data(withJSONObject: callbackData),
                      let callbackStr = String(data: callbackJSON, encoding: .utf8) else {
                    sendCitationPickerError(webView: webView, message: "Failed to encode callback data")
                    return
                }

                // Send both parsed data and CSL items to web editor
                let escapedCallback = callbackStr
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                let escapedItems = itemsJSON
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")

                let script = "window.FinalFinal.citationPickerCallback(JSON.parse(`\(escapedCallback)`), JSON.parse(`\(escapedItems)`))"
                webView.evaluateJavaScript(script) { _, _ in }
            } catch ZoteroError.userCancelled {
                // User cancelled - bring app back to foreground, no error
                NSApp.activate(ignoringOtherApps: true)
                sendCitationPickerCancelled(webView: webView)
            } catch ZoteroError.notRunning {
                NSApp.activate(ignoringOtherApps: true)
                sendCitationPickerError(webView: webView, message: "Zotero is not running. Please open Zotero and try again.")
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                sendCitationPickerError(webView: webView, message: error.localizedDescription)
            }
        }

        /// Send citation picker error to web editor
        @MainActor
        private func sendCitationPickerError(webView: WKWebView, message: String) {
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "\"", with: "\\\"")
            webView.evaluateJavaScript("window.FinalFinal.citationPickerError(`\(escaped)`)") { _, _ in }
        }

        /// Send citation picker cancelled to web editor
        @MainActor
        private func sendCitationPickerCancelled(webView: WKWebView) {
            webView.evaluateJavaScript("window.FinalFinal.citationPickerCancelled()") { _, _ in }
        }

        /// Handle lazy citation resolution request from web editor
        /// Fetches CSL-JSON for unresolved citekeys and pushes back to editor
        @MainActor
        private func handleResolveCitekeys(_ citekeys: [String]) async {
            guard let webView, isEditorReady else {
                print("[MilkdownEditor] handleResolveCitekeys: webView or editor not ready")
                return
            }

            guard !citekeys.isEmpty else { return }

            print("[MilkdownEditor] Resolving \(citekeys.count) citekeys: \(citekeys)")

            do {
                // Fetch CSL items from Zotero via BBT
                let items = try await ZoteroService.shared.fetchItemsForCitekeys(citekeys)

                guard !items.isEmpty else {
                    print("[MilkdownEditor] No items found for citekeys")
                    return
                }

                print("[MilkdownEditor] Resolved \(items.count) items")

                // Encode as JSON
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(items)
                guard let json = String(data: data, encoding: .utf8) else {
                    print("[MilkdownEditor] Failed to encode items as JSON")
                    return
                }

                // Push items to editor
                addCitationItems(json)
            } catch ZoteroError.notRunning {
                print("[MilkdownEditor] Zotero not running - cannot resolve citekeys")
                // Don't show error to user for lazy resolution - just log it
            } catch {
                print("[MilkdownEditor] Failed to resolve citekeys: \(error.localizedDescription)")
            }
        }

        /// Push citation items to editor without replacing existing library
        @MainActor
        func addCitationItems(_ itemsJSON: String) {
            guard isEditorReady, let webView else { return }
            let escaped = itemsJSON.escapedForJSTemplateLiteral
            webView.evaluateJavaScript("window.FinalFinal.addCitationItems(JSON.parse(`\(escaped)`))") { _, _ in }
        }

        /// Refresh all citations in the document
        /// Gets all citekeys from the editor, fetches their CSL data, and pushes it back
        @MainActor
        func refreshAllCitations() async {
            guard isEditorReady, let webView else {
                print("[MilkdownEditor] refreshAllCitations: editor not ready")
                return
            }

            print("[MilkdownEditor] Refreshing all citations...")

            // Get all citekeys from the document
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getAllCitekeys())") { [weak self] result, error in
                guard let self else { return }

                if let error {
                    print("[MilkdownEditor] Failed to get citekeys: \(error.localizedDescription)")
                    return
                }

                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let citekeys = try? JSONDecoder().decode([String].self, from: data) else {
                    print("[MilkdownEditor] Failed to decode citekeys")
                    return
                }

                guard !citekeys.isEmpty else {
                    print("[MilkdownEditor] No citations in document")
                    return
                }

                print("[MilkdownEditor] Found \(citekeys.count) citekeys to refresh: \(citekeys)")

                // Fetch all citekeys from Zotero
                Task { @MainActor in
                    await self.handleResolveCitekeys(citekeys)
                }
            }
        }

        func shouldPushContent(_ newContent: String) -> Bool {
            let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
            if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
            return newContent != lastPushedContent
        }

        func setContent(_ markdown: String) {
            guard isEditorReady, let webView else { return }

            #if DEBUG
            // PASTE DEBUG: Log setContent calls with content preview and call stack
            let preview = String(markdown.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
            print("[MilkdownEditor] setContent called with \(markdown.count) chars: \(preview)...")
            print("[MilkdownEditor] setContent stack: \(Thread.callStackSymbols.prefix(8).joined(separator: "\n"))")
            #endif

            lastPushedContent = markdown
            lastPushTime = Date()  // Record push time to prevent poll feedback

            // Use JSONEncoder to properly encode string with all special characters escaped
            // JSONEncoder handles strings directly (unlike JSONSerialization which needs Array/Dict)
            guard let jsonData = try? JSONEncoder().encode(markdown),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                #if DEBUG
                print("[MilkdownEditor] setContent: Failed to encode markdown as JSON")
                #endif
                return
            }

            // Set content and then read it back to confirm (acknowledgement pattern)
            // This ensures WebView has processed the content before we continue
            webView.evaluateJavaScript("""
                window.FinalFinal.setContent(\(jsonString));
                window.FinalFinal.getContent();
            """) { [weak self] result, error in
                #if DEBUG
                if let result = result as? String {
                    let ackPreview = String(result.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
                    print("[MilkdownEditor] setContent acknowledged: \(result.count) chars: \(ackPreview)...")
                }
                #endif

                // Content is now confirmed set in WebView
                // Call acknowledgement callback if registered
                if let callback = self?.onContentAcknowledged {
                    self?.onContentAcknowledged = nil  // One-shot callback
                    callback()
                }
            }
        }

        func setFocusMode(_ enabled: Bool) {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.setFocusMode(\(enabled))") { _, _ in }
        }

        func setTheme(_ cssVariables: String) {
            guard isEditorReady, let webView else { return }
            let escaped = cssVariables.replacingOccurrences(of: "`", with: "\\`")
            webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
        }

        func scrollToOffset(_ offset: Int) {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.scrollToOffset(\(offset))") { _, _ in }
        }

        func getCursorPosition(completion: @escaping (CursorPosition) -> Void) {
            guard isEditorReady, let webView else {
                completion(.start)
                return
            }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let line = dict["line"] as? Int,
                      let column = dict["column"] as? Int else {
                    completion(.start)
                    return
                }
                completion(CursorPosition(line: line, column: column))
            }
        }

        func setCursorPosition(_ position: CursorPosition, completion: (() -> Void)? = nil) {
            guard isEditorReady, let webView else {
                completion?()
                return
            }

            // Track pending cursor restore to handle race conditions with toggle
            pendingCursorRestore = position

            webView.evaluateJavaScript(
                "window.FinalFinal.setCursorPosition({line: \(position.line), column: \(position.column)})"
            ) { [weak self] _, _ in
                // Clear pending restore now that JS has executed
                self?.pendingCursorRestore = nil
                completion?()
            }
        }

        private func startPolling() {
            pollingTimer?.invalidate()
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.pollContent()
                }
            }
        }

        private func pollContent() {
            guard !isCleanedUp, isEditorReady, let webView else { return }

            // Skip polling during content reset (project switch)
            guard !isResettingContentBinding.wrappedValue else { return }

            // Skip polling during content transitions (zoom, hierarchy enforcement)
            // This prevents stale content from being read during transitions
            guard contentState == .idle else { return }

            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let content = result as? String else { return }

                // Double-check reset flag in callback (may have changed)
                guard !self.isResettingContentBinding.wrappedValue else { return }

                // Double-check contentState in callback (may have changed)
                guard self.contentState == .idle else { return }

                // DEFENSIVE: Don't overwrite non-empty content with empty content
                // This can happen when Milkdown fails to initialize (JS exception)
                let existingContent = self.contentBinding.wrappedValue
                if content.isEmpty && !existingContent.isEmpty {
                    #if DEBUG
                    print("[MilkdownEditor] pollContent: BLOCKED empty content overwriting non-empty")
                    #endif
                    return  // Don't erase good content with empty from broken editor
                }

                // Grace period guard: don't overwrite recent pushes (race condition fix)
                // Extended from 300ms to 600ms to better match polling interval + processing time
                let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
                if timeSincePush < 0.6 && content != self.lastPushedContent {
                    #if DEBUG
                    let pollPreview = String(content.prefix(50)).replacingOccurrences(of: "\n", with: "\\n")
                    let pushPreview = String(self.lastPushedContent.prefix(50)).replacingOccurrences(of: "\n", with: "\\n")
                    print("[MilkdownEditor] pollContent: BLOCKED during grace period (\(String(format: "%.2f", timeSincePush))s)")
                    print("[MilkdownEditor]   polled: \(pollPreview)...")
                    print("[MilkdownEditor]   pushed: \(pushPreview)...")
                    #endif
                    return  // JS hasn't processed our push yet
                }

                guard content != self.lastPushedContent else { return }

                // DEFENSIVE: Reject clearly corrupted content from Milkdown serialization bugs
                // If we pushed a header and got back `<br />`, Milkdown's getMarkdown() is broken
                let pushedFirstLine = self.lastPushedContent.components(separatedBy: "\n").first ?? ""
                let polledFirstLine = content.components(separatedBy: "\n").first ?? ""

                if pushedFirstLine.hasPrefix("#") && polledFirstLine.hasPrefix("<br") {
                    print("[MilkdownEditor] REJECTED: Milkdown returned corrupted content")
                    print("[MilkdownEditor]   pushed first line: '\(pushedFirstLine)'")
                    print("[MilkdownEditor]   polled first line: '\(polledFirstLine)'")
                    return  // Don't accept corrupted content
                }

                // DIAGNOSTIC: Detect unexpected content length changes (e.g., missing heading markers)
                // This helps diagnose the section deletion cascade bug
                let lengthDiff = content.count - self.lastPushedContent.count
                if abs(lengthDiff) > 0 && abs(lengthDiff) <= 10 {
                    // Small length change (1-10 chars) might indicate missing # markers
                    if pushedFirstLine != polledFirstLine {
                        print("[MilkdownEditor] DIAGNOSTIC: First line changed unexpectedly")
                        print("[MilkdownEditor]   pushed first line: '\(pushedFirstLine)'")
                        print("[MilkdownEditor]   polled first line: '\(polledFirstLine)'")
                        print("[MilkdownEditor]   length diff: \(lengthDiff) chars")
                    }
                }

                #if DEBUG
                // PASTE DEBUG: Log when poll updates the binding
                let pollPreview = String(content.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
                print("[MilkdownEditor] pollContent: Updating binding with \(content.count) chars: \(pollPreview)...")
                print("[MilkdownEditor] pollContent: timeSincePush=\(String(format: "%.2f", timeSincePush))s")
                #endif

                self.lastReceivedFromEditor = Date()
                self.lastPushedContent = content
                self.contentBinding.wrappedValue = content
                self.onContentChange(content)
            }

            webView.evaluateJavaScript("window.FinalFinal.getStats()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let dict = result as? [String: Any],
                      let words = dict["words"] as? Int, let chars = dict["characters"] as? Int else { return }
                self.onStatsChange(words, chars)
            }
        }
    }
}
