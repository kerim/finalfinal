//
//  DocumentWriterBarrierTests+TimeoutAndHold.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a, U1 (continued): hold bookkeeping (since reset, awaitSettled/drain ignore the
//  barrier entry, I-BAR, the hold warning) and the barrier TIMEOUT (editor sequences only, stale timer
//  no-op, timeout racing reach / retire). Same suite as DocumentWriterBarrierTests.swift: an extension, so it
//  inherits `.serialized` / the time limit and shares that file's harness helpers.
//
//  FAIL-BEFORE: `DocumentWriter.enqueueBarrier()` is a stub returning nil, so every test here fails
//  BEHAVIOURALLY at its first `try #require(writer.enqueueBarrier())`.
//

import Foundation
import GRDB
import Testing
@testable import final_final

extension DocumentWriterBarrierTests {

    // MARK: - Hold bookkeeping

    @Test("""
        Release resets `since` on parked sequences, and none goes late within the hold window: a sequence held behind a \
        barrier for longer than the turn-stall bound is NOT instantly expired when the barrier is released
        """)
    func releaseResetsSince_noParkedSeqGoesLateWhileHeld() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let lateAfter: TimeInterval = 0.5
        writer.testLateAfterSeconds = lateAfter
        let recorder = WriterEventRecorder()
        let expired2 = expiredSignal(2)
        writer.testEventHandler = { recorder.append($0); expired2.note($0) }

        let handle = try #require(writer.enqueueBarrier())     // seq 1
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)
        _ = writer.reserve()                                    // seq 2: reserved NOW, never fetched
        let ticket3 = writer.reserve()                          // seq 3: its parked waiter lets seq 2's expiry arm later
        ticket3.noteFetched()
        Task { _ = await ticket3.waitForTurn() }

        // Hold the barrier for LONGER than the turn-stall bound.
        try await Task.sleep(for: .milliseconds(700))
        #expect(!recorder.all.contains { if case .expired = $0 { return true }; return false },
                "nothing parked behind a held barrier may go late during the hold")

        let clock = ContinuousClock()
        let releasedAt = clock.now
        handle.release()
        await expired2.wait()
        let elapsed = clock.now - releasedAt
        // With `since` reset at release, seq 2 expires a full `lateAfter` AFTER the release. Without the
        // reset its original `since` is already 0.7s old and it would expire at once (elapsed ~ 0).
        #expect(elapsed >= .milliseconds(450), "since must be reset on release (elapsed \(elapsed))")
    }

    @Test("awaitSettled and drainForLifecycle ignore the barrier entry (like .abandoned): both return promptly while it is held")
    func awaitSettledAndDrain_ignoreBarrierEntry() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let ticket1 = writer.reserve()
        ticket1.settleIfOpen(.empty)
        let handle = try #require(writer.enqueueBarrier())     // seq 2, reached and held
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)

        let clock = ContinuousClock()
        let start = clock.now
        let settled = await writer.awaitSettled(through: handle.seq, timeout: 1.5)
        let drained = await writer.drainForLifecycle(timeout: 1.5)
        let elapsed = clock.now - start
        #expect(settled == .settled)
        #expect(drained == .drained)
        #expect(elapsed < .seconds(1), "neither wait may block on the held barrier entry (took \(elapsed))")
        #expect(writer.testFrontier == handle.seq, "and neither may move or cancel the barrier")
        #expect(writer.ledger.barriersCancelled == 0)
    }

    @Test("While a barrier is held nothing above it can apply (I-BAR): an out-of-turn apply is refused, and succeeds after release")
    func heldBarrier_blocksApplyAbove_iBar() async throws {
        let (db, pid, writer) = try makeBarrierStack()
        let handle = try #require(writer.enqueueBarrier())     // seq 1
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)
        let ticket2 = writer.reserve()                          // seq 2, above the held barrier
        ticket2.noteFetched()
        #expect(writer.enqueueBarrier() == nil, "at most one open barrier")

        let refused = await writer.applyEditorBatch(2, BlockChanges(), stamp: try stamp(db, pid, 2))
        guard case .refused(.outOfTurn) = refused else {
            Issue.record("expected .refused(.outOfTurn) above a held barrier, got \(refused)")
            return
        }

        handle.release()
        let applied = await writer.applyEditorBatch(2, BlockChanges(), stamp: try stamp(db, pid, 2))
        guard case .applied = applied else {
            Issue.record("expected the sequence above to apply after release, got \(applied)")
            return
        }
    }

    @Test("The hold warning fires through the test seam (testBarrierHoldWarnAfterSeconds) while a barrier is held, and stops after a release")
    func holdWarning_firesThroughTestSeam() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testBarrierHoldWarnAfterSeconds = 0.1
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)

        var waited = 0
        while writer.testBarrierHoldWarnCount == 0, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(writer.testBarrierHoldWarnCount >= 1, "a barrier held past the (overridden) bound must warn")
        handle.release()
        let countAtRelease = writer.testBarrierHoldWarnCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(writer.testBarrierHoldWarnCount == countAtRelease, "a released barrier must stop warning")

        // And a barrier released BEFORE the bound never warns.
        writer.testBarrierHoldWarnAfterSeconds = 0.3
        let quick = try #require(writer.enqueueBarrier())
        defer { quick.release() }
        #expect(await quick.wait(timeout: 2) == .reached)
        quick.release()
        try await Task.sleep(for: .milliseconds(500))
        #expect(writer.testBarrierHoldWarnCount == countAtRelease)
    }

    // MARK: - Timeout

    @Test("""
        A timeout on an unfetched sequence gives .timedOut: the EDITOR sequences below are skipped (and listed, with the \
        fetched ones counted), counted barriersTimedOut, and the barrier itself is never counted as a skipped/consumed loss
        """)
    func timeoutOnUnfetchedSeq_givesTimedOut() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }
        _ = writer.reserve()                                    // seq 1: unfetched
        let ticket2 = writer.reserve()                          // seq 2: fetched, never applied
        ticket2.noteFetched()
        let handle = try #require(writer.enqueueBarrier())     // seq 3
        defer { handle.release() }

        let outcome = await handle.wait(timeout: 0.2)
        #expect(outcome == .timedOut(skippedEditorSeqs: [1, 2], skippedFetched: 1))
        #expect(writer.ledger.barriersTimedOut == 1)
        #expect(count(.barrierTimedOut, in: recorder) == 1)
        #expect(writer.ledger.skippedUnfetched == 1)
        #expect(writer.ledger.skippedConsumed == 1, "the fetched editor batch is a counted loss; the barrier is not")
        #expect(writer.ledger.barriersCancelled == 0)
        handle.release()
    }

    @Test("""
        The timeout skips EDITOR sequences only (coder item 4): a parked system sequence below completes, the frontier is \
        never moved past it, and the I-HOLD accounting of a held op dropped by the timeout balances
        """)
    func timeoutSkipsEditorSeqsOnly_systemSeqBelowCompletes_iHoldBalances() async throws {
        let (db, pid, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 0.05
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }
        let identity = SystemWriteIdentity(projectId: pid, database: db)

        // Part 1: editor seq 1 (unfetched) below a pending SYSTEM seq 2 below the barrier (seq 3).
        let ticket1 = writer.reserve()
        let systemTicket = writer.reserveSystem()
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        #expect(systemTicket.seq == 2 && handle.seq == 3)
        let outcome = await handle.wait(timeout: 0.2)
        #expect(outcome == .timedOut(skippedEditorSeqs: [ticket1.seq], skippedFetched: 0),
                "only the editor sequence is skipped; the system sequence is left to finish")
        #expect(writer.testFrontier == systemTicket.seq,
                "skipEditorSequences must never move the frontier past a pending system sequence")
        #expect(writer.ledger.systemWritesSkipped == 0)
        #expect(writer.systemSkipReason(systemTicket.seq) == nil)
        let systemOutcome = await writer.applySystemWrite(
            systemTicket.seq, kind: .headingLevels, identity: identity
        ) { _ in SystemWriteBody(value: 7) }
        guard case .applied(let value) = systemOutcome else {
            Issue.record("the parked system sequence below must still complete after the timeout, got \(systemOutcome)")
            return
        }
        #expect(value == 7)
        handle.release()

        // Part 2: a held op whose HOLDER is a sequence below a timing-out barrier is dropped and
        // counted, and I-HOLD (total == resolved + unresolved + dropped + superseded + held) holds.
        let writer2 = DocumentWriter(database: db, projectId: pid)
        writer2.testLateAfterSeconds = 0.05
        let recorder2 = WriterEventRecorder()
        writer2.testEventHandler = { recorder2.append($0) }
        _ = writer2.reserve()                                   // seq 1: never fetched, goes late
        let ticket2 = writer2.reserve()                         // seq 2: the holder
        let blocker = writer2.reserve()                         // seq 3: stays unfetched -> keeps the barrier unreached
        let handle2 = try #require(writer2.enqueueBarrier())   // seq 4
        defer { handle2.release() }
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer2.applyEditorBatch(2, BlockChanges(updates: [
                BlockUpdate(id: "temp-barrier-held", textContent: "held edit", markdownFragment: nil, headingLevel: nil)
            ]), stamp: stamp2)
        }
        let holderResult = await cycle2.value
        guard case .applied = holderResult else {
            Issue.record("the holder sequence must apply (and hold its op) once seq 1 goes late, got \(holderResult)")
            return
        }
        #expect(writer2.testHeldCount == 1)
        let outcome2 = await handle2.wait(timeout: 0.3)
        #expect(outcome2 == .timedOut(skippedEditorSeqs: [1, blocker.seq], skippedFetched: 0))
        // Whether the timeout's skip drops this op or leaves it held is the implementation's call
        // (plan item 4 only requires it to ACCOUNT for any op it drops); what must hold either way is
        // that the op never vanishes untracked: I-HOLD balances (heldOpsInFlight is 0 here).
        let ledger = writer2.ledger
        #expect(ledger.heldOpsTotal == 1)
        #expect(ledger.heldOpsTotal ==
                ledger.heldOpsResolved + ledger.heldOpsUnresolved + ledger.heldOpsDropped
                + ledger.heldOpsSuperseded + writer2.testHeldCount,
                "I-HOLD must balance after the timeout")
        handle2.release()
    }

    @Test("""
        A stale timeout timer is a no-op (coder item 4, review fix M15): a barrier whose 0.25s wait was registered and then \
        REACHED before the bound is never timed out afterwards -- the reach takes the continuation and bumps the wait \
        token, so the timer (still pending, or cancelled and waking at once) finds it no longer owns the wait
        """)
    func staleTimeoutTimer_isNoOp() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }

        let editor = writer.reserve()                           // seq 1: open -> the barrier cannot be reached yet
        let handle = try #require(writer.enqueueBarrier())     // seq 2
        defer { handle.release() }
        let waitTask = try await startPendingWait(handle, timeout: 0.25)   // registered before this returns

        editor.settleIfOpen(.empty)                             // reach: takes the wait and bumps the token
        #expect(await waitTask.value == .reached)

        // Outlive the 0.25s timer, which the reach has superseded.
        try await Task.sleep(for: .milliseconds(500))
        #expect(count(.barrierTimedOut, in: recorder) == 0, "the stale timer must not time out a reached barrier")
        #expect(writer.ledger.barriersTimedOut == 0)
        #expect(!recorder.all.contains { if case .skipped = $0 { return true }; return false }, "and must not skip anything")
        #expect(writer.ledger.skippedUnfetched == 0)
        #expect(writer.ledger.skippedConsumed == 0)
        #expect(writer.ledger.barriersReached == 1)
        #expect(writer.testFrontier == handle.seq, "the barrier is still reached and held")
    }

    @Test("Timeout racing reach gives exactly one outcome and one event, never both (100 iterations)")
    func timeoutRacingReach_exactlyOneOutcome() async throws {
        let (db, pid, _) = try makeBarrierStack()
        var reachedCount = 0
        var timedOutCount = 0
        for iteration in 0..<100 {
            let writer = DocumentWriter(database: db, projectId: pid)
            let recorder = WriterEventRecorder()
            writer.testEventHandler = { recorder.append($0) }
            let ticket = writer.reserve()
            let handle = try #require(writer.enqueueBarrier())
            defer { handle.release() }
            let jitter = 1 + iteration % 3
            let waiter = Task { await handle.wait(timeout: 0.002 * Double(jitter)) }
            let settler = Task {
                try? await Task.sleep(for: .milliseconds(1 + jitter))
                ticket.settleIfOpen(.empty)
            }
            let outcome = await waiter.value
            await settler.value

            switch outcome {
            case .reached:
                reachedCount += 1
                #expect(count(.barrierTimedOut, in: recorder) == 0, "iteration \(iteration)")
                #expect(writer.ledger.barriersTimedOut == 0, "iteration \(iteration)")
            case .timedOut:
                timedOutCount += 1
                #expect(count(.barrierTimedOut, in: recorder) == 1, "iteration \(iteration)")
                #expect(writer.ledger.barriersTimedOut == 1, "iteration \(iteration)")
            case .cancelled:
                Issue.record("iteration \(iteration): nothing cancelled this barrier, got .cancelled")
            }
            #expect(count(.barrierCancelled, in: recorder) == 0, "iteration \(iteration)")
            #expect(writer.ledger.barriersCancelled == 0, "iteration \(iteration)")
            handle.release()
        }
        #expect(reachedCount + timedOutCount == 100)
    }

    @Test("retire racing a timeout gives exactly one outcome and one event, never both (100 iterations)")
    func retireRacingTimeout_exactlyOneOutcome() async throws {
        let (db, pid, _) = try makeBarrierStack()
        for iteration in 0..<100 {
            let writer = DocumentWriter(database: db, projectId: pid)
            let recorder = WriterEventRecorder()
            writer.testEventHandler = { recorder.append($0) }
            _ = writer.reserve()                                // never settled: the barrier can only time out or be cancelled
            let handle = try #require(writer.enqueueBarrier())
            defer { handle.release() }
            let jitter = 1 + iteration % 3
            // Review fix M14: the wait must REGISTER before the race starts -- a retire that ran first would
            // drop a barrier with no pending wait (so no `.cancelled` outcome and `barriersCancelled == 0`),
            // an interleaving this test's `.cancelled` branch must not be asked about.
            let registeredBefore = writer.testBarrierWaitsRegistered
            let waiter = Task { await handle.wait(timeout: 0.002 * Double(jitter)) }
            try await waitForBarrierWaitRegistration(writer, after: registeredBefore)
            let retirer = Task {
                try? await Task.sleep(for: .milliseconds(1 + jitter))
                writer.retire(reason: .projectSwitch)
            }
            let outcome = await waiter.value
            await retirer.value

            switch outcome {
            case .cancelled:
                #expect(writer.ledger.barriersCancelled == 1, "iteration \(iteration)")
                #expect(writer.ledger.barriersTimedOut == 0, "iteration \(iteration)")
                #expect(count(.barrierCancelled, in: recorder) == 1, "iteration \(iteration)")
                #expect(count(.barrierTimedOut, in: recorder) == 0, "iteration \(iteration)")
            case .timedOut:
                #expect(writer.ledger.barriersTimedOut == 1, "iteration \(iteration)")
                #expect(writer.ledger.barriersCancelled == 0,
                        "iteration \(iteration): a retire after the timeout took the wait must not count a cancel")
                #expect(count(.barrierTimedOut, in: recorder) == 1, "iteration \(iteration)")
                #expect(count(.barrierCancelled, in: recorder) == 0, "iteration \(iteration)")
            case .reached:
                Issue.record("iteration \(iteration): the open sequence below was never settled, got .reached")
            }
            handle.release()
        }
    }

    // MARK: - Non-finite timeouts (review fix M12)

    @Test("""
        A non-finite timeout never traps (review fix M12): +infinity is 'practically forever' (the wait stays pending until \
        released), NaN is 'no wait at all' (it times out at once), and drainForLifecycle / awaitSettled accept both
        """)
    func nonFiniteTimeouts_doNotTrap() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60
        let editor = writer.reserve()                           // seq 1: open -> keeps barriers unreached
        let first = try #require(writer.enqueueBarrier())      // seq 2
        defer { first.release() }

        let infiniteWait = try await startPendingWait(first, timeout: .infinity)
        first.release()                                         // unreached release: resumes the pending wait
        #expect(await infiniteWait.value == .cancelled, "an infinite bound is a pending wait, not an immediate timeout")

        let second = try #require(writer.enqueueBarrier())     // seq 3
        defer { second.release() }
        let nanOutcome = await second.wait(timeout: .nan)
        #expect(nanOutcome == .timedOut(skippedEditorSeqs: [editor.seq], skippedFetched: 0), "NaN is a zero bound")

        #expect(await writer.drainForLifecycle(timeout: .infinity) == .drained)
        #expect(await writer.drainForLifecycle(timeout: .nan) == .drained)
        #expect(await writer.awaitSettled(through: second.seq, timeout: .infinity) == .settled)
        #expect(await writer.awaitSettled(through: second.seq, timeout: .nan) == .settled)
    }
}
