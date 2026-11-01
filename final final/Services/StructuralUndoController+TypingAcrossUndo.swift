//
//  StructuralUndoController+TypingAcrossUndo.swift
//  final final
//
//  t-d2061b27 (Phase 4c, job 2): a Cmd-Z or Cmd-Shift-Z that WAITS (behind a section command's job and settle) keeps waiting when the user
//  types, and then runs on the document as it was when the key was pressed; the page puts the typing back on top of the swapped-in
//  document (web/milkdown/src/typing-rebase.ts, web/codemirror/src/typing-rebase.ts). Typing is no longer a reason to refuse the press.
//
//  WHAT SWIFT DOES ABOUT IT. Almost nothing, on purpose: the page's reply carries `typingReplayed: true` (only ever `true`; absent
//  otherwise) and an EMPTY `batch`, and the typing reaches the rows by the paths that already exist (the quick routes' resume, which
//  detects the replay and queues it behind the reinsert; the slow routes' block-sync / step 8, which see it as typing after the swap).
//  No batch is sent for it and no reservation order changes. The one thing Swift owes is the TIMELINE: text typed after an undo ends the
//  redo branch (`UnifiedUndoService.invalidateRedoBranch`), exactly as typing after any undo does, and the page's replay transactions do
//  NOT post `historyEdited` (the page skips them: `maybeNotifyHistoryEdited` in Rich Text, no message in Markdown), so without this call
//  the entry that was just undone, and any older redo entries under it, would stay redoable over text the redo never saw.
//
//  WHERE IT RUNS. Inside the structural gate, AFTER the entry has moved to the other stack (`moveEntryAfterSwap` / `performUndo(opId:)` /
//  `performRedo(opId:)`) and the first `pushDescriptor()`, because `invalidateRedoBranch` bumps the timeline's generation and the
//  routes' own "the timeline changed mid-sequence" checks compare it before they move the entry. It is called by:
//    - the Rich Text slow route (+QueuedSnapshotUndo.swift, after `moveEntryAfterSwap`), from `EditorFirstReplaceReply.typingReplayed`;
//    - the Rich Text quick undo (+QuickUndo.swift, in place of the page query `quickUndoLiveDiffersFromRestored`), from
//      `QuickUndoReply.typingReplayed`;
//    - the Markdown slow route (+MarkdownSlowUndo.swift) and the Markdown quick undo and quick redo (+MarkdownQuickUndo.swift), from
//      `MarkdownStructuralReply.typingReplayed`.
//  The Rich Text quick REDOS never carry the flag (a quick redo is a fresh editor-first command on the live document: there is no
//  replay), but when typing was done in THEIR wait the page hands it back as the reply's `batch` (ordinary batch N) and says so in the
//  reply's `typed` flag (its gate's own answer: the user typed since the key was pressed). That typing ends the editor's own redo list, so
//  after a successful quick redo of a Delete (+QuickUndo.swift), a Duplicate (+EditorFirstDuplicate.swift) or a restore
//  (+EditorFirstRestore.swift) whose reply says `typed == true`, the older redo entries end too: `endRedoAfterReplayedTyping(reply.typed)`
//  (review F4, parity with Markdown's quick redo). Round 6: NOT for a non-empty `batch` alone, which can hold a rewrite the previous
//  command's settle left; ending the branch for it would lose a second Cmd-Shift-Z in a row.
//
//  F7 (review): `releaseHeldTypingForOldBody`, below, is the other half of the page's hold on the typing while a press is latched: a press
//  that goes to the OLD body must have that typing released and sent as batch N before the old body runs.
//
//  IDEMPOTENT. `invalidateRedoBranch` returns at once when the redo stack is empty; a second call (the quick undo's own post-move text
//  compare may fire for the same typing) finds it empty and only re-sends the descriptor. The page keeps nothing aside for the ended
//  redo: it clears its own set-aside redo record in the same turn that sets the flag (`setAsideRedoBranch(opId, null, ...)`), so there is
//  no stash for Swift to release.
//

import Foundation

/// The reply of `window.FinalFinal.releaseHeldTypingAndGetBatch()` (web/milkdown/src/undo-coordinator.ts): `released` is true when a hold on
/// the typing pushes was ended, `batch` is the pending batch the call took (always applied: `consumeEditorFirstReply`).
struct ReleasedTypingReply: EditorFirstBatchReply {
    let batch: BlockChanges
    let released: Bool
}

extension StructuralUndoController {

    /// t-d2061b27 (judge D1, review F7): a Rich Text press that goes to the OLD whole-document body (zoomed, no plan, `noCheckpoint`, an
    /// editor refusal that falls back, the legacy flags) is still latched on the page, which holds the typing it would report to the
    /// polls. The old body's own flush would find that typing held back, so it is released here and the batch it takes is sent as batch N
    /// FIRST: ticket reserved and the one call submitted in one synchronous stretch (`submitEditorFirstCall`), the batch applied by
    /// `consumeEditorFirstReply` (always). Called once per press, from `queuedSnapshotUndo`, when the editor-first route hands the press
    /// to the old body. Not for Markdown: its old body reads the page's live text itself. Costs one JavaScript call; a page with nothing
    /// held answers `released: false` and an empty batch, which settles the ticket empty.
    func releaseHeldTypingForOldBody() async {
        guard let editorState, editorState.editorMode == .wysiwyg, let blockSync = blockSyncService, blockSync.webView != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return }
        let script = "JSON.stringify(window.FinalFinal.releaseHeldTypingAndGetBatch())"
        guard let submission = await blockSync.submitEditorFirstCall(database: db, projectId: pid, script: script) else { return }
        guard let reply = consumeEditorFirstReply(
            submission, as: ReleasedTypingReply.self, blockSync: blockSync, database: db, projectId: pid, logName: "release before old body"
        ) else { return }
        spy("heldTypingReleasedForOldBody")
        DebugLog.log(
            .undo, "[StructuralUndoController] old body: released=\(reply.released) batch updates=\(reply.batch.updates.count) "
            + "inserts=\(reply.batch.inserts.count) deletes=\(reply.batch.deletes.count)")
    }

    /// Ends the redo branch when the page says the typing done while the press waited was put back on top of the swapped-in document
    /// (`typingReplayed == true`; a Rich Text quick redo passes its reply's `typed` flag here instead, round 6), then tells the editor
    /// the new descriptor (`redoTopOpId` gone). Returns whether it did: the quick
    /// undo skips its own page query then. Does nothing for `nil` or `false`.
    @discardableResult
    func endRedoAfterReplayedTyping(_ typingReplayed: Bool?, opId: UUID, trace: StructTrace) async -> Bool {
        guard typingReplayed == true, let unifiedUndoService else { return false }
        unifiedUndoService.invalidateRedoBranch(reason: "typing put back on top of the undo it waited behind")
        await pushDescriptor()
        spy("redoBranchEndedByReplayedTyping")
        trace.log("redo branch ended: the typing done while the press waited was put back (op \(opId.uuidString.prefix(8)))")
        return true
    }
}
