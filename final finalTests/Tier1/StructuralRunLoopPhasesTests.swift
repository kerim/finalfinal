//
//  StructuralRunLoopPhasesTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2a, fix round 12, speed): the run-loop phase lines of the structural trace
//  (StructuralTraceRunLoop.swift). `wake-work` is the time from the run loop waking to its first BeforeWaiting observer, and
//  `ui-update` the time from that observer to the last one. Each is written only when it took MORE than 50 ms, and only while the
//  op's trace window is open. A fake clock drives the decisions; the real observers on the main run loop are not touched.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

private final class PhaseLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var clock = 1_000
    private var open = true
    private var closedCalls = 0
    func note(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var nowMs: Int { lock.lock(); defer { lock.unlock() }; return clock }
    func advance(_ milliseconds: Int) { lock.lock(); clock += milliseconds; lock.unlock() }
    var windowOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func closeWindow() { lock.lock(); open = false; lock.unlock() }
    func windowClosedCalled() { lock.lock(); closedCalls += 1; lock.unlock() }
    var windowClosedCount: Int { lock.lock(); defer { lock.unlock() }; return closedCalls }
}

@Suite("Run-loop phase trace lines — Phase 4b slice 2a fix round 12 (Tier 1)")
struct StructuralRunLoopPhasesTests {

    private func makePhases(_ log: PhaseLines) -> StructuralRunLoopPhases {
        StructuralRunLoopPhases(
            now: { log.nowMs }, windowIsOpen: { _ in log.windowOpen }, emit: { log.note($0) },
            onWindowClosed: { log.windowClosedCalled() })
    }

    @Test("A wake that kept the main thread busy for 120 ms, then 80 ms of UI update, write one wake-work and one ui-update line")
    func testSlowPhasesAreWritten() {
        let log = PhaseLines()
        let phases = makePhases(log)

        phases.afterWaiting()
        log.advance(120)
        phases.firstBeforeWaiting()
        log.advance(80)
        phases.lastBeforeWaiting()

        #expect(log.all == ["wake-work took=120ms", "ui-update took=80ms"], "\(log.all)")
    }

    @Test("Phases of 50 ms or less write nothing: only a phase that took MORE than 50 ms is reported")
    func testFastPhasesAreNotWritten() {
        let log = PhaseLines()
        let phases = makePhases(log)

        phases.afterWaiting()
        log.advance(50)
        phases.firstBeforeWaiting()
        log.advance(50)
        phases.lastBeforeWaiting()
        phases.afterWaiting()
        log.advance(3)
        phases.firstBeforeWaiting()
        log.advance(2)
        phases.lastBeforeWaiting()

        #expect(log.all.isEmpty, "\(log.all)")
    }

    @Test("A BeforeWaiting with no wake before it (the first pass) writes no wake-work, and a wake's time is counted once")
    func testWakeTimeIsCountedOnce() {
        let log = PhaseLines()
        let phases = makePhases(log)

        phases.firstBeforeWaiting()   // the loop's first pass has no AfterWaiting before it
        log.advance(10)
        phases.lastBeforeWaiting()
        phases.afterWaiting()
        log.advance(90)
        phases.firstBeforeWaiting()
        log.advance(10)
        phases.lastBeforeWaiting()
        // A second BeforeWaiting that follows with no wake in between must not count the old wake again.
        log.advance(500)
        phases.firstBeforeWaiting()
        log.advance(5)
        phases.lastBeforeWaiting()

        #expect(log.all == ["wake-work took=90ms"], "\(log.all)")
    }

    @Test("With the op's trace window closed nothing is written, and the observers are asked to go away")
    func testClosedWindowWritesNothingAndAsksToUninstall() {
        let log = PhaseLines()
        let phases = makePhases(log)
        log.closeWindow()

        phases.afterWaiting()
        log.advance(500)
        phases.firstBeforeWaiting()
        log.advance(500)
        phases.lastBeforeWaiting()

        #expect(log.all.isEmpty, "\(log.all)")
        #expect(log.windowClosedCount == 2, "both the wake and the first BeforeWaiting saw the closed window: \(log.windowClosedCount)")
    }
}
