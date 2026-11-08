//
//  LifecycleDeadlineRaceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C1 (slice-3a-1b-everyday.md §5.1 items 1-3, obligations 19 / 20): the page-side primitives the
//  lifecycle sequence calls, each bounded and each asking the WebView it is handed.
//
//  Phase 5 job B4: the poll-side primitives (`raceDrain`, `raceForcedPoll`, the poll watchdog-hit flag) went with the 2-second poll.
//  Step F is `flushAndAck(on:bound:)`; what these tests kept is what it inherited from them: it returns at its own bound when the
//  page never answers (`.pageSilent`, which the sequence reads as the watchdog hit that skips the fetch), and it asks the WebView it
//  is handed, not the service's own weak one. `fetchContentFromWebView(timeout:webView:)`'s test is unchanged.
//

import Foundation
import Testing
import WebKit
@testable import final_final

@Suite("Lifecycle page-call bounds and the explicit WebView — Tier 2 (t-94369a83 3a-1b C1)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleDeadlineRaceTests {

    // MARK: - Bounds

    @Test("flushAndAck returns .pageSilent at its own bound while the page never answers flushReports (the wedge is left as an orphan)")
    func flushAndAck_returnsAtItsBound_whenThePageIsWedged() async throws {
        let stack = try makeStack()
        let js = ScriptedJSEvaluator()
        js.wedgeOn("flushReports")
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await stack.sync.flushAndAck(on: stack.webView, bound: 0.1)
        let elapsed = clock.now - start

        #expect(outcome == .pageSilent)
        #expect(elapsed < .seconds(5), "must return at the 0.1s bound -- took \(elapsed)")
        #expect(js.callCount("flushReports") == 1, "the page was asked once")
        js.releaseWedge()
    }

    @Test("flushAndAck settles at once when the page answers that nothing was posted")
    func flushAndAck_settles_whenNothingIsPending() async throws {
        let stack = try makeStack()
        let js = ScriptedJSEvaluator()
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }
        #expect(await stack.sync.flushAndAck(on: stack.webView, bound: 1) == .settled)
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
        flushAndAck(on:) asks the WebView it is handed: with the service's own WebView gone, a flush without one is .pageSilent \
        and asks nothing, and the same flush with an explicit one reaches the page and settles
        """)
    func explicitWebView_isAsked_whenTheServicesOwnIsGone() async throws {
        let service = try await makeServiceWithoutItsOwnWebView()
        let sync = service.sync
        try #require(sync.isConfigured == false, "precondition: the service's own WebView must have been released")
        let js = ScriptedJSEvaluator()
        sync.testJSEvaluator = { try await js.evaluate($0) }

        #expect(await sync.flushAndAck(bound: 1) == .pageSilent, "control: no WebView at all")
        #expect(js.callCount("flushReports") == 0, "control: with no WebView at all the page is never asked")

        let explicit = WKWebView()
        var askedViews: [ObjectIdentifier] = []
        sync.testJSWebViewObserver = { askedViews.append(ObjectIdentifier($0)) }
        #expect(await sync.flushAndAck(on: explicit, bound: 1) == .settled)
        #expect(js.callCount("flushReports") == 1, "the explicit WebView must have been asked")
        #expect(askedViews == [ObjectIdentifier(explicit)])
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
