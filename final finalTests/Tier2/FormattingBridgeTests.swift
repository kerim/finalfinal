//
//  FormattingBridgeTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for markdown formatting roundtrip through both editors.
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop.
//

import XCTest
@testable import final_final

// MARK: - Milkdown Formatting Tests

final class MilkdownFormattingTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testBoldRoundtrip() async throws {
        let input = "This is **bold** text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("**bold**") || output.contains("__bold__"),
                      "Bold markdown should survive roundtrip. Got: \(output)")
    }

    @MainActor
    func testItalicRoundtrip() async throws {
        let input = "This is *italic* text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("*italic*") || output.contains("_italic_"),
                      "Italic markdown should survive roundtrip. Got: \(output)")
    }

    @MainActor
    func testStrikethroughRoundtrip() async throws {
        let input = "This is ~~strikethrough~~ text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("~~strikethrough~~"),
                      "Strikethrough should survive roundtrip. Got: \(output)")
    }

    @MainActor
    func testHeadingLevelsRoundtrip() async throws {
        let input = "# H1\n\n## H2\n\n### H3"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("# H1"), "H1 should survive. Got: \(output)")
        XCTAssertTrue(output.contains("## H2"), "H2 should survive. Got: \(output)")
        XCTAssertTrue(output.contains("### H3"), "H3 should survive. Got: \(output)")
    }

    @MainActor
    func testListItemsRoundtrip() async throws {
        let input = "- Item one\n- Item two\n- Item three"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        // Milkdown may use * or - for list markers
        XCTAssertTrue(output.contains("Item one"), "List items should survive. Got: \(output)")
        XCTAssertTrue(output.contains("Item two"), "List items should survive. Got: \(output)")
        XCTAssertTrue(output.contains("Item three"), "List items should survive. Got: \(output)")
    }

    @MainActor
    func testBlockquoteRoundtrip() async throws {
        let input = "> This is a blockquote."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("> ") && output.contains("blockquote"),
                      "Blockquote should survive. Got: \(output)")
    }

    @MainActor
    func testCodeBlockRoundtrip() async throws {
        let input = "```\nlet x = 42\n```"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("```") && output.contains("let x = 42"),
                      "Code block should survive. Got: \(output)")
    }

    @MainActor
    func testLinkRoundtrip() async throws {
        let input = "Visit [example](https://example.com) for more."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("[example]") && output.contains("https://example.com"),
                      "Link should survive. Got: \(output)")
    }
}

// MARK: - CodeMirror Formatting Tests

final class CodeMirrorFormattingTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .codemirror)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    @MainActor
    func testBoldRoundtrip() async throws {
        let input = "This is **bold** text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("**bold**"),
                      "Bold should survive exact roundtrip in CodeMirror. Got: \(output)")
    }

    @MainActor
    func testItalicRoundtrip() async throws {
        let input = "This is *italic* text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("*italic*"),
                      "Italic should survive exact roundtrip in CodeMirror. Got: \(output)")
    }

    @MainActor
    func testStrikethroughRoundtrip() async throws {
        let input = "This is ~~strikethrough~~ text."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("~~strikethrough~~"),
                      "Strikethrough should survive exact roundtrip in CodeMirror. Got: \(output)")
    }

    @MainActor
    func testHeadingLevelsRoundtrip() async throws {
        let input = "# H1\n\n## H2\n\n### H3"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("# H1"), "H1 should survive. Got: \(output)")
        XCTAssertTrue(output.contains("## H2"), "H2 should survive. Got: \(output)")
        XCTAssertTrue(output.contains("### H3"), "H3 should survive. Got: \(output)")
    }

    @MainActor
    func testListItemsRoundtrip() async throws {
        let input = "- Item one\n- Item two\n- Item three"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("- Item one"), "List exact roundtrip in CodeMirror. Got: \(output)")
        XCTAssertTrue(output.contains("- Item two"), "List exact roundtrip in CodeMirror. Got: \(output)")
    }

    @MainActor
    func testBlockquoteRoundtrip() async throws {
        let input = "> This is a blockquote."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("> This is a blockquote"),
                      "Blockquote should survive exact roundtrip. Got: \(output)")
    }

    @MainActor
    func testCodeBlockRoundtrip() async throws {
        let input = "```\nlet x = 42\n```"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("```") && output.contains("let x = 42"),
                      "Code block should survive exact roundtrip. Got: \(output)")
    }

    @MainActor
    func testLinkRoundtrip() async throws {
        let input = "Visit [example](https://example.com) for more."
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 300_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(output.contains("[example](https://example.com)"),
                      "Link should survive exact roundtrip in CodeMirror. Got: \(output)")
    }
}
