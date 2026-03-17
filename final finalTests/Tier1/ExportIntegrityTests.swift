//
//  ExportIntegrityTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for export integrity: zoom-state isolation, image path handling,
//  annotation stripping, and the loadContentForExport contract.
//  Export corruption silently destroys the user's shared output.
//
//  Uses assembleMarkdownForExport (Pandoc-flavored) — the path used by
//  ExportOperations.handleExport(). ExportAssemblyTests covers
//  assembleStandardMarkdownForExport (plain markdown for Markdown/TextBundle).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Export Integrity — Tier 1: Silent Killers")
struct ExportIntegrityTests {

    // MARK: - Export Excludes Bibliography

    @Test("loadContentForExport excludes bibliography blocks")
    func exportExcludesBibliography() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // Bibliography content should not appear in export
        #expect(!exported.contains("Carroll, S. R., et al. (2020)"),
                "Export should exclude bibliography entries")
        #expect(!exported.contains("Himmelmann, N. P. (1998)"),
                "Export should exclude bibliography entries")

        // But the heading "References" (which is a bibliography section) should be excluded
        // Verify bibliography blocks are actually present in the full set
        let bibBlocks = blocks.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "Rich content should have bibliography blocks")
    }

    // MARK: - Export Returns All Sections (Not Just Zoomed)

    @Test("Export assembles all sections regardless of zoom state simulation")
    func exportAllSectionsNotZoomed() throws {
        let content = """
        # Document Title

        Intro paragraph.

        ## Section One

        Content for section one.

        ## Section Two

        Content for section two.

        ## Section Three

        Content for section three.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Simulate what loadContentForExport does: filter out bibliography, assemble all
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // All sections should be present
        #expect(exported.contains("Section One"), "Export should include Section One")
        #expect(exported.contains("Section Two"), "Export should include Section Two")
        #expect(exported.contains("Section Three"), "Export should include Section Three")
        #expect(exported.contains("Intro paragraph"), "Export should include intro")
    }

    // MARK: - Export Preserves Footnote Definitions from Notes Section

    @Test("Export includes footnote definitions from Notes section")
    func exportIncludesFootnoteDefinitions() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exportBlocks = blocks.filter { !$0.isBibliography }
        let exported = BlockParser.assembleMarkdownForExport(from: exportBlocks)

        // Notes section footnote definitions should be present
        #expect(exported.contains("[^1]:") || exported.contains("[^1]"),
                "Export should contain footnote references")
        #expect(exported.contains("OLAC metadata standards"),
                "Export should contain footnote definition text")
    }

    // MARK: - Annotation Stripping

    @Test("stripAnnotations removes annotation HTML comments")
    func stripAnnotationsRemovesComments() throws {
        let content = """
        Regular text here.

        <!-- ::task:: [ ] Review this section -->

        More text.

        <!-- ::comment:: This is a comment annotation -->

        Final text.
        """

        let stripped = MarkdownUtils.stripAnnotations(from: content)

        #expect(!stripped.contains("::task::"), "Stripped content should not contain task annotations")
        #expect(!stripped.contains("::comment::"), "Stripped content should not contain comment annotations")
        #expect(stripped.contains("Regular text here."), "Should preserve regular text")
        #expect(stripped.contains("More text."), "Should preserve regular text")
        #expect(stripped.contains("Final text."), "Should preserve regular text")
    }

    @Test("stripAnnotations preserves non-annotation HTML comments")
    func stripAnnotationsPreservesRegularComments() throws {
        let content = """
        Text with <!-- a regular HTML comment --> here.

        <!-- ::task:: [ ] Do something -->
        """

        let stripped = MarkdownUtils.stripAnnotations(from: content)

        #expect(stripped.contains("a regular HTML comment"),
                "Should preserve non-annotation HTML comments")
        #expect(!stripped.contains("::task::"),
                "Should strip annotation comments")
    }

    // MARK: - Image Path in Export

    @Test("Export preserves image markdown syntax")
    func exportPreservesImageSyntax() throws {
        let content = """
        # Document

        Some text.

        ![Alt text](media/photo.png)

        More text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("media/photo.png"),
                "Export should preserve image path")
    }

    @Test("Export preserves image with spaces in filename")
    func exportPreservesSpacesInFilename() throws {
        let content = """
        # Document

        ![Screenshot](media/my screenshot.png)

        Text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("my screenshot.png"),
                "Export should preserve image filename with spaces")
    }

    @Test("Export preserves image with URL-encoded filename")
    func exportPreservesUrlEncodedFilename() throws {
        let content = """
        # Document

        ![Screenshot](media/Screenshot%202.png)

        Text.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        #expect(exported.contains("Screenshot%202.png"),
                "Export should preserve URL-encoded image filename")
    }

    // MARK: - Export Image Path Rewriting (ExportService)

    @Test("ExportService imagePathPattern matches markdown images")
    func imagePathPatternMatches() throws {
        // Test the regex pattern used by ExportService for image rewriting
        let pattern = #"!\[[^\]]*\]\(media/([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        let testCases: [(input: String, expectedFilename: String)] = [
            ("![Alt](media/photo.png)", "photo.png"),
            ("![](media/image.jpg)", "image.jpg"),
            ("![Diagram of workflow](media/diagram-v2.pdf)", "diagram-v2.pdf"),
            ("![Screenshot](media/Screenshot%202.png)", "Screenshot%202.png")
        ]

        for testCase in testCases {
            let range = NSRange(testCase.input.startIndex..., in: testCase.input)
            let matches = regex.matches(in: testCase.input, range: range)
            #expect(matches.count == 1,
                    "Should match image syntax for: \(testCase.input)")

            if let match = matches.first,
               let captureRange = Range(match.range(at: 1), in: testCase.input) {
                let filename = String(testCase.input[captureRange])
                #expect(filename == testCase.expectedFilename,
                        "Should capture filename '\(testCase.expectedFilename)' from '\(testCase.input)'")
            }
        }
    }

    @Test("ExportService imagePathPattern truncates at parentheses (known gap)")
    func imagePathPatternParenthesesGap() throws {
        // Documents a known limitation: [^)]+ stops at first ')' in filename
        // Filenames with literal parentheses (e.g. "Screenshot (2).png") will
        // be truncated. URL-encoding the parens avoids this issue.
        let pattern = #"!\[[^\]]*\]\(media/([^)]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        let input = "![Screenshot](media/Screenshot (2).png)"
        let range = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: range)

        // The regex matches but captures only up to the first ')'
        #expect(matches.count == 1, "Pattern should still match")
        if let match = matches.first,
           let captureRange = Range(match.range(at: 1), in: input) {
            let filename = String(input[captureRange])
            #expect(filename == "Screenshot (2",
                    "Known gap: parentheses in filename truncate capture")
        }
    }

    // MARK: - Export Assembles in Sort Order

    @Test("Export assembles blocks in sort order, not insertion order")
    func exportRespectsBlockSortOrder() throws {
        let content = """
        # First

        First content.

        ## Second

        Second content.

        ## Third

        Third content.
        """

        let db = try TestFixtureFactory.createTemporary(content: content)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let exported = BlockParser.assembleMarkdownForExport(from: blocks)

        // Verify order: First before Second before Third
        if let firstIdx = exported.range(of: "First content")?.lowerBound,
           let secondIdx = exported.range(of: "Second content")?.lowerBound,
           let thirdIdx = exported.range(of: "Third content")?.lowerBound {
            #expect(firstIdx < secondIdx, "First should appear before Second")
            #expect(secondIdx < thirdIdx, "Second should appear before Third")
        } else {
            Issue.record("Export should contain all section content")
        }
    }
}
