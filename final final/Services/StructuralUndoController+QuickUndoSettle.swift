//
//  StructuralUndoController+QuickUndoSettle.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (plan-v2-addendum 4.5, plan-v3-addendum D1, plan-v4-addendum 3, verdict-v1 S10, verdict-v4 V1/V2): the
//  work that follows a quick undo, behind the reply to the press. The reply `performed` goes out as soon as the reinsert holds its
//  place in the writer's queue; everything here runs afterwards and is what the unsettled marker of the reinsert's key stands for (a
//  close, quit, zoom, mode switch, Save Version, export and any flush wait for it).
//
//  `reinsertSettled` runs when the reinsert's job future has resolved:
//    (a) the footnote checkpoint hold of this quick undo ends;
//    (b) the outcome: applied (the sidebar overlay goes; a missing root row after an applied reinsert is the C5 fallback), a refusal
//        by the lifecycle (nothing: the closing whole-document save writes the editor, which holds the section), anything else
//        (C5: the editor is the truth, so its text is written to the database; the unsettled marker is settled FIRST, or the flush's
//        own wait for pending structural jobs would wait out this very entry);
//    (c) only while the entry's epoch has not moved (no quick redo, no later quick undo has taken it): the editor's own text is read
//        (`getContent()`), never the content assigned before the restore, and adopted as `content`;
//    (d) the bibliography and footnote resyncs, the section and annotation syncs, the sidebar refresh, the wait for running rebuilds
//        (`resyncAfterEditorFirstDelete`, each step re-reading `content` and re-checking the epoch);
//    (e) the A20 push of the database's Notes and Bibliography into the editor, after the rebuild wait, the pattern of the rebuild
//        handlers (verdict-v4 V2): the database text is never assigned to `content` first, `isResettingContent` holds the view off
//        during the push, and afterwards `content` is the merged text (or the live re-read if the push was skipped as stale).
//

import SwiftUI
import GRDB

extension StructuralUndoController {

    // MARK: - After the reinsert

    /// The Notes and Bibliography rows were just put back (the restore, the reinsert, the C5 flush): what the footnote and
    /// bibliography services last committed (the delete's 1..45 renumber, its smaller bibliography) describes the post-delete table, and
    /// a redo that deletes the same section again would hash to the same value and be skipped as "already done". Both services forget
    /// their committed hash (`forgetCommittedNotesState`, `forgetCommittedBibliographyState`); nothing else of their dedup state.
    func forgetCommittedDerivedState() {
        footnoteSyncService?.forgetCommittedNotesState()
        bibliographySyncService?.forgetCommittedBibliographyState()
    }

    func reinsertSettled( // swiftlint:disable:this function_parameter_count
        opId: UUID, key: UUID, epoch: Int, holder: SectionDeletePayloadHolder,
        result: SystemWriteResult<SectionReinsertJob.Output>, trace: StructTrace
    ) async {
        guard let editorState else { return }
        #if DEBUG
        await testReinsertSettleHold?()
        #endif
        await TestMode.holdReinsertSettle(opId: trace.opId)
        footnoteSyncService?.releaseUndoCheckpointHold(token: key)   // (a)

        // (b) What the reinsert did.
        switch result.outcome {
        case .applied(let output):
            // The table equals the pre-delete rows from here on, whatever the epoch checks below decide; a delete-resync write that
            // committed after the quick undo's own reset (it had reserved before the undo) set the committed hash back.
            forgetCommittedDerivedState()
            trace.log(
                "applied inserted=\(output.insertedIds.count) updated=\(output.updatedIds.count) deleted=\(output.deletedIds.count) "
                + "userRowsDeleted=\(output.deletedUserRows)")
            spy("reinsertApplied")
            let epochUnmoved = (efOpEpoch[opId] ?? epoch) == epoch
            if epochUnmoved, output.wroteRows, rootRowIsMissing(holder: holder, editorState: editorState) {
                await reinsertFallback(opId: opId, key: key, why: "rows applied but the section's root row is not there", editorState: editorState)
                return
            }
            editorState.pendingRestoreSections[opId] = nil
        case .refused(let reason) where Self.isLifecycleRefusal(reason):
            // Code review G-F6: the closing save only helps while the lifecycle is still armed; one that was cancelled (or has ended)
            // leaves the project open with the section on the screen and not in the table, so it is the C5 case then.
            if editorState.activeLifecycle == nil {
                await reinsertFallback(opId: opId, key: key, why: "refused(\(reason)) and no lifecycle is armed", editorState: editorState)
                return
            }
            DebugLog.log(.lifecycle, "[StructuralUndoController] reinsert \(opId): not applied (\(reason)) -- the closing save writes the editor")
            editorState.pendingRestoreSections[opId] = nil
            return
        case .refused(let reason):
            await reinsertFallback(opId: opId, key: key, why: "refused(\(reason))", editorState: editorState)
            return
        case .failed(let error):
            await reinsertFallback(opId: opId, key: key, why: "failed(\(error))", editorState: editorState)
            return
        }

        await settleDerivedContent(opId: opId, epoch: epoch, editorState: editorState, trace: trace)   // (c)-(e)
    }

    /// (c)-(e) of the settle, only while this quick undo still owns the entry: the editor's own text is read, the resyncs run from it,
    /// and the database's Notes and Bibliography are pushed into the editor.
    private func settleDerivedContent(opId: UUID, epoch: Int, editorState: EditorViewState, trace: StructTrace) async {
        guard (efOpEpoch[opId] ?? epoch) == epoch else {
            DebugLog.log(.undo, "[StructuralUndoController] reinsert \(opId): settle skipped (the epoch moved: a redo or a later undo took it)")
            trace.log("settle skipped (epoch moved)")
            editorState.refreshSections()
            return
        }
        guard editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil, let blockSync = blockSyncService else {
            editorState.refreshSections()
            return
        }
        // The restore generation as it stands BEFORE the text is read: a quick undo or redo of any entry that starts while the read is
        // out makes the text older than the editor's document (code review G-F1), and that operation's own settle takes over.
        let restoreGeneration = editorState.editorRestoreGeneration
        await editorState.adoptLiveEditorText(blockSync: blockSync, why: "the reinsert settle")   // (c)
        guard (efOpEpoch[opId] ?? epoch) == epoch, editorState.editorRestoreGeneration == restoreGeneration else {
            DebugLog.log(.undo, "[StructuralUndoController] reinsert \(opId): settle skipped (another quick undo or redo took over)")
            trace.log("settle skipped (epoch moved)")
            editorState.refreshSections()
            return
        }
        await resyncAfterEditorFirstDelete(   // (d), and the closing push in a lifecycle
            editorState: editorState, opId: opId, epoch: epoch, restoreGeneration: restoreGeneration)
        if (efOpEpoch[opId] ?? epoch) == epoch, editorState.activeLifecycle == nil {
            await quickRepushManagedRegions(editorState: editorState)   // (e)
        }
        spy("reinsertSettled")
        trace.log("settled")
    }

    /// A refusal that only a close, quit or project switch produces: nothing to carry out, nothing to repair (the whole-document save
    /// that ends the lifecycle writes the editor, which holds the section).
    private static func isLifecycleRefusal(_ reason: SystemRefuseReason) -> Bool {
        switch reason {
        case .writerRetired, .identityMismatch, .skipped(.lifecycleDrain), .skipped(.drainTimeout), .skipped(.projectSwitch),
             .skipped(.writerReplaced), .skipped(.editorReplaced), .skipped(.close):
            return true
        default:
            return false
        }
    }

    /// True when the delete job applied and, with this quick undo still the entry's owner, the section's root row is not in the table
    /// after the reinsert: the rows do not match the screen.
    private func rootRowIsMissing(holder: SectionDeletePayloadHolder, editorState: EditorViewState) -> Bool {
        let state = holder.snapshot()
        guard state.outcome == .applied, let db = editorState.projectDatabase else { return false }
        let rootId = state.resolvedRootId ?? holder.rootId
        do {
            return try db.read { try Block.fetchOne($0, key: rootId) } == nil
        } catch {
            return false   // a read that failed proves nothing about the rows
        }
    }

    /// C5, the reinsert did not do its job: the screen shows the section, so the editor's text is written to the database (a
    /// whole-document write with fresh ids and the ids pushed back into the editor, no content push), the entry's slot is marked
    /// `fallback` (a later undo or redo of it is the old path or, for a quick-undone entry, a refusal with the notice), and the loss
    /// risk is logged. The unsettled marker is settled FIRST: the flush waits for pending structural jobs and would otherwise wait out
    /// its own entry's bound (verdict-v1 S10).
    private func reinsertFallback(opId: UUID, key: UUID, why: String, editorState: EditorViewState) async {
        DebugLog.alwaysPersisted(
            "[StructuralUndoController] quick undo \(opId): the reinsert did not put the rows back (\(why)) -- writing the editor's content "
            + "to the database and marking the entry's slot fallback")
        editorState.efJobRegistry.markSettled(key)
        efSlots.markFallback(opId)
        editorState.pendingRestoreSections[opId] = nil
        await editorState.flushLiveContentToDatabase { [weak self] in await self?.blockSyncService?.fetchContentFromWebView() }
        forgetCommittedDerivedState()   // the flush rewrote the Notes rows from the editor's text
        editorState.refreshSections()
    }

    // MARK: - The A20 push after a quick undo (verdict-v4 V2)

    /// The merge-guarded push of the database's Notes and Bibliography into the editor, run after the reinsert's rows are in and the
    /// rebuilds that were running have landed. Stamped on the line before the database read; the database's text never goes into
    /// `content` before the push; `isResettingContent` holds the view off while the push runs; afterwards `content` is the merged text
    /// the editor now holds (or its live text when a newer quick undo or redo made the push stale).
    func quickRepushManagedRegions(editorState: EditorViewState) async {
        guard editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              let pid = editorState.currentProjectId, let db = editorState.projectDatabase else { return }
        let stamp = editorState.stampRebuildRead()
        guard let result = fetchFullBlocksWithIds(db: db, pid: pid) else { return }
        // Code review C-L1: the rebuild handlers clear `isResettingContent` unconditionally when they end, so a rebuild that started
        // while this push was out has set the flag for ITS OWN protection; clearing it here would end that early. The flag is cleared
        // only when no rebuild is running; otherwise the running rebuild clears it.
        editorState.isResettingContent = true
        let text = await repushManagedRegionsFromDatabase(result, stamp: stamp)
        if let text { editorState.adoptEditorText(text) }
        if editorState.runningRebuildTasks.isEmpty { editorState.isResettingContent = false }
    }

    // MARK: - A restore that was refused (verdict-v3 D1, verdict-v4 V1)

    /// The quick undo (or redo) bumped the entry's epoch and the restore generation before its JavaScript went out, and the editor
    /// then refused: a delete settle that reached its resync meanwhile skipped its steps, and a rebuild whose push the generation bump
    /// skipped left the editor's Notes half updated (renumbered references, old Notes). One fresh settle under the new epoch,
    /// registered as unsettled work, puts the steps back (`resyncAfterEditorFirstDelete`) and, after any reinsert still pending has
    /// ended, one merge-guarded push with a fresh stamp makes the editor's Notes the database's (typing in user blocks survives).
    func startFreshSettleAfterRefusedRestore(opId: UUID) {
        guard let editorState else { return }
        let registry = editorState.efJobRegistry
        let key = UUID()
        registry.register(key)
        efJobKeys[opId, default: []].append(key)
        let epoch = efOpEpoch[opId] ?? 0
        Task { @MainActor [weak self, weak editorState] in
            defer {
                registry.resolve(key, .applied)
                registry.markSettled(key)
            }
            guard let self, let editorState else { return }
            // Code review G-F2: the text this settle works from is the editor's own, read first (the undo's `contentChanged` may
            // not have arrived); a quick undo or redo of any entry that starts meanwhile takes over (the generation, G-F1).
            let restoreGeneration = editorState.editorRestoreGeneration
            if let blockSync = self.blockSyncService {
                await editorState.adoptLiveEditorText(blockSync: blockSync, why: "the fresh settle after a refused restore")
            }
            guard editorState.editorRestoreGeneration == restoreGeneration else { return }
            await self.resyncAfterEditorFirstDelete(
                editorState: editorState, opId: opId, epoch: epoch, restoreGeneration: restoreGeneration)
            // A reinsert that is still pending (a refused redo right after a quick undo) must have ended before the push reads.
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(15))
            while editorState.pendingReinsertCount > 0, clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
            if (self.efOpEpoch[opId] ?? epoch) == epoch, editorState.activeLifecycle == nil {
                await self.quickRepushManagedRegions(editorState: editorState)
            }
        }
    }
}
