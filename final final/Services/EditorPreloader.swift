//
//  EditorPreloader.swift
//  final final
//
//  Pre-loads the Milkdown WebView during app launch so it's ready
//  when the editor appears, eliminating the cold start delay.
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
    private(set) var state: State = .idle

    private override init() {
        super.init()
    }

    /// Call from AppDelegate.applicationDidFinishLaunching
    func startPreloading() {
        guard case .idle = state else { return }
        state = .loading

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        // Add JS error handler script so we can see errors from preloaded views
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

        // Create WebView with minimal size (off-screen)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://milkdown/milkdown.html") else {
            assertionFailure("[EditorPreloader] Invalid preload URL")
            state = .idle
            return
        }

        #if DEBUG
        print("[EditorPreloader] Starting preload")
        #endif

        webView.load(URLRequest(url: url))
        preloadedMilkdownView = webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .ready
        #if DEBUG
        print("[EditorPreloader] Preload complete")
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .failed(error)
        #if DEBUG
        print("[EditorPreloader] Preload failed: \(error.localizedDescription)")
        #endif
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .failed(error)
        #if DEBUG
        print("[EditorPreloader] Navigation failed: \(error.localizedDescription)")
        #endif
    }

    /// Wait until preload is ready, with timeout
    /// Returns true if ready, false if timeout or failed
    func waitUntilReady(timeout: TimeInterval = 2.0) async -> Bool {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.05  // 50ms polling

        while Date().timeIntervalSince(startTime) < timeout {
            switch state {
            case .ready:
                return true
            case .failed:
                return false
            case .claimed:
                return false  // Already claimed by someone else
            case .idle, .loading:
                // Still waiting - sleep and check again
                try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
            }
        }

        return false
    }

    /// Claims the preloaded WebView, transferring ownership to the caller.
    /// Returns nil if not ready. Can only be called once per preload cycle.
    /// Automatically starts preloading a new WebView for subsequent use.
    func claimMilkdownView() -> WKWebView? {
        guard case .ready = state, let view = preloadedMilkdownView else {
            #if DEBUG
            print("[EditorPreloader] Claim failed: state=\(state)")
            #endif
            return nil
        }
        preloadedMilkdownView = nil
        #if DEBUG
        print("[EditorPreloader] WebView claimed successfully")
        #endif

        // Immediately start preloading next WebView for subsequent project opens
        // Do this BEFORE setting claimed state so restartPreloading works
        restartPreloading()

        return view
    }

    /// Restart preloading for a new WebView (used after claim or for new projects)
    func restartPreloading() {
        // Reset state and start fresh
        preloadedMilkdownView = nil
        state = .idle
        startPreloading()
    }
}
