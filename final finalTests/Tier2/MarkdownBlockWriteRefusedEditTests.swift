//
//  MarkdownBlockWriteRefusedEditTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, test U2 (j) with judge verdict 2 note C4 and review M9: edits the database
//  would REFUSE (a hand edit of the generated bibliography, deleting a footnote's definition line in the Notes section)
//  are never sent block by block. While the user types them:
//
//    - the user's ordinary edits in the same text are still written;
//    - the refused edits are not written and the baseline goes back to the stored rows (it never claims text the
//      database lacks), and a normal debounce fire is requested once;
//    - the next fire, whose diff is empty ONLY because of that filtering, stays on rows and schedules nothing (C4).
//
//  The end state is whole-document, as today: one switch to Rich Text (`commitMarkdownTextForRichTextSwitch`), and
//  separately one close (FB), write the whole text, so the document ends exactly as it does without the block-by-block
//  saves.
//

import Foundation
import SwiftUI
import Testing
@testable import final_final

@Suite("Markdown block writes: refused edits — Tier 2 (t-94369a83 Phase 4a, U2 j)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownBlockWriteRefusedEditTests {

    private static let original = [
        "# Intro", "Body paragraph.",
        "# Bibliography", "Smith 2020. First entry.", "Jones 2021. Second entry.", BlockParser.bibliographyEndMarker,
        "# Notes", "[^1]: First note.", "[^2]: Second note."
    ].joined(separator: "\n\n")

    /// The user's ordinary edit, a hand edit of a bibliography entry, and a deleted Notes definition line.
    private static let typed = [
        "# Intro", "Body paragraph, typed.",
        "# Bibliography", "Smith 2020. First entry EDITED BY HAND.", "Jones 2021. Second entry.", BlockParser.bibliographyEndMarker,
        "# Notes", "[^1]: First note."
    ].joined(separator: "\n\n")

    /// What a whole-document write left behind, for comparing end states (ids differ between whole-document writes).
    private func signature(_ blocks: [Block]) -> [String] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(blocks).map {
            "\($0.blockType.rawValue)|bib=\($0.isBibliography)|notes=\($0.isNotes)|\($0.markdownFragment)"
        }
    }

    /// Types and fragments only: the legacy debounced write parses the text WITH the end-of-bibliography marker, the switch
    /// parses it without (it strips the marker first), so their flags are not what this test compares.
    private func fragments(_ blocks: [Block]) -> [String] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(blocks).map { "\($0.blockType.rawValue)|\($0.markdownFragment)" }
    }

    private func typeWithRefusedEdits(_ rig: MarkdownWriterRig) async throws {
        try #require(try rig.rows().contains { $0.isBibliography && $0.markdownFragment.hasPrefix("Smith") }, "premise: the bibliography is flagged")
        try #require(try rig.rows().contains { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]") }, "premise: the Notes definitions are flagged")
        let disposition = await rig.fireAndSettle(Self.typed)
        #expect(disposition == .started, "the user's own edit is still sent")
    }

    // MARK: - Not written per block

    @Test("""
        (j) typing a bibliography hand edit and a deleted Notes line: only the ordinary edit is written, the baseline goes back to rows and \
        a retry is requested once; the next fire, empty only because of the filter, stays on rows and schedules nothing (C4)
        """)
    func refusedEditsAreNotWrittenPerBlock() async throws {
        let rig = try MarkdownWriterRig(content: Self.original)
        try await typeWithRefusedEdits(rig)

        let rows = try rig.rows()
        #expect(rows.contains { $0.markdownFragment == "Body paragraph, typed." }, "the ordinary edit landed")
        #expect(rows.contains { $0.markdownFragment == "Smith 2020. First entry." }, "the bibliography entry was not changed")
        #expect(!rows.contains { $0.markdownFragment.contains("EDITED BY HAND") })
        #expect(rows.contains { $0.markdownFragment == "[^2]: Second note." }, "the Notes definition was not deleted")
        let line = try #require(rig.markdownWriter.lastTimingLine)
        #expect(line.contains("filtered=2") && line.contains("u/i/d=1/0/0"), "got \(line)")
        #expect(rig.markdownWriter.baseline.isRows, "the baseline never claims text the database lacks")
        #expect(rig.refireCount == 1, "one normal debounce fire is requested after a write that carried filtered changes")

        // C4: the same text again. The diff is empty only because everything left is filtered: stays rows, schedules nothing.
        let stampsBefore = try rig.stamps()
        let sequenceBefore = rig.writer.nextSequence
        let again = await rig.fireAndSettle(Self.typed)
        #expect(again == .stayedRows)
        #expect(rig.markdownWriter.baseline.isRows)
        #expect(rig.refireCount == 1, "nothing further was scheduled")
        #expect(rig.writer.nextSequence == sequenceBefore, "nothing reserved")
        #expect(try rig.stamps() == stampsBefore, "nothing written")
        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=filtered-only") == true)
    }

    // MARK: - End state: the switch

    @Test("(j) one switch to Rich Text after typing the refused edits ends exactly as the switch alone does: the whole text is written")
    func switchWritesTheWholeTextLikeTheLegacyPath() async throws {
        let rig = try MarkdownWriterRig(content: Self.original)
        try await typeWithRefusedEdits(rig)
        rig.editorState.sourceContent = Self.typed
        rig.editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())

        // Reference: no block-by-block saves at all, the same switch.
        let reference = try MarkdownWriterRig(content: Self.original)
        reference.editorState.sourceContent = Self.typed
        reference.editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService())
        // And the legacy debounced write of the same text.
        let legacy = try MarkdownWriterRig(content: Self.original)
        ContentSyncObserverHost<EmptyView>.legacyWholeDocumentReparse(
            newValue: Self.typed, db: legacy.db, pid: legacy.pid, editorState: legacy.editorState)

        let ended = signature(try rig.rows())
        #expect(ended == signature(try reference.rows()))
        #expect(fragments(try rig.rows()) == fragments(try legacy.rows()), "and the text matches the legacy debounced write's")
        #expect(ended.contains { $0.hasSuffix("Smith 2020. First entry EDITED BY HAND.") }, "the hand edit is saved by the switch")
        #expect(!ended.contains { $0.contains("[^2]") }, "the deleted definition line is gone")
        #expect(ended.contains { $0.hasSuffix("Body paragraph, typed.") })
    }

    // MARK: - End state: the close

    @Test("(j) one close (FB) after typing the refused edits ends exactly as a close alone does: the whole text is written")
    func closeWritesTheWholeTextLikeTheLegacyPath() async throws {
        let rig = try LifecycleFlushHarness(content: Self.original)
        rig.editorState.editorMode = .source
        rig.editorState.content = Self.typed
        let service = rig.sync
        let started = rig.editorState.markdownWriter.prepareAndStart(
            text: Self.typed, database: rig.db, projectId: rig.pid, service: service, refire: {})
        #expect(started == .started)
        while let pending = rig.editorState.markdownWriter.inFlight { await pending.value }
        try #require(try !rig.paragraphTexts().contains { $0.contains("EDITED BY HAND") }, "premise: the hand edit was not written per block")
        rig.fetchAnswer = Self.typed

        let result = await rig.run(.close)

        #expect(result.outcome == .flushed)
        #expect(result.fbOutcome == .applied)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "no barrier left open")

        let reference = try LifecycleFlushHarness(content: Self.original)
        reference.editorState.editorMode = .source
        reference.fetchAnswer = Self.typed
        let referenceResult = await reference.run(.close)
        #expect(referenceResult.fbOutcome == .applied)

        let ended = signature(try rig.blocks())
        #expect(ended == signature(try reference.blocks()))
        #expect(ended.contains { $0.hasSuffix("Smith 2020. First entry EDITED BY HAND.") })
        #expect(!ended.contains { $0.contains("[^2]") })
    }
}
