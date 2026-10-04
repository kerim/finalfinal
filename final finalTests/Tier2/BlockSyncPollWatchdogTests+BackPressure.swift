//
//  BlockSyncPollWatchdogTests+BackPressure.swift
//  final finalTests
//
//  Addendum A1 (t-94369a83, Phase 1 "writer foundation"): the M3/A5 back-pressure
//  guard used to refuse EVERY unforced tick outright for as long as ANY
//  watchdog-timed-out orphan remained outstanding (`outstandingPrefetchOrphans ==
//  0`). That was fine under the pre-Phase-1 apply-chain design (a wedged content
//  process's own eventual reply would apply everything pending, in one burst), but
//  under Phase 1 the writer -- not "the orphan eventually replies" -- owns ordering,
//  and a successor's op can only be `.held` behind a stuck predecessor if some cycle
//  actually reaches the writer. A bare `== 0` guard made that structurally
//  unreachable for two ordinary, periodic (unforced) ticks against a content
//  process that never replies again: see BlockSyncPollWatchdogTests+StuckSave.swift's
//  B1/B2, which reproduced exactly this hang before this addendum.
//
//  The fix, tested here: admit a BOUNDED number of further unforced cycles as
//  PROBES while orphans are outstanding, gated on the content process having
//  RECENTLY proven itself responsive (`orphansToleratedWhileResponsive`), with a
//  hard ceiling (`maxOutstandingPrefetchOrphans`) regardless of tolerance. See
//  `BlockSyncService.outstandingPrefetchOrphans`/`orphansToleratedWhileResponsive`/
//  `maxOutstandingPrefetchOrphans`'s own doc comments for the full mechanism.
//
//  Same-suite context: an extension of `BlockSyncPollWatchdogTests` (Tier 2), so
//  these inherit `.serialized` and `.timeLimit(.minutes(1))` from that suite's
//  `@Suite` line, and share `makeStack` (0.2s poll watchdog), `blockChangesJSON`,
//  `TestStack`, `CountGate` with the rest of it. `StartSignal`/`waitUntil` are
//  `private` to the base file, so this file keeps its own copies, same precedent as
//  BlockSyncPollWatchdogTests+StuckSave.swift's `StuckSaveSignal`.
//
//  `PatternedJSEvaluator` (below) is a SEPARATE, purpose-built evaluator, not a
//  reuse or modification of the shared `ScriptedJSEvaluator`: these tests need an
//  arbitrary per-call wedge PATTERN (e.g. "every odd-numbered `getBlockChanges`
//  call"), not `ScriptedJSEvaluator`'s one-shot "the first matching call wedges."
//

import Foundation
import Testing
import WebKit
@testable import final_final

/// Bounded `Task.yield` spin until `condition` holds. File-scoped copy of the base
/// file's private `waitUntil`; the suite's `.timeLimit(.minutes(1))` is the
/// backstop.
@MainActor
@discardableResult
private func backPressureWaitUntil(_ condition: @MainActor () -> Bool, iterations: Int = 200_000) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Stands in for the poll path's four `webView.evaluateJavaScript` calls, same
/// script-substring matching as `ScriptedJSEvaluator`, but with an arbitrary
/// per-call wedge PATTERN instead of a one-shot first-match wedge: `shouldWedge`
/// is consulted with the call's 1-based index for its own key, and every call for
/// which it answers `true` parks on its own continuation in `parkedContinuations`
/// until `releaseAll()` resumes every parked call at once. Answers are keyed by
/// script substring exactly like `ScriptedJSEvaluator`; the last entry in a key's
/// answer list repeats for every further call past the end of the list.
@MainActor
private final class PatternedJSEvaluator {
    private var answers: [String: [Any?]] = [:]
    private var callCounts: [String: Int] = [:]
    private var parkedContinuations: [CheckedContinuation<Void, Never>] = []

    /// Consulted with (key, 1-based call index FOR THAT KEY) for every call this
    /// evaluator sees. Defaults to never wedging.
    var shouldWedge: (String, Int) -> Bool = { _, _ in false }

    func answer(_ key: String, _ values: Any?...) {
        answers[key] = values.isEmpty ? [nil] : values
    }

    func callCount(_ key: String) -> Int { callCounts[key] ?? 0 }

    func evaluate(_ script: String) async throws -> Any? {
        guard let key = Self.matchKey(for: script) else { return nil }
        let index = (callCounts[key] ?? 0) + 1
        callCounts[key] = index

        if shouldWedge(key, index) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedContinuations.append(continuation)
            }
        }

        let values = answers[key] ?? [nil]
        return values[min(index - 1, values.count - 1)]
    }

    /// Resumes every call currently parked on a wedge, all at once. One-shot per
    /// call to `releaseAll()` -- calls wedged AFTER this returns (a later cycle's
    /// own wedge) park on a fresh continuation and need their own `releaseAll()`.
    func releaseAll() {
        let continuations = parkedContinuations
        parkedContinuations = []
        for continuation in continuations { continuation.resume() }
    }

    private static func matchKey(for script: String) -> String? {
        if script.contains("hasBlockChanges") { return "hasBlockChanges" }
        if script.contains("getBlockChanges") { return "getBlockChanges" }
        if script.contains("flushPendingBlockChanges") { return "flushPendingBlockChanges" }
        if script.contains("confirmBlockIds") { return "confirmBlockIds" }
        return nil
    }
}

@MainActor
extension BlockSyncPollWatchdogTests {

    /// BP1. `hasBlockChanges` itself wedges every call -- the content process never
    /// even answers the cheap pre-check. Cycle 1 becomes the first orphan; cycle 2
    /// is admitted as the one tolerated PROBE (`1 <= 0 + 1`); cycle 3 is refused
    /// (`2 <= 0 + 1` is false, since no fetch has ever succeeded to raise the
    /// tolerance). Releasing both wedged calls lets both orphans clear, and a later
    /// cycle 4 is freshly admitted (and wedges again, on its own new call).
    @Test("A wedged editor pauses periodic polling after one probe")
    func wedgedEditor_pausesPollingAfterOneProbe() async throws {
        let stack = try makeStack()
        let sync = stack.sync

        let js = PatternedJSEvaluator()
        js.answer("hasBlockChanges", false)
        js.shouldWedge = { key, _ in key == "hasBlockChanges" }
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // Cycle 1: becomes the first orphan.
        await sync.pollBlockChangesForTest(force: false)
        #expect(sync.testOutstandingPrefetchOrphans == 1)

        // Cycle 2: the one admitted PROBE (`1 <= 0 + 1`).
        await sync.pollBlockChangesForTest(force: false)
        #expect(js.callCount("hasBlockChanges") == 2)
        #expect(sync.testOutstandingPrefetchOrphans == 2)

        // Cycle 3: refused outright (`2 <= 0 + 1` is false) -- never reaches the JS
        // bridge at all, so the call count does not move.
        await sync.pollBlockChangesForTest(force: false)
        #expect(js.callCount("hasBlockChanges") == 2)
        #expect(sync.testOutstandingPrefetchOrphans == 2)

        js.releaseAll()
        try #require(await backPressureWaitUntil { sync.testOutstandingPrefetchOrphans == 0 })

        // Cycle 4: freshly admitted now that both orphans have cleared -- and it
        // wedges too, on its own new call.
        await sync.pollBlockChangesForTest(force: false)
        #expect(js.callCount("hasBlockChanges") == 3)

        js.releaseAll()
        try #require(await backPressureWaitUntil { sync.testOutstandingPrefetchOrphans == 0 })
    }

    /// BP2. `getBlockChanges` wedges only on its very first call (a single lost
    /// reply, not a permanently stuck process) -- cycle 1's insert-free update to
    /// block A (X) is the one that's lost; cycles 2 and 3 (admitted as the probe,
    /// then normally once the tolerance covers it) land Y and Z, proving a single
    /// stuck save does not stop LATER periodic saves from reaching the writer.
    @Test("A single lost reply does not stop later periodic saves")
    func singleLostReply_doesNotStopLaterPeriodicSaves() async throws {
        let stack = try makeStack()
        let (db, sync) = (stack.db, stack.sync)

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let blockA = try #require(blocks.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")
        let blockB = try #require(blocks.first { $0.textContent.contains("four five six") },
                                  "expected the Beta paragraph in the fixture")

        let xJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockA.id, textContent: "X text (lost)", markdownFragment: nil, headingLevel: nil)
        ])
        let yJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockA.id, textContent: "Y text", markdownFragment: nil, headingLevel: nil)
        ])
        let zJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockB.id, textContent: "Z text", markdownFragment: nil, headingLevel: nil)
        ])

        let js = PatternedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", xJSON, yJSON, zJSON)
        js.shouldWedge = { key, index in key == "getBlockChanges" && index == 1 }
        sync.testJSEvaluator = { try await js.evaluate($0) }

        sync.testWriterLateAfterSeconds = 0.3
        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Cycle 1: wedges on its own first `getBlockChanges` call, becoming the
        // first orphan; its reserved sequence stays open, still unfetched.
        await sync.pollBlockChangesForTest(force: false)
        #expect(sync.testOutstandingPrefetchOrphans == 1)

        // Cycle 2: admitted as the probe (`1 <= 0 + 1`); its OWN fetch (call #2)
        // does not wedge, so it reaches the writer, parks behind cycle 1, and lands
        // once cycle 1's turn-stall expiry (0.3s) lets the frontier advance.
        await sync.pollBlockChangesForTest(force: false)
        await applies.waitFor(1)
        #expect(sync.testOrphansToleratedWhileResponsive == 1)

        // Cycle 3: the tolerance cycle 2 raised now covers it (`1 <= 1 + 1`); its
        // fetch (call #3) lands immediately -- the frontier is already past its own
        // sequence by the time it parks.
        await sync.pollBlockChangesForTest(force: false)
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let textForId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.textContent) })
        #expect(textForId[blockA.id] == "Y text",
                "Y must win on block A -- got \(String(describing: textForId[blockA.id]))")
        #expect(textForId[blockB.id] == "Z text",
                "Z must land on block B -- got \(String(describing: textForId[blockB.id]))")
        #expect(sync.testOutstandingPrefetchOrphans == 1, "cycle 1's own orphan claim is still outstanding")

        js.releaseAll()
        try #require(await backPressureWaitUntil { sync.testOutstandingPrefetchOrphans == 0 })
    }

    /// BP3. `hasBlockChanges` always answers promptly and truthfully, but EVERY
    /// `getBlockChanges` call wedges -- the content process is genuinely,
    /// permanently stuck on the heavier call specifically. Proves responsiveness
    /// must be recorded from `getBlockChanges` returning, not from `hasBlockChanges`
    /// answering: a design that recorded tolerance from the cheap pre-check would
    /// see this process as "responsive" every single cycle and admit unlimited
    /// probes, never actually reaching orphans==2 as asserted below.
    @Test("A fetch that always wedges pauses polling even while the change check answers")
    func alwaysWedgedFetch_pausesPollingDespiteResponsiveChangeCheck() async throws {
        let stack = try makeStack()
        let sync = stack.sync

        let js = PatternedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.shouldWedge = { key, _ in key == "getBlockChanges" }
        sync.testJSEvaluator = { try await js.evaluate($0) }

        for _ in 1...5 {
            await sync.pollBlockChangesForTest(force: false)
            #expect(sync.testOutstandingPrefetchOrphans <= 2,
                    "back-pressure must cap orphans even though hasBlockChanges keeps answering")
        }

        #expect(js.callCount("getBlockChanges") == 2,
                "only cycle 1 and the one admitted probe (cycle 2) should ever reach getBlockChanges")
        #expect(sync.testOrphansToleratedWhileResponsive == 0,
                "hasBlockChanges answering is not responsiveness -- getBlockChanges never once returned")

        js.releaseAll()
        try #require(await backPressureWaitUntil { sync.testOutstandingPrefetchOrphans == 0 })
    }

    /// BP4. `getBlockChanges` wedges on every ODD call and answers an empty batch
    /// (still a real, responsive return -- just nothing to apply) on every EVEN
    /// call -- repeated, ISOLATED lost replies from a process that keeps proving
    /// itself alive in between, rather than one continuous stuck stretch. Each
    /// alternating pair raises the tolerance by one and admits one more orphan,
    /// until the hard ceiling (`maxOutstandingPrefetchOrphans == 4`) refuses
    /// further probes regardless of how recently the process proved responsive.
    @Test("Repeated isolated lost replies stop at the hard ceiling")
    func repeatedIsolatedLostReplies_stopAtHardCeiling() async throws {
        let stack = try makeStack()
        let sync = stack.sync

        let js = PatternedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", try blockChangesJSON())   // empty batch; last entry repeats
        js.shouldWedge = { key, index in key == "getBlockChanges" && index % 2 == 1 }
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // Cycles 1-7: wedge, tolerance-set, wedge, tolerance-set, wedge,
        // tolerance-set, wedge -- orphans climbs to 4 (one per odd/wedged cycle),
        // tolerance climbs to 3 (one per even/empty-but-responsive cycle, always
        // one behind the still-outstanding wedged orphans).
        for _ in 1...7 {
            await sync.pollBlockChangesForTest(force: false)
        }
        #expect(sync.testOutstandingPrefetchOrphans == 4)
        #expect(sync.testOrphansToleratedWhileResponsive == 3)

        // Cycle 8 would satisfy the tolerance check (`4 <= 3 + 1`) but is refused by
        // the hard ceiling (`4 < 4` is false) -- neither the call count nor the
        // orphan count moves.
        await sync.pollBlockChangesForTest(force: false)
        #expect(js.callCount("getBlockChanges") == 7)
        #expect(sync.testOutstandingPrefetchOrphans == 4)

        js.releaseAll()
        try #require(await backPressureWaitUntil { sync.testOutstandingPrefetchOrphans == 0 })
    }
}
