//
//  BareCitationExportTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Real-pandoc integration test for bare-citations-literal.lua: a bare (unbracketed)
//  `@citekey` must never resolve as a citation in PDF output. Without this filter, pandoc's
//  citation extension still builds a Cite node for ANY bare `@word` (mode "AuthorInText"),
//  and with --citeproc active an unresolved Cite renders as a visibly broken marker
//  (`\textbf{key?}`) rather than staying invisible -- so simply not fetching the key from
//  Zotero was never enough; the Cite node itself has to be flattened back to literal text
//  before citeproc ever sees it.
//
//  Two DIFFERENT and complementary things are proven here, deliberately not conflated:
//
//  1. Pandoc itself is order-sensitive (the two `runPandocToLatex`-based tests below). This
//     is a NECESSARY but NOT SUFFICIENT condition: hand-building both argument orderings and
//     feeding each to real pandoc proves pandoc cares which order it sees `--lua-filter` vs
//     `--citeproc` in, but says nothing about what order PRODUCTION actually emits, since
//     these two tests build their own argument array from scratch rather than calling any
//     real ExportService code path.
//  2. Production's real `ExportService.buildBaseArguments` (via `@testable import`, not
//     `private`) actually places the bare-citations-literal.lua `--lua-filter` argument in
//     its PDF-format output (`testProductionBuildBaseArguments_...` below). Because
//     `export()` always calls `buildBaseArguments` in full before it ever computes
//     `citationArguments`/`bibliographyWriteArguments` (which is what appends `--citeproc`),
//     and always appends the latter's result AFTER the former's returned array, a real
//     `--lua-filter <bare-citations path>` found INSIDE `buildBaseArguments`'s own returned
//     array is guaranteed to land before any `--citeproc` production adds later -- so this
//     test would fail if a future change moved the bare-citations lua-filter line out of
//     `buildBaseArguments` and into `citationArguments` (after `--citeproc`), which is
//     exactly the regression #1 alone could never catch (it doesn't touch production code at
//     all). `buildBaseArguments` needs a real on-disk path rather than `ExportService.
//     bundledBareCitationsLuaPath` because `Bundle.main` doesn't resolve bundled `Export/`
//     resources correctly from the unit-test host -- see `ResourcePaths.
//     bareCitationsLuaPathOverride`'s doc comment in ExportService.swift for the injection
//     seam this test uses instead.
//
//  Together, (1)+(2) close the gap a single test could not: (2) proves production's real
//  argument order is correct; (1) proves that order is what actually matters to pandoc.
//
//  Locates the bundled Lua filter relative to THIS source file's location (repo root ->
//  final final/Resources/Export/...) rather than via Bundle.main, which in a unit-test host
//  resolves to the XCTest runner's own bundle, not the app's -- see
//  ImageCaptionExportTests.swift's identical #filePath-relative pattern for figure-
//  placement.lua, the sibling PDF-only Lua filter this test mirrors.
//

import XCTest
import Foundation
@testable import final_final

final class BareCitationExportTests: XCTestCase {

    // MARK: - Pandoc/resource helpers

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var bareCitationsLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/bare-citations-literal.lua").path
    }

    /// A single real-shaped, resolvable CSL-JSON bibliography entry.
    private static let bibliographyJSON = """
    [
      {"id": "smith2020", "type": "book", "title": "A Real Resolvable Book", \
    "author": [{"family": "Smith", "given": "Jane"}], "issued": {"date-parts": [[2020]]}}
    ]
    """

    /// Markdown containing both a genuinely bracketed citation for the fixture's key (which
    /// must resolve) and a bare `@key` for a DIFFERENT, deliberately unresolvable key (so
    /// that, absent the filter, citeproc would render it as a broken marker rather than
    /// simply omitting it -- proving the filter is what keeps it literal, not the mere
    /// absence of a bibliography entry).
    private static let markdownContent =
        "See [@smith2020] for details. A bare @nonexistentkey2099 should stay literal text, not resolve."

    /// Runs real Pandoc `--to latex` with the given argument ordering around `--citeproc`,
    /// against a temp bibliography file built from `bibliographyJSON`.
    private func runPandocToLatex(filterBeforeCiteproc: Bool) throws -> String {
        guard let pandocPath = Self.findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping bare-citation LaTeX verification")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.bareCitationsLuaPath),
                      "bare-citations-literal.lua should exist at \(Self.bareCitationsLuaPath)")

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        let bibURL = tempDir.appendingPathComponent(UUID().uuidString + ".json")
        try Self.markdownContent.write(to: inputURL, atomically: true, encoding: .utf8)
        try Self.bibliographyJSON.write(to: bibURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: bibURL)
        }

        var arguments = [inputURL.path, "--from", "markdown", "--to", "latex"]
        let filterArgs = ["--lua-filter", Self.bareCitationsLuaPath]
        let citeprocArgs = ["--citeproc", "--bibliography", bibURL.path]
        if filterBeforeCiteproc {
            // Matches production: ExportService.buildBaseArguments appends the filter, then
            // citationArguments appends --citeproc afterward.
            arguments.append(contentsOf: filterArgs)
            arguments.append(contentsOf: citeprocArgs)
        } else {
            arguments.append(contentsOf: citeprocArgs)
            arguments.append(contentsOf: filterArgs)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0,
                       "pandoc --to latex should succeed; stderr: \(String(data: stderrData, encoding: .utf8) ?? "")")

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Real production seam: buildBaseArguments actually places the filter

    /// Calls the REAL, non-hand-duplicated `ExportService.buildBaseArguments` and asserts its
    /// actual returned argument array places `--lua-filter <bare-citations-literal path>`
    /// somewhere in the PDF-format output. See the file header comment for why this is the
    /// piece the pandoc-order tests below cannot prove on their own, and why the injected
    /// `bareCitationsLuaPathOverride` is needed instead of the real `Bundle.main` lookup.
    func testProductionBuildBaseArguments_PlacesBareCitationsLuaFilterForPDF() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.bareCitationsLuaPath),
                      "bare-citations-literal.lua should exist at \(Self.bareCitationsLuaPath)")

        let service = ExportService()
        let pdfPrep = ExportService.PDFContentPreparation(
            content: "Placeholder content for argument-order verification.",
            effectiveResourceURL: nil,
            tempMediaDir: nil,
            warnings: []
        )
        let resourcePaths = ExportService.ResourcePaths(
            luaScriptPath: nil,
            referenceDocPath: nil,
            bareCitationsLuaPathOverride: Self.bareCitationsLuaPath,
            mathSpecialCharsLuaPathOverride: nil
        )

        let arguments = await service.buildBaseArguments(
            inputURL: URL(fileURLWithPath: "/tmp/bare-citation-order-test-input.md"),
            outputURL: URL(fileURLWithPath: "/tmp/bare-citation-order-test-output.pdf"),
            format: .pdf,
            pdfPrep: pdfPrep,
            resourcePaths: resourcePaths
        )

        guard let pathIndex = arguments.firstIndex(of: Self.bareCitationsLuaPath) else {
            XCTFail("buildBaseArguments must include the bare-citations-literal.lua path for PDF. Arguments: \(arguments)")
            return
        }
        XCTAssertGreaterThan(pathIndex, 0, "The path must be preceded by a flag. Arguments: \(arguments)")
        XCTAssertEqual(arguments[pathIndex - 1], "--lua-filter",
                       "The path must immediately follow a --lua-filter flag. Arguments: \(arguments)")
        XCTAssertFalse(arguments.contains("--citeproc"),
                       "buildBaseArguments itself never adds --citeproc (that's citationArguments's job, " +
                       "appended by export() strictly after this array) -- confirms nothing here already " +
                       "smuggled it in ahead of the filter. Arguments: \(arguments)")
    }

    // MARK: - Production argument order (filter BEFORE --citeproc)

    func testBareCitation_FilterBeforeCiteproc_StaysLiteralAndBracketResolves() throws {
        let latex = try runPandocToLatex(filterBeforeCiteproc: true)

        XCTAssertTrue(latex.contains("Smith") && latex.contains("2020"),
                      "The genuinely bracketed [@smith2020] citation must still resolve via citeproc. LaTeX:\n\(latex)")
        XCTAssertTrue(latex.contains("@nonexistentkey2099"),
                      "The bare @key must survive as its own literal text. LaTeX:\n\(latex)")
        XCTAssertFalse(latex.contains("nonexistentkey2099?"),
                       "The bare key must NOT be rendered as citeproc's broken-citation marker. LaTeX:\n\(latex)")
    }

    // MARK: - Regression guard: wrong argument order reproduces the broken marker
    //
    // Negative control, run directly against real pandoc (not merely asserted from memory):
    // when the filter is placed AFTER --citeproc, citeproc has already converted the
    // unresolved bare Cite node into the broken `\textbf{key?}` marker by the time the
    // filter runs against what's left in the document -- there is no more Cite node for the
    // filter's Cite() function to intercept, so the marker survives untouched. This proves
    // the test suite actually depends on the correct ordering, not merely on the filter's
    // presence.
    func testBareCitation_FilterAfterCiteproc_ReproducesBrokenMarker() throws {
        let latex = try runPandocToLatex(filterBeforeCiteproc: false)

        XCTAssertTrue(latex.contains("nonexistentkey2099?"),
                      "Wrong ordering must reproduce citeproc's broken-citation marker -- proves this test suite is " +
                      "actually sensitive to argument order, matching the exact regression production guards against. " +
                      "LaTeX:\n\(latex)")
    }
}
