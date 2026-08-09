//
//  URLWrapExportTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Real-pandoc + real-bundled-xelatex integration test for the long-citation-URL page-margin
//  overflow fix: a long, unbroken alphanumeric URL (e.g. a DOI or a tracking-parameter-heavy
//  citation link) with no slashes/hyphens to break at used to run off the page instead of
//  wrapping, because pandoc's default LaTeX template only loads xurl.sty conditionally
//  (`\IfFileExists{xurl.sty}{\usepackage{xurl}}{}`), and xurl.sty isn't part of this app's
//  bundled TinyTeX distribution -- so that conditional silently no-ops (confirmed: zero matches
//  for `xurl*` anywhere under Resources/TinyTeX). The fix has two parts: xurl-workaround.tex
//  (a LaTeX-preamble `\UrlBreaks`) and linkify-urls.lua (turns a bare URL-shaped Str into a
//  real Link, since `\UrlBreaks` only affects an actual `\url{}`).
//
//  This file covers Fix 1 (linkify-urls.lua) and Fix 2 (xurl-workaround.tex) TOGETHER, via real
//  PDF compilation -- the end-to-end proof the two fixes actually cooperate. This suite is split
//  across several files purely to stay under SwiftLint's type_body_length limit, each covering
//  one logical concern:
//    - URLWrapWorkaroundTexTests.swift      -- Fix 2 (xurl-workaround.tex) alone
//    - URLWrapLinkifyFilterTests.swift      -- Fix 1 (linkify-urls.lua) alone, fast `--to latex` fragments
//    - URLWrapArchiveSuppressionTests.swift -- Fix 2's CSL archive-field suppression, via real citeproc
//    - URLWrapArgumentOrderTests.swift      -- ExportService.assembleFinalArguments wiring/order regression
//    - URLWrapExportTestSupport.swift       -- shared resource paths + executable discovery
//
//  Resources (xurl-workaround.tex, linkify-urls.lua, chicago-author-date.csl, bundled xelatex)
//  are located relative to URLWrapExportTestSupport.swift (repo root), the same #filePath
//  pattern ImageCaptionExportTests.swift and FixtureGeneratorTests.swift use, since Bundle.main
//  in a unit-test host is the XCTest runner's own bundle, not the app's.
//

import XCTest
import Foundation
@testable import final_final

final class URLWrapExportTests: XCTestCase {

    // MARK: - Fix 1 + Fix 2 together: real PDF-compile tests
    //
    // Unlike the fragment tests in URLWrapLinkifyFilterTests.swift, these compile a REAL PDF
    // with the real bundled xelatex, with linkify-urls.lua and xurl-workaround.tex wired
    // together exactly as ExportService.export()/assembleFinalArguments do for a real PDF
    // export. Run with `--verbose` so pdfTeX's own "Overfull \hbox" warnings are captured in
    // stderr -- pandoc otherwise suppresses the engine's log entirely on a zero-exit-status run
    // (confirmed empirically: identical invocation without --verbose produces the same PDF but
    // zero log lines in stderr). Distinct from xdvipdfmx's "Annotation out of page boundary"
    // warning used by URLWrapWorkaroundTexTests.swift -- that one only fires for a hyperlink
    // annotation (i.e. a real Link/\url{}); a bare, un-linkified Str overflows via an ordinary
    // "Overfull \hbox" instead, since pandoc never wraps unlinked plain text in \url{} at all.

    /// Compiles a markdown fixture with real pandoc + the real bundled xelatex, optionally
    /// wiring in linkify-urls.lua, xurl-workaround.tex, and a real `--citeproc` bibliography.
    private func compilePDFFixtureAndExtractText(
        markdown: String,
        applyLinkifyFix: Bool,
        applyXurlFix: Bool,
        bibliographyJSON: String? = nil
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
        if applyLinkifyFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.linkifyUrlsLuaPath),
                          "linkify-urls.lua should exist at \(URLWrapExportFixtures.linkifyUrlsLuaPath)")
        }
        if applyXurlFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.xurlWorkaroundTexPath),
                          "xurl-workaround.tex should exist at \(URLWrapExportFixtures.xurlWorkaroundTexPath)")
        }
        if bibliographyJSON != nil {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.cslPath),
                          "chicago-author-date.csl should exist at \(URLWrapExportFixtures.cslPath)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xurl-wrap-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)

        // Space-free symlink to the bundled TinyTeX + xdvipdfmx wrapper, mirroring
        // ExportService.prepareBundledTinyTeX()'s own spaces-in-app-bundle-path workaround --
        // this repo's own checkout path contains a space ("final final"). Same setup as
        // URLWrapWorkaroundTexTests.swift's own PDF-compile helper.
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
            "--pdf-engine-opt", "-output-driver=\(wrapperURL.path)",
            "--verbose"
        ]
        if let bibliographyJSON {
            let bibURL = tempDir.appendingPathComponent("bibliography.json")
            try bibliographyJSON.write(to: bibURL, atomically: true, encoding: .utf8)
            // Order matches ExportService.citationArguments(): --citeproc before the linkify
            // filter gets appended below -- see URLWrapArgumentOrderTests.swift for the
            // dedicated argument-order regression tests.
            arguments.append(contentsOf: [
                "--citeproc", "--bibliography", bibURL.path, "--csl", URLWrapExportFixtures.cslPath
            ])
        }
        if applyXurlFix {
            arguments.append(contentsOf: ["--include-in-header", URLWrapExportFixtures.xurlWorkaroundTexPath])
        }
        if applyLinkifyFix {
            arguments.append(contentsOf: ["--lua-filter", URLWrapExportFixtures.linkifyUrlsLuaPath])
        }
        process.arguments = arguments
        // `--verbose` makes pandoc dump its own diagnostics (temp dir, full command line,
        // environment, and the entire rendered LaTeX source) plus xelatex's full
        // package-loading trace to stderr -- easily exceeding the OS pipe's fixed buffer
        // (~64KB on macOS). A Pipe() read AFTER waitUntilExit() deadlocks once that happens:
        // pandoc blocks on write() with nobody draining the pipe, and waitUntilExit() never
        // returns because pandoc is blocked. Redirect to a temp file instead -- files have no
        // fixed OS buffer size, so this can never deadlock regardless of output volume.
        let stderrFileURL = tempDir.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stderrFileURL.path, contents: nil)
        let stderrFileHandle = try FileHandle(forWritingTo: stderrFileURL)
        process.standardError = stderrFileHandle
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        try stderrFileHandle.close()
        let stderrData = try Data(contentsOf: stderrFileURL)
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

    /// Counts pdfTeX's own "Overfull \hbox (" runtime warnings in a `--verbose` stderr capture.
    private func overfullHboxWarningCount(in stderr: String) -> Int {
        stderr.components(separatedBy: "Overfull \\hbox (").count - 1
    }

    /// Real PDF-compile test, body text: a bare, unlinked long URL in an ordinary paragraph, no
    /// citation involved, compiled with both linkify-urls.lua and xurl-workaround.tex together.
    /// pdftotext confirms it wraps across multiple lines instead of overflowing.
    func testBareBodyTextURL_WithBothFixesApplied_WrapsAcrossMultipleLinesInCompiledPDF() throws {
        let markdown = "See \(URLWrapExportFixtures.longURL) for the full dataset.\n"

        let (renderedText, stderr) = try compilePDFFixtureAndExtractText(
            markdown: markdown, applyLinkifyFix: true, applyXurlFix: true
        )

        XCTAssertFalse(renderedText.contains(URLWrapExportFixtures.longURL),
                       "The long URL must wrap across multiple lines, not survive intact on one " +
                       "line. Rendered text:\n\(renderedText)")
        XCTAssertTrue(renderedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                      "The end of the URL must still be present somewhere in the wrapped text. " +
                      "Rendered text:\n\(renderedText)")
        XCTAssertEqual(overfullHboxWarningCount(in: stderr), 0,
                       "With both fixes applied, pdfTeX should report zero Overfull-hbox " +
                       "warnings for this paragraph. Stderr:\n\(stderr)")
    }

    /// Negative control: with ONLY xurl-workaround.tex applied (no linkify-urls.lua), the bare
    /// Str URL is never turned into a real link, so \UrlBreaks never gets a chance to apply --
    /// the text overflows exactly as before Fix 1, proving linkify-urls.lua (not
    /// xurl-workaround.tex alone) is what makes body-text URLs wrap. Verified empirically:
    /// identical invocation minus --lua-filter produces 2 "Overfull \hbox (" warnings; with the
    /// filter added, 0.
    func testBareBodyTextURL_WithOnlyXurlWorkaround_StillOverflowsWithOverfullHboxWarning() throws {
        let markdown = "See \(URLWrapExportFixtures.longURL) for the full dataset.\n"

        let (_, stderr) = try compilePDFFixtureAndExtractText(
            markdown: markdown, applyLinkifyFix: false, applyXurlFix: true
        )

        XCTAssertGreaterThan(overfullHboxWarningCount(in: stderr), 0,
                             "Without linkify-urls.lua, a bare-Str body-text URL is never " +
                             "turned into a real link, so xurl-workaround.tex's \\UrlBreaks " +
                             "never applies to it -- pdfTeX must still report an Overfull-hbox " +
                             "warning, reproducing the pre-fix bug. Stderr:\n\(stderr)")
    }

    /// Real PDF-compile test, citation field: the URL comes from a real citeproc-rendered
    /// bibliography entry's CSL field -- `archive_collection`, deliberately NOT `archive` (Fix 2
    /// suppresses `archive` from ever rendering, so a test built around it would silently stop
    /// testing anything once Fix 2 lands). `archive_collection` is untouched by Fix 2 and
    /// renders in unmodified case via `source-archive-reference-location-first-bib` -- confirmed
    /// empirically to be a better fit than `medium`, which this CSL style capitalizes via
    /// `text-case="capitalize-first"` and would break the filter's case-sensitive `^https?://`
    /// anchor (rendering as "Https://...").
    func testCitationFieldURL_WithBothFixesApplied_WrapsAcrossMultipleLinesInCompiledPDF() throws {
        let bibliographyJSON = """
            [{"id":"item1","type":"book","title":"A Test Book",
              "author":[{"family":"Smith","given":"John"}],"issued":{"date-parts":[[2020]]},
              "publisher":"Acme Press","archive_collection":"\(URLWrapExportFixtures.longURL)"}]
            """
        let markdown = "According to research [@item1], much has changed.\n"

        let (renderedText, stderr) = try compilePDFFixtureAndExtractText(
            markdown: markdown, applyLinkifyFix: true, applyXurlFix: true,
            bibliographyJSON: bibliographyJSON
        )

        XCTAssertFalse(renderedText.contains(URLWrapExportFixtures.longURL),
                       "The citation-field URL must wrap across multiple lines, not survive " +
                       "intact on one line. Rendered text:\n\(renderedText)")
        // `pdftotext -layout` can insert a line-wrap (and leading indentation whitespace) in the
        // middle of the tail marker itself when the wrap point falls inside this run -- e.g. the
        // bibliography entry's hanging indent pushes "...QRSTUVW" onto one line and
        // "   XYZ0123456789" onto the next. That's the wrap working correctly (the actual
        // behavior under test), not a failure, so strip whitespace/newlines from the rendered
        // text before checking for the tail marker -- concatenating the wrapped pieces back
        // together without reordering them.
        let flattenedRenderedText = renderedText.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(flattenedRenderedText.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                      "The end of the URL must still be present somewhere in the wrapped text " +
                      "(whitespace/newlines stripped to tolerate pdftotext -layout's mid-marker " +
                      "line wrap). Rendered text:\n\(renderedText)")
        XCTAssertEqual(overfullHboxWarningCount(in: stderr), 0,
                       "With both fixes applied, pdfTeX should report zero Overfull-hbox " +
                       "warnings for the bibliography entry. Stderr:\n\(stderr)")
    }

    /// Negative control for the citation-field case: real citeproc rendering plus
    /// xurl-workaround.tex alone (no linkify-urls.lua) still overflows, since `--citeproc`'s own
    /// bibliography rendering produces plain Str text, never a real Link on its own -- proving
    /// this fix genuinely needs linkify-urls.lua running after it, not just citeproc plus the
    /// preamble fix.
    func testCitationFieldURL_WithOnlyXurlWorkaround_StillOverflowsWithOverfullHboxWarning() throws {
        let bibliographyJSON = """
            [{"id":"item1","type":"book","title":"A Test Book",
              "author":[{"family":"Smith","given":"John"}],"issued":{"date-parts":[[2020]]},
              "publisher":"Acme Press","archive_collection":"\(URLWrapExportFixtures.longURL)"}]
            """
        let markdown = "According to research [@item1], much has changed.\n"

        let (_, stderr) = try compilePDFFixtureAndExtractText(
            markdown: markdown, applyLinkifyFix: false, applyXurlFix: true,
            bibliographyJSON: bibliographyJSON
        )

        XCTAssertGreaterThan(overfullHboxWarningCount(in: stderr), 0,
                             "Without linkify-urls.lua, a citeproc-rendered citation-field URL " +
                             "is never turned into a real link, so xurl-workaround.tex's " +
                             "\\UrlBreaks never applies to it. Stderr:\n\(stderr)")
    }
}
