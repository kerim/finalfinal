//
//  BlockSyncPollWatchdogTests.swift
//  final finalTests
//
//  Tier 2: the poll watchdog (t-090cb580). Before this change, `runPollCycle`
//  raced the poll work against a fake 5s watchdog built on
//  `withThrowingTaskGroup` — but a task group's exit contract still awaits every
//  child, so a cycle wedged inside a bare `webView.evaluateJavaScript(...)` (which
//  does not observe Swift Task cancellation) held `inFlightPoll` forever and hung
//  any forced flush that drained it. The watchdog is now two independent,
//  UNSTRUCTURED tasks (`raceWithTimeout(seconds:work:)`) whose loser is never
//  awaited, and the cycle's work task is created by `runPollCycle` itself so both
//  cancellation sites (the drain, and the watchdog) can reach it.
//
//  Swift Testing (not XCTest) and — crucially — a scripted JS evaluator rather
//  than a real WKWebView: the entire poll path's JavaScript goes through the
//  `testJSEvaluator` seam, so these tests need no run loop, no WebView load, and
//  no wall-clock settling. The only clocks that run are the two per-instance
//  overrides — the poll watchdog (`testPollWatchdogSeconds`) and, for the
//  valve-abandon path alone, the apply-chain valve (`testApplyChainWaitSeconds`) —
//  so no other concurrently running suite is affected
//  (`DiagnosticLogFile.swift:57-61` is the same reasoning for its own
//  instance-scoped test override). Timeout observation is an instance-scoped
//  handler (`testPollTimeoutHandler`), never the process-global `DebugLog.always`
//  sink: only T2 installs the sink, and only to assert the literal line text.
//
//  What is deliberately NOT here: any assertion on the timing of a
//  cancellation. Cancellation reaches the work task, but a task wedged inside a
//  bare `evaluateJavaScript` cannot be forced to finish (L5/L10 in the plan) —
//  that residual is named, not papered over.
//

import Foundation
import Testing
import WebKit
@testable import final_final

// MARK: - Scripted JS evaluator

// NOTE: `ScriptedJSEvaluator`, `CountGate`, `AlwaysLogCapture`, `TestStack`, `makeStack` and
// `blockChangesJSON` are internal, not private, because the epoch-barrier tests in
// BlockSyncPollWatchdogTests+EpochBarrier.swift (an extension of this suite, split out for
// SwiftLint's file/type length limits) share them. The rest stay private to this file.

/// Stands in for the four poll-path `webView.evaluateJavaScript` calls routed
/// through `BlockSyncService.evaluateJS(_:in:)`. Answers are keyed by a
/// substring of the script (the call's own name), so the match rules are
/// non-overlapping: "hasBlockChanges", "getBlockChanges",
/// "flushPendingBlockChanges" (which contains "BlockChanges" but not
/// "getBlockChanges"), "confirmBlockIds".
///
/// Ordered answers: each entry in `answers[key]` is consumed by one call, and the
/// LAST entry repeats for every further call (so a test can say "true, then
/// always true" with `["true"]`, or wedge on the first call and still let a later
/// cycle through).
///
/// `wedgeOn` parks the FIRST matching call on a checked continuation until
/// `releaseWedge()`, which is how these tests reproduce "WebKit never calls
/// back": the call has been entered (visible in `callCount`) and the cycle is
/// suspended inside it, exactly the shape the poll watchdog exists to bound.
@MainActor
final class ScriptedJSEvaluator {
    private var answers: [String: [Any?]] = [:]
    private var callCounts: [String: Int] = [:]
    private(set) var scripts: [String] = []

    private var wedgeKey: String?
    private var wedgeEntered = false
    private var wedgeEnteredContinuation: CheckedContinuation<Void, Never>?
    private var wedgeReleaseContinuation: CheckedContinuation<Void, Never>?
    private var wedgeReleased = false

    /// Installs the ordered answer list for `key`. The last entry repeats.
    func answer(_ key: String, _ values: Any?...) {
        // A18: `answer(key)` with no values used to store `[]`, and `evaluate` then
        // indexed `values[-1]` (a crash). An empty list now behaves like "no answer".
        answers[key] = values.isEmpty ? [nil] : values
    }

    /// Parks the FIRST call whose script matches `key` until `releaseWedge()`.
    /// One-shot by design: only the first match wedges.
    func wedgeOn(_ key: String) {
        wedgeKey = key
    }

    func callCount(_ key: String) -> Int { callCounts[key] ?? 0 }

    /// Suspends until `key` has been called at least `count` times.
    func waitUntilCallEntry(_ key: String, _ count: Int) async {
        while callCount(key) < count {
            await Task.yield()
        }
    }

    /// Suspends until this evaluator is actually parked inside its wedge.
    func waitUntilEnteredWedge() async {
        if wedgeEntered { return }
        await withCheckedContinuation { wedgeEnteredContinuation = $0 }
    }

    /// Releases the wedge; future calls pass straight through.
    func releaseWedge() {
        wedgeReleased = true
        wedgeReleaseContinuation?.resume()
        wedgeReleaseContinuation = nil
    }

    func evaluate(_ script: String) async throws -> Any? {
        scripts.append(script)
        guard let key = Self.matchKey(for: script) else { return nil }
        let index = callCounts[key] ?? 0
        callCounts[key] = index + 1

        if key == wedgeKey, !wedgeReleased {
            wedgeKey = nil
            wedgeEntered = true
            wedgeEnteredContinuation?.resume()
            wedgeEnteredContinuation = nil
            await withCheckedContinuation { wedgeReleaseContinuation = $0 }
        }

        let values = answers[key] ?? [nil]
        return values[min(index, values.count - 1)]
    }

    private static func matchKey(for script: String) -> String? {
        if script.contains("hasBlockChanges") { return "hasBlockChanges" }
        if script.contains("getBlockChanges") { return "getBlockChanges" }
        if script.contains("flushPendingBlockChanges") { return "flushPendingBlockChanges" }
        if script.contains("confirmBlockIds") { return "confirmBlockIds" }
        return nil
    }
}

// MARK: - Synchronization primitives

/// Counts completed applies (`testAfterApplyHook`) and lets a test await the nth.
/// `value` is readable so a test can assert that an abandoned cycle did NOT apply.
@MainActor
final class CountGate {
    private(set) var value = 0
    private var continuations: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func note() {
        value += 1
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for entry in continuations {
            if entry.target <= value {
                ready.append(entry.continuation)
            } else {
                pending.append(entry)
            }
        }
        continuations = pending
        for continuation in ready { continuation.resume() }
    }

    func waitFor(_ target: Int) async {
        if value >= target { return }
        await withCheckedContinuation { continuations.append((target, $0)) }
    }
}

/// Checked-continuation gate (no sleep) that holds a poll cycle deterministically
/// suspended from `testPollCycleHook` — the very top of the cycle — until the test
/// releases it. Same shape as BlockSyncProjectSwitchDrainTests' `SwitchGate`.
@MainActor
private final class HookGate {
    private var reached = false
    private var released = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Call from inside the poll cycle (via `testPollCycleHook`).
    func waitAtGate() async {
        reached = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    func open() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// MainActor-isolated one-shot signal; `wait()` returns immediately if already
/// fired. Same shape as BlockSyncProjectSwitchDrainTests' `StartSignal`.
@MainActor
private final class StartSignal {
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

/// Thread-safe collector for `DebugLog.alwaysSink`. The sink may be invoked from any
/// thread (the production code path is not MainActor-only), hence the lock and
/// `@unchecked Sendable`. Kept ONLY for T2's literal-line-text assertions (M5): tests
/// synchronize on instance-scoped seams (`testPollTimeoutHandler`), never on this
/// process-global sink.
final class AlwaysLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Bounded `Task.yield` spin until `condition` holds. Mirrors
/// `ScriptedJSEvaluator.waitUntilCallEntry`'s shape; the suite's `.timeLimit(.minutes(1))`
/// is the backstop if the condition never becomes true, and the return value lets the
/// caller turn that into a normal assertion failure rather than a hang.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, iterations: Int = 100_000) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

// MARK: - Stack

struct TestStack {
    let db: ProjectDatabase
    let pid: String
    let webView: WKWebView
    let sync: BlockSyncService
    let editorState: EditorViewState
}

@MainActor
func makeStack(content: String = "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
    throws -> TestStack {
    let db = try TestFixtureFactory.createTemporary(content: content)   // auto-registered
    let pid = try TestFixtureFactory.getProjectId(from: db)
    let webView = WKWebView()                                           // never loaded; retained here
    let sync = BlockSyncService()
    sync.configure(database: db, projectId: pid, webView: webView)      // isConfigured == true
    // Held strongly HERE and returned, because `BlockSyncService.editorState` is
    // `weak`: assigning a temporary (`sync.editorState = EditorViewState()`) lets
    // it deallocate immediately, the unforced `contentState == .idle` guard then
    // sees nil and returns before any JS call, and a test waiting on the wedge
    // waits forever. Same precedent as ZoomWordCountSyncTests.swift:457-458.
    let editorState = EditorViewState()                                 // .idle by default
    sync.editorState = editorState
    sync.testPollWatchdogSeconds = 0.2
    return TestStack(db: db, pid: pid, webView: webView, sync: sync, editorState: editorState)
}

/// Builds the JSON string `getBlockChanges()` would have returned for these updates.
/// Single-update batches with `markdownFragment`/`headingLevel` nil and inserts/deletes
/// empty keep `shouldRejectStaleSnapshot` (which early-returns unless deletes or inserts
/// are non-empty) off the path and never call `confirmBlockIds` — no temp→permanent ID
/// mapping to confirm. `inserts` is used only by the wire-contract test and the epoch-barrier
/// tests (BlockSyncPollWatchdogTests+EpochBarrier.swift).
func blockChangesJSON(updates: [BlockUpdate] = [], inserts: [BlockInsert] = []) throws -> String {
    let changes = BlockChanges(updates: updates, inserts: inserts, deletes: [])
    let data = try JSONEncoder().encode(changes)
    guard let json = String(data: data, encoding: .utf8) else {
        throw BlockChangesJSONError.notUTF8
    }
    return json
}

private enum BlockChangesJSONError: Error { case notUTF8 }

/// `.timeLimit(.minutes(1))` (M4/A11): a regression used to hang CI on an unbounded
/// `await`/`waitFor`/`waitUntil*`; it now fails the test instead.
@Suite("BlockSync poll watchdog — Tier 2", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BlockSyncPollWatchdogTests {

    /// T1. The defect at its simplest: an unforced cycle wedged inside a JS call
    /// must not hold the in-flight slot past the watchdog, and the cycle that runs
    /// afterwards must be a genuinely fresh one.
    @Test("Unforced cycle wedged in a JS call frees the in-flight slot at the watchdog, and the next cycle runs fresh")
    func unforcedWedgeFreesSlot_atWatchdog_andNextCycleRunsFresh() async throws {
        let stack = try makeStack()
        let (db, pid, webView, sync, editorState) = (stack.db, stack.pid, stack.webView, stack.sync, stack.editorState)

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", false)
        js.wedgeOn("hasBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // M5: synchronize on the INSTANCE-scoped handler, not on the process-global
        // `DebugLog.always` sink (A12). The flag is appended before the handler fires
        // (A13), so awaiting the signal is enough to read it.
        let timedOut = StartSignal()
        sync.testPollTimeoutHandler = { timedOut.fire() }

        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        await cycle1.value
        await timedOut.wait()

        #expect(sync.testPollTimeoutForceFlags == [false],
                "the watchdog must record exactly one unforced timeout — got \(sync.testPollTimeoutForceFlags)")
        #expect(sync.testInFlightPollIsNil,
                "the in-flight slot must be released at the watchdog even though the JS call never returned")

        js.releaseWedge()
        // The released orphan ends at its next pre-fetch checkpoint; its `defer` then
        // releases the M3 back-pressure claim. Unforced ticks are skipped while the
        // claim is outstanding, so wait for it before starting the fresh cycle —
        // otherwise this second cycle would be (correctly) skipped and the count
        // below would still be 1.
        let released = await waitUntil { sync.testOutstandingPrefetchOrphans == 0 }
        #expect(released,
                "the released orphan must release the back-pressure counter — got \(sync.testOutstandingPrefetchOrphans)")

        await sync.pollBlockChangesForTest(force: false)

        #expect(js.callCount("hasBlockChanges") == 2,
                "the second cycle must be a fresh one that really calls the editor — got \(js.callCount("hasBlockChanges"))")
        #expect(js.callCount("getBlockChanges") == 0,
                "both answers were false, so no batch was ever fetched")
        // A14: freeze the wire contract of the scripts this path issued.
        #expect(js.scripts.contains("window.FinalFinal.hasBlockChanges()"),
                "the checkForChanges wire script changed — got \(js.scripts)")
        // Not merely unused: the wedged first cycle's orphan hits its pre-fetch
        // `Task.checkCancellation()` (a timeout cancels it) and unwinds there, so it
        // cannot inflate the count either.
        #expect(sync.testPollTimeoutForceFlags == [false],
                "no SECOND timeout may be recorded once the wedge is released")
        _ = (db, pid, webView, editorState)
    }

    /// T2. A FORCED cycle gets the same bound, but its timeout must be observable:
    /// the unconditional line is the only signal a caller's edit was left out of
    /// the database (L8), and it must carry the force flag.
    ///
    /// Deliberately the ONE test that keeps installing `DebugLog.alwaysSink`, and only
    /// to assert the literal line text (M5). Its pass/fail does NOT depend on the sink
    /// for synchronization: the flag is appended and the line is emitted synchronously
    /// inside `runPollCycle`, so `await cycle.value` already guarantees both.
    @Test("Forced cycle wedged in a JS call returns at the watchdog and logs an unconditional timeout line carrying force=true")
    func forcedWedgeReturnsAtWatchdog_andLogsUnconditionalTimeoutWithForceFlag() async throws {
        let stack = try makeStack()
        let sync = stack.sync
        _ = stack.editorState

        let js = ScriptedJSEvaluator()
        js.answer("flushPendingBlockChanges", true)
        js.answer("hasBlockChanges", false)
        js.wedgeOn("hasBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }

        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: true) }
        await js.waitUntilEnteredWedge()
        await cycle.value

        #expect(sync.testPollTimeoutForceFlags == [true],
                "the forced cycle's timeout must be recorded with force=true — got \(sync.testPollTimeoutForceFlags)")
        #expect(sync.testInFlightPollIsNil,
                "a forced flush must no longer hold the in-flight slot forever")

        let timeouts = capture.captured.filter { $0.contains("[BlockSync] Poll cycle TIMED OUT") }
        #expect(timeouts.count == 1, "exactly one timeout line — got \(capture.captured)")
        #expect(timeouts.first?.contains("force=true") == true,
                "the timeout line must carry force=true — got \(String(describing: timeouts.first))")
        #expect(timeouts.first?.contains("FORCED FLUSH") == true,
                "a forced timeout must say plainly that its caller proceeded without its edit")
        // A14: this forced cycle ran both of its scripts.
        #expect(js.scripts.contains("window.FinalFinal.flushPendingBlockChanges(); true"),
                "the flushPendingJSChanges wire script changed — got \(js.scripts)")
        #expect(js.scripts.contains("window.FinalFinal.hasBlockChanges()"),
                "the checkForChanges wire script changed — got \(js.scripts)")

        js.releaseWedge()
    }

    /// T3. The batching hazard the apply chain exists for: cycle 1 times out while
    /// ALREADY HOLDING batch X (the JS side cleared its queues when it produced X,
    /// so X is consumed and must land), then cycle 2 fetches the newer batch Y.
    /// Fetch order — not cycle-start order — is what the chain serializes on, so X
    /// must land BEFORE Y: the shared block ends on Y's text, X's unique edit
    /// survives.
    ///
    /// M4/A11: `testApplyChainWaitSeconds` is pinned LONG (30s) so cycle 2 WAITS for
    /// cycle 1 instead of abandoning it — with the new 3s default, cycle 2's valve
    /// could otherwise expire and drop X, which is deliberately T4's scenario.
    ///
    /// M3/A5 interaction: cycle 1's wedge is INSIDE the fetch, so its batch has not
    /// been handed to Swift and it counts as an outstanding pre-fetch orphan, which
    /// pauses UNFORCED ticks. Cycle 2 is therefore driven forced — which is also the
    /// realistic caller (a forced flush arriving while an orphan holds a consumed
    /// batch) and is exactly the path that bypasses the back-pressure.
    @Test("Apply chain: a timed-out orphan that already holds batch X still writes X, and a later cycle's newer batch Y wins on shared block ids")
    func applyChain_orphanBatchXLandsBeforeNewerBatchY_onSharedBlockIds() async throws {
        let stack = try makeStack()
        let (db, pid, sync, editorState) = (stack.db, stack.pid, stack.sync, stack.editorState)

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

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true, true)
        js.answer("getBlockChanges", xJSON, yJSON)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        // M4/A11: keep cycle 2 waiting for cycle 1 rather than abandoning it.
        sync.testApplyChainWaitSeconds = 30

        // M5: instance-scoped timeout signal instead of the process-global sink.
        let timedOut = StartSignal()
        sync.testPollTimeoutHandler = { timedOut.fire() }

        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        // Cycle 1 fetches X and parks inside the fetch, holding chain node 1.
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        await cycle1.value
        await timedOut.wait()
        #expect(sync.testInFlightPollIsNil,
                "cycle 1's slot must be free while its orphan is still parked on the fetch")

        // Cycle 2 fetches the newer Y and parks on node 1 (or, with no chain at all,
        // applies Y immediately — see the final assertions).
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: true) }
        await js.waitUntilCallEntry("getBlockChanges", 2)
        await cycle2.value

        js.releaseWedge()
        await applies.waitFor(2)

        let after = try TestFixtureFactory.fetchBlocks(from: db)
        let textForId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.textContent) })

        #expect(textForId[blockA.id] == "Y alpha text",
                "block A is shared: the NEWER batch Y must win — got \(String(describing: textForId[blockA.id]))")
        #expect(textForId[blockB.id] == "X beta text",
                // swiftlint:disable:next line_length
                "block B is X's unique edit and was already consumed JS-side: the orphan's batch must still land — got \(String(describing: textForId[blockB.id]))")
        // A14: freeze the getBlockChanges wire script.
        #expect(js.scripts.contains("JSON.stringify(window.FinalFinal.getBlockChanges())"),
                "the getBlockChanges wire script changed — got \(js.scripts)")
        _ = (pid, blockA, blockB, editorState)
    }

    // swiftlint:disable line_length
    /// T4. The L6 valve-abandon path: a successor gives up on a wedged predecessor and
    /// marks it abandoned; when the predecessor finally resumes it MERGES its (older)
    /// batch per block — block A is shared with the successor's newer batch and keeps
    /// the successor's text, while block B, which only the predecessor touched, still
    /// lands — and a later cycle still applies normally.
    ///
    /// Only the VALVE fires in the interesting phase: the watchdog is lengthened to 30s
    /// for cycle 2 and the valve shortened to 0.05s, so cycle 2's apply is what proves
    /// the valve expired (not a timeout). Cycle 1 must first time out under a SHORT
    /// watchdog, because that is the only way its in-flight slot is freed while it is
    /// still parked on its fetch — otherwise no second cycle could start at all.
    @Test("Apply chain valve: a successor that gives up on a wedged predecessor abandons it, and the predecessor's batch is merged per block (shared ids keep the newer text, its own blocks still land) (L6)")
    // swiftlint:enable line_length
    func applyChainValveExpiry_abandonsWedgedPredecessor_whoseBatchIsMergedPerBlock() async throws {
        let stack = try makeStack()
        let (db, pid, sync, editorState) = (stack.db, stack.pid, stack.sync, stack.editorState)

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
        let zJSON = try blockChangesJSON(updates: [
            BlockUpdate(id: blockB.id, textContent: "Z beta text", markdownFragment: nil, headingLevel: nil)
        ])

        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", xJSON, yJSON, zJSON)
        js.wedgeOn("getBlockChanges")
        sync.testJSEvaluator = { try await js.evaluate($0) }

        let applies = CountGate()
        sync.testAfterApplyHook = { await applies.note() }

        let timedOut = StartSignal()
        sync.testPollTimeoutHandler = { timedOut.fire() }

        // Phase 1: cycle 1 must FREE the slot (so cycle 2 can start) while staying
        // parked on its fetch.
        sync.testPollWatchdogSeconds = 0.2
        let cycle1 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        await cycle1.value
        await timedOut.wait()
        #expect(sync.testInFlightPollIsNil,
                "cycle 1's slot must be free while its orphan is parked on the fetch")

        // Phase 2: from here only the VALVE may fire.
        sync.testPollWatchdogSeconds = 30
        sync.testApplyChainWaitSeconds = 0.05

        // Cycle 2 fetches Y, parks on cycle 1's node, and gives up on it. Forced:
        // cycle 1 is an outstanding pre-fetch orphan, which pauses unforced ticks.
        let cycle2 = Task { @MainActor in await sync.pollBlockChangesForTest(force: true) }
        await cycle2.value
        await applies.waitFor(1)

        let afterY = try TestFixtureFactory.fetchBlocks(from: db)
        let yText = Dictionary(uniqueKeysWithValues: afterY.map { ($0.id, $0.textContent) })
        #expect(yText[blockA.id] == "Y alpha text",
                "cycle 2 must still apply its own newer batch after abandoning cycle 1 — got \(String(describing: yText[blockA.id]))")

        // Release the abandoned predecessor and watch the MERGE: it resumes with X,
        // and the persisted (epoch, sequence) write guard drops only the id a newer
        // batch WROTE (block A — Y's) inside the write transaction, applying the rest
        // (block B, which only X touched). The sink is installed for just this window
        // to capture the unconditional merge line; the suite is `.serialized`, so no
        // sibling test's line can interleave in this window.
        //
        // This test is ALSO the end-to-end proof that `BlockSyncService` threads its
        // own real `fetchSequence` through to the DB write as the stamp's sequence
        // half (no hand-built stamp anywhere in it) — the merge counts below (merged=1
        // superseded=1) only come out right if the service's real stamps, not a stub,
        // drove the guard's per-row decision.
        let capture = AlwaysLogCapture()
        DebugLog.alwaysSink = { capture.append($0) }
        defer { DebugLog.alwaysSink = nil }
        js.releaseWedge()
        let merged = await waitUntil { sync.testOwnBatchAbandonCount == 1 }
        #expect(merged,
                "cycle 1 must observe that it was abandoned and merge its batch — got \(sync.testOwnBatchAbandonCount)")
        // The counter is now bumped AFTER the merged apply runs (it reads the write
        // transaction's own result) rather than before, but `waitUntil` above polls
        // until it is set either way, so wait for that extra apply the same way:
        // cycle 2's Y plus cycle 1's filtered X.
        await applies.waitFor(2)
        #expect(applies.value == 2,
                "the abandoned predecessor must apply its MERGED batch (block B only), not drop it — got \(applies.value) applies")
        DebugLog.alwaysSink = nil
        #expect(capture.captured.contains {
                    $0.contains("[BlockSync] apply chain: own batch arrived after a successor applied")
                        && $0.contains("merged=1") && $0.contains("superseded=1")
                },
                "the merge must be logged unconditionally with its counts — got \(capture.captured)")

        let afterX = try TestFixtureFactory.fetchBlocks(from: db)
        let xText = Dictionary(uniqueKeysWithValues: afterX.map { ($0.id, $0.textContent) })
        #expect(xText[blockA.id] == "Y alpha text",
                "block A is shared: Y's newer text must survive the late, abandoned X — got \(String(describing: xText[blockA.id]))")
        #expect(xText[blockB.id] == "X beta text",
                "block B is X's own edit and no newer batch wrote it: the merged batch must land it — got \(String(describing: xText[blockB.id]))")

        // A later cycle still lands: the chain is not wedged by the abandoned node.
        let released = await waitUntil { sync.testOutstandingPrefetchOrphans == 0 }
        #expect(released, "the abandoned orphan must release the back-pressure counter")
        let cycle3 = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await cycle3.value
        await applies.waitFor(3)
        let afterZ = try TestFixtureFactory.fetchBlocks(from: db)
        let zText = Dictionary(uniqueKeysWithValues: afterZ.map { ($0.id, $0.textContent) })
        #expect(zText[blockB.id] == "Z beta text",
                "a later cycle's batch must still land after the merge — got \(String(describing: zText[blockB.id]))")
        _ = (pid, editorState)
    }

    /// T5. The drain's side of the contract: `reconfigure(database:projectId:)` on
    /// an in-flight UNFORCED cycle must cancel it and return promptly, not wait out
    /// the watchdog. The 30s override is the discriminator — a drain that merely
    /// waits would still be parked when the assertions run (and the cycle's own JS
    /// calls would then really happen).
    @Test("A drain cancels an in-flight unforced cycle promptly, without waiting for the watchdog")
    func drainCancelsInFlightUnforcedCycle_promptly() async throws {
        let stack = try makeStack()
        let sync = stack.sync
        _ = stack.editorState
        // The watchdog cannot realistically fire here: its absence from the outcome
        // is the promptness signal.
        sync.testPollWatchdogSeconds = 30

        let js = ScriptedJSEvaluator()
        // True so that an UNcancelled variant would definitely reach the fetch,
        // making the zero-call assertions below sharp.
        js.answer("hasBlockChanges", true)
        sync.testJSEvaluator = { try await js.evaluate($0) }

        let gate = HookGate()
        sync.testPollCycleHook = { await gate.waitAtGate() }

        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await gate.waitUntilReached()

        let newDb = try TestFixtureFactory.createTemporary(content: "# Gamma\n\nseven eight nine.\n")
        let newPid = try TestFixtureFactory.getProjectId(from: newDb)

        let started = StartSignal()
        let drain = Task { @MainActor in
            started.fire()
            await sync.reconfigure(database: newDb, projectId: newPid)
        }
        await started.wait()
        // By the same MainActor-seriality argument BlockSyncProjectSwitchDrainTests
        // uses: reconfigure's synchronous prefix has already run to its first real
        // suspension (drainInFlightPoll's `task.cancel()` — which reaches the work
        // task through runPollCycle's withTaskCancellationHandler — then
        // `await task.value`), so the unforced cycle has been cancelled.

        gate.open()   // the parked hook returns; the cancelled work task then hits its checkpoint and unwinds
        await drain.value
        await cycle.value

        #expect(sync.testInFlightPollIsNil)
        #expect(sync.testPollTimeoutForceFlags.isEmpty,
                "the drain must not have waited for the 30s watchdog — got \(sync.testPollTimeoutForceFlags)")
        #expect(js.callCount("getBlockChanges") == 0,
                "the cancelled cycle must unwind before fetching — got \(js.callCount("getBlockChanges"))")
        // Zero only because `try Task.checkCancellation()` is the FIRST statement of
        // `doPollBlockChanges`, and `checkForChanges` is called later — so the
        // cancellation is observed before any JS call at all.
        #expect(js.callCount("hasBlockChanges") == 0,
                "the cancelled cycle must unwind before any JS call — got \(js.callCount("hasBlockChanges"))")
    }

    /// T6. Freeze the wire contract (A14): the poll path must issue exactly these JS
    /// scripts. The three constant scripts are asserted byte-for-byte; the
    /// `confirmBlockIds` script embeds the temp→permanent mapping, so its full text is
    /// reconstructed here (the inserted block's real id is read back from the DB) and
    /// asserted exactly. Deliberately NOT modelled (follow-up, noted in the review):
    /// the real JS clears its queues on read, so a scripted re-read hands back a fresh
    /// batch where the real editor would hand back an empty one.
    @Test("The poll path issues exactly the four frozen JS scripts (wire contract)")
    func pollPath_issuesFrozenJSScripts() async throws {
        let stack = try makeStack()
        let db = stack.db
        let sync = stack.sync
        _ = (stack.pid, stack.webView, stack.editorState)
        // Long watchdog: this test is about script text, not timing.
        sync.testPollWatchdogSeconds = 30

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let anchor = try #require(blocks.first, "expected at least one fixture block")
        let tempId = "temp-wire-1"
        let insertJSON = try blockChangesJSON(inserts: [
            BlockInsert(tempId: tempId, blockType: "paragraph",
                        textContent: "inserted by the wire test",
                        markdownFragment: "inserted by the wire test",
                        headingLevel: nil, afterBlockId: anchor.id, atDocumentStart: nil)
        ])

        let js = ScriptedJSEvaluator()
        js.answer("flushPendingBlockChanges", true)
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", insertJSON)
        js.answer("confirmBlockIds", true)
        sync.testJSEvaluator = { try await js.evaluate($0) }

        await sync.pollBlockChangesForTest(force: true)

        #expect(js.scripts.contains("window.FinalFinal.flushPendingBlockChanges(); true"),
                "flushPendingJSChanges wire script changed — got \(js.scripts)")
        #expect(js.scripts.contains("window.FinalFinal.hasBlockChanges()"),
                "checkForChanges wire script changed — got \(js.scripts)")
        #expect(js.scripts.contains("JSON.stringify(window.FinalFinal.getBlockChanges())"),
                "getBlockChanges wire script changed — got \(js.scripts)")

        let afterBlocks = try TestFixtureFactory.fetchBlocks(from: db)
        let inserted = try #require(
            afterBlocks.first { $0.textContent.contains("inserted by the wire test") },
            "the scripted insert must have landed"
        )
        let mappingData = try JSONSerialization.data(withJSONObject: [tempId: inserted.id])
        let mappingJSON = try #require(String(data: mappingData, encoding: .utf8))
        let expectedConfirm = "window.FinalFinal.confirmBlockIds(JSON.parse(`\(mappingJSON)`)); true"
        #expect(js.scripts.contains(expectedConfirm),
                "confirmBlockIds wire script changed — expected \(expectedConfirm), got \(js.scripts)")
    }
}
