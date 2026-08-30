//
//  MultiParagraphFootnoteExportTests.swift
//  final finalTests
//
//  Tier 1: Data Integrity
//
//  Tests for multi-paragraph footnote export -- BlockParser.swift's
//  `sectionFlagCarriedForward` carries `isNotes = true` forward onto every non-heading
//  block after a "# Notes" heading, including a footnote definition's CONTINUATION
//  paragraph(s) (the second, third, ... paragraph of a footnote, stored as its own block
//  because Milkdown's footnote plugin round-trips a multi-paragraph definition as separate
//  blocks -- see BlockParser+Assembly.swift's `classifyNotesRuns` doc comment for why a
//  single-block representation was rejected). Before this fix, `BlockParser+Assembly.swift`
//  treated any non-`[^N]:`-shaped block in a Notes run as evidence the run was NOT pure
//  machine-managed footnote content: the "# Notes" heading was wrongly kept, AND the
//  continuation text was emitted as an unindented, stray top-level paragraph instead of
//  being folded into its footnote.
//
//  These fixtures seed every continuation block with `isNotes: true` explicitly -- exactly
//  what a real reparse produces via `sectionFlagCarriedForward` -- so these tests exercise
//  only `BlockParser+Assembly.swift`'s export logic, independent of the separate insert-path
//  (Database+BlocksInsert.swift) and replace-path (Database+BlocksReplace.swift) fixes.
//

import XCTest
import Foundation
@testable import final_final

final class MultiParagraphFootnoteExportTests: XCTestCase {

    // MARK: - (a) Notes heading dropped when a footnote has a continuation

    func testFootnoteWithContinuation_HeadingDroppedContinuationFolded() {
        let heading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Introduction", markdownFragment: "# Introduction"
        )
        let para = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "Some text with a footnote.[^1]", markdownFragment: "Some text with a footnote.[^1]"
        )
        let notesHeading = Block(
            projectId: "test", sortOrder: 3.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 4.0, blockType: .paragraph,
            textContent: "[^1]: First paragraph of the footnote.",
            markdownFragment: "[^1]: First paragraph of the footnote.",
            isNotes: true
        )
        let continuation1 = Block(
            projectId: "test", sortOrder: 5.0, blockType: .paragraph,
            textContent: "Second paragraph of the same footnote.",
            markdownFragment: "Second paragraph of the same footnote.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [heading, para, notesHeading, def1, continuation1])

        XCTAssertFalse(output.contains("# Notes"),
                       "A Notes heading whose run is entirely a definition plus its continuation " +
                       "must still be dropped -- a continuation is not disqualifying evidence. " +
                       "Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: First paragraph of the footnote."))
        XCTAssertTrue(output.contains("    Second paragraph of the same footnote."),
                     "The continuation must be 4-space indented so it parses as PART OF the " +
                     "footnote definition, not as a stray top-level paragraph. Output:\n\(output)")
        XCTAssertFalse(output.contains("\nSecond paragraph of the same footnote."),
                       "The continuation must never appear unindented (as a top-level paragraph) " +
                       "anywhere in the output. Output:\n\(output)")
    }

    // MARK: - (b) Every line of a multi-line continuation fragment gets indented

    func testMultiLineContinuationFragment_EveryLineIndented() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^1]: First paragraph.", markdownFragment: "[^1]: First paragraph.",
            isNotes: true
        )
        // A single continuation BLOCK whose fragment itself contains an internal newline
        // (e.g. the user pressed Shift+Return inside the continuation paragraph) -- both
        // lines must be indented, not just the first.
        let continuation1 = Block(
            projectId: "test", sortOrder: 3.0, blockType: .paragraph,
            textContent: "Line one of the continuation.\nLine two of the continuation.",
            markdownFragment: "Line one of the continuation.\nLine two of the continuation.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [notesHeading, def1, continuation1])

        XCTAssertTrue(output.contains("    Line one of the continuation.\n    Line two of the continuation."),
                     "Every line of a multi-line continuation fragment must be individually " +
                     "4-space indented, not just the first line. Output:\n\(output)")
        XCTAssertFalse(output.contains("\nLine two of the continuation."),
                       "The second line must never appear unindented. Output:\n\(output)")
    }

    // MARK: - (c) assembleStandardMarkdownForExport keeps the heading, still indents continuations

    func testStandardMarkdownExport_KeepsHeadingButIndentsContinuation() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "[^1]: First paragraph.", markdownFragment: "[^1]: First paragraph.",
            isNotes: true
        )
        let continuation1 = Block(
            projectId: "test", sortOrder: 3.0, blockType: .paragraph,
            textContent: "Second paragraph.", markdownFragment: "Second paragraph.",
            isNotes: true
        )

        let output = BlockParser.assembleStandardMarkdownForExport(from: [notesHeading, def1, continuation1])

        XCTAssertTrue(output.contains("# Notes"),
                     "assembleStandardMarkdownForExport (plain .md export) must KEEP the Notes " +
                     "heading -- correct for .md, unlike the Pandoc-targeted export path. " +
                     "Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: First paragraph."))
        XCTAssertTrue(output.contains("    Second paragraph."),
                     "The continuation must still be 4-space indented in the plain markdown " +
                     "export, so the exported .md file remains valid Pandoc-flavored markdown " +
                     "for a multi-paragraph footnote. Output:\n\(output)")
        XCTAssertFalse(output.contains("\nSecond paragraph."),
                       "The continuation must never appear unindented. Output:\n\(output)")
    }

    // MARK: - (d) User's own hand-typed Notes prose before any definition -- untouched

    func testUserProseBeforeAnyDefinition_HeadingKeptProseUntouched() {
        let notesHeading = Block(
            projectId: "test", sortOrder: 1.0, blockType: .heading,
            textContent: "Notes", markdownFragment: "# Notes", isNotes: true
        )
        // Hand-typed prose the user wrote ABOVE their footnotes, before any "[^N]:"
        // definition appears in the run -- per the shared ownership definition, a
        // non-definition block preceding the first definition owns nothing and is never a
        // continuation, regardless of what comes after it.
        let userProse = Block(
            projectId: "test", sortOrder: 2.0, blockType: .paragraph,
            textContent: "These are my own notes, written before any footnote definition.",
            markdownFragment: "These are my own notes, written before any footnote definition.",
            isNotes: true
        )
        let def1 = Block(
            projectId: "test", sortOrder: 3.0, blockType: .paragraph,
            textContent: "[^1]: A real footnote.", markdownFragment: "[^1]: A real footnote.",
            isNotes: true
        )

        let output = BlockParser.assembleMarkdownForExport(from: [notesHeading, userProse, def1])

        XCTAssertTrue(output.contains("# Notes"),
                     "Pre-definition user prose disqualifies the run -- the heading must be " +
                     "kept, exactly as before this fix. Output:\n\(output)")
        XCTAssertTrue(output.contains("These are my own notes, written before any footnote definition."),
                     "The user's prose must survive completely untouched -- not indented, not " +
                     "dropped. Output:\n\(output)")
        XCTAssertFalse(output.contains("    These are my own notes"),
                       "Pre-definition prose must never be indented -- it owns nothing and is " +
                       "not a continuation. Output:\n\(output)")
        XCTAssertTrue(output.contains("[^1]: A real footnote."))
    }
}
