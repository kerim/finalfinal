//
//  TimeoutRace.swift
//  final final
//
//  Shared "race an operation against a timeout, and actually return at the timeout"
//  primitive (t-027c3835, quitting-can-hang-if-the-editor-stops-responding). Before
//  this file existed, three call sites each carried their own copy of the same
//  pattern -- `BlockSyncService.awaitWithTimeout`/`raceWithTimeout` (backed by a
//  private `RaceBox`) and `ContentView.raceContentFetch` (backed by a private
//  `ContentFetchRaceBox`) -- and a fourth, `BlockSyncService.fetchContentFromWebView`,
//  had the BROKEN version of the same idea: it raced `webView.evaluateJavaScript`
//  against a `Task.sleep` inside `withThrowingTaskGroup`, whose exit contract still
//  awaits every child task -- including the loser -- before the group's own closure
//  returns. `webView.evaluateJavaScript`'s underlying `withCheckedContinuation` does
//  not observe Swift Task cancellation, so `group.cancelAll()` cannot force a wedged
//  WebKit call to resume, and the "timeout" never actually let the function return.
//
//  Two independent, UNSTRUCTURED `Task`s racing to resume the same continuation have
//  no such join: whichever one resumes the continuation first is the one this
//  function returns through, and the loser (an orphaned, never-awaited `Task`) is
//  simply left running -- exactly what makes the timeout real.
//

import Foundation

/// Resumes a `CheckedContinuation<Value, Never>` at most once (first resume wins,
/// later ones are no-ops). Backs `raceAgainstTimeout` below, where two independent,
/// UNSTRUCTURED `Task`s race to resume the same continuation (whichever finishes
/// first). Without this guard, both sides resuming would be a runtime trap --
/// `Task.cancel()` and `CheckedContinuation` do not protect against that on their
/// own; only the continuation's own single-use contract, enforced here, does.
/// `@MainActor`-isolated because every current caller races two MainActor `Task`s.
@MainActor
final class OneShotContinuation<Value> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// Outcome of `raceAgainstTimeout(_:_:)`.
enum TimeoutRaceOutcome<T> {
    case finished(T)
    case timedOut
}

/// Races `work` against `timeout`, returning `.finished(value)` if `work` completes
/// first, or `.timedOut` if the deadline elapses first.
///
/// Deliberately two independent, UNSTRUCTURED `Task`s rather than a
/// `withTaskGroup`/`withThrowingTaskGroup` race -- see this file's header comment for
/// why a task group's exit contract cannot bound a `work` closure that never
/// completes.
///
/// KNOWN RESIDUAL, inherited by every caller: once the continuation resumes
/// (whichever side won), the LOSING task is cancelled and left running --
/// cancelling an unstructured `Task` only sets its `isCancelled` flag; it cannot
/// force a suspended `withCheckedContinuation` (e.g. a `webView.evaluateJavaScript`
/// callback that never arrives) to resume. So when the deadline wins, `work` stays
/// alive holding whatever it captured (a `WKWebView`, in every current caller) until
/// -- if ever -- the operation it is awaiting finally calls back, possibly for the
/// rest of the process.
@MainActor
func raceAgainstTimeout<T: Sendable>(
    _ timeout: Duration,
    _ work: @escaping @MainActor () async -> T
) async -> TimeoutRaceOutcome<T> {
    var deadline: Task<Void, Never>?
    var workTask: Task<Void, Never>?
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<TimeoutRaceOutcome<T>, Never>) in
        let box = OneShotContinuation(continuation)
        workTask = Task { @MainActor in
            let value = await work()
            box.resume(.finished(value))
        }
        deadline = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            box.resume(.timedOut)
        }
    }
    switch outcome {
    case .finished:
        // The deadline lost -- cancel it so a `work` that wins its own race doesn't
        // leave a parked `Task.sleep` running on MainActor for no reason.
        deadline?.cancel()
    case .timedOut:
        // Best-effort only, per the residual above: this cannot force a wedged
        // `work` to actually stop.
        workTask?.cancel()
    }
    return outcome
}
