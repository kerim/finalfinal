//
//  StructuralUndoController+MarkdownEditorFirstDuplicate.swift
//  final final
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 3: Duplicate Section as an editor-first command in Markdown mode
//  (plan-v1 "Core idea" and Step 2, plan-v1-addendum M2/M3/M4/M7, judge rulings; the page's side is
//  docs/architecture/write-queue-plan/phase4b-markdown/slice3-duplicate/page-contract.md). Today a Markdown Duplicate replaces the whole
//  document (`setContent`, no section markers); this click inserts the copy in ONE CodeMirror transaction instead, takes the typing and
//  the caret with it, and queues the existing Rich Text `SectionDuplicateJob` behind everything typed. Nothing is pushed back over the page.
//
//  THE IDEA: Swift mints a fresh UUID for every LEADER of the section's subtree BEFORE it calls the page and sends the pairs as `copyIds`.
//  The page writes each id into the copy's leader line as `<!-- @sid:NEW -->`; the queued job receives the same pairs as `copies`, so the
//  copy ROWS carry the ids the page's markers carry. The Outline card of the copy therefore finds the copy in the live page text (the
//  card click looks for the literal marker in `sourceContent`) both while the job is pending and after it, and later rebuilds agree.
//
//  THE CLICK (`performMarkdownEditorFirstDuplicate`, under the structural gate), the Delete's skeleton
//  (StructuralUndoController+MarkdownEditorFirst.swift) with the Duplicate's pieces:
//    1. guards: the kill switch, Markdown mode, NOT ZOOMED (the first condition: a Duplicate is refused while zoomed, and the old body
//       says so), a root the rows (or the overlay of an earlier command's copy) agree is a duplicable leader. A nil return takes the old body;
//    2. await the earlier command's hold (`awaitStructuralHoldReleased`), THEN look again at the lifecycle, the zoom (a zoom can begin
//       during the wait) and the mode. The rows are read only after this wait: the copy of a section made a moment ago has its rows once
//       the first job has applied, and the gate holds every next command until it did. The delayed "Finishing the last change…" notice is
//       made BEFORE the wait and belongs to the whole click, not to the wait: on a book the page call and the reply turn take seconds
//       too. A `defer` takes it down when the click returns, on every exit (performed, handed to the old body, refused by the page);
//    3. the hold, the click generation and the pending-jobs count (the `defer` releases them on every exit that did not hand them on).
//       The hold is also what keeps a zoom, Save Version, export and the idle backup out until the job is queued and step 8 has saved
//       the typing: the click registers no unsettled job before then, so `EditorViewState.awaitPendingStructuralJobs` and the user zoom's
//       pre-check wait for the writer's hold too (`hasUnfinishedStructuralWork`; held, never refused);
//    4. the pending re-parse is cancelled and the boundary hygiene is made (`prepareMarkdownPageForStructuralCommand`);
//    5. rows read, leader map built, `copyIds` minted (once: the retry below reuses the same ids), ONE call into the page,
//       `markdownStructuralDuplicate(request)`. On `leadersMismatch` the typing is flushed and the call is made once more; a second
//       mismatch, any other refusal or a JavaScript error adopts the page's live text into the record and returns nil (the old body runs);
//    6. the reply turn (`markdownDuplicateReplyTurn`, shared with the quick redo): one synchronous stretch after the writer's last write is
//       awaited (the typing batch up to the click, the page's text adopted, the sidebar overlay built from the ROWS of the subtree, the
//       step-8 gate, the job); only when the job reserved its place is the hold handed to the step-8 continuation;
//    7. the entry: `efRecordedGeneration`, `efRecordedStructGeneration`, `efEditorKind[opId] = .markdown`, `StructuralEntry(.sectionDuplicate)`.
//       NO bump of `structuralOutOfQueueGeneration` (that bump lives only in the old body): an earlier Delete stays quick-undoable.
//
//  THE UNDO AND REDO of the entry are the Markdown quick route (+MarkdownQuickUndo.swift): the undo hides the copy's leaders and reinserts
//  the rows before the op; the redo asks the page for its composed redo (`markdownStructuralSwap(opId, 'redo')`, no request) and runs this
//  file's reply turn again with the first click's copy ids, so the same ids come back on every cycle.
//
//  TRACE (for the real-app tests): `[STRUCT-TRACE] sectionDuplicate op=<id8> start (editor-first) mode=markdown`, then on a successful page
//  reply `[STRUCT-TRACE] sectionDuplicate-editor-first opId=<id8> ok=true mode=markdown copies=<n>`, then `performed`; or `fell back to the
//  old sequence (...)` when the page declined.
//

import Foundation
import WebKit

/// A `{from, to}` range of UTF-16 offsets in a page reply (`MarkdownDuplicateReply.inserted`). The page's `to` field is `end` here.
struct MarkdownDuplicateSpan: Decodable, Equatable {
    let from: Int
    let end: Int

    private enum CodingKeys: String, CodingKey {
        case from
        case end = "to"
    }
}

/// The page's answer to `markdownStructuralDuplicate` (web/codemirror/src/api-structural-markdown-duplicate.ts `MarkdownDuplicateResult`).
/// Only the fields Swift reads. `preRaw` and `postRaw` are the same two fields the Delete's reply carries; `insertedLeaders` is the page's
/// list of the copy's leaders, a CROSS-CHECK for the overlay Swift builds from the rows (the ids and the order are authoritative).
struct MarkdownDuplicateReply: Decodable, Equatable {
    let succeeded: Bool
    let reason: String?
    let detail: String?
    let preRaw: String?
    let postRaw: String?
    /// UTF-16 offsets of the inserted text in the post-op document (the copy and its blank-line separator).
    let inserted: MarkdownDuplicateSpan?
    let insertedLeaders: [InsertedLeader]?

    struct InsertedLeader: Decodable, Equatable {
        let id: String
        /// `heading` or `section_break`.
        let kind: String
        let level: Int
        let title: String
    }

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case reason
        case detail
        case preRaw
        case postRaw
        case inserted
        case insertedLeaders
    }
}

extension StructuralUndoController {

    /// One page call's result: the page's reply, the leader map it was built from, and the pairs it carried.
    struct MarkdownDuplicateAttempt {
        let reply: MarkdownDuplicateReply
        let map: MarkdownLeaderMap
        let copyIds: [MarkdownLeaderMap.DuplicateCopyId]
    }

    /// Duplicate Section, Markdown, editor first. Called under the structural gate. Returns nil, having changed nothing the old body cannot
    /// cope with, when this press has to take today's whole sequence (the switch is off, a zoom, a root that is no duplicable leader, a page
    /// that refused); otherwise the outcome the sidebar reports.
    func performMarkdownEditorFirstDuplicate(rootId: String) async -> StructuralOpOutcome? {
        guard MarkdownEditorFirstSwitch.enabled else { return nil }
        #if DEBUG
        if testForceLegacyStructural { return nil }
        #endif
        let outcome = await runMarkdownEditorFirstDuplicate(rootId: rootId)
        guard outcome == nil else { return outcome }
        // The click is over and its `defer` has released the hold; the old body runs next. The click cancelled the pending re-parse
        // (`prepareMarkdownPageForStructuralCommand`); if the old body then refuses before it flushes (for instance "Can't Duplicate
        // While Zoomed"), the typing would sit only in the page, so the re-parse is scheduled again from the record. The scheduler
        // applies its own gates (a lifecycle, a zoom, the writer's hold).
        rearmMarkdownReparseAfterRefusedPress()
        // O20 (D6), as the Delete: a rebuild whose push the click's stamp skipped has left the Notes and Bibliography as they were; with
        // no job coming to put them in, they are re-posted before the old body runs.
        if let editorState, editorState.managedRegionsNeedRepush {
            editorState.managedRegionsNeedRepush = false
            NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        }
        return nil
    }

    private func runMarkdownEditorFirstDuplicate(rootId: String) async -> StructuralOpOutcome? {
        // Step 1: the guards. The zoom check comes FIRST (before the root check, the leader map and the page call): a Duplicate is refused
        // while zoomed, and a nil return gives the press to the old body, which says "Can't Duplicate While Zoomed".
        guard let editorState, editorState.zoomedSectionId == nil, let unifiedUndoService, let blockSync = blockSyncService,
              let db = editorState.projectDatabase, let pid = editorState.currentProjectId, activeWebView != nil,
              editorState.editorMode == .source, editorState.markdownWriter.isEnabled,
              editorState.activeLifecycle == nil, !TestMode.isUITestingLegacyStructural,
              blockSync.writer?.database === db, blockSync.writer?.projectId == pid,
              editorFirstRootIsEligible(rootId: rootId, database: db, projectId: pid) else { return nil }
        let writer = editorState.markdownWriter

        // Round M1 measurement (MdSpeed.swift): the timeline starts here, at the menu click (it used to start after the hold wait and the
        // page preparation, which left those two steps outside it); `noteOpId` below gives it the op's short id. Silent unless tracing is on.
        StructuralTrace.beginOp(label: "sectionDuplicate")
        MdSpeed.mark("entered")
        let clickSpan = MdSpeed.span("click")
        defer { clickSpan.end() }

        // Step 2: an earlier Markdown command finishes saving first. Held, never refused. Duplicate, then Duplicate the copy at once, waits
        // here. ONE notice belongs to the whole click (UX contract 4.2: "Finishing the last change…"; floor 3: past one second the app
        // shows it is working): it is counted from the press, not from the end of the wait, and it stays through the page call and the
        // reply turn, which on a book take seconds. Under a second nothing shows. The `defer` takes it down by id (`stop()` is idempotent) on
        // every way out: performed, a nil return for the old body (whose own notices are made after this return), a refused page, a
        // changed timeline.
        let waiting = DelayedProgressToast(toastCenter: editorState.toastCenter, message: DelayedProgressToast.finishingMessage)
        defer { waiting.stop() }
        let holdWaitSpan = MdSpeed.span("holdWait")
        await writer.awaitStructuralHoldReleased()
        holdWaitSpan.end()
        // The wait can span a lifecycle, a zoom (zoom is not on the structural gate: the page then holds the zoomed text, which this click
        // must not copy a section of) or a mode switch; the old body, which knows the state, gets the press.
        guard editorState.activeLifecycle == nil, editorState.zoomedSectionId == nil, editorState.editorMode == .source else { return nil }

        // Step 3 (O7): the hold, and the `defer` that releases it on every early exit.
        let hold = writer.beginStructuralHold()
        var run = MarkdownDeleteRun()
        defer {
            if run.countRaised, !run.countHandedToJob { releasePendingEditorFirstJob() }
            if !run.handedOff { hold.release() }
        }
        editorState.editorFirstClickGeneration &+= 1
        editorState.pendingEditorFirstJobs += 1
        run.countRaised = true

        // Step 4: the pending re-parse is cancelled, and the boundary hygiene the old body does.
        await prepareMarkdownPageForStructuralCommand()

        // Step 5: the page call. The per-op epoch starts at the click (the job reads it as `epochAtClick`); a nil return clears it again.
        let opId = UUID()
        efOpEpoch[opId] = 1
        let trace = StructTrace(label: "sectionDuplicate", opId: String(opId.uuidString.prefix(8)))
        StructuralTrace.noteOpId(trace.opId)   // round M1: `beginOp` moved to the top of the click, so only the id is given here
        trace.log("start (editor-first) mode=markdown")
        let attempt = await sendMarkdownDuplicateWithRetry(opId: opId, rootId: rootId, database: db, projectId: pid)
        guard let attempt, attempt.reply.succeeded, let preRaw = attempt.reply.preRaw, let postRaw = attempt.reply.postRaw else {
            efOpEpoch[opId] = nil
            let why = attempt?.reply.reason ?? "no answer"
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown editor-first duplicate: the page refused or failed (\(why)) -- old path for this press")
            trace.log("fell back to the old sequence (the page refused or failed: \(why))")
            // The old body flushes the content record, which lags the page by its debounce: take the page's live text first.
            await adoptPageTextForTheOldBody(editorState)
            return nil
        }
        let copies = attempt.copyIds.map { DuplicatedBlock(sourceId: $0.source, newId: $0.new) }
        let insertedSpan = MdSpeed.span("insertedSections+crossCheck")
        let insertedSections = attempt.map.duplicateInsertedSections(rootId: rootId, copyIds: attempt.copyIds)
        crossCheckMarkdownDuplicate(reply: attempt.reply, copyIds: attempt.copyIds, sections: insertedSections, opId: opId)
        insertedSpan.end()
        DebugLog.log(.undo, "[STRUCT-TRACE] sectionDuplicate-editor-first opId=\(trace.opId) ok=true mode=markdown copies=\(copies.count)")

        // Step 6: the reply turn (shared with the quick redo): the writer's last write is awaited, then nothing suspends until the job holds
        // its place and the hold is handed on.
        let epoch = unifiedUndoService.generation
        let context = MarkdownJobContext(editorState: editorState, blockSync: blockSync, database: db, projectId: pid)
        await markdownDuplicateReplyTurn(
            opId: opId, rootId: rootId, jobKey: nil, copies: copies, insertedSections: insertedSections, preRaw: preRaw, postRaw: postRaw,
            context: context, hold: hold, run: &run)

        // Step 7: the entry. Nothing here touches `structuralOutOfQueueGeneration` (only the old body bumps it).
        guard unifiedUndoService.generation == epoch else {
            DebugLog.log(.undo, "[StructuralUndoController] markdown editor-first duplicate: timeline generation changed mid-click -- not recording")
            trace.log("timeline generation changed mid-click -- not recording")
            efSlots.remove(opId)
            editorState.efJobRegistry.forget(opId)
            forgetQuickUndoState(opId)
            return .failedAfterCommit
        }
        efRecordedGeneration[opId] = editorState.outOfQueueWriteGeneration
        efRecordedStructGeneration[opId] = editorState.structuralOutOfQueueGeneration
        efEditorKind[opId] = .markdown
        unifiedUndoService.record(StructuralEntry(id: opId, kind: .sectionDuplicate, title: "Duplicate Section", undoSnapshotId: nil))
        spy("efRecorded")
        let descriptorSpan = MdSpeed.span("pushDescriptor")
        await pushDescriptor()
        descriptorSpan.end()
        trace.log("performed")
        return .performed
    }

    // MARK: - The page call

    /// One call of `markdownStructuralDuplicate`: the rows read now, the leader map built from them, the `copyIds` for the subtree (each
    /// new id taken from `minted` when the retry already sent one for that leader), the request built, the page asked. nil: the rows
    /// cannot be read, the root is no duplicable leader in them, or the page did not answer with readable JSON (a JavaScript error).
    private func sendMarkdownDuplicate(
        opId: UUID, rootId: String, minted: inout [String: String], database: ProjectDatabase, projectId: String
    ) async -> MarkdownDuplicateAttempt? {
        guard let rows = try? MdSpeed.timed("fetchBlocks", { try database.fetchBlocks(projectId: projectId) }) else { return nil }
        let map = MdSpeed.timed("leaderMap") { MarkdownLeaderMap(rows: rows) }
        let copyIds = MdSpeed.timed("mintCopyIds") { map.mintDuplicateCopyIds(rootId: rootId, minted: &minted) }
        guard !copyIds.isEmpty, let json = MdSpeed.timed("requestJson", {
            map.duplicateRequest(opId: opId, rootId: rootId, copyIds: copyIds)?.json
        }) else { return nil }
        let pageCallSpan = MdSpeed.span("pageCall")
        let answer = await evalString("JSON.stringify(window.FinalFinal.markdownStructuralDuplicate(\(json)))")
        pageCallSpan.end("chars=\(answer?.utf16.count ?? 0)")
        guard let answer else { return nil }
        let decodeSpan = MdSpeed.span("replyDecode")
        let reply = try? JSONDecoder().decode(MarkdownDuplicateReply.self, from: Data(answer.utf8))
        decodeSpan.end()
        guard let reply else { return nil }
        return MarkdownDuplicateAttempt(reply: reply, map: map, copyIds: copyIds)
    }

    /// The page call with the B1 flush-and-retry once: a leader the page found does not match the rows (a heading typed or renamed a
    /// moment ago), so the typing is flushed and the call is made once more, from the rows as they are then and with the SAME minted ids
    /// for every leader that was already in the first request. nil: no usable answer.
    private func sendMarkdownDuplicateWithRetry(
        opId: UUID, rootId: String, database: ProjectDatabase, projectId: String
    ) async -> MarkdownDuplicateAttempt? {
        var minted: [String: String] = [:]
        var attempt = await sendMarkdownDuplicate(opId: opId, rootId: rootId, minted: &minted, database: database, projectId: projectId)
        if attempt?.reply.reason == "leadersMismatch" {
            guard await flushTypingForMarkdownRetry(projectId: projectId) else { return nil }
            attempt = await sendMarkdownDuplicate(opId: opId, rootId: rootId, minted: &minted, database: database, projectId: projectId)
        }
        return attempt
    }

    /// The page's `insertedLeaders` against what Swift sent and what the rows say: ids and order must be exactly the pairs' new ids (a
    /// difference is a broken contract and is persisted in the log); kind, level and title are compared too, but the page sees the title as
    /// raw heading text and a row's `textContent` can differ for formatted headings, so those differences are logged at `.undo` only.
    /// The overlay always comes from the rows.
    private func crossCheckMarkdownDuplicate(
        reply: MarkdownDuplicateReply, copyIds: [MarkdownLeaderMap.DuplicateCopyId],
        sections: [EditorFirstDuplicateReply.InsertedSection], opId: UUID
    ) {
        let pageLeaders = reply.insertedLeaders ?? []
        if pageLeaders.map(\.id) != copyIds.map(\.new) {
            DebugLog.alwaysPersisted(
                "[StructuralUndoController] markdown duplicate \(opId): the page's inserted leaders (\(pageLeaders.count)) are not the "
                + "\(copyIds.count) copy ids Swift sent, in order")
        }
        if sections.isEmpty {
            DebugLog.alwaysPersisted("[StructuralUndoController] markdown duplicate \(opId): no sidebar overlay could be built from the rows")
            return
        }
        for (pageLeader, section) in zip(pageLeaders, sections)
        where pageLeader.kind != section.kind || pageLeader.level != section.level || pageLeader.title != section.title {
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown duplicate \(opId): leader \(section.id.prefix(8)) differs between the page "
                + "(\(pageLeader.kind) \(pageLeader.level)) and the rows (\(section.kind) \(section.level)); the overlay uses the rows")
        }
    }

    // MARK: - The reply turn (the click and the quick redo)

    /// Step 6 of the click and of the quick redo: the writer's last write is awaited, then in ONE synchronous stretch the typing batch up to
    /// the command (`prepareStructuralClick`, never a whole-document write), `noteQueuedStructuralJob`, the page's text adopted into the
    /// content record (`adoptMarkdownPageText`, O11: from here the card click finds the copy's marker in `sourceContent`), the sidebar
    /// overlay for the copy (from the rows), the step-8 gate (made BEFORE the job starts: the settle may reach it at once) and the job
    /// through `startEditorFirstDuplicateJob` with `copiesAreLeadersOnly`. Once the starter has returned true the hold is HANDED OFF in the
    /// same synchronous turn (D2/O21): a continuation Task takes it and releases it in its own `defer`. When the job did not reserve its
    /// place there is no continuation: the gate is finished and the caller's `defer` releases the hold.
    ///
    /// `jobKey` is the quick redo's fresh registry key (nil for the click, whose job is keyed by the entry's id); it is also the key of the
    /// gate and of the continuation. A redo has marked its slot `reserved` before the job starts (`efSlots.markReserved`, as the Rich Text
    /// redo). `copies` are the first click's pairs on a redo, so the same ids come back.
    func markdownDuplicateReplyTurn( // swiftlint:disable:this function_parameter_count
        opId: UUID, rootId: String, jobKey: UUID?, copies: [DuplicatedBlock], insertedSections: [EditorFirstDuplicateReply.InsertedSection],
        preRaw: String, postRaw: String, context: MarkdownJobContext, hold: MarkdownStructuralHold, run: inout MarkdownDeleteRun
    ) async {
        let editorState = context.editorState
        let writer = editorState.markdownWriter
        let replyTurnSpan = MdSpeed.span("replyTurn")   // round M1 measurement: the whole reply turn, and each step inside it
        defer { replyTurnSpan.end() }
        // t-2fbe4c9b trigger (iii): the parse memo prepares the post-click text in the background while the wait below runs; step 8 reads it.
        writer.prewarmParse(raw: postRaw, projectId: context.projectId, database: context.database)
        let inFlightSpan = MdSpeed.span("inFlightWait")
        while let pending = writer.inFlight { await pending.value }
        inFlightSpan.end()
        let preText = MdSpeed.timed("recordText.pre") { MarkdownLeaderMap.recordText(fromRaw: preRaw) }
        let prepareClickSpan = MdSpeed.span("prepareStructuralClick")
        writer.prepareStructuralClick(
            text: preText, database: context.database, projectId: context.projectId,
            service: context.blockSync,
            refire: { [weak editorState] in editorState?.lifecycleHost?.scheduleSourceModeReparse(editorState?.content ?? "") })
        prepareClickSpan.end()
        writer.noteQueuedStructuralJob()
        let adoptSpan = MdSpeed.span("adopt")
        editorState.adoptMarkdownPageText(postRaw)   // O11: the record takes the page's text in this turn; nothing is pushed back
        adoptSpan.end()

        // The copy's leaders leave the removal filter a quick undo put them in (a redo; nothing to subtract for the click) and show in the
        // sidebar at once, kept by the overlay until the job has put their rows into the database.
        let sidebarSpan = MdSpeed.span("sidebar")
        editorState.pendingRemovalIds.subtract((efHolders[opId]?.snapshot().clickLeaderIds ?? []).union(copies.map(\.newId)))
        efDuplicateCopies[opId] = copies
        showDuplicateInSidebar(opId: opId, rootId: rootId, copies: copies, insertedSections: insertedSections, database: context.database)
        sidebarSpan.end()

        run.countHandedToJob = true   // the job's task brings `pendingEditorFirstJobs` down once its future has resolved
        let gate = MarkdownStep8Gate()
        writer.structuralHoldState.step8Gates[jobKey ?? opId] = gate
        efEditorKind[opId] = .markdown
        if jobKey != nil { efSlots.markReserved(opId) }   // the quick redo's fresh job, as the Rich Text redo
        let jobStartSpan = MdSpeed.span("jobStart")
        let reserved = await startEditorFirstDuplicateJob(
            opId: opId, rootId: rootId, copies: copies, database: context.database, projectId: context.projectId, jobKey: jobKey,
            ownsPendingJobCount: true, copiesAreLeadersOnly: true)
        jobStartSpan.end()
        // D2/O21: the hand-off is the same synchronous turn as the starter's return, no `await` in between.
        if reserved {
            run.handedOff = true
            let handOffSpan = MdSpeed.span("holdHandOff")
            startMarkdownHoldContinuation(hold: hold, opId: opId, jobKey: jobKey)
            handOffSpan.end()
        } else {
            gate.finish()   // no continuation will run step 8
        }
    }
}
