//
//  ScriptedJSSupport.swift
//  final finalTests
//
//  Shared helpers for tests that drive a REAL `BlockSyncService` with a scripted page (`testJSEvaluator`) instead of a loaded
//  WKWebView. Moved here (Phase 5 job B4) out of BlockSyncPollWatchdogTests.swift, which was deleted with the 2-second poll it
//  tested; the helpers themselves are unchanged except that the scripted page now knows the report calls the service makes
//  (`flushReports`, the save's held read, `ackReports`, `reportOutboxSince`) and answers them as a quiet page would.
//

import Foundation
import Testing
import WebKit
@testable import final_final

// MARK: - Scripted JS evaluator

/// Stands in for the page calls routed through `BlockSyncService.evaluateJS(_:in:)`. Answers are keyed by a substring of the
/// script (the call's own name); see `matchKey(for:)` for the keys, which do not overlap.
///
/// Ordered answers: each entry in `answers[key]` is consumed by one call, and the LAST entry repeats for every further call.
///
/// A report call with no answer installed is answered as a page with nothing pending would (Phase 5 job B4): `flushReports`
/// with `through: 0` (so `flushAndAck` settles at once), `ackReports` and `reportOutboxSince` with an empty reply.
///
/// `wedgeOn` parks the FIRST matching call on a checked continuation until `releaseWedge()`, which is how a test reproduces
/// "WebKit never calls back".
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

    /// Runs once, the first time `flushReports` is asked, before it is answered (the page posts its reports while it answers).
    private var flushHook: (() -> Void)?

    /// The page holds `changes` unsent: when Swift asks `flushReports` (`flushAndAck`, step F of a close) it posts them as report 1
    /// of session "scripted" to `sync`'s intake and answers with that number. Phase 5 B4: it was `hasBlockChanges` / `getBlockChanges`
    /// answering the forced poll.
    func reportOnFlush(_ changes: BlockChanges, to sync: BlockSyncService) {
        flushHook = { [weak sync] in
            sync?.reportApplier.receive(IncomingReport(number: 1, session: "scripted", changes: changes, detectedAt: 0), via: .message)
        }
        answer("flushReports", "{\"session\":\"scripted\",\"through\":1,\"held\":false,\"enabled\":true}")
    }

    /// Parks the FIRST call whose script matches `key` until `releaseWedge()`.
    /// One-shot by design: only the first match wedges.
    func wedgeOn(_ key: String) {
        wedgeKey = key
    }

    func callCount(_ key: String) -> Int { callCounts[key] ?? 0 }

    /// Suspends until `key` has been called at least `count` times. Bounded and cancellation-aware.
    @discardableResult
    func waitUntilCallEntry(_ key: String, _ count: Int, iterations: Int = 100_000) async -> Bool {
        for _ in 0..<iterations {
            if callCount(key) >= count { return true }
            if Task.isCancelled { return false }
            await Task.yield()
        }
        return callCount(key) >= count
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

        if key == "flushReports", let hook = flushHook {
            flushHook = nil
            hook()
        }
        guard let values = answers[key] else { return Self.quietPageAnswer(key) }
        return values[min(index, values.count - 1)]
    }

    /// What a page with nothing pending answers to a report call no test scripted.
    static func quietPageAnswer(_ key: String) -> Any? {
        switch key {
        case "flushReports": return "{\"session\":\"scripted\",\"through\":0,\"held\":false,\"enabled\":true}"
        case "ackReports": return "0"
        case "reportOutboxSince": return "{\"session\":\"scripted\",\"lastEs\":0,\"entries\":[]}"
        default: return nil
        }
    }

    private static func matchKey(for script: String) -> String? {
        if script.contains("flushReports") { return "flushReports" }
        if script.contains("ackReports") { return "ackReports" }
        if script.contains("reportOutboxSince") { return "reportOutboxSince" }
        if script.contains("releaseReportHold") { return "releaseReportHold" }
        if script.contains("flushPendingBlockChanges") { return "flushPendingBlockChanges" }
        if script.contains("confirmBlockIds") { return "confirmBlockIds" }
        return nil
    }
}

// MARK: - Synchronization primitives

/// Counts completed events and lets a test await the nth. `value` is readable so a test can assert that something did NOT happen.
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

/// Thread-safe collector for `DebugLog.alwaysSink`. The sink may be invoked from any thread (the production code path is not
/// MainActor-only), hence the lock and `@unchecked Sendable`. Suites that install the process-global sink must be `.serialized`.
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
    // Held strongly HERE and returned, because `BlockSyncService.editorState` is `weak`.
    let editorState = EditorViewState()                                 // .idle by default
    sync.editorState = editorState
    return TestStack(db: db, pid: pid, webView: webView, sync: sync, editorState: editorState)
}

/// The JSON string of a `BlockChanges` batch (what a report's `json` field, or a route's batch, carries).
func blockChangesJSON(updates: [BlockUpdate] = [], inserts: [BlockInsert] = [], deletes: [String] = []) throws -> String {
    let changes = BlockChanges(updates: updates, inserts: inserts, deletes: deletes)
    let data = try JSONEncoder().encode(changes)
    guard let json = String(data: data, encoding: .utf8) else {
        throw BlockChangesJSONError.notUTF8
    }
    return json
}

private enum BlockChangesJSONError: Error { case notUTF8 }

/// The answer of the lifecycle save's held read (`BlockSyncService.fetchContentHoldingReports`, Phase 5 B3): the page's content,
/// no hold (the scripted page posts no reports). nil content: the call answers nothing (a failed fetch).
func heldReadAnswer(content: String?) -> String? {
    guard let content else { return nil }
    let reply: [String: Any] = ["content": content]
    return (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) }
}
