//
//  LifecycleBoundsTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C1: `LifecycleBounds` (slice-3a-1b-everyday.md §4.1). Pins the production
//  values the lifecycle sequence budgets against, the derived floors, and `scaled(_:)` (the knob the
//  later rounds' tests use to run the same sequence on a short clock).
//

import Foundation
import Testing
@testable import final_final

@Suite("LifecycleBounds (t-94369a83 3a-1b)", .serialized)
struct LifecycleBoundsTests {

    @Test("production values match the plan's section 4.1 table")
    func productionValues() {
        let b = LifecycleBounds.production
        #expect(b.closeTotal == 15)
        #expect(b.quitTotal == 18)
        #expect(b.sectionOperationWaitClose == 3)
        #expect(b.sectionOperationWaitQuit == 10)
        #expect(b.rebuildWait == 8)
        #expect(b.forcedPoll == 8)
        #expect(b.fetch == 2)
        #expect(b.fbRace == 2)
        #expect(b.bibliographyRefresh == 3)
        #expect(b.barrierFloor == 1)
        #expect(b.quitBackupReserve == 3)
        // Round C5a: the abort routine's own flat bound (FB still queued, and the block-id re-push), plan 4.3.
        #expect(b.abortStep == 2)
        // Round C6 (N3): a joined close/switch tail starts its automatic version only if this much remains.
        #expect(b.joinedBackupMinimum == 0.5)
        // t-eb07cd67: a command held behind a running close or open shows "Finishing the last change..." after one second.
        #expect(b.heldNoticeDelay == 1)
    }

    @Test("floors are the plan's 3 / 6 before FB and 1 / 4 after it (close-switch / quit)")
    func derivedFloors() {
        let b = LifecycleBounds.production
        #expect(b.floorBeforeFB(quit: false) == 3)
        #expect(b.floorBeforeFB(quit: true) == 6)
        #expect(b.floorAfterFB(quit: false) == 1)
        #expect(b.floorAfterFB(quit: true) == 4)
    }

    @Test("scaled(_:) multiplies every time value, so the derived floors scale with it")
    func scaledScalesEverything() {
        let b = LifecycleBounds.production.scaled(0.1)
        #expect(abs(b.closeTotal - 1.5) < 0.0001)
        #expect(abs(b.quitTotal - 1.8) < 0.0001)
        #expect(abs(b.sectionOperationWaitClose - 0.3) < 0.0001)
        #expect(abs(b.sectionOperationWaitQuit - 1.0) < 0.0001)
        #expect(abs(b.rebuildWait - 0.8) < 0.0001)
        #expect(abs(b.forcedPoll - 0.8) < 0.0001)
        #expect(abs(b.fetch - 0.2) < 0.0001)
        #expect(abs(b.fbRace - 0.2) < 0.0001)
        #expect(abs(b.bibliographyRefresh - 0.3) < 0.0001)
        #expect(abs(b.barrierFloor - 0.1) < 0.0001)
        #expect(abs(b.quitBackupReserve - 0.3) < 0.0001)
        #expect(abs(b.abortStep - 0.2) < 0.0001)
        #expect(abs(b.joinedBackupMinimum - 0.05) < 0.0001)
        #expect(abs(b.heldNoticeDelay - 0.1) < 0.0001)
        #expect(abs(b.floorBeforeFB(quit: true) - 0.6) < 0.0001)
        #expect(abs(b.floorAfterFB(quit: true) - 0.4) < 0.0001)
    }
}
