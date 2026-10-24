//
//  MarkdownManagedRegionsTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 4, O28: the Swift side of the region contract, the NORMAL
//  FORM and the two regions of a text (`MarkdownManagedRegions`). The page compares in the same normal form
//  (web/codemirror/src/api-managed-region.ts `normalizeRegionText`), so a difference here makes every region push come back
//  `regionChanged`. The real page is exercised in `MarkdownManagedRegionPusherTests`.
//
//   BREAK (normal form): in `MarkdownManagedRegions.normalized` delete the `blankRuns` replacement line.
//   FAILS with: "blank-line runs are not collapsed".
//   BREAK (regions): in `snapshot(blocks:)` filter on `\.isBibliography` for the Notes list.
//   FAILS with: "the Notes region is not the isNotes blocks".
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown managed regions — Tier 2 (t-4a8fd8af round 4, O28)", .serialized, .timeLimit(.minutes(1)))
struct MarkdownManagedRegionsTests {

    @Test("the normal form: hidden markers removed, whitespace-only lines emptied, blank-line runs collapsed, trimmed")
    func normalForm() {
        #expect(
            MarkdownManagedRegions.normalized("<!-- @sid:ab12-cd --># Notes\n\n\n\n[^1]: One.\n\n<!-- ::auto-bibliography-end:: -->")
                == "# Notes\n\n[^1]: One.",
            "blank-line runs are not collapsed or the markers are not removed")
        #expect(MarkdownManagedRegions.normalized("A\n \t\nB") == "A\n\nB", "a whitespace-only line is not emptied")
        #expect(MarkdownManagedRegions.normalized("  \nA\r\nB\n\n") == "A\nB", "CRLF or trimming differs from the page's normal form")
        #expect(
            MarkdownManagedRegions.normalized("<!-- ::auto-bibliography:: --># Bibliography\n\nSmith.") == "# Bibliography\n\nSmith.",
            "the bibliography opening marker is not removed")
    }

    @Test("the regions of a text: Notes (heading line included) and Bibliography, from the parse; no region is nil")
    func regionsOfAText() {
        let text = "# Chapter one\n\nChapter one.[^1]\n\n# Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n"
            + "# Bibliography\n\nSmith, J. (2020). A book.\n\n<!-- ::auto-bibliography-end:: -->"
        let snapshot = MarkdownManagedRegions.snapshot(
            markdown: text, projectId: "p", notesTitle: nil, bibliographyHeaderName: "Bibliography", graceNames: [])
        #expect(snapshot.notes == "# Notes\n\n[^1]: Note one.\n\n[^2]: Note two.", "the Notes region is not the isNotes blocks")
        #expect(snapshot.notesHeadingLine == "# Notes")
        #expect(snapshot.bibliography == "# Bibliography\n\nSmith, J. (2020). A book.", "the Bibliography region is not the isBibliography blocks")
        #expect(snapshot.text(.notes) == snapshot.notes && snapshot.text(.bibliography) == snapshot.bibliography)

        let plain = MarkdownManagedRegions.snapshot(
            markdown: "# Chapter one\n\nJust text.", projectId: "p", notesTitle: nil, bibliographyHeaderName: "Bibliography", graceNames: [])
        #expect(plain == MarkdownRegionSnapshot(), "a document without the regions must report none")
    }

    @Test("the rows' side and the editor's side agree: the blocks of the stored rows give the same regions as the parse of their text")
    func rowsAndParseAgree() throws {
        let text = "# Chapter one\n\nChapter one.[^1]\n\n# Notes\n\n[^1]: Note one.\n\n# Bibliography\n\nSmith, J. (2020). A book.\n\n"
            + "<!-- ::auto-bibliography-end:: -->"
        let db = try TestFixtureFactory.createTemporary(content: text)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let fromRows = MarkdownManagedRegions.snapshot(blocks: try TestFixtureFactory.fetchBlocks(from: db))
        let fromParse = MarkdownManagedRegions.snapshot(
            markdown: text, projectId: pid, notesTitle: nil, bibliographyHeaderName: "Bibliography", graceNames: [])
        #expect(fromRows.notes != nil, "premise: the stored rows carry a Notes region")
        #expect(fromRows.notes == fromParse.notes && fromRows.bibliography == fromParse.bibliography,
                "the two descriptions of the same text differ, so a region push would be rejected")
    }
}
