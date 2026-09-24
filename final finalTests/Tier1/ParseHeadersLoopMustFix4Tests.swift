//
//  ParseHeadersLoopMustFix4Tests.swift
//  final finalTests
//
//  Split out of ParseHeadersLoopCharacterizationTests.swift to keep that file's struct body
//  under SwiftLint's type_body_length limit -- see the header comment there for the full
//  parseHeaders loop-characterization background. This file covers MUST-FIX 4 (same-titled
//  evidenced/unevidenced Notes headings judged independently of order), case G (a custom-title
//  heading with no footnote evidence beneath it), and case H (a real Bibliography and a real
//  Notes section in the same document, neither swallowing the other) -- using the shared
//  `offset(of:in:)` helper defined in ParseHeadersLoopCharacterizationTests.swift.
//

import Testing
import Foundation
@testable import final_final

extension ParseHeadersLoopCharacterizationTests {

    // MARK: - F. MUST-FIX 4: same-titled evidenced/unevidenced headings, independent of order

    /// Uses `existingNotesTitle: "Notes"` (the custom-title case) for both headings, since that
    /// is the real-world shape MUST-FIX 4 was found in: once a document already has a known
    /// Notes title, a second, later heading sharing that title must be evaluated against its
    /// OWN content, never against the first heading's already-confirmed verdict.
    @Test(
        """
        F1 (evidenced-then-unevidenced): an earlier evidenced Notes heading keeps isNotes == true when a later \
        same-titled heading has no evidence
        """
    )
    func sameTitledHeadingsEvidencedThenUnevidenced() {
        let markdown = """
        # Intro

        # Notes

        [^1]: A real footnote with genuine evidence.

        # Notes

        Some appendix content with no footnote evidence at all.
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

        let evidencedNotes = headers[1]
        let firstNotesOffset = offset(of: "# Notes", in: markdown)
        #expect(evidencedNotes.startOffset == firstNotesOffset)
        #expect(evidencedNotes.level == 1)
        #expect(evidencedNotes.title == "Notes")
        #expect(evidencedNotes.isPseudoSection == false)
        #expect(evidencedNotes.isBibliography == false)
        #expect(evidencedNotes.isNotes == true, "the earlier heading has real footnote evidence beneath it and must be flagged")

        let unevidencedNotes = headers[2]
        let secondNotesRange = markdown.range(of: "# Notes", options: .backwards)!
        #expect(unevidencedNotes.startOffset == markdown.distance(from: markdown.startIndex, to: secondNotesRange.lowerBound))
        #expect(unevidencedNotes.level == 1)
        #expect(unevidencedNotes.title == "Notes")
        #expect(unevidencedNotes.isPseudoSection == false)
        #expect(unevidencedNotes.isBibliography == false)
        #expect(
            unevidencedNotes.isNotes == false,
            """
            the later, same-titled heading has no footnote evidence beneath it and must stay unflagged -- it \
            must NOT un-flag the earlier, evidenced heading either
            """
        )
    }

    @Test(
        """
        F2 (unevidenced-then-evidenced): a later evidenced Notes heading is flagged true even when an earlier \
        same-titled heading has no evidence
        """
    )
    func sameTitledHeadingsUnevidencedThenEvidenced() {
        let markdown = """
        # Intro

        # Notes

        Some appendix content with no footnote evidence at all.

        # Notes

        [^1]: A real footnote with genuine evidence.
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

        let unevidencedNotes = headers[1]
        #expect(unevidencedNotes.startOffset == offset(of: "# Notes", in: markdown))
        #expect(unevidencedNotes.level == 1)
        #expect(unevidencedNotes.title == "Notes")
        #expect(unevidencedNotes.isPseudoSection == false)
        #expect(unevidencedNotes.isBibliography == false)
        #expect(
            unevidencedNotes.isNotes == false,
            "the earlier heading has no footnote evidence beneath it and must stay unflagged"
        )

        let evidencedNotes = headers[2]
        let secondNotesRange = markdown.range(of: "# Notes", options: .backwards)!
        #expect(evidencedNotes.startOffset == markdown.distance(from: markdown.startIndex, to: secondNotesRange.lowerBound))
        #expect(evidencedNotes.level == 1)
        #expect(evidencedNotes.title == "Notes")
        #expect(evidencedNotes.isPseudoSection == false)
        #expect(evidencedNotes.isBibliography == false)
        #expect(
            evidencedNotes.isNotes == true,
            """
            the later, same-titled heading has real footnote evidence beneath it and must be flagged -- the \
            earlier, unevidenced heading must NOT suppress it
            """
        )
    }

    // MARK: - G. custom-title case, NEGATIVE evidence: no footnote content beneath a matching heading

    @Test(
        """
        G: a heading matching a configured custom notes title, with NO footnote evidence beneath it, stays \
        unflagged and the rest of the document is intact
        """
    )
    func customTitleMatchWithoutEvidenceStaysUnflagged() {
        let markdown = """
        # Intro

        ## Endnotes

        No footnote content beneath this heading at all.

        <!-- ::break:: -->

        Final section text.
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

        let endnotes = headers[1]
        #expect(endnotes.startOffset == offset(of: "## Endnotes", in: markdown))
        #expect(endnotes.level == 2)
        #expect(endnotes.title == "Endnotes")
        #expect(endnotes.isPseudoSection == false)
        #expect(endnotes.isBibliography == false)
        #expect(
            endnotes.isNotes == false,
            """
            the heading matches the configured custom notes title but has no real footnote evidence beneath it, \
            so MUST-FIX 1's false-positive guard must keep it unflagged
            """
        )

        let pseudo = headers[2]
        #expect(pseudo.startOffset == offset(of: "<!-- ::break:: -->", in: markdown))
        #expect(
            pseudo.level == 1,
            """
            the custom-title case does not update lastActualHeaderLevel (the MUST-FIX-1 asymmetry pinned in \
            case B), so the break still inherits level 1 from "# Intro"
            """
        )
        #expect(pseudo.title == "§ Final section text.")
        #expect(pseudo.isPseudoSection == true)
        #expect(pseudo.isBibliography == false)
        #expect(pseudo.isNotes == false)
    }

    // MARK: - H. combined real Bibliography + real Notes in the same document

    @Test("H: a real Bibliography section and a real Notes section in the same document are both flagged correctly and neither swallows the other")
    func combinedBibliographyAndNotesSections() {
        let markdown = """
        # Introduction

        Some intro text.

        # References

        Entry one.

        \(BlockParser.bibliographyEndMarker)

        # Notes

        [^1]: A real footnote with genuine evidence.
        """

        let headers = SectionSyncService.parseHeaders(
            from: markdown,
            existingBibTitle: "References",
            existingNotesTitle: "Notes"
        )

        #expect(headers.count == 3)
        guard headers.count == 3 else { return }

        let intro = headers[0]
        #expect(intro.startOffset == offset(of: "# Introduction", in: markdown))
        #expect(intro.level == 1)
        #expect(intro.title == "Introduction")
        #expect(intro.isPseudoSection == false)
        #expect(intro.isBibliography == false)
        #expect(intro.isNotes == false)

        let references = headers[1]
        #expect(references.startOffset == offset(of: "# References", in: markdown))
        #expect(references.level == 1)
        #expect(references.title == "References")
        #expect(references.isPseudoSection == false)
        #expect(references.isBibliography == true, "the real, terminator-bounded bibliography heading must be flagged")
        #expect(references.isNotes == false)

        let notes = headers[2]
        #expect(notes.startOffset == offset(of: "# Notes", in: markdown))
        #expect(notes.level == 1)
        #expect(notes.title == "Notes")
        #expect(notes.isPseudoSection == false)
        #expect(notes.isBibliography == false)
        #expect(
            notes.isNotes == true,
            "the real, evidence-backed Notes heading must be flagged -- the bibliography branch being checked first must not swallow it"
        )
    }
}
