//
//  BibliographyBareTitleCurativeFixAndTerminatorTests.swift
//  final finalTests
//
//  Split out of BibliographyBareTitleSelectionTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full bare-title
//  selection background. This file covers the replaceBlocks curative-fix cases (Cases 5b-6:
//  the real assembleMarkdownForEditor round trip, and its non-interference with the existing
//  carry-forward fix), the parseHeaders terminator-bound cases (Cases 9-9b), and
//  injectBibliographyMarker's last-anchored-match selection (Case 10) -- all of which turn on
//  the same terminator (`BlockParser.bibliographyEndMarker`) correctly bounding which heading
//  counts as the real, machine-managed bibliography boundary. The insert-path adoption/marker
//  cases (Cases 7-8) that used to live here moved to BibliographyBareTitleInsertPathTests.swift.
//

import Testing
import Foundation
import GRDB
@testable import final_final

extension BibliographyBareTitleSelectionTests {

    // MARK: - Case 5b: replaceBlocks curative fix via the real assembleMarkdownForEditor round-trip

    @Test("replaceBlocks curative fix drops a stale false-positive flag via the real assembleMarkdownForEditor -> parse -> replaceBlocks path")
    func replaceBlocksCurativeFixDropsStaleFalsePositiveViaAssembleRoundTrip() throws {
        // Unlike Case 5 (BibliographyBareTitleSelectionTests.swift's
        // replaceBlocksCurativeFixSuppressesStaleFalsePositiveWithoutTerminator, which feeds a
        // hand-typed markdown string straight to BlockParser.parse), this variant goes through
        // the real production shape for the default replaceBlocks path: assembleMarkdownForEditor(blocks) -> parse ->
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

    @Test(
        """
        parseHeaders (reversed shape): a bare-title heading above the real bibliography does not steal the flag -- \
        the later, real heading is flagged
        """
    )
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
