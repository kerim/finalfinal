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
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var isResettingContent: Bool

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    func makeNSView(context: Context) -> WKWebView {
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

        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false
        private var toggleObserver: NSObjectProtocol?
        private var insertBreakObserver: NSObjectProtocol?
        private var annotationDisplayModesObserver: NSObjectProtocol?
        private var insertAnnotationObserver: NSObjectProtocol?
        private var toggleHighlightObserver: NSObjectProtocol?

        /// Last sent annotation display modes (to avoid redundant calls)
        private var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        private var pendingCursorRestore: CursorPosition?

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
            webView = nil
        }

        func insertSectionBreak() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.insertBreak()") { _, _ in }
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
            #if DEBUG
            print("[CodeMirrorEditor] WebView finished loading")

            webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, _ in
                print("[CodeMirrorEditor] JS script check: \(result ?? "nil")")
            }

            webView.evaluateJavaScript("typeof window.FinalFinal") { result, _ in
                print("[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
            }
            #endif

            isEditorReady = true
            setContent(contentBinding.wrappedValue)
            setTheme(ThemeManager.shared.cssVariables)
            restoreCursorPositionIfNeeded()
            focusEditor()
            startPolling()
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

        // Handle JS error messages and citation picker requests
        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            #if DEBUG
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                print("[CodeMirrorEditor] JS \(msgType.uppercased()): \(errorMsg)")
            }
            #endif

            // Handle CAYW citation picker request from web editor
            if message.name == "openCitationPicker", let cmdStart = message.body as? Int {
                Task { @MainActor in
                    await self.handleOpenCitationPicker(cmdStart: cmdStart)
                }
            }
        }

        /// Handle CAYW citation picker request from web editor
        @MainActor
        private func handleOpenCitationPicker(cmdStart: Int) async {
            guard let webView else {
                print("[CodeMirrorEditor] handleOpenCitationPicker: webView is nil")
                return
            }

            print("[CodeMirrorEditor] Opening CAYW picker, cmdStart: \(cmdStart)")

            do {
                // Call CAYW picker - this blocks until user selects references
                let (parsed, items) = try await ZoteroService.shared.openCAYWPicker()

                // Bring app back to foreground after Zotero picker closes
                NSApp.activate(ignoringOtherApps: true)

                print("[CodeMirrorEditor] CAYW returned citekeys: \(parsed.citekeys)")

                // Encode CSL items as JSON for web
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let itemsData = try encoder.encode(items)
                guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                    print("[CodeMirrorEditor] Failed to encode CSL items")
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
                    print("[CodeMirrorEditor] Failed to encode callback data")
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
                webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        print("[CodeMirrorEditor] citationPickerCallback error: \(error)")
                    } else {
                        print("[CodeMirrorEditor] citationPickerCallback succeeded")
                    }
                }
            } catch ZoteroError.userCancelled {
                NSApp.activate(ignoringOtherApps: true)
                print("[CodeMirrorEditor] CAYW cancelled by user")
                sendCitationPickerCancelled(webView: webView)
            } catch ZoteroError.notRunning {
                NSApp.activate(ignoringOtherApps: true)
                print("[CodeMirrorEditor] Zotero not running")
                sendCitationPickerError(webView: webView, message: "Zotero is not running. Please open Zotero and try again.")
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                print("[CodeMirrorEditor] CAYW error: \(error.localizedDescription)")
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

        // === Content push guard - prevent feedback loops ===
        func shouldPushContent(_ newContent: String) -> Bool {
            let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
            if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
            return newContent != lastPushedContent
        }

        // === JavaScript API calls ===
        func setContent(_ markdown: String) {
            guard isEditorReady, let webView else { return }
            lastPushedContent = markdown
            lastPushTime = Date()  // Record push time to prevent poll feedback
            let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`)") { _, _ in }
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

        // === 500ms content polling ===
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

        // MARK: - Annotation API

        /// Set annotation display modes (no-op in source mode, but call for consistency)
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

            var modeDict: [String: String] = [:]
            for (type, mode) in modes {
                modeDict[type.rawValue] = mode.rawValue
            }
            // Add special keys for global settings
            modeDict["__panelOnly"] = isPanelOnly ? "true" : "false"
            modeDict["__hideCompletedTasks"] = hideCompletedTasks ? "true" : "false"

            guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(jsonString))") { _, _ in }
        }

        /// Insert an annotation at the current cursor position
        func insertAnnotation(type: AnnotationType) {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.insertAnnotation('\(type.rawValue)')") { _, _ in }
        }

        /// Toggle highlight mark on selected text (Cmd+Shift+H)
        func toggleHighlight() {
            guard isEditorReady, let webView else { return }
            webView.evaluateJavaScript("window.FinalFinal.toggleHighlight()") { _, _ in }
        }
    }
}
