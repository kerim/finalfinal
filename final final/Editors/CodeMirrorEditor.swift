//
//  CodeMirrorEditor.swift
//  final final
//
//  WKWebView wrapper for CodeMirror 6 source editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

struct CodeMirrorEditor: NSViewRepresentable {
    @Binding var content: String
    @Binding var cursorPositionToRestore: CursorPosition?

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
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

        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false

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
        }

        deinit { pollingTimer?.invalidate() }

        func cleanup() {
            isCleanedUp = true
            pollingTimer?.invalidate()
            pollingTimer = nil
            webView = nil
        }

        func saveCursorPositionBeforeCleanup() {
            guard isEditorReady, let webView, !isCleanedUp else { return }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { [weak self] result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let line = dict["line"], let column = dict["column"] else { return }
                self?.onCursorPositionSaved(CursorPosition(line: line, column: column))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            print("[CodeMirrorEditor] WebView finished loading")

            webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, error in
                print("[CodeMirrorEditor] JS script check: \(result ?? "nil")")
            }

            webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
                print("[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
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
                self?.setCursorPosition(position)
                self?.cursorPositionToRestoreBinding.wrappedValue = nil
            }
        }

        // === WKScriptMessageHandler - handle JS error messages ===
        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "errorHandler", let body = message.body as? [String: Any] {
                let msgType = body["type"] as? String ?? "unknown"
                let errorMsg = body["message"] as? String ?? "unknown"
                print("[CodeMirrorEditor] JS \(msgType.uppercased()): \(errorMsg)")
            }
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
            let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`)") { _, error in
                if let error { print("[CodeMirrorEditor] setContent error: \(error)") }
            }
        }

        func setTheme(_ cssVariables: String) {
            guard isEditorReady, let webView else { return }
            let escaped = cssVariables.replacingOccurrences(of: "`", with: "\\`")
            webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
        }

        func getCursorPosition(completion: @escaping (CursorPosition) -> Void) {
            guard isEditorReady, let webView else {
                print("[CodeMirrorEditor] getCursorPosition: editor not ready, returning line 1 col 0")
                completion(.start)
                return
            }
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, error in
                if let error = error {
                    print("[CodeMirrorEditor] getCursorPosition error: \(error)")
                    completion(.start)
                    return
                }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                      let line = dict["line"], let column = dict["column"] else {
                    print("[CodeMirrorEditor] getCursorPosition: failed to parse JSON")
                    completion(.start)
                    return
                }
                let pos = CursorPosition(line: line, column: column)
                print("[CodeMirrorEditor] getCursorPosition returned: line \(pos.line) col \(pos.column)")
                completion(pos)
            }
        }

        func setCursorPosition(_ position: CursorPosition) {
            print("[CodeMirrorEditor] setCursorPosition called with: line \(position.line) col \(position.column)")
            guard isEditorReady, let webView else {
                print("[CodeMirrorEditor] setCursorPosition: editor not ready")
                return
            }
            webView.evaluateJavaScript(
                "window.FinalFinal.setCursorPosition({line: \(position.line), column: \(position.column)})"
            ) { _, error in
                if let error = error {
                    print("[CodeMirrorEditor] setCursorPosition error: \(error)")
                }
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
