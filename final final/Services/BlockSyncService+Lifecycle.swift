//
//  BlockSyncService+Lifecycle.swift
//  final final
//
//  t-94369a83 Phase 3a-1b: BlockSyncService's side of the close / project switch / quit save sequence --
//  the poll-cycle result types the sequence reads, and the two entry points that ask the service's writer for
//  the lifecycle barrier and retire it, plus three DEBUG-only test accessors. Split out of BlockSyncService.swift
//  to keep that file and type from growing further; everything the sequence needs that has to live on the type
//  itself (the changed `pollBlockChanges` / `drainInFlightPoll` / `performSystemWrite` signatures, the stored
//  test hooks) stays there, because an extension cannot hold stored properties or reach the file's private poll
//  internals. `writer` and `webView` are internal rather than private so the members below can reach them from
//  this file.
//

import Foundation

/// How one poll cycle ended (t-94369a83 Phase 3a-1b, coder obligation 20).
enum PollCycleOutcome: Equatable {
    /// The cycle ran to the end (including "no changes" and a batch the generation guard discarded).
    case finished
    /// The cycle was cancelled by `drainInFlightPoll()` and unwound at a pre-fetch checkpoint.
    case cancelled
    /// The cycle ended with an error other than a cancellation.
    case failed
    /// The poll watchdog expired first (a likely wedged WebKit call): the cycle's work was left to the
    /// orphan handling in `runPollCycle`.
    case timedOut
    /// No cycle ran: an unforced tick found one already in flight, or back-pressure refused it.
    case notRun
}

/// What one poll cycle reports. `hitWatchdog` is the PRODUCTION watchdog-hit outcome the lifecycle
/// sequence needs (obligation 20): `runPollCycle` returns it, the spawner `Task` carries it, and
/// `drainInFlightPoll()` ORs it across the iterations of its drain loop. Existing callers ignore it.
struct PollCycleResult: Equatable {
    let hitWatchdog: Bool
    let outcome: PollCycleOutcome

    init(outcome: PollCycleOutcome) {
        self.outcome = outcome
        self.hitWatchdog = outcome == .timedOut
    }
}

extension BlockSyncService {
    /// What `requestLifecycleBarrier()` found.
    enum LifecycleBarrierRequest {
        /// There is no writer yet (a launch straight into Markdown, plan #2): nothing to wait for.
        case noWriter
        /// A writer exists but refused the barrier: it is retired, or another barrier is already open.
        case refused
        case granted(BarrierHandle)
    }

    /// Phase 3a-1b (t-94369a83, C3b), plan section 4.2 step 8: enqueues the lifecycle's writer barrier on
    /// this service's writer. The save sequence asks the service rather than holding the writer itself. The
    /// caller must have reserved FB first (N9) and must never call `drainForLifecycle`, `skip`,
    /// `skipAllReserved` or `configure`/`reconfigure` on this writer while the barrier is open (N8): it
    /// releases first, or `retire`s.
    func requestLifecycleBarrier() -> LifecycleBarrierRequest {
        guard let writer else { return .noWriter }
        guard let handle = writer.enqueueBarrier() else { return .refused }
        return .granted(handle)
    }

    /// Phase 3a-1b (t-94369a83, C5b), plan section 4.4 (P6): retires this service's writer on behalf of a
    /// completed close or switch tail. `retire` skips every turn the writer still has reserved, drops its
    /// held ops AND drops an open barrier (a reached barrier dropped this way is a RELEASE, never
    /// `barriersCancelled`), and resumes a system write parked above the barrier `.skipped` -- never `.go`.
    /// The tail asks here, through `EditorViewState.retireForLifecycle(reason:)`, which also drops the editor
    /// state's own handle. A no-op without a writer (a launch straight into Markdown that never mounted the
    /// Milkdown editor).
    func retireWriterForLifecycle(reason: SkipReason) {
        writer?.retire(reason: reason)
    }
}

#if DEBUG
extension BlockSyncService {
    /// Test-only handle to the service's current writer (Phase 3a-1b, §5.1 item 7). Nil until the
    /// first `configure`. Lets a test enqueue/inspect a barrier on the writer the service actually
    /// uses (`DocumentWriter.testOpenBarrierSeq`) and check `assertsMainActorCallers` (N19).
    var testWriterHandle: DocumentWriter? { writer }

    /// Test-only (Phase 3a-1b, round C3a): forgets the service's own (weak) WebView on demand, and says
    /// whether it is nil. `configure` takes a non-optional view and the reference is weak, so a test
    /// otherwise had to wait for ARC to release a `WKWebView`, which is not guaranteed to happen promptly.
    /// This makes "the service's own view is gone" a fact the test sets up itself.
    func testClearOwnWebView() { webView = nil }
    var testOwnWebViewIsNil: Bool { webView == nil }
}
#endif
