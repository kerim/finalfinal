//
//  BibliographyCarryForwardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers — bibliography carry-forward core mechanism.
//
//  See `BibliographyCarryForwardTestSupport.swift` for the shared fixtures/helpers, and for the
//  full explanation of the bug this fix addresses (applyPreservedHeading restoring
//  isBibliography onto a HEADING but never onto the entry rows beneath it) and the
//  carry-forward fix itself.
//
//  This file covers the mechanism's core behavior: when the carry fires, what bounds it (the
//  next heading, the terminator marker, or the budget), and where the terminator marker's
//  literal text is or isn't a real boundary. `BibliographyCarryForwardRegressionTests.swift`
//  covers idempotency, isolation from other replaceBlocks paths, and the multi-section case.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Carry-Forward — Tier 1: Silent Killers")
struct BibliographyCarryForwardTests {

    @Test("Entries under a heading parse() cannot recognise are re-flagged on reparse")
    func carriesFlagForwardOntoEntriesWhenParseMissesTheHeading() throws {
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
        #expect(after.count == 5, "Intro, body, heading, two entries — the terminator emits no Block")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader),
            "The heading is re-flagged by applyPreservedHeading's title match"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."),
            "Entry one must be re-flagged by the carry-forward"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry two."),
            "Entry two must be re-flagged by the carry-forward"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Body prose.") == false,
            "Prose above the heading must never be flagged"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# Intro") == false,
            "An unrelated heading must never be flagged"
        )
    }

    @Test("An intervening heading before the terminator now suppresses the restore itself, not just the carry (bib-heading-false-positive follow-up)")
    func interveningHeadingSuppressesRestoreBeforeTerminatorIsReached() throws {
        // Pre-Correction-1 behavior (still documented here for context): `hasGenuineBibliographyRun`
        // only checked the block IMMEDIATELY after the heading (not itself a heading), so the
        // restore gate armed regardless of "## Mid Chapter" sitting later in the same run --
        // `carryBibliographyFlagForward`'s OWN loop then independently stopped at that interior
        // heading, carrying "Entry one." but not "Entry two.". Since `hasGenuineBibliographyRun`
        // now scans the WHOLE run for an interior heading (matching
        // `BibliographyOpeningSelector`'s tier 2), the restore gate itself refuses to arm here --
        // the heading's own stale flag is not resurrected either, so nothing downstream of it
        // ever gets a chance to be carried.
        let content = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        ## Mid Chapter

        Entry two.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [BibliographyCarryForwardSupport.syntheticHeader, "Entry one.", "Entry two."]
        )

        try BibliographyCarryForwardSupport.roundTrip(db, projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 4)
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader) == false,
            "The interior heading invalidates the whole run, so the heading's own stale flag is no longer restored"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one.") == false,
            "With the heading's flag never restored, there is nothing to carry forward onto Entry one either"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "## Mid Chapter") == false,
            "The carry must never flag a heading"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry two.") == false,
            "The intervening heading disarms the restore entirely; the later terminator must not resurrect any of it"
        )
    }

    @Test("A second, downstream terminator does not extend the run over user prose")
    func strayDownstreamTerminatorDoesNotExtendTheRun() throws {
        let content = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [BibliographyCarryForwardSupport.syntheticHeader, "Entry one.", "Entry two."]
        )

        let doctored = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        \(BlockParser.bibliographyEndMarker)

        Trailing user note.

        \(BlockParser.bibliographyEndMarker)
        """
        try db.replaceBlocks(BlockParser.parse(markdown: doctored, projectId: projectId), for: projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 3, "Two terminators emit no Blocks of their own")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader))
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."))
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Trailing user note.") == false,
            "The run must end at the FIRST terminator after the heading, not the last one in the document"
        )
    }

    @Test("The carry never flags more rows than the project already had flagged entries")
    func budgetCapsTheCarry() throws {
        let content = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.

        Entry three.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [BibliographyCarryForwardSupport.syntheticHeader, "Entry one."]
        )

        let doctored = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.

        Entry three.

        \(BlockParser.bibliographyEndMarker)
        """
        try db.replaceBlocks(BlockParser.parse(markdown: doctored, projectId: projectId), for: projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 4)
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."), "The one row the budget allows")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two.") == false, "Budget exhausted after one row")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry three.") == false, "Budget exhausted after one row")
    }

    @Test("A document already in the damaged state is deliberately NOT repaired")
    func alreadyDamagedDocumentIsNotRepaired() throws {
        let content = """
        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [BibliographyCarryForwardSupport.syntheticHeader]
        )

        try BibliographyCarryForwardSupport.roundTrip(db, projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 3)
        // t-341706cb round 8: `applyPreservedHeading`'s restore gate now ALSO requires a
        // genuine, non-empty, terminator-bounded run beneath the heading (see
        // `hasGenuineBibliographyRun`'s doc comment on `Database+BlocksReplace+Preservation.swift`) — not
        // just `!parseFoundBibliographyHeading` alone, as before. In this exact damaged shape
        // (heading flagged, entries not), `assembleMarkdownForEditor` never even emits a
        // terminator at all (the LAST block, "Entry two.", isn't flagged, so there is nothing
        // to bound a run on), so `bibliographyRunEnd` finds none and the heading's OWN stale
        // flag is now suppressed too, not just the entries'. This is the intentional,
        // documented consequence disclosed on `BibliographyOpeningSelector`'s "DISCLOSED
        // CONSEQUENCES" #3: an already-damaged document stays exactly as damaged (now
        // uniformly unflagged, rather than a heading-flagged/entries-unflagged split state) —
        // visible and fixable by the user, never silently repaired past this the wrong way.
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader) == false,
            "KNOWN LIMITATION, round 8 revision — the heading's stale flag is no longer resurrected without a genuine run either"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry one.") == false, "KNOWN LIMITATION — not repaired")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two.") == false, "KNOWN LIMITATION — not repaired")
    }

    @Test("An interior heading between a stale-flagged heading and the terminator suppresses the restore, even though it is not the block immediately after the heading")
    func interiorHeadingSuppressesRestoreEvenWhenNotImmediatelyNext() throws {
        // Simulates the pre-existing damaged state directly: the user's own "Bibliography"
        // heading already carries a stale isBibliography flag from an earlier (pre-fix) parse
        // that wrongly selected it -- exactly the state a document left over from before this
        // whole fix landed would be in. Nothing else is flagged.
        let content = """
        # Bibliography

        Prose the user wrote under their own Bibliography heading.

        # Notes

        Notes prose.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: ["# Bibliography"]
        )

        // Reparse markdown carrying a stranded terminator after the interior "# Notes" section
        // -- the shape produced when the user backspaces away the real, machine-managed
        // bibliography further down the document, leaving their own heading and the unrelated
        // "Notes" section above the leftover terminator. `BlockParser.parse` sets
        // `endsBibliographyRun` on "Notes prose." regardless of any isBibliography flag, so a
        // terminator-bounded run exists in `[Block]` terms even though nothing in it is flagged
        // yet -- and, with the fixed `BibliographyOpeningSelector`, the fresh parse itself also
        // recognises nothing here (the interior "# Notes" heading invalidates the run), so
        // `parseFoundBibliographyHeading` is false and the restore gate is actually reached.
        let reparseMarkdown = """
        # Bibliography

        Prose the user wrote under their own Bibliography heading.

        # Notes

        Notes prose.

        \(BlockParser.bibliographyEndMarker)
        """
        try db.replaceBlocks(BlockParser.parse(markdown: reparseMarkdown, projectId: projectId), for: projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# Bibliography") == false,
            """
            Before this fix: hasGenuineBibliographyRun only checked the block IMMEDIATELY after \
            the heading (the user's own prose, not a heading) and returned true, so \
            applyPreservedHeading resurrected the stale flag onto the user's own heading even \
            though a real, unrelated heading ("# Notes") sits inside the same run before the \
            terminator. The fix scans the WHOLE run for an interior heading, matching \
            BibliographyOpeningSelector's own tier-2 rule, so the stale flag must stay dropped \
            instead of being resurrected on every reparse -- the user's actual already-damaged \
            document must heal, not just fresh documents.
            """
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Prose the user wrote under their own Bibliography heading.") == false,
            "The user's own prose under their own heading must never be flagged"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# Notes") == false,
            "The unrelated interior heading must never be flagged"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Notes prose.") == false,
            "The unrelated interior heading's prose must never be flagged"
        )
    }

    @Test("A restored isNotes heading does NOT carry its flag forward")
    func notesIsNotCarriedForward() throws {
        let content = """
        ## Notes

        [^1]: A footnote body.
        """
        let db = try TestFixtureFactory.createTemporary(content: content)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        try db.replaceBlocks(BlockParser.parse(markdown: content, projectId: projectId), for: projectId)
        try db.write { database in
            for var row in try Block
                .filter(Block.Columns.projectId == projectId)
                .fetchAll(database) where row.markdownFragment.contains("## Notes") {
                row.isNotes = true
                try row.update(database)
            }
        }

        try BibliographyCarryForwardSupport.roundTrip(db, projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        let footnote = try #require(after.first { $0.markdownFragment.contains("[^1]:") })
        #expect(footnote.isNotes == false, "Deliberate: no Notes terminator exists to bound a carry")
        #expect(footnote.isBibliography == false)
    }

    @Test("A terminator as the very first raw block sets no flag and does not crash")
    func terminatorAsFirstBlockIsSafe() {
        let parsed = BlockParser.parse(
            markdown: "\(BlockParser.bibliographyEndMarker)\n\nText after.",
            projectId: "p"
        )
        #expect(parsed.count == 1, "The terminator itself emits no Block")
        #expect(parsed[0].markdownFragment == "Text after.")
        #expect(parsed[0].endsBibliographyRun == false, "There was no preceding block to flag")
        #expect(parsed[0].isBibliography == false)
    }

    @Test("Two adjacent terminators flag exactly one block, idempotently")
    func adjacentTerminatorsAreIdempotent() {
        let markdown = """
        Entry one.

        \(BlockParser.bibliographyEndMarker)

        \(BlockParser.bibliographyEndMarker)
        """
        let parsed = BlockParser.parse(markdown: markdown, projectId: "p")
        #expect(parsed.count == 1)
        #expect(parsed.filter { $0.endsBibliographyRun }.count == 1)
        #expect(parsed[0].endsBibliographyRun)
    }

    @Test("The marker's literal text inside a fenced code block is not a real boundary")
    func markerInsideFencedCodeIsNotABoundary() throws {
        let markdown = """
        Before the sample.

        ```
        \(BlockParser.bibliographyEndMarker)
        ```

        After the sample.
        """
        let parsed = BlockParser.parse(markdown: markdown, projectId: "p")
        let fence = try #require(parsed.first { $0.blockType == .codeBlock }, "The fence must survive as one code block")
        #expect(
            fence.markdownFragment.contains(BlockParser.bibliographyEndMarker),
            "The quoted marker text must be preserved verbatim inside the sample"
        )
        #expect(
            parsed.allSatisfy { !$0.endsBibliographyRun },
            "A quoted marker inside a code sample must never become a real boundary"
        )
        #expect(parsed.contains { $0.markdownFragment == "After the sample." })
    }
}
