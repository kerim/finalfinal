//
//  StructuralUndoController+EditorFirstDuplicate.swift
//  final final
//
//  t-18b7fa48 Phase 4b, slice 3, round 1e-i (plan-v3 D1, D4, D6, D6a, D9, D16, C4; round verdicts 1a, 1b): "Duplicate Section" in
//  Rich Text without the freeze and without losing what the user types around it. The EDITOR inserts the copy first (one JavaScript
//  call, a few milliseconds, `duplicateSectionEditorFirst`, web/milkdown/src/api-section-duplicate.ts); the database follows as a
//  queued system-write job (`SectionDuplicateJob`), behind everything the user typed. Nothing is pushed back over the user's text.
//  It is the twin of `performEditorFirstDelete` (StructuralUndoController+EditorFirstDelete.swift) and stands on the same shared
//  click (`runEditorFirstStructuralClick`, StructuralUndoController+EditorFirstStructural.swift).
//
//    1. `performEditorFirstDuplicate(rootId:)`: the click. Returns nil when this press must take today's whole sequence instead
//       (Markdown mode, zoomed -- a duplicate is refused while zoomed today and stays so --, no writer turn, the UI-test legacy flag,
//       a root that is not a duplicable leader, an editor that has no document yet).
//    2. `startEditorFirstDuplicateJob(...)`: reserves the job and keeps the task that runs it and the work after it.
//    3. `showDuplicateInSidebar` / `hideDuplicateInSidebar`: what the sidebar shows at once (the copy's leaders after the click and
//       after a redo; none of them after the quick undo), before the database holds the rows.
//    4. `performQuickRedoOfDuplicate(_:)`: Cmd-Shift-Z of a quick-undone duplicate, a fresh editor-first duplicate under the same
//       operation id that REUSES the first click's copy ids (S9).
//
//  THE QUICK UNDO of a duplicate is the delete's (`undoSectionDeleteEditorFirst` swaps the pre-op checkpoint back in and reports the
//  copy's leaders in `removedLeaderIds`; `SectionReinsertJob` makes the table equal "the rows before the op" the duplicate job kept in
//  the payload holder, which removes the copy). Its wiring is in StructuralUndoController+QuickUndo.swift, branching on the entry's
//  kind.
//
//  THE RESERVATION WINDOW (round 1a verdict, "the uncovered hazard"). Typing into the copy and a forced poll in the gap between the
//  click's reply and the job's reservation would send an update for a row the database does not hold yet. The reply is read and its
//  job reserved without waiting for anything that can sit behind queued work: `consumeEditorFirstReply` is synchronous, the
//  `afterReply` closure runs the sidebar update (synchronous main-actor work, during which no poll task can run) and
//  `startEditorFirstDuplicateJob`, which creates the job's task and suspends ONCE, at `await reserved.wait()`. The task's first
//  statements run `SectionDuplicateJob.perform`, whose `performSystemWrite` runs its steps 1 to 4 (nesting check, wanted, writer and
//  identity, `reserveSystem`) without a suspension. So the only suspension between the reply and the reservation is that one hop onto
//  the main actor; it waits behind main-actor turns already queued, never behind the writer's queue, a JavaScript call or a
//  database call. That keeps the window as the judge's RARE case (a keystroke into the copy AND a forced poll reserved inside the
//  hop). Typing in the copy that reaches the database before the job exists is applied as an update for an unknown id, which
//  `processEditorUpdates` logs and skips (Database+Blocks.swift: "Block not found for update", `.data`).
//

import SwiftUI
import GRDB

// MARK: - The reply

/// The JavaScript reply of `duplicateSectionEditorFirst` and `redoSectionDuplicateEditorFirst` (web/milkdown/src/api-section-duplicate.ts).
/// Only the fields Swift uses. On a failure `copies`, `insertedLeaderIds` and `insertedSectionsSnapshot` are empty. The editor also
/// sends `predecessorId`; nothing here reads it (the database places the copy by sort order), so it is not decoded (round 2d-i, review
/// B4) -- the decoder ignores keys it does not name, so a reply that carries it still decodes.
struct EditorFirstDuplicateReply: EditorFirstOpReply {
    /// Present on EVERY path (even a failed one) and ALWAYS applied: the pending changes the call consumed.
    let batch: BlockChanges
    let succeeded: Bool
    let reason: String?
    /// One entry per copied top-level block, in document order: the editor's id for the source at the click (a temp id the writer has
    /// not confirmed yet is possible: it is resolved through the writer's id map when the job runs) and the permanent id the copy got.
    let copies: [DuplicatedBlock]
    /// The new ids of the copy's section leaders (headings and section breaks), in document order.
    let insertedLeaderIds: [String]
    /// What the sidebar needs to show each leader of the copy at once.
    let insertedSectionsSnapshot: [InsertedSection]

    struct InsertedSection: Decodable, Equatable {
        let id: String
        /// `heading` or `section_break`.
        let kind: String
        let level: Int
        /// The copy's own text (the root heading's with " copy"); empty for a section break.
        let title: String
    }

    private enum CodingKeys: String, CodingKey {
        case batch
        case succeeded = "ok"
        case reason
        case copies
        case insertedLeaderIds
        case insertedSectionsSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batch = try container.decode(BlockChanges.self, forKey: .batch)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        copies = try container.decodeIfPresent([DuplicatedBlock].self, forKey: .copies) ?? []
        insertedLeaderIds = try container.decodeIfPresent([String].self, forKey: .insertedLeaderIds) ?? []
        insertedSectionsSnapshot = try container.decodeIfPresent([InsertedSection].self, forKey: .insertedSectionsSnapshot) ?? []
    }
}

// MARK: - The click

extension StructuralUndoController {

    /// Duplicate Section, editor first (plan-v3 D1, D4). Called under the structural gate. Returns nil, having changed nothing, when
    /// this press has to take today's whole sequence; otherwise the outcome the sidebar reports.
    func performEditorFirstDuplicate(rootId: String) async -> StructuralOpOutcome? {
        guard let editorState, let unifiedUndoService, blockSyncService != nil,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId else { return nil }
        #if DEBUG
        if testForceLegacyStructural { return nil }
        #endif
        // Rich Text, not zoomed (a duplicate is refused while zoomed, and the old sequence says so), and a root the database agrees is
        // a leader that is neither Notes nor Bibliography (the same yes or no `sectionBlockIds` gives, from ONE indexed row), or a
        // leader the sidebar shows through an overlay whose job has not committed yet (round 1g-A, review A1: Duplicate the copy of
        // the duplicate you just made; `editorFirstRootIsEligible`). An unknown id is today's refusal, which the old sequence reports
        // exactly as before.
        let guardStartMs = StructTrace.nowMs()
        guard !TestMode.isUITestingLegacyStructural,
              editorState.editorMode == .wysiwyg, editorState.zoomedSectionId == nil,
              editorFirstRootIsEligible(rootId: rootId, database: db, projectId: pid) else { return nil }
        let guardMs = StructTrace.nowMs() - guardStartMs

        let opId = UUID()
        efOpEpoch[opId] = 1   // the per-op epoch starts at the click, as the delete's
        guard let built = editorFirstScript(
            function: "duplicateSectionEditorFirst", opId: opId, rootId: rootId, database: db, projectId: pid, logName: "duplicate"
        ) else {
            efOpEpoch[opId] = nil
            return nil
        }
        let trace = StructTrace(label: "sectionDuplicate", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "sectionDuplicate", opId: trace.opId)
        trace.log("start (editor-first) guardMs=\(guardMs) managedIdsMs=\(built.managedIdsMs)")
        let epoch = unifiedUndoService.generation

        let outcome = await runEditorFirstStructuralClick(
            kind: .sectionDuplicate, opId: opId, script: built.script, replyType: EditorFirstDuplicateReply.self,
            database: db, projectId: pid, trace: trace
        ) { reply in
            // What the user sees changes NOW, in the reply's own main-actor turn (synchronous: no poll task runs inside it): the
            // copy's leaders appear in the sidebar, kept by an overlay until the job has put their rows into the database.
            efDuplicateCopies[opId] = reply.copies
            showDuplicateInSidebar(opId: opId, rootId: rootId, reply: reply, database: db)
            // Reserve the job and wait for its `onReserved` before the poll pause is lifted. The job takes over the raised
            // `pendingEditorFirstJobs` and brings it down when its future has resolved.
            await startEditorFirstDuplicateJob(
                opId: opId, rootId: rootId, copies: reply.copies, database: db, projectId: pid, ownsPendingJobCount: true)
        }
        switch outcome {
        case .legacy, .declined:   // (`.declined` goes only to the slow undo, which hands `noCheckpoint` back: never here)
            efOpEpoch[opId] = nil
            return nil
        case .refused:
            efOpEpoch[opId] = nil   // round 2d-i, review B1: the refused click never becomes an entry (the fresh settle holds its own copy)
            return .refused
        case .done:
            break
        }

        guard unifiedUndoService.generation == epoch else {
            // A barrier invalidated the timeline while the click ran: recording now would put an entry on a timeline that is no
            // longer this section's. The duplicate happened (and is saved), but cannot be undone with Cmd-Z.
            DebugLog.log(.undo, "[StructuralUndoController] editor-first duplicate: timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)   // round 2d-i, review B1: the entry's job record would otherwise stay for the session
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionDuplicate, title: "Duplicate Section", undoSnapshotId: nil))
        spy("efRecorded")
        await pushDescriptor()
        trace.log("performed")
        return .performed
    }

    // MARK: - The job

    /// Opens the entry's slot, registers its job future, and spawns the job (`SectionDuplicateJob.perform`, a `.sectionDuplicate`
    /// system write). Returns once the job holds its place in the writer's queue (its `onReserved` fired, or it came back without
    /// reserving), never when it applies. The task that runs the job and the work after it is kept in `efSettleTasks`.
    ///
    /// `jobKey` (the quick redo): a fresh registry key, because `EFJobRegistry.register` hands back the record already there for a
    /// repeated id. The payload holder is created at the first click and handed to every job of the entry.
    ///
    /// `ownsPendingJobCount` (D6): the caller is an editor-first CLICK that raised `EditorViewState.pendingEditorFirstJobs`; the job's
    /// task brings it down as soon as the job's future has resolved, BEFORE the settle or the put-back starts (their rebuild stamps
    /// must see the count already lowered: round 1b, addendum must-fix 1). The quick redo raises the count in its own stretch too
    /// (round 1g-B, review A3) and passes true.
    @discardableResult
    func startEditorFirstDuplicateJob(
        opId: UUID, rootId: String, copies: [DuplicatedBlock], database: ProjectDatabase, projectId: String,
        jobKey: UUID? = nil, ownsPendingJobCount: Bool = false
    ) async -> Bool {
        guard let editorState else { return false }
        efSlots.open(opId)
        let registry = editorState.efJobRegistry
        let registryKey = jobKey ?? opId
        registry.register(registryKey)
        let holder = efHolders[opId] ?? SectionDeletePayloadHolder(opId: opId, rootId: rootId, projectId: projectId)
        efHolders[opId] = holder
        holder.setFootnoteCheckpointMarker(Set((footnoteSyncService?.undoCheckpoints ?? []).map(\.id)))
        // The quick redo's caller has already listed the key in `efJobKeys` (round 2d-i, review B1: it used to be appended twice).
        if let jobKey { efLatestJobKey[opId] = jobKey }
        let epochAtClick = efOpEpoch[opId] ?? 0
        var heldJob = SectionDuplicateJob(
            opId: opId, rootBlockId: rootId, projectId: projectId,
            fallbackBibliographyTitle: ExportSettingsManager.shared.effectiveBibliographyHeaderName, slots: efSlots)
        heldJob.copies = copies
        heldJob.bodyHold = jobBodyHold()
        heldJob.holder = holder
        heldJob.registryKey = jobKey
        let job = heldJob
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let reserved = EFReservationSignal()
        let settleTask = Task { @MainActor [weak self, weak weakBlockSync = blockSyncService] in
            StructuralTrace.log("job task started")
            // D6: the pending-jobs count comes down once, when the job's future has resolved (or on the way out of here, whichever
            // comes first), and always BEFORE the settle or the put-back below starts.
            var pendingCountReleased = !ownsPendingJobCount
            @MainActor func releasePendingCount() {
                guard !pendingCountReleased else { return }
                pendingCountReleased = true
                self?.releasePendingEditorFirstJob()
            }
            // The job AND the work after it are over on every way out of here: whoever waits for the duplicate (the close/quit wait,
            // the zoom, the switch to Markdown, Save Version, export) is let go only now, not when the job's future resolved.
            defer {
                releasePendingCount()
                registry.markSettled(registryKey)
            }
            guard let blockSync = weakBlockSync else {
                reserved.fire()
                registry.resolve(registryKey, .abandoned)
                return
            }
            let result = await job.perform(
                on: blockSync, identity: identity, registry: registry,
                onReserved: {
                    StructuralTrace.log("onReserved fired")
                    reserved.fireReserved()
                })
            releasePendingCount()   // the job has ended: the settle's own rebuilds read the table after it and must stamp as current
            reserved.fire()   // `perform` returned without reserving (refused before step 4): never leave the click waiting
            var idsDisagree = false
            if case .applied(let output) = result.outcome, let mismatch = output.copiesMismatch {
                // The editor's copies and the rows differ (D4): the copy was made, the rows the editor had no id for got fresh ones.
                // Round 1g-C (review A2): the settle then pushes the database's ids to the editor, so both sides agree again.
                idsDisagree = true
                DebugLog.alwaysPersisted(
                    "[StructuralUndoController] editor-first duplicate \(opId): duplicateCopiesMismatch: \(mismatch)")
            }
            await self?.editorFirstJobSettled(
                opId: opId, outcome: JobOutcome(result.outcome), removedLeaders: [], epoch: epochAtClick, jobKey: jobKey,
                kind: .sectionDuplicate, pushesDatabaseBlockIds: idsDisagree)
        }
        efSettleTasks[opId] = settleTask
        await reserved.wait()
        return reserved.didReserve
    }

    // MARK: - Ids that disagree

    /// Round 1g-C, review A2: the duplicate job reported that the editor's copies and the rows it inserted differ (a node of the
    /// editor's got a fresh id the editor does not hold, an editor copy matched no row, a copy was matched by position), so typing
    /// into such a node would be an update for an id the table lacks, which `processEditorUpdates` drops. This puts the database's
    /// ids onto the editor's nodes (`pushBlockIds`), as the idle backup's and Save Version's flush do after they re-mint ids.
    ///
    /// Only here, in the settle of a duplicate whose job applied and reported a difference, never on every duplicate. It follows the
    /// settle's own rules: the entry must still be this settle's (`efOpEpoch`, `editorRestoreGeneration`: a quick undo or redo has
    /// replaced the document and re-derives everything), and no close, quit or switch may be armed (their whole-document save
    /// re-mints the ids itself, and a cancelled one re-pushes them: `EditorViewState+LifecycleAbort`). The ordered forced poll comes
    /// first, so the editor's pending changes are in the table before it is read and the ids are assigned by position against the
    /// document the editor holds; a poll that did not complete pushes nothing (the table could be older than the editor, and a
    /// positional push onto a longer document would put ids on the wrong blocks).
    func pushDatabaseBlockIdsAfterCopiesMismatch(editorState: EditorViewState, opId: UUID, epoch: Int) async {
        guard let blockSync = blockSyncService else { return }
        let restoreGeneration = editorState.editorRestoreGeneration
        func wanted() -> Bool {
            (efOpEpoch[opId] ?? epoch) == epoch && editorState.editorRestoreGeneration == restoreGeneration
                && editorState.activeLifecycle == nil && editorState.editorMode == .wysiwyg && editorState.zoomedSectionId == nil
        }
        guard wanted() else {
            DebugLog.log(.undo, "[StructuralUndoController] duplicate settle \(opId): id push skipped (entry taken or a lifecycle armed)")
            return
        }
        guard await blockSync.pollBlockChangesNowForDatabaseRebuild(), wanted() else {
            DebugLog.log(.undo, "[StructuralUndoController] duplicate settle \(opId): id push skipped (poll incomplete or entry taken)")
            return
        }
        await blockSync.pushBlockIds()
        DebugLog.log(.undo, "[StructuralUndoController] duplicate settle \(opId): pushed the database's block ids (the copies differed)")
    }

    // MARK: - The sidebar

    /// Shows the copy's leaders in the sidebar before the database holds their rows (the click, and the quick redo). They go into
    /// `sections` at once and into an overlay (`pendingRestoreSections`, the one the quick undo of a delete uses) that every outline
    /// result merges in until the job has applied (`editorFirstJobSettled` lifts it). Each leader takes the original's status, tags
    /// and goals when the original's row can be read (its id is the editor's `sourceId`; a temp id the writer has not confirmed is not
    /// in the table yet, and that leader is built from the snapshot alone), so the card does not change when the real row arrives.
    /// The copy goes right after the last outline entry of the original section (the sidebar's own list: the section's root and
    /// everything below it, never into Notes or Bibliography).
    func showDuplicateInSidebar(opId: UUID, rootId: String, reply: EditorFirstDuplicateReply, database: ProjectDatabase) {
        guard let editorState, !reply.insertedSectionsSnapshot.isEmpty else { return }
        let projectId = editorState.currentProjectId ?? ""
        let sourceByNew = Dictionary(reply.copies.map { ($0.newId, $0.sourceId) }, uniquingKeysWith: { first, _ in first })
        let sourceIds = reply.insertedSectionsSnapshot.compactMap { sourceByNew[$0.id] }.filter { !$0.isEmpty && !$0.hasPrefix("temp-") }
        let originals: [String: Block] = sourceIds.isEmpty ? [:] : Dictionary(
            ((try? database.read { try Block.filter(keys: sourceIds).fetchAll($0) }) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let sections = editorState.sections
        let rootSort = sections.first { $0.id == rootId }?.sortOrder ?? 0
        var leaders: [Block] = []
        for (index, section) in reply.insertedSectionsSnapshot.enumerated() {
            var block = sourceByNew[section.id].flatMap { originals[$0] } ?? Block(
                projectId: projectId, sortOrder: rootSort, blockType: section.kind == "section_break" ? .sectionBreak : .heading,
                headingLevel: section.kind == "heading" ? section.level : nil, isPseudoSection: section.kind == "section_break")
            block.id = section.id
            block.projectId = projectId
            block.parentId = nil
            // Only the old-sort-order fallback reads this (an anchor places the leaders): just after the original section's root.
            block.sortOrder = rootSort + 0.5 + Double(index) * 0.001
            if section.kind == "heading" {
                block.textContent = section.title
                block.headingLevel = section.level
            }
            leaders.append(block)
        }
        let anchor = Self.sidebarAnchorForCopy(ofRoot: rootId, in: sections)
        if let anchor { editorState.pendingRestoreAnchors[opId] = anchor }
        editorState.pendingRestoreSections[opId] = leaders
        let restored = PendingRestore(leaders: leaders.map { SectionViewModel(from: $0) }, anchor: anchor)
        editorState.sections = SidebarRestoreOverlay.merging([restored], into: sections)
        editorState.recalculateParentRelationships()
        editorState.refreshSections()
    }

    /// The anchor for a copy of the section rooted at `rootId`: right after the last entry of the sidebar's list that belongs to that
    /// section (the entries below the root with a deeper level, up to the next one at the same or a higher level, a Notes or a
    /// Bibliography entry). Nil when the root is not in the list.
    static func sidebarAnchorForCopy(ofRoot rootId: String, in sections: [SectionViewModel]) -> RestoreAnchor? {
        guard let rootIndex = sections.firstIndex(where: { $0.id == rootId }) else { return nil }
        let rootLevel = sections[rootIndex].headerLevel
        var last = rootIndex
        var index = rootIndex + 1
        while index < sections.count, !sections[index].isBibliography, !sections[index].isNotes, sections[index].headerLevel > rootLevel {
            last = index
            index += 1
        }
        return .after(sections[last].id)
    }

    /// The quick undo of a duplicate takes the copy out: its leaders leave the sidebar and every outline result at once (the delete
    /// click's own steps), and stay out until the reinsert has removed their rows (`reinsertSettled`) or a redo shows them again.
    ///
    /// Only the COPY's leaders leave (round 1g-B, review A5). The editor's `removedLeaderIds` is "the live leaders whose id the
    /// checkpoint's id map lacks" (api-section-undo.ts), and a flush that re-mints the ids of non-heading blocks (the idle backup, Save
    /// Version, export: `flushLiveContentToDatabase` then `pushBlockIds`) between the duplicate and the undo makes that list every
    /// section break of the document, the original sections' included; hiding them would empty the sidebar of its section-break cards
    /// until the reinsert settles. So the set is cut down to the ids the click or the redo reported for the copy (`efDuplicateCopies`
    /// holds the new id of every copied top-level block, a superset of the reply's `insertedLeaderIds`; a leader of the document is
    /// never one of them unless it is the copy's own). When nothing is left (the copy's own ids were re-minted too) nothing is hidden
    /// and the settle's outline refresh shows the right list.
    ///
    /// `ownIds` (round 2d-ii): the ids the operation made, when they are not a duplicate's `efDuplicateCopies` (a restore as duplicate
    /// knows them from its plan). The rule is the same: only the operation's own leaders are hidden.
    func hideDuplicateInSidebar(opId: UUID, removedLeaderIds: Set<String>, holder: SectionDeletePayloadHolder, ownIds: Set<String>? = nil) {
        guard let editorState else { return }
        let hidden = removedLeaderIds.intersection(ownIds ?? Set((efDuplicateCopies[opId] ?? []).map(\.newId)))
        holder.setClickLeaderIds(hidden)   // what `pendingRemovalIds` holds for this entry; the settle releases them
        editorState.pendingRemovalIds.formUnion(hidden)
        editorState.pendingRestoreSections[opId] = nil
        guard !hidden.isEmpty else {
            DebugLog.log(
                .undo, "[StructuralUndoController] quick undo \(opId): none of the \(removedLeaderIds.count) leader(s) the editor took out "
                + "is one the copy was made with -- the sidebar is left to the settle's refresh")
            return
        }
        var visibleSections = editorState.sections
        visibleSections.removeAll { hidden.contains($0.id) }
        editorState.sections = visibleSections
        editorState.recalculateParentRelationships()
    }

    // MARK: - The quick redo

    /// Cmd-Shift-Z of a quick-undone duplicate: a fresh editor-first duplicate of the document as it is NOW, under the same operation
    /// id (`redoSectionDuplicateEditorFirst`), the new copy taking the SAME ids as the first click's (S9: a later Cmd-Z of something
    /// done to the copy, or a delete of the copy redone after this, finds the rows it expects). Its job is queued behind the undo's
    /// reinsert in ticket order, under a fresh registry key. The shape of `performQuickRedoOfDelete`.
    func performQuickRedoOfDuplicate(_ entry: StructuralEntry) async -> UndoResult {
        guard let editorState, let blockSync = blockSyncService, let unifiedUndoService, let db = editorState.projectDatabase,
              let pid = editorState.currentProjectId, let holder = efHolders[entry.id] else { return .failed }
        let opId = entry.id
        let trace = StructTrace(label: "redo", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.beginOp(label: "redo", opId: trace.opId)
        trace.log("start (quick, duplicate)")
        let timelineEpoch = unifiedUndoService.generation
        guard let copiesLiteral = Self.jsLiteral(efDuplicateCopies[opId] ?? []), let built = editorFirstScript(
            function: "redoSectionDuplicateEditorFirst", opId: opId, rootId: holder.rootId, database: db, projectId: pid,
            logName: "duplicate redo", extraArguments: [copiesLiteral]
        ) else {
            return await abandonQuickRedo(opId: opId, reason: "managedIdsUnreadable", trace: trace, changedEpoch: false)
        }

        // THE ONE SYNCHRONOUS STRETCH, as the delete's quick redo: epoch and generation up, the debounces cancelled, the redo job's
        // unsettled marker registered under its fresh key, ticket reserved and the JavaScript handed to the web view.
        blockSync.structuralClickPending = true
        defer { blockSync.structuralClickPending = false }
        findBarState?.clearSearch()
        bumpEpoch(opId)
        editorState.editorRestoreGeneration += 1
        // Round 1g-B, review A3: the redo is an editor-first change like the click, so the rebuild stamp moves the click's way. The
        // restore generation above covers a rebuild that stamped BEFORE this stretch; the click generation and the pending count cover
        // one that stamps AFTER the reply and reads a table that has no copy yet (the redo's job has not committed, and the undo's
        // reinsert, which the generation alone would cover, may have applied long ago). The job takes the count over
        // (`ownsPendingJobCount`); every exit below that reserves no job brings it down in `abandonQuickRedo`.
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        footnoteSyncService?.cancelPendingDebounce()
        bibliographySyncService?.cancelPendingDebounce()
        let redoKey = UUID()
        editorState.efJobRegistry.register(redoKey)
        efJobKeys[opId, default: []].append(redoKey)
        let submission = await blockSync.submitEditorFirstCall(database: db, projectId: pid, script: built.script)

        guard let submission else {
            return await abandonQuickRedo(opId: opId, redoKey: redoKey, reason: "noWriterTurn", trace: trace, changedEpoch: true)
        }
        spy("quickRedoJS")
        guard let reply = consumeEditorFirstReply(
            submission, as: EditorFirstDuplicateReply.self, blockSync: blockSync, database: db, projectId: pid, logName: "duplicate redo"
        ) else {
            return await abandonQuickRedo(opId: opId, redoKey: redoKey, reason: "unreadableReply", trace: trace, changedEpoch: true)
        }
        guard reply.succeeded else {
            return await abandonQuickRedo(
                opId: opId, redoKey: redoKey, reason: reply.reason ?? "refused", trace: trace, changedEpoch: true)
        }
        // The footnote checkpoint hold of the undo ends only now that the redo has really happened (see the delete's redo).
        if let token = holder.takeCheckpointHoldToken() { footnoteSyncService?.releaseUndoCheckpointHold(token: token) }
        forgetCommittedDerivedState()
        trace.log("quick duplicate done copied=\(reply.copies.count) leaders=\(reply.insertedLeaderIds.count)")

        // What the user sees: the copy's leaders come back into the sidebar (the same ids as before: S9) and leave the removal filter
        // the undo put them in.
        editorState.pendingRemovalIds.subtract(holder.snapshot().clickLeaderIds.union(reply.insertedLeaderIds))
        efDuplicateCopies[opId] = reply.copies
        showDuplicateInSidebar(opId: opId, rootId: holder.rootId, reply: reply, database: db)
        sectionSyncService?.cancelPendingSync()
        sectionSyncService?.resetSyncTracking()

        // The new duplicate job goes behind every ticket reserved so far, a pending reinsert included.
        efSlots.markReserved(opId)
        let reservedForReal = await startEditorFirstDuplicateJob(
            opId: opId, rootId: holder.rootId, copies: reply.copies, database: db, projectId: pid, jobKey: redoKey,
            ownsPendingJobCount: true)
        blockSync.structuralClickPending = false
        trace.log("duplicate job reserved")
        spy("quickRedoJobReserved")
        if !reservedForReal {
            // The new job's own settle runs the D6 put-back (the copy is taken out again from the database and the entry is dropped).
            DebugLog.alwaysPersisted("[StructuralUndoController] quick redo \(opId): the duplicate job could not be reserved")
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration

        guard unifiedUndoService.generation == timelineEpoch, case .performed = unifiedUndoService.performRedo(opId: opId) else {
            DebugLog.log(
                .undo, "[StructuralUndoController] quick redo \(opId): the timeline changed mid-sequence -- the copy is on the "
                + "screen and its duplicate job is queued; reporting .failed")
            return .failed
        }
        await pushDescriptor()
        spy("quickRedoPerformed")
        trace.log("performed")
        return .performed
    }
}
