//
//  LifecycleFlushBarrierTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3b (slice-3a-1b-everyday.md section 4.2 step 8, section 7.2 "C3b"): the
//  writer barrier at the end of the save sequence, FB's place in front of it, and the quit path.
//
//    - the barrier is taken AFTER FB was reserved (N9), held when the sequence returns, and the sequence
//      records it in `lifecycleBarrier` (the caller's defer releases it)
//    - U2(c): an editor batch reserved before FB that applies late is refused for its stale epoch
//      (REGRESSION PIN: the mechanism is 3a-1a's, this pins it through the whole sequence)
//    - U2(d): the starvation case. A quit's barrier wait is `remaining - backupReserve`, so the automatic
//      version always has its 3s (A23 form); a close has no reserve
//    - E1: a slow FB (it lost its 2s race) is what the barrier waits for: FB is applied before the barrier
//      is reached and nothing is counted lost
//    - an existing writer refusing the barrier cancels a close and lets a quit continue
//    - a quit whose section operation never clears: F applied, no FB, no step 7
//
//  The automatic version made AFTER FB (E1's "snapshot row contains FB's text") is the tail's work: rounds
//  C5b/C6. Here E1 pins everything up to the barrier.
//

import Foundation
import Testing
@testable import final_final

@Suite("Lifecycle save sequence, step 8 barrier — Tier 2 (t-94369a83 3a-1b C3b)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleFlushBarrierTests {

    private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"

    private func prime(_ rig: LifecycleFlushHarness) {
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = Self.fresh
    }

    private func firstIndex(of match: (WriterEvent) -> Bool, in events: [WriterEvent]) -> Int? {
        events.firstIndex(where: match)
    }

    // MARK: - The barrier after FB

    @Test("""
        a healthy close: FB is applied, THEN the barrier is queued and reached, the sequence returns with it held \
        and recorded in lifecycleBarrier, and lifecycleFlushDoneFor is set
        """)
    func healthyClose_holdsTheBarrierBehindFB() async throws {
        let rig = try LifecycleFlushHarness()
        prime(rig)

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.fbOutcome == .applied)
        #expect(result.barrier == .waited(.reached))
        let held = try #require(rig.barrierSeqHeldAtReturn, "the sequence must leave the barrier recorded in lifecycleBarrier")
        #expect(rig.writerBarrierSeqAtReturn == held, "and held on the writer")
        #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "the harness (execute's defer) released it")
        #expect(rig.editorState.lifecycleFlushDoneFor != nil, "the save sequence is done (a joined quit will not flush again)")
        let events = rig.writerEvents.events
        let applied = try #require(firstIndex(of: { if case .systemApplied = $0 { return true }; return false }, in: events))
        let queued = try #require(firstIndex(of: { $0 == .barrierQueued }, in: events))
        let reached = try #require(firstIndex(of: { $0 == .barrierReached }, in: events))
        #expect(applied < queued, "N9: FB must be reserved and applied before the barrier is queued; events: \(events)")
        #expect(queued < reached)
        // FB's sequence number is below the barrier's: it was reserved first.
        let fbSeq: UInt64? = events.compactMap { event -> UInt64? in if case .systemApplied(let seq) = event { return seq }; return nil }.first
        #expect(try #require(fbSeq) < held)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
    }

    // MARK: - U2(c): REGRESSION PIN

    @Test("""
        U2(c), REGRESSION PIN (the epoch mechanism is 3a-1a's): an editor batch reserved before FB that applies late, \
        after the sequence, is refused whole for its stale epoch -- the rows stay FB's
        """)
    func orphanBatchAfterTheSequence_isRefusedByStamp() async throws {
        let rig = try LifecycleFlushHarness()
        prime(rig)
        rig.sync.testWriterLateAfterSeconds = 0.05
        let writer = try #require(rig.sync.testWriterHandle)
        let before = try rig.blocks()
        let alphaId = try #require(before.first { $0.blockType == .heading && $0.textContent == "Alpha" }).id
        let betaId = try #require(before.first { $0.blockType == .heading && $0.textContent == "Beta" }).id
        // An orphan editor batch: reserved at epoch E, never answered (a wedged poll that gave up).
        let epochE = try rig.db.currentBlockWriteEpoch(projectId: rig.pid)
        let orphan = writer.reserve()
        let stamp = BlockWriteStamp(epoch: epochE, sequence: Int64(orphan.seq))

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.25))

        #expect(result.outcome == .flushed)
        #expect(result.barrier == .waited(.reached), "the orphan goes late (0.05s), which is frontier-passable: it never blocks the barrier")
        #expect(try rig.paragraphTexts().contains("fresh Y paragraph."), "FB applied past the orphan")
        // The orphan's reply finally arrives, targeting rows that still exist after FB.
        orphan.noteFetched()
        let changes = BlockChanges(
            updates: [BlockUpdate(id: alphaId, textContent: "STALE alpha", markdownFragment: nil, headingLevel: nil)],
            inserts: [BlockInsert(tempId: "temp-u2c-1", blockType: "paragraph", textContent: "stale insert",
                                  markdownFragment: "stale insert", headingLevel: nil,
                                  afterBlockId: alphaId, atDocumentStart: nil)],
            deletes: [betaId])
        let outcome = await writer.applyEditorBatch(orphan.seq, changes, stamp: stamp)
        guard case .applied(let applied) = outcome else {
            Issue.record("expected the late batch to be admitted and then refused by stamp, got \(outcome)")
            return
        }
        #expect(applied.rejectedWholeBatchForStaleEpoch, "the WHOLE batch must be refused for its stale epoch")
        #expect(applied.writtenCount == 0)
        let after = try rig.blocks()
        #expect(!after.contains { $0.textContent == "STALE alpha" || $0.textContent == "stale insert" })
        #expect(after.contains { $0.id == betaId }, "the stale delete must not have removed Beta")
        #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
    }

    // MARK: - U2(d): starvation (A23 form)

    @Test("""
        U2(d), A23 form: a quit whose barrier can never be reached waits only `remaining - backupReserve`, so at least \
        the backup reserve (minus a scheduling margin) is left for the automatic version; a CLOSE has no reserve and \
        spends it all
        """)
    func starvedBarrier_leavesTheQuitItsBackupReserve() async throws {
        let bounds = LifecycleBounds.production.scaled(0.1)       // quit total 1.8s, backup reserve 0.3s
        let epsilon = 0.12     // timer lateness under a loaded test run; the close variant below leaves ~0, not 0.3

        let quitRig = try LifecycleFlushHarness()
        prime(quitRig)
        let quitBlocker = try #require(quitRig.sync.testWriterHandle).reserve()     // never settles: the barrier starves
        let quit = await quitRig.run(.quit, bounds: bounds)
        let leftForQuit = try #require(quitRig.lastDeadline).remaining
        quitBlocker.settleIfOpen(.noBatch)

        guard case .waited(.timedOut) = quit.barrier else {
            Issue.record("expected the starved barrier wait to time out, got \(quit.barrier)")
            return
        }
        #expect(leftForQuit >= bounds.quitBackupReserve - epsilon,
                "the quit's automatic version needs \(bounds.quitBackupReserve)s; only \(leftForQuit)s were left")

        let closeRig = try LifecycleFlushHarness()
        prime(closeRig)
        let closeBlocker = try #require(closeRig.sync.testWriterHandle).reserve()
        let close = await closeRig.run(.close, bounds: bounds)
        let leftForClose = try #require(closeRig.lastDeadline).remaining
        closeBlocker.settleIfOpen(.noBatch)

        guard case .waited(.timedOut) = close.barrier else {
            Issue.record("expected the starved barrier wait to time out, got \(close.barrier)")
            return
        }
        #expect(leftForClose < bounds.quitBackupReserve, "a close keeps no reserve; \(leftForClose)s were left")
    }

    // MARK: - E1: a slow FB

    @Test("""
        E1 slow FB at close: FB loses its race (the writer is held ~1s behind an unsettled sequence), the sequence \
        CONTINUES, the barrier -- queued behind FB -- waits for it, FB is applied BEFORE the barrier is reached, \
        and lifecycleWholeDocumentLost stays 0
        """)
    func slowFB_isWaitedForByTheBarrier_notLost() async throws {
        let rig = try LifecycleFlushHarness()
        prime(rig)
        let blocker = try #require(rig.sync.testWriterHandle).reserve()
        // The hold is an unsettled editor sequence below FB (the body of an applying write runs synchronously on
        // the main actor, so it cannot be "held" without freezing the race timer too). Settled after ~1s: a 4s
        // hold at 0.25x. FB's own race is 0.5s, so FB loses it.
        let releaser = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            blocker.settleIfOpen(.noBatch)
        }

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.25))
        await releaser.value

        #expect(result.outcome == .flushed, "losing the FB race must not abort the sequence")
        #expect(result.fbStatus == .started)
        #expect(result.fbOutcome == nil, "FB lost its own race (queued behind the unsettled sequence)")
        #expect(result.barrier == .waited(.reached), "the barrier, queued behind FB, waited for it")
        #expect(result.fbSettledOutcome == .applied, "FB is settled by the time the sequence returns")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0, "a slow FB is never a loss (E1)")
        #expect(rig.sync.testLifecycleLossReports == 0)
        let events = rig.writerEvents.events
        let applied = try #require(events.firstIndex { if case .systemApplied = $0 { return true }; return false })
        let reached = try #require(events.firstIndex { $0 == .barrierReached })
        #expect(applied < reached, "FB is applied before the barrier is reached; events: \(events)")
        #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
        // The automatic version made AFTER FB (its snapshot row contains FB's text) is the tail's: rounds C5b / C6.
    }

    // MARK: - The writer refuses the barrier

    @Test("an existing writer refusing the barrier CANCELS a close (the abort routine restores, round C5a); nothing is left held by it")
    func barrierRefused_cancelsAClose() async throws {
        let rig = try LifecycleFlushHarness()
        prime(rig)
        let writer = try #require(rig.sync.testWriterHandle)
        let foreign = try #require(writer.enqueueBarrier(), "precondition: another barrier is open")

        let result = await rig.run(.close, bounds: LifecycleBounds.production.scaled(0.25))

        #expect(result.outcome == .cancelledBarrierRefused)
        #expect(result.barrier == .refused)
        #expect(rig.barrierSeqHeldAtReturn == nil, "a refused barrier leaves nothing recorded")
        #expect(rig.editorState.lifecycleFlushDoneFor != nil, "FB and step 7 had run")
        // FB was reserved behind the foreign barrier: let it through and make sure it lands (never lost).
        foreign.release()
        let fbTask = try #require(result.fbTask)
        #expect(await fbTask.value == .applied)
    }

    @Test("an existing writer refusing the barrier does NOT stop a quit: it continues, the barrier is simply not held")
    func barrierRefused_aQuitContinues() async throws {
        let rig = try LifecycleFlushHarness()
        prime(rig)
        let writer = try #require(rig.sync.testWriterHandle)
        let foreign = try #require(writer.enqueueBarrier())

        let result = await rig.run(.quit, bounds: LifecycleBounds.production.scaled(0.25))

        #expect(result.outcome == .flushed, "a quit never gives up on its save")
        #expect(result.barrier == .refused)
        #expect(rig.barrierSeqHeldAtReturn == nil)
        foreign.release()
        let fbTask = try #require(result.fbTask)
        #expect(await fbTask.value == .applied)
    }

    // MARK: - Quit with a section operation still running (d)

    @Test("quit with a section operation that never clears: F is applied, NO FB, NO step 7 -- and the barrier is still taken")
    func quitWithAnOperationStillRunning_appliesFOnly() async throws {
        let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: First note.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswer = "Body[^1] and new[^2] text.\n\n# Notes\n\n[^1]: First note.\n"
        rig.editorState.contentState = .structuralUndo
        defer { rig.editorState.contentState = .idle }

        let result = await rig.run(.quit, bounds: LifecycleBounds.production.scaled(0.1))

        #expect(result.outcome == .flushed)
        #expect(result.opStillRunning)
        #expect(result.fbStatus == .skippedOpStillRunning)
        #expect(result.fbTask == nil, "no FB")
        #expect(result.footnoteRefresh == .notRun, "no step 7 either")
        #expect(result.bibliographyRefresh == .notRun)
        #expect(rig.log.contains("poll"), "F still ran; log: \(rig.log)")
        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "step 7 must not have added a definition for [^2]")
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0)
        #expect(result.barrier == .waited(.reached), "the barrier is taken whatever happened before it")
        #expect(rig.editorState.lifecycleFlushDoneFor != nil)
        withExtendedLifetime(footnotes) {}
    }
}
