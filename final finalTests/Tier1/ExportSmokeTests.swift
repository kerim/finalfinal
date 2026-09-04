//
//  ExportSmokeTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Host-side unit-tier stand-in for an export golden-path UI smoke test.
//  Every export route in the app ends in NSSavePanel.begin
//  (FileCommands+Export.swift), and NSSavePanel is blocked inside the
//  vmtest guest VM (see scripts/vmtest/README.md), so there is no headless
//  UI route to exercise export in `vmtest run --suite smoke`. This drives
//  ExportService directly instead -- the same calls the app makes once the
//  save panel returns a URL -- so the export mechanism still has SOME
//  coverage in the fast merge gate rather than none at all.
//
//  Two paths, because they have genuinely different dependencies:
//   - Markdown (`exportMarkdownOnly`): a plain file write, no pandoc
//     involved. Always runs.
//   - Word/.docx (`export(format: .word, ...)`): pandoc-based. Guarded with
//     the same XCTSkip-if-pandoc-missing idiom already established in
//     ExportCitekeyCanonicalizationIntegrationTests.swift, so this never
//     fails the gate on a host with no pandoc installed -- it just carries
//     no coverage on that host, same as its sibling.
//
//  The fixture is deliberately citation-free (no `[@key]`), so
//  ExportService.export's Zotero preflight never runs and nothing touches
//  the network -- this proves the export mechanism works, not citation
//  resolution (covered elsewhere in Tier 1/2).
//

import XCTest
@testable import final_final

final class ExportSmokeTests: XCTestCase {

    private static let fixtureHeading = "Export Smoke Fixture"
    private static let fixtureMarkdown = """
    # \(fixtureHeading)

    A short paragraph with no citations, so the Zotero preflight never runs.
    """

    /// Same idiom as ExportCitekeyCanonicalizationIntegrationTests.findPandocPath().
    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Markdown (no pandoc dependency)

    func testMarkdownExportProducesNonEmptyFileWithFixtureHeading() async throws {
        let service = ExportService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-smoke-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await service.exportMarkdownOnly(content: Self.fixtureMarkdown, outputURL: tempURL)

        let written = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.contains(Self.fixtureHeading))
    }

    // MARK: - Word / .docx (pandoc-based)

    func testWordExportProducesNonEmptyFileContainingFixtureHeading() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping export golden-path Word smoke test")
        }

        let service = ExportService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-smoke-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await service.export(
            content: Self.fixtureMarkdown,
            to: tempURL,
            format: .word,
            settings: ExportSettings.default,
            projectURL: nil
        )

        XCTAssertEqual(result.outputURL, tempURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Exported .docx must be a non-empty file")
    }
}
