//
//  EditorViewState+SwitchTransition.swift
//  final final
//
//  Phase 5 job A9 (design: docs/architecture/write-queue-plan/phase5/a7-a10-design.md, sections 0 and 3; run record a9-notes.md): the
//  switch from Rich Text to Markdown with the typing carried across. Today's switch (ViewNotificationModifiers.swift,
//  `performLegacySwitchToMarkdown`) writes the 50 ms-late copy of the text, flips the editors at once and hands the new Markdown page its
//  text 0.5 to 2 s later: keys pressed in that gap reach no editor or are overwritten when the text arrives (measurements.md: 4 or 5 of 6
//  markers lost). The carried switch keeps the outgoing Rich Text page on screen and typeable until the incoming page has its text. In the
//  sync model's names (docs/architecture/tla/DocSyncCurrent.tla; README "Phase 5 step T", round 4, TransTwoPage):
//
//    TransBegin + TransLiveRead  the Rich Text page hands over its pending batch and starts holding (A7's `beginTransition`), the batch goes
//                                through the ordered queue,
//    TransBarrier                and the queue is waited for (`awaitSettled`), all while `contentState` is still `.idle`;
//    (F8)                        only then `.editorTransition`;
//    TransIncomingReady          the rows are read and assembled as the Markdown text (anchors, bibliography marker) and the incoming
//                                CodeMirror page, still detached (the standby, or a fresh page), is given that text; the outgoing page is
//                                live, focused and typeable throughout, every key held and recorded;
//    TransSwap                   the held typing is drained (`takeTransitionBatch`), the flip (`toggleEditorMode`, the page staged for
//                                `makeNSView`, which focuses it on attach), the drained typing through the queue, one more drain once the
//                                outgoing page has left the window (the catch-up), the rows read again, and the difference carried onto the
//                                incoming page as typing (`applySwitchCarry`), mapped over anything typed there since the flip.
//
//  `AblTwoPageEarlyTeardown` (the must-fail) is the flip before the incoming page has its text: today's switch.
//
//  Failure paths fall back to today's switch (section 0): the page could not begin, no incoming page could be loaded, the first drain
//  failed -> the hold ends and `legacy` runs; a stuck writer -> the hold ends and the switch is abandoned with a notice; a close, quit or
//  project switch meanwhile -> the hold ends and nothing else happens; a carry the page refuses -> the rows' text is pushed the old way
//  (`[TRANS] catchup=1`).
//

import Foundation
import WebKit

extension EditorViewState {
    /// How long the switch waits for the outgoing page to leave the window after the flip (one SwiftUI update; a bound for a fault).
    nonisolated static let switchDetachTimeout: Duration = .seconds(2)

    /// Whether a switch takes the carried path: not the UI tests' legacy switch, a configured block sync, not zoomed (a zoomed switch keeps
    /// today's path: its text is the zoomed range with mini-Notes that carry no ids; a9-notes.md).
    var usesCarriedSwitch: Bool {
        guard !TestMode.isUITestingLegacyTransition(for: .modeSwitch), let blockSync = blockSyncService, blockSync.webView != nil else {
            return false
        }
        return zoomedSectionIds == nil && zoomedSectionId == nil
    }

    // MARK: - The Markdown text from the rows

    /// The Markdown editor's text assembled from `rows` exactly as the switch has always assembled it: the editor assembly (the
    /// bibliography end marker after the last bibliography block), section anchors at each section's block, the bibliography start marker.
    static func markdownSwitchText(rows: [Block], sections: [SectionViewModel], sectionSync: SectionSyncService) -> String {
        let sorted = rows.sorted { lhs, rhs in
            (lhs.sortOrder, lhs.blockType == .heading ? 0 : 1) < (rhs.sortOrder, rhs.blockType == .heading ? 0 : 1)
        }
        let markdown = BlockParser.assembleMarkdownForEditor(from: sorted)
        // Each block's character offset in `markdown` (the anchors' offsets are in characters): the same walk as the assembly.
        let real = sorted.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
        let lastBib = real.lastIndex(where: { $0.isBibliography })
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (index, block) in real.enumerated() {
            if index > 0 { offset += 2 }
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
            if index == lastBib { offset += 2 + BlockParser.bibliographyEndMarker.count }
        }
        let anchored = sections.sorted { $0.sortOrder < $1.sortOrder }.compactMap { section in
            blockOffset[section.id].map { section.withUpdates(startOffset: $0) }
        }
        let withAnchors = sectionSync.injectSectionAnchors(markdown: markdown, sections: anchored)
        return sectionSync.injectBibliographyMarker(markdown: withAnchors, sections: sections)
    }

    // MARK: - The switch

    /// Starts the carried switch to Markdown (called by `performEditorModeToggle` in place of today's body). Marks the switch running at
    /// once (a zoom pressed from here on is held) and runs it on its own task; `legacy` runs today's switch when the carried one cannot.
    func startCarriedSwitchToMarkdown(
        sectionSync: SectionSyncService, cursor: CursorPosition?, legacy: @escaping @MainActor () -> Void,
        consumeCursor: @escaping @MainActor () -> Void = {}
    ) {
        transitionHolds.switchRunning = true
        // "Switching to Markdown…" once the switch has taken a second (UX contract 4.2's delayed progress toast), dismissed by id when the
        // task ends, whichever way: done, today's switch as the fallback, abandoned, the writer's timeout, or a close that refused it.
        let notice = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.switchingToMarkdownMessage)
        Task { @MainActor [weak self] in
            defer {
                notice.stop()
                SwitchKeyResendFilter.shared.disarmSoon()
            }
            guard let self else { return }
            defer { self.transitionHolds.switchRunning = false }
            // The structural gate: a section command or a second Cmd-/ pressed during the switch is held behind it and runs after it.
            guard await self.structuralGate.acquire() == .granted else {
                DebugLog.log(.lifecycle, "[TRANS] switch to markdown not run: the project is closing or switching")
                return
            }
            defer { self.structuralGate.release() }
            // The saved caret is consumed once the switch is over (the outgoing page has been dismantled by then); see
            // MilkdownCoordinator+PreparedPage.swift. Today's path consumes it in the incoming editor's mount, as before.
            defer {
                if self.transitionHolds.switchCarriedToEnd { consumeCursor() }
                self.transitionHolds.switchCarriedToEnd = false
            }
            await self.runCarriedSwitchToMarkdown(sectionSync: sectionSync, cursor: cursor, legacy: legacy)
        }
    }

    private func runCarriedSwitchToMarkdown(
        sectionSync: SectionSyncService, cursor: CursorPosition?, legacy: @MainActor () -> Void
    ) async {
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork, editorMode == .wysiwyg else { return }
        guard let blockSync = blockSyncService, let outgoing = blockSync.webView, let db = projectDatabase,
              let pid = currentProjectId, await waitForIdleContentState() else {
            DebugLog.alwaysPersisted("[TRANS] fallback=notReady kind=switch to markdown")
            legacy()
            return
        }
        SwitchKeyResendFilter.shared.arm(outgoing: outgoing)
        let clock = ContinuousClock()
        let pressed = clock.now
        // The incoming page loads while steps 1 to 3 run (they wait on the page and the writer; the load waits on WebKit), so the switch
        // costs the longer of the two, not their sum.
        let incomingPage = Task { @MainActor in await EditorPreloader.shared.takeCodeMirrorPageForSwitch() }
        // TransBegin + TransLiveRead + TransBarrier.
        let token: Int
        switch await blockSync.beginTransition() {
        case .notStarted(let reason):
            DebugLog.alwaysPersisted("[TRANS] fallback=beginFailed kind=switch to markdown reason=\(reason)")
            legacy()
            return
        case .barrierTimedOut:
            toastCenter.show(ToastFactory.switchCancelledBehindEarlierChange())
            return
        case .ready(let began):
            token = began
        }
        contentState = .editorTransition // F8: after the barrier; nothing is pending, the page holds

        // TransIncomingReady: the rows' text into the detached incoming page.
        guard let rows = try? db.fetchBlocks(projectId: pid) else {
            await abandonCarriedSwitch(blockSync, token: token, outgoing: outgoing, why: "the rows could not be read")
            legacy()
            return
        }
        let text = Self.markdownSwitchText(rows: rows, sections: sections, sectionSync: sectionSync)
        guard let page = await prepareIncomingMarkdownPage(await incomingPage.value, text: text, cursor: cursor) else {
            await abandonCarriedSwitch(blockSync, token: token, outgoing: outgoing, why: "no Markdown page could be prepared")
            legacy()
            return
        }
        DebugLog.alwaysPersisted(
            "[TRANS] incoming ready kind=switch to markdown chars=\(text.utf8.count) after \(EditorPreloader.milliseconds(clock.now - pressed)) ms")
        // UI-test seam: the window in which typing used to be lost, widened on purpose. The outgoing page is live and records throughout.
        await TestMode.holdTransition("switch to markdown")
        guard activeLifecycle == nil, !structuralGate.isClosedToNewWork, currentProjectId == pid else {
            await abandonCarriedSwitch(blockSync, token: token, outgoing: outgoing, why: "a close, quit or switch started")
            return
        }

        // TransSwap, first half: what was typed while the page was prepared, then the flip.
        guard let first = await blockSync.takeTransitionBatch(token: token, from: outgoing) else {
            await abandonCarriedSwitch(blockSync, token: token, outgoing: outgoing, why: "the typing could not be read")
            legacy()
            return
        }
        sourceContent = text
        transitionHolds.switchCarriedToEnd = true
        EditorPreloader.shared.stageCodeMirrorPage(page, content: text)
        toggleEditorMode()
        markdownWriter.noteLoaded(text: text, pid: pid)
        DebugLog.alwaysPersisted(
            "[TRANS] swapped kind=switch to markdown (flip) after \(EditorPreloader.milliseconds(clock.now - pressed)) ms")

        // TransSwap, second half: the carry, with the catch-up.
        await carryTypingOntoMarkdownPage(
            blockSync, token: token, outgoing: outgoing, page: page, first: first, text: text,
            sectionSync: sectionSync, db: db, pid: pid)
        contentState = .idle
        _ = try? await page.evaluateJavaScript("JSON.stringify(window.FinalFinal.finishIncomingSwitch('send'))")
        DebugLog.alwaysPersisted("[TRANS] switch to markdown done in \(EditorPreloader.milliseconds(clock.now - pressed)) ms")
    }

    /// The incoming page, detached, given `text` and the caret, tracking from now on (TransIncomingReady). Nil when none could be had.
    private func prepareIncomingMarkdownPage(_ loaded: WKWebView?, text: String, cursor: CursorPosition?) async -> WKWebView? {
        guard let page = loaded else { return nil }
        let useScrollRestore = cursor.map { !$0.cursorIsVisible && $0.topLine > 1.0 } ?? false
        let cursorJS = cursor.flatMap { useScrollRestore ? nil : "{line:\($0.line),column:\($0.column)}" } ?? "null"
        guard let textJSON = Self.jsonLiteral(text), let themeJSON = Self.jsonLiteral(ThemeManager.shared.cssVariables) else { return nil }
        let script = """
            (() => { window.FinalFinal.initialize({content: \(textJSON), theme: \(themeJSON), cursorPosition: \(cursorJS)});
            return JSON.stringify(window.FinalFinal.prepareIncomingSwitch()); })()
            """
        guard let reply = (try? await page.evaluateJavaScript(script)) as? String, reply.contains("\"ok\":true") else {
            DebugLog.alwaysPersisted("[TRANS] the incoming Markdown page did not take its text")
            return nil
        }
        if useScrollRestore, let topLine = cursor?.topLine {
            _ = try? await page.evaluateJavaScript("window.FinalFinal.scrollToLine(\(topLine))")
        }
        return page
    }

    /// TransSwap's carry: the first drain through the queue; once the outgoing page has left the window, the last drain (the catch-up: keys
    /// that reached it between the first drain and the flip); the hold ends; the rows are read again and the difference goes onto the page.
    private func carryTypingOntoMarkdownPage( // swiftlint:disable:this function_parameter_count
        _ blockSync: BlockSyncService, token: Int, outgoing: WKWebView, page: WKWebView,
        first: (batch: BlockChanges, cursor: CursorPosition?), text: String,
        sectionSync: SectionSyncService, db: ProjectDatabase, pid: String
    ) async {
        var lastSeq = blockSync.writeTransitionBatch(first.batch)
        var cursor = first.cursor
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.switchDetachTimeout)
        while outgoing.window != nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        var drained = first.batch.updates.count + first.batch.inserts.count + first.batch.deletes.count
        if let last = await blockSync.takeTransitionBatch(token: token, from: outgoing) {
            if let seq = blockSync.writeTransitionBatch(last.batch) { lastSeq = seq }
            if let lastCursor = last.cursor { cursor = lastCursor }
            drained += last.batch.updates.count + last.batch.inserts.count + last.batch.deletes.count
        }
        await blockSync.endTransition(token: token, on: outgoing)
        guard let seq = lastSeq else {
            DebugLog.alwaysPersisted("[TRANS] carried kind=switch to markdown drained=0")
            return
        }
        guard await blockSync.awaitTransitionBarrier(through: seq, timeout: BlockSyncService.transitionBarrierTimeout),
              let rows = try? db.fetchBlocks(projectId: pid) else {
            DebugLog.alwaysPersisted("[TRANS] carry: the typing did not settle; the page keeps the rows' text as read before")
            return
        }
        let carried = Self.markdownSwitchText(rows: rows, sections: sections, sectionSync: sectionSync)
        let reply = await applySwitchCarry(page: page, from: text, to: carried, cursor: cursor)
        if reply.contains("\"ok\":true") {
            markdownWriter.noteLoaded(text: carried, pid: pid)
            DebugLog.alwaysPersisted("[TRANS] carried kind=switch to markdown drained=\(drained) reply=\(reply.prefix(120))")
        } else {
            // The one catch-up: the rows' text pushed the old way (keys typed on the new page in the last moments may be overwritten).
            DebugLog.alwaysPersisted("[TRANS] catchup=1 kind=switch to markdown reply=\(reply.prefix(200))")
            _ = try? await page.evaluateJavaScript("JSON.stringify(window.FinalFinal.finishIncomingSwitch('discard'))")
            sourceContent = carried
            forcedPushGeneration += 1
        }
    }

    private func applySwitchCarry(page: WKWebView, from base: String, to target: String, cursor: CursorPosition?) async -> String {
        guard let fromJSON = Self.jsonLiteral(base), let toJSON = Self.jsonLiteral(target) else { return "{\"ok\":false}" }
        let cursorJS = cursor.map { "{line:\($0.line),column:\($0.column)}" } ?? "null"
        let script = "JSON.stringify(window.FinalFinal.applySwitchCarry({from: \(fromJSON), to: \(toJSON), cursor: \(cursorJS)}))"
        return ((try? await page.evaluateJavaScript(script)) as? String) ?? "{\"ok\":false,\"reason\":\"no answer\"}"
    }

    /// Ends the hold (the held typing goes out with the next poll), forgets any staged page and returns to `.idle`.
    private func abandonCarriedSwitch(_ blockSync: BlockSyncService, token: Int, outgoing: WKWebView, why: String) async {
        DebugLog.alwaysPersisted("[TRANS] abandoned kind=switch to markdown: \(why)")
        await blockSync.endTransition(token: token, on: outgoing)
        EditorPreloader.shared.discardStagedPages()
        if contentState == .editorTransition { contentState = .idle }
    }

    /// `value` as a JavaScript string literal (JSON is a JavaScript expression: no template-literal escaping to get wrong).
    static func jsonLiteral(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
