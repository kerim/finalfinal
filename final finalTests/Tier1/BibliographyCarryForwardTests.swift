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

    @Test("An intervening heading stops the carry before the terminator is reached")
    func headingStopsCarryBeforeTerminator() throws {
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
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader))
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."),
            "Rows before the intervening heading are carried"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "## Mid Chapter") == false,
            "The carry must never flag a heading"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry two.") == false,
            "The intervening heading disarms the carry; the later terminator must not resurrect it"
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
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader),
            "The heading flag survives, as it always did"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry one.") == false, "KNOWN LIMITATION — not repaired")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two.") == false, "KNOWN LIMITATION — not repaired")
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
