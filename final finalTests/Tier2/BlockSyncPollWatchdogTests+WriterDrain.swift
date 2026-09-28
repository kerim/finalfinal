//
//  BlockSyncPollWatchdogTests+WriterDrain.swift
//  final finalTests
//
//  t-94369a83 Phase 1 ("writer foundation", plan §2.5 step 7). Split out of
//  BlockSyncPollWatchdogTests.swift for the same file/type-length reasons as the
//  other `+`-suffixed extensions in this suite -- see that file's header for the
//  shared scripted-JS-evaluator design. Same-suite context: inherits `.serialized`
//  and shares `makeStack`, `ScriptedJSEvaluator`, `blockChangesJSON`, `TestStack`.
//
//  B3 proves `stopPollingAndDrain()`'s NEW bound (§2.3): after the (unchanged) poll
//  drain returns, it also waits at most `DocumentWriter.drainTimeoutSeconds` (here
//  overridden short) for the writer, then gives up rather than waiting on a
//  genuinely wedged fetch forever. `WriterEventSignal` (defined in
//  DocumentWriterTests.swift) is reused here because `testWriterEventHandler`'s
//  closure is `@Sendable` and is not guaranteed to fire on MainActor.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@MainActor
extension BlockSyncPollWatchdogTests {

    /// B3. A routine cycle's fetch is wedged (never returns), well past both its own
    /// poll watchdog (0.2s, so the in-flight slot frees quickly) and the writer's
    /// lifecycle drain timeout (0.3s, overridden short here from the 2.0s
    /// production default). `stopPollingAndDrain()` must still return promptly
    /// (well under the production 2s bound), the writer must log/count the skip
    /// (`.drainTimedOut` event). Because `getBlockChanges` itself never returns,
    /// the reserved sequence's contents are genuinely unknown to the writer --
    /// `ledger.skippedUnfetched == 1`, not `skippedConsumed` (that bucket is for a
    /// sequence whose batch already reached Swift before the drain gave up on it;
    /// see §2.2 "Skip"). The DB must be unchanged -- releasing the wedge afterwards
    /// must not retroactively write anything.
    @Test("stopPollingAndDrain() bounds the writer drain: a never-fetched batch is skipped, not waited out forever")
    func stopPollingAndDrain_boundsWriterDrain_onStuckFetch() async throws {
        let stack = try makeStack()
        let (db, sync, editorState) = (stack.db, stack.sync, stack.editorState)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let target = try #require(before.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")

        let staleJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "stuck edit", markdownFragment: nil, headingLevel: nil)
        ])
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", staleJSON)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        sync.testPollWatchdogSeconds = 0.2
        sync.testWriterDrainTimeoutSeconds = 0.3

        let drainTimedOut = WriterEventSignal(matching: {
            if case .drainTimedOut = $0 { return true }; return false
        })
        sync.testWriterEventHandler = { event in drainTimedOut.note(event) }

        // Cycle 1 reserves its turn, then wedges inside getBlockChanges -- fetched
        // but never applied.
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        let clock = ContinuousClock()
        let start = clock.now
        await sync.stopPollingAndDrain()
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(2),
                "the writer drain must bound this well under the production 2s default — took \(elapsed)")
        await drainTimedOut.wait()
        #expect(sync.testWriterLedger.skippedUnfetched == 1,
                "the still-wedged fetch's contents are unknown to the writer — got \(sync.testWriterLedger)")

        // Release the wedge afterward: it must not retroactively write anything --
        // the sequence was already skipped by the drain.
        js.releaseWedge()
        await cycle1.value

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(!after.contains { $0.textContent == "stuck edit" },
                "a batch skipped by the drain must never land, even once its wedge finally releases")
        _ = editorState
    }
}
