//
//  URLWrapLinkifyFilterTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Fix 1 in isolation: linkify-urls.lua (converting a bare URL-shaped Str into a real Link).
//  Split out of URLWrapExportTests.swift (SwiftLint type_body_length) -- see that file for the
//  full feature background comment shared by every URLWrap*Tests.swift file.
//
//  Unlike xurl-workaround.tex (URLWrapWorkaroundTexTests.swift), which lives entirely in the
//  LaTeX preamble and only affects actual PDF compilation, this fix is fully observable from a
//  `--to latex` fragment -- so these tests prove the filter itself rewrites the AST correctly,
//  cheaply, without paying for a full PDF compile every time.
//

import XCTest
import Foundation
@testable import final_final

final class URLWrapLinkifyFilterTests: XCTestCase {

    /// Runs real Pandoc `--to latex` with linkify-urls.lua optionally applied.
    private func runPandocToLatex(markdown: String, applyLinkifyFix: Bool) throws -> String {
        guard let pandocPath = URLWrapExportFixtures.findPandocPath() else {
            throw XCTSkip("Pandoc not installed -- skipping LaTeX assembly verification")
        }
        if applyLinkifyFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URLWrapExportFixtures.linkifyUrlsLuaPath),
                          "linkify-urls.lua should exist at \(URLWrapExportFixtures.linkifyUrlsLuaPath)")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        var arguments = [inputURL.path, "--from", "markdown", "--to", "latex"]
        if applyLinkifyFix {
            arguments.append(contentsOf: ["--lua-filter", URLWrapExportFixtures.linkifyUrlsLuaPath])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        process.arguments = arguments
        // The rendered LaTeX is the payload here (unlike compilePDFFixtureAndExtractText, where
        // the large stream is stderr under --verbose) -- reading a Pipe() for it AFTER
        // waitUntilExit() deadlocks once the document exceeds the OS pipe's fixed buffer (~64KB
        // on macOS): pandoc blocks on write() with nobody draining stdout, and waitUntilExit()
        // never returns. Redirect stdout to a temp file instead, same fix
        // compilePDFFixtureAndExtractText applies to its own large-output stream.
        let stdoutFileURL = tempDir.appendingPathComponent(UUID().uuidString + "-stdout.tex")
        FileManager.default.createFile(atPath: stdoutFileURL.path, contents: nil)
        let stdoutFileHandle = try FileHandle(forWritingTo: stdoutFileURL)
        defer { try? FileManager.default.removeItem(at: stdoutFileURL) }
        process.standardOutput = stdoutFileHandle
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        try stdoutFileHandle.close()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0,
                       "pandoc --to latex should succeed; stderr: \(String(data: stderrData, encoding: .utf8) ?? "")")

        let data = try Data(contentsOf: stdoutFileURL)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Fast fragment test, position 1 of 2: a bare URL in an ordinary body paragraph becomes a
    /// real `\url{}` link once linkify-urls.lua runs -- proving the filter fires on plain body
    /// text, one of the two confirmed sources of unlinked URLs (the other is CSL fields, tested
    /// below via `testLinkifyFilter_BareURLInBibliographyShapedSnippet_BecomesRealLinkInLatex`).
    func testLinkifyFilter_BareURLInBodyParagraph_BecomesRealLinkInLatex() throws {
        let markdown = "Visit https://example.com/path for more information.\n"

        let withFilter = try runPandocToLatex(markdown: markdown, applyLinkifyFix: true)
        XCTAssertTrue(withFilter.contains("\\url{https://example.com/path}"),
                      "A bare URL in body text should become a real \\url{} link once " +
                      "linkify-urls.lua runs. LaTeX:\n\(withFilter)")

        let withoutFilter = try runPandocToLatex(markdown: markdown, applyLinkifyFix: false)
        XCTAssertFalse(withoutFilter.contains("\\url{"),
                       "Negative control: without the filter, pandoc must not auto-linkify a " +
                       "bare URL on its own. LaTeX:\n\(withoutFilter)")
    }

    /// Fast fragment test, position 2 of 2: a bare URL sitting in a bibliography-shaped
    /// paragraph (mimicking rendered citeproc output, without paying for a real citeproc run)
    /// also becomes a real link -- proving the filter applies document-wide (`traverse =
    /// 'topdown'` over the whole AST), not just to ordinary body paragraphs. Also exercises the
    /// filter's trailing-punctuation stripping (the period after the URL must not end up inside
    /// the href).
    func testLinkifyFilter_BareURLInBibliographyShapedSnippet_BecomesRealLinkInLatex() throws {
        let markdown = "Smith, John. 2020. *A Great Book*. New York: Acme Press. " +
            "Retrieved from https://example.com/archive/item123.\n"

        let latex = try runPandocToLatex(markdown: markdown, applyLinkifyFix: true)

        XCTAssertTrue(latex.contains("\\url{https://example.com/archive/item123}"),
                      "URL in a bibliography-shaped paragraph must become a real \\url{} link, " +
                      "with the trailing period stripped from the href. LaTeX:\n\(latex)")
    }

    /// Balanced-paren fix, positive case: a URL that legitimately ends in ")" (e.g. a Wikipedia
    /// disambiguation link, where the "(" is part of the URL's own path) must keep that
    /// closing paren in the link TARGET, not just in the visible text. Before the fix,
    /// TRAILING_PUNCTUATION stripped the ")" from the href unconditionally, silently truncating
    /// the click target while leaving the rendered text intact.
    func testLinkifyFilter_URLWithOwnUnmatchedOpenParen_KeepsClosingParenInLinkTarget() throws {
        let markdown = "See https://en.wikipedia.org/wiki/Example_(disambiguation) for details.\n"

        let latex = try runPandocToLatex(markdown: markdown, applyLinkifyFix: true)

        XCTAssertTrue(latex.contains("\\url{https://en.wikipedia.org/wiki/Example_(disambiguation)}"),
                      "A URL whose own content has an unmatched '(' must keep the matching " +
                      "trailing ')' in the link target. LaTeX:\n\(latex)")
    }

    /// Balanced-paren fix, negative control (no regression): a URL immediately followed by a
    /// ")" that closes SURROUNDING markdown prose -- not part of the URL itself -- must still
    /// have that paren stripped from the link target, exactly as before the balanced-paren fix.
    func testLinkifyFilter_URLFollowedByProseClosingParen_StripsParenFromLinkTarget() throws {
        let markdown = "For background (see https://example.com) for more.\n"

        let latex = try runPandocToLatex(markdown: markdown, applyLinkifyFix: true)

        XCTAssertTrue(latex.contains("\\url{https://example.com}"),
                      "A URL with no unmatched '(' of its own must still have a prose-closing " +
                      "')' stripped from the link target. LaTeX:\n\(latex)")
        XCTAssertFalse(latex.contains("\\url{https://example.com)}"),
                       "The surrounding prose's closing ')' must not leak into the link target. " +
                       "LaTeX:\n\(latex)")
    }

    /// Link-guard regression test: an already-linked URL (angle-bracket autolink) must not be
    /// double-wrapped into a nested link. An earlier draft of this exact filter had a real
    /// double-nesting bug from getting the `Link = function(l) return l, false end` guard wrong
    /// -- caught empirically, not fixed here (this filter is used exactly as judge-verified).
    func testLinkifyFilter_AlreadyLinkedURL_IsNotDoubleWrapped() throws {
        let markdown = "See <https://example.com/already-linked> for details.\n"

        let latex = try runPandocToLatex(markdown: markdown, applyLinkifyFix: true)

        XCTAssertTrue(latex.contains("\\url{https://example.com/already-linked}"),
                      "Already-linked URL should still render as a normal \\url{} link. LaTeX:\n\(latex)")
        XCTAssertFalse(latex.contains("\\url{\\url{"),
                       "An already-linked URL must not be re-wrapped into a nested link. LaTeX:\n\(latex)")
        let occurrences = latex.components(separatedBy: "https://example.com/already-linked").count - 1
        XCTAssertEqual(occurrences, 1,
                       "The URL must appear exactly once in the LaTeX output, not duplicated by " +
                       "a Link-wrapping-a-Link traversal bug. LaTeX:\n\(latex)")
    }
}
