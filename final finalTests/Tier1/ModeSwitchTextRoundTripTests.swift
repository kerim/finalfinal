//
//  ModeSwitchTextRoundTripTests.swift
//  final finalTests
//
//  Step 2.0 of the book-length switch plan (plan-book-length-switch.md): "name the 33 characters".
//
//  THE QUESTION. On a book-length document the two copies of the text that reach the incoming Rich Text editor after a
//  Markdown -> Rich Text switch differ by 33 characters (VM run, BOOK-6: 352,083 and 352,116). Step 2b will skip the switch's
//  database write when the rows the new text would produce equal the stored rows (`LifecycleWholeDocumentWrite.rowsMatch`, the
//  rule close and quit already use). 33 characters cannot make that skip drop a change (the comparison is on parsed rows, not
//  text), but they could stop it from ever firing. This test builds both texts the way the switch does and shows where they
//  differ and whether the rows still match.
//
//  WHAT THE TEST DOES (Swift side only; the web editors are not involved):
//    1. `content`: the document as the Rich Text editor holds it, `assembleMarkdownForEditor` of the stored rows (with the
//       bibliography end marker). For the x6 document this is 352,116 characters, the larger payload of the VM run.
//    2. The Markdown editor's text, as `handleEditorModeToggle` builds it: `injectSectionAnchors`, then `injectBibliographyMarker`.
//    3. The plain payload the switch back hands to the flush: `extractSectionAnchors`, then `stripBibliographyMarker`.
//    4. The text the database then assembles for the incoming editor: `assembleMarkdownForEditor(parse(plain))`.
//  It prints (lines starting `[ROUNDTRIP]`) the lengths and the first difference of: content vs plain, plain vs the assembled
//  text, and the stored rows vs the rows `replaceBlocks` would write for each of the texts.
//
//  WHAT IT ASSERTS: the fixture is shaped like the app's own output (precondition); and both the plain payload and the assembled
//  text parse to rows that satisfy `rowsMatch` against the stored rows, with no near tie (so the skip could fire). If that assertion
//  fails, the Markdown round trip itself alters the saved document (for example the bibliography flags or the Notes text), which
//  goes to the user, not to a fix in this test (plan: "Stop and report").
//
//  WHAT IT ONLY PRINTS: two "what if" variants of the plain payload that name candidate causes of a 33-character gap without the
//  Swift side producing one: the end marker missing, and one stray newline at the end. They show what the rows would do in each case.
//
//  Expected on today's code: the preconditions pass. Whether the round trip is lossless on the Swift side is what the output
//  says: if `plain` equals `content`, the 33 characters are introduced outside this code (the web editors' own text for the
//  document), and the what-if lines show the effect of each candidate.
//

import Foundation
import Testing
@testable import final_final

@Suite("Mode switch text round trip -- the 33 characters (book-length plan, step 2.0)")
struct ModeSwitchTextRoundTripTests {

    // MARK: - Comparing texts

    /// The length of each text and the first place they differ (UTF-16 offsets, the unit JavaScript string lengths use).
    private func describeDifference(_ leftName: String, _ left: String, _ rightName: String, _ right: String) -> String {
        let leftUnits = Array(left.utf16)
        let rightUnits = Array(right.utf16)
        var index = 0
        let common = min(leftUnits.count, rightUnits.count)
        while index < common, leftUnits[index] == rightUnits[index] { index += 1 }
        let difference = rightUnits.count - leftUnits.count
        let header = "\(leftName) \(leftUnits.count) characters, \(rightName) \(rightUnits.count) characters (difference \(difference))"
        if index == common, leftUnits.count == rightUnits.count { return header + "; identical" }
        func context(_ units: [UInt16]) -> String {
            let from = max(0, index - 40)
            let end = min(units.count, index + 90)
            return String(decoding: units[from..<end], as: UTF16.self).debugDescription
        }
        return header + "; first difference at offset \(index)\n    \(leftName) there: \(context(leftUnits))"
            + "\n    \(rightName) there: \(context(rightUnits))"
    }

    /// Whether the rows `text` produces would be written by a flush over the stored rows, and why not if they would.
    private func rowsVerdict(_ text: String, stored: [Block]) -> (skipWouldFire: Bool, description: String) {
        let parsed = ComplexDocumentFixture.parse(text)
        let sortedStored = BlockParser.assemblySorted(stored)
        let wouldWrite = ProjectDatabase.preparedRowsForWholeReplace(existing: sortedStored, parsed: parsed)
        let nearTie = LifecycleWholeDocumentWrite.hasNearTie(sortedStored)
        let difference = LifecycleWholeDocumentWrite.firstDifference(stored: stored, wouldWrite: wouldWrite)
        let description = difference.map { "rows DIFFER: \($0.prefix(400))" } ?? "rows match (\(wouldWrite.count) rows)"
        return (difference == nil && !nearTie, description + (nearTie ? "; NEAR TIE among the stored rows" : ""))
    }

    // MARK: - The round trip

    @MainActor
    private func roundTrip(_ label: String, _ document: ComplexDocumentFixture.Document) {
        #expect(
            ComplexDocumentFixture.bibliographyEndMarker == BlockParser.bibliographyEndMarker,
            "the fixture's copy of the end marker must be the app's")

        let inputs = ComplexDocumentFixture.switchInputs(for: document)
        let content = inputs.content
        let stored = inputs.storedBlocks

        // Preconditions: the fixture is shaped like the app's own output.
        #expect(
            content == document.editorMarkdown,
            """
            the app's own assembly of the fixture's rows must reproduce the fixture's editor text \
            (the order bibliography / Notes / end marker is the app's)
            """)
        #expect(
            stored.filter { $0.isBibliography }.count == document.counts.bibliographyEntries + 1,
            "the generated bibliography is the heading and one row per cited key, all flagged")
        #expect(stored.contains { $0.isNotes }, "the Notes section is flagged")
        #expect(inputs.sectionsToInject.contains { $0.isBibliography }, "a bibliography section exists, so the opening marker will be injected")

        let service = SectionSyncService()
        // Rich Text -> Markdown, as handleEditorModeToggle builds the Markdown editor's text.
        let withAnchors = service.injectSectionAnchors(markdown: content, sections: inputs.adjustedSections)
        let markdownEditorText = service.injectBibliographyMarker(markdown: withAnchors, sections: inputs.sectionsToInject)
        // Markdown -> Rich Text, as the switch back builds the plain payload for the flush.
        let (cleaned, anchors) = service.extractSectionAnchors(markdown: markdownEditorText)
        let plain = SectionSyncService.stripBibliographyMarker(from: cleaned)
        // What the database assembles for the incoming editor after that flush.
        let assembledAfterFlush = BlockParser.assembleMarkdownForEditor(from: ComplexDocumentFixture.parse(plain))

        var report: [String] = []
        report.append("[ROUNDTRIP] \(label): \(document.counts.summary)")
        let anchorGrowth = markdownEditorText.utf16.count - content.utf16.count
        report.append("[ROUNDTRIP] \(label): sections \(inputs.adjustedSections.count), anchors injected and extracted \(anchors.count); "
            + "the Markdown editor's text is \(markdownEditorText.utf16.count) characters (\(anchorGrowth) more than the Rich Text text)")
        report.append("[ROUNDTRIP] \(label): content vs plain payload: " + describeDifference("content", content, "plain", plain))
        report.append("[ROUNDTRIP] \(label): plain payload vs the text the database assembles after the flush: "
            + describeDifference("plain", plain, "assembled", assembledAfterFlush))

        let plainVerdict = rowsVerdict(plain, stored: stored)
        let assembledVerdict = rowsVerdict(assembledAfterFlush, stored: stored)
        report.append("[ROUNDTRIP] \(label): stored rows vs the rows the plain payload would write: \(plainVerdict.description)")
        report.append("[ROUNDTRIP] \(label): stored rows vs the rows the assembled text would write: \(assembledVerdict.description)")

        // What-if variants (printed only): candidate causes of a gap that this Swift code does not produce.
        let separatorAndMarker = "\n\n" + BlockParser.bibliographyEndMarker
        if plain.hasSuffix(separatorAndMarker) {
            let withoutMarker = String(plain.dropLast(separatorAndMarker.count))
            report.append("[ROUNDTRIP] \(label): WHAT IF the end marker were missing from the payload: "
                + describeDifference("assembled", assembledAfterFlush, "payload", withoutMarker))
            report.append("[ROUNDTRIP] \(label): WHAT IF the end marker were missing: \(rowsVerdict(withoutMarker, stored: stored).description)")
        }
        let withStrayNewline = plain + "\n"
        report.append("[ROUNDTRIP] \(label): WHAT IF one newline were added at the end: \(rowsVerdict(withStrayNewline, stored: stored).description)")
        UnitOutputFile.emit("roundtrip", report)

        #expect(
            plainVerdict.skipWouldFire,
            """
            the plain payload of a Markdown -> Rich Text switch must produce rows that match the stored rows \
            (otherwise the unchanged-switch skip can never fire): \(plainVerdict.description)
            """)
        #expect(
            assembledVerdict.skipWouldFire,
            "the text the database assembles after the flush must produce rows that match the stored rows: \(assembledVerdict.description)")
    }

    @Test("x1 (one chapter, 68 citation groups): content, plain payload and assembled text; do the rows still match?")
    @MainActor
    func articleRoundTrip() {
        roundTrip("x1", ComplexDocumentFixture.article)
    }

    @Test("x6 (six chapters, 408 citation groups): content, plain payload and assembled text; do the rows still match?")
    @MainActor
    func bookSixRoundTrip() {
        roundTrip("x6", ComplexDocumentFixture.book6)
    }
}
