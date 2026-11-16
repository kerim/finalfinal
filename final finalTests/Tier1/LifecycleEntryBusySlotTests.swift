//
//  LifecycleEntryBusySlotTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md sections 5.2, 7.2 and 8): the one global slot (N25, B15), the host
//  captured at arm (#8, N26), the `@ObservationIgnored` lifecycle storage (N34) and the notice strings (posted through the editor
//  state's own `ToastCenter`, item 38). The pass-through and the guard path itself are in `LifecycleEntryTests`.
//
//  t-eb07cd67: the slot used to REFUSE a different request that arrived while a close or open was saving ("Try again in a moment")
//  and drop it. It now HOLDS it (`LifecycleEntry.withTurn`): the request runs when the running one ends, the last held one wins, a
//  repeated Cmd-W is a silent duplicate, a quit drops the held request, and the hand-on happens whatever way the first one ends.
//  The held request shows "Finishing the last change..." only after `LifecycleBounds.heldNoticeDelay`.
//
//  Every wait is bounded: each `run` is started with `startRun`, which records its outcome in an `OutcomeBox` the moment it returns,
//  and the tests read it with `finished` (the harness's bounded `waitUntil`). A request that is wrongly held, never handed on or
//  never dropped therefore FAILS a test with "timed out waiting for: ..." instead of hanging the run on an `await task.value`.
//

import Foundation
import Observation
import Testing
@testable import final_final

// File-level helpers keep the suite one level inside `LifecycleEntryStatic`, the shared serialization parent.
private typealias Harness = LifecycleEntryHarness

private final class ObservationFlag: @unchecked Sendable { var fired = false }

/// Counts `perform` calls made from a `Task` (a plain captured `var` cannot be mutated from one).
private final class PerformCount: @unchecked Sendable { var value = 0 }

/// What a `run` started by `startRun` returned (or threw), recorded the moment it ended.
private final class OutcomeBox: @unchecked Sendable {
    var value: LifecycleRunOutcome?
    var error: Error?
    var isFinished: Bool { value != nil || error != nil }
}

/// Thrown by a first command's `perform` in the hand-on test.
private struct HoldTestError: Error {}

extension LifecycleEntryStatic {
    @MainActor
    @Suite("LifecycleEntry hold slot, captured host and strings (t-94369a83 3a-1b, t-eb07cd67)", .serialized)
    struct LifecycleEntryBusySlotTests {

        // MARK: - Helpers

        /// Starts `run` in a Task and records what it returned, so a test waits for it with a BOUNDED wait (`finished`).
        private func startRun(
            _ kind: LifecycleKind,
            perform: @escaping @MainActor () async throws -> LifecycleTail
        ) -> OutcomeBox {
            let box = OutcomeBox()
            Task { @MainActor in
                do {
                    box.value = try await LifecycleEntry.run(kind: kind, perform: perform)
                } catch {
                    box.error = error
                }
            }
            return box
        }

        /// A close parked on `gate` inside its `perform`; returns once its lifecycle has armed.
        private func startParkedClose(_ world: Harness.World, gate: Harness.Gate) async -> OutcomeBox {
            let box = startRun(.close) {
                await gate.wait()
                return .close
            }
            await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }
            return box
        }

        /// Waits (bounded, the harness's) until the run behind `box` has ended, and returns what it returned (nil if it threw or never ended).
        private func finished(_ box: OutcomeBox, _ what: String) async -> LifecycleRunOutcome? {
            await Harness.waitUntil(what) { box.isFinished }
            return box.value
        }

        /// Waits (bounded) until the entry recorded `event`.
        private func waitForEvent(_ what: String, _ event: LifecycleEntry.Event) async {
            await Harness.waitUntil(what) { LifecycleEntry.testEvents.contains(event) }
        }

        // MARK: - Host captured at arm (#8, N26)

        @Test("the host survives a view swap: tearing it down during perform does not lose the tail")
        func hostSurvivesViewSwap() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    // ContentView's `.onDisappear`, mid-lifecycle: the view is gone, `lifecycleHost` is nil.
                    world.editorState.lifecycleHost = nil
                    return .close
                }
                #expect(outcome == .performed)
                #expect(world.probe.log == ["close:true"], "the tail must use the host captured at arm")
                #expect(world.editorState.lifecycleHost == nil, "the entry must not put a host back")
                #expect(LifecycleEntry.current == nil)
            }
        }

        // MARK: - One global slot: a different request is HELD (t-eb07cd67)

        @Test("a different request during a close is HELD, not refused: nothing shows in the first second, and it runs after the close")
        func aDifferentRequestDuringACloseIsHeldThenRuns() async {
            await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = await startParkedClose(world, gate: gate)
                #expect(world.editorState.activeLifecycle?.kind == .close)
                #expect(LifecycleEntry.current?.token.kind == .close)

                let performed = PerformCount()
                let second = startRun(.projectSwitch) {
                    performed.value += 1
                    world.probe.log.append("perform switch")
                    return .open
                }
                await waitForEvent("the switch to be held", .held(requested: .projectSwitch, behind: .close))
                #expect(performed.value == 0, "a held request does not run while the close is saving")
                #expect(world.toasts.current == nil, "nothing on screen in the first second, and never a warning")
                #expect(world.editorState.activeLifecycle?.kind == .close, "the running lifecycle is untouched")
                #expect(LifecycleEntry.current?.token.kind == .close)

                gate.open()
                let firstOutcome = await finished(first, "the close to finish")
                #expect(firstOutcome == .performed)
                let secondOutcome = await finished(second, "the held switch to run and finish")
                #expect(secondOutcome == .performed, "the held switch ran and finished")
                #expect(performed.value == 1)
                #expect(
                    world.probe.log == ["close:true", "perform switch", "open"],
                    "the close finished first, then the held switch ran")
                #expect(LifecycleEntry.testEvents.contains(.admitted(.projectSwitch)))
                #expect(LifecycleEntry.current == nil)
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        @Test("the last of several held requests wins: an earlier held one is superseded, and a held close can replace a held switch")
        func theLastOfSeveralHeldRequestsWins() async {
            await Harness.withWorld { world in
                Harness.mount(world)

                // Two switches behind a close: A is replaced by B.
                let gate = Harness.Gate()
                let first = await startParkedClose(world, gate: gate)
                let aBox = startRun(.projectSwitch) {
                    world.probe.log.append("perform A")
                    return .open
                }
                await waitForEvent("A to be held", .held(requested: .projectSwitch, behind: .close))
                let bBox = startRun(.projectSwitch) {
                    world.probe.log.append("perform B")
                    return .open
                }
                // A returns BEFORE the gate opens: it was replaced, not run.
                let aOutcome = await finished(aBox, "A to be replaced by B")
                #expect(aOutcome == .superseded)
                #expect(LifecycleEntry.testEvents.contains(.superseded(.projectSwitch)))
                #expect(world.toasts.current == nil, "a replaced request says nothing")
                gate.open()
                let firstOutcome = await finished(first, "the close to finish")
                #expect(firstOutcome == .performed)
                let bOutcome = await finished(bBox, "B to run and finish")
                #expect(bOutcome == .performed)
                #expect(world.probe.log == ["close:true", "perform B", "open"], "only the last request ran")

                // A close held behind a close, replacing a held switch: the close is NOT a duplicate (the newest request is the switch).
                world.probe.log.removeAll()
                LifecycleEntry.testEvents.removeAll()
                let gate2 = Harness.Gate()
                let first2 = await startParkedClose(world, gate: gate2)
                let replacedBox = startRun(.projectSwitch) {
                    world.probe.log.append("perform C")
                    return .open
                }
                await waitForEvent("the switch to be held", .held(requested: .projectSwitch, behind: .close))
                let replacingBox = startRun(.close) {
                    world.probe.log.append("perform D")
                    return .close
                }
                let replacedOutcome = await finished(replacedBox, "the switch to be replaced by the close")
                #expect(replacedOutcome == .superseded)
                #expect(LifecycleEntry.testEvents.contains(.held(requested: .close, behind: .close)))
                gate2.open()
                let first2Outcome = await finished(first2, "the second close to finish")
                #expect(first2Outcome == .performed)
                let replacingOutcome = await finished(replacingBox, "the held close to run and finish")
                #expect(replacingOutcome == .performed)
                #expect(
                    world.probe.log == ["close:true", "perform D", "close:true"],
                    "the held close ran, the replaced switch did not")
            }
        }

        @Test("a repeated Cmd-W is a SILENT duplicate: no toast, perform never runs; also behind a switch that already has a held close")
        func aRepeatedCloseIsASilentDuplicate() async {
            await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = await startParkedClose(world, gate: gate)

                let performed = PerformCount()
                let secondBox = startRun(.close) {
                    performed.value += 1
                    return .close
                }
                let secondOutcome = await finished(secondBox, "the repeated close to return at once")
                #expect(secondOutcome == .duplicate)
                #expect(performed.value == 0)
                #expect(world.toasts.current == nil, "a repeated Cmd-W must say nothing")
                #expect(LifecycleEntry.testEvents.contains(.duplicate(.close)))

                gate.open()
                _ = await finished(first, "the close to finish")
                #expect(world.probe.log == ["close:true"], "the repeat added no second tail")

                // A switch is running and a close is already held behind it: another Cmd-W is a duplicate of the held close.
                world.probe.log.removeAll()
                LifecycleEntry.testEvents.removeAll()
                let gate2 = Harness.Gate()
                let running = startRun(.projectSwitch) {
                    await gate2.wait()
                    return .open
                }
                await Harness.waitUntil("the switch to arm") { world.editorState.activeLifecycle != nil }
                let heldClose = startRun(.close) {
                    world.probe.log.append("perform held close")
                    return .close
                }
                await waitForEvent("the close to be held", .held(requested: .close, behind: .projectSwitch))
                let thirdBox = startRun(.close) {
                    performed.value += 1
                    return .close
                }
                let thirdOutcome = await finished(thirdBox, "the second repeated close to return at once")
                #expect(thirdOutcome == .duplicate)
                #expect(performed.value == 0)
                #expect(world.toasts.current == nil)
                gate2.open()
                let runningOutcome = await finished(running, "the switch to finish")
                #expect(runningOutcome == .performed)
                let heldCloseOutcome = await finished(heldClose, "the held close to run and finish")
                #expect(heldCloseOutcome == .performed)
                #expect(
                    world.probe.log == ["open", "perform held close", "close:true"],
                    "exactly one close ran, after the switch")
            }
        }

        @Test("a held request shows \"Finishing the last change...\" only after the delay (never a warning), and the toast goes when it runs")
        func aHeldRequestShowsFinishingAfterTheDelay() async {
            var bounds = LifecycleBounds.production
            bounds.heldNoticeDelay = 0.1
            await Harness.withWorld(bounds: bounds) { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = await startParkedClose(world, gate: gate)
                let second = startRun(.projectSwitch) { .open }
                var sawWarning = false
                await Harness.waitUntil("the Finishing notice") {
                    if world.toasts.current?.style == .warning { sawWarning = true }
                    return world.toasts.current?.message == DelayedProgressToast.finishingMessage
                        && world.toasts.current?.style == .progress
                }
                gate.open()
                let firstOutcome = await finished(first, "the close to finish")
                #expect(firstOutcome == .performed)
                let secondOutcome = await finished(second, "the held switch to run and finish")
                #expect(secondOutcome == .performed)
                #expect(
                    world.toasts.current?.message != DelayedProgressToast.finishingMessage,
                    "the notice is taken down when the held request runs")
                if world.toasts.current?.style == .warning { sawWarning = true }
                #expect(!sawWarning, "a held request is never refused with a warning")
            }
        }
    }
}

// The rest of the suite is in an extension, so the struct body stays under the project's type-body-length limit.
extension LifecycleEntryStatic.LifecycleEntryBusySlotTests {

    @Test("a quit drops the held request (it returns skippedForQuit before the first one ends) and every later request does nothing")
    func aQuitDropsTheHeldRequest() async {
        await Harness.withWorld { world in
            Harness.mount(world)
            let gate = Harness.Gate()
            let first = await startParkedClose(world, gate: gate)
            let performed = PerformCount()
            let heldBox = startRun(.projectSwitch) {
                performed.value += 1
                return .open
            }
            await waitForEvent("the switch to be held", .held(requested: .projectSwitch, behind: .close))

            // What `AppDelegate.runQuitSequence` does when it joins the running close.
            _ = world.editorState.armLifecycle(.quit, wasGettingStarted: false)
            LifecycleEntry.noteQuitStarted()

            let heldOutcome = await finished(heldBox, "the held request to be dropped before the close ends")
            #expect(heldOutcome == .skippedForQuit, "returns before the gate opens: dropped, not waiting")
            #expect(performed.value == 0)
            #expect(LifecycleEntry.testEvents.contains(.droppedForQuit(.projectSwitch)))
            #expect(world.toasts.current == nil, "the app is quitting: nothing is shown")

            let freshBox = startRun(.projectSwitch) {
                performed.value += 1
                return .open
            }
            let freshOutcome = await finished(freshBox, "a request made after the quit started to return at once")
            #expect(freshOutcome == .skippedForQuit, "a command pressed after the quit started does nothing, at once")
            #expect(performed.value == 0)

            gate.open()
            _ = await finished(first, "the close to finish")
        }
    }

    @Test("the hold is global: a request routed to a NEW editor state is held, and its notice shows on the running editor's window")
    func theHoldIsGlobalAcrossEditorStates() async {
        var bounds = LifecycleBounds.production
        bounds.heldNoticeDelay = 0.1
        await Harness.withWorld(bounds: bounds) { world in
            Harness.mount(world)
            let gate = Harness.Gate()
            let first = startRun(.close) {
                await gate.wait()
                return .none
            }
            await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }

            // E9: the new ContentView mounted and `AppDelegate.shared?.editorState` now points at it.
            let newState = EditorViewState()
            let newToasts = ToastCenter()
            newState.toastCenter = newToasts
            let newProbe = Harness.Probe()
            newState.lifecycleHost = Harness.makeHost(newProbe)
            world.editorStateOverride = newState

            let performed = PerformCount()
            let second = startRun(.projectSwitch) {
                performed.value += 1
                return .open
            }
            await waitForEvent("the switch to be held", .held(requested: .projectSwitch, behind: .close))
            #expect(performed.value == 0)
            #expect(newState.activeLifecycle == nil, "nothing is armed on the new editor state while it waits")
            await Harness.waitUntil("the notice on the running window's toast center") {
                world.toasts.current?.message == DelayedProgressToast.finishingMessage
            }
            #expect(newToasts.current == nil, "the notice goes through the editor state that is running, not the new one")

            gate.open()
            _ = await finished(first, "the close to finish")
            let secondOutcome = await finished(second, "the held switch to run and finish")
            #expect(secondOutcome == .performed)
            #expect(performed.value == 1)
            #expect(newProbe.log == ["open"], "it ran, armed on the new editor state")
            #expect(newProbe.tailTokens.count == 1)
        }
    }

    // MARK: - The turn is handed on whichever way the first command ends

    @Test("a close held behind a switch closes the project the switch has just opened (run as if pressed after it)")
    func aCloseHeldBehindASwitchClosesTheNewlyOpenedProject() async {
        await Harness.withWorld { world in
            Harness.mount(world)
            let gate = Harness.Gate()
            let switching = startRun(.projectSwitch) {
                await gate.wait()
                return .open
            }
            await Harness.waitUntil("the switch to arm") { world.editorState.activeLifecycle != nil }
            let closing = startRun(.close) { .close }
            await waitForEvent("the close to be held", .held(requested: .close, behind: .projectSwitch))
            #expect(world.probe.log.isEmpty, "nothing ran yet")

            gate.open()
            let switchingOutcome = await finished(switching, "the switch to finish")
            #expect(switchingOutcome == .performed)
            let closingOutcome = await finished(closing, "the held close to run and finish")
            #expect(closingOutcome == .performed)
            #expect(world.probe.log == ["open", "close:true"], "the close ran after the open, against the project then open")
        }
    }

    @Test("the held request still runs when the first perform THROWS, and the turn is then free")
    func aHeldCommandRunsWhenTheFirstPerformThrows() async {
        await Harness.withWorld { world in
            Harness.mount(world)
            let gate = Harness.Gate()
            let first = startRun(.projectSwitch) {
                await gate.wait()
                throw HoldTestError()
            }
            await Harness.waitUntil("the first switch to arm") { world.editorState.activeLifecycle != nil }
            let held = startRun(.close) {
                world.probe.log.append("perform close")
                return .close
            }
            await waitForEvent("the close to be held", .held(requested: .close, behind: .projectSwitch))

            gate.open()
            _ = await finished(first, "the first run to rethrow its perform's error")
            #expect(first.error is HoldTestError, "`run` rethrows after the abort routine restored the editor: \(String(describing: first.error))")

            // Without the hand-on after a throw the held close never runs; the bounded wait says so.
            let heldOutcome = await finished(held, "the held close to run after the throw")
            #expect(heldOutcome == .performed)
            guard heldOutcome != nil else { return }

            // The turn is free: a further request is admitted at once, not held.
            let third = startRun(.projectSwitch) { .open }
            let thirdOutcome = await finished(third, "a third request to run at once")
            #expect(thirdOutcome == .performed)
            #expect(
                !LifecycleEntry.testEvents.contains(.held(requested: .projectSwitch, behind: .close)),
                "the third request was admitted, never held")
        }
    }

    // MARK: - Storage and strings

    @Test("lifecycle storage on EditorViewState is @ObservationIgnored (N34)")
    func lifecycleStorageIsObservationIgnored() {
        let state = EditorViewState()
        let ignored = ObservationFlag()
        withObservationTracking({
            _ = state.lifecycleHost
            _ = state.lifecycleBarrier
            _ = state.runningRebuildTasks
            _ = state.lifecycleFlushDoneFor
            _ = state.lifecycleBackupDoneFor
        }, onChange: { ignored.fired = true })
        state.lifecycleHost = Harness.makeHost(Harness.Probe())
        state.lifecycleBarrier = nil
        state.runningRebuildTasks[UUID()] = Task {}
        state.lifecycleFlushDoneFor = UUID()
        state.lifecycleBackupDoneFor = UUID()
        #expect(ignored.fired == false)
        state.runningRebuildTasks.values.forEach { $0.cancel() }

        // Positive control: the same tracking DOES fire for an ordinary observed property, so the check
        // above cannot pass just because observation never fires in this harness.
        let control = ObservationFlag()
        withObservationTracking({ _ = state.wordCount }, onChange: { control.fired = true })
        state.wordCount += 1
        #expect(control.fired)
    }

    @Test("stuck-save notices: one per command, naming what did not happen, text is safe, never 'try again' or 'wait'; 9s warning toasts")
    func stuckSaveNoticeStrings() {
        let tail = " because an earlier change didn't finish. Your text is safe."
        let approved: [(LifecycleCommand, String)] = [
            (.close, "The project wasn't closed" + tail),
            (.openProject, "The other project wasn't opened" + tail),
            (.saveAs, "Save As didn't make a copy" + tail),
            (.newProject, "The new project wasn't created" + tail),
            (.importMarkdown, "The file wasn't imported" + tail),
            (.gettingStarted, "Getting Started wasn't opened" + tail),
            (.repair, "The project wasn't repaired" + tail)
        ]
        #expect(approved.count == LifecycleCommand.allCases.count, "every command has an approved string")
        #expect(Set(approved.map { $0.1 }).count == approved.count, "each command's notice is different")
        for (command, text) in approved {
            let toast = ToastFactory.lifecycleCancelled(command)
            #expect(toast.message == text)
            #expect(toast.style == .warning)
            #expect(toast.fadeDelayOverride == .seconds(9))
            #expect(toast.action == nil)
            let lowered = toast.message.lowercased()
            for banned in ["try again", "wait", "moment"] {
                #expect(!lowered.contains(banned), "\(command): the notice must not ask the user to time anything")
            }
        }
    }
}
