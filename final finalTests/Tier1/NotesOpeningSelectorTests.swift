//
//  NotesOpeningSelectorTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- Stage C (t-7f7e6ed2 / t-mtianjujt9ub, "notes-heading-scanner-unify").
//  Covers the plan's Test Discipline T8 scenarios for the shared `NotesOpeningSelector`: title
//  collision with Bibliography, a Notes-titled heading inside a fenced code block, two separate
//  Notes runs, an evidence-free Notes-titled heading, the DB-derived-title (renamed) branch, and
//  the both-evidenced tie (first-in-document-order).
//

import Testing
import Foundation
@testable import final_final

@Suite("NotesOpeningSelector -- title + evidence rule, multi-run, deterministic tie")
struct NotesOpeningSelectorTests {

    // MARK: - Title collision with Bibliography

    @Test("A heading titled 'Bibliography' is never selected as a Notes opening, even with evidence-shaped content beneath it")
    func bibliographyTitledHeadingNeverSelectedAsNotes() throws {
        // `adoptUnflaggedNotesContinuations` already excludes isBibliography-flagged ROWS from
        // Notes adoption (Reconciliation.swift's dual-flag exclusion) -- but that guard operates
        // on the `Block.isBibliography` FLAG, which `NotesOpeningSelector` itself has no concept
        // of at all (it is a pure text+evidence selector). This test proves the selector-level
        // half of the same invariant directly: a heading whose TITLE is "Bibliography" is never
        // a Notes candidate in the first place, regardless of what evidence-shaped content
        // follows it -- title equality alone rules it out, before evidence is ever consulted.
        let markdown = """
        # Bibliography

        [^1]: An entry that happens to be styled like a footnote definition.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let heading = try #require(blocks.first { $0.blockType == .heading })
        #expect(heading.textContent == "Bibliography")
        #expect(heading.isNotes == false, "A 'Bibliography'-titled heading must never be selected as a Notes opening")
    }

    // MARK: - Notes-titled heading inside a fenced code block

    @Test("A '## Notes'-shaped line inside a fenced code block is never selected -- it is code sample text, not a real heading")
    func notesHeadingInsideFencedCodeBlockIsNeverSelected() throws {
        let markdown = """
        # Chapter

        Here is an example of how to write a Notes section:

        ```markdown
        ## Notes

        [^1]: like this.
        ```

        More prose after the example.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        #expect(
            blocks.first { $0.blockType == .heading && $0.textContent == "Notes" } == nil,
            "The fenced '## Notes' text must not even be classified as a heading block"
        )
        #expect(
            !blocks.contains { $0.isNotes },
            "Nothing in this document is real Notes content -- the whole thing is inside one code-fence block"
        )

        // Cross-check the line-based scanners too (BlockParser's raw-block tokenizer is
        // naturally fence-safe -- a fence is one opaque raw block -- but `stripNotesSection`/
        // `pushDefinitionsToEditor` scan line-by-line and must track fence state explicitly;
        // see their own doc comments for the bug this guards against).
        let stripped = FootnoteSyncService.stripNotesSection(from: markdown)
        #expect(stripped == markdown, "stripNotesSection must leave the document untouched -- nothing real was recognized")
    }

    // MARK: - Two separate Notes runs

    @Test("Two independent, evidence-backed Notes runs are both selected -- not fused, not overwritten by each other")
    func twoSeparateNotesRunsAreBothSelected() throws {
        let markdown = """
        # Part One

        Some prose[^1].

        ## Notes

        [^1]: First run's definition.

        # Part Two

        More prose[^2].

        ## Notes

        [^2]: Second run's definition.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let notesHeadings = blocks.filter { $0.blockType == .heading && $0.textContent == "Notes" }
        #expect(notesHeadings.count == 2, "Both '## Notes' headings must exist as separate blocks")
        #expect(notesHeadings.allSatisfy { $0.isNotes }, "Both independent runs must be selected")

        let def1 = try #require(blocks.first { $0.markdownFragment.contains("First run's definition") })
        let def2 = try #require(blocks.first { $0.markdownFragment.contains("Second run's definition") })
        #expect(def1.isNotes, "The first run's own definition must be flagged")
        #expect(def2.isNotes, "The second run's own definition must be flagged")
    }

    // MARK: - Evidence-free Notes-titled heading

    @Test("A '## Notes'-titled heading with no real footnote evidence beneath it is never selected")
    func evidenceFreeNotesHeadingIsNeverSelected() throws {
        let markdown = """
        # Chapter

        Body prose with no footnote references at all.

        ## Notes

        Just some closing remarks the user wrote -- not a single footnote definition.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1")

        let heading = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Notes" })
        #expect(heading.isNotes == false, "Title match alone, with no evidence, must never select the heading")
        #expect(
            blocks.first { $0.markdownFragment.contains("closing remarks") }?.isNotes == false,
            "The prose beneath an unselected heading must stay unflagged too"
        )
    }

    // MARK: - DB-derived-title (renamed) branch

    @Test("A DB-resolved, non-default Notes header name is recognized -- C2's title mechanism, no live rename UI assumed")
    func dbDerivedNonDefaultTitleIsRecognized() throws {
        // C2's scope, stated explicitly: `fetchNotesHeadingTitle` makes the TITLE MECHANISM
        // correct once a section is already recognized -- it does NOT assume any Notes-heading-
        // rename UI exists (none does; see bt t-412c9fab, logged as deferred). This test
        // constructs the DB STATE such a mechanism would produce (an already-flagged heading
        // whose stored title differs from the literal default "Notes") directly via
        // `BlockParser.parse`'s `notesHeaderName` parameter -- exactly how `SnapshotService`/
        // `BlockSyncService`/etc. thread `fetchNotesHeadingTitle`'s result today (see those
        // call sites' own C5 comments) -- rather than assuming any UI path that types a
        // different name into a heading and renames the section live.
        let markdown = """
        # Chapter

        A reference[^1].

        ## Endnotes

        [^1]: The real text, under a non-default recognized title.
        """
        let blocks = BlockParser.parse(markdown: markdown, projectId: "p1", notesHeaderName: "Endnotes")

        let heading = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Endnotes" })
        #expect(heading.isNotes == true, "The DB-resolved title 'Endnotes' must be recognized as the Notes heading")
        #expect(
            blocks.first { $0.markdownFragment.contains("The real text") }?.isNotes == true,
            "Its definition must be recognized too"
        )

        // Without the explicit override, the SAME document is never recognized -- the literal
        // default "Notes" doesn't match "Endnotes", proving this genuinely depends on the
        // threaded title rather than some broader fallback.
        let withoutOverride = BlockParser.parse(markdown: markdown, projectId: "p1")
        #expect(
            withoutOverride.first { $0.blockType == .heading }?.isNotes == false,
            "Without the DB-resolved title, 'Endnotes' must not be recognized by the literal default"
        )
    }

    // MARK: - Both-evidenced tie: first-in-document-order wins

    @Test("When two Notes-titled headings both carry evidence, NotesOpeningSelector.primaryOpening picks the first in document order -- never a level heuristic")
    func bothEvidencedTiePicksFirstInDocumentOrder() throws {
        // Deliberately gives the SECOND heading the "stronger" level (H1) and the FIRST heading
        // the "weaker" one (H2), so a level-based heuristic (e.g. "prefer H1") would pick the
        // WRONG (second) heading -- only first-in-document-order picks correctly here. See
        // `NotesOpeningSelector`'s own doc comment, "WHY NO LEVEL HEURISTIC FOR THE TIE".
        let units: [NotesOpeningSelector.Unit] = [
            NotesOpeningSelector.Unit(isCandidateHeading: true, isAnyHeading: true, isEvidence: false),  // 0: ## Notes (first)
            NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: true), // 1: [^1]: evidence for the first
            NotesOpeningSelector.Unit(isCandidateHeading: true, isAnyHeading: true, isEvidence: false),  // 2: # Notes (second, stronger level)
            NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: true)  // 3: [^2]: evidence for the second
        ]

        let openings = NotesOpeningSelector.select(units)
        #expect(openings == [0, 2], "Both headings are independently confirmed -- this is not itself a conflict")

        let primary = NotesOpeningSelector.primaryOpening(units)
        #expect(primary == 0, "The FIRST confirmed opening wins, regardless of the second heading's stronger level")
    }

    // MARK: - `select` and `hasEvidence` agree at the boundary

    @Test("hasEvidence stops scanning at the next heading -- evidence after a later heading does not count for an earlier candidate")
    func hasEvidenceStopsAtNextHeading() throws {
        let units: [NotesOpeningSelector.Unit] = [
            NotesOpeningSelector.Unit(isCandidateHeading: true, isAnyHeading: true, isEvidence: false),   // 0: ## Notes
            NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: false), // 1: unrelated prose, no evidence
            NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: true, isEvidence: false),  // 2: ## Unrelated heading
            NotesOpeningSelector.Unit(isCandidateHeading: false, isAnyHeading: false, isEvidence: true)   // 3: [^1]: evidence, but past the boundary
        ]

        #expect(
            NotesOpeningSelector.select(units).isEmpty,
            "Evidence appearing after an intervening heading must not confirm the earlier candidate"
        )
    }
}
