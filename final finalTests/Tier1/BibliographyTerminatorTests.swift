//
//  BibliographyTerminatorTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Tests for the explicit `BlockParser.bibliographyEndMarker` terminator — the THIRD fix
//  attempt for the full-document-reparse bibliography orphan bug: text typed after the
//  bibliography section (with no heading following it) silently gets flagged
//  isBibliography=true the next time BlockParser.parse() re-derives every block's flag
//  from scratch on a full reparse, reachable via ViewNotificationModifiers.swift's
//  `scheduleFullDocumentReparse` (Source Mode's 1s debounced re-parse) and, critically,
//  the reparse that runs immediately before every PDF export
//  (EditorViewState.flushContentToDatabase(), wired to DocumentManager.flushBeforeExport).
//
//  ROOT CAUSE: the auto-generated bibliography section
//  (`BibliographySyncService.updateBibliographyBlock`) is always the LAST thing in the
//  document and never has a closing heading. On a full reparse of raw markdown TEXT — no
//  block IDs, no prior `isBibliography` history — `BlockParser.parse()`'s
//  `sectionFlagCarriedForward` rule ("carry the flag until the next heading") has no way to
//  distinguish "one more bibliography entry" from "the user's first paragraph typed below
//  the references" — they're textually identical shapes. Once mis-flagged,
//  `exportBlocks()`'s `!$0.isBibliography` filter silently drops that text from every
//  export, and `processEditorDeletes`'s safety net refuses to let the user delete it.
//
//  Two earlier fixes were tried and rejected before this one: a position-bounded self-heal
//  sweep (no bound could safely distinguish real orphans from real user content) and a
//  block-count "hint" threaded into `BlockParser.parse()` (missed every reparse call site
//  except one, and could misfire under ordinary editing — see
//  `BibliographySyncService.updateBibliographyBlock`'s and `BlockParser.parse()`'s doc
//  comments for the full history).
//
//  FIX: an explicit, invisible terminator (`<!-- ::auto-bibliography-end:: -->`) written
//  permanently into the document's own editable text by
//  `BlockParser+Assembly.swift`'s `assembleMarkdownForEditor` whenever the last real block
//  is bibliography content — so the closing boundary is self-describing wherever the text
//  goes, with no count, no per-call-site threading, and no dependency on database state
//  that could itself be corrupted.
//

import Testing
import Foundation
@testable import final_final

@Suite("Bibliography Terminator — Tier 1: Silent Killers")
struct BibliographyTerminatorTests {

    @Test("Full reparse WITH the terminator present correctly closes the section")
    func fullReparseWithTerminatorClosesSection() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let bibBlocks = existingBlocks.filter { $0.isBibliography }
        #expect(
            bibBlocks.count == 5,
            "richTestContent's References section must be heading + 4 entries for this test to be meaningful"
        )

        // Simulate exactly what editorState.content looks like after
        // assembleMarkdownForEditor appends the terminator, plus a trailing note the user
        // typed after it — no hint parameter passed to parse(), since it no longer exists.
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)
        let withTerminatorAndTrailingNote = assembled
            + "\n\n" + BlockParser.bibliographyEndMarker
            + "\n\nA trailing note the user typed after the references."

        let reparsed = BlockParser.parse(markdown: withTerminatorAndTrailingNote, projectId: pid)

        let trailingBlock = try #require(
            reparsed.last { $0.markdownFragment.contains("A trailing note the user typed") }
        )
        #expect(
            trailingBlock.isBibliography == false,
            "With the terminator present, the trailing paragraph must NOT be flagged isBibliography"
        )

        // exportBlocks() is `blocks.filter { !$0.isBibliography }` — proves the fix actually
        // restores this text to every export, not just to the flag in isolation.
        #expect(
            reparsed.filter { !$0.isBibliography }.contains { $0.id == trailingBlock.id },
            "Trailing paragraph must survive the isBibliography export filter after the fix"
        )

        // All 5 real bibliography blocks (heading + 4 entries) must still be flagged — the
        // fix must not under-flag genuine bibliography content.
        let reparsedBibBlocks = reparsed.filter { $0.isBibliography }
        #expect(
            reparsedBibBlocks.count == 5,
            "The fix must not change how many real bibliography blocks are flagged (still heading + 4 entries)"
        )
        let referencesHeading = reparsed.first { $0.markdownFragment == "# References" }
        #expect(referencesHeading?.isBibliography == true, "The References heading itself must still be flagged")

        // The terminator produces ZERO Blocks — stronger than the opening marker, which DOES
        // persist as a `.bibliography`-typed Block.
        #expect(
            !reparsed.contains { $0.markdownFragment == BlockParser.bibliographyEndMarker },
            "The terminator must never itself produce a Block"
        )
    }

    @Test("Full reparse with NO terminator reproduces the legacy carry-to-end-of-document behavior (documented, expected gap)")
    func fullReparseWithoutTerminatorReproducesLegacyGap() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)

        // No terminator here — models content saved BEFORE this fix shipped. Plain
        // assembleMarkdown (not assembleMarkdownForEditor), matching what pre-upgrade
        // editorState.content would contain.
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)
        let withTrailingNote = assembled + "\n\nA trailing note the user typed after the references."

        let reparsed = BlockParser.parse(markdown: withTrailingNote, projectId: pid)

        let trailingBlock = try #require(
            reparsed.last { $0.markdownFragment.contains("A trailing note the user typed") }
        )
        #expect(
            trailingBlock.isBibliography == true,
            """
            EXPECTED, DOCUMENTED GAP — not a regression: pre-upgrade content with no \
            terminator still carries isBibliography to the end of the document on a full \
            reparse, exactly as before this fix. This self-heals on first touch: the next \
            time editorState.content is rebuilt from blocks (Source Mode toggle, any \
            flushContentToDatabase() call), assembleMarkdownForEditor adds the terminator \
            going forward. See BlockParser.bibliographyEndMarker's doc comment.
            """
        )
    }

    @Test("Editing an existing bibliography entry's text keeps it correctly flagged, with the terminator present")
    func editingEntryTextStaysFlaggedWithTerminator() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)

        // Edit one entry's text and add a trailing paragraph after the terminator — editing
        // an entry's wording must not disturb the terminator's own closing behavior.
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)
        let editedAssembled = assembled.replacingOccurrences(
            of: "Carroll, S. R., et al. (2020). The CARE Principles for Indigenous Data Governance. *Data Science Journal*, 19(1), 43.",
            with: "Carroll, S. R., et al. (2020). The CARE Principles for Indigenous Data Governance, revised. *Data Science Journal*, 19(1), 43."
        )
        let withTerminatorAndTrailingNote = editedAssembled
            + "\n\n" + BlockParser.bibliographyEndMarker
            + "\n\nA trailing note the user typed after the references."

        let reparsed = BlockParser.parse(markdown: withTerminatorAndTrailingNote, projectId: pid)

        let editedEntry = try #require(reparsed.first { $0.markdownFragment.contains("revised") })
        #expect(editedEntry.isBibliography == true, "Editing an entry's own text must not un-flag it")

        let trailingBlock = try #require(
            reparsed.last { $0.markdownFragment.contains("A trailing note the user typed") }
        )
        #expect(trailingBlock.isBibliography == false, "Trailing paragraph must still be correctly unflagged")
    }

    @Test("The Enter-key placement fix's two outcomes: paragraph after the terminator is unflagged, before it is flagged")
    func enterKeyPlacementBothDirections() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)

        // Corrected placement — what bibliography-end-marker-plugin.ts's custom Enter
        // handler produces: the new paragraph lands AFTER the terminator.
        let correctPlacement = assembled
            + "\n\n" + BlockParser.bibliographyEndMarker
            + "\n\nNew paragraph after Enter."
        let reparsedCorrect = BlockParser.parse(markdown: correctPlacement, projectId: pid)
        let correctBlock = try #require(
            reparsedCorrect.last { $0.markdownFragment.contains("New paragraph after Enter") }
        )
        #expect(
            correctBlock.isBibliography == false,
            "Paragraph placed AFTER the terminator (the corrected Enter-key placement) must NOT be flagged"
        )

        // Naive/wrong placement — what ProseMirror's default splitBlock would produce
        // WITHOUT the custom keymap fix: the new paragraph lands BEFORE the terminator,
        // still positionally inside the bibliography section.
        let wrongPlacement = assembled
            + "\n\nNew paragraph before Enter fix.\n\n"
            + BlockParser.bibliographyEndMarker
        let reparsedWrong = BlockParser.parse(markdown: wrongPlacement, projectId: pid)
        let wrongBlock = try #require(
            reparsedWrong.first { $0.markdownFragment.contains("New paragraph before Enter fix") }
        )
        #expect(
            wrongBlock.isBibliography == true,
            """
            Paragraph placed BEFORE the terminator (the naive default splitBlock placement, \
            without the web-side Enter-key fix) IS flagged isBibliography — this is what \
            proves the web-side keymap fix in bibliography-end-marker-plugin.ts is \
            load-bearing, not decorative. Swift tests can't drive real keyboard input, so \
            this is the closest proof available at this layer that the fix matters.
            """
        )
    }

    @Test("Terminator glued to following content with no blank line splits into a zero-Block terminator plus a separately, correctly-unflagged paragraph")
    func gluedTerminatorSplitsCorrectly() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)

        // No blank line between the terminator and the following text — the Source Mode
        // hand-typing/paste edge case RawBlockSplitter.consumeContentLine now handles for
        // bibliographyEndMarker the same way it already did for sectionBreakMarker.
        let glued = assembled + "\n\n" + BlockParser.bibliographyEndMarker + "\nGlued trailing text."

        let reparsed = BlockParser.parse(markdown: glued, projectId: pid)

        #expect(
            !reparsed.contains { $0.markdownFragment.contains(BlockParser.bibliographyEndMarker) },
            "The terminator must split into its own raw block and produce ZERO Blocks, even when glued to following text"
        )
        let gluedBlock = try #require(reparsed.last { $0.markdownFragment.contains("Glued trailing text") })
        #expect(
            gluedBlock.isBibliography == false,
            "Text glued to the terminator must still split out into its own block and be correctly unflagged"
        )
        #expect(
            gluedBlock.blockType == .paragraph,
            "Glued trailing text must become an ordinary paragraph, not stay glued to a marker fragment"
        )
    }

    @Test("Terminator glued on the SAME line as text (both shapes) splits into a zero-Block terminator plus a separately, correctly-unflagged paragraph")
    func sameLineGluedTerminatorSplitsCorrectly() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)

        // Glued-before: text typed onto the START boundary of the terminator's CodeMirror-hidden
        // "blank" line, landing directly in front of the marker on the SAME physical line — the
        // shape the adjacent-LINE glue guards above don't cover, since the marker doesn't occupy
        // the whole line by itself.
        let gluedBefore = assembled + "\n\n" + "Glued before text." + BlockParser.bibliographyEndMarker
        let reparsedBefore = BlockParser.parse(markdown: gluedBefore, projectId: pid)

        #expect(
            !reparsedBefore.contains { $0.markdownFragment.contains(BlockParser.bibliographyEndMarker) },
            "The terminator must split into its own raw block and produce ZERO Blocks, even when text is glued before it on the same line"
        )
        let beforeBlock = try #require(reparsedBefore.last { $0.markdownFragment.contains("Glued before text") })
        #expect(
            beforeBlock.isBibliography == false,
            """
            Text glued BEFORE the terminator on the same line must still end up correctly \
            unflagged — the terminator always closes the section first, since a user can never \
            deliberately choose which side of an invisible marker to type on
            """
        )
        #expect(beforeBlock.blockType == .paragraph, "Glued-before text must become an ordinary paragraph")

        // Glued-after: the mirror shape — text typed onto the END boundary, landing directly
        // behind the marker on the same physical line.
        let gluedAfter = assembled + "\n\n" + BlockParser.bibliographyEndMarker + "Glued after text."
        let reparsedAfter = BlockParser.parse(markdown: gluedAfter, projectId: pid)

        #expect(
            !reparsedAfter.contains { $0.markdownFragment.contains(BlockParser.bibliographyEndMarker) },
            "The terminator must split into its own raw block and produce ZERO Blocks, even when text is glued after it on the same line"
        )
        let afterBlock = try #require(reparsedAfter.last { $0.markdownFragment.contains("Glued after text") })
        #expect(afterBlock.isBibliography == false, "Text glued AFTER the terminator on the same line must be correctly unflagged")
        #expect(afterBlock.blockType == .paragraph, "Glued-after text must become an ordinary paragraph")

        // Both shapes must not disturb the real bibliography block count (heading + 4 entries).
        #expect(reparsedBefore.filter { $0.isBibliography }.count == 5)
        #expect(reparsedAfter.filter { $0.isBibliography }.count == 5)
    }

    @Test("Terminator appearing TWICE on the same line splits into two zero-Block terminators plus separately, correctly-unflagged paragraphs")
    func sameLineGluedTerminatorTwiceSplitsCorrectly() throws {
        let db = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.richTestContent)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let existingBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let assembled = BlockParser.assembleMarkdown(from: existingBlocks)

        // Two same-line glues stacked back to back on ONE physical line — e.g. two separate
        // accidental clicks-and-types onto the terminator's CodeMirror-hidden line before
        // either glue is ever cleaned up. `String.range(of:)` only ever finds the FIRST
        // occurrence, so without splitting out every occurrence, everything from the first
        // match onward — INCLUDING the second marker's own literal text — gets swallowed
        // verbatim into what looks like an ordinary paragraph fragment, and can never
        // subsequently satisfy `parse()`'s exact `trimmed == bibliographyEndMarker` check.
        let twiceGlued = assembled + "\n\n"
            + "Entry one." + BlockParser.bibliographyEndMarker
            + "Middle." + BlockParser.bibliographyEndMarker
            + "Tail."
        let reparsed = BlockParser.parse(markdown: twiceGlued, projectId: pid)

        #expect(
            !reparsed.contains { $0.markdownFragment.contains(BlockParser.bibliographyEndMarker) },
            "Neither occurrence of the terminator may survive, whole or as a substring, inside any block's markdownFragment"
        )

        let entryOneBlock = try #require(reparsed.last { $0.markdownFragment.contains("Entry one") })
        let middleBlock = try #require(reparsed.last { $0.markdownFragment.contains("Middle") })
        let tailBlock = try #require(reparsed.last { $0.markdownFragment.contains("Tail") })
        #expect(entryOneBlock.isBibliography == false, "Text before the first terminator must be unflagged")
        #expect(middleBlock.isBibliography == false, "Text between the two terminators must be unflagged")
        #expect(tailBlock.isBibliography == false, "Text after the second terminator must be unflagged")
        #expect(entryOneBlock.blockType == .paragraph, "Text before the first terminator must become an ordinary paragraph")
        #expect(middleBlock.blockType == .paragraph, "Text between the two terminators must become an ordinary paragraph")
        #expect(tailBlock.blockType == .paragraph, "Text after the second terminator must become an ordinary paragraph")

        // Neither same-line glue may disturb the real bibliography block count (heading + 4 entries).
        #expect(reparsed.filter { $0.isBibliography }.count == 5)
    }

    @Test("bibliographyEndMarker is never itself recognized as a bibliography-opening heading")
    func terminatorIsNeverRecognizedAsOpeningHeading() {
        // Regression guard for the no-substring-collision naming property: the terminator's
        // "-end" sits BEFORE the closing "::" specifically so it can never match either
        // isBibliographyHeading's or listTableOrMediaType's opening-marker substring check.
        #expect(BlockParser.isBibliographyHeading(BlockParser.bibliographyEndMarker) == false)
    }

    // ---- Real assembleMarkdownForEditor() coverage ----
    //
    // Every test above hand-constructs its input with the terminator already present via
    // string concatenation — that only proves parse() consumes an EXISTING terminator
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
    private func blocksWithUnflaggedTrailingParagraph(
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
