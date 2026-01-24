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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: $content,
            cursorPositionToRestore: $cursorPositionToRestore,
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
        private let onContentChange: (String) -> Void
        private let onStatsChange: (Int, Int) -> Void
        private let onCursorPositionSaved: (CursorPosition) -> Void

        private var pollingTimer: Timer?
        private var lastReceivedFromEditor: Date = .distantPast
        private var lastPushedContent: String = ""

        var lastFocusModeState: Bool = false
        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false
        private var toggleObserver: NSObjectProtocol?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        private var pendingCursorRestore: CursorPosition?

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            onContentChange: @escaping (String) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
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
        }

        deinit {
            pollingTimer?.invalidate()
            if let observer = toggleObserver {
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
            webView = nil
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
                print("[MilkdownEditor] saveAndNotify: editor not ready, returning start position")
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
                print("[MilkdownEditor] saveAndNotify: using pending cursor restore position line \(pending.line) col \(pending.column)")
                NotificationCenter.default.post(
                    name: .didSaveCursorPosition,
                    object: nil,
                    userInfo: ["position": pending]
                )
                return
            }

            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { [weak self] result, _ in
                // Query debug log first
                self?.queryDebugLog()

                var position = CursorPosition.start
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let line = dict["line"] as? Int,
                   let column = dict["column"] as? Int {
                    position = CursorPosition(line: line, column: column)
                }

                print("[MilkdownEditor] saveAndNotify: posting didSaveCursorPosition with line \(position.line) col \(position.column)")

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
            webView.evaluateJavaScript("window.FinalFinal.scrollCursorToCenter()") { _, error in
                if let error = error {
                    print("[MilkdownEditor] scrollCursorToCenter error: \(error)")
                }
            }
        }

        /// Query the JavaScript debug log for cursor position debugging
        func queryDebugLog() {
            guard isEditorReady, let webView else {
                print("[MilkdownEditor] queryDebugLog: editor not ready")
                return
            }
            webView.evaluateJavaScript("JSON.stringify(window.__MD_DEBUG_LOG__ || [])") { result, error in
                if let error = error {
                    print("[MilkdownEditor] queryDebugLog error: \(error)")
                    return
                }
                if let json = result as? String {
                    print("[MilkdownEditor] JS DEBUG LOG: \(json)")
                }
            }
        }

        // === PHASE 4: Handle JS error messages from WKScriptMessageHandler ===
        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                let url = body["url"] as? String ?? ""
                let line = body["line"] ?? ""
                let col = body["column"] ?? ""
                let error = body["error"] as? String ?? ""

                print("[MilkdownEditor] JS \(msgType.uppercased()): \(errorMsg)")
                if !url.isEmpty { print("  URL: \(url)") }
                print("  Line: \(line), Col: \(col)")
                if !error.isEmpty { print("  Error: \(error)") }
            }
        }

        func shouldPushContent(_ newContent: String) -> Bool {
            let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
            if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
            return newContent != lastPushedContent
        }

        func setContent(_ markdown: String) {
            guard isEditorReady, let webView else { return }
            lastPushedContent = markdown
            let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`)") { _, error in
                if let error { print("[MilkdownEditor] setContent error: \(error)") }
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

        func getCursorPosition(completion: @escaping (CursorPosition) -> Void) {
            guard isEditorReady, let webView else {
                print("[MilkdownEditor] getCursorPosition: editor not ready, returning line 1 col 0")
                completion(.start)
                return
            }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, error in
                if let error = error {
                    print("[MilkdownEditor] getCursorPosition error: \(error)")
                    completion(.start)
                    return
                }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let line = dict["line"] as? Int,
                      let column = dict["column"] as? Int else {
                    print("[MilkdownEditor] getCursorPosition: failed to parse JSON")
                    completion(.start)
                    return
                }
                let pos = CursorPosition(line: line, column: column)
                print("[MilkdownEditor] getCursorPosition returned: line \(pos.line) col \(pos.column)")
                completion(pos)
            }
        }

        func setCursorPosition(_ position: CursorPosition, completion: (() -> Void)? = nil) {
            print("[MilkdownEditor] setCursorPosition called with: line \(position.line) col \(position.column)")
            guard isEditorReady, let webView else {
                print("[MilkdownEditor] setCursorPosition: editor not ready")
                completion?()
                return
            }

            // Track pending cursor restore to handle race conditions with toggle
            pendingCursorRestore = position

            webView.evaluateJavaScript(
                "window.FinalFinal.setCursorPosition({line: \(position.line), column: \(position.column)})"
            ) { [weak self] _, error in
                if let error = error {
                    print("[MilkdownEditor] setCursorPosition error: \(error)")
                }
                // Clear pending restore now that JS has executed
                self?.pendingCursorRestore = nil
                // Query debug log to see what happened
                self?.queryDebugLog()
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
                      let content = result as? String, content != self.lastPushedContent else { return }
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
