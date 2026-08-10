//
//  MathSpecialCharsArgumentOrderTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Wiring/argument-order tests for math-special-chars.lua, split out of
//  MathSpecialCharsExportTests.swift (SwiftLint type_body_length) -- mirroring how
//  URLWrapArgumentOrderTests.swift is split out of URLWrapExportTests.swift for the sibling
//  linkify-urls.lua filter. See MathSpecialCharsExportTests.swift for the full feature
//  background comment.
//
//  Unlike that file, these tests never spawn pandoc -- they call ExportService.buildBaseArguments
//  and ExportService.assembleFinalArguments directly (the REAL production functions `export()`
//  itself delegates to), so they catch a wiring regression a fragment/compile test never could:
//  e.g. if someone deleted the math-special-chars wiring block from buildBaseArguments entirely,
//  every test in MathSpecialCharsExportTests.swift would keep passing (they invoke the .lua file
//  directly by path), but the tests here would fail.
//

import XCTest
import Foundation
@testable import final_final

final class MathSpecialCharsArgumentOrderTests: XCTestCase {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var mathSpecialCharsLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/math-special-chars.lua").path
    }

    private static func emptyPDFPrep() -> ExportService.PDFContentPreparation {
        ExportService.PDFContentPreparation(
            content: "Placeholder content for argument-order verification.",
            effectiveResourceURL: nil,
            tempMediaDir: nil,
            warnings: []
        )
    }

    private static func resourcePaths() -> ExportService.ResourcePaths {
        ExportService.ResourcePaths(
            luaScriptPath: nil,
            referenceDocPath: nil,
            bareCitationsLuaPathOverride: nil,
            mathSpecialCharsLuaPathOverride: Self.mathSpecialCharsLuaPath
        )
    }

    // MARK: - Real production seam: buildBaseArguments actually places the filter

    /// Calls the REAL, non-hand-duplicated `ExportService.buildBaseArguments` and asserts its
    /// actual returned argument array places `--lua-filter <math-special-chars-lua path>`
    /// somewhere in the PDF-format output. Mirrors
    /// `BareCitationExportTests.testProductionBuildBaseArguments_PlacesBareCitationsLuaFilterForPDF`
    /// for the sibling filter.
    func testProductionBuildBaseArguments_PlacesMathSpecialCharsLuaFilterForPDF() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.mathSpecialCharsLuaPath),
                      "math-special-chars.lua should exist at \(Self.mathSpecialCharsLuaPath)")

        let service = ExportService()
        let arguments = await service.buildBaseArguments(
            inputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-input.md"),
            outputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-output.pdf"),
            format: .pdf,
            pdfPrep: Self.emptyPDFPrep(),
            resourcePaths: Self.resourcePaths()
        )

        guard let pathIndex = arguments.firstIndex(of: Self.mathSpecialCharsLuaPath) else {
            XCTFail("buildBaseArguments must include the math-special-chars.lua path for PDF. Arguments: \(arguments)")
            return
        }
        XCTAssertGreaterThan(pathIndex, 0, "The path must be preceded by a flag. Arguments: \(arguments)")
        XCTAssertEqual(arguments[pathIndex - 1], "--lua-filter",
                       "The path must immediately follow a --lua-filter flag. Arguments: \(arguments)")
    }

    /// Non-PDF formats (DOCX/ODT) must NOT get this PDF-only filter -- they don't invoke xelatex
    /// at all, so there is no LaTeX-special-character crash for it to prevent there.
    func testProductionBuildBaseArguments_DoesNotPlaceMathSpecialCharsLuaFilterForNonPDFFormats() async {
        let service = ExportService()

        for format: ExportFormat in [.word, .odt] {
            let arguments = await service.buildBaseArguments(
                inputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-input.md"),
                outputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-output.\(format.rawValue)"),
                format: format,
                pdfPrep: Self.emptyPDFPrep(),
                resourcePaths: Self.resourcePaths()
            )

            XCTAssertFalse(arguments.contains(Self.mathSpecialCharsLuaPath),
                           "\(format) export must not get the PDF-only math-special-chars filter. Arguments: \(arguments)")
        }
    }

    // MARK: - Ordering relative to --citeproc (documents/executes the review's must-fix 2)

    /// Executable companion to the doc comment on this filter's wiring site in
    /// `ExportService.buildBaseArguments`: today the filter runs BEFORE `--citeproc` gets
    /// appended by `assembleFinalArguments`. That is a real, deliberate constraint on THIS
    /// filter's position (unlike its position relative to the other PDF-only filters in the same
    /// block, which genuinely is free) -- citeproc can generate its own fresh Math nodes from a
    /// bibliography field's raw LaTeX, and this filter running first means it never sees them.
    /// Only safe today because this app's actual bibliography source is CSL JSON, which never
    /// hands citeproc a real math span (confirmed separately, by direct reproduction, in
    /// MathSpecialCharsExportTests.swift's compile-level tests). This test pins the CURRENT
    /// ordering so a future change to that ordering is a deliberate, visible diff here rather
    /// than a silent behavior change.
    func testAssembleFinalArguments_MathSpecialCharsFilterComesBeforeCiteproc_ForPDFWithCitations() async {
        let service = ExportService()
        let baseArguments = await service.buildBaseArguments(
            inputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-input.md"),
            outputURL: URL(fileURLWithPath: "/tmp/math-special-chars-order-test-output.pdf"),
            format: .pdf,
            pdfPrep: Self.emptyPDFPrep(),
            resourcePaths: Self.resourcePaths()
        )
        let citationArguments = ["--citeproc", "--bibliography", "/tmp/bib.json", "--csl", "/tmp/style.csl"]

        let finalArguments = await service.assembleFinalArguments(
            baseArguments: baseArguments,
            citationArguments: citationArguments,
            format: .pdf,
            linkifyUrlsLuaPath: nil
        )

        guard let citeprocIndex = finalArguments.firstIndex(of: "--citeproc") else {
            XCTFail("Expected --citeproc to be present in the assembled arguments: \(finalArguments)")
            return
        }
        guard let mathFilterPathIndex = finalArguments.firstIndex(of: Self.mathSpecialCharsLuaPath) else {
            XCTFail("Expected the math-special-chars.lua path in the assembled arguments: \(finalArguments)")
            return
        }

        XCTAssertLessThan(mathFilterPathIndex, citeprocIndex,
            "math-special-chars.lua currently runs BEFORE --citeproc -- see the doc comment at " +
            "its call site in ExportService.buildBaseArguments for why that is currently safe " +
            "(CSL-JSON bibliographies never hand citeproc a real math span) but not free in " +
            "general. Assembled arguments:\n\(finalArguments)")
    }
}
