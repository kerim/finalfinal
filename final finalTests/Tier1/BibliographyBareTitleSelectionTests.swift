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

    @Test("replaceBlocks curative fix suppresses a stale false-positive flag rather than resurrecting it onto another heading, when there is no terminator to prove which heading is real")
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

    // MARK: - Case 5b: replaceBlocks curative fix via the real assembleMarkdownForEditor round-trip

    @Test("replaceBlocks curative fix drops a stale false-positive flag via the real assembleMarkdownForEditor -> parse -> replaceBlocks path")
    func replaceBlocksCurativeFixDropsStaleFalsePositiveViaAssembleRoundTrip() throws {
        // Unlike Case 5 above (which feeds a hand-typed markdown string straight to
        // BlockParser.parse), this variant goes through the real production shape for the
        // default replaceBlocks path: assembleMarkdownForEditor(blocks) -> parse ->
        // replaceBlocks -- e.g. the zoom-exit reparse and the project-open reassembly in
        // ContentView+ProjectLifecycle.swift. This matters because the real bibliography
        // heading here is MARKER-typed (blockType == .bibliography, never .heading --
        // detectBlockType requires `^#{1,6}\s`, which the glued marker prefix defeats), and
        // assembleMarkdownForEditor emits each block's own markdownFragment verbatim,
        // including that glued marker text -- exactly the shape that reaches replaceBlocks in
        // production and that a hand-typed raw string never exercises.
        let markdown = """
        # Intro

        Body prose.

        # Bibliography

        Stray chapter text.

        <!-- ::auto-bibliography:: --># Bibliography

        Real entry one.

        Real entry two.

        \(BlockParser.bibliographyEndMarker)
        """

        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        // `createTemporary` already parsed + replaced once on an empty DB, so it reflects the
        // FIXED, correct state: the bare-title heading unflagged, the marker-typed block
        // flagged. Force the bare-title heading's OWN existing row into the historical DAMAGED
        // state -- flagged `isBibliography = true` -- simulating a document corrupted before
        // this fix ever ran. `applyPreservedHeading`'s title-match restore reads exactly this
        // row when the fresh parse below reaches the bare-title heading again.
        try db.write { database in
            var stale = try #require(
                try Block.filter(Block.Columns.projectId == projectId).fetchAll(database)
                    .first { $0.blockType == .heading && $0.textContent == "Bibliography" }
            )
            try #require(
                stale.isBibliography == false,
                "sanity: the initial correct parse must have left the bare-title heading unflagged"
            )
            stale.isBibliography = true
            try stale.update(database)
        }

        // The real path: snapshot the (now-damaged) DB rows, reassemble them into markdown via
        // assembleMarkdownForEditor (verbatim fragments, including the glued marker), reparse
        // that markdown fresh, and replace. The fresh parse's tier 1 correctly selects the
        // marker-typed block regardless of the damaged DB row's stale flag -- parse() only
        // ever reads the raw markdown text, never prior DB state.
        let seeded = try BibliographyCarryForwardSupport.blocks(db, projectId)
        let reassembled = BlockParser.assembleMarkdownForEditor(from: seeded)
        #expect(
            reassembled.contains("<!-- ::auto-bibliography:: -->"),
            "sanity: the reassembled markdown must still carry the marker, or this test proves nothing"
        )
        try db.replaceBlocks(BlockParser.parse(markdown: reassembled, projectId: projectId), for: projectId)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(
            after.first { $0.blockType == .heading && $0.textContent == "Bibliography" }?.isBibliography == false,
            """
            The bare-title heading's stale flag must NOT be resurrected: the fresh parse's \
            marker-typed block (blockType == .bibliography, not .heading) must still count as \
            "the parse found a real bibliography heading" and suppress restoringBibliography
            """
        )
        #expect(
            after.contains { $0.markdownFragment.contains("<!-- ::auto-bibliography:: -->") && $0.isBibliography },
            "The marker-typed block remains the flagged bibliography opening"
        )
        #expect(
            after.first { $0.textContent.hasPrefix("Real entry one") }?.isBibliography == true,
            "Real entries remain flagged"
        )
        #expect(
            after.first { $0.textContent.hasPrefix("Stray chapter text") }?.isBibliography == false,
            "Prose under the bare-title heading must never be flagged"
        )
    }

    // MARK: - Case 6: replaceBlocks curative fix does not interfere with the carry-forward fix

    @Test("replaceBlocks curative fix does not interfere with the existing carry-forward fix (commit 097e4ba1)")
    func replaceBlocksCurativeFixDoesNotInterfereWithCarryForward() throws {
        let content = """
        # Intro

        Body prose.

        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [BibliographyCarryForwardSupport.syntheticHeader, "Entry one.", "Entry two."]
        )

        let markdown = try BibliographyCarryForwardSupport.roundTrip(db, projectId)
        #expect(
            markdown.contains(BlockParser.bibliographyEndMarker),
            "assembleMarkdownForEditor must emit the terminator, or this test proves nothing"
        )

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader),
            """
            The heading is still re-flagged by applyPreservedHeading's title match -- the curative \
            fix's suppression must NOT fire here, since the fresh parse found no bibliography \
            heading at all (parseFoundBibliographyHeading == false), matching restoringBibliography's \
            unchanged default
            """
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."),
            "Carry-forward onto entries is unaffected by the curative fix"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two."))
    }

    // MARK: - Case 7: insert path never adopts by title

    @Test("Insert path never adopts by title: a bare-title heading fragment between two flagged bibliography rows is not flagged")
    func insertPathNeverAdoptsByTitle() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let blocksBefore = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocksBefore = blocksBefore.filter { $0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        let himmelmann = try #require(
            bibBlocksBefore.first { $0.markdownFragment.contains("Himmelmann") },
            "richTestContent should contain a Himmelmann bibliography entry"
        )

        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-bare-title-heading",
                blockType: "heading",
                textContent: "References",
                markdownFragment: "# References",
                headingLevel: 1,
                afterBlockId: himmelmann.id
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-bare-title-heading"])
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == false,
            """
            A bare-title heading fragment (no marker) must never be adopted as the bibliography \
            heading, even wedged between two flagged entries where containment alone would \
            resolve true
            """
        )
    }

    // MARK: - Case 8: insert path honours the marker

    @Test("Insert path honours the marker: a marker-carrying heading fragment inserted OUTSIDE any bibliography containment is still flagged")
    func insertPathHonoursTheMarker() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // Insert at document start -- deliberately NOT anchored to any bibliography block.
        // `resolveInsertPlacement`'s doc-start branch always resolves `isBibliography: false`
        // unconditionally, without ever reaching the containment check, so
        // `isBibliographyContainment` is guaranteed false here. That means ONLY
        // `buildInsertedBlock`'s independent `hasBibliographyMarker` check can make the
        // assertion below pass. (The previous version of this test anchored between two
        // already-flagged bibliography rows, where containment alone would have satisfied the
        // assertion even with the marker-check branch deleted -- it proved nothing about the
        // marker check itself.)
        let changes = BlockChanges(inserts: [
            BlockInsert(
                tempId: "temp-marker-heading",
                blockType: "heading",
                textContent: "References",
                markdownFragment: "<!-- ::auto-bibliography:: --># References",
                headingLevel: 1,
                afterBlockId: nil,
                atDocumentStart: true
            )
        ])

        let mapping = try db.applyBlockChangesFromEditor(changes, for: pid)
        let newId = try #require(mapping["temp-marker-heading"])
        let blocksAfter = try TestFixtureFactory.fetchBlocks(from: db)
        let newBlock = try #require(blocksAfter.first { $0.id == newId })

        #expect(
            newBlock.isBibliography == true,
            "A marker-carrying heading fragment must be flagged purely by carrying the marker, with no containment help"
        )
    }

    // MARK: - Case 9: parseHeaders terminator bound

    @Test("parseHeaders: the earlier, real heading is flagged; a later duplicate-titled heading past the terminator does not steal it")
    func parseHeadersTerminatorBoundKeepsTheEarlierRealHeadingFlagged() throws {
        let markdown = """
        # Bibliography

        Entry one.

        \(BlockParser.bibliographyEndMarker)

        # Bibliography

        Some other content.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        let bibliographyHeaders = headers.filter { $0.isBibliography }
        #expect(bibliographyHeaders.count == 1, "Exactly one boundary must be flagged isBibliography")
        #expect(
            bibliographyHeaders.first?.startOffset == 0,
            "The flagged boundary must be the EARLIER, real heading (at the document start), not the later duplicate"
        )
        // NOTE: `parseHeaders`'s `inAutoBibliography` latch is now terminator-bounded -- it
        // closes exactly at `BlockParser.bibliographyEndMarker` (exact equality, matching the
        // pre-scan's own terminator gating), so the region no longer absorbs everything for the
        // rest of the document. The later, duplicate-titled "# Bibliography" heading DOES surface
        // here, as an ordinary, unflagged boundary -- it is a bare-title match that is not the
        // pre-scan's selected offset, exactly like any other non-matching heading.
        #expect(headers.count == 2, "The later duplicate heading now surfaces too, past the terminator")
        let laterDuplicate = try #require(headers.last)
        #expect(laterDuplicate.isBibliography == false, "The later duplicate heading is never flagged")
        #expect(
            laterDuplicate.markdownContent.contains("Some other content."),
            "Content after the terminator must surface under the later, unflagged heading, not be swallowed"
        )
    }

    // MARK: - Case 9b: parseHeaders terminator bound -- the actual regression shape

    @Test("parseHeaders (reversed shape): a bare-title heading above the real bibliography does not steal the flag -- the later, real heading is flagged")
    func parseHeadersReversedShapeFlagsTheLaterRealHeading() throws {
        // Case 9 above (real heading first, duplicate after the terminator) already held under
        // the OLD first-match-wins logic, since the real heading happened to come first anyway
        // -- it doesn't discriminate old from new behavior. This is the shape that actually
        // regresses under first-match-wins: a bare-title heading ABOVE the real, machine-managed
        // one.
        let markdown = """
        # Bibliography

        Not the real one -- a user chapter that merely shares the title.

        # Bibliography

        Real entry one.

        \(BlockParser.bibliographyEndMarker)
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        #expect(headers.count == 2, "Both the bare-title chapter and the real heading must surface as boundaries")
        #expect(
            headers.first?.isBibliography == false,
            "The EARLIER, bare-title heading must never be flagged -- old first-match-wins logic would have picked this one"
        )
        #expect(
            headers.last?.isBibliography == true,
            "The LATER, real heading (the one actually followed by entries and the terminator) must be flagged"
        )
        let bibliographyHeaders = headers.filter { $0.isBibliography }
        #expect(bibliographyHeaders.count == 1, "Exactly one boundary must be flagged isBibliography")
    }

    // MARK: - Case 10: injectBibliographyMarker selection

    @Test("injectBibliographyMarker selects the last anchored match before the terminator, not the first")
    @MainActor
    func injectBibliographyMarkerSelectsLastMatchBeforeTerminator() throws {
        let markdown = """
        # Bibliography

        Not the real one -- a user chapter that merely shares the title.

        # Bibliography

        Real entry one.

        \(BlockParser.bibliographyEndMarker)
        """
        let sections = [
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 0, headerLevel: 1, isBibliography: false,
                title: "Bibliography", markdownContent: "# Bibliography"
            )),
            SectionViewModel(from: Section(
                projectId: "test", sortOrder: 1, headerLevel: 1, isBibliography: true,
                title: "Bibliography", markdownContent: "# Bibliography"
            ))
        ]
        let syncService = SectionSyncService()

        let result = syncService.injectBibliographyMarker(markdown: markdown, sections: sections)

        #expect(
            !result.contains("<!-- ::auto-bibliography:: --># Bibliography\n\nNot the real one"),
            "Marker must not land on the earlier, bare-title heading"
        )
        #expect(
            result.contains("<!-- ::auto-bibliography:: --># Bibliography\n\nReal entry one."),
            "Marker must land on the last anchored match before the terminator -- the real, later heading"
        )
    }
}
