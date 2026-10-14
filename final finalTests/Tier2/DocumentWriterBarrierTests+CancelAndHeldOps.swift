//
//  DocumentWriterBarrierTests+CancelAndHeldOps.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a, U1 (continued): the cancel paths (retire / skipAllReserved / skip(upTo:) before
//  reach, no loss counter), addendum P6 (retire on a REACHED, held barrier is a release, not a cancel) and the
//  held-op release racing the reach (coder items 1 and 35). Same suite as DocumentWriterBarrierTests.swift: an
//  extension, so it inherits `.serialized` / the time limit and shares that file's harness helpers.
//
//  FAIL-BEFORE: `DocumentWriter.enqueueBarrier()` is a stub returning nil, so every test here fails
//  BEHAVIOURALLY at its first `try #require(writer.enqueueBarrier())`.
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension DocumentWriterBarrierTests {

    // MARK: - Cancel (retire / skipAllReserved / skip) -- no loss counter

    /// Shared body for the three "cancelled before reach" triggers.
    private func assertCancelledBeforeReach(_ trigger: (DocumentWriter, BarrierHandle) -> Void) async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }

        _ = writer.reserve()                                    // seq 1: open -> the barrier cannot be reached
        let handle = try #require(writer.enqueueBarrier())     // seq 2
        defer { handle.release() }
        let waitTask = try await startPendingWait(handle)
        trigger(writer, handle)

        #expect(await waitTask.value == .cancelled)
        #expect(writer.ledger.barriersCancelled == 1)
        #expect(count(.barrierCancelled, in: recorder) == 1)
        // Review fix M1/M3: the drop is production-visible -- exactly one `.barrierDropped`, not reached.
        let drops = recorder.all.filter { if case .barrierDropped(_, false, _) = $0 { return true }; return false }
        #expect(drops.count == 1, "a skip that drops an unreached barrier emits one .barrierDropped(reached: false)")
        // No LOSS counter for the barrier itself: only the editor sequence the trigger skipped is counted.
        #expect(writer.ledger.skippedUnfetched == 1)
        #expect(writer.ledger.skippedConsumed == 0)
        #expect(writer.ledger.systemWritesSkipped == 0)
        #expect(writer.ledger.failedWrites == 0)
        #expect(writer.ledger.lifecycleWholeDocumentLost == 0)

        handle.release()                                        // no-op afterwards
        #expect(count(.barrierReleased, in: recorder) == 0)
        #expect(writer.ledger.barriersCancelled == 1)
    }

    @Test("retire() before reach resumes the wait .cancelled, counts barriersCancelled == 1, no loss counter; release() afterwards is a no-op")
    func retireBeforeReach_givesCancelled() async throws {
        try await assertCancelledBeforeReach { writer, _ in writer.retire(reason: .projectSwitch) }
    }

    @Test("skipAllReserved before reach resumes the wait .cancelled with no loss counter")
    func skipAllReservedBeforeReach_givesCancelled() async throws {
        try await assertCancelledBeforeReach { writer, _ in writer.skipAllReserved(reason: .editorReplaced) }
    }

    @Test("skip(upTo:) reaching the barrier resumes the wait .cancelled with no loss counter")
    func skipUpToReachingBarrier_givesCancelled() async throws {
        try await assertCancelledBeforeReach { writer, handle in _ = writer.skip(upTo: handle.seq, reason: .editorReplaced) }
    }

    @Test("skip(upTo:) BELOW the barrier that settles everything under it makes the barrier reached (not cancelled)")
    func skipUpToBelowBarrier_reachesIt() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60
        let ticket1 = writer.reserve()
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        let waitTask = try await startPendingWait(handle)
        writer.skip(upTo: ticket1.seq, reason: .drainTimeout)
        #expect(await waitTask.value == .reached)
        #expect(writer.ledger.barriersCancelled == 0)
    }

    // MARK: - Addendum P6: retire on a REACHED, held barrier

    private func assertRetireOnReachedBarrier(reason: SkipReason) async throws {
        let (_, _, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        let parked = parkedSignal(2)
        writer.testEventHandler = { recorder.append($0); parked.note($0) }

        let handle = try #require(writer.enqueueBarrier())     // seq 1
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)
        let above = writer.reserve()                            // seq 2, parked above the held barrier
        above.noteFetched()
        let turn = Task { await above.waitForTurn() }
        await parked.wait()

        writer.retire(reason: reason)

        #expect(await turn.value == .skipped, "retire skips the parked waiter above (it is NOT resumed 'proceed')")
        #expect(count(.barrierReleased, in: recorder) == 1, "a reached, held barrier dropped by retire is a RELEASE (P6)")
        #expect(count(.barrierDropped(handle.seq, reached: true, reason), in: recorder) == 1,
                "review fix M1/M3: the drop is production-visible, with its reason and 'reached'")
        #expect(writer.ledger.barriersCancelled == 0, "never a cancel: no wait was pending")
        #expect(count(.barrierCancelled, in: recorder) == 0)

        handle.release()                                        // a no-op once retired
        #expect(count(.barrierReleased, in: recorder) == 1)
        #expect(writer.ledger.barriersCancelled == 0)
        #expect(writer.enqueueBarrier() == nil, "a retired writer grants no barrier")
    }

    @Test("""
        retire(.projectSwitch) on a reached, held barrier emits .barrierReleased once with barriersCancelled == 0; release() \
        afterwards is a no-op
        """)
    func retireProjectSwitchOnReachedBarrier_isReleaseNotCancel() async throws {
        try await assertRetireOnReachedBarrier(reason: .projectSwitch)
    }

    @Test("retire(.close) on a reached, held barrier emits .barrierReleased once with barriersCancelled == 0; release() afterwards is a no-op")
    func retireCloseOnReachedBarrier_isReleaseNotCancel() async throws {
        try await assertRetireOnReachedBarrier(reason: .close)
    }

    // MARK: - A drain drops a held barrier (review finding M1: today's behaviour, pinned)

    @Test("""
        TODAY'S BEHAVIOUR, pinned (review finding M1): a reached, HELD barrier with an .abandoned entry below it is DROPPED by \
        drainForLifecycle's done-path skip -- the drain returns .drained, the holder is not told, release() afterwards is a \
        no-op, a sequence reserved next is no longer parked -- and the drop is production-visible as \
        .barrierDropped(reached: true, .lifecycleDrain)
        """)
    func drainDropsHeldBarrier_whenAbandonedEntryBelow_dropEventFires() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 0.05
        writer.testLateAbandonAfterSeconds = 0.4
        let recorder = WriterEventRecorder()
        let expired1 = expiredSignal(1)
        let abandoned1 = abandonedSignal(1)
        let reached = reachedSignal()
        writer.testEventHandler = { recorder.append($0); expired1.note($0); abandoned1.note($0); reached.note($0) }

        _ = writer.reserve()                                    // seq 1: never fetched -> late -> abandoned
        let keepAlive = writer.reserve()                        // seq 2: its parked waiter arms seq 1's expiry
        let handle = try #require(writer.enqueueBarrier())     // seq 3
        defer { handle.release() }
        Task { _ = await keepAlive.waitForTurn() }
        await expired1.wait()                                   // seq 1 is a passable .late entry now
        keepAlive.settleIfOpen(.empty)
        await reached.wait()                                    // reached WITH the .late entry (not abandoned yet) below
        await abandoned1.wait()                                 // now an .abandoned entry sits below a held barrier
        #expect(writer.testFrontier == handle.seq, "the barrier is reached and held")

        let outcome = await writer.drainForLifecycle(timeout: 2)

        #expect(outcome == .drained)
        #expect(recorder.all.contains(.barrierDropped(handle.seq, reached: true, .lifecycleDrain)),
                "the drain's skip dropped the held barrier and said so")
        #expect(recorder.all.contains(.skipped([1], .lifecycleDrain)), "only the abandoned entry is a counted skip")
        #expect(count(.barrierReleased, in: recorder) == 1, "a dropped barrier with no pending wait settles as released")
        #expect(writer.ledger.barriersCancelled == 0)
        #expect(writer.ledger.skippedUnfetched == 1)
        #expect(writer.testFrontier == handle.seq + 1, "the frontier jumped past the dropped barrier")

        handle.release()                                        // a no-op: the barrier is already gone
        #expect(count(.barrierReleased, in: recorder) == 1)
        let after = writer.reserve()
        after.noteFetched()
        #expect(await after.waitForTurn() == .go, "nothing is held back any more")
        after.settleIfOpen(.empty)
    }

    // MARK: - Held-op release vs reach (coder items 1 and 35, row 2)

    /// Phase 1 of the held-op scenario, in which the barrier's only remaining obstacle will be
    /// `releaseScheduled`: seq 1 goes late then ABANDONED (so an update on an unresolved temp id CAN be
    /// held, because `mintPossible` stays true, while `holdingActive` is false), seq 2 is a keep-alive
    /// that is then settled, seq 3 is the fetched HOLDER of the future held op, seq 4 is the barrier
    /// and seq 5 a fetched sequence above it. Returns with the frontier AT seq 3 (the holder), the
    /// barrier not yet reached (seq 3 is still open below it).
    private func prepareHeldOpScenario(
        _ writer: DocumentWriter, recorder: WriterEventRecorder
    ) async throws -> (handle: BarrierHandle, above: WriterTicket) {
        writer.testLateAfterSeconds = 0.03
        writer.testLateAbandonAfterSeconds = 0.08
        let abandoned1 = abandonedSignal(1)
        writer.testEventHandler = { event in
            recorder.append(event)
            abandoned1.note(event)
        }

        _ = writer.reserve()                                    // seq 1: never fetched -> late -> abandoned
        let keepAlive = writer.reserve()                        // seq 2: its parked waiter arms seq 1's expiry
        Task { _ = await keepAlive.waitForTurn() }
        let holder = writer.reserve()                           // seq 3: the holder of the held op
        holder.noteFetched()
        let handle = try #require(writer.enqueueBarrier())     // seq 4
        let above = writer.reserve()                            // seq 5, above the barrier
        above.noteFetched()

        await abandoned1.wait()
        keepAlive.settleIfOpen(.empty)
        return (handle, above)
    }

    /// Phase 2: apply the holder (seq 3). Its update names an unresolved temp id while seq 1 is merely
    /// abandoned (`mintPossible`), so the op is HELD; the apply's tail schedules `releaseDueHolds`
    /// (`holdingActive` is false) and leaves the frontier at the barrier with `releaseScheduled` set.
    private func applyHeldOpHolder(_ writer: DocumentWriter, db: ProjectDatabase, pid: String) async throws {
        let applied = await writer.applyEditorBatch(3, BlockChanges(updates: [
            BlockUpdate(id: "temp-held-op", textContent: "held", markdownFragment: nil, headingLevel: nil)
        ]), stamp: try stamp(db, pid, 3))
        guard case .applied = applied else {
            Issue.record("the holder sequence must apply and hold its op, got \(applied)")
            return
        }
    }

    @Test("""
        Reach is evaluated by releaseDueHolds clearing releaseScheduled ALONE (coder item 1): everything below is settled or \
        abandoned, the only remaining obstacle is the scheduled held-op release, and the barrier still becomes reached \
        (no spurious timeout), skipping the abandoned entry with .lifecycleDrain
        """)
    func reachEvaluatedByReleaseDueHoldsAlone() async throws {
        let (db, pid, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        let (handle, _) = try await prepareHeldOpScenario(writer, recorder: recorder)
        defer { handle.release() }
        let waitTask = try await startPendingWait(handle, timeout: 2)
        #expect(writer.ledger.barriersReached == 0, "the holder (seq 3) is still open below the barrier")

        try await applyHeldOpHolder(writer, db: db, pid: pid)

        #expect(await waitTask.value == .reached,
                "the scheduled release job clearing releaseScheduled must trigger the reach evaluation")
        #expect(writer.ledger.barriersTimedOut == 0)
        #expect(writer.ledger.barriersReached == 1)
        #expect(writer.testFrontier == handle.seq)
        #expect(
            recorder.all.contains { event in
                if case .skipped(let seqs, .lifecycleDrain) = event { return seqs.contains(1) }
                return false
            },
            "on reach the abandoned entry below is skipped with .lifecycleDrain"
        )
        handle.release()
    }

    @Test("""
        A held-op release racing the reach (coder item 35, row 2): releasing the barrier immediately after the held op is \
        created, in every interleaving, gives exactly one terminal outcome, never double-resumes, and always lets the \
        sequence parked above resume (12 iterations)
        """)
    func heldOpReleaseRacingReach_oneOutcome_aboveAlwaysResumes() async throws {
        let (db, pid, _) = try makeBarrierStack()
        for iteration in 0..<12 {
            let writer = DocumentWriter(database: db, projectId: pid)
            let recorder = WriterEventRecorder()
            let (handle, above) = try await prepareHeldOpScenario(writer, recorder: recorder)
            defer { handle.release() }
            let waitTask = try await startPendingWait(handle)   // the wait is PENDING before the race starts
            let aboveTurn = Task { await above.waitForTurn() }

            try await applyHeldOpHolder(writer, db: db, pid: pid)
            handle.release()                                    // races the scheduled releaseDueHolds / reach

            let outcome = await waitTask.value
            switch outcome {
            case .reached, .cancelled:
                break
            case .timedOut:
                Issue.record("iteration \(iteration): a release must never leave the wait to time out")
            }
            #expect(await aboveTurn.value == .go, "iteration \(iteration): the sequence above must resume after release")
            let ledger = writer.ledger
            #expect(ledger.barriersReached + ledger.barriersCancelled == 1,
                    "iteration \(iteration): exactly one terminal outcome (reached \(ledger.barriersReached), cancelled \(ledger.barriersCancelled))")
            #expect(ledger.barriersTimedOut == 0, "iteration \(iteration)")
        }
    }
}
