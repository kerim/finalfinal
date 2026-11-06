//
//  EditorViewState+SwitchTransitionRichText.swift
//  final final
//
//  Phase 5 job A10 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 4; run record a9-notes.md): the
//  switch from Markdown to Rich Text with the typing carried across, the mirror of A9 (EditorViewState+SwitchTransition.swift). Today's
//  switch saves the Markdown text, flips at once and hands the new Rich Text page its text 0.3 to 2 s later, over whatever was typed meanwhile
//  (measurements.md: 4 of 6 markers lost). In the sync model's names (DocSyncCurrent.tla, round 4, TransTwoPage; `Source_` switch cells):
//
//    TransBegin + TransLiveRead  the Markdown page hands over its live text and starts holding and recording (A8's `beginTransition`);
//    (the write)                 that text through the ordered queue by the per-block writer, which writes NOTHING when the rows already
//                                match (today's `replaceBlocksIfChanged` property, kept; A8's `beginMarkdownZoomTransition`);
//    TransBarrier                the queue waited for, all while `.idle`;
//    (F8)                        only then `.editorTransition`;
//    TransIncomingReady          the rows read (`fullDocumentTarget`, as `fetchBlocksWithIds` assembles them) and the incoming Rich Text page,
//                                still detached (the standby with its citation memo and prefill, or a fresh page), is given them in one
//                                page turn (A7's begin + swap: the replace with ids and a synchronous block-sync baseline) and starts
//                                holding and recording (a second begin); the outgoing Markdown page stays live and typeable throughout;
//    TransSwap                   the outgoing page's live text read without ending its hold (`takeTransitionText`), the flip (the page staged
//                                for `makeNSView`, focused on attach), one more read once the outgoing page has left the window (the
//                                catch-up), the typing written through the per-block writer, the rows read again, and A7's `swapTransition`
//                                on the incoming page: the rows' text in, with anything typed on the new page since the flip put back on top.
//
//  Speed (A10 must not get slower): no fixed wait; with nothing typed during the switch the carry is skipped entirely (no write, no second
//  read, no second swap); the per-block compare writes nothing on an unchanged document; the citation memo and prefill of the standby are
//  claimed exactly where today's mount claims them.
//

import Foundation
import WebKit

/// What the outgoing Markdown page held when read during a switch to Rich Text: its text at the begin, its text now, its caret.
struct MarkdownSwitchTake {
    let base: String
    let raw: String
    let cursor: CursorPosition
}

extension EditorViewState {
    /// Whether a switch to Rich Text takes the carried path: not the UI tests' legacy switch, the per-block writer and block sync in place,
    /// a Markdown page to read, not zoomed (a zoomed switch keeps today's path; a9-notes.md).
    var usesCarriedSwitchToRichText: Bool {
        guard !TestMode.isUITestingLegacyTransition(for: .modeSwitch), blockSyncService != nil, markdownWriter.isEnabled,
              lifecycleHost?.activeWebView() != nil else { return false }
        return zoomedSectionIds == nil && zoomedSectionId == nil
    }

    /// Starts the carried switch to Rich Text (called by `performEditorModeToggle` in place of today's body); see A9's twin.
    func startCarriedSwitchToRichText(
        sectionSync: SectionSyncService, cursor: CursorPosition?, legacy: @escaping @MainActor () -> Void,
        consumeCursor: @escaping @MainActor () -> Void = {}
    ) {
        transitionHolds.switchRunning = true
        // "Switching to Rich Text…" once the switch has taken a second; dismissed by id on every exit (see A9's twin).
        let notice = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.switchingToRichTextMessage)
        Task { @MainActor [weak self] in
            defer {
                notice.stop()
                SwitchKeyResendFilter.shared.disarmSoon()
            }
            guard let self else { return }
            defer { self.transitionHolds.switchRunning = false }
            guard await self.structuralGate.acquire() == .granted else {
                DebugLog.log(.lifecycle, "[TRANS] switch to rich text not run: the project is closing or switching")
                return
            }
            defer { self.structuralGate.release() }
            // The saved caret is consumed once the switch is over (the outgoing page has been dismantled by then); see
            // MilkdownCoordinator+PreparedPage.swift. Today's path consumes it in the incoming editor's mount, as before.
            defer {
                if self.transitionHolds.switchCarriedToEnd { consumeCursor() }
                self.transitionHolds.switchCarriedToEnd = false
            }
            await self.runCarriedSwitchToRichText(sectionSync: sectionSync, cursor: cursor, legacy: legacy)
        }
    }

    private func runCarriedSwitchToRichText(
        sectionSync: SectionSyncService, cursor: CursorPosition?, legacy: @MainActor () -> Void
    ) async {
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork, editorMode == .source else { return }
        guard let blockSync = blockSyncService, let outgoing = lifecycleHost?.activeWebView(), let db = projectDatabase,
              let pid = currentProjectId else {
            legacy()
            return
        }
        SwitchKeyResendFilter.shared.arm(outgoing: outgoing)
        let clock = ContinuousClock()
        let pressed = clock.now
        // The incoming page loads while steps 1 to 3 run (A9's twin: the switch costs the longer of the two, not their sum).
        let incomingPage = Task { @MainActor in await EditorPreloader.shared.takeMilkdownPageForSwitch() }
        // TransBegin + TransLiveRead, the write, TransBarrier (A8's steps 1 to 3; the test hold comes later).
        let token: Int
        switch await beginMarkdownZoomTransition(
            label: "switch to rich text", testHold: false, cancelledToast: { ToastFactory.switchCancelledBehindEarlierChange() }) {
        case .legacy:
            legacy()
            return
        case .abandoned:
            return
        case .ready(let began):
            token = began
        }
        contentState = .editorTransition // F8

        // TransIncomingReady.
        guard let rows = try? db.fetchBlocks(projectId: pid) else {
            await abandonCarriedRichTextSwitch(token: token, outgoing: outgoing, why: "the rows could not be read")
            legacy()
            return
        }
        let target = Self.fullDocumentTarget(from: rows)
        guard let page = await incomingPage.value,
              let pageToken = await prepareIncomingRichTextPage(page, target: target, cursor: cursor) else {
            await abandonCarriedRichTextSwitch(token: token, outgoing: outgoing, why: "no Rich Text page could be prepared")
            legacy()
            return
        }
        DebugLog.alwaysPersisted(
            "[TRANS] incoming ready kind=switch to rich text blocks=\(target.blockIds.count) after "
                + "\(EditorPreloader.milliseconds(clock.now - pressed)) ms")
        await TestMode.holdTransition("switch to rich text")
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork, currentProjectId == pid else {
            await abandonCarriedRichTextSwitch(token: token, outgoing: outgoing, why: "a close, quit or switch started")
            return
        }

        // TransSwap, first half: the outgoing page's text now, then the flip.
        guard let first = await takeMarkdownText(token: token, from: outgoing) else {
            await abandonCarriedRichTextSwitch(token: token, outgoing: outgoing, why: "the typing could not be read")
            legacy()
            return
        }
        sourceAnchors = sectionSync.extractSectionAnchors(markdown: first.raw).anchors
        content = target.markdown
        transitionHolds.preparedRichTextPage = true
        transitionHolds.switchCarriedToEnd = true
        EditorPreloader.shared.stageMilkdownPage(page, content: target.markdown)
        toggleEditorMode()
        DebugLog.alwaysPersisted(
            "[TRANS] swapped kind=switch to rich text (flip) after \(EditorPreloader.milliseconds(clock.now - pressed)) ms")

        // TransSwap, second half: the catch-up and the carry.
        await carryTypingOntoRichTextPage(
            blockSync, token: token, pageToken: pageToken, outgoing: outgoing, page: page, first: first, db: db, pid: pid)
        transitionHolds.preparedRichTextPage = false
        contentState = .idle
        DebugLog.alwaysPersisted("[TRANS] switch to rich text done in \(EditorPreloader.milliseconds(clock.now - pressed)) ms")
    }

    /// The incoming Rich Text page, detached: the theme, the rows' document with ids and a synchronous block-sync baseline (A7's begin and
    /// swap, nothing to replay), the caret, focus, and a second begin so typing on the page after the flip is held and recorded until the
    /// carry. Returns that second begin's token, nil when the page refused.
    private func prepareIncomingRichTextPage(_ page: WKWebView, target: ZoomTargetDocument, cursor: CursorPosition?) async -> Int? {
        let payload = TransitionSwapPayload(
            markdown: target.markdown, blockIds: target.blockIds, expected: target.expected,
            managedBlockIds: Array(target.managedBlockIds), imageMeta: TransitionSwapPayload.images(target.imageMeta),
            zoomMode: false, scrollToStart: false, scrollToBlockId: nil)
        guard let payloadData = try? JSONEncoder().encode(payload), let payloadJSON = String(data: payloadData, encoding: .utf8),
              let themeJSON = Self.jsonLiteral(ThemeManager.shared.cssVariables) else { return nil }
        // The citation style, then the library, before the text, in the order today's mount sends them (the page runs its calls in order;
        // a style it already runs is skipped there).
        if let path = ExportSettingsManager.shared.settings.effectiveCSLStylePath,
           let styleXML = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
            page.evaluateJavaScript(MilkdownEditor.Coordinator.setCitationStyleScript(styleXML)) { _, _ in }
        }
        let library = ZoteroService.shared.cachedItemsJSON()
        if library != "[]" { page.evaluateJavaScript(MilkdownEditor.Coordinator.setCitationLibraryScript(library)) { _, _ in } }
        let useScrollRestore = cursor.map { !$0.cursorIsVisible && $0.topLine > 1.0 } ?? false
        let cursorJS = cursor.flatMap { useScrollRestore ? nil : "{line:\($0.line),column:\($0.column)}" } ?? "null"
        let script = """
            (() => { const ff = window.FinalFinal; ff.setTheme(\(themeJSON));
            const b = ff.beginTransition(); if (!b.ok) return JSON.stringify({ok: false, reason: 'begin ' + b.reason});
            const s = ff.swapTransition(b.token, \(payloadJSON)); if (!s.ok) return JSON.stringify({ok: false, reason: 'swap ' + s.reason});
            const c = \(cursorJS); if (c) { ff.setCursorPosition(c); }
            const t = ff.beginTransition(); if (!t.ok) return JSON.stringify({ok: false, reason: 'hold ' + t.reason});
            ff.focus(); return JSON.stringify({ok: true, token: t.token}); })()
            """
        guard let json = (try? await page.evaluateJavaScript(script)) as? String, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(TransitionTakeReply.self, from: data), reply.succeeded,
              let token = reply.token else {
            DebugLog.alwaysPersisted("[TRANS] the incoming Rich Text page did not take its text")
            return nil
        }
        if useScrollRestore, let topLine = cursor?.topLine {
            _ = try? await page.evaluateJavaScript("window.FinalFinal.scrollToLine(\(topLine))")
        }
        return token
    }

    /// The outgoing Markdown page's text at the begin and now, and its caret, WITHOUT ending its hold. Nil when it could not answer.
    private func takeMarkdownText(token: Int, from page: WKWebView) async -> MarkdownSwitchTake? {
        let script = "JSON.stringify(window.FinalFinal.takeTransitionText(\(token)))"
        guard let json = (try? await page.evaluateJavaScript(script)) as? String, let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(TransitionTakeReply.self, from: data), reply.succeeded,
              let base = reply.base, let raw = reply.raw, let cursor = reply.cursor else { return nil }
        return MarkdownSwitchTake(base: base, raw: raw, cursor: CursorPosition(line: cursor.line, column: cursor.column))
    }

    /// TransSwap's carry: once the outgoing page has left the window, its last text (the catch-up); its hold ends with the owed push dropped
    /// (the text is written here). With nothing typed since the begin the incoming page's hold just ends; otherwise the text goes through
    /// the per-block writer, the rows are read again and swapped onto the incoming page with its own typing put back on top.
    private func carryTypingOntoRichTextPage( // swiftlint:disable:this function_parameter_count
        _ blockSync: BlockSyncService, token: Int, pageToken: Int, outgoing: WKWebView, page: WKWebView,
        first: MarkdownSwitchTake, db: ProjectDatabase, pid: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.switchDetachTimeout)
        while outgoing.window != nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let last = await takeMarkdownText(token: token, from: outgoing) ?? first
        _ = try? await outgoing.evaluateJavaScript("JSON.stringify(window.FinalFinal.endTransition(\(token), 'discard'))")
        guard last.raw != last.base else {
            await blockSync.endTransition(token: pageToken, on: page)
            DebugLog.alwaysPersisted("[TRANS] carried kind=switch to rich text typed=0")
            return
        }
        // The typing through the queue: the per-block writer's synchronous step (its baseline is the begin's text), else today's direct
        // whole-document write.
        let text = MarkdownLeaderMap.recordText(fromRaw: last.raw)
        var queued = false
        if markdownWriter.inFlight == nil {
            let disposition = markdownWriter.prepare(MarkdownBlockWriter.Context(
                trigger: .writeNow, text: text, database: db, projectId: pid, service: blockSync, refire: {}))
            switch disposition {
            case .started, .nothingToWrite, .stayedRows: queued = true
            case .skippedOpenFence, .guardTripped, .noWriter, .refused, .unreadable, .heldForStructuralWork: queued = false
            }
        }
        if !queued { flushContentToDatabase(overrideContent: text) }
        if let next = blockSync.writer?.nextSequence, next > 1 {
            _ = await blockSync.awaitTransitionBarrier(through: next - 1, timeout: BlockSyncService.transitionBarrierTimeout)
        }
        guard let rows = try? db.fetchBlocks(projectId: pid) else {
            await blockSync.endTransition(token: pageToken, on: page)
            DebugLog.alwaysPersisted("[TRANS] carry: the rows could not be read; the page keeps the text it had")
            return
        }
        await swapCarriedRowsIn(Self.fullDocumentTarget(from: rows), pageToken: pageToken, page: page, cursor: last.cursor, blockSync)
    }

    /// A7's swap on the incoming page: the rows' text in, the typing done on it since the flip put back on top; the caret from the outgoing
    /// page when nothing was typed on the new one. A refusal writes the held typing and pushes the rows the old way (the one catch-up).
    private func swapCarriedRowsIn(
        _ target: ZoomTargetDocument, pageToken: Int, page: WKWebView, cursor: CursorPosition, _ blockSync: BlockSyncService
    ) async {
        // The rows hold the keys typed in the outgoing page before the flip; keys typed on the new page after it at the same place go after
        // them (`carriedTextFirst`), never before.
        let payload = TransitionSwapPayload(
            markdown: target.markdown, blockIds: target.blockIds, expected: target.expected,
            managedBlockIds: Array(target.managedBlockIds), imageMeta: TransitionSwapPayload.images(target.imageMeta),
            zoomMode: false, scrollToStart: false, scrollToBlockId: nil, carriedTextFirst: true)
        guard let payloadData = try? JSONEncoder().encode(payload), let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            await blockSync.endTransition(token: pageToken, on: page)
            return
        }
        let script = """
            (() => { const ff = window.FinalFinal; const s = ff.swapTransition(\(pageToken), \(payloadJSON));
            if (s.ok && s.replayed === 0) { ff.setCursorPosition({line: \(cursor.line), column: \(cursor.column)}); }
            return JSON.stringify(s); })()
            """
        let json = (try? await page.evaluateJavaScript(script)) as? String
        let reply = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(TransitionSwapReply.self, from: $0) }
        if let reply, reply.succeeded {
            NotificationCenter.default.post(name: .blockSyncDidPushContent, object: nil, userInfo: ["markdown": target.markdown])
            content = target.markdown
            DebugLog.alwaysPersisted("[TRANS] carried kind=switch to rich text replayed=\(reply.replayed ?? 0)")
            return
        }
        // The one catch-up: the typing held on the new page written, then the rows pushed the old way.
        DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=switch to rich text reason=\(reply?.reason ?? "no answer")")
        if let batch = reply?.batch, let seq = blockSync.writeTransitionBatch(batch) {
            _ = await blockSync.awaitTransitionBarrier(through: seq, timeout: BlockSyncService.transitionBarrierTimeout)
        }
        guard let db = projectDatabase, let pid = currentProjectId, let rows = try? db.fetchBlocks(projectId: pid) else { return }
        let fresh = Self.fullDocumentTarget(from: rows)
        await blockSync.setContentWithBlockIds(
            markdown: fresh.markdown, blockIds: fresh.blockIds, imageMeta: fresh.imageMeta, cursorBoundary: nil, cursorBoundaryEnd: nil,
            expectedBlocks: fresh.expected, managedBlockIds: fresh.managedBlockIds, zoomMode: false)
        content = fresh.markdown
    }

    /// Ends the outgoing hold (its owed push is sent, so the typing reaches Swift the ordinary way), forgets any staged page, `.idle`.
    private func abandonCarriedRichTextSwitch(token: Int, outgoing: WKWebView, why: String) async {
        DebugLog.alwaysPersisted("[TRANS] abandoned kind=switch to rich text: \(why)")
        _ = try? await outgoing.evaluateJavaScript("JSON.stringify(window.FinalFinal.endTransition(\(token), 'send'))")
        EditorPreloader.shared.discardStagedPages()
        transitionHolds.preparedRichTextPage = false
        if contentState == .editorTransition { contentState = .idle }
    }
}
