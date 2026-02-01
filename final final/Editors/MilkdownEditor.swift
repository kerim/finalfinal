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
    }
}

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var isResettingContent: Bool

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    func makeNSView(context: Context) -> WKWebView {
        // Try to use preloaded WebView for faster startup
        if let preloaded = EditorPreloader.shared.claimMilkdownView() {
            // Re-register message handlers with this coordinator
            let controller = preloaded.configuration.userContentController
            controller.add(context.coordinator, name: "errorHandler")
            controller.add(context.coordinator, name: "searchCitations")
            controller.add(context.coordinator, name: "openCitationPicker")

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
        if context.coordinator.lastFocusModeState != focusModeEnabled {
            context.coordinator.lastFocusModeState = focusModeEnabled
            context.coordinator.setFocusMode(focusModeEnabled)
        }

        if context.coordinator.shouldPushContent(content) {
            context.coordinator.setContent(content)
        }

        let cssVars = ThemeManager.shared.cssVariables
        if context.coordinator.lastThemeCss != cssVars {
            context.coordinator.lastThemeCss = cssVars
            context.coordinator.setTheme(cssVars)
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
            onCursorPositionSaved: onCursorPositionSaved
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
        private var toggleObserver: NSObjectProtocol?
        private var insertBreakObserver: NSObjectProtocol?
        private var annotationDisplayModesObserver: NSObjectProtocol?
        private var insertAnnotationObserver: NSObjectProtocol?
        private var toggleHighlightObserver: NSObjectProtocol?
        private var citationLibraryObserver: NSObjectProtocol?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        private var pendingCursorRestore: CursorPosition?

        /// Last sent annotation display modes (to avoid redundant calls)
        private var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.isResettingContentBinding = isResettingContent
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onCursorPositionSaved = onCursorPositionSaved
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
            webView = nil
        }

        func insertSectionBreak() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.insertBreak()") { _, _ in }
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
        }

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
        }

        /// Batch initialization - sends all setup data in a single JS call
        private func batchInitialize() {
            guard let webView else { return }

            let content = contentBinding.wrappedValue
            let theme = ThemeManager.shared.cssVariables
            let cursor = cursorPositionToRestoreBinding.wrappedValue

            let cursorJS: String
            if let pos = cursor {
                cursorJS = "{line:\(pos.line),column:\(pos.column)}"
            } else {
                cursorJS = "null"
            }

            let script = """
            window.FinalFinal.initialize({
                content: `\(content.escapedForJSTemplateLiteral)`,
                theme: `\(theme.escapedForJSTemplateLiteral)`,
                cursorPosition: \(cursorJS)
            })
            """

            webView.evaluateJavaScript(script) { [weak self] _, error in
                if let error {
                    #if DEBUG
                    print("[MilkdownEditor] Initialize error: \(error.localizedDescription)")
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
                print("[MilkdownEditor DEBUG] handleOpenCitationPicker: webView is nil")
                return
            }

            print("[MilkdownEditor DEBUG] === handleOpenCitationPicker called ===")
            print("[MilkdownEditor DEBUG] cmdStart: \(cmdStart)")

            // Query debug state before calling Zotero
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCAYWDebugState())") { result, error in
                if let error {
                    print("[MilkdownEditor DEBUG] Pre-picker state query error: \(error)")
                } else {
                    print("[MilkdownEditor DEBUG] Pre-picker state: \(String(describing: result))")
                }
            }

            do {
                print("[MilkdownEditor DEBUG] Calling ZoteroService.openCAYWPicker()...")

                // Call CAYW picker - this blocks until user selects references
                let (parsed, items) = try await ZoteroService.shared.openCAYWPicker()

                print("[MilkdownEditor DEBUG] ZoteroService returned successfully")
                print("[MilkdownEditor DEBUG] Parsed citekeys: \(parsed.citekeys)")
                print("[MilkdownEditor DEBUG] Items count: \(items.count)")

                // Bring app back to foreground after Zotero picker closes
                NSApp.activate(ignoringOtherApps: true)

                // Encode CSL items as JSON for web
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let itemsData = try encoder.encode(items)
                guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                    print("[MilkdownEditor] Failed to encode CSL items")
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
                    print("[MilkdownEditor] Failed to encode callback data")
                    sendCitationPickerError(webView: webView, message: "Failed to encode callback data")
                    return
                }

                print("[MilkdownEditor DEBUG] CAYW success: \(parsed.citekeys)")

                // Query debug state before callback
                webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCAYWDebugState())") { result, error in
                    if let error {
                        print("[MilkdownEditor DEBUG] Pre-callback state query error: \(error)")
                    } else {
                        print("[MilkdownEditor DEBUG] Pre-callback state: \(String(describing: result))")
                    }
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
                print("[MilkdownEditor DEBUG] About to call citationPickerCallback")
                print("[MilkdownEditor DEBUG] Script length: \(script.count)")

                webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        print("[MilkdownEditor DEBUG] evaluateJavaScript ERROR: \(error)")
                    } else {
                        print("[MilkdownEditor DEBUG] evaluateJavaScript succeeded, result: \(String(describing: result))")
                    }

                    // Query debug state after callback
                    webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCAYWDebugState())") { result, error in
                        if let error {
                            print("[MilkdownEditor DEBUG] Post-callback state query error: \(error)")
                        } else {
                            print("[MilkdownEditor DEBUG] Post-callback state: \(String(describing: result))")
                        }
                    }
                }
            } catch ZoteroError.userCancelled {
                // User cancelled - bring app back to foreground, no error
                NSApp.activate(ignoringOtherApps: true)
                print("[MilkdownEditor DEBUG] CAYW cancelled by user")
                sendCitationPickerCancelled(webView: webView)
            } catch ZoteroError.notRunning {
                NSApp.activate(ignoringOtherApps: true)
                print("[MilkdownEditor DEBUG] Zotero not running")
                sendCitationPickerError(webView: webView, message: "Zotero is not running. Please open Zotero and try again.")
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                print("[MilkdownEditor DEBUG] CAYW error: \(error.localizedDescription)")
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

        func shouldPushContent(_ newContent: String) -> Bool {
            let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
            if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
            return newContent != lastPushedContent
        }

        func setContent(_ markdown: String) {
            guard isEditorReady, let webView else { return }
            lastPushedContent = markdown
            lastPushTime = Date()  // Record push time to prevent poll feedback
            let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`)") { _, _ in }
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

            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let content = result as? String else { return }

                // Double-check reset flag in callback (may have changed)
                guard !self.isResettingContentBinding.wrappedValue else { return }

                // Grace period guard: don't overwrite recent pushes (race condition fix)
                let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
                if timeSincePush < 0.3 && content != self.lastPushedContent {
                    return  // JS hasn't processed our push yet
                }

                guard content != self.lastPushedContent else { return }

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
