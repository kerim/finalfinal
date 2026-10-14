//
//  LifecycleEntryHarness.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C2: the shared harness for the `LifecycleEntry` tests. It installs a test
//  `LifecycleEnvironment` (item 32: no real `DocumentManager`, no `AppDelegate`), builds a recording
//  `LifecycleHost`, and puts the entry's global state back afterwards. Later rounds' tests reuse it.
//

import Foundation
import Testing
@testable import final_final

/// The ONE parent suite for every test that touches `LifecycleEntry`'s process-global state:
/// `LifecycleEntry.current`, `.environment` and `.testEvents` (and so `resetForTests()`, which the harness runs
/// in a `defer`). Swift Testing serializes tests only within a suite (and, for `.serialized` on a parent,
/// within its nested suites): two sibling top-level suites run CONCURRENTLY, so one suite's reset used to clear
/// `testEvents` (or swap `environment`) in the middle of another suite's run. Every such suite is therefore
/// declared as a nested suite in an `extension LifecycleEntryStatic { ... }`, so `.serialized` here covers them
/// all against each other. Declare any new test that calls `LifecycleEntry.run` or `resetForTests` the same way.
@Suite("LifecycleEntry static state (t-94369a83 3a-1b)", .serialized)
enum LifecycleEntryStatic {}

@MainActor
enum LifecycleEntryHarness {

    /// Parks a `perform` closure until the test opens the gate.
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Records what the host closures were asked to do.
    @MainActor final class Probe {
        var log: [String] = []
        var tailTokens: [LifecycleToken] = []
        var currentSeenInTail: [LifecycleToken?] = []
    }

    /// One test's view of the app: what the environment closures answer, plus the editor state under test.
    @MainActor final class World {
        let editorState = EditorViewState()
        let toasts = ToastCenter()
        let probe = Probe()
        var hasOpenProject: Bool
        var isGettingStarted: Bool
        /// When true the environment reports no editor state at all (`AppDelegate.shared?.editorState` nil).
        var editorStateUnreachable: Bool
        /// When set, the environment answers with this state instead (the E9 swap to a new ContentView).
        var editorStateOverride: EditorViewState?
        var controller: StructuralUndoController?
        let bounds: LifecycleBounds

        init(
            hasOpenProject: Bool,
            isGettingStarted: Bool,
            editorStateUnreachable: Bool,
            controller: StructuralUndoController?,
            bounds: LifecycleBounds
        ) {
            self.hasOpenProject = hasOpenProject
            self.isGettingStarted = isGettingStarted
            self.editorStateUnreachable = editorStateUnreachable
            self.controller = controller
            self.bounds = bounds
            editorState.toastCenter = toasts
        }
    }

    /// A host whose closures only record into `probe`.
    static func makeHost(_ probe: Probe) -> LifecycleHost {
        LifecycleHost(
            activeWebView: { nil },
            runOpenTail: { token in
                probe.log.append("open")
                probe.tailTokens.append(token)
                probe.currentSeenInTail.append(LifecycleEntry.current?.token)
            },
            runCreateTail: { token, content in
                probe.log.append("create:\(content ?? "nil")")
                probe.tailTokens.append(token)
                probe.currentSeenInTail.append(LifecycleEntry.current?.token)
            },
            runCloseTail: { token, callOnClosed in
                probe.log.append("close:\(callOnClosed)")
                probe.tailTokens.append(token)
                probe.currentSeenInTail.append(LifecycleEntry.current?.token)
            },
            repostDeferredRebuilds: { probe.log.append("repost") },
            scheduleSourceModeReparse: { content in probe.log.append("reparse:\(content)") },
            toastCenter: { ToastCenter() }
        )
    }

    /// Installs a test environment reading a fresh `World`, runs `body`, and puts the entry's global state
    /// back. The editor state has NO host mounted: call `mount(_:)` for a test that wants the guard path.
    static func withWorld(
        hasOpenProject: Bool = true,
        isGettingStarted: Bool = false,
        editorStateUnreachable: Bool = false,
        controller: StructuralUndoController? = nil,
        bounds: LifecycleBounds = .production,
        _ body: (World) async throws -> Void
    ) async rethrows {
        let world = World(
            hasOpenProject: hasOpenProject,
            isGettingStarted: isGettingStarted,
            editorStateUnreachable: editorStateUnreachable,
            controller: controller,
            bounds: bounds
        )
        LifecycleEntry.environment = LifecycleEnvironment(
            hasOpenProject: { world.hasOpenProject },
            isGettingStartedProject: { world.isGettingStarted },
            editorState: { world.editorStateUnreachable ? nil : (world.editorStateOverride ?? world.editorState) },
            structuralUndoController: { world.controller },
            bounds: world.bounds
        )
        LifecycleEntry.resetForTests()
        defer {
            LifecycleEntry.environment = .production
            LifecycleEntry.resetForTests()
        }
        try await body(world)
    }

    /// Installs the recording host on the world's editor state, as ContentView's `.task` does.
    static func mount(_ world: World) {
        world.editorState.lifecycleHost = makeHost(world.probe)
    }

    /// Spins the main actor until `condition` holds (bounded; records an issue if it never does).
    static func waitUntil(
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for: \(what)", sourceLocation: sourceLocation)
    }
}
