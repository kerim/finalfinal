//
//  LifecycleEntryTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md section 5.2 and section 7.2): the
//  `LifecycleEntry` skeleton, with no save sequence and no real tail behind it yet. This file covers the
//  pass-through and the guard path; `LifecycleEntryBusySlotTests` covers the busy slot, the host captured
//  at arm, and the notice strings. Shared harness: `Helpers/LifecycleEntryHarness.swift`.
//
//  Item 32: every test that expects the guard path installs a host and POSITIVELY asserts the token was
//  armed (`activeLifecycle` / `LifecycleEntry.current` seen from inside `perform`, and the `.armed` event),
//  so a pass-through can never make such a test pass vacuously.
//

import Foundation
import Testing
@testable import final_final

// Helper types are file-level (not nested in the suite) so the suite stays one level inside
// `LifecycleEntryStatic`, the shared serialization parent (Helpers/LifecycleEntryHarness.swift).
private typealias Harness = LifecycleEntryHarness

private struct Boom: Error, Equatable {}

private struct TailCase {
    let kind: LifecycleKind
    let tail: LifecycleTail
    let expectedLog: String
}

extension LifecycleEntryStatic {
    @MainActor
    @Suite("LifecycleEntry pass-through and guard path (t-94369a83 3a-1b)", .serialized)
    struct LifecycleEntryTests {

        // MARK: - Pass-through

        @Test("no open project: perform runs straight through, nothing is armed")
        func passesThroughWithNoOpenProject() async throws {
            try await Harness.withWorld(hasOpenProject: false) { world in
                Harness.mount(world)
                var performed = 0
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    #expect(world.editorState.activeLifecycle == nil)
                    return .close
                }
                #expect(outcome == .performed)
                #expect(performed == 1)
                #expect(world.probe.log.isEmpty, "no tail closure may run on a pass-through")
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
            }
        }

        @Test("no mounted host: perform runs straight through, nothing is armed")
        func passesThroughWithNoHost() async throws {
            try await Harness.withWorld { world in
                // Deliberately no `mount`: ContentView's `.task` has not installed a host.
                var performed = 0
                let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                    performed += 1
                    return .open
                }
                #expect(outcome == .performed)
                #expect(performed == 1)
                #expect(world.probe.log.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noHost)])
            }
        }

        @Test("no editor state reachable: perform runs straight through")
        func passesThroughWithNoEditorState() async throws {
            try await Harness.withWorld(editorStateUnreachable: true) { _ in
                var performed = 0
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    performed += 1
                    return .close
                }
                #expect(outcome == .performed)
                #expect(performed == 1)
                #expect(LifecycleEntry.current == nil)
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noEditorState)])
            }
        }

        @Test("a pass-through still rethrows what perform throws")
        func passThroughRethrows() async {
            await Harness.withWorld(hasOpenProject: false) { _ in
                await #expect(throws: Boom.self) {
                    try await LifecycleEntry.run(kind: .close) { throw Boom() }
                }
                #expect(LifecycleEntry.current == nil)
            }
        }

        // MARK: - The guard path

        @Test("guard path: token armed and slot held while perform runs, then the matching tail, then everything cleared")
        func armsRunsPerformThenTheTail() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                var seenInPerform: LifecycleToken?
                var currentInPerform: LifecycleToken?
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    seenInPerform = world.editorState.activeLifecycle
                    currentInPerform = LifecycleEntry.current?.token
                    return .close
                }
                #expect(outcome == .performed)
                // Positive proof the guard path ran (item 32): the token existed while perform ran.
                let token = try #require(seenInPerform)
                #expect(token.kind == .close)
                #expect(currentInPerform == token)
                #expect(LifecycleEntry.testEvents.first == .armed(.close))
                // The tail ran once, with the same token, inside the slot (current is cleared only after it).
                #expect(world.probe.log == ["close:true"])
                #expect(world.probe.tailTokens == [token])
                #expect(world.probe.currentSeenInTail == [token])
                // Everything cleared at the end.
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("the returned LifecycleTail picks the host closure: open, create, close, none")
        func tailRoutesToTheMatchingHostClosure() async throws {
            let cases = [
                TailCase(kind: .projectSwitch, tail: .open, expectedLog: "open"),
                TailCase(kind: .projectSwitch, tail: .create(content: "# New"), expectedLog: "create:# New"),
                TailCase(kind: .projectSwitch, tail: .create(content: nil), expectedLog: "create:nil"),
                TailCase(kind: .close, tail: .close, expectedLog: "close:true"),
                // E9 (Getting Started): `perform` posts nothing, the close tail runs WITHOUT onProjectClosed.
                TailCase(kind: .close, tail: .none, expectedLog: "close:false")
            ]
            for testCase in cases {
                try await Harness.withWorld { world in
                    Harness.mount(world)
                    _ = try await LifecycleEntry.run(kind: testCase.kind) { testCase.tail }
                    #expect(world.probe.log == [testCase.expectedLog], "tail \(testCase.tail)")
                    #expect(LifecycleEntry.current == nil)
                }
            }
        }

        @Test("perform throwing rethrows, runs no tail, and leaves neither a token nor a held slot")
        func throwingPerformClearsEverything() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                await #expect(throws: Boom.self) {
                    try await LifecycleEntry.run(kind: .projectSwitch) { throw Boom() }
                }
                #expect(world.probe.log.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch))
                // The slot is free again: a following request is accepted.
                let outcome = try await LifecycleEntry.run(kind: .close) { .close }
                #expect(outcome == .performed)
                #expect(world.probe.log == ["close:true"])
            }
        }

        @Test("wasGettingStarted is captured when the token is armed, not when the tail runs (N1)")
        func wasGettingStartedIsCapturedAtArm() async throws {
            try await Harness.withWorld(isGettingStarted: true) { world in
                Harness.mount(world)
                _ = try await LifecycleEntry.run(kind: .close) {
                    // E9: by the time the tail runs, DocumentManager has already switched over.
                    world.isGettingStarted = false
                    return .none
                }
                let token = try #require(world.probe.tailTokens.first)
                #expect(token.wasGettingStarted)
            }
        }

        @Test("the deadline comes from the bounds for the kind: close and switch 15s, scaled here")
        func deadlineComesFromTheBounds() async throws {
            try await Harness.withWorld(bounds: LifecycleBounds.production.scaled(0.1)) { world in
                Harness.mount(world)
                var remaining: TimeInterval = -1
                _ = try await LifecycleEntry.run(kind: .close) {
                    remaining = LifecycleEntry.current?.deadline.remaining ?? -1
                    return .close
                }
                #expect(remaining > 0 && remaining <= 1.5, "closeTotal 15s x 0.1")
            }
        }

        @Test("the structural-undo controller is captured at arm, not re-read later (C26)")
        func controllerIsCapturedAtArm() async throws {
            try await Harness.withWorld(controller: StructuralUndoController()) { world in
                Harness.mount(world)
                let armedController = try #require(world.controller)
                var captured: StructuralUndoController?
                _ = try await LifecycleEntry.run(kind: .close) {
                    world.controller = nil  // e.g. the next ContentView replaced the global one
                    captured = LifecycleEntry.current?.structuralUndoController
                    return .close
                }
                #expect(captured === armedController)
            }
        }
    }
}
