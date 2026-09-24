//
//  BibliographyBareTitleSelectionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers — bibliography-heading selection.
//
//  A heading whose text merely EQUALS the bibliography header name is not automatically
//  the machine-managed bibliography heading. Selection is: (1) a heading carrying
//  `<!-- ::auto-bibliography:: -->` wins outright; (2) otherwise the LAST title match
//  occurring before the FIRST `BlockParser.bibliographyEndMarker` (exact equality);
//  (3) with neither marker nor terminator, the LAST title match. Before this fix every
//  consumer took the FIRST title match, so a user chapter titled "Bibliography" placed
//  above the real one hijacked the flag — its prose was dropped from every export and
//  deleted by the next regeneration.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography heading selection — bare-title false positives")
struct BibliographyBareTitleSelectionTests {

    // MARK: - Case 1: BlockParser.parse -- marker wins over an earlier bare-title heading

    @Test("A bare-title user heading above the real bibliography is never selected")
    func bareTitleAboveRealBibliographyIsNotSelected() throws {
        let markdown = """
        # Intro

        Body prose.

        # Bibliography

        This chapter discusses how bibliographies are compiled.

        <!-- ::auto-bibliography:: --># Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let userChapter = try #require(blocks.first { $0.textContent == "Bibliography" })
        #expect(
            userChapter.isBibliography == false,
            "The bare-title user chapter must not be selected as the bibliography heading"
        )
        #expect(
            blocks.contains { $0.markdownFragment.contains("<!-- ::auto-bibliography:: -->") && $0.isBibliography },
            "The marked heading is the bibliography heading"
        )
        #expect(
            blocks.first { $0.textContent.hasPrefix("This chapter discusses") }?.isBibliography == false,
            "User prose under the bare-title chapter must stay unflagged — otherwise it is dropped from every export"
        )
        #expect(
            blocks.first { $0.textContent.hasPrefix("Smith, J.") }?.isBibliography == true,
            "The real entry stays flagged"
        )
    }

    // MARK: - Case 2: BlockParser.parse -- terminator bound

    @Test("BlockParser.parse: the earlier, real heading wins; a later duplicate-titled heading past the terminator is unflagged")
    func parseTerminatorBoundKeepsTheEarlierRealHeadingFlagged() throws {
        let markdown = """
        # Bibliography

        Entry one.

        \(BlockParser.bibliographyEndMarker)

        # Bibliography

        Some other chapter text.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        let headings = blocks.filter { $0.blockType == .heading }
        #expect(headings.count == 2)
        #expect(headings[0].isBibliography == true, "The earlier, real heading (before the terminator) is flagged")
        #expect(headings[1].isBibliography == false, "The later duplicate-titled heading, past the terminator, is unflagged")
        #expect(
            blocks.first { $0.textContent == "Entry one." }?.isBibliography == true,
            "The real entry stays flagged"
        )
        #expect(
            blocks.first { $0.textContent == "Some other chapter text." }?.isBibliography == false,
            "Prose under the later, unflagged duplicate heading must never be flagged"
        )
    }

    // MARK: - Case 3: BlockParser.parse -- tier 3 deleted, no marker + no terminator selects nothing

    @Test("BlockParser.parse: with no marker and no terminator, nothing is selected (tier 3 is deleted)")
    func parseNoMarkerNoTerminatorSelectsNothing() throws {
        let markdown = """
        # Bibliography

        First paragraph.

        # Bibliography

        Second paragraph.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")
        let headings = blocks.filter { $0.blockType == .heading }
        #expect(headings.count == 2)
        #expect(headings[0].isBibliography == false, "Tier 3 is deleted -- no evidence, no selection")
        #expect(headings[1].isBibliography == false, "Tier 3 is deleted -- no evidence, no selection")
        #expect(blocks.first { $0.textContent == "First paragraph." }?.isBibliography == false)
        #expect(blocks.first { $0.textContent == "Second paragraph." }?.isBibliography == false)
    }

    // MARK: - Case 4: BlockParser.parse -- marker precedence over a later bare-title heading

    @Test("BlockParser.parse: an earlier marked heading wins over a later bare-title heading")
    func parseMarkerPrecedenceOverLaterBareTitleHeading() throws {
        let markdown = """
        <!-- ::auto-bibliography:: --># Bibliography

        Entry one.

        # Bibliography

        Other content.
        """

        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.contains { $0.markdownFragment.contains("<!-- ::auto-bibliography:: -->") && $0.isBibliography },
            "The marked (earlier) heading wins"
        )
        let laterBareHeading = try #require(
            blocks.first { $0.blockType == .heading && $0.textContent == "Bibliography" }
        )
        #expect(laterBareHeading.isBibliography == false, "The later bare-title heading is unflagged")
        #expect(blocks.first { $0.textContent == "Other content." }?.isBibliography == false)
    }

    // MARK: - Case 5: replaceBlocks curative fix -- suppression, not fallback (tier 3 deleted)

    @Test(
        """
        replaceBlocks curative fix suppresses a stale false-positive flag rather than resurrecting it onto another heading, \
        when there is no terminator to prove which heading is real
        """
    )
    func replaceBlocksCurativeFixSuppressesStaleFalsePositiveWithoutTerminator() throws {
        let markdown = """
        # Bibliography

        Stray chapter text.

        # Bibliography

        Real entry one.

        Real entry two.
        """

        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        // `createTemporary` already ran BlockParser.parse + replaceBlocks once, so the DB
        // already reflects the current, correct state (nothing flagged -- tier 3 is deleted,
        // and this markdown has neither a marker nor a terminator). Force it into the
        // historical DAMAGED state instead: the earlier, bare-title heading flagged, the real
        // later heading not -- simulating a document corrupted by the pre-fix bug before this
        // fix ever ran.
        try db.write { database in
            let headings = try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchAll(database)
                .filter { $0.blockType == .heading }
                .sorted { $0.sortOrder < $1.sortOrder }
            try #require(headings.count == 2)
            var first = headings[0]
            first.isBibliography = true
            try first.update(database)
            var second = headings[1]
            second.isBibliography = false
            try second.update(database)
        }

        // Fresh reparse: with no marker and no terminator, BlockParser.parse's two-tier rule
        // selects NOTHING (tier 3 is deleted). The restore gate therefore has no
        // terminator-bounded run to restore from for EITHER heading -- neither comes back
        // flagged. This is suppression, not a fallback onto whichever heading happens to be
        // first or last: resurrecting the flag onto the later heading here would be
        // indistinguishable, from the code's point of view, from resurrecting it onto the
        // earlier bare-title one -- neither has terminator-bounded evidence.
        try db.replaceBlocks(BlockParser.parse(markdown: markdown, projectId: projectId), for: projectId)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let headingsAfter = after.filter { $0.blockType == .heading }.sorted { $0.sortOrder < $1.sortOrder }
        #expect(headingsAfter.count == 2)
        #expect(
            headingsAfter.first?.isBibliography == false,
            "The earlier, bare-title heading's stale flag must NOT be resurrected by title-match restore"
        )
        #expect(
            headingsAfter.last?.isBibliography == false,
            "Nor is the flag resurrected onto the later heading -- there is no terminator-bounded evidence for it either"
        )
        #expect(
            after.first { $0.textContent == "Real entry one." }?.isBibliography == false,
            "With no bibliography heading selected, entries stay unflagged too"
        )
        #expect(
            after.first { $0.textContent == "Stray chapter text." }?.isBibliography == false,
            "Prose under the bare-title heading must never be flagged"
        )
    }

}
