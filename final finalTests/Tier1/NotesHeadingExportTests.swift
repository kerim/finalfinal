//
//  NotesHeadingExportTests.swift
//  final finalTests
//
//  Tier 1: Data Integrity
//
//  Tests for `BlockParser.assembleMarkdownForExport(from:bibliographyPlaceholder:)`'s
//  `liftedNotesHeadingIDs` fix -- export used to leave a stray, empty "# Notes" heading
//  behind whenever a document had footnotes: Pandoc lifts `[^N]: definition` blocks out of
//  the flowing body and turns them into real footnotes, but the machine-managed `# Notes`
//  heading itself (persisted as an `isNotes`-flagged block by `FootnoteSyncService`) was
//  never dropped along with them.
//
//  FIX: `assembleMarkdownForExport` now scans, for every `isNotes && .heading` block in the
//  sorted array, the run of immediately-following `isNotes` blocks up to (not including) the
//  next heading of any kind. A heading is dropped from export ONLY when that run has at
//  least one non-empty block AND every non-empty block in it matches the numeric
//  machine-generated footnote-definition shape (`^\[\^\d+\]:`) -- the same digits-only
//  anchoring `FootnoteSyncService` itself uses when generating labels, since a non-numeric
//  label is evidence of hand-typed content, not evidence to loosen the pattern for. Any
//  ambiguity (mixed content, no evidence at all) fails toward keeping the heading.
//

import XCTest
import Foundation
@testable import final_final

final class NotesHeadingExportTests: XCTestCase {

    // MARK: - Fixtures

    /// Ordinary heading + a paragraph with two footnote references, followed by a
    /// machine-managed "# Notes" run: the Notes heading itself, plus two numeric-labeled
    /// footnote definitions -- exactly what `FootnoteSyncService` produces when Pandoc lifts
    /// `[^N]: ...` blocks out of the flowing body. Every non-empty block under the heading
    /// matches the footnote-definition pattern, so the heading should be dropped on export.
    private func buildQualifyingNotesRunBlocks() -> [Block] {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some text with two footnotes.[^1][^2]",
            markdownFragment: "Some text with two footnotes.[^1][^2]"
        )
        let notesHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "[^1]: First footnote.", markdownFragment: "[^1]: First footnote.",
            isNotes: true
        )
        let def2 = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "[^2]: Second footnote.", markdownFragment: "[^2]: Second footnote.",
            isNotes: true
        )
        return [heading, para, notesHeading, def1, def2]
    }

    /// A user-typed "Notes" heading with the user's own prose underneath -- zero footnotes
    /// anywhere in the document, no `[^N]:` pattern at all. The critical negative case: this
    /// heading must never be dropped, since the app never generated it.
    private func buildUserAuthoredNotesBlocks() -> [Block] {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let prose = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "These are my own notes to self, unrelated to any footnote.",
            markdownFragment: "These are my own notes to self, unrelated to any footnote.",
            isNotes: true
        )
        return [notesHeading, prose]
    }

    // MARK: - 1. Homogeneous machine-managed run -> heading dropped

    func testQualifyingNotesRun_HeadingDroppedDefinitionsSurvive() {
        let output = BlockParser.assembleMarkdownForExport(from: buildQualifyingNotesRunBlocks())

        XCTAssertFalse(output.contains("# Notes"),
                       "A machine-managed Notes heading with only footnote definitions under it " +
                       "must be dropped. Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: First footnote."))
        XCTAssertTrue(output.contains("[^2]: Second footnote."))
        XCTAssertTrue(output.contains("Some text with two footnotes.[^1][^2]"),
                     "The body paragraph carrying the inline footnote references must survive " +
                     "untouched -- checking for its exact text, not just the substring \"[^1]\" " +
                     "which the definition-line assertions above already guarantee is present. " +
                     "Output:\n\(output)")
        XCTAssertTrue(output.contains("# Introduction"), "An ordinary user heading elsewhere must survive.")
    }

    // MARK: - 2. User-authored Notes heading, zero footnotes -> unchanged (critical negative case)

    func testUserAuthoredNotesHeading_NoFootnotesAnywhere_SurvivesUnchanged() {
        let output = BlockParser.assembleMarkdownForExport(from: buildUserAuthoredNotesBlocks())

        XCTAssertTrue(output.contains("# Notes"),
                     "A user-typed Notes heading with no footnote evidence under it must never be " +
                     "dropped. Output:\n\(output)")
        XCTAssertTrue(output.contains("These are my own notes to self, unrelated to any footnote."))
    }

    // MARK: - 3. Mixed run (one real definition + user prose) -> heading survives

    func testMixedNotesRun_RealDefinitionPlusUserProse_HeadingSurvives() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^1]: A real footnote.", markdownFragment: "[^1]: A real footnote.",
            isNotes: true
        )
        let userProse = Block(
            projectId: "test", sortOrder: 3.0, blockType: .paragraph,
            textContent: "By the way, thanks for reading this far.",
            markdownFragment: "By the way, thanks for reading this far.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [notesHeading, def1, userProse])

        XCTAssertTrue(output.contains("# Notes"),
                     "Ambiguous evidence (one real definition, one user sentence in the same run) " +
                     "must fail toward preservation. Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: A real footnote."))
        XCTAssertTrue(output.contains("By the way, thanks for reading this far."))
    }

    // MARK: - 4. Run-boundary: stops at the next heading, whatever follows is untouched

    func testRunBoundary_StopsAtNextHeading_AfterwordUntouched() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^1]: A real footnote.", markdownFragment: "[^1]: A real footnote.",
            isNotes: true
        )
        let afterwordHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Afterword", markdownFragment: "# Afterword"
        )
        let afterwordProse = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "Some closing thoughts.", markdownFragment: "Some closing thoughts."
        )

        let output = BlockParser.assembleMarkdownForExport(
            from: [notesHeading, def1, afterwordHeading, afterwordProse]
        )

        XCTAssertFalse(output.contains("# Notes"), "Qualifying Notes heading must be dropped. Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: A real footnote."))
        XCTAssertTrue(output.contains("# Afterword"),
                     "The next heading (not part of the Notes run) must survive untouched. Output:\n\(output)")
        XCTAssertTrue(output.contains("Some closing thoughts."))
    }

    // MARK: - 5. Two independent Notes runs, each judged on its own evidence

    func testTwoIndependentNotesRuns_EachJudgedOnItsOwnEvidence() {
        let notesHeadingA = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let defA1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^1]: First run's footnote.", markdownFragment: "[^1]: First run's footnote.",
            isNotes: true
        )
        let middleHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Middle", markdownFragment: "# Middle"
        )
        let notesHeadingB = Block(
            projectId: "test", sortOrder: 4.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let defB1 = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "[^2]: Second run's footnote.", markdownFragment: "[^2]: Second run's footnote.",
            isNotes: true
        )
        let userProseB = Block(
            projectId: "test", sortOrder: 6.0, blockType: .paragraph,
            textContent: "This second Notes section also has my own thought.",
            markdownFragment: "This second Notes section also has my own thought.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(
            from: [notesHeadingA, defA1, middleHeading, notesHeadingB, defB1, userProseB]
        )

        XCTAssertTrue(output.contains("# Middle"))
        XCTAssertTrue(output.contains("[^1]: First run's footnote."))
        XCTAssertTrue(output.contains("[^2]: Second run's footnote."))
        XCTAssertTrue(output.contains("This second Notes section also has my own thought."))

        // Run A is homogeneous (must be dropped); run B is mixed (must survive) -- exactly one
        // "# Notes" heading should remain, independent of the other run's outcome.
        let notesHeadingOccurrences = output.components(separatedBy: "# Notes").count - 1
        XCTAssertEqual(notesHeadingOccurrences, 1,
                       "Run A (homogeneous) must be dropped and run B (mixed) must survive -- " +
                       "exactly one '# Notes' heading should remain. Output:\n\(output)")

        // A bare count can't distinguish "run A survived, run B dropped" from the reverse --
        // both scenarios render the identical text "# Notes" once. Prove it's specifically run
        // B's heading (the one AFTER "# Middle") that survived, by checking the surviving
        // "# Notes" heading's position comes after "# Middle"'s.
        guard let middleRange = output.range(of: "# Middle"),
              let notesRange = output.range(of: "# Notes") else {
            XCTFail("Expected both '# Middle' and '# Notes' to be present in the output. Output:\n\(output)")
            return
        }
        XCTAssertTrue(notesRange.lowerBound > middleRange.lowerBound,
                     "The surviving '# Notes' heading must be run B's (the mixed, non-qualifying " +
                     "run declared after '# Middle'), not run A's (the homogeneous, qualifying " +
                     "run declared before it) -- a heading-count check alone cannot tell these " +
                     "two outcomes apart. Output:\n\(output)")
    }

    // MARK: - 6. PDF call shape: qualifying Notes run + real bibliography section

    func testPDFCallShape_QualifyingNotesRunAndBibliography() {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some intro text.[^1]", markdownFragment: "Some intro text.[^1]"
        )
        let notesHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "[^1]: A footnote.", markdownFragment: "[^1]: A footnote.",
            isNotes: true
        )
        let bibHeading = Block(
            projectId: "test", sortOrder: 5.0, blockType: .heading,
            textContent: "Bibliography", markdownFragment: "# Bibliography",
            isBibliography: true
        )
        let bibEntry1 = Block(
            projectId: "test", sortOrder: 6.0, blockType: .paragraph,
            textContent: "Entry one.", markdownFragment: "Entry one.",
            isBibliography: true
        )
        let bibEntry2 = Block(
            projectId: "test", sortOrder: 7.0, blockType: .paragraph,
            textContent: "Entry two.", markdownFragment: "Entry two.",
            isBibliography: true
        )

        let output = BlockParser.assembleMarkdownForExport(
            from: [heading, para, notesHeading, def1, bibHeading, bibEntry1, bibEntry2],
            bibliographyPlaceholder: true
        )

        XCTAssertFalse(output.contains("# Notes"),
                       "Qualifying Notes heading must be dropped even in the PDF/placeholder path. " +
                       "Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: A footnote."))
        XCTAssertTrue(output.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertTrue(output.contains("# Bibliography"))
        XCTAssertFalse(output.contains("Entry one."), "Bibliography entry text must never survive into export")
        XCTAssertFalse(output.contains("Entry two."), "Bibliography entry text must never survive into export")
    }

    // MARK: - 7. Legacy dual-flagged heading (isBibliography AND isNotes) -> bibliography wins

    func testDualFlaggedLegacyHeading_BibliographyBranchWins() {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some intro text.", markdownFragment: "Some intro text."
        )
        // Legacy shape: the bibliography header was once literally named "Notes", so this one
        // heading carries BOTH flags -- and since the real parser tracks the two section flags
        // independently off the same heading text, its entries below carry isNotes forward too.
        let legacyHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isBibliography: true, isNotes: true
        )
        // Real numeric footnote-definition shapes (not plain prose) -- so this run genuinely
        // WOULD qualify for notes-removal on the evidence, and the assertions below actually
        // prove the bibliography branch wins the ordering, rather than passing vacuously because
        // the heading never qualified for notes-removal in the first place.
        let entry1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "[^1]: Entry one.", markdownFragment: "[^1]: Entry one.",
            isBibliography: true, isNotes: true
        )
        let entry2 = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "[^2]: Entry two.", markdownFragment: "[^2]: Entry two.",
            isBibliography: true, isNotes: true
        )
        let blocks = [heading, para, legacyHeading, entry1, entry2]

        let placeholderOutput = BlockParser.assembleMarkdownForExport(from: blocks, bibliographyPlaceholder: true)
        XCTAssertTrue(placeholderOutput.contains("# Notes"),
                     "The legacy heading's own text must still appear, emitted via the bibliography " +
                     "heading path exactly as it would without this fix. Output:\n\(placeholderOutput)")
        XCTAssertTrue(placeholderOutput.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertFalse(placeholderOutput.contains("Entry one."))
        XCTAssertFalse(placeholderOutput.contains("Entry two."))

        let droppedOutput = BlockParser.assembleMarkdownForExport(from: blocks, bibliographyPlaceholder: false)
        XCTAssertFalse(droppedOutput.contains("# Notes"),
                       "Without the placeholder flag, the whole dual-flagged section must be dropped " +
                       "exactly as bibliography content always is. Output:\n\(droppedOutput)")
        XCTAssertFalse(droppedOutput.contains(BlockParser.bibliographyPlacementMarker))
        XCTAssertFalse(droppedOutput.contains("Entry one."))
        XCTAssertFalse(droppedOutput.contains("Entry two."))
    }

    // MARK: - 8. assembleMarkdownForEditor guard: the live editor is completely unaffected

    func testAssembleMarkdownForEditor_UnaffectedByNotesHeadingLogic() {
        let qualifyingOutput = BlockParser.assembleMarkdownForEditor(from: buildQualifyingNotesRunBlocks())
        XCTAssertTrue(qualifyingOutput.contains("# Notes"),
                     "The live editor must never drop a Notes heading, even when export would. " +
                     "Output:\n\(qualifyingOutput)")

        let userAuthoredOutput = BlockParser.assembleMarkdownForEditor(from: buildUserAuthoredNotesBlocks())
        XCTAssertTrue(userAuthoredOutput.contains("# Notes"))
    }

    // MARK: - 9. Raw-markdown export paths guard: unaffected, heading is correct/wanted there

    func testRawMarkdownExportPaths_UnaffectedByNotesHeadingLogic() {
        let blocks = buildQualifyingNotesRunBlocks()

        let standardOutput = BlockParser.assembleStandardMarkdownForExport(from: blocks)
        XCTAssertTrue(standardOutput.contains("# Notes"))
        XCTAssertTrue(standardOutput.contains("[^1]: First footnote."))
        XCTAssertTrue(standardOutput.contains("[^2]: Second footnote."))

        let markdownOnlyOutput = BlockParser.assembleMarkdownOnlyForExport(from: blocks)
        XCTAssertTrue(markdownOnlyOutput.contains("# Notes"))
        XCTAssertTrue(markdownOnlyOutput.contains("[^1]: First footnote."))
        XCTAssertTrue(markdownOnlyOutput.contains("[^2]: Second footnote."))
    }

    // MARK: - 10. Non-numeric footnote-shaped label -> heading survives (regex is numeric-only)

    /// The single most important test here: the fix's whole safety property rests on
    /// `footnoteDefStartPattern` matching ONLY numeric labels (`[^1]:`, `[^42]:`, ...), because
    /// `FootnoteSyncService` never generates anything else. A non-numeric label like
    /// `[^method-note]:` is therefore evidence the block was hand-typed by the user, not
    /// evidence to loosen the pattern for -- if this regex were ever widened to match any label
    /// shape, this is the test that would catch it, since every other test here only ever uses
    /// numeric labels.
    func testNonNumericFootnoteShapedLabel_HeadingSurvives() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let handTypedAside = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^method-note]: A hand-typed aside.",
            markdownFragment: "[^method-note]: A hand-typed aside.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [notesHeading, handTypedAside])

        XCTAssertTrue(output.contains("# Notes"),
                     "A non-numeric footnote-shaped label ([^method-note]:) is evidence of " +
                     "hand-typed content, not a machine-generated definition -- the app only ever " +
                     "generates numeric labels like [^1]:. The heading must survive. " +
                     "Output:\n\(output)")
        XCTAssertTrue(output.contains("[^method-note]: A hand-typed aside."))
    }

    // MARK: - 11. Start-anchoring: a definition shape on line 2 must not count (no .anchorsMatchLines)

    /// Proves the footnote-definition regex anchors `^` to the START of the whole trimmed
    /// fragment, not to the start of any line within it. A fragment whose first line is ordinary
    /// prose and whose SECOND line merely looks like a footnote definition must not be treated
    /// as one -- if the pattern were ever built with `.anchorsMatchLines`, this test would catch
    /// the resulting false-positive match.
    func testDefinitionShapeOnSecondLine_StartAnchored_HeadingSurvives() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes",
            isNotes: true
        )
        let twoLineFragment = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some prose here.\n[^1]: something",
            markdownFragment: "Some prose here.\n[^1]: something",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [notesHeading, twoLineFragment])

        XCTAssertTrue(output.contains("# Notes"),
                     "The footnote-definition pattern must anchor to the start of the whole " +
                     "trimmed fragment, not to the start of any line within it -- a block whose " +
                     "SECOND line merely looks like a definition must not qualify. " +
                     "Output:\n\(output)")
        XCTAssertTrue(output.contains("Some prose here.\n[^1]: something"))
    }
}
