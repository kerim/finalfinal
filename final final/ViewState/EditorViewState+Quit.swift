//
//  EditorViewState+Quit.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C6 (slice-3a-1b-everyday.md section 4.5): the quit-time flush, re-implemented
//  on the lifecycle save sequence. It used to be its own recipe: stop and drain the 2s block-sync poll (so a
//  poll cycle cannot re-insert a paragraph the flush just wrote, TLA+ Finding #8 / Calm_InsertThenQuit), fetch
//  fresh content, then `flushAllSync()` (a direct database write, plus a bounded wait on the bibliography and
//  footnote services), with a quit-only suppression flag armed first so a rebuild notification could not start a
//  forced poll underneath it. All of that is now the one sequence close and project switch use
//  (`runLifecycleFlush`, EditorViewState+Lifecycle.swift): the page posts what it holds and the writer settles it (F,
//  `flushAndAck`), the editor's live document is read with its reports held and written through the ordered write
//  queue (FB), the bibliography and footnotes are re-derived from it, and a writer barrier waits for everything queued.
//  The quit token (`armLifecycle(.quit)`) replaces that flag: the three rebuild handlers defer while it is armed, so no
//  rebuild's flush can start underneath the save.
//

import Foundation

extension EditorViewState {
    /// Quit's save sequence: `runLifecycleFlush` under the already-armed QUIT `token`, against `deadline` (18s
    /// when quit runs alone, the shared tightened deadline when it joined a close or project switch whose own
    /// save never completed).
    ///
    /// What is quit-specific lives in `runLifecycleFlush` itself, keyed on `token.kind`: the section-operation
    /// wait is 10s and a still-running operation means F is applied and FB is skipped (the typing is saved,
    /// the operation is not undone); the floors keep 6 seconds before FB and 4 after it for the barrier and the
    /// automatic version; a barrier the writer refuses does not stop a quit; a barrier wait that runs out with
    /// FB still unapplied is counted as a lost whole-document write (item 15).
    ///
    /// The writer barrier the sequence leaves held stays held: quit exits holding it, so nothing queued behind
    /// it (a bibliography or Notes update the sequence orphaned) can write after the automatic version. The
    /// caller (`AppDelegate.runQuitSequence`) makes the automatic version and replies.
    func flushForQuit(
        token: LifecycleToken,
        host: LifecycleHost,
        structuralUndoController: StructuralUndoController?,
        deadline: LifecycleDeadline,
        bounds: LifecycleBounds
    ) async -> LifecycleFlushResult {
        assert(token.kind == .quit, "flushForQuit runs under a quit token")
        let started = Date()
        let result = await runLifecycleFlush(
            token: token,
            host: host,
            structuralUndoController: structuralUndoController,
            deadline: deadline,
            bounds: bounds
        )
        DebugLog.log(
            .lifecycle,
            "[EditorViewState] flushForQuit: sequence took \(Date().timeIntervalSince(started))s, "
                + "fb=\(result.fbStatus), barrier=\(result.barrier), \(deadline.remaining)s left")
        return result
    }
}
