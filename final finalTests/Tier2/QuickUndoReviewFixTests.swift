//
//  QuickUndoReviewFixTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b, the code-review round: verdict-code-v1.md section (iii), S2 items 1-5): the guards of the
//  review fixes S1-1, S1-2, S1-3 and S1-7, each reddened by its own break (swift-break-map.md):
//    - U-Q15d (S1-1, sw50)   a footnote deleted after the quick undo keeps its undo checkpoint
//    - U-Q29  (S1-2, sw51, sw53)  two entries: another entry's quick undo ends a settle that works from older text
//    - U-Q29b (S1-2, sw52)   a redo during the reinsert settle's live read adopts no stale text
//    - U-Q31  (S1-3, sw54, sw55)  a flush during the quick redo waits for the redo job; a refused redo keeps the undo's hold
//    - U-Q28  (S1-7, sw59)   text typed during the quick undo drops the redo branch
//  Shared helpers: QuickUndoFixtures.swift; the rig: EditorFirstRig+QuickUndo.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: the code-review fixes (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoReviewFixTests: QuickUndoFixtures {

    private static let singleFootnote = "# A\n\nBody text[^1] end.\n\n# Notes\n\n[^1]: Kept definition."
    private static let singleFootnoteDeleted = "# A\n\nBody text end.\n\n# Notes\n\n[^1]: Kept definition."
    private static let singleFootnoteUndone = "# A\n\nBody text[^1] end."

    // MARK: - U-Q15d (S1-1)

    @Test("U-Q15d (S1-1): a footnote reference deleted after a quick undo, while its hold is active, still records its undo checkpoint")
    func testFootnoteDeletedAfterQuickUndoKeepsItsCheckpoint() async throws {
        let rig = try EditorFirstRig(markdown: Self.singleFootnote, lifecycleServices: true)
        let service = rig.footnotes
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: Self.singleFootnote)
        await service.flushPendingSync()   // the first write: `lastKnownRefs == ["1"]`
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: Self.singleFootnote)   // the content seen
        let token = UUID()
        service.holdUndoCheckpoints(token: token)   // the quick undo's first stretch

        service.checkAndUpdateFootnotes(footnoteRefs: [], projectId: rig.pid, fullContent: Self.singleFootnoteDeleted)
        await service.fireBurst(deadline: ContinuousClock.now)   // the burst's deadline arrives while the hold is still active
        let notesLeft = try rig.blocks().filter(\.isNotes).count
        #expect(notesLeft == 0, "precondition: the burst's write removed the Notes")
        #expect(
            service.undoCheckpoints.count == 1,
            "expected the deleted reference's checkpoint to be recorded although the hold is active, got \(service.undoCheckpoints.count)")

        service.releaseUndoCheckpointHold(token: token)   // the reinsert settle ends
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: Self.singleFootnoteUndone)   // Cmd-Z
        await service.flushPendingSync()   // waits for the restore
        let definitions = try rig.blocks().filter { $0.isNotes && $0.blockType == .paragraph }.map(\.markdownFragment)
        #expect(
            definitions.contains { $0.contains("Kept definition.") },
            "expected definition text \"Kept definition.\", got \"\(definitions.joined(separator: " | "))\"")
    }

    // MARK: - U-Q28 (S1-7)

    private func expectRedoBranchDropped(_ rig: EditorFirstRig, _ context: String) {
        #expect(rig.replyWords() == ["undo performed"], "\(context): got \(rig.replyWords())")
        #expect(rig.unifiedUndo.redoStack.isEmpty, "\(context): expected the redo stack to be empty, got a redo entry")
        let descriptor = rig.scripts(containing: "setUndoDescriptor").last ?? ""
        #expect(!descriptor.contains("redoTopOpId"), "\(context): expected the descriptor to carry no redoTopOpId: \(descriptor)")
    }

    @Test("U-Q28 (S1-7): text typed while the quick undo is paused drops the redo branch, so Cmd-Shift-Z cannot delete the section again")
    func testTypingDuringQuickUndoInvalidatesRedo_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let elsewhere = try paragraphOutside(deleted.subtree, rig)
        // The window `FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS` opens: block-sync is paused, the writer is free, the user types.
        rig.controller.testQuickUndoResumeHold = { [weak rig] in rig?.typeIntoEditor(elsewhere, appending: " TYPED-Q28") }

        #expect(await rig.pressAndSettle(deleted.entry))

        expectRedoBranchDropped(rig, "typed during the window")
        #expect(rig.editorState.content.contains("TYPED-Q28"), "the typing is on the screen")
    }

    @Test("U-Q28 (S1-7, second case): no paused edit was reported, but the live document differs from the restored one (the bridge says so)")
    func testLiveDocumentDifferingAfterQuickUndoInvalidatesRedo_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        rig.liveDiffersOverride = true

        #expect(await rig.pressAndSettle(deleted.entry))

        expectRedoBranchDropped(rig, "the bridge answered true")
    }

    @Test("U-Q28 (control): with nothing typed the redo branch stays, and the descriptor names the redo entry")
    func testQuickUndoWithoutTypingKeepsTheRedoBranch_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)

        #expect(await rig.pressAndSettle(deleted.entry))

        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "the entry waits on the redo stack")
        let descriptor = rig.scripts(containing: "setUndoDescriptor").last ?? ""
        #expect(descriptor.contains("redoTopOpId"), "the descriptor names the redo entry: \(descriptor)")
    }

    // MARK: - U-Q29 (S1-2)

    /// The article's first two footnoted sections (A first, B after it) and what the document looked like before either was deleted.
    private struct TwoSections {
        let first: (heading: Block, references: Int)
        let second: (heading: Block, references: Int)
        let before: String
    }

    private func twoFootnotedSections(_ rig: EditorFirstRig) throws -> TwoSections {
        let before = try rig.assembledMarkdown()
        let sections = try footnotedSections(rig)
        let first = try #require(sections.first, "the article has a footnoted section")
        let second = try #require(sections.dropFirst().first, "and a second one")
        return TwoSections(first: first, second: second, before: before)
    }

    @Test("U-Q29 (G-F1): a settle waiting inside the footnote resync when ANOTHER entry's quick undo runs does not renumber from older text")
    func testUndoTwiceQuicklyDoesNotRenumberFromStaleContent_article() async throws {
        let rig = try makeArticleRig()
        let sections = try twoFootnotedSections(rig)
        // Both deletes' settles are parked at their start; the text they will read is the post-delete one of BOTH sections.
        let settlesMayGo = QuickUndoMultiGate()   // both deletes' settles wait here
        defer { settlesMayGo.open() }
        rig.controller.testEFSettleHold = { await settlesMayGo.wait() }
        let deletedA = try await delete(rig, sections.first.heading.textContent, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deletedA.entry.id)
        let deletedB = try await delete(rig, sections.second.heading.textContent, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deletedB.entry.id)
        rig.withholdContentUpdate = true   // B's restore will not update `content`: it stays the post-delete text of both
        try rig.syncEditorContentFromDatabase()
        let staleContent = rig.editorState.content

        // A write of the test's own, parked behind a held ticket, keeps the footnote service busy: the settles then wait INSIDE the
        // footnote resync (past the call site's check), which is where another entry's quick undo catches them.
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        let busyWrite = Task { @MainActor in
            await rig.footnotes.resyncNow(
                footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: staleContent), projectId: rig.pid, fullContent: staleContent)
        }
        #expect(await gateWaitUntil { rig.footnotes.state == .syncing }, "precondition: the footnote service is busy")
        settlesMayGo.open()
        try await Task.sleep(for: .milliseconds(300))   // a margin: the settles are now inside the wait

        let undoB = rig.startPress(deletedB.entry)
        #expect(await rig.awaitRuns([undoB]), "the quick undo of B does not wait for the footnote service")
        rig.release(blocker)
        await busyWrite.value
        let firstSettled = await rig.waitUntilSettled(iterations: 1500)
        let registry = rig.editorState.efJobRegistry
        func diagnosis() -> String {
            let running = [deletedA, deletedB].map { rig.controller.efSettleTasks[$0.entry.id] != nil }
            let pending = rig.editorState.pendingReinsertCount
            return "outstanding \(registry.outstandingCount), unsettled \(registry.unsettledCount), delete settles running \(running), "
                + "pending reinserts \(pending), footnotes \(rig.footnotes.state), bibliography \(rig.bibliography.state), "
                + "last events \(rig.events.items.suffix(6))"
        }
        #expect(firstSettled, "everything settled after B's undo (\(diagnosis()))")

        // A is still deleted, B is back: every reference has its definition (A's settle did not remove B's definitions from older text).
        let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        let originalReferences = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: sections.before).references.count
        let expected = originalReferences - sections.first.references
        let found = "\(labels.references.count) references and \(labels.definitions.count) definitions"
        #expect(
            labels.references.count == expected && labels.definitions.count == expected,
            "expected \(expected) references with their definitions, got \(found)")

        let undoA = rig.startPress(deletedA.entry)
        let endedA = await rig.awaitRuns([undoA])
        let settledA = await rig.waitUntilSettled(iterations: 1500)
        #expect(endedA && settledA, "the second undo ended (\(endedA)) and everything settled (\(settledA); \(diagnosis()); \(rig.replyWords()))")
        #expect(try rig.documentDiff(sections.before) == nil, "after the second undo the rows are the pre-delete rows")
    }

    @Test("U-Q29 (second case): B's reinsert settle, with its live read still out, stands down when ANOTHER entry's quick undo starts meanwhile")
    func testSettleWithALiveReadOutStandsDownForAnotherEntrysUndo_article() async throws {
        let rig = try makeArticleRig()
        let sections = try twoFootnotedSections(rig)
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        let deletedA = try await delete(rig, sections.first.heading.textContent)
        let deletedB = try await delete(rig, sections.second.heading.textContent)
        // The first live read (B's settle) is answered at once by the editor but its reply is delayed: it is as old as its JS turn.
        let readMayEnd = LifecycleEntryHarness.Gate()
        defer { readMayEnd.open() }
        let reads = GateOrderLog()
        rig.getContentHold = {
            reads.note("read")
            if reads.items.count == 1 { await readMayEnd.wait() }
        }
        let undoB = rig.startPress(deletedB.entry)
        #expect(await rig.awaitRuns([undoB]))
        #expect(await gateWaitUntil { reads.items.count == 1 }, "B's settle is waiting for its live read")

        let undoA = rig.startPress(deletedA.entry)   // another entry's quick undo starts while B's read is out
        #expect(await rig.awaitRuns([undoA]))
        let restoreOfA = try #require(rig.events.items.lastIndex { $0.contains("undoSectionDeleteEditorFirst") })
        readMayEnd.open()
        _ = await rig.waitUntilSettled()

        let afterA = rig.events.items[restoreOfA...].filter { $0 == "setContent preserve=true" }.count
        #expect(afterA == 1, "expected the resync of B's settle to be skipped once A's quick undo had started: \(afterA) pushes after A's restore")
        #expect(try rig.documentDiff(sections.before) == nil, "both sections are back, exactly as they were")
    }

    // MARK: - U-Q29b (S1-2b)

    @Test("U-Q29b (G-F1): a quick redo that runs while the reinsert settle's live read is out: the older text is not adopted as content")
    func testRedoDuringReinsertSettleAdoptsNoStaleText_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let readMayEnd = LifecycleEntryHarness.Gate()
        defer { readMayEnd.open() }
        rig.getContentHold = { await readMayEnd.wait() }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        #expect(await gateWaitUntil { rig.getContentCalls >= 1 }, "the settle is waiting for its live read (the restored text, section included)")

        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await rig.awaitRuns([redo]))
        readMayEnd.open()
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
        #expect(
            !rig.editorState.content.contains(deleted.root.textContent),
            "expected editorState.content without the removed section after the redo, got content holding the section (stale text adopted)")
    }

    // MARK: - U-Q31 (S1-3)

    @Test("U-Q31 (C-M3): a flush that starts while the quick redo's JavaScript is out waits for the redo's job and its settle")
    func testFlushDuringQuickRedoRoundTripWaitsForTheRedoJob_book6() async throws {
        let rig = try makeBookRig()
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        let deleted = try await delete(rig)
        #expect(await rig.pressAndSettle(deleted.entry))
        let replyMayGo = LifecycleEntryHarness.Gate()
        defer { replyMayGo.open() }
        rig.quickRedoReplyHold = { await replyMayGo.wait() }
        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await gateWaitUntil { !rig.quickRedoScripts.isEmpty }, "the redo's JavaScript is out and its reply is held")

        let flush = Task { @MainActor in
            await rig.editorState.flushLiveContentToDatabase { [weak rig] in rig?.quickEditorText }
            rig.events.note("flush done")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!rig.events.items.contains("flush done"), "the flush waits for the redo's job: its marker is registered in the first stretch")

        replyMayGo.open()
        #expect(await rig.awaitRuns([redo]))
        await flush.value
        _ = await rig.waitUntilSettled()

        let events = rig.events.items
        let jobSettled = try #require(events.lastIndex(of: "spy efJobSettled"))
        let idPush = try #require(events.lastIndex(of: "pushBlockIds"))
        #expect(jobSettled < idPush, "expected the flush's whole-document write after the redo job's settle, got it before")
    }

    @Test("U-Q31 (sibling): a refused quick redo leaves the undo's checkpoint hold in place, so a late delete-resync write records no checkpoint")
    func testRefusedQuickRedoKeepsTheCheckpointHold_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let blocker = try rig.holdQueue()   // the reinsert stays queued: the undo's hold stays active
        defer { rig.release(blocker) }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        #expect(rig.footnotes.undoCheckpointHold != nil, "precondition: the quick undo's hold is active")
        try rig.setReply(.init(succeeded: false, reason: "docChanged"), forRoot: deleted.root.id)

        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await rig.awaitRuns([redo]))

        #expect(rig.replyWords() == ["undo performed", "redo failed"], "got \(rig.replyWords())")
        #expect(rig.footnotes.undoCheckpointHold != nil, "the refused redo does not release the hold")
        // A delete-resync write that was scheduled before the undo commits now.
        let lateWrite = FootnoteUndoCheckpoint(
            bodyBefore: "Text [^1] and [^2].", refsBefore: ["1", "2"], deletedDefinitions: ["2": "Second note"], appliedRenameMap: [:])
        let hold = try #require(rig.footnotes.undoCheckpointHold)
        rig.footnotes.committedNotesWrite(undoCheckpoint: lateWrite, scheduledGeneration: hold.belowOrAt)
        #expect(
            rig.footnotes.undoCheckpoints.isEmpty,
            "expected no checkpoint from a write scheduled before the quick undo after a refused redo, got \(rig.footnotes.undoCheckpoints.count)")
        rig.release(blocker)
        _ = await rig.waitUntilSettled()
    }
}
