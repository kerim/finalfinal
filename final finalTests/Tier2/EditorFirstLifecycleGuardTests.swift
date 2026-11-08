//
//  EditorFirstLifecycleGuardTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, fix round 8): small guards at the edge of a close, quit or project switch that an independent
//  read of rounds 3 to 7 asked for.
//
//    - F2  zoom in/out waits for a delete's follow-up work and then used to go on without looking: it wakes at the very moment the
//          lifecycle's own wait does, and zoom is not on the structural gate, so it could zoom a project that is being saved.
//    - F3  a held Rich Text / Markdown switch is a waiter on the structural gate; `acquire` looks at the closed barrier only at
//          entry, so a waiter queued before Cmd-W was granted the gate during the close's wait and the switch ran beside the save.
//    - F4  the held-press count has a bound; a count that cannot be read in time is "none held" and the second Cmd-Z is cancelled
//          silently. JavaScript is single-threaded, so the call can queue behind a long content push at the end of an undo.
//    - T3  a quit that joins a close keeps the allowance the close's barrier took (it neither asks again nor overwrites the count).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Guards at the lifecycle — Phase 4b slice 2a fix round 8 (Tier 2)", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct EditorFirstLifecycleGuardTests {

    private static let smallDocument = "# First Chapter\n\nBody one.\n\n## Second Section\n\nBody two."

    private func makeRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: Self.smallDocument)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswerProvider = { [unowned rig] in try? rig.assembledMarkdown() }
        return rig
    }

    // MARK: - F2

    /// A zoom in is pressed while a delete's job and follow-up work are still pending; they end, and the zoom wakes. With
    /// `lifecycle` a close has started in between. Returns how many times the undo timeline was invalidated (the zoom does that
    /// first thing, synchronously, when it goes ahead).
    private func zoomInWhileADeleteIsPending(lifecycle: Bool) async throws -> Int {
        let rig = try LifecycleTailRig()
        defer { rig.shutdown() }
        let registry = rig.editorState.efJobRegistry
        let opId = UUID()
        registry.register(opId)
        let before = rig.view.unifiedUndoService.generation
        rig.view.performUserZoomIn("no-such-section", mode: .full, reason: "test")
        if lifecycle {
            _ = rig.arm(.close)
            rig.editorState.structuralGate.isClosedToNewWork = true
        }
        registry.resolve(opId, .applied)
        registry.markSettled(opId)
        try await Task.sleep(for: .milliseconds(300))
        return rig.view.unifiedUndoService.generation - before
    }

    @Test("F2: a zoom that woke from its wait for a delete does not go ahead when a close has started; without a close it does")
    func testZoomDoesNotWakeIntoAClose() async throws {
        let withoutClose = try await zoomInWhileADeleteIsPending(lifecycle: false)
        #expect(withoutClose >= 1, "control: with no close the zoom goes ahead (it invalidates the undo timeline first): \(withoutClose)")
        let withClose = try await zoomInWhileADeleteIsPending(lifecycle: true)
        #expect(withClose == 0, "a close started while the zoom waited: the zoom must not start on the project being saved: \(withClose)")
    }

    // MARK: - F3

    @Test("F3: a held mode switch waiting on the gate is dropped, not run, when a close starts before it is granted")
    func testHeldSwitchIsDroppedWhenACloseStarts() async throws {
        let rig = try makeRig()
        let posted = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { posted.note("switch started") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let gate = rig.editorState.structuralGate
        let command = await gate.acquire()   // a command is running: the press is held behind it
        #expect(command == .granted)
        rig.editorState.requestEditorModeToggle()
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held")
        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { gate.isClosedToNewWork }
        #expect(armed, "the close must have placed its barrier while the switch waits")

        gate.release()   // the held switch is granted the gate during the close's wait
        let result = await close.value
        try await Task.sleep(for: .milliseconds(150))

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        #expect(posted.items.isEmpty, "the held switch must not start beside the close's save: \(posted.items)")
        #expect(rig.editorState.heldModeToggleTask == nil, "and it is gone")
        #expect(rig.editorState.editorMode == .wysiwyg)
    }

    @Test("F3: a switch queued on the gate by `runAfterPendingStructuralWork` does not run its body when a close starts before it is granted")
    func testQueuedSwitchBodyDoesNotRunBesideAClose() async throws {
        let rig = try makeRig()
        let gate = rig.editorState.structuralGate
        let ran = GateOrderLog()
        let command = await gate.acquire()
        #expect(command == .granted)
        let queued = rig.editorState.runAfterPendingStructuralWork(label: "test switch") { ran.note("switch body") }
        #expect(queued != nil, "a running command makes the switch wait")
        let waiting = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(waiting)
        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { gate.isClosedToNewWork }
        #expect(armed)

        gate.release()
        let result = await close.value
        await queued?.value

        #expect(result.outcome == .flushed)
        #expect(ran.items.isEmpty, "the switch's body must not run beside the close's save: \(ran.items)")
        #expect(gate.isIdle)
    }

    // MARK: - F4

    @Test("F4: a held-press count that the editor answers late (1.2 s, behind a long content push) still counts the press")
    func testSlowHeldPressCountStillCountsThePress() async throws {
        let rig = try makeRig()
        rig.heldPressCountAnswer = 1
        rig.heldPressCountDelay = .milliseconds(1200)
        let gate = rig.editorState.structuralGate
        let undoInFlight = await gate.acquire()
        #expect(undoInFlight == .granted)
        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }

        let counted = await gateWaitUntil({ gate.isClosedToNewWork && gate.preBarrierAllowance == 1 }, iterations: 1600)
        #expect(counted, "the late answer must still become the allowance (it was read as 0 after one second): \(gate.preBarrierAllowance)")
        gate.release()
        rig.controller.settleHeldPresses(1)
        let result = await close.value
        #expect(result.outcome == .flushed)
    }

    // MARK: - T3

    @Test("T3: a quit that joins a close keeps the allowance the close's barrier took: it does not ask the editor again or overwrite it")
    func testQuitJoiningACloseKeepsTheAllowance() async throws {
        let rig = try makeRig()
        let gate = rig.editorState.structuralGate
        let undoInFlight = await gate.acquire()   // an undo is in flight, so the editor may hold a press
        #expect(undoInFlight == .granted)
        rig.heldPressCountAnswer = 1
        let close = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let counted = await gateWaitUntil { gate.isClosedToNewWork && gate.preBarrierAllowance == 1 }
        #expect(counted)
        #expect(rig.heldCountReads == 1)

        // The quit arrives. The editor would now answer 0 (the press is on its way to Swift as a request): the quit must not read it.
        rig.heldPressCountAnswer = 0
        guard case .joined(let quitToken) = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
            Issue.record("the quit must join the close")
            return
        }
        let deadline = LifecycleDeadline(total: LifecycleBounds.production.quitTotal)
        let quit = Task { @MainActor in
            await rig.editorState.runLifecycleFlush(
                token: quitToken, host: rig.lifecycleHost(), structuralUndoController: rig.controller, deadline: deadline,
                bounds: .production)
        }
        try await Task.sleep(for: .milliseconds(150))

        #expect(rig.heldCountReads == 1, "the quit finds the barrier already placed and does not count again: \(rig.heldCountReads) reads")
        #expect(gate.preBarrierAllowance == 1, "and the allowance the close took is still there: \(gate.preBarrierAllowance)")

        // What the user sees: the second Cmd-Z, held in the editor behind the first undo, now reaches Swift marked `held`. It was
        // pressed before the Cmd-W and the Cmd-Q, so the closed gate must let it through (it queues behind the undo still running),
        // not cancel it.
        let secondUndo = Task { @MainActor in await gate.acquire(heldPress: true) }
        let queued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(queued, "the held press is let through the closed gate and waits behind the running undo: \(gate.waiterCount) waiting")
        gate.release()   // the first undo ends
        let second = await secondUndo.value
        #expect(second == .granted, "the second Cmd-Z is carried out after the quit joined, not cancelled: \(second)")
        gate.release()   // the second undo ends: nothing is owed, so both sequences can finish
        _ = await quit.value
        _ = await close.value
    }
}
