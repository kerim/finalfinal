//
//  EditorModeSwitchTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for content integrity across editor mode switches (Milkdown ↔ CodeMirror).
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
@testable import final_final

// MARK: - Cross-Editor Content Tests

final class EditorModeSwitchTests: XCTestCase {

    /// Helper: set content in source editor, get it, then load in dest editor and verify.
    /// Returns (exported content from source, final content from dest).
    @MainActor
    private func crossEditorRoundtrip(
        from sourceType: EditorTestHelper.EditorType,
        to destType: EditorTestHelper.EditorType,
        content: String
    ) async throws -> (sourceExport: String, destFinal: String) {
        // Phase 1: Load in source editor
        let source = EditorTestHelper(editorType: sourceType)
        try await source.loadAndWaitForReady(timeout: 15)
        try await source.setContent(content)
        try await Task.sleep(nanoseconds: 300_000_000)

        let exported = try await source.getContent()

        // Phase 2: Load exported content in destination editor
        let dest = EditorTestHelper(editorType: destType)
        try await dest.loadAndWaitForReady(timeout: 15)
        try await dest.setContent(exported)
        try await Task.sleep(nanoseconds: 300_000_000)

        let final_ = try await dest.getContent()

        return (exported, final_)
    }

    // MARK: - Milkdown → CodeMirror

    @MainActor
    func testMilkdownToCodeMirrorBasicContent() async throws {
        let input = "# Test Document\n\nThis is a test paragraph.\n\n## Second Section\n\nMore content here."

        let (_, final_) = try await crossEditorRoundtrip(
            from: .milkdown, to: .codemirror, content: input
        )

        XCTAssertTrue(final_.contains("Test Document"), "Title should survive cross-editor. Got: \(final_)")
        XCTAssertTrue(final_.contains("test paragraph"), "Paragraph should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("Second Section"), "Second heading should survive. Got: \(final_)")
    }

    @MainActor
    func testMilkdownToCodeMirrorHeadingsAndLists() async throws {
        let input = "# Heading One\n\n- List item A\n- List item B\n\n## Heading Two\n\n1. Ordered one\n2. Ordered two"

        let (_, final_) = try await crossEditorRoundtrip(
            from: .milkdown, to: .codemirror, content: input
        )

        XCTAssertTrue(final_.contains("Heading One"), "H1 should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("List item A"), "List items should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("Heading Two"), "H2 should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("Ordered one"), "Ordered list should survive. Got: \(final_)")
    }

    @MainActor
    func testMilkdownToCodeMirrorFormattedContent() async throws {
        // Single-format cases only — Milkdown may reorder nested marks
        let input = "This has **bold** and *italic* words."

        let (_, final_) = try await crossEditorRoundtrip(
            from: .milkdown, to: .codemirror, content: input
        )

        // Check key formatting survived (allowing for mark reordering)
        XCTAssertTrue(final_.contains("bold"), "Bold text should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("italic"), "Italic text should survive. Got: \(final_)")
        // Check formatting markers are present
        XCTAssertTrue(final_.contains("**") || final_.contains("__"), "Bold markers should be present. Got: \(final_)")
        XCTAssertTrue(final_.contains("*") || final_.contains("_"), "Italic markers should be present. Got: \(final_)")
    }

    // MARK: - CodeMirror → Milkdown

    @MainActor
    func testCodeMirrorToMilkdownBasicContent() async throws {
        let input = "# Test Document\n\nA paragraph of text.\n\n## Another Section\n\nMore text."

        let (_, final_) = try await crossEditorRoundtrip(
            from: .codemirror, to: .milkdown, content: input
        )

        XCTAssertTrue(final_.contains("Test Document"), "Title should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("paragraph"), "Paragraph should survive. Got: \(final_)")
        XCTAssertTrue(final_.contains("Another Section"), "Second heading should survive. Got: \(final_)")
    }

    // MARK: - Large Content

    @MainActor
    func testLargeContentIntegrity() async throws {
        // Generate 500+ word content
        var lines = ["# Large Document\n"]
        for i in 1...50 {
            lines.append(
                "Paragraph number \(i) contains several words to build up the word count of this document.\n"
            )
        }
        let input = lines.joined(separator: "\n")

        let (_, final_) = try await crossEditorRoundtrip(
            from: .milkdown, to: .codemirror, content: input
        )

        // Check beginning and end survived
        XCTAssertTrue(final_.contains("Large Document"), "Title should survive. Got first 100 chars: \(String(final_.prefix(100)))")
        XCTAssertTrue(final_.contains("Paragraph number 1"), "First paragraph should survive")
        XCTAssertTrue(final_.contains("Paragraph number 50"), "Last paragraph should survive")
    }

    // MARK: - Empty Content

    @MainActor
    func testEmptyContentHandled() async throws {
        // Milkdown editor
        let milkdown = EditorTestHelper(editorType: .milkdown)
        try await milkdown.loadAndWaitForReady(timeout: 15)
        try await milkdown.setContent("")
        try await Task.sleep(nanoseconds: 300_000_000)

        let milkdownOutput = try await milkdown.getContent()
        // Empty or whitespace-only is acceptable
        XCTAssertTrue(milkdownOutput.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1,
                      "Milkdown empty content should be empty or near-empty. Got: \(milkdownOutput)")

        // CodeMirror editor
        let codemirror = EditorTestHelper(editorType: .codemirror)
        try await codemirror.loadAndWaitForReady(timeout: 15)
        try await codemirror.setContent("")
        try await Task.sleep(nanoseconds: 300_000_000)

        let cmOutput = try await codemirror.getContent()
        XCTAssertTrue(cmOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "CodeMirror empty content should be empty. Got: \(cmOutput)")
    }
}
