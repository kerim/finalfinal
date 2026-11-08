//
//  BlockSyncService+Lifecycle.swift
//  final final
//
//  t-94369a83 Phase 3a-1b: BlockSyncService's side of the close / project switch / quit save sequence -- the two entry points that
//  ask the service's writer for the lifecycle barrier and retire it, the release of typing held for a waiting Cmd-Z, plus DEBUG-only
//  test accessors. (The poll-cycle result types the sequence used to read went with the poll in Phase 5 job B4.)
//

import Foundation
import WebKit

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

    /// t-d2061b27 (Phase 4c job 2, judge D1): the Rich Text editor HOLDS the typing it would report while a Cmd-Z or Cmd-Shift-Z is
    /// latched on it (no report leaves from the page's request until Swift's reply): the press's swap puts that typing back on top
    /// of the undone document, and the replay is the only carrier. A close, quit or project switch must not wait for that: its step
    /// F (`flushAndAck`) has to see the typing, or it would go unsaved. This asks the page to release the hold, on the CAPTURED
    /// view, once, before F (`EditorViewState.forceSendForLifecycle`). Returns whether a hold was released (false: nothing was
    /// held, the page did not answer within `bound` seconds, or the page has no such function). After a release a press that is
    /// still waiting on the page is answered `docChanged` (the typing was already sent, so putting it back would save it twice).
    /// Markdown needs no such call: the lifecycle reads CodeMirror's live document directly (step 5), and F is not run in source mode.
    @discardableResult
    func releaseHeldTypingPushes(webView: WKWebView, bound: TimeInterval) async -> Bool {
        let outcome = await raceAgainstTimeout(.seconds(bound)) { () -> Bool in
            let raw = try? await self.evaluateJS(Self.releaseHeldTypingPushesScript, in: webView)
            return (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        }
        switch outcome {
        case .finished(let released):
            if released { DebugLog.log(.lifecycle, "[LifecycleFlush] F: released the typing the editor held for a waiting Cmd-Z") }
            return released
        case .timedOut:
            DebugLog.log(.lifecycle, "[LifecycleFlush] F: the editor did not answer releaseHeldTypingPushes within \(bound)s -- going on")
            return false
        }
    }

    /// `window.FinalFinal.releaseHeldTypingPushes()` (web/milkdown/src/undo-coordinator.ts); `?.` so a page without it answers nothing.
    static let releaseHeldTypingPushesScript = "window.FinalFinal.releaseHeldTypingPushes?.() === true"
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
