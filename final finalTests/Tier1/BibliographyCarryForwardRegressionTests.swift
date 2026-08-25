//
//  BibliographyCarryForwardRegressionTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers — bibliography carry-forward regression pins.
//
//  See `BibliographyCarryForwardTestSupport.swift` for the shared fixtures/helpers, and for the
//  full explanation of the bug this fix addresses and the carry-forward fix itself.
//  `BibliographyCarryForwardTests.swift` covers the carry-forward mechanism's core behavior.
//
//  This file covers: round-trip idempotency; that the transient `endsBibliographyRun` marker
//  is never persisted; that a heading BlockParser.parse() already recognises never arms the
//  carry (both directly through parse() and end-to-end through replaceBlocks); that the
//  preservingMachineManagedBlocks: true branch is untouched by this fix; and that two
//  independently-mismatched bibliography sections in one document both carry correctly.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("Bibliography Carry-Forward — Tier 1: Silent Killers (regression)")
struct BibliographyCarryForwardRegressionTests {

    @Test("Two consecutive assemble/parse/replace cycles converge")
    func roundTripIsIdempotent() throws {
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

        try BibliographyCarryForwardSupport.roundTrip(db, projectId)
        let firstPass = try BibliographyCarryForwardSupport.blocks(db, projectId)
        let secondMarkdown = try BibliographyCarryForwardSupport.roundTrip(db, projectId)
        let secondPass = try BibliographyCarryForwardSupport.blocks(db, projectId)

        #expect(firstPass.count == secondPass.count, "Block count must be stable across cycles")
        #expect(
            firstPass.map(\.isBibliography) == secondPass.map(\.isBibliography),
            "Flags must be stable across cycles — convergence, not oscillation"
        )
        #expect(
            firstPass.map(\.markdownFragment) == secondPass.map(\.markdownFragment),
            "Fragments must be stable across cycles"
        )
        #expect(
            secondMarkdown.components(separatedBy: BlockParser.bibliographyEndMarker).count - 1 == 1,
            "Exactly one terminator — never a duplicate accumulating per cycle"
        )
    }

    @Test("endsBibliographyRun is never persisted and never read back")
    func transientFlagIsNotPersisted() throws {
        let db = try TestFixtureFactory.createTemporary()
        let projectId = try TestFixtureFactory.getProjectId(from: db)

        let columns: [String] = try db.read { database in
            try Row.fetchAll(database, sql: "PRAGMA table_info(block)").map { $0["name"] }
        }
        #expect(
            !columns.contains("endsBibliographyRun"),
            """
            endsBibliographyRun must stay out of Block.Columns/CodingKeys — a future Codable \
            refactor turning it into a real column is exactly what this guards
            """
        )

        var block = Block(projectId: projectId, sortOrder: 999, blockType: .paragraph, markdownFragment: "Transient probe.")
        block.endsBibliographyRun = true
        try db.write { database in try block.insert(database) }

        let readBack = try #require(
            try BibliographyCarryForwardSupport.blocks(db, projectId).first { $0.markdownFragment == "Transient probe." }
        )
        #expect(readBack.endsBibliographyRun == false, "A row fetched from the database always has the flag false")
    }

    @Test(
        """
        A standalone marker followed by a non-matching heading, with no terminator, is an \
        unsupported orphan and flags nothing
        """
    )
    func recognisedHeadingNeedsNoCarry() throws {
        let content = """
        <!-- ::auto-bibliography:: -->

        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Trailing user note.
        """
        let parsed = BlockParser.parse(markdown: content, projectId: "p")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(parsed, "auto-bibliography") == false,
            "The marker block itself is not flagged"
        )
        // This fixture is a standalone marker (nothing glued to it, i.e. it sits on its own
        // line/unit) immediately followed by a heading that is NOT a recognised
        // bibliography-title candidate — a synthetic/unrecognised heading — with no terminator
        // anywhere in the content. That is exactly the orphan shape the later orphan-marker fix
        // (this same task, a follow-up round after the one this comment originally referenced)
        // now correctly excludes from tier 1:
        // `BibliographyOpeningSelector.markerIsSupported` treats a standalone marker as
        // supported only when the next non-empty unit is a bibliography-title candidate, and
        // the synthetic heading used here deliberately isn't one. So tier 1 no longer selects
        // this marker. Tier 2 needs a terminator to select a candidate heading, and this content
        // has none, so tier 2 also returns nothing. Nothing opens the section anywhere in this
        // document — not the marker block, not the heading, not the entries, not the trailing
        // note. This test still calls `parse()` directly rather than `replaceBlocks`, so the
        // 097e4ba1 carry-forward machinery never runs here — that part of the original
        // reasoning is unaffected by the orphan-marker fix.
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(parsed, BibliographyCarryForwardSupport.syntheticHeader) == false,
            "The non-matching heading is unflagged — nothing opens the section for it to close"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(parsed, "Entry one.") == false,
            "Nothing opens the section, so entries are never flagged either"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(parsed, "Trailing user note.") == false)
    }

    // MARK: - M1 regression: healthy, parser-recognised headings must never arm the carry

    @Test(
        """
        A heading BlockParser.parse() recognises on its own, through replaceBlocks end-to-end, \
        needs no carry-forward help (regression pin for the mismatch-only arming guard)
        """
    )
    func healthyRecognisedHeadingThroughReplaceBlocksNeedsNoCarry() throws {
        let content = """
        # Intro

        Body prose.

        # References

        Entry one.

        Entry two.

        \(BlockParser.bibliographyEndMarker)
        """
        // No manual flagging: BlockParser.parse() recognises the built-in "References" title
        // on its own, so the heading and its entries are already correctly flagged before this
        // test ever touches them — unlike every other test in this file, which relies on
        // `flag()` to simulate a heading title parse() can't recognise.
        //
        // t-341706cb round 8: this content now carries an explicit terminator, which it didn't
        // need to before. Tier 3 ("no marker, no terminator -> last/only title match still
        // wins") is deleted outright by round 8 -- without a terminator here,
        // `BibliographyOpeningSelector` would now select NOTHING for this content, and this
        // test's own premise (parse() recognises "References" ON ITS OWN, with no help) would
        // no longer hold. The terminator restores tier 2 (terminator-bounded, genuine
        // non-empty run) as the evidence parse() recognises the heading by -- the actual thing
        // this test exists to pin (that a HEALTHY, parser-recognised heading needs no
        // carry-forward help) is unaffected by which tier supplied that recognition.
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(content: content, flagged: [])

        let before = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "# References"), "parse() recognises \"References\" directly")
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "Entry one."))
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "Entry two."))

        try BibliographyCarryForwardSupport.roundTrip(db, projectId)

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 5, "Intro, body, heading, two entries — unchanged by the round trip")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# References"),
            "Still flagged — parse() re-derives this directly on every reparse"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."),
            "Still flagged — with no help from carryBibliographyFlagForward, which must never arm on a healthy heading"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two."))
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Body prose.") == false,
            "Prose above the heading must never be flagged"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# Intro") == false,
            "An unrelated heading must never be flagged"
        )
    }

    // MARK: - M4 regression: the preservingMachineManagedBlocks: true branch is untouched

    @Test(
        """
        preservingMachineManagedBlocks: true stays on its own preservation path, unaffected by \
        this task's carry-forward (which only ever runs on the default false path)
        """
    )
    func preservingMachineManagedBlocksPathIsUnaffected() throws {
        // t-341706cb round 8: carries an explicit terminator for the same reason as
        // healthyRecognisedHeadingThroughReplaceBlocksNeedsNoCarry above -- with tier 3
        // deleted, parse() needs terminator-bounded evidence to recognise "References" on
        // its own; this test's premise (the heading and entries start out flagged before the
        // preservingMachineManagedBlocks: true branch is ever exercised) depends on that.
        let content = """
        # Intro

        Body prose.

        # References

        Entry one.

        Entry two.

        \(BlockParser.bibliographyEndMarker)
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(content: content, flagged: [])

        let before = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(before.count == 5)
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "# References"))
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "Entry one."))
        #expect(try BibliographyCarryForwardSupport.isFlagged(before, "Entry two."))

        // Simulate a section-restore call site: `blocks` here has bibliography content
        // excluded entirely (rebuildContentFromSections filters it out before re-parsing —
        // see replaceBlocks' own doc comment). Passing only the non-bibliography prose with
        // preservingMachineManagedBlocks: true must leave the existing bibliography heading +
        // entries alone via that branch's own preserved-row mechanism — carryBibliographyFlagForward
        // never runs on this path at all.
        let nonBibliographyOnly = """
        # Intro

        Body prose, edited.
        """
        try db.replaceBlocks(
            BlockParser.parse(markdown: nonBibliographyOnly, projectId: projectId),
            for: projectId,
            preservingMachineManagedBlocks: true
        )

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 5, "Intro, edited body, heading, two entries — the bibliography survives untouched")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# References"),
            "The bibliography heading is preserved by this branch's own mechanism"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."), "Preserved bibliography entries are untouched")
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two."))
        #expect(
            after.contains { $0.markdownFragment == "Body prose, edited." },
            "The non-bibliography content is still replaced normally"
        )
    }

    // MARK: - M2: multi-section carry, only the last section is genuinely terminator-bounded

    @Test(
        """
        Two independently-mismatched bibliography sections in one document both carry \
        correctly, even though only the last is genuinely terminator-bounded
        """
    )
    func twoMismatchedSectionsBothCarryCorrectly() throws {
        let content = """
        # Intro

        Body prose.

        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown)

        Entry one.

        Entry two.

        \(BibliographyCarryForwardSupport.syntheticHeadingMarkdown2)

        Entry three.

        Entry four.
        """
        let (db, projectId) = try BibliographyCarryForwardSupport.seed(
            content: content,
            flagged: [
                BibliographyCarryForwardSupport.syntheticHeader, BibliographyCarryForwardSupport.syntheticHeader2,
                "Entry one.", "Entry two.", "Entry three.", "Entry four."
            ]
        )

        let markdown = try BibliographyCarryForwardSupport.roundTrip(db, projectId)
        #expect(
            markdown.components(separatedBy: BlockParser.bibliographyEndMarker).count - 1 == 1,
            "assembleMarkdownForEditor emits exactly one terminator per document, after the last flagged row"
        )

        let after = try BibliographyCarryForwardSupport.blocks(db, projectId)
        #expect(after.count == 8, "Intro, body, two headings, four entries — the terminator emits no Block")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader),
            "First heading re-flagged by applyPreservedHeading's title match"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, BibliographyCarryForwardSupport.syntheticHeader2),
            "Second heading re-flagged by applyPreservedHeading's title match"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry one."),
            """
            First section's entries are carried forward, falling back to the next-heading bound \
            — the document's one terminator sits past this section, not right after it
            """
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry two."), "First section's entries carried forward")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Entry three."),
            "Second section is genuinely terminator-bounded — the document's one terminator sits right after it"
        )
        #expect(try BibliographyCarryForwardSupport.isFlagged(after, "Entry four."), "Second section's entries carried forward")
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "Body prose.") == false,
            "Prose above both headings must never be flagged"
        )
        #expect(
            try BibliographyCarryForwardSupport.isFlagged(after, "# Intro") == false,
            "An unrelated heading must never be flagged"
        )
    }
}
