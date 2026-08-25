//
//  BibliographyOpeningSelectorCrossCheckTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- t-341706cb round 8. Feeds the SAME fixture to all three
//  bibliography-opening-selection call sites (BlockParser.parse, SectionSyncService.
//  parseHeaders, SectionSyncService.injectBibliographyMarker) and asserts they agree: either
//  all three select the same "Bibliography" heading, or all three select nothing.
//
//  This property is FALSE for an unscoped fixture set -- the three sites deliberately diverge
//  on candidate title sets (site A accepts "References"/"Bibliography"/the settings value;
//  sites B/C match only one configured title), heading levels (site B allows 1-6, A/C only
//  1-2), and fence/notes gating. See `BibliographyOpeningSelector.swift`'s doc comment and the
//  per-site doc comments on each of the three functions for the full divergence table. Every
//  fixture below is deliberately scoped to avoid all of those divergences:
//
//  1. The heading title is "Bibliography" everywhere -- the shipped DEFAULT
//     `effectiveBibliographyHeaderName`, so no ExportSettings swapping is needed to make the
//     settings value, `existingBibTitle`, and the markdown literal all agree.
//  2. Every heading is level 1.
//  3. `existingBibTitle: "Bibliography"` is always passed, and the fixture's `sections` array
//     always includes an `isBibliography` entry.
//  4. No code fences, no Notes section.
//  5. No decoy titles: no heading anywhere in a fixture equals "References" (site A's
//     always-candidate literal) except never, since these fixtures don't use it at all.
//  6. No marker anywhere in ANY cross-check fixture, deliberately -- site C bails
//     unconditionally on any marker (returns the input unchanged), which is incomparable to
//     sites A/B's index-selecting behavior for that same input. Marker-strictness per site is
//     tested independently in `BibliographyOpeningSelectorTests`'s C8 cases instead.
//  7. Every heading, entry, and the terminator is its own blank-line-delimited unit -- no
//     terminator glued directly onto the line after the last entry, no heading glued to its
//     first line of content. Site A tokenizes into blank-line-delimited raw blocks; sites B/C
//     work line-by-line -- a glued terminator would make site A's block-based view see one
//     block that *contains but never equals* the terminator literal (failing site A's
//     exact-equality test) while B/C's line-based view sees its own line and matches: a real,
//     but ARTIFICIAL, divergence this suite must not manufacture.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("BibliographyOpeningSelector -- cross-check: sites A/B/C agree")
struct BibliographyOpeningSelectorCrossCheckTests {

    private static let title = "Bibliography"

    private func sections(bibliography: Bool) -> [SectionViewModel] {
        [SectionViewModel(from: Section(
            projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: bibliography,
            title: Self.title, markdownContent: "# \(Self.title)"
        ))]
    }

    /// Fails the calling test (via `#expect`) if `markdown` violates any of this suite's own
    /// scoping preconditions (see the type's doc comment) -- guards against a future edit to
    /// one of the fixtures below silently reintroducing one of the three sites' KNOWN,
    /// deliberate divergences into what's meant to be an apples-to-apples comparison.
    private func assertFixtureIsInScope(_ markdown: String) {
        #expect(
            markdown.range(of: #"(^|\n)#{3,6}\s"#, options: .regularExpression) == nil,
            "Cross-check fixtures must only use heading levels 1-2 (site B allows 1-6, A/C only 1-2)"
        )
        #expect(
            !markdown.contains("<!-- ::auto-bibliography:: -->"),
            "Cross-check fixtures must never contain a marker -- see precondition 6"
        )
        #expect(
            !markdown.contains("# References"),
            "Cross-check fixtures must never contain the decoy title 'References' -- see precondition 5"
        )
        if let terminatorRange = markdown.range(of: BlockParser.bibliographyEndMarker) {
            let before = markdown[..<terminatorRange.lowerBound]
            #expect(
                before.isEmpty || before.hasSuffix("\n\n"),
                "The terminator must be its own blank-line-delimited unit -- see precondition 7"
            )
        }
    }

    // MARK: - Fixture: terminator-bounded with real entries -- all three select "Bibliography"

    @Test("Cross-check: terminator-bounded with real entries -- all three sites select the Bibliography heading")
    @MainActor
    func terminatorBoundedWithRealEntriesAllSitesAgree() throws {
        let markdown = """
        # Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)
        """
        assertFixtureIsInScope(markdown)

        // Site A
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.first { $0.blockType == .heading }?.isBibliography == true, "Site A must select the heading")
        #expect(blocks.first { $0.textContent.hasPrefix("Smith, J.") }?.isBibliography == true)

        // Site B
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        let bibHeaders = headers.filter { $0.isBibliography }
        #expect(bibHeaders.count == 1, "Site B must select exactly one boundary")
        #expect(bibHeaders.first?.title == Self.title)

        // Site C
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(
            result.contains("<!-- ::auto-bibliography:: --># \(Self.title)\n\nSmith, J."),
            "Site C must inject the marker directly before the same heading"
        )
    }

    // MARK: - Fixture: damaged empty-run shape -- all three select nothing

    @Test("Cross-check: damaged empty-run shape (terminator immediately after the heading) -- all three sites select nothing")
    @MainActor
    func damagedEmptyRunShapeAllSitesSelectNothing() throws {
        let markdown = """
        # Bibliography

        \(BlockParser.bibliographyEndMarker)
        """
        assertFixtureIsInScope(markdown)

        // Site A
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.allSatisfy { !$0.isBibliography }, "Site A must select nothing")

        // Site B
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        #expect(headers.filter { $0.isBibliography }.isEmpty, "Site B must select nothing")

        // Site C
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(result == markdown, "Site C must return the markdown unchanged")
    }

    // MARK: - Fixture: two same-titled headings, later one terminator-bounded and non-empty

    @Test("Cross-check: two same-titled headings, the later terminator-bounded and non-empty -- all three sites select the LATER heading")
    @MainActor
    func twoSameTitledHeadingsAllSitesSelectTheLaterOne() throws {
        let markdown = """
        # Bibliography

        A user chapter that merely shares the title, with real prose of its own.

        # Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)
        """
        assertFixtureIsInScope(markdown)

        // Site A
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        let headingBlocks = blocks.filter { $0.blockType == .heading }
        #expect(headingBlocks.count == 2)
        #expect(headingBlocks.first?.isBibliography == false, "Site A must not select the earlier heading")
        #expect(headingBlocks.last?.isBibliography == true, "Site A must select the later heading")

        // Site B
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        let bibHeaders = headers.filter { $0.isBibliography }
        #expect(bibHeaders.count == 1, "Site B must select exactly one boundary")
        let earlierHeaderOffset = try #require(headers.first { $0.title == Self.title }?.startOffset)
        #expect(
            bibHeaders.first?.startOffset != earlierHeaderOffset,
            "Site B must select the LATER heading's offset, not the earlier one"
        )

        // Site C
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(
            !result.contains("<!-- ::auto-bibliography:: --># \(Self.title)\n\nA user chapter"),
            "Site C must not inject before the earlier heading"
        )
        #expect(
            result.contains("<!-- ::auto-bibliography:: --># \(Self.title)\n\nSmith, J."),
            "Site C must inject before the later heading"
        )
    }

    // MARK: - Fixture: no terminator anywhere -- all three select nothing

    @Test("Cross-check: no terminator anywhere -- all three sites select nothing (tier 3 deleted)")
    @MainActor
    func noTerminatorAllSitesSelectNothing() throws {
        let markdown = """
        # Bibliography

        Smith, J. (2020). A Book.
        """
        assertFixtureIsInScope(markdown)

        // Site A
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.allSatisfy { !$0.isBibliography }, "Site A must select nothing without a terminator")

        // Site B
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        #expect(headers.filter { $0.isBibliography }.isEmpty, "Site B must select nothing without a terminator")

        // Site C
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(result == markdown, "Site C must return the markdown unchanged without a terminator")
    }

    // MARK: - Fixture: an unrelated real heading interior to the run -- all three select nothing
    // (bib-heading-false-positive follow-up)

    @Test("Cross-check: an unrelated real heading interior to the candidate's run, before the terminator -- all three sites select nothing")
    @MainActor
    func interiorHeadingAllSitesSelectNothing() throws {
        let markdown = """
        # Bibliography

        A user chapter that merely shares the title, with real prose of its own.

        # Later

        More text, an unrelated real heading interior to the run.

        \(BlockParser.bibliographyEndMarker)
        """
        assertFixtureIsInScope(markdown)

        // Site A
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(blocks.allSatisfy { !$0.isBibliography }, "Site A must select nothing -- the interior heading invalidates the run")

        // Site B
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        #expect(headers.filter { $0.isBibliography }.isEmpty, "Site B must select nothing -- the interior heading invalidates the run")

        // Site C
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(result == markdown, "Site C must return the markdown unchanged -- no marker written when an interior heading invalidates the run")
    }

    // MARK: - Fixture: standalone-marker orphan + a real marker -- exercises `select`'s
    // isStandaloneMarker-implies-isMarker debug assert at all three sites' own tokenizers
    // (t-341706cb follow-up: bare-marker orphan false positive)
    //
    // Deliberately violates this suite's own precondition 6 ("no marker anywhere") -- this
    // fixture's entire purpose is to run all three of `select`'s real callers against a
    // standalone marker, a glued marker, and a marker embedded mid-line, so `select`'s internal
    // debug assert -- `isStandaloneMarker` must always imply `isMarker` -- actually executes
    // against each site's OWN tokenizer output, not just hand-built `Unit`s (see
    // `BibliographyOpeningSelectorTests`'s standalone-marker-support cases for those). A future
    // edit to any site's `isStandaloneMarker` expression that ever becomes laxer than that same
    // site's own `isMarker` expression will trip this assert (crashing the test run) rather than
    // silently misclassifying an orphan. `assertFixtureIsInScope` is intentionally NOT called
    // here for that reason.
    @Test("Cross-check: the isStandaloneMarker invariant holds when real marker-shaped input reaches all three sites' own tokenizers")
    @MainActor
    func standaloneMarkerInvariantHoldsAtAllThreeSites() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->

        Ordinary paragraph, not a bibliography heading -- makes the standalone marker above an unsupported orphan.

        <!-- ::auto-bibliography:: --># Bibliography

        Entry one.

        \(BlockParser.bibliographyEndMarker)

        Trailing text mentioning <!-- ::auto-bibliography:: --> mid-line, well after the terminator.
        """

        // Site A: the standalone orphan (its own raw block) is skipped as unsupported -- the
        // block right after it is ordinary prose, not a candidate. The later glued marker is
        // not standalone, so it is supported unconditionally and opens the section, exactly
        // like the pre-existing C10b glued-marker shape.
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        let orphanBlock = try #require(blocks.first { $0.markdownFragment == BlockParser.bibliographyStartMarker })
        #expect(orphanBlock.isBibliography == false, "The unsupported standalone orphan must not be flagged")
        let gluedBlock = try #require(blocks.first { $0.markdownFragment.contains("# Bibliography") })
        #expect(gluedBlock.isBibliography == true, "The later, supported glued marker must still open the section")
        let entryBlock = try #require(blocks.first { $0.textContent == "Entry one." })
        #expect(entryBlock.isBibliography == true, "The entry beneath the real opening must be flagged")

        // Site B: `parseHeaders`'s marker branch now defers to `selectedBibliographyOffset`. The
        // pre-scan's tier 1 finds the standalone orphan at line 0 unsupported (its next
        // non-empty unit is ordinary prose, not a candidate) and instead selects the LATER,
        // glued marker (`<!-- ::auto-bibliography:: --># Bibliography`), which is supported
        // unconditionally. But that selected line is never itself a *heading* line -- the
        // marker literal is glued directly onto "# Bibliography" on the very same line, so the
        // whole line fails `trimmed.hasPrefix("#")` and the marker branch's own `continue` skips
        // it before `parseHeaderLine` is ever consulted, exactly like the pre-existing glued-
        // marker shape (C1/C6/C8c) already does elsewhere in this file. This fixture's only
        // heading-shaped text is that same glued line, so no line in the whole document ever
        // independently qualifies as a boundary-emitting heading -- `headers.isEmpty` here is
        // "no boundary-emitting heading exists in this fixture", not "the marker is supported so
        // nothing else surfaces".
        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: Self.title)
        #expect(headers.isEmpty, "The glued marker+heading line is consumed whole by the marker branch's continue -- no line in this fixture is ever parsed as an independent heading")

        // Site C: change 1b's unconditional marker guard bails before `select` is even called
        // whenever ANY marker is present anywhere in the document -- deterministically unchanged.
        let result = SectionSyncService().injectBibliographyMarker(markdown: markdown, sections: sections(bibliography: true))
        #expect(result == markdown, "Site C must bail unchanged whenever any marker is present, regardless of support")
    }
}
