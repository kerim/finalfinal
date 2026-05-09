//
//  TableBridgeTests.swift
//  final finalTests
//
//  Tier 2: Layer 2 guardrail tests for table cell inline marks.
//
//  These tests verify that getContent() (the mdast-util-to-markdown path)
//  preserves bold, italic, inline code, links, and highlights inside table
//  cells. Each mark type has its own test because failures are independent.
//
//  Timing: ≥600ms sleep after setContent ensures at least one full 500ms
//  block-sync poll fires before asserting. Using 300ms (the existing
//  EditorBridgeTests pattern) is shorter than the poll cycle and would
//  produce flaky failures on slow hardware.
//

import XCTest
@testable import final_final

final class MilkdownTableMarkTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    // MARK: - Bold in table cell

    @MainActor
    func testBoldInTableCell() async throws {
        let input = """
            | Header |
            | ------ |
            | **bold text** |
            """
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(
            output.contains("**bold text**") || output.contains("__bold text__"),
            "Bold mark in table cell must survive getContent(). Got: \(output)"
        )
    }

    // MARK: - Italic in table cell

    @MainActor
    func testItalicInTableCell() async throws {
        let input = """
            | Header |
            | ------ |
            | *italic text* |
            """
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(
            output.contains("*italic text*") || output.contains("_italic text_"),
            "Italic mark in table cell must survive getContent(). Got: \(output)"
        )
    }

    // MARK: - Inline code in table cell

    @MainActor
    func testInlineCodeInTableCell() async throws {
        let input = """
            | Header |
            | ------ |
            | `inline code` |
            """
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(
            output.contains("`inline code`"),
            "Inline code in table cell must survive getContent(). Got: \(output)"
        )
    }

    // MARK: - Link in table cell

    @MainActor
    func testLinkInTableCell() async throws {
        let input = """
            | Header |
            | ------ |
            | [example](https://example.com) |
            """
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(
            output.contains("example") && output.contains("https://example.com"),
            "Link in table cell must survive getContent(). Got: \(output)"
        )
    }

    // MARK: - Highlight in table cell

    @MainActor
    func testHighlightInTableCell() async throws {
        let input = """
            | Header |
            | ------ |
            | ==highlighted text== |
            """
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        XCTAssertTrue(
            output.contains("==highlighted text=="),
            "Highlight mark in table cell must survive getContent(). Got: \(output)"
        )
    }
}
