//
//  LifecycleTailEntryTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5b (slice-3a-1b-everyday.md sections 4.4 and 7.2 "C5b"): the tails run through
//  `LifecycleEntry.run` with the REAL host `installLifecycleHost()` installs, on a bare `ContentView` wired to a
//  temporary project database (`LifecycleTailRig`), so the whole path is exercised: the save sequence (FB through
//  the ordered queue), the barrier, `perform`, the tail, and the entry's own clean-up.
//
//    - #7: a completed close leaves an automatic-version ROW that contains what FB just wrote (the backup ran AFTER
//      the whole-document save), the writer is retired, the barrier is gone and the safety net had nothing to do
//    - N10: a system write parked behind the held barrier is released within the lifecycle deadline by the close
//      tail's retire, and the content-state watchdog does not loop: `systemWriteInFlight` is back to 0 and the
//      watchdog task is gone. (The proof is the plan's section 4.4: a parked write keeps `systemWriteInFlight > 0`,
//      which the watchdog waits on; retire skips it, so the loop ends, and the tail's reset cancels the task.)
//    - #12 / N31: an ABORTED switch (a `perform` that throws) never reaches the open tail, so the undo stacks stay
//    - the safety net: a tail that did not retire still gets its barrier released and the event is recorded; a
//      JOINED quit's barrier is never released by the lifecycle task's own end (N32)
//
//  Item 32: each test asserts the `.armed` entry event so a pass-through can never make one pass vacuously.
//

import Foundation
import Testing
@testable import final_final

private struct TailBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry tails through run — Tier 2 (t-94369a83 3a-1b C5b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleTailEntryTests {

        // MARK: - #7: the whole close

        @Test("""
            #7: a completed close leaves a snapshot ROW made AFTER FB (it contains the fresh text), retires the writer, \
            leaves no barrier and no token, and the safety net had nothing to release
            """)
        func completedCloseLeavesASnapshotRowWithTheFreshText() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var tokenInsidePerform: LifecycleToken?

            try await rig.withEntry {
                let outcome = try await LifecycleEntry.run(kind: .close) {
                    tokenInsidePerform = rig.editorState.activeLifecycle
                    return .close
                }
                #expect(outcome == .performed)
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "the tail retired the writer: nothing for the net")
            let rows = try rig.snapshotPreviews()
            #expect(try rig.snapshotCount() == before + 1)
            #expect(rows.last?.contains("fresh Y paragraph.") == true, "the version was made after FB, so it holds FB's text; got \(rows)")
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
            #expect(rig.writer?.ledger.barriersCancelled == 0)
            #expect(rig.writer?.enqueueBarrier() == nil, "the writer was retired")
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBackupDoneFor == tokenInsidePerform?.id)
            #expect(rig.editorState.content.isEmpty, "the close tail reset the editor state")
        }

        // MARK: - N10

        @Test("""
            N10: a system write parked behind the held barrier is released within the lifecycle deadline by the close \
            tail, systemWriteInFlight returns to 0 and the content-state watchdog is gone
            """)
        func parkedWriteIsReleasedAndTheWatchdogDoesNotLoop() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let clock = ContinuousClock()
            let started = clock.now
            var parked: Task<SystemWriteResult<Int>, Never>?
            var inFlightWhileParked = -1
            var watchdogArmedWhileParked = false
            var closeTotal: TimeInterval = 0

            try await rig.withEntry {
                _ = try await LifecycleEntry.run(kind: .close) {
                    closeTotal = LifecycleEntry.current?.deadline.remaining ?? 0
                    // The barrier is held now (the sequence left it so). A hierarchy-style system write parks above it
                    // while the content state is non-idle, which is what starts the 5s watchdog.
                    rig.editorState.contentState = .hierarchyEnforcement
                    parked = await rig.parkSystemWrite()
                    inFlightWhileParked = rig.editorState.systemWriteInFlight
                    watchdogArmedWhileParked = !rig.editorState.testContentStateWatchdogIsNil
                    return .close
                }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(inFlightWhileParked == 1, "precondition: the parked write keeps systemWriteInFlight above 0")
            #expect(watchdogArmedWhileParked, "precondition: the watchdog is waiting on it")
            let result = try #require(await parked?.value)
            guard case .refused(.skipped(let reason)) = result.outcome else {
                Issue.record("the parked write must be skipped by the retire, got \(result.outcome)")
                return
            }
            #expect(reason == .close)
            #expect(rig.editorState.systemWriteInFlight == 0, "the watchdog's loop condition is false again")
            #expect(rig.editorState.testContentStateWatchdogIsNil, "the tail's reset cancelled the watchdog: it cannot loop")
            #expect(rig.editorState.contentState == .idle)
            let elapsed = started.duration(to: clock.now)
            #expect(elapsed < .seconds(closeTotal), "released within the lifecycle deadline (\(closeTotal)s), took \(elapsed)")
            #expect(elapsed < .seconds(5), "and well before the watchdog's own 5s")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier))
        }

        // MARK: - #12: an abort never invalidates

        @Test("#12 / N31: an ABORTED switch (perform throws) never reaches the open tail: the undo stacks stay, no safety net")
        func abortedSwitchLeavesTheUndoStacks() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            rig.sync.testPushBlockIdsHook = { _ in }   // the abort re-pushes block ids after FB: no JavaScript here
            let undo = rig.view.unifiedUndoService
            let first = StructuralEntry(kind: .restoreSectionReplace, title: "First", undoSnapshotId: "snap-1")
            undo.record(first)
            rig.backup.contentDidChange()
            let before = try rig.snapshotCount()

            await rig.withEntry {
                await #expect(throws: TailBoom.self) {
                    try await LifecycleEntry.run(kind: .projectSwitch) { throw TailBoom() }
                }
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(undo.undoStack.map(\.id) == [first.id], "the project stays open: its undo history stays")
            #expect(try rig.snapshotCount() == before, "an abort makes no automatic version (no tail ran)")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier))
            #expect(rig.editorState.lifecycleBarrier == nil)
            let grant = rig.writer?.enqueueBarrier()
            #expect(grant != nil, "the writer was NOT retired: it still grants a barrier")
            grant?.release()
        }

        // MARK: - The safety net (N9, N32)

        @Test("""
            safety net: a tail that did NOT retire still gets its barrier released, and the event is recorded \
            (the recording tail double of LifecycleFlushHarness never retires)
            """)
        func safetyNetReleasesABarrierATailLeftHeld() async throws {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = LifecycleTailRig.fresh

            try await rig.withEntry {
                _ = try await LifecycleEntry.run(kind: .close) { .close }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(rig.log.contains("tail:close"))
            #expect(rig.entryEvents.contains(.safetyNetReleasedBarrier), "the net found the barrier still held and released it")
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil)
        }

        @Test("N32: a quit that joined DURING perform keeps its barrier: the task's end releases nothing and records nothing")
        func joinedQuitKeepsItsBarrierThroughACompletedTail() async throws {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = LifecycleTailRig.fresh
            var joinedKind: LifecycleKind?

            try await rig.withEntry {
                _ = try await LifecycleEntry.run(kind: .close) {
                    if case .joined(let token) = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) {
                        joinedKind = token.kind
                    }
                    return .close
                }
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(joinedKind == .quit)
            #expect(rig.editorState.lifecycleBarrier != nil, "the CURRENT token is a quit: its barrier is held to exit")
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq != nil)
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier))
            // Clean up what the quit would hold until exit.
            rig.editorState.lifecycleBarrier?.release()
            rig.editorState.lifecycleBarrier = nil
        }
    }
}
