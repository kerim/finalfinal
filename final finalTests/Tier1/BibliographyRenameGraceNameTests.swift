//
//  BibliographyRenameGraceNameTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for the grace list -- the load-bearing piece of the
//  bibliography-heading-name preference. The moment the configured name changes, a document
//  whose heading text still reads the OLD name becomes unrecognizable to
//  BlockParser.isBibliographyHeading unless the old name is still in the recognized set (the
//  grace list). Without it, a full re-parse strips isBibliography off the heading and every
//  entry beneath it, and the next regeneration appends a duplicate bibliography beside the
//  now-orphaned one -- exactly the data-loss bug two prior real implementation attempts at
//  this feature each shipped.
//
//  Isolation: same seam as `BlockParserBibliographyHeaderNameTests.swift` -- see that file's
//  doc comment for the full rationale, including the CROSS-SUITE RACE section (`.serialized`
//  only orders this suite against its own tests, not against other suites running
//  concurrently). That race, once only documented as latent, was actually reproduced by a
//  full-suite run against `staleReparseAfterRenameKeepsBibliographyFlags` below -- both of
//  this file's swap sites (`withIsolatedStore` and `graceListCapsAt50`'s own inline setup)
//  now acquire `exportSettingsTestLock` (see `ExportSettingsTestLock.swift`) around the
//  entire swap-to-restore window, shared with the two other suites that swap the same
//  process-wide `ExportSettings.userDefaults` static.
//
//  Both tests below that reach `ExportSettingsManager.shared` -- a process-wide singleton
//  that caches `settings` in memory after its first access and does NOT re-read
//  `ExportSettings.userDefaults` on its own -- snapshot whatever it held BEFORE they touch
//  it and restore EXACTLY that in teardown, never a fixed neutral constant:
//  `withIsolatedStore` (used by `staleReparseAfterRenameKeepsBibliographyFlags`) and
//  `graceListCapsAt50`'s own inline setup. This closes a real intra-file isolation gap this
//  file used to have: only `graceListCapsAt50` touched the manager, and its teardown reset
//  it to a fixed `.default` rather than to whatever it held before -- which "bounded"
//  contamination to a known constant instead of actually reversing it, so a stale
//  `.default` could still leak into whichever sibling test ran next in the SAME process.
//  `withIsolatedStore` now performs the identical snapshot/force-sync/restore around
//  `staleReparseAfterRenameKeepsBibliographyFlags`'s own body, so that test is never
//  affected by whatever `ExportSettingsManager.shared` happens to hold when it starts
//  (today: nothing on its call path reads the manager instead of calling
//  `ExportSettings.load()` directly -- but the singleton is now genuinely restored either
//  way, closing the gap for any future call path that does).
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite(.serialized)
struct BibliographyRenameGraceNameTests {

    /// Points `ExportSettings.userDefaults` at a fresh, per-call isolated suite, saves
    /// `headerName`/`graceNames` into it, force-syncs `ExportSettingsManager.shared`'s
    /// in-memory cache to match, runs `body`, then restores BOTH the manager's cache and
    /// the previous store to exactly what they held before this call, and deletes the
    /// throwaway suite's persistent domain. Never touches the real `UserDefaults.standard`
    /// domain. Mirrors `BlockParserBibliographyHeaderNameTests.withIsolatedStore` for the
    /// `ExportSettings.userDefaults` swap, plus `graceListCapsAt50`'s own
    /// snapshot/force-sync/restore pattern for `ExportSettingsManager.shared` -- see this
    /// file's doc comment for why that manager sync belongs here too: without it, this
    /// call is only isolated against `ExportSettings.load()` call sites, not against the
    /// manager's own in-memory cache, which a sibling test (`graceListCapsAt50`) DOES
    /// mutate. `@MainActor` because `ExportSettingsManager.shared` is a `@MainActor`
    /// singleton; the caller (`staleReparseAfterRenameKeepsBibliographyFlags`) is
    /// `@MainActor` too so this can be called directly, without a `MainActor.run` hop.
    @MainActor
    private static func withIsolatedStore(
        headerName: String,
        graceNames: [String] = [],
        _ body: () throws -> Void
    ) rethrows {
        let suiteName = "com.kerim.final-final.tests.bibRenameGrace.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite for test")
            return
        }
        // Cross-suite lock (see ExportSettingsTestLock.swift): must be acquired before the
        // very first write to the shared `ExportSettings.userDefaults` pointer below, and
        // held until it -- and the manager cache swapped alongside it -- are fully restored,
        // or another suite's concurrently-running test could observe this throwaway store.
        exportSettingsTestLock.lock()
        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = suite
        let manager = ExportSettingsManager.shared
        // Snapshot whatever the singleton held BEFORE this call touches it -- not
        // assumed to be `.default` -- so teardown below can restore EXACTLY that,
        // regardless of what an earlier-run sibling test (`graceListCapsAt50`) left it
        // holding.
        let previousManagerSettings = manager.settings
        defer {
            // Reverse order of the setup below: restore the manager's cache FIRST, while
            // `ExportSettings.userDefaults` still points at `suite` (so this write lands
            // in the throwaway store, never the real one) -- `defer` blocks run in
            // reverse order, so this runs before the store-pointer restore just below it
            // in source order.
            manager.update { $0 = previousManagerSettings }
            ExportSettings.userDefaults = previousStore
            suite.removePersistentDomain(forName: suiteName)
            // Release LAST, after both restores above have fully landed -- releasing any
            // earlier would let another suite's concurrently-waiting test swap the pointer
            // out from under one of those restore writes.
            exportSettingsTestLock.unlock()
        }

        var settings = ExportSettings.default
        settings.bibliographyHeaderName = headerName
        settings.previousBibliographyHeaderNames = graceNames
        settings.save()
        // Force-sync the singleton's in-memory cache to the isolated settings just
        // saved above -- `ExportSettingsManager.shared` caches `settings` once at first
        // access and does not re-read `ExportSettings.userDefaults` on its own.
        manager.update { $0 = settings }

        try body()
    }

    @Test("A previous custom heading name is still recognized after a custom-to-custom rename")
    func graceNameStillRecognized() {
        #expect(BlockParser.isBibliographyHeading(
            "# Works Cited", bibliographyHeaderName: "Sources", graceNames: ["Works Cited"]))
        // Control: without the grace list, the old custom name is NOT recognized. Neither
        // "Works Cited" nor "Sources" is a built-in literal, so this is a real check --
        // renaming from/to "Bibliography" or "References" would pass even with the whole
        // feature deleted, since those are always recognized regardless of the grace list.
        #expect(BlockParser.isBibliographyHeading(
            "# Works Cited", bibliographyHeaderName: "Sources", graceNames: []) == false)
    }

    @Test("Stale re-parse after a custom-to-custom rename keeps bibliography flags")
    @MainActor
    func staleReparseAfterRenameKeepsBibliographyFlags() throws {
        try Self.withIsolatedStore(headerName: "Sources", graceNames: ["Works Cited"]) {
            // Heading text STILL reads the OLD name ("Works Cited"), simulating a document
            // that hasn't been regenerated since the setting was renamed to "Sources" -- the
            // exact scenario the grace list exists to keep recognized.
            //
            // Unlike other fixture-backed tests, this one does NOT go through
            // `TestFixtureFactory.createFixture`: that convenience wrapper calls
            // `BlockParser.parse(markdown:projectId:)` with no bibliography-name arguments,
            // which falls through to `ExportSettings.load()` -- a read of the very
            // process-wide `ExportSettings.userDefaults` static this file's doc comment
            // documents as a cross-suite race (see `ExportSettingsTestLock.swift`).
            // `withIsolatedStore` above closes that race for THIS suite's own tests, but a
            // full-suite run still reproduced a failure here, meaning something beyond this
            // suite's own swap sites can still be mid-flight on that global while this parse
            // runs. So this test passes `bibliographyHeaderName`/`graceNames` explicitly to
            // `BlockParser.parse` -- which, per that function's own doc comment, skips the
            // `ExportSettings.load()` call entirely when both are supplied together -- making
            // the actual parse under test immune to the shared global altogether, not merely
            // well-behaved around it. `withIsolatedStore` is kept anyway as defense in depth;
            // it no longer matters to this parse call but costs nothing to leave in place.
            // Everything else below (package creation, project/content insert, `replaceBlocks`)
            // mirrors `TestFixtureFactory.createFixture` exactly -- only the `BlockParser.parse`
            // call itself differs, exercising the same `replaceBlocks` path production goes
            // through (not a hand-rolled block insert).
            let markdown = """
            # Test Document

            Introductory text citing a source [@doe2020].

            # Works Cited

            Doe, J. (2020). *An Example Work*.

            Smith, A. (2019). *Another Example Work*.

            <!-- ::auto-bibliography-end:: -->
            """
            let url = URL(fileURLWithPath: "/tmp/claude/test-\(UUID().uuidString).ff")
            let package = try ProjectPackage.create(at: url, title: "Test Project")
            let db = try ProjectDatabase.create(package: package, title: "Test Project", initialContent: markdown)
            let projectId = try TestFixtureFactory.getProjectId(from: db)
            let parsedBlocks = BlockParser.parse(
                markdown: markdown,
                projectId: projectId,
                bibliographyHeaderName: "Sources",
                graceNames: ["Works Cited"]
            )
            try db.replaceBlocks(parsedBlocks, for: projectId)
            let blocks = try TestFixtureFactory.fetchBlocks(from: db)

            let heading = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Works Cited" })
            #expect(heading.isBibliography, "Heading must still be recognized via the grace list")

            let entries = blocks.filter { $0.textContent.contains("Doe, J.") || $0.textContent.contains("Smith, A.") }
            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0.isBibliography }, "Every entry beneath the stale heading must stay flagged")
        }
    }

    @Test("Grace list caps at 50 entries, oldest dropped first, no duplicates")
    @MainActor
    func graceListCapsAt50() throws {
        // Inlined (not via `withIsolatedStore`'s closure-taking helper): this test drives
        // `ExportSettingsManager.shared`, a @MainActor singleton, directly -- keeping the
        // swap/seed/restore inline avoids any ambiguity about which actor context a
        // passed-in closure runs on.
        let suiteName = "com.kerim.final-final.tests.bibRenameGraceCap.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        // Cross-suite lock (see ExportSettingsTestLock.swift): see the identical acquire in
        // `withIsolatedStore` above for the full rationale. This function has two `defer`
        // blocks below (LIFO: the second-declared one, restoring the manager cache, runs
        // FIRST; this one runs LAST) -- the release belongs in THIS defer, since it's the
        // one that runs last and therefore only after both restores have landed.
        exportSettingsTestLock.lock()
        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = suite
        defer {
            ExportSettings.userDefaults = previousStore
            suite.removePersistentDomain(forName: suiteName)
            exportSettingsTestLock.unlock()
        }

        var seed = ExportSettings.default
        seed.bibliographyHeaderName = "Name0"
        seed.save()

        let manager = ExportSettingsManager.shared
        // Snapshot whatever the singleton held BEFORE this test touches it -- not assumed
        // to be `.default` -- so teardown below can restore EXACTLY that, not a fixed
        // neutral constant. See this file's doc comment: a fixed `.default` restore only
        // "bounds" contamination to a known-but-still-wrong value; the sibling test that
        // runs next still doesn't see what was really there.
        let previousManagerSettings = manager.settings
        // Force-sync the singleton's in-memory cache to the isolated store just swapped in
        // above -- `ExportSettingsManager.shared` caches `settings` once at first access and
        // does not re-read on its own; see this file's doc comment.
        manager.update { $0 = ExportSettings.load() }
        defer {
            // Restore the process-wide singleton's in-memory cache to EXACTLY what it held
            // before this test touched it, BEFORE the isolated store is torn down (so this
            // restore itself still writes to the isolated store, not the real one --
            // `defer` blocks run in reverse order, so this runs before the store-swap
            // `defer` above restores `previousStore`).
            manager.update { $0 = previousManagerSettings }
        }

        for i in 1...51 {
            manager.setBibliographyHeaderName("Name\(i)")
        }

        let grace = manager.previousBibliographyHeaderNames
        #expect(grace.count == 50)
        #expect(Set(grace).count == grace.count, "No duplicates")
        #expect(!grace.contains("References"))
        #expect(!grace.contains("Bibliography"))
        #expect(!grace.contains(manager.bibliographyHeaderName), "Current name must not appear in its own grace list")
        // Oldest dropped first: the very first outgoing name ("Name0", recorded by the
        // rename TO "Name1") must be gone after capping 51 recorded outgoing names down to
        // 50; every later outgoing name ("Name1" through "Name50") must survive.
        #expect(!grace.contains("Name0"))
        #expect(grace.contains("Name1"))
        #expect(grace.contains("Name50"))
        #expect(manager.bibliographyHeaderName == "Name51")
    }
}
