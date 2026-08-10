//
//  MathSpecialCharsExportTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Real-pandoc + real-bundled-xelatex integration test for math-special-chars.lua: PDF export
//  used to crash (pandoc exit 43, xelatex "Misplaced alignment tab character &") whenever a
//  document's inline/display math (`$...$`/`$$...$$`) contained an unescaped `&`, since pandoc
//  passes math content through to LaTeX verbatim by design. Confirmed by direct reproduction
//  against this app's real bundled pandoc + xelatex (not guessed) -- see math-special-chars.lua's
//  own header comment for the exact failure signatures for `&`, `#`, and `%`. We don't have
//  access to whatever specific document originally triggered the crash report, so this doesn't
//  prove that document's math was the exact cause -- but this reproduction independently produces
//  the identical failure signature from math content alone, which is a real, fixable bug
//  regardless of the original report's precise trigger.
//
//  Reuses URLWrapExportFixtures (URLWrapExportTestSupport.swift) for pandoc/xelatex/pdftotext
//  discovery and the bundled-TinyTeX path, and mirrors URLWrapExportTests.swift's real-PDF-
//  compile harness (space-free TinyTeX symlink, xdvipdfmx wrapper, stderr-to-a-file instead of a
//  Pipe() to avoid the OS pipe buffer deadlock documented there) rather than building a second
//  one from scratch. Split into its own file rather than folded into an existing URLWrap*Tests.swift
//  file since this fix is unrelated to URL wrapping.
//

import XCTest
import Foundation
@testable import final_final

final class MathSpecialCharsExportTests: XCTestCase {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var mathSpecialCharsLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/math-special-chars.lua").path
    }

    // MARK: - Real PDF-compile harness

    /// Compiles a markdown fixture with real pandoc + the real bundled xelatex, optionally
    /// wiring in math-special-chars.lua. Unlike URLWrapExportTests.swift's harness (which always
    /// expects success and only inspects Overfull-hbox warning counts), this one also has to
    /// tolerate and report a genuine pandoc failure -- that's the crash under test -- so it
    /// returns the raw exit code instead of asserting success internally.
    private func compileMathFixture(
        markdown: String,
        applyMathFix: Bool
    ) throws -> (exitCode: Int32, renderedText: String, stderr: String) {
        guard let pandocPath = URLWrapExportFixtures.findPandocPath() else {
            throw XCTSkip("Pandoc not installed -- skipping real PDF compilation verification")
        }
        guard FileManager.default.isExecutableFile(atPath: URLWrapExportFixtures.bundledXelatexPath) else {
            throw XCTSkip("Bundled TinyTeX xelatex not present -- skipping real PDF compilation verification")
        }
        guard let pdftotextPath = URLWrapExportFixtures.findPdftotextPath() else {
            throw XCTSkip("pdftotext not installed -- skipping PDF text-layout verification")
        }
        if applyMathFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.mathSpecialCharsLuaPath),
                          "math-special-chars.lua should exist at \(Self.mathSpecialCharsLuaPath)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("math-special-chars-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("input.md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)

        // Space-free symlink to the bundled TinyTeX + xdvipdfmx wrapper -- mirrors
        // ExportService.prepareBundledTinyTeX()'s own spaces-in-app-bundle-path workaround, and
        // URLWrapExportTests.swift's identical test-side setup (this repo's checkout path
        // contains a space, "final final").
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
        if applyMathFix {
            arguments.append(contentsOf: ["--lua-filter", Self.mathSpecialCharsLuaPath])
        }
        process.arguments = arguments

        // Redirect stderr to a temp file rather than a Pipe() -- see
        // URLWrapExportTests.compilePDFFixtureAndExtractText's doc comment for why a Pipe() read
        // after waitUntilExit() can deadlock once xelatex's error trace exceeds the OS pipe's
        // fixed buffer (~64KB on macOS), which a crashing compile (the case under test here)
        // makes especially likely.
        let stderrFileURL = tempDir.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stderrFileURL.path, contents: nil)
        let stderrFileHandle = try FileHandle(forWritingTo: stderrFileURL)
        process.standardError = stderrFileHandle
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        try stderrFileHandle.close()
        let stderrData = try Data(contentsOf: stderrFileURL)
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        var renderedText = ""
        if process.terminationStatus == 0 {
            let textProcess = Process()
            textProcess.executableURL = URL(fileURLWithPath: pdftotextPath)
            textProcess.arguments = ["-layout", outputURL.path, "-"]
            let textPipe = Pipe()
            textProcess.standardOutput = textPipe
            try textProcess.run()
            textProcess.waitUntilExit()
            renderedText = String(data: textPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        return (process.terminationStatus, renderedText, stderrText)
    }

    /// Fast fragment helper (no PDF compile) for tests that only need to see how
    /// math-special-chars.lua rewrote the AST, mirroring URLWrapLinkifyFilterTests.swift's
    /// `runPandocToLatex`.
    private func runPandocToLatexFragment(markdown: String, applyMathFix: Bool) throws -> String {
        guard let pandocPath = URLWrapExportFixtures.findPandocPath() else {
            throw XCTSkip("Pandoc not installed -- skipping LaTeX assembly verification")
        }
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        var arguments = [inputURL.path, "--from", "markdown", "--to", "latex"]
        if applyMathFix {
            arguments.append(contentsOf: ["--lua-filter", Self.mathSpecialCharsLuaPath])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        process.arguments = arguments
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

    // MARK: - `&`: crash without the fix, compiles with it

    /// Negative control: reproduces the reported crash signature exactly, with NO filter applied
    /// -- proving the failure is real and pinning its exact shape (exit 43, xelatex's specific
    /// error text) before showing the fix resolves it below.
    func testAmpersandInMath_WithoutFix_CrashesPandocMatchingReportedFailure() throws {
        let markdown = "Test math: $x & y$ should crash.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: false)

        XCTAssertEqual(result.exitCode, 43,
                       "An unescaped & in math must reproduce pandoc's documented exit code. Stderr:\n\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("Misplaced alignment tab character"),
                      "Stderr must contain xelatex's specific error text. Stderr:\n\(result.stderr)")
    }

    func testAmpersandInMath_WithFix_CompilesSuccessfully() throws {
        let markdown = "Test math: $x & y$ should not crash.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: true)

        XCTAssertEqual(result.exitCode, 0,
                       "With the filter applied, the export must succeed. Stderr:\n\(result.stderr)")
        XCTAssertTrue(result.renderedText.contains("&"),
                      "The escaped & must still render as a literal ampersand. Rendered text:\n\(result.renderedText)")
    }

    // MARK: - `#`: crash without the fix, compiles with it

    func testHashInMath_WithoutFix_CrashesPandoc() throws {
        let markdown = "Test math: $x # y$ should crash too.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: false)

        XCTAssertNotEqual(result.exitCode, 0,
                          "An unescaped # in math must also crash pandoc. Stderr:\n\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("macro parameter character"),
                      "Stderr must contain xelatex's specific error text. Stderr:\n\(result.stderr)")
    }

    func testHashInMath_WithFix_CompilesSuccessfully() throws {
        let markdown = "Test math: $x # y$ should not crash.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: true)

        XCTAssertEqual(result.exitCode, 0,
                       "With the filter applied, the export must succeed. Stderr:\n\(result.stderr)")
        XCTAssertTrue(result.renderedText.contains("#"),
                      "The escaped # must still render as a literal hash. Rendered text:\n\(result.renderedText)")
    }

    // MARK: - `%`: does NOT crash pandoc, but silently truncates the rest of the line

    /// `%` is a different failure shape than `&`/`#`: pandoc's own LaTeX writer already inserts a
    /// newline immediately after `%` in its output, so it never runs off into a LaTeX comment
    /// that swallows the rest of the compiled .tex file -- it just silently drops the text
    /// between the `%` and that inserted newline. Confirmed by direct reproduction: exit 0, but
    /// the trailing "7" never reaches the rendered PDF.
    ///
    /// Uses a digit ("7"), not a letter, as the post-% survival marker: xelatex's unicode-math
    /// renders a bare math-mode LETTER as an italic Unicode math-alphanumeric symbol (e.g. "y"
    /// becomes U+1D466 "𝑦", confirmed empirically via pdftotext -- not the plain ASCII "y" a
    /// naive `.contains("y")` check looks for, so that check could never match either before or
    /// after the fix). A digit renders as its own plain ASCII character in this font, so
    /// `.contains("7")` is a direct, unambiguous check with no Unicode-variant pitfalls.
    func testPercentInMath_WithoutFix_SilentlyDropsTextAfterItButDoesNotCrash() throws {
        let markdown = "Test math: $x % 7$ should not crash.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: false)

        XCTAssertEqual(result.exitCode, 0,
                       "An unescaped % in math must NOT crash pandoc (unlike & and #). Stderr:\n\(result.stderr)")
        XCTAssertFalse(result.renderedText.contains("7"),
                       "Known pre-fix bug: text after an unescaped % in math is silently dropped. " +
                       "Rendered text:\n\(result.renderedText)")
    }

    func testPercentInMath_WithFix_PreservesTextThatWasPreviouslySilentlyDropped() throws {
        let markdown = "Test math: $x % 7$ should not crash.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: true)

        XCTAssertEqual(result.exitCode, 0,
                       "With the filter applied, the export must succeed. Stderr:\n\(result.stderr)")
        XCTAssertTrue(result.renderedText.contains("7"),
                      "The escaped % must no longer swallow the rest of the line. " +
                      "Rendered text:\n\(result.renderedText)")
    }

    // MARK: - Legitimate alignment environments keep working, with or without the fix

    /// `$$\begin{aligned}...\end{aligned}$$`-style math legitimately uses unescaped `&` as a real
    /// alignment tab -- this must keep compiling unchanged once the filter is wired in.
    func testAlignedEnvironment_WithFixApplied_KeepsCompilingWithUnescapedAmpersand() throws {
        let markdown = "Test aligned math:\n\n$$\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}$$\n\nDone.\n"

        let result = try compileMathFixture(markdown: markdown, applyMathFix: true)

        XCTAssertEqual(result.exitCode, 0,
                       "A legitimate aligned environment must still compile once the filter is " +
                       "wired in -- its unescaped & must be exempted. Stderr:\n\(result.stderr)")
    }

    /// Fragment-level companion to the compile test above: proves the filter recognizes the
    /// `\begin{` exemption and leaves the aligned environment's LaTeX byte-for-byte identical,
    /// not merely "still compiles" (which a partial, differently-broken rewrite could also do).
    func testAlignedEnvironment_FragmentIsByteIdenticalWithAndWithoutFilter() throws {
        let markdown = "$$\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}$$\n"

        let withFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: true)
        let withoutFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: false)

        XCTAssertEqual(withFilter, withoutFilter,
                       "The \\begin{ exemption must leave an aligned environment's LaTeX " +
                       "completely untouched. With filter:\n\(withFilter)\nWithout filter:\n\(withoutFilter)")
    }

    // MARK: - Pre-existing, already-working ampersand cases stay undisturbed

    /// The filter only touches Math AST nodes, so prose ampersands, bibliography-shaped
    /// ampersands, and URL query-string ampersands (all Str/plain-text nodes, already escaped
    /// correctly by pandoc's own LaTeX writer) must render byte-for-byte identically whether or
    /// not this filter runs.
    func testFilterDoesNotAlterAmpersandsOutsideMathSpans() throws {
        let markdown = "Smith & Jones (2020) cite a source at " +
            "https://example.com/search?a=1&b=2, contra Doe & Roe.\n"

        let withFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: true)
        let withoutFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: false)

        XCTAssertEqual(withFilter, withoutFilter,
                       "Non-math ampersands must be completely unaffected by this filter. " +
                       "With filter:\n\(withFilter)\nWithout filter:\n\(withoutFilter)")
        XCTAssertTrue(withFilter.contains("\\&"),
                      "Prose/URL ampersands must still be escaped by pandoc's own writer, " +
                      "independently of this filter. LaTeX:\n\(withFilter)")
    }

    // MARK: - Already-escaped math characters are not double-escaped

    /// An author-supplied `\&` (single backslash) is already valid LaTeX and must be left alone,
    /// not turned into `\\&` (a spurious extra backslash).
    func testAlreadyEscapedAmpersandInMath_IsNotDoubleEscaped() throws {
        let markdown = "Test math: $x \\& y$ already escaped.\n"

        let withFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: true)

        XCTAssertFalse(withFilter.contains("\\\\&"),
                       "An already-escaped & must not be escaped a second time. LaTeX:\n\(withFilter)")
        XCTAssertTrue(withFilter.contains("\\&"),
                      "The single escape must survive. LaTeX:\n\(withFilter)")
    }

    /// Regression guard for the consecutive-backslash counting fix: `\\` (LaTeX's own line-break
    /// command, TWO backslashes) immediately followed by an unescaped `&` must still get that `&`
    /// escaped -- a naive single-character lookbehind would see the backslash directly before `&`
    /// (the second half of `\\`) and wrongly conclude `&` was already escaped, silently letting a
    /// real crash-causing `&` straight through.
    func testAmpersandAfterLineBreak_IsCorrectlyEscapedDespiteEvenBackslashCount() throws {
        // Two literal backslash characters (LaTeX's \\ line break), then an unescaped &.
        let mathBody = "x" + String(repeating: "\\", count: 2) + "&y"
        let markdown = "Test math: $\(mathBody)$ done.\n"

        let withFilter = try runPandocToLatexFragment(markdown: markdown, applyMathFix: true)

        // The two original backslashes must survive untouched, immediately followed by a freshly
        // inserted escaping backslash and the &  -- i.e. an ODD (3) backslash run right before &.
        guard let ampersandRange = withFilter.range(of: "&") else {
            XCTFail("Expected an & to survive in the LaTeX output. LaTeX:\n\(withFilter)")
            return
        }
        let beforeAmpersand = withFilter[..<ampersandRange.lowerBound]
        let trailingBackslashes = beforeAmpersand.reversed().prefix { $0 == "\\" }.count
        XCTAssertEqual(trailingBackslashes, 3,
                       "The & after a literal \\\\ must be escaped (3 backslashes total: the " +
                       "original 2 plus 1 inserted), not skipped as already-escaped. LaTeX:\n\(withFilter)")
    }
}
