//
//  BibliographySyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for bibliography sync: citekey extraction and bibliography block detection.
//  Bibliography drift silently corrupts the references section.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Sync — Tier 1: Silent Killers")
struct BibliographySyncTests {

    // MARK: - Helpers

    private func createTestDatabase(content: String) throws -> ProjectDatabase {
        let url = URL(fileURLWithPath: "/tmp/claude/bib-sync-test-\(UUID().uuidString).ff")
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

    // MARK: - extractCitekeys

    @Test("extractCitekeys finds single key")
    func extractCitekeysSingleKey() {
        let keys = BibliographySyncService.extractCitekeys(from: "Text [@himmelmann1998] more.")
        #expect(keys == ["himmelmann1998"])
    }

    @Test("extractCitekeys finds multiple keys in combined citation")
    func extractCitekeysMultipleKeys() {
        let keys = BibliographySyncService.extractCitekeys(from: "[@key1; @key2, p. 123]")
        #expect(keys == ["key1", "key2"])
    }

    @Test("extractCitekeys preserves duplicates across paragraphs")
    func extractCitekeysPreservesDuplicates() {
        let markdown = """
        First paragraph [@key1].

        Second paragraph [@key1].
        """
        let keys = BibliographySyncService.extractCitekeys(from: markdown)
        #expect(keys.filter { $0 == "key1" }.count == 2,
                "Same key in separate paragraphs should appear twice")
    }

    @Test("extractCitekeys ignores code blocks")
    func extractCitekeysIgnoresCodeBlocks() {
        let markdown = """
        Real citation [@real].

        ```
        Not a citation [@fake].
        ```

        Another real one [@also_real].
        """
        let keys = BibliographySyncService.extractCitekeys(from: markdown)
        #expect(keys.contains("real"))
        #expect(keys.contains("also_real"))
        #expect(!keys.contains("fake"), "@key inside fenced code block should not be extracted")
    }

    // MARK: - Bibliography blocks in DB

    @Test("Rich content has bibliography blocks marked correctly")
    func bibliographyBlocksMarkedCorrectly() throws {
        let db = try createTestDatabase(content: TestFixtureFactory.richTestContent)
        let blocks = try fetchBlocks(db)
        let bibBlocks = blocks.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "richTestContent should have blocks with isBibliography == true")
    }

    @Test("extractCitekeys from rich content finds 4 keys")
    func extractCitekeysFromRichContent() {
        let keys = BibliographySyncService.extractCitekeys(from: TestFixtureFactory.richTestContent)
        let unique = Array(Set(keys)).sorted()
        #expect(unique == ["carroll2020", "himmelmann1998", "smith2023", "wilkinson2016"],
                "Should find exactly 4 unique citekeys from richTestContent")
    }
}
