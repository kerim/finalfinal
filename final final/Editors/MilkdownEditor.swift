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

    let onContentChange: (String) -> Void
    let onStatsChange: (Int, Int) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

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
        Coordinator(content: $content, onContentChange: onContentChange, onStatsChange: onStatsChange)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        private var contentBinding: Binding<String>
        private let onContentChange: (String) -> Void
        private let onStatsChange: (Int, Int) -> Void

        private var pollingTimer: Timer?
        private var lastReceivedFromEditor: Date = .distantPast
        private var lastPushedContent: String = ""

        var lastFocusModeState: Bool = false
        var lastThemeCss: String = ""
        private var isEditorReady = false
        private var isCleanedUp = false

        init(content: Binding<String>, onContentChange: @escaping (String) -> Void, onStatsChange: @escaping (Int, Int) -> Void) {
            self.contentBinding = content
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            super.init()
        }

        deinit { pollingTimer?.invalidate() }

        func cleanup() {
            isCleanedUp = true
            pollingTimer?.invalidate()
            pollingTimer = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[MilkdownEditor] WebView finished loading")
            isEditorReady = true
            setContent(contentBinding.wrappedValue)
            setTheme(ThemeManager.shared.cssVariables)
            startPolling()
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
