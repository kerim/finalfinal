//
//  URLWrapWorkaroundTexTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Fix 2 in isolation: xurl-workaround.tex (the `\UrlBreaks` LaTeX-preamble fix). Split out of
//  URLWrapExportTests.swift (SwiftLint type_body_length) -- see that file for the full feature
//  background comment shared by every URLWrap*Tests.swift file.
//
//  This fix lives entirely in the LaTeX *preamble* (`\UrlBreaks`), which only affects line
//  breaking during actual PDF compilation -- a non-standalone `--to latex` fragment never
//  includes --include-in-header content at all. So these tests compile a REAL PDF with the
//  bundled xelatex and check, via `pdftotext`, that the rendered text wraps the URL across
//  multiple lines instead of it surviving intact as one unbroken run (confirmed manually
//  against this exact fixture: without the fix, xdvipdfmx reports the hyperlink annotation's
//  bounding box extending ~500pt past the page's 612pt width; with the fix, that warning
//  disappears and the extracted text shows the URL split across 4 lines).
//

import XCTest
import Foundation
@testable import final_final

final class URLWrapWorkaroundTexTests: XCTestCase {

    func testXurlWorkaroundTexExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.xurlWorkaroundTexPath),
                      "xurl-workaround.tex should exist at \(URLWrapExportFixtures.xurlWorkaroundTexPath)")
    }

    /// Compiles the long-unbroken-URL fixture with real pandoc + the real bundled xelatex,
    /// optionally with xurl-workaround.tex applied via --include-in-header exactly as
    /// ExportService.buildBaseArguments wires it in for PDF export, and returns both the
    /// pdftotext-extracted rendered text AND pandoc's stderr (which relays xelatex/xdvipdfmx's
    /// own warnings, including the page-boundary-overflow warning that is the actual pre-fix
    /// symptom -- see the negative-control test's doc comment for why stderr, not the rendered
    /// text, is the reliable signal for "did the URL overflow the page").
    private func compileLongURLFixtureAndExtractText(
        applyXurlFix: Bool
    ) throws -> (renderedText: String, stderr: String) {
        guard let pandocPath = URLWrapExportFixtures.findPandocPath() else {
            throw XCTSkip("Pandoc not installed -- skipping real PDF compilation verification")
        }
        guard FileManager.default.isExecutableFile(atPath: URLWrapExportFixtures.bundledXelatexPath) else {
            throw XCTSkip("Bundled TinyTeX xelatex not present -- skipping real PDF compilation verification")
        }
        guard let pdftotextPath = URLWrapExportFixtures.findPdftotextPath() else {
            throw XCTSkip("pdftotext not installed -- skipping PDF text-layout verification")
        }
        if applyXurlFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.xurlWorkaroundTexPath),
                          "xurl-workaround.tex should exist at \(URLWrapExportFixtures.xurlWorkaroundTexPath)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xurl-wrap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let markdown = "Retrieved from <\(URLWrapExportFixtures.longURL)>\n"

        let inputURL = tempDir.appendingPathComponent("input.md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)

        // Space-free symlink to the bundled TinyTeX + xdvipdfmx wrapper, mirroring
        // ExportService.prepareBundledTinyTeX()'s own spaces-in-app-bundle-path workaround --
        // this repo's own checkout path contains a space ("final final").
        let symlinkURL = tempDir.appendingPathComponent("TinyTeX")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL, withDestinationURL: URLWrapExportFixtures.bundledTinyTeXURL)
        let xelatexPath = symlinkURL.appendingPathComponent("bin/universal-darwin/xelatex").path
        let xdvipdfmxPath = symlinkURL.appendingPathComponent("bin/universal-darwin/xdvipdfmx").path

        let wrapperURL = tempDir.appendingPathComponent("xdvipdfmx-wrapper.sh")
        try "#!/bin/bash\nexec \"\(xdvipdfmxPath)\" \"$@\"\n"
            .write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        let outputURL = tempDir.appendingPathComponent("output.pdf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        var arguments = [
            inputURL.path, "--from", "markdown", "--to", "pdf",
            "--output", outputURL.path,
            "--pdf-engine", xelatexPath,
            "--pdf-engine-opt", "-output-driver=\(wrapperURL.path)"
        ]
        if applyXurlFix {
            arguments.append(contentsOf: ["--include-in-header", URLWrapExportFixtures.xurlWorkaroundTexPath])
        }
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Nothing consumes stdout here (the PDF itself goes to --output, not stdout) -- so
        // there's no payload to drain into a Pipe(). A Pipe() that's never read still hangs
        // once pandoc writes past the OS pipe's fixed buffer (~64KB on macOS), with zero
        // diagnostic. FileHandle.nullDevice is the simplest correct fix when output is
        // genuinely unused.
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0,
                       "pandoc PDF export should succeed; stderr: \(String(data: stderrData, encoding: .utf8) ?? "")")

        let textProcess = Process()
        textProcess.executableURL = URL(fileURLWithPath: pdftotextPath)
        textProcess.arguments = ["-layout", outputURL.path, "-"]
        let textPipe = Pipe()
        textProcess.standardOutput = textPipe
        try textProcess.run()
        textProcess.waitUntilExit()
        let renderedText = String(data: textPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        return (renderedText, stderrText)
    }

    /// End-to-end: real pandoc, real bundled xelatex, a genuinely long unbroken-alphanumeric
    /// citation URL, with xurl-workaround.tex applied via --include-in-header exactly as
    /// ExportService.buildBaseArguments wires it in for PDF export. Asserts the rendered PDF
    /// text shows the URL broken across multiple lines rather than surviving as one run.
    func testLongUnbrokenURL_WrapsAcrossMultipleLines_InCompiledPDF() throws {
        let (renderedText, stderr) = try compileLongURLFixtureAndExtractText(applyXurlFix: true)

        XCTAssertFalse(renderedText.contains(URLWrapExportFixtures.longURL),
                       "The long URL must wrap across multiple lines, not survive intact on one line. " +
                       "Rendered text:\n\(renderedText)")
        XCTAssertTrue(renderedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                      "The end of the URL must still be present somewhere in the wrapped text. " +
                      "Rendered text:\n\(renderedText)")
        XCTAssertFalse(stderr.contains("Annotation out of page boundary"),
                       "With xurl-workaround.tex applied, xdvipdfmx should no longer report the " +
                       "hyperlink annotation's bounding box extending past the page boundary. " +
                       "Stderr:\n\(stderr)")
    }

    /// Negative control: confirms the wrap in the other test genuinely comes from
    /// xurl-workaround.tex, not from pandoc's default template or xelatex's own default
    /// behavior. Reproduces the exact pre-fix pandoc invocation (no --include-in-header) and
    /// asserts the pre-fix symptom actually occurs: xdvipdfmx's own stderr warning that the
    /// hyperlink annotation's bounding box extends past the page boundary.
    ///
    /// This deliberately does NOT assert `renderedText.contains(Self.longURL)` (an earlier
    /// version of this test did, and it failed). Verified directly by compiling this exact
    /// fixture without the fix and inspecting pdftotext's raw output: `pdftotext -layout` does
    /// NOT preserve off-page overflowing text as one intact unbroken run -- it TRUNCATES the
    /// extracted text at the point the glyphs cross the page's right margin. The rendered text
    /// comes back as just "Retrieved from https://example.com/articles/aVeryLongUnbrokenAlpha
    /// numericTrackingParameterSegmentT" with the rest of the URL silently dropped, not present
    /// anywhere, wrapped or not. So `renderedText.contains(longURL)` is false in BOTH the fixed
    /// case (wrapped across lines) and the unfixed case (truncated past the margin), for two
    /// different reasons -- it cannot distinguish "wrapped" from "overflowed," which is exactly
    /// why the assertion based on it was failing here regardless of fix state. xdvipdfmx's
    /// stderr warning is the only reliable signal that overflow actually occurred; confirmed via
    /// `xdvipdfmx:warning: Annotation out of page boundary` / `Current page's MediaBox: [0 0 612
    /// 792]` / `Annotation: [200.1 654.346 1133.58 668.463]` (i.e. the annotation's right edge at
    /// x=1133.58 vs. the page's right edge at x=612) appearing only when xurl-workaround.tex is
    /// omitted.
    func testLongUnbrokenURL_WithoutXurlWorkaround_OverflowsPageBoundary() throws {
        let (renderedText, stderr) = try compileLongURLFixtureAndExtractText(applyXurlFix: false)

        XCTAssertTrue(stderr.contains("Annotation out of page boundary"),
                      "Without xurl-workaround.tex, xdvipdfmx must report the hyperlink annotation " +
                      "extending past the page boundary -- reproducing the pre-fix bug and proving " +
                      "the wrap in the other test is actually caused by the fix, not by pandoc's " +
                      "default template or xelatex's own default behavior. Stderr:\n\(stderr)\n\n" +
                      "Rendered text (reference only -- pdftotext truncates rather than preserving " +
                      "the overflow; see this test's doc comment):\n\(renderedText)")
    }
}
