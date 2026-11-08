//
//  BibliographySyncService.swift
//  final final
//
//  Service for auto-updating bibliography sections based on citations in the document.
//  Uses state machine to prevent race conditions during sync operations.
//

import Foundation
import GRDB

/// State machine for bibliography sync to prevent race conditions
enum BibliographySyncState: Sendable {
    case idle
    case syncing
    case userEditPending
}

/// Snapshot captured when a debounced bibliography update is scheduled but not yet consumed.
/// The `generation` always travels with the rest of the snapshot — see `flushPendingSync()`
/// for why it must be the one captured at schedule time, not a freshly-read `syncGeneration`.
private struct PendingBibliographyUpdate {
    let citekeys: [String]
    let projectId: String
    let generation: Int
}

/// t-94369a83 Phase 3a-1b (C3b): the last `checkAndUpdateBibliography` request recorded while the service was
/// suspended for a close/switch/quit, replayed by `resumeAfterLifecycle()`. Doubles as the "dirty" flag.
private struct DeferredBibliographyCheck {
    let citekeys: [String]
    let projectId: String
}

@MainActor
@Observable
final class BibliographySyncService {
    // MARK: - State

    /// Current sync state
    private(set) var state: BibliographySyncState = .idle

    /// Last known citekeys (to prevent unnecessary regeneration)
    private var lastKnownCitekeys: Set<String> = []

    /// Hash of last generated bibliography content
    private var lastGeneratedHash: Int = 0

    /// Debounce timer for bibliography updates
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval (1 second for bibliography, longer than section sync's 500ms). A UI test can stretch it
    /// (`TestMode.uiTestingRewriteDelaySeconds`, inert unless `FF_UI_TESTING=1` and the variable are both set).
    private let debounceInterval: TimeInterval = TestMode.uiTestingRewriteDelaySeconds ?? 1.0

    /// Monotonic counter bumped by every scheduled debounce and by `regenerateBibliography`'s
    /// immediate write. A debounced rebuild captures this at schedule time; if a newer
    /// schedule or an immediate regeneration has bumped it since, the older debounced
    /// rebuild is stale and must not run.
    private var syncGeneration: Int = 0

    /// Snapshot captured at the moment a debounced update was scheduled but not yet
    /// consumed by `performBibliographyUpdate`. Cleared inside the debounce closure
    /// immediately before it fires, so `pendingUpdate != nil` reliably means "there is
    /// unconsumed scheduled work" — see `flushPendingSync()`.
    private var pendingUpdate: PendingBibliographyUpdate?

    /// t-94369a83 Phase 3a-1b (C3b, plan section 4.2 step 0): true from `suspendForLifecycle()` to
    /// `resumeAfterLifecycle()` (or `reset()`). While set, `checkAndUpdateBibliography` records its request
    /// in `deferredCheck` and returns, so nothing new is scheduled behind the close/switch/quit save.
    @ObservationIgnored private var isSuspendedForLifecycle = false

    /// The request to replay on resume: the last check made while suspended, or the update that was pending
    /// at suspend (C23).
    @ObservationIgnored private var deferredCheck: DeferredBibliographyCheck?

    // MARK: - Configuration

    /// Whether auto-update is enabled (false if user has manually edited)
    var isAutoUpdateEnabled: Bool = true

    // MARK: - Dependencies

    weak var database: ProjectDatabase?

    /// Phase 2 (t-94369a83), §2.0: the typed handle to `BlockSyncService`'s ordered
    /// write queue. Wired in `ContentView+ProjectLifecycle.swift`'s
    /// `configureSyncServices`. `nil` (never configured, or `BlockSyncService`
    /// deallocated) degrades every write below to the pre-Phase-2 direct-write
    /// fallback (§2.0's `.noWriter` fallback).
    var systemWriter: SystemWriter?

    /// Phase 2 (t-94369a83), §2.1: retry bookkeeping for a system write that came back
    /// with any outcome other than `.applied`/`.refused(.identityMismatch/
    /// .writerRetired/.notWanted)` -- keyed by the exact (deduplicated) citekey set so
    /// a retry counter never leaks across an unrelated later edit that happens to
    /// produce a different set.
    private var bibliographyRetryCounts: [Set<String>: Int] = [:]
    private static let maxBibliographyRetries = 3

    /// Review fix (F5, round 3): handle to the retry `Task` scheduled by
    /// `scheduleBibliographyRetryOrGiveUp` below -- cancelled by `reset()` so a project
    /// switch landing inside the retry's ~2s deferral window can never let a stale
    /// retry fire against the NEW project's freshly-reset state. Belt-and-braces: the
    /// retry closure ALSO captures the database identity at schedule time and re-checks
    /// it before doing anything (see that function's own doc comment) -- either guard
    /// alone would close the hazard, but `reset()` runs synchronously on MainActor
    /// while the retry's own `Task` may be suspended mid-wait, so cancelling here is
    /// the more direct signal and the identity check is the defense-in-depth match to
    /// every other `stillWanted`-style check in this file.
    private var pendingRetryTask: Task<Void, Never>?

    /// Hook invoked at the start of every bibliography update, BEFORE any bibliography row
    /// is written, so the block table reflects the live editor's current text.
    ///
    /// Wired unconditionally by ContentView (both editor modes) to a closure that writes the
    /// live Markdown text into the block table, but the closure itself gates on
    /// `editorMode == .source` and self-guards to a no-op in WYSIWYG, where
    /// `BlockSyncService`'s incremental poll already keeps the block table current.
    ///
    /// Phase 4a (t-94369a83): the write is the per-block Markdown write on the ordered queue
    /// (`MarkdownBlockWriter.writeNow`: only the blocks whose text differs from what is stored are
    /// sent, bibliography rows are never touched, and the user's text lands before this update's own
    /// rows). It falls back to today's wholesale `EditorViewState.flushContentToDatabase()` when
    /// the service has no writer, when the text ends inside an open code fence or `$$` block, and
    /// for the UI-test legacy flag (`FF_UI_TESTING_MD_LEGACY_REPARSE`).
    ///
    /// Exists because in Source Mode the ONLY writer of live editor text into the block
    /// table is a 1s-debounced re-parse whose fire-time guard silently drops the write --
    /// and this update is about to make that guard false. `BlockSyncService.flushForDatabaseRebuild()`,
    /// which the bibliography rebuild relies on for the same purpose, is inert in Source Mode
    /// (its WebView is only ever assigned to the Milkdown editor).
    ///
    /// Same targeted per-consumer-flush pattern already shipped for export
    /// (`DocumentManager.flushBeforeExport`) and snapshot/auto-backup
    /// (`EditorViewState.flushLiveContentToDatabase`).
    ///
    /// The closure receives the projectId this bibliography update was scheduled for
    /// (captured at schedule time) and must verify it still matches the live editor's
    /// current project before flushing -- protects against a project switch landing
    /// between scheduling and this update actually running. Bails (no-ops) on mismatch.
    ///
    /// The second parameter, `overrideContent`, is threaded straight through from
    /// `performBibliographyUpdate`'s own `overrideContent` parameter -- see that
    /// function's doc comment for why a project-switch caller must pass a non-nil value
    /// here rather than let the closure fall back to reading `editorState.content`
    /// itself (review round 1 must-fix: the bibliography-flush clobber).
    var flushLiveEditorContentToBlocks: ((_ scheduledForProjectId: String, _ overrideContent: String?) async -> Void)?

    // MARK: - Public Methods

    // Citekey extraction (citationSpanPattern, citationKeyPattern, extractCitekeys) lives in
    // BibliographySyncService+CitationExtraction.swift — a distinct, self-contained concern
    // from this class's sync state machine, and split out to keep type_body_length in range.

    /// Configure the service with a database
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
    }

    /// Called after SectionSyncService completes a sync
    /// Checks if bibliography needs updating based on current document citekeys
    func checkAndUpdateBibliography(
        currentCitekeys: [String],
        projectId: String
    ) {
        // Skip if auto-update is disabled
        guard isAutoUpdateEnabled else { return }

        // Phase 3a-1b (C3b): suspended for a lifecycle -- record "dirty" with the request and return.
        guard !isSuspendedForLifecycle else {
            deferredCheck = DeferredBibliographyCheck(citekeys: currentCitekeys, projectId: projectId)
            return
        }

        // Skip if currently syncing
        guard state == .idle else { return }

        // Check if citekeys have changed
        // Allow transition-to-empty so bibliography can be removed when all citations are deleted
        let currentSet = Set(currentCitekeys)
        let isTransitioningToEmpty = currentSet.isEmpty && !lastKnownCitekeys.isEmpty
        guard currentSet != lastKnownCitekeys || isTransitioningToEmpty else { return }

        // Debounce the update
        syncGeneration += 1
        let scheduledGeneration = syncGeneration
        pendingUpdate = PendingBibliographyUpdate(
            citekeys: currentCitekeys, projectId: projectId, generation: scheduledGeneration
        )
        debounceTask?.cancel()
        // Read here, outside the `[weak self]` closure: inside it `self` is optional (so `self.debounceInterval`
        // does not compile) and the implicit-self read it replaces is an error in the Swift 6 language mode.
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }

            // Wait for debounce interval (derived from property to prevent drift)
            try? await Task.sleep(for: .seconds(interval))

            guard !Task.isCancelled else { return }
            self?.pendingUpdate = nil
            await self?.performBibliographyUpdate(
                citekeys: currentCitekeys, projectId: projectId, scheduledGeneration: scheduledGeneration
            )
        }
    }

    /// Force any already-scheduled (but not yet fired) debounced bibliography update to
    /// run immediately. Used on quit/project-close so the derived Bibliography section
    /// isn't left stale behind the 1s debounce.
    ///
    /// If a natural debounce fire is already in flight (`state == .syncing`), waits for it
    /// to finish rather than starting a second, overlapping update. After the wait (or
    /// immediately, if nothing was in flight), re-checks for pending work rather than
    /// unconditionally returning: a new update can become pending in the moments between
    /// the in-flight run finishing and this method's poll loop waking up, and that update
    /// must still be picked up rather than silently dropped right before the process quits.
    ///
    /// Replays using the STORED generation captured at schedule time, not a freshly-read
    /// `syncGeneration` — this is what lets `performBibliographyUpdate`'s existing
    /// `scheduledGeneration == syncGeneration` guard correctly reject a snapshot that a
    /// newer `checkAndUpdateBibliography` call or `regenerateBibliography` has since superseded.
    ///
    /// `overrideContent` (default `nil`, preserving prior behavior for every existing
    /// caller) is forwarded verbatim to `performBibliographyUpdate` -- see its doc comment.
    /// No production caller passes a non-nil value since 3a-1b: the old `ContentView.handleProjectOpened()` did,
    /// via `EditorViewState.flushPendingBibliographyAndFootnoteSync(overrideContent:)`, and the lifecycle's save
    /// sequence (`EditorViewState.runLifecycleFlush`) replaced it.
    func flushPendingSync(overrideContent: String? = nil) async {
        if state == .syncing {
            let deadline = Date().addingTimeInterval(2.0)
            while state == .syncing, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard state == .idle, let pending = pendingUpdate else { return }

        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        await performBibliographyUpdate(
            citekeys: pending.citekeys, projectId: pending.projectId, scheduledGeneration: pending.generation,
            overrideContent: overrideContent
        )
    }

    /// Phase 3a-1b (t-94369a83, C3b), plan section 4.2 step 0 (review rows C6, C23): a close, project switch
    /// or quit holds the editor, so this service stops scheduling. Cancels the debounce, clears
    /// `pendingUpdate`, bumps `syncGeneration` (an OLDER run's write is then refused by its own generation
    /// check in `performBibliographyUpdate` and by `stillWanted` at its turn), and makes
    /// `checkAndUpdateBibliography` record its request instead of scheduling. An update that was PENDING is
    /// kept as the request to replay (C23). `resyncNow` (step 7's refresh) is NOT gated: it is the
    /// lifecycle's own write.
    func suspendForLifecycle() {
        debounceTask?.cancel()
        debounceTask = nil
        if let pending = pendingUpdate, deferredCheck == nil {
            deferredCheck = DeferredBibliographyCheck(citekeys: pending.citekeys, projectId: pending.projectId)
        }
        pendingUpdate = nil
        syncGeneration += 1
        isSuspendedForLifecycle = true
    }

    /// Phase 3a-1b (C3b): the lifecycle was cancelled. Clears the suspension and re-runs ONE check for the
    /// request recorded while suspended (or pending at suspend), if there is one. A completed close/switch
    /// never calls this: its tail's `reset()` clears the suspension.
    func resumeAfterLifecycle() {
        isSuspendedForLifecycle = false
        guard let check = deferredCheck else { return }
        deferredCheck = nil
        checkAndUpdateBibliography(currentCitekeys: check.citekeys, projectId: check.projectId)
    }

    /// Phase 2 (t-94369a83), §2.5: forces the write to run directly, right now, bypassing
    /// the debounce and any `pendingUpdate` entirely -- used by an audited structural
    /// operation (`StructuralUndoController.forceResyncDerivedContent`) that needs the
    /// write to complete INSIDE its own `isPerforming` window, not on a later debounce
    /// fire outside it.
    ///
    /// Waits out any already-in-flight run first, the same bound `flushPendingSync`
    /// above uses. JUDGMENT CALL (see this dispatch's report): §2.0 describes a
    /// `currentRun: Task<Void, Never>?` this would properly `await`, plus a
    /// `deferredCheck` slot to also bypass -- neither was built this round (a larger
    /// item spanning every write path, not just this one call site); this reuses the
    /// existing `state == .syncing` wait as the nearest equivalent instead.
    ///
    /// Review fix (finding #5): after the wait, this used to UNCONDITIONALLY cancel
    /// the debounce, clear `pendingUpdate`, and bump `syncGeneration` even if `state`
    /// was STILL `.syncing` -- discarding a pending debounced update with nothing
    /// replacing it, AND (via the generation bump) causing the still-in-flight run's
    /// own `stillWanted` check to fail, superseding ITS write too. Net effect: both the
    /// in-flight run and the pending debounced update could silently vanish with no
    /// write landing at all. Mirrors `flushPendingSync`'s own correct pattern instead:
    /// touch `debounceTask`/`pendingUpdate`/`syncGeneration` only once `state ==
    /// .idle`. If it's still `.syncing` after the wait, this simply cannot force a
    /// resync without corrupting the in-flight run's own result -- log it and return
    /// rather than forcing state out from under it.
    ///
    /// Review fix (finding #8): `checkAndUpdateBibliography` refuses to run at all
    /// once the user has manually edited the bibliography (`isAutoUpdateEnabled ==
    /// false`, set by `markAsManuallyEdited()`), but this function called
    /// `performBibliographyUpdate` directly, which has no such guard of its own --
    /// bypassing it and overwriting the user's manual edit. Same guard, same place a
    /// caller would expect it.
    ///
    /// Slice 2b (plan-v2-addendum 4.2): `stillWanted`, when given, is asked after the idle wait (nothing is touched when it says no) and
    /// is part of the write's own `stillWanted` at its reservation, so a delete's settle that a quick undo has superseded writes nothing.
    func resyncNow(citekeys: [String], projectId: String, stillWanted: (() -> Bool)? = nil) async {
        guard isAutoUpdateEnabled else {
            DebugLog.log(.bib, "[BibliographySyncService] resyncNow: skipped -- auto-update is disabled " +
                "(user has manually edited the bibliography)")
            return
        }
        if state == .syncing {
            let deadline = Date().addingTimeInterval(2.0)
            while state == .syncing, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard stillWanted?() ?? true else { DebugLog.log(.undo, "[BibliographySyncService] resyncNow: superseded by a quick undo"); return }
        guard state == .idle else {
            DebugLog.alwaysPersisted(
                "[BibliographySyncService] resyncNow: could not run -- a write was still in flight after the " +
                "2s wait; leaving it and any pending debounced update untouched rather than superseding them")
            return
        }
        cancelPendingDebounce()   // the same three lines as before (cancel the timer, drop the waiting update), in the extension below
        syncGeneration += 1
        await performBibliographyUpdate(citekeys: citekeys, projectId: projectId, scheduledGeneration: syncGeneration, stillWanted: stillWanted)
    }

    /// Regenerate bibliography (manual trigger)
    func regenerateBibliography(projectId: String, citekeys: [String]) async {
        isAutoUpdateEnabled = true
        debounceTask?.cancel()
        debounceTask = nil
        syncGeneration += 1        // supersede any debounced rebuild scheduled before now
        await performBibliographyUpdate(
            citekeys: citekeys, projectId: projectId, scheduledGeneration: syncGeneration
        )
    }

    /// Mark bibliography as manually edited (disables auto-update)
    func markAsManuallyEdited() {
        isAutoUpdateEnabled = false
    }

    /// Reset service state (call when switching projects)
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        lastKnownCitekeys = []
        lastGeneratedHash = 0
        isAutoUpdateEnabled = true
        state = .idle
        bibliographyRetryCounts.removeAll()
        // F5: cancel any retry still waiting out its ~2s deferral -- see
        // `pendingRetryTask`'s own doc comment for why this must happen here.
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        isSuspendedForLifecycle = false   // Phase 3a-1b (C3b): the next project's checks must schedule again
        deferredCheck = nil
    }

    // MARK: - Private Methods

    /// Internal (not private) so the race-condition guard can be unit-tested directly.
    ///
    /// `overrideContent` (default `nil`): forwarded verbatim as the second argument to
    /// `flushLiveEditorContentToBlocks` below. `nil` preserves the original behavior --
    /// the flush hook falls back to reading `editorState.content` directly, which is
    /// correct for every caller except a project switch in progress (see
    /// `EditorViewState.switchInProgressContent`'s doc comment for why `editorState.content`
    /// is deliberately stale during that specific window, and
    /// `flushPendingSync(overrideContent:)`'s doc comment for how a non-nil value reaches
    /// here).
    /// Phase 2 (t-94369a83), §2.1: the write itself now goes through
    /// `DocumentWriter`'s ordered system-write queue (`systemWriter`) instead of
    /// writing directly. Dedup state (`lastKnownCitekeys`/`lastGeneratedHash`) commits
    /// ONLY on `.applied` (or the `.noWriter` direct-write fallback's own success) --
    /// never before the write, so a superseded/refused/failed attempt leaves the dedup
    /// gate exactly where it was, letting a retry (or a later natural edit reproducing
    /// the same citekeys) see the change as still-pending rather than already-applied.
    func performBibliographyUpdate(
        citekeys: [String], projectId: String, scheduledGeneration: Int, overrideContent: String? = nil, stillWanted extra: (() -> Bool)? = nil
    ) async {
        // Deduplicate citekeys early - a citation may appear multiple times in document
        var seen = Set<String>()
        let uniqueCitekeys = citekeys.filter { seen.insert($0).inserted }

        guard let database else { return }

        // Execution-time mutual exclusion: a newer scheduled debounce or an immediate
        // `regenerateBibliography` call may have bumped syncGeneration since this update was
        // scheduled. A stale debounced rebuild must NOT run against its now-superseded
        // citekeys snapshot.
        guard !Task.isCancelled, scheduledGeneration == syncGeneration, state == .idle else { return }

        let zoteroService = ZoteroService.shared
        guard zoteroService.isConnected else { return }

        state = .syncing
        defer { state = .idle }

        #if DEBUG
        // Test-only hook, awaited right after `state` becomes `.syncing`, before
        // anything else in this run happens. Lets a test hold a run deterministically
        // "in flight" for exactly as long as it needs (e.g. to exercise `resyncNow`'s
        // own 2s-wait-then-give-up path) without relying on wall-clock timing or
        // blocking a real database writer lock from a background thread/Task --
        // `Thread.sleep` inside a `Task` risks starving Swift concurrency's
        // cooperative thread pool and delaying unrelated timers (including this
        // service's own debounce), which is exactly what made an earlier version of
        // that test flaky. No cost in
        // release builds.
        await testInFlightHook?()
        #endif

        // Flush the live editor's text into the block table before writing anything.
        // MUST run BEFORE both write branches below. Since Phase 4a the Source-Mode flush
        // normally sends only the blocks whose text differs from what is stored and never
        // touches bibliography rows, so running it afterwards could not clobber the fresh rows;
        // but its fallback (no writer, a text that ends inside an open code fence or `$$`
        // block, the legacy UI-test flag) is still a wholesale delete-and-reinsert of every
        // block parsed from the live editor content, which WOULD re-parse the editor's
        // now-stale bibliography text and clobber the fresh rows this update is about to write.
        // And the rebuild that follows reads the rows, so the user's text must be in them first.
        // Safe to place here: this function never reads block/body content itself -- it
        // derives the bibliography purely from the citekey snapshot -- and the markdown that
        // actually reaches the editor is assembled later, elsewhere (ContentView's
        // handleBibliographySectionChanged -> fetchBlocksWithIds), from a fresh block read.
        // Not logged here: the closure is always wired (both editor modes -- see the property's
        // doc comment above) and self-guards to a no-op in WYSIWYG, so a log statement at this
        // call site would fire unconditionally and misleadingly claim a flush happened even when
        // the closure's own guards skipped it. The actual flush is logged from inside the
        // closure itself (ContentView+ProjectLifecycle.swift), right before it calls
        // flushContentToDatabase() -- the one place that knows whether a flush is really occurring.
        if let flush = flushLiveEditorContentToBlocks {
            await flushLiveEditorContent(flush, projectId: projectId, overrideContent: overrideContent)
        }

        // The flush is the first suspension point since the staleness guard above. Re-check
        // that a manual regenerateBibliography() hasn't superseded this snapshot while it ran.
        guard scheduledGeneration == syncGeneration else { return }

        // Remove bibliography if no citations. `lastKnownCitekeys` is committed inside
        // `removeBibliographyBlock` itself now, only once its own write actually applies.
        guard !uniqueCitekeys.isEmpty else {
            await removeBibliographyBlock(projectId: projectId, scheduledGeneration: scheduledGeneration, stillWanted: extra)
            return
        }

        // Check for missing items and fetch them from Zotero
        let missingKeys = uniqueCitekeys.filter { !zoteroService.hasItem(citekey: $0) }
        if !missingKeys.isEmpty {
            do {
                _ = try await zoteroService.fetchItemsForCitekeys(missingKeys)
            } catch {
                DebugLog.log(.bib, "[BibliographySyncService] Failed to fetch items: \(error)")
            }
        }

        // Generate bibliography markdown (items now in cache)
        let bibliographyContent = generateBibliographyMarkdown(citekeys: uniqueCitekeys)

        // Check if content actually changed, against the last COMMITTED hash (only
        // updated on a successful write below -- see this function's own doc comment).
        let contentHash = bibliographyContent.hashValue
        guard contentHash != lastGeneratedHash else {
            // Review fix (finding #10): the RENDERED content can be unchanged even
            // when the CITEKEY SET changed (e.g. an unresolvable citekey that never
            // appears in the generated bibliography either way) -- `lastKnownCitekeys`
            // must still be committed here, or `checkAndUpdateBibliography`'s own
            // `currentSet != lastKnownCitekeys` guard sees a "change" on every future
            // check forever, rescheduling a full run (a Zotero fetch, and in Source
            // Mode a flush of the live editor text) every tick with nothing to
            // show for it. This IS a legitimate "handled" outcome, not a failure --
            // `lastGeneratedHash` is deliberately left as-is since the content itself
            // genuinely didn't change.
            lastKnownCitekeys = Set(uniqueCitekeys)
            return
        }

        guard let systemWriter else {
            // §2.0's `.noWriter` fallback -- no writer configured at all (should not
            // happen once `configureSyncServices` wires it; defensive only).
            await writeBibliographyDirectly(
                content: bibliographyContent, projectId: projectId, database: database,
                uniqueCitekeys: uniqueCitekeys, contentHash: contentHash
            )
            return
        }

        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let result = await systemWriter.perform(
            identity: identity, kind: .bibliographyUpdate,
            stillWanted: { [weak self] in
                guard let self else { return false }
                return scheduledGeneration == self.syncGeneration && self.database === identity.database && (extra?() ?? true)
            },
            body: { db in
                try BibliographySyncService.writeBibliographyRows(db: db, content: bibliographyContent, projectId: projectId)
            }
        )

        switch result.outcome {
        case .applied:
            lastKnownCitekeys = Set(uniqueCitekeys)
            lastGeneratedHash = contentHash
            bibliographyRetryCounts[Set(uniqueCitekeys)] = nil
            // Post notification directly - don't rely on ValueObservation
            // ValueObservation may be blocked by contentState guard during editing
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        case .refused(.identityMismatch), .refused(.writerRetired), .refused(.notWanted):
            break   // superseded or project changed -- nothing to do
        case .refused(.noWriter):
            await writeBibliographyDirectly(
                content: bibliographyContent, projectId: projectId, database: database,
                uniqueCitekeys: uniqueCitekeys, contentHash: contentHash
            )
        case .refused, .failed:
            scheduleBibliographyRetryOrGiveUp(citekeys: uniqueCitekeys, projectId: projectId)
        }
    }

    /// §2.0's `.noWriter` fallback: writes directly against the captured database,
    /// exactly as this method did before Phase 2. Commits dedup state itself since
    /// there is no writer-mediated `.applied` outcome to gate on here.
    private func writeBibliographyDirectly(
        content: String, projectId: String, database: ProjectDatabase,
        uniqueCitekeys: [String], contentHash: Int
    ) async {
        DebugLog.log(.sync, "[SystemWrite] no writer - direct write")
        do {
            _ = try database.write { db in
                try BibliographySyncService.writeBibliographyRows(db: db, content: content, projectId: projectId)
            }
            lastKnownCitekeys = Set(uniqueCitekeys)
            lastGeneratedHash = contentHash
            bibliographyRetryCounts[Set(uniqueCitekeys)] = nil
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        } catch {
            DebugLog.log(.bib, "[BibliographySyncService] Failed to update bibliography (direct write): \(error)")
        }
    }

    /// §2.1: "any other outcome" (a real refusal or a failed write) leaves dedup state
    /// untouched and schedules ONE retry, capped at `maxBibliographyRetries` per
    /// (deduplicated) citekey set.
    ///
    /// Review fix (finding #4): this is called from INSIDE `performBibliographyUpdate`,
    /// whose own `state = .syncing; defer { state = .idle }` has not unwound yet at
    /// this point in the call stack -- calling anything SYNCHRONOUSLY here would hit a
    /// `state == .idle` guard and silently no-op. A `Task` body never runs inline; it
    /// is scheduled onto MainActor's queue for a later turn, strictly after
    /// `performBibliographyUpdate` (this function's caller) returns and its own
    /// `defer` has already restored `state` to `.idle` -- so deferring the retry
    /// through a `Task` is enough to let it actually fire. The bounded wait below is a
    /// belt-and-braces safety net matching `flushPendingSync`/`resyncNow`'s own
    /// pattern, for the rare case something else legitimately starts a new sync in the
    /// interim.
    ///
    /// Review fix (F4, round 3): this used to re-enter through
    /// `checkAndUpdateBibliography(currentCitekeys:projectId:)`, which guards on
    /// `currentSet != lastKnownCitekeys` -- a check that exists to decide whether a
    /// NEW check is warranted at all, not whether a FAILED write should be retried.
    /// Since a failed write never commits `lastKnownCitekeys`, that guard is only
    /// false (blocking the retry) when the failed citekey set is UNCHANGED from what
    /// was already committed before the failed attempt -- exactly `regenerateBibliography`'s
    /// own manual re-trigger case (same citekeys, e.g. after Zotero metadata changed)
    /// and a `resyncNow`-triggered retry restoring the same citekey set after a
    /// structural undo. On those two paths the retry silently never ran at all, which
    /// was this task's own original bug, still present. Fixed by calling
    /// `performBibliographyUpdate` DIRECTLY here instead -- forcing the exact failed
    /// generation/content to actually re-run regardless of whether the citekey set
    /// changed -- rather than routing through a guard meant for a different purpose.
    /// `isAutoUpdateEnabled` is still respected (mirrors `resyncNow`'s own guard): a
    /// manual edit landing in the ~2s gap before the retry fires must not be silently
    /// overwritten by it.
    private func scheduleBibliographyRetryOrGiveUp(citekeys: [String], projectId: String) {
        let key = Set(citekeys)
        let attempt = (bibliographyRetryCounts[key] ?? 0) + 1
        if attempt <= Self.maxBibliographyRetries {
            bibliographyRetryCounts[key] = attempt
            // F5: captured at schedule time -- see `pendingRetryTask`'s own doc comment
            // for why both this identity check AND `reset()`'s cancel exist together.
            let scheduledDatabase = database
            pendingRetryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .syncing {
                    let deadline = Date().addingTimeInterval(2.0)
                    while self.state == .syncing, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                guard !Task.isCancelled,
                      self.state == .idle,
                      self.isAutoUpdateEnabled,
                      self.database === scheduledDatabase
                else { return }
                self.syncGeneration += 1
                self.debounceTask?.cancel()
                self.debounceTask = nil
                self.pendingUpdate = nil
                await self.performBibliographyUpdate(
                    citekeys: citekeys, projectId: projectId, scheduledGeneration: self.syncGeneration)
            }
        } else {
            DebugLog.alwaysPersisted(
                "[BibliographySyncService] giving up on bibliography update after \(attempt - 1) "
                + "retries for citekeys \(key)")
            bibliographyRetryCounts[key] = nil
        }
    }

    // Bibliography markdown/entry formatting (generateBibliographyMarkdown,
    // formatBibliographyEntry, formatAuthorList, formatAuthorName, formatTitle,
    // formatContainerParts, formatPublisher) lives in
    // BibliographySyncService+EntryFormatting.swift — a distinct, self-contained concern
    // from this class's sync state machine and block persistence, split out to keep
    // type_body_length in range.

    /// Phase 2 (t-94369a83), §2.1: removes bibliography blocks when all citations are
    /// deleted, routed through the same system-write queue as
    /// `performBibliographyUpdate` above -- same outcome handling, same `.noWriter`
    /// direct-write fallback, same retry-on-any-other-outcome rule (keyed by the empty
    /// citekey set, since a removal has none).
    private func removeBibliographyBlock(projectId: String, scheduledGeneration: Int, stillWanted extra: (() -> Bool)? = nil) async {
        guard let database else { return }

        guard let systemWriter else {
            await removeBibliographyDirectly(projectId: projectId, database: database)
            return
        }

        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let result = await systemWriter.perform(
            identity: identity, kind: .bibliographyRemoval,
            stillWanted: { [weak self] in
                guard let self else { return false }
                return scheduledGeneration == self.syncGeneration && self.database === identity.database && (extra?() ?? true)
            },
            body: { db in
                try BibliographySyncService.writeBibliographyRemoval(db: db, projectId: projectId)
            }
        )

        switch result.outcome {
        case .applied:
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
            lastGeneratedHash = 0
            lastKnownCitekeys = []
            bibliographyRetryCounts[[]] = nil
        case .refused(.identityMismatch), .refused(.writerRetired), .refused(.notWanted):
            break   // superseded or project changed -- nothing to do
        case .refused(.noWriter):
            await removeBibliographyDirectly(projectId: projectId, database: database)
        case .refused, .failed:
            scheduleBibliographyRetryOrGiveUp(citekeys: [], projectId: projectId)
        }
    }

    /// §2.0's `.noWriter` fallback for removal -- writes directly, exactly as this
    /// method did before Phase 2.
    private func removeBibliographyDirectly(projectId: String, database: ProjectDatabase) async {
        DebugLog.log(.sync, "[SystemWrite] no writer - direct write")
        do {
            _ = try database.write { db in
                try BibliographySyncService.writeBibliographyRemoval(db: db, projectId: projectId)
            }
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
            lastGeneratedHash = 0
            lastKnownCitekeys = []
        } catch {
            DebugLog.log(.bib, "[BibliographySyncService] Error removing bibliography (direct write): \(error)")
        }
    }

    #if DEBUG
    /// Test-only read of whether a debounced update is currently scheduled --
    /// review finding #4: lets a test deterministically poll for "the retry's own
    /// `checkAndUpdateBibliography()` call has actually scheduled pending work" rather
    /// than guessing at a wall-clock delay for the retry's `Task` to run.
    var testHasPendingUpdate: Bool { pendingUpdate != nil }

    /// Test-only hook -- see the call site inside `performBibliographyUpdate` for the
    /// full doc comment.
    var testInFlightHook: (() async -> Void)?
    #endif
}

/// Used by `BibliographySyncService+SystemWrite.swift`'s `writeBibliographyRows`
/// anchor-fallback chain (formerly `updateBibliographyBlock`'s own, moved there
/// verbatim by Phase 2, t-94369a83 §2.1) -- not `private` because that function lives
/// in a separate file (Swift's `private` is file-scoped).
extension Block {
    /// A "bare opening marker" block names no real bibliography content: it is either the
    /// unstripped marker literal on its own (a document parsed WITHOUT
    /// strippingBibliographyMarkerFromBlocks), or — on the legacy-load path, where the
    /// marker literal is stripped out of the stored fragment before classification — an
    /// EMPTY fragment on a block that is NOT `.heading`-typed (the only way an
    /// `isBibliography`-flagged, non-heading block can have empty content is if its entire
    /// original text WAS the marker, stripped away). Both shapes must be excluded from the
    /// anchor fallback, or a legacy-document orphan can still hijack regeneration.
    var isBareOpeningMarker: Bool {
        let trimmedFragment = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFragment == BlockParser.bibliographyStartMarker { return true }
        return trimmedFragment.isEmpty && blockType != .heading
    }
}

extension BibliographySyncService {
    /// Ends the update that is waiting for its debounce, if any (the three lines `resyncNow` runs), WITHOUT bumping `syncGeneration`.
    /// A quick undo of a section delete calls this in its first synchronous stretch (plan-v3 D1): what was waiting was computed from
    /// the post-delete document, and the restored text schedules its own. (An extension in this file: the fields are `private`.)
    func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
    }

    /// A quick undo's reinsert puts the pre-delete Bibliography rows back without telling this service, so `lastGeneratedHash` (the hash
    /// of the content the delete's resync committed) no longer describes the table. A redo that deletes the same section again generates
    /// the same content, `performBibliographyUpdate` sees `contentHash == lastGeneratedHash` and returns without writing: the
    /// Bibliography keeps the deleted chapter's entries for good. Called wherever the rows have just been put back (the same four points
    /// as `FootnoteSyncService.forgetCommittedNotesState`). Clears the hash and nothing else; the next write that applies commits it.
    func forgetCommittedBibliographyState() {
        lastGeneratedHash = 0
    }

    /// The editor's live flush (`flushLiveEditorContentToBlocks`) as one `bibliography.liveFlush` trace span (round M2 measurement: the
    /// span is silent unless tracing is on). Same actor, same single `await`, nothing added: the call used to sit in the update itself, and
    /// moved here, as three plain lines, because the class body is at SwiftLint's type-body-length cap.
    private func flushLiveEditorContent(
        _ flush: (_ scheduledForProjectId: String, _ overrideContent: String?) async -> Void, projectId: String, overrideContent: String?
    ) async {
        let liveFlushSpan = MdSpeed.span("bibliography.liveFlush")
        await flush(projectId, overrideContent)
        liveFlushSpan.end()
    }
}
