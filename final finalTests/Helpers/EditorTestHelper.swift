//
//  EditorTestHelper.swift
//  final finalTests
//
//  WKWebView wrapper for integration-testing the JS-Swift bridge.
//  Creates a real WKWebView, loads an editor via editor:// scheme,
//  and provides typed access to __testSnapshot().
//

import WebKit
import XCTest
@testable import final_final

// MARK: - EditorSnapshot

struct EditorSnapshot: Codable, Equatable {
    let content: String
    let cursorPosition: CursorPosition
    let stats: Stats
    let editorReady: Bool
    let focusModeEnabled: Bool

    struct CursorPosition: Codable, Equatable {
        let line: Int
        let column: Int
    }

    struct Stats: Codable, Equatable {
        let words: Int
        let characters: Int
    }
}

// MARK: - BlockReportRelay

/// The test page's `blockReport` handler: what `MilkdownCoordinator+MessageDispatch.swift` does with the message, synchronously.
final class BlockReportRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { ReportApplier.route(body: message.body, from: message.webView) }
    }
}

// MARK: - EditorTestHelper

@MainActor
final class EditorTestHelper: NSObject, WKNavigationDelegate {

    enum EditorType {
        case milkdown
        case codemirror

        var htmlPath: String {
            switch self {
            case .milkdown: return "editor://milkdown/milkdown.html"
            case .codemirror: return "editor://codemirror/codemirror.html"
            }
        }
    }

    let editorType: EditorType
    let webView: WKWebView

    private var navigationContinuation: CheckedContinuation<Void, Error>?

    init(editorType: EditorType) {
        self.editorType = editorType

        let configuration = WKWebViewConfiguration()
        // Use non-persistent data store for test isolation
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        if editorType == .milkdown {
            // Phase 5 job B4: as in the app (MilkdownEditor.swift), the Rich Text page reports its block changes itself and the
            // reports go to the intake of whichever `BlockSyncService` is configured with this web view (`ReportApplier.route`).
            // Without this nothing would ever carry a test's typing to the database: the 2-second poll that used to is gone.
            configuration.userContentController.addUserScript(ReportIntake.configUserScript())
            configuration.userContentController.add(BlockReportRelay(), name: "blockReport")
        }

        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )

        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Navigation

    /// Loads the editor HTML and waits for the editor JS to be ready.
    /// Two-phase check: (1) wait for navigation, (2) poll for JS readiness.
    func loadAndWaitForReady(timeout: TimeInterval = 10.0) async throws {
        guard let url = URL(string: editorType.htmlPath) else {
            throw EditorTestError.invalidURL
        }

        // Phase 1: Wait for WKWebView navigation to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.navigationContinuation = continuation
            self.webView.load(URLRequest(url: url))
        }

        // Phase 2: Poll for JS editor readiness
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let ready = try await evaluateJS(
                "typeof window.FinalFinal !== 'undefined' && typeof window.FinalFinal.__testSnapshot === 'function'"
            )
            if let isReady = ready as? Bool, isReady {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        throw EditorTestError.editorNotReady
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navigationContinuation?.resume()
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume(throwing: error)
            navigationContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navigationContinuation?.resume(throwing: error)
            navigationContinuation = nil
        }
    }

    // MARK: - JS Bridge

    /// Captures a typed snapshot from __testSnapshot()
    func captureSnapshot() async throws -> EditorSnapshot {
        let jsonString = try await evaluateJS(
            "JSON.stringify(window.FinalFinal.__testSnapshot())"
        ) as? String

        guard let json = jsonString, let data = json.data(using: .utf8) else {
            throw EditorTestError.snapshotFailed
        }

        return try JSONDecoder().decode(EditorSnapshot.self, from: data)
    }

    /// Sets editor content via setContent()
    func setContent(_ markdown: String) async throws {
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        _ = try await evaluateJS("window.FinalFinal.setContent(`\(escaped)`)")
        // Brief delay for editor to process
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
    }

    /// Gets editor content via getContent()
    func getContent() async throws -> String {
        let result = try await evaluateJS("window.FinalFinal.getContent()")
        return result as? String ?? ""
    }

    /// Sets focus mode via setFocusMode()
    func setFocusMode(_ enabled: Bool) async throws {
        _ = try await evaluateJS("window.FinalFinal.setFocusMode(\(enabled))")
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms for state update
    }

    // MARK: - Private

    private func evaluateJS(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }
}

// MARK: - Errors

enum EditorTestError: Error, LocalizedError {
    case invalidURL
    case editorNotReady
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid editor URL"
        case .editorNotReady: return "Editor did not become ready within timeout"
        case .snapshotFailed: return "Failed to capture editor snapshot"
        }
    }
}
