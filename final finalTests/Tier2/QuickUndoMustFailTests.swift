//
//  QuickUndoMustFailTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b, plan-v2-addendum 6.1, verdict-v1 item 15): the MUST-FAIL REPRODUCTIONS of "Cmd-Z after an
//  editor-first Delete Section is slow and loses typing". They use ONLY the API of the code before the quick undo existed
//  (`EditorFirstRig`, `handleStructuralRequest`, `holdQueue`, `testEFSettleHold`, `events`, `scripts(containing:)`, `registerRebuildTask`,
//  `handleHistoryEdited`), so this file compiles with the production change taken out; the driver runs it there to see each test fail
//  on the assertion named in its title and message, and with the change in to see it pass.
//
//  Shape (verdict-v1 item 15, M17): every press runs in a CHILD task, the edits the user types during the undo are injected right
//  after the press is sent (a rig batch through the poll path, `contentChanged` produced the way the rig produces it), then the hold
//  is released, and every wait is bounded (at most 5 s), so today's code fails on an assertion, never on a deadlock.
//
//  The quick path's calls are answered by the rig (`EditorFirstRig.answerQuickUndo`, `noteResume`): where today's code never makes
//  them, the bounded waits for them just time out and the test goes on to its assertion about the document.
//
//  NOT RUN by the coder against today's code: the driver does that (reverse-applying the production change).
//

import Foundation
import GRDB
import Testing
@testable import final_final

/// A press, or a poll, running in a child task: `done` is what a bounded wait reads.
@MainActor
final class QuickUndoChildRun {
    var done = false
}

@Suite("Quick undo — must-fail reproductions (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(4)))
@MainActor
struct QuickUndoMustFailTests {

    // MARK: - Helpers

    /// Cmd-Z or Cmd-Shift-Z for `entry`, in a child task.
    private func press(
        _ rig: EditorFirstRig, _ entry: StructuralEntry, _ direction: StructuralUndoController.UndoDirection = .undo
    ) -> QuickUndoChildRun {
        let run = QuickUndoChildRun()
        Task { @MainActor in
            await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: direction)
            run.done = true
        }
        return run
    }

    /// One routine poll cycle, in a child task (it fetches what `typeIntoEditor` queued and applies it through the writer).
    private func poll(_ rig: EditorFirstRig) -> QuickUndoChildRun {
        let run = QuickUndoChildRun()
        Task { @MainActor in
            await rig.sync.pollBlockChangesForTest()
            run.done = true
        }
        return run
    }

    /// Waits at most 5 s for every run to end.
    private func allEnd(_ runs: [QuickUndoChildRun]) async -> Bool {
        await gateWaitUntil({ runs.allSatisfy(\.done) }, iterations: 1000)
    }

    /// The first plain paragraph (its text is its Markdown) among `ids`.
    private func firstParagraph(in ids: [String], _ rig: EditorFirstRig) throws -> Block {
        let wanted = Set(ids)
        return try #require(try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.first {
            wanted.contains($0.id) && $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography
                && $0.textContent == $0.markdownFragment && !$0.textContent.contains("[") && $0.textContent.count > 20
        })
    }

    /// The first plain paragraph that is NOT among `ids`, after the document's second chapter (so the delete of the first never
    /// touches it).
    private func paragraphOutside(_ ids: [String], _ rig: EditorFirstRig) throws -> Block {
        let excluded = Set(ids)
        let second = try #require(try rig.chapterHeadings().dropFirst().first)
        return try #require(try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.first {
            $0.sortOrder > second.sortOrder && !excluded.contains($0.id) && $0.blockType == .paragraph && !$0.isNotes
                && !$0.isBibliography && $0.textContent.count > 20
        })
    }

    // MARK: - U-Q1

    @Test("U-Q1: Cmd-Z puts the section back in the editor at once, while the delete's own job is still queued")
    func testUndoRestoresWhileTheDeleteJobIsHeld_book6() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        let chapter = try #require(try rig.chapterHeadings().first)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: chapter.id, projectId: rig.pid))
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }   // the delete job waits behind this sequence: it cannot apply until the test says so
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        let undo = press(rig, entry)
        let restored = await gateWaitUntil({ !rig.scripts(containing: "undoSectionDeleteEditorFirst").isEmpty }, iterations: 200)
        #expect(restored, "no editor restore within 1.0 s while the delete's job was held")

        rig.release(blocker)
        let ended = await allEnd([undo])
        #expect(ended, "the press did not end within 5 s of the job being released")
        _ = await rig.waitUntilSettled()
        let after = Set(try rig.blocks().map(\.id))
        let missing = subtree.filter { id in !after.contains(id) }.count
        #expect(missing == 0, "the section's rows are back in the database once everything has settled (\(missing) rows missing)")
    }

    // MARK: - U-Q2

    @Test("U-Q2: text typed into the restored section while the delete's job is still queued is saved")
    func testTypingIntoRestoredSectionIsSaved_book6() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        let chapter = try #require(try rig.chapterHeadings().first)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: chapter.id, projectId: rig.pid))
        let paragraph = try firstParagraph(in: subtree, rig)
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        let undo = press(rig, entry)
        // The quick path's press ends at once (the reinsert is reserved, the editor may queue typing again); today's code is still
        // waiting for the job, and this wait just ends after a second.
        _ = await gateWaitUntil({ undo.done }, iterations: 200)
        rig.typeIntoEditor(paragraph, appending: " TYPED-Q2")
        let typing = poll(rig)
        rig.release(blocker)
        let ended = await allEnd([undo, typing])
        #expect(ended, "the press and the poll did not both end within 5 s of the job being released")
        _ = await rig.waitUntilSettled()

        let text = try rig.blocks().first { $0.id == paragraph.id }?.textContent ?? "<row missing>"
        #expect(text.contains("TYPED-Q2"), "expected database to contain \"TYPED-Q2\", the restored paragraph holds \"\(text)\"")
    }

    // MARK: - U-Q13

    @Test("U-Q13: from the press to its reply, no whole-document write reaches the editor")
    func testNoWholeDocumentEditorWriteDuringUndo_book6() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        // The slow path's checkpoint swap puts the document as it was back into the editor (the rig's stand-in for the editor).
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        let chapter = try #require(try rig.chapterHeadings().first)
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        let undo = press(rig, entry)
        let ended = await allEnd([undo])
        #expect(ended, "the press did not end within 5 s")
        _ = await rig.waitUntilSettled()

        // A whole-document write: the checkpoint swap (`performStructuralSwap`), a block-id push over the whole document, or a
        // whole-content push (not the merge-guarded push of the Notes and Bibliography). Counted up to the press's reply.
        let events = rig.events.items
        let replyIndex = events.firstIndex { $0.hasPrefix("js ") && $0.contains("receiveUndoOutcome") } ?? events.count
        let wholeDocumentWrites = events[..<replyIndex].filter {
            $0.contains("performStructuralSwap") || $0 == "pushBlockIds" || $0 == "setContent preserve=false"
        }
        #expect(wholeDocumentWrites.isEmpty, "expected 0 whole-document editor writes, got \(wholeDocumentWrites.count): \(wholeDocumentWrites)")
        #expect(rig.scripts(containing: "receiveUndoOutcome").first?.contains("'performed'") == true, "the press was carried out")
    }

    // MARK: - U-Q14 (S1)

    @Test("U-Q14: a text edit after the undo (it empties the redo branch) neither drops the section nor the typing that follows")
    func testHistoryEditBeforeReinsertKeepsSectionAndTyping_book6() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        let chapter = try #require(try rig.chapterHeadings().first)
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: chapter.id, projectId: rig.pid))
        let elsewhere = try paragraphOutside(subtree, rig)
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        let undo = press(rig, entry)
        // The press ends at once on the quick path (the reinsert is reserved, not applied); today's code is still waiting for the job.
        _ = await gateWaitUntil({ undo.done }, iterations: 200)
        // The editor's first text edit after the undo: it empties the redo branch, which discards the entry's slot while the reinsert
        // is still queued. (Today's code is still running the undo, and ignores it.)
        await rig.controller.handleHistoryEdited()
        rig.typeIntoEditor(elsewhere, appending: " KEPT-S1")
        let typing = poll(rig)
        rig.release(blocker)
        let ended = await allEnd([undo, typing])
        #expect(ended, "the press and the poll did not both end within 5 s of the job being released")
        _ = await rig.waitUntilSettled()

        let rows = try rig.blocks()
        let typedText = rows.first { $0.id == elsewhere.id }?.textContent ?? "<row missing>"
        #expect(typedText.contains("KEPT-S1"), "expected database to contain \"KEPT-S1\", the paragraph holds \"\(typedText)\"")
        let present = Set(rows.map(\.id))
        let missingRows = subtree.filter { id in !present.contains(id) }.count
        #expect(missingRows == 0, "expected the section's rows in the database (\(missingRows) of \(subtree.count) missing)")
    }

    // MARK: - U-Q15 (S3)

    @Test("U-Q15: the footnote texts of a delete whose resync renumbered them are left alone by the undo, and typing during it is kept")
    func testQuickUndoLeavesFootnoteTextsAlone_article() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.article.editorMarkdown, lifecycleServices: true)
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        let notesBefore = try notesTexts(rig)
        let root = try rig.heading("1.2 The Village Registers")
        let subtree = try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid))
        let elsewhere = try anyParagraphOutside(subtree, rig)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        // As the other article tests: the delete's follow-up work finds the post-delete text in `content`, so its footnote resync
        // really renumbers the references and cleans the Notes.
        rig.controller.testEFSettleHold = { [weak rig] in _ = try? rig?.syncEditorContentFromDatabase() }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()
        rig.editorText = rig.editorState.content   // the editor shows the post-delete document
        #expect(try notesTexts(rig) != notesBefore, "precondition: the delete's resync changed the Notes")

        // A rebuild stand-in keeps today's undo waiting at its entry (every structural command waits for running rebuilds there), so
        // typing "during the undo" is deterministic on both paths; the quick path does not wait for it.
        let rebuildMayLand = LifecycleEntryHarness.Gate()
        defer { rebuildMayLand.open() }
        rig.editorState.registerRebuildTask(Task { @MainActor in await rebuildMayLand.wait() })
        rig.emulatesFootnoteContentChange = true

        let undo = press(rig, entry)
        _ = await gateWaitUntil({ undo.done }, iterations: 200)
        rig.typeIntoEditor(elsewhere, appending: " KEPT-S3")
        let typing = poll(rig)
        rebuildMayLand.open()
        let ended = await allEnd([undo, typing])
        #expect(ended, "the press and the poll did not both end within 5 s")
        _ = await rig.waitUntilSettled()
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)

        #expect(
            rig.editorState.content.contains("KEPT-S3") && (rig.editorText ?? "").contains("KEPT-S3"),
            "expected editor content to contain \"KEPT-S3\"")
        #expect(try notesTexts(rig) == notesBefore, "every Notes definition text is unchanged by the undo")
        #expect(rig.footnotes.undoCheckpoints.isEmpty, "the undo leaves no footnote checkpoint armed: \(rig.footnotes.undoCheckpoints.count)")
    }

    /// The text of every Notes definition row, in document order.
    private func notesTexts(_ rig: EditorFirstRig) throws -> [String] {
        try rig.blocks().filter { $0.isNotes && $0.blockType != .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.textContent)
    }

    /// `paragraphOutside` for a document whose chapters are not the unit of the test (the article has one chapter): the first plain
    /// paragraph that is not among `ids`.
    private func anyParagraphOutside(_ ids: [String], _ rig: EditorFirstRig) throws -> Block {
        let excluded = Set(ids)
        return try #require(try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }.first {
            !excluded.contains($0.id) && $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography && $0.textContent.count > 20
        })
    }
}
