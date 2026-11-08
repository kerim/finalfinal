//
//  StructuralGateTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2a, plan D1.1 and addenda A3, A5, A21): the structural command gate.
//
//    - `StructuralGateTests`: the FIFO mutex itself, the held-never-refused rule, and the progress toast every exit path dismisses
//      by id (A5: `testEveryExitDismissesProgressToast`).
//    - `StructuralGateBarrierTests`: once the lifecycle barrier is up the gate stops taking work (A21), and a Cmd-Z the lifecycle
//      cancelled still gets its reply (A3).
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

/// A controller wired to an `EditorViewState` that has its own `ToastCenter`, with the JS bridge stubbed. The unified timeline is
/// empty: these tests exercise the gate, not an operation.
@MainActor
struct GateRig {
    let controller = StructuralUndoController()
    let editorState = EditorViewState()
    let toasts = ToastCenter()
    let unifiedUndo = UnifiedUndoService()
    /// Every script the controller sent to the editor, in order.
    let sent = GateScriptLog()
    /// What ran, in order (appended to by the test's commands).
    let order = GateOrderLog()
    /// The project behind the rig when it was made `withProject` (nil otherwise): a real database, so a command that wrongly runs
    /// has something to change.
    let db: ProjectDatabase?
    let pid: String?

    init(project: (database: ProjectDatabase, projectId: String)? = nil) {
        editorState.toastCenter = toasts
        if let project {
            editorState.projectDatabase = project.database
            editorState.currentProjectId = project.projectId
            editorState.content = TestFixtureFactory.testContent
            db = project.database
            pid = project.projectId
        } else {
            db = nil
            pid = nil
        }
        controller.configure(
            editorState: editorState, blockSyncService: BlockSyncService(), sectionSyncService: SectionSyncService(),
            bibliographySyncService: BibliographySyncService(), footnoteSyncService: FootnoteSyncService(),
            annotationSyncService: AnnotationSyncService(), unifiedUndoService: unifiedUndo, findBarState: FindBarState())
        let sent = self.sent
        controller.testEvalVoidOverride = { js in sent.append(js); return true }
        controller.testEvalBoolOverride = { _ in true }
    }

    /// A rig with a real temporary project behind it.
    static func withProject() throws -> GateRig {
        let database = try TestFixtureFactory.createTemporary(content: TestFixtureFactory.testContent)
        return GateRig(project: (database, try TestFixtureFactory.getProjectId(from: database)))
    }

    /// A real entry on the timeline, backed by a real snapshot of the rig's project. `undone: true` moves it to the redo stack with
    /// a redo snapshot, the state Cmd-Shift-Z works from. If a command that should not run DID run, the stacks and the block rows
    /// would change.
    func recordEntry(undone: Bool) throws -> StructuralEntry {
        let database = try #require(db)
        let projectId = try #require(pid)
        let service = SnapshotService(database: database, projectId: projectId)
        let entry = StructuralEntry(
            kind: .sectionDuplicate, title: "Duplicate Section", undoSnapshotId: try service.createUndoPointSnapshot())
        unifiedUndo.record(entry)
        if undone {
            _ = unifiedUndo.performUndo(opId: entry.id)
            unifiedUndo.attachRedoSnapshot(opId: entry.id, redoSnapshotId: try service.createUndoPointSnapshot())
        }
        return entry
    }

    /// The ids of the project's block rows, in order.
    func blockIds() throws -> [String] {
        try #require(db).fetchBlocks(projectId: try #require(pid)).map(\.id)
    }
}

final class GateScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ script: String) { lock.withLock { storage.append(script) } }
    var scripts: [String] { lock.withLock { storage } }
}

@MainActor
final class GateOrderLog {
    private(set) var items: [String] = []
    func note(_ item: String) { items.append(item) }
}

/// Waits (bounded) until `condition` holds, sleeping briefly between looks.
@MainActor
func gateWaitUntil(_ condition: () -> Bool, iterations: Int = 600) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Structural gate — Tier 1 (t-94369a83 Phase 4b slice 2a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StructuralGateTests {

    @Test("The gate runs commands one at a time, in arrival order, and never refuses a second one")
    func testGateIsFirstInFirstOutAndNeverRefuses() async {
        let gate = StructuralCommandGate()
        let order = GateOrderLog()

        let first = await gate.acquire()
        #expect(first == .granted)
        let second = Task { @MainActor in
            let result = await gate.acquire()
            order.note("second \(result)")
            gate.release()
        }
        let third = Task { @MainActor in
            let result = await gate.acquire()
            order.note("third \(result)")
            gate.release()
        }
        let queued = await gateWaitUntil { gate.waiterCount == 2 }
        #expect(queued, "both later commands must be held, not refused")
        #expect(order.items.isEmpty, "nothing may start while the first command holds the gate")

        gate.release()
        await second.value
        await third.value
        #expect(order.items == ["second granted", "third granted"], "held commands run in arrival order: \(order.items)")
        #expect(gate.isIdle)
    }

    @Test("A command pressed on an idle gate is granted at once")
    func testIdleGateGrantsAtOnce() async {
        let gate = StructuralCommandGate()
        #expect(gate.isIdle)
        let result = await gate.acquire()
        #expect(result == .granted)
        #expect(gate.isHeld)
        gate.release()
        #expect(gate.isIdle)
    }

    @Test("A5: every exit of a held command dismisses its 'Finishing the last change' toast by id")
    func testEveryExitDismissesProgressToast() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(30)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = GateRig()
        let gate = rig.editorState.structuralGate

        // Exit 1: the held command STARTS (applied or refused: the body ran).
        let held = await gate.acquire()
        #expect(held == .granted)
        let ran = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "test-run", cancelled: "cancelled") { "ran" }
        }
        let showed = await gateWaitUntil { rig.toasts.current?.style == .progress }
        #expect(showed, "a command held for longer than the delay must show the progress toast")
        #expect(rig.toasts.current?.message == DelayedProgressToast.finishingMessage)
        gate.release()
        let ranResult = await ran.value
        #expect(ranResult == "ran")
        #expect(rig.toasts.current == nil, "starting the command must dismiss the toast")

        // Exit 2: the held command is CANCELLED while it waits (the lifecycle cancelled the queue).
        let heldAgain = await gate.acquire()
        #expect(heldAgain == .granted)
        let cancelled = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "test-cancel", cancelled: "cancelled") { "ran" }
        }
        let showedAgain = await gateWaitUntil { rig.toasts.current?.style == .progress }
        #expect(showedAgain)
        let cancelledCount = gate.cancelWaiters()
        #expect(cancelledCount == 1)
        let cancelledResult = await cancelled.value
        #expect(cancelledResult == "cancelled")
        #expect(rig.toasts.current == nil, "cancelling the command must dismiss the toast")
        gate.release()
        #expect(gate.isIdle)

        // Exit 3: a command that never had to wait shows nothing at all, not even after the delay.
        let immediate = await rig.controller.runStructuralCommand(label: "test-idle", cancelled: "cancelled") { "ran" }
        #expect(immediate == "ran")
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.toasts.current == nil, "an idle gate must never show a toast")
    }

    @Test("A5: a warning toast that was showing comes back when the held command's progress toast is dismissed")
    func testHeldCommandToastGivesTheWarningBack() async {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(30)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        rig.toasts.show(Toast(style: .warning, message: "A standing warning"))

        let held = await gate.acquire()
        #expect(held == .granted)
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "test", cancelled: false) { true }
        }
        let showed = await gateWaitUntil { rig.toasts.current?.style == .progress }
        #expect(showed)
        gate.release()
        let commandResult = await command.value
        #expect(commandResult)
        #expect(rig.toasts.current?.message == "A standing warning", "the displaced warning must return")
    }

    @Test("isPerforming is true exactly while a command holds the gate")
    func testIsPerformingTracksTheGate() async {
        let rig = GateRig()
        #expect(!rig.controller.isPerforming)
        let during = GateOrderLog()
        _ = await rig.controller.runStructuralCommand(label: "test", cancelled: false) {
            during.note(rig.controller.isPerforming ? "performing" : "idle")
            return true
        }
        #expect(during.items == ["performing"])
        #expect(!rig.controller.isPerforming)
    }
}

@Suite("Structural gate barrier — Tier 1 (t-94369a83 Phase 4b slice 2a)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StructuralGateBarrierTests {

    @Test("A21: a command arriving after the lifecycle barrier is placed is cancelled and never runs; one queued before it still runs")
    func testCommandArrivingAfterCloseStartedIsCancelled() async {
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        let order = rig.order

        // A command is running and another is queued behind it BEFORE the barrier.
        let held = await gate.acquire()
        #expect(held == .granted)
        let queuedBefore = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "queued-before", cancelled: "cancelled") {
                order.note("queued-before")
                return "ran"
            }
        }
        let waiting = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(waiting)

        // The barrier goes up (what `runLifecycleFlush` does at step 1).
        gate.isClosedToNewWork = true

        // A Delete Section that arrives now is not run.
        let lateDelete = await rig.controller.runStructuralCommand(label: "late-delete", cancelled: "cancelled") {
            order.note("late-delete")
            return "ran"
        }
        #expect(lateDelete == "cancelled")

        // The one queued before the barrier still runs, inside the lifecycle's drain wait.
        gate.release()
        let queuedResult = await queuedBefore.value
        #expect(queuedResult == "ran")
        #expect(order.items == ["queued-before"], "only the command queued before the barrier may run: \(order.items)")
        #expect(gate.isIdle)
        // (That a CANCELLED close opens the gate again is `testCancelledCloseReopensTheGate`, which runs a real close through
        // `LifecycleEntry` instead of setting the flag by hand.)
    }

    @Test("A3: a Cmd-Z the lifecycle cancelled while it waited still replies, `cancelled`, and neither runs nor touches the document")
    func testCancelledUndoWaiterRepliesToJS() async throws {
        // A REAL entry on the timeline, backed by a real snapshot: if the cancelled command ran, the entry would move to the redo
        // stack and the snapshot would be restored over the block rows (fix round 2a, item 16: the old version used a random id, so
        // `fallback` was also the answer when the command wrongly ran).
        let rig = try GateRig.withProject()
        let entry = try rig.recordEntry(undone: false)
        let rowsBefore = try rig.blockIds()
        let gate = rig.editorState.structuralGate
        let opId = entry.id.uuidString

        let held = await gate.acquire()
        #expect(held == .granted)
        let undo = Task { @MainActor in
            await rig.controller.handleStructuralRequest(opId: opId, direction: .undo)
        }
        let waiting = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(waiting, "the undo must be held on the gate")
        #expect(!rig.sent.scripts.contains { $0.contains("receiveUndoOutcome") }, "nothing may be answered while the undo waits")

        // The lifecycle cancels the queue (a quit that gave up on the section operation).
        let cancelled = gate.cancelWaiters()
        #expect(cancelled == 1)
        await undo.value

        let replies = rig.sent.scripts.filter { $0.contains("receiveUndoOutcome") }
        #expect(replies.count == 1, "exactly one reply must reach the editor: \(replies)")
        #expect(replies.first?.contains("'\(opId)'") == true)
        // `cancelled`, not `fallback`: `fallback` makes the editor replay a plain text undo, which would remove the user's latest
        // typing just before the closing save writes it.
        #expect(replies.first?.contains("'cancelled'") == true, "a waiter the lifecycle cancelled replies cancelled: \(replies)")
        #expect(rig.unifiedUndo.undoStack.map(\.id) == [entry.id], "the cancelled undo must not have moved the entry")
        #expect(rig.unifiedUndo.redoStack.isEmpty)
        #expect(try rig.blockIds() == rowsBefore, "the cancelled undo must not have touched the database")
        gate.release()
    }

    @Test("A21: a Cmd-Shift-Z that arrives after the barrier is placed replies `cancelled` and neither runs nor touches the document")
    func testRedoArrivingAfterTheBarrierRepliesCancelled() async throws {
        // The must-fail proof for the gate's own barrier check (fix round 2a, item 16): with
        // `if isClosedToNewWork { return .cancelled }` deleted from StructuralCommandGate.acquire, this redo would run for real
        // (the entry would move to the undo stack, the snapshot would be restored) and the reply would not be `cancelled`.
        let rig = try GateRig.withProject()
        let entry = try rig.recordEntry(undone: true)
        let rowsBefore = try rig.blockIds()
        rig.editorState.structuralGate.isClosedToNewWork = true

        await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .redo)

        let replies = rig.sent.scripts.filter { $0.contains("receiveRedoOutcome") }
        #expect(replies.count == 1)
        #expect(replies.first?.contains("'cancelled'") == true, "got \(replies)")
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [entry.id], "the cancelled redo must not have moved the entry")
        #expect(rig.unifiedUndo.undoStack.isEmpty)
        #expect(try rig.blockIds() == rowsBefore, "the cancelled redo must not have touched the database")
        #expect(!rig.controller.isPerforming)
    }

    @Test("Fix round 5: the allowance lets exactly that many held presses through a closed gate; a press made after the barrier is cancelled")
    func testPreBarrierAllowanceLetsExactlyThatManyHeldPressesThrough() async {
        let gate = StructuralCommandGate()
        gate.isClosedToNewWork = true
        gate.preBarrierAllowance = 2
        #expect(!gate.isIdle, "a counted press that has not arrived keeps the gate from reading idle, so the lifecycle's wait keeps waiting")

        // A press that is not one of the held ones (made after the barrier) is cancelled, and uses none of the allowance.
        let madeAfterTheBarrier = await gate.acquire()
        #expect(madeAfterTheBarrier == .cancelled)
        #expect(gate.preBarrierAllowance == 2)

        // The first held press takes the gate; the second queues behind it (counted off the allowance in the same turn).
        let first = await gate.acquire(heldPress: true)
        #expect(first == .granted)
        #expect(gate.preBarrierAllowance == 1)
        let second = Task { @MainActor in await gate.acquire(heldPress: true) }
        let queued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(queued)
        #expect(gate.preBarrierAllowance == 0)
        #expect(!gate.isIdle)

        // A third held press finds the allowance spent: cancelled, exactly as before this fix.
        let third = await gate.acquire(heldPress: true)
        #expect(third == .cancelled, "a held press beyond the allowance is cancelled")

        gate.release()
        let secondResult = await second.value
        #expect(secondResult == .granted)
        gate.release()
        #expect(gate.isIdle)

        // A press the editor reports as ended without a request lowers the allowance, never below zero.
        gate.preBarrierAllowance = 1
        gate.settleHeldPresses(3)
        #expect(gate.preBarrierAllowance == 0)
        #expect(gate.isIdle)

        // The quit's give-up (`cancelWaiters`) and reopening the gate both forget it.
        gate.preBarrierAllowance = 2
        gate.cancelWaiters()
        #expect(gate.preBarrierAllowance == 0)
        gate.preBarrierAllowance = 2
        gate.isClosedToNewWork = false
        #expect(gate.preBarrierAllowance == 0, "reopening the gate leaves no owed press behind")
    }

    @Test("Fix round 5: a held press that arrives with the barrier up and no allowance left replies `cancelled` and touches nothing")
    func testHeldPressWithNoAllowanceLeftIsCancelled() async throws {
        let rig = try GateRig.withProject()
        let entry = try rig.recordEntry(undone: true)
        let rowsBefore = try rig.blockIds()
        rig.editorState.structuralGate.isClosedToNewWork = true   // a press made AFTER Cmd-W: nothing was counted for it

        await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .redo, held: true)

        let replies = rig.sent.scripts.filter { $0.contains("receiveRedoOutcome") }
        #expect(replies.count == 1)
        #expect(replies.first?.contains("'cancelled'") == true, "got \(replies)")
        #expect(rig.unifiedUndo.redoStack.map(\.id) == [entry.id], "the cancelled press must not have moved the entry")
        #expect(try rig.blockIds() == rowsBefore, "and must not have touched the database")
        #expect(rig.editorState.structuralGate.isClosedToNewWork)
    }

    @Test("A21: a close cancelled for a running section operation (through LifecycleEntry) opens the gate again, so a later command runs")
    func testCancelledCloseReopensTheGate() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswer = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"
        let controller = rig.controller
        rig.editorState.toastCenter = ToastCenter()
        controller.configure(
            editorState: rig.editorState, blockSyncService: rig.sync, sectionSyncService: SectionSyncService(),
            bibliographySyncService: BibliographySyncService(), footnoteSyncService: FootnoteSyncService(),
            annotationSyncService: AnnotationSyncService(), unifiedUndoService: UnifiedUndoService(), findBarState: FindBarState())
        controller.testSetIsPerforming(true)   // a section operation that never clears
        defer { controller.testSetIsPerforming(false) }
        var outcome: LifecycleRunOutcome?
        var flagDuringTheCancelledClose: Bool?

        try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.1)) {
            let closing = Task { @MainActor in try await LifecycleEntry.run(kind: .close) { .close } }
            await LifecycleEntryHarness.waitUntil("the close to place the barrier") {
                rig.editorState.structuralGate.isClosedToNewWork
            }
            flagDuringTheCancelledClose = rig.editorState.structuralGate.isClosedToNewWork
            outcome = try await closing.value
        }

        #expect(flagDuringTheCancelledClose == true, "the close put the barrier up while it waited")
        #expect(outcome == .cancelled, "the close gave up on the section operation that never cleared")
        #expect(!rig.editorState.structuralGate.isClosedToNewWork, "LifecycleEntry.finish must open the gate again after a cancelled close")
        controller.testSetIsPerforming(false)
        let ran = await controller.runStructuralCommand(label: "after the cancelled close", cancelled: "cancelled") { "ran" }
        #expect(ran == "ran", "a command after a cancelled close must run")
    }

    /// What a test saw from inside a real switch: in `perform`, and in the host's open tail right after the real tail returned
    /// (before `LifecycleEntry.finish`, which clears the flag too, could have done it).
    private final class SwitchObservations {
        var flagInPerform: Bool?
        var gateAnswerInPerform: StructuralGateResult?
        var flagAfterOpenTail: Bool?
        var barrierGoneAfterOpenTail: Bool?
    }

    @Test("Item 11 / R1: in a real switch the gate is still closed inside perform and opens only when the open tail has retired the old writer")
    func testGateStaysClosedThroughPerformAndOpensAfterTheTailRetiresTheOldWriter() async throws {
        // Fix round 2a, R1 (the second round corrects item 11): the old project is still on screen and being saved until the open
        // tail has retired its writer, so a Delete or Cmd-Z pressed in `perform` must be cancelled, not run against a closing project.
        // A Delete in the NEW project (after the tail) must run.
        let rig = try LifecycleTailRig(mountedEditor: true)
        defer { rig.shutdown() }
        let gate = rig.editorState.structuralGate
        let seen = SwitchObservations()
        var outcome: LifecycleRunOutcome?

        try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
            // The REAL host with one addition: it looks at the gate the moment the real open tail has returned.
            let realHost = try #require(rig.editorState.lifecycleHost)
            var observingHost = realHost
            observingHost.runOpenTail = { [rig, seen] token in
                await realHost.runOpenTail(token)
                seen.flagAfterOpenTail = rig.editorState.structuralGate.isClosedToNewWork
                seen.barrierGoneAfterOpenTail = rig.editorState.lifecycleBarrier == nil
            }
            rig.editorState.lifecycleHost = observingHost
            outcome = try await LifecycleEntry.run(kind: .projectSwitch) { [rig, seen] in
                seen.flagInPerform = rig.editorState.structuralGate.isClosedToNewWork
                let answer = await rig.editorState.structuralGate.acquire()
                if answer == .granted { rig.editorState.structuralGate.release() }
                seen.gateAnswerInPerform = answer
                return .open
            }
        }

        #expect(outcome == .performed)
        #expect(rig.entryEvents.first == .armed(.projectSwitch), "the real entry ran (item 32)")
        #expect(seen.flagInPerform == true, "the old project is still being saved: perform must find the gate closed")
        #expect(seen.gateAnswerInPerform == .cancelled, "a command pressed inside perform is cancelled, never run against the closing project")
        #expect(seen.barrierGoneAfterOpenTail == true, "precondition: by the end of the open tail the old writer is retired and its barrier released")
        #expect(seen.flagAfterOpenTail == false, "the open tail opens the gate after retiring the old writer: a Delete in the NEW project runs")
        #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "the tail retired the writer; nothing was left for the safety net")
        let inTheNewProject = await gate.acquire()
        #expect(inTheNewProject == .granted, "after the switch a command is granted the gate")
        gate.release()
    }
}

@Suite("Structural gate, reading and toasts — Tier 1 (t-94369a83 Phase 4b slice 2a fix round)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StructuralGateFixRoundTests {

    @Test("Item 2: a held command's own run keeps 'Finishing the last change' on screen, and it goes when the command ends")
    func testHeldCommandKeepsItsToastThroughItsOwnRun() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(40)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        let bodyMayEnd = LifecycleEntryHarness.Gate()
        let bodyStarted = GateOrderLog()

        // The command is held for a moment SHORTER than the toast delay, so it starts before the toast would have shown.
        let held = await gate.acquire()
        #expect(held == .granted)
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "long held command", cancelled: false) {
                bodyStarted.note("started")
                await bodyMayEnd.wait()
                return true
            }
        }
        let queued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(queued)
        gate.release()
        let started = await gateWaitUntil { bodyStarted.items == ["started"] }
        #expect(started)

        // The command is now RUNNING for longer than the delay: its toast must appear and stay (it used to be dismissed at start).
        let shown = await gateWaitUntil { rig.toasts.current?.message == DelayedProgressToast.finishingMessage }
        #expect(shown, "the held command's own run must show 'Finishing the last change'")
        bodyMayEnd.open()
        let result = await command.value
        #expect(result)
        #expect(rig.toasts.current == nil, "the toast is dismissed when the command's run is over")
    }

    @Test("R3: a held command's notice does not replace the progress toast of another operation, which is still on screen after the command ends")
    func testHeldCommandsNoticeYieldsToARunningExportToast() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(40)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        // An export is running and has its own progress toast up.
        let exportToast = Toast(style: .progress, message: "Exporting to Word\u{2026}")
        rig.toasts.show(exportToast)

        // A command is held behind another one for longer than the notice's delay.
        let held = await gate.acquire()
        #expect(held == .granted)
        let command = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "held behind an export", cancelled: false) { true }
        }
        let queued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(queued)
        try await Task.sleep(for: .milliseconds(200))   // well past the notice's 40 ms delay
        #expect(
            rig.toasts.current?.id == exportToast.id,
            "the notice must not replace the export's toast: \(String(describing: rig.toasts.current?.message))")

        gate.release()
        let result = await command.value
        #expect(result)
        #expect(
            rig.toasts.current?.id == exportToast.id,
            "the export is still running: its toast must still be on screen after the held command ended")
    }

    @Test("R3: two commands held one behind the other each get their own notice in turn, so the one that runs last still has it")
    func testSecondHeldCommandKeepsItsNotice() async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(40)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        let secondMayEnd = LifecycleEntryHarness.Gate()
        let ran = GateOrderLog()

        let held = await gate.acquire()
        #expect(held == .granted)
        let first = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "first", cancelled: false) { ran.note("first"); return true }
        }
        let firstQueued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(firstQueued)
        let second = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "second", cancelled: false) {
                ran.note("second")
                await secondMayEnd.wait()
                return true
            }
        }
        let secondQueued = await gateWaitUntil { gate.waiterCount == 2 }
        #expect(secondQueued)
        let noticeShown = await gateWaitUntil { rig.toasts.current?.message == DelayedProgressToast.finishingMessage }
        #expect(noticeShown)
        try await Task.sleep(for: .milliseconds(100))   // both notices' timers have fired by now

        gate.release()
        let secondRunning = await gateWaitUntil { ran.items == ["first", "second"] }
        #expect(secondRunning)
        #expect(
            rig.toasts.current?.message == DelayedProgressToast.finishingMessage,
            "the second command is running: its notice must be on screen, not left empty by the first one ending")
        secondMayEnd.open()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult && secondResult)
        #expect(rig.toasts.current == nil, "no notice is left behind when both are done")
    }

    @Test("Item 8: the dropped-presses warning is a notice-only warning that fades after 9 seconds")
    func testUndoQueueDroppedWarningFades() {
        let rig = GateRig()
        let toast = ToastFactory.undoQueueDropped()
        #expect(toast.style == .warning)
        #expect(toast.action == nil, "notice-only: no action")
        #expect(toast.fadeDelayOverride == .seconds(9))
        #expect(toast.fades, "it fades, so it does not hold the one warning slot")
        rig.controller.showUndoQueueDroppedWarning()
        #expect(rig.toasts.current?.message == "Some undo or redo presses could not be carried out.")
    }

    @Test("Item 13: isPerforming stays true while the gate is handed from one command to the next")
    func testIsPerformingIsTrueDuringTheHandOff() async {
        let rig = GateRig()
        let gate = rig.editorState.structuralGate
        let held = await gate.acquire()
        #expect(held == .granted)
        #expect(rig.controller.isPerforming)
        let next = Task { @MainActor in
            await rig.controller.runStructuralCommand(label: "next", cancelled: false) { true }
        }
        let queued = await gateWaitUntil { gate.waiterCount == 1 }
        #expect(queued)

        gate.release()
        // The next command has not resumed yet, but the gate has been handed to it: no moment reads "idle".
        #expect(rig.controller.isPerforming, "between release and the next command resuming the gate is still held")
        let result = await next.value
        #expect(result)
        #expect(!rig.controller.isPerforming)
    }
}
