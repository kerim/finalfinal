//
//  MarkdownBlockWriter.swift
//  final final
//
//  t-94369a83 Phase 4a, plan v2 section 1(a), 1(d), 1(f), judge verdict 2 notes C1, C3, C4, model ruling M1: the
//  MAIN-ACTOR half of saving Markdown typing block by block through the ordered write queue. Owned by `EditorViewState`
//  (`markdownWriter`). The pure half (what to write) is `MarkdownBlockDiff`; the part that talks to `DocumentWriter` is
//  `BlockSyncService+Markdown.swift` (`reserveMarkdownTurn`, `applyMarkdownTurn`, `ensureWriter`). This type holds the
//  BASELINE (what the last write, or the last load, says the stored rows look like), the in-flight write, and the one
//  synchronous step that decides what a debounce fire (or a bibliography flush) writes.
//
//  THE BASELINE has two states.
//
//    .rows  No trusted baseline: the next fire compares the editor's text with the STORED ROWS (`fetchBlocks`, aligned
//           to the parse). This is the state after every Swift load or push into the Markdown editor (`noteLoaded`),
//           after `reset()`, after a direct whole-document write (`noteDirectWholeWrite`) and after any refused,
//           failed, writer-skipped (retire or drain), stale-epoch or partly dropped batch. (A fire the open-fence guard
//           skips keeps whatever baseline it found.) It is the EVERYDAY first-fire path: the loaded text came from the
//           database, so whatever differs from the rows at that fire is the user's typing since.
//    .text  Set only after a clean applied write: the written parse's blocks with the ids the write gave them. The next
//           fire diffs against them and reads no ROWS. It still reads two single values on the main thread: the
//           project's write epoch (to see that no direct write or `configure` moved it) and, for the parse, the Notes
//           heading title (`fetchNotesHeadingTitle`, every fire in both modes).
//
//  `version` is bumped by `noteLoaded`, `noteDirectWholeWrite`, `reset` and by every baseline change a completion makes.
//  A completion changes the baseline only when `version` is unchanged since its reservation (judge M3/F5): a push or a
//  reset that landed while the write was in flight already put the baseline back to `.rows`, and a completion must
//  never put old text back over that.
//
//  C1: the identity check, the epoch read, `reserve()` and `noteFetched()` run SYNCHRONOUSLY in the fire's (or
//  `writeNow`'s) main-actor turn, right after the gate checks, BEFORE any Task is created; only the apply (waitForTurn,
//  write) is asynchronous. A lifecycle that arms after that turn finds the reserved sequence in the queue and waits for
//  it; one that arms before it makes the fire's own gate drop the write, so nothing is ever reserved after FB.
//
//  M1: the text a fire writes is `editorState.content` READ AT FIRE TIME, in the same synchronous step as the parse, the
//  diff and the reservation. Never the text captured when the debounce was scheduled: a push made while `contentState`
//  is not `.idle` (bibliography or Notes rebuild, structural op, zoom) does not restart a scheduled re-parse, so a
//  surviving schedule's captured text can be OLDER than the database.
//
//  C3/C4: the open-fence guard skips a DEBOUNCE FIRE and keeps the baseline (no whole-document fallback); inside
//  `writeNow` a guard trip falls back to today's `flushContentToDatabase(overrideContent:)`, because the bibliography
//  rebuild that follows reads the rows. A diff that is empty ONLY because the pre-filter dropped everything stays `.rows`
//  and schedules nothing.
//
//  Retry: any non-clean outcome puts the baseline back to `.rows` and schedules a NORMAL debounce fire through the
//  caller's `refire` closure (every gate runs again). There is no immediate re-fire inside the task. A second
//  consecutive failure is logged with `DebugLog.alwaysPersisted` and schedules nothing further (the next keystroke
//  does), so a persistent failure cannot loop once a second.
//
//  LEGACY SWITCH. `isLegacyReparse` (the UI-test flag `FF_UI_TESTING_MD_LEGACY_REPARSE`, read when the editor state is
//  created) turns every piece of this type off: the set-point methods return at once and the callers use today's code.
//
//  THE PARSE MEMO (t-2fbe4c9b, Phase 4c job 3). `prepare` looks the parse of the text up in `parseCache` (ViewState/MarkdownParseCache.swift:
//  a byte-exact memo of `BlockParser.parse` and the open-fence scan, prepared in the background or stored by an earlier `prepare`)
//  and parses on the main thread only on a miss; the `[MdWrite]` line ends with `cache=hit|miss`. Besides the lookup, `prepare` also
//  changed in three ways: the Notes-title read and `ExportSettings.load()` (once; they build the key) now come BEFORE the open-fence
//  check instead of after it, the miss path passes the bibliography names to the parse explicitly (so the stored entry is keyed by
//  exactly what it was parsed with), and `line.chars` reads the key's contiguous text. The hold check, writer identity, `resolveMode`,
//  the baseline side of the fence check, `fetchRows`, `baselineEntries`, the diff and the reservation are as they were, in the same order.
//
//  File layout (SwiftLint's type-body-length applies to the class body, so the parts sit in same-file extensions):
//  the state and the public API here; the synchronous core and `writeNow` in "The synchronous core"; the completion
//  in "Completion"; the `[MdWrite]` line in "The timing line".
//

import Foundation

@MainActor
final class MarkdownBlockWriter {

    // MARK: - Baseline

    /// The baseline after a clean write: the written parse's blocks (ids, keys, flags) and what they were written against.
    struct TextBaseline: Equatable {
        let entries: [MarkdownBlockDiff.Entry]
        /// The project's `blockWriteEpoch` the write was stamped with. A different stored epoch means a direct whole-document
        /// write or a `configure` happened since, and the entries no longer describe the rows.
        let epoch: Int64
        let projectId: String
        /// Whether the written text ended inside an open code fence or `$$` block (the open-fence guard's baseline side).
        let endsOpen: Bool
    }

    enum Baseline: Equatable {
        case rows
        case text(TextBaseline)

        var label: String {
            switch self {
            case .rows: return "rows"
            case .text: return "text"
            }
        }

        var isRows: Bool {
            if case .rows = self { return true }
            return false
        }
    }

    private(set) var baseline: Baseline = .rows
    private(set) var version = 0
    /// The write in flight: the apply Task of the last reserved turn, nil when none. A debounce fire and `writeNow` await
    /// it (`while let t = inFlight { await t.value }`) before they do anything else.
    private(set) var inFlight: Task<Void, Never>?
    private var inFlightToken = 0
    private(set) var consecutiveFailures = 0
    /// What the last Swift push put into the Markdown editor. Kept only for the diagnostic log line and for tests.
    private(set) var loadedText: String?
    /// How the last apply of a reserved turn ended, keyed by its `inFlightToken`: `landed` is true when the user's text
    /// is in the rows (a clean apply, with or without pre-filtered bibliography or Notes changes), false for every
    /// other outcome. `writeNow` reads it after it awaits its own write (judge R1).
    private var lastApply: (token: Int, landed: Bool)?
    /// The last `[MdWrite]` timing line this writer produced (tests read it here; the e2e reads the log).
    private(set) var lastTimingLine: String?
    /// t-4a8fd8af: the structural hold (count, held refire, waiters). Its type, its API and every write to it live in
    /// MarkdownBlockWriter+StructuralHold.swift; it is a stored property here only because an extension cannot add one.
    var structuralHoldState = StructuralHoldState()
    /// t-2fbe4c9b: the memo of the whole-text parse `prepare` needs (see the header). `reset()` empties it; `noteLoaded` does not.
    let parseCache: MarkdownParseCache
    /// t-b097670d: the status, tags and goals of the headings this writer deleted, for a heading that comes back in a later save. A stored
    /// property only because an extension cannot add one: its API and every write to it are in MarkdownBlockWriter+RemovedHeadings.swift.
    var removedHeadings = RemovedHeadingMemory()
    #if DEBUG
    /// Test seams: the source of the temp ids the diff mints, and a look at the changes a step reserved.
    var testMakeTempId: (() -> String)?
    var testChangesObserver: ((BlockChanges) -> Void)?
    fileprivate var tempIdSource: () -> String { testMakeTempId ?? MarkdownBlockDiff.makeTempId }
    #else
    fileprivate var tempIdSource: () -> String { MarkdownBlockDiff.makeTempId }
    #endif

    /// True when the UI-test flag `FF_UI_TESTING_MD_LEGACY_REPARSE` is set: every new piece is off.
    var isLegacyReparse: Bool
    var isEnabled: Bool { !isLegacyReparse }

    /// `parseMemoDisabled`: the UI-test flag `FF_UI_TESTING_NO_PARSE_MEMO` (read once, here): the parse memo and the scan memo are off.
    init(
        isLegacyReparse: Bool = TestMode.isUITestingMarkdownLegacyReparse, parseMemoDisabled: Bool = TestMode.isUITestingNoParseMemo
    ) {
        self.isLegacyReparse = isLegacyReparse
        parseCache = MarkdownParseCache(isDisabled: parseMemoDisabled)
    }

    // MARK: - Set-points

    /// Swift put `text` into the Markdown editor (the switch into Markdown, the initial load, CodeMirror's
    /// `onWebViewReady`, and every push through `CodeMirrorCoordinator.setContent`): the baseline is the stored rows from
    /// here. Stores the text only; does NO parse and NO database read. Calling it more often than strictly needed only
    /// costs a re-align at the next fire; it never loses data. A push is also a fresh start for the failure count (judge
    /// R7). `pid` names the project the text belongs to; nothing reads it today, the parameter keeps the call sites explicit.
    func noteLoaded(text: String, pid: String?) {
        guard isEnabled else { return }
        loadedText = text
        baseline = .rows
        consecutiveFailures = 0
        version += 1
    }

    /// A direct whole-document write (`flushContentToDatabase`: zoom, the mode switch, export, version snapshots, the
    /// legacy fallback) replaced the rows with a fresh parse of `text`: the ids a `.text` baseline holds are gone.
    func noteDirectWholeWrite(text: String) {
        guard isEnabled else { return }
        loadedText = text
        baseline = .rows
        // The recovery path (a failed per-block write falls back to a direct write) ends the failure streak, as a push does.
        consecutiveFailures = 0
        version += 1
    }

    /// t-4a8fd8af (plan A.3): a structural job (Delete Section, ...) was queued after the click's typing batch was reserved.
    /// The job changes the rows behind the batch, so the baseline goes back to `.rows` and the version moves: the batch's
    /// completion (`version == versionAtReservation` fails) then leaves the baseline on `.rows` instead of installing a
    /// `.text` baseline that names rows the job deleted.
    func noteQueuedStructuralJob() {
        guard isEnabled else { return }
        baseline = .rows
        version += 1
    }

    /// The editor state is being reset (project switch or close), the editor mode changed, or a zoom started: nothing
    /// about the old document describes the new one. An in-flight write is NOT cancelled (a reserved sequence must
    /// settle); its completion sees the new version and leaves the baseline alone.
    func reset() {
        guard isEnabled else { return }
        loadedText = nil
        baseline = .rows
        consecutiveFailures = 0
        version += 1
        parseCache.reset()
        structuralHoldState.pullOwed = false   // a pull owed to the old document must not act on the new one (O29)
    }

    // MARK: - Dispositions

    /// What one synchronous step decided. The callers act on it; the writer has already updated its own state.
    enum Disposition: Equatable, Sendable {
        /// A turn was reserved and the apply Task now runs as `inFlight`.
        case started
        /// The text is what the baseline says is stored: nothing to write (the baseline was advanced to `.text`).
        case nothingToWrite
        /// Nothing to send, but only because the pre-filter dropped every change (C4): the baseline stays `.rows`.
        case stayedRows
        /// Debounce fire only: the text ends inside an open fence or `$$` block and the baseline did not. Skipped.
        case skippedOpenFence
        /// `writeNow` only: the same guard tripped. The caller falls back to `flushContentToDatabase(overrideContent:)` (C3).
        case guardTripped
        /// The service has no writer. The caller's fallback is today's whole-document write.
        case noWriter
        /// The reservation was refused (identity mismatch, epoch unavailable): nothing reserved, rows mode, a retry is scheduled.
        case refused(MarkdownRefusal)
        /// The rows could not be read: rows mode, a retry is scheduled.
        case unreadable
        /// Debounce fire only (t-4a8fd8af): a structural command's hold is up, so nothing was reserved and the fire's `refire`
        /// closure was stored; releasing the hold (or `requestRefire()`) runs it. See MarkdownBlockWriter+StructuralHold.swift.
        case heldForStructuralWork
    }

    /// What `writeNow` did, for the bibliography flush hook.
    enum WriteNowOutcome: Equatable, Sendable {
        /// The text was written through the queue (or was already stored). The bibliography update continues.
        case proceeded
        /// The caller must write today's way: `flushContentToDatabase(overrideContent:)`. No writer, or the open-fence
        /// guard tripped (C3: the rebuild that follows reads the rows, which must carry the user's text), or the editor
        /// state has no database. Every guard was true in the same main-actor turn as this answer.
        case fallBackToDirectWrite
        /// Nothing was written and nothing should be: a guard failed after the in-flight await (M5), or the reservation
        /// was refused (a retry is scheduled). The bibliography update continues exactly as it does today when a guard fails.
        case abandoned
    }

    // MARK: - The debounce fire's synchronous step

    /// The debounce fire's synchronous step (plan 1(d) step 5). The caller has already awaited `inFlight`, re-checked the
    /// generation and passed every gate, and passes the text it just READ from `editorState.content` (M1). No suspension
    /// in here: the parse, the alignment, the diff, the reservation and the start of the apply Task are one main-actor turn.
    ///
    /// - Parameter refire: schedules a NORMAL debounce fire (every gate runs again). Called after any non-clean outcome.
    @discardableResult
    func prepareAndStart(
        text: String,
        database: ProjectDatabase,
        projectId: String,
        service: BlockSyncService?,
        refire: @escaping @MainActor () -> Void
    ) -> Disposition {
        guard let service else {
            DebugLog.log(.lifecycle, "[MdWrite] no block-sync service: today's whole-document write")
            return .noWriter
        }
        return prepare(Context(
            trigger: .debounceFire, text: text, database: database, projectId: projectId, service: service, refire: refire))
    }

    // MARK: - writeNow (the bibliography and Notes flush)

    /// The bibliography flush (plan 1(f), judge M5): cancel the debounce, wait for the write in flight, RE-CHECK every
    /// guard (`guardsHold`), then diff and write the text the flush would have written (`overrideContent ??
    /// switchInProgressContent ?? content`, the exact source `flushContentToDatabase` uses) and wait for that write.
    ///
    /// The caller does the fallback (it has `flushContentToDatabase`); this type never writes whole documents.
    ///
    /// The bibliography rebuild that follows reads the ROWS, so `.proceeded` is returned only when the user's text is in
    /// them: a clean apply, an empty diff (`.nothingToWrite`), or a diff that was empty only because of the pre-filter
    /// (`.stayedRows`). Any other end (the write failed, was skipped, was refused for a stale epoch or dropped changes)
    /// re-checks the guards: they hold -> `.fallBackToDirectWrite` (the direct write this hook always made before Phase
    /// 4a); they do not (a lifecycle armed, the mode changed...) -> `.abandoned`, and the debounce is re-armed so the
    /// typing is still saved (judge R1, R2). A skip caused by a lifecycle drain therefore never writes directly. When no
    /// turn could be reserved at all (no writer, another project's writer, an unreadable epoch or rows, the open-fence
    /// guard) the guards held in the same main-actor turn, so the answer is `.fallBackToDirectWrite` at once.
    ///
    /// t-4a8fd8af (O22): while a structural command's hold is up (`isHeldForStructuralWork`) `writeNow` WAITS for the release
    /// BEFORE it reserves anything, so it is never `inFlight` while it waits (step 8's `while let inFlight` loop-await would
    /// otherwise deadlock on it) and it diffs against the rows the job left. `bypassingStructuralHold` is for the click's OWN
    /// mismatch flush (plan B1), which runs while its own hold is up and before its job is reserved.
    func writeNow(
        overrideContent: String?,
        editorState: EditorViewState,
        bypassingStructuralHold: Bool = false,
        guardsHold: @MainActor () -> Bool,
        refire: @escaping @MainActor () -> Void
    ) async -> WriteNowOutcome {
        // `flushContentToDatabase` cancels the pending debounce first; so does this.
        editorState.blockReparseTask?.cancel()
        editorState.blockReparseTask = nil
        // Wait first (the hold, then the write in flight), then reserve; nothing suspends between the last check and `prepare`.
        await awaitQuietWriter(bypassingStructuralHold: bypassingStructuralHold)
        // M5: the await above can span a lifecycle arming, a mode change, a zoom or a project switch.
        guard guardsHold() else {
            DebugLog.log(.lifecycle, "[MdWrite] writeNow: a guard failed after waiting for the write in flight; nothing written")
            // R2: the debounce was cancelled above and nothing else will save the text typed since; every gate runs again.
            refire()
            return .abandoned
        }
        guard let database = editorState.projectDatabase, let projectId = editorState.currentProjectId else {
            return .fallBackToDirectWrite
        }
        let text = overrideContent ?? editorState.switchInProgressContent ?? editorState.content
        guard !text.isEmpty else { return .fallBackToDirectWrite }
        guard let service = editorState.blockSyncService else {
            DebugLog.log(.lifecycle, "[MdWrite] writeNow: no block-sync service: today's whole-document write")
            return .fallBackToDirectWrite
        }

        let disposition = prepare(Context(
            trigger: .writeNow, text: text, database: database, projectId: projectId, service: service, refire: refire))
        switch disposition {
        case .started:
            // `prepare` published its apply as `inFlight` in the same synchronous step, so a woken debounce fire waits for it.
            let token = inFlightToken
            if let own = inFlight {
                await own.value
            }
            if let applied = lastApply, applied.token == token, applied.landed { return .proceeded }
            return fallBackOrAbandon(guardsHold: guardsHold, refire: refire)
        case .nothingToWrite, .stayedRows, .skippedOpenFence:
            return .proceeded
        case .guardTripped, .noWriter, .refused, .unreadable:
            // Nothing was reserved or written, and every guard held in this same main-actor turn (`prepare` is synchronous).
            return .fallBackToDirectWrite
        case .heldForStructuralWork:
            // Not reachable: only a debounce fire is held, and the loop above ended with the hold down in this same turn.
            refire()
            return .abandoned
        }
    }

    /// The write did not land (judge R1): the direct write if the guards still hold, otherwise nothing and a re-armed debounce.
    private func fallBackOrAbandon(guardsHold: @MainActor () -> Bool, refire: @MainActor () -> Void) -> WriteNowOutcome {
        guard guardsHold() else {
            DebugLog.log(.lifecycle, "[MdWrite] writeNow: the write did not land and a guard failed since; nothing written, re-arming")
            refire()
            return .abandoned
        }
        DebugLog.log(.lifecycle, "[MdWrite] writeNow: the write did not land; falling back to the whole-document write")
        return .fallBackToDirectWrite
    }
}

// MARK: - A write started outside `prepare` (Phase 5 job A8)

extension MarkdownBlockWriter {
    /// Publishes `task` (the queued zoomed range write) as the write in flight, so a fire and `writeNow` wait for it; returns its token.
    func publishInFlight(_ task: Task<Void, Never>) -> Int {
        inFlightToken += 1
        inFlight = task
        return inFlightToken
    }
    /// The published write has ended: `inFlight` is cleared unless a later write replaced it.
    func clearInFlight(token: Int) { if inFlightToken == token { inFlight = nil } }
}

// MARK: - The synchronous core

extension MarkdownBlockWriter {

    /// Internal (not fileprivate) so MarkdownBlockWriter+StructuralHold.swift can start the two bypass triggers through `prepare`.
    enum Trigger {
        case debounceFire
        case writeNow
        /// t-4a8fd8af: the structural click's typing batch (the text up to the click). Ignores the hold; never a whole-document write.
        case structuralClick
        /// t-4a8fd8af: step 8's post-apply flush of the live text. Ignores the hold; never a whole-document write.
        case structuralFlush
    }

    struct Context {
        let trigger: Trigger
        let text: String
        let database: ProjectDatabase
        let projectId: String
        let service: BlockSyncService
        let refire: @MainActor () -> Void
    }

    fileprivate enum Mode {
        case rows
        case text(TextBaseline)

        var label: String {
            switch self {
            case .rows: return "rows"
            case .text: return "text"
            }
        }
    }

    /// The outcome of the compare half of one step (parse, alignment, diff): everything the reservation and the completion need.
    fileprivate struct Prepared {
        let context: Context
        let mode: Mode
        let epoch: Int64
        let endsOpen: Bool
        let result: MarkdownBlockDiff.Result
        var line: TimingLine
    }

    func prepare(_ context: Context) -> Disposition {
        // Round M2 measurement: every caller reaches the parse and diff through here; the span names its trigger (the `[MdWrite]` line
        // this call may write later is matched to it, in order, by the UI test's report). Synchronous: the whole span is main-thread work.
        let prepareSpan = MdSpeed.span("writer.prepare.\(context.trigger)")
        defer { prepareSpan.end() }
        let clock = ContinuousClock()
        let start = clock.now

        // t-4a8fd8af: a debounce fire never reserves a diff while a structural command is unapplied (plan B4); it keeps its
        // `refire` and the release runs it. `writeNow` waited for the hold before it got here; the structural triggers bypass it.
        if context.trigger == .debounceFire, isHeldForStructuralWork {
            holdFire(context.refire)
            return .heldForStructuralWork
        }

        guard let writer = context.service.writer else {
            DebugLog.log(.lifecycle, "[MdWrite] no writer: today's whole-document write")
            return .noWriter
        }
        guard writer.database === context.database, writer.projectId == context.projectId else {
            DebugLog.log(.lifecycle, "[MdWrite] refused: the writer belongs to another database or project")
            return failBeforeReservation(.refused(.identityMismatch), context)
        }
        guard let (mode, epoch) = resolveMode(context) else {
            return failBeforeReservation(.refused(.epochUnavailable), context)
        }

        // The parse memo (t-2fbe4c9b): the settings and the Notes title are read ONCE, here, and the key is built from them; on a hit the
        // memo's blocks and fence answer stand in for the parse and the new-text fence scan below.
        let lookupSpan = MdSpeed.span("parseCache.lookup")
        let notesTitle = try? context.database.fetchNotesHeadingTitle(projectId: context.projectId)
        let names = BlockParser.bibliographyNames(from: ExportSettings.load())
        let key = MarkdownParseCache.Key(
            text: context.text, projectId: context.projectId, notesTitle: notesTitle,
            bibliographyHeaderName: names.headerName, graceNames: names.graceNames)
        let cached = parseCache.lookup(key)
        lookupSpan.end()

        var line = TimingLine(mode: mode.label, cache: cached == nil ? "miss" : "hit")
        var rows: [Block]?
        let fence = checkOpenFence(context, mode: mode, cachedEndsOpen: cached?.endsOpen, line: &line, rows: &rows)
        if let stop = fence.stop { return stop }

        let parsed: [Block]
        if let cached {
            parsed = cached.blocks
        } else {
            let parseStart = clock.now
            parsed = BlockParser.parse(
                markdown: key.text, projectId: context.projectId, bibliographyHeaderName: names.headerName,
                graceNames: names.graceNames, notesHeaderName: notesTitle)
            line.parse = clock.now - parseStart
            parseCache.store(key, blocks: parsed, endsOpen: fence.endsOpen)   // trigger (iv): the next step on this text hits
        }
        line.blocks = parsed.count
        line.chars = key.text.utf8.count

        guard let result = diffAgainstBaseline(context, mode: mode, parsed: parsed, line: &line, rows: &rows) else {
            return failBeforeReservation(.unreadable, context)
        }
        line.filtered = result.filtered.total
        line.counts = Self.counts(of: result.changes)
        let prepared = Prepared(
            context: context, mode: mode, epoch: epoch, endsOpen: fence.endsOpen, result: result, line: line)
        if result.isEmpty {
            return finishWithoutWrite(prepared, mainThread: clock.now - start)
        }
        return reserveAndStart(prepared, clock: clock, start: start)
    }

    /// Picks the baseline this fire compares against, and reads the project's write epoch (one primary-key read).
    /// `.text` falls back to `.rows` (and stays there) when the project differs, the epoch moved (a direct whole-document
    /// write, `configure`, `ensureWriter` or a project switch bumped it) or a deferred epoch bump is still pending.
    fileprivate func resolveMode(_ context: Context) -> (Mode, Int64)? {
        let epoch: Int64
        do {
            epoch = try context.database.currentBlockWriteEpoch(projectId: context.projectId)
        } catch {
            DebugLog.alwaysPersisted("[MdWrite] could not read blockWriteEpoch (\(error)); nothing written, rows mode, retrying")
            return nil
        }
        guard case .text(let stored) = baseline else { return (.rows, epoch) }
        if stored.projectId != context.projectId || stored.epoch != epoch || context.service.needsEpochBump {
            DebugLog.log(
                .lifecycle,
                "[MdWrite] text baseline no longer valid (project or write epoch changed); re-aligning against the rows")
            baseline = .rows
            return (.rows, epoch)
        }
        return (.text(stored), epoch)
    }

    fileprivate func fetchRows(_ context: Context, line: inout TimingLine) -> [Block]? {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let rows = try context.database.fetchBlocks(projectId: context.projectId)
            line.align += clock.now - start
            return rows
        } catch {
            DebugLog.alwaysPersisted("[MdWrite] could not read the stored rows (\(error)); nothing written, rows mode, retrying")
            return nil
        }
    }

    /// The open-fence guard. A splitter-only pass over the new text; the baseline side is stored in `.text` mode and
    /// computed from the assembled rows in `.rows` mode (only when the new text ends open, which is rare). `stop` is
    /// the disposition to return when the guard tripped (or the rows could not be read).
    fileprivate func checkOpenFence(
        _ context: Context, mode: Mode, cachedEndsOpen: Bool?, line: inout TimingLine, rows: inout [Block]?
    ) -> (endsOpen: Bool, stop: Disposition?) {
        let clock = ContinuousClock()
        let guardStart = clock.now
        let newEndsOpen = cachedEndsOpen ?? BlockParser.endsInsideOpenFenceOrMath(context.text)   // the memo's answer on a hit
        line.guardPass = clock.now - guardStart
        guard newEndsOpen else { return (false, nil) }

        let baselineEndsOpen: Bool
        switch mode {
        case .text(let stored):
            baselineEndsOpen = stored.endsOpen
        case .rows:
            guard let fetched = fetchRows(context, line: &line) else {
                return (newEndsOpen, failBeforeReservation(.unreadable, context))
            }
            rows = fetched
            let assembleStart = clock.now
            baselineEndsOpen = BlockParser.endsInsideOpenFenceOrMath(BlockParser.assembleMarkdown(from: fetched))
            line.guardPass += clock.now - assembleStart
        }
        guard !baselineEndsOpen else { return (newEndsOpen, nil) }
        switch context.trigger {
        case .debounceFire, .structuralClick, .structuralFlush:
            // The two structural triggers reserve nothing here either (A17): the post-apply save writes the typing.
            DebugLog.log(.lifecycle, "[MdWrite] skipped: text ends inside an open code fence or $$ block")
            return (newEndsOpen, .skippedOpenFence)
        case .writeNow:
            DebugLog.log(
                .lifecycle,
                "[MdWrite] writeNow: text ends inside an open code fence or $$ block; falling back to today's whole-document write")
            return (newEndsOpen, .guardTripped)
        }
    }

    /// `.text`: the diff against the stored entries, no database read. `.rows`: read the rows (unless the guard already did),
    /// build the baseline entries (`align=`), then the diff (`diff=`). Nil when the rows could not be read.
    fileprivate func diffAgainstBaseline(
        _ context: Context, mode: Mode, parsed: [Block], line: inout TimingLine, rows: inout [Block]?
    ) -> MarkdownBlockDiff.Result? {
        let clock = ContinuousClock()
        let entries: [MarkdownBlockDiff.Entry]
        switch mode {
        case .text(let stored):
            entries = stored.entries
        case .rows:
            if rows == nil {
                guard let fetched = fetchRows(context, line: &line) else { return nil }
                rows = fetched
            }
            let alignStart = clock.now
            entries = MarkdownBlockDiff.baselineEntries(rows: rows ?? [])
            line.align += clock.now - alignStart
        }
        let diffStart = clock.now
        let result = MarkdownBlockDiff.diff(
            baseline: entries, new: parsed, remembered: removedHeadings.items(for: context.projectId), makeTempId: tempIdSource)
        line.diff = clock.now - diffStart
        return result
    }

    /// An empty diff. Truly empty: the text is what is stored, so the baseline advances to `.text`. Empty only because the
    /// pre-filter dropped everything (C4): the baseline stays `.rows` and nothing is scheduled.
    fileprivate func finishWithoutWrite(_ prepared: Prepared, mainThread: Duration) -> Disposition {
        let disposition: Disposition
        var line = prepared.line
        if prepared.result.emptyOnlyBecauseFiltered {
            baseline = .rows
            disposition = .stayedRows
            line.outcome = "filtered-only"
        } else {
            baseline = .text(TextBaseline(
                entries: prepared.result.entries, epoch: prepared.epoch, projectId: prepared.context.projectId,
                endsOpen: prepared.endsOpen))
            disposition = .nothingToWrite
            line.outcome = "unchanged"
        }
        line.mainThread = mainThread
        emit(line)
        return disposition
    }

    /// C1: reserve in THIS main-actor turn, before any Task exists; then start the apply as `inFlight`.
    fileprivate func reserveAndStart(
        _ prepared: Prepared, clock: ContinuousClock, start: ContinuousClock.Instant
    ) -> Disposition {
        let context = prepared.context
        let turn: MarkdownTurn
        switch context.service.reserveMarkdownTurn(database: context.database, projectId: context.projectId) {
        case .refused(.noWriter):
            return .noWriter
        case .refused(let refusal):
            return failBeforeReservation(.refused(refusal), context)
        case .reserved(let reserved):
            turn = reserved
        }

        inFlightToken += 1
        var line = prepared.line
        line.mainThread = clock.now - start
        let pending = PendingWrite(
            prepared: prepared, line: line, versionAtReservation: version, stampEpoch: turn.stamp.epoch, token: inFlightToken)
        let changes = prepared.result.changes
        #if DEBUG
        testChangesObserver?(changes)
        #endif
        let service = context.service
        inFlight = Task { [weak self] in
            let applyStart = ContinuousClock.now
            let outcome = await service.applyMarkdownTurn(turn, changes)
            self?.complete(pending, outcome: outcome, apply: ContinuousClock.now - applyStart)
        }
        return .started
    }

    /// A failure before any turn was reserved: rows mode, and one normal retry through the debounce.
    fileprivate func failBeforeReservation(_ disposition: Disposition, _ context: Context) -> Disposition {
        baseline = .rows
        scheduleRetryAfterFailure(context.refire, reason: "\(disposition)")
        return disposition
    }

    fileprivate static func counts(of changes: BlockChanges) -> String {
        "\(changes.updates.count)/\(changes.inserts.count)/\(changes.deletes.count)"
    }
}

// MARK: - Completion

extension MarkdownBlockWriter {

    /// Everything the completion of one write needs.
    fileprivate struct PendingWrite {
        let prepared: Prepared
        let line: TimingLine
        let versionAtReservation: Int
        let stampEpoch: Int64
        let token: Int
    }

    fileprivate enum Verdict {
        /// Applied and nothing was dropped: the baseline is the written parse.
        case cleanText([MarkdownBlockDiff.Entry])
        /// Applied, but the baseline must be the rows (the batch carried a pre-filtered change, or an id is unknown).
        case rowsAfterWrite(String)
        /// Nothing (or not everything) was written.
        case failure(String)
    }

    fileprivate func complete(_ write: PendingWrite, outcome: MarkdownBatchOutcome, apply: Duration) {
        if inFlightToken == write.token { inFlight = nil }
        var line = write.line
        line.apply = apply
        line.outcome = Self.label(of: outcome)
        emit(line)

        let context = write.prepared.context
        if case .applied(let applied) = outcome {
            updateRemovedHeadings(from: write.prepared.result, projectId: context.projectId, applied: applied)
        }
        // A set-point (a push, a reset, a direct write) that landed while this write was in flight has already put the
        // baseline back to `.rows`: a completion must not put older text over it.
        let ours = version == write.versionAtReservation
        let decision = verdict(for: outcome, prepared: write.prepared)
        var landed = true
        if case .failure = decision { landed = false }
        lastApply = (write.token, landed)
        switch decision {
        case .cleanText(let entries):
            consecutiveFailures = 0
            guard ours else { return }
            baseline = .text(TextBaseline(
                entries: entries, epoch: write.stampEpoch, projectId: context.projectId, endsOpen: write.prepared.endsOpen))
            version += 1
        case .rowsAfterWrite(let why):
            // Judge R7: a completion whose version moved on (a push, a reset or a direct write landed while it was in
            // flight) belongs to a session that already has its own baseline: it neither retries nor counts.
            guard ours else { return }
            DebugLog.log(.lifecycle, "[MdWrite] applied, baseline back to rows: \(why)")
            consecutiveFailures = 0
            baseline = .rows
            version += 1
            context.refire()
        case .failure(let why):
            guard ours else {
                DebugLog.log(.lifecycle, "[MdWrite] \(why); a push, reset or direct write came first: no retry, not counted")
                return
            }
            baseline = .rows
            version += 1
            scheduleRetryAfterFailure(context.refire, reason: why)
        }
    }

    fileprivate func verdict(for outcome: MarkdownBatchOutcome, prepared: Prepared) -> Verdict {
        switch outcome {
        case .applied(let applied):
            guard outcome.isClean else {
                return .failure(
                    "dropped updates=\(applied.droppedUpdateIds.count) deletes=\(applied.droppedDeleteIds.count) "
                    + "staleAnchorInserts=\(applied.rejectedStaleAnchorInserts.count)")
            }
            if prepared.result.baselineAfterWriteMustBeRows {
                return .rowsAfterWrite("the batch carried a pre-filtered or unaddressable change")
            }
            let entries = prepared.result.resolvingTempIds(applied.idMapping)
            if entries.contains(where: { $0.id == nil }) {
                return .rowsAfterWrite("an inserted block has no permanent id")
            }
            return .cleanText(entries)
        case .staleEpoch:
            return .failure("stale epoch")
        case .refused(let refusal):
            return .failure("refused (\(refusal))")
        case .skipped:
            return .failure("skipped")
        case .failed(let error):
            return .failure("failed (\(error))")
        }
    }

    /// One normal retry (the caller's `refire` schedules a debounce fire, so every gate runs again); a SECOND consecutive
    /// failure is logged to the persisted log and not retried again.
    fileprivate func scheduleRetryAfterFailure(_ refire: @MainActor () -> Void, reason: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            DebugLog.alwaysPersisted(
                "[MdWrite] \(consecutiveFailures) consecutive failures (\(reason)); not retrying until the next keystroke or a clean write")
            return
        }
        DebugLog.log(.lifecycle, "[MdWrite] \(reason); rows mode, retrying through a normal debounce fire")
        refire()
    }

    fileprivate static func label(of outcome: MarkdownBatchOutcome) -> String {
        switch outcome {
        case .applied: return outcome.isClean ? "applied" : "applied-with-drops"
        case .staleEpoch: return "stale-epoch"
        case .refused: return "refused"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }
}

// MARK: - The timing line

extension MarkdownBlockWriter {

    /// The fields of the ONE `[MdWrite]` line both arms log (the per-block path and `legacyWholeDocumentReparse`), so the
    /// e2e reads the same fields from either:
    /// `[MdWrite] mode=rows|text|legacy parse= align= guard= diff= mainThread= apply= u/i/d= filtered= blocks= chars= outcome= cache=hit|miss`
    /// (`cache=` is the parse memo's answer, t-2fbe4c9b; the legacy arm has none).
    ///
    /// `align` is the stored-row read plus the baseline keys (rows mode only); `diff` is the difference and the change list;
    /// `mainThread` is the whole synchronous step on the main actor; `apply` is the wait for the turn plus the write (the
    /// legacy arm: the `replaceBlocks`). `blocks` and `chars` are the document counts that belong beside every number: the
    /// parse's block count and the text's UTF-8 length.
    struct TimingLine {
        var mode: String
        var parse: Duration = .zero
        var align: Duration = .zero
        var guardPass: Duration = .zero
        var diff: Duration = .zero
        var mainThread: Duration = .zero
        var apply: Duration = .zero
        var counts = "0/0/0"
        var filtered = 0
        var blocks = 0
        var chars = 0
        var outcome = ""
        /// t-2fbe4c9b: "hit" when the parse memo supplied the blocks, "miss" when this step parsed. nil on the legacy arm (no memo).
        var cache: String?

        var text: String {
            "[MdWrite] mode=\(mode) parse=\(Self.format(parse)) align=\(Self.format(align)) guard=\(Self.format(guardPass)) "
                + "diff=\(Self.format(diff)) mainThread=\(Self.format(mainThread)) apply=\(Self.format(apply)) "
                + "u/i/d=\(counts) filtered=\(filtered) blocks=\(blocks) chars=\(chars) outcome=\(outcome)" + (cache.map { " cache=\($0)" } ?? "")
        }

        static func format(_ duration: Duration) -> String {
            let parts = duration.components
            let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            return String(format: "%.1fms", milliseconds)
        }
    }

    /// Logs `line` at `.lifecycle` and remembers it (`lastTimingLine`). Internal: the legacy arm
    /// (`legacyWholeDocumentReparse`) logs through it too.
    func emit(_ line: TimingLine) {
        lastTimingLine = line.text
        DebugLog.log(.lifecycle, line.text)
    }
}
