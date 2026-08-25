//
//  BibliographyOutlineSpanTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers -- `SectionSyncService.parseHeaders`'s marker branch used to be a
//  second, independent detection mechanism: ANY line prefixed
//  `<!-- ::auto-bibliography:: -->` latched `inAutoBibliography = true` unconditionally, and
//  the latch never reset. A leftover/orphan marker mid-document (left behind by CodeMirror's
//  Source Mode, which hides the marker as an invisible atomic decoration with no
//  delete-protection) therefore swallowed every heading for the rest of the document --
//  including a correctly-placed real bibliography -- silently dropping them from the sidebar
//  outline. These tests pin the fix: the marker branch now defers to the shared
//  `BibliographyOpeningSelector`-backed pre-scan (`selectedBibliographyOffset`), and the
//  managed span is bounded by `BlockParser.bibliographyEndMarker` exactly like the pre-scan's
//  own terminator gating.
//

import Testing
import Foundation
import GRDB
@testable import final_final

@Suite("parseHeaders -- bibliography span: orphan markers don't swallow the outline, terminator closes the span")
struct BibliographyOutlineSpanTests {

    @Test("An orphan marker mid-document (unsupported -- its next non-empty unit is not a candidate) does not swallow the real, later bibliography")
    func orphanMarkerMidDocumentDoesNotSwallowTheRealBibliography() throws {
        let markdown = """
        # Introduction

        Body prose about the introduction.

        \(BlockParser.bibliographyStartMarker)

        # Chapter Two

        Body prose about chapter two.

        # Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        #expect(
            headers.count == 3,
            "Introduction, Chapter Two, and Bibliography must all surface -- the orphan marker must not swallow anything"
        )
        #expect(
            headers.contains { $0.title == "Chapter Two" },
            "Chapter Two must survive the orphan marker unharmed"
        )
        let bibliographyHeaders = headers.filter { $0.isBibliography }
        #expect(bibliographyHeaders.count == 1, "Exactly one boundary must be flagged isBibliography")
        #expect(bibliographyHeaders.first?.title == "Bibliography")
    }

    @Test("""
    ANTI-REGRESSION: a supported marker (paired with its own heading, per markerIsSupported) still opens \
    the managed region and, with no terminator, truncates it unbounded-until-EOF exactly as before -- \
    existingBibTitle must be non-nil here, or this collapses into the orphan shape above instead of \
    exercising a genuinely supported marker
    """)
    func supportedMarkerStillOpensTheRegionViaTheSelector() throws {
        let markdown = """
        # Introduction

        Body prose about the introduction.

        \(BlockParser.bibliographyStartMarker)

        # Bibliography

        Smith, J. (2020). A Book.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        #expect(
            headers.count == 1,
            """
            Only Introduction surfaces: the supported marker opens the managed region (the pre-scan's tier 1 \
            selects the marker line itself, paired with the "# Bibliography" heading right after it), and with \
            no terminator the region never closes, absorbing the heading and its content until EOF -- unchanged \
            from before this fix.
            """
        )
        #expect(headers.first?.title == "Introduction")
    }

    @Test("A terminator closes the bibliography span, letting a later heading (Appendix) surface again")
    func terminatorClosesTheBibliographySpan() throws {
        let markdown = """
        # Introduction

        Body prose about the introduction.

        # Bibliography

        Smith, J. (2020). A Book.

        \(BlockParser.bibliographyEndMarker)

        # Appendix

        Body prose about the appendix.
        """

        let headers = SectionSyncService.parseHeaders(from: markdown, existingBibTitle: "Bibliography")

        #expect(
            headers.count == 3,
            "Introduction, Bibliography, and Appendix must all surface -- the terminator must reset the latch"
        )
        let appendix = try #require(headers.first { $0.title == "Appendix" })
        #expect(appendix.isBibliography == false)
        #expect(
            appendix.markdownContent.contains("Body prose about the appendix."),
            "Appendix's content must not be swallowed by the still-open bibliography span"
        )
    }
}
