//
//  EditorPreloader.swift
//  final final
//
//  Pre-loads Milkdown and CodeMirror WebViews during app launch so they're
//  ready when the editor appears, eliminating cold start delay for both modes.
//

import WebKit

@MainActor
final class EditorPreloader: NSObject, WKNavigationDelegate {
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

    /// Call from AppDelegate.applicationDidFinishLaunching
    func startPreloading() {
        guard !TestMode.isUITesting else { return }
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

        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    console.error('[Milkdown JS ERROR]', msg, 'at', url, line, col, error);
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('[Milkdown JS REJECTION]', e.reason);
                });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://milkdown/milkdown.html") else {
            assertionFailure("[EditorPreloader] Invalid Milkdown preload URL")
            milkdownState = .idle
            return
        }

        #if DEBUG
        print("[EditorPreloader] Starting Milkdown preload")
        #endif

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

        let errorScript = WKUserScript(
            source: """
                window.onerror = function(msg, url, line, col, error) {
                    console.error('[CodeMirror JS ERROR]', msg, 'at', url, line, col, error);
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('[CodeMirror JS REJECTION]', e.reason);
                });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(errorScript)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://codemirror/codemirror.html") else {
            assertionFailure("[EditorPreloader] Invalid CodeMirror preload URL")
            codemirrorState = .idle
            return
        }

        #if DEBUG
        print("[EditorPreloader] Starting CodeMirror preload")
        #endif

        webView.load(URLRequest(url: url))
        preloadedCodeMirrorView = webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === preloadedMilkdownView {
            milkdownState = .ready
            #if DEBUG
            print("[EditorPreloader] Milkdown preload complete")
            #endif
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .ready
            #if DEBUG
            print("[EditorPreloader] CodeMirror preload complete")
            #endif
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            #if DEBUG
            print("[EditorPreloader] Milkdown preload failed: \(error.localizedDescription)")
            #endif
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            #if DEBUG
            print("[EditorPreloader] CodeMirror preload failed: \(error.localizedDescription)")
            #endif
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            #if DEBUG
            print("[EditorPreloader] Milkdown navigation failed: \(error.localizedDescription)")
            #endif
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            #if DEBUG
            print("[EditorPreloader] CodeMirror navigation failed: \(error.localizedDescription)")
            #endif
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

    // MARK: - Claim

    /// Claims the preloaded Milkdown WebView, transferring ownership to the caller.
    /// Returns nil if not ready. Automatically starts preloading a replacement.
    func claimMilkdownView() -> WKWebView? {
        guard case .ready = milkdownState, let view = preloadedMilkdownView else {
            #if DEBUG
            print("[EditorPreloader] Milkdown claim failed: state=\(milkdownState)")
            #endif
            return nil
        }
        preloadedMilkdownView = nil
        #if DEBUG
        print("[EditorPreloader] Milkdown WebView claimed successfully")
        #endif

        restartMilkdownPreloading()
        return view
    }

    /// Claims the preloaded CodeMirror WebView, transferring ownership to the caller.
    /// Returns nil if not ready. Automatically starts preloading a replacement.
    func claimCodeMirrorView() -> WKWebView? {
        guard case .ready = codemirrorState, let view = preloadedCodeMirrorView else {
            #if DEBUG
            print("[EditorPreloader] CodeMirror claim failed: state=\(codemirrorState)")
            #endif
            return nil
        }
        preloadedCodeMirrorView = nil
        #if DEBUG
        print("[EditorPreloader] CodeMirror WebView claimed successfully")
        #endif

        restartCodeMirrorPreloading()
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
