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

    @Test(
        """
        C1: BlockParser.parse(strippingBibliographyMarkerFromBlocks:) flags a legacy marker heading and strips the marker \
        literal from its stored fragment
        """
    )
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

}
