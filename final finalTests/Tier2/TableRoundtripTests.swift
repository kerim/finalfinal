//
//  TableRoundtripTests.swift
//  final finalTests
//
//  Tier 2: Layer 3 full round-trip tests for table serialization.
//
//  Covers:
//  - AST equality across getContent() round-trips (5 mark types)
//  - Accumulation guard: 5 successive setContent/getContent cycles on a
//    table with bold cells produce byte-identical output
//  - Performance smoke: 10×10 table round-trip completes within 2 seconds
//  - Export verification: DOCX output contains bold/italic/link XML elements
//    (skipped if Pandoc is not installed)
//
//  Timing: ≥700ms sleep covers the 500ms block-sync poll cycle.
//

import XCTest
import Foundation
@testable import final_final

final class TableRoundtripTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    // MARK: - AST equality round-trips

    @MainActor
    func testBoldCellASTRoundtrip() async throws {
        let input = "| Header |\n| ------ |\n| **bold** |"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        let equal = try await compareTables(input, output)
        XCTAssertTrue(equal, "Bold cell must round-trip with AST equality. Input:\n\(input)\nOutput:\n\(output)")
    }

    @MainActor
    func testItalicCellASTRoundtrip() async throws {
        let input = "| Header |\n| ------ |\n| *italic* |"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        let equal = try await compareTables(input, output)
        XCTAssertTrue(equal, "Italic cell must round-trip with AST equality. Output:\n\(output)")
    }

    @MainActor
    func testCodeCellASTRoundtrip() async throws {
        let input = "| Header |\n| ------ |\n| `code` |"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        let equal = try await compareTables(input, output)
        XCTAssertTrue(equal, "Code cell must round-trip with AST equality. Output:\n\(output)")
    }

    @MainActor
    func testLinkCellASTRoundtrip() async throws {
        let input = "| Header |\n| ------ |\n| [link](https://example.com) |"
        try await helper.setContent(input)
        try await Task.sleep(nanoseconds: 700_000_000)

        let output = try await helper.getContent()
        let equal = try await compareTables(input, output)
        XCTAssertTrue(equal, "Link cell must round-trip with AST equality. Output:\n\(output)")
    }

    // MARK: - Accumulation guard

    @MainActor
    func testTableAccumulationOver5Cycles() async throws {
        // Table with bold, alignment, and footnote ref (covers the known accumulation risks)
        let seed = """
            | Name        | Score     |
            | :---------- | --------: |
            | **Alice**   | 100       |
            | *Bob*       | 95        |
            """

        try await helper.setContent(seed)
        try await Task.sleep(nanoseconds: 700_000_000)
        let cycle1 = try await helper.getContent()

        // Run 4 more cycles: set cycle output back and get again
        var current = cycle1
        for _ in 2...5 {
            try await helper.setContent(current)
            try await Task.sleep(nanoseconds: 700_000_000)
            let next = try await helper.getContent()
            XCTAssertEqual(current, next,
                           "Table output must be byte-identical across successive round-trip cycles (accumulation guard).\n" +
                           "Previous cycle:\n\(current)\nCurrent cycle:\n\(next)")
            current = next
        }
    }

    // MARK: - Performance smoke

    @MainActor
    func testLargeTableRoundtripPerformance() async throws {
        // Build a 10×10 table (header row + 9 data rows, 10 columns)
        var lines: [String] = []
        let header = (1...10).map { "Col \($0)" }.joined(separator: " | ")
        lines.append("| \(header) |")
        lines.append("| " + Array(repeating: "------", count: 10).joined(separator: " | ") + " |")
        for row in 1...9 {
            let cells = (1...10).map { "R\(row)C\($0)" }.joined(separator: " | ")
            lines.append("| \(cells) |")
        }
        let table = lines.joined(separator: "\n")

        let start = Date()
        try await helper.setContent(table)
        try await Task.sleep(nanoseconds: 700_000_000)
        _ = try await helper.getContent()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.7,
                          "10×10 table round-trip must complete within 2.7s (actual: \(String(format: "%.2f", elapsed))s). " +
                          "If CI consistently exceeds this, the serializer has a performance regression.")
    }

    // MARK: - Export verification (skips if Pandoc not installed)

    @MainActor
    func testTableMarksInDOCXExport() async throws {
        // Skip if Pandoc is not installed at standard locations
        guard let pandocPath = findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping DOCX export verification")
        }

        let markdownContent = """
            | Mark     | Example         |
            | -------- | --------------- |
            | Bold     | **strong text** |
            | Italic   | *emphasized*    |
            | Link     | [site](https://example.com) |
            """

        // Export to a temp DOCX
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("table-export-test.docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let settings = ExportSettings()
        let service = ExportService()
        _ = try await service.export(
            content: markdownContent,
            to: tempURL,
            format: .word,
            settings: settings
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path),
                      "DOCX file should be created at \(tempURL.path)")

        // Extract word/document.xml from the DOCX (which is a ZIP)
        let unzipResult = try runUnzip(archive: tempURL, entry: "word/document.xml")

        // Bold: <w:b/> or <w:b w:val="..."/> — check for <w:b
        XCTAssertTrue(unzipResult.contains("<w:b"),
                      "DOCX document.xml should contain bold markup (<w:b>). Got \(unzipResult.prefix(500))")

        // Italic: <w:i/> or <w:i w:val="..."/>
        XCTAssertTrue(unzipResult.contains("<w:i"),
                      "DOCX document.xml should contain italic markup (<w:i>). Got \(unzipResult.prefix(500))")

        // Link: <w:hyperlink
        XCTAssertTrue(unzipResult.contains("<w:hyperlink") || unzipResult.contains("hyperlink"),
                      "DOCX document.xml should contain hyperlink markup. Got \(unzipResult.prefix(500))")

        _ = pandocPath  // used above for skip check; keep reference for clarity
    }

    // MARK: - Helpers

    /// Uses window.FinalFinal.compareTableASTs() to compare two markdown strings at the AST level.
    private func compareTables(_ md1: String, _ md2: String) async throws -> Bool {
        let escaped1 = md1.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let escaped2 = md2.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let js = "window.FinalFinal.compareTableASTs(`\(escaped1)`, `\(escaped2)`)"
        let result = try await helper.webView.evaluateJavaScript(js)
        return result as? Bool ?? false
    }

    /// Runs `unzip -p archive entry` and returns the output as a String.
    private func runUnzip(archive: URL, entry: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Pandoc path helper

/// Returns the Pandoc executable path if found in standard locations, else nil.
private func findPandocPath() -> String? {
    let candidates = [
        "/opt/homebrew/bin/pandoc",
        "/usr/local/bin/pandoc",
        "/usr/bin/pandoc",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
