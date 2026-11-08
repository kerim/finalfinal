//
//  EditorViewState+ZoomTransition.swift
//  final final
//
//  Phase 5 job A7 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 1): zoom in and zoom out in Rich
//  Text with the typing carried across. Today's `zoomToSection` / `zoomOut` (EditorViewState+Zoom.swift) write the 50 ms-late copy of the
//  text (`flushContentToDatabase`), read the rows and push the whole document over the editor; keys typed meanwhile are lost (the sync
//  model's W1 and W2). The carried path, in the model's names (docs/architecture/tla/README.md, "Phase 5 step T"):
//
//    1-2  TransBegin + TransLiveRead  the page hands over its pending batch and starts holding and recording, in one turn; the batch
//                                     goes through the ordered queue (BlockSyncService+Transition.swift, `beginTransition`).
//    3    TransBarrier                `awaitSettled` through that batch. `contentState` is still `.idle`, so nothing is refused.
//    4    (F8)                        only now `.zoomTransition` (which bumps `contentGeneration`); nothing is pending: the page holds.
//    5                                the rows are read and assembled exactly as today (EditorViewState+ZoomTargets.swift).
//    6    TransPushFrom + TransReplay `swapTransition`: one page turn swaps the text in and puts the recorded typing back on top.
//    7                                `.idle`, then (same main-actor turn) the zoom in's `outside` batch through the queue.
//
//  Failure paths fall back to today's behaviour (section 0): the begin failed (nothing held) -> the caller runs today's path; the barrier
//  timed out (a stuck writer) -> the hold ends, the zoom is abandoned with a notice; the swap refused -> the held typing is written, the
//  rows re-read and pushed the old way (the one catch-up).
//
//  Rich Text here; Markdown (job A8) is EditorViewState+ZoomTransitionMarkdown.swift, reached from the two entry points below.
//

import Foundation

/// Per-window state of a zoom transition and of the zoom held behind a transition (Phase 5 job A7). A class held by `EditorViewState`
/// (one stored line there) because that class body is at its size limit.
@MainActor
final class TransitionHoldState {
    /// True from a carried zoom's start until it has ended: `contentState` stays `.idle` during steps 1 to 3, so the holds (Cmd-/ during a
    /// zoom, a zoom during a zoom) read this as well.
    var zoomRunning = false
    /// Phase 5 job A9/A10: true from a carried switch's start (Cmd-/) until it has ended (EditorViewState+SwitchTransition.swift). A zoom
    /// pressed meanwhile is held; the content-state watchdog leaves the switch's own `.editorTransition` alone.
    var switchRunning = false
    /// Phase 5 job A10: set by a carried switch to Rich Text just before the flip; the Rich Text `onWebViewReady` closure then knows the page
    /// it is handed already holds its text and ids, and skips its own push (ContentView+EditorPresentation.swift). Cleared there.
    var preparedRichTextPage = false
    /// Phase 5 jobs A9/A10: set at a carried switch's flip; the switch then consumes the saved caret when it ends (a switch that fell back to
    /// today's path leaves it to today's mount).
    var switchCarriedToEnd = false
    /// The one zoom held behind a transition (the newest press replaces an older one: the last wish wins), and the task waiting to run it.
    var heldZoom: (@MainActor () -> Void)?
    var heldZoomTask: Task<Void, Never>?
    /// Phase 5 job A8: the text a carried Markdown zoom made the content record (`adoptMarkdownPageText`) when nothing was replayed. Today's
    /// zoom assigns its text while the state is not idle, so the content observer ignores it; the carried zoom is idle at once, so the
    /// observer skips exactly this text once instead (`consumeSettledContent`). Any other text clears it.
    var settledContent: String?
    #if DEBUG
    /// Test seam (unit tests only): answers the Markdown page's transition calls in place of the window's web view.
    var testMarkdownPage: ((String) async -> String?)?
    #endif

    /// True (and cleared) when `text` is the text a carried zoom settled; any other text just clears it.
    func consumeSettledContent(_ text: String) -> Bool {
        guard let settled = settledContent else { return false }
        settledContent = nil
        return settled == text
    }
}

/// What steps 1 to 3 came to.
enum ZoomTransitionStart: Equatable {
    /// The page holds and records; the batch is written and the barrier is open.
    case ready(token: Int)
    /// Nothing is held: the caller takes today's path.
    case legacy
    /// The transition was abandoned (a stuck writer, a close or switch started); the hold is ended and nothing else is to be done.
    case abandoned
}

extension EditorViewState {
    /// The bound of the two waits for `.idle` around the barrier (a rebuild in progress ends in well under a second).
    nonisolated static let transitionIdleWaitTimeout: Duration = .seconds(15)

    /// Whether a user zoom takes the carried path: Rich Text, a configured editor, and not the UI tests' legacy switch.
    var usesCarriedZoom: Bool {
        // Phase 5 job A8: Markdown too (EditorViewState+ZoomTransitionMarkdown.swift).
        guard !TestMode.isUITestingLegacyTransition(for: .zoom), blockSyncService != nil else { return false }
        return editorMode == .wysiwyg || editorMode == .source
    }

    /// Waits until `contentState` is `.idle` (bounded). True when it is.
    func waitForIdleContentState(timeout: Duration = EditorViewState.transitionIdleWaitTimeout) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while contentState != .idle {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    /// Steps 1 to 3 (TransBegin + TransLiveRead, the batch, TransBarrier), then the UI tests' hold, then `.idle` again. Never leaves `.idle`.
    func beginZoomTransition(_ blockSync: BlockSyncService, label: String) async -> ZoomTransitionStart {
        // The page call is made only while `.idle` (a rebuild that is pushing into the page would be a change the replay cannot carry).
        guard await waitForIdleContentState() else {
            DebugLog.alwaysPersisted("[TRANS] fallback=notIdle kind=\(label) contentState=\(contentState)")
            return .legacy
        }
        switch await blockSync.beginTransition() {
        case .notStarted(let reason):
            DebugLog.alwaysPersisted("[TRANS] fallback=beginFailed kind=\(label) reason=\(reason)")
            return .legacy
        case .barrierTimedOut:
            toastCenter.show(ToastFactory.zoomCancelledBehindEarlierChange())
            return .abandoned
        case .ready(let token):
            // UI-test seam: the window in which typing used to be lost, widened on purpose. The page holds and records throughout.
            await TestMode.holdTransition(label)
            // A rebuild may have started while the barrier was awaited (the state stayed `.idle`); it ends in `.idle`.
            let idle = await waitForIdleContentState()
            // A close, quit or project switch that started meanwhile: the window is going away; its save already released the hold.
            guard activeLifecycle == nil, !structuralGate.isClosedToNewWork else {
                DebugLog.alwaysPersisted("[TRANS] abandoned kind=\(label): a close, quit or switch started")
                await blockSync.endTransition(token: token)
                return .abandoned
            }
            guard idle else {
                DebugLog.alwaysPersisted("[TRANS] abandoned kind=\(label): the editor never became idle")
                await blockSync.endTransition(token: token)
                toastCenter.show(ToastFactory.zoomCancelledBehindEarlierChange())
                return .abandoned
            }
            return .ready(token: token)
        }
    }

    /// Zoom OUT with the typing carried across (Rich Text). Returns false, having changed nothing, when the page could not begin (the
    /// caller then runs today's `zoomOut`); true when the zoom out ran or was abandoned.
    func zoomOutCarried(restoreScrollToSectionId: String?) async -> Bool {
        if editorMode == .source { return await zoomOutCarriedMarkdown() } // Phase 5 job A8
        await awaitPendingStructuralJobs()
        guard zoomedSectionId != nil else { return true }
        guard let blockSync = blockSyncService else { return false }
        await acquireZoomRestore()
        defer { releaseZoomRestore() }
        guard zoomedSectionId != nil else { return true }
        guard let db = projectDatabase, let pid = currentProjectId else {
            zoomedSectionId = nil
            return true
        }
        transitionHolds.zoomRunning = true
        defer { transitionHolds.zoomRunning = false }
        let token: Int
        switch await beginZoomTransition(blockSync, label: "zoom out") {
        case .ready(let began): token = began
        case .legacy: return false
        case .abandoned: return true
        }
        await swapZoomOut(blockSync, token: token, db: db, pid: pid, restoreScrollTo: restoreScrollToSectionId)
        return true
    }

    /// Steps 4 to 7 of the zoom out, once the page holds and the barrier is open.
    private func swapZoomOut(
        _ blockSync: BlockSyncService, token: Int, db: ProjectDatabase, pid: String, restoreScrollTo restoreScrollToSectionId: String?
    ) async {
        // The mini-Notes carry no ids, so they reach the rows from the text: the page's own (the cached `content` is up to 50 ms late).
        // Typing in them after the begin makes the swap refuse, and the catch-up reads the page again.
        let miniNotes = await liveMiniNotes(blockSync)

        contentState = .zoomTransition // step 4 (F8): after the barrier; nothing is pending, the page holds
        zoomEpoch += 1
        let myEpoch = zoomEpoch
        if let miniNotes { sectionSyncService?.syncMiniNotesBackPublic(miniNotes, projectId: pid) }
        let target: ZoomTargetDocument
        do {
            target = Self.fullDocumentTarget(from: try db.fetchBlocks(projectId: pid)) // step 5
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried zoom out: the rows could not be read: \(error)")
            await blockSync.endTransition(token: token)
            contentState = .idle
            clearZoomFlagsSafely()
            return
        }
        NotificationCenter.default.post(name: .setZoomFootnoteState, object: nil, userInfo: ["zoomed": false, "maxLabel": 0])
        isZoomingContent = true
        isResettingContent = true
        let payload = TransitionSwapPayload(
            markdown: target.markdown, blockIds: target.blockIds, expected: target.expected,
            managedBlockIds: Array(target.managedBlockIds), imageMeta: TransitionSwapPayload.images(target.imageMeta),
            zoomMode: false, scrollToStart: false, scrollToBlockId: restoreScrollToSectionId)
        switch await blockSync.swapTransition(token: token, payload: payload) { // step 6: TransPushFrom + TransReplay
        case .swapped(let replayed, let outside):
            isResettingContent = false
            guard zoomEpoch == myEpoch else { // a project switch completed during the swap: touch nothing of it
                isZoomingContent = false
                return
            }
            noteSwappedContent(target.markdown)
            content = target.markdown
            pendingImageMeta = target.imageMeta
            sourceContent = target.markdown
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            DebugLog.alwaysPersisted("[TRANS] swapped kind=zoom out replayed=\(replayed)")
            isZoomingContent = false
            contentState = .idle // step 7
            blockSync.writeTransitionBatch(outside) // nothing outside a whole document; written all the same if the page says so
        case .refused(let reason, let batch):
            isResettingContent = false
            await catchUpZoomOut(blockSync, reason: reason, batch: batch, restoreScrollTo: restoreScrollToSectionId, epoch: myEpoch)
        }
    }

    /// Zoom IN with the typing carried across (Rich Text). Typing in blocks outside the zoomed range comes back from the page as an
    /// ordinary batch, written after the state is `.idle` again. Returns false, having changed nothing, when the page could not begin
    /// (the caller then runs today's `zoomToSection`); true when the zoom ran or was abandoned.
    func zoomToSectionCarried(_ sectionId: String, mode: ZoomMode) async -> Bool {
        if editorMode == .source { return await zoomToSectionCarriedMarkdown(sectionId, mode: mode) } // Phase 5 job A8
        await awaitPendingStructuralJobs()
        guard let blockSync = blockSyncService, projectDatabase != nil, currentProjectId != nil else { return false }
        // Zoomed into another section: out first, carried, as its own transition.
        if zoomedSectionId != nil && zoomedSectionId != sectionId {
            guard await zoomOutCarried(restoreScrollToSectionId: nil) else { return false }
            guard zoomedSectionId == nil else { return true } // the zoom out was abandoned
        }
        // Anything today's path handles by aborting (an unknown section) is left to it.
        guard sections.contains(where: { $0.id == sectionId }) else { return false }
        transitionHolds.zoomRunning = true
        defer { transitionHolds.zoomRunning = false }
        let token: Int
        switch await beginZoomTransition(blockSync, label: "zoom in") {
        case .ready(let began): token = began
        case .legacy: return false
        case .abandoned: return true
        }
        guard let db = projectDatabase, let pid = currentProjectId else {
            await blockSync.endTransition(token: token)
            return true
        }
        await swapZoomIn(blockSync, token: token, sectionId: sectionId, mode: mode, db: db, pid: pid)
        return true
    }

    /// Steps 4 to 7 of the zoom in, once the page holds and the barrier is open.
    private func swapZoomIn( // swiftlint:disable:this function_parameter_count
        _ blockSync: BlockSyncService, token: Int, sectionId: String, mode: ZoomMode, db: ProjectDatabase, pid: String
    ) async {
        contentState = .zoomTransition // step 4 (F8)
        zoomEpoch += 1
        // Phase 4a: the editor text from here is a section of the document, so the Markdown writer's baseline describes nothing.
        markdownWriter.reset()
        let target: ZoomInTarget
        do {
            guard let built = try buildZoomInTarget(sectionId: sectionId, mode: mode, db: db, pid: pid) else { // step 5
                await abandonZoomIn(blockSync, token: token)
                return
            }
            target = built
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried zoom in: the rows could not be read: \(error)")
            await abandonZoomIn(blockSync, token: token)
            return
        }
        zoomedSectionIds = target.descendantIds
        zoomedBlockRange = target.range
        NotificationCenter.default.post(name: .setZoomFootnoteState, object: nil, userInfo: ["zoomed": true, "maxLabel": target.maxLabel])
        zoomedSectionId = sectionId
        isZoomingContent = true
        isResettingContent = true
        let document = target.document
        let payload = TransitionSwapPayload(
            markdown: document.markdown, blockIds: document.blockIds, expected: document.expected, managedBlockIds: [],
            imageMeta: TransitionSwapPayload.images(document.imageMeta), zoomMode: true, scrollToStart: true, scrollToBlockId: nil)
        switch await blockSync.swapTransition(token: token, payload: payload) { // step 6: TransPushFrom + TransReplay
        case .swapped(let replayed, let outside):
            noteSwappedContent(document.markdown)
            content = document.markdown
            pendingImageMeta = document.imageMeta
            isResettingContent = false
            sourceContent = document.markdown
            DebugLog.alwaysPersisted(
                "[TRANS] swapped kind=zoom in replayed=\(replayed) outside u=\(outside.updates.count) i=\(outside.inserts.count) "
                    + "d=\(outside.deletes.count)")
            isZoomingContent = false
            contentState = .idle // step 7, then the outside batch in the same main-actor turn: no poll slips between
            blockSync.writeTransitionBatch(outside)
        case .refused(let reason, let batch):
            isResettingContent = false
            await catchUpZoomIn(blockSync, sectionId: sectionId, mode: mode, reason: reason, batch: batch)
        }
    }

    /// Today's zoom assigns the new text to `content` while its state is not `.idle` (it waits for the page's paint first), so the
    /// assignment reaches the content observers as a transition and starts no section sync of its own; only later typing does. The
    /// carried zoom is `.idle` again at once, so it tells the section sync that this text is the one the section rows already describe
    /// (they are read from the same rows). Without it every carried zoom set off a section sync today's path never ran; in the first A/B
    /// runs that showed as the zoomed chapter's section rows swept at the next switch to Markdown. Waiting for the paint instead, as
    /// today's path does, cost 100 to 700 ms per zoom in the A/B runs (the acknowledgement often came before the wait began).
    private func noteSwappedContent(_ markdown: String) {
        sectionSyncService?.noteContentAlreadySynced(markdown)
    }

    /// The zoom in could not read its target after the barrier: the hold ends (the typing goes out with the next poll) and the zoom is
    /// abandoned as today's abort branches abandon it.
    private func abandonZoomIn(_ blockSync: BlockSyncService, token: Int) async {
        await blockSync.endTransition(token: token)
        isZoomingContent = false
        clearZoomFlagsSafely()
        contentState = .idle
    }
}
