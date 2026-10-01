//
//  DocumentWriterBarrierTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1a, U1: the WRITER BARRIER (plan v3 §2.1, as overridden by the binding
//  coder items 1-7, addendum P6 and judge adjustments B3/B9). Drives `DocumentWriter` directly
//  (no BlockSyncService, no WebView), exactly like DocumentWriterTests.swift / ...LateBoundTests.
//
//  The suite is split across three files (SwiftLint's type_body_length / file_length caps, the same
//  reason ZoomDataIntegrityTests is split): this file holds the harness plus reach, late/abandoned
//  entries below, parking above the barrier and release; `DocumentWriterBarrierTests+TimeoutAndHold`
//  holds hold bookkeeping and the timeout; `DocumentWriterBarrierTests+CancelAndHeldOps` holds the
//  cancel paths, addendum P6 and the held-op release racing the reach.
//
//  FAIL-BEFORE (honest): `DocumentWriter.enqueueBarrier()` is a STUB that returns nil, so every test
//  in all three files fails BEHAVIOURALLY at its first `try #require(writer.enqueueBarrier())`.
//  None of these tests can pass until the real barrier exists.
//
//  Vocabulary used below (all from plan v3 §2.1 / coder-obligations items 1-7):
//    - "reached":  every entry below the barrier is settled, `.abandoned`, or frontier-passable
//                  `.late` (item 3); no held-op release is pending; the frontier is AT the barrier.
//    - "held":     a reached barrier whose holder has not released it. A sequence reserved after
//                  it parks until `release()` (or retire).
//    - A `.late` entry only comes into being when the turn-stall timer fires, and that timer only
//      arms while some waiter is parked behind the frontier (I-EXP). Where a test needs a sequence
//      to go late it therefore reserves a keep-alive ticket and starts its `waitForTurn()` ONLY at
//      the moment the late transition is wanted (the pattern of DocumentWriterLateBoundTests W15).
//
//  Review fix M16: every test ends with `handle.release()` (a `defer`, idempotent) or a `retire`, so no
//  sequence is left parked behind a still-held barrier ("leaked its continuation" noise).
//  Review fix M14: `startPendingWait` waits on the DEBUG counter `DocumentWriter.testBarrierWaitsRegistered`,
//  not on a timer, so a cancel/release issued next always hits a genuinely PENDING wait.
//
//  Things these tests deliberately do NOT pin because the plan leaves them open (each is called
//  out where it comes up, and in the coder report): what the final `barriersReached` count is
//  after a TIMEOUT (the barrier may or may not then count as reached), the fate of a passable
//  `.late` entry at reach, and whether releasing an unreached barrier emits `.barrierReleased`.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("DocumentWriter barrier — Tier 2", .serialized, .timeLimit(.minutes(1)))
struct DocumentWriterBarrierTests {

    // MARK: - Harness (internal, not private: shared with the extension files)

    /// Same fixture as `DocumentWriterTests.makeWriterStack` (internal, shared by
    /// `DocumentWriterSystemWriteTests` the same way). Named distinctly from
    /// BlockSyncPollWatchdogTests.swift's top-level `makeStack()` to avoid shadowing it.
    func makeBarrierStack() throws -> (db: ProjectDatabase, pid: String, writer: DocumentWriter) { // swiftlint:disable:this large_tuple
        let helper = DocumentWriterTests()
        let (db, pid, writer, _, _) = try helper.makeWriterStack()
        return (db, pid, writer)
    }

    func stamp(_ db: ProjectDatabase, _ pid: String, _ seq: UInt64) throws -> BlockWriteStamp {
        BlockWriteStamp(epoch: try db.currentBlockWriteEpoch(projectId: pid), sequence: Int64(seq))
    }

    func abandonedSignal(_ seq: UInt64) -> WriterEventSignal {
        WriterEventSignal(matching: { if case .abandoned(let abandoned) = $0 { return abandoned == seq }; return false })
    }

    func parkedSignal(_ seq: UInt64) -> WriterEventSignal {
        WriterEventSignal(matching: { if case .parked(let parked) = $0 { return parked == seq }; return false })
    }

    func expiredSignal(_ seq: UInt64) -> WriterEventSignal {
        WriterEventSignal(matching: { if case .expired(let expired) = $0 { return expired == seq }; return false })
    }

    func reachedSignal() -> WriterEventSignal {
        WriterEventSignal(matching: { $0 == .barrierReached })
    }

    func count(_ event: WriterEvent, in recorder: WriterEventRecorder) -> Int {
        recorder.all.filter { $0 == event }.count
    }

    /// Polls (bounded, 1ms steps, 2s) until `writer`'s barrier-wait registration count exceeds `before` --
    /// the DEBUG counter is monotonic, so this also succeeds when the wait has ALREADY resolved (a
    /// short timeout) by the time the poll looks. Records an issue (never hangs) if it never registers.
    func waitForBarrierWaitRegistration(_ writer: DocumentWriter, after before: Int) async throws {
        var polls = 0
        while writer.testBarrierWaitsRegistered <= before, polls < 2000 {
            try await Task.sleep(for: .milliseconds(1))
            polls += 1
        }
        #expect(writer.testBarrierWaitsRegistered > before, "the barrier wait never registered its continuation")
    }

    /// Starts `handle.wait(timeout:)` in its own Task and returns only once that wait has REGISTERED its
    /// continuation (deterministic, review fix M14 -- no fixed sleep), so a cancel/release issued next
    /// hits a genuinely PENDING wait. Only for a barrier that is not already reached (a reached barrier's
    /// wait resolves at once without registering).
    func startPendingWait(_ handle: BarrierHandle, timeout: TimeInterval = 5) async throws -> Task<BarrierOutcome, Never> {
        let before = handle.writer.testBarrierWaitsRegistered
        let task = Task { await handle.wait(timeout: timeout) }
        try await waitForBarrierWaitRegistration(handle.writer, after: before)
        return task
    }

    // MARK: - Basics

    @Test("""
        A barrier on a writer with nothing open is reached at once: wait returns .reached, the ledger counts it queued and \
        reached, and the events arrive in order queued -> reached
        """)
    func emptyWriter_barrierReachedImmediately() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }

        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)

        #expect(writer.ledger.barriersQueued == 1)
        #expect(writer.ledger.barriersReached == 1)
        #expect(writer.ledger.barriersTimedOut == 0)
        #expect(writer.ledger.barriersCancelled == 0)
        let barrierEvents = recorder.all.filter { $0 == .barrierQueued || $0 == .barrierReached }
        #expect(barrierEvents == [.barrierQueued, .barrierReached])
        #expect(writer.testFrontier == handle.seq, "a reached barrier holds the frontier AT itself")
    }

    @Test("Reached only after BOTH earlier sequences (1 and 2) have settled -- never after just one of them")
    func reachedOnlyAfterSeq1AndSeq2Settle() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let ticket1 = writer.reserve()
        let ticket2 = writer.reserve()
        ticket1.noteFetched()
        ticket2.noteFetched()
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        #expect(handle.seq == 3)
        let waitTask = Task { await handle.wait(timeout: 5) }

        #expect(writer.ledger.barriersReached == 0, "seq 1 and 2 are still open")
        ticket1.settleIfOpen(.empty)
        #expect(writer.ledger.barriersReached == 0, "seq 2 is still open -- one settled sequence is not enough")
        ticket2.settleIfOpen(.empty)
        #expect(writer.ledger.barriersReached == 1, "settle is synchronous, and reach is evaluated inside that same transition")

        #expect(await waitTask.value == .reached)
        #expect(writer.testFrontier == 3)
    }

    // MARK: - Late / abandoned entries below (coder item 3, and item 35 row 1)

    @Test("""
        A reserved-but-unfetched entry below keeps the barrier UNREACHED; once that entry goes .late (frontier-passable) the \
        barrier is reached -- a passable .late entry is non-blocking (coder item 3)
        """)
    func lateUnfetchedBelow_keepsUnreachedUntilPassable_thenReached() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 0.05
        let reached = reachedSignal()
        writer.testEventHandler = { reached.note($0) }

        let ticket1 = writer.reserve()                  // seq 1: reserved, never fetched
        let handle = try #require(writer.enqueueBarrier())   // seq 2
        defer { handle.release() }
        let keepAlive = writer.reserve()                // seq 3: its parked waiter is what arms seq 1's expiry
        let waitTask = Task { await handle.wait(timeout: 5) }

        // No waiter is parked yet, so seq 1's turn-stall timer is not armed: nothing can make it
        // late, and the barrier must stay unreached.
        #expect(writer.ledger.barriersReached == 0)
        #expect(writer.testFrontier == ticket1.seq)

        Task { _ = await keepAlive.waitForTurn() }      // arms the expiry on seq 1
        await reached.wait()
        #expect(await waitTask.value == .reached)
        #expect(writer.ledger.barriersReached == 1)
        #expect(writer.ledger.barriersTimedOut == 0, "no spurious timeout")
    }

    @Test("""
        Reach with an .abandoned entry AND a passable .late entry below (coder item 35, row 1): the barrier is reached, the \
        abandoned entry is skipped with .lifecycleDrain, and an unfetched .reserved entry still blocks it until it goes late
        """)
    func reachWithAbandonedAndPassableLateBelow() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 0.05
        writer.testLateAbandonAfterSeconds = 0.15
        let recorder = WriterEventRecorder()
        let abandoned1 = abandonedSignal(1)
        let reached = reachedSignal()
        writer.testEventHandler = { recorder.append($0); abandoned1.note($0); reached.note($0) }

        // seq 1 goes late and then abandoned (a keep-alive waiter at seq 2 arms its expiry).
        _ = writer.reserve()
        let keepAlive0 = writer.reserve()
        Task { _ = await keepAlive0.waitForTurn() }
        await abandoned1.wait()
        keepAlive0.settleIfOpen(.empty)

        // A fresh unfetched editor entry (seq 3, which will go .late), the barrier (seq 4), and a
        // keep-alive (seq 5).
        _ = writer.reserve()
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        let keepAlive1 = writer.reserve()
        let waitTask = Task { await handle.wait(timeout: 5) }

        // seq 3 is still `.reserved`: it blocks the barrier even though seq 1 is merely abandoned.
        #expect(writer.ledger.barriersReached == 0)

        Task { _ = await keepAlive1.waitForTurn() }     // arms seq 3's expiry; seq 3 goes .late
        await reached.wait()
        #expect(await waitTask.value == .reached)
        #expect(writer.testFrontier == handle.seq)
        #expect(
            recorder.all.contains { event in
                if case .skipped(let seqs, .lifecycleDrain) = event { return seqs.contains(1) }
                return false
            },
            "on reach the abandoned entry below is skipped with .lifecycleDrain"
        )
        #expect(writer.ledger.barriersTimedOut == 0)
    }

    // MARK: - Parking above the barrier, release

    @Test("A sequence reserved AFTER the barrier parks until release(); release resumes it with .go, with no loss counter")
    func seqReservedAfterBarrier_parksUntilRelease() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        let parked = parkedSignal(2)
        writer.testEventHandler = { recorder.append($0); parked.note($0) }

        let handle = try #require(writer.enqueueBarrier())     // seq 1
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)
        let ticket2 = writer.reserve()                          // seq 2, after the barrier
        ticket2.noteFetched()
        let turn = Task { await ticket2.waitForTurn() }
        await parked.wait()
        #expect(writer.testFrontier == handle.seq, "seq 2 must not pass a held barrier")

        handle.release()
        #expect(await turn.value == .go)
        #expect(writer.testFrontier == 2)
        #expect(count(.barrierReleased, in: recorder) == 1)
        #expect(writer.ledger.barriersCancelled == 0, "releasing a REACHED barrier is not a cancel")
    }

    @Test("release() is idempotent: a second release is a no-op (one .barrierReleased event, frontier unchanged)")
    func releaseIsIdempotent() async throws {
        let (_, _, writer) = try makeBarrierStack()
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }
        let handle = try #require(writer.enqueueBarrier())
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)

        handle.release()
        let frontierAfterFirst = writer.testFrontier
        handle.release()
        #expect(count(.barrierReleased, in: recorder) == 1)
        #expect(writer.testFrontier == frontierAfterFirst)
        #expect(writer.ledger.barriersCancelled == 0)
    }

    @Test("release() WITHOUT retire resumes parked sequences, and the writer stays usable (P1: abort releases without retiring)")
    func releaseWithoutRetire_resumesParkedSeqs_writerStaysUsable() async throws {
        let (db, pid, writer) = try makeBarrierStack()
        let parked = parkedSignal(3)
        writer.testEventHandler = { parked.note($0) }

        let ticket1 = writer.reserve()                          // seq 1
        ticket1.settleIfOpen(.empty)
        let handle = try #require(writer.enqueueBarrier())     // seq 2
        defer { handle.release() }
        #expect(await handle.wait(timeout: 2) == .reached)
        let ticket3 = writer.reserve()                          // seq 3
        ticket3.noteFetched()
        let turn = Task { await ticket3.waitForTurn() }
        await parked.wait()

        handle.release()
        #expect(await turn.value == .go)
        let outcome = await writer.applyEditorBatch(3, BlockChanges(), stamp: try stamp(db, pid, 3))
        guard case .applied = outcome else {
            Issue.record("expected the parked sequence to apply after a plain release, got \(outcome)")
            return
        }
        // A new barrier can be opened again afterwards (the writer was never retired).
        let again = try #require(writer.enqueueBarrier())
        defer { again.release() }
        #expect(again.seq > handle.seq)
    }

    @Test("""
        Releasing an UNREACHED barrier (coder items 5 and 35, row 3): a pending wait resumes .cancelled and is counted \
        barriersCancelled, the barrier stops blocking, and a waiter parked above resumes once the open sequence below settles
        """)
    func releasingUnreachedBarrier_resumesParkedWaiters() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60      // keep seq 1 from going late while a waiter is parked behind it
        let parked = parkedSignal(3)
        writer.testEventHandler = { parked.note($0) }

        let ticket1 = writer.reserve()                          // seq 1: open, blocks the barrier
        let handle = try #require(writer.enqueueBarrier())     // seq 2
        defer { handle.release() }
        let waitTask = try await startPendingWait(handle)
        let ticket3 = writer.reserve()                          // seq 3, above the barrier
        ticket3.noteFetched()
        let turn = Task { await ticket3.waitForTurn() }
        await parked.wait()

        handle.release()                                         // unreached
        // Micro-decision recorded in slice-3a-1a.md C1: a PENDING wait is resumed .cancelled by release().
        #expect(await waitTask.value == .cancelled)
        #expect(writer.ledger.barriersCancelled == 1)

        ticket1.settleIfOpen(.empty)
        #expect(await turn.value == .go, "the released barrier must no longer hold seq 3 back")
        #expect(writer.testFrontier == 3)
    }

    @Test("A second enqueueBarrier while one is open returns nil (unreached and reached alike); after release a new one is granted")
    func nestedEnqueueBarrier_returnsNilWhileOpen() async throws {
        let (_, _, writer) = try makeBarrierStack()
        writer.testLateAfterSeconds = 60
        let ticket1 = writer.reserve()
        let first = try #require(writer.enqueueBarrier())
        defer { first.release() }
        #expect(writer.enqueueBarrier() == nil, "a barrier is already open (unreached)")
        ticket1.settleIfOpen(.empty)
        #expect(await first.wait(timeout: 2) == .reached)
        #expect(writer.enqueueBarrier() == nil, "a barrier is already open (reached and held)")
        #expect(writer.ledger.barriersQueued == 1, "a refused nested request must not count as queued")

        first.release()
        let second = try #require(writer.enqueueBarrier())
        defer { second.release() }
        #expect(second.seq > first.seq)
    }
}
