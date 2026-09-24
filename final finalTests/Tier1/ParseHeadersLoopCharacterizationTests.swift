//
//  ParseHeadersLoopCharacterizationTests.swift
//  final finalTests
//
//  Characterization tests for `SectionSyncService.parseHeaders`' main parsing loop, written
//  BEFORE a cyclomatic-complexity refactor (12 -> <=10) of that loop in
//  `SectionSyncService+Parsing.swift`. This loop has a documented history of THREE separate
//  MUST-FIX data-loss bugs from mishandled latch transitions (see that file's own inline
//  comments: MUST-FIX 1 on the `existingNotesTitle != nil` case of the merged
//  `header.title == notesHeaderName` branch, its mirror in the bibliography pre-scan, and
//  MUST-FIX 4, covered by Case F in ParseHeadersLoopMustFix4Tests.swift). These tests pin the loop's exact current behavior --
//  including a documented pre-existing ASYMMETRY (see case B below) -- so the refactor can be
//  verified to change zero behavior rather than accidentally re-introducing one of those bugs,
//  or silently "fixing" the asymmetry as an unintended side effect of a code-shape change.
//
//  Cases:
//  A. import-auto-detection Notes case (existingNotesTitle == nil): pseudo-section level
//     inherits from the auto-detected Notes heading; the Notes heading is confirmed via
//     footnote evidence beneath it.
//  B. custom-title Notes case (existingNotesTitle != nil, matching heading): PINS the
//     documented MUST-FIX-1 asymmetry -- this case does NOT update `lastActualHeaderLevel`,
//     unlike case A. This is a pre-existing asymmetry pinned as-is for the refactor's
//     sake, not endorsed as correct behavior -- a future deliberate fix to it is not a
//     regression against this test.
//  C. a heading that does NOT match the configured notes title is an ordinary heading: it
//     updates `lastActualHeaderLevel` normally and is never a Notes candidate, regardless of
//     footnote content beneath it.
//  D. code-fence gating: headings inside a fenced block (closed or left open) are invisible to
//     the parser.
//  E. `notesHeaderName` (the configured title), not the literal string "Notes", drives the
//     Notes-candidate match -- closes the gap a wrong merge hardcoding "Notes" would slip
//     through.
//  F. MUST-FIX 4: two headings sharing the same notes title, one with real footnote evidence
//     beneath it and one without, are confirmed/rejected independently of each other and of
//     document order -- a later same-titled heading with no evidence must never un-flag an
//     earlier one that has it, and an earlier same-titled heading with no evidence must never
//     prevent a later one that has it from being flagged.
//  G. custom-title case, NEGATIVE evidence: a heading matches a configured custom notes title
//     but has no footnote evidence beneath it -- it must stay unflagged, and the rest of the
//     document's boundaries must remain intact. This is exactly the false-positive shape
//     MUST-FIX 1 exists to prevent.
//  H. a real Bibliography section and a real Notes section in the same document, with both
//     `existingBibTitle` and `existingNotesTitle` set -- both must be flagged correctly
//     (isBibliography / isNotes respectively) and neither may swallow the other. The loop
//     checks the bibliography branch before the notes branch specifically so a colliding
//     header name configured for both can't wrongly exclude the real bibliography.
//

import Testing
import Foundation
@testable import final_final

@Suite("parseHeaders Loop Characterization (pre-refactor pin)")
struct ParseHeadersLoopCharacterizationTests {

    /// Returns the character offset (matching `ParsedHeader.startOffset`'s own counting scheme)
    /// of the first occurrence of `substring` in `markdown`, so expected offsets are derived
    /// from the same test markdown the assertions check against, rather than hand-counted.
    func offset(of substring: String, in markdown: String) -> Int {
        guard let range = markdown.range(of: substring) else {
            Issue.record("Expected to find \"\(substring)\" in test markdown")
            return -1
        }
        return markdown.distance(from: markdown.startIndex, to: range.lowerBound)
    }

    // MARK: - A. import auto-detection: pseudo-section inherits the auto-detected Notes level

    @Test(
        """
        A: existingNotesTitle nil -- pseudo-section inherits level 2 from the auto-detected \
        Notes heading, Notes heading confirmed by footnote evidence
        """
    )
    func importAutoDetectionNotesBranch() {
        let markdown = """
        # Intro

        Some intro text.

        ## Notes

        [^1]: A footnote with real evidence.

        <!-- ::break:: -->

        Final section text.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown)

        #expect(headers.count == 3)
        guard headers.count == 3 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Intro", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Intro")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)

        let notes = headers[1]
        #expect(notes.startOffset == offset(of: "## Notes", in: markdown))
        #expect(notes.level == 2)
        #expect(notes.title == "Notes")
        #expect(notes.isPseudoSection == false)
        #expect(notes.isBibliography == false)
        #expect(notes.isNotes == true, "the auto-detected Notes heading must be confirmed by the footnote evidence beneath it")

        let pseudo = headers[2]
        #expect(pseudo.startOffset == offset(of: "<!-- ::break:: -->", in: markdown))
        #expect(pseudo.level == 2, "pseudo-section level must inherit from the Notes heading (lastActualHeaderLevel was updated to 2)")
        #expect(pseudo.title == "§ Final section text.")
        #expect(pseudo.isPseudoSection == true)
        #expect(pseudo.isBibliography == false)
        #expect(pseudo.isNotes == false)
    }

    // MARK: - B. custom-title case: PINS the documented MUST-FIX-1 asymmetry (not a spec)

    /// This test PINS a documented, pre-existing behavioral ASYMMETRY -- it does not assert this
    /// is "correct" behavior. See `SectionSyncService+Parsing.swift`'s inline comment on the
    /// ternary inside the merged `header.title == notesHeaderName` branch: the
    /// `existingNotesTitle != nil` case (this test) deliberately does NOT update
    /// `lastActualHeaderLevel`, unlike the `existingNotesTitle == nil` import auto-detection
    /// case (case A above), when a heading matches an ALREADY-KNOWN notes title. If a future
    /// change deliberately fixes this asymmetry (making both cases update
    /// `lastActualHeaderLevel` the same way), this test's expected pseudo-section level of 1
    /// (below) will need to change too -- that is an intentional, reviewed behavior change, not
    /// a regression this test is meant to catch.
    @Test(
        """
        B: existingNotesTitle set (same document as A) -- pseudo-section stays at level 1, \
        pinning the documented MUST-FIX-1 asymmetry, not a behavioral spec
        """
    )
    func customTitleNotesBranchAsymmetryPin() {
        let markdown = """
        # Intro

        Some intro text.

        ## Notes

        [^1]: A footnote with real evidence.

        <!-- ::break:: -->

        Final section text.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingNotesTitle: "Notes")

        #expect(headers.count == 3)
        guard headers.count == 3 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Intro", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Intro")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)

        let notes = headers[1]
        #expect(notes.startOffset == offset(of: "## Notes", in: markdown))
        #expect(notes.level == 2)
        #expect(notes.title == "Notes")
        #expect(notes.isPseudoSection == false)
        #expect(notes.isBibliography == false)
        #expect(notes.isNotes == true, "the custom-title Notes heading is still confirmed by the footnote evidence beneath it")

        let pseudo = headers[2]
        #expect(pseudo.startOffset == offset(of: "<!-- ::break:: -->", in: markdown))
        #expect(
            pseudo.level == 1,
            """
            MUST-FIX-1 asymmetry pin: the custom-title branch does NOT update lastActualHeaderLevel, \
            so the pseudo-section still inherits level 1 from "# Intro", not level 2 from the Notes heading
            """
        )
        #expect(pseudo.title == "§ Final section text.")
        #expect(pseudo.isPseudoSection == true)
        #expect(pseudo.isBibliography == false)
        #expect(pseudo.isNotes == false)
    }

    // MARK: - C. non-matching title is an ordinary heading, never a Notes candidate

    @Test(
        """
        C: a heading not matching the configured notes title ("Endnotes") is ordinary -- \
        updates lastActualHeaderLevel, never flagged Notes even with footnote content beneath it
        """
    )
    func nonMatchingTitleIsOrdinaryHeading() {
        let markdown = """
        # Intro

        ## Notes

        [^1]: A footnote that must not confer Notes status here.

        <!-- ::break:: -->
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingNotesTitle: "Endnotes")

        #expect(headers.count == 3)
        guard headers.count == 3 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Intro", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Intro")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)

        let notes = headers[1]
        #expect(notes.startOffset == offset(of: "## Notes", in: markdown))
        #expect(notes.level == 2)
        #expect(notes.title == "Notes")
        #expect(notes.isPseudoSection == false)
        #expect(notes.isBibliography == false)
        #expect(
            notes.isNotes == false,
            "\"## Notes\" does not match the configured notes title \"Endnotes\", so it is ordinary regardless of the footnote content beneath it"
        )

        let pseudo = headers[2]
        #expect(pseudo.startOffset == offset(of: "<!-- ::break:: -->", in: markdown))
        #expect(
            pseudo.level == 2,
            "lastActualHeaderLevel must update to 2 from the ordinary \"## Notes\" heading, so the break inherits level 2"
        )
        #expect(pseudo.title == "§ Section Break", "no content follows the break marker, so the fallback title applies")
        #expect(pseudo.isPseudoSection == true)
        #expect(pseudo.isBibliography == false)
        #expect(pseudo.isNotes == false)
    }

    // MARK: - D. code-fence gating

    @Test("D1: a closed code fence hides the heading inside it from the parser")
    func codeFenceHidesHeadingWhenClosed() {
        let markdown = """
        # Intro

        ```swift
        # Hidden
        ```

        ## Real
        """

        let headers = SectionSyncService.parseHeaders(from: markdown)

        #expect(headers.count == 2)
        guard headers.count == 2 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Intro", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Intro")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)

        let real = headers[1]
        #expect(real.startOffset == offset(of: "## Real", in: markdown), "the fenced \"# Hidden\" heading must not be recognized")
        #expect(real.level == 2)
        #expect(real.title == "Real")
        #expect(real.isPseudoSection == false)
        #expect(real.isBibliography == false)
        #expect(real.isNotes == false)
    }

    @Test("D2: an unclosed code fence hides every heading after it for the rest of the document")
    func codeFenceHidesHeadingsWhenUnclosed() {
        let markdown = """
        # Intro

        ```
        # AlsoHidden
        """

        let headers = SectionSyncService.parseHeaders(from: markdown)

        #expect(headers.count == 1, "only headings before the unclosed fence may be recognized")
        guard headers.count == 1 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Intro", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Intro")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)
    }

    // MARK: - E. notesHeaderName (not the literal "Notes") drives the Notes-candidate match

    @Test(
        """
        E: the CONFIGURED notes title ("Endnotes"), not the literal string "Notes", determines \
        the Notes-candidate match
        """
    )
    func configuredNotesTitleDrivesMatchNotLiteralNotes() {
        let matchingMarkdown = """
        # Intro

        ## Endnotes

        [^1]: A footnote confirming Endnotes status.
        """
        let matchingHeaders = SectionSyncService.parseHeaders(from: matchingMarkdown, existingNotesTitle: "Endnotes")

        #expect(matchingHeaders.count == 2)
        if matchingHeaders.count == 2 {
            let intro = matchingHeaders[0]
            #expect(intro.startOffset == offset(of: "# Intro", in: matchingMarkdown))
            #expect(intro.level == 1)
            #expect(intro.title == "Intro")
            #expect(intro.isPseudoSection == false)
            #expect(intro.isBibliography == false)
            #expect(intro.isNotes == false)

            let endnotes = matchingHeaders[1]
            #expect(endnotes.startOffset == offset(of: "## Endnotes", in: matchingMarkdown))
            #expect(endnotes.level == 2)
            #expect(endnotes.title == "Endnotes")
            #expect(endnotes.isPseudoSection == false)
            #expect(endnotes.isBibliography == false)
            #expect(
                endnotes.isNotes == true,
                """
                "## Endnotes" must be flagged because it matches the CONFIGURED notesHeaderName ("Endnotes"), \
                even though it isn't literally titled "Notes"
                """
            )
        }

        let nonMatchingMarkdown = """
        # Intro

        ## Notes

        [^1]: A footnote that should not confer Endnotes status.
        """
        let nonMatchingHeaders = SectionSyncService.parseHeaders(from: nonMatchingMarkdown, existingNotesTitle: "Endnotes")

        #expect(nonMatchingHeaders.count == 2)
        if nonMatchingHeaders.count == 2 {
            let intro = nonMatchingHeaders[0]
            #expect(intro.startOffset == offset(of: "# Intro", in: nonMatchingMarkdown))
            #expect(intro.level == 1)
            #expect(intro.title == "Intro")
            #expect(intro.isPseudoSection == false)
            #expect(intro.isBibliography == false)
            #expect(intro.isNotes == false)

            let notes = nonMatchingHeaders[1]
            #expect(notes.startOffset == offset(of: "## Notes", in: nonMatchingMarkdown))
            #expect(notes.level == 2)
            #expect(notes.title == "Notes")
            #expect(notes.isPseudoSection == false)
            #expect(notes.isBibliography == false)
            #expect(
                notes.isNotes == false,
                """
                "## Notes" must NOT be flagged when notesHeaderName is configured as "Endnotes" -- a merge that \
                hardcoded the literal string "Notes" would wrongly flag this
                """
            )
        }
    }
}
