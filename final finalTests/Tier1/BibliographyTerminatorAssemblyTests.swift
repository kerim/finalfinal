//
//  BibliographyTerminatorAssemblyTests.swift
//  final finalTests
//
//  Split out of BibliographyTerminatorTests.swift to keep that file's struct body under
//  SwiftLint's type_body_length limit -- see the header comment there for the full
//  explicit-terminator background (`BlockParser.bibliographyEndMarker`). Every test in
//  BibliographyTerminatorTests.swift hand-constructs its input with the terminator already
//  present; this file covers the REAL assembleMarkdownForEditor() coverage -- proving the
//  function actually EMITS the terminator for the reported failing cases -- using the shared
//  `blocksWithUnflaggedTrailingParagraph(from:projectId:trailingText:)` helper defined in
//  BibliographyTerminatorTests.swift.
//

import Testing
import Foundation
@testable import final_final

extension BibliographyTerminatorTests {

    // ---- Real assembleMarkdownForEditor() coverage ----
    //
    // Every test in BibliographyTerminatorTests.swift hand-constructs its input with the
    // terminator already present via string concatenation — that only proves parse() consumes an EXISTING terminator
    // correctly. It never proves assembleMarkdownForEditor() actually EMITS one for the
    // reported failing case: a trailing paragraph typed after the bibliography, where the
    // document's LAST block is that trailing paragraph, not bibliography content. An earlier
    // version of assembleMarkdownForEditor guarded on "the last non-empty block IS
    // bibliography content" and returned the base markdown unmodified otherwise — which is
    // exactly backwards for this scenario: the terminator is needed precisely when trailing
    // content follows the bibliography, and that guard skipped emitting it in exactly that
    // case. These two tests call the REAL function on blocks shaped for that scenario.

    /// Builds `existingBlocks` (richTestContent's References section: heading + 4 entries,
    /// all `isBibliography == true`, the LAST section in the fixture) plus one additional,
    /// already-correctly-unflagged trailing paragraph Block appended after it — the exact
    /// shape must-fix 4 calls for: `[…, bibliography heading, entries, unflagged trailing
    /// paragraph]`.
    func blocksWithUnflaggedTrailingParagraph(
        from db: ProjectDatabase,
        projectId pid: String,
        trailingText: String
    ) throws -> (blocks: [Block], trailingText: String) {
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let maxSortOrder = try #require(existingBlocks.map(\.sortOrder).max())
        let trailingBlock = Block(
            projectId: pid,
            sortOrder: maxSortOrder + 1.0,
            blockType: .paragraph,
            textContent: trailingText,
            markdownFragment: trailingText,
            isBibliography: false
        )
        return (existingBlocks + [trailingBlock], trailingText)
    }

    @Test("assembleMarkdownForEditor emits the terminator BETWEEN the bibliography entries and an unflagged trailing paragraph")
    func assembleMarkdownForEditorEmitsTerminatorBeforeTrailingParagraph() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let (blocks, trailingText) = try blocksWithUnflaggedTrailingParagraph(
            from: db, projectId: pid, trailingText: "A trailing paragraph the user typed after the references."
        )

        // The function under test — no hand-constructed terminator string anywhere here.
        let assembled = BlockParser.assembleMarkdownForEditor(from: blocks)

        let terminatorRange = try #require(
            assembled.range(of: BlockParser.bibliographyEndMarker),
            """
            assembleMarkdownForEditor must emit the terminator even though the trailing paragraph, \
            not bibliography content, is the document's last block
            """
        )
        let trailingRange = try #require(assembled.range(of: trailingText))
        #expect(
            terminatorRange.upperBound <= trailingRange.lowerBound,
            "The terminator must appear BEFORE the trailing paragraph, not after it or omitted"
        )

        let lastEntry = try #require(blocks.filter { $0.isBibliography }.max { $0.sortOrder < $1.sortOrder })
        let lastEntryRange = try #require(assembled.range(of: lastEntry.markdownFragment))
        #expect(
            lastEntryRange.upperBound <= terminatorRange.lowerBound,
            "The terminator must appear AFTER the last real bibliography entry"
        )
    }

    @Test("Round-trip: assembleMarkdownForEditor's own output, reparsed, keeps the trailing paragraph correctly unflagged")
    func assembleMarkdownForEditorRoundTripKeepsTrailingParagraphUnflagged() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let (blocks, trailingText) = try blocksWithUnflaggedTrailingParagraph(
            from: db, projectId: pid, trailingText: "A trailing paragraph the user typed after the references."
        )

        // Full round trip: real assembly, then real reparse of exactly what that assembly
        // produced — proves the fix closes the loop end-to-end (assemble -> editorState.content
        // -> parse), not just that the terminator's text appears somewhere in the output.
        let assembled = BlockParser.assembleMarkdownForEditor(from: blocks)
        let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)

        let reparsedTrailing = try #require(reparsed.last { $0.markdownFragment.contains(trailingText) })
        #expect(
            reparsedTrailing.isBibliography == false,
            """
            The trailing paragraph must survive a full reparse of assembleMarkdownForEditor's own \
            output without being re-flagged isBibliography
            """
        )
        #expect(
            reparsed.filter { !$0.isBibliography }.contains { $0.id == reparsedTrailing.id },
            "Trailing paragraph must survive the isBibliography export filter after the round trip"
        )
        #expect(
            reparsed.filter { $0.isBibliography }.count == 5,
            "Real bibliography blocks (heading + 4 entries) must still all be flagged after the round trip"
        )
    }

    @Test("assembleMarkdownForEditor emits the terminator at the very end when the bibliography IS the document's literal last block")
    func assembleMarkdownForEditorEmitsTerminatorWhenBibliographyIsLastBlock() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)

        // No trailing paragraph appended — richTestContent's bibliography section is already
        // the fixture's last section, so this exercises the "last non-empty block IS
        // bibliography content" branch the two tests above deliberately do NOT cover.
        let assembled = BlockParser.assembleMarkdownForEditor(from: existingBlocks)

        let terminatorRange = try #require(
            assembled.range(of: BlockParser.bibliographyEndMarker),
            "assembleMarkdownForEditor must emit the terminator when bibliography content is the document's last block"
        )

        let lastEntry = try #require(existingBlocks.filter { $0.isBibliography }.max { $0.sortOrder < $1.sortOrder })
        let lastEntryRange = try #require(assembled.range(of: lastEntry.markdownFragment))
        #expect(
            lastEntryRange.upperBound <= terminatorRange.lowerBound,
            "The terminator must appear AFTER the last real bibliography entry"
        )
        #expect(
            assembled.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(BlockParser.bibliographyEndMarker),
            "With nothing after the bibliography, the terminator must be the very last thing in the assembled markdown"
        )

        // Round trip: reparsing the terminator-closed, bibliography-last document must not
        // spuriously flag anything beyond the real bibliography blocks (nothing trails it here,
        // but this guards against the terminator itself, or its absence, corrupting the count).
        let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)
        #expect(
            reparsed.filter { $0.isBibliography }.count == existingBlocks.filter { $0.isBibliography }.count,
            "Reparsing a bibliography-last document must preserve exactly the real bibliography block count"
        )
    }

    @Test("assembleMarkdownForEditor emits no terminator at all when the document has no bibliography content")
    func assembleMarkdownForEditorEmitsNoTerminatorWithoutBibliography() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Strip every bibliography block out entirely — no isBibliography content anywhere,
        // so `sortedReal.lastIndex(where: { $0.isBibliography })` must come back nil and the
        // terminator must never be inserted.
        let noBibBlocks = existingBlocks.filter { !$0.isBibliography }
        #expect(!noBibBlocks.isEmpty, "Fixture must still have non-bibliography content for this test to be meaningful")
        #expect(noBibBlocks.contains { $0.isBibliography } == false)

        let assembled = BlockParser.assembleMarkdownForEditor(from: noBibBlocks)

        #expect(
            assembled.range(of: BlockParser.bibliographyEndMarker) == nil,
            "assembleMarkdownForEditor must never emit the terminator when no block is flagged isBibliography"
        )

        // Round trip: reparsing must not introduce any isBibliography flag out of thin air.
        let reparsed = BlockParser.parse(markdown: assembled, projectId: pid)
        #expect(
            reparsed.filter { $0.isBibliography }.isEmpty,
            "Reparsing a document with no bibliography content must produce zero isBibliography-flagged blocks"
        )
    }
}
