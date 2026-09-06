//
//  ToggleStateRegressionTests.swift
//  final finalTests
//
//  Tier 2: Regression guard for a previously-shipped bug in
//  `applyPersistedToggleStates()` (MilkdownCoordinator+Content.swift /
//  CodeMirrorCoordinator+Handlers.swift).
//
//  The bug: a freshly-created Coordinator + WKWebView (a brand-new load, or a
//  preloaded instance just claimed from EditorPreloader) always started its JS
//  module state at the default (enabled), regardless of what the user had
//  actually set via the Edit menu — because the persisted Smart Quotes /
//  Spellcheck preference was only re-applied through a one-shot
//  NotificationCenter post that reached whichever Coordinator happened to
//  exist at that moment. Any Coordinator created afterward (e.g. every
//  WYSIWYG/Source mode switch creates a fresh Coordinator+WKWebView) silently
//  reverted to "enabled" no matter what the toggle actually said. The fix
//  added `applyPersistedToggleStates()` and calls it from both
//  `webView(_:didFinish:)` and `handlePreloadedView()` — i.e. whenever
//  `isEditorReady` flips true, not just once at app launch.
//
//  Why this doesn't use EditorTestHelper (the harness every other bridge test
//  in this target uses): EditorTestHelper is a bare WKWebView wrapper that
//  never owns a MilkdownEditor.Coordinator / CodeMirrorEditor.Coordinator, so
//  its `loadAndWaitForReady()` never calls applyPersistedToggleStates() at
//  all. A test built on it would pass identically whether the fix is present,
//  reverted, or the function is deleted outright — it would prove nothing.
//  So this file drives the REAL Coordinator classes as the WKNavigationDelegate
//  for a fresh WKWebView load — same URL scheme handler and message-handler
//  names as MilkdownEditor.makeNSView() / CodeMirrorEditor.makeNSView() — so
//  `webView(_:didFinish:)` runs for real and calls the real
//  applyPersistedToggleStates(), exactly as production does.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop —
//  same reasoning as EditorBridgeTests.swift.
//

import WebKit
import XCTest
@testable import final_final

// MARK: - Real-Coordinator harnesses

/// Drives a real `MilkdownEditor.Coordinator` through its actual navigation-delegate
/// lifecycle (unlike EditorTestHelper, which bypasses the Coordinator entirely), so
/// `applyPersistedToggleStates()` runs exactly the way production code runs it —
/// from `webView(_:didFinish:)`, not from a direct test-only call.
@MainActor
private final class RealMilkdownHarness {
    let webView: WKWebView
    let coordinator: MilkdownEditor.Coordinator

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        coordinator = MilkdownEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToBlockId: .constant(nil),
            isResettingContent: .constant(false),
            contentState: .idle,
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onContentAcknowledged: nil,
            onWebViewReady: nil
        )

        // Same message-handler names as registerMilkdownMessageHandlers() in
        // MilkdownEditor.swift (that function is private to that file, so the
        // list is duplicated here) — keeps any JS-side postMessage call from
        // hitting an unregistered handler during the real didFinish flow.
        let controller = configuration.userContentController
        for name in [
            "contentChanged", "sectionChanged", "errorHandler", "searchCitations",
            "openCitationPicker", "resolveCitekeys", "paintComplete", "openURL",
            "spellcheck", "navigateToFootnote", "footnoteInserted", "pasteImage",
            "requestImagePicker", "updateImageMeta", "tableInsertTruncated",
            "openEquationDialog", "selectionChanged",
        ] {
            controller.add(coordinator, name: name)
        }

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
    }

    /// Loads the real editor HTML with `coordinator` as the navigation delegate, and
    /// waits for `coordinator.isEditorReady` (set inside the real `didFinish`) to flip
    /// true — proving the real lifecycle ran, not just that the page loaded.
    func loadAndWaitForReady(timeout: TimeInterval = 15) async throws {
        guard let url = URL(string: EditorTestHelper.EditorType.milkdown.htmlPath) else {
            throw EditorTestError.invalidURL
        }
        webView.load(URLRequest(url: url))

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if coordinator.isEditorReady { return }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw EditorTestError.editorNotReady
    }
}

/// Same as `RealMilkdownHarness` but drives `CodeMirrorEditor.Coordinator`.
@MainActor
private final class RealCodeMirrorHarness {
    let webView: WKWebView
    let coordinator: CodeMirrorEditor.Coordinator

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")

        coordinator = CodeMirrorEditor.Coordinator(
            content: .constant(""),
            cursorPositionToRestore: .constant(nil),
            scrollToOffset: .constant(nil),
            scrollToAnnotationIndex: .constant(nil),
            isResettingContent: .constant(false),
            onContentChange: { _, _ in },
            onStatsChange: { _, _ in },
            onSectionChange: { _ in },
            onCursorPositionSaved: { _ in },
            onWebViewReady: nil
        )

        // Same message-handler names as CodeMirrorEditor.makeNSView()'s fresh-view path.
        let controller = configuration.userContentController
        for name in [
            "contentChanged", "sectionChanged", "errorHandler", "openCitationPicker",
            "paintComplete", "openURL", "spellcheck", "navigateToFootnote",
            "footnoteInserted", "pasteImage", "requestImagePicker", "updateImageMeta",
            "tableInsertTruncated", "openEquationDialog", "selectionChanged",
        ] {
            controller.add(coordinator, name: name)
        }

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
    }

    func loadAndWaitForReady(timeout: TimeInterval = 15) async throws {
        guard let url = URL(string: EditorTestHelper.EditorType.codemirror.htmlPath) else {
            throw EditorTestError.invalidURL
        }
        webView.load(URLRequest(url: url))

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if coordinator.isEditorReady { return }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw EditorTestError.editorNotReady
    }
}

// MARK: - Tests

final class ToggleStateRegressionTests: XCTestCase {

    private var savedSpelling: Bool?
    private var savedGrammar: Bool?
    private var savedSmartQuotes: Bool?

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        savedSpelling = defaults.object(forKey: "isSpellingEnabled") as? Bool
        savedGrammar = defaults.object(forKey: "isGrammarEnabled") as? Bool
        savedSmartQuotes = defaults.object(forKey: "isSmartQuotesEnabled") as? Bool
    }

    override func tearDown() async throws {
        restore(key: "isSpellingEnabled", to: savedSpelling)
        restore(key: "isGrammarEnabled", to: savedGrammar)
        restore(key: "isSmartQuotesEnabled", to: savedSmartQuotes)
        try await super.tearDown()
    }

    private func restore(key: String, to value: Bool?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor
    private func evaluateBool(_ webView: WKWebView, _ script: String) async throws -> Bool {
        let result = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(result as? Bool, "Expected `\(script)` to return a Bool, got \(String(describing: result))")
    }

    // MARK: - Milkdown

    @MainActor
    func testMilkdownAppliesPersistedDisabledToggleStatesOnFreshLoad() async throws {
        UserDefaults.standard.set(false, forKey: "isSmartQuotesEnabled")
        UserDefaults.standard.set(false, forKey: "isSpellingEnabled")
        UserDefaults.standard.set(false, forKey: "isGrammarEnabled")

        let harness = RealMilkdownHarness()
        try await harness.loadAndWaitForReady(timeout: 15)

        let smartQuotesEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSmartQuotesEnabled()")
        let spellcheckEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSpellcheckEnabled()")

        XCTAssertFalse(smartQuotesEnabled,
            "A fresh Milkdown editor must re-apply the persisted (disabled) smart-quotes preference — " +
            "this is exactly the applyPersistedToggleStates() regression.")
        XCTAssertFalse(spellcheckEnabled,
            "A fresh Milkdown editor must re-apply the persisted (disabled) spellcheck preference.")
    }

    @MainActor
    func testMilkdownAppliesPersistedEnabledToggleStatesOnFreshLoad() async throws {
        UserDefaults.standard.set(true, forKey: "isSmartQuotesEnabled")
        UserDefaults.standard.set(true, forKey: "isSpellingEnabled")
        UserDefaults.standard.set(false, forKey: "isGrammarEnabled")

        let harness = RealMilkdownHarness()
        try await harness.loadAndWaitForReady(timeout: 15)

        let smartQuotesEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSmartQuotesEnabled()")
        let spellcheckEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSpellcheckEnabled()")

        XCTAssertTrue(smartQuotesEnabled, "Persisted smart quotes = true should remain enabled on a fresh load.")
        XCTAssertTrue(spellcheckEnabled, "Spelling enabled (even with grammar off) should keep spellcheck enabled.")
    }

    // MARK: - CodeMirror

    @MainActor
    func testCodeMirrorAppliesPersistedDisabledToggleStatesOnFreshLoad() async throws {
        UserDefaults.standard.set(false, forKey: "isSmartQuotesEnabled")
        UserDefaults.standard.set(false, forKey: "isSpellingEnabled")
        UserDefaults.standard.set(false, forKey: "isGrammarEnabled")

        let harness = RealCodeMirrorHarness()
        try await harness.loadAndWaitForReady(timeout: 15)

        let smartQuotesEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSmartQuotesEnabled()")
        let spellcheckEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSpellcheckEnabled()")

        XCTAssertFalse(smartQuotesEnabled,
            "A fresh CodeMirror editor must re-apply the persisted (disabled) smart-quotes preference.")
        XCTAssertFalse(spellcheckEnabled,
            "A fresh CodeMirror editor must re-apply the persisted (disabled) spellcheck preference.")
    }

    @MainActor
    func testCodeMirrorAppliesPersistedEnabledToggleStatesOnFreshLoad() async throws {
        UserDefaults.standard.set(true, forKey: "isSmartQuotesEnabled")
        UserDefaults.standard.set(false, forKey: "isSpellingEnabled")
        UserDefaults.standard.set(true, forKey: "isGrammarEnabled")

        let harness = RealCodeMirrorHarness()
        try await harness.loadAndWaitForReady(timeout: 15)

        let smartQuotesEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSmartQuotesEnabled()")
        let spellcheckEnabled = try await evaluateBool(harness.webView, "window.FinalFinal.isSpellcheckEnabled()")

        XCTAssertTrue(smartQuotesEnabled, "Persisted smart quotes = true should remain enabled on a fresh load.")
        XCTAssertTrue(spellcheckEnabled, "Grammar enabled (even with spelling off) should keep spellcheck enabled.")
    }
}
