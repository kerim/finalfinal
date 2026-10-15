//
//  StructuralTraceRunLoop.swift
//  final final
//
//  Phase 4b slice 2a, fix round 12 (speed): MEASUREMENT ONLY. Says where a long main-thread stall of a structural op sat, in the
//  phases of the main run loop, so it can be told apart from the work of the app's own code. Two lines of the timeline family
//  (StructuralTrace.swift), each written only when the phase took more than 50 ms and only while an op's trace window is open:
//
//    [STRUCT-TRACE] t=<ms>ms +timeline=<ms>ms <label> op=<id> wake-work took=<n>ms
//        From the run loop waking up (AfterWaiting) to the moment it was about to go back to sleep (the first BeforeWaiting
//        observer): everything the loop ran in between, timers, sources and the main dispatch queue's blocks (including a
//        web view's replies and an accessibility request served by this process). `t=` is the end of the phase.
//    [STRUCT-TRACE] t=<ms>ms +timeline=<ms>ms <label> op=<id> ui-update took=<n>ms
//        From the first BeforeWaiting observer to the last one: what the loop does just before it sleeps, which includes the
//        SwiftUI and Core Animation update and commit.
//
//  The observers are added to the main run loop by `StructuralTrace.beginOp` (only while tracing is on) and take themselves off
//  again once the op's window (30 s, `StructuralTrace.timelineWindowMs`) has closed, so with tracing off, or long after an op,
//  nothing is installed and the run loop pays nothing.
//

import CoreFoundation
import Foundation
import os

/// What to write for each run-loop phase. The clock, the window check and the line sink are injected, so the unit tests drive it with
/// a fake clock; `StructuralRunLoopTracer` wires it to the main run loop.
final class StructuralRunLoopPhases: @unchecked Sendable {

    /// A phase is written only when it took MORE than this many milliseconds.
    static let thresholdMs = 50

    private struct Marks {
        var wakeMs: Int?
        var beforeWaitingMs: Int?
    }

    private let marks = OSAllocatedUnfairLock(initialState: Marks())
    private let now: () -> Int
    private let windowIsOpen: (Int) -> Bool
    private let emit: (String) -> Void
    private let onWindowClosed: () -> Void

    init(
        now: @escaping () -> Int,
        windowIsOpen: @escaping (Int) -> Bool,
        emit: @escaping (String) -> Void,
        onWindowClosed: @escaping () -> Void
    ) {
        self.now = now
        self.windowIsOpen = windowIsOpen
        self.emit = emit
        self.onWindowClosed = onWindowClosed
    }

    /// The run loop woke up (observer order `Int.min`: first of the AfterWaiting observers).
    func afterWaiting() {
        let nowMs = now()
        guard windowIsOpen(nowMs) else {
            marks.withLock { $0 = Marks() }
            onWindowClosed()
            return
        }
        marks.withLock { $0.wakeMs = nowMs }
    }

    /// The run loop is about to run its BeforeWaiting observers (order `Int.min`: the first of them). Writes `wake-work`.
    func firstBeforeWaiting() {
        let nowMs = now()
        guard windowIsOpen(nowMs) else {
            marks.withLock { $0 = Marks() }
            onWindowClosed()
            return
        }
        let wakeMs = marks.withLock { marks -> Int? in
            let wake = marks.wakeMs
            marks.wakeMs = nil
            marks.beforeWaitingMs = nowMs
            return wake
        }
        if let wakeMs, nowMs - wakeMs > Self.thresholdMs { emit("wake-work took=\(nowMs - wakeMs)ms") }
    }

    /// The run loop has run all its BeforeWaiting observers (order `Int.max`: the last of them). Writes `ui-update`.
    func lastBeforeWaiting() {
        let nowMs = now()
        let beganMs = marks.withLock { marks -> Int? in
            let began = marks.beforeWaitingMs
            marks.beforeWaitingMs = nil
            return began
        }
        if let beganMs, nowMs - beganMs > Self.thresholdMs { emit("ui-update took=\(nowMs - beganMs)ms") }
    }
}

/// The main run loop's three observers. Everything here is a no-op until `StructuralTrace.beginOp` installs them (tracing on).
enum StructuralRunLoopTracer {

    private final class Installation: @unchecked Sendable {
        let lock = NSLock()
        var observers: [CFRunLoopObserver] = []
    }

    private static let installation = Installation()

    static let phases = StructuralRunLoopPhases(
        now: { StructuralTrace.nowMs() },
        windowIsOpen: { nowMs in windowIsOpen(nowMs: nowMs) },
        emit: { line in StructuralTrace.log(line) },
        onWindowClosed: {
            // Asked again on the main queue, because a new op may have begun (and found the observers still installed) in between.
            DispatchQueue.main.async {
                if !windowIsOpen(nowMs: StructuralTrace.nowMs()) { uninstall() }
            }
        }
    )

    /// Whether the most recent op's trace window is open at `nowMs` (tracing on, an op began, and not more than 30 s ago).
    static func windowIsOpen(nowMs: Int) -> Bool {
        guard StructuralTrace.isOn, let start = StructuralTrace.shared.startMs else { return false }
        return StructuralTrace.stallWindowIsOpen(nowMs: nowMs, opStartMs: start, windowMs: StructuralTrace.timelineWindowMs)
    }

    /// Adds the observers to the main run loop if they are not there yet. Safe from any thread.
    static func installIfNeeded() {
        installation.lock.lock()
        defer { installation.lock.unlock() }
        guard installation.observers.isEmpty, let mainLoop = CFRunLoopGetMain() else { return }
        func add(_ activity: CFRunLoopActivity, order: Int, _ handler: @escaping () -> Void) {
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, activity.rawValue, true, order, { _, _ in handler() }) else { return }
            CFRunLoopAddObserver(mainLoop, observer, .commonModes)
            installation.observers.append(observer)
        }
        add(.afterWaiting, order: Int.min) { phases.afterWaiting() }
        add(.beforeWaiting, order: Int.min) { phases.firstBeforeWaiting() }
        add(.beforeWaiting, order: Int.max) { phases.lastBeforeWaiting() }
    }

    /// Takes the observers off the main run loop.
    static func uninstall() {
        installation.lock.lock()
        defer { installation.lock.unlock() }
        guard let mainLoop = CFRunLoopGetMain() else { return }
        for observer in installation.observers { CFRunLoopRemoveObserver(mainLoop, observer, .commonModes) }
        installation.observers.removeAll()
    }
}
