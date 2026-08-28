//
//  ReferenceOdtStyleParityTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  reference.odt shipped stock (pandoc's generic ODF default): a different font, different
//  heading sizes, and no accent color from reference.docx, so a document that looks
//  consistent when exported to PDF/DOCX looked different again when exported to ODT. This
//  hand-tunes reference.odt's styles.xml to match reference.docx's house style, and this file
//  proves it landed and stays landed.
//
//  Three things, deliberately not conflated:
//
//  1. A CANARY on reference.docx's own key style values (page size, margins, body
//     spacing/justification, heading sizes, accent color). If someone re-tunes the docx later
//     without re-syncing the odt, THIS test fails first and says so -- the docx is the
//     source of truth the odt was hand-matched against, so a silent drift here is exactly the
//     failure mode the rest of this file can't detect on its own.
//  2. Direct assertions against the COMMITTED, bundled `final final/Resources/Export/
//     reference.odt` -- the file that actually ships in the app -- not one regenerated
//     on the fly here. This file deliberately does NOT invoke
//     `scripts/reference-odt/build-reference-odt.py`: doing so would validate the checked-in
//     styles.xml source instead of the binary that ships, and would let a stale committed
//     .odt pass green. `build-reference-odt.py` is a build-time step (run it, then run these
//     tests), never something the test itself triggers.
//  3. A real-pandoc round-trip: exporting through the bundled reference.odt as
//     `--reference-doc` and checking the produced document's styles.xml actually carries the
//     tuned values through pandoc's own template machinery, not just that our source XML
//     contains the right strings.
//
//  Both archives are zip files inspected via `/usr/bin/unzip -p <path> <member>` (the same
//  pattern TableRoundtripTests.swift and ImageCaptionExportTests.swift use), with paths
//  resolved relative to the repo root via #filePath -- `Bundle.main` in a unit-test host is
//  the XCTest runner's own bundle, not the app's.
//
//  Style-block assertions use plain substring search scoped between a unique
//  `w:styleId="..."`/`style:name="..."` marker and the next `</w:style>`/`</style:style>`
//  close tag, rather than a full XML parser -- both archives' XML members are single-line/
//  minified, so this is robust as long as each marker string is unique in the file (verified
//  by construction: every style name referenced below is declared exactly once).

import XCTest
import Foundation
@testable import final_final

final class ReferenceOdtStyleParityTests: XCTestCase {

    // MARK: - Paths

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tier2/
            .deletingLastPathComponent()  // final finalTests/
            .deletingLastPathComponent()  // repo root
    }

    private static var referenceDocxURL: URL {
        repoRoot().appendingPathComponent("final final/Resources/Export/reference.docx")
    }

    private static var referenceOdtURL: URL {
        repoRoot().appendingPathComponent("final final/Resources/Export/reference.odt")
    }

    private static var sourceStylesXMLURL: URL {
        repoRoot().appendingPathComponent("scripts/reference-odt/styles.xml")
    }

    // MARK: - Shell helpers

    /// Runs `unzip -p archive entry` and returns the raw output bytes.
    ///
    /// Reads the pipe to end BEFORE calling `waitUntilExit()`: payloads through this helper
    /// run ~57-58KB, close to Darwin's ~64KB pipe buffer ceiling. If the child fills the pipe
    /// before `waitUntilExit()` is called, the child blocks writing (pipe full) while we block
    /// waiting for it to exit -- a classic Process/Pipe deadlock, not a red test but an
    /// indefinite hang. Draining first (which itself blocks until the child closes/finishes
    /// writing, then EOFs) and waiting after is the standard safe ordering.
    private func runUnzipData(archive: URL, entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "unzip -p \(archive.lastPathComponent) \(entry) should succeed")

        return data
    }

    /// Runs `unzip -p archive entry` and returns the output as a String.
    private func runUnzip(archive: URL, entry: String) throws -> String {
        let data = try runUnzipData(archive: archive, entry: entry)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs `unzip -v archive` (verbose listing: Length/Method/Size/Cmpr/Date/Time/CRC-32/Name,
    /// one entry per line, in archive order) and returns just the per-entry data lines.
    private func runUnzipVerboseListing(archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-v", archive.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "unzip -v \(archive.lastPathComponent) should succeed")

        let output = String(data: data, encoding: .utf8) ?? ""
        // Entry lines are the ones with a "%" compression-ratio column; this skips the
        // "Archive:" line, the two header lines, and the trailing "-------- ------- ---"
        // totals line.
        return output.split(separator: "\n").map(String.init).filter { $0.contains("%") }
    }

    private static func findPandocPath() -> String? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns the substring of `xml` from the first occurrence of `marker` through the next
    /// occurrence of `endTag` (inclusive) -- scopes an assertion to one style element without
    /// a full XML parser. `marker` must be unique in `xml`.
    private func extractBlock(_ xml: String, marker: String, endTag: String) -> String? {
        guard let markerRange = xml.range(of: marker) else { return nil }
        guard let endRange = xml.range(of: endTag, range: markerRange.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[markerRange.lowerBound..<endRange.upperBound])
    }

    // MARK: - 1. Canary: reference.docx's own key style values

    /// Pins reference.docx's page geometry, body spacing/justification, heading sizes, and
    /// accent color. If this test fails, someone changed the docx template without
    /// re-syncing reference.odt's hand-tuned styles.xml -- fix the docx/odt mismatch (or
    /// re-run scripts/reference-odt/build-reference-odt.py after updating the mapping) before
    /// touching the odt assertions below.
    func testDocxCanary_KeyStyleValuesUnchanged() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.referenceDocxURL.path),
                      "reference.docx should exist at \(Self.referenceDocxURL.path)")

        let documentXML = try runUnzip(archive: Self.referenceDocxURL, entry: "word/document.xml")
        XCTAssertTrue(documentXML.contains(#"w:w="12240" w:h="15840""#),
                      "reference.docx page size should be 8.5x11in (12240x15840 twips)")
        XCTAssertTrue(
            documentXML.contains(#"w:top="1440" w:right="1440" w:bottom="1440" w:left="1440""#),
            "reference.docx margins should be 1in (1440 twips) on all sides")

        let stylesXML = try runUnzip(archive: Self.referenceDocxURL, entry: "word/styles.xml")

        guard let bodyText = extractBlock(stylesXML, marker: #"w:styleId="BodyText""#, endTag: "</w:style>") else {
            return XCTFail("BodyText style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(bodyText.contains(#"w:before="180" w:after="180" w:line="360" w:lineRule="auto""#),
                      "BodyText spacing should be 180/180 twips before/after, 360 auto (150% line height)")
        XCTAssertTrue(bodyText.contains(#"w:jc w:val="both""#), "BodyText should be justified")

        guard let heading1 = extractBlock(stylesXML, marker: #"w:styleId="Heading1""#, endTag: "</w:style>") else {
            return XCTFail("Heading1 style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(heading1.contains(#"w:sz w:val="32""#), "Heading1 should be 32 half-points (16pt)")

        guard let heading2 = extractBlock(stylesXML, marker: #"w:styleId="Heading2""#, endTag: "</w:style>") else {
            return XCTFail("Heading2 style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(heading2.contains(#"w:sz w:val="28""#), "Heading2 should be 28 half-points (14pt)")

        guard let heading3 = extractBlock(stylesXML, marker: #"w:styleId="Heading3""#, endTag: "</w:style>") else {
            return XCTFail("Heading3 style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(heading3.contains(#"w:color w:val="4F81BD""#), "Heading3 accent color should be #4F81BD")

        guard let title = extractBlock(stylesXML, marker: #"w:styleId="Title""#, endTag: "</w:style>") else {
            return XCTFail("Title style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(title.contains(#"w:sz w:val="36""#), "Title should be 36 half-points (18pt)")

        guard let subtitle = extractBlock(stylesXML, marker: #"w:styleId="Subtitle""#, endTag: "</w:style>") else {
            return XCTFail("Subtitle style not found in reference.docx styles.xml")
        }
        XCTAssertTrue(subtitle.contains(#"w:sz w:val="30""#), "Subtitle should be 30 half-points (15pt)")
    }

    // MARK: - 2. reference.odt (the committed, bundled file) matches the docx house style

    func testOdt_PageGeometryMatchesDocx() throws {
        let stylesXML = try committedOdtStylesXML()
        XCTAssertTrue(stylesXML.contains(#"fo:page-width="8.5in""#), "ODT page width should be 8.5in")
        XCTAssertTrue(stylesXML.contains(#"fo:page-height="11in""#), "ODT page height should be 11in")
        XCTAssertTrue(stylesXML.contains(#"fo:margin-top="1in""#), "ODT top margin should be 1in")
        XCTAssertTrue(stylesXML.contains(#"fo:margin-bottom="1in""#), "ODT bottom margin should be 1in")
        XCTAssertTrue(stylesXML.contains(#"fo:margin-left="1in""#), "ODT left margin should be 1in")
        XCTAssertTrue(stylesXML.contains(#"fo:margin-right="1in""#), "ODT right margin should be 1in")
    }

    func testOdt_BodyTextMatchesDocx() throws {
        let stylesXML = try committedOdtStylesXML()
        guard let bodyText = extractBlock(stylesXML, marker: #"style:name="Text_20_body""#,
                                           endTag: "</style:style>") else {
            return XCTFail("Text_20_body style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(bodyText.contains(#"style:font-name="Times New Roman""#),
                      "Text body should use Times New Roman")
        XCTAssertTrue(bodyText.contains(#"fo:font-size="12pt""#), "Text body should be 12pt")
        XCTAssertTrue(bodyText.contains(#"fo:margin-top="0.125in""#), "Text body top margin should be 0.125in")
        XCTAssertTrue(bodyText.contains(#"fo:line-height="150%""#), "Text body line height should be 150%")
        XCTAssertTrue(bodyText.contains(#"fo:text-align="justify""#), "Text body should be justified")
    }

    func testOdt_HeadingsMatchDocx() throws {
        let stylesXML = try committedOdtStylesXML()

        guard let headingBase = extractBlock(stylesXML, marker: #"style:name="Heading""#,
                                              endTag: "</style:style>") else {
            return XCTFail("Heading base style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(headingBase.contains(#"style:font-name="Times New Roman""#),
                      "Heading base should use Times New Roman, not the stock Arial")
        XCTAssertFalse(headingBase.contains(#"font-name="Arial""#),
                       "Heading base should no longer use Arial")

        guard let h1 = extractBlock(stylesXML, marker: #"style:name="Heading_20_1""#,
                                     endTag: "</style:style>") else {
            return XCTFail("Heading_20_1 style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(h1.contains(#"fo:font-size="16pt""#), "Heading 1 should be 16pt")

        guard let h2 = extractBlock(stylesXML, marker: #"style:name="Heading_20_2""#,
                                     endTag: "</style:style>") else {
            return XCTFail("Heading_20_2 style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(h2.contains(#"fo:font-size="14pt""#), "Heading 2 should be 14pt")
        XCTAssertFalse(h2.contains(#"fo:font-style="italic""#), "Heading 2 should no longer be italic")

        for level in 3...6 {
            guard let heading = extractBlock(stylesXML, marker: #"style:name="Heading_20_\#(level)""#,
                                              endTag: "</style:style>") else {
                XCTFail("Heading_20_\(level) style not found in reference.odt styles.xml")
                continue
            }
            XCTAssertTrue(heading.contains(#"style:font-name="Calibri""#),
                          "Heading \(level) should use Calibri")
            XCTAssertTrue(heading.contains(##"fo:color="#4F81BD""##),
                          "Heading \(level) accent color should be #4F81BD")
        }

        // reference.docx's Heading3 is bold (confirmed: bold: True); H4 is italic-not-bold,
        // H5/H6 are neither. The loop above only checks font/color across 3-6, so pin H3's
        // bold weight here specifically to stop it from silently regressing again.
        guard let h3 = extractBlock(stylesXML, marker: #"style:name="Heading_20_3""#,
                                     endTag: "</style:style>") else {
            return XCTFail("Heading_20_3 style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(h3.contains(#"fo:font-weight="bold""#),
                      "Heading 3 should be bold, matching reference.docx's Heading3")

        guard let title = extractBlock(stylesXML, marker: #"style:name="Title""#,
                                        endTag: "</style:style>") else {
            return XCTFail("Title style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(title.contains(#"fo:font-size="18pt""#), "Title should be 18pt")
        XCTAssertTrue(title.contains(#"fo:font-weight="bold""#), "Title should be bold")

        guard let subtitle = extractBlock(stylesXML, marker: #"style:name="Subtitle""#,
                                           endTag: "</style:style>") else {
            return XCTFail("Subtitle style not found in reference.odt styles.xml")
        }
        XCTAssertTrue(subtitle.contains(#"fo:font-size="15pt""#), "Subtitle should be 15pt")
        XCTAssertTrue(subtitle.contains(#"fo:font-weight="bold""#), "Subtitle should be bold")
        XCTAssertFalse(subtitle.contains(#"fo:font-style="italic""#), "Subtitle should no longer be italic")
    }

    func testOdt_DeclaresCalibriCambriaConsolasFontFaces() throws {
        let stylesXML = try committedOdtStylesXML()
        guard let fontFaceDecls = extractBlock(stylesXML, marker: "<office:font-face-decls>",
                                                endTag: "</office:font-face-decls>") else {
            return XCTFail("office:font-face-decls not found in reference.odt styles.xml")
        }
        XCTAssertTrue(fontFaceDecls.contains(#"style:name="Calibri""#), "Calibri font-face should be declared")
        XCTAssertTrue(fontFaceDecls.contains(#"style:name="Cambria""#), "Cambria font-face should be declared")
        XCTAssertTrue(fontFaceDecls.contains(#"style:name="Consolas""#), "Consolas font-face should be declared")
    }

    /// Guards against `scripts/reference-odt/styles.xml` (the source someone actually hand-
    /// edits) drifting from what is inside the committed, bundled reference.odt -- e.g.
    /// someone edits the source, forgets to re-run `build-reference-odt.py`, and commits.
    /// Every other test in this file only reads the committed binary, so they would all stay
    /// green even after that drift; this is the one test that would catch it.
    ///
    /// Also pins the ODF "mimetype must be the first archive entry, stored uncompressed"
    /// invariant that `build-reference-odt.py` depends on to produce a valid package --
    /// folded into this test because it's a cheap check against the same committed archive.
    func testOdt_StylesXmlMatchesSourceAndMimetypeIsFirstAndStored() throws {
        let sourceData = try Data(contentsOf: Self.sourceStylesXMLURL)
        let committedData = try runUnzipData(archive: Self.referenceOdtURL, entry: "styles.xml")
        XCTAssertEqual(committedData, sourceData,
                       "Committed reference.odt's styles.xml has drifted from " +
                       "scripts/reference-odt/styles.xml -- re-run " +
                       "`python3 scripts/reference-odt/build-reference-odt.py` and commit the result")

        let entries = try runUnzipVerboseListing(archive: Self.referenceOdtURL)
        guard let firstEntry = entries.first else {
            return XCTFail("Could not parse `unzip -v` listing for reference.odt")
        }
        XCTAssertTrue(firstEntry.hasSuffix("mimetype"),
                      "ODF requires the mimetype entry to be first in the archive; got: \(firstEntry)")
        XCTAssertTrue(firstEntry.contains("Stored"),
                      "ODF requires the mimetype entry to be stored uncompressed; got: \(firstEntry)")
    }

    private func committedOdtStylesXML() throws -> String {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.referenceOdtURL.path),
                      "reference.odt should exist at \(Self.referenceOdtURL.path)")
        return try runUnzip(archive: Self.referenceOdtURL, entry: "styles.xml")
    }

    // MARK: - 3. Real-pandoc round-trip through the bundled reference.odt

    /// Exports real markdown through pandoc using the bundled, committed reference.odt as
    /// `--reference-doc`, then inspects the PRODUCED document's styles.xml -- proving pandoc's
    /// own style round-trip (not just our source XML) actually carries the tuned values
    /// through, exactly as ExportService does for a real user ODT export.
    func testRoundTrip_PandocExportCarriesTunedStylesThrough() throws {
        guard let pandocPath = Self.findPandocPath() else {
            throw XCTSkip("Pandoc not installed — skipping reference.odt round-trip verification")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.referenceOdtURL.path),
                      "reference.odt should exist at \(Self.referenceOdtURL.path)")

        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + ".md")
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".odt")
        let markdown = "# A Heading\n\nSome body text that should come out justified.\n\n### A Level-3 Heading\n"
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pandocPath)
        process.arguments = [
            inputURL.path,
            "--from", "markdown",
            "--to", "odt",
            "--reference-doc", Self.referenceOdtURL.path,
            "-o", outputURL.path
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0,
                       "pandoc --to odt should succeed; stderr: \(String(data: stderrData, encoding: .utf8) ?? "")")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "pandoc should produce an .odt")

        let producedStylesXML = try runUnzip(archive: outputURL, entry: "styles.xml")

        guard let bodyText = extractBlock(producedStylesXML, marker: #"style:name="Text_20_body""#,
                                           endTag: "</style:style>") else {
            return XCTFail("Text_20_body style not found in pandoc's produced styles.xml")
        }
        XCTAssertTrue(bodyText.contains(#"fo:line-height="150%""#),
                      "Produced document's body text should carry the 150% line height through")
        XCTAssertTrue(bodyText.contains(#"fo:text-align="justify""#),
                      "Produced document's body text should carry justification through")

        guard let heading3 = extractBlock(producedStylesXML, marker: #"style:name="Heading_20_3""#,
                                           endTag: "</style:style>") else {
            return XCTFail("Heading_20_3 style not found in pandoc's produced styles.xml")
        }
        XCTAssertTrue(heading3.contains(##"fo:color="#4F81BD""##),
                      "Produced document's Heading 3 should carry the #4F81BD accent color through")
    }
}
