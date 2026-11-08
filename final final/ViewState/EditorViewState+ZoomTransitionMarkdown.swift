//
//  EditorViewState+ZoomTransitionMarkdown.swift
//  final final
//
//  Phase 5 job A8 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 2): zoom in and zoom out in
//  Markdown with the typing carried across. Today's `zoomToSection` / `zoomOut` (EditorViewState+Zoom.swift) write the 50 ms-late copy of
//  the text (`flushContentToDatabase`), read the rows and push the zoomed (or full) text over the CodeMirror page through `sourceContent`;
//  keys typed meanwhile are lost (the sync model's W1 and W2). The carried path reuses A7's protocol and orchestration with the CodeMirror
//  page (web/codemirror/src/api-transition.ts). In the model's names (docs/architecture/tla/DocSyncCurrent.tla, README "Phase 5 step T"):
//
//    1    TransBegin + TransLiveRead  `beginTransition()` on the page: its live raw text, recording and the push hold, in one turn.
//    2    (the batch)                 that text written through the ordered queue: `markdownWriter.writeNow` (per block; zoomed, the queued
//                                     zoomed range write of MarkdownBlockWriter+ZoomedWrite.swift).
//    3    TransBarrier                `awaitSettled` through everything reserved so far. Still `.idle`: nothing is refused.
//    4    (F8)                        only now `.zoomTransition`.
//    5                                the rows are read and assembled exactly as today (EditorViewState+ZoomTargets.swift).
//    6    TransPushFrom + TransReplay `swapTransition` on the page: one turn swaps the text in and puts the recorded typing back on top.
//    7                                `.idle`; zoom in: typing outside the chapter is written through the per-block writer in the same turn.
//
//  Failure paths fall back to today's behaviour: the begin failed (nothing held) -> today's path; a stuck writer -> the hold ends and the
//  zoom is abandoned with a notice; the swap refused -> the page's live text is adopted and today's zoom runs (the one catch-up).
//

import Foundation
import WebKit

/// The reply of the CodeMirror page's `beginTransition()`.
private struct MarkdownTransitionBeginReply: Decodable {
    let succeeded: Bool
    let token: Int?
    let raw: String?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case token, raw, reason
    }
}

/// The options of the CodeMirror page's `swapTransition(token, options)` (api-transition.ts, `MarkdownSwapOptions`).
private struct MarkdownTransitionSwapOptions: Encodable {
    let text: String
    let kind: String
    let scrollToStart: Bool
}

/// The reply of the CodeMirror page's `swapTransition(...)`.
private struct MarkdownTransitionSwapReply: Decodable {
    let succeeded: Bool
    let replayed: Int?
    let raw: String?
    let outside: String?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case replayed, raw, outside, reason
    }
}

/// How the Markdown swap ended.
enum MarkdownTransitionSwap: Equatable {
    /// The page shows the target with `replayed` recorded changes on top; `raw` is its text now; `outside` (zoom in) the step-1 text with
    /// only the typing done outside the chapter.
    case swapped(replayed: Int, raw: String, outside: String?)
    /// The page left its text as the user had it (`raw`; nil when the bridge failed and the page could not answer).
    case refused(reason: String, raw: String?)
}

extension EditorViewState {
    // MARK: - The page calls

    private func markdownTransitionPage() -> WKWebView? {
        lifecycleHost?.activeWebView()
    }

    private var hasMarkdownTransitionPage: Bool {
        #if DEBUG
        if transitionHolds.testMarkdownPage != nil { return true }
        #endif
        return markdownTransitionPage() != nil
    }

    private func evaluateMarkdownTransition(_ script: String) async -> String? {
        #if DEBUG
        if let page = transitionHolds.testMarkdownPage { return await page(script) }
        #endif
        guard let webView = markdownTransitionPage() else { return nil }
        return (try? await webView.evaluateJavaScript(script)) as? String
    }

    /// Ends a hold whose swap never came (`token` nil: any hold). The held typing push is sent.
    func endMarkdownTransition(token: Int?) async {
        _ = await evaluateMarkdownTransition(
            "JSON.stringify(window.FinalFinal.endTransition(\(token.map(String.init) ?? "null"), 'send'))")
    }

    // MARK: - Steps 1 to 3

    /// Steps 1 to 3 (TransBegin + TransLiveRead, the write, TransBarrier), then the UI tests' hold, then `.idle` again. Never leaves `.idle`.
    /// Phase 5 job A10: the switch to Rich Text uses this too, with its own notice and its test hold placed later (`testHold: false`).
    func beginMarkdownZoomTransition(
        label: String, testHold: Bool = true,
        cancelledToast: @MainActor () -> Toast = { ToastFactory.zoomCancelledBehindEarlierChange() }
    ) async -> ZoomTransitionStart {
        guard await waitForIdleContentState() else {
            DebugLog.alwaysPersisted("[TRANS] fallback=notIdle kind=\(label) mode=markdown contentState=\(contentState)")
            return .legacy
        }
        guard markdownWriter.isEnabled, let pid = currentProjectId, hasMarkdownTransitionPage else {
            DebugLog.alwaysPersisted("[TRANS] fallback=beginFailed kind=\(label) mode=markdown reason=no page or writer")
            return .legacy
        }
        // TransBegin + TransLiveRead: the live text, the recording and the hold, in one page turn.
        guard let json = await evaluateMarkdownTransition("JSON.stringify(window.FinalFinal.beginTransition())"),
              let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(MarkdownTransitionBeginReply.self, from: data) else {
            await endMarkdownTransition(token: nil) // the page may hold without Swift knowing its token
            DebugLog.alwaysPersisted("[TRANS] fallback=beginFailed kind=\(label) mode=markdown reason=the page did not answer")
            return .legacy
        }
        guard reply.succeeded, let token = reply.token, let raw = reply.raw else {
            DebugLog.alwaysPersisted("[TRANS] fallback=beginFailed kind=\(label) mode=markdown reason=\(reply.reason ?? "refused")")
            return .legacy
        }
        DebugLog.alwaysPersisted("[TRANS] begin token=\(token) kind=\(label) mode=markdown chars=\(raw.utf8.count)")
        // The text the page held at the begin, through the queue (the writer waits for any write in flight first).
        guard await writeMarkdownTransitionText(raw, pid: pid, zoomed: zoomedSectionId != nil) else {
            DebugLog.alwaysPersisted("[TRANS] abandoned kind=\(label) mode=markdown: the text could not be written")
            await endMarkdownTransition(token: token)
            return .abandoned
        }
        // TransBarrier: everything reserved up to now (our write included) has settled.
        if let blockSync = blockSyncService, let next = blockSync.writer?.nextSequence, next > 1 {
            guard await blockSync.awaitTransitionBarrier(through: next - 1, timeout: BlockSyncService.transitionBarrierTimeout) else {
                await endMarkdownTransition(token: token)
                toastCenter.show(cancelledToast())
                return .abandoned
            }
        }
        // UI-test seam: the window in which typing used to be lost, widened on purpose. The page holds and records throughout.
        if testHold { await TestMode.holdTransition(label) }
        let idle = await waitForIdleContentState()
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork, currentProjectId == pid else {
            DebugLog.alwaysPersisted("[TRANS] abandoned kind=\(label) mode=markdown: a close, quit or switch started")
            await endMarkdownTransition(token: token)
            return .abandoned
        }
        guard idle else {
            DebugLog.alwaysPersisted("[TRANS] abandoned kind=\(label) mode=markdown: the editor never became idle")
            await endMarkdownTransition(token: token)
            toastCenter.show(cancelledToast())
            return .abandoned
        }
        return .ready(token: token)
    }

    /// Step 2: the page's step-1 text through the queue. A write a busy moment (a rebuild that started meanwhile) turned away is tried
    /// again once the editor is idle; today's direct write is the fallback the writer itself asks for. False when it could not be written.
    private func writeMarkdownTransitionText(_ raw: String, pid: String, zoomed: Bool) async -> Bool {
        let text = MarkdownLeaderMap.recordText(fromRaw: raw)
        let guardsHold: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.activeLifecycle == nil && self.currentProjectId == pid && self.contentState == .idle
                && self.editorMode == .source && (self.zoomedSectionId != nil) == zoomed
        }
        for _ in 0..<3 {
            // Unzoomed: per block. Zoomed: the queued zoomed range write. No refire: the hold owns this text (a refused write is retried
            // here, or the hold's end sends it to Swift as an ordinary push).
            let outcome = zoomed
                ? await markdownWriter.writeZoomedNow(overrideContent: text, editorState: self, guardsHold: guardsHold, refire: {})
                : await markdownWriter.writeNow(overrideContent: text, editorState: self, guardsHold: guardsHold, refire: {})
            switch outcome {
            case .proceeded:
                return true
            case .fallBackToDirectWrite:
                flushContentToDatabase(overrideContent: text)
                return true
            case .abandoned:
                guard activeLifecycle == nil, currentProjectId == pid, editorMode == .source,
                      (zoomedSectionId != nil) == zoomed, await waitForIdleContentState() else { return false }
            }
        }
        return false
    }

    // MARK: - Step 6

    /// TransPushFrom + TransReplay: the page swaps `text` in and replays the recorded typing on top, in one turn. A bridge failure ends the
    /// hold and answers a refusal with no text (the catch-up reads the page again).
    func swapMarkdownTransition(token: Int, text: String, kind: String, scrollToStart: Bool) async -> MarkdownTransitionSwap {
        let options = MarkdownTransitionSwapOptions(text: text, kind: kind, scrollToStart: scrollToStart)
        guard let optionsData = try? JSONEncoder().encode(options), let optionsJSON = String(data: optionsData, encoding: .utf8) else {
            await endMarkdownTransition(token: token)
            return .refused(reason: "the options could not be encoded", raw: nil)
        }
        // JSON is a JavaScript expression: the options go in as an object literal, with no template-literal escaping to get wrong.
        let script = "JSON.stringify(window.FinalFinal.swapTransition(\(token), \(optionsJSON)))"
        guard let json = await evaluateMarkdownTransition(script), let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(MarkdownTransitionSwapReply.self, from: data) else {
            await endMarkdownTransition(token: token)
            return .refused(reason: "the page did not answer", raw: nil)
        }
        guard reply.succeeded, let raw = reply.raw else { return .refused(reason: reply.reason ?? "refused", raw: reply.raw) }
        return .swapped(replayed: reply.replayed ?? 0, raw: raw, outside: reply.outside)
    }

    /// Makes the page's text after the swap the content record (still `.zoomTransition`, nothing pushed back). With nothing replayed the
    /// content observer is told to skip this one text, as it skips today's zoom text; with a replay it is typing and saved as such.
    private func adoptSwappedMarkdownText(_ raw: String, replayed: Int) {
        adoptMarkdownPageText(raw)
        transitionHolds.settledContent = replayed == 0 ? content : nil
    }

    // MARK: - Zoom out

    /// Zoom OUT in Markdown with the typing carried across. False, having changed nothing, when the page could not begin (the caller runs
    /// today's `zoomOut`); true when the zoom out ran or was abandoned.
    func zoomOutCarriedMarkdown() async -> Bool {
        await awaitPendingStructuralJobs()
        guard zoomedSectionId != nil else { return true }
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
        switch await beginMarkdownZoomTransition(label: "zoom out") {
        case .ready(let began): token = began
        case .legacy: return false
        case .abandoned: return true
        }
        contentState = .zoomTransition // step 4 (F8): after the barrier; nothing is pending, the page holds
        zoomEpoch += 1
        let myEpoch = zoomEpoch
        let allBlocks: [Block]
        do {
            allBlocks = try db.fetchBlocks(projectId: pid) // step 5
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried Markdown zoom out: the rows could not be read: \(error)")
            await endMarkdownTransition(token: token)
            contentState = .idle
            clearZoomFlagsSafely()
            return true
        }
        let target = Self.fullDocumentTarget(from: allBlocks)
        let text = markdownFullDocumentText(target.markdown, allBlocks: allBlocks)
        NotificationCenter.default.post(name: .setZoomFootnoteState, object: nil, userInfo: ["zoomed": false, "maxLabel": 0])
        switch await swapMarkdownTransition(token: token, text: text, kind: "out", scrollToStart: false) { // step 6
        case .swapped(let replayed, let raw, _):
            guard zoomEpoch == myEpoch else { return true } // a project switch completed during the swap: touch nothing of it
            pendingImageMeta = target.imageMeta
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            markdownWriter.noteLoaded(text: text, pid: pid)
            adoptSwappedMarkdownText(raw, replayed: replayed)
            DebugLog.alwaysPersisted("[TRANS] swapped kind=zoom out mode=markdown replayed=\(replayed)")
            contentState = .idle // step 7
            markdownWriter.prewarmParse(raw: sourceContent, projectId: pid, database: db)
        case .refused(let reason, let raw):
            await catchUpMarkdownZoomOut(reason: reason, raw: raw, db: db, pid: pid, epoch: myEpoch)
        }
        return true
    }

    /// The zoom out's catch-up: the page's live text becomes the record, today's flush writes it, today's restore pushes the whole text.
    private func catchUpMarkdownZoomOut(reason: String, raw: String?, db: ProjectDatabase, pid: String, epoch: Int) async {
        DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=zoom out mode=markdown reason=\(reason)")
        if let raw { adoptMarkdownPageText(raw) } else { await adoptLiveMarkdownText(why: "carried zoom out catch-up") }
        flushContentToDatabase()
        do {
            let completed = try await restoreFullDocumentAndClearZoom(db: db, pid: pid, expectedEpoch: epoch)
            isZoomingContent = false
            guard completed else { return }
            contentState = .idle
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried Markdown zoom out, catch-up: \(error)")
            isZoomingContent = false
            contentState = .idle
            clearZoomFlagsSafely()
        }
    }

    // MARK: - Zoom in

    /// Zoom IN in Markdown with the typing carried across. Typing outside the zoomed chapter comes back from the page and is written after
    /// the state is `.idle` again. False, having changed nothing, when the page could not begin; true when the zoom ran or was abandoned.
    func zoomToSectionCarriedMarkdown(_ sectionId: String, mode: ZoomMode) async -> Bool {
        await awaitPendingStructuralJobs()
        guard projectDatabase != nil, currentProjectId != nil else { return false }
        if zoomedSectionId != nil && zoomedSectionId != sectionId { // zoomed into another chapter: out first, carried
            guard await zoomOutCarriedMarkdown() else { return false }
            guard zoomedSectionId == nil else { return true } // the zoom out was abandoned
        }
        guard sections.contains(where: { $0.id == sectionId }) else { return false } // today's path aborts it
        transitionHolds.zoomRunning = true
        defer { transitionHolds.zoomRunning = false }
        let token: Int
        switch await beginMarkdownZoomTransition(label: "zoom in") {
        case .ready(let began): token = began
        case .legacy: return false
        case .abandoned: return true
        }
        guard let db = projectDatabase, let pid = currentProjectId else {
            await endMarkdownTransition(token: token)
            return true
        }
        await swapMarkdownZoomIn(token: token, sectionId: sectionId, mode: mode, db: db, pid: pid)
        return true
    }

    /// Steps 4 to 7 of the Markdown zoom in, once the page holds and the barrier is open.
    private func swapMarkdownZoomIn(token: Int, sectionId: String, mode: ZoomMode, db: ProjectDatabase, pid: String) async {
        contentState = .zoomTransition // step 4 (F8)
        zoomEpoch += 1
        markdownWriter.reset() // Phase 4a: the editor text from here is a section of the document
        let target: ZoomInTarget
        do {
            guard let built = try buildZoomInTarget(sectionId: sectionId, mode: mode, db: db, pid: pid) else { // step 5
                await abandonMarkdownZoomIn(token: token)
                return
            }
            target = built
        } catch {
            DebugLog.log(.zoom, "[EditorViewState] carried Markdown zoom in: the rows could not be read: \(error)")
            await abandonMarkdownZoomIn(token: token)
            return
        }
        let text = markdownZoomInText(target)
        NotificationCenter.default.post(name: .setZoomFootnoteState, object: nil, userInfo: ["zoomed": true, "maxLabel": target.maxLabel])
        // Today's zoom in hides the page at the compositor until its paint (the page's `paintComplete` shows it again), so the jump to the
        // top is not seen. The same here; a swap that does not paint shows it again below.
        markdownTransitionPage()?.alphaValue = 0
        switch await swapMarkdownTransition(token: token, text: text, kind: "in", scrollToStart: true) { // step 6
        case .swapped(let replayed, let raw, let outside):
            zoomedSectionIds = target.descendantIds
            zoomedBlockRange = target.range
            zoomedSectionId = sectionId
            pendingImageMeta = target.document.imageMeta
            markdownWriter.noteLoaded(text: text, pid: pid)
            adoptSwappedMarkdownText(raw, replayed: replayed)
            DebugLog.alwaysPersisted(
                "[TRANS] swapped kind=zoom in mode=markdown replayed=\(replayed) outside=\(outside == nil ? 0 : 1)")
            contentState = .idle // step 7, then the outside typing in the same main-actor turn
            if let outside { writeOutsideTyping(outside, db: db, pid: pid) }
        case .refused(let reason, let raw):
            markdownTransitionPage()?.alphaValue = 1
            await catchUpMarkdownZoomIn(sectionId: sectionId, mode: mode, reason: reason, raw: raw)
        }
    }

    /// The zoom in could not read its target after the barrier: the hold ends (its push carries the typing) and the zoom is abandoned.
    private func abandonMarkdownZoomIn(token: Int) async {
        await endMarkdownTransition(token: token)
        clearZoomFlagsSafely()
        contentState = .idle
    }

    /// The zoom in's catch-up: the page's live text becomes the record, then today's zoom in runs with the state already
    /// `.zoomTransition` (its direct flush writes that text, its push shows the chapter).
    private func catchUpMarkdownZoomIn(sectionId: String, mode: ZoomMode, reason: String, raw: String?) async {
        DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=zoom in mode=markdown reason=\(reason)")
        if let raw { adoptMarkdownPageText(raw) } else { await adoptLiveMarkdownText(why: "carried zoom in catch-up") }
        await zoomToSection(sectionId, mode: mode)
        contentState = .idle
    }

    /// Zoom in, step 7: typing done outside the zoomed chapter during the zoom, as the step-1 text with only that typing in it. Compared
    /// block by block with the rows and written through the queue in THIS main-actor turn (the per-block writer's synchronous step), so no
    /// zoomed write of the replayed typing can be reserved before it (the rows inside the chapter still hold the step-1 text, as `outside`
    /// does, so only the outside blocks differ).
    private func writeOutsideTyping(_ outsideRaw: String, db: ProjectDatabase, pid: String) {
        let text = MarkdownLeaderMap.recordText(fromRaw: outsideRaw)
        if markdownWriter.inFlight == nil, let service = blockSyncService {
            let disposition = markdownWriter.prepare(MarkdownBlockWriter.Context(
                trigger: .writeNow, text: text, database: db, projectId: pid, service: service, refire: {}))
            DebugLog.alwaysPersisted("[TRANS] outside typing written mode=markdown disposition=\(disposition)")
            switch disposition {
            case .started, .nothingToWrite, .stayedRows:
                return
            case .skippedOpenFence, .guardTripped, .noWriter, .refused, .unreadable, .heldForStructuralWork:
                break
            }
        }
        // No turn could be had (or a write is in flight): the whole text written directly (today's whole-document write; nothing when the
        // rows already match). Its chapter is the step-1 text the rows already hold, so the replayed typing is not undone by it: that
        // typing is saved by the zoomed re-parse its own push schedules, which runs after this.
        do {
            let blocks = BlockParser.parse(markdown: text, projectId: pid, notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid))
            try writeWholeDocumentRows(blocks, to: db, projectId: pid, skipUnchangedWrite: true)
            DebugLog.alwaysPersisted("[TRANS] outside typing written directly mode=markdown")
        } catch {
            DebugLog.alwaysPersisted("[TRANS] outside typing could not be written mode=markdown: \(error)")
        }
    }
}
