//
//  EditorPreloader+CitationPrefill.swift
//  final final
//
//  Working the document's citations out ahead of time in the standby Rich Text page
//  (plan: .claude/superdev/write-queue-phase3b/plan-citations-ahead-of-time.md). The pure pieces (guard, reply parsing, step
//  rules, the JavaScript sent) are in CitationPrefill.swift; this file is the one production function that uses them against the
//  spare, and the wiring of `CitationPrefillScheduler` (CitationPrefillScheduler.swift), which decides when to call it.
//

import WebKit

extension EditorPreloader {

    /// Why a fill on `spare` that started on `generation` must stop now, or nil to go on.
    private func citationPrefillStopReason(spare: WKWebView, generation: Int) -> CitationPrefillStop? {
        var spareIsReady = false
        if case .ready = milkdownState, preloadedMilkdownView === spare { spareIsReady = true }
        return CitationPrefillGuard.stopReason(
            expectedGeneration: generation, currentGeneration: milkdownSpareGeneration,
            claimedGeneration: milkdownClaimedGeneration, spareIsReady: spareIsReady)
    }

    private static func elapsedMs(since startNanos: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000
    }

    /// One call into the Rich Text page through `callAsyncJavaScript` (the document and the budget travel as arguments, so nothing is
    /// escaped on the Swift side).
    private func citationPrefillPageCall(_ spare: WKWebView, body: String, arguments: [String: Any]) async -> Result<Any, Error> {
        await withCheckedContinuation { continuation in
            spare.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { continuation.resume(returning: $0) }
        }
    }

    /// Works the document's citations out ahead of time in the standby Rich Text page `spare`, so the switch to Rich Text finds
    /// them already formatted. The one production entry for it; the page does the work in its own process.
    ///
    /// What it does, in order, each time stopping at once if the spare was claimed or replaced since `generation` (the value of
    /// `milkdownSpareGeneration` when the caller chose this spare):
    ///   1. If `pushLibrary` and the cached citation library is not `[]`, gives it to the spare -- the call the mount makes
    ///      (`MilkdownEditor.Coordinator.setCitationLibraryScript`), so the mount's own push is then identical to it. The
    ///      scheduler passes `false` when the spare already holds this revision of the library.
    ///   2. Checks again, then calls the page's `prefillCitationsBegin(markdown)`, which parses the document and queues its
    ///      citation groups (a late `begin` would parse inside a page the user is loading, hence the check right before it).
    ///   3. Calls `prefillCitationsStep(100)` until the page says it is done, checking before each call.
    /// Main-thread cost: the library push, the `begin` hand-off (the document is the call's argument) and one small call per
    /// 100 ms step. Any error, an unexpected answer or a page without these functions ends the fill, never throws. An
    /// unfinished fill leaves a partly filled memo, which only means the missing groups are formatted at the switch, as today.
    @discardableResult
    func prefillCitations(
        in spare: WKWebView, markdown: String, generation: Int, pushLibrary: Bool = true
    ) async -> CitationPrefillOutcome {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        var outcome = CitationPrefillOutcome(generation: generation, documentChars: markdown.utf16.count)
        var progress = CitationPrefillProgress()
        let stop = await runCitationPrefill(in: spare, markdown: markdown, pushLibrary: pushLibrary, outcome: &outcome, progress: &progress)
        outcome.stop = stop
        outcome.steps = progress.steps
        outcome.formatted = progress.formatted
        outcome.totalMs = Self.elapsedMs(since: startNanos)
        DebugLog.log(
            .zotero,
            "[CitationPrefill] generation \(generation) ended: \(stop.logText) -- queued \(outcome.begin?.pending ?? 0), "
                + "formatted \(progress.formatted), steps \(progress.steps), \(Int(outcome.totalMs)) ms")
        return outcome
    }

    /// The fill itself, for the spare generation `outcome` was created with; returns why it ended.
    private func runCitationPrefill(
        in spare: WKWebView, markdown: String, pushLibrary: Bool,
        outcome: inout CitationPrefillOutcome, progress: inout CitationPrefillProgress
    ) async -> CitationPrefillStop {
        let generation = outcome.generation
        if let stop = citationPrefillStopReason(spare: spare, generation: generation) { return stop }
        if markdown.isEmpty { return .noDocument }

        if pushLibrary { pushCachedLibraryToSpare(spare, outcome: &outcome) }

        // Verdict must-fix 3: the check right before `begin`, not only before each step. A claim that landed since the caller chose
        // this spare must not be followed by a parse inside the page the user is now loading.
        if let stop = citationPrefillStopReason(spare: spare, generation: generation) { return stop }

        if let stop = await beginCitationPrefill(in: spare, markdown: markdown, outcome: &outcome) { return stop }
        if outcome.begin?.pending == 0 { return .completed }
        return await stepCitationPrefill(in: spare, generation: generation, progress: &progress)
    }

    /// The step loop: 100 ms of the page's work per call, the guard checked before each, until the page is done or something ends it.
    private func stepCitationPrefill(in spare: WKWebView, generation: Int, progress: inout CitationPrefillProgress) async -> CitationPrefillStop {
        while true {
            if let stop = citationPrefillStopReason(spare: spare, generation: generation) { return stop }
            let call = await citationPrefillPageCall(spare, body: CitationPrefillPageCalls.stepBody, arguments: ["budgetMs": 100])
            switch call {
            case .failure(let error):
                return .pageError(error.localizedDescription)
            case .success(let raw):
                if CitationPrefillPageCalls.isMissing(raw) { return .pageFunctionMissing }
                guard let reply = CitationPrefillStepReply.parse(raw) else { return .unexpectedReply("step") }
                if let stop = progress.record(reply) { return stop }
            }
        }
    }

    /// Gives the spare the cached citation library (the call the mount makes) unless there is none.
    private func pushCachedLibraryToSpare(_ spare: WKWebView, outcome: inout CitationPrefillOutcome) {
        let libraryJSON = ZoteroService.shared.cachedItemsJSON()
        guard libraryJSON != "[]" else { return }
        outcome.libraryPushed = true
        spare.evaluateJavaScript(MilkdownEditor.Coordinator.setCitationLibraryScript(libraryJSON)) { _, error in
            if let error {
                DebugLog.log(.zotero, "[CitationPrefill] Pushing the citation library to the Milkdown spare failed: \(error.localizedDescription)")
            }
        }
    }

    /// The `begin` call: nil means the page queued the document's groups and the steps may start.
    private func beginCitationPrefill(
        in spare: WKWebView, markdown: String, outcome: inout CitationPrefillOutcome
    ) async -> CitationPrefillStop? {
        let call = await citationPrefillPageCall(spare, body: CitationPrefillPageCalls.beginBody, arguments: ["markdown": markdown])
        switch call {
        case .failure(let error):
            return .pageError(error.localizedDescription)
        case .success(let raw):
            if CitationPrefillPageCalls.isMissing(raw) { return .pageFunctionMissing }
            guard let begin = CitationPrefillBeginReply.parse(raw) else { return .unexpectedReply("begin") }
            outcome.begin = begin
            switch begin.status {
            case .notReady: return .notReady
            case .parseFailed: return .parseFailed
            case .accepted: return nil
            }
        }
    }

    // MARK: - The scheduler

    /// Creates the scheduler that decides when `prefillCitations` runs, and connects the Zotero service's cache writes to it. Called
    /// once from `startPreloading()`, i.e. only where the preloader runs (production, and UI tests that enable it) -- unit tests
    /// never reach it. Not called when `TestMode.isCitationPrefillSchedulerEnabled` is false (`FF_UI_TESTING_CITATION_PREFILL`
    /// `off` / `memoOff`).
    ///
    /// The document text reaches it from `ViewNotificationModifiers.handleContentChange`, the standby page's state from
    /// `didFinish` / `claimMilkdownView`, the style from the `.citationStyleChanged` observer and the library from
    /// `ZoteroService.onLibraryChanged`.
    func installCitationPrefillScheduler() {
        guard citationPrefillScheduler == nil else { return }
        let environment = CitationPrefillScheduler.Environment(
            readySpareGeneration: { [unowned self] in
                guard case .ready = self.milkdownState, self.preloadedMilkdownView != nil else { return nil }
                return self.milkdownSpareGeneration
            },
            libraryRevision: { ZoteroService.shared.itemsRevision },
            signature: { text in
                // The scan reads the whole document: off the main thread, which only waits for the answer.
                await Task.detached(priority: .utility) { CitationGroupSignature.of(text) }.value
            },
            fill: { [unowned self] generation, markdown, pushLibrary in
                guard case .ready = self.milkdownState, let spare = self.preloadedMilkdownView, self.milkdownSpareGeneration == generation else {
                    return CitationPrefillOutcome(generation: generation, documentChars: markdown.utf16.count, stop: .replaced)
                }
                return await self.prefillCitations(in: spare, markdown: markdown, generation: generation, pushLibrary: pushLibrary)
            },
            now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
            sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.001) * 1_000_000_000)) })
        citationPrefillScheduler = CitationPrefillScheduler(environment: environment)
        ZoteroService.shared.onLibraryChanged = { [weak self] in self?.citationPrefillScheduler?.libraryChanged() }
    }

    /// The `.citationStyleChanged` observer's body: gives the standby page the new style, then tells the scheduler, whose key then
    /// differs from the last fill's (the page's engine rebuilt itself and emptied its memo).
    func citationStyleDidChange() {
        pushCitationStyleToMilkdownSpare(reason: "style changed")
        citationPrefillScheduler?.styleChanged()
    }

    /// Called from `ViewNotificationModifiers.handleContentChange` on every document change (both editors, project open). Does
    /// nothing where there is no scheduler.
    func noteDocumentChanged(_ markdown: String) {
        citationPrefillScheduler?.documentChanged(markdown)
    }
}
