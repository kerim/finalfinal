//
//  DocumentWriterTests.swift
//  final finalTests
//
//  t-94369a83 Phase 1 ("writer foundation", plan §2.5 step 6): drives `DocumentWriter`
//  directly (no `BlockSyncService`, no WebView, no JS) -- reserve/fetch/apply/settle
//  called straight against the actor, observed only through `testEventHandler`,
//  `testFrontier`, `testArmedExpirySeq`, `testHeldCount` and `ledger`.
//
//  `DocumentWriter.testEventHandler` is `@Sendable` (the writer calls it from
//  nonisolated contexts reachable from any actor, not just MainActor), so these tests
//  cannot capture and mutate a plain local `var` from inside it the way the
//  MainActor-isolated `BlockSyncPollWatchdogTests` helpers do. `WriterEventSignal`
//  and `WriterEventRecorder` below are the Sendable-safe (NSLock-guarded) equivalents.
//

import Foundation
import Testing
@testable import final_final

/// One-shot, thread-safe signal that fires the first time `note(_:)` sees an event
/// matching `predicate`. See the file header for why this can't just be a captured
/// local `var` toggled from `testEventHandler`.
final class WriterEventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let predicate: @Sendable (WriterEvent) -> Bool

    init(matching predicate: @escaping @Sendable (WriterEvent) -> Bool) {
        self.predicate = predicate
    }

    func note(_ event: WriterEvent) {
        guard predicate(event) else { return }
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            let wasFired = fired
            fired = true
            let cont = continuation
            continuation = nil
            return wasFired ? nil : cont
        }
        pending?.resume()
    }

    /// `NSLock.withLock` (not raw `.lock()`/`.unlock()`): those are flagged as unsafe
    /// to call from an `async` function body -- an error under the Swift 6 language
    /// mode -- because the compiler can't verify no suspension happens between them.
    /// `withLock`'s closure is synchronous, so this stays a plain, brief critical
    /// section with no `await` inside it, same as before.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFired: Bool = lock.withLock {
                if fired {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if alreadyFired {
                continuation.resume()
            }
        }
    }
}

/// Thread-safe append-only recorder of every `WriterEvent` a test has seen.
final class WriterEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WriterEvent] = []
    func append(_ event: WriterEvent) {
        lock.withLock { events.append(event) }
    }
    var all: [WriterEvent] {
        lock.withLock { events }
    }
}

/// One-shot, thread-safe signal fired by `DocumentWriter.testDrainWatermarkCapturedHook`
/// once `drain(timeout:)` has actually captured its watermark (item 13, W5). Same
/// NSLock shape as `WriterEventSignal` above, just carrying a `UInt64` instead of a
/// `WriterEvent` and needing no predicate (this hook exists for exactly one purpose,
/// so every call is a match). Replaces a spin-wait whose loop condition
/// (`writer.nextSequence < 3`) was already false before the loop ever ran: two prior
/// `reserve()` calls had already advanced `nextSeq` to 3, and `drain()` never mutates
/// it, so the loop body never executed even once and the "wait" provided zero
/// synchronization against the real race (spawning the drain Task vs. reserving
/// ticket 3).
final class WatermarkSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func note(_ watermark: UInt64) {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            let wasFired = fired
            fired = true
            let cont = continuation
            continuation = nil
            return wasFired ? nil : cont
        }
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFired: Bool = lock.withLock {
                if fired { return true }
                self.continuation = continuation
                return false
            }
            if alreadyFired { continuation.resume() }
        }
    }
}

@Suite("DocumentWriter — Tier 2", .serialized, .timeLimit(.minutes(1)))
struct DocumentWriterTests {

    // Deliberately NOT @MainActor: unlike BlockSyncPollWatchdogTests.swift's makeStack
    // (which touches WKWebView/EditorViewState/BlockSyncService, all MainActor-bound),
    // nothing here is actor-isolated -- TestFixtureFactory's methods are plain static
    // funcs, `Block`/`ProjectDatabase` are Sendable, and `DocumentWriter` is its own
    // actor. These `@Test` functions are not MainActor either, so a `@MainActor` here
    // would force every call site to `await` it as a cross-actor hop instead of a
    // plain synchronous call.
    // Internal, not private: DocumentWriterLateBoundTests.swift's `extension
    // DocumentWriterTests` (addendum A2, §5 step 7) shares these two helpers --
    // `private` would restrict them to this file, invisible to an extension
    // declared elsewhere.
    func makeWriterStack(
        content: String = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n"
    ) throws -> (db: ProjectDatabase, pid: String, writer: DocumentWriter, blockA: Block, blockB: Block) {
        let db = try TestFixtureFactory.createTemporary(content: content)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let writer = DocumentWriter(database: db, projectId: pid)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let blockA = try #require(blocks.first { $0.textContent.contains("one two three") })
        let blockB = try #require(blocks.first { $0.textContent.contains("four five six") })
        return (db, pid, writer, blockA, blockB)
    }

    func stamp(_ db: ProjectDatabase, _ pid: String, _ seq: UInt64) throws -> BlockWriteStamp {
        BlockWriteStamp(epoch: try db.currentBlockWriteEpoch(projectId: pid), sequence: Int64(seq))
    }

    // W1
    @Test("drain(timeout:) times out on a reserved-but-unfetched sequence, refusing it as skipped and counting it unfetched")
    func drainTimesOutOnUnfetchedSequence() async throws {
        let (db, pid, writer, _, _) = try makeWriterStack()
        let recorder = WriterEventRecorder()
        writer.testEventHandler = { recorder.append($0) }

        _ = writer.reserve()   // seq 1: reserved, never fetched, never settled

        let outcome = await writer.drainForLifecycle(timeout: 0.2)
        guard case .timedOut(let skipped) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(skipped == [1])
        #expect(recorder.all.contains {
            if case .drainTimedOut(let seqs) = $0 { return seqs == [1] }
            return false
        })

        let outcome1 = await writer.applyEditorBatch(1, BlockChanges(), stamp: try stamp(db, pid, 1))
        guard case .refused(.skipped) = outcome1 else {
            Issue.record("expected .refused(.skipped), got \(outcome1)")
            return
        }
        #expect(writer.ledger.skippedUnfetched == 1)
    }

    // W2
    @Test("applyEditorBatch admits strictly in turn order: a later sequence's apply parks until the earlier one settles")
    func applyOrder_laterSequenceWaitsForEarlier() async throws {
        let (db, pid, writer, blockA, blockB) = try makeWriterStack()
        let ticket1 = writer.reserve()
        let ticket2 = writer.reserve()
        ticket1.noteFetched()
        ticket2.noteFetched()

        let parked2 = WriterEventSignal(matching: { if case .parked(2) = $0 { return true }; return false })
        writer.testEventHandler = { parked2.note($0) }

        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(updates: [
                BlockUpdate(id: blockA.id, textContent: "seq2 text", markdownFragment: nil, headingLevel: nil)
            ]), stamp: stamp2)
        }
        await parked2.wait()

        #expect(await ticket1.waitForTurn() == .go)
        _ = await writer.applyEditorBatch(1, BlockChanges(updates: [
            BlockUpdate(id: blockA.id, textContent: "seq1 alpha", markdownFragment: nil, headingLevel: nil),
            BlockUpdate(id: blockB.id, textContent: "seq1 beta", markdownFragment: nil, headingLevel: nil)
        ]), stamp: try stamp(db, pid, 1))

        _ = await cycle2.value

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let textForId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.textContent) })
        #expect(textForId[blockA.id] == "seq2 text", "seq2 (newer) must win on the shared block")
        #expect(textForId[blockB.id] == "seq1 beta", "seq1's unique row must still land")
    }

    // W3
    @Test("A parked waiter is deterministic: the frontier stays put and its rows are absent until the frontier settles")
    func parkedWaiter_isDeterministic() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        let ticket1 = writer.reserve()
        let ticket2 = writer.reserve()
        ticket2.noteFetched()

        let parked2 = WriterEventSignal(matching: { if case .parked(2) = $0 { return true }; return false })
        writer.testEventHandler = { parked2.note($0) }

        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(updates: [
                BlockUpdate(id: blockA.id, textContent: "seq2 text", markdownFragment: nil, headingLevel: nil)
            ]), stamp: stamp2)
        }
        await parked2.wait()
        #expect(writer.testFrontier == 1)
        let before = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id }
        #expect(before?.textContent != "seq2 text")

        ticket1.settleIfOpen(.empty)
        _ = await cycle2.value
        let after = try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id }
        #expect(after?.textContent == "seq2 text")
    }

    // W4
    @Test("skip(upTo:) synchronously releases a parked waiter as .skipped, and a later apply for a skipped sequence is refused")
    func skip_releasesWaiterSynchronously_andRefusesLateApply() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        _ = writer.reserve()   // seq 1: occupies the frontier so seq 2 has to park
        let ticket2 = writer.reserve()
        ticket2.noteFetched()

        let parked2 = WriterEventSignal(matching: { if case .parked(2) = $0 { return true }; return false })
        let refused1 = WriterEventSignal(matching: { if case .refused(1, .skipped) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            parked2.note(event)
            refused1.note(event)
        }

        let cycle2 = Task { await ticket2.waitForTurn() }
        await parked2.wait()

        writer.skip(upTo: 2, reason: .editorReplaced)
        let result2 = await cycle2.value
        #expect(result2 == .skipped)

        let outcome1 = await writer.applyEditorBatch(1, BlockChanges(updates: [
            BlockUpdate(id: blockA.id, textContent: "too late", markdownFragment: nil, headingLevel: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .refused(.skipped) = outcome1 else {
            Issue.record("expected .refused(.skipped), got \(outcome1)")
            return
        }
        await refused1.wait()
    }

    // W5
    @Test("drain(timeout:) is a snapshot: a sequence reserved after it started is not covered")
    func drain_isASnapshot() async throws {
        let (_, _, writer, _, _) = try makeWriterStack()
        let ticket1 = writer.reserve()
        let ticket2 = writer.reserve()

        let watermarkCaptured = WatermarkSignal()
        writer.testDrainWatermarkCapturedHook = { watermark in watermarkCaptured.note(watermark) }

        let drainTask = Task { await writer.drainForLifecycle(timeout: 5) }
        // Real synchronization on the moment `drainForLifecycle()` actually
        // captures its watermark (item 13) -- not a spin on unrelated state.
        await watermarkCaptured.wait()

        let ticket3 = writer.reserve()
        ticket1.settleIfOpen(.empty)
        ticket2.settleIfOpen(.empty)

        let outcome = await drainTask.value
        #expect(outcome == .drained)
        #expect(writer.testFrontier == 3, "seq 3 must still be open — the drain must not have covered it")
        ticket3.settleIfOpen(.empty)
    }

    // W6
    @Test("A temp id minted by an earlier sequence resolves in a later sequence's update and insert anchor")
    func tempId_resolvesInLaterSequence() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-w6-1", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied(let applied1) = result1, let permanentId = applied1.idMapping["temp-w6-1"] else {
            Issue.record("expected seq 1 to mint temp-w6-1, got \(result1)")
            return
        }

        let result2 = await writer.applyEditorBatch(2, BlockChanges(
            updates: [BlockUpdate(id: "temp-w6-1", textContent: "edited", markdownFragment: nil, headingLevel: nil)],
            inserts: [BlockInsert(tempId: "temp-w6-2", blockType: "paragraph", textContent: "second",
                                   markdownFragment: "second", headingLevel: nil,
                                   afterBlockId: "temp-w6-1", atDocumentStart: nil)]
        ), stamp: try stamp(db, pid, 2))
        guard case .applied = result2 else {
            Issue.record("expected seq 2 to apply, got \(result2)")
            return
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let editedRow = try #require(after.first { $0.id == permanentId })
        #expect(editedRow.textContent == "edited", "the update must resolve temp-w6-1 to its permanent id")
        let secondIndex = try #require(after.firstIndex { $0.textContent == "second" })
        let firstIndex = try #require(after.firstIndex { $0.id == permanentId })
        #expect(secondIndex == firstIndex + 1, "the insert anchored on temp-w6-1 must resolve and land right after it")
    }

    // W7
    @Test("A stuck sequence's turn-stall expiry lets a successor proceed, holding its ops until the stuck sequence applies late")
    func expiry_holdsOpsUntilLateApply() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2

        let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        let held2 = WriterEventSignal(matching: { if case .held(2, 2) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            expired1.note(event)
            held2.note(event)
        }

        _ = writer.reserve()   // seq 1: never fetched -- stays .reserved until it expires

        let ticket2 = writer.reserve()
        ticket2.noteFetched()
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(
                updates: [BlockUpdate(id: "temp-w7-1", textContent: "seq2 edit", markdownFragment: nil, headingLevel: nil)],
                inserts: [BlockInsert(tempId: "temp-w7-2", blockType: "paragraph", textContent: "seq2 insert",
                                       markdownFragment: "seq2 insert", headingLevel: nil,
                                       afterBlockId: "temp-w7-1", atDocumentStart: nil)]
            ), stamp: stamp2)
        }
        await expired1.wait()
        await held2.wait()
        let result2 = await cycle2.value
        guard case .applied = result2 else {
            Issue.record("seq2 must apply once seq1 goes late — got \(result2)")
            return
        }

        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-w7-1", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied(let applied1) = result1, let permanentId = applied1.idMapping["temp-w7-1"] else {
            Issue.record("expected seq 1 to apply late and mint temp-w7-1, got \(result1)")
            return
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let mainRow = try #require(after.first { $0.id == permanentId })
        #expect(mainRow.textContent == "seq2 edit", "the held update must cascade onto the newly minted row")
        let insertIndex = try #require(after.firstIndex { $0.textContent == "seq2 insert" })
        let mainIndex = try #require(after.firstIndex { $0.id == permanentId })
        #expect(insertIndex == mainIndex + 1, "the held insert must land directly after the minted row")
        #expect(writer.ledger.lateApplies == 1)
        let ledger = writer.ledger
        #expect(ledger.skippedConsumed == 0 && ledger.skippedUnfetched == 0 && ledger.discardedAfterFetch == 0
                && ledger.failedWrites == 0 && ledger.heldOpsUnresolved == 0 && ledger.heldOpsDropped == 0,
                "every loss counter must be zero — got \(ledger)")
    }

    // W8
    @Test("A held delete of a not-yet-minted temp id is applied when the insert lands, leaving no row; a delete of a missing id is not counted")
    func heldDelete_appliesOnMint_leavingNoRow() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2
        let before = try TestFixtureFactory.fetchBlocks(from: db)

        let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        writer.testEventHandler = { expired1.note($0) }

        _ = writer.reserve()
        let ticket2 = writer.reserve()
        ticket2.noteFetched()
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(deletes: ["temp-w8-1"]), stamp: stamp2)
        }
        await expired1.wait()
        let result2 = await cycle2.value
        guard case .applied = result2 else {
            Issue.record("expected seq2 to apply, got \(result2)")
            return
        }

        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-w8-1", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied = result1 else {
            Issue.record("expected seq1 late apply, got \(result1)")
            return
        }

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.count == before.count, "the insert-then-delete must leave no new row")
        #expect(!after.contains { $0.textContent == "created" })

        let deleted = try await db.dbWriter.write { database in
            try db.processEditorDeletes(db: database, deletes: ["not-a-real-id"])
        }
        #expect(deleted == [])
    }

    // W9
    // swiftlint:disable line_length
    @Test("Settlement rules: a double settle is a no-op, a settle of a skipped sequence is a no-op too, and an out-of-order settle only advances the frontier once both resolve")
    // swiftlint:enable line_length
    func settlement_doubleAndOutOfOrder() async throws {
        let (_, _, writer, _, _) = try makeWriterStack()
        let ticket1 = writer.reserve()
        ticket1.settleIfOpen(.empty)
        let frontierAfterFirst = writer.testFrontier
        ticket1.settleIfOpen(.empty)   // double settle: no-op
        #expect(writer.testRedundantSettleCount == 1)
        #expect(writer.testFrontier == frontierAfterFirst)

        let ticket2 = writer.reserve()
        writer.skip(upTo: 2, reason: .editorReplaced)
        ticket2.settleIfOpen(.empty)   // settling an already-skipped sequence: also a no-op
        #expect(writer.testRedundantSettleCount == 2)

        let ticket3 = writer.reserve()
        let ticket4 = writer.reserve()
        ticket4.settleIfOpen(.empty)
        #expect(writer.testFrontier == 3, "seq 4 settling out of order must not move the frontier past the still-open seq 3")
        ticket3.settleIfOpen(.empty)
        #expect(writer.testFrontier == 5)
    }

    // W10
    @Test("Held ops with no late sequence left open are released unresolved, not left waiting for a next apply that may never come")
    func heldOps_releasedUnresolvedWhenOrphaned() async throws {
        let (db, pid, writer, _, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2

        let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        let orphansReleased = WriterEventSignal(matching: {
            if case .orphansReleased(2, inline: false) = $0 { return true }; return false
        })
        writer.testEventHandler = { event in
            expired1.note(event)
            orphansReleased.note(event)
        }

        let ticket1 = writer.reserve()
        let ticket2 = writer.reserve()
        ticket2.noteFetched()
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(
                updates: [BlockUpdate(id: "temp-w10-1", textContent: "seq2 edit", markdownFragment: nil, headingLevel: nil)],
                inserts: [BlockInsert(tempId: "temp-w10-2", blockType: "paragraph", textContent: "seq2 insert",
                                       markdownFragment: "seq2 insert", headingLevel: nil,
                                       afterBlockId: "temp-w10-1", atDocumentStart: nil)]
            ), stamp: stamp2)
        }
        await expired1.wait()
        let result2 = await cycle2.value
        guard case .applied = result2 else {
            Issue.record("expected seq2 to apply, got \(result2)")
            return
        }
        #expect(writer.testHeldCount == 2)

        // Seq 1 settles WITHOUT applying (its batch was discarded upstream) -- no
        // further apply ever comes for it.
        ticket1.settleIfOpen(.discarded(.generationChanged("postFetch")))

        await orphansReleased.wait()
        let ledger = writer.ledger
        #expect(ledger.heldOpsUnresolved == 2)
        #expect(writer.testHeldCount == 0)
        #expect(ledger.heldOpsTotal == 2 && ledger.heldOpsTotal == ledger.heldOpsUnresolved,
                "I-HOLD: every held op must be accounted — got \(ledger)")

        // An unknown temp id is handled exactly as an ordinary unmatched insert: it
        // still lands (the update to it is simply logged and ignored upstream).
        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.contains { $0.textContent == "seq2 insert" })
    }

    // W11
    @Test("The turn-stall expiry re-arms on the new frontier when it moves to another stuck sequence")
    func expiry_rearmsOnFrontierMove() async throws {
        let (_, _, writer, _, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.3

        let expiryArmed1 = WriterEventSignal(matching: { if case .expiryArmed(1) = $0 { return true }; return false })
        let expiryArmed2 = WriterEventSignal(matching: { if case .expiryArmed(2) = $0 { return true }; return false })
        let expired2 = WriterEventSignal(matching: { if case .expired(2) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            expiryArmed1.note(event)
            expiryArmed2.note(event)
            expired2.note(event)
        }

        let ticket1 = writer.reserve()   // seq 1, unfetched
        _ = writer.reserve()             // seq 2, unfetched
        let ticket3 = writer.reserve()
        ticket3.noteFetched()
        let cycle3 = Task { await ticket3.waitForTurn() }

        await expiryArmed1.wait()

        ticket1.settleIfOpen(.noBatch)   // seq 1 resolves normally; frontier moves to seq 2
        await expiryArmed2.wait()
        await expired2.wait()

        let result3 = await cycle3.value
        #expect(result3 == .go)
    }

    // W12
    @Test("Chained turn-stall expiries fire back-to-back, in frontier order, across multiple stuck sequences")
    func expiry_chainedAcrossMultipleStuckSequences() async throws {
        let (_, _, writer, _, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2

        let recorder = WriterEventRecorder()
        let expired3 = WriterEventSignal(matching: { if case .expired(3) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            recorder.append(event)
            expired3.note(event)
        }

        _ = writer.reserve()   // seq 1, unfetched
        _ = writer.reserve()   // seq 2, unfetched
        _ = writer.reserve()   // seq 3, unfetched
        let ticket4 = writer.reserve()
        ticket4.noteFetched()
        let cycle4 = Task { await ticket4.waitForTurn() }

        await expired3.wait()
        let expiredSeqs = recorder.all.compactMap { event -> UInt64? in
            if case .expired(let seq) = event { return seq }
            return nil
        }
        #expect(expiredSeqs == [1, 2, 3], "expiries must fire in frontier order — got \(expiredSeqs)")

        let result4 = await cycle4.value
        #expect(result4 == .go)
    }

    // W13
    @Test("When the last open late sequence closes by APPLYING, its held-op release runs inline in the same actor turn")
    func lastLateCloses_byApplying_releasesInline() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2

        let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        // Any count, not a literal `1`: the code's own comment on this exact release
        // documents that an earlier, equally-valid internal batching choice (combining
        // both cascades into one event/count instead of two separate ones) caused this
        // exact test to hang for 60s waiting on a count that never arrived. The
        // ledger/DB assertions below already pin down the real end state; this signal
        // only needs to know an inline release happened at all.
        let orphansReleasedInline = WriterEventSignal(matching: {
            if case .orphansReleased(_, inline: true) = $0 { return true }; return false
        })
        writer.testEventHandler = { event in
            expired1.note(event)
            orphansReleasedInline.note(event)
        }

        _ = writer.reserve()
        let ticket2 = writer.reserve()
        ticket2.noteFetched()
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            // One update on temp-w13-x (which seq1 will mint) and one on an unrelated
            // temp id that will be left orphaned once seq1 applies.
            return await writer.applyEditorBatch(2, BlockChanges(updates: [
                BlockUpdate(id: "temp-w13-x", textContent: "seq2 on x", markdownFragment: nil, headingLevel: nil),
                BlockUpdate(id: "temp-w13-z", textContent: "seq2 on z", markdownFragment: nil, headingLevel: nil)
            ]), stamp: stamp2)
        }
        await expired1.wait()
        let result2 = await cycle2.value
        guard case .applied = result2 else {
            Issue.record("expected seq2 to apply, got \(result2)")
            return
        }
        #expect(writer.testHeldCount == 2)

        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-w13-x", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied(let applied1) = result1, let permanentId = applied1.idMapping["temp-w13-x"] else {
            Issue.record("expected seq1 to apply late and mint temp-w13-x, got \(result1)")
            return
        }

        // No `await` between the apply returning and these assertions: the release for
        // the orphaned temp-w13-z must already have happened, inline, in that same turn.
        let ledger = writer.ledger
        #expect(ledger.heldOpsResolved == 1, "temp-w13-x's held update must have cascaded")
        #expect(ledger.heldOpsUnresolved == 1, "temp-w13-z's held update must have released unresolved inline")
        #expect(writer.testHeldCount == 0)
        await orphansReleasedInline.wait()

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let row = try #require(after.first { $0.id == permanentId })
        #expect(row.textContent == "seq2 on x")
    }

    // W14
    @Test("Drain timeout and retire both drop every remaining held op, counted, rather than releasing them after the caller has moved on")
    func drainTimeoutAndRetire_dropHeldOps() async throws {
        // (a) drain timeout.
        do {
            let (db, pid, writer, blockA, _) = try makeWriterStack()
            writer.testLateAfterSeconds = 0.05
            let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
            writer.testEventHandler = { expired1.note($0) }

            _ = writer.reserve()
            let ticket2 = writer.reserve()
            ticket2.noteFetched()
            let stamp2 = try stamp(db, pid, 2)
            let cycle2 = Task { () -> WriterApplyOutcome in
                guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
                return await writer.applyEditorBatch(2, BlockChanges(updates: [
                    BlockUpdate(id: "temp-w14a-1", textContent: "held", markdownFragment: nil, headingLevel: nil),
                    BlockUpdate(id: "temp-w14a-2", textContent: "held too", markdownFragment: nil, headingLevel: nil)
                ]), stamp: stamp2)
            }
            await expired1.wait()
            let result2 = await cycle2.value
            guard case .applied = result2 else {
                Issue.record("expected seq2 to apply, got \(result2)")
                return
            }
            #expect(writer.testHeldCount == 2)

            let outcome = await writer.drainForLifecycle(timeout: 0.1)
            guard case .timedOut = outcome else {
                Issue.record("expected .timedOut, got \(outcome)")
                return
            }
            #expect(writer.ledger.heldOpsDropped == 2)
            #expect(writer.testHeldCount == 0)

            let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
                BlockInsert(tempId: "temp-w14a-1", blockType: "paragraph", textContent: "created",
                            markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
            ]), stamp: try stamp(db, pid, 1))
            guard case .refused(.skipped) = result1 else {
                Issue.record("expected seq1 refused as skipped after drain timeout, got \(result1)")
                return
            }
            let after = try TestFixtureFactory.fetchBlocks(from: db)
            #expect(!after.contains { $0.textContent == "held" || $0.textContent == "held too" || $0.textContent == "created" })
        }

        // (b) retire.
        do {
            let (db, pid, writer, _, _) = try makeWriterStack()
            writer.testLateAfterSeconds = 0.05
            let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
            writer.testEventHandler = { expired1.note($0) }

            _ = writer.reserve()
            let ticket2 = writer.reserve()
            ticket2.noteFetched()
            let stamp2 = try stamp(db, pid, 2)
            let cycle2 = Task { () -> WriterApplyOutcome in
                guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
                return await writer.applyEditorBatch(2, BlockChanges(updates: [
                    BlockUpdate(id: "temp-w14b-1", textContent: "held", markdownFragment: nil, headingLevel: nil),
                    BlockUpdate(id: "temp-w14b-2", textContent: "held too", markdownFragment: nil, headingLevel: nil)
                ]), stamp: stamp2)
            }
            await expired1.wait()
            let result2 = await cycle2.value
            guard case .applied = result2 else {
                Issue.record("expected seq2 to apply, got \(result2)")
                return
            }
            #expect(writer.testHeldCount == 2)

            writer.retire(reason: .writerReplaced)
            #expect(writer.ledger.heldOpsDropped == 2)

            await writer.releaseDueHolds()   // idempotent: must not double-count
            #expect(writer.ledger.heldOpsDropped == 2, "a no-op release must not double count")
        }
    }
}
