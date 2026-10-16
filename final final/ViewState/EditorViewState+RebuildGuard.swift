//
//  EditorViewState+RebuildGuard.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (quick undo of an editor-first section delete; plan-v4-addendum 3, verdict-v4 V1-V4): the stale-rebuild
//  guard, and the few small helpers the quick undo needs on the editor state.
//
//  THE HOLE THIS CLOSES. Each of the three rebuild handlers (bibliography and Notes in ContentView+NotificationHandlers.swift, footnote
//  insertion in ContentView+FootnoteHandlers.swift) reads the database, assigns the text to `content`, and some time later pushes
//  what it read into the editor (merge-guarded: it keeps the editor's own blocks and takes the database's Notes and Bibliography).
//  The slow undo is safe only because it waits for those Tasks first. The quick undo waits for nothing, so a rebuild that read the
//  POST-delete database can land after the restore; the merge then treats the restored section's blocks, which the database it read
//  does not have, as managed leftovers and drops them: the section and anything typed into it vanish from the editor. Its stale
//  `content = result.markdown` assignment is a second hazard (the view can push it as a whole document).
//
//  THE GUARD. A rebuild stamps the moment it reads the database (`stampRebuildRead`, on the line right before `fetchBlocksWithIds()`,
//  with no `await` between the two): the restore generation, and whether a quick undo's reinsert was pending at that moment. Its push
//  is only issued if, right before `evaluateJavaScript`, the stamp is still current (`rebuildPushStillWanted`); otherwise the push is
//  skipped and the editor's own live text is read back into `content` (`skipStaleRebuildTail`). The reinsert settle's own push, which
//  reads the database after the reinsert has applied, then brings the managed regions in line. The generation moves in the quick
//  undo's and quick redo's synchronous stretch before their JavaScript is sent; the pending count is +1 there and -1 when the
//  reinsert's job future resolves.
//

import Foundation

/// What a rebuild remembers about the moment it read the database.
struct RebuildReadStamp: Equatable, Sendable {
    let generation: Int
    /// A quick undo's reinsert was still pending when the database was read, so what was read is the post-delete table.
    let readWhileReinsertPending: Bool
}

extension EditorViewState {

    // MARK: - The stamp

    /// Call on the line immediately before the database read of a rebuild (no `await` between the two).
    func stampRebuildRead() -> RebuildReadStamp {
        RebuildReadStamp(generation: editorRestoreGeneration, readWhileReinsertPending: pendingReinsertCount > 0)
    }

    /// Whether what a rebuild read is still what the editor should be given: no quick undo or redo has started since, and the
    /// database was not read with a reinsert pending.
    func rebuildPushStillWanted(_ stamp: RebuildReadStamp) -> Bool {
        !stamp.readWhileReinsertPending && stamp.generation == editorRestoreGeneration
    }

    /// After a rebuild's push call has returned: when its stamp went stale (a quick undo or redo started since it read, so either its
    /// push was skipped or the restore replaced it), ignore the merged text, read the editor's own text back into `content` (still
    /// under the caller's `isResettingContent`), log, and tell the caller to skip the rest of its tail (the reinsert settle runs the
    /// section and annotation syncs). Returns false, doing nothing, when the stamp is current: the caller goes on exactly as before.
    func skipStaleRebuildTail(_ stamp: RebuildReadStamp, kind: String, blockSync: BlockSyncService) async -> Bool {
        guard !rebuildPushStillWanted(stamp) else { return false }
        await adoptLiveEditorText(blockSync: blockSync, why: "a stale \(kind) rebuild", requireUnchangedGeneration: false)
        DebugLog.log(.undo, "[STRUCT-TRACE] rebuild push skipped (stale: quick restore) kind=\(kind)")
        return true
    }

    // MARK: - Reading the editor's own text

    /// Reads the editor's live Markdown (`window.FinalFinal.getContent()`) and makes it the editor state's `content` the way an editor
    /// `contentChanged` push does: the text is assigned and the coordinator is told it is what the editor already holds (so
    /// `updateNSView` has nothing to push). Used where the database's text must NOT go into `content` (a quick restore is on the screen
    /// and the database may still hold the post-delete rows). When the editor does not answer, the current `content` is declared the
    /// editor's text instead (nothing is pushed either way) and the gap is logged: the next `contentChanged` from the editor corrects it.
    /// Returns the text now held as `content`.
    ///
    /// Code review G-F1(b): by default the answer is dropped, nothing assigned and nothing posted, when a quick undo or redo started
    /// while the call was out (`editorRestoreGeneration` moved): its JavaScript ran after this call's `getContent()`, so the text read
    /// is older than the editor's document, and that operation's own settle reads the text afresh. `requireUnchangedGeneration: false` is
    /// for the two callers that must correct a stale `content` the rebuild handlers or the A20 closing push had assigned (the database's
    /// text, which the view would otherwise push into the editor as a whole document).
    @discardableResult
    func adoptLiveEditorText(blockSync: BlockSyncService, why: String, requireUnchangedGeneration: Bool = true) async -> String {
        let generationBefore = editorRestoreGeneration
        let live: String? = await blockSync.fetchContentFromWebView()
        if requireUnchangedGeneration, editorRestoreGeneration != generationBefore { return content }
        guard let live else {
            let message = "[EditorViewState] " + why + ": the editor did not answer -- keeping the current content until its next change"
            DebugLog.alwaysPersisted(message)
            adoptEditorText(content)
            return content
        }
        adoptEditorText(live)
        return live
    }

    /// Makes `text` the editor state's `content` AND tells the editor coordinator that it is what the editor already holds.
    func adoptEditorText(_ text: String) {
        // The coordinator first (its observer runs synchronously), so no view update can see the new `content` before it knows the
        // editor already holds it.
        NotificationCenter.default.post(name: .blockSyncDidPushContent, object: nil, userInfo: ["markdown": text])
        content = text
    }

    // MARK: - A flush that is still running

    /// Waits until no `flushLiveContentToDatabase` is running (the idle backup, Save Version, export, the old-path structural ops),
    /// for at most `bound`. A quick undo or redo calls this inside the structural gate, BEFORE it decides whether it may run quick:
    /// the flush writes the post-delete screen into the table outside the queue and pushes the matching ids into the editor, and a
    /// restore that ran inside it would find its rows overwritten and its ids mis-aligned (verdict-v3 T1). It holds the press; it
    /// never refuses it. Past one second the existing "Finishing the last change..." notice shows.
    func awaitRunningLiveFlush(bound: Duration = .seconds(15)) async {
        guard liveFlushRunning > 0 else { return }
        let notice = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { notice.stop() }
        DebugLog.log(.lifecycle, "[EditorViewState] quick undo/redo: waiting for \(liveFlushRunning) running flush(es)")
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: bound)
        while liveFlushRunning > 0 {
            if clock.now >= end {
                DebugLog.alwaysPersisted("[EditorViewState] quick undo/redo: gave up waiting for a running flush after \(bound)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The sidebar overlay

    /// `blocks` (an outline result, in the outline's own order: user sections by sort order, bibliography last) with the leaders of
    /// every quick-undone section whose rows the database has not got back yet merged in at their positions. A leader already in
    /// `blocks` is not added twice. Each section goes right after its document anchor (`pendingRestoreAnchors`), never by its old sort
    /// order against the current ones (the rows after a deleted section are renumbered); see `SidebarRestoreOverlay`.
    func mergingPendingRestores(into blocks: [Block]) -> [Block] {
        guard !pendingRestoreSections.isEmpty else { return blocks }
        let restores = pendingRestoreSections.map { PendingRestore(leaders: $0.value, anchor: pendingRestoreAnchors[$0.key]) }
        return SidebarRestoreOverlay.merging(restores, into: blocks)
    }
}
