//
//  EditorBridgeTests.swift
//  final finalTests
//
//  Integration tests for the JS-Swift bridge using real WKWebViews.
//  Tests both Milkdown (WYSIWYG) and CodeMirror (Source) editors.
//
//  Uses XCTest (not Swift Testing) because WKWebView tests must not
//  run in parallel, and XCTest's sequential execution model is simpler
//  for async WebView operations.
//

import XCTest
@testable import final_final

// MARK: - Milkdown Tests

final class MilkdownBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testMilkdownEditorLoads() async throws {
        let snapshot = try await helper.captureSnapshot()
        XCTAssertTrue(snapshot.editorReady, "Editor should report ready after load")
    }

    @MainActor
    func testMilkdownContentRoundtrip() async throws {
        let testMarkdown = TestFixtureFactory.testContent
        try await helper.setContent(testMarkdown)

        // Brief delay for editor to settle
        try await Task.sleep(nanoseconds: 300_000_000)

        let retrieved = try await helper.getContent()
        // Milkdown may normalize whitespace — check key content is present
        XCTAssertTrue(retrieved.contains("# Test Document"), "Should contain heading")
        XCTAssertTrue(retrieved.contains("test paragraph"), "Should contain paragraph text")
        XCTAssertTrue(retrieved.contains("## Second Section"), "Should contain second heading")
    }

    @MainActor
    func testMilkdownStatsAccuracy() async throws {
        try await helper.setContent(TestFixtureFactory.testContent)
        try await Task.sleep(nanoseconds: 300_000_000)

        let snapshot = try await helper.captureSnapshot()
        XCTAssertGreaterThan(snapshot.stats.words, 0, "Word count should be positive")
        XCTAssertGreaterThan(snapshot.stats.characters, 0, "Character count should be positive")
    }

    @MainActor
    func testMilkdownTestSnapshot() async throws {
        try await helper.setContent(TestFixtureFactory.testContent)
        try await Task.sleep(nanoseconds: 300_000_000)

        let snapshot = try await helper.captureSnapshot()
        XCTAssertTrue(snapshot.editorReady)
        XCTAssertTrue(snapshot.content.contains("Test Document"))
        XCTAssertGreaterThan(snapshot.stats.words, 0)
        XCTAssertGreaterThan(snapshot.stats.characters, 0)
        // Cursor position should be valid (line >= 1)
        XCTAssertGreaterThanOrEqual(snapshot.cursorPosition.line, 1)
        XCTAssertGreaterThanOrEqual(snapshot.cursorPosition.column, 0)
    }

    @MainActor
    func testMilkdownFocusModeSnapshot() async throws {
        try await helper.setContent(TestFixtureFactory.testContent)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Enable focus mode
        try await helper.setFocusMode(true)
        let enabledSnapshot = try await helper.captureSnapshot()
        XCTAssertTrue(enabledSnapshot.focusModeEnabled, "Focus mode should be enabled")

        // Disable focus mode
        try await helper.setFocusMode(false)
        let disabledSnapshot = try await helper.captureSnapshot()
        XCTAssertFalse(disabledSnapshot.focusModeEnabled, "Focus mode should be disabled")
    }

    @MainActor
    func testMilkdownSmartQuotesBridgeMethodsCallable() async throws {
        // Verifies ONLY that the window.FinalFinal.disableSmartQuotes()/enableSmartQuotes()
        // bridge surface exists and is callable without throwing from Swift's side — NOT that
        // toggling has any behavioral effect. setContent() parses markdown directly into the
        // ProseMirror doc without ever touching the InputRules/handleTextInput pipeline, so
        // straight quotes round-trip identically here whether disableSmartQuotes() is a real
        // implementation or a no-op stub; this test cannot and does not distinguish the two.
        // Behavioral correctness of the balanced-curling logic itself is covered by the
        // web/milkdown/src/__tests__/smart-quotes-plugin.test.ts vitest suite instead. Per this
        // project's established lesson, execCommand/programmatic content-setting doesn't
        // replicate real keyboard input for WKWebView, so exercising the actual toggle's effect
        // from a Swift test would require real keystroke simulation, which is out of scope here.
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.disableSmartQuotes()")

        let testMarkdown = "She said \"hello\" and it's a test."
        try await helper.setContent(testMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let retrieved = try await helper.getContent()
        XCTAssertTrue(retrieved.contains("\"hello\""), "Content should round-trip via setContent/getContent regardless of the toggle")
        XCTAssertTrue(retrieved.contains("it's"), "Content should round-trip via setContent/getContent regardless of the toggle")
    }
}

// MARK: - CodeMirror Tests

final class CodeMirrorBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testCodeMirrorEditorLoads() async throws {
        let snapshot = try await helper.captureSnapshot()
        XCTAssertTrue(snapshot.editorReady, "Editor should report ready after load")
    }

    @MainActor
    func testCodeMirrorContentRoundtrip() async throws {
        let testMarkdown = TestFixtureFactory.testContent
        try await helper.setContent(testMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let retrieved = try await helper.getContent()
        // CodeMirror preserves markdown more literally
        XCTAssertTrue(retrieved.contains("# Test Document"), "Should contain heading")
        XCTAssertTrue(retrieved.contains("test paragraph"), "Should contain paragraph text")
        XCTAssertTrue(retrieved.contains("## Second Section"), "Should contain second heading")
    }

    @MainActor
    func testCodeMirrorStatsAccuracy() async throws {
        try await helper.setContent(TestFixtureFactory.testContent)
        try await Task.sleep(nanoseconds: 300_000_000)

        let snapshot = try await helper.captureSnapshot()
        XCTAssertGreaterThan(snapshot.stats.words, 0, "Word count should be positive")
        XCTAssertGreaterThan(snapshot.stats.characters, 0, "Character count should be positive")
    }

    @MainActor
    func testCodeMirrorTestSnapshot() async throws {
        try await helper.setContent(TestFixtureFactory.testContent)
        try await Task.sleep(nanoseconds: 300_000_000)

        let snapshot = try await helper.captureSnapshot()
        XCTAssertTrue(snapshot.editorReady)
        XCTAssertTrue(snapshot.content.contains("Test Document"))
        XCTAssertGreaterThan(snapshot.stats.words, 0)
        XCTAssertGreaterThan(snapshot.stats.characters, 0)
        // CodeMirror always reports focusModeEnabled as false
        XCTAssertFalse(snapshot.focusModeEnabled)
        // Cursor position should be valid
        XCTAssertGreaterThanOrEqual(snapshot.cursorPosition.line, 1)
        XCTAssertGreaterThanOrEqual(snapshot.cursorPosition.column, 0)
    }

    @MainActor
    func testCodeMirrorSmartQuotesBridgeMethodsCallable() async throws {
        // Verifies ONLY that the window.FinalFinal.disableSmartQuotes()/enableSmartQuotes()
        // bridge surface exists and is callable without throwing from Swift's side — NOT that
        // toggling has any behavioral effect. setContent() sets the CodeMirror EditorState
        // directly without ever touching the EditorView.inputHandler pipeline, so straight
        // quotes round-trip identically here whether disableSmartQuotes() is a real
        // implementation or a no-op stub; this test cannot and does not distinguish the two.
        // Behavioral correctness of the balanced-curling logic itself is covered by the
        // web/codemirror/src/__tests__/smart-quotes-plugin.test.ts vitest suite instead. Per
        // this project's established lesson, execCommand/programmatic content-setting doesn't
        // replicate real keyboard input for WKWebView, so exercising the actual toggle's effect
        // from a Swift test would require real keystroke simulation, which is out of scope here.
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.disableSmartQuotes()")

        let testMarkdown = "She said \"hello\" and it's a test."
        try await helper.setContent(testMarkdown)
        try await Task.sleep(nanoseconds: 300_000_000)

        let retrieved = try await helper.getContent()
        XCTAssertTrue(retrieved.contains("\"hello\""), "Content should round-trip via setContent/getContent regardless of the toggle")
        XCTAssertTrue(retrieved.contains("it's"), "Content should round-trip via setContent/getContent regardless of the toggle")
    }
}
