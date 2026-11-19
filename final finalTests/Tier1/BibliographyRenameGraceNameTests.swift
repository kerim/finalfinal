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
//  doc comment's "CROSS-SUITE RACE, CLOSED FOR THIS FILE" section for the full rationale
//  (`.serialized` only orders this suite against its own tests, not against other suites
//  running concurrently; that file's race is closed only for ITS OWN tests, not for this
//  file's `graceListCapsAt50` below, which still swaps the same static). That race, once only
//  documented as latent, was actually reproduced by a full-suite run against
//  `staleReparseAfterRenameKeepsBibliographyFlags` below.
//
//  Of this file's two tests that touch `ExportSettingsManager.shared`/
//  `ExportSettings.userDefaults`, only `graceListCapsAt50` still needs the swap: it drives
//  `ExportSettingsManager.shared` directly (`setBibliographyHeaderName`, the grace-list cap
//  logic under test), so it has no way to avoid the global. `staleReparseAfterRenameKeepsBibliographyFlags`
//  passes `bibliographyHeaderName`/`graceNames` explicitly to `BlockParser.parse` -- which, per
//  that function's own doc comment, skips the `ExportSettings.load()` call entirely when both
//  are supplied together -- and `replaceBlocks` below never touches `ExportSettings` either, so
//  that test no longer needs the isolated store, the lock, or `ExportSettingsManager.shared` at
//  all; its former swap/lock scaffolding was pure defense-in-depth for a read path the explicit
//  parameters had already made unreachable, so it has been removed. `graceListCapsAt50` below
//  still acquires `exportSettingsTestLock` (see `ExportSettingsTestLock.swift`) around its
//  entire swap-to-restore window, shared with the other suites that swap the same process-wide
//  `ExportSettings.userDefaults` static.
//
//  `graceListCapsAt50` reaches `ExportSettingsManager.shared` -- a process-wide singleton that
//  builds `settings` LAZILY on first access (`private init` calls `ExportSettings.load()`)
//  and does NOT re-read `ExportSettings.userDefaults` afterwards. It snapshots whatever the
//  singleton holds BEFORE swapping the store pointer, and restores EXACTLY that in teardown.
//  The ordering is the whole point: a snapshot taken AFTER installing the throwaway suite would
//  let the lazy init trigger against the THROWAWAY store if this ran first in the process, and
//  teardown would then write that throwaway value back as if it were the real one, leaving it
//  in place for every test that ran afterwards. Snapshotting before the swap (and under the
//  lock, so a sibling suite cannot have the pointer aimed at its own throwaway store at that
//  instant) is what actually reverses the mutation instead of laundering it.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite(.serialized)
struct BibliographyRenameGraceNameTests {

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
    func staleReparseAfterRenameKeepsBibliographyFlags() throws {
        // Heading text STILL reads the OLD name ("Works Cited"), simulating a document
        // that hasn't been regenerated since the setting was renamed to "Sources" -- the
        // exact scenario the grace list exists to keep recognized.
        //
        // Unlike other fixture-backed tests, this one does NOT go through
        // `TestFixtureFactory.createFixture`: that convenience wrapper calls
        // `BlockParser.parse(markdown:projectId:)` with no bibliography-name arguments,
        // which falls through to `ExportSettings.load()` -- a read of the process-wide
        // `ExportSettings.userDefaults` static this file's doc comment documents as a
        // cross-suite race (see `ExportSettingsTestLock.swift`). This test instead passes
        // `bibliographyHeaderName`/`graceNames` explicitly to `BlockParser.parse` -- which,
        // per that function's own doc comment, skips the `ExportSettings.load()` call
        // entirely when both are supplied together -- and `replaceBlocks` below never reads
        // `ExportSettings` either. So this test never touches `ExportSettings.userDefaults`
        // or `ExportSettingsManager.shared` at all, and needs no isolated store, no swap, and
        // no `exportSettingsTestLock`: an isolated-store/manager-sync setup here would only
        // ever be written to, never read by anything this test actually exercises.
        // Everything below (package creation, project/content insert, `replaceBlocks`)
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
        // Tests that create .ff packages under /tmp have historically left every one of them
        // behind; clean this test's own up rather than adding to the pile.
        defer { try? FileManager.default.removeItem(at: url) }
        let package = try ProjectPackage.create(at: url, title: "Test Project")
        TestFixtureCleanup.register(package.packageURL)
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

    @Test("Grace list caps at 50 entries, oldest dropped first, no duplicates")
    @MainActor
    func graceListCapsAt50() throws {
        // Isolation is inline: this test drives `ExportSettingsManager.shared`, a @MainActor
        // singleton, directly, and has no explicit-parameter path around it the way
        // `staleReparseAfterRenameKeepsBibliographyFlags` above does.
        let suiteName = TestDefaultsSuite.uniqueName("bibRenameGraceCap")
        let suite = try #require(UserDefaults(suiteName: suiteName))
        // Cross-suite lock (see ExportSettingsTestLock.swift): must be acquired before the
        // very first write to the shared `ExportSettings.userDefaults` pointer below, and
        // held until it is fully restored. This function has two `defer` blocks below (LIFO:
        // the second-declared one, restoring the manager cache, runs FIRST; this one runs
        // LAST) -- the release belongs in THIS defer, since it's the one that runs last and
        // therefore only after both restores have landed.
        exportSettingsTestLock.lock()

        // Snapshot the singleton BEFORE the store pointer is swapped, and under the lock:
        // `ExportSettingsManager` builds `settings` lazily on first access, so a first touch
        // taken after the swap would initialise it from this throwaway suite and teardown
        // would then "restore" that throwaway value into the process for every test that runs
        // afterwards.
        let manager = ExportSettingsManager.shared
        let previousManagerSettings = manager.settings

        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = suite
        defer {
            ExportSettings.userDefaults = previousStore
            TestDefaultsSuite.remove(suiteName)
            exportSettingsTestLock.unlock()
        }

        var seed = ExportSettings.default
        seed.bibliographyHeaderName = "Name0"
        seed.save()

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
