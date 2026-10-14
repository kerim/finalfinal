//
//  MarkdownBlockWriteTypingTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U2 (a) at article length, (b), (h), (k), (l), (m) and the model ruling's
//  M2 (the flag-on fire reads the CURRENT editor text). What the user does while typing in Markdown, and what the
//  database holds afterwards:
//
//    - (a) one typed sentence in a generated article (60+ citations, footnotes, comments, CJK): exactly one row written
//    - (b) the bibliography revert control: the legacy whole-document write puts an OLD bibliography back; the per-block
//          write leaves the newer bibliography alone
//    - (h) an unclosed code fence or `$$`: no write, headings untouched; closed, one write; and judge C3, in `writeNow`
//          ONLY a guard trip falls back to the whole-document write (the typed text IS in the database afterwards)
//    - (k) the switch to Rich Text after typing writes keeps every id
//    - (l) a heading rename or level change keeps its id, status, tags and word goal
//    - (m) delete three paragraphs one at a time, restore them one at a time: the database equals the editor each step
//    - (n) model ruling M2: a fire scheduled with older text never puts it over a structural op's newer rows
//
//  Every test uses the real writer and the real database (`MarkdownWriterRig`); nothing is mocked.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown block writes: typing — Tier 2 (t-94369a83 Phase 4a, U2 a b h k l m n)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct MarkdownBlockWriteTypingTests {

    private static let base = "# Alpha\n\nOne.\n\nTwo.\n\nThree.\n\n# Beta\n\nFour.\n\nFive."

    // MARK: - (a) at article length

    @Test("(a) at article length: one typed sentence in a generated article is exactly one update; every other row keeps its id and stamp")
    func oneTypedSentenceInAnArticle() async throws {
        let article = POCComplexGenerator.make(id: "article", title: "Article", chapters: 1)
        let rig = try MarkdownWriterRig(content: article.markdown)
        let loaded = try rig.storedText()
        rig.editorState.content = loaded
        rig.markdownWriter.noteLoaded(text: loaded, pid: rig.pid)   // the app loads the editor from the stored rows

        let before = try rig.rows()
        let stampsBefore = try rig.stamps()
        // A long body paragraph with a citation, whose text occurs exactly once in the document.
        let target = try #require(before.first {
            $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography
                && $0.markdownFragment.contains("[@") && $0.markdownFragment.count > 200
                && loaded.components(separatedBy: $0.markdownFragment).count == 2
        })
        let typed = loaded.replacingOccurrences(of: target.markdownFragment, with: target.markdownFragment + " A typed sentence.")

        let disposition = await rig.fireAndSettle(typed)

        #expect(disposition == .started)
        let line = try #require(rig.markdownWriter.lastTimingLine)
        #expect(line.contains("mode=rows") && line.contains("u/i/d=1/0/0") && line.contains("outcome=applied"), "got \(line)")
        #expect(try rig.storedText() == typed)
        #expect(try rig.rows().count == rig.parse(typed).count)
        #expect(try rig.rows().map(\.id) == before.map(\.id), "no row was created or removed")
        let stampsAfter = try rig.stamps()
        for block in before where block.id != target.id {
            #expect(stampsAfter[block.id] == stampsBefore[block.id], "row \(block.id) was not touched")
        }
        #expect(stampsAfter[target.id] != stampsBefore[target.id], "the edited row was restamped")
    }

    // MARK: - (b) the bibliography revert control

    private static let withBibliography = [
        "# Intro", "Body paragraph.", "# Bibliography", "Smith 2020. First entry.", BlockParser.bibliographyEndMarker
    ].joined(separator: "\n\n")

    /// A bibliography update, as the bibliography service writes it: a SYSTEM write on the queue that rewrites the entry.
    private func applyBibliographyWrite(_ rig: MarkdownWriterRig, entryId: String, newText: String) async throws {
        let ticket = rig.writer.reserveSystem()
        let identity = SystemWriteIdentity(projectId: rig.pid, database: rig.db)
        let outcome = await rig.writer.applySystemWrite(ticket.seq, kind: .bibliographyUpdate, identity: identity) { database in
            try database.execute(
                sql: "UPDATE block SET textContent = ?, markdownFragment = ? WHERE id = ?", arguments: [newText, newText, entryId])
            return SystemWriteBody(value: 1)
        }
        guard case .applied = outcome else {
            Issue.record("the bibliography system write did not apply: \(outcome)")
            return
        }
    }

    @Test("""
        (b) a bibliography update lands first, then the editor's OLDER text is saved: the legacy whole-document write puts \
        the old bibliography back; the per-block write (text baseline) leaves the new bibliography alone and updates the paragraph
        """)
    func bibliographyRevertControl() async throws {
        let newEntry = "Smith 2020. UPDATED entry written by the bibliography."
        let typed = Self.withBibliography.replacingOccurrences(of: "Body paragraph.", with: "Body paragraph, typed.")

        // Control: the legacy path.
        let legacy = try MarkdownWriterRig(content: Self.withBibliography)
        let legacyEntry = try #require(try legacy.rows().first { $0.isBibliography && $0.markdownFragment.hasPrefix("Smith 2020") })
        try await applyBibliographyWrite(legacy, entryId: legacyEntry.id, newText: newEntry)
        #expect(try legacy.rows().contains { $0.markdownFragment == newEntry }, "premise: the bibliography write landed")
        ContentSyncObserverHost<EmptyView>.legacyWholeDocumentReparse(
            newValue: typed, db: legacy.db, pid: legacy.pid, editorState: legacy.editorState)
        #expect(try legacy.rows().contains { $0.markdownFragment == "Smith 2020. First entry." }, "the legacy write reverted the bibliography")
        #expect(try !legacy.rows().contains { $0.markdownFragment == newEntry })

        // The per-block path, in text mode with the earlier baseline.
        let rig = try MarkdownWriterRig(content: Self.withBibliography)
        let entry = try #require(try rig.rows().first { $0.isBibliography && $0.markdownFragment.hasPrefix("Smith 2020") })
        let unchanged = await rig.fireAndSettle(Self.withBibliography)   // the earlier text: nothing to write, baseline becomes text
        #expect(unchanged == .nothingToWrite)
        #expect(!rig.markdownWriter.baseline.isRows, "premise: the baseline is the earlier text")
        try await applyBibliographyWrite(rig, entryId: entry.id, newText: newEntry)

        let disposition = await rig.fireAndSettle(typed)

        #expect(disposition == .started)
        #expect(rig.markdownWriter.lastTimingLine?.contains("mode=text") == true, "the comparison was against the earlier text, not the rows")
        let rows = try rig.rows()
        #expect(rows.contains { $0.id == entry.id && $0.markdownFragment == newEntry }, "the newer bibliography is intact")
        #expect(rows.contains { $0.markdownFragment == "Body paragraph, typed." }, "the user's paragraph was updated")
        #expect(rows.count == legacy.parse(typed).count)
    }

    // MARK: - (h) an unclosed fence or $$

    private func inserting(_ block: String, into text: String) -> String {
        text.replacingOccurrences(of: "One.\n\n", with: "One.\n\n\(block)\n\n")
    }

    @Test("(h) an opener typed mid-document is skipped (no write, headings untouched); closed, one write lands",
          arguments: [("```", "```\ncode line\n```"), ("$$", "$$\nx = 1\n$$")])
    func openFenceOrMathIsSkippedThenWritten(opener: String, closed: String) async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        try rig.setMetadata(onHeading: "Beta", status: .review, tags: ["kept"], wordGoal: 500)
        let before = try rig.rows()
        let headingsBefore = before.filter { $0.blockType == .heading }
        let open = inserting(opener, into: Self.base)
        try #require(BlockParser.endsInsideOpenFenceOrMath(open), "premise: the typed opener leaves the text ending open")
        let sequenceBefore = rig.writer.nextSequence

        let skipped = await rig.fireAndSettle(open)

        #expect(skipped == .skippedOpenFence, "the skip line `[MdWrite] skipped: text ends inside an open code fence or $$ block` accompanies this")
        #expect(rig.writer.nextSequence == sequenceBefore, "nothing was reserved")
        #expect(try rig.rows().map(\.id) == before.map(\.id))
        #expect(try rig.storedText() == Self.base)
        #expect(rig.markdownWriter.baseline.isRows, "the baseline is kept")

        let close = inserting(closed, into: Self.base)
        try #require(!BlockParser.endsInsideOpenFenceOrMath(close))
        let written = await rig.fireAndSettle(close)

        #expect(written == .started)
        #expect(rig.writer.nextSequence == sequenceBefore + 1, "exactly one write")
        let after = try rig.rows()
        #expect(after.count == rig.parse(close).count)
        #expect(after.count == before.count + 1, "one more row than before: the closed block")
        #expect(try rig.storedText() == close)
        let headingsAfter = after.filter { $0.blockType == .heading }
        #expect(headingsAfter.map(\.id) == headingsBefore.map(\.id), "heading ids intact")
        let beta = try #require(headingsAfter.first { $0.textContent == "Beta" })
        #expect(beta.status == .review && beta.tags == ["kept"] && beta.wordGoal == 500, "heading status, tags and goal intact")
    }

    @Test("""
        (h)/C3 in `writeNow` ONLY a guard trip falls back to the whole-document write: through the real bibliography flush hook the \
        typed text IS in the database afterwards (the debounce fire's plain skip leaves it out)
        """)
    func writeNowGuardTripFallsBackToTheWholeDocumentWrite() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        // Insert the opener FIRST: `inserting` looks for "One.\n\n", which the marker edit below would remove (the first version of
        // this test did it the other way round, so its `open` text had no fence in it at all).
        let open = inserting("```", into: Self.base).replacingOccurrences(of: "One.", with: "One TYPED-MARK.")
        try #require(open.contains("\n```\n"), "premise: the opener line is in the text")
        try #require(open.contains("TYPED-MARK"), "premise: the typed marker is in the text")
        try #require(BlockParser.endsInsideOpenFenceOrMath(open), "premise: the text ends inside an open code fence")

        // The debounce fire: a plain skip. The typed text is NOT in the database.
        #expect(await rig.fireAndSettle(open) == .skippedOpenFence)
        #expect(try !rig.storedText().contains("TYPED-MARK"))

        // `writeNow` itself says: write it the old way.
        rig.editorState.content = open
        #expect(await rig.writeNow() == .fallBackToDirectWrite)
        #expect(try !rig.storedText().contains("TYPED-MARK"), "writeNow never writes whole documents itself; the caller does")

        // The real hook the bibliography update calls does, so the rebuild that follows reads rows that hold the user's text.
        let hook = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
        await hook(rig.pid, nil)
        #expect(try rig.storedText().contains("One TYPED-MARK."), "the typed text is in the database after the bibliography flush hook")
    }

    // MARK: - (k) id continuity across the switch

    @Test("(k) typing is saved block by block, so the switch to Rich Text finds the rows matching and rewrites nothing: every id is kept")
    func switchAfterTypingKeepsEveryId() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let typed = Self.base.replacingOccurrences(of: "Two.", with: "Two, typed.").replacingOccurrences(of: "Five.", with: "Five.\n\nSix, new.")
        #expect(await rig.fireAndSettle(typed) == .started)
        let idsAfterTyping = try rig.rows().map(\.id)
        #expect(idsAfterTyping.count == rig.parse(typed).count)

        // The switch: the editor's text is committed and saved with `skipUnchangedWrite`.
        rig.editorState.sourceContent = typed
        rig.editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())

        #expect(try rig.rows().map(\.id) == idsAfterTyping, "no row id changed across the switch")
        #expect(try rig.storedText() == typed)

        // Control: without the block-by-block saves the same switch rewrites the rows (non-heading ids are re-created).
        let control = try MarkdownWriterRig(content: Self.base)
        let controlBefore = try control.rows()
        control.editorState.sourceContent = typed
        control.editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())
        let controlAfter = try control.rows()
        #expect(try control.storedText() == typed)
        let paragraphIds = { (blocks: [Block]) in Set(blocks.filter { $0.blockType == .paragraph }.map(\.id)) }
        #expect(paragraphIds(controlAfter).isDisjoint(with: paragraphIds(controlBefore)), "control: the switch alone re-creates the paragraph ids")
    }

    // MARK: - (l) a heading rename

    @Test("(l) a heading rename and a level change keep the heading's id, status, tags and word goal")
    func headingRenameKeepsItsMetadata() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        try rig.setMetadata(onHeading: "Beta", status: .review, tags: ["alpha", "beta"], wordGoal: 750)
        let beta = try #require(try rig.heading("Beta"))

        let renamed = Self.base.replacingOccurrences(of: "# Beta", with: "# Beta renamed")
        #expect(await rig.fireAndSettle(renamed) == .started)
        let afterRename = try #require(try rig.heading("Beta renamed"))
        #expect(afterRename.id == beta.id)
        #expect(afterRename.status == .review && afterRename.tags == ["alpha", "beta"] && afterRename.wordGoal == 750)

        let demoted = renamed.replacingOccurrences(of: "# Beta renamed", with: "## Beta renamed")
        #expect(await rig.fireAndSettle(demoted) == .started)
        let afterLevel = try #require(try rig.heading("Beta renamed"))
        #expect(afterLevel.id == beta.id && afterLevel.headingLevel == 2)
        #expect(afterLevel.status == .review && afterLevel.tags == ["alpha", "beta"] && afterLevel.wordGoal == 750)
        #expect(try rig.storedText() == demoted)
    }

    // MARK: - (m) one step at a time

    @Test("(m) delete three paragraphs one at a time, restore them one at a time, redo, restore: the database equals the editor each step")
    func oneParagraphAtATime() async throws {
        let paragraphs = ["P1.", "P2.", "P3.", "P4."]
        func text(_ keep: [String]) -> String { (["# Alpha"] + keep + ["# Beta", "Q1."]).joined(separator: "\n\n") }
        let rig = try MarkdownWriterRig(content: text(paragraphs))
        let survivors = try rig.rows().filter { ["# Alpha", "P1.", "# Beta", "Q1."].contains($0.markdownFragment) }

        // Delete P2, P3, P4 (a fire each), undo them in reverse (a fire each), redo the first deletion, undo it again.
        let states = [
            ["P1.", "P3.", "P4."], ["P1.", "P4."], ["P1."],
            ["P1.", "P4."], ["P1.", "P3.", "P4."], paragraphs,
            ["P1.", "P3.", "P4."], paragraphs
        ].map(text)
        for (step, state) in states.enumerated() {
            let disposition = await rig.fireAndSettle(state)
            #expect(disposition == .started, "step \(step + 1) wrote")
            #expect(try rig.storedText() == state, "step \(step + 1): the database equals the editor")
            #expect(try rig.rows().count == rig.parse(state).count, "step \(step + 1): one row per block")
            #expect(try rig.duplicateFragments().isEmpty, "step \(step + 1): no duplicate rows")
        }
        #expect(rig.ledger.failedWrites == 0 && rig.ledger.markdownStaleEpochRejections == 0)
        let after = try rig.rows()
        for survivor in survivors {
            #expect(after.contains { $0.id == survivor.id }, "\(survivor.markdownFragment) kept its id through every step")
        }
    }

    // MARK: - (n) model ruling M2: the fire reads the CURRENT text

    @Test("""
        (n)/M2 a fire scheduled with older text T0 does not put it over rows a structural op wrote for T1 (zero writes); \
        with one typed paragraph on top of T1, only that paragraph is written
        """)
    func theFireReadsTheCurrentText() async throws {
        let olderText = Self.base.replacingOccurrences(of: "One.", with: "One, T0 edit.")
        let opText = Self.base.replacingOccurrences(of: "Two.", with: "Two, structural op.")

        // Arm 1: nothing typed after the op.
        let rig = try MarkdownWriterRig(content: Self.base)
        let task = try #require(rig.schedule(olderText), "precondition: the fire was scheduled with T0")
        let sequenceBefore = rig.writer.nextSequence
        rig.editorState.contentState = .structuralUndo
        _ = try rig.db.replaceBlocks(rig.parse(opText), for: rig.pid)   // the op's native rewrite of the rows
        rig.editorState.content = opText                                // its post-op push (dropped by onChange while the op runs)
        rig.editorState.contentState = .idle
        await task.value
        await rig.settle()

        #expect(try rig.storedText() == opText, "T0's edit never landed over T1")
        #expect(rig.writer.nextSequence == sequenceBefore, "zero writes: no turn was reserved")
        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=unchanged") == true)

        // Arm 2: one paragraph typed on top of T1 before the fire runs.
        let typedOn = opText + "\n\nTyped after the op."
        let second = try MarkdownWriterRig(content: Self.base)
        let secondTask = try #require(second.schedule(olderText))
        let secondSequenceBefore = second.writer.nextSequence
        second.editorState.contentState = .structuralUndo
        _ = try second.db.replaceBlocks(second.parse(opText), for: second.pid)
        let idsAfterOp = try second.rows().map(\.id)
        second.editorState.content = typedOn
        second.editorState.contentState = .idle
        await secondTask.value
        await second.settle()

        #expect(try second.storedText() == typedOn)
        #expect(second.writer.nextSequence == secondSequenceBefore + 1, "one write")
        #expect(second.markdownWriter.lastTimingLine?.contains("u/i/d=0/1/0") == true, "only the typed paragraph")
        #expect(try Array(second.rows().map(\.id).prefix(idsAfterOp.count)) == idsAfterOp, "every row the op wrote kept its id")
    }

    // MARK: - (o) judge R4: the no-writer fallback also writes the CURRENT text

    @Test("""
        (o) the fire's no-writer fallback (the whole-document write) writes `editorState.content` read at fire time, not the text \
        captured when the debounce was scheduled (control: with a writer, the same run writes the current text too)
        """, arguments: [true, false])
    func theNoWriterFallbackWritesTheCurrentText(withWriter: Bool) async throws {
        let scheduledText = Self.base.replacingOccurrences(of: "One.", with: "One, scheduled edit.")
        let currentText = Self.base.replacingOccurrences(of: "Two.", with: "Two, current edit.")
        let rig = try MarkdownWriterRig(content: Self.base)
        if !withWriter { rig.sync.writer = nil }

        let task = try #require(rig.schedule(scheduledText), "precondition: the fire was scheduled with the older text")
        rig.editorState.content = currentText   // pushed while the content state was not idle: it did not restart the schedule
        await task.value
        await rig.settle()

        let stored = try rig.storedText()
        #expect(stored == currentText, "the current text is what the database holds (withWriter: \(withWriter))")
        #expect(!stored.contains("One, scheduled edit."), "the older, schedule-time text never landed")
        if !withWriter {
            #expect(rig.markdownWriter.lastTimingLine?.contains("mode=legacy") == true, "the fallback is the whole-document write")
        }
    }
}
