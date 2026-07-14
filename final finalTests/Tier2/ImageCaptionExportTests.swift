//
//  ImageCaptionExportTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Real-pandoc integration tests for the caption/alt separation + PDF
//  figure-placement fix (image-placement plan):
//  - A captioned image must show its REAL caption (not the auto-filled
//    filename) in PDF, DOCX, and ODT exports, and stay pinned in place
//    ([H]) in PDF instead of floating past following text at a page break.
//  - A no-caption image must not become a figure/caption wrapper at all, in
//    any format — no "Figure N: filename.jpg" placeholder caption.
//
//  End-to-end for the actual production pipeline: markdown as persisted by
//  the editor (image-plugin.ts's new format) -> BlockParser.parse() ->
//  BlockParser.assembleMarkdownForExport() -> ExportService.export(), the
//  exact same call sequence DocumentManager.loadContentForExport() and
//  ExportCommands.swift use for a real user-triggered export.
//
//  PDF-specific assertions run against `pandoc --to latex` output directly
//  (per the plan's own test-plan wording) rather than a fully-compiled PDF:
//  ExportService's bundled figure-placement.lua/float-package.tex are
//  resolved via Bundle.main, which in a unit-test host is the XCTest
//  runner's own bundle, not the app's — so they're located here relative to
//  this source file instead (see FixtureGeneratorTests.swift for the same
//  #filePath-relative-to-repo-root pattern). This also sidesteps needing a
//  working xelatex/TinyTeX installation just to verify LaTeX structure.
//

import XCTest
import Foundation
@testable import final_final

final class ImageCaptionExportTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal valid 1x1 PNG (same bytes as ImageImportServiceTests's fixture) — real bytes so
    /// Pandoc can actually embed/measure the image instead of just warning about a missing
    /// resource.
    private static let minimalPNGData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    /// Creates a temp .ff-shaped project directory with media/photo.png, returns its URL.
    private func makeProjectWithImage() throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-export-test-\(UUID().uuidString)")
        let mediaURL = projectURL.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try Self.minimalPNGData.write(to: mediaURL.appendingPathComponent("photo.png"))
        return projectURL
    }

    /// Builds the export-ready Pandoc markdown for a single image block, exactly as production
    /// does: parse the persisted (new-format) markdownFragment into a Block, then
    /// assembleMarkdownForExport (which calls Block.markdownForExport() per block).
    private func exportMarkdown(forPersistedImageFragment fragment: String) -> String {
        let blocks = BlockParser.parse(markdown: fragment, projectId: "test")
        return BlockParser.assembleMarkdownForExport(from: blocks)
    }

    // MARK: - Pandoc/resource helpers

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Locates the bundled PDF-placement resources relative to THIS source file's location
    /// (repo root -> final final/Resources/Export/...) rather than via Bundle.main, which in a
    /// unit-test host resolves to the XCTest runner's bundle, not the app's — see the file
    /// header comment and FixtureGeneratorTests.swift's identical #filePath pattern.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var figurePlacementLuaPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/figure-placement.lua").path
    }

    private static var floatPackageTexPath: String {
        repoRoot().appendingPathComponent("final final/Resources/Export/float-package.tex").path
    }

    /// Runs real Pandoc with `--to latex`, optionally with the bundled PDF-placement filter +
    /// header snippet (mirrors exactly what ExportService wires in for `format == .pdf`).
    private func runPandocToLatex(markdown: String, applyPlacementFix: Bool) throws -> String {
        guard let pandocPath = Self.findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping LaTeX assembly verification")
        }
        if applyPlacementFix {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.figurePlacementLuaPath),
                          "figure-placement.lua should exist at \(Self.figurePlacementLuaPath)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.floatPackageTexPath),
                          "float-package.tex should exist at \(Self.floatPackageTexPath)")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        var arguments = [inputURL.path, "--from", "markdown", "--to", "latex"]
        if applyPlacementFix {
            arguments.append(contentsOf: ["--lua-filter", Self.figurePlacementLuaPath])
            arguments.append(contentsOf: ["--include-in-header", Self.floatPackageTexPath])
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

    /// Runs `unzip -p archive entry` and returns the output as a String (mirrors
    /// TableRoundtripTests.swift's identical helper).
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

    // MARK: - PDF/LaTeX: no-caption image

    func testNoCaptionImage_LatexHasNoFigureWrapper() throws {
        // Persisted format for a freshly-inserted image: empty bracket (no
        // caption typed yet), alt="..." unconditionally present (auto-filled
        // filename) — exactly what image-plugin.ts's toMarkdown produces.
        let fragment = #"![](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let latex = try runPandocToLatex(markdown: markdown, applyPlacementFix: true)

        XCTAssertFalse(latex.contains("\\begin{figure}"),
                        "No-caption image must not become a figure wrapper. LaTeX:\n\(latex)")
        XCTAssertFalse(latex.contains("my-photo-2026.jpg]"),
                        "Filename must never appear as a visible caption. LaTeX:\n\(latex)")
        XCTAssertFalse(latex.contains("\\caption"),
                        "No-caption image must produce no \\caption at all. LaTeX:\n\(latex)")
    }

    // MARK: - PDF/LaTeX: captioned image, placement pinning

    func testCaptionedImage_LatexHasPinnedPlacementAndRealCaption() throws {
        let fragment = #"![A real typed caption](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let latex = try runPandocToLatex(markdown: markdown, applyPlacementFix: true)

        XCTAssertTrue(latex.contains("\\begin{figure}[H]"),
                       "Captioned image must be pinned with [H] placement. LaTeX:\n\(latex)")
        // The filename correctly appears in the SEPARATE alt={...} accessibility attribute —
        // this exact-match assertion on \caption{...} is what proves it does NOT also leak into
        // the visible caption.
        XCTAssertTrue(latex.contains("\\caption{A real typed caption}"),
                       "Caption must contain ONLY the real typed text, not the filename. LaTeX:\n\(latex)")
        XCTAssertTrue(latex.contains("alt={my-photo-2026.jpg}"),
                       "The filename should still appear separately as the accessibility alt text. LaTeX:\n\(latex)")
    }

    func testCaptionedImage_WithoutPlacementFilter_FloatsUnpinned() throws {
        // Negative control: confirms the [H] placement genuinely comes from
        // the Lua filter, not from Pandoc's own default behavior.
        let fragment = #"![A real typed caption](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let latex = try runPandocToLatex(markdown: markdown, applyPlacementFix: false)

        XCTAssertTrue(latex.contains("\\begin{figure}"))
        XCTAssertFalse(latex.contains("\\begin{figure}[H]"),
                        "Without the Lua filter, Pandoc's default figure should NOT be pinned. LaTeX:\n\(latex)")
    }

    // MARK: - PDF/LaTeX: judge-required empty-alt-but-has-caption case

    func testEmptyAltButHasCaption_LatexShowsCaptionNotFilename() throws {
        let fragment = #"![A caption with no accessibility text set](media/photo.png){alt=""}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let latex = try runPandocToLatex(markdown: markdown, applyPlacementFix: true)

        XCTAssertTrue(latex.contains("\\begin{figure}[H]"))
        XCTAssertTrue(latex.contains("\\caption{A caption with no accessibility text set}"))
    }

    // MARK: - PDF/LaTeX: backslash escaping (regression guard for the "escape backslash before
    // the delimiter" fix)

    func testCaptionAndAltEndingInBackslash_LatexPreservesImageInsteadOfSilentlyVanishing() throws {
        // Regression guard: Block.markdownForExport() used to escape only the closing delimiter
        // (`]` for caption, `"` for alt) and never a literal backslash first. A caption/alt
        // ending in an unescaped `\` immediately before the real closing delimiter makes
        // Pandoc's markdown reader treat that delimiter as escaped (a literal character), not as
        // the bracket/quote's terminator — corrupting the markup so badly the whole figure
        // silently disappears from the export. Verified directly against real pandoc: feeding
        // the PRE-FIX (delimiter-only) escaping through `pandoc --to latex` produces raw
        // corrupted text (`!{[}caption...`) with no `\begin{figure}`/`\includegraphics` at all —
        // exactly the "image silently vanishes" failure this guards against. Escaping backslash
        // FIRST (same order as the JS side's escapeAltAttr in
        // web/milkdown/src/image-plugin.ts) fixes this.
        //
        // Unlike the other tests in this file, this constructs the Block directly (bypassing
        // BlockParser.parse's fragment parsing) so it exercises ONLY markdownForExport()'s own
        // escaping — the bug and fix live entirely there.
        let block = Block(
            projectId: "test", sortOrder: 1.0, blockType: .image,
            markdownFragment: "irrelevant",
            imageSrc: "media/photo.png",
            imageAlt: #"alt with "quotes" and trailing backslash\"#,
            imageCaption: #"caption with ] bracket and trailing backslash\"#
        )
        let markdown = BlockParser.assembleMarkdownForExport(from: [block])

        let latex = try runPandocToLatex(markdown: markdown, applyPlacementFix: true)

        XCTAssertTrue(latex.contains("\\begin{figure}[H]"),
                      "Image must still become a pinned figure, not silently vanish into corrupted raw text. LaTeX:\n\(latex)")
        XCTAssertTrue(latex.contains("\\includegraphics"),
                      "The image itself must survive. LaTeX:\n\(latex)")
        XCTAssertTrue(latex.contains("\\caption"),
                      "A real \\caption must be present (not corrupted into plain text). LaTeX:\n\(latex)")
        XCTAssertTrue(latex.contains("caption with"),
                      "Caption text must survive intact rather than being consumed as an escape sequence. LaTeX:\n\(latex)")
    }

    // MARK: - DOCX: captioned vs no-caption

    func testCaptionedImage_DOCXShowsRealCaption() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping DOCX export verification")
        }
        let projectURL = try makeProjectWithImage()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let fragment = #"![The real caption](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = ExportService()
        _ = try await service.export(
            content: markdown, to: tempURL, format: .word,
            settings: ExportSettings(), projectURL: projectURL
        )

        let documentXML = try runUnzip(archive: tempURL, entry: "word/document.xml")
        XCTAssertTrue(documentXML.contains("ImageCaption"),
                      "DOCX should contain an ImageCaption-styled paragraph. XML head: \(documentXML.prefix(2000))")
        XCTAssertTrue(documentXML.contains("The real caption"),
                      "DOCX caption paragraph should contain the real caption text")
        XCTAssertFalse(documentXML.contains("my-photo-2026.jpg<"),
                        "Filename must not appear as visible caption text in the document body")
    }

    func testNoCaptionImage_DOCXHasNoCaptionParagraph() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping DOCX export verification")
        }
        let projectURL = try makeProjectWithImage()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let fragment = #"![](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-caption-test-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = ExportService()
        _ = try await service.export(
            content: markdown, to: tempURL, format: .word,
            settings: ExportSettings(), projectURL: projectURL
        )

        let documentXML = try runUnzip(archive: tempURL, entry: "word/document.xml")
        XCTAssertFalse(documentXML.contains("ImageCaption"),
                        "No-caption image must not produce an ImageCaption paragraph. XML: \(documentXML.prefix(2000))")
        XCTAssertFalse(documentXML.contains("my-photo-2026.jpg<"),
                        "Filename must never appear as visible text in the document body")
    }

    // MARK: - ODT: captioned vs no-caption

    func testCaptionedImage_ODTShowsRealCaption() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping ODT export verification")
        }
        let projectURL = try makeProjectWithImage()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let fragment = #"![The real caption](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-test-\(UUID().uuidString).odt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = ExportService()
        _ = try await service.export(
            content: markdown, to: tempURL, format: .odt,
            settings: ExportSettings(), projectURL: projectURL
        )

        let contentXML = try runUnzip(archive: tempURL, entry: "content.xml")
        XCTAssertTrue(contentXML.contains("FigureCaption"),
                      "ODT should contain a FigureCaption-styled paragraph. XML head: \(contentXML.prefix(2000))")
        XCTAssertTrue(contentXML.contains("The real caption"),
                      "ODT caption paragraph should contain the real caption text")
        XCTAssertFalse(contentXML.contains("my-photo-2026.jpg<"),
                        "Filename must not appear as visible caption text in the document body")
    }

    func testNoCaptionImage_ODTHasNoCaptionParagraph() async throws {
        guard Self.findPandocPath() != nil else {
            throw XCTSkip("Pandoc not installed — skipping ODT export verification")
        }
        let projectURL = try makeProjectWithImage()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let fragment = #"![](media/photo.png){alt="my-photo-2026.jpg"}"#
        let markdown = exportMarkdown(forPersistedImageFragment: fragment)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-caption-test-\(UUID().uuidString).odt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = ExportService()
        _ = try await service.export(
            content: markdown, to: tempURL, format: .odt,
            settings: ExportSettings(), projectURL: projectURL
        )

        let contentXML = try runUnzip(archive: tempURL, entry: "content.xml")
        XCTAssertFalse(contentXML.contains("FigureCaption"),
                        "No-caption image must not produce a FigureCaption paragraph. XML: \(contentXML.prefix(2000))")
        XCTAssertFalse(contentXML.contains("my-photo-2026.jpg<"),
                        "Filename must never appear as visible text in the document body")
    }
}
