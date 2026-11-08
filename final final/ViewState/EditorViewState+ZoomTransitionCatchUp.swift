//
//  EditorViewState+ZoomTransitionCatchUp.swift
//  final final
//
//  Phase 5 job A7, the one catch-up the plan allows (design section 0 (c)): the page refused the swap (a recorded step the target cannot
//  take, typing in a zoomed chapter's mini-Notes, a plugin that changed the replayed document, an exception) and left its document as the
//  user had it, handing back the held typing as a batch. Swift writes that batch through the queue, waits for it, re-reads the rows and
//  pushes them with today's plain `setContentWithBlockIds`. Only keys typed during this catch-up meet today's push window, and only after
//  a refusal. Not modelled (the README's "Not modelled"); the web tests make a refusal rare by construction.
//

import Foundation

extension EditorViewState {
    /// Writes a refused swap's held typing and waits for it (bounded; on the bound the catch-up goes on, as today's path would).
    private func writeCatchUpBatch(_ blockSync: BlockSyncService, _ batch: BlockChanges) async {
        guard let seq = blockSync.writeTransitionBatch(batch) else { return }
        _ = await blockSync.awaitTransitionBarrier(through: seq, timeout: BlockSyncService.transitionBarrierTimeout)
    }

    /// The zoom out's catch-up: the held typing, the mini-Notes from the page's text (typing there is one reason a swap refuses), then
    /// today's restore of the whole document from the rows.
    func catchUpZoomOut(
        _ blockSync: BlockSyncService, reason: String, batch: BlockChanges, restoreScrollTo: String?, epoch: Int
    ) async {
        DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=zoom out reason=\(reason)")
        await writeCatchUpBatch(blockSync, batch)
        guard let db = projectDatabase, let pid = currentProjectId else {
            isZoomingContent = false
            contentState = .idle
            return
        }
        if let miniNotes = await liveMiniNotes(blockSync) { sectionSyncService?.syncMiniNotesBackPublic(miniNotes, projectId: pid) }
        do {
            let completed = try await restoreFullDocumentAndClearZoom(
                db: db, pid: pid, restoreScrollToSectionId: restoreScrollTo, expectedEpoch: epoch)
            isZoomingContent = false
            guard completed else { return }
            contentState = .idle
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried zoom out, catch-up: \(error)")
            isZoomingContent = false
            contentState = .idle
            clearZoomFlagsSafely()
        }
    }

    /// The zoom in's catch-up: the held typing (in and out of the range), then the zoomed chapter re-read from the rows and pushed as today,
    /// with today's tail (`pushBlockIds` for the range).
    func catchUpZoomIn(_ blockSync: BlockSyncService, sectionId: String, mode: ZoomMode, reason: String, batch: BlockChanges) async {
        DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=zoom in reason=\(reason)")
        await writeCatchUpBatch(blockSync, batch)
        guard let db = projectDatabase, let pid = currentProjectId,
              let target = try? buildZoomInTarget(sectionId: sectionId, mode: mode, db: db, pid: pid) else {
            isZoomingContent = false
            clearZoomFlagsSafely()
            contentState = .idle
            return
        }
        zoomedSectionIds = target.descendantIds
        zoomedBlockRange = target.range
        let document = target.document
        isResettingContent = true
        await blockSync.setContentWithBlockIds(
            markdown: document.markdown, blockIds: document.blockIds, scrollToStart: true, imageMeta: document.imageMeta,
            expectedBlocks: document.expected, zoomMode: true)
        content = document.markdown
        pendingImageMeta = document.imageMeta
        isResettingContent = false
        sourceContent = document.markdown
        await waitForContentAcknowledgement()
        isZoomingContent = false
        contentState = .idle
        await blockSync.pushBlockIds(for: zoomedBlockRange)
    }

    /// The mini-Notes of the zoomed text as the page holds it now, or of `content` when the page does not answer; nil when there are none.
    func liveMiniNotes(_ blockSync: BlockSyncService) async -> String? {
        guard SectionSyncService.stripZoomNotes(from: content).miniNotes != nil else { return nil }
        let live = await blockSync.fetchContentFromWebView() ?? content
        guard let notes = SectionSyncService.stripZoomNotes(from: live).miniNotes, !notes.isEmpty else { return nil }
        return notes
    }
}
