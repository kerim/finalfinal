//
//  LifecycleEntryGettingStartedRoutingTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5b (slice-3a-1b-everyday.md section 4.4 and obligation N2): which tail
//  `LifecycleEntry.run` calls when the token was armed while GETTING STARTED was open.
//
//  Help > Getting Started -> a regular project (Open Project, Open Recent, Finder open, Repair, New Project, Import)
//  flips the app's root view from `.gettingStarted` to `.editor`, which builds a NEW ContentView (new editor
//  state, new services) that opens the project itself on mount (`ContentView.initializeProject` calls
//  `runProjectOpenSequence(kind: .launch)` whenever a project is open). The open tail on the OLD state would
//  reconfigure it for the new project (a second writer for it, a content push into a dead web view). So the old
//  state gets the CLOSE tail, as E9 does, without `onProjectClosed` (that would close the project the new view is
//  opening). `wasGettingStarted` is the value captured at arm (N1): by the time the tail is chosen,
//  `DocumentManager.isGettingStartedProject` already describes the NEW project, which the tests model by flipping it
//  inside `perform`.
//
//  Item 32: every test asserts the `.armed` entry event so a pass-through can never make one pass vacuously.
//

import Foundation
import Testing
@testable import final_final

// File-level helpers keep the suite one level inside `LifecycleEntryStatic`, the shared serialization parent.
private typealias Harness = LifecycleEntryHarness
private struct GettingStartedBoom: Error {}

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry Getting Started tail routing — Tier 1 (t-94369a83 3a-1b C5b)", .serialized)
    @MainActor
    struct LifecycleEntryGettingStartedRoutingTests {

        @Test("N2: Getting Started -> an opened regular project runs the CLOSE tail on the old state, WITHOUT onProjectClosed")
        func gettingStartedToOpenRunsTheCloseTail() async throws {
            try await Harness.withWorld(isGettingStarted: true) { world in
                Harness.mount(world)

                let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                    world.isGettingStarted = false   // DocumentManager has already switched to the new project
                    return .open
                }

                #expect(outcome == .performed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran")
                #expect(world.probe.log == ["close:false"], "log: \(world.probe.log)")
                #expect(world.probe.tailTokens.first?.wasGettingStarted == true)
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("N2: Getting Started -> a CREATED regular project (New Project, Import) runs the close tail too")
        func gettingStartedToCreateRunsTheCloseTail() async throws {
            for content in [nil, "# Imported"] as [String?] {
                try await Harness.withWorld(isGettingStarted: true) { world in
                    Harness.mount(world)

                    _ = try await LifecycleEntry.run(kind: .projectSwitch) {
                        world.isGettingStarted = false
                        return .create(content: content)
                    }

                    #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran")
                    #expect(world.probe.log == ["close:false"], "content \(String(describing: content)): \(world.probe.log)")
                }
            }
        }

        @Test("a REGULAR project's switch keeps the open tail and the create tail (the N2 routing keys on the token only)")
        func regularSwitchKeepsTheOpenAndCreateTails() async throws {
            try await Harness.withWorld(isGettingStarted: false) { world in
                Harness.mount(world)
                _ = try await LifecycleEntry.run(kind: .projectSwitch) { .open }
                #expect(world.probe.log == ["open"])
            }
            try await Harness.withWorld(isGettingStarted: false) { world in
                Harness.mount(world)
                _ = try await LifecycleEntry.run(kind: .projectSwitch) { .create(content: "# New") }
                #expect(world.probe.log == ["create:# New"])
            }
        }

        @Test("a perform that THROWS from Getting Started runs no tail at all (the abort restores; N2 never applies)")
        func throwingPerformFromGettingStartedRunsNoTail() async throws {
            await Harness.withWorld(isGettingStarted: true) { world in
                Harness.mount(world)
                await #expect(throws: GettingStartedBoom.self) {
                    try await LifecycleEntry.run(kind: .projectSwitch) { throw GettingStartedBoom() }
                }
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran")
                #expect(world.probe.log.isEmpty)
            }
        }
    }
}
