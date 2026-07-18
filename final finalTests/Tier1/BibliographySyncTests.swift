//
//  BibliographySyncTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for bibliography sync: citekey extraction and bibliography block detection.
//  Bibliography drift silently corrupts the references section.
//
//  flushPendingSyncForcesScheduledBibliographyUpdate touches ZoteroService.shared (a
//  @MainActor singleton — performBibliographyUpdate hardcodes it, not injectable), so this
//  suite is .serialized (mirrors ProjectLifecycleTests.swift's convention for the same
//  class of singleton risk) and that test saves/restores isConnected + clears the cache
//  around itself to avoid cross-test bleed.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Sync — Tier 1: Silent Killers", .serialized)
struct BibliographySyncTests {

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
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
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

    // MARK: - flushPendingSync (force pending debounce to run immediately, e.g. on quit)

    @Test("flushPendingSync with nothing pending returns without needing a database configured")
    @MainActor
    func flushPendingSyncNoOpWhenNothingPending() async {
        let service = BibliographySyncService()
        // Fresh service — checkAndUpdateBibliography was never called, so nothing is
        // pending, and `database` is nil. Must not crash or attempt any DB access.
        await service.flushPendingSync()
        #expect(service.state == .idle, "No-op flush must leave state untouched")
    }

    @Test("flushPendingSync forces a scheduled bibliography update to run immediately, bypassing the 1s debounce")
    @MainActor
    func flushPendingSyncForcesScheduledBibliographyUpdate() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@flushtestkey2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemJSON = """
        {"id":"flushtestkey2026","type":"book","title":"Flush Test Title","author":[{"family":"Doe","given":"Jane"}],"issued":{"date-parts":[[2020]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))

        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)

        // Schedules the 1s debounce — this call sets pendingCitekeys synchronously, before
        // the sleep even starts.
        service.checkAndUpdateBibliography(currentCitekeys: ["flushtestkey2026"], projectId: projectId)

        // Force it through immediately instead of waiting for the real 1s debounce.
        await service.flushPendingSync()

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocks = blocks.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "Bibliography block should exist immediately after flush, not only after the 1s debounce")
        #expect(bibBlocks.contains { $0.markdownFragment.contains("Doe") }, "Bibliography entry should contain the test item's author")
    }
}
