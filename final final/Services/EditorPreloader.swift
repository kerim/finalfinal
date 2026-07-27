//
//  EditorPreloader.swift
//  final final
//
//  Pre-loads Milkdown and CodeMirror WebViews during app launch so they're
//  ready when the editor appears, eliminating cold start delay for both modes.
//

import WebKit

@MainActor
final class EditorPreloader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = EditorPreloader()

    enum State {
        case idle
        case loading
        case ready
        case failed(Error)
        case claimed
    }

    private var preloadedMilkdownView: WKWebView?
    private var preloadedCodeMirrorView: WKWebView?
    private(set) var milkdownState: State = .idle
    private(set) var codemirrorState: State = .idle

    private override init() {
        super.init()
    }

    private var preloadFrameSize: CGSize {
        NSScreen.screens.first?.frame.size ?? CGSize(width: 1200, height: 800)
    }

    /// Call from AppDelegate.applicationDidFinishLaunching
    func startPreloading() {
        guard !TestMode.isTesting else { return }
        startMilkdownPreloading()
        startCodeMirrorPreloading()
    }

    // MARK: - Milkdown Preloading

    private func startMilkdownPreloading() {
        guard case .idle = milkdownState else { return }
        milkdownState = .loading

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")

        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    console.error('[Milkdown JS ERROR]', msg, 'at', url, line, col, error);
                    window.webkit?.messageHandlers?.errorHandler?.postMessage({
                        type: 'error',
                        message: '[Milkdown] ' + msg,
                        url: url,
                        line: line,
                        column: col,
                        error: error ? error.toString() : null,
                        phase: 'preload'
                    });
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('[Milkdown JS REJECTION]', e.reason);
                    window.webkit?.messageHandlers?.errorHandler?.postMessage({
                        type: 'unhandledrejection',
                        message: '[Milkdown] Unhandled Promise Rejection: ' + e.reason,
                        url: '',
                        line: 0,
                        column: 0,
                        error: e.reason ? e.reason.toString() : null,
                        phase: 'preload'
                    });
                });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)
        // userContentController.add retains the handler (self) strongly, creating a
        // preloader<->webview reference cycle until claimMilkdownView() removes it below.
        // Intentional and acceptable for a short-lived preload window, not a leak.
        configuration.userContentController.add(self, name: "errorHandler")

        let webView = WKWebView(frame: CGRect(origin: .zero, size: preloadFrameSize), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://milkdown/milkdown.html") else {
            assertionFailure("[EditorPreloader] Invalid Milkdown preload URL")
            milkdownState = .idle
            return
        }

        DebugLog.log(.editor, "[EditorPreloader] Starting Milkdown preload")

        webView.load(URLRequest(url: url))
        preloadedMilkdownView = webView
    }

    // MARK: - CodeMirror Preloading

    private func startCodeMirrorPreloading() {
        guard case .idle = codemirrorState else { return }
        codemirrorState = .loading

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")

        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    console.error('[CodeMirror JS ERROR]', msg, 'at', url, line, col, error);
                    window.webkit?.messageHandlers?.errorHandler?.postMessage({
                        type: 'error',
                        message: '[CodeMirror] ' + msg,
                        url: url,
                        line: line,
                        column: col,
                        error: error ? error.toString() : null,
                        phase: 'preload'
                    });
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('[CodeMirror JS REJECTION]', e.reason);
                    window.webkit?.messageHandlers?.errorHandler?.postMessage({
                        type: 'unhandledrejection',
                        message: '[CodeMirror] Unhandled Promise Rejection: ' + e.reason,
                        url: '',
                        line: 0,
                        column: 0,
                        error: e.reason ? e.reason.toString() : null,
                        phase: 'preload'
                    });
                });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)
        // userContentController.add retains the handler (self) strongly, creating a
        // preloader<->webview reference cycle until claimCodeMirrorView() removes it below.
        // Intentional and acceptable for a short-lived preload window, not a leak.
        configuration.userContentController.add(self, name: "errorHandler")

        let webView = WKWebView(frame: CGRect(origin: .zero, size: preloadFrameSize), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://codemirror/codemirror.html") else {
            assertionFailure("[EditorPreloader] Invalid CodeMirror preload URL")
            codemirrorState = .idle
            return
        }

        DebugLog.log(.editor, "[EditorPreloader] Starting CodeMirror preload")

        webView.load(URLRequest(url: url))
        preloadedCodeMirrorView = webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === preloadedMilkdownView {
            milkdownState = .ready
            DebugLog.log(.editor, "[EditorPreloader] Milkdown preload complete")
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .ready
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror preload complete")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] Milkdown preload failed: \(error.localizedDescription)")
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror preload failed: \(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] Milkdown navigation failed: \(error.localizedDescription)")
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror navigation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wait

    /// Wait until both preloads are terminal (ready or failed), with timeout.
    /// Returns true if both ready, false on timeout or any failure.
    func waitUntilReady(timeout: TimeInterval = 2.0) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.05  // 50ms polling

        while Date().timeIntervalSince(startTime) < timeout {
            let milkdownTerminal = isTerminal(milkdownState)
            let codemirrorTerminal = isTerminal(codemirrorState)

            if milkdownTerminal && codemirrorTerminal {
                // Both done — return true only if both ready
                if case .ready = milkdownState, case .ready = codemirrorState {
                    return true
                }
                return false
            }

            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }

        return false
    }

    private func isTerminal(_ state: State) -> Bool {
        switch state {
        case .ready, .failed, .claimed:
            return true
        case .idle, .loading:
            return false
        }
    }

    // MARK: - WKScriptMessageHandler

    /// Route JS console/error messages fired during the preload window to DebugLog.
    /// Mirrors the "errorHandler" case in MilkdownCoordinator+MessageHandlers.swift so
    /// preload-time JS errors aren't silently dropped before an editor is claimed.
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "errorHandler", let body = message.body as? [String: Any] else { return }
        let msgType = body["type"] as? String ?? "unknown"
        let msg = body["message"] as? String ?? "unknown"
        // window.onerror/unhandledrejection payloads (see errorScript above) tag themselves
        // with phase: 'preload' so a DebugLog line can be told apart from the same error
        // shape logged post-claim via MilkdownCoordinator+MessageHandlers.swift /
        // CodeMirrorCoordinator+Handlers.swift (which never set this field).
        let phase = body["phase"] as? String
        let prefix = phase == "preload" ? "[EditorPreloader][Preload]" : "[EditorPreloader]"

        switch msgType {
        case "sync-diag":
            DebugLog.log(.sync, "\(prefix) JS SYNC-DIAG: \(msg)")
        case "debug", "slash-diag":
            DebugLog.log(.editor, "\(prefix) JS \(msgType.uppercased()): \(msg)")
        case "plugin-error", "unhandledrejection", "error":
            DebugLog.log(.editor, "\(prefix) JS ERROR: \(msg)")
        default:
            DebugLog.log(.editor, "\(prefix) JS \(msgType.uppercased()): \(msg)")
        }
    }

    // MARK: - Claim

    /// Claims the preloaded Milkdown WebView, transferring ownership to the caller.
    /// Returns nil if not ready. Automatically starts preloading a replacement.
    func claimMilkdownView() -> WKWebView? {
        guard case .ready = milkdownState, let view = preloadedMilkdownView else {
            DebugLog.log(.editor, "[EditorPreloader] Milkdown claim failed: state=\(milkdownState)")
            return nil
        }
        preloadedMilkdownView = nil
        DebugLog.log(.editor, "[EditorPreloader] Milkdown WebView claimed successfully")

        restartMilkdownPreloading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler")
        return view
    }

    /// Claims the preloaded CodeMirror WebView, transferring ownership to the caller.
    /// Returns nil if not ready. Automatically starts preloading a replacement.
    func claimCodeMirrorView() -> WKWebView? {
        guard case .ready = codemirrorState, let view = preloadedCodeMirrorView else {
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror claim failed: state=\(codemirrorState)")
            return nil
        }
        preloadedCodeMirrorView = nil
        DebugLog.log(.editor, "[EditorPreloader] CodeMirror WebView claimed successfully")

        restartCodeMirrorPreloading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "errorHandler")
        return view
    }

    // MARK: - Restart

    /// Restart Milkdown preloading (used after claim or for new projects)
    func restartMilkdownPreloading() {
        preloadedMilkdownView = nil
        milkdownState = .idle
        startMilkdownPreloading()
    }

    /// Restart CodeMirror preloading (used after claim or for new projects)
    func restartCodeMirrorPreloading() {
        preloadedCodeMirrorView = nil
        codemirrorState = .idle
        startCodeMirrorPreloading()
    }

    /// Restart both preloaders (convenience for project switches)
    func restartPreloading() {
        restartMilkdownPreloading()
        restartCodeMirrorPreloading()
    }
}
