//
//  MilkdownEditor.swift
//  final final
//
//  WKWebView wrapper for Milkdown WYSIWYG editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

struct MilkdownEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
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

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        private var pendingCursorRestore: CursorPosition?

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
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
        }

        deinit {
            pollingTimer?.invalidate()
            if let observer = toggleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertBreakObserver {
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
            print("[MilkdownEditor] WebView finished loading")

            // === PHASE 2: Verify JavaScript execution from Swift side ===
            webView.evaluateJavaScript("typeof window.__MILKDOWN_SCRIPT_STARTED__") { result, error in
                if let error = error {
                    print("[MilkdownEditor] JS script check error: \(error)")
                } else {
                    print("[MilkdownEditor] JS script execution check: \(result ?? "nil") (should be 'number')")
                }
            }

            webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
                if let error = error {
                    print("[MilkdownEditor] FinalFinal check error: \(error)")
                } else {
                    print("[MilkdownEditor] window.FinalFinal type: \(result ?? "nil") (should be 'object')")
                }
            }

            webView.evaluateJavaScript("document.querySelector('#editor') !== null") { result, _ in
                print("[MilkdownEditor] #editor element exists: \(result ?? "unknown")")
            }

            // === PHASE 6: Query debug state ===
            webView.evaluateJavaScript("window.__MILKDOWN_DEBUG__ ? JSON.stringify(window.__MILKDOWN_DEBUG__) : 'not defined'") { result, error in
                if let error = error {
                    print("[MilkdownEditor] Debug state error: \(error)")
                } else {
                    print("[MilkdownEditor] Debug state: \(result ?? "nil")")
                }
            }
            #endif

            isEditorReady = true
            setContent(contentBinding.wrappedValue)
            setTheme(ThemeManager.shared.cssVariables)
            restoreCursorPositionIfNeeded()
            startPolling()
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

        // Handle JS error messages from WKScriptMessageHandler
        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            #if DEBUG
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                print("[MilkdownEditor] JS \(msgType.uppercased()): \(errorMsg)")
            }
            #endif
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

            webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                guard let self, !self.isCleanedUp,
                      let content = result as? String else { return }

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
