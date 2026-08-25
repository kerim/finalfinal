//
//  BibliographyOpeningSelectorTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- t-341706cb round 8, the shared two-tier
//  `BibliographyOpeningSelector` (tier 3 permanently deleted). Covers the plan's C1-C6/C8
//  scenarios that are not already exercised by `BibliographyBareTitleSelectionTests.swift`.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("BibliographyOpeningSelector -- two-tier rule, tier 3 deleted")
struct BibliographyOpeningSelectorTests {

    // MARK: - C1: coupling test -- Step 7's legacy-load fix

    @Test("C1: BlockParser.parse(strippingBibliographyMarkerFromBlocks:) flags a legacy marker heading and strips the marker literal from its stored fragment")
    func strippingBibliographyMarkerFromBlocksFlagsLegacyMarkerAndStripsFragment() throws {
        let markdown = """
        <!-- ::auto-bibliography:: --># Bibliography

        Smith, J. (2020). A Book.
        """

        let blocks = BlockParser.parse(
            markdown: markdown,
            projectId: "p1",
            strippingBibliographyMarkerFromBlocks: true
        )

        let headingBlock = try #require(
            blocks.first { $0.isBibliography && $0.markdownFragment.contains("Bibliography") }
        )
        #expect(
            !headingBlock.markdownFragment.contains("<!-- ::auto-bibliography:: -->"),
            "The marker literal must be stripped from the stored fragment on this opt-in path"
        )
        // Must-fix (round 9): classification (blockType/headingLevel/textContent) has to run
        // against the STRIPPED text too, not just the stored fragment -- otherwise this block
        // parses as `.bibliography`/`headingLevel == nil` (the marker-glued raw text never
        // matches `detectBlockType`'s heading regex) instead of `.heading`/level 1, which
        // breaks `fetchBibliographyHeadingTitle`, `applyPreservedHeading`, and
        // `updateBibliographyBlock`'s anchor selection -- all of which require `blockType ==
        // .heading` to ever see this row. This must parse EXACTLY as if the heading had no
        // marker glued to it at all.
        #expect(headingBlock.blockType == .heading, "Must classify as .heading despite the marker glued to the raw text")
        #expect(headingBlock.headingLevel == 1)
        #expect(headingBlock.textContent == "Bibliography")
        #expect(
            blocks.first { $0.textContent.hasPrefix("Smith, J.") }?.isBibliography == true,
            "The entry beneath the legacy marker heading is still flagged"
        )
    }

    @Test("C1b: without the opt-in, BlockParser.parse is byte-identical to before -- the marker literal survives in the fragment")
    func withoutOptInMarkerLiteralSurvivesInFragment() throws {
        let markdown = """
        <!-- ::auto-bibliography:: --># Bibliography

        Smith, J. (2020). A Book.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let headingBlock = try #require(
            blocks.first { $0.isBibliography && $0.markdownFragment.contains("Bibliography") }
        )
        #expect(
            headingBlock.markdownFragment.contains("<!-- ::auto-bibliography:: -->"),
            "Default (false) behavior is unchanged: the marker literal stays in the fragment"
        )
    }

    // MARK: - C2: damaged-document shape (the core discriminating case)

    @Test("C2: a terminator immediately after a heading with no real content selects nothing, and does NOT fall back to an earlier candidate")
    func damagedDocumentShapeSelectsNothing() throws {
        let markdown = """
        # References

        This is real prose the user wrote under their own chapter heading.

        # Chapter Two

        Body text.

        # Bibliography

        \(BlockParser.bibliographyEndMarker)
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "Bibliography" }?.isBibliography == false,
            "The empty-run heading itself is not selected"
        )
        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "References" }?.isBibliography == false,
            "Must NOT fall through to the earlier candidate ('References' is also a title match)"
        )
        #expect(
            blocks.first {
                $0.textContent == "This is real prose the user wrote under their own chapter heading."
            }?.isBibliography == false,
            "The user's real prose under the earlier candidate must never be flagged"
        )
    }

    @Test("C2b (must-fix 1): a subsection heading between the candidate and the terminator invalidates the run")
    func subsectionHeadingBetweenCandidateAndTerminatorInvalidatesTheRun() throws {
        let markdown = """
        # Bibliography

        ## Notes

        \(BlockParser.bibliographyEndMarker)
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            "A subsection heading anywhere in the run invalidates it -- it is not merely excluded from an emptiness check"
        )
    }

    // MARK: - C3: suppression doesn't over-suppress

    @Test("C3: the same damaged shape, but with one real entry row, DOES select the later candidate")
    func oneRealEntryRowMakesTheRunGenuine() throws {
        let markdown = """
        # References

        This is real prose the user wrote under their own chapter heading.

        # Chapter Two

        Body text.

        # Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "Bibliography" }?.isBibliography == true,
            "A genuine, non-empty run before the terminator IS selected"
        )
        #expect(
            blocks.first { $0.textContent.hasPrefix("Smith, J.") }?.isBibliography == true,
            "The real entry is flagged"
        )
        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "References" }?.isBibliography == false,
            "The earlier candidate is still never selected"
        )
        #expect(
            blocks.first {
                $0.textContent == "This is real prose the user wrote under their own chapter heading."
            }?.isBibliography == false
        )
    }

    // MARK: - C4: tier 3 deletion -- a single candidate, no marker, no terminator

    @Test("C4: tier 3 deleted -- a single bare-title heading with no marker and no terminator is not selected")
    func singleBareTitleHeadingNoMarkerNoTerminatorSelectsNothing() throws {
        let markdown = """
        # Bibliography

        Some placeholder prose.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            "Tier 3 ('single candidate still opens') no longer exists -- no evidence, no selection"
        )
    }

    // MARK: - C5: injectBibliographyMarker writes nothing without evidence

    @Test("C5: injectBibliographyMarker -- no terminator anywhere returns the input unchanged, byte-for-byte")
    @MainActor
    func injectBibliographyMarkerWithNoTerminatorReturnsUnchanged() throws {
        let markdown = """
        # Bibliography

        Real entry one.
        """
        let sections = [
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: true,
                title: "Bibliography", markdownContent: "# Bibliography"
            ))
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(result == markdown, "No terminator -> no evidence -> markdown must be returned unchanged")
    }

    // MARK: - C6: marker-only last block -- no state leak into a later, unrelated parse() call

    @Test("C6: a document ending in a bare opening marker with nothing after it does not leak state into a later, unrelated parse() call")
    func markerOnlyLastBlockDoesNotLeakIntoLaterParse() throws {
        let markdown = """
        # Intro

        Body text.

        <!-- ::auto-bibliography:: --># Bibliography
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(
            blocks.first { $0.markdownFragment.contains("<!-- ::auto-bibliography:: -->") }?.isBibliography == true
        )

        let unrelatedMarkdown = """
        # Something Else

        Ordinary prose, no bibliography anywhere.
        """
        let unrelatedBlocks = BlockParser.parse(markdown: unrelatedMarkdown, projectId: "p2")
        #expect(
            unrelatedBlocks.allSatisfy { !$0.isBibliography },
            "A pending marker-only state from a prior parse() call must not leak into an unrelated later call"
        )
    }

    // MARK: - C8: site-specific marker-strictness (deliberately NOT unified, and NOT in the cross-check suite)

    @Test("C8a: site A (BlockParser.hasBibliographyMarker) -- a marker mid-block still counts, via .contains")
    func siteAMarkerTestIsContainsNotAnchored() {
        #expect(BlockParser.hasBibliographyMarker("Some text <!-- ::auto-bibliography:: --> more text"))
    }

    @Test("C8b: site B (SectionSyncService.parseHeaders) -- a marker NOT at line start does not count, via .hasPrefix")
    func siteBMarkerTestIsHasPrefixNotContains() throws {
        let markdown = """
        Some text mentioning <!-- ::auto-bibliography:: --> mid-line, not a real marker.

        # Bibliography

        Entry one.

        \(BlockParser.bibliographyEndMarker)
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        let bibliographyHeaders = headers.filter { $0.isBibliography }
        #expect(bibliographyHeaders.count == 1, "Exactly one boundary must be flagged")
        #expect(
            bibliographyHeaders.first?.title == "Bibliography",
            """
            The mid-line marker text must not be treated as a real marker (tier 1 would otherwise fire at that \
            non-header offset and no header line's offset would ever match it) -- tier 2's terminator-bounded \
            candidate must win instead
            """
        )
    }

    @Test("C8c: site C (injectBibliographyMarker) -- any marker anywhere means bail, unchanged")
    @MainActor
    func siteCAnyMarkerAnywhereBails() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->
        # Bibliography

        Real entry one.

        \(BlockParser.bibliographyEndMarker)
        """
        let sections = [
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: true,
                title: "Bibliography", markdownContent: "# Bibliography"
            ))
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(result == markdown, "A marker anywhere in the document means bail -- markdown must be returned unchanged")
    }

    // MARK: - C10: standalone marker block immediately before its own heading (round 9's find)

    @Test("""
    C10: a standalone marker block (glued to nothing, its own raw block) immediately followed by \
    the real bibliography heading in its own separate raw block flags BOTH the heading and the \
    entries beneath it -- not just the marker block itself
    """)
    func standaloneMarkerBlockImmediatelyBeforeHeadingFlagsHeadingAndEntries() throws {
        // Distinct from the GLUED shape (`<!-- ::auto-bibliography:: --># Bibliography`, one raw
        // block, covered by C1/C1b/C6/C8c above): here the marker sits alone on its own raw
        // block, separated by a blank line from the real heading in ITS own raw block -- a real,
        // persisted shape (see `BlockParser+Assembly.swift`'s `assembleMarkdownForExport` comment
        // on `headingBlock`, and `BibliographyPlacementExportTests`'s
        // `testLeadingBibliographyMarkerBlockAheadOfHeading_SameOutputAsHappyPath`, which covers
        // the same shape but via hand-built `Block`s rather than `BlockParser.parse` itself).
        let markdown = """
        <!-- ::auto-bibliography:: -->

        # Bibliography

        Entry one.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let markerBlock = try #require(blocks.first { $0.markdownFragment == "<!-- ::auto-bibliography:: -->" })
        let headingBlock = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Bibliography" })
        let entryBlock = try #require(blocks.first { $0.textContent == "Entry one." })

        #expect(markerBlock.isBibliography == true, "The marker block itself is still flagged (tier 1, unchanged)")
        #expect(
            headingBlock.isBibliography == true,
            """
            The real heading immediately after a standalone marker block must stay flagged -- \
            before the fix, `sectionFlagCarriedForward`'s 'any other heading closes the run' rule \
            fired on it since only the marker's own index was `opensSection`
            """
        )
        #expect(
            entryBlock.isBibliography == true,
            """
            The entry beneath the heading must stay flagged too -- it was silently dropped once \
            the heading incorrectly closed the run
            """
        )
    }

    @Test("C10b: the GLUED marker shape (one raw block) is unaffected by the standalone-marker pairing")
    func gluedMarkerShapeUnaffectedByStandaloneMarkerFix() throws {
        let markdown = """
        <!-- ::auto-bibliography:: --># Bibliography

        Entry one.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let markerHeadingBlock = try #require(
            blocks.first { $0.markdownFragment.contains("<!-- ::auto-bibliography:: -->") }
        )
        let entryBlock = try #require(blocks.first { $0.textContent == "Entry one." })

        #expect(markerHeadingBlock.isBibliography == true)
        #expect(entryBlock.isBibliography == true)
    }

    // MARK: - C9: site C's `isHeading` must tolerate the SAME anchor prefix `isCandidate` does

    @Test("""
    C9: injectBibliographyMarker -- an anchor-prefixed non-candidate heading between the candidate and the \
    terminator, with nothing else in the run, must be recognized as a heading (matching sites A/B) and \
    invalidate the run, selecting nothing rather than writing a marker
    """)
    @MainActor
    func siteCAnchorPrefixedNonCandidateHeadingInvalidatesTheRun() throws {
        // Mirrors production input: every real caller pipes `injectSectionAnchors(...)` output
        // straight into this function, and the real bibliography heading itself is excluded
        // from anchor injection (so the candidate line below stays bare) -- but an ORDINARY
        // heading sitting in the run, like "# Appendix" here, IS anchor-prefixed, exactly as
        // it would be for real CodeMirror source-mode content. Once the anchored heading is
        // correctly recognized as a heading (not content), it invalidates the run outright --
        // the same shape `BlockParser`'s own pre-scan refuses to select on (a subsection heading
        // anywhere in the run is not evidence of a genuine run for the outer candidate). Before
        // this fix, the anchor-prefixed line failed `isHeading`'s bare `^#{1,6}\s` regex, got
        // scored as CONTENT instead, and this site wrote a permanent marker onto "# Bibliography"
        // despite there being no real bibliography content in the document at all.
        let markdown = """
        # Bibliography

        <!-- @sid:11111111-1111-1111-1111-111111111111 --># Appendix

        \(BlockParser.bibliographyEndMarker)
        """
        let sections = [
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: true,
                title: "Bibliography", markdownContent: "# Bibliography"
            ))
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(
            result == markdown,
            "The anchored heading must be recognized as a heading and invalidate the run -- no marker must be written"
        )
    }

    // MARK: - Interior heading must stop tier 2 dead, anywhere in the run
    // (bib-heading-false-positive follow-up: the user's own "Bibliography" heading was
    // selected when an unrelated real heading sat further down the same run, before the
    // terminator -- the old rule only checked for non-empty, non-heading content anywhere in
    // the range and never asked whether any of that content was ITSELF a heading.)

    @Test("Interior heading: the user's real reproduction shape -- candidate, prose, unrelated interior heading, prose, terminator selects nothing anywhere")
    func interiorHeadingUserReproductionShapeSelectsNothing() throws {
        let markdown = """
        # Paper Title

        Intro prose.

        # Bibliography

        Prose the user wrote under their own heading.

        # Notes

        Notes prose.

        \(BlockParser.bibliographyEndMarker)
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            """
            Pre-fix: the user's own "Bibliography" heading was selected because the old rule only \
            checked for non-empty, non-heading content anywhere in the run and skipped over the \
            interior "# Notes" heading entirely -- the next regeneration would then have rewritten \
            the bibliography mid-document, under the user's own heading, and deleted "Notes" as a \
            section along the way.
            """
        )
        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "Bibliography" }?.isBibliography == false,
            "The user's own heading must not be selected"
        )
        #expect(
            blocks.first { $0.textContent == "Prose the user wrote under their own heading." }?.isBibliography == false,
            "The user's own prose must not be flagged"
        )
        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "Notes" }?.isBibliography == false,
            "The unrelated interior heading must not be flagged"
        )
        #expect(
            blocks.first { $0.textContent == "Notes prose." }?.isBibliography == false,
            "The unrelated interior heading's prose must not be flagged"
        )
    }

    @Test("Interior heading (Unit-level, minimal): [candidate, content, heading, content, terminator] selects nothing")
    func interiorHeadingUnitLevelMinimalSelectsNothing() {
        let units: [BibliographyOpeningSelector.Unit] = [
            // index 0: candidate heading.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 1: content.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 2: interior heading -- not itself a candidate.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 3: content.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 4: terminator.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: true, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .none,
            "An interior heading anywhere in the run, not just as the first unit, must invalidate it"
        )
    }

    @Test("Interior heading (Unit-level positive control): [candidate, content, content, terminator] still selects the candidate")
    func interiorHeadingUnitLevelPositiveControlStillSelects() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: true, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .candidate(0),
            "With no interior heading, a genuine non-empty run still selects the candidate -- the new rule must not over-suppress"
        )
    }

    @Test("Interior heading boundary pin: immediately after the candidate, with real content further down, still invalidates the run")
    func interiorHeadingImmediatelyAfterCandidateInvalidatesRun() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 1: heading immediately after the candidate.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 2: real content after the interior heading.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: true, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .none,
            "The rule is 'anywhere in the range', not 'the first unit' -- real content downstream of the interior heading must not rescue the run"
        )
    }

    @Test("Interior heading boundary pin: immediately before the terminator also invalidates the run")
    func interiorHeadingImmediatelyBeforeTerminatorInvalidatesRun() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 1: real content immediately after the candidate.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 2: heading immediately before the terminator.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: true, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .none,
            "The rule is 'anywhere in the range', not 'only the first unit' -- real content earlier in the run must not shield a later interior heading"
        )
    }

    // MARK: - Standalone-marker support (t-341706cb follow-up: bare-marker orphan false positive)
    //
    // CodeMirror's Source Mode hides the opening marker as an invisible atomic decoration with
    // no delete-protection, so deleting the visible bibliography section around it can leave a
    // bare `<!-- ::auto-bibliography:: -->` literal behind, orphaned, mid-document. These cases
    // exercise `markerIsSupported`'s scan directly via hand-built `Unit`s.

    @Test("Support: an unsupported orphan earlier in the sequence does not disable tier 1 for a real, supported marker later on")
    func orphanEarlierDoesNotDisableTier1ForARealMarkerLater() {
        let units: [BibliographyOpeningSelector.Unit] = [
            // index 0: standalone marker orphan -- its next non-empty unit (index 1) is
            // ordinary prose, not a candidate, so it is UNSUPPORTED.
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: true
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 4: a real marker glued to its own heading text -- not standalone, so it is
            // supported unconditionally.
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: true, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .marker(4),
            "An earlier unsupported orphan must not block tier 1 from finding the later, supported marker"
        )
    }

    @Test("Support: an unsupported orphan falls through to tier 2's terminator-bounded candidate")
    func unsupportedOrphanFallsThroughToTier2() {
        let units: [BibliographyOpeningSelector.Unit] = [
            // index 0: standalone marker orphan, unsupported (next unit is ordinary prose).
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: true
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 2: tier-2 candidate heading.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 3: real entry content -- makes the run non-empty.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // index 4: terminator.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: true, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .candidate(2),
            "With no marker anywhere supported, tier 2's own terminator-bounded rule must still fire"
        )
    }

    @Test("Support: an unsupported orphan with nothing else in the sequence selects nothing")
    func unsupportedOrphanAloneSelectsNothing() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: true
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .none,
            "A lone unsupported orphan, with no terminator and no candidate to fall back on, must select nothing"
        )
    }

    @Test("Support: a standalone marker separated from its heading by a blank unit is still supported")
    func standaloneMarkerBlankThenCandidateIsStillSupported() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: true
            ),
            // A blank unit between the marker and its heading -- the normal persisted shape at
            // sites B and C (line tokenizers). Must be skipped, not treated as "the next unit".
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: true, isStandaloneMarker: false
            ),
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: true, isHeading: true,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .marker(0),
            "The blank unit between the marker and its heading must be skipped, not treated as evidence of no pairing"
        )
    }

    @Test("Support: a marker glued to other text is supported regardless of what follows it")
    func gluedMarkerIsSupportedRegardlessOfWhatFollows() {
        let units: [BibliographyOpeningSelector.Unit] = [
            BibliographyOpeningSelector.Unit(
                isMarker: true, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            ),
            // Ordinary prose, deliberately NOT a candidate -- a glued marker needs no pairing.
            BibliographyOpeningSelector.Unit(
                isMarker: false, isTerminator: false, isCandidate: false, isHeading: false,
                isEmpty: false, isStandaloneMarker: false
            )
        ]

        #expect(
            BibliographyOpeningSelector.select(units) == .marker(0),
            "A glued marker (isStandaloneMarker == false) is always supported, regardless of what follows it"
        )
    }

    // MARK: - Must-fix 1 (round 9 review follow-up): a standalone-marker unit must never be
    // eligible as a tier-2 candidate. The earlier `Support:` tests above exercise
    // `markerIsSupported` via hand-built `Unit`s with `isCandidate: false` on the orphan --
    // that value is what the fix (BlockParser's `isCandidate` construction) now guarantees,
    // but it was never actually proven against site A's REAL tokenizer until these tests: the
    // real tokenizer used to produce `isCandidate: true` for that exact shape (since
    // `isBibliographyHeading` matches on ANY block containing the marker literal, including the
    // bare marker alone), letting tier 2 re-select the same orphan tier 1 had already rejected.

    @Test("Must-fix 1: an orphan marker above leftover prose, terminator-bounded, is not selected by either tier -- the prose stays unflagged")
    func orphanMarkerAboveLeftoverProseTerminatorBoundedSelectsNothing() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->

        Leftover user prose the section used to contain.

        <!-- ::auto-bibliography-end:: -->
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            """
            Before the fix: tier 1 correctly judged the orphan unsupported (its next unit, the \
            prose, is not a title candidate), but tier 2's own candidate scan then found the SAME \
            orphan marker eligible (since the real tokenizer's `isCandidate` also matched the bare \
            marker literal), with the prose sitting in its content range -- re-opening the section \
            via tier 2 and flagging the user's leftover prose as bibliography content.
            """
        )
    }

    @Test("Must-fix 1: two stacked bare orphan markers followed by ordinary prose and a terminator select nothing from either tier")
    func twoStackedBareMarkersFollowedByProseAndTerminatorSelectNothing() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->

        <!-- ::auto-bibliography:: -->

        Ordinary prose here, not a bibliography heading.

        <!-- ::auto-bibliography-end:: -->
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            """
            Before the fix: the first marker's `markerIsSupported` check saw the second marker as \
            its "next unit" and, because the real tokenizer's `isCandidate` wrongly matched the \
            bare marker literal too, judged itself supported -- winning tier 1 outright on nothing \
            but two stacked orphans and unrelated prose.
            """
        )
    }

    @Test("Must-fix 1 (tokenizer invariant): BlockParser.isBibliographyHeading matches the bare marker literal by design, yet the real tokenizer's isCandidate must never do so for a standalone-marker unit")
    func siteATokenizerNeverProducesStandaloneMarkerCandidate() throws {
        // This is the root cause, unchanged and correct on its own: `isBibliographyHeading`
        // deliberately matches ANY fragment containing the marker (it checks
        // `hasBibliographyMarker` before its title-match logic) -- that's what lets the GLUED
        // shape (`<!-- ::auto-bibliography:: --># Bibliography`) count as a candidate. The bug
        // was letting that same broad match reach `Unit.isCandidate` for the BARE literal too.
        #expect(
            BlockParser.isBibliographyHeading(BlockParser.bibliographyStartMarker),
            "sanity: isBibliographyHeading matching the bare marker by itself is correct, unchanged behavior"
        )

        // Proven against the real tokenizer (not a hand-built Unit): a lone standalone marker,
        // by itself, with no terminator and no candidate anywhere -- tier 1 must find it
        // unsupported (no next unit at all) and tier 2 must find no terminator, so nothing is
        // selected. If the tokenizer's `isCandidate` construction ever regressed to matching the
        // bare literal again, `BibliographyOpeningSelector.select`'s own
        // `isStandaloneMarker` implies `!isCandidate` debug assert (which runs against every real
        // caller, including this one) would trip on the very first test above that pairs a
        // standalone orphan with another candidate-shaped unit -- this test instead documents the
        // simplest possible input that isolates the invariant with nothing else in play.
        let blocks = BlockParser.parse(markdown: BlockParser.bibliographyStartMarker, projectId: "p1")
        #expect(
            blocks.allSatisfy { !$0.isBibliography },
            "A lone standalone marker with nothing else in the document must never be selected"
        )
    }

    // MARK: - Site inertness / non-double-write guards (t-341706cb follow-up)

    @Test("""
    Support: with existingBibTitle nil, no title is ever a candidate, so isCandidate is always \
    false regardless of what the standalone marker's next unit is -- `markerIsSupported` judges \
    it an unsupported orphan, and with no terminator anywhere tier 2 finds nothing either, so \
    `select` returns `.none`. Nothing latches: both headings surface as ordinary, unflagged \
    boundaries.
    """)
    func siteBStandaloneMarkerWithNilExistingBibTitleIsInert() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->

        # Bibliography

        Some prose.

        # Later

        More text.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: nil)

        #expect(headers.count == 2, "Both headings must surface -- the unsupported orphan marker must not swallow anything")
        #expect(
            headers.allSatisfy { $0.isBibliography == false },
            """
            `parseHeaders`'s marker branch now defers to `selectedBibliographyOffset`, which is `nil` \
            here (no candidate is possible with `existingBibTitle == nil`, and there is no \
            terminator for tier 2 to find either) -- so the marker line never sets \
            `inAutoBibliography`, and both "Bibliography" and "Later" surface as ordinary, unflagged \
            headings.
            """
        )
    }

    @Test("Guard: injectBibliographyMarker never writes a second marker when an unsupported orphan coexists with a real, terminator-bounded candidate elsewhere")
    @MainActor
    func siteCNeverWritesASecondMarker() throws {
        let markdown = """
        <!-- ::auto-bibliography:: -->

        Ordinary paragraph, not a bibliography heading.

        # Bibliography

        Entry one.

        \(BlockParser.bibliographyEndMarker)
        """
        let sections = [
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: true,
                title: "Bibliography", markdownContent: "# Bibliography"
            ))
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(
            result == markdown,
            "An orphan marker present anywhere means site C bails unconditionally -- it must never insert a second marker onto the real candidate heading"
        )
    }
}
