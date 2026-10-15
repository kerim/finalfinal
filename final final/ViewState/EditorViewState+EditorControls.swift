//
//  EditorViewState+EditorControls.swift
//  final final
//

import SwiftUI

// MARK: - Editor Controls

extension EditorViewState {

    /// Resolve the active section ID from a block ID (Milkdown) or title (CodeMirror fallback)
    func resolveSectionId(blockId: String?, title: String) -> String? {
        if let blockId, sections.contains(where: { $0.id == blockId }) {
            return blockId
        }
        // Fallback: match by title (for CodeMirror or if blockId not found)
        return sections.first { $0.title == title }?.id
    }

    /// Guarded companion to `resolveSectionId`, and the only sanctioned way to write
    /// `currentSectionId` (bt t-fecee361). The editors report the caret's section on essentially
    /// every content push, and `@Observable` fires on any write, same value included -- so an
    /// unguarded assignment fired `currentSectionId`'s observation on every keystroke even when
    /// the resolved value hadn't actually changed. That wasted work reached
    /// `OutlineSidebarPane.body` (and its `OutlineSidebarRenderKey` construction), though the
    /// sidebar's own `.equatable()` gate already kept it from reaching the expensive
    /// `OutlineSidebar` render itself. (Measurement after this guard landed found
    /// `ContentView.body`'s actual per-keystroke redraw is driven by `editorState.content`
    /// changing -- a separate read in `ViewNotificationModifiers.swift`'s `.onChange(of:
    /// editorState.content)` -- not by `currentSectionId`, which does not change during a typing
    /// session; this guard does not fix that reported slowness, and is a correctness fix in its
    /// own right regardless -- `@Observable` firing on an identical write is always wasted work.)
    /// Two distinct shapes, both real, both handled here:
    ///
    ///  1. Same-value repeat: the caret hasn't left the section, `resolveSectionId` returns the id
    ///     already stored. Skip the write entirely.
    ///  2. Transient nil: `resolveSectionId` returns nil whenever `blockId` is absent from
    ///     `sections` AND no title matches -- which a mid-flight re-parse causes routinely, making
    ///     `currentSectionId` flap id -> nil -> id. Each of those IS a genuine value change, so
    ///     check 1 does not catch it. Treat an unresolvable caret as "we don't know yet" and keep
    ///     the previous id -- BUT ONLY IF that id is still a real section. If the previous id is
    ///     gone from `sections` (the user deleted the section the caret was in), nil is the honest
    ///     answer and gets written; pinning to a deleted id would highlight a card that no longer
    ///     exists in the sidebar and name a dead section in the status bar.
    func setCurrentSectionId(blockId: String?, title: String) {
        let resolved = resolveSectionId(blockId: blockId, title: title)
        if let resolved {
            if currentSectionId != resolved { currentSectionId = resolved }
            return
        }
        if let previous = currentSectionId, sections.contains(where: { $0.id == previous }) { return }
        if currentSectionId != nil { currentSectionId = nil }
    }

    func updateStats(words: Int, characters: Int) {
        wordCount = words
        characterCount = characters
    }

    /// Called by editor coordinators when the selection changes (empty text = deselect).
    func updateSelection(_ text: String) {
        selectedWordCount = text.isEmpty ? nil : MarkdownUtils.wordCount(for: text)
    }

    func scrollTo(offset: Int) {
        scrollToOffset = offset
    }

    func clearScrollRequest() {
        scrollToOffset = nil
        scrollToBlockId = nil
        scrollToAnnotationIndex = nil
    }

    func toggleEditorMode() {
        editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
    }

    /// Markdown -> Rich Text, the text half of the switch (everything `handleEditorModeToggle` does before `toggleEditorMode()`): takes
    /// the text the Markdown editor holds NOW, strips the section anchors and the bibliography START marker, saves THAT to the database
    /// and hands it to Rich Text as `content`. The bibliography END marker (`BlockParser.bibliographyEndMarker`) is deliberately NOT
    /// stripped: it is what makes `BlockParser.parse` flag the bibliography heading and its entries, so a text without it stores them
    /// as ordinary blocks (`BibliographyOpeningSelector`, tier 2). `content` always carried it in Markdown mode (the page's push), and
    /// the Rich Text editor re-reads its document from the database right after (`onWebViewReady` sets `content` again).
    ///
    /// The text is `sourceContent`, not `content`. Just before the switch `CodeMirrorCoordinator.saveAndNotify` reads the page and
    /// refreshes `sourceContent` only; `content` (the same text with the anchors stripped) is refreshed by the page's own push, which
    /// runs 50 ms after the last key. Keys typed in that last 50 ms were therefore in `sourceContent` but not in `content`, and saving
    /// `content` stored the text without them. The incoming Rich Text editor loads its document from the database, so they were lost.
    ///
    /// `sourceContent` must hold the RAW document, hidden markers included: `saveAndNotify` reads it with
    /// `CodeMirrorEditor.Coordinator.preSwitchContentScript` (`getContentRaw()`), not `getContent()`, which strips the end marker (and
    /// the zoom-notes marker a zoomed flush splits the mini-Notes on) before this function ever sees the text. Reading `getContent()`
    /// here is what made every switch to Rich Text unflag the bibliography (2026-10-09, first seen in the VM runs of that day).
    func commitMarkdownTextForRichTextSwitch(sectionSyncService: SectionSyncService) {
        let (cleaned, anchors) = sectionSyncService.extractSectionAnchors(markdown: sourceContent)
        DebugLog.log(.editor, "[SWITCH→MW] After extract: cleaned length=\(cleaned.count), anchors=\(anchors.count)")
        sourceAnchors = anchors
        // Also strip bibliography marker since Milkdown shouldn't see it
        let plainText = SectionSyncService.stripBibliographyMarker(from: cleaned)
        // `skipUnchangedWrite`: when the stored rows already are what this flush would store (no edit since the last save), nothing is
        // written, so every row keeps its id. A zoomed flush ignores the flag.
        // Does not wait for a pending section-delete job (plan D7): this runs only when LEAVING Markdown, and an editor-first delete
        // happens in Rich Text only, whose switch to Markdown already waited for every delete job before it changed anything.
        flushContentToDatabase(overrideContent: plainText, skipUnchangedWrite: true)
        content = plainText
    }

    /// Runs `body` (the switch between Rich Text and Markdown) once every structural command ahead of it has finished and every
    /// section-delete job has ended (t-94369a83 Phase 4b slice 2a, plan D7, addendum A2). The switch must not change anything
    /// until then, so the editor stays live and idle during the wait and typing is saved normally.
    ///
    /// It enters through the structural gate: a second toggle pressed during the wait is held behind the first and runs after it,
    /// never in parallel and never dropped; one the lifecycle cancels (a close, quit or project switch started) does not run.
    /// With the gate idle and no job pending (the normal case) `body` runs right here, in this call, with no task hop: the
    /// switch keeps its old timing. Returns the waiting task, or nil when `body` already ran.
    @discardableResult
    func runAfterPendingStructuralWork(label: String, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        // A close, quit or project switch has started: the project is being saved and closed, and a switch between Rich Text and
        // Markdown must not run beside that save (fix round 8, F3). This covers a request whose cursor save was already under way.
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[\(label)] not run: the project is closing or switching")
            return nil
        }
        guard structuralGate.isIdle, !efJobRegistry.hasUnsettledWork else {
            return Task { @MainActor [weak self] in
                guard let self else { return }
                // A toggle held behind a slow command shows "Finishing the last change..." after one second (fix round 2a, item 4),
                // dismissed by id when the toggle starts or is cancelled.
                var waitToast: DelayedProgressToast?
                defer { waitToast?.stop() }
                let toastCenter = self.toastCenter
                let result = await self.structuralGate.acquire(onQueued: {
                    waitToast = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.finishingMessage)
                })
                guard result == .granted else {
                    DebugLog.log(.lifecycle, "[\(label)] cancelled: the project is closing or switching")
                    return
                }
                defer { self.structuralGate.release() }
                // `acquire` looks at the barrier only at entry: a waiter queued before the close started is granted the gate while the
                // close is waiting, and must not run the switch then (F3).
                guard self.activeLifecycle == nil, !self.structuralGate.isClosedToNewWork else {
                    DebugLog.log(.lifecycle, "[\(label)] cancelled: a close, quit or switch started while it waited")
                    return
                }
                await self.awaitPendingStructuralJobs()
                // The wait above suspended: look again.
                guard self.activeLifecycle == nil, !self.structuralGate.isClosedToNewWork else {
                    DebugLog.log(.lifecycle, "[\(label)] cancelled: a close, quit or switch started while it waited")
                    return
                }
                body()
            }
        }
        body()
        return nil
    }

    /// A switch requested while a structural command is running or queued (`contentState == .structuralUndo`, or the structural gate
    /// busy: a slow Cmd-Z, a section operation, an undo still waiting for a delete's saving job) is HELD, not dropped (fix round 2a,
    /// item 4; floor #2/#5): it waits for the command to finish, and for any command queued behind it, then makes the request again
    /// from the top, so the cursor save, the jobs wait and the switch all run as if the key had just been pressed. "Finishing the
    /// last change..." shows after one second. A second press while one is held is the same wish and adds nothing; one the
    /// lifecycle cancels (a close, quit or project switch started) is dropped with the project.
    ///
    /// Two places call it: the request itself (`requestEditorModeToggle`, phase one) and the receiver of `.didSaveCursorPosition`
    /// (phase two, `handleDidSaveCursorPosition`). The second is for a command that started DURING the cursor save: the cursor
    /// save is two web calls (about half a second on a book-length document), the press passed phase one while everything was
    /// idle, and the command set `.structuralUndo` before the save replied. Phase two used to drop the switch there without a word.
    ///
    /// `.zoomTransition` is deliberately still refused: zoom waits for the delete job BEFORE it sets that state
    /// (`performUserZoomIn`), so the state lasts only the zoom itself, a few tenths of a second.
    func holdModeToggleUntilStructuralWorkEnds() {
        guard heldModeToggleTask == nil else {
            DebugLog.log(.editor, "[EditorModeToggle] a toggle is already held behind the running structural command")
            return
        }
        DebugLog.log(.editor, "[EditorModeToggle] held: a structural command is running (contentState=\(contentState))")
        heldModeToggleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let toast = DelayedProgressToast(toastCenter: self.toastCenter, message: DelayedProgressToast.finishingMessage)
            defer { toast.stop() }
            // Wait for this press's turn on the gate (every command that was running or queued before it has then finished) and
            // look again: normally the state is clear by then; if a command is still mid-way the loop waits once more.
            var proceedDespiteDeleteWork = false
            repeat {
                let result = await self.structuralGate.acquire()
                guard result == .granted else {
                    self.heldModeToggleTask = nil
                    return
                }
                // A delete's job and its follow-up work (the resyncs, and the Notes and Bibliography rebuilds they start) end before the
                // press asks again: the request below saves the caret, and a rebuild that landed after that save would clear it, so
                // the Markdown editor would open at line 1. The press is held while the gate is held (as `runAfterPendingStructuralWork`
                // does) so nothing slips in between. Only when there is work to wait for: the wait also bumps
                // `outOfQueueWriteGeneration`, which a held press behind an ordinary command has no reason to do.
                // The wait is bounded (15 s) and logs when it gives up; nothing else can register delete work while this press holds the
                // gate, so work still unsettled afterwards is work that never ended, and the request below must not hold for it again.
                proceedDespiteDeleteWork = false
                if self.efJobRegistry.hasUnsettledWork {
                    await self.awaitPendingStructuralJobs()
                    proceedDespiteDeleteWork = self.efJobRegistry.hasUnsettledWork
                }
                self.structuralGate.release()
                // A waiter queued before a close or quit started is granted the gate while that lifecycle waits: the press is dropped
                // with the project, not run beside its save (F3).
                guard self.activeLifecycle == nil, !self.structuralGate.isClosedToNewWork else {
                    DebugLog.log(.lifecycle, "[EditorModeToggle] held switch dropped: a close, quit or switch started while it waited")
                    self.heldModeToggleTask = nil
                    return
                }
                if self.contentState == .structuralUndo { try? await Task.sleep(for: Self.sectionOperationPollInterval) }
            } while self.contentState == .structuralUndo
            // The task is over before it asks again: the request below may hold again (a command queued behind this press has
            // taken the gate), and that new hold must be the one `heldModeToggleTask` names. (A `defer` that cleared it here would
            // clear the new one instead.)
            self.heldModeToggleTask = nil
            // This is the press the user already made, not a second one: the debounce that stops a double-click must not drop it.
            self.lastToggleRequestTime = .distantPast
            self.requestEditorModeToggle(ignoringUnfinishedDeleteWork: proceedDespiteDeleteWork)
        }
    }

    /// Request editor mode toggle - posts notification for current editor to save cursor first.
    /// Gates on debounce interval and blocks during data-sensitive transitions.
    ///
    /// `ignoringUnfinishedDeleteWork` is only for the held press's own second request, after its bounded wait for a delete's work gave
    /// up: it goes on, and the switch's own wait (`runAfterPendingStructuralWork`) runs as it always did, rather than the press being
    /// held for ever behind work that never ends.
    func requestEditorModeToggle(ignoringUnfinishedDeleteWork: Bool = false) {
        // Diagnostic (bug-fix round, ship-fix/fullsuite-round2): records that the request
        // reached this handler at all, plus the two values that decide whether either guard
        // below rejects it -- so a future regression (e.g. a click silently swallowed before it
        // ever reaches here) is distinguishable in the log from a guard genuinely rejecting a
        // request that did arrive.
        DebugLog.log(.editor, "[EditorModeToggle] requestEditorModeToggle called: canToggle=\(canToggleEditorMode) contentState=\(contentState)")
        guard canToggleEditorMode else { return }
        // A close, quit or project switch is saving the project: no switch begins beside it (fix round 8, F3).
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork else {
            DebugLog.log(.lifecycle, "[EditorModeToggle] not started: the project is closing or switching")
            return
        }
        // Don't start the save chain during data-sensitive transitions. .structuralUndo
        // added in the Phase 3 review round: a mode toggle mid-sequence would reassign the
        // WebView StructuralUndoController is still operating on
        // (docs/architecture/unified-undo.md).
        switch contentState {
        case .projectSwitch, .zoomTransition:
            return
        case .structuralUndo:
            // Held, not dropped: runs again when the structural command (and any queued behind it) has finished.
            holdModeToggleUntilStructuralWorkEnds()
            return
        default:
            break
        }
        // A structural command that is still waiting for its first step (an undo that waits for a delete's saving job holds the gate
        // while `contentState` is still `.idle`) or commands queued behind it: hold the press now rather than start a cursor save that
        // the command would overtake. With the gate idle (nothing running, nothing queued) the press goes straight through.
        //
        // The same for a delete whose job or follow-up work has not finished (t-94369a83 Phase 4b slice 2a, fix round 9): the gate is
        // idle then, but the follow-up work starts the Notes and Bibliography rebuilds, and each of those clears the caret the cursor
        // save below stores (`handleNotesSectionChanged`, `handleBibliographySectionChanged`: a position computed before a rebuild
        // is stale). A press that saved its caret first and then waited for the delete (`handleEditorModeToggle`) opened the Markdown
        // editor with no caret, at line 1 column 0, and the next typing landed at the start of the document. Held here, the caret is
        // saved after the work has ended, and nothing clears it afterwards. The editor stays live while the press is held.
        let deleteWorkPending = !ignoringUnfinishedDeleteWork && efJobRegistry.hasUnsettledWork
        guard structuralGate.isIdle, !deleteWorkPending else {
            holdModeToggleUntilStructuralWorkEnds()
            return
        }
        lastToggleRequestTime = Date()  // Record at entry point to close the race window

        NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
    }

    /// The not-zoomed write of `flushContentToDatabase`: replace every row of the project with `blocks`.
    ///
    /// With `skipUnchangedWrite` (passed only by the Markdown <-> Rich Text switch) it uses `replaceBlocksIfChanged`: when the
    /// rows already stored are the rows this parse would store, nothing is written, every row keeps its id and the write counter
    /// is not bumped. Otherwise it is `replaceBlocks`, as it always was.
    func writeWholeDocumentRows(_ blocks: [Block], to db: ProjectDatabase, projectId: String, skipUnchangedWrite: Bool) throws {
        guard skipUnchangedWrite else {
            try db.replaceBlocks(blocks, for: projectId)
            return
        }
        let wrote = try db.replaceBlocksIfChanged(blocks, for: projectId)
        DebugLog.log(.zoom, "[FLUSH] switch flush: stored rows \(wrote ? "differed, wrote them" : "already matched, wrote nothing")")
    }

}
