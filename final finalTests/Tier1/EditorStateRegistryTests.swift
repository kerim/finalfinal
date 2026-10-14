//
//  EditorStateRegistryTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, e2e fix round: which editor state the lifecycle acts on.
//
//  The bug these pin (found by the disposable-VM e2e run): a Finder / `open(1)` double-click of a second project
//  while one is open makes macOS create an EXTRA main window. That window builds its own ContentView, whose `.task`
//  used to overwrite `AppDelegate.editorState` (a weak, last-writer-wins pointer) and install its own host; the
//  window is then closed, so by the time `ProjectCommands.openFromFinder` reached `LifecycleEntry.run` the pointer
//  held a closed window's state (no host, or already freed). `run` passed through: the project was opened in
//  `DocumentManager` without saving the old one, and nothing reloaded the real editor.
//
//  The unit suite cannot mount windows, so each ContentView registers its state WITH the window it lives in
//  (`AppDelegate.registerEditorState`), and `AppDelegate.editorState` resolves the state of `mainWindow`. These
//  tests stand in plain `NSWindow` objects (never shown) for the real and the extra window and install the
//  environment the app installs: `editorState: { delegate.editorState }`.
//
//  Item 32: every test that expects the guard path asserts the `.armed` event (never a bare "perform ran"), and
//  the recording probe of the MAIN state saw the tail while the extra window's probe saw nothing.
//

import AppKit
import Foundation
import Testing
@testable import final_final

private typealias Harness = LifecycleEntryHarness

/// A window that is never shown; `isReleasedWhenClosed` off because ARC owns it.
@MainActor
private func makeTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

/// The real window, the extra window a Finder open creates, and one editor state with a recording host in each.
@MainActor
private final class FinderOpenRig {
    let delegate = AppDelegate()
    let mainWindow = makeTestWindow()
    let extraWindow = makeTestWindow()
    let mainProbe = Harness.Probe()
    let extraProbe = Harness.Probe()
    let main = EditorViewState()
    let extra = EditorViewState()

    init() {
        delegate.mainWindow = mainWindow
        main.lifecycleHost = Harness.makeHost(mainProbe)
        extra.lifecycleHost = Harness.makeHost(extraProbe)
    }

    /// What `LifecycleEnvironment.production` reads (`AppDelegate.shared?.editorState`), on this rig's delegate. Only
    /// call inside `Harness.withWorld`, which puts the environment back.
    func installLifecycleEnvironment() {
        LifecycleEntry.environment.editorState = { [delegate] in delegate.editorState }
    }

    /// The ContentView of each window attaching to it (its window reader / `.task`).
    func mountMain() { delegate.registerEditorState(main, in: mainWindow) }
    func mountExtra() { delegate.registerEditorState(extra, in: extraWindow) }
}

extension LifecycleEntryStatic {
    @MainActor
    @Suite("Which editor state the lifecycle acts on (t-94369a83 3a-1b e2e fix)", .serialized)
    struct EditorStateRegistryTests {

        // MARK: - The Finder-open extra window

        @Test("""
            the extra window mounts AFTER the main one and is still up: the lifecycle arms on the MAIN window's state \
            with the MAIN window's host (the old pointer pointed at the extra one)
            """)
        func armsOnMainStateWhileExtraWindowIsUp() async throws {
            try await Harness.withWorld { _ in
                let rig = FinderOpenRig()
                rig.installLifecycleEnvironment()
                rig.mountMain()
                rig.mountExtra()
                #expect(rig.delegate.editorState === rig.main)

                var performed = 0
                let outcome = try await LifecycleEntry.run(kind: .projectSwitch) {
                    performed += 1
                    return .open
                }
                #expect(outcome == .performed)
                #expect(performed == 1)
                #expect(LifecycleEntry.testEvents == [.armed(.projectSwitch)], "must ARM, not pass through")
                #expect(rig.mainProbe.log == ["open"], "the open tail ran on the main window's host")
                #expect(rig.extraProbe.log.isEmpty, "nothing ran on the extra window's host")
                #expect(rig.extra.activeLifecycle == nil)
            }
        }

        @Test("""
            the extra window mounts and then goes away (its ContentView's .onDisappear): the lifecycle still arms on \
            the main window's state (the old pointer was left on a state with no host, or on a freed one)
            """)
        func armsOnMainStateAfterExtraWindowDisappears() async throws {
            try await Harness.withWorld { _ in
                let rig = FinderOpenRig()
                rig.installLifecycleEnvironment()
                rig.mountMain()
                rig.mountExtra()
                EditorStateRegistry.contentViewDidDisappear(rig.extra)
                #expect(rig.extra.lifecycleHost == nil, "the extra view's own host is dropped")

                let outcome = try await LifecycleEntry.run(kind: .projectSwitch) { .open }
                #expect(outcome == .performed)
                #expect(LifecycleEntry.testEvents == [.armed(.projectSwitch)], "must ARM, not pass through")
                #expect(rig.mainProbe.log == ["open"])
                #expect(rig.extraProbe.log.isEmpty)
            }
        }

        @Test("""
            the extra window registers FIRST, before the main one: it never becomes the lifecycle's state, and when \
            it is the only one registered the lifecycle passes through rather than act on it
            """)
        func extraWindowRegisteringFirstNeverBecomesTheLifecycleState() async throws {
            try await Harness.withWorld { _ in
                let rig = FinderOpenRig()
                rig.installLifecycleEnvironment()
                rig.mountExtra()
                #expect(rig.delegate.editorState == nil, "the extra window is not the main window")

                var performed = 0
                _ = try await LifecycleEntry.run(kind: .projectSwitch) {
                    performed += 1
                    return .open
                }
                #expect(performed == 1, "perform still runs: nothing is mounted for the main window yet")
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noEditorState)])
                #expect(rig.extraProbe.log.isEmpty, "the extra window's host was never used")
                LifecycleEntry.resetForTests()

                rig.mountMain()
                #expect(rig.delegate.editorState === rig.main, "the main window's state wins whatever the order")
                _ = try await LifecycleEntry.run(kind: .projectSwitch) { .open }
                #expect(LifecycleEntry.testEvents == [.armed(.projectSwitch)])
                #expect(rig.mainProbe.log == ["open"])
                #expect(rig.extraProbe.log.isEmpty)
            }
        }

        @Test("""
            a disappearing ContentView drops only ITS OWN host: the extra window going away leaves the main window's \
            host and registration alone, and the main window's own teardown does drop its host (then the lifecycle \
            passes through on noHost)
            """)
        func disappearingViewTouchesOnlyItsOwnState() async throws {
            try await Harness.withWorld { _ in
                let rig = FinderOpenRig()
                rig.installLifecycleEnvironment()
                rig.mountMain()
                rig.mountExtra()

                EditorStateRegistry.contentViewDidDisappear(rig.extra)
                #expect(rig.main.lifecycleHost != nil, "the registered state's host is untouched")
                #expect(rig.delegate.editorState === rig.main)

                EditorStateRegistry.contentViewDidDisappear(rig.main)
                #expect(rig.main.lifecycleHost == nil, "item 11: the host is nil-ed on its own view's teardown")
                _ = try await LifecycleEntry.run(kind: .projectSwitch) { .open }
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noHost)])
            }
        }

        // MARK: - Getting Started and regular project swap the root view in the SAME window

        @Test("""
            the Getting Started <-> editor swap builds a NEW ContentView in the same window: the new state registers \
            and becomes the app's editor state, in either order of mount and teardown, while the lifecycle armed on \
            the old state keeps the state and host it captured at arm (N26)
            """)
        func swapRegistersTheNewStateAndTheRunningLifecycleKeepsTheOldOne() async throws {
            try await Harness.withWorld(isGettingStarted: true) { _ in
                let rig = FinderOpenRig()
                rig.installLifecycleEnvironment()
                rig.mountMain()
                let gate = Harness.Gate()
                let running = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        await gate.wait()
                        return .open
                    }
                }
                await Harness.waitUntil("the lifecycle to arm on the old state") { rig.main.activeLifecycle != nil }

                // The swap: the new ContentView mounts first, then the old one goes away.
                let newProbe = Harness.Probe()
                let new = EditorViewState()
                new.lifecycleHost = Harness.makeHost(newProbe)
                rig.delegate.registerEditorState(new, in: rig.mainWindow)
                EditorStateRegistry.contentViewDidDisappear(rig.main)
                #expect(rig.delegate.editorState === new, "the NEW ContentView's state is the app's editor state")
                #expect(LifecycleEntry.current?.editorState === rig.main, "the running lifecycle holds the old state")

                gate.open()
                _ = try await running.value
                #expect(rig.mainProbe.log == ["close:false"], "N2: the tail ran on the OLD state, with the host captured at arm")
                #expect(newProbe.log.isEmpty, "nothing ran on the new view's host")
                #expect(rig.delegate.editorState === new)
            }
        }

        @Test("the old view's teardown running BEFORE the new view registers leaves nothing stale: the new state registers fresh")
        func teardownBeforeNewMountStillRegistersTheNewState() {
            let rig = FinderOpenRig()
            rig.mountMain()
            EditorStateRegistry.contentViewDidDisappear(rig.main)

            let new = EditorViewState()
            rig.delegate.registerEditorState(new, in: rig.mainWindow)
            #expect(rig.delegate.editorState === new, "the most recent state registered in the main window wins")
        }

        // MARK: - The view wiring (a source scan: the unit suite cannot mount a ContentView)

        @Test("""
            ContentView registers its state with its OWN window through HostWindowReader, and its .onDisappear drops only its \
            own host; nothing assigns the app's editor state directly (the property is get-only, so that is a compile error too)
            """)
        func contentViewIsWiredToTheRegistry() throws {
            let url = ProjectPostSiteScanner.repoRoot().appendingPathComponent("final final/Views/ContentView.swift")
            let source = ProjectPostSiteScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            #expect(source.contains("HostWindowReader"), "ContentView must read its window")
            #expect(source.contains("registerEditorState(editorState, in: window)"), "and register its state with it")
            #expect(source.contains("EditorStateRegistry.contentViewDidDisappear(editorState)"), "and tear down only itself")
            #expect(!source.contains("AppDelegate.shared?.editorState ="), "the last-writer-wins assignment is gone")
        }

        // MARK: - The registry itself

        @Test("with the main window not captured yet (launch) the earliest live registration is used")
        func resolvesEarliestLiveStateBeforeMainWindowIsKnown() {
            let registry = EditorStateRegistry()
            let first = EditorViewState()
            let second = EditorViewState()
            registry.register(first, in: nil)
            registry.register(second, in: nil)
            #expect(registry.resolve(mainWindow: nil) === first)

            let window = makeTestWindow()
            registry.register(second, in: window)
            #expect(registry.resolve(mainWindow: window) === second, "registering again records the window it attached to")
            #expect(registry.resolve(mainWindow: makeTestWindow()) == nil, "a window nothing registered in resolves to nothing")
        }

        @Test("a registered state that is freed is dropped, never resolved")
        func freedStateIsDropped() {
            let registry = EditorStateRegistry()
            var only: EditorViewState? = EditorViewState()
            registry.register(only!, in: nil)
            #expect(registry.resolve(mainWindow: nil) === only)
            only = nil
            #expect(registry.resolve(mainWindow: nil) == nil)
        }
    }
}
