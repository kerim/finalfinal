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

    /// Read by the citation fill (`EditorPreloader+CitationPrefill.swift`) to tell whether a spare is still the standby page; written only here.
    private(set) var preloadedMilkdownView: WKWebView?
    private var preloadedCodeMirrorView: WKWebView?
    private var citationStyleObserver: NSObjectProtocol?
    private(set) var milkdownState: State = .idle
    private(set) var codemirrorState: State = .idle

    /// Bumped whenever the Rich Text spare is replaced (`startMilkdownPreloading`) or claimed (`claimMilkdownView`). A citation fill
    /// remembers the generation it started on and stops the moment this differs (`CitationPrefillGuard`).
    private(set) var milkdownSpareGeneration = 0
    /// The generation of the spare most recently handed out by `claimMilkdownView()`; lets a stopped fill say "claimed" rather than "replaced".
    private(set) var milkdownClaimedGeneration: Int?
    /// Decides when the spare works the document's citations out ahead of time (`EditorPreloader+CitationPrefill.swift`). Created by
    /// `startPreloading()` unless `TestMode.isCitationPrefillSchedulerEnabled` is false; nil in unit tests, which never start the preloader.
    /// Not `private(set)`: `installCitationPrefillScheduler()` lives in `EditorPreloader+CitationPrefill.swift`, a different file.
    var citationPrefillScheduler: CitationPrefillScheduler?

    /// Phase 5 jobs A9 / A10 (EditorPreloader+Prepare.swift): fresh pages loaded for a switch (no standby was ready), waiting for their
    /// load to finish, keyed by the web view's identity.
    var prepareLoads: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    /// Phase 5 jobs A9 / A10: the incoming page a switch has filled and handed over at the flip, claimed by the editor's `makeNSView`.
    var stagedCodeMirror: StagedSwitchPage?
    var stagedMilkdown: StagedSwitchPage?
    /// Phase 5 jobs A9 / A10: set when a staged page is handed over; the outgoing editor's `dismantleNSView` consumes it and skips its
    /// caret save (EditorPreloader+Prepare.swift).
    var suppressOutgoingCursorSave = false

    private override init() {
        super.init()
    }

    private var preloadFrameSize: CGSize {
        NSScreen.screens.first?.frame.size ?? CGSize(width: 1200, height: 800)
    }

    /// Call from AppDelegate.applicationDidFinishLaunching
    func startPreloading() {
        // `FF_UI_TESTING_ENABLE_PRELOADER=1` (UI tests only) lets the preloader run under test exactly as in production; unset,
        // the guard is the same `!TestMode.isTesting` as always.
        guard !TestMode.isTesting || TestMode.isUITestingEditorPreloaderEnabled else { return }
        if TestMode.isCitationPrefillSchedulerEnabled { installCitationPrefillScheduler() }
        observeCitationStyleChanges()
        startMilkdownPreloading()
        startCodeMirrorPreloading()
    }

    // MARK: - Citation style for the Rich Text spare

    /// Keeps the standby Rich Text page on the current citation style. Starts at launch (after the test guard above, so
    /// unit tests never observe), once.
    private func observeCitationStyleChanges() {
        guard citationStyleObserver == nil else { return }
        citationStyleObserver = NotificationCenter.default.addObserver(
            forName: .citationStyleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main`: this runs on the main thread, so main-actor isolation is assumed.
            MainActor.assumeIsolated { self?.citationStyleDidChange() }
        }
    }

    /// Gives the Rich Text spare the current effective citation style (custom if configured and valid, else the bundled one)
    /// ahead of the user's switch, so the engine rebuild a different style needs -- about a second -- happens in the standby
    /// page instead of while the user waits. Called when the spare's page finishes loading and again when the style changes
    /// while a spare is ready. A spare that is still loading is not touched: its own page-finished call reads the style then.
    ///
    /// The mount-time push (`MilkdownCoordinator.pushCitationStyle`) stays unconditional and always re-reads the file; the
    /// page compares what it is pushed with what it already runs and skips an identical one. So a spare that missed this
    /// push (a failed evaluation, a change in between) still ends up on the right style at mount, just not for free.
    /// A failed push is logged, never retried here.
    func pushCitationStyleToMilkdownSpare(reason: String) {
        guard case .ready = milkdownState, let webView = preloadedMilkdownView else { return }
        guard let path = ExportSettingsManager.shared.settings.effectiveCSLStylePath,
              let styleXML = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            DebugLog.log(.zotero, "[EditorPreloader] Could not read CSL style file to push to the Milkdown spare (\(reason))")
            return
        }
        DebugLog.log(.zotero, "[EditorPreloader] Pushing CSL style to the Milkdown spare (\(reason), \(styleXML.utf16.count) chars)")
        webView.evaluateJavaScript(MilkdownEditor.Coordinator.setCitationStyleScript(styleXML)) { _, error in
            if let error {
                DebugLog.log(.zotero, "[EditorPreloader] Pushing CSL style to the Milkdown spare failed (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Milkdown Preloading

    private func startMilkdownPreloading() {
        guard case .idle = milkdownState else { return }
        milkdownState = .loading

        guard let webView = makeLoadingMilkdownWebView() else {
            assertionFailure("[EditorPreloader] Invalid Milkdown preload URL")
            milkdownState = .idle
            return
        }

        DebugLog.log(.editor, "[EditorPreloader] Starting Milkdown preload")
        preloadedMilkdownView = webView
        milkdownSpareGeneration += 1
    }

    /// A Milkdown page as the standby is made (error script, scheme handlers, this object as its navigation delegate), already loading.
    /// Also the fresh page a switch to Rich Text fills when no standby is ready (EditorPreloader+Prepare.swift). Nil for a bad URL.
    func makeLoadingMilkdownWebView() -> WKWebView? {
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

        // Phase 5 job A10: a page that takes keyboard focus the moment it is attached, if a switch asks it to (EditorPreloader+Prepare.swift).
        let webView = FocusOnAttachWebView(frame: CGRect(origin: .zero, size: preloadFrameSize), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://milkdown/milkdown.html") else { return nil }
        webView.load(URLRequest(url: url))
        return webView
    }

    // MARK: - CodeMirror Preloading

    private func startCodeMirrorPreloading() {
        guard case .idle = codemirrorState else { return }
        codemirrorState = .loading

        guard let webView = makeLoadingCodeMirrorWebView() else {
            assertionFailure("[EditorPreloader] Invalid CodeMirror preload URL")
            codemirrorState = .idle
            return
        }

        DebugLog.log(.editor, "[EditorPreloader] Starting CodeMirror preload")
        preloadedCodeMirrorView = webView
    }

    /// A CodeMirror page as the standby is made (error script, scheme handlers, this object as its navigation delegate), already loading.
    /// Also the fresh page a switch to Markdown fills when no standby is ready (EditorPreloader+Prepare.swift). Nil for a bad URL.
    func makeLoadingCodeMirrorWebView() -> WKWebView? {
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

        // Phase 5 job A9: a page that takes keyboard focus the moment it is attached, if a switch asks it to (EditorPreloader+Prepare.swift).
        let webView = FocusOnAttachWebView(frame: CGRect(origin: .zero, size: preloadFrameSize), configuration: configuration)
        webView.navigationDelegate = self

        guard let url = URL(string: "editor://codemirror/codemirror.html") else { return nil }
        webView.load(URLRequest(url: url))
        return webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === preloadedMilkdownView {
            milkdownState = .ready
            DebugLog.log(.editor, "[EditorPreloader] Milkdown preload complete")
            // UI-test-only (FF_UI_TESTING_CITATION_PREFILL=memoOff): the standby page runs without the citation memo from the start.
            // A skipped `if` otherwise.
            if TestMode.isUITestingCitationMemoOff { webView.evaluateJavaScript(CitationPrefillTestScripts.memoOff) { _, _ in } }
            pushCitationStyleToMilkdownSpare(reason: "page loaded")
            // After the style push above (the page runs its calls in order), so the fill finds the engine on the right style.
            citationPrefillScheduler?.spareBecameReady()
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .ready
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror preload complete")
        } else {
            finishPrepareLoad(webView, loaded: true)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] Milkdown preload failed: \(error.localizedDescription)")
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror preload failed: \(error.localizedDescription)")
        } else {
            finishPrepareLoad(webView, loaded: false)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === preloadedMilkdownView {
            milkdownState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] Milkdown navigation failed: \(error.localizedDescription)")
        } else if webView === preloadedCodeMirrorView {
            codemirrorState = .failed(error)
            DebugLog.log(.editor, "[EditorPreloader] CodeMirror navigation failed: \(error.localizedDescription)")
        } else {
            finishPrepareLoad(webView, loaded: false)
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
        milkdownClaimedGeneration = milkdownSpareGeneration
        milkdownSpareGeneration += 1  // any citation fill running on this spare stops at its next check
        citationPrefillScheduler?.spareClaimed()
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
