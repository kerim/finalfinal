//
//  TypingAcrossUndoSwiftTests.swift
//  final finalTests
//
//  Tier 2 (t-d2061b27, Phase 4c job 2, coder S round S1): the Swift side of "a Cmd-Z that waits keeps waiting when the user types, then
//  runs on the document as it was at the press with the typing put back on top" in RICH TEXT. The page does the work (web/milkdown/src/
//  typing-rebase.ts, tested in vitest); these tests are about what SWIFT does with the page's reply, against the scripted stand-in editor
//  (`EditorFirstRig`): so they can show that the Swift handling is right, never that the page's replay is (the web tests and the VM tests
//  do that).
//
//    - TA-1  a quick undo whose reply says `typingReplayed` ends the redo branch inside the gate, no notice, no alert
//    - TA-2  a quick undo with no such flag keeps the redo branch (the control that makes TA-1 not vacuous)
//    - TA-3  a slow undo whose reply says `typingReplayed` (empty batch) ends the redo branch
//    - TA-4  a slow REDO whose reply says `typingReplayed` ends the whole redo branch, the older entries under it too
//    - TA-5  a quick redo the editor refuses (`docChanged`, the typing sits inside the text it takes out) with a NON-empty batch applies
//            the batch (the typing reaches the rows once) and shows the existing notice
//    - TA-6  a quick redo that runs after typing elsewhere (`ok: true`, the typing as batch N, no `typingReplayed`) is performed and
//            the typing reaches the rows once
//    - D1    a close releases the typing the editor held for a waiting Cmd-Z BEFORE its drain and forced poll
//
//  Break patches (1 to 5 lines in production code that must make the test fail) are in .claude/superdev/cmdz-waits-through-typing/
//  break-patches/SW-<test id>.patch. NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Typing across a waiting Cmd-Z, Swift side, Rich Text (t-d2061b27, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct TypingAcrossUndoSwiftTests: QuickUndoFixtures {

    private static var noticeText: String { "Some undo or redo presses could not be carried out." }

    /// A rig on `fourSections` whose undo is forced onto the slow path.
    private func slowRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.controller.testForceSlowDeleteUndo = true
        return rig
    }

    /// The jobs pin the snapshots they write: unpin everything this rig's project holds when the test ends.
    private static func unpinSnapshots(of rig: EditorFirstRig) {
        for snapshot in (try? SnapshotService(database: rig.db, projectId: rig.pid).fetchAllSnapshots()) ?? [] {
            SnapshotService.unpinUndoPointSnapshot(snapshot.id)
        }
    }

    /// The last descriptor the controller sent the editor (`setUndoDescriptor({...})`), as text.
    private func lastDescriptor(_ rig: EditorFirstRig) -> String? {
        rig.scripts(containing: "setUndoDescriptor").last
    }

    // MARK: - TA-1 and TA-2: the quick undo

    // TA-1: the page says the typing done during the wait was put back on top (`typingReplayed`, empty batch). The redo branch ends in the
    // gate (the page's replay posts no `historyEdited`, and the stand-in's "live differs from restored" answer is false on purpose, so
    // only the FLAG can end it), the press is performed, no notice, no alert, and the editor is told (the descriptor has no redo).
    // Predicted failure with `endRedoAfterReplayedTyping` an empty body: "the redo branch was not ended by the replayed typing".
    @Test("TA-1: a quick undo whose reply says the typing was put back on top ends the redo branch, with no notice")
    func testQuickUndoThatReplayedTypingEndsTheRedoBranch_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.quickUndoReplaysTyping = true
        rig.liveDiffersOverride = false   // the text compare cannot rescue the branch: only the flag ends it

        #expect(await rig.pressAndSettle(deleted.entry))
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        // Review T-b: the test can fail. The stand-in honours `liveDiffersOverride` (the old text compare answers false here), so only the
        // flag can end the branch; and the flag ends it WITHOUT asking the page (with the flag ignored the query is made and answers false:
        // SW-TA-1-quick-undo-ignores-flag.patch makes both of the next two checks fail, as does SW-endRedoAfterReplayedTyping-empty).
        #expect(!rig.liveDiffersFromRestored, "premise: the text compare would NOT end the branch")
        #expect(rig.scripts(containing: "quickUndoLiveDiffersFromRestored").isEmpty, "the flag must end the branch without asking the page")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the redo branch was not ended by the replayed typing")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the entry stayed on the undo stack although the undo was performed")
        let descriptor = lastDescriptor(rig)
        #expect(
            descriptor != nil && descriptor?.contains("redoTopOpId") == false,
            "the editor still thinks a redo exists: \(String(describing: descriptor))")
        #expect(rig.toasts.current?.message != Self.noticeText, "typing is not a reason for the notice")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        #expect(try rig.presentRowCount(deleted.subtree) == deleted.subtree.count, "the section is not back in the rows")
        #expect(rig.editorState.pendingReinsertCount == 0)
    }

    // TA-2: the control. The same quick undo with no flag keeps the entry on the redo stack (nothing typed, nothing ended).
    @Test("TA-2: a quick undo with no replayed typing keeps the redo branch (the control for TA-1)")
    func testQuickUndoWithoutReplayedTypingKeepsTheRedoBranch_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.liveDiffersOverride = false

        #expect(await rig.pressAndSettle(deleted.entry))
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "the entry is not on the redo stack")
        #expect(lastDescriptor(rig)?.contains("redoTopOpId") == true, "the editor was not told about the redo")
    }

    // MARK: - TA-3 and TA-4: the slow undo and redo

    // TA-3: a slow undo whose reply says `typingReplayed` (empty batch, the replay is the only carrier) ends the redo branch.
    // Predicted failure with `endRedoAfterReplayedTyping` an empty body: "the redo branch was not ended by the replayed typing".
    @Test("TA-3: a slow undo whose reply says the typing was put back on top ends the redo branch, with no notice")
    func testSlowUndoThatReplayedTypingEndsTheRedoBranch() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let deleted = try await delete(rig, "Section A")
        rig.swapReplaysTyping = true

        #expect(await rig.pressAndSettle(deleted.entry)); _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "Section A is not back")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the redo branch was not ended by the replayed typing")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the entry stayed on the undo stack although the undo was performed")
        let descriptor = lastDescriptor(rig)
        #expect(
            descriptor != nil && descriptor?.contains("redoTopOpId") == false,
            "the editor still thinks a redo exists: \(String(describing: descriptor))")
        #expect(rig.toasts.current?.message != Self.noticeText, "typing is not a reason for the notice")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0)
    }

    // TA-4: two entries undone, then the top one redone by a slow redo whose reply says the typing was put back on top: the entry goes
    // back to the undo stack and the OLDER redo entry under it is ended too (typing after the press ends the whole redo branch).
    // Predicted failure with `endRedoAfterReplayedTyping` an empty body: "the older redo entry survived the typing".
    @Test("TA-4: a slow redo whose reply says the typing was put back on top ends the whole redo branch, the older entries too")
    func testSlowRedoThatReplayedTypingEndsTheWholeRedoBranch() async throws {
        let rig = try slowRig()
        defer { Self.unpinSnapshots(of: rig) }
        let first = try await delete(rig, "Section A")
        let second = try await delete(rig, "Section B")
        try await restorePress(rig, .undo)   // Section B back
        try await restorePress(rig, .undo)   // Section A back
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [second.entry.id, first.entry.id], "premise: two entries wait for a redo")
        rig.swapReplaysTyping = true

        try await restorePress(rig, .redo)

        #expect(rig.replyWords().last == "redo performed", "got \(rig.replyWords())")
        #expect(rig.unifiedUndo.undoStack.last?.id == first.entry.id, "the redone entry is not back on the undo stack")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "the older redo entry survived the typing")
        #expect(rig.toasts.current?.message != Self.noticeText, "typing is not a reason for the notice")
    }

    // MARK: - TA-5 and TA-6: the quick redo

    // TA-5 (contract section 8): a quick redo of Delete Section REFUSED because the typing sits inside the text it takes out comes from
    // the operation itself, so its reply carries the pending edit: `ok: false`, `docChanged`, and a NON-empty batch (the typing, once).
    // Swift applies the batch as it does for every other refusal of the call, shows the existing notice, and leaves the entry on the
    // redo stack.
    // Predicted failure with the batch not applied on a refusal: "the typing the refused redo handed back never reached the rows".
    @Test("TA-5: a quick redo the editor refuses with the typing as its batch applies the batch, shows the notice and keeps the entry")
    func testRefusedQuickRedoWithTheTypingAsItsBatchApplesTheBatch() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(deleted.entry))
        _ = await rig.waitUntilSettled()
        let paragraph = try #require(rig.blocks().first { $0.textContent == "The B body." })
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The B body. KEPT", markdownFragment: "The B body. KEPT", headingLevel: nil)])
        try rig.setReply(.init(batch: typed, succeeded: false, reason: "docChanged", removedLeaderIds: []), forRoot: deleted.root.id)

        #expect(await rig.pressAndSettle(deleted.entry, .redo))
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed", "redo failed"], "got \(rig.replyWords())")
        #expect(rig.toasts.current?.message == Self.noticeText, "the refused redo showed no notice")
        let kept = await gateWaitUntil({ (try? rig.blocks().first { $0.id == paragraph.id }?.textContent == "The B body. KEPT") == true })
        #expect(kept, "the typing the refused redo handed back never reached the rows")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "the entry left the redo stack")
        #expect(try rig.presentRowCount(deleted.subtree) == deleted.subtree.count, "the refused redo deleted the section")
    }

    // TA-6: a quick redo that RUNS after typing elsewhere: `ok: true`, the typing as batch N, no `typingReplayed`. Performed; the typing
    // reaches the rows once (the batch is applied by the same road as every other reply's batch).
    @Test("TA-6: a quick redo that ran after typing elsewhere is performed and the typing it handed back reaches the rows once")
    func testQuickRedoThatRanAfterTypingElsewhereIsPerformedAndTheTypingIsKept() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(deleted.entry))
        _ = await rig.waitUntilSettled()
        let paragraph = try #require(rig.blocks().first { $0.textContent == "The B body." })
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: "The B body. KEPT", markdownFragment: "The B body. KEPT", headingLevel: nil)])
        try rig.setReply(.init(batch: typed, removedLeaderIds: [deleted.root.id]), forRoot: deleted.root.id)

        #expect(await rig.pressAndSettle(deleted.entry, .redo))
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
        #expect(rig.toasts.current?.message != Self.noticeText, "typing elsewhere is not a reason for the notice")
        let kept = await gateWaitUntil({ (try? rig.blocks().first { $0.id == paragraph.id }?.textContent == "The B body. KEPT") == true })
        #expect(kept, "the typing the redo handed back never reached the rows")
        #expect(try rig.blocks().filter { $0.textContent == "The B body. KEPT" }.count == 1, "the typing reached the rows more than once")
        #expect(try rig.presentRowCount(deleted.subtree) == 0, "the redo did not take the section out again")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id, "the entry is not back on the undo stack")
    }

    // MARK: - D1: the lifecycle releases the held typing

    // D1 (judge round 3): while a Cmd-Z waits, the Rich Text page holds the typing it would report to the polls. A close (or quit, or
    // project switch) must release that hold BEFORE its drain and forced poll, or the typing done during the wait would miss the closing
    // save through the poll. The scripted editor records the call; the order is what is asserted.
    // Predicted failure with the release taken out of `forceSendForLifecycle`: "the lifecycle never asked the editor to release the held typing".
    @Test("D1: a close asks the editor to release the typing it held for a waiting Cmd-Z before it drains and polls")
    func testCloseReleasesTheHeldTypingPushesBeforeTheForcedPoll() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }

        let result = await rig.runLifecycle(.close, bounds: .production)

        #expect(result.outcome == .flushed, "premise: the close ran to the end: \(result.outcome)")
        let scripts = rig.js.scripts
        let release = scripts.firstIndex { $0.contains("releaseHeldTypingPushes") }
        #expect(release != nil, "the lifecycle never asked the editor to release the held typing")
        let firstPoll = scripts.firstIndex { $0.contains("BlockChanges") }
        if let release, let firstPoll {
            #expect(release < firstPoll, "the release came after the forced poll (script \(release) vs \(firstPoll))")
        }
        #expect(scripts.filter { $0.contains("releaseHeldTypingPushes") }.count == 1, "the release must be asked for once")
    }
}
