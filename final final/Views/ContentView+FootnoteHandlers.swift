//
//  ContentView+FootnoteHandlers.swift
//  final final
//
//  Footnote-insertion handlers, split out of ContentView+NotificationHandlers.swift (t-94369a83 Phase 3a-1b)
//  to keep that file under SwiftLint's length limit: the pending-label drain, the immediate-insertion
//  handler (a rebuild that registers itself with the lifecycle save sequence, and is deferred while a
//  close / project switch / quit holds the editor), and the resync that follows it.
//

import SwiftUI

extension ContentView {
    /// Dequeues and re-posts exactly one pending footnote label, if contentState is
    /// idle and the queue is non-empty. Called both from the idle-transition branch
    /// above and from handleFootnoteInsertedImmediate's own early-return guard — the
    /// latter closes a gap where a drained item that turns out unprocessable (nil
    /// label/projectId) would otherwise never touch contentState, so no further idle
    /// transition would occur to pick up whatever is left in the queue.
    @MainActor
    func drainNextPendingFootnoteIfPossible() {
        guard editorState.contentState == .idle,
              let next = editorState.pendingFootnoteLabels.dequeue() else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .footnoteInsertedImmediate, object: nil,
                userInfo: ["label": next])
        }
    }

    /// Inserts a footnote definition into the Notes section after a slash-command insertion
    @MainActor
    func handleFootnoteInsertedImmediate(_ notification: Notification) {
        DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: entry " +
            "label=\(notification.userInfo?["label"] as? String ?? "nil") " +
            "projectId=\(documentManager.projectId ?? "nil")")

        // A close / project switch / quit holds the editor (t-94369a83 3a-1b, round C4, item 23): no footnote
        // rebuild may START inside its window, zoomed or not, so the label is kept (deferred, not dropped).
        // Needs only the label, so it sits ahead of the project check and the zoom routing below. A
        // cancelled lifecycle re-posts it (round C5a); a completed one drops it (round C5b); the footnote
        // refresh at step 7 of the save sequence gives a completed close the definition row.
        if editorState.activeLifecycle != nil {
            if let label = notification.userInfo?["label"] as? String {
                editorState.pendingFootnoteLabels.enqueue(label)
            }
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: deferred " +
                "(close/switch/quit in progress) label=\(notification.userInfo?["label"] as? String ?? "nil")")
            return
        }

        guard let label = notification.userInfo?["label"] as? String,
              let projectId = documentManager.projectId else {
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: skip " +
                "reason=missing-label-or-projectId")
            drainNextPendingFootnoteIfPossible()
            return
        }
        // Zoom-aware handling: use zoom-specific insertion path
        if editorState.zoomedSectionId != nil {
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: routing to zoom path " +
                "label=\(label) zoomedSectionId=\(editorState.zoomedSectionId ?? "?")")
            handleZoomedFootnoteInsertion(label: label, projectId: projectId)
            return
        }

        // Rapid double-insertion safety: queue label if busy
        guard editorState.contentState == .idle else {
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: queueing (busy) " +
                "label=\(label) contentState=\(editorState.contentState)")
            editorState.pendingFootnoteLabels.enqueue(label)
            return
        }

        // This is a synthetic content rebuild, not a mode switch — any cursor position
        // already sitting in cursorPositionToRestore was computed against the
        // pre-rebuild document and is stale by construction. Drop it so the stale
        // mode-switch restore mechanism can't fire later and overwrite the correct
        // footnote cursor placement Stage E is about to set below. Order-independent
        // (unrelated to contentState gating), so this stays at the original
        // synchronous point rather than moving into the Task below.
        cursorPositionToRestore = nil

        DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: proceeding " +
            "label=\(label) projectId=\(projectId)")
        // Phase 2 (t-94369a83), §2.4: the SYNCHRONOUS half of the insertion (debounce
        // cancel, generation bump) runs HERE, at the original call point, in the same
        // synchronous MainActor region as everything else above. The write itself
        // (`commitImmediateInsertion`) is async now -- routed through the ordered
        // system-write queue -- so `contentState` deliberately stays `.idle` across
        // that wait (moved into the Task below, AFTER the commit returns) rather than
        // being set busy before it: this is what keeps routine polls and editor
        // pushes working normally while the write is in flight, instead of stalling
        // behind a `contentState` gate for the whole wait.
        let insertionGeneration = footnoteSyncService.beginImmediateInsertion()

        // Registered for the lifecycle save sequence's step 3, as in `handleBibliographySectionChanged`.
        let rebuildTask: Task<Void, Never> = Task {
            // E1/E4: capture the real DB id of the definition row just inserted for
            // `label`, so it can ride along on the `.scrollToFootnoteDefinition` post
            // below instead of being discarded -- lets Milkdown resolve the cursor
            // target by block identity rather than a positional/label search.
            let insertedBlockId = await footnoteSyncService.commitImmediateInsertion(
                label: label, projectId: projectId, generation: insertionGeneration)

            // Set content state BEFORE the rebuild flush below to suppress sync --
            // moved here (after the commit above) per this function's own §2.4 doc
            // comment.
            editorState.contentState = .bibliographyUpdate
            editorState.isResettingContent = true

            // Everything the editor holds reaches the DB first (`flushAndAck`). This MUST complete before the
            // fetchBlocksWithIds() read below: a just-typed edit to an existing footnote definition can still be
            // in the page (pending, or a report not yet decided), and fetchBlocksWithIds reads block text straight
            // from the DB, so a read that raced ahead of this flush would rebuild the document from stale
            // (pre-edit) text and stomp the user's edit when the result is pushed back to the editor below.
            // BEST-EFFORT, not a guarantee: a page that does not answer, or a writer that does not settle within
            // `rebuildFlushAndAckBound` (8 s), lets this caller proceed, and `flushAndAck` logs it.
            await blockSyncService.flushForDatabaseRebuild()
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: fresh flush guaranteed " +
                "complete for label=\(label), reading blocks from DB")

            // Single source of truth: one DB fetch produces markdown + IDs that are
            // guaranteed mutually aligned (BlockParser.assembleMarkdown /
            // idsForProseMirrorAlignment share filtering + list-merge logic). Previously
            // this function hand-spliced a separately-derived string and paired it with
            // this fetch's block IDs; when the two disagreed on top-level node arrangement,
            // the editor's positional ID-assignment could attach an existing footnote's
            // identity to the wrong (blank) node. Pushing result.markdown directly (the
            // same pattern every other rebuild handler uses) eliminates that mismatch.
            let rebuildStamp = editorState.stampRebuildRead()   // slice 2b: on the line before the read, no `await` between
            let sourceRead = markdownRegionRead()   // t-4a8fd8af O28: the editor's regions on the stamp's line (nil: not Markdown)
            guard let result = fetchBlocksWithIds() else {
                DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: aborting " +
                    "label=\(label) reason=fetchBlocksWithIds-returned-nil")
                editorState.isResettingContent = false
                editorState.contentState = .idle
                resyncFootnotesAfterImmediateInsertion(projectId: projectId)
                return
            }

            if let sourceRead {
                // Markdown: only the Notes region is replaced, in place (O28); the record takes the page's text (O30).
                editorState.pendingImageMeta = result.imageMeta
                await holdRebuildFlushWindowForUITesting()
                await pushRebuildToMarkdownEditor([.notes], result: result, read: sourceRead, stamp: rebuildStamp, kind: "footnote")
            } else {
                editorState.content = result.markdown
                editorState.pendingImageMeta = result.imageMeta
                // DERIVED REFRESH (default, genuinely ambiguous -- flagged): a deliberate user
                // action (footnote insertion) synthesizes new content, so a case could be made
                // for INTENTIONAL, but this is exactly the call site the comment below already
                // documents as a KNOWN residual data-loss window -- leaving it DERIVED means the
                // new settle-window guard actively helps this pre-existing issue rather than
                // bypassing it.
                updateSourceContentIfNeeded()

                // Formerly a "known residual limitation": a keystroke typed in the window between
                // the flush above and setContentWithBlockIds below used to be lost the same way the
                // bibliography/Notes rebuilds could lose one (t-6a0d195d) -- that push replaced
                // every block that differed from the freshly-read DB content, including a user edit
                // the DB hadn't caught up with yet. Fixed the same way: `preserveUserBlocks: true`
                // below merges the push instead of replacing wholesale, so a block the user is
                // still typing in keeps its live-editor identity and content. See
                // mergeManagedBlocks's doc comment (api-content.ts) for the merge algorithm.

                await holdRebuildFlushWindowForUITesting()

                // Push fresh content with real block IDs atomically
                // (same pattern as bibliography — prevents temp ID race)
                let merged = await blockSyncService.setContentWithBlockIds(
                    markdown: result.markdown, blockIds: result.blockIds,
                    imageMeta: result.imageMeta,
                    cursorBoundary: result.bibBoundaryIndex,
                    cursorBoundaryEnd: result.bibBoundaryEndIndex,
                    expectedBlocks: result.expectedBlocks,
                    managedBlockIds: result.managedBlockIds,
                    preserveUserBlocks: true,
                    traceKind: .footnote,
                    stillWanted: { editorState.rebuildPushStillWanted(rebuildStamp) })
                // t-6a0d195d: see handleBibliographySectionChanged's matching comment -- the merged
                // push's actual markdown can differ from result.markdown. pendingImageMeta (set just
                // above) is kept regardless -- image metadata isn't affected by which markdown wins.
                // Slice 2b: when a quick undo or redo started since the read, the editor's own text is `content` instead.
                if await editorState.skipStaleRebuildTail(rebuildStamp, kind: "footnote", blockSync: blockSyncService) {
                    updateSourceContentIfNeeded()
                } else if let merged, merged != result.markdown {
                    editorState.content = merged
                    updateSourceContentIfNeeded() // #12: keep the Markdown-mode source copy in sync
                }
            }

            editorState.isResettingContent = false
            editorState.contentState = .idle
            resyncFootnotesAfterImmediateInsertion(projectId: projectId)

            await Task.yield()

            // Navigate cursor to new definition. E1: `blockId`, when present, is threaded
            // through to Milkdown's id-addressed cursor placement (`focusFootnoteDefinition`)
            // -- see MilkdownCoordinator+NotificationObservers.swift. CodeMirror's observer
            // ignores `blockId` (E2's fix is region-anchored text search, not id-addressed;
            // CodeMirror has no block ids).
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: posting " +
                "scrollToFootnoteDefinition label=\(label) blockId=\(insertedBlockId ?? "nil")")
            var scrollUserInfo: [String: Any] = ["label": label]
            if let insertedBlockId {
                scrollUserInfo["blockId"] = insertedBlockId
            }
            NotificationCenter.default.post(
                name: .scrollToFootnoteDefinition,
                object: nil,
                userInfo: scrollUserInfo
            )
        }
        editorState.registerRebuildTask(rebuildTask)
    }

    /// Guaranteed resync after an immediate footnote insertion returns `contentState` to
    /// `.idle`. `handleImmediateInsertion` unconditionally cancels any outstanding debounce,
    /// and `handleContentChange`'s `contentState == .idle` guard drops every `onChange` firing
    /// for the whole duration of this flow — including the flow's own final content push — so
    /// nothing else re-schedules a debounce for work that was dropped. Calling
    /// `checkAndUpdateFootnotes` here closes that gap. Cheap no-op in the common case: it
    /// early-exits when the live document's ref set already matches `lastKnownRefs`.
    @MainActor
    private func resyncFootnotesAfterImmediateInsertion(projectId: String) {
        let refreshedRefs = FootnoteSyncService.extractFootnoteRefs(from: editorState.content)
        footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: refreshedRefs,
            projectId: projectId,
            fullContent: editorState.content
        )
    }
}
