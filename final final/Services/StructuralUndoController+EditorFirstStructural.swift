//
//  StructuralUndoController+EditorFirstStructural.swift
//  final final
//
//  t-18b7fa48 Phase 4b, round 1b: the click skeleton that every editor-first structural operation shares, factored out of Delete Section
//  (`performEditorFirstDelete`, StructuralUndoController+EditorFirstDelete.swift) so that Duplicate Section and the Version History
//  restores can stand on it. Delete is the first user, and behaves exactly as before apart from the rebuild stamp below; Duplicate
//  Section is the second (round 1e-i, StructuralUndoController+EditorFirstDuplicate.swift).
//
//    1. `runEditorFirstStructuralClick`: the click's stretch under the structural gate (the entry point takes the gate with
//       `waitsForRebuilds: false` and keeps it across a fall back to the old body): the poll pause, the rebuild stamp (D6), the ONE
//       JavaScript call through the writer's ticket N, the reply and its batch, the refusal exits (D6a), and room for the caller to
//       reserve its job before the poll pause ends.
//    2. `putBackAfterFailedEditorFirstOp(kind:)`: the job did not apply; the database is the truth, so the document goes back.
//    3. `startFreshSettleAfterRefusedEditorFirstClick(opId:)`: the click bumped the stamp and then reserved no job; one fresh settle.
//    4. `settleManagedRegionsAtEndOfEditorFirstSettle`: the last step of every editor-first settle (round 1b-ii), see the last paragraph.
//
//  THE REBUILD STAMP (D6, option (a)). The click, in its synchronous stretch before the JavaScript goes out, bumps
//  `EditorViewState.editorFirstClickGeneration` and raises `pendingEditorFirstJobs`. A rebuild (bibliography, Notes, footnote
//  insertion) that read the database before the click, or while the job is pending, skips its editor push (`rebuildPushStillWanted`)
//  and adopts the editor's live text. The click does NOT touch `editorRestoreGeneration` or `pendingReinsertCount`: those are read by
//  the settles of the quick undo and redo, and a click must not change what an in-flight one does.
//
//  THE COUNT COMES DOWN FIRST. `pendingEditorFirstJobs` falls when the job's future has resolved (applied, failed, refused or
//  abandoned), and that happens BEFORE the operation's own settle (`editorFirstJobSettled` -> `resyncAfterEditorFirstDelete`) or the
//  put-back push calls `stampRebuildRead()`. The order matters: the settle's own rebuilds read the table after the job has applied, so
//  they must stamp as current. With the count still raised they would stamp "read while pending", skip every Notes and Bibliography
//  push the settle starts, and the editor's Notes would never be updated (everyday: delete or duplicate a footnoted section).
//
//  D6a, THE REFUSAL EXITS. A click exit that reserved no job (the editor refused, or the bridge call threw or answered nothing
//  readable) brings the count down at once and starts the fresh settle, which adopts the editor's live text, runs the full resync and
//  re-pushes the managed regions: a rebuild whose push the click's stamp skipped would otherwise leave the editor's Notes half
//  updated. The exception is an exit that hands the press to the old whole-document body in the same gate turn (no writer turn, or
//  an editor with no document yet): that body's own full resync and push stand in for the fresh settle.
//
//  THE RE-PUSH OWED AFTER A SKIPPED REBUILD (round 1b-ii). A rebuild whose push the stamp skipped (the click generation moved, or it
//  read while a job was pending) leaves the editor's Notes and Bibliography as they were while the database is right; it raises
//  `EditorViewState.managedRegionsNeedRepush` (`noteStalePushSkipped`). Nothing else would put the editor right: the operation's own
//  settle cannot (`FootnoteSyncService` skips a second resync of the same references). So the shared settle tail
//  (`settleManagedRegionsAtEndOfEditorFirstSettle`, called at the end of `resyncAfterEditorFirstDelete`) pushes the database's regions
//  once the flag is up AND no editor-first job is pending: the LAST settle of a run of back-to-back operations is the one that sees
//  both. Never an unconditional re-push on every settle, and never a re-queued rebuild (it would loop).
//

import SwiftUI
import WebKit
import GRDB

// MARK: - The kinds and the reply

/// Which editor-first operation a click is. Carries the per-kind wording of the shared logs and of the put-back alert.
enum EditorFirstOpKind {
    case sectionDelete
    /// t-18b7fa48 round 1e-i: Duplicate Section (StructuralUndoController+EditorFirstDuplicate.swift).
    case sectionDuplicate
    /// t-18b7fa48 round 2d-i: Version History "Restore this version" of the WHOLE project
    /// (StructuralUndoController+EditorFirstRestore.swift).
    case restoreProject
    /// t-18b7fa48 round 2d-ii: Version History "Replace Current Section" (StructuralUndoController+EditorFirstSectionRestore.swift).
    case restoreSectionReplace
    /// t-18b7fa48 round 2d-ii: Version History "Restore as Duplicate" (StructuralUndoController+EditorFirstSectionRestore.swift).
    case restoreSectionDuplicate
    /// t-18b7fa48 round 3c: the SLOW undo of any entry in Rich Text (StructuralUndoController+QueuedSnapshotUndo.swift): the editor swaps its
    /// saved state in (`structuralSwapEditorFirst`), the queued job makes the database equal to the snapshot's document.
    case snapshotUndo
    /// t-18b7fa48 round 3c: the slow REDO of any entry in Rich Text (the same call and job, the other direction).
    case snapshotRedo
    /// t-0b70d1e9: a drag-reorder in the Outline sidebar in Rich Text (StructuralUndoController+EditorFirstReorder.swift, queued job
    /// `SectionReorderJob`). The editor moves the section(s) as one range move; there is no quick undo (its undo is the slow one).
    case sectionReorder

    /// The word the shared log lines use: "editor-first <name>: ...".
    var logName: String {
        switch self {
        case .sectionDelete: return "delete"
        case .sectionDuplicate: return "duplicate"
        case .restoreProject: return "restoreProject"
        case .restoreSectionReplace: return "restoreSectionReplace"
        case .restoreSectionDuplicate: return "restoreSectionDuplicate"
        case .snapshotUndo: return "snapshotUndo"
        case .snapshotRedo: return "snapshotRedo"
        case .sectionReorder: return "reorder"
        }
    }

    /// Whether this is one of the three Version History restores: they replace or add document TEXT, so their settle adopts the
    /// editor's own text before it derives anything from `content` (D14), and an editor that refuses hands the press to the old
    /// restore (D7).
    var isVersionRestore: Bool {
        switch self {
        case .sectionDelete, .sectionDuplicate, .snapshotUndo, .snapshotRedo, .sectionReorder: return false
        case .restoreProject, .restoreSectionReplace, .restoreSectionDuplicate: return true
        }
    }

    /// The slow undo or redo (round 3c): the editor swaps its saved state in and the job makes the whole table equal to a snapshot.
    var isSnapshotSwap: Bool { self == .snapshotUndo || self == .snapshotRedo }

    /// Whether the operation replaces or rearranges document TEXT (a restore, a snapshot swap, or a reorder that moves whole sections of
    /// it): its settle adopts the editor's own text before it derives anything from `content` (D14), because `content` may still be the
    /// text from before the change. A reorder needs it as much as a restore does: the footnote resync numbers the references in TEXT
    /// order, and `content` (the editor's own push, about 50 ms behind) can still be the order from before the move (t-0b70d1e9, A9).
    var replacesDocumentText: Bool { isVersionRestore || isSnapshotSwap || self == .sectionReorder }

    /// D7: whether an editor that REFUSES the click (`ok:false`) hands the press to the old whole-document body in the same gate turn
    /// instead of refusing it. A restore does for every reason: the old restore is a complete, working restore, and "Restore failed.
    /// Nothing was changed." is shown only when that body itself refuses. Delete and Duplicate refuse (their old body would meet the
    /// same editor state).
    ///
    /// The slow undo and redo (round 3c) fall back for every reason EXCEPT the two it answers itself: `docChanged` (the user typed while
    /// the press waited: the press is refused with the notice and the typing stays, D13) and `noCheckpoint` (handed back to the
    /// caller, `handsBackToCaller`).
    ///
    /// A reorder (t-0b70d1e9) falls back for every reason too: the old whole-document reorder is a complete, working reorder, and it
    /// runs in the same gate turn, as a restore's does (`planMismatch`, `managedMoved`, `rootNotFound`, `noEditor`, a failed begin).
    func refusalFallsBackToLegacy(reason: String?) -> Bool {
        switch self {
        case .sectionDelete, .sectionDuplicate: return false
        case .restoreProject, .restoreSectionReplace, .restoreSectionDuplicate, .sectionReorder: return true
        case .snapshotUndo, .snapshotRedo: return reason != "docChanged" && reason != "noCheckpoint"
        }
    }

    /// Whether an `ok:false` with this reason is handed back to the caller (`EditorFirstClickOutcome.declined`) instead of being refused
    /// or handed to the old body. Only the slow undo's `noCheckpoint`: the editor has no saved state for the entry, nothing was swapped,
    /// and the caller runs slice 2's whole replace from the same plan (U-S3-3).
    func handsBackToCaller(reason: String?) -> Bool { isSnapshotSwap && reason == "noCheckpoint" }

    /// Whether this kind's click puts its leaders into a sidebar overlay (`EditorViewState.pendingRestoreSections`) that the settle lifts
    /// once an outline read after the job's commit shows the real rows. Delete only removes leaders, so it has none.
    var usesSidebarOverlay: Bool {
        switch self {
        // A reorder has its own overlay (`EditorViewState.pendingReorder`, lifted by `liftPendingReorder(opId:)`), not this one.
        case .sectionDelete, .sectionReorder: return false
        case .sectionDuplicate, .restoreProject, .restoreSectionReplace, .restoreSectionDuplicate, .snapshotUndo, .snapshotRedo: return true
        }
    }

    /// The put-back alert (UX contract 4.3: a modal alert for an operation that did not happen).
    var putBackAlert: SectionOperationAlert {
        switch self {
        case .sectionDelete:
            return SectionOperationAlert(
                title: "Couldn't Delete Section",
                message: "The delete couldn't be saved, so the section has been put back. If you typed in the last moments, "
                    + "check that your text is still there."
            )
        case .sectionDuplicate:
            // The wording of plan-v3 C4. It drops delete's "If you typed in the last moments..." sentence on the strength of U-S1-7 (a
            // failed duplicate's put-back keeps the typing from the click's batch and the typing made while the put-back's push is in
            // flight); if that test is red, the sentence goes back in and the debt is recorded. The last sentence is round 1g-A's
            // (review T1, floor item 5): the copy never reached the database, so the put-back removes it and whatever the user typed
            // into it; the user is told, in plain words, instead of finding it gone.
            return SectionOperationAlert(
                title: "Couldn't Duplicate Section",
                message: "The duplicate couldn't be saved, so the section is back as it was. "
                    + "Anything you typed into the copy was removed with it."
            )
        case .restoreProject:
            // Plan-v3 C4 (approved wording) in the duplicate's structure: no "check your typing" sentence (U-S2-7: the click's batch
            // and the typing the database could apply are kept), and, as for the duplicate (review T1, floor item 5), one plain
            // sentence for what the put-back cannot keep: text typed into the RESTORED text after the click is typed into blocks the
            // database never got (the job rolled back), so the put-back removes it together with the restored text.
            return SectionOperationAlert(
                title: "Couldn't Restore Version",
                message: "The restore couldn't be saved, so the document is back as it was before the restore. "
                    + "Anything you typed into the restored text was removed with it."
            )
        case .restoreSectionReplace, .restoreSectionDuplicate:
            // Plan-v3 C4 (approved wording for the section restores) with the same added sentence as the other two restores: text
            // typed into the restored section (or into the copy) after the click is typed into blocks the database never got.
            return SectionOperationAlert(
                title: "Couldn't Restore Section",
                message: "The restore couldn't be saved, so the section is back as it was. "
                    + "Anything you typed into the restored text was removed with it."
            )
        case .snapshotUndo:
            // Round 3c (plan-v3 C4 lists only the duplicate and the restores; the judge approved this wording in fix round F1, item 7):
            // the job rolled back, so the database still holds the document from before the press; the put-back gives that document
            // back to the editor, which removes the text typed after the swap together with the swapped-in text (UX contract 4.3).
            return SectionOperationAlert(
                title: "Couldn't Undo",
                message: "The undo couldn't be saved, so the document is back as it was before you pressed Undo. "
                    + "Anything you typed in the text the undo brought back was removed with it."
            )
        case .snapshotRedo:
            return SectionOperationAlert(
                title: "Couldn't Redo",
                message: "The redo couldn't be saved, so the document is back as it was before you pressed Redo. "
                    + "Anything you typed in the text the redo brought back was removed with it."
            )
        case .sectionReorder:
            // t-0b70d1e9 (approved wording, UX contract 4.3). "Move" matches the existing bail-out toast ("Couldn't move the section").
            // Delete's sentence about the last moments' typing, not the duplicate's: the put-back gives the document back from the
            // database, and a block typed in the last poll window can be older than that read.
            return SectionOperationAlert(
                title: "Couldn't Move Section",
                message: "The move couldn't be saved, so the sections are back in their earlier order. "
                    + "If you typed in the last moments, check that your text is still there."
            )
        }
    }
}

/// The reply of an editor-first CLICK call: the pending changes it consumed (always applied) and its verdict.
protocol EditorFirstOpReply: EditorFirstBatchReply {
    /// The editor's `ok`: false means the document is unchanged or restored and no registry entry was left.
    var succeeded: Bool { get }
    var reason: String? { get }
}

extension EditorFirstDeleteReply: EditorFirstOpReply {}

/// How a click ended, from the caller's seat.
enum EditorFirstClickOutcome<Reply: EditorFirstOpReply> {
    /// The editor did it and the caller's `afterReply` ran. The caller records the entry.
    case done(Reply)
    /// Nothing was consumed or changed: the old whole sequence runs next, in this same gate turn.
    case legacy
    /// The editor refused, or the bridge failed: the document is as it was. The rebuild stamp has been settled (D6a).
    case refused
    /// The editor refused with a reason the kind hands back to its caller (`EditorFirstOpKind.handsBackToCaller`; only the slow undo's
    /// `noCheckpoint`). The document is as it was, the batch has been applied, the pending count is down, and NO fresh settle was
    /// started: the caller goes on with another click of its own. Every other caller never receives it.
    case declined(Reply)
}

// MARK: - The shared click

extension StructuralUndoController {

    /// The shared stretch of an editor-first click, called under the structural gate after the caller has checked eligibility,
    /// set `efOpEpoch[opId]` and built `script`. In order: routine polls step aside (`structuralClickPending`; `contentState` is NOT
    /// touched, which would bump `contentGeneration` and discard a batch some routine cycle already fetched, finding M1); the
    /// rebuild stamp moves (D6); the one call is reserved as ticket N and submitted in ONE synchronous stretch, so reservation order
    /// equals execution order; the reply is read and its batch applied whatever the verdict (`consumeEditorFirstReply`).
    ///
    /// On a successful reply, `afterReply` runs INSIDE the poll pause: it is where the caller shows what the user sees change and
    /// reserves its job (`startEditorFirstJob`, which hands the raised `pendingEditorFirstJobs` over to the job), and the pause ends
    /// once it returns, i.e. once the job holds its place in the queue (D1.5).
    ///
    /// Every exit that reserved no job brings `pendingEditorFirstJobs` down here, at once (D6a). `.refused` also starts the fresh
    /// settle; `.legacy` does not, because the old body runs next and does its own full resync and push.
    func runEditorFirstStructuralClick<Reply: EditorFirstOpReply>( // swiftlint:disable:this function_parameter_count
        kind: EditorFirstOpKind, opId: UUID, script: String, replyType: Reply.Type,
        database: ProjectDatabase, projectId: String, trace: StructTrace,
        afterReply: (Reply) async -> Void
    ) async -> EditorFirstClickOutcome<Reply> {
        guard let editorState, let blockSync = blockSyncService else { return .legacy }

        // D1.2: routine polls step aside from here until the job holds its place.
        blockSync.structuralClickPending = true
        defer { blockSync.structuralClickPending = false }
        // UI-test seam FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS: dormant until the first editor-first structural click (a delete or a
        // duplicate), so the document load cannot use the one idle backup it allows.
        TestMode.armAutoBackupIdleSeamAfterStructuralClick()
        findBarState?.clearSearch()   // code review B-M2: the find bar's cached match positions belong to the document the click changes
        #if DEBUG
        if testEFBumpGenerationAtClick {
            // Addendum A10: U14's "old shape". Sets `contentState` non-idle and back before reserving, which bumps
            // `contentGeneration` the way the old whole-document sequence did.
            editorState.contentState = .structuralUndo
            editorState.contentState = .idle
        }
        spy("efClickStart")
        #endif

        // D6: the rebuild stamp moves in the click's synchronous stretch, before the JavaScript is sent (no `await` up to the submit).
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1

        // D1.3 and D1.4: reserve ticket N and submit the one call in ONE synchronous stretch, then apply whatever batch came back.
        guard let submission = await blockSync.submitEditorFirstCall(database: database, projectId: projectId, script: script) else {
            DebugLog.log(.undo, "[StructuralUndoController] editor-first \(kind.logName): no writer turn available -- old path for this press")
            releasePendingEditorFirstJob()
            return .legacy
        }
        spy("efJS")
        trace.log("after the editor-first JS call")
        guard let reply = consumeEditorFirstReply(
            submission, as: replyType, blockSync: blockSync, database: database, projectId: projectId, logName: kind.logName
        ) else {
            releasePendingEditorFirstJob()
            startFreshSettleAfterRefusedEditorFirstClick(opId: opId)
            return .refused
        }
        guard reply.succeeded else {
            releasePendingEditorFirstJob()
            if kind.handsBackToCaller(reason: reply.reason) {
                DebugLog.log(
                    .undo, "[StructuralUndoController] editor-first \(kind.logName): the editor has no saved state to swap in "
                    + "(\(reply.reason ?? "")) -- handed back to the caller")
                return .declined(reply)
            }
            if kind.refusalFallsBackToLegacy(reason: reply.reason) {
                // D7 (a restore): the editor changed nothing, the batch it consumed has just been applied, and the old restore runs in
                // this same gate turn. Its own full resync and push stand in for the fresh settle (D6a's exception). The line names the
                // project, so a test that looks for fallbacks sees only its own (the capture is scoped to one rig).
                DebugLog.alwaysPersisted(
                    "[EF-STRUCT] \(kind.logName) fell back to the old path: \(reply.reason ?? "no reason") (project \(projectId))")
                return .legacy
            }
            // `noEditor`: the editor had no document yet (a click in the first moment after a project opened). Nothing was consumed,
            // so this press takes today's whole sequence. That sequence finds no editor either (its `beginStructuralOp` answers
            // false), so it ends `.refused` and the user sees the same alert as for any refusal: this branch removes no alert (fix
            // round 2a, R2). It only keeps the editor-first path from reporting a refusal of its own.
            //
            // `rootNotFound` (round 1g-A, review A7): the editor holds no top-level node with the root's id. The database row and the
            // sidebar entry are confirmed, but the heading's id in the EDITOR is still a temporary one (a heading typed a moment ago
            // whose confirmation has not reached it). Same shape as `noEditor`: the call changed nothing (it fails before its first
            // change), the batch it consumed has just been applied by `consumeEditorFirstReply`, and the old whole sequence, which
            // flushes the editor and finds the section by the database's id, completes the press instead of a false refusal.
            if reply.reason == "noEditor" || reply.reason == "rootNotFound" {
                DebugLog.log(
                    .undo, "[StructuralUndoController] editor-first \(kind.logName): the editor could not take this press "
                    + "(\(reply.reason ?? "")) -- old path for this press")
                return .legacy
            }
            // The editor refused or failed and put everything back: the document is as it was.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first \(kind.logName) refused by the editor: \(reply.reason ?? "no reason")")
            startFreshSettleAfterRefusedEditorFirstClick(opId: opId)
            return .refused
        }

        await afterReply(reply)
        blockSync.structuralClickPending = false
        spy("efReservedJob")
        trace.log("after the job reserved its turn")
        return .done(reply)
    }

    // MARK: - The root of a click

    /// Whether an editor-first Delete or Duplicate click may take `rootId` as its section root (round 1g-A, review A1). Either the
    /// database agrees it is a leader that is neither Notes nor Bibliography (`isDeletableSectionRoot`, one indexed row), or it is a
    /// leader the sidebar shows only through an overlay (`EditorViewState.pendingRestoreSections`): the copy of a duplicate whose job
    /// has not committed yet, or a section a quick undo has put back whose reinsert has not. The row of such a leader is not in the
    /// table yet, but the job that puts it there was reserved earlier than the one this click would queue, and the writer runs
    /// reservations in order, so by the time the click's own job runs the row is there. A job that finds it missing anyway fails
    /// (`rootNotDuplicable`, `rootNotDeletable`) and the put-back gives the document back, as for any failed job.
    func editorFirstRootIsEligible(rootId: String, database: ProjectDatabase, projectId: String) -> Bool {
        if (try? database.isDeletableSectionRoot(rootId: rootId, projectId: projectId)) == true { return true }
        return editorState?.pendingRestoreSections.values.contains { leaders in leaders.contains { $0.id == rootId } } ?? false
    }

    /// An editor-first Delete has taken `removed` off the screen. A sidebar overlay that still lists some of them (the copy of an
    /// earlier duplicate whose job is still queued) must not show them again: the outline results merge every overlay in AFTER the
    /// pending removals are filtered out, so the copy's card would come back until the earlier job's settle lifted its overlay. The
    /// overlay entry itself stays (its owner lifts it, and the hierarchy check waits while any overlay exists).
    func dropFromSidebarOverlays(_ removed: Set<String>) {
        guard let editorState, !removed.isEmpty else { return }
        for (key, leaders) in editorState.pendingRestoreSections where leaders.contains(where: { removed.contains($0.id) }) {
            editorState.pendingRestoreSections[key] = leaders.filter { !removed.contains($0.id) }
        }
    }

    /// Brings `pendingEditorFirstJobs` down by one: a click that reserved no job, or a job whose future has resolved (D6, D6a).
    func releasePendingEditorFirstJob() {
        guard let editorState else { return }
        editorState.pendingEditorFirstJobs = max(0, editorState.pendingEditorFirstJobs - 1)
    }

    // MARK: - After a refused click

    /// The click bumped the entry's epoch (delete: `efOpEpoch` at the click) and the rebuild stamp before its JavaScript went out, and
    /// then reserved no job: a delete settle that reached its resync meanwhile skipped its steps, and a rebuild whose push the stamp
    /// skipped left the editor's Notes half updated (renumbered references, old Notes). One fresh settle under the new epoch,
    /// registered as unsettled work, puts the steps back (`resyncAfterEditorFirstDelete`) and, after any reinsert still pending has
    /// ended, one merge-guarded push with a fresh stamp makes the editor's Notes the database's (typing in user blocks survives).
    ///
    /// This is the quick undo's `startFreshSettleAfterRefusedRestore` (verdict-v3 D1, verdict-v4 V1), generalised; that name forwards
    /// here. The caller has already brought `pendingEditorFirstJobs` down, so this settle's own stamps are current.
    ///
    /// The marker is registered AND its job future resolved at once: this is follow-up work, not a job, so `outstandingCount` ("a job
    /// has not ended") stays 0 (a refused Delete Section queues no job, which a test pins), while `unsettledCount` holds until the
    /// settle ends and so keeps the close, quit, zoom, mode-switch, Save Version and export waits waiting for it. Nothing awaits this
    /// key's future: `efJobKeys` holds it only so a discard can forget it.
    func startFreshSettleAfterRefusedEditorFirstClick(opId: UUID) {
        guard let editorState else { return }
        let registry = editorState.efJobRegistry
        let key = UUID()
        registry.register(key)
        registry.resolve(key, .applied)
        efJobKeys[opId, default: []].append(key)
        let epoch = efOpEpoch[opId] ?? 0
        Task { @MainActor [weak self, weak editorState] in
            // Round 2d-i, review B1: nothing awaits this follow-up marker's future and, for a refused click, no entry exists whose discard
            // would forget it, so it is forgotten here once the settle has ended (the entry of a refused quick undo or redo, which does
            // exist, keeps its other keys).
            defer {
                registry.markSettled(key)
                registry.forget(key)
                self?.efJobKeys[opId]?.removeAll { $0 == key }
            }
            guard let self, let editorState else { return }
            // Code review G-F2: the text this settle works from is the editor's own, read first (the undo's `contentChanged` may
            // not have arrived); a quick undo or redo of any entry that starts meanwhile takes over (the generation, G-F1).
            let restoreGeneration = editorState.editorRestoreGeneration
            if let blockSync = self.blockSyncService {
                await editorState.adoptLiveEditorText(blockSync: blockSync, why: "the fresh settle after a refused editor-first click or restore")
            }
            guard editorState.editorRestoreGeneration == restoreGeneration else { return }
            await self.resyncAfterEditorFirstDelete(
                editorState: editorState, opId: opId, epoch: epoch, restoreGeneration: restoreGeneration)
            // A reinsert that is still pending (a refused redo right after a quick undo) must have ended before the push reads.
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: .seconds(15))
            while editorState.pendingReinsertCount > 0, clock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
            if (self.efOpEpoch[opId] ?? epoch) == epoch, editorState.activeLifecycle == nil {
                // The push also settles what a skipped rebuild owed the editor (round 1b-ii): the flag comes down when it went through.
                if await self.quickRepushManagedRegions(editorState: editorState) { editorState.managedRegionsNeedRepush = false }
            }
        }
    }

    // MARK: - The end of every editor-first settle

    /// The last step of `resyncAfterEditorFirstDelete` (shared by Delete Section now, and by Duplicate Section and the Version History
    /// restores in the next rounds), after the settle's own rebuilds have landed (`awaitNoRunningRebuilds`) and only while the settle is
    /// still wanted. Runs inside the settle's task, so the registry resolves the settle only after it, and a close begun meanwhile
    /// waits for it.
    ///
    /// (a) A lifecycle (close, quit, project switch) holds the editor: the existing closing push, UNCHANGED and unconditional on the
    ///     resync (the rebuild handlers are deferred while the lifecycle is armed, so nothing else carries the database's Notes into
    ///     the editor before the save captures it). The flag comes down when that push actually went through; a push skipped as stale
    ///     raises it again (`noteStalePushSkipped`).
    /// (b) Otherwise, when a rebuild's push was skipped for an editor-first reason (`managedRegionsNeedRepush`) AND no editor-first job
    ///     is pending any more: the flag comes down FIRST (a skip during this push raises it again) and the same push the quick undo's
    ///     settle makes (`quickRepushManagedRegions`) puts the database's Notes and Bibliography into the editor. With a job still
    ///     pending the flag stays up: that job's own settle is the last one to finish and sees both conditions (it waits for the
    ///     rebuilds this settle waited for).
    ///
    /// Nothing is pushed otherwise: the flag is the only reason, so a settle with no skipped rebuild behind it does exactly what it did
    /// before this tail existed.
    func settleManagedRegionsAtEndOfEditorFirstSettle(editorState: EditorViewState, projectId: String?) async {
        if editorState.activeLifecycle != nil {
            if await pushManagedRegionsWhileClosing(editorState: editorState, projectId: projectId) {
                editorState.managedRegionsNeedRepush = false
            }
        } else if editorState.managedRegionsNeedRepush, editorState.pendingEditorFirstJobs == 0 {
            editorState.managedRegionsNeedRepush = false
            await quickRepushManagedRegions(editorState: editorState)
        }
    }

    // MARK: - The job did not apply

    /// Plan D6: the database still holds the section plus every applied batch, so it is the truth. Put the document back from it
    /// with a whole-content push (deliberately NOT the merge-guarded one: the change must be undone everywhere), drop the entry, its
    /// slot and its pin, and tell the user (UX contract 4.3: a modal alert for an operation that did not happen; the wording is
    /// per kind, `EditorFirstOpKind.putBackAlert`). A put-back can overwrite typing from the last poll window (parked as rare, plan
    /// section 7, P9). The caller has already brought `pendingEditorFirstJobs` down, so the push's stamp is current.
    func putBackAfterFailedEditorFirstOp(kind: EditorFirstOpKind, opId: UUID, removedLeaders: Set<String>) async {
        guard let editorState, let unifiedUndoService else { return }
        defer {
            editorState.pendingRemovalIds.subtract(removedLeaders)
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            efRecordedGeneration[opId] = nil
            forgetQuickUndoState(opId)   // slice 2b: the holder (a pending reinsert keeps its own reference), the job keys, the generation
            editorState.pendingRestoreSections[opId] = nil
            // t-0b70d1e9: a failed reorder's overlay goes on every way out, the closed-gate return included
            editorState.liftPendingReorder(opId: opId)
        }
        unifiedUndoService.removeEntry(opId: opId)
        // Round 1g-A, review A8: the sidebar overlay that showed the copy before its rows existed goes FIRST, before anything below
        // suspends or asks for an outline refresh: the job failed, so the copy's rows never come, and an outline result computed from
        // here on must not merge its leaders back in. (The `defer` still clears it on the early exits.)
        editorState.pendingRestoreSections[opId] = nil
        // t-0b70d1e9: the same for a failed reorder, for the same reason: its rows never moved, so an outline result computed from here
        // on must show the database's (earlier) order, not the moved one.
        editorState.liftPendingReorder(opId: opId)
        // Remembered so that a Cmd-Z for this entry that was already on its way (held on the gate while this ran) is answered
        // `failed`, not `fallback`: the change was put back, and a plain text undo now would remove the user's last typing
        // (fix round 2a, item 12; see `resolveOutcome`).
        efPutBackOpIds.insert(opId)
        // A project that is closing has nothing to put back into: its content is saved by the lifecycle's own whole-document write.
        guard !editorState.structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[StructuralUndoController] D6 put-back skipped: the project is closing or switching")
            return
        }
        await evalVoid("window.FinalFinal.clearFailedStructuralOpEntry?.('\(opId.uuidString)')")
        // Slice 2b (verdict-v4 V4): stamped on the line before the database read; a put-back that a quick undo has overtaken is skipped
        // (harmless: the editor already shows the section, and the database still holds it).
        let stamp = editorState.stampRebuildRead()
        if let db = editorState.projectDatabase, let pid = editorState.currentProjectId,
           let result = fetchFullBlocksWithIds(db: db, pid: pid) {
            editorState.content = result.markdown
            editorState.isResettingContent = true
            await blockSyncService?.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex, cursorBoundaryEnd: result.bibBoundaryEndIndex,
                detectPausedEdits: true,
                expectedBlocks: result.expectedBlocks,
                managedBlockIds: result.managedBlockIds,
                stillWanted: { [weak editorState] in editorState?.rebuildPushStillWanted(stamp) ?? false }
            )
            editorState.isResettingContent = false
            NotificationCenter.default.post(
                name: .blockSyncDidPushContent, object: nil, userInfo: ["markdown": result.markdown]
            )
        } else {
            DebugLog.alwaysPersisted("[StructuralUndoController] D6 put-back: could not read the document back from the database")
        }
        await pushDescriptor()
        editorState.pendingRemovalIds.subtract(removedLeaders)
        editorState.refreshSections()
        #if DEBUG
        testShownAlerts.append(kind.putBackAlert.title)
        #endif
        presentAlert?(kind.putBackAlert)
    }
}
