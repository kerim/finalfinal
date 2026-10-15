//
//  LifecycleEntryBusySlotTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md sections 5.2, 7.2 and 8): the one global busy
//  slot (N25, B15), the host captured at arm (#8, N26), the `@ObservationIgnored` lifecycle storage (N34)
//  and the section 8 notice strings (posted through the editor state's own `ToastCenter`, item 38). The
//  pass-through and the guard path itself are in `LifecycleEntryTests`.
//

import Foundation
import Observation
import Testing
@testable import final_final

// File-level helpers keep the suite one level inside `LifecycleEntryStatic`, the shared serialization parent.
private typealias Harness = LifecycleEntryHarness

private final class ObservationFlag: @unchecked Sendable { var fired = false }

extension LifecycleEntryStatic {
    @MainActor
    @Suite("LifecycleEntry busy slot, captured host and strings (t-94369a83 3a-1b)", .serialized)
    struct LifecycleEntryBusySlotTests {

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

        // MARK: - One global busy slot (N25, B15)

        @Test("a different request while a lifecycle runs is refused with the busy notice; perform never runs")
        func busyRefusalWhileAnotherLifecycleRuns() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .close) {
                        await gate.wait()
                        return .close
                    }
                }
                await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }
                // Positive proof the guard path ran for the first request.
                #expect(world.editorState.activeLifecycle?.kind == .close)
                #expect(LifecycleEntry.current?.token.kind == .close)

                var secondPerformed = 0
                let second = try await LifecycleEntry.run(kind: .projectSwitch) {
                    secondPerformed += 1
                    return .open
                }
                #expect(second == .refusedBusy(active: .close))
                #expect(secondPerformed == 0)
                #expect(world.toasts.current?.message == ToastFactory.lifecycleBusy().message)
                #expect(world.toasts.current?.style == .warning)
                #expect(world.editorState.activeLifecycle?.kind == .close, "the running lifecycle is untouched")
                #expect(LifecycleEntry.testEvents.contains(.refusedBusy(requested: .projectSwitch, active: .close)))

                gate.open()
                let firstOutcome = try await first.value
                #expect(firstOutcome == .performed)
                #expect(world.probe.log == ["close:true"], "only the first request's tail ran")
                #expect(LifecycleEntry.current == nil)
                #expect(world.editorState.activeLifecycle == nil)

                // The slot is free again.
                let third = try await LifecycleEntry.run(kind: .projectSwitch) { .open }
                #expect(third == .performed)
                #expect(world.probe.log == ["close:true", "open"])
            }
        }

        @Test("a same-kind repeat is a SILENT duplicate: no toast, perform never runs, logged as an event")
        func sameKindRepeatIsASilentDuplicate() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .close) {
                        await gate.wait()
                        return .close
                    }
                }
                await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }
                #expect(world.editorState.activeLifecycle?.kind == .close)

                var secondPerformed = 0
                let second = try await LifecycleEntry.run(kind: .close) {
                    secondPerformed += 1
                    return .close
                }
                #expect(second == .duplicate)
                #expect(secondPerformed == 0)
                #expect(world.toasts.current == nil, "a repeated Cmd-W must say nothing")
                #expect(LifecycleEntry.testEvents.contains(.duplicate(.close)))

                gate.open()
                _ = try await first.value
                #expect(world.probe.log == ["close:true"], "the repeat added no second tail")
            }
        }

        @Test("the busy slot is global: a request routed to a NEW editor state is refused, notice on the running editor")
        func busySlotIsGlobalAcrossEditorStates() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .close) {
                        await gate.wait()
                        return .none
                    }
                }
                await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }

                // E9: the new ContentView mounted and `AppDelegate.shared?.editorState` now points at it.
                let newState = EditorViewState()
                let newToasts = ToastCenter()
                newState.toastCenter = newToasts
                newState.lifecycleHost = Harness.makeHost(Harness.Probe())
                world.editorStateOverride = newState

                var performed = 0
                let second = try await LifecycleEntry.run(kind: .projectSwitch) {
                    performed += 1
                    return .open
                }
                #expect(second == .refusedBusy(active: .close))
                #expect(performed == 0)
                #expect(newState.activeLifecycle == nil, "nothing is armed on the new editor state")
                #expect(world.toasts.current != nil, "the notice goes through the editor state captured at arm")
                #expect(newToasts.current == nil)

                gate.open()
                _ = try await first.value
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

        @Test("section 8 notice strings: sentence case, glossary words, warning toasts that fade after 9s")
        func noticeStrings() {
            let closeCancelled = "Couldn't close the project while an earlier change was still finishing. " +
                "Try again in a moment."
            let otherCancelled = "Couldn't do that while an earlier change was still finishing. " +
                "Try again in a moment."
            let busy = "Couldn't do that while the project was being saved. Try again in a moment."
            let cases = [
                (ToastFactory.lifecycleCloseCancelled(), closeCancelled),
                (ToastFactory.lifecycleCancelled(), otherCancelled),
                (ToastFactory.lifecycleBusy(), busy)
            ]
            for (toast, text) in cases {
                #expect(toast.message == text)
                #expect(toast.style == .warning)
                #expect(toast.fadeDelayOverride == .seconds(9))
                #expect(toast.action == nil)
            }
        }
    }
}
