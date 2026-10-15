//
//  LifecycleDeadlineRaceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C1 (slice-3a-1b-everyday.md §5.1 items 1-3, obligations 19 / 20):
//  the poll-side primitives the lifecycle sequence calls.
//    - the watchdog-hit flag: `runPollCycle` reports one `PollCycleResult`, the spawner Task carries it,
//      `drainInFlightPoll()` ORs it across iterations, and `raceDrain(bound:)` hands it to the sequence
//    - `raceDrain(bound:)` / `raceForcedPoll(webView:bound:)` return at their own bound even when the
//      drain or poll is wedged (the orphan is accepted, obligation 19)
//    - the explicit WebView: `pollBlockChanges(force:webView:)` and `fetchContentFromWebView(timeout:webView:)`
//      poll/fetch the WebView they are handed, not the service's own weak one
//
//  Same harness as BlockSyncPollWatchdogTests.swift (`makeStack`, `ScriptedJSEvaluator`, a scripted JS
//  evaluator instead of a real WKWebView, per-instance watchdog override).
//

import Foundation
import Testing
import WebKit
@testable import final_final

@Suite("Lifecycle drain / forced-poll races — Tier 2 (t-94369a83 3a-1b C1)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleDeadlineRaceTests {

    /// Releases the wedge and waits (bounded, 3s) for the cycle that was parked in it to unwind and free the
    /// in-flight slot, so no cycle is still running against the test's temporary database when the test ends.
    private func releaseWedgeAndSettle(_ js: ScriptedJSEvaluator, _ sync: BlockSyncService) async throws {
        js.releaseWedge()
        for _ in 0..<300 {
            if sync.testInFlightPollIsNil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Watchdog-hit flag

    @Test("""
        Drain-watchdog flag: draining an in-flight cycle that is wedged inside a JS call (so only its own poll \
        watchdog can end it) reports hitWatchdog == true through raceDrain
        """)
    func raceDrain_reportsWatchdogHit_forAWedgedCycle() async throws {
        let stack = try makeStack()                       // poll watchdog 0.2s
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", false)
        js.wedgeOn("hasBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let sync = stack.sync
        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        let outcome = await sync.raceDrain(bound: 10)
        guard case .finished(let hitWatchdog) = outcome else {
            Issue.record("the drain must finish at the 0.2s poll watchdog, well inside its 10s bound; got \(outcome)")
            js.releaseWedge(); await cycle.value
            return
        }
        #expect(hitWatchdog, "a cycle ended by its watchdog must set the flag the lifecycle sequence reads")
        #expect(sync.testPollTimeoutForceFlags == [false], "exactly the one unforced watchdog timeout")
        js.releaseWedge()
        await cycle.value
    }

    @Test("Drain-watchdog flag: with nothing in flight the drain finishes at once and reports no watchdog hit")
    func raceDrain_reportsNoWatchdogHit_whenNothingIsInFlight() async throws {
        let stack = try makeStack()
        let outcome = await stack.sync.raceDrain(bound: 10)
        guard case .finished(let hitWatchdog) = outcome else {
            Issue.record("an idle drain must finish, got \(outcome)")
            return
        }
        #expect(hitWatchdog == false)
    }

    @Test("""
        Drain-watchdog flag: a cycle drained (cancelled) while it is merely slow, not wedged past its watchdog, \
        reports no watchdog hit
        """)
    func raceDrain_reportsNoWatchdogHit_forACycleThatEndsBeforeItsWatchdog() async throws {
        let stack = try makeStack()
        stack.sync.testPollWatchdogSeconds = 30           // the watchdog must NOT be what ends this cycle
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", false)
        js.wedgeOn("hasBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let sync = stack.sync
        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()
        let drain = Task { @MainActor in await sync.raceDrain(bound: 10) }
        await Task.yield()
        js.releaseWedge()                                  // the slow call answers; the cancelled cycle unwinds

        guard case .finished(let hitWatchdog) = await drain.value else {
            Issue.record("the drain must finish once the cycle unwinds")
            await cycle.value
            return
        }
        #expect(hitWatchdog == false, "a cycle that ends on its own (here: cancelled by the drain) is not a watchdog hit")
        #expect(sync.testPollTimeoutForceFlags.isEmpty)
        await cycle.value
    }

    // MARK: - The bound is real (the orphan is accepted)

    @Test("""
        raceDrain returns .timedOut at its own bound while the cycle it was draining is still wedged and still \
        owns the in-flight slot (the orphan is accepted, obligation 19)
        """)
    func raceDrain_returnsAtItsBound_whenTheCycleIsStillWedged() async throws {
        let stack = try makeStack()
        stack.sync.testPollWatchdogSeconds = 30           // far longer than the drain bound
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", false)
        js.wedgeOn("hasBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let sync = stack.sync
        let cycle = Task { @MainActor in await sync.pollBlockChangesForTest(force: false) }
        await js.waitUntilEnteredWedge()

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await sync.raceDrain(bound: 0.1)
        let elapsed = clock.now - start
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            js.releaseWedge(); await cycle.value
            return
        }
        #expect(elapsed < .seconds(5), "the race must return at its 0.1s bound, not at the 30s poll watchdog — took \(elapsed)")
        #expect(sync.testInFlightPollIsNil == false, "the wedged cycle still owns the slot: the orphan is accepted, not cancelled away")

        try await releaseWedgeAndSettle(js, sync)
        await cycle.value
    }

    @Test("""
        raceForcedPoll runs a forced cycle through the handed WebView and reports the cycle's result: a forced cycle \
        wedged in a JS call ends at the poll watchdog with hitWatchdog == true
        """)
    func raceForcedPoll_reportsWatchdogHit_forAWedgedForcedCycle() async throws {
        let stack = try makeStack()                       // poll watchdog 0.2s
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.wedgeOn("hasBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let outcome = await stack.sync.raceForcedPoll(webView: stack.webView, bound: 10)
        guard case .finished(let result) = outcome else {
            Issue.record("the forced poll must finish at the 0.2s poll watchdog, inside its 10s bound; got \(outcome)")
            js.releaseWedge()
            return
        }
        #expect(result.hitWatchdog)
        #expect(result.outcome == .timedOut)
        #expect(stack.sync.testPollTimeoutForceFlags == [true], "the timed-out cycle was a FORCED one")
        try await releaseWedgeAndSettle(js, stack.sync)
    }

    @Test("raceForcedPoll returns .timedOut at its own bound when the forced cycle is wedged and its watchdog is longer")
    func raceForcedPoll_returnsAtItsBound() async throws {
        let stack = try makeStack()
        stack.sync.testPollWatchdogSeconds = 30
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.wedgeOn("hasBlockChanges")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await stack.sync.raceForcedPoll(webView: stack.webView, bound: 0.1)
        let elapsed = clock.now - start
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            js.releaseWedge()
            return
        }
        #expect(elapsed < .seconds(5), "must return at the 0.1s bound, not the 30s watchdog — took \(elapsed)")
        try await releaseWedgeAndSettle(js, stack.sync)
    }

    // MARK: - Explicit WebView

    private struct ServiceWithoutView {
        let sync: BlockSyncService
        let db: ProjectDatabase
        /// `BlockSyncService.editorState` is weak: held here so it stays alive for the test.
        let editorState: EditorViewState
    }

    /// A service whose OWN weak WebView is already gone (`isConfigured == false`), as the lifecycle
    /// capture sees an editor whose view the service no longer references.
    private func makeServiceWithoutItsOwnWebView() async throws -> ServiceWithoutView {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\none two three.\n\n# Beta\n\nfour five six.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let sync = BlockSyncService()
        do {
            let own = WKWebView()
            sync.configure(database: db, projectId: pid, webView: own)
        }                                                   // `own` is released here; the service holds it weakly
        // Give the run loop a few turns to drain any autorelease pool still holding the view.
        for _ in 0..<50 where sync.isConfigured {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editorState = EditorViewState()
        sync.editorState = editorState
        return ServiceWithoutView(sync: sync, db: db, editorState: editorState)
    }

    @Test("""
        pollBlockChanges(force:webView:) polls the WebView it is handed: with the service's own WebView gone, a poll \
        without one does nothing, and the same poll with an explicit one fetches and applies the editor's batch
        """)
    func explicitWebView_isPolled_whenTheServicesOwnIsGone() async throws {
        let service = try await makeServiceWithoutItsOwnWebView()
        let (sync, db) = (service.sync, service.db)
        try #require(sync.isConfigured == false, "precondition: the service's own WebView must have been released")
        let target = try #require(TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent.contains("one two three") })
        let json = try blockChangesJSON(updates: [
            BlockUpdate(id: target.id, textContent: "explicit webview edit", markdownFragment: nil, headingLevel: nil)
        ])
        let js = ScriptedJSEvaluator()
        js.answer("hasBlockChanges", true)
        js.answer("getBlockChanges", json)
        sync.testJSEvaluator = { try await js.evaluate($0) }

        await sync.pollBlockChangesForTest(force: true)
        #expect(js.callCount("hasBlockChanges") == 0, "control: with no WebView at all the poll must not reach the editor")

        let explicit = WKWebView()
        await sync.pollBlockChangesForTest(force: true, webView: explicit)
        #expect(js.callCount("hasBlockChanges") >= 1, "the explicit WebView must have been polled")
        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.contains { $0.id == target.id && $0.textContent == "explicit webview edit" },
                "the batch fetched through the explicit WebView must have been applied")
        _ = service.editorState
    }

    @Test("fetchContentFromWebView(timeout:webView:) fetches from the WebView it is handed, not the service's own")
    func explicitWebView_isFetched_whenTheServicesOwnIsGone() async throws {
        let service = try await makeServiceWithoutItsOwnWebView()
        let sync = service.sync
        try #require(sync.isConfigured == false)
        sync.testJSEvaluator = { script in script.contains("getContent") ? "content from the explicit view" : nil }

        let withoutView = await sync.fetchContentFromWebView()
        #expect(withoutView == nil, "control: no WebView at all means nil")

        let explicit = WKWebView()
        let fetched = await sync.fetchContentFromWebView(timeout: .seconds(2), webView: explicit)
        #expect(fetched == "content from the explicit view")
        _ = service.editorState
    }
}
