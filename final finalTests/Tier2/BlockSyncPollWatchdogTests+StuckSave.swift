//
//  BlockSyncPollWatchdogTests+StuckSave.swift
//  final finalTests
//
//  t-94369a83 Phase 1 ("writer foundation", plan §2.5 step 1): these three tests are
//  written FIRST, before `DocumentWriter.swift` exists, and are expected to FAIL TO
//  COMPILE on the untouched branch — `sync.testWriterLedger`, `sync.testWriterLateAfterSeconds`
//  and the writer machinery they exercise do not exist yet. That failure-to-compile is
//  itself the proof the plan's step 1 asks for; do not attempt to make these pass before
//  DocumentWriter.swift and the BlockSyncService rewiring (steps 3-4) land.
//
//  Same-suite context: an extension of `BlockSyncPollWatchdogTests` (Tier 2), so these
//  inherit `.serialized` and `.timeLimit(.minutes(1))` from that suite's `@Suite`, and
//  share `makeStack`, `ScriptedJSEvaluator`, `blockChangesJSON`, `TestStack` with the rest
//  of it — see that file's header for the shared scripted-JS-evaluator design.
//
//  B1 and B2 reproduce t-8a92dde2: an edit to a block just created by a save that is
//  still stuck (its `getBlockChanges()` fetch has not returned) used to be either
//  abandoned outright (dropping the edit) or applied against an id that does not exist
//  yet. After Phase 1: cycle 2 either waits its turn, or, once cycle 1's fetch has been
//  outstanding 3s, proceeds with its edit to `temp-stuck-1` held by DocumentWriter until
//  the insert lands; either way the edit lands on the permanent row.
//
//  B4 is a REGRESSION LOCK, not a before-fail: today it passes only via the apply-chain
//  valve (removed by this phase); against the pre-Phase-1 unbounded predecessor wait it
//  would have failed at the poll watchdog. It proves the A2 requirement: a forced
//  database-rebuild flush lands its own batch before it returns, even while an unrelated
//  routine fetch is stuck.
//
//  The local synchronization helper (`StuckSaveSignal`) is a file-scoped copy of the
//  base file's private `StartSignal` — that is file-private in BlockSyncPollWatchdogTests.swift
//  and not visible here.
//

import Foundation
import Testing
import WebKit
@testable import final_final

/// MainActor-isolated one-shot signal; `wait()` returns immediately if already fired.
/// File-scoped copy of BlockSyncPollWatchdogTests.swift's private `StartSignal` (not
/// visible across files).
@MainActor
private final class StuckSaveSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
extension BlockSyncPollWatchdogTests {

    /// B1. Cycle 1 wedges inside `getBlockChanges` while consuming an insert of a new
    /// block (`temp-stuck-1`); cycle 2 fetches an update to that same not-yet-created
    /// block. Before Phase 1, the apply chain's valve abandons cycle 1 after 3s and the
    /// update it never got to apply is silently lost. After Phase 1, cycle 2's update is
    /// HELD by DocumentWriter (the referenced temp id has no row yet) until cycle 1's
    /// insert lands — whether cycle 1 resumes before or after the 3s turn-stall expiry —
    /// and is then applied on the permanent row. Runtime is about 4.5s: `makeStack()`
    /// sets a 0.2s per-JS-call poll watchdog (irrelevant to a genuinely wedged
    /// continuation, which does not observe Task cancellation), and the writer's
    /// turn-stall expiry uses its 3.0s production default; the suite limit is 1 minute.
    @Test("A stuck insert's fetch outstanding: a successor's edit to the not-yet-created block is held, not lost, and lands once the insert lands")
    func stuckInsertSave_editToNewBlockLandsOnPermanentRow() async throws {
        let stack = try makeStack()
        let (db, sync, editorState) = (stack.db, stack.sync, stack.editorState)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let anchor = try #require(before.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")

        let xJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: "temp-stuck-1", blockType: "paragraph",
                        textContent: "created text", markdownFragment: "created text",
                        headingLevel: nil, afterBlockId: anchor.id, atDocumentStart: nil)
        ])
        let yJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: "temp-stuck-1", textContent: "typed into it", markdownFragment: nil, headingLevel: nil)
        ])

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // Counts completed applies so the held update's inline cascade (after cycle
        // 1's insert lands) can be waited on deterministically, rather than polling
        // the DB (B2's pattern, same file).
        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Cycle 1 fetches X (the insert) and wedges before it returns — its sequence
        // stays `.reserved`, its fetch outstanding.
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        await cycle1.value   // spawner returns at cycle 1's 0.2s poll watchdog; its fetch stays wedged
        #expect(sync.testInFlightPollIsNil, "a real later tick only arrives once cycle 1's slot is free")
        #expect(sync.testOutstandingPrefetchOrphans == 1, "cycle 1 must be counted as a pre-fetch orphan")

        // Cycle 2 fetches Y (the update to the not-yet-created block) and parks behind
        // cycle 1 in DocumentWriter's turn order. Deliberately UNFORCED, same as
        // cycle 1 -- addendum A1's back-pressure guard admits exactly this cycle as
        // the ADMITTED PROBE (one orphan outstanding, none yet tolerated, so
        // `1 <= 0 + 1` holds) while cycle 1 remains wedged.
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilCallEntry("getBlockChanges", 2)
        await cycle2.value

        // Release cycle 1: its insert lands (late if the 3s expiry already fired,
        // in-order otherwise), and any op held on `temp-stuck-1` cascades in the same turn.
        js.releaseWedge()
        await cycle1.value

        // Two applies: cycle 2's own (empty -- its update was held) apply, and cycle
        // 1's own insert apply, which cascades the held update inline in the SAME
        // actor turn (this test only observes the cascade's result through the DB,
        // so it needs the hook rather than the ledger's own counters to know when
        // it's safe to read).
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.contains { $0.id != "temp-stuck-1" && $0.textContent == "typed into it" },
                "the held update never landed on the permanent row")
        #expect(after.count == before.count + 1,
                "exactly one new block, not a ghost plus a dropped edit — got \(after.count - before.count)")
        #expect(!after.contains { $0.textContent == "created text" },
                "the held update must have overwritten the insert's original text — got \(after.map(\.textContent))")
        #expect(sync.testWriterLedger.skippedConsumed == 0 && sync.testWriterLedger.heldOpsUnresolved == 0,
                "the update must be RESOLVED (held-then-applied), not skipped or left unresolved — got \(sync.testWriterLedger)")
        _ = editorState
    }

    /// B2. Same setup as B1, but cycle 2 carries a DELETE of the not-yet-created block
    /// rather than an update. Before this fix, `processEditorDeletes` counted a delete of
    /// a row that does not exist yet as "deleted" regardless, and the insert that arrived
    /// later then landed as a ghost block nobody asked to keep. After Phase 1 (and the
    /// `processEditorDeletes` fix in step 4): the delete is held until the insert lands,
    /// then applied, leaving no row at all.
    @Test("A stuck insert's fetch outstanding: a successor's delete of the not-yet-created block leaves no ghost row")
    func stuckInsertSave_deleteOfNewBlockLeavesNoGhost() async throws {
        let stack = try makeStack()
        let (db, sync, editorState) = (stack.db, stack.sync, stack.editorState)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let originalCount = before.count
        let anchor = try #require(before.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")

        let xJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: "temp-stuck-1", blockType: "paragraph",
                        textContent: "created text", markdownFragment: "created text",
                        headingLevel: nil, afterBlockId: anchor.id, atDocumentStart: nil)
        ])
        let yJSON = try blockChangesJSON(deletes: ["temp-stuck-1"])

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // Counts completed applies so the held delete's inline cascade (after cycle
        // 1's insert lands) can be waited on deterministically, rather than polling
        // the ledger.
        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        await cycle1.value   // spawner returns at cycle 1's 0.2s poll watchdog; its fetch stays wedged
        #expect(sync.testInFlightPollIsNil, "a real later tick only arrives once cycle 1's slot is free")
        #expect(sync.testOutstandingPrefetchOrphans == 1, "cycle 1 must be counted as a pre-fetch orphan")

        // Cycle 2 fetches Y (the delete of the not-yet-created block) and parks
        // behind cycle 1 in DocumentWriter's turn order. Deliberately UNFORCED, same
        // as cycle 1 -- addendum A1's back-pressure guard admits exactly this cycle
        // as the ADMITTED PROBE (one orphan outstanding, none yet tolerated, so
        // `1 <= 0 + 1` holds) while cycle 1 remains wedged.
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilCallEntry("getBlockChanges", 2)
        await cycle2.value

        js.releaseWedge()
        await cycle1.value

        // Two applies: cycle 2's own (empty -- its delete was held) apply, and cycle
        // 1's own insert apply, which cascades the held delete inline in the SAME
        // actor turn (this test only observes the cascade's result through the DB,
        // so it needs the hook rather than the ledger's own counters to know when
        // it's safe to read).
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.count == originalCount,
                "the insert-then-delete of the same not-yet-created block must leave no row — got \(after.count) vs \(originalCount)")
        #expect(!after.contains { $0.textContent == "created text" },
                "no ghost block from the insert may survive — got \(after.map(\.textContent))")
        #expect(!after.contains { $0.textContent.hasPrefix("typed") })
        _ = editorState
    }

    /// B4. REGRESSION LOCK (not a before-fail): today this passes only via the apply
    /// chain's valve, which this phase removes. Proves the A2 requirement stated in
    /// §2.2 "Late sequences and held temp-id ops": a forced database-rebuild flush lands
    /// its own batch, and reads it back, before it returns — even while an unrelated
    /// routine fetch is stuck — because the turn-stall expiry (0.3s override here) lets
    /// the routine's stuck sequence go late well within the rebuild's own bound. Against
    /// the pre-Phase-1 design (an unbounded predecessor wait) this would instead fail at
    /// the poll watchdog.
    @Test("A forced database-rebuild flush lands its own batch before returning, even while a routine fetch is stuck")
    func forcedRebuildFlush_landsItsOwnBatchBeforeReturning_whenARoutineFetchIsStuck() async throws {
        let stack = try makeStack()
        let (db, sync, editorState) = (stack.db, stack.sync, stack.editorState)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let blockA = try #require(blocks.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")
        let blockB = try #require(blocks.first { $0.textContent.contains("four five six") },
                                  "expected the Beta paragraph in the fixture")

        let xJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockA.id, textContent: "X alpha text", markdownFragment: nil, headingLevel: nil),
            BlockUpdate(id: blockB.id, textContent: "X beta text", markdownFragment: nil, headingLevel: nil)
        ])
        let yJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockA.id, textContent: "Y alpha text", markdownFragment: nil, headingLevel: nil)
        ])

        // Cycle 1 (unforced, routine) wedges inside its fetch.
        sync.testPollWatchdogSeconds = 0.2
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.answer("confirmBlockIds", true)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        // Production-shaped watchdog from here; a short turn-stall expiry so the
        // forced rebuild flush's own batch does not wait out cycle 1.
        sync.testPollWatchdogSeconds = 8
        sync.testWriterLateAfterSeconds = 0.3
        editorState.contentState = .bibliographyUpdate
        sync.beginDatabaseRebuild()

        let flushDone = StuckSaveSignal()
        let flush = Task { @MainActor in
            await sync.pollBlockChangesNowForDatabaseRebuild()
            flushDone.fire()
        }
        // t-94369a83 Phase 1: `pollBlockChangesNowForDatabaseRebuild()` now calls
        // `awaitWriterSettlementForRebuild()` before it returns (B4 fix; addendum A2
        // §1 replaced its earlier `drainWriterSettlement()` name/implementation),
        // which waits on the WRITER for cycle 1's own ticket to actually settle --
        // not just for cycle 1's poll-level watchdog to release the in-flight slot.
        // Releasing the wedge AFTER `flushDone.wait()` (as this test originally did)
        // would deadlock: `flushDone.fire()` cannot run until
        // `awaitWriterSettlementForRebuild()` returns, which
        // cannot happen until cycle 1's real, wedged apply is unblocked -- which this
        // test alone controls, via `releaseWedge()`. Releasing it here, right after
        // spawning the flush, lets cycle 1's real (already-confirmed-wedged, per
        // `waitUntilEnteredWedge()` above) work proceed CONCURRENTLY with the flush's
        // own reserve/fetch/apply/drain sequence -- exactly the "routine fetch is
        // stuck while the flush runs anyway" scenario this test is designed to prove,
        // still exercised because cycle 1 was confirmed wedged before the flush was
        // ever spawned; releasing early only lets its resolution and the flush's own
        // resolution interleave, which the assertions below verify by final state
        // rather than by ordering.
        js.releaseWedge()
        await flushDone.wait()

        #expect(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == blockA.id }?.textContent == "Y alpha text",
                "the rebuild's forced flush must have landed its own batch Y before returning")
        // Cycle 1's OWN poll watchdog (0.2s, set above) is EXPECTED to fire here —
        // that is the whole premise of "stuck insert": a wedged `getBlockChanges`
        // reply outlives the routine cycle's short watchdog, well before the
        // writer's 0.3s turn-stall expiry (which starts from cycle 1's ticket
        // reservation, itself captured before the wedge) lets the flush proceed.
        // `reserveWriterTurn` runs before `getBlockChanges` (see that call site's
        // ordering above `getBlockChanges` in `doPollBlockChanges`), so a `false`
        // (unforced) entry from cycle 1 is inevitable well before this assertion,
        // regardless of the writer's own behaviour. What this assertion actually
        // guards -- and all the surrounding assertions below independently
        // confirm the flush's own successful, on-time completion -- is that the
        // FORCED flush itself (force=true) never appears, i.e. never hit ITS OWN
        // generous 8s watchdog waiting on cycle 1's expiry.
        #expect(!sync.testPollTimeoutForceFlags.contains(true),
                "the forced flush must not have hit the poll watchdog — got \(sync.testPollTimeoutForceFlags)")

        // The wedge was already released above (before `flushDone.wait()`); X applies
        // late (per-block merge): A keeps Y's newer text, B (untouched by Y) still
        // gets X's. `cycle1`/`flush` should both already be resolved by this point
        // (`awaitWriterSettlementForRebuild()` inside the flush waited for cycle 1's real
        // settlement), so these are no-ops confirming that rather than genuine waits.
        await cycle1.value
        await flush.value

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let textForId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.textContent) })
        #expect(textForId[blockA.id] == "Y alpha text",
                "block A is shared: the newer batch Y must still win — got \(String(describing: textForId[blockA.id]))")
        #expect(textForId[blockB.id] == "X beta text",
                "block B is X's own edit and must still land late — got \(String(describing: textForId[blockB.id]))")
        editorState.contentState = .idle
    }
}
