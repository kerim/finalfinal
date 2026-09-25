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
//  CROSS-SUITE RACE, CLOSED FOR THIS FILE -- earlier versions of this suite pointed the
//  process-wide `ExportSettings.userDefaults` static at a throwaway `UserDefaults(suiteName:)`
//  via a `withIsolatedStore` helper, guarded by `exportSettingsTestLock` (see
//  `ExportSettingsTestLock.swift`) against a real cross-suite race a full-suite run once
//  reproduced: any test reaching `BlockParser.isBibliographyHeading` only through its
//  default-argument `ExportSettings.load()` fallback -- without itself swapping the pointer
//  or holding the lock -- could transiently observe another suite's in-flight throwaway
//  settings. The fix below is threading settings through `isBibliographyHeading`'s existing
//  explicit `bibliographyHeaderName:`/`graceNames:` parameters instead of relying on that
//  fallback; every test below now does exactly that, so none of them touch
//  `ExportSettings.userDefaults`, `ExportSettingsManager.shared`, or the lock at all. That
//  closes the race for THIS FILE'S 3 TESTS ONLY, not the race in general: `graceListCapsAt50`
//  (`BibliographyRenameGraceNameTests.swift`) and every test in
//  `ExportSettingsResetNotificationTests.swift`/`ExportSettingsBibliographyRenameTests.swift`
//  still swap the same process-wide static under the same lock, and an unlocked reader that
//  reaches `BlockParser.parse`/`isBibliographyHeading` only through the default-argument
//  `ExportSettings.load()` fallback -- e.g. `TestFixtureFactory.createFixture`, which calls
//  `BlockParser.parse(markdown:projectId:)` with no bibliography-name arguments -- still exists
//  and is still exposed to whichever of those suites happens to be mid-swap at the same moment.
//
//  `bibliographyNames(from:)` (see `BlockParser.swift`) is the one piece of the production path
//  this file's tests do NOT cover: the bare `ExportSettings.load()` call that feeds a loaded
//  settings value into it. That gap is left deliberately -- `ExportSettings.load()`/`save()`
//  already have their own dedicated settings load/save tests, and covering that call HERE would
//  mean re-swapping `ExportSettings.userDefaults` in this file, reintroducing the exact global
//  this suite exists to get off of.
//

import Testing
import Foundation
@testable import final_final

struct BlockParserBibliographyHeaderNameTests {

    @Test("Custom header name is recognized at both # and ## levels")
    func customHeaderNameRecognizedAtBothLevels() {
        #expect(BlockParser.isBibliographyHeading(
            "# Works Cited", bibliographyHeaderName: "Works Cited", graceNames: []))
        #expect(BlockParser.isBibliographyHeading(
            "## Works Cited", bibliographyHeaderName: "Works Cited", graceNames: []))
    }

    @Test("bibliographyNames(from:) trims the stored header name and carries the grace list through")
    func bibliographyNamesTrimsHeaderNameAndCarriesGraceNamesThrough() {
        // This is the case that failed before BlockParser read effectiveBibliographyHeaderName:
        // the raw stored value ("  Works Cited  ") never equals the actual generated heading
        // ("# Works Cited"). Exercised here against the shared `bibliographyNames(from:)` helper
        // both fallback call sites in `BlockParser.parse`/`isBibliographyHeading` now go
        // through -- not just against `effectiveBibliographyHeaderName` directly -- so this also
        // covers the `parse` fallback path, which no earlier version of this suite reached at
        // all (it only ever called `isBibliographyHeading` directly). A non-empty grace list is
        // included alongside the untrimmed name so the tuple's second element is proven to pass
        // through unchanged, not just defaulted to `[]`.
        var settings = ExportSettings.default
        settings.bibliographyHeaderName = "  Works Cited  "
        settings.previousBibliographyHeaderNames = ["References", "Sources"]

        let derived = BlockParser.bibliographyNames(from: settings)

        #expect(derived.headerName == "Works Cited")
        #expect(derived.graceNames == ["References", "Sources"])
    }

    @Test("An unrelated heading is never matched")
    func unrelatedHeadingIsNeverMatched() {
        #expect(!BlockParser.isBibliographyHeading(
            "# Introduction", bibliographyHeaderName: "Works Cited", graceNames: []))
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
