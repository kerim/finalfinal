//
//  EditorFirstLifecycleTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a): what the editor-first section delete's still-pending job means for everything that has
//  to wait for it.
//
//    - U7   `testCloseResolvesFuturesAndDrainsJob`: a close waits for the job, which applies; its future is resolved.
//    - U11  `testDirectWritersAwaitOnlyTheDeleteJob`: the wait zoom, Save Version/export and the switch to Markdown share ends with
//           the delete's own job, never with an unrelated queued system write.
//    - U15  `testQuitBeforeJobAppliesAbandonsFutureAndReleasesGate`: a Cmd-Z held on the job, then a quit that gives up.
//    - A1   `LifecycleWaitsForGateTests.testCloseWaitsForTwoQueuedUndos_book6`
//    - A2   `ModeSwitchWaitsFirstTests.testTypingDuringJobWaitIsSaved_book12` and `testSecondToggleIsHeld`
//
//  The delete job is held "queued but not run" with an editor ticket that never settles (`EditorFirstRig.holdQueue`), which
//  makes every later sequence wait without blocking a thread; the plan's `FF_UI_TESTING_STRUCT_JOB_HOLD_MS` seam (a UI-test
//  environment variable) and `testEFJobBodyHold` (which blocks the writer's thread) are not needed for that.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import SwiftUI
import Testing
@testable import final_final

/// Set by a system write's body (which runs on the writer's thread) so a test can tell whether the body has run.
final class BodyRanFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false
    func mark() { lock.withLock { ran = true } }
    var hasRun: Bool { lock.withLock { ran } }
}

@Suite("Pending delete job and its waiters — Phase 4b slice 2a (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EditorFirstJobWaitTests {

    private static let threeSections = """
    # First Chapter

    The first chapter's body.

    ## Second Section

    The second section's body.

    ## Third Section

    The third section's body.
    """

    /// A rig whose lifecycle fetch answers the document as the database holds it, with the polls answered "nothing pending".
    private func makeRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: Self.threeSections)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }
        return rig
    }

    // MARK: - U7

    @Test("U7: a close waits for the pending delete job, which then applies, and its future is resolved")
    func testCloseResolvesFuturesAndDrainsJob() async throws {
        let rig = try makeRig()
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let blocker = try rig.holdQueue()
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        #expect(rig.editorState.efJobRegistry.outstandingCount == 1, "the job is queued behind the held sequence")

        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let started = await gateWaitUntil { rig.editorState.structuralGate.isClosedToNewWork }
        #expect(started, "the close must have reached its step 1")
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.editorState.efJobRegistry.outstandingCount == 1, "the close is waiting for the job, not abandoning it")
        rig.release(blocker)
        let result = await close.value

        #expect(result.outcome == .flushed)
        #expect(!result.opStillRunning, "the job drained inside the wait")
        #expect(rig.editorState.efJobRegistry.outstandingCount == 0)
        #expect(rig.editorState.efJobRegistry.record(for: entry.id)?.outcome == .applied, "the future resolved with the job's outcome")
        let titles = Set(try rig.blocks().map(\.textContent))
        #expect(!titles.contains("Second Section"), "the job's delete reached the database")
        #expect(rig.editorState.structuralGate.isIdle)
    }

    // MARK: - U11

    @Test("U11: the wait zoom, Save Version/export and the switch to Markdown share ends with the delete's own job, not an unrelated queued write")
    func testDirectWritersAwaitOnlyTheDeleteJob() async throws {
        let rig = try makeRig()
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        rig.editorState.content = ""   // the flush below then writes nothing: only its waiting is under test

        // The delete job waits behind one held sequence; an unrelated bibliography write is reserved AFTER the job and waits
        // behind a second one, so it cannot apply until the test says so.
        let holdsJob = try rig.holdQueue()
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let holdsBibliography = try rig.holdQueue()
        let identity = SystemWriteIdentity(projectId: rig.pid, database: rig.db)
        let bibliographyDone = GateOrderLog()
        let bibliographyBody = BodyRanFlag()
        let inFlightBefore = rig.editorState.systemWriteInFlight
        let bibliography = Task { @MainActor in
            _ = await rig.sync.performSystemWrite(
                identity: identity, kind: .bibliographyUpdate, stillWanted: { true },
                body: { _ -> SystemWriteBody<Void> in
                    bibliographyBody.mark()
                    return SystemWriteBody(value: ())
                })
            bibliographyDone.note("bibliography applied")
        }
        // `systemWriteInFlight` counts every system write from its reservation until it returns: the delete job's, and now this one.
        let reserved = await gateWaitUntil { rig.editorState.systemWriteInFlight == inFlightBefore + 1 }
        #expect(reserved, "the unrelated bibliography write must hold its place in the queue")

        // The three waiters: the shared wait (zoom, Save Version and export call it), the flush Save Version and export run, and
        // the switch to Markdown.
        let finished = GateOrderLog()
        let generationBefore = rig.editorState.outOfQueueWriteGeneration
        let shared = Task { @MainActor in
            await rig.editorState.awaitPendingStructuralJobs()
            finished.note("shared wait")
        }
        let flush = Task { @MainActor in
            await rig.editorState.flushLiveContentToDatabase { nil }
            finished.note("save version flush")
        }
        let toggle = rig.editorState.runAfterPendingStructuralWork(label: "test toggle") { finished.note("switch to Markdown") }
        #expect(toggle != nil, "a pending job makes the switch wait")
        try await Task.sleep(for: .milliseconds(150))
        #expect(finished.items.isEmpty, "nothing may go ahead while the delete job is pending: \(finished.items)")

        // The delete job applies; the bibliography write is still parked.
        rig.release(holdsJob)
        await shared.value
        await flush.value
        await toggle?.value
        #expect(Set(finished.items) == ["shared wait", "save version flush", "switch to Markdown"], "got \(finished.items)")
        // The unrelated write is still parked: it has not returned and its body has not run. (The delete job's own count left
        // `systemWriteInFlight` when the job returned, so the counter now shows this write alone.)
        #expect(bibliographyDone.items.isEmpty, "the unrelated bibliography write was not what they waited for")
        #expect(!bibliographyBody.hasRun, "the unrelated bibliography write's body must not have run while the others finished")
        #expect(rig.editorState.systemWriteInFlight >= 1, "the unrelated write still holds its reservation")
        #expect(rig.editorState.outOfQueueWriteGeneration > generationBefore, "each wait then bumps the out-of-queue counter")

        rig.release(holdsBibliography)
        await bibliography.value
        #expect(bibliographyDone.items == ["bibliography applied"])
        #expect(bibliographyBody.hasRun, "once its turn comes the write runs")
    }

    // MARK: - U15

    @Test("U15: a Cmd-Z held on the pending job, then a quit that gives up: the gate is released and the job's future is abandoned")
    func testQuitBeforeJobAppliesAbandonsFutureAndReleasesGate() async throws {
        let rig = try makeRig()
        // Slice 2b: this pins the SLOW undo's wait for the pending job ("a Cmd-Z held on the job", U15). The quick undo does not wait
        // for the job; its twin is QuickUndoTamperTwinTests.testQuitRightAfterQuickUndoWithTheJobPendingReleasesTheGate.
        rig.controller.testForceSlowDeleteUndo = true
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)

        // Cmd-Z takes the gate and waits for the job, which cannot apply.
        let undo = Task { @MainActor in
            await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)
        }
        let holding = await gateWaitUntil { rig.controller.isPerforming }
        #expect(holding, "the undo must be holding the gate, waiting for the job")

        // A quit starts before the job applies, and gives up on it (a tenth of the real bounds).
        let result = await rig.runLifecycle(.quit, bounds: LifecycleBounds.production.scaled(0.05))
        await undo.value

        #expect(result.opStillRunning, "the quit gave up on the section operation and went on")
        #expect(rig.editorState.efJobRegistry.record(for: entry.id)?.outcome == .abandoned, "the future is resolved, as abandoned")
        #expect(rig.editorState.structuralGate.isIdle, "the gate was released")
        #expect(!rig.controller.isPerforming)
        let undoReplies = rig.scripts(containing: "receiveUndoOutcome")
        #expect(undoReplies.count == 1, "the held undo still got its one reply: \(undoReplies)")
        // `cancelled`, not `fallback`: a plain text undo now would remove the user's latest typing right before the closing save.
        #expect(undoReplies.first?.contains("'cancelled'") == true, "the lifecycle gave up on it, so it answers cancelled: \(undoReplies)")
    }
}

@Suite("Close waits for queued undos — Phase 4b slice 2a, addendum A1 (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LifecycleWaitsForGateTests {

    @Test("A1: Cmd-Z, Cmd-Z, close in the REAL order: the second press is held in the editor, counted at the barrier, and carried out")
    func testCloseWaitsForTwoQueuedUndos_book6() async throws {
        // The real order (fix round 5, the judge's "allowance" ruling). The editor holds a Cmd-Z pressed while an earlier undo is in
        // flight in ITS OWN queue and sends it to Swift only when that undo replies, so at Cmd-W the second press is neither queued on
        // the gate nor made after the barrier. The old version of this test put both undos on the gate directly, which the real app
        // never does, and so passed while the app dropped the second press.
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book6.editorMarkdown, configureSyncServices: false)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }
        let chapters = try rig.chapterHeadings()
        let first = try #require(chapters.first)
        let second = try #require(chapters.dropFirst().first)
        try rig.setReply(.init(removedLeaderIds: [first.id]), forRoot: first.id)
        try rig.setReply(.init(removedLeaderIds: [second.id]), forRoot: second.id)
        let firstOutcome = await rig.controller.performSectionDelete(rootId: first.id)
        let secondOutcome = await rig.controller.performSectionDelete(rootId: second.id)
        #expect(firstOutcome == .performed)
        #expect(secondOutcome == .performed)
        let entries = rig.unifiedUndo.undoStack
        #expect(entries.count == 2)
        let entryFirst = try #require(entries.first)
        let entrySecond = try #require(entries.last)
        for entry in entries { await rig.settle(entry.id) }
        try rig.syncEditorContentFromDatabase()
        let gate = rig.editorState.structuralGate

        // The first Cmd-Z is on the gate and busy, which keeps the order of this test fixed without a sleep. Before slice 2b a stand-in
        // rebuild held it at its entry (every structural command waited there for the rebuilds that run, fix round 5 part A2); the
        // quick undo waits for no rebuild, so the same hold is now the quick undo's own seam: between its reinsert holding a place in
        // the queue and the call that lets the editor queue typing again, with the gate held and the writer free.
        let firstUndoMayRun = LifecycleEntryHarness.Gate()
        defer { firstUndoMayRun.open() }
        rig.controller.testQuickUndoResumeHold = { await firstUndoMayRun.wait() }
        let firstUndo = Task { @MainActor in
            await rig.controller.handleStructuralRequest(opId: entrySecond.id.uuidString, direction: .undo)
        }
        let onTheGate = await gateWaitUntil { gate.isHeld }
        #expect(onTheGate, "the first undo must be holding the gate")

        // The editor holds the second press in its own queue (the stub answers the count the close asks for); then Cmd-W.
        rig.heldPressCountAnswer = 1
        let finished = GateOrderLog()
        let close = Task { @MainActor in
            let result = await rig.runLifecycle(.close, bounds: .production)
            finished.note("close done")
            return result
        }
        let counted = await gateWaitUntil { gate.isClosedToNewWork && gate.preBarrierAllowance == 1 }
        #expect(counted, "the barrier must have counted the one press the editor holds: allowance \(gate.preBarrierAllowance)")

        // The first undo ends and replies. The close is still waiting: the second press is owed a turn.
        firstUndoMayRun.open()
        await firstUndo.value
        #expect(rig.scripts(containing: "receiveUndoOutcome").count == 1, "the first undo has replied")
        try await Task.sleep(for: .milliseconds(150))
        #expect(finished.items.isEmpty, "the close must wait for the press the editor still holds, not finish now")
        #expect(!gate.isIdle, "the gate is not idle while a counted press has not arrived")

        // Only now does the editor send the second press, marked held; the closed gate lets it through.
        await rig.controller.handleStructuralRequest(opId: entryFirst.id.uuidString, direction: .undo, held: true)
        let result = await close.value

        #expect(result.outcome == .flushed, "the close must complete, not be cancelled")
        let replies = rig.scripts(containing: "receiveUndoOutcome")
        #expect(replies.count == 2, "got \(replies)")
        #expect(replies.first?.contains(entrySecond.id.uuidString) == true, "the newer delete is undone first: \(replies)")
        #expect(replies.last?.contains(entryFirst.id.uuidString) == true)
        #expect(replies.allSatisfy { $0.contains("'performed'") }, "both undos ran: \(replies)")
        let texts = Set(try rig.blocks().map(\.textContent))
        #expect(texts.contains(first.textContent) && texts.contains(second.textContent), "both chapters are back in the saved document")
        #expect(rig.toasts.current?.message != ToastFactory.lifecycleCloseCancelled().message, "no cancel toast may be posted")
        #expect(rig.toasts.current?.style != .warning, "and no warning toast at all: \(String(describing: rig.toasts.current?.message))")
        #expect(gate.isIdle && gate.preBarrierAllowance == 0)
    }

    @Test("Fix round 5: a held press that ends without a request (undoHeldPressSettled) lets the close finish, not wait out its whole budget")
    func testSettledHeldPressLetsTheCloseFinish() async throws {
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }
        let gate = rig.editorState.structuralGate
        // An undo is in flight (it holds the gate): the only time the editor holds a press, so the only time the close asks.
        let undoInFlight = await gate.acquire()
        #expect(undoInFlight == .granted)
        rig.heldPressCountAnswer = 1   // the editor holds one press when the close starts
        let finished = GateOrderLog()
        let close = Task { @MainActor in
            let result = await rig.runLifecycle(.close, bounds: .production)
            finished.note("close done")
            return result
        }
        let counted = await gateWaitUntil { gate.isClosedToNewWork && gate.preBarrierAllowance == 1 }
        #expect(counted)
        // The undo ends. The gate is free, but the counted press is still owed: the close keeps waiting.
        gate.release()
        try await Task.sleep(for: .milliseconds(300))
        #expect(finished.items.isEmpty, "the close waits for the press the editor holds")

        // The press ends without a request (the editor ran a plain text undo for it): what the `undoHeldPressSettled` message does.
        rig.controller.settleHeldPresses(1)
        // The close's whole budget is about twelve seconds; it must finish in a small fraction of that.
        let done = await gateWaitUntil({ finished.items == ["close done"] }, iterations: 600)
        #expect(done, "the close must finish once the press has settled, not wait out its budget")
        let result = await close.value
        #expect(result.outcome == .flushed)
        #expect(!result.opStillRunning)
        #expect(gate.isIdle)
    }

    @Test("Fix round 5: step 1 asks the editor for its held presses only while the gate is busy; with the gate idle it makes no JS call at all")
    func testHeldPressCountIsReadOnlyWhileTheGateIsBusy() async throws {
        // Idle gate: nothing is in flight, so the editor holds nothing and step 1 must not touch the view before its guard has cleared
        // (obligation N24; the older lifecycle tests pin the same thing through the rig log).
        let idle = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        idle.js.answer("flushPendingBlockChanges", true)
        idle.js.answer("hasBlockChanges", false)
        idle.fetchAnswerProvider = { [unowned idle] in try? idle.assembledMarkdown() }
        idle.heldPressCountAnswer = 1   // would be counted if it were asked
        #expect(idle.editorState.structuralGate.isIdle)
        let idleResult = await idle.runLifecycle(.close, bounds: .production)
        #expect(idleResult.outcome == .flushed)
        #expect(idle.heldCountReads == 0, "with the gate idle step 1 makes no heldUndoPressCount call: read \(idle.heldCountReads) times")
        #expect(idle.editorState.structuralGate.preBarrierAllowance == 0)

        // Busy gate: an undo is in flight, so the editor may hold presses and the close counts them.
        let busy = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        busy.js.answer("flushPendingBlockChanges", true)
        busy.js.answer("hasBlockChanges", false)
        busy.fetchAnswerProvider = { [unowned busy] in try? busy.assembledMarkdown() }
        busy.heldPressCountAnswer = 1
        let busyGate = busy.editorState.structuralGate
        let inFlight = await busyGate.acquire()
        #expect(inFlight == .granted)
        let close = Task { @MainActor in await busy.runLifecycle(.close, bounds: .production) }
        let counted = await gateWaitUntil { busyGate.isClosedToNewWork && busyGate.preBarrierAllowance == 1 }
        #expect(counted, "with the gate busy the close asks the editor and takes the answer as the allowance")
        #expect(busy.heldCountReads == 1, "and asks exactly once: read \(busy.heldCountReads) times")
        busyGate.release()
        busy.controller.settleHeldPresses(1)   // the press ends, so the close can finish
        let busyResult = await close.value
        #expect(busyResult.outcome == .flushed)
    }
}

@Suite("Switch to Markdown waits first — Phase 4b slice 2a, addendum A2 (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ModeSwitchWaitsFirstTests {

    /// A paragraph in the second chapter of the document, which the first chapter's delete does not touch.
    private func paragraphInSecondChapter(_ rig: EditorFirstRig) throws -> Block {
        let rows = try rig.blocks().sorted { $0.sortOrder < $1.sortOrder }
        let second = try #require(try rig.chapterHeadings().dropFirst().first)
        let start = try #require(rows.firstIndex { $0.id == second.id })
        return try #require(rows[start...].first { $0.blockType == .paragraph && !$0.isNotes && !$0.isBibliography })
    }

    /// What the editor holds after the delete click: the database's rows without the removed section, with `paragraphId`'s text
    /// replaced by `typedText` (the editor's own `contentChanged` push does this in a real session; the rig has no editor). The
    /// mode-switch handler flushes `editorState.content` to the database, so it has to say what the editor says.
    private func editorContent(
        _ rig: EditorFirstRig, removing subtree: Set<String>, typing typedText: String? = nil, in paragraphId: String? = nil
    ) throws -> String {
        var rows = try rig.blocks().filter { !subtree.contains($0.id) }
            .sorted { ($0.sortOrder, $0.blockType == .heading ? 0 : 1) < ($1.sortOrder, $1.blockType == .heading ? 0 : 1) }
        if let typedText, let paragraphId, let index = rows.firstIndex(where: { $0.id == paragraphId }) {
            rows[index].textContent = typedText
            rows[index].markdownFragment = typedText
        }
        return BlockParser.assembleMarkdownForEditor(from: rows)
    }

    @Test("A2: typing during the wait for the delete job is saved: the editor stays live, the real switch handler runs after the job")
    func testTypingDuringJobWaitIsSaved_book12() async throws {
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.book12.editorMarkdown, configureSyncServices: false)
        let chapter = try #require(try rig.chapterHeadings().first)
        let paragraph = try paragraphInSecondChapter(rig)
        let subtree = Set(try #require(try rig.db.sectionBlockIds(rootId: chapter.id, projectId: rig.pid)))
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        // The plan's hold seam: the queued job's body blocks the writer until the test lets it go.
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let typedText = paragraph.textContent + " KEPT-A2"
        rig.editorState.content = try editorContent(rig, removing: subtree, typing: typedText, in: paragraph.id)

        // The user presses the switch to Markdown: the REAL handler must wait for the job and change nothing until then.
        let generationBefore = rig.unifiedUndo.generation
        Color.clear.handleEditorModeToggle(
            editorState: rig.editorState, sectionSyncService: SectionSyncService(),
            findBarState: FindBarState(), unifiedUndoService: rig.unifiedUndo)
        #expect(rig.editorState.editorMode == .wysiwyg, "the switch has not happened while the job is pending")
        #expect(rig.editorState.contentState == .idle, "the editor stays live and idle during the wait")
        #expect(rig.unifiedUndo.generation == generationBefore, "no barrier fired: the switch changed nothing yet")

        // The user types during the wait: a routine poll fetches the edit (the editor is live), and it must reach the database.
        let typed = BlockChanges(updates: [BlockUpdate(
            id: paragraph.id, textContent: typedText, markdownFragment: typedText, headingLevel: nil)])
        rig.js.answer("hasBlockChanges", true)
        rig.js.answer("getBlockChanges", String(data: try JSONEncoder().encode(typed), encoding: .utf8))
        let poll = Task { @MainActor in await rig.sync.pollBlockChangesForTest() }
        let fetched = await rig.js.waitUntilCallEntry("getBlockChanges", 1)
        #expect(fetched, "the routine poll must run during the wait: typing is not held back")
        #expect(rig.editorState.editorMode == .wysiwyg)

        jobMayRun.signal()
        await poll.value
        // (book12: the job's snapshot and the switch's own flush parse and write 700,000 characters, so allow up to 20 s.)
        let switched = await gateWaitUntil({ rig.editorState.editorMode == .source }, iterations: 4000)
        #expect(switched, "the switch runs once the job has ended")

        #expect(rig.unifiedUndo.generation == generationBefore + 1, "the switch ran exactly once")
        let saved = try rig.blocks().first { $0.id == paragraph.id }?.textContent ?? ""
        let allText = try rig.blocks().map(\.textContent).joined(separator: "\n")
        #expect(saved.contains("KEPT-A2") || allText.contains("KEPT-A2"), "the typing done during the wait is saved in the database")
        #expect(!Set(try rig.blocks().map(\.textContent)).contains(chapter.textContent), "the delete reached the database before the switch")
        #expect(rig.editorState.sourceContent.contains("KEPT-A2"), "the Markdown editor is handed the text with the typing in it")
        #expect(!rig.editorState.sourceContent.contains(chapter.textContent), "and without the deleted chapter")
    }

    @Test("A2: a second toggle pressed during the wait is held and runs after the first: never in parallel, never dropped")
    func testSecondToggleIsHeld() async throws {
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.\n\n## Third Section\n\nBody three.")
        let root = try rig.heading("Second Section")
        let subtree = Set(try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid)))
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let jobMayRun = DispatchSemaphore(value: 0)
        defer { jobMayRun.signal() }
        rig.controller.testEFJobBodyHold = { jobMayRun.wait() }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        rig.editorState.content = try editorContent(rig, removing: subtree)

        // Two presses of the switch during the wait, through the real handler: each is a whole switch (it flips the editor).
        let generationBefore = rig.unifiedUndo.generation
        for _ in 0..<2 {
            Color.clear.handleEditorModeToggle(
                editorState: rig.editorState, sectionSyncService: SectionSyncService(),
                findBarState: FindBarState(), unifiedUndoService: rig.unifiedUndo)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.unifiedUndo.generation == generationBefore, "neither switch may run while the job is pending")
        #expect(rig.editorState.editorMode == .wysiwyg)

        jobMayRun.signal()
        let bothRan = await gateWaitUntil { rig.unifiedUndo.generation == generationBefore + 2 }
        #expect(bothRan, "both presses ran, one after the other, none dropped: generation \(rig.unifiedUndo.generation)")
        // Two switches end where they started: Rich Text. (Held and run one after the other, not in parallel: each is one
        // synchronous body on the main actor, and the second waits behind the first on the gate.)
        #expect(rig.editorState.editorMode == .wysiwyg, "two switches leave the editor in Rich Text")
        let settled = await gateWaitUntil { rig.editorState.structuralGate.isIdle }
        #expect(settled)
    }

    @Test("Item 4: a switch pressed during a slow Cmd-Z is held and happens when the undo is over, not dropped")
    func testSwitchPressedDuringASlowUndoIsHeld() async throws {
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        let slowUndoMayEnd = LifecycleEntryHarness.Gate()
        let posted = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { posted.note("toggle requested") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // A structural command is mid-way (a slow undo sets this state while it runs).
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "slow undo", cancelled: false) {
                rig.editorState.contentState = .structuralUndo
                await slowUndoMayEnd.wait()
                rig.editorState.contentState = .idle
                return true
            }
        }
        let running = await gateWaitUntil { rig.editorState.contentState == .structuralUndo }
        #expect(running)

        rig.editorState.requestEditorModeToggle()
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held, not refused")
        try await Task.sleep(for: .milliseconds(150))
        #expect(posted.items.isEmpty, "the switch must not start while the undo is running")

        slowUndoMayEnd.open()
        _ = await command.value
        let happened = await gateWaitUntil { posted.items == ["toggle requested"] }
        #expect(happened, "the held press starts the switch once the undo is over: \(posted.items)")
        let released = await gateWaitUntil { rig.editorState.heldModeToggleTask == nil }
        #expect(released)
    }

    /// Phase two's input: the notification the editor posts when the cursor is saved (no position needed here).
    private func cursorSaved() -> Notification {
        Notification(name: .didSaveCursorPosition, object: nil, userInfo: nil)
    }

    @Test("Item 4 (third round): a switch whose cursor save ends after a slow Cmd-Z has started is held, asked again once, flips once")
    func testSwitchWhoseCursorSaveEndsDuringAnUndoIsHeldNotDropped() async throws {
        // The VM test's failure (testDeleteUndoThenSwitchModeAtOnce_book6): the press passed phase one while everything was idle and
        // started the cursor save; a Cmd-Z then set `.structuralUndo` before the save replied; phase two dropped the switch.
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        try rig.syncEditorContentFromDatabase()
        let undoMayEnd = LifecycleEntryHarness.Gate()
        let seen = GateOrderLog()
        let willObserver = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("cursor save requested") }
        }
        let toggleObserver = NotificationCenter.default.addObserver(forName: .toggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("switch requested") }
        }
        defer {
            NotificationCenter.default.removeObserver(willObserver)
            NotificationCenter.default.removeObserver(toggleObserver)
        }
        let noCursor = Binding<CursorPosition?>(get: { nil }, set: { _ in })

        // Phase one: nothing is running, so the press goes straight through and the cursor save starts.
        rig.editorState.requestEditorModeToggle()
        let firstRequest = await gateWaitUntil { seen.items == ["cursor save requested"] }
        #expect(firstRequest, "\(seen.items)")
        #expect(rig.editorState.heldModeToggleTask == nil, "nothing was running: the press is not held")

        // A slow Cmd-Z starts while the cursor save is still on its way: it takes the gate and sets `.structuralUndo`.
        let undo = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "slow undo", cancelled: false) {
                rig.editorState.contentState = .structuralUndo
                await undoMayEnd.wait()
                rig.editorState.contentState = .idle
                return true
            }
        }
        let undoRunning = await gateWaitUntil { rig.editorState.contentState == .structuralUndo }
        #expect(undoRunning)

        // Phase two: the cursor save replies now. The switch must be held (it used to be dropped here, silently).
        Color.clear.handleDidSaveCursorPosition(cursorSaved(), editorState: rig.editorState, cursorRestore: noCursor)
        #expect(rig.editorState.heldModeToggleTask != nil, "held, not dropped")
        #expect(rig.editorState.editorMode == .wysiwyg)
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.items == ["cursor save requested"], "the switch itself is not requested while the undo runs: \(seen.items)")

        // The undo ends. The held press asks again from the top, ONCE, although the first request was only a moment ago (the
        // 0.5 s debounce that stops a double-click must not swallow the press the user already made).
        undoMayEnd.open()
        _ = await undo.value
        let askedAgain = await gateWaitUntil { seen.items == ["cursor save requested", "cursor save requested"] }
        #expect(askedAgain, "the held press starts the cursor save again: \(seen.items)")
        let released = await gateWaitUntil { rig.editorState.heldModeToggleTask == nil }
        #expect(released)

        // The second cursor save replies with nothing running: the switch is requested, and the real handler flips the mode once.
        Color.clear.handleDidSaveCursorPosition(cursorSaved(), editorState: rig.editorState, cursorRestore: noCursor)
        let switchRequested = await gateWaitUntil { seen.items.filter { $0 == "switch requested" }.count == 1 }
        #expect(switchRequested, "\(seen.items)")
        let generationBefore = rig.unifiedUndo.generation
        Color.clear.handleEditorModeToggle(
            editorState: rig.editorState, sectionSyncService: SectionSyncService(),
            findBarState: FindBarState(), unifiedUndoService: rig.unifiedUndo)
        #expect(rig.editorState.editorMode == .source, "the switch happened")
        #expect(rig.unifiedUndo.generation == generationBefore + 1, "and exactly once")

        // Nothing else is pending: no second request, no second flip.
        try await Task.sleep(for: .milliseconds(150))
        #expect(seen.items == ["cursor save requested", "cursor save requested", "switch requested"], "\(seen.items)")
        #expect(rig.editorState.editorMode == .source)
        #expect(rig.editorState.heldModeToggleTask == nil)
    }

    @Test("Item 4 (third round): a press while the gate is busy but contentState is still idle is held, and runs once afterwards")
    func testPressWhileTheGateIsBusyIsHeldAndRunsAfterwards() async throws {
        // An undo that waits for a delete's saving job holds the gate while `contentState` is still `.idle`.
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.")
        let commandMayEnd = LifecycleEntryHarness.Gate()
        let seen = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("cursor save requested") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "undo waiting for a job", cancelled: false) {
                await commandMayEnd.wait()
                return true
            }
        }
        let gateBusy = await gateWaitUntil { !rig.editorState.structuralGate.isIdle }
        #expect(gateBusy)
        #expect(rig.editorState.contentState == .idle, "precondition: the command has not set .structuralUndo yet")

        rig.editorState.requestEditorModeToggle()
        rig.editorState.requestEditorModeToggle()   // a second press is the same wish: it adds nothing
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held, not started")
        try await Task.sleep(for: .milliseconds(150))
        #expect(seen.items.isEmpty, "no cursor save starts while the command holds the gate: \(seen.items)")
        #expect(rig.editorState.lastToggleRequestTime == .distantPast, "nothing recorded a request: the press is only waiting")

        commandMayEnd.open()
        _ = await command.value
        let started = await gateWaitUntil { seen.items == ["cursor save requested"] }
        #expect(started, "the held press starts the switch once the command is over: \(seen.items)")
        let released = await gateWaitUntil { rig.editorState.heldModeToggleTask == nil }
        #expect(released)
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.items == ["cursor save requested"], "exactly once: the second press added nothing: \(seen.items)")
    }

    @Test("Item 4 (third round): with nothing running a press goes straight through and is never held")
    func testPressWithNothingRunningIsNotHeld() async throws {
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.")
        let seen = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { seen.note("cursor save requested") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(rig.editorState.structuralGate.isIdle)

        rig.editorState.requestEditorModeToggle()

        let started = await gateWaitUntil { seen.items == ["cursor save requested"] }
        #expect(started, "the press starts the cursor save: \(seen.items)")
        #expect(rig.editorState.heldModeToggleTask == nil, "and is never held")
        #expect(rig.editorState.lastToggleRequestTime != .distantPast)
    }

    @Test("Item 5: the wait for a delete job does not replace a running export's progress notice, and leaves it in place when it ends")
    func testWaitDoesNotReplaceARunningExportToast() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(30)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = try EditorFirstRig(markdown: "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two.\n\n## Third Section\n\nBody three.")
        let root = try rig.heading("Second Section")
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let blocker = try rig.holdQueue()
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)

        // Export has put up its own progress notice and then waits for the delete job (the flush it runs first).
        let exportToast = Toast(style: .progress, message: "Exporting to Word\u{2026}")
        rig.toasts.show(exportToast)
        let waiting = Task { @MainActor in await rig.editorState.awaitPendingStructuralJobs() }
        try await Task.sleep(for: .milliseconds(150))   // well past the notice's delay
        #expect(
            rig.toasts.current?.id == exportToast.id,
            "the wait must not replace the export's notice: \(String(describing: rig.toasts.current?.message))")

        rig.release(blocker)
        await waiting.value
        #expect(rig.toasts.current?.id == exportToast.id, "and the export's notice is still there when the wait ends")
    }
}
