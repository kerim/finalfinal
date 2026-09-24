//
//  NotesHeadingExportGuardTests.swift
//  final finalTests
//
//  Split out of NotesHeadingExportTests.swift to keep that file's class body under SwiftLint's
//  type_body_length limit -- see the header comment there for the full `classifyNotesRuns`
//  export-heading-drop background. This file covers the guard cases: the live editor
//  (assembleMarkdownForEditor) and raw-markdown export paths are completely unaffected by the
//  export-only Notes heading logic, a non-numeric footnote-shaped label leaves the heading
//  intact, and start-anchoring means a definition shape on line 2 doesn't count -- using the
//  shared `buildQualifyingNotesRunBlocks()` / `buildUserAuthoredNotesBlocks()` fixtures defined
//  in NotesHeadingExportTests.swift.
//

import XCTest
import Foundation
@testable import final_final

extension NotesHeadingExportTests {

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
