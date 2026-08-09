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

    // MARK: - Generation guard (stale debounced rebuild race)

    @Test("A stale scheduled generation is rejected while the current generation still writes")
    @MainActor
    func staleGenerationRejectedCurrentGenerationWrites() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "Citing [@racekeyA2026] here.")
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let itemAJSON = """
        {"id":"racekeyA2026","type":"book","title":"Race Key A","author":[{"family":"Alpha","given":"Ann"}],"issued":{"date-parts":[[2020]]}}
        """
        let itemBJSON = """
        {"id":"racekeyB2026","type":"book","title":"Race Key B","author":[{"family":"Beta","given":"Bob"}],"issued":{"date-parts":[[2021]]}}
        """
        let itemA = try JSONDecoder().decode(CSLItem.self, from: Data(itemAJSON.utf8))
        let itemB = try JSONDecoder().decode(CSLItem.self, from: Data(itemBJSON.utf8))

        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(itemA)
        ZoteroService.shared.loadItem(itemB)
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }

        let service = BibliographySyncService()
        service.configure(database: db, projectId: projectId)

        // Two racing calls in quick succession, as happens from ViewNotificationModifiers.swift
        // and ContentView.swift. Each bumps syncGeneration and schedules its own debounce
        // Task, but neither Task is allowed to run to completion here — we drive
        // performBibliographyUpdate directly with each call's captured generation to
        // deterministically simulate "the older debounce Task fires anyway, despite being
        // cooperatively cancelled".
        service.checkAndUpdateBibliography(currentCitekeys: ["racekeyA2026"], projectId: projectId)
        // Generation is now 1, with citekeys A pending.

        service.checkAndUpdateBibliography(currentCitekeys: ["racekeyB2026"], projectId: projectId)
        // Generation is now 2, with citekeys B pending (A's debounce Task was cancelled, but
        // cancellation is cooperative — it may still be running its body when this executes).

        let beforeStale = try TestFixtureFactory.fetchBlocks(from: db)
        let beforeStaleCount = beforeStale.count

        // The stale (generation 1) debounce fires late, carrying the superseded citekeys A
        // snapshot. It must be rejected before writing anything.
        await service.performBibliographyUpdate(
            citekeys: ["racekeyA2026"], projectId: projectId, scheduledGeneration: 1
        )

        let afterStale = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(
            afterStale.count == beforeStaleCount,
            "Stale generation 1 must be rejected — no database write from the superseded citekeys A snapshot"
        )
        #expect(
            !afterStale.contains { $0.isBibliography && $0.markdownFragment.contains("Alpha") },
            "Citekey A's stale bibliography entry must never be written"
        )

        // The current (generation 2) debounce fires, carrying citekeys B — this one must run
        // and write correctly.
        await service.performBibliographyUpdate(
            citekeys: ["racekeyB2026"], projectId: projectId, scheduledGeneration: 2
        )

        let afterCurrent = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocks = afterCurrent.filter { $0.isBibliography }
        #expect(!bibBlocks.isEmpty, "Current generation 2 must write the bibliography")
        #expect(
            bibBlocks.contains { $0.markdownFragment.contains("Beta") },
            "Bibliography should reflect citekey B (the current generation), not the stale citekey A"
        )
        #expect(
            !bibBlocks.contains { $0.markdownFragment.contains("Alpha") },
            "Bibliography must not contain citekey A's entry — the stale generation was correctly rejected"
        )
    }

    // MARK: - Self-heal sweep (removed — see updateBibliographyBlock's doc comment)
    //
    // A prior version added a bounded sweep here that deleted unflagged orphan rows by
    // exact-text match. Removed: the position bound was unsound in both directions at
    // once (see the comment in BibliographySyncService.updateBibliographyBlock). Orphan
    // cleanup now happens at full-reparse time via BlockParser.parse()'s
    // sectionFlagCarriedForward, which re-derives isBibliography from scratch with no
    // position-bound tension. The three sweep-specific tests that lived in this section
    // were removed along with the feature they exercised.

}
