//
//  ExportAssemblyTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for export assembly: bibliography placement, annotation preservation,
//  footnote preservation, and rich content roundtrip.
//  Export corruption silently destroys the user's shared output.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Export Assembly — Tier 1: Silent Killers")
struct ExportAssemblyTests {

    // MARK: - Helpers

    private func createTestDatabase(content: String) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/export-test-\(UUID().uuidString).ff")
        return try TestFixtureFactory.createFixture(at: url, content: content)
    }

    private func fetchBlocks(_ db: ProjectDatabase) throws -> [Block] {
        try db.dbWriter.read { database in
            try Block
                .filter(Block.Columns.projectId != "")
                .order(Block.Columns.sortOrder)
                .fetchAll(database)
        }
    }

    // MARK: - Export Tests

    @Test("Export places bibliography at end")
    func exportBibliographyPlacedAtEnd() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Find last heading — References should be the final H1
        guard let refsRange = exported.range(of: "# References") else {
            Issue.record("Export should contain # References heading")
            return
        }

        // Check no other H1 heading appears after References
        let afterRefs = String(exported[refsRange.upperBound...])
        let otherH1 = afterRefs.range(of: "\n# ", options: [])
        #expect(otherH1 == nil, "No H1 heading should appear after # References")
    }

    @Test("Export preserves annotation comments")
    func exportAnnotationsPresent() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        #expect(exported.contains("<!-- ::task::"), "Export should contain task annotations")
        #expect(exported.contains("<!-- ::comment::"), "Export should contain comment annotations")
    }

    @Test("Export preserves footnote refs and Notes section")
    func exportFootnotesPreserved() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        #expect(exported.contains("[^1]"), "Export should contain footnote references")
        #expect(exported.contains("[^2]"), "Export should contain footnote references")
        #expect(exported.contains("# Notes"), "Export should contain Notes section")
    }

    @Test("Export rich content roundtrip preserves key elements")
    func exportRichContentRoundtrip() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Headings
        #expect(exported.contains("# Research Paper Draft"), "Should preserve H1")
        #expect(exported.contains("## Background and Literature Review"), "Should preserve H2")
        #expect(exported.contains("### Archival Standards"), "Should preserve H3")

        // Citations
        #expect(exported.contains("@himmelmann1998"), "Should preserve citations")

        // Images
        #expect(exported.contains("media/methodology-workflow.png"), "Should preserve image references")

        // Highlights
        #expect(exported.contains("=="), "Should preserve highlight markers")
    }

    @Test("Export with captions formats correctly")
    func exportWithCaptionsFormatsCorrectly() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let exported = BlockParser.assembleStandardMarkdownForExport(from: blocks)

        // Image should be present
        #expect(exported.contains("![Methodology workflow diagram]") ||
                exported.contains("media/methodology-workflow.png"),
                "Export should contain image")

        // Caption annotation should be present
        #expect(exported.contains("Caption: Figure 1"),
                "Export should contain caption annotation")
    }
}
