//
//  BibliographyPlacementExportTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Tests for `BlockParser.assembleMarkdownForExport(from:bibliographyPlaceholder:)`'s
//  `bibliographyPlacementMarker` insertion — the fix for text typed after a document's
//  bibliography section rendering BEFORE the bibliography in PDF exports, instead of after
//  it where the user typed it.
//
//  ROOT CAUSE: `DocumentManager.exportBlocks()` strips ALL `isBibliography`-flagged blocks
//  before assembling markdown for PDF export, so pandoc has no idea where the bibliography
//  section was — it just sees ordinary body content (correctly including the user's trailing
//  text). Pandoc's `--citeproc` then generates its own bibliography and, per pandoc's own
//  standard behavior, APPENDS it at the very end of the document — unless the source markdown
//  contains an explicit `<div id="refs">...</div>` (or `::: {#refs}\n:::` fenced-div shorthand)
//  placement marker, in which case pandoc places its generated bibliography exactly there
//  instead.
//
//  FIX: `assembleMarkdownForExport(from:bibliographyPlaceholder:)` replaces the bibliography
//  section -- which is otherwise dropped entirely, since each export format regenerates its
//  own bibliography -- with the document's OWN bibliography heading (if the section has one)
//  followed by `BlockParser.bibliographyPlacementMarker`, at the position the section occupies.
//  Callers that run pandoc's citeproc (PDF export, formatted print) pass `true`; DOCX/ODT
//  export (which use Zotero field codes / a Lua filter, not citeproc) keep passing `false` --
//  byte-identical to the pre-fix assembly.
//
//  PDF-specific assertions run against `pandoc --to latex` output directly (matching
//  ImageCaptionExportTests.swift's pattern) rather than a fully-compiled PDF: a real-PDF-compile
//  test isn't practical here (citation resolution needs live Zotero) -- the LaTeX writer's
//  output is authoritative for ordering; the real PDF is covered by user-verification instead.
//

import XCTest
import Foundation
@testable import final_final

final class BibliographyPlacementExportTests: XCTestCase {

    // MARK: - Fixtures

    /// heading + para (citing `minimalCSLJSON`'s "smith2020" entry, so the real-pandoc
    /// citeproc tests below actually exercise citation resolution, not just marker
    /// survival) + `# Bibliography` (heading, isBibliography) + 2 bib entries
    /// (isBibliography) + trailing para -- the shape of the actual bug report: text typed
    /// after the bibliography section.
    private func buildHappyPathBlocks() -> [Block] {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some intro text. [@smith2020]", markdownFragment: "Some intro text. [@smith2020]"
        )
        let bibHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            isBibliography: true
        )
        let entry1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "Entry one.", markdownFragment: "Entry one.",
            isBibliography: true
        )
        let entry2 = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "Entry two.", markdownFragment: "Entry two.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: "test", sortOrder: 6.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )
        return [heading, para, bibHeading, entry1, entry2, trailing]
    }

    // MARK: - 1. Happy path

    func testHappyPath_HeadingThenMarkerThenTrailingText_NoEntryText() throws {
        let output = BlockParser.assembleMarkdownForExport(
            from: buildHappyPathBlocks(), bibliographyPlaceholder: true
        )

        let headingRange = try XCTUnwrap(output.range(of: "# Bibliography"))
        let markerRange = try XCTUnwrap(output.range(of: BlockParser.bibliographyPlacementMarker))
        let trailingRange = try XCTUnwrap(output.range(of: "Trailing sentinel text."))

        XCTAssertTrue(headingRange.upperBound <= markerRange.lowerBound,
                      "Heading must come before the placement marker. Output:\n\(output)")
        XCTAssertTrue(markerRange.upperBound <= trailingRange.lowerBound,
                      "Placement marker must come before the trailing paragraph. Output:\n\(output)")

        XCTAssertFalse(output.contains("Entry one."), "Bibliography entry text must never survive into export")
        XCTAssertFalse(output.contains("Entry two."), "Bibliography entry text must never survive into export")
    }

    // MARK: - 2. Selector regression case (the actual bug this plan fixes)

    func testLeadingBibliographyMarkerBlockAheadOfHeading_SameOutputAsHappyPath() {
        // A standalone `.bibliography`-typed marker block (isBibliography = true, distinct from
        // an ordinary heading/paragraph block that happens to be flagged isBibliography) sorted
        // AHEAD of the real `# Bibliography` heading block -- the shape a naive "first
        // isBibliography block" selector would misidentify as the section's heading.
        var blocks = buildHappyPathBlocks()
        let markerBlock = Block(
            projectId: "test", sortOrder: 2.5, blockType: .bibliography,
            textContent: "<!-- ::auto-bibliography:: -->", markdownFragment: "<!-- ::auto-bibliography:: -->",
            isBibliography: true
        )
        blocks.insert(markerBlock, at: 2)

        let output = BlockParser.assembleMarkdownForExport(from: blocks, bibliographyPlaceholder: true)
        let happyPathOutput = BlockParser.assembleMarkdownForExport(
            from: buildHappyPathBlocks(), bibliographyPlaceholder: true
        )

        XCTAssertEqual(
            output, happyPathOutput,
            "A leading .bibliography marker block must not change the output -- the whole-run scan " +
            "must still correctly select the real heading, not fall back to the marker-only branch"
        )
    }

    // MARK: - 3. Marker-only fallback

    func testNoHeadingInBibliographySection_MarkerOnlyEmitted() {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let entry1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Entry one.", markdownFragment: "Entry one.",
            isBibliography: true
        )
        let entry2 = Block(
            projectId: "test", sortOrder: 3.0, blockType: .paragraph,
            textContent: "Entry two.", markdownFragment: "Entry two.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        let output = BlockParser.assembleMarkdownForExport(
            from: [heading, entry1, entry2, trailing], bibliographyPlaceholder: true
        )

        XCTAssertTrue(output.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertFalse(output.contains("Bibliography"), "No heading text must appear when the section has no heading")
        XCTAssertFalse(output.contains("Entry one."))
        XCTAssertFalse(output.contains("Entry two."))
        XCTAssertTrue(output.contains("Trailing sentinel text."))
    }

    // MARK: - 4. Flag false (DOCX/ODT path) -- byte-identical to today's behavior

    func testFlagFalse_ByteIdenticalToTodaysFilteredAssembly() {
        let blocks = buildHappyPathBlocks()

        let output = BlockParser.assembleMarkdownForExport(from: blocks, bibliographyPlaceholder: false)

        // Today's DOCX/ODT path: DocumentManager.exportBlocks() filters bibliography blocks out
        // BEFORE assembly, then assembleMarkdownForExport had no bibliographyPlaceholder concept
        // at all. `bibliographyPlaceholder: false` (the default) must reproduce that exactly.
        let preFixEquivalent = BlockParser.assembleMarkdownForExport(from: blocks.filter { !$0.isBibliography })

        XCTAssertEqual(output, preFixEquivalent)
        XCTAssertFalse(output.contains("#refs"))
        XCTAssertFalse(output.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertFalse(output.contains("Bibliography"))
        XCTAssertFalse(output.contains("Entry one."))
        XCTAssertFalse(output.contains("Entry two."))
    }

    // MARK: - 5. No bibliography blocks, flag true

    func testNoBibliographyBlocks_FlagTrue_NoMarkerEmitted() {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some intro text.", markdownFragment: "Some intro text."
        )

        let output = BlockParser.assembleMarkdownForExport(from: [heading, para], bibliographyPlaceholder: true)

        XCTAssertFalse(output.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertFalse(output.contains("#refs"))
    }

    // MARK: - 9. Leading blank bibliography-flagged block does not suppress the real heading

    func testLeadingBlankBibliographyBlock_DoesNotSuppressRealHeadingOrMarker() throws {
        // A blank/whitespace-only isBibliography-flagged block sorted AHEAD of ordinary body
        // content -- the exact shape the empty-fragment guard in assembleMarkdownForExport
        // exists to close. If the empty-fragment check ran AFTER the isBibliography branch
        // instead of before it, this block would set emittedPlaceholder = true at its own early
        // sort position (0.5), and the REAL `# Bibliography` heading/marker reached later in
        // iteration would be silently dropped -- since `guard bibliographyPlaceholder,
        // !emittedPlaceholder else { continue }` would see a placeholder as "already emitted."
        let leadingBlankBibBlock = Block(
            projectId: "test", sortOrder: 0.5, blockType: .paragraph,
            textContent: "", markdownFragment: "   ",
            isBibliography: true
        )
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some intro text.", markdownFragment: "Some intro text."
        )
        let bibHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            isBibliography: true
        )
        let entry1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "Entry one.", markdownFragment: "Entry one.",
            isBibliography: true
        )
        let trailing = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "Trailing sentinel text.", markdownFragment: "Trailing sentinel text."
        )

        let output = BlockParser.assembleMarkdownForExport(
            from: [leadingBlankBibBlock, heading, para, bibHeading, entry1, trailing],
            bibliographyPlaceholder: true
        )

        let introRange = try XCTUnwrap(output.range(of: "Some intro text."))
        let headingRange = try XCTUnwrap(
            output.range(of: "# Bibliography"),
            "The real bibliography heading must not be dropped just because a blank " +
            "bibliography-flagged block sorted ahead of it. Output:\n\(output)"
        )
        let markerRange = try XCTUnwrap(
            output.range(of: BlockParser.bibliographyPlacementMarker),
            "The placement marker must still be emitted for the real bibliography section. Output:\n\(output)"
        )
        let trailingRange = try XCTUnwrap(output.range(of: "Trailing sentinel text."))

        XCTAssertTrue(introRange.upperBound <= headingRange.lowerBound,
                      "The leading blank bibliography-flagged block must not itself trigger early " +
                      "marker emission -- the heading must sort after ordinary body content, not before " +
                      "it. Output:\n\(output)")
        XCTAssertTrue(headingRange.upperBound <= markerRange.lowerBound,
                      "Heading must come before the placement marker. Output:\n\(output)")
        XCTAssertTrue(markerRange.upperBound <= trailingRange.lowerBound,
                      "Placement marker must come before the trailing paragraph. Output:\n\(output)")

        XCTAssertFalse(output.contains("Entry one."), "Bibliography entry text must never survive into export")
    }

    // MARK: - Pandoc helpers (mirrors ImageCaptionExportTests.swift's pattern)

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Minimal valid CSL-JSON bibliography. Its "smith2020" entry is cited (`[@smith2020]`)
    /// by `buildHappyPathBlocks()`'s `para` block, so the real-pandoc citeproc tests below
    /// actually exercise citation resolution -- `--citeproc --bibliography` also just plain
    /// requires a real, parseable file to point at, cited or not.
    private static let minimalCSLJSON = """
    [
      {
        "id": "smith2020",
        "type": "article-journal",
        "title": "A Sample Article",
        "author": [{"family": "Smith", "given": "Jane"}],
        "issued": {"date-parts": [[2020]]}
      }
    ]
    """

    /// Runs real Pandoc `--to latex` over `markdown`, optionally with `--citeproc` wired to a
    /// throwaway bibliography file (mirrors exactly what ExportService wires in for PDF export
    /// when Zotero-backed citations are present).
    private func runPandocToLatex(markdown: String, citeproc: Bool) throws -> String {
        guard let pandocPath = Self.findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping LaTeX assembly verification")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        var arguments = [inputURL.path, "--from", "markdown", "--to", "latex"]
        var bibURL: URL?
        if citeproc {
            let url = tempDir.appendingPathComponent(UUID().uuidString + ".json")
            try Self.minimalCSLJSON.write(to: url, atomically: true, encoding: .utf8)
            bibURL = url
            arguments.append(contentsOf: ["--citeproc", "--bibliography", url.path])
        }
        defer { if let bibURL { try? FileManager.default.removeItem(at: bibURL) } }

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

    // MARK: - 6. Real pandoc, with citeproc

    func testRealPandoc_WithCiteproc_RefsLabelBetweenHeadingAndTrailingText() throws {
        let markdown = BlockParser.assembleMarkdownForExport(
            from: buildHappyPathBlocks(), bibliographyPlaceholder: true
        )

        let latex = try runPandocToLatex(markdown: markdown, citeproc: true)

        let headingRange = try XCTUnwrap(latex.range(of: "Bibliography"))
        // "CSLReferences" is the LaTeX environment citeproc wraps its GENERATED bibliography
        // entries in -- it only appears when citeproc actually resolved the `[@smith2020]`
        // citation in the fixture's para block and rendered the corresponding reference.
        // Checking for it (rather than just `\label{refs}`, which survives from the fenced-div
        // marker syntax alone, citeproc or not) is what makes this test actually distinguish
        // "citeproc correctly placed the generated bibliography at the marker" from "the marker
        // just survived untouched."
        let referencesRange = try XCTUnwrap(latex.range(of: "CSLReferences"),
                                       "citeproc must actually generate bibliography content at the #refs marker, " +
                                       "not just leave \\label{refs} behind untouched. LaTeX:\n\(latex)")
        let trailingRange = try XCTUnwrap(latex.range(of: "Trailing sentinel text."))

        XCTAssertTrue(headingRange.upperBound <= referencesRange.lowerBound,
                      "Citeproc-generated bibliography content must appear AFTER the Bibliography heading. LaTeX:\n\(latex)")
        XCTAssertTrue(referencesRange.upperBound <= trailingRange.lowerBound,
                      "Citeproc-generated bibliography content must appear BEFORE the trailing sentinel text -- " +
                      "this is the fix: trailing text must render after the bibliography, not before it. LaTeX:\n\(latex)")
    }

    // MARK: - 7. Real pandoc, WITHOUT citeproc (every export with Zotero closed)

    func testRealPandoc_WithoutCiteproc_NoLiteralFencedDivSyntaxLeaksIntoOutput() throws {
        let markdown = BlockParser.assembleMarkdownForExport(
            from: buildHappyPathBlocks(), bibliographyPlaceholder: true
        )

        let latex = try runPandocToLatex(markdown: markdown, citeproc: false)

        XCTAssertFalse(latex.contains(":::"),
                       "Turning off citation processing must never leak the placeholder's raw fenced-div " +
                       "syntax into the LaTeX output. LaTeX:\n\(latex)")
    }

    // MARK: - 8. Naming-collision guard

    func testPlacementMarkerIsNeverRecognizedAsABibliographyOpeningHeading() {
        XCTAssertFalse(BlockParser.isBibliographyHeading(BlockParser.bibliographyPlacementMarker))
    }
}
