//
//  BlockSyncPollWatchdogTests+WriterDrain.swift
//  final finalTests
//
//  t-94369a83 Phase 1 ("writer foundation", plan §2.5 step 7). Split out of
//  BlockSyncPollWatchdogTests.swift for the same file/type-length reasons as the
//  other `+`-suffixed extensions in this suite -- see that file's header for the
//  shared scripted-JS-evaluator design. Same-suite context: inherits `.serialized`
//  and shares `blockChangesJSON` and `ScriptedJSEvaluator`.
//
//  B3 proves the lifecycle's NEW bound on the writer (§2.3): a poll cycle whose fetch is wedged
//  reserved its place in the writer's queue and will never apply or settle it, and a close must not
//  wait on that forever -- it gives up after a bound, counts the sequence as skipped (never fetched)
//  and the batch must never land later.
//
//  PORTED (t-94369a83 Phase 3a-1b, round C7b): B3 used to prove this for `stopPollingAndDrain()`'s bounded
//  writer drain (`DocumentWriter.drainTimeoutSeconds`, here overridden short). That method has since been
//  deleted: close, switch and quit save through the lifecycle sequence, and the unkeyed Getting Started close
//  calls only `stopPolling()`. The bound the sequence puts on the writer is the WRITER
//  BARRIER's timeout (`BarrierHandle.wait(timeout:)`, step 8 of the save sequence), which skips the editor
//  sequences below it the same way and counts them in the same ledger. So B3 now enters through the close's
//  save sequence (`LifecycleFlushHarness.run(.close)`: `EditorViewState.runLifecycleFlush`, the part of
//  `LifecycleEntry.run(.close)` before `perform`) on scaled-down bounds, and keeps its three assertions:
//  the close returns well inside its bound, the never-fetched sequence is counted `skippedUnfetched == 1`
//  (not `skippedConsumed`: that bucket is for a sequence whose batch already reached Swift before the writer
//  gave up on it; see §2.2 "Skip"), and the database never shows the stuck edit, even once the wedge finally
//  releases. The `.drainTimedOut` writer event of the old drain is the barrier's `.timedOut` outcome here.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@MainActor
extension BlockSyncPollWatchdogTests {

    /// B3. A routine cycle's fetch is wedged (never returns), well past its own poll watchdog (0.2s, so the
    /// in-flight slot frees quickly). The close's save sequence (production bounds scaled to 0.1: 1.5s in all)
    /// must still return inside that bound, its writer barrier must report that it gave up on exactly that one
    /// never-fetched sequence (`.timedOut`, one editor sequence skipped, none of them already fetched), and the
    /// writer must count it `skippedUnfetched == 1`, not `skippedConsumed`: because `getBlockChanges` itself never
    /// returns, the reserved sequence's contents are genuinely unknown to the writer. The DB must never show the
    /// stuck edit -- releasing the wedge afterwards must not retroactively write anything.
    @Test("a close bounds the writer wait: a never-fetched batch is skipped, not waited out forever")
    func close_boundsTheWriterWait_onStuckFetch() async throws {
        let rig = try LifecycleFlushHarness()
        let before = try rig.blocks()
        let target = try #require(before.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")

        let staleJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "stuck edit", markdownFragment: nil, headingLevel: nil)
        ])
        let js = rig.js
        js.answer("hasBlockChanges", true)
        js.answer("flushPendingBlockChanges", true)
        // The FIRST `getBlockChanges` call (cycle 1's) wedges and, once released, answers the stuck edit; any later
        // call (the save sequence's own forced poll, if the drain did not end at the watchdog) answers nothing, so
        // the stuck edit can only ever reach the database through the wedged sequence this test is about.
        js.answer("getBlockChanges", staleJSON, try blockChangesJSON())
        js.wedgeOn("getBlockChanges")
        rig.sync.testPollWatchdogSeconds = 0.2

        // Cycle 1 reserves its turn, then wedges inside getBlockChanges -- never fetched, never applied.
        let sync = rig.sync
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        let bounds = LifecycleBounds.production.scaled(0.1)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await rig.run(.close, bounds: bounds)
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(bounds.closeTotal + 1.5),
                "the close's writer wait must be bounded by its own deadline (\(bounds.closeTotal)s) -- took \(elapsed)")

        if case .waited(.timedOut(let skippedEditorSeqs, let skippedFetched)) = result.barrier {
            #expect(skippedEditorSeqs.count == 1, "exactly the wedged cycle's sequence is skipped -- got \(skippedEditorSeqs)")
            #expect(skippedFetched == 0, "its batch never reached Swift, so none of it was fetched")
        } else {
            Issue.record("expected the barrier wait to time out on the wedged sequence, got \(result.barrier)")
        }
        #expect(rig.sync.testWriterLedger.skippedUnfetched == 1,
                "the still-wedged fetch's contents are unknown to the writer — got \(rig.sync.testWriterLedger)")

        // Release the wedge afterward: it must not retroactively write anything --
        // the sequence was already skipped by the barrier's timeout.
        js.releaseWedge()
        await cycle1.value

        let after = try rig.blocks()
        #expect(!after.contains { $0.textContent == "stuck edit" },
                "a batch skipped by the barrier's timeout must never land, even once its wedge finally releases")
    }
}
