//
//  MarkdownBlockWriter+ZoomedWrite.swift
//  final final
//
//  Phase 5 job A8, slice 1 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, section 2): the zoomed Markdown save goes
//  onto the ordered write queue. Until now the zoomed re-parse (`scheduleZoomedReparse`) wrote straight to the rows with
//  `flushContentToDatabase` (`replaceBlocksInRange`), outside the queue the unzoomed per-block save has used since Phase 4a. Now it reserves
//  an editor turn exactly as the per-block write does (`reserveMarkdownTurn`, synchronous, in the same main-actor turn as its guard check),
//  and the turn's body runs the extracted zoomed write (`EditorViewState.applyZoomedRangeWrite`) on the main actor with the text captured at
//  the reservation. The write is published as the writer's `inFlight`, so a debounce fire and `writeNow` wait for it as for any write.
//  In the sync model this is `MdPerBlockQueue`'s write (`P5_PB_Source_Zoom_Carry`): the same queue actor, one more kind of turn.
//
//  The design names it a "zoomed mode" of `writeNow`; it is its own entry, `writeZoomedNow`, with `writeNow`'s answers, because neither
//  older caller of `writeNow` is ever zoomed and `writeNow` is left exactly as it was. The lifecycle's whole-document save while zoomed
//  (`LifecycleWholeDocumentWrite.prepare(zoomedRange:)`) is unchanged.
//

import Foundation

extension MarkdownBlockWriter {
    /// Where the queued zoomed write's apply task leaves its result and its `inFlight` token.
    @MainActor
    private final class ZoomedWriteBox {
        var token: Int?
        var landed = false
    }

    /// The queued zoomed write: wait for the write in flight, re-check the guards, reserve a turn, then (when the turn comes) write the text
    /// over the zoom range, and wait for that. Same answers as `writeNow`: `.proceeded` when the text is in the rows; `.abandoned` when a
    /// guard failed (the debounce is re-armed) or the zoom moved on since the reservation; `.fallBackToDirectWrite` when no turn could be
    /// had (no writer, another project's writer, an unreadable epoch) or the write failed while every guard still holds.
    func writeZoomedNow(
        overrideContent: String?,
        editorState: EditorViewState,
        guardsHold: @MainActor () -> Bool,
        refire: @escaping @MainActor () -> Void
    ) async -> WriteNowOutcome {
        editorState.blockReparseTask?.cancel()
        editorState.blockReparseTask = nil
        await awaitQuietWriter(bypassingStructuralHold: false)
        guard guardsHold() else {
            DebugLog.log(.lifecycle, "[MdWrite] zoomed write: a guard failed after waiting for the write in flight; nothing written")
            refire()
            return .abandoned
        }
        guard let database = editorState.projectDatabase, let projectId = editorState.currentProjectId,
              let service = editorState.blockSyncService, isEnabled else { return .fallBackToDirectWrite }
        let text = overrideContent ?? editorState.switchInProgressContent ?? editorState.content
        guard !text.isEmpty else { return .fallBackToDirectWrite }
        guard editorState.zoomedBlockRange != nil else {
            // The direct flush's own skip: a zoom whose range is not known yet (or is being recovered) writes nothing.
            DebugLog.log(.zoom, "[FLUSH] SKIP: zoom in-flight, no block range yet")
            return .abandoned
        }
        guard case .reserved(let turn) = service.reserveMarkdownTurn(database: database, projectId: projectId) else {
            return .fallBackToDirectWrite
        }
        let epoch = editorState.zoomEpoch
        let box = ZoomedWriteBox()
        let apply = Task { @MainActor [weak self, weak editorState] in
            defer {
                turn.ticket.settleIfOpen(.noBatch)
                if let token = box.token { self?.clearInFlight(token: token) }
            }
            guard await turn.ticket.waitForTurn() == .go else {
                DebugLog.log(.lifecycle, "[MdWrite] zoomed write skipped at the wait seq=\(turn.ticket.seq)")
                return
            }
            box.landed = editorState?.applyZoomedWriteAtTurn(text, database: database, projectId: projectId, epoch: epoch, seq: turn.ticket.seq)
                ?? false
        }
        box.token = publishInFlight(apply)
        await apply.value
        if box.landed { return .proceeded }
        // Not written. A direct write is only right while this is still the same zoom (else the text would land in another range).
        guard guardsHold(), editorState.zoomEpoch == epoch else {
            refire()
            return .abandoned
        }
        return .fallBackToDirectWrite
    }
}

extension EditorViewState {
    /// The queued zoomed write's body, at its turn. True when the text is in the rows. Nothing is written when the zoom this text belongs
    /// to is no longer the one shown (a zoom out or a re-zoom bumps the epoch; a project switch changes the database).
    fileprivate func applyZoomedWriteAtTurn(_ text: String, database: ProjectDatabase, projectId: String, epoch: Int, seq: UInt64) -> Bool {
        guard projectDatabase === database, currentProjectId == projectId, zoomEpoch == epoch, zoomedBlockRange != nil else {
            DebugLog.log(.lifecycle, "[MdWrite] zoomed write seq=\(seq) dropped at its turn: the zoom or the project moved on")
            return false
        }
        // A write to the block table the editor-first quick undos must see (as the direct flush always counted it).
        outOfQueueWriteGeneration &+= 1
        do {
            try applyZoomedRangeWrite(text: text, db: database, pid: projectId)
            DebugLog.log(.lifecycle, "[MdWrite] zoomed range write applied seq=\(seq) chars=\(text.utf8.count)")
            return true
        } catch {
            DebugLog.alwaysPersisted("[MdWrite] zoomed range write FAILED seq=\(seq): \(error)")
            return false
        }
    }

    /// The zoomed Markdown re-parse's save (`scheduleZoomedReparse`, after its debounce and gates): the queued zoomed write, or today's
    /// direct `flushContentToDatabase` for the UI tests' legacy zoom switch, the legacy re-parse switch, and the queue's own fallback.
    func saveZoomedMarkdownText(projectId pid: String?) async {
        guard markdownWriter.isEnabled, !TestMode.isUITestingLegacyTransition(for: .zoom) else {
            flushContentToDatabase()
            return
        }
        let outcome = await markdownWriter.writeZoomedNow(
            overrideContent: nil,
            editorState: self,
            guardsHold: {
                activeLifecycle == nil && currentProjectId == pid && contentState == .idle && editorMode == .source && zoomedSectionId != nil
            },
            refire: { [weak self] in self?.lifecycleHost?.scheduleSourceModeReparse(self?.content ?? "") })
        if outcome == .fallBackToDirectWrite { flushContentToDatabase() }
    }
}
