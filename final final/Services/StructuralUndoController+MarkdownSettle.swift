//
//  StructuralUndoController+MarkdownSettle.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 6: everything that happens AFTER a Markdown Delete
//  Section's job has ended (plan v2 B3 step 8 and B5/B8; plan v2.1 addendum section 2; judge D1, D3, O9, O10, O25, O27; model:
//  `MdEFPostApplyFlush` is ONE atomic step that reads, reserves, adopts and releases, and the settle's resyncs may only run once the flush
//  has applied, `fq`).
//
//  STEP 8 (`runMarkdownStep8`), run by the job-future continuation (`startMarkdownHoldContinuation`) when the job's future has resolved:
//    (a) `while let inFlight { await }` FIRST (D1): the live read comes after the wait, so typing made during the wait is in it;
//    (a2) a FAILED job: the page's undo swap puts the section back when the document is still the one the click made (B8);
//    (b) the LIVE text from the page (`getContentRaw`);
//    (c) ONE synchronous turn, no `await` in it: `reserveStructuralFlush(live)` (never a whole-document write), the content record adopts
//        the live text (O25: in the turn the writer's baseline moves to it), and the hold is released (the release runs the held
//        refire, which now diffs equal text and writes nothing);
//    (d) `await flush`: the flush has applied;
//    (e) the gate the settle waits on is finished (also on every early exit, by the continuation's `defer`).
//  The settle (`editorFirstJobSettled`) waits for that gate before anything of its own starts (`awaitMarkdownStep8`), bounded at 15 s
//  (`MarkdownStep8Gate.wait`, the bound `EFJobRegistry.awaitAllSettled` uses). The released hold never blocks this wait: it is already
//  down at (c).
//
//  THE MARKDOWN BRANCHES OF THE SETTLE live here too (the Rich Text code only gains one `if` at each site):
//    - `settleMarkdownManagedRegions`: when a rebuild's push was skipped for an editor-first reason the Notes and Bibliography rebuilds
//      are re-posted; they run the round-4 region-scoped push (a rebuild that reads after the job applied pushes a region replace);
//    - `putBackMarkdownJob`: a failed job (B8). The editor swapped back only if the document had not been typed in, then the alert;
//    - `markMarkdownSettle` / `unmarkMarkdownSettle` (B5/O10): the page's structural-settle flag around the footnote resync.
//

import Foundation
import GRDB
import WebKit

extension StructuralUndoController {

    // MARK: - Step 8

    /// Runs after the job's future has resolved with `outcome` (nil: it was cancelled or forgotten; then nothing is flushed). `readLive` is
    /// a test seam for the page's live text; nil reads `getContentRaw()` from the active web view.
    ///
    /// Round 7a: serves every Markdown job that holds the writer, not only the click's delete. `jobKey` is the job's registry key (the
    /// quick redo's delete job and a quick undo's reinsert have fresh ones; nil: the click's, which is the entry's id) and is also the
    /// key of the job's gate. `swapsBackOnFailure` is false for a reinsert: a failed reinsert has no section to swap back, and the flush
    /// below writes the restored document into the rows instead.
    ///
    /// CALLERS THAT RUN THIS INLINE (no continuation behind them to release the hold: the quick undo's and the slow route's "job not
    /// reserved" exits) MUST pass `.failed`, never `.abandoned` or nil: those return before the hold's turn below, and only the
    /// continuation's own `defer` would release the hold then (review F14).
    func runMarkdownStep8(
        opId: UUID, jobKey: UUID? = nil, hold: MarkdownStructuralHold, outcome: JobOutcome?, swapsBackOnFailure: Bool = true,
        readLive: (() async -> String?)? = nil
    ) async {
        guard let editorState else { return }
        let writer = editorState.markdownWriter
        let key = jobKey ?? opId
        defer { writer.structuralHoldState.step8Gates[key]?.finish() }
        guard let outcome, outcome != .abandoned else { return }
        spy("md8Begin")

        // (a) D1: wait for the write in flight FIRST. No other Markdown write can start meanwhile: the hold is still up.
        while let pending = writer.inFlight { await pending.value }
        spy("md8InFlightDone")

        // (a2) B8: a failed job. If the document is still the one the click made, the editor puts the section back.
        if swapsBackOnFailure, !outcome.isApplied, let gate = writer.structuralHoldState.step8Gates[key] {
            gate.swappedBack = await swapBackFailedMarkdownDelete(opId: opId, gateKey: key)
        }

        // (b) the live text, read AFTER the wait.
        let live: String?
        if let readLive { live = await readLive() } else { live = await evalString("window.FinalFinal.getContentRaw()") }
        spy("md8Read")

        // (c) one synchronous turn (the helper has no `await`).
        let flush = markdownStep8Turn(live: live, hold: hold)
        spy("md8Reserved")

        // (d) the flush has applied.
        await flush?.value
        spy("md8FlushApplied")
    }

    /// Step 8 (c): reserve the flush, adopt the live text into the content record, release the hold. Always releases the hold (the token
    /// is idempotent), also when nothing can be flushed (no answer from the page, a lifecycle armed, the mode or the project changed).
    private func markdownStep8Turn(live: String?, hold: MarkdownStructuralHold) -> Task<Void, Never>? {
        defer { hold.release() }
        guard let editorState, let live, let blockSync = blockSyncService, let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId, editorState.activeLifecycle == nil, editorState.editorMode == .source,
              editorState.zoomedSectionId == nil else {
            DebugLog.alwaysPersisted("[MdWrite] step 8: no live text or the editor state changed; nothing flushed (the next save writes it)")
            return nil
        }
        let flush = editorState.markdownWriter.reserveStructuralFlush(
            text: MarkdownLeaderMap.recordText(fromRaw: live), database: db, projectId: pid, service: blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        editorState.adoptMarkdownPageText(live)   // O25
        return flush
    }

    /// What the settle calls first for a Markdown entry: waits (bounded) until step 8 has finished. The gate is dropped afterwards unless
    /// the job failed: the put-back (`putBackMarkdownJob`) reads whether step 8 swapped the editor back and drops it itself.
    ///
    /// A job is a Markdown job exactly when it has a gate (made before the job starts, under the job's key: `jobKey`, or the entry's id
    /// for the click), so this is a no-op for every Rich Text settle, and it does not depend on the entry's `efEditorKind`, which a
    /// discard of the entry may clear while the job and its settle are still running.
    func awaitMarkdownStep8(opId: UUID, jobKey: UUID? = nil, keepsGateForPutBack: Bool) async {
        let key = jobKey ?? opId
        guard let writer = editorState?.markdownWriter, let gate = writer.structuralHoldState.step8Gates[key] else { return }
        await gate.wait()
        if !keepsGateForPutBack { writer.structuralHoldState.step8Gates[key] = nil }
    }

    /// Called by the task that runs a job (`startEditorFirstJob`, `startReinsert`) the moment the job's system write has returned: tells
    /// the hold continuation how the job ended. A no-op for a job without a gate (every Rich Text job).
    func notifyMarkdownJobEnded(key: UUID, outcome: JobOutcome) {
        editorState?.markdownWriter.structuralHoldState.step8Gates[key]?.jobEnded.resolve(outcome)
    }

    /// Whether the job `jobKey` (nil: the entry's first, whose key is its id) is a Markdown job whose gate is still kept.
    func hasMarkdownGate(opId: UUID, jobKey: UUID?) -> Bool {
        editorState?.markdownWriter.structuralHoldState.step8Gates[jobKey ?? opId] != nil
    }

    // MARK: - B8: a failed job

    /// The page's undo swap, with the click's own opId. It checks by itself that the live document still equals the entry's saved copy
    /// (nothing typed since); if so the pre-op state is back, and its text is adopted. Any other answer leaves the editor alone.
    private func swapBackFailedMarkdownDelete(opId: UUID, gateKey: UUID) async -> Bool {
        editorState?.markdownWriter.structuralHoldState.step8Gates[gateKey]?.swapAttempted = true
        guard let editorState,
              let answer = await evalString("JSON.stringify(window.FinalFinal.markdownStructuralSwap('\(opId.uuidString)', 'undo'))"),
              let reply = try? JSONDecoder().decode(MarkdownStructuralReply.self, from: Data(answer.utf8)),
              reply.succeeded, let postRaw = reply.postRaw else {
            DebugLog.log(.undo, "[StructuralUndoController] markdown delete \(opId) failed; the editor was typed in or did not swap: left as it is")
            return false
        }
        editorState.adoptMarkdownPageText(postRaw)
        return true
    }

    /// The Markdown counterpart of `putBackAfterFailedEditorFirstOp` for a Markdown job that did not apply (plan B8): a delete, since
    /// slice 2 a drag-reorder (`.sectionReorder`), since slice 3 a duplicate (`.sectionDuplicate`) and since slice 4 the three Version
    /// History restores (`kind.isVersionRestore`) (slice 1 called it `putBackMarkdownDelete`). The editor was already swapped back by step 8 when
    /// the document was unchanged (for a job that never held its place in the queue there is no step 8: the swap is tried here, for a
    /// delete, a reorder and a duplicate alike), and then the UX contract 4.3 alert of the entry's KIND shows ("Couldn't Delete Section",
    /// "Couldn't Move Section", "Couldn't Duplicate Section"); when the user had typed since, the command stands (the flush wrote the
    /// editor's text) and NO alert shows. The entry, its slot, its job record and its undo-timeline entry go either way, exactly as
    /// the Rich Text put-back drops them; a reorder's sidebar overlay (`pendingReorder`) and a duplicate's copy overlay
    /// (`pendingRestoreSections`) go first, so an outline read from here on shows the rows' (earlier) state.
    func putBackMarkdownJob(opId: UUID, jobKey: UUID? = nil, kind: EditorFirstOpKind = .sectionDelete, removedLeaders: Set<String>) async {
        guard let editorState, let unifiedUndoService else { return }
        let gateKey = jobKey ?? opId
        let gate = editorState.markdownWriter.structuralHoldState.step8Gates[gateKey]
        editorState.markdownWriter.structuralHoldState.step8Gates[gateKey] = nil
        defer {
            editorState.pendingRemovalIds.subtract(removedLeaders)
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            efRecordedGeneration[opId] = nil
            forgetQuickUndoState(opId)
            efEditorKind[opId] = nil
            editorState.pendingRestoreSections[opId] = nil   // a failed duplicate's copy overlay goes on every way out (as the Rich Text put-back)
            editorState.liftPendingReorder(opId: opId)   // a failed reorder's overlay goes on every way out, the closed-gate return included
        }
        unifiedUndoService.removeEntry(opId: opId)
        // A failed duplicate's copy never reached the rows: an outline result computed from here on must not merge its leaders back in, so
        // the overlay that showed it goes before anything below suspends (no-op for any other kind).
        editorState.pendingRestoreSections[opId] = nil
        editorState.liftPendingReorder(opId: opId)   // and before anything below suspends: its rows never moved (no-op for any other kind)
        efPutBackOpIds.insert(opId)   // a Cmd-Z already on its way for this entry is answered `failed` (as Rich Text does)
        guard !editorState.structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[StructuralUndoController] markdown put-back skipped: the project is closing or switching")
            return
        }
        // Step 8 tries the swap-back for a job that ended. A job that never held its place in the queue has no continuation and no
        // step 8: its swap-back is tried here (the hold is already down, and nothing was written, so there is nothing to flush).
        // A failed slow undo or redo (round 7b: `.snapshotUndo`, `.snapshotRedo`) has nothing to swap back: the page already shows the
        // swapped-in document, and its step 8 flush has written that text into the rows, so the editor and the rows agree; the entry
        // goes off the timeline (below) and the user is not told the press failed, because it did what it said.
        var swappedBack = gate?.swappedBack ?? false
        if kind == .sectionDelete || kind == .sectionReorder || kind == .sectionDuplicate || kind.isVersionRestore,
           let gate, !gate.swapAttempted {
            swappedBack = await swapBackFailedMarkdownDelete(opId: opId, gateKey: gateKey)
        }
        await evalVoid("window.FinalFinal.clearFailedStructuralOpEntry?.('\(opId.uuidString)')")
        await pushDescriptor()
        editorState.pendingRemovalIds.subtract(removedLeaders)
        editorState.refreshSections()
        guard swappedBack else { return }
        let alert = kind.putBackAlert
        #if DEBUG
        testShownAlerts.append(alert.title)
        #endif
        presentAlert?(alert)
    }

    // MARK: - The end of the settle

    /// `settleManagedRegionsAtEndOfEditorFirstSettle` for Markdown: when a rebuild's push was skipped for an editor-first reason (the stamp
    /// went stale) and no editor-first job is pending any more, the Notes and Bibliography rebuilds are posted again. They read the rows
    /// AFTER the job applied and push a region replace (round 4), so nothing here pushes text. A lifecycle holds the rebuild handlers back
    /// and saves the live text itself, so nothing is re-posted then.
    func settleMarkdownManagedRegions(editorState: EditorViewState) {
        guard editorState.activeLifecycle == nil, editorState.managedRegionsNeedRepush, editorState.pendingEditorFirstJobs == 0 else { return }
        editorState.managedRegionsNeedRepush = false
        NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
        NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
    }

    // MARK: - B5/O10: the page's structural-settle flag

    /// Sets the page's structural-settle flag to `opId`, in Markdown mode only (a settle cannot run in Markdown mode for a Rich Text
    /// entry: the mode switch waits for every settle; since round 7a the entry's `efEditorKind` is not read here, a discard may clear
    /// it while the settle runs). Submitted at once through the web view's
    /// `evaluateJavaScript`, which runs scripts in submission order: the renumber the footnote resync posts is submitted AFTER this.
    func markMarkdownSettle(opId: UUID) {
        guard editorState?.editorMode == .source, let activeWebView else { return }
        #if DEBUG
        editorState?.markdownWriter.structuralHoldState.settleFlagLog.append(opId.uuidString)
        #endif
        // The second argument is the Notes heading's line as the ROWS have it (the same snapshot the Notes region push takes its
        // `headingLine` from): with it the page's footnote renumber also sorts the Notes definitions, in the same transaction, so a
        // Save Version or a close straight after a drag cannot save relabelled-but-unsorted Notes. null: relabel only.
        let headingLiteral = notesHeadingLineForTheSettle().flatMap { Self.jsLiteral($0) } ?? "null"
        activeWebView.evaluateJavaScript("window.FinalFinal.setStructuralSettleOpId('\(opId.uuidString)', \(headingLiteral))") { _, _ in }
    }

    /// The Notes heading's line from the rows ("## Notes", or the user's own title), taken the way the Notes region push takes it
    /// (`MarkdownManagedRegions.snapshot`'s `notesHeadingLine`); nil when the project has no Notes heading.
    private func notesHeadingLineForTheSettle() -> String? {
        guard let editorState, let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return nil }
        // The first Notes heading row, by the rule `fetchNotesHeadingTitle` uses (the first in document order).
        guard let heading = try? db.read({ database in
            try Block
                .filter(Block.Columns.projectId == pid)
                .filter(Block.Columns.blockType == BlockType.heading.rawValue)
                .filter(Block.Columns.isNotes == true)
                .order(Block.Columns.sortOrder)
                .fetchOne(database)
        }) else { return nil }
        return MarkdownManagedRegions.snapshot(blocks: [heading]).notesHeadingLine
    }

    /// Clears the flag, from the `defer` that follows the footnote resync. The renumber that resync posts reaches the page through the
    /// Markdown coordinator's observer, which is delivered on the MAIN QUEUE (`NotificationCenter` with `queue: .main`) and then calls the
    /// same web view's `evaluateJavaScript` (CodeMirrorCoordinator+Handlers.swift `renumberFootnotes`). The clear goes through the same
    /// main queue, so it is submitted after that observer block has run, and the web view's FIFO then runs it after the renumber.
    ///
    /// The clear names the settle it belongs to (`expecting`, review F9/M-5): two settles can overlap (a Delete, then a Delete again at
    /// once; the first one's hold is down before its settle starts), and the earlier settle's clear must not drop the later settle's
    /// flag. The page clears only while the flag still holds `opId`.
    func unmarkMarkdownSettle(opId: UUID) {
        guard editorState?.editorMode == .source, let activeWebView else { return }
        #if DEBUG
        editorState?.markdownWriter.structuralHoldState.settleFlagLog.append(nil)
        #endif
        DispatchQueue.main.async { [weak activeWebView] in
            activeWebView?.evaluateJavaScript("window.FinalFinal.setStructuralSettleOpId(null, '\(opId.uuidString)')") { _, _ in }
        }
    }
}
