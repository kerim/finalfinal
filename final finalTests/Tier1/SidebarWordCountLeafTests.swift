//
//  SidebarWordCountLeafTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  bt t-ef411da3 (sidebar re-render investigation): OutlineSidebar's own body read
//  `section.title` inside `cardHeight(for:)` (reached via body -> sectionCard -> cardHeight)
//  and summed every visible section's `wordCount` inline in `body` for the filter bar's word
//  count -- both are `@Observable` reads inside `OutlineSidebar.body`'s own call graph, so a
//  single-character heading edit or any wordCount change re-ran the WHOLE sidebar body, not
//  just the affected card. The fix extracts the word-count sum into a leaf view
//  (`FilteredWordCountLabel`) and switches `cardHeight` to read only the plain `cardFrames`
//  `@State` dictionary populated by `.onGeometryChange`.
//
//  What these tests DO cover: the two pure static helpers the fix introduced --
//  `FilteredWordCountLabel.total(of:excludeBibliography:)` and
//  `OutlineSidebar.cardHeight(measured:)` -- return the right values in isolation.
//
//  What these tests do NOT and CANNOT cover (review round 2 correction -- an earlier draft of
//  this comment overclaimed otherwise): whether `OutlineSidebar.body` actually calls these
//  helpers instead of re-inlining the old `section.title`/per-keystroke-wordCount reads directly.
//  A regression that re-inlined either computation back into `body` would leave both helpers
//  here untouched and green -- these are unit tests of the extracted seams, not of `body`'s own
//  Observation dependency graph. That structural no-regression guarantee comes from the e2e
//  diagnostic counters instead (`final finalUITests/E2EScratchTests.swift`'s
//  `[SidebarBody]`/`[WordCountLabel]`/`[ContentViewBody]` DebugLog fire-count assertions), which
//  do observe `body`'s real invocation count against a live app.
//

import Testing
import Foundation
@testable import final_final

@Suite("Sidebar Word Count Leaf — Tier 1: Silent Killers")
struct SidebarWordCountLeafTests {

    // MARK: - Helpers

    private func makeSection(
        title: String, wordCount: Int, isBibliography: Bool = false, sortOrder: Int = 0
    ) -> SectionViewModel {
        SectionViewModel(from: Section(
            projectId: "test-project",
            sortOrder: sortOrder,
            headerLevel: 1,
            isBibliography: isBibliography,
            title: title,
            wordCount: wordCount
        ))
    }

    // MARK: - 1. FilteredWordCountLabel.total(of:excludeBibliography:)

    @Test("total sums all visible sections when excludeBibliography is false, including bibliography")
    func totalIncludesBibliographyWhenNotExcluded() {
        let sections = [
            makeSection(title: "Chapter One", wordCount: 100, sortOrder: 0),
            makeSection(title: "References", wordCount: 50, isBibliography: true, sortOrder: 1)
        ]

        let total = FilteredWordCountLabel.total(of: sections, excludeBibliography: false)

        #expect(total == 150)
    }

    @Test("total excludes bibliography-flagged sections when excludeBibliography is true")
    func totalExcludesBibliographyWhenExcluded() {
        let sections = [
            makeSection(title: "Chapter One", wordCount: 100, sortOrder: 0),
            makeSection(title: "References", wordCount: 50, isBibliography: true, sortOrder: 1)
        ]

        let total = FilteredWordCountLabel.total(of: sections, excludeBibliography: true)

        #expect(total == 100)
    }

    @Test("total of an empty section list is 0, regardless of excludeBibliography")
    func totalOfEmptySectionListIsZero() {
        #expect(FilteredWordCountLabel.total(of: [], excludeBibliography: false) == 0)
        #expect(FilteredWordCountLabel.total(of: [], excludeBibliography: true) == 0)
    }

    @Test("total is 0 when every section is bibliography-flagged and excludeBibliography is true")
    func totalIsZeroWhenAllSectionsAreBibliographyAndExcluded() {
        let sections = [
            makeSection(title: "Works Cited", wordCount: 40, isBibliography: true, sortOrder: 0),
            makeSection(title: "Further Reading", wordCount: 60, isBibliography: true, sortOrder: 1)
        ]

        let total = FilteredWordCountLabel.total(of: sections, excludeBibliography: true)

        #expect(total == 0)
    }

    // MARK: - 2. OutlineSidebar.cardHeight(measured:)

    @Test("cardHeight prefers the measured frame's height when one is available")
    func cardHeightPrefersMeasuredFrame() {
        let measured = CGRect(x: 0, y: 0, width: 280, height: 112)

        let height = OutlineSidebar.cardHeight(measured: measured)

        #expect(height == 112)
    }

    @Test("cardHeight falls back to estimatedCardHeight when no measurement exists yet")
    func cardHeightFallsBackToEstimateWhenUnmeasured() {
        let height = OutlineSidebar.cardHeight(measured: nil)

        #expect(height == OutlineSidebar.estimatedCardHeight)
    }
}
