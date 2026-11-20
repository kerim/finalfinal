//
//  FullScreenManagerUnitHostTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Board t-95fa4f7f. Every full unit-test run used to switch the user's Mac to another desktop: about fifty Focus
//  Mode tests call enterFocusMode() / exitFocusMode(), which call FullScreenManager.request(.fullScreen / .windowed),
//  and FullScreenManager.apply(_:window:) really called window.toggleFullScreen(nil) on the unit-test host's real
//  main window (AppDelegate.shared is set in the host, and its mainWindow is that real window).
//
//  The rule pinned here: under unit tests FullScreenManager records every request in its model but never toggles a
//  real window. The test stands a real window in as AppDelegate's main window (the same wiring captureMainWindow does,
//  without making AppDelegate the window's delegate) and asks the manager for full screen. It then does the same on a
//  fresh second window, settled in full screen in the model, and asks for windowed. After each request it watches the
//  window itself, for a bounded time, for the native full-screen mask. Without the rule the window really enters
//  native full screen and the expectation fails, with a message that names the half that failed.
//

import AppKit
import Testing
@testable import final_final

@MainActor
@Suite("FullScreenManager never toggles a real window under unit tests", .serialized, .timeLimit(.minutes(1)))
struct FullScreenManagerUnitHostTests {

    @Test("request(.fullScreen) and request(.windowed) leave a real main window windowed")
    func requestNeverTogglesRealWindowUnderUnitTests() async throws {
        let delegate = try #require(AppDelegate.shared, "the unit-test host has an AppDelegate")
        let original = delegate.mainWindow
        let firstWindow = makeTestWindow()
        var secondWindow: NSWindow?
        defer {
            FullScreenManager.resetForTesting()
            delegate.mainWindow = original
            firstWindow.close()
            secondWindow?.close()
        }
        #expect(firstWindow.isVisible, "the test window must be on screen, or a pass proves nothing")

        // The app's own wiring: captureMainWindow sets mainWindow, then bootstraps FullScreenManager. The window is
        // deliberately not given AppDelegate as its delegate, so nothing here activates the app.
        delegate.mainWindow = firstWindow
        FullScreenManager.resetForTesting()
        FullScreenManager.bootstrap(window: firstWindow)

        // First half: .fullScreen from a windowed window reaches the toggle.
        FullScreenManager.request(.fullScreen)
        #expect(FullScreenManager.isEffectivelyFullScreen(), "the model still records the full-screen request")
        try await waitUpTo(seconds: 2.5) { firstWindow.styleMask.contains(.fullScreen) }
        #expect(
            !firstWindow.styleMask.contains(.fullScreen),
            "FullScreenManager put a real window into native full screen during a unit test (request .fullScreen)")

        // Second half, on its own fresh and really windowed window: .windowed only reaches the toggle when the model
        // believes the window is settled in full screen. Reset the model, bootstrap on the new window, and deliver the
        // did-enter notification the way AppKit would: the manager's own observer receives it and moves the model to
        // settled full screen. Then request(.windowed) really asks for a toggle.
        FullScreenManager.resetForTesting()
        let second = makeTestWindow()
        secondWindow = second
        #expect(second.isVisible, "the second test window must be on screen, or a pass proves nothing")
        delegate.mainWindow = second
        FullScreenManager.bootstrap(window: second)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: second)
        #expect(
            FullScreenManager.isSettledFullScreen(),
            "precondition: the model is settled in full screen, so .windowed reaches the toggle")
        FullScreenManager.request(.windowed)
        #expect(!FullScreenManager.isEffectivelyFullScreen(), "the model still records the windowed request")
        try await waitUpTo(seconds: 2.5) { second.styleMask.contains(.fullScreen) }
        #expect(
            !second.styleMask.contains(.fullScreen),
            "FullScreenManager put a real window into native full screen during a unit test (request .windowed)")
    }

    /// A real, on-screen, really windowed window that can enter native full screen. Alpha 0 and ignoring the mouse so a
    /// unit run never shows a window to the user (AppKit still counts it as on screen, which `isVisible` confirms).
    private func makeTestWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        return window
    }

    /// Polls `condition` every 100 ms for at most `seconds`; returns as soon as it holds, and just as quietly when it
    /// never does. It never fails by itself: the caller's expectation decides.
    private func waitUpTo(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
