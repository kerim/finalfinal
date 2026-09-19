//
//  BlockParserBibliographyHeaderNameTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for a custom bibliography-header-name setting only being applied at
//  one of its five consumers. `BlockParser.isBibliographyHeading` is one of those consumers:
//  it now reads `ExportSettings.load().effectiveBibliographyHeaderName` (trimmed,
//  never-empty) instead of the raw stored `bibliographyHeaderName`. Before that fix, a custom
//  name saved WITH surrounding whitespace (e.g. from a text field that doesn't trim on
//  commit) would never match the actual generated heading -- silently dropping
//  `isBibliography` from every entry paragraph in the section, leaving them stranded as
//  duplicate body text on the next bibliography write. See `BlockParser.isBibliographyHeading`
//  and `ExportSettings.effectiveBibliographyHeaderName`'s doc comments for the full mechanism.
//
//  Isolation: `ExportSettings.load()`/`save()` go straight to a swappable `userDefaults`
//  static var (`AppDefaults.store` in production -- see that property's doc comment in
//  ExportSettings.swift). This suite points it at a throwaway `UserDefaults(suiteName:)`
//  for the duration of each test and restores the previous store afterward via `defer` --
//  it must NEVER write the real `UserDefaults.standard` domain, since a crash mid-test
//  between the write and its cleanup would permanently change the user's real bibliography
//  header name. `.serialized` only orders this suite against its own tests (Swift Testing
//  runs suites concurrently by default).
//
//  CROSS-SUITE RACE -- `ExportSettings.userDefaults` is a single process-wide static, not a
//  per-suite or per-test value, and `.serialized` above only orders THIS suite's own tests
//  against each other, not against other suites (Swift Testing runs different suites
//  concurrently by default). This was documented here as a "known, currently-latent" risk
//  until it stopped being latent: a full-suite run reproduced a failure caused by exactly
//  this seam, in `BibliographyRenameGraceNameTests`, another suite that swaps this same
//  static (the third is `ExportSettingsResetNotificationTests`). All 3 now share
//  `exportSettingsTestLock` (see `ExportSettingsTestLock.swift`), acquired immediately
//  before this suite's own swap above and released only after the restore in the `defer`
//  below -- closing the race between any two of these three writers. This does NOT extend
//  to a fourth kind of test: one that only ever READS via `BlockParser.isBibliographyHeading`'s
//  default-argument `ExportSettings.load()` fallback without itself swapping the pointer --
//  such a reader never acquires the lock, so it could still transiently observe one of these
//  suites' throwaway stores while it holds the lock. That narrower risk is unchanged by this
//  fix. Precisely: `BlockParser.isBibliographyHeading`'s `titles` array always includes the
//  literal "Bibliography" unconditionally (see `BlockParser.swift`), regardless of the stored
//  setting, so an unlocked reader parsing an ordinary `# Bibliography` heading is never
//  affected -- but a reader parsing a heading that matches a swapper's custom/grace name CAN
//  get a false POSITIVE while that swapper's throwaway store is installed. The durable fix --
//  threading settings through `BlockParser.parse`'s existing explicit parameters at the
//  remaining swap sites -- is deliberately out of scope here; it should be filed as a separate
//  task rather than left as only a comment.
//
//  SCOPE -- this seam only reaches `BlockParser.isBibliographyHeading`, which calls
//  `ExportSettings.load()` directly. `withIsolatedStore` below ALSO reaches
//  `ExportSettingsManager.shared`: it snapshots the singleton's current settings BEFORE
//  swapping `ExportSettings.userDefaults`, so the singleton's lazy init (`private init` calls
//  `ExportSettings.load()`) reads the real store, never the throwaway one, and restores that
//  snapshot via `manager.update` in the `defer` (mirroring
//  `BibliographyRenameGraceNameTests.staleReparseAfterRenameKeepsBibliographyFlags`'s ordering
//  in this same file tree). This suite's own test bodies still only exercise
//  `BlockParser.isBibliographyHeading` directly, not the manager. Of the production call sites
//  this task changed to read `effectiveBibliographyHeaderName`, only
//  `BlockParser.isBibliographyHeading` goes through the `ExportSettings.load()` seam;
//  `BibliographySyncService`'s two bibliography-generation call sites
//  (`generateBibliographyMarkdown`, `updateBibliographyBlock`), `SectionSyncService`'s three
//  `fallbackBibTitle` call sites, and `SectionSyncService+Anchors.injectBibliographyMarker`
//  all read via `ExportSettingsManager.shared` and are untouched by this seam. Do not write
//  a test against any of those five sites assuming this isolation covers them.
//

import Testing
import Foundation
@testable import final_final

@Suite(.serialized)
struct BlockParserBibliographyHeaderNameTests {

    /// Points `ExportSettings.userDefaults` at a fresh, per-call isolated suite, saves
    /// `headerName` as the stored `bibliographyHeaderName` into it, runs `body`, then
    /// restores the previous store and deletes the throwaway suite's persistent domain.
    /// Never touches the real `UserDefaults.standard` domain.
    @MainActor
    private static func withIsolatedStore(headerName: String, _ body: () -> Void) {
        let suiteName = "com.kerim.final-final.tests.blockParserBibHeader.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite for test")
            return
        }
        // Cross-suite lock (see ExportSettingsTestLock.swift): must be acquired before the
        // very first write to the shared `ExportSettings.userDefaults` pointer below, and
        // held until it is fully restored -- this closes the "KNOWN, CURRENTLY-LATENT RISK"
        // this file's own doc comment above previously only documented rather than fixed.
        exportSettingsTestLock.lock()

        // Snapshot the singleton BEFORE the store pointer is swapped, and under the lock --
        // mirroring `BibliographyRenameGraceNameTests.staleReparseAfterRenameKeepsBibliographyFlags`.
        // `ExportSettingsManager` builds `settings` lazily on first access (`private init` calls
        // `ExportSettings.load()`), so a first touch taken AFTER the swap would initialise it
        // from this throwaway suite -- and teardown would then "restore" that throwaway value
        // into the process for every test that runs afterwards.
        let manager = ExportSettingsManager.shared
        let previousManagerSettings = manager.settings

        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = suite
        defer {
            // Restore the manager's cache FIRST, while `ExportSettings.userDefaults` still
            // points at `suite`, so the `save()` inside `update` lands in the throwaway store
            // and never the real one.
            manager.update { $0 = previousManagerSettings }
            ExportSettings.userDefaults = previousStore
            suite.removePersistentDomain(forName: suiteName)
            // Release LAST, after both restores above have fully landed.
            exportSettingsTestLock.unlock()
        }

        var settings = ExportSettings.default
        settings.bibliographyHeaderName = headerName
        settings.save()

        body()
    }

    @Test("Custom header name is recognized at both # and ## levels")
    @MainActor
    func customHeaderNameRecognizedAtBothLevels() {
        Self.withIsolatedStore(headerName: "Works Cited") {
            #expect(BlockParser.isBibliographyHeading("# Works Cited"))
            #expect(BlockParser.isBibliographyHeading("## Works Cited"))
        }
    }

    @Test("Custom header name stored with surrounding whitespace still matches the generated heading")
    @MainActor
    func customHeaderNameWithSurroundingWhitespaceStillMatches() {
        // This is the case that failed before BlockParser read effectiveBibliographyHeaderName:
        // the raw stored value ("  Works Cited  ") never equals the actual generated heading
        // ("# Works Cited"), so isBibliographyHeading returned false and the fix above exists
        // specifically to trim before comparing.
        Self.withIsolatedStore(headerName: "  Works Cited  ") {
            #expect(BlockParser.isBibliographyHeading("# Works Cited"))
        }
    }

    @Test("An unrelated heading is never matched")
    @MainActor
    func unrelatedHeadingIsNeverMatched() {
        Self.withIsolatedStore(headerName: "Works Cited") {
            #expect(!BlockParser.isBibliographyHeading("# Introduction"))
        }
    }
}

/// Regression coverage for `SectionSyncService+Anchors.injectBibliographyMarker`'s
/// header-matching regex directly -- not just `BlockParser.isBibliographyHeading`. Before
/// the anchored pattern, `# \#(escapedHeaderName)` had no line anchors, so `firstMatch`
/// could match mid-line inside a legitimate `## <name>` H2 heading (splitting the marker
/// between the two `#` characters and corrupting the content), or stop at an EARLIER
/// ordinary heading whose text merely starts with the bibliography name, before ever
/// reaching the real bibliography heading later in the document. These tests exercise the
/// injection itself, on both the `#` and `##` forms `BlockParser.isBibliographyHeading`
/// accepts.
///
/// Uses the default "Bibliography" header name only (no `ExportSettings` seam needed):
/// "Bibliography" is an unconditional literal in `BlockParser.isBibliographyHeading`'s
/// `titles` array regardless of the stored setting, and `injectBibliographyMarker` locates
/// its section only via `SectionViewModel.isBibliography`, set directly on the constructed
/// `Section` fixtures below -- no dependency on `ExportSettings.userDefaults` at all.
@Suite("SectionSyncService+Anchors.injectBibliographyMarker — header matching")
struct InjectBibliographyMarkerMatchingTests {

    private func section(title: String, headerLevel: Int, isBibliography: Bool) -> SectionViewModel {
        SectionViewModel(from: Section(
            projectId: "test",
            sortOrder: 0,
            headerLevel: headerLevel,
            isBibliography: isBibliography,
            title: title,
            markdownContent: String(repeating: "#", count: headerLevel) + " " + title
        ))
    }

    @Test("An H2 bibliography heading gets the marker, uncorrupted")
    @MainActor
    func h2BibliographyHeadingGetsMarkerUncorrupted() {
        // t-341706cb round 9: `injectBibliographyMarker` now requires a genuine
        // terminator-bounded, non-empty run before it will write a marker at all — no
        // terminator means `.none` and the markdown returns UNCHANGED (see
        // `BibliographyOpeningSelector` and this function's `.marker, .none: return markdown`
        // branch). The terminator below is real evidence a generated bibliography would carry.
        let markdown = """
        ## Bibliography

        Entry one.

        <!-- ::auto-bibliography-end:: -->
        """
        let sections = [section(title: "Bibliography", headerLevel: 2, isBibliography: true)]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(
            result.hasPrefix("<!-- ::auto-bibliography:: -->## Bibliography"),
            "Marker must land immediately before the intact H2 heading, not mid-line inside it"
        )
        #expect(
            !result.contains("#<!-- ::auto-bibliography:: -->#"),
            "Marker must never split the two '#' characters of the H2 heading apart"
        )
    }

    @Test("An earlier heading that's a textual prefix of the bibliography name is not matched")
    @MainActor
    func earlierPrefixHeadingIsNotMatched() {
        // t-341706cb round 9: `injectBibliographyMarker` now requires a genuine
        // terminator-bounded, non-empty run before it will write a marker at all — no
        // terminator means `.none` and the markdown returns UNCHANGED (see
        // `BibliographyOpeningSelector` and this function's `.marker, .none: return markdown`
        // branch). The terminator below is real evidence a generated bibliography would carry,
        // bounding the run under the real "# Bibliography" heading (not the earlier, unrelated
        // "# Bibliography Notes" heading, which stays a non-candidate either way).
        let markdown = """
        # Bibliography Notes

        Some unrelated notes, not the bibliography.

        # Bibliography

        Entry one.

        <!-- ::auto-bibliography-end:: -->
        """
        let sections = [
            section(title: "Bibliography Notes", headerLevel: 1, isBibliography: false),
            section(title: "Bibliography", headerLevel: 1, isBibliography: true)
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(
            !result.contains("<!-- ::auto-bibliography:: --># Bibliography Notes"),
            "Marker must not land on the earlier heading just because its text starts with the bibliography name"
        )
        #expect(
            result.contains("<!-- ::auto-bibliography:: --># Bibliography\n"),
            "Marker must land on the real, later bibliography heading"
        )
    }
}
