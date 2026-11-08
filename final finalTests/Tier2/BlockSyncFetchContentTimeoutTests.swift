//
//  BlockSyncFetchContentTimeoutTests.swift
//  final finalTests
//
//  Tier 2: t-027c3835, quitting-can-hang-if-the-editor-stops-responding.
//
//  ROOT CAUSE: `BlockSyncService.fetchContentFromWebView(timeout:)` raced
//  `webView.evaluateJavaScript` against a `Task.sleep` inside
//  `withThrowingTaskGroup`. A task group cannot return from its closure until every
//  child task has finished, and cancelling the group cannot resume a WebKit
//  continuation that never gets its callback -- so the "timeout" never actually let
//  the function return. Five callers inherited the hang: quit
//  (`EditorViewState+Quit.swift`'s `flushForQuit()`), Save Version
//  (`ContentView+VersionHistory.swift`), idle auto-backup (`AutoBackupService.swift`),
//  structural undo (`StructuralUndoController.swift`), and
//  `ContentView.swift`'s `flushBeforeExport`.
//
//  Fix: `fetchContentFromWebView` now routes its JS call through `evaluateJS(_:in:)`
//  (the same DEBUG `testJSEvaluator` seam the poll path already used) and races it
//  against the timeout via the shared `raceAgainstTimeout(_:_:)`
//  (Services/TimeoutRace.swift) -- two independent, UNSTRUCTURED `Task`s whose loser
//  is simply never awaited, rather than a task group whose exit contract cannot
//  bound a wedged call.
//
//  Reuses `makeStack()`/`TestStack` from BlockSyncPollWatchdogTests.swift. Gets its
//  own scripted evaluator (`FetchContentWedge`) rather than `ScriptedJSEvaluator`:
//  the latter's `matchKey` deliberately does not recognize "getContent" (it only
//  matches the four poll-path calls), so this is a substitute for this suite's own
//  needs, not an extension of that one.
//

import Foundation
import Testing
@testable import final_final

/// Scripted `testJSEvaluator` standing in for `window.FinalFinal.getContent()` --
/// stands in for a WebKit `evaluateJavaScript` callback that never arrives, the same
/// shape as `BlockSyncPollWatchdogTests.ScriptedJSEvaluator`'s wedge but scoped to
/// the one script `getContent` (never routed through that evaluator's `matchKey`).
@MainActor
final class FetchContentWedge {
    private(set) var getContentCalls = 0
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var released = false
    var wedge = true
    var reply: String? = "late"

    func evaluate(_ script: String) async throws -> Any? {
        // Step F (`flushAndAck`) finds a page with nothing pending, so the quit goes on to its fetch, which is what wedges.
        if script.contains("flushReports") { return ScriptedJSEvaluator.quietPageAnswer("flushReports") }
        guard script.contains("getContent") else { return nil }
        getContentCalls += 1
        if wedge && !released {
            entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
            await withCheckedContinuation { release = $0 }
        }
        return reply
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseWedge() {
        released = true
        release?.resume(); release = nil
    }
}

/// `.timeLimit(.minutes(1))` mirrors `BlockSyncPollWatchdogTests`: a regression that
/// hangs must fail the test, not the CI run.
@Suite("BlockSync fetchContent timeout — Tier 2", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BlockSyncFetchContentTimeoutTests {

    /// T1. The defect at its simplest: `fetchContentFromWebView` must return at its
    /// own timeout, not join a `getContent()` call that never replies.
    @Test("fetchContentFromWebView times out on a wedged reply, not when it finally arrives")
    func fetchTimesOutOnWedgedReply() async throws {
        let stack = try makeStack()
        let wedge = FetchContentWedge()
        stack.sync.testJSEvaluator = { try await wedge.evaluate($0) }

        let clock = ContinuousClock()
        let start = clock.now
        let fetch = Task { @MainActor in
            await stack.sync.fetchContentFromWebView(timeout: .milliseconds(300))
        }

        // Proves the call actually reached and parked at the seam, not that it
        // returned nil for some unrelated reason (e.g. no webView configured).
        await wedge.waitUntilEntered()

        // Safety net: releases the wedge well above the elapsed bound below so a
        // regression that never returns on its own doesn't hang the suite forever --
        // the elapsed assertion still correctly fails in that case.
        let safety = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            wedge.releaseWedge()
        }
        defer {
            safety.cancel()
            wedge.releaseWedge()
        }

        let result = await fetch.value
        let elapsed = clock.now - start

        #expect(result == nil, "the timeout must win when the wedged reply never arrives in time")
        #expect(wedge.getContentCalls == 1)
        #expect(
            elapsed < .milliseconds(2600),
            "fetchContentFromWebView must return at its 300ms timeout, not the wedge (released at 3s) -- elapsed=\(elapsed)"
        )
    }

    /// T2. The happy path must still work once the fetch routes through
    /// `evaluateJS(_:in:)` and `raceAgainstTimeout(_:_:)`.
    @Test("fetchContentFromWebView returns the reply content when it arrives before the timeout")
    func fetchReturnsContentWhenReplyArrives() async throws {
        let stack = try makeStack()
        let wedge = FetchContentWedge()
        wedge.wedge = false
        wedge.reply = "# Fresh\n\nText."
        stack.sync.testJSEvaluator = { try await wedge.evaluate($0) }
        defer { wedge.releaseWedge() }

        let clock = ContinuousClock()
        let start = clock.now
        let result = await stack.sync.fetchContentFromWebView(timeout: .milliseconds(300))
        let elapsed = clock.now - start

        #expect(result == "# Fresh\n\nText.")
        #expect(wedge.getContentCalls == 1)
        #expect(elapsed < .seconds(1), "an immediate reply must not wait anywhere near the timeout")
    }

    /// T3. The actual regression this task fixes: `EditorViewState.flushForQuit()`
    /// must return despite a wedged `fetchContentFromWebView` call, not hang quit
    /// indefinitely.
    @Test("flushForQuit returns despite a wedged fetchContentFromWebView")
    func flushForQuitReturnsDespiteWedgedFetch() async throws {
        let stack = try makeStack()
        let wedge = FetchContentWedge()
        stack.sync.testJSEvaluator = { try await wedge.evaluate($0) }
        // Precedent: QuitFlushDuplicateInsertTests.swift:374. `blockSyncService` is
        // `weak` on EditorViewState, so without this, flushForQuit's
        // `blockSyncService?.fetchContentFromWebView()` skips the fetch entirely
        // (nil optional) and this test would pass vacuously.
        stack.editorState.blockSyncService = stack.sync
        #expect(stack.editorState.blockSyncService === stack.sync)

        // Entry (round C6): quit's flush is the lifecycle save sequence under an armed QUIT token
        // (`QuitFlushTestSupport`, Helpers/); the barrier it holds to exit is released there.
        let editorState = stack.editorState
        guard let quitToken = QuitFlushTestSupport.armQuit(editorState) else {
            Issue.record("could not arm the quit token")
            return
        }
        let webView = stack.webView

        let clock = ContinuousClock()
        let start = clock.now
        let quit = Task { @MainActor in
            _ = await QuitFlushTestSupport.flush(editorState, token: quitToken, webView: webView)
        }
        await wedge.waitUntilEntered()

        // Safety net, above the 5s elapsed bound below: flushForQuit's own fetch
        // uses the 2s default timeout, so a healthy post-fix run finishes in a few
        // seconds; releasing the wedge at 6s only matters if the fix is broken.
        let safety = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            wedge.releaseWedge()
        }
        defer {
            safety.cancel()
            wedge.releaseWedge()
        }

        await quit.value
        let elapsed = clock.now - start

        #expect(
            elapsed < .seconds(5),
            "flushForQuit must return at the fetch's 2s timeout, not the wedge (released at 6s) -- elapsed=\(elapsed)"
        )
        #expect(wedge.getContentCalls == 1)
    }
}
