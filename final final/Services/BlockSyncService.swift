//
//  BlockSyncService.swift
//  final final
//
//  Unified sync service for block-based content model.
//  Polls the editor for block changes and applies them to the database.
//

import Foundation
import GRDB
import WebKit

/// Winner of `BlockSyncService.raceWithTimeout(seconds:work:)`.
private enum PollCycleRaceOutcome {
    case finished
    case failed(Error)
    /// The work task had not finished when the watchdog expired. Handed back so
    /// the caller can cancel() it — the unstructured race never awaits the
    /// loser, which is the whole point (a `withThrowingTaskGroup`'s exit would).
    case timedOut(orphan: Task<Void, Error>)
}

/// Per-cycle progress for the poll watchdog's orphan back-pressure (M3/A5). One
/// instance is created by `runPollCycle`, handed to the cycle's work task, and read
/// by the watchdog's `.timedOut` arm.
///
/// `hasFetchedBatch` records whether `getBlockChanges()` RETURNED — i.e. whether the
/// JS side has already cleared its queues for this batch (a consumed batch must be
/// written or lost). It is set in the same synchronous region as `logFetchedUpdates`,
/// immediately after the fetch guard in `doPollBlockChanges`.
///
/// `countedAsOrphan` and `workFinished` together make the outstanding-orphan count
/// exact. `runPollCycle` claims the orphan — incrementing the service's counter —
/// only if the work task has not already exited; the work task releases that claim in
/// its own `defer`. All three flags are read and written synchronously on MainActor,
/// so the claim and the release can never both happen or neither happen.
@MainActor
private final class CycleProgress {
    var hasFetchedBatch = false
    var countedAsOrphan = false
    var workFinished = false
}

/// Service to sync editor block changes with the database
/// Uses poll-based pattern (similar to existing content polling) for change detection
@MainActor
@Observable
class BlockSyncService {
    private var pollTimer: Timer?
    /// 2s polling (block changes accumulate in JS). Not `private`: `EditorViewState.
    /// ReconcileSuppression`'s TTL is derived from this (plus a margin) rather than
    /// duplicating the constant -- see that type's doc comment. `nonisolated` (judge-review
    /// should-fix): not a real race (immutable, Sendable, literal-initialized), but without
    /// it this is a new warning under Swift 6 mode that would become a hard error.
    nonisolated static let pollInterval: TimeInterval = 2.0
    private let pollInterval: TimeInterval = BlockSyncService.pollInterval

    /// Phase 5 job B2: the shadow-report comparison the poll's fetch feeds (`ReportIntake.shared` unless a test sets its own).
    @ObservationIgnored var reportIntakeOverride: ReportIntake?
    var reportIntake: ReportIntake { reportIntakeOverride ?? .shared }

    private(set) var projectDatabase: ProjectDatabase?
    private(set) var projectId: String?
    /// Internal (was private) only so the DEBUG accessors in `BlockSyncService+Lifecycle.swift` can reach it.
    weak var webView: WKWebView?

    /// t-94369a83 Phase 4b slice 2a (plan D1.2): true from the moment an editor-first section delete's click starts until the
    /// delete's job holds its place in the writer's queue. A ROUTINE poll (`force == false`) that reaches its reservation step
    /// while this is set returns before reserving or consuming anything; a forced poll (a rebuild's, a lifecycle's) ignores it.
    /// Written only by `StructuralUndoController`'s click path, which clears it in a `defer`. It does NOT touch
    /// `EditorViewState.contentState`: moving that would bump `contentGeneration` and discard a batch some routine cycle had
    /// already fetched (finding M1), which the reservation order alone protects instead.
    var structuralClickPending = false
    /// The JavaScript call `fetchContentFromWebView` makes. Rich Text: the editor's `getContent()`, as always (Milkdown has no
    /// `getContentRaw`, and when zoomed it serializes the zoom-notes marker itself). Markdown (CodeMirror): the page's `getContent()`
    /// strips EVERY hidden marker (`stripAnchors`, web/codemirror/src/anchor-plugin.ts; its regex has listed the end marker since
    /// 2026-08-09), and the text this returns is SAVED, so two of those markers must survive it:
    ///   - the bibliography END marker (`BlockParser.bibliographyEndMarker`): a document parsed without it stores its bibliography
    ///     heading and entries as ordinary blocks (`BibliographyOpeningSelector`, tier 2 needs the terminator), and the next
    ///     regeneration then adds a second bibliography;
    ///   - the zoom-notes marker `<!-- ::zoom-notes:: -->`: `LifecycleWholeDocumentWrite.prepare` splits a zoomed section's mini-Notes
    ///     off on exactly that marker (`SectionSyncService.stripZoomNotes`). Without it the trailing `# Notes` heading and the `[^n]:`
    ///     definitions are parsed as part of the zoomed section and written into the middle of the document when that section is not
    ///     the last (a second Notes heading, duplicate definitions), and an edit to a definition never reaches the real Notes.
    /// So on a page that offers `getContentRaw()` this strips only the section anchors and the bibliography START marker, which is
    /// the shape `editorState.content` has in Markdown mode (the page's own push, minus the anchors and the start marker; the zoomed
    /// text there carries the zoom-notes marker too). The final branch keeps the literal `getContent()` call that the unit-test
    /// harnesses (LifecycleFlushHarness, LifecycleTailHarness) answer by script text.
    ///
    /// Who can reach a Markdown page: only the lifecycle save sequence (close, quit, project switch), which hands
    /// `fetchContentFromWebView` the captured CodeMirror view explicitly (`EditorViewState.captureForLifecycle`). Export
    /// (`ContentView`'s `flushBeforeExport`), Save Version (`ContentView.handleSaveVersion`) and auto-backup
    /// (`AutoBackupService.createAutoBackup`) pass no view, so they ask this service's own `webView`, which `configure` sets from the
    /// Rich Text page only; in Markdown mode they get nil once that page is freed and flush the text on hand.
    nonisolated static let fetchContentScript = """
        (() => {
            const ff = window.FinalFinal;
            if (typeof ff.getContentRaw !== 'function') { return window.FinalFinal.getContent(); }
            return ff.getContentRaw().replace(/<!-- @sid:[0-9a-fA-F-]+ -->|<!-- ::auto-bibliography:: -->/g, '');
        })()
        """

    /// Fetch content from the active WebView with a timeout.
    /// Returns nil if WebView is unavailable, JS call fails, or timeout elapses.
    ///
    /// Races the JS call against `timeout` via the shared `raceAgainstTimeout(_:_:)`
    /// (TimeoutRace.swift) rather than a `withThrowingTaskGroup` — see that
    /// function's doc comment for why a task group's exit contract cannot bound a
    /// wedged `webView.evaluateJavaScript` call (t-027c3835,
    /// quitting-can-hang-if-the-editor-stops-responding: this was the root cause of
    /// quit, Save Version, idle auto-backup, and structural undo all being able to
    /// hang indefinitely against a stuck WebKit content process).
    ///
    /// `webView` (t-94369a83 Phase 3a-1b): fetches from THIS WebView instead of the service's own
    /// weak one. The lifecycle sequence captures the editor's WebView strongly at the start and
    /// hands it to every later step, so a view swap or teardown during the sequence cannot make
    /// the fetch silently ask a different (or no) view. Nil, the default, is today's behaviour.
    func fetchContentFromWebView(timeout: Duration = .seconds(2), webView explicitWebView: WKWebView? = nil) async -> String? {
        guard let webView = explicitWebView ?? self.webView else { return nil }
        let outcome = await raceAgainstTimeout(timeout) {
            (try? await self.evaluateJS(Self.fetchContentScript, in: webView)) as? String
        }
        switch outcome {
        case .finished(let value):
            // Native, contiguous UTF-8 once, where the text arrives: the web view's answer is a bridged `NSString`, on which every
            // later `count` / `index(offsetBy:)` (close-time section sync, `SectionSyncService.parseHeaders`) is about 40 times slower.
            return value?.contiguousUTF8Copy
        case .timedOut:
            DebugLog.log(.lifecycle, "[BlockSyncService] fetchContentFromWebView: timed out after \(timeout)")
            return nil
        }
    }

    /// The script the close/quit/switch step 1 asks the editor how many Cmd-Z / Cmd-Shift-Z presses it holds in its own queue (a press
    /// made while an earlier undo is in flight is held and only sent when that undo replies). Both editors answer it (the Markdown
    /// page since t-4a8fd8af); a page without the function (an older bundle) holds none.
    static let heldUndoPressCountScript =
        "(window.FinalFinal && typeof window.FinalFinal.heldUndoPressCount === 'function') ? window.FinalFinal.heldUndoPressCount() : 0"

    /// How many presses `webView`'s editor holds in its own undo queue right now (`window.FinalFinal.heldUndoPressCount`). 0 when the
    /// editor has no such function, answers something that is not a number, fails, or does not answer within `timeout`: a count that
    /// cannot be read is treated as "none held", which is today's behaviour (the close does not wait for presses it was not told of).
    ///
    /// The bound is five seconds (fix round 8, F4): JavaScript is single-threaded, so the call queues behind whatever the editor is
    /// still doing at the end of an undo (a long content push on a book takes hundreds of milliseconds to over a second), and a
    /// shorter bound would read that as "none held" and cancel the second Cmd-Z silently. A timeout is logged `alwaysPersisted`.
    func heldUndoPressCount(webView: WKWebView, timeout: Duration = .seconds(5)) async -> Int {
        let outcome = await raceAgainstTimeout(timeout) { () -> Int? in
            let raw = try? await self.evaluateJS(Self.heldUndoPressCountScript, in: webView)
            if let number = raw as? NSNumber { return number.intValue }
            return raw as? Int
        }
        switch outcome {
        case .finished(let value):
            return max(0, value ?? 0)
        case .timedOut:
            DebugLog.alwaysPersisted(
                "[BlockSyncService] heldUndoPressCount: the editor did not answer within \(timeout) -- treating as none held "
                    + "(a Cmd-Z it holds will be cancelled by the close)")
            return 0
        }
    }

    /// Whether the service is properly configured
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil && webView != nil
    }

    /// Reference to editor state for contentGeneration and contentState checks
    weak var editorState: EditorViewState?

    /// t-94369a83 Phase 1: the single ordered write queue. Owns the sequence space
    /// and the only temp->permanent block id map (DocumentWriter.swift replaces the
    /// old apply chain plus `pendingConfirmations`/`confirmedTempIds`). Ownership
    /// moves to `DocumentManager` in a later phase; for now `BlockSyncService` still
    /// owns it, same as it owned the apply chain before.
    ///
    /// Internal (was private) only so `BlockSyncService+Lifecycle.swift` can reach it; callers outside
    /// `BlockSyncService` still go through the service's own methods, never the writer directly.
    var writer: DocumentWriter?

    /// Whether a `checkForChanges` JS failure has already been logged since the last
    /// success (A8). Reset on the next successful call; without it the failure line
    /// fires every 2s against a broken/wedged WebView.
    private var hasLoggedCheckForChangesFailure = false

    // MARK: - Stale-snapshot guard helpers (pure, testable)

    /// Reason a poll result was hard-rejected as a stale snapshot.
    enum StaleRejectReason: Equatable {
        case allDeletedNoInserts    // all blocks would be deleted with no inserts
    }

    /// Decide whether a poll payload should be hard-rejected.
    /// Preserves the pre-existing tight "100% delete, no inserts" signature —
    /// a tight pattern that never arises from a legitimate user action.
    /// Pure, nonisolated, no effects.
    nonisolated static func shouldRejectAsStale(
        changes: BlockChanges,
        blockCount: Int
    ) -> StaleRejectReason? {
        let deleteCount = changes.deletes.count
        let insertCount = changes.inserts.count
        if blockCount > 2 && deleteCount == blockCount && insertCount == 0 {
            return .allDeletedNoInserts
        }
        return nil
    }

    /// Detect the "balanced massive churn" pattern — the observed signature of the
    /// figure-ID-theft bug: large, balanced insert/delete churn together with
    /// non-trivial updates on a document bigger than the threshold. Pure, nonisolated.
    /// WARNING-only signal — never reject a payload based on this alone. Legitimate
    /// bulk operations (paste-replace, find-and-replace with block-splitting, etc.)
    /// can approach this signature, and rejecting silently discards user work.
    nonisolated static func hasBalancedMassiveChurnSignature(
        changes: BlockChanges,
        blockCount: Int
    ) -> Bool {
        let deleteCount = changes.deletes.count
        let insertCount = changes.inserts.count
        let updateCount = changes.updates.count
        guard blockCount > 10 else { return false }
        guard deleteCount + insertCount > blockCount / 2 && updateCount > 5 else { return false }
        let churn = max(deleteCount, insertCount)
        let balanceDelta = abs(deleteCount - insertCount)
        return churn > 0 && balanceDelta <= churn / 4
    }

    /// True when this poll cycle must abandon its batch because content was wholesale
    /// replaced since the cycle began. Applies in force mode too: `force` bypasses the
    /// contentState *precondition*, NOT mid-flight invalidation — a snapshot taken before
    /// a replaceBlocks() is stale no matter who asked for it.
    ///
    /// `currentGeneration == nil` is ambiguous on its own — it can mean either "no
    /// `editorState` was ever wired" (some test harnesses, or timing before
    /// `onWebViewReady`) or "`editorState` WAS wired when this poll started but has since
    /// been deallocated mid-poll" (e.g. a project switch tearing down the view). Those two
    /// cases must be treated oppositely: the first is not staleness, so we proceed; the
    /// second is itself evidence of a wholesale teardown — a live `editorState` going away
    /// mid-flight is exactly the kind of change this guard exists to catch — so we abandon
    /// rather than silently write a stale batch against `database`/`projectId` locals that
    /// were captured before the switch. `wasWiredAtPollStart` disambiguates the two: it's
    /// whether `editorState` was non-nil at the moment `generationAtPollStart` was captured.
    nonisolated static func shouldAbandonForGenerationChange(
        currentGeneration: Int?,
        generationAtPollStart: Int,
        wasWiredAtPollStart: Bool
    ) -> Bool {
        guard let currentGeneration else {
            // Nil now: abandon only if editorState was actually torn down mid-poll
            // (wired at capture, gone now) — not if it was simply never wired at all.
            return wasWiredAtPollStart
        }
        return currentGeneration != generationAtPollStart
    }

    // MARK: - Public API

    /// Configure the service for a specific project. Called from a fresh WebView's
    /// `onWebViewReady`, before `startPolling()` is (re)invoked for it.
    ///
    /// Does NOT drain (unlike `reconfigure(database:projectId:)` below) -- not
    /// because no poll cycle can be in flight here (a WYSIWYG<->Source mode
    /// toggle destroys and recreates the WebView WITHOUT calling `stopPolling()`
    /// first, so this CAN in fact run while this same service instance's timer/
    /// poll from the OLD WebView is still live -- out of scope for this fix, see
    /// the block-sync-poll-races review), but because it is safe regardless:
    /// this reassigns `self.webView` to the fresh reference, and `doPollBlockChanges`
    /// captures `webView` into a local at the top of each cycle (before any
    /// `await`) -- so an old cycle already past that point holds its OWN local
    /// reference to the PREVIOUS WebView and runs to completion against it,
    /// unaffected by this reassignment.
    ///
    /// That old cycle's write does NOT land. The `bumpBlockWriteEpoch` call below
    /// advances the persisted epoch, so the batch the old cycle already fetched
    /// carries a stale epoch and is refused WHOLESALE (inserts included) by the
    /// epoch check inside the write transaction. Nothing the old editor typed is
    /// lost by that: the text it had already pushed to Swift survives because the
    /// mode-toggle paths call `flushContentToDatabase` first.
    ///
    /// The limit of that guarantee: a cycle reads the epoch only AFTER two pre-fetch
    /// awaits (`flushPendingJSChanges`, `checkForChanges`), against a
    /// `webView`/`database`/`projectId` snapshot taken BEFORE them. A WebView swap
    /// that lands inside that window is therefore caught by the content-generation
    /// guards (pre- and post-fetch), not by the epoch check alone.
    func configure(database: ProjectDatabase, projectId: String, webView: WKWebView) {
        // t-94369a83 Phase 1: same database and project -> skip everything this
        // writer has reserved so far (a fresh WebView cannot adopt an in-flight
        // turn from the old one); a different database/project -> retire the old
        // writer (skips its reserved turns AND drops every held op) and start a new
        // one, continuing its sequence space so stamps stay monotonic across the
        // replacement (see "Sequence continuity" in the plan).
        let sameProject = self.projectDatabase === database && self.projectId == projectId
        if sameProject, let writer {
            writer.skipAllReserved(reason: .editorReplaced)
        } else {
            let next = writer?.nextSequence ?? 1
            // Test-only knobs (DEBUG-gated on DocumentWriter; no production effect) are
            // per-INSTANCE, so replacing `writer` silently drops whatever a test wired
            // onto the old one — a test that sets `testWriterEventHandler` (etc.) before
            // triggering a writer replacement would otherwise see it go silently dark on
            // the new instance. Carried forward here, mirroring "Sequence continuity"
            // above for `nextSequence`.
            #if DEBUG
            let carriedEventHandler = writer?.testEventHandler
            let carriedLateAfter = writer?.testLateAfterSeconds
            let carriedDrainTimeout = writer?.testDrainTimeoutSeconds
            let carriedLateAbandonAfter = writer?.testLateAbandonAfterSeconds
            #endif
            writer?.retire(reason: .writerReplaced)
            writer = DocumentWriter(
                database: database, projectId: projectId, firstSequence: next, assertsMainActorCallers: true)
            #if DEBUG
            writer?.testEventHandler = carriedEventHandler
            writer?.testLateAfterSeconds = carriedLateAfter
            writer?.testDrainTimeoutSeconds = carriedDrainTimeout
            writer?.testLateAbandonAfterSeconds = carriedLateAbandonAfter
            #endif
        }
        self.projectDatabase = database
        self.projectId = projectId
        self.webView = webView
        // A fresh WebView means every batch still in flight from the OLD editor was fetched
        // against a coordinate space this new editor does not share. Bump the persisted
        // epoch so those batches are refused wholesale in the write transaction - the
        // durable replacement for the in-memory reset that used to sit here and could not
        // see a native rewrite at all. `needsEpochBump` is set on EVERY attempt (false on
        // success, true on failure) so a failed bump is retried by the next poll rather
        // than left failed open - see `needsEpochBump`.
        do {
            _ = try database.bumpBlockWriteEpoch(projectId: projectId)
            needsEpochBump = false
        } catch {
            needsEpochBump = true
            DebugLog.alwaysPersisted("[BlockSync] configure: could not bump blockWriteEpoch (\(error)) - the next poll will retry it")
        }
        // Same reasoning for the M3/A5 back-pressure: an orphan still parked in the
        // OLD WebView's `evaluateJavaScript` must not keep the NEW editor's unforced
        // polling paused. Its `defer` releases against a counter that no longer
        // includes it, which the saturating decrement there tolerates.
        self.outstandingPrefetchOrphans = 0
        // Addendum A1 (t-94369a83): a fresh WebView means any tolerance earned against
        // the OLD one, and any pending "already logged this pause" flag for it, no
        // longer describe anything relevant to the editor now being polled.
        self.orphansToleratedWhileResponsive = 0
        self.hasLoggedBackPressureSkip = false
        // A fresh WebView means any rebuild marker set against the OLD editor no longer
        // describes anything this service should keep a batch for.
        self.databaseRebuildGeneration = nil
    }

    /// Reconfigure database references for project switch (WebView stays the same).
    ///
    /// Race 1 fix: drains any in-flight poll cycle FIRST. Without this, a cycle
    /// already running against the OLD project could still be mid-suspension
    /// (inside `flushPendingJSChanges`'s `evaluateJavaScript` await, or any later
    /// await in `doPollBlockChanges`) when this reassigns `projectDatabase`/
    /// `projectId` out from under it — and because that cycle captured its
    /// `database`/`projectId` locals BEFORE this call ever ran, while its
    /// `generationAtPoll` snapshot is captured fresh after resuming from a
    /// suspension, the two halves of its snapshot could straddle this very
    /// reassignment: `generationAtPoll` reflecting the NEW (post-switch) state
    /// while `database`/`projectId` still point at the OLD project. The mid-flight
    /// generation guard (`checkGenerationGuard`) would then see no mismatch — it
    /// compares live `editorState?.contentGeneration` against a snapshot that
    /// already reflects the post-switch value — and the cycle could finish by
    /// writing a stale OLD-project batch through locals that no longer describe
    /// the currently-configured project.
    ///
    /// `database`/`projectId` are assigned immediately after the drain with no
    /// suspension point between them and no suspension point before them either
    /// (the whole type is @MainActor), so nothing can observe a half-switched
    /// state once this returns.
    func reconfigure(database: ProjectDatabase, projectId: String) async {
        await drainInFlightPoll()          // the ONLY await, unchanged (Race 1)
        // --- synchronous from here: nothing can observe a half-switched state ---
        // t-94369a83 Phase 1: retire the old writer (skips every turn it has
        // reserved and drops every held op) and start a new one, continuing its
        // sequence space so stamps stay monotonic across the switch (see
        // "Sequence continuity" in the plan). The save before a switch is the
        // lifecycle's own sequence (`EditorViewState.runLifecycleFlush`: the
        // force-send, FB and the writer barrier, then the tail's retire); `retire`
        // here refuses anything reserved after that, which the epoch bump below
        // already rejects today.
        let next = writer?.nextSequence ?? 1
        // See the matching comment in `configure`'s writer-replacement branch: these
        // are DEBUG-only test knobs, per-INSTANCE on the writer, that must survive a
        // replacement the same way `nextSequence` continuity already does.
        #if DEBUG
        let carriedEventHandler = writer?.testEventHandler
        let carriedLateAfter = writer?.testLateAfterSeconds
        let carriedDrainTimeout = writer?.testDrainTimeoutSeconds
        let carriedLateAbandonAfter = writer?.testLateAbandonAfterSeconds
        #endif
        writer?.retire(reason: .projectSwitch)
        writer = DocumentWriter(
            database: database, projectId: projectId, firstSequence: next, assertsMainActorCallers: true)
        #if DEBUG
        writer?.testEventHandler = carriedEventHandler
        writer?.testLateAfterSeconds = carriedLateAfter
        writer?.testDrainTimeoutSeconds = carriedDrainTimeout
        writer?.testLateAbandonAfterSeconds = carriedLateAbandonAfter
        #endif
        self.projectDatabase = database
        self.projectId = projectId
        // A fresh project means every batch still in flight from the OLD project was
        // fetched against a coordinate space this project does not share. Bump the
        // persisted epoch so those batches are refused wholesale in the write
        // transaction - the durable replacement for the in-memory reset that used to
        // sit here and could not see a native rewrite at all. `needsEpochBump` is set on
        // EVERY attempt, so a failed bump for the previous project cannot leak into this
        // one, and a failed bump for this one is retried by the next poll.
        do {
            _ = try database.bumpBlockWriteEpoch(projectId: projectId)
            needsEpochBump = false
        } catch {
            needsEpochBump = true
            DebugLog.alwaysPersisted("[BlockSync] reconfigure: could not bump blockWriteEpoch (\(error)) - the next poll will retry it")
        }
        // A rebuild marker set against the OLD project describes a generation bump that
        // no longer applies once the drain above has settled and this reassigns the
        // project references.
        self.databaseRebuildGeneration = nil
    }

    /// Start polling for block changes
    func startPolling() {
        stopPolling()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollBlockChanges()
            }
        }
    }

    /// Stop polling for block changes. Synchronous — does NOT drain an in-flight
    /// cycle; a cycle already running keeps running until it finishes or its own
    /// watchdog expires (see `raceWithTimeout(seconds:work:)` in
    /// `runPollCycle`), after this returns. Also used internally by
    /// `startPolling()` above, which must stay synchronous (it is not `async`, and
    /// re-polling right after starting has never needed to wait on a prior cycle).
    /// Callers that need a guarantee no poll cycle is still running afterward —
    /// e.g. before flush work that itself writes to the database — await a raced
    /// drain (`raceDrain(bound:)`, the lifecycle save sequence's step 4) instead.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Force an immediate poll of block changes (bypasses the 2s timer).
    /// Call before reading blocks from DB when fresh editor content is needed.
    /// Uses force mode to bypass contentState/generation guards, since callers
    /// explicitly need the flush to succeed regardless of current state.
    /// May block under contention: if a poll cycle is already running, this
    /// waits for it to finish before running a fresh cycle of its own, so the
    /// worst case is bounded by two watchdog periods
    /// (`defaultPollWatchdogSeconds`, 8s each) rather than returning immediately
    /// with stale (or no) data. That wait is bounded because each cycle's own
    /// watchdog releases the in-flight slot after `defaultPollWatchdogSeconds`
    /// even when the cycle's WebKit call never returns.
    ///
    /// What this does NOT guarantee (A2/A15): the forced flush returns when the
    /// SPAWNER returns, and the cycle's work task can still be parked waiting for its
    /// writer turn (`ticket.waitForTurn()`) when the watchdog fires (when the fetch
    /// itself returned late). t-94369a83 Phase 1: a stuck predecessor's turn now goes
    /// LATE after `DocumentWriter.lateAfterSeconds` (3.0s, strictly below this
    /// watchdog's 8s with margin) rather than blocking this cycle forever, and any of
    /// THIS cycle's own ops that depend on the stuck predecessor's not-yet-minted
    /// temp ids are held (not lost) until it lands. Even so, a forced flush whose
    /// cycle times out returns WITHOUT its own edit in the DB (L8 in the plan's
    /// loss-path table), which the unconditional timeout log says explicitly.
    /// Awaiting this narrows the stale-read window; it does not close it.
    func pollBlockChangesNow() async {
        await pollBlockChanges(force: true)
    }

    /// Addendum A2 §1: replaces `drainWriterSettlement()`. Bounded, READ-ONLY wait
    /// for the writer to actually SETTLE every sequence reserved as of this call --
    /// not merely for `pollBlockChanges(force:)`'s own drain loop (`while let
    /// inFlight = inFlightPoll { await inFlight.value }`) to return, which (per
    /// this file's "What this does NOT guarantee" note above `pollBlockChangesNow`)
    /// only waits for a stuck predecessor's OWN poll-level watchdog, not for its
    /// real underlying work (a bare `evaluateJavaScript` call the watchdog cannot
    /// observe completion of). `DocumentWriter.awaitSettled(through:timeout:)` is a
    /// DIFFERENT, writer-internal wait: it polls `WriterState.phase` directly, so
    /// it keeps waiting for a predecessor's real apply to land even after the
    /// poll-level drain has already returned early. Bounded by THIS poll cycle's
    /// own `watchdogSeconds` (DEBUG-overridable via
    /// `testRebuildSettleTimeoutSeconds`) -- matching the "worst case bounded by
    /// two watchdog periods" model `pollBlockChangesNow()`'s doc comment already
    /// describes, and strictly above `DocumentWriter.lateAfterSeconds` with
    /// margin, so a predecessor gets the chance to go late and apply before this
    /// gives up.
    ///
    /// UNLIKE the old `drain`-based wait, timing out here changes NOTHING: no
    /// skip, no held-op drop, no ledger change, no frontier move -- see
    /// `awaitSettled`'s own doc comment. A rebuild that gives up waiting proceeds
    /// against whatever is in the database right now. This narrows the residual
    /// this method exists to close, but does not eliminate it: the remaining case
    /// is a late batch that meets the generation guard's check AFTER this wait's
    /// own bound has already been reached -- that case is now COUNTED (via
    /// `testRebuildProceededUnsettledCount`, and via `awaitSettled`'s own
    /// unconditional log line and `testAwaitSettledTimeoutCount` on the writer
    /// itself), not silently skipped or dropped the way the old drain-based wait
    /// would have forced it to be. Used by `pollBlockChangesNowForDatabaseRebuild()`
    /// so it does not clear `databaseRebuildGeneration` -- closing the Finding #1
    /// KEEP exception's window -- while a routine cycle it is meant to be waiting
    /// on is still genuinely in flight underneath a watchdog-truncated Task handle
    /// (t-94369a83 Phase 1, B4 regression: `checkGenerationGuard`'s own doc
    /// comment names this exact class of gap).
    @discardableResult
    func awaitWriterSettlementForRebuild() async -> SettleWaitOutcome {
        guard let writer else { return .settled }
        let watermark = writer.nextSequence - 1
        let outcome = await writer.awaitSettled(through: watermark, timeout: rebuildSettleTimeoutSeconds)
        #if DEBUG
        if case .stillOpen = outcome {
            testRebuildProceededUnsettledCount += 1
        }
        #endif
        return outcome
    }

    /// The rebuild-settlement wait bound this call site actually uses. DEBUG
    /// builds may override it per instance for tests, mirroring
    /// `watchdogSeconds`.
    private var rebuildSettleTimeoutSeconds: TimeInterval {
        #if DEBUG
        testRebuildSettleTimeoutSeconds ?? watchdogSeconds
        #else
        watchdogSeconds
        #endif
    }

    /// Handle to whichever poll cycle is currently running, or nil if none is.
    /// Replaces a boolean `isPolling` reentrancy guard so a forced flush can
    /// *wait out* a concurrently-running cycle instead of silently skipping
    /// itself — see `pollBlockChanges(force:)` for the full reasoning. This was
    /// the root cause of a footnote/Notes data-loss bug: a forced flush arriving
    /// while a periodic poll was mid-flight used to return immediately without
    /// ever reading the caller's just-made edit.
    ///
    /// The Task's value is the cycle's `PollCycleResult` (Phase 3a-1b): the spawner carries the
    /// watchdog-hit outcome out to whoever awaits it (`drainInFlightPoll()`, `pollBlockChanges`).
    private var inFlightPoll: Task<PollCycleResult, Never>?

    /// Whether `inFlightPoll` (when non-nil) is a *forced* cycle. Paired with
    /// `inFlightPoll` and set in the same synchronous window as its assignment in
    /// `pollBlockChanges(force:)` (no suspension point between them; the whole type
    /// is @MainActor), so it's always consistent with whichever task the slot
    /// currently holds. Read by `drainInFlightPoll()` to decide whether it may
    /// cancel the in-flight cycle or must only wait for it — see that method's doc
    /// comment (MUST-FIX 2 in the block-sync-poll-races plan).
    ///
    /// The poll watchdog (`raceWithTimeout` in `runPollCycle`) may still cancel a
    /// forced cycle's WORK task as best-effort cleanup when it expires; what this
    /// flag governs is only the DRAIN, which never cancels a forced cycle and
    /// instead waits (bounded) for it — a forced call is a completion guarantee its
    /// caller relies on.
    private var inFlightPollIsForced = false

    /// Number of watchdog-timed-out cycles that are still parked BEFORE their batch
    /// was handed to Swift (`CycleProgress.hasFetchedBatch == false`) — i.e. orphans
    /// whose `evaluateJavaScript` call has not returned, so no batch was consumed
    /// yet. This bounds how much parked work (one work Task + watcher + JS
    /// continuation per orphan) can accumulate against a content process that is
    /// slow to reply or genuinely wedged — ordering and holding a successor's op
    /// behind a stuck predecessor is no longer this counter's job; that's the
    /// writer's (§2.2), which reserves a turn and queues independently of whether
    /// THIS counter is zero. Addendum A1 (t-94369a83): a bare `== 0` guard used to
    /// block every unforced tick for as long as ANY orphan remained outstanding,
    /// which for a content process that never replies again is forever — a real,
    /// periodic successor edit could never even attempt to reach the writer. See
    /// `orphansToleratedWhileResponsive` and `maxOutstandingPrefetchOrphans` for the
    /// fix: a bounded number of unforced cycles are now admitted as PROBES even
    /// while orphans are outstanding, provided the content process has proven
    /// recently responsive. Each claim is released by the orphan's own `defer` when
    /// it actually ends (see `runPollCycle`), saturating at zero because `configure`
    /// RESETS this to 0 when it installs a fresh WebView: an orphan parked in the OLD
    /// WebView no longer belongs to the editor now being polled, so it must neither
    /// keep the new editor's unforced ticks paused nor drive the count negative when
    /// it finally releases. (`reconfigure` deliberately does NOT reset it: a project
    /// switch keeps the same WebView and drains first, so any outstanding orphan is
    /// still that WebView's.)
    private var outstandingPrefetchOrphans = 0

    /// Addendum A1 (t-94369a83): how many outstanding orphans the LAST proven-
    /// responsive fetch tolerated -- i.e. the orphan count observed at the moment a
    /// cycle's `getBlockChanges()` call actually RETURNED (see
    /// `doPollBlockChanges`), not merely at the moment its cheap `hasBlockChanges()`
    /// pre-check answered. Responsiveness has to come from `getBlockChanges`
    /// specifically: `hasBlockChanges` is a trivial flag read the content process can
    /// answer even while the SAME process is about to wedge on the very next,
    /// heavier call -- proving that call alone would let a process that's actually
    /// stuck on `getBlockChanges` look "responsive" forever and defeat the guard
    /// below entirely. An unforced tick is admitted (as a PROBE) only while
    /// `outstandingPrefetchOrphans` is no more than one past this tolerated count --
    /// i.e. at most one MORE cycle may be outstanding, parked, than the process has
    /// most recently proven it can still complete. Clamped down (never up) whenever
    /// an orphan releases, so a stretch of genuine unresponsiveness can't leave a
    /// stale, too-generous tolerance sitting around forever once the process goes
    /// fully silent. See `maxOutstandingPrefetchOrphans` for the hard backstop this
    /// works alongside.
    private var orphansToleratedWhileResponsive = 0

    /// Addendum A1 (t-94369a83): true once the current run of paused unforced ticks
    /// has already logged its one `[BlockSync] Periodic poll paused` line -- reset
    /// the moment a tick is admitted again, so a genuinely long stuck stretch logs
    /// once per pause, not once per 2-second tick.
    private var hasLoggedBackPressureSkip = false

    /// Addendum A1 (t-94369a83): hard backstop on `outstandingPrefetchOrphans`,
    /// independent of `orphansToleratedWhileResponsive` -- no matter how responsive
    /// the content process has recently proven itself, this many STILL-parked
    /// orphans is the most this service will ever let accumulate before refusing
    /// every further unforced tick outright, same as the pre-addendum behavior. This
    /// is what keeps a content process that wedges on a DIFFERENT call every few
    /// ticks (proving `getBlockChanges` responsive each time, but never actually
    /// finishing one) from admitting an unbounded number of parked cycles.
    private static let maxOutstandingPrefetchOrphans = 4

    /// True when the last `bumpBlockWriteEpoch` attempt in `configure`/`reconfigure`
    /// FAILED. Set on every attempt (false on success), never left over from an earlier
    /// project.
    ///
    /// Why this exists: with the bump failed, the persisted epoch is still the previous
    /// session's while the writer's sequence restarts low. Rows already edited last
    /// session carry stamps like `(E, 300)`, so every update/delete this session's
    /// low-sequence batches sent to those rows would be dropped as "superseded" until
    /// the in-memory counter caught up -- silent loss of the user's typing.
    /// `reserveWriterTurn` retries the bump — after `doPollBlockChanges`'s
    /// fetch-boundary cancellation check, not at the top of the cycle — BEFORE it
    /// reads the epoch and before anything is fetched, and defers the whole poll while
    /// the retry keeps failing. That trades a silent-drop failure for a no-write
    /// failure, which is lossless: nothing has been consumed JS-side yet, so the
    /// batch stays queued and is re-offered next tick.
    ///
    /// Internal (was private) in Phase 4a: `ensureWriter` (BlockSyncService+Markdown.swift) mirrors `configure`'s
    /// new-writer branch, which sets it.
    var needsEpochBump = false

    /// Set synchronously by a bibliography/Notes/footnote rebuild the instant it bumps
    /// `contentGeneration` (i.e. the instant it sets `editorState.contentState =
    /// .bibliographyUpdate`); cleared when its forced flush returns, before it reads the
    /// database. Not `private` — `BlockSyncService+DatabaseRebuild.swift` (an extension)
    /// reads and writes it. See `shouldKeepBatchForDatabaseRebuild(currentGeneration:
    /// generationAtPollStart:rebuildGeneration:)` for how this narrow window lets a poll
    /// cycle parked between its fetch and its generation re-check KEEP a batch that would
    /// otherwise be discarded as stale — the fix for Finding #1 (Calm_Bibliography).
    var databaseRebuildGeneration: Int?

    #if DEBUG
    /// Test-only hook, awaited at the very top of every poll cycle
    /// (`runPollCycle`). Lets a test hold a cycle deterministically suspended
    /// mid-flight to exercise the reentrancy paths below without racing real
    /// timers or sleeping. No cost in release builds (property doesn't exist).
    var testPollCycleHook: (() async -> Void)?

    /// Test-only counter, incremented every time `shouldAbandonForGenerationChange`
    /// causes a poll cycle to abandon its batch (see `checkGenerationGuard`). Lets
    /// tests assert precisely that THIS guard — not the pre-existing
    /// `contentState == .idle` guard or the stale-snapshot guard — caused a
    /// rejection, without scraping `DebugLog` console output.
    var testGenerationAbandonCount = 0

    /// Test-only counter, incremented every time `checkGenerationGuard` KEEPS a batch
    /// that would otherwise have been abandoned, because
    /// `shouldKeepBatchForDatabaseRebuild(...)` found the pending transition was the
    /// rebuild itself (Finding #1, Calm_Bibliography). Lets tests assert precisely that
    /// this exception fired, without scraping `DebugLog` console output.
    var testRebuildKeptBatchCount = 0

    /// Test-only hook, awaited immediately after `generationAtPoll` is captured in
    /// `doPollBlockChanges` — i.e. right at the point a wholesale content rewrite
    /// (mode toggle, zoom, bibliography/notes rebuild, project switch) landing here
    /// would make this cycle's snapshot stale. Unlike `testPollCycleHook` (awaited
    /// at the very top of the cycle, before this capture happens), gating here lets
    /// a test hold a cycle deterministically suspended with an already-captured
    /// generation snapshot, so it can simulate the race the mid-flight generation
    /// guard exists to close without a wall-clock sleep. Deliberately placed OUTSIDE
    /// `checkGenerationGuard` itself (not conditional on the guard existing) so a
    /// deletion-check that removes the guard still reaches this hook — the guard's
    /// absence must change the test's OBSERVED OUTCOME, not silently deadlock its
    /// synchronization. No cost in release builds (property doesn't exist).
    ///
    /// Ordering note (block-sync-poll-races fix): this now fires BEFORE
    /// `flushPendingJSChanges` runs, not after — the generation/database/projectId
    /// snapshot moved earlier so it's captured in one suspension-free window (see
    /// `doPollBlockChanges`'s doc comment). A test parked here is therefore
    /// suspended strictly before that JS-side debounce flush, not after it. This
    /// doesn't weaken what the hook can exercise: `checkGenerationGuard`'s callers
    /// read `editorState?.contentGeneration` live at invocation time, not a value
    /// cached at this hook, so a mid-flight rewrite injected while parked here is
    /// still detected regardless of exactly when the JS flush call happens to run
    /// relative to this point.
    var testAfterGenerationCaptureHook: (() async -> Void)?

    /// Test-only hook, awaited immediately after `pollBlockChangesNowForDatabaseRebuild()`
    /// (`BlockSyncService+DatabaseRebuild.swift`) captures its own `myMarker` snapshot of
    /// `databaseRebuildGeneration` — before that call can suspend on anything. Lets a test
    /// prove exactly when that entry (and therefore that capture) happened, rather than
    /// assuming a freshly spawned `Task`'s body starts only after its spawner's next
    /// `await` — that is not a language guarantee. No cost in release builds (property
    /// doesn't exist).
    var testAfterMarkerCaptureHook: (() async -> Void)?

    /// Test-only entry point to the otherwise-private poll, so tests can drive
    /// forced/periodic cycles directly instead of waiting on the real timer.
    func pollBlockChangesForTest(force: Bool = false, webView: WKWebView? = nil) async {
        await pollBlockChanges(force: force, webView: webView)
    }

    /// Test-only per-INSTANCE override of the poll watchdog duration
    /// (`watchdogSeconds` in `runPollCycle`). Deliberately an instance property and
    /// never a `static var`: Swift Testing runs suites concurrently, and a
    /// process-global 0.2s watchdog would shorten the cycle for every other
    /// concurrently-running suite in the same process (the same reason
    /// DiagnosticLogFile.swift:57-61 keeps its own test override instance-scoped).
    var testPollWatchdogSeconds: TimeInterval?

    /// Test-only per-INSTANCE override of the writer's turn-stall expiry
    /// (`DocumentWriter.lateAfterSeconds`), mirroring `testPollWatchdogSeconds`.
    /// Threaded straight through to the writer; nil until a writer exists.
    var testWriterLateAfterSeconds: TimeInterval? {
        get { writer?.testLateAfterSeconds }
        set { writer?.testLateAfterSeconds = newValue }
    }

    /// Test-only read of the writer's loss ledger (skipped/discarded/failed/held
    /// counts) -- see `LossLedger`. Empty (all zero) if no writer exists yet.
    var testWriterLedger: LossLedger { writer?.ledger ?? LossLedger() }

    /// Addendum A2 §1: test-only per-INSTANCE override of
    /// `awaitWriterSettlementForRebuild()`'s own wait bound, mirroring
    /// `testWriterLateAfterSeconds`. Nil means fall back to `watchdogSeconds`,
    /// same as before this addendum.
    var testRebuildSettleTimeoutSeconds: TimeInterval?

    /// Addendum A2 §1: counts every time `awaitWriterSettlementForRebuild()` gave
    /// up waiting (`SettleWaitOutcome.stillOpen`) and proceeded against the
    /// database as-is. Distinct from `DocumentWriter`'s own
    /// `testAwaitSettledTimeoutCount` (which counts every `awaitSettled` timeout
    /// on the writer, not just ones reached through this rebuild wrapper) --
    /// telemetry only, incremented from `awaitWriterSettlementForRebuild()` itself.
    var testRebuildProceededUnsettledCount = 0

    /// Test-only per-INSTANCE override of the writer's abandonment bound
    /// (`DocumentWriter.lateAbandonAfterSeconds`, addendum A2 §3), mirroring
    /// `testWriterLateAfterSeconds`. Threaded straight through to the writer; nil
    /// until a writer exists. Carried across `configure`/`reconfigure` the same
    /// way the other writer test knobs already are.
    var testWriterLateAbandonAfterSeconds: TimeInterval? {
        get { writer?.testLateAbandonAfterSeconds }
        set { writer?.testLateAbandonAfterSeconds = newValue }
    }

    /// Test-only observation of the writer's currently-held op count
    /// (`DocumentWriter.testHeldCount`). Zero if no writer exists yet.
    var testWriterHeldCount: Int { writer?.testHeldCount ?? 0 }

    /// Test-only pass-through to the writer's DEBUG event handler (see `WriterEvent`).
    /// Nil until a writer exists (i.e. before the first `configure`).
    var testWriterEventHandler: (@Sendable (WriterEvent) -> Void)? {
        get { writer?.testEventHandler }
        set { writer?.testEventHandler = newValue }
    }

    /// Test-only observation of the M3/A5 back-pressure counter. The counter itself
    /// is private (and never exposed for mutation), so a test can only read it.
    var testOutstandingPrefetchOrphans: Int { outstandingPrefetchOrphans }

    /// Test-only observation of addendum A1's tolerance counter. Private (and never
    /// exposed for mutation), so a test can only read it.
    var testOrphansToleratedWhileResponsive: Int { orphansToleratedWhileResponsive }

    /// Test-only signal invoked on MainActor from the watchdog's `.timedOut` arm,
    /// AFTER `testPollTimeoutForceFlags` is appended and BEFORE the unconditional
    /// `DebugLog.always` timeout line (M5/A13). Instance-scoped on purpose: tests must
    /// not synchronize through the process-global `DebugLog.alwaysSink`, which other
    /// concurrently running suites can capture from and overwrite (A12).
    var testPollTimeoutHandler: (() -> Void)?

    /// Test-only observation of the in-flight slot. The slot itself is `private`
    /// (and is cleared from INSIDE the spawned task's body — see
    /// `pollBlockChanges(force:)`), so a test can only read it through this seam.
    var testInFlightPollIsNil: Bool { inFlightPoll == nil }

    /// Test-only observation of the periodic poll timer. True while a scheduled,
    /// still-valid timer exists (i.e. a future periodic tick can still fire).
    var testPollTimerIsArmed: Bool { pollTimer?.isValid == true }

    /// Test-only replacement for the four poll-path `webView.evaluateJavaScript`
    /// calls routed through `evaluateJS(_:in:)` (checkForChanges,
    /// getBlockChanges, flushPendingJSChanges, confirmBlockIds). Lets a test script
    /// replies — including a one-shot wedge — without a real WKWebView or a run loop.
    var testJSEvaluator: ((String) async throws -> Any?)?

    /// Test-only (t-94369a83 3a-1b round C4, U7(a)): called with the WebView each `evaluateJS` call is made
    /// against, before `testJSEvaluator` answers it. `testJSEvaluator` receives only the script, so without
    /// this a test could not tell WHICH view a fetch went to -- the editor the user is typing in (CodeMirror
    /// in Markdown) or the block-sync service's own, which is the Milkdown editor's.
    var testJSWebViewObserver: ((WKWebView) -> Void)?

    /// Test-only (t-94369a83 3a-1b round C5a): replaces the `evaluateJavaScript` call at the end of
    /// `pushBlockIds(for:)` (which does NOT route through `evaluateJS`, so `testJSEvaluator` never sees it). It
    /// receives the ordered block ids the push would have sent and is awaited in place of the real call, so a test
    /// can record that (and when) the abort routine re-pushed ids, or park it to stand in for a push that never
    /// returns (the real call has no timeout). No cost in release builds (property doesn't exist).
    var testPushBlockIdsHook: (([String]) async -> Void)?

    /// Test-only (t-94369a83 Phase 4b slice 2a): replaces `setContentWithBlockIds`'s whole JavaScript push. Receives the markdown,
    /// the block ids, the managed block ids and `preserveUserBlocks`, and returns what the push would return (the merged markdown
    /// under `preserveUserBlocks`, else nil). No cost in release builds (property doesn't exist).
    var testSetContentHook: ((String, [String], Set<String>, Bool) async -> String?)?

    /// Test-only (t-18b7fa48 round 1g-A, review T1): the `detectPausedEdits` option of the push that is going through
    /// `testSetContentHook` (the hook's own arguments carry no options). It is the flag that keeps keystrokes typed while the push
    /// is in flight (the editor's block-sync paused) as pending changes instead of discarding them, so a test that stands in for the
    /// editor needs it to tell the two apart. Set just before the hook is called. No cost in release builds (property doesn't exist).
    var testSetContentLastDetectPausedEdits = false

    /// Test-only hook, awaited immediately after `ticket.noteFetched()` -- i.e.,
    /// while this cycle's editor sequence is genuinely OPEN (`SystemWriteScope.
    /// heldEditorSeq` is already set to it, and `DocumentWriter.isOpen(_:)` reports
    /// `true`) but before `waitForTurn()`/`applyAndConfirm` have run. Lets a test
    /// park a real poll cycle deterministically inside that window (W34) to drive
    /// `performSystemWrite`'s A5 nesting check against a REAL open editor sequence
    /// -- not a synthetic stand-in -- from a concurrent `Task`. No cost in release
    /// builds (property doesn't exist).
    var testAfterFetchHook: (() async -> Void)?

    /// Test-only hook awaited immediately AFTER the apply step (the writer's
    /// `applyEditorBatch` call, plus any `confirmBlockIds` round-trip). Tests must
    /// NEVER park in it: parking here would hold up nothing on THIS cycle's own
    /// account (unlike the old apply-chain valve), but it still runs before the
    /// cycle's own defer/return, so a parked hook delays this test's own assertions.
    var testAfterApplyHook: (() async -> Void)?

    /// Test-only record of every watchdog timeout, one entry per timeout carrying
    /// that cycle's `force` flag. Empty means no cycle timed out.
    var testPollTimeoutForceFlags: [Bool] = []
    #endif

    // MARK: - Polling

    /// Poll the editor for block changes, guarding against reentrancy.
    ///
    /// - Unforced (periodic): cheap skip — if a cycle is already in flight, drop
    ///   this tick; the in-flight cycle will pick up any changes itself.
    /// - Forced: callers need a guarantee that everything up to and including
    ///   their own just-made edit has reached the DB. A merely-completed
    ///   in-flight cycle is not sufficient on its own — its snapshot may predate
    ///   the edit — so a forced call always (1) drains any cycle already in
    ///   flight, then (2) runs and awaits a *fresh* cycle of its own, whose
    ///   snapshot is guaranteed to be taken at or after the call.
    ///
    /// Phase 3a-1b (t-94369a83): `webView` polls THAT WebView instead of the service's own weak
    /// one (nil, the default, is today's behaviour); the lifecycle sequence hands in the WebView
    /// it captured strongly at the start. The result is the result of the cycle THIS call ran
    /// (`.notRun` for an unforced tick that was skipped); every existing caller ignores it, and
    /// the lifecycle sequence reads `hitWatchdog` to skip a fetch against a wedged editor.
    /// Internal (not private) so `LifecycleDeadline.swift`'s `raceForcedPoll` can call it.
    @discardableResult
    func pollBlockChanges(force: Bool = false, webView explicitWebView: WKWebView? = nil) async -> PollCycleResult {
        if force {
            // Drain loop, not a single `if`/await: after `await inFlight.value`
            // returns, a *different* caller may have installed a new cycle
            // during that very suspension — recheck catches that.
            while let inFlight = inFlightPoll {
                _ = await inFlight.value
            }
        } else {
            guard inFlightPoll == nil else { return PollCycleResult(outcome: .notRun) }
            // M3/A5 back-pressure for UNFORCED ticks only, addendum A1 (t-94369a83):
            // while cycles that timed out BEFORE their batch was handed to Swift are
            // still parked (a wedged `getBlockChanges` reply, L5), admit only a
            // BOUNDED number of further unforced ticks as PROBES, rather than
            // refusing outright for as long as any orphan remains outstanding. A
            // bare `== 0` guard here blocks every later periodic tick forever
            // against a content process that never replies again — exactly the "a
            // stuck save no longer silently drops a successor's edit" scenario
            // ordering now belongs to the writer (§2.2) for, which can only queue a
            // successor's op if some cycle actually reaches it. Each admitted probe
            // still counts as its own orphan if it also times out unresponsive (see
            // `runPollCycle`), so the count self-corrects: it only keeps climbing
            // while the content process keeps proving unresponsive, and
            // `maxOutstandingPrefetchOrphans` is the hard backstop against unbounded
            // parked work regardless. The counter is deliberately SEPARATE from
            // `inFlightPoll`: the slot is already free here (the spawner returned at
            // the watchdog), and leaving a completed spawner in it would make the
            // forced drain loop above spin on it. Forced cycles skip this check
            // entirely — a forced flush is a completion guarantee.
            guard outstandingPrefetchOrphans <= orphansToleratedWhileResponsive + 1,
                  outstandingPrefetchOrphans < Self.maxOutstandingPrefetchOrphans else {
                if !hasLoggedBackPressureSkip {
                    hasLoggedBackPressureSkip = true
                    DebugLog.alwaysPersisted(
                        "[BlockSync] Periodic poll paused: \(outstandingPrefetchOrphans) cycle(s) stuck before "
                        + "their fetch returned (tolerated=\(orphansToleratedWhileResponsive), "
                        + "cap=\(Self.maxOutstandingPrefetchOrphans)); forced flushes still run"
                    )
                }
                return PollCycleResult(outcome: .notRun)
            }
            hasLoggedBackPressureSkip = false
        }

        // Spawn this cycle and register its handle so a concurrent caller can
        // drain (forced) or skip (unforced) against it.
        //
        // Safety-critical: this task clears `inFlightPoll` itself, from INSIDE
        // its own body, as its last action — never the spawner, after `await
        // task.value` returns out here. If the spawner cleared it from outside,
        // a concurrent drain loop elsewhere could observe this task as complete
        // (`await` on an already-completed `Task`'s `.value` can resume inline,
        // without yielding the MainActor's run loop) and loop back to recheck
        // `inFlightPoll` before the spawner's own post-await statement ever
        // runs. That is a deterministic hang: the drain loop spins forever on a
        // stale non-nil handle. Clearing inside the task body — guaranteed to
        // run before the task's result becomes observable to any awaiter —
        // means the slot is already nil (or has been reassigned to a newer
        // task) by the time anyone can see this task as finished.
        //
        // The clear is unconditional, with no identity check against a
        // captured self-reference: `inFlightPoll = task` immediately follows
        // `Task { ... }` with no `await` between them, and this whole method
        // runs on @MainActor, so no other call can install a different task
        // into the slot between this task's creation and its own eventual
        // completion — only this task's own body is ever "the" in-flight poll
        // for this particular slot occupancy.
        //
        // Phase 3a-1b: the body returns the cycle's `PollCycleResult` AFTER that clear, so the
        // watchdog-hit outcome travels with the task to whoever awaits it, and the ordering
        // guarantee above is untouched (the slot is cleared before the value becomes observable).
        let task = Task { @MainActor [weak self] () -> PollCycleResult in
            let result = await self?.runPollCycle(force: force, webView: explicitWebView)
                ?? PollCycleResult(outcome: .notRun)
            self?.inFlightPoll = nil
            return result
        }
        inFlightPoll = task
        inFlightPollIsForced = force
        return await task.value
    }

    /// Cancels and awaits any in-flight poll cycle, looping because a resumed
    /// `await` can find a newer task already installed (same reasoning as the
    /// drain loop in `pollBlockChanges(force:)` above — a concurrent caller may
    /// install a fresh cycle during the very suspension this awaits through).
    ///
    /// Only cancels an in-flight *unforced* (periodic/background) cycle.
    /// MUST-FIX 2 (block-sync-poll-races plan): a forced cycle — the one behind
    /// `pollBlockChangesNow()` — is a completion guarantee its caller relies on
    /// (footnote insertion, bibliography rebuild, notes rebuild all await it
    /// expecting their own just-made edit to have reached the DB). If this
    /// cancelled a forced cycle, `Task.checkCancellation()` firing inside
    /// `doPollBlockChanges` would make it return early and silently —
    /// indistinguishable, from the awaiting caller's point of view, from a real
    /// completed flush — so that caller's edit could vanish without any error
    /// surfacing. A forced cycle is instead awaited to completion without being
    /// cancelled. Chosen over making the forced-poll cancellation outcome
    /// observable to its caller (a `throws`/enum-returning
    /// `pollBlockChangesNow()`) because that would touch every call site across
    /// `ContentView+NotificationHandlers.swift` and every test that calls it —
    /// this is the smaller, self-contained fix.
    ///
    /// Bounded by the poll cycle's OWN watchdog (`raceWithTimeout` in
    /// `runPollCycle`) — corrected (block-sync-poll-races review round 2, MF1, and
    /// again in the poll-watchdog round): an earlier version of this comment
    /// claimed this "cannot hang indefinitely" because it's "bounded by
    /// `runPollCycle`'s existing 5-second watchdog" — that was false, because
    /// `runPollCycle` raced the poll against its watchdog with a
    /// `withThrowingTaskGroup`, and a task group's exit contract still awaits every
    /// child task before the group call itself returns, even one the watchdog
    /// already "won" against. `doPollBlockChanges` is frequently suspended inside a
    /// bare `webView.evaluateJavaScript(...)` call, which does not observe Swift
    /// Task cancellation, so if WebKit's content process ever wedged mid-cycle,
    /// `runPollCycle` — and therefore `task.value` below — could hang forever.
    ///
    /// The fix is now inside `runPollCycle`: it creates the cycle's work task
    /// itself, races it against `watchdogSeconds` with two independent,
    /// UNSTRUCTURED `Task`s (`raceWithTimeout(seconds:work:)`), and cancels the
    /// loser — so its body always returns within `watchdogSeconds` even when the
    /// work task is wedged forever. This method therefore needs no second race of
    /// its own: cancelling the spawner (`inFlightPoll`) is enough, because
    /// `runPollCycle`'s `withTaskCancellationHandler` forwards the cancellation to
    /// the work task (an unstructured child does not inherit it), and
    /// `await task.value` below then returns as soon as that bounded body is done.
    ///
    /// What the drain guarantees, exactly: it CANCELS an unforced cycle and waits
    /// (at most one watchdog period) for the spawner to return; it never cancels a
    /// forced cycle, and waits the same bounded time for it. This is a BEST-EFFORT
    /// contract, not a proof that no poll write can land underneath the caller's
    /// next write: a cycle wedged inside a bare `evaluateJavaScript` cannot be
    /// forced to finish, and a post-fetch orphan still applies its batch when its
    /// reply finally arrives (see the invariant at the fetch boundary in
    /// `doPollBlockChanges`). Waiting here narrows that window; it cannot close it.
    ///
    /// Phase 3a-1b (obligation 20): returns whether ANY cycle this drain waited for ended at its poll
    /// watchdog (`PollCycleResult.hitWatchdog`), OR-ed across the loop's iterations. The lifecycle
    /// sequence reads it to skip a forced poll and a fetch against an editor that just proved
    /// wedged; every existing caller ignores it (`@discardableResult`). Internal (not private) so
    /// `LifecycleDeadline.swift`'s `raceDrain(bound:)` can call it.
    @discardableResult
    func drainInFlightPoll() async -> Bool {
        var hitWatchdog = false
        while let task = inFlightPoll {
            if !inFlightPollIsForced { task.cancel() }   // never a forced cycle
            // Cancelling the spawner now also cancels the work task (via
            // runPollCycle's withTaskCancellationHandler). Bounded without a
            // second race: the spawner body is `await runPollCycle(...)` + the
            // slot clear, and runPollCycle always returns within watchdogSeconds.
            // NOT a hard bound on the LOOP (A17): a new cycle can be installed
            // between the spawner's clear and this loop's recheck, so the loop may
            // iterate more than once — each iteration still waits at most one
            // watchdog period for the task it is holding, and a post-fetch orphan
            // (L10) can still write after this returns.
            let result = await task.value
            hitWatchdog = hitWatchdog || result.hitWatchdog
        }
        return hitWatchdog
    }

    /// How long `runPollCycle(force:)` waits for a cycle's work task before
    /// declaring it timed out and releasing the in-flight slot (see
    /// `raceWithTimeout(seconds:work:)`). 8 seconds is the bound
    /// `drainInFlightPoll()` used to carry on its own through the deleted
    /// `drainTimeoutSeconds`; the watchdog now enforces it for every cycle, so the
    /// drain inherits it instead of duplicating it.
    ///
    /// A15: this moved the effective per-cycle watchdog from 5s to 8s, so a forced
    /// flush's worst case (an in-flight cycle's watchdog, then its own) grew from
    /// roughly 5+8=13s to 8+8=16s. That is a deliberate trade for a single,
    /// consistent bound everywhere.
    nonisolated static let defaultPollWatchdogSeconds: TimeInterval = 8.0

    /// The watchdog duration this cycle actually races against. DEBUG builds may
    /// override it per instance for tests (`testPollWatchdogSeconds`); release
    /// builds always use the constant.
    private var watchdogSeconds: TimeInterval {
        #if DEBUG
        testPollWatchdogSeconds ?? Self.defaultPollWatchdogSeconds
        #else
        Self.defaultPollWatchdogSeconds
        #endif
    }

    /// Races the poll cycle's already-created `work` task against `seconds`,
    /// handing the task back on timeout so the caller can cancel() it. The
    /// deadline task is cancelled once the race settles, so a cycle that finishes
    /// early leaves no lingering `Task.sleep` (judge should-fix SF-1).
    ///
    /// This — not a `withThrowingTaskGroup` — is what makes the poll watchdog real:
    /// the loser is never awaited, so a work task wedged inside a bare
    /// `webView.evaluateJavaScript` cannot hold `runPollCycle` (and therefore
    /// `inFlightPoll`, and therefore a forced flush's drain) open past
    /// `seconds`.
    private static func raceWithTimeout(seconds: TimeInterval, work: Task<Void, Error>) async -> PollCycleRaceOutcome {
        var deadline: Task<Void, Never>?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<PollCycleRaceOutcome, Never>) in
            let box = OneShotContinuation(continuation)
            Task { @MainActor in
                do { try await work.value; box.resume(.finished) } catch { box.resume(.failed(error)) }
            }
            deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                box.resume(.timedOut(orphan: work))
            }
        }
        deadline?.cancel()
        return outcome
    }

    /// The poll cycle body: the real work task raced against a `watchdogSeconds`
    /// watchdog, with the work task's handle kept so BOTH cancellation sites can
    /// reach it (see the plan's cancellation-semantics table).
    ///
    /// The work task is created HERE, not inside the race, for two reasons:
    /// (1) so its handle is available to the caller's `onCancel:` below, and
    /// (2) so the watchdog can hand it back for best-effort cancellation.
    /// Cancelling the SPAWNER does not reach an unstructured child task, hence the
    /// explicit `withTaskCancellationHandler`.
    ///
    /// `doPollBlockChanges` is `async throws`: it raises `CancellationError` at a
    /// handful of `Task.checkCancellation()` checkpoints so a cancelled cycle (via
    /// `drainInFlightPoll()`) unwinds promptly instead of running its full body
    /// regardless. A7 correction: such a cancellation does NOT surface here like a
    /// watchdog timeout. It arrives as `.failed(CancellationError)`, which is logged
    /// calmly at category `.sync`, records NO `testPollTimeoutForceFlags` entry and
    /// emits NO unconditional line — a timeout is the `.timedOut` arm below. And the
    /// watchdog's `orphan.cancel()` is governed by whether the cycle had already
    /// fetched its batch (A16), not by the forced flag; `inFlightPollIsForced`
    /// governs only the DRAIN (see `drainInFlightPoll()`).
    ///
    /// Phase 3a-1b (obligation 20): returns the cycle's `PollCycleResult`, whose `hitWatchdog` is
    /// true exactly when the `.timedOut` arm below ran. `webView` is threaded to `doPollBlockChanges`.
    private func runPollCycle(force: Bool, webView explicitWebView: WKWebView? = nil) async -> PollCycleResult {
        // Captured ONCE, here, rather than re-read later via the `watchdogSeconds`
        // computed property: `watchdogSeconds` reads the LIVE `testPollWatchdogSeconds`
        // override, which a test is free to mutate for a LATER cycle while this one is
        // still running (e.g. B4's `forcedRebuildFlush...` test sets 0.2 for cycle 1,
        // then 8 for the rebuild flush right after spawning cycle 1). The RACE itself
        // (`raceWithTimeout` below) always correctly used the value in effect at ITS
        // OWN call site -- this bug was only in the TIMED-OUT log line re-reading the
        // (by-then-mutated) property instead of the value actually raced against,
        // which made a cycle that genuinely timed out at 0.2s misleadingly log "TIMED
        // OUT after 8.0s" once some other code had since changed the override. Purely a
        // diagnostic-accuracy fix -- the race's actual timing was never affected.
        let watchdogBound = watchdogSeconds
        // Created HERE (not inside the race) so its handle is cancellable from
        // both sites below. Cancelling the SPAWNER does not reach an unstructured
        // child task, hence the cancellation handler.
        let progress = CycleProgress()
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Release this cycle's pre-fetch orphan claim (if any) the moment the
                // work task actually ends. `workFinished` is set in the same
                // synchronous MainActor block as the watchdog's claim check, which is
                // what makes claim/release exact: either the watchdog claims before
                // this runs (and this releases it), or this runs first and the
                // watchdog sees `workFinished` and does not claim at all.
                progress.workFinished = true
                // Saturating: `configure` zeroes the counter when it installs a fresh
                // WebView, so an orphan that outlives its WebView can still reach this
                // release; without the clamp it would drive the count negative.
                if progress.countedAsOrphan {
                    self.outstandingPrefetchOrphans = max(0, self.outstandingPrefetchOrphans - 1)
                    // Addendum A1 (t-94369a83): clamp DOWN only, never up -- a stretch of
                    // genuine unresponsiveness must not leave a stale, too-generous
                    // tolerance sitting around once the process has gone fully silent
                    // (see `orphansToleratedWhileResponsive`'s own doc comment).
                    self.orphansToleratedWhileResponsive = min(self.orphansToleratedWhileResponsive, self.outstandingPrefetchOrphans)
                }
            }
            #if DEBUG
            await self.testPollCycleHook?()
            #endif
            try await self.doPollBlockChanges(force: force, webView: explicitWebView, progress: progress)
        }
        let outcome = await withTaskCancellationHandler {
            await Self.raceWithTimeout(seconds: watchdogBound, work: work)
        } onCancel: {
            work.cancel()
        }
        switch outcome {
        case .finished:
            return PollCycleResult(outcome: .finished)
        case .failed(let error):
            // A8: a routine drain cancel (`drainInFlightPoll`) unwinds at a pre-fetch
            // checkpoint and lands here as `CancellationError`. That happens on every
            // project switch/close, so it gets a calm category-gated line — not the
            // error line, and (unlike `.timedOut`) no flag and no unconditional line.
            if error is CancellationError {
                DebugLog.log(.sync, "[BlockSync] Poll cycle cancelled (drain) force=\(force)")
                return PollCycleResult(outcome: .cancelled)
            }
            DebugLog.log(.sync, "[BlockSync] Poll cycle ended with error: \(error) force=\(force)")
            return PollCycleResult(outcome: .failed)
        case .timedOut(let orphan):
            #if DEBUG
            // M5/A13: record the flag BEFORE firing the test signal, so a test that
            // awaits `testPollTimeoutHandler` can read the flag without relying on an
            // undescribed MainActor ordering against the log line. The signal is
            // INSTANCE-scoped on purpose — tests must not synchronize through the
            // process-global `DebugLog.alwaysSink`, which concurrent suites can
            // capture from and overwrite (A12).
            testPollTimeoutForceFlags.append(force)
            testPollTimeoutHandler?()
            #endif
            DebugLog.alwaysPersisted(
                "[BlockSync] Poll cycle TIMED OUT after \(watchdogBound)s (likely a wedged WebKit call) — "
                + "force=\(force). A cycle that timed out before its batch was fetched is cancelled and "
                + "unwinds at its next checkpoint; one that already holds a consumed batch is left to "
                + "finish on its own."
                + (force
                   ? " THIS WAS A FORCED FLUSH: its caller has now proceeded WITHOUT its edit in the database."
                   : "")
            )
            // M3/A5: count a cycle that timed out WITHOUT its batch having been handed
            // to Swift as an outstanding pre-fetch orphan, so unforced ticks pause
            // while it is parked. `workFinished` is false in every real wedge (the work
            // task is still parked); it is true only in the narrow interleaving where
            // the work task exited in the same MainActor turn the watchdog won — and
            // in that case its own `defer` has already run without decrementing, so
            // claiming it here would leak the counter forever (permanently pausing
            // unforced polling).
            if !progress.hasFetchedBatch && !progress.countedAsOrphan && !progress.workFinished {
                progress.countedAsOrphan = true
                outstandingPrefetchOrphans += 1
            }
            // A16: cancel only a cycle that has NOT already consumed a batch.
            // Post-fetch cancellation is unobservable today (see the invariant at the
            // fetch boundary in `doPollBlockChanges`), so this changes no current
            // behaviour; it future-proofs "a consumed batch always lands" against
            // `evaluateJavaScript` ever observing cancellation, which would turn
            // `getBlockChanges`'s `try?` into a silently discarded batch.
            if !progress.hasFetchedBatch {
                orphan.cancel()
            }
            return PollCycleResult(outcome: .timedOut)
        }
    }

    /// Inner poll body — contains the actual polling logic.
    ///
    /// `async throws`: raises `CancellationError` at each `Task.checkCancellation()`
    /// checkpoint below. These checkpoints don't change what is lossless to abandon
    /// (see the per-checkpoint reasoning at each call, and the "not after
    /// `getBlockChanges()`" note there) — they exist so a cycle that
    /// `drainInFlightPoll()` has cancelled unwinds promptly at the next checkpoint
    /// instead of running its full body (including further `evaluateJavaScript`
    /// round-trips) to completion regardless. A7 correction: `runPollCycle` reports
    /// the resulting error as a distinct `.failed(CancellationError)` — a calm
    /// category-gated line, NOT a timeout (no timeout flag, no unconditional line).
    ///
    /// The four checkpoints are ALL before the fetch boundary; there is no
    /// cancellation-observing await after it (the invariant comment at that
    /// boundary spells out every post-fetch step and why none observes
    /// cancellation).
    ///
    /// `progress` is the watchdog's per-cycle back-pressure state (M3/A5); it is
    /// optional so every other caller (and any future one) can keep calling this
    /// without threading it.
    private func doPollBlockChanges(
        force: Bool = false, webView explicitWebView: WKWebView? = nil, progress: CycleProgress? = nil
    ) async throws {
        try Task.checkCancellation()

        guard force || editorState?.contentState == .idle else {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] SKIPPED: contentState=\(String(describing: editorState?.contentState))")
            return
        }

        // `explicitWebView` (Phase 3a-1b): the lifecycle sequence's strongly captured WebView, polled
        // instead of the service's own weak one. Without it this is exactly the old `isConfigured`
        // guard (database, project id and WebView all present).
        guard let webView = explicitWebView ?? self.webView, let database = projectDatabase, let projectId else { return }

        // Captured here — BEFORE `flushPendingJSChanges`'s `await` below, in the same
        // suspension-free window as the `database`/`projectId` locals just captured
        // above — so the three form one consistent snapshot. Capturing generation
        // AFTER that await (as this used to) let a project switch land inside the
        // suspension: `database`/`projectId` would still be the OLD project (already
        // captured), but `generationAtPoll` would end up reflecting the NEW,
        // post-switch generation — the mid-flight guard below compares against a live
        // value, so it would see no mismatch and let a stale OLD-project write
        // through. See `reconfigure(database:projectId:)`'s doc comment for the
        // matching half of this fix (draining before it reassigns).
        let generationAtPoll = editorState?.contentGeneration ?? 0
        // Captured alongside generationAtPoll so the guard can tell "editorState was
        // never wired" (not staleness) apart from "editorState was wired here but has
        // since gone nil" (a teardown mid-poll, which IS staleness) — see
        // `shouldAbandonForGenerationChange`.
        let wasEditorStateWiredAtPoll = editorState != nil
        // Scoped to THIS cycle only (a fresh `false` on every `doPollBlockChanges` call,
        // never a stored property): `checkGenerationGuard` is invoked at up to three
        // checkpoints below (preFetch, postFetch, postTurnWait) against the SAME
        // unchanged (generationAtPoll, databaseRebuildGeneration) snapshot whenever
        // nothing else moves the generation between them — unlike an abandon, which
        // short-circuits the cycle at its first checkpoint and so can only ever fire
        // once, a KEEP does not return, so postFetch and postTurnWait both legitimately
        // re-evaluate and would both find the same rebuild-in-flight condition true.
        // That is one save rescued from discard, not two, so the diagnostic counter/log
        // is gated on this flag to fire only at the first checkpoint that finds it.
        var keptForDatabaseRebuildThisCycle = false

        #if DEBUG
        await testAfterGenerationCaptureHook?()
        #endif

        await flushPendingJSChanges(webView: webView, force: force)

        try Task.checkCancellation()

        // Check if there are pending changes
        let hasChanges = await checkForChanges(webView: webView)

        try Task.checkCancellation()

        // DIAGNOSTIC (temporary, footnote-export-race investigation): log the raw
        // hasBlockChanges() result even on the early-return path, so a forced flush
        // that races the JS-side detection debounce is visible in the log instead of
        // silently no-op'ing.
        DebugLog.log(.blockPoll, "[DIAG:BlockPoll] hasChanges=\(hasChanges) force=\(force) at \(Date())")
        guard hasChanges else { return }

        DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] changes detected, fetching... (force=\(force))")

        // Applies in force mode too: force bypasses the contentState *precondition*,
        // not mid-flight invalidation. Nothing has been consumed from JS yet at this
        // point, so an abandoned batch simply stays queued and is re-offered on the
        // next poll — this check is provably lossless. `allowDatabaseRebuildKeep: false`:
        // a discard HERE loses nothing (the forced flush that bumped the generation
        // re-fetches from scratch), so there is no reason to open the database-rebuild
        // exception at this checkpoint — see `checkGenerationGuard`'s doc comment.
        if checkGenerationGuard(
            generationAtPoll: generationAtPoll, wasWiredAtPoll: wasEditorStateWiredAtPoll,
            stage: "preFetch", force: force, allowDatabaseRebuildKeep: false,
            alreadyKeptForRebuild: &keptForDatabaseRebuildThisCycle
        ) {
            return
        }

        // Last lossless cancellation checkpoint. INVARIANT (do not weaken): there
        // must be NO cancellation-OBSERVING await between here and
        // `applyAndConfirm` below. The steps between here and the write are
        // `reserveWriterTurn` (sync: epoch-bump retry, epoch read, `writer.reserve()`
        // — the same no-await region the old chain install used), the `evaluateJS`
        // call inside `getBlockChanges` (WebKit's async API does not observe Swift
        // task cancellation), the synchronous guards/logs (`classifyBatch`),
        // `ticket.waitForTurn()` (a continuation only, resumed by the writer — never
        // by this cycle's own cancellation, which it never observes), and
        // `applyAndConfirm` (an actor hop into `DocumentWriter.applyEditorBatch` plus
        // a synchronous write; actor hops do not observe cancellation). None of this
        // is cancellation-observing. That is exactly what makes the watchdog's
        // `orphan.cancel()` and the drain's `task.cancel()` safe: cancellation stops
        // this cycle only at its four pre-fetch checkpoints, so a batch already
        // consumed JS-side is always written (in writer order) rather than lost.
        // The checkpoint immediately below, BEFORE this call, is the last safe
        // place to bail out losslessly.
        try Task.checkCancellation()

        // t-94369a83 Phase 4b slice 2a (plan D1.2): an editor-first delete's click is in progress, so a ROUTINE cycle steps
        // aside BEFORE reserving or fetching anything (nothing is consumed, so nothing is lost: the pending changes stay queued
        // JS-side and the click's own call takes them). This check and `reserveWriterTurn` below are one synchronous stretch:
        // the `try Task.checkCancellation()` above and this `guard` contain no `await`, and `reserveWriterTurn` is synchronous,
        // so the click path (which sets the flag and reserves its own ticket in one synchronous stretch too,
        // `submitEditorFirstDelete`) can never run in the gap between this check and this cycle's reservation. A forced poll
        // is never paused.
        guard force || !structuralClickPending else {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] SKIPPED: an editor-first section delete's click is in progress")
            return
        }

        guard let (ticket, stamp) = reserveWriterTurn(database: database, projectId: projectId) else { return }

        // Phase 2 (t-94369a83), §1.3: this editor sequence is open -- reserved and
        // (about to be) fetched -- from here through `applyAndConfirm` returning or
        // the `defer` below settling it. `SystemWriteScope.heldEditorSeq` names it for
        // that whole window so `performSystemWrite`'s nesting check (A5) can refuse
        // `.nested` rather than deadlock if something reachable from inside this
        // window ever tries to start a system write against the SAME writer this
        // cycle is holding a turn on. This wraps the EXISTING body verbatim in
        // `withValue(_:operation:)` -- a synchronous save/restore of the task-local
        // around the same `await`s already here -- and changes NOTHING about control
        // flow, suspension points, or the INVARIANT documented above
        // `reserveWriterTurn` (no cancellation-observing `await` between the fetch and
        // `applyAndConfirm`): `withValue` itself introduces no suspension of its own.
        await SystemWriteScope.$heldEditorSeq.withValue(ticket.seq) {
            // Idempotent (S2/S3): a no-op once `applyAndConfirm` below has already
            // settled this sequence, on every path below including an early return.
            defer { ticket.settleIfOpen(.noBatch) }

            // Get the changes
            let changes: BlockChanges
            switch await getBlockChanges(webView: webView) {
            case .success(let fetched):
                changes = fetched
            case .noData:
                return
            case .decodeFailed:
                // The JS call succeeded (the batch was consumed, JS-side queues cleared)
                // but decoding it on the Swift side failed -- a real, counted loss, not
                // the uncounted `.noBatch` the `defer` above would otherwise settle it as
                // (item 7, plan's S6 settlement rule).
                ticket.settleIfOpen(.discarded(.decodeFailed))
                return
            }
            // M3/A5: from here the batch is CONSUMED — the JS side cleared its queues when
            // `getBlockChanges()` ran — so this cycle is no longer a pre-fetch orphan for
            // back-pressure purposes, and a timeout from here on is left to finish rather
            // than cancelled (A16). Recorded in the same synchronous region as
            // `logFetchedUpdates`, immediately after the guard.
            progress?.hasFetchedBatch = true
            // Addendum A1 (t-94369a83): a fetch just returned, so the content process can
            // complete the call that wedges -- every orphan outstanding right now is a
            // lost reply, not a wedge THIS process is currently in. Deliberately recorded
            // here, not in `checkForChanges`'s cheap `hasBlockChanges` pre-check: that
            // call proves nothing about the heavier call that actually wedges, and a
            // process stuck specifically on `getBlockChanges` could otherwise look
            // "responsive" forever. See `orphansToleratedWhileResponsive`'s own doc
            // comment for the full guard this feeds.
            orphansToleratedWhileResponsive = outstandingPrefetchOrphans
            ticket.noteFetched()
            logFetchedUpdates(changes, force: force)
            #if DEBUG
            await testAfterFetchHook?()
            #endif

            // Unlike the preFetch check above, abandoning HERE is NOT lossless: by this point
            // getBlockChanges() (block-sync-plugin.ts's getBlockChanges(), ~line 704-707) has
            // already cleared the JS-side pendingUpdates/pendingInserts/pendingDeletes, so this
            // batch will not be re-offered on a later poll — returning now genuinely discards
            // it. That's still the right call for a mode toggle, zoom, or project switch: there
            // is no lossless option inside this window, and the alternative — re-queuing the
            // already-fetched batch for a later poll — would mean writing pre-rewrite content
            // against a document that's actively being rebuilt from the DB, corrupting the
            // rebuild instead of just dropping one already-stale batch.
            //
            // ONE EXCEPTION (Finding #1, Calm_Bibliography, t-7c1d3fd8): a bibliography/Notes/
            // footnote rebuild is different in kind from those other rewrites — for THOSE, the
            // database is the FRESHER copy and this parked batch is the stale one; for a
            // database rebuild, this parked batch is the FRESHER copy (it may hold the very
            // citation/footnote edit that triggered the rebuild) and the database — which the
            // rebuild is about to read via `fetchBlocksWithIds()` — is the OLDER one. Discarding
            // here would let the rebuild overwrite the editor with its own stale pre-edit text.
            // `allowDatabaseRebuildKeep: true` lets `checkGenerationGuard` below KEEP (not
            // abandon) a batch in that one specific case — see that function's doc comment for
            // why it's safe: the rebuild cannot read the database until ITS forced flush
            // returns, and that forced flush awaits this very poll cycle first, so a kept batch
            // is normally written before the rebuild's read (see that doc comment's KNOWN
            // RESIDUAL for the narrow hung-WebKit-watchdog window where it is not).
            if checkGenerationGuard(
                generationAtPoll: generationAtPoll, wasWiredAtPoll: wasEditorStateWiredAtPoll,
                stage: "postFetch", force: force, allowDatabaseRebuildKeep: true,
                alreadyKeptForRebuild: &keptForDatabaseRebuildThisCycle
            ) {
                ticket.settleIfOpen(.discarded(.generationChanged("postFetch")))
                return
            }

            // Classify, wait for the turn, check the generation once more, apply (`applyFetchedBatch`, shared with the
            // editor-first section delete's click path, t-94369a83 Phase 4b slice 2a). The post-turn generation check is this
            // cycle's own, so it is handed in.
            await applyFetchedBatch(
                ticket: ticket, changes: changes, stamp: stamp, webView: webView,
                database: database, projectId: projectId, force: force,
                abandonAfterTurn: {
                    // Writer jobs cannot slip into this gap: the writer admits seq+1 only after
                    // seq settles. A MainActor write that does NOT bump the epoch can still
                    // land while `await applyEditorBatch` is suspended. Review fix (finding
                    // #12): bibliography/Notes/heading-level writes no longer belong on this
                    // list -- Phase 2 (t-94369a83) routed them through `performSystemWrite`,
                    // the same ordered queue. What's still genuinely outside it: `SectionOps`,
                    // `SectionReconciler`, and `StructuralUndoController`'s own direct
                    // `reorderAllBlocks` call (see `Database+BlockWriteStamp.swift`'s own
                    // comment for the authoritative, up-to-date list). That is the same
                    // residual documented on `applyChanges`, not yet closed for those
                    // remaining writers.
                    self.checkGenerationGuard(
                        generationAtPoll: generationAtPoll, wasWiredAtPoll: wasEditorStateWiredAtPoll,
                        stage: "postTurnWait", force: force, allowDatabaseRebuildKeep: true,
                        alreadyKeptForRebuild: &keptForDatabaseRebuildThisCycle
                    )
                })
            #if DEBUG
            await testAfterApplyHook?()
            #endif
        }
    }

    /// The tail of an editor batch's journey, shared by the poll cycle and the editor-first section delete's click path
    /// (t-94369a83 Phase 4b slice 2a): classify the fetched batch, wait for the ticket's turn, then apply it through the
    /// writer and confirm any minted ids back to the editor. Returns when the ticket has settled (applied, empty, discarded
    /// or skipped). The caller owns the "ticket always settles" `defer` for paths that never get here.
    ///
    /// `abandonAfterTurn` runs once the turn is granted, before the apply: the poll cycle passes its post-turn generation check
    /// (true = discard the batch); the click path passes nothing (there is no generation to compare: the click does not move
    /// `contentState`).
    func applyFetchedBatch( // swiftlint:disable:this function_parameter_count
        ticket: WriterTicket, changes: BlockChanges, stamp: BlockWriteStamp, webView: WKWebView,
        database: ProjectDatabase, projectId: String, force: Bool,
        abandonAfterTurn: () -> Bool = { false }
    ) async {
        switch classifyBatch(changes, database: database, projectId: projectId, force: force) {
        case .apply:
            break
        case .empty:
            ticket.settleIfOpen(.empty)
            return
        case .staleSnapshot:
            ticket.settleIfOpen(.discarded(.staleSnapshot))
            return
        }

        // A non-`.go` result means the writer's own `skip()` call already logged
        // (`DebugLog.alwaysPersisted`, item 1) and counted this sequence in its ledger.
        guard await ticket.waitForTurn() == .go else { return }

        if abandonAfterTurn() {
            ticket.settleIfOpen(.discarded(.generationChanged("postTurnWait")))
            return
        }

        await applyAndConfirm(ticket, changes, webView: webView, stamp: stamp)
    }

    // MARK: - Editor-first section delete: the click's one JavaScript call (t-94369a83 Phase 4b slice 2a)

    /// What `submitEditorFirstDelete` hands back to the click path.
    struct EditorFirstSubmission {
        /// Ticket N, reserved just before the call. Open until the caller settles it or hands the batch to `applyFetchedBatch`.
        let ticket: WriterTicket
        /// The write stamp the batch carries when it is applied (the epoch read at the reservation, the ticket's sequence).
        let stamp: BlockWriteStamp
        /// The call's answer: the JSON string the editor returned, or the error the bridge threw.
        let result: Result<String?, Error>
    }

    /// Reserves editor ticket N and submits the editor-first delete's one JavaScript call in ONE synchronous stretch (plan D1.3,
    /// addendum A7): there is no `await` between `reserveWriterTurn` and the point `evaluateJS` hands the script to the web
    /// view, so reservation order equals submission order equals JavaScript execution order. Any forced poll (a rebuild's, a
    /// lifecycle's) reserves AFTER N and fetches after the removal, which is safe; a routine poll is paused by
    /// `structuralClickPending` and is never between the two.
    ///
    /// Returns nil, having reserved nothing and consumed nothing, when there is no writer, no web view or the epoch could not be
    /// read: the caller then takes today's slow path for this one press.
    func submitEditorFirstDelete(database: ProjectDatabase, projectId: String, script: String) async -> EditorFirstSubmission? {
        await submitEditorFirstCall(database: database, projectId: projectId, script: script)
    }

    /// The same call under its general name (t-18b7fa48 round 1e-i): every editor-first structural operation (a delete, a duplicate,
    /// their quick undo and redo) submits its one JavaScript call this way. `submitEditorFirstDelete` above forwards here.
    func submitEditorFirstCall(database: ProjectDatabase, projectId: String, script: String) async -> EditorFirstSubmission? {
        guard let webView, let (ticket, stamp) = reserveWriterTurn(database: database, projectId: projectId) else { return nil }
        do {
            let value = try await evaluateJS(script, in: webView) as? String
            return EditorFirstSubmission(ticket: ticket, stamp: stamp, result: .success(value))
        } catch {
            return EditorFirstSubmission(ticket: ticket, stamp: stamp, result: .failure(error))
        }
    }

    /// Mid-flight generation re-check, shared by all three call sites in
    /// `doPollBlockChanges` (preFetch, postFetch, postTurnWait — the last one added
    /// by M1/A1 to cover the window the apply-chain valve opens).
    /// Runs unconditionally — including in force mode — because `force` only bypasses the
    /// contentState *precondition* at the top of the cycle, never mid-flight invalidation:
    /// a snapshot taken before a wholesale content rewrite (mode toggle, zoom, bibliography/
    /// notes rebuild, project switch) is stale no matter who asked for the flush. Returns
    /// true (and logs + counts, DEBUG only) when the caller must abandon this poll's batch.
    ///
    /// Note: this guard is inert for the three force callers in
    /// `ContentView+NotificationHandlers.swift` and `ContentView+FootnoteHandlers.swift`
    /// (bibliography rebuild, notes rebuild, immediate footnote insertion) with respect
    /// to their OWN transition — each sets
    /// `editorState.contentState` to a non-idle value (bumping `contentGeneration`)
    /// *before* spawning the `Task` that calls `pollBlockChangesNow()`, so `generationAtPoll`
    /// is always captured post-bump and those callers never observe a mid-flight change
    /// from the very transition they're running. Not a defect — a *different*, concurrent
    /// rewrite landing during their poll would still be caught — just worth naming so a
    /// future reader doesn't assume those three callers are protected against every stale
    /// scenario by this guard alone.
    ///
    /// ONE EXCEPTION (Finding #1, Calm_Bibliography, t-7c1d3fd8), gated by
    /// `allowDatabaseRebuildKeep`: a bibliography/Notes/footnote rebuild is not a wholesale
    /// content rewrite in the same sense as the others above — it FORCE-FLUSHES (via
    /// `pollBlockChangesNowForDatabaseRebuild()`) and only THEN reads the database, which
    /// means the database it is about to read cannot yet reflect anything this method's
    /// caller (the ROUTINE 2-second cycle, parked here since before the rebuild began) has
    /// not already written. If that routine cycle's own snapshot predates the rebuild by
    /// exactly one generation — i.e. the pending transition IS the rebuild itself, not some
    /// earlier or additional rewrite (`shouldKeepBatchForDatabaseRebuild` enforces this
    /// precisely) — abandoning it here would DISCARD the very edit the rebuild is about to
    /// overwrite with older database text. Safe because of ordering, not luck: the rebuild's
    /// force-flush (`pollBlockChangesNowForDatabaseRebuild`) awaits THIS cycle's REAL
    /// settlement before it can return — not just the poll-level drain, see the (now
    /// closed) FORMER KNOWN RESIDUAL below — so a kept batch is written before the
    /// rebuild's read. `allowDatabaseRebuildKeep: false` at the preFetch call
    /// site because a discard there is lossless anyway (nothing has been consumed JS-side, and
    /// the rebuild's own forced flush re-fetches from scratch) — the exception only matters,
    /// and is only enabled, once a batch has actually been consumed (postFetch, postTurnWait).
    ///
    /// FORMER KNOWN RESIDUAL, CLOSED (t-94369a83 Phase 1, B4 regression fix) for the
    /// rebuild path specifically: "the rebuild does not touch the database until that
    /// await returns" used to be true only of the SPAWNER (`pollBlockChanges(force:)`'s
    /// drain loop, `while let inFlight = inFlightPoll { await inFlight.value }`), which
    /// can return at its OWN `defaultPollWatchdogSeconds` (8s) watchdog even while the
    /// underlying WORK TASK — which already holds this kept batch and is mid-write, or
    /// (the deterministic case a short poll watchdog exposes) hasn't even reached this
    /// checkpoint yet — is still running (`runPollCycle`'s `.timedOut` arm releases the
    /// slot without cancelling a post-fetch-consumed cycle; see that arm's own comment).
    /// Previously, if the rebuild's forced flush then found no further changes and
    /// returned WITHOUT joining that still-running work task's own completion, the
    /// marker would clear and the rebuild would read the database (or a routine cycle
    /// still in flight would find the KEEP window already closed) before the real write
    /// landed, not after.
    ///
    /// `pollBlockChangesNowForDatabaseRebuild()` (`BlockSyncService+DatabaseRebuild.swift`)
    /// now closes this by calling `awaitWriterSettlementForRebuild()` after
    /// `pollBlockChangesNow()` returns and before its `defer` clears the marker: that
    /// waits on the WRITER's own internal state
    /// (`DocumentWriter.awaitSettled(through:timeout:)`, bounded by this cycle's own
    /// watchdog), READ-ONLY, rather than on the poll cycle's Task, so it keeps waiting
    /// for a stuck predecessor's REAL apply to land — kept-batch-mid-write or
    /// not-yet-fetched-at-all — even after the poll-level drain above has already
    /// returned early. Bounded, not unconditional: addendum A2 §1 replaced the earlier
    /// `drainWriterSettlement()` (backed by `DocumentWriter.drain(timeout:)`, which used
    /// to skip/drop a predecessor still stuck past the bound) with this read-only wait,
    /// which changes NOTHING on its own timeout — no skip, no drop, no ledger change, no
    /// frontier move. NARROWED, NOT CLOSED: the residual this guards against is now a
    /// late batch that meets the generation guard's check after this wait's own bound has
    /// already been reached — still possible, but now COUNTED (this wait's own
    /// `alwaysPersisted` log line and `testAwaitSettledTimeoutCount` on the writer, plus
    /// `BlockSyncService.testRebuildProceededUnsettledCount`) rather than silently forced
    /// into a skip or drop that never happened here in the first place. This fix is
    /// specific to the rebuild wrapper; a forced flush that calls `pollBlockChangesNow()`
    /// directly (not through the rebuild path) is not covered and remains subject to the
    /// general L8/L10 residuals described elsewhere in this file.
    ///
    /// `alreadyKeptForRebuild` (`inout`): postFetch and postTurnWait both pass
    /// `allowDatabaseRebuildKeep: true` and, when nothing moves the generation between
    /// them, both independently find the SAME keep condition true against the SAME
    /// unchanged snapshot -- unlike an abandon, which returns immediately and so can only
    /// ever fire at one checkpoint, a keep does not return, so a naive per-call log/count
    /// would double-count one rescued save as two. The caller (`doPollBlockChanges`)
    /// declares this flag fresh (`false`) once per cycle and threads the SAME instance
    /// through every call site in that cycle, so the log/count below fires only at
    /// whichever checkpoint reaches the condition first.
    private func checkGenerationGuard(
        generationAtPoll: Int, wasWiredAtPoll: Bool, stage: String, force: Bool,
        allowDatabaseRebuildKeep: Bool, alreadyKeptForRebuild: inout Bool
    ) -> Bool {
        guard Self.shouldAbandonForGenerationChange(
            currentGeneration: editorState?.contentGeneration,
            generationAtPollStart: generationAtPoll,
            wasWiredAtPollStart: wasWiredAtPoll
        ) else { return false }
        if allowDatabaseRebuildKeep, Self.shouldKeepBatchForDatabaseRebuild(
            currentGeneration: editorState?.contentGeneration,
            generationAtPollStart: generationAtPoll,
            rebuildGeneration: databaseRebuildGeneration
        ) {
            // `alreadyKeptForRebuild` is one flag, scoped to and owned by THIS cycle's
            // `doPollBlockChanges` call (see its declaration there): postFetch and
            // postTurnWait both call this on the SAME unchanged snapshot whenever
            // nothing moves the generation between them, so both independently find
            // this condition true. That is one save rescued from discard, not two --
            // log and count it once, at whichever checkpoint reaches it first.
            if !alreadyKeptForRebuild {
                alreadyKeptForRebuild = true
                DebugLog.alwaysPersisted(
                    "[SYNC-DIAG:BlockPoll] KEPT: reason=databaseRebuildPending stage=\(stage) " +
                    "generationAtPoll=\(generationAtPoll) current=\(String(describing: editorState?.contentGeneration))"
                )
                #if DEBUG
                testRebuildKeptBatchCount += 1
                #endif
            }
            return false
        }
        DebugLog.alwaysPersisted(
            "[SYNC-DIAG:BlockPoll] REJECTED: reason=generationChangedMidFlight stage=\(stage) " +
            "generationAtPoll=\(generationAtPoll) wasWired=\(wasWiredAtPoll) " +
            "current=\(String(describing: editorState?.contentGeneration)) force=\(force)"
        )
        #if DEBUG
        testGenerationAbandonCount += 1
        #endif
        return true
    }

    /// Poll-path (plus `fetchContentFromWebView`) `evaluateJavaScript`, funneled
    /// through one seam so a test can script replies (including a one-shot wedge)
    /// without a real WKWebView.
    ///
    /// Five call sites route through here — the four poll-cycle calls
    /// (`checkForChanges`, `getBlockChanges`, `flushPendingJSChanges`,
    /// `confirmBlockIds`) plus `fetchContentFromWebView`, included (t-027c3835) so a
    /// test can wedge it the same way (`BlockSyncFetchContentTimeoutTests`). The
    /// remaining push-side calls (`pushBlockIds`, `setContentWithBlockIds`,
    /// `updateHeadingLevels`) still do NOT route through here: they are not part of
    /// the poll cycle the watchdog bounds (nor of `fetchContentFromWebView`'s own
    /// timeout), and routing them would widen the seam past what the tests need.
    ///
    /// Internal (it was private) so `releaseHeldTypingPushes` in BlockSyncService+Lifecycle.swift goes through the same seam.
    func evaluateJS(_ script: String, in webView: WKWebView) async throws -> Any? {
        #if DEBUG
        testJSWebViewObserver?(webView)
        if let testJSEvaluator { return try await testJSEvaluator(script) }
        #endif
        return try await webView.evaluateJavaScript(script)
    }

    /// Check if the editor has pending block changes
    private func checkForChanges(webView: WKWebView) async -> Bool {
        do {
            let result = try await evaluateJS("window.FinalFinal.hasBlockChanges()", in: webView)
            hasLoggedCheckForChangesFailure = false
            return result as? Bool ?? false
        } catch {
            // A8: log only the FIRST failure after a success. `.blockPoll` is enabled
            // by default, so against a broken/wedged WebView this line used to fire
            // every 2s and drown the log; one line per failure streak is enough.
            if !hasLoggedCheckForChangesFailure {
                hasLoggedCheckForChangesFailure = true
                DebugLog.log(
                    .blockPoll,
                    "[SYNC-DIAG:BlockPoll] hasBlockChanges() call failed: \(error) — treating as \"no changes\""
                )
            }
            return false
        }
    }

    /// Outcome of a `getBlockChanges` call. Distinguishes a genuine "nothing to fetch"
    /// (the JS call itself never completed, or returned no usable string/data --
    /// lossless, since the JS-side queues were never cleared) from a decode failure
    /// AFTER the JS side already consumed the batch (item 7): the caller must count
    /// the latter as a real loss rather than settle it as the uncounted `.noBatch`.
    private enum GetBlockChangesResult {
        case success(BlockChanges)
        case noData
        case decodeFailed
    }

    /// Get block changes from the editor
    private func getBlockChanges(webView: WKWebView) async -> GetBlockChangesResult {
        // Phase 5 job B2: with reporting on, the script also returns the number of the `drain` report this drain posted (the same
        // drain, the same batch; `BlockChanges` decoding ignores the two extra keys). `FF_UI_TESTING_LEGACY_POLL=1` runs the old script.
        guard let jsonString = try? await evaluateJS(ReportIntake.pollFetchScript, in: webView) as? String,
              let data = jsonString.data(using: .utf8) else {
            return .noData
        }
        do {
            let changes = try JSONDecoder().decode(BlockChanges.self, from: data)
            compareWithReports(changes, replyData: data)
            return .success(changes)
        } catch {
            DebugLog.log(.sync, "[BlockSyncService] Failed to decode block changes: \(error)")
            return .decodeFailed
        }
    }

    /// Phase 5 job B2: hands the fetched batch to the shadow-report comparison (`ReportIntake`). Synchronous, read-only: it changes
    /// nothing the poll does with the batch.
    private func compareWithReports(_ changes: BlockChanges, replyData: Data) {
        guard let window = try? JSONDecoder().decode(ReportIntake.PollWindow.self, from: replyData),
              let through = window.reportThrough, let session = window.reportSession else { return }
        reportIntake.compare(drained: changes, through: through, session: session, idMap: writer?.tempIdMapSnapshot() ?? [:])
    }

    /// Retries a deferred `blockWriteEpoch` bump, reads the current write epoch, and
    /// reserves this cycle's turn on the writer -- immediately before
    /// `doPollBlockChanges` calls `getBlockChanges()`. MUST stay synchronous and
    /// non-throwing (no `await`, no `throws`): it is part of the "no
    /// cancellation-OBSERVING await between here and `applyAndConfirm`" invariant
    /// documented at `doPollBlockChanges`'s fetch-boundary comment. `writer.reserve()`
    /// is itself synchronous (nonisolated, Mutex-guarded), so sequence order still
    /// equals fetch order with no `await` in between, exactly as the old chain install
    /// guaranteed.
    ///
    /// Internal (was private) in Phase 4a so `BlockSyncService+Markdown.swift` reuses this body rather than duplicating
    /// it: the Markdown entry reserves its turn exactly as the poll does (epoch-bump retry, epoch read, `reserve()`).
    func reserveWriterTurn(database: ProjectDatabase, projectId: String) -> (WriterTicket, BlockWriteStamp)? {
        // A `configure`/`reconfigure` epoch bump that FAILED is retried here, on THIS
        // cycle's own `database`/`projectId`, before the epoch is read below - otherwise
        // this session's low sequences would be measured against the previous
        // session's persisted row stamps and silently drop real edits (see
        // `needsEpochBump`). If the retry fails too, return WITHOUT fetching - lossless,
        // because nothing has been consumed JS-side yet, so the batch stays queued and is
        // re-offered next tick. Logged unconditionally every time, since a persistently
        // failing bump means nothing is being written.
        if needsEpochBump {
            do {
                _ = try database.bumpBlockWriteEpoch(projectId: projectId)
                needsEpochBump = false
            } catch {
                DebugLog.alwaysPersisted(
                    "[BlockSync] write-stamp: retry of the deferred blockWriteEpoch bump failed (\(error)) - "
                    + "deferring this poll BEFORE the fetch; the batch stays queued JS-side")
                return nil
            }
        }
        guard let writer else { return nil }
        let myWriteEpoch: Int64
        do {
            myWriteEpoch = try database.currentBlockWriteEpoch(projectId: projectId)
        } catch {
            DebugLog.alwaysPersisted(
                "[BlockSync] write-stamp: could not read blockWriteEpoch (\(error)) - "
                + "abandoning this poll BEFORE the fetch; the batch stays queued JS-side")
            return nil
        }
        let ticket = writer.reserve()
        let stamp = BlockWriteStamp(epoch: myWriteEpoch, sequence: Int64(clamping: ticket.seq))
        return (ticket, stamp)
    }

    /// Applies `changes` through the writer (an actor hop plus a synchronous DB
    /// write, serialized against every other sequence -- see
    /// `DocumentWriter.applyEditorBatch`), then confirms whatever temp->permanent id
    /// mapping THIS write produced back to the editor. Known gap (not closed this
    /// phase): a held op the writer cascades onto a LATER mint, inside the same actor
    /// turn, produces its own idMapping entries that are merged into the writer's
    /// `tempIdMap` but not currently surfaced back out to this caller, so a cascaded
    /// confirmation does not yet reach `confirmBlockIds`. Tracked for a follow-up
    /// pass, not silently accepted.
    private func applyAndConfirm(
        _ ticket: WriterTicket, _ changes: BlockChanges, webView: WKWebView, stamp: BlockWriteStamp
    ) async {
        let outcome = await ticket.writer.applyEditorBatch(ticket.seq, changes, stamp: stamp)
        switch outcome {
        case .applied(let result):
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Applied changes to DB successfully")
            if !result.idMapping.isEmpty {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Confirming \(result.idMapping.count) IDs")
                await confirmBlockIds(webView: webView, mapping: result.idMapping)
            }
        case .refused(let reason):
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] writer refused seq \(ticket.seq): \(reason)")
            // `.skipped` is already logged and counted by the `skip()` call that
            // produced it (its phase entry is already gone, so the caller's `defer`
            // settle is a no-op). `.outOfTurn` is different: the phase entry is still
            // open here (`applyEditorBatch`'s admission check never removes it on this
            // path), so without this the caller's `defer { ticket.settleIfOpen(.noBatch) }`
            // would settle it uncounted. Give it its own counted outcome (item 7,
            // plan's S6 settlement rule).
            if reason == .outOfTurn {
                ticket.settleIfOpen(.discarded(.outOfTurn))
            }
        case .failed(let error):
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Error applying changes: \(error)")
        }
    }

    #if DEBUG
    /// Test-only escape hatch for W32 (`DocumentWriterSystemWriteTests`): lets a test
    /// force `.nested` by calling `performSystemWrite` from inside
    /// `SystemWriteScope.$active.withValue(true)` without tripping the DEBUG
    /// `assertionFailure` that would otherwise crash the test process.
    var testSuppressNestedAssert = false

    /// Test-only (review fix M24): bumped by EVERY `reportLifecycleWholeDocumentLost` call,
    /// including the no-writer branch that only logs -- the writer's own
    /// `lifecycleWholeDocumentLost` ledger counter cannot show a report that had no writer to
    /// count on (and `testWriterLedger` is all-zero then), so an assertion on the ledger alone
    /// cannot tell "reported, no writer" from "never reported".
    var testLifecycleLossReports = 0
    #endif

    /// Phase 2 (t-94369a83), §1.1: the ONE public entry point for a non-editor
    /// (bibliography/Notes/heading-level) write, routed through the same ordered
    /// queue `DocumentWriter` already serializes every editor-diff write through. See
    /// `docs/architecture/document-writer.md`'s "System writes" section for the full
    /// design (settlement, the I-SYS backstop, why system writes do not stamp rows -- bar the
    /// one exception, `.lifecycleWholeDocument`, which bumps and restamps the epoch).
    ///
    /// Steps, in order (the only suspensions are `waitForTurn` and the actor hop):
    /// 1. Nesting check (`SystemWriteScope.active`, `SystemWriteScope.heldEditorSeq`).
    /// 2. `stillWanted()` -- refuses `.notWanted` WITHOUT reserving.
    /// 3. Writer/identity checks -- `.noWriter`/`.identityMismatch`, no reservation.
    /// 4. Reserve (`SystemReservation(writer.reserveSystem())`).
    /// 5. Run `prepare?()` synchronously; record `prepareRan`.
    /// 6. Wait for turn -- a skip settles via the writer itself; reads back the real
    ///    reason from `systemSkipReason`.
    /// 7. Re-check `stillWanted()` -- ONLY when `prepare == nil` (once `prepare` has
    ///    run, e.g. posted a `.renumberFootnotes`, there is no safe way to "un-notify"
    ///    the editor, so the write must proceed and let the caller's OWN recovery
    ///    table decide what to do with a stale result).
    /// 8. Apply.
    ///
    /// Phase 3a-1a (t-94369a83, coder-obligations item 15): a `.lifecycleWholeDocument` write
    /// whose outcome is anything but `.applied` is reported as a LOSS through
    /// `reportLifecycleWholeDocumentLost`, from this single choke point so every refusal and
    /// failure path (nested, identity mismatch, skipped, out of turn, retired, failed) is
    /// covered by the one hook. The exception (judge adjustment B6) is `.refused(.noWriter)`:
    /// that is the direct-write fallback plan §2.3 gives the caller, not a loss, so it is only
    /// logged. Every other `kind` is untouched by the hook. The loss is counted on the writer
    /// captured at entry (review fix M18), not on whatever `writer` has become by the time the
    /// outcome is known; the counter overlays an ordinary one -- see `LossLedger.lifecycleWholeDocumentLost`.
    ///
    /// Phase 3a-1b (C3b): `onReserved` (default nil) runs synchronously right after step 4's reservation,
    /// in the same MainActor turn, before the first suspension. The lifecycle save sequence uses it to know
    /// that FB holds its place in the queue BEFORE it enqueues the writer barrier (N9): a barrier enqueued
    /// first would park FB behind itself.
    @MainActor
    func performSystemWrite<R: Sendable>(
        identity: SystemWriteIdentity,
        kind: SystemWriteKind,
        stillWanted: @escaping () -> Bool,
        prepare: (() -> Void)? = nil,
        onReserved: (() -> Void)? = nil,
        body: @escaping @Sendable (Database) throws -> SystemWriteBody<R>
    ) async -> SystemWriteResult<R> {
        await performSystemWrite(
            identity: identity, kind: kind, stillWanted: stillWanted, prepare: prepare,
            onReserved: onReserved) { db, _ in try body(db) }
    }

    /// The same eight steps and the same loss hook as the overload above, for a body that needs the writer's
    /// temp-id map (t-94369a83 Phase 4b, slice 2a: `SystemWriteKind.sectionDelete`). The body receives a copy
    /// of `DocumentWriter`'s temp-id -> permanent-id map taken at admission, after step 8's turn check said
    /// proceed (see `DocumentWriter.applySystemWrite`'s `(Database, IdMap)` overload). Every existing caller
    /// keeps the one-argument body and is unchanged; the one-argument overload above forwards here with
    /// a body that ignores the map.
    @MainActor
    func performSystemWrite<R: Sendable>(
        identity: SystemWriteIdentity,
        kind: SystemWriteKind,
        stillWanted: @escaping () -> Bool,
        prepare: (() -> Void)? = nil,
        onReserved: (() -> Void)? = nil,
        body: @escaping @Sendable (Database, IdMap) throws -> SystemWriteBody<R>
    ) async -> SystemWriteResult<R> {
        // Review fix M18: the writer THIS call used is the one in place at entry (the steps below
        // read it before their first suspension). `configure`/`reconfigure` can replace
        // `self.writer` on the MainActor while this call is suspended (a close/switch race), so
        // the loss must be counted on the entry writer, not re-read after the await.
        let writerAtEntry = writer
        let result = await performSystemWriteSteps(
            identity: identity, kind: kind, stillWanted: stillWanted, prepare: prepare,
            onReserved: onReserved, body: body)
        if kind == .lifecycleWholeDocument {
            noteLifecycleWholeDocumentOutcome(result.outcome, writerAtEntry: writerAtEntry)
        }
        return result
    }

    /// Classifies a `.lifecycleWholeDocument` outcome for `performSystemWrite`'s loss hook (see
    /// its doc comment): `.applied` is not a loss, `.refused(.noWriter)` is the caller's
    /// direct-write fallback (B6, logged at `.lifecycle`, never counted), everything else is.
    private func noteLifecycleWholeDocumentOutcome<R: Sendable>(
        _ outcome: SystemWriteOutcome<R>, writerAtEntry: DocumentWriter?
    ) {
        switch outcome {
        case .applied:
            break
        case .refused(.noWriter):
            DebugLog.log(.lifecycle, "[SystemWrite] lifecycleWholeDocument: no writer -- not a loss, the caller's direct write is the fallback")
        case .refused(let reason):
            reportLifecycleWholeDocumentLost(reason: "refused(\(reason))", on: writerAtEntry)
        case .failed(let error):
            reportLifecycleWholeDocumentLost(reason: "failed(\(error))", on: writerAtEntry)
        }
    }

    /// Counts and logs a `.lifecycleWholeDocument` write that did not happen, on this service's
    /// writer (`DocumentWriter.noteLifecycleWholeDocumentLost`). Internal rather than private so
    /// `performLifecycleWholeDocumentWrite` (LifecycleWholeDocumentWrite.swift) can report its
    /// own pre-reservation refusal through the SAME hook -- `writer` is private to this file.
    /// With no writer there is no ledger to count on, so the loss is only logged
    /// (`alwaysPersisted`).
    func reportLifecycleWholeDocumentLost(reason: String) {
        reportLifecycleWholeDocumentLost(reason: reason, on: writer)
    }

    /// The same report, counted on an explicit `writer` (review fix M18): `performSystemWrite`
    /// passes the writer it captured at entry, so a loss observed after the await lands on the
    /// writer the write actually used -- not on whatever `self.writer` has become since (a
    /// replacement project's). Counts on `writer` when it is non-nil (even if that writer is
    /// retired by now); only when it is nil is there nothing to count on and the loss is just
    /// logged. Bumps `testLifecycleLossReports` either way.
    func reportLifecycleWholeDocumentLost(reason: String, on writer: DocumentWriter?) {
        #if DEBUG
        testLifecycleLossReports += 1
        #endif
        guard let writer else {
            DebugLog.alwaysPersisted("[SystemWrite] lifecycle whole-document write LOST (no writer to count it on): \(reason)")
            return
        }
        writer.noteLifecycleWholeDocumentLost(reason: reason)
    }

    /// The eight documented steps of `performSystemWrite` (see its doc comment), unchanged by
    /// Phase 3a-1a: split out so the wrapper above can classify the outcome of EVERY return path
    /// -- including the early refusals -- in one place.
    @MainActor
    private func performSystemWriteSteps<R: Sendable>(
        identity: SystemWriteIdentity,
        kind: SystemWriteKind,
        stillWanted: @escaping () -> Bool,
        prepare: (() -> Void)? = nil,
        onReserved: (() -> Void)? = nil,
        body: @escaping @Sendable (Database, IdMap) throws -> SystemWriteBody<R>
    ) async -> SystemWriteResult<R> {
        // Step 1: nesting.
        if SystemWriteScope.active {
            return SystemWriteResult(outcome: .refused(.nested), prepareRan: false)
        }
        if let heldSeq = SystemWriteScope.heldEditorSeq, let writer, writer.isOpen(heldSeq) {
            #if DEBUG
            if !testSuppressNestedAssert {
                assertionFailure("[SystemWrite] performSystemWrite called while editor seq \(heldSeq) is still open")
            }
            #endif
            DebugLog.alwaysPersisted("[SystemWrite] refused .nested -- editor seq \(heldSeq) still open")
            return SystemWriteResult(outcome: .refused(.nested), prepareRan: false)
        }

        // Step 2: wanted, pre-reserve.
        guard stillWanted() else {
            return SystemWriteResult(outcome: .refused(.notWanted), prepareRan: false)
        }

        // Step 3: writer + identity.
        guard let writer else {
            // Fallback (§2.0): the caller runs the write directly against its OWN
            // captured identity. Every Phase 2 caller now implements this fallback --
            // `BibliographySyncService`/`FootnoteSyncService` each have a direct-write
            // path for every `.refused(.noWriter)` outcome (defensive only: should not
            // happen once `configureSyncServices` wires a writer, but exercised
            // deliberately by `DocumentWriterSystemWriteTests`). `.noWriter` still
            // counts as a real refusal outcome; the fallback write itself is the
            // CALLER's responsibility, never this function's.
            DebugLog.log(.sync, "[SystemWrite] no writer - direct write is the caller's responsibility")
            return SystemWriteResult(outcome: .refused(.noWriter), prepareRan: false)
        }
        guard identity.database === writer.database, identity.projectId == writer.projectId else {
            return SystemWriteResult(outcome: .refused(.identityMismatch), prepareRan: false)
        }

        // Step 4: reserve.
        // §2.8: EditorViewState's contentStateWatchdog waits this out rather than
        // force-resetting contentState mid-write -- incremented here (reserve) and
        // decremented via `defer` on every exit from this point on (steps 6-8),
        // spanning the whole reserve-through-apply window.
        //
        // Review fix (finding #13): `editorState` is a `weak var` -- reading it twice
        // (once to increment, once via `defer` to decrement) risked the two reads
        // resolving to DIFFERENT instances if `self.editorState` were reassigned (or
        // deallocated) in between, permanently stranding the first instance's counter
        // incremented and never reflecting the increment on the new one. Captured ONCE
        // into a local so both operations always target the exact same instance.
        let systemWriteEditorState = editorState
        systemWriteEditorState?.systemWriteInFlight += 1
        defer { systemWriteEditorState?.systemWriteInFlight -= 1 }
        let reservation = SystemReservation(writer.reserveSystem())
        onReserved?()   // Phase 3a-1b (C3b): see `performSystemWrite`'s doc comment

        // Steps 5-8, all wrapped in ONE `SystemWriteScope.active` window. Review fix
        // (finding #11): the doc comment on `SystemWriteScope.active`
        // (DocumentWriter+SystemWrite.swift) has always described this as covering
        // "performSystemWrite's own steps 6-8 (wait through apply)", but the code only
        // ever wrapped step 6 (`waitForTurnAsync`) -- `prepare` (step 5) and `apply`
        // (step 8) both ran OUTSIDE it, so a system write started synchronously from
        // inside `prepare` (e.g. a `.renumberFootnotes` notification observer) or from
        // inside the `body` closure passed to `applySystemWrite` would NOT have been
        // caught by the `.nested` guard. Widened to genuinely cover prepare through
        // apply, matching the documented invariant.
        let (outcome, prepareRan) = await SystemWriteScope.$active.withValue(true) { () async -> (SystemWriteOutcome<R>, Bool) in
            // Step 5: prepare.
            prepare?()
            let prepareRan = prepare != nil

            // Step 6: wait. (Round M2: the `md-speed systemWrite.<kind>.waitForTurn` and `.apply` spans; the main thread is free in both.)
            let waitSpan = MdSpeed.span("systemWrite.\(kind).waitForTurn")
            let turnResult = await reservation.ticket.writer.waitForTurnAsync(reservation.ticket.seq)
            waitSpan.end()
            if turnResult == .skipped {
                let reason = reservation.ticket.writer.systemSkipReason(reservation.ticket.seq) ?? .writerReplaced
                // `systemSkipReason` only peeks (see its doc comment) -- this call is
                // what actually retires the entry now that its value has been consumed,
                // so `skipReasons` doesn't grow unboundedly for this (the common) path.
                reservation.ticket.writer.discardSystemSkipReason(reservation.ticket.seq)
                reservation.consume()
                return (.refused(.skipped(reason)), prepareRan)
            }

            // Step 7: re-check, only when prepare was never supplied.
            if prepare == nil, !stillWanted() {
                reservation.ticket.writer.settleSystemNotWanted(reservation.ticket.seq)
                reservation.consume()
                return (.refused(.notWanted), prepareRan)
            }

            // Step 8: apply.
            let applySpan = MdSpeed.span("systemWrite.\(kind).apply")   // hop to the writer actor, the database write, the hop back
            let outcome = await reservation.ticket.writer.applySystemWrite(
                reservation.ticket.seq, kind: kind, identity: identity, body: body)
            applySpan.end()
            switch outcome {
            case .applied, .failed:
                // The writer itself already removed the phase entry on both these paths.
                reservation.consume()
            case .refused:
                // Out-of-turn or retired: `applySystemWrite` deliberately does NOT settle
                // this (mirroring `applyEditorBatch`'s own unsettled out-of-turn refusal)
                // -- `reservation`'s `deinit` is the safety net that settles it.
                break
            }
            return (outcome, prepareRan)
        }
        return SystemWriteResult(outcome: outcome, prepareRan: prepareRan)
    }

    // MARK: - A system write reserved in the caller's own synchronous stretch (t-18b7fa48 Phase 4b slice 3, round 3c)

    /// Steps 1 to 4 of `performSystemWrite`, and nothing else, as ONE synchronous call: the nesting check, the writer and identity
    /// checks, and the reservation. It never suspends, so a caller that is itself in a synchronous stretch (the editor-first slow
    /// undo's click reply, requirement R3+) holds its place in the queue before any other main-actor turn can run. `stillWanted` is
    /// not part of it (the one caller's is always true), and there is no `prepare`.
    ///
    /// Returns the handle, or the reason the write was refused before it reserved anything (the same reasons `performSystemWrite`
    /// answers at these steps). A handle MUST be given to `runReservedSystemWrite` (it brings `systemWriteInFlight` down); the
    /// existing `performSystemWrite` is unchanged and still the only way every other kind of write runs.
    @MainActor
    func reserveSystemWriteNow(identity: SystemWriteIdentity) -> SystemWriteReservationResult {
        // Step 1: nesting.
        if SystemWriteScope.active { return .refused(.nested) }
        if let heldSeq = SystemWriteScope.heldEditorSeq, let writer, writer.isOpen(heldSeq) { return .refused(.nested) }
        // Step 3: writer + identity.
        guard let writer else { return .refused(.noWriter) }
        guard identity.database === writer.database, identity.projectId == writer.projectId else {
            return .refused(.identityMismatch)
        }
        // Step 4: reserve (and §2.8: the content-state watchdog waits this write out; the count comes down in `runReservedSystemWrite`).
        let systemWriteEditorState = editorState
        systemWriteEditorState?.systemWriteInFlight += 1
        return .held(ReservedSystemWrite(reservation: SystemReservation(writer.reserveSystem()), editorState: systemWriteEditorState))
    }

    /// Steps 6 and 8 of `performSystemWrite` for a write `reserveSystemWriteNow` reserved: wait for the turn, then apply, inside the
    /// same `SystemWriteScope.active` window. (Step 5, `prepare`, and step 7, the re-check, are absent: there is no `prepare`, and
    /// `stillWanted` is always true.) The outcome handling is the existing code's, line for line.
    @MainActor
    func runReservedSystemWrite<R: Sendable>(
        _ reserved: ReservedSystemWrite,
        kind: SystemWriteKind,
        identity: SystemWriteIdentity,
        body: @escaping @Sendable (Database, IdMap) throws -> SystemWriteBody<R>
    ) async -> SystemWriteResult<R> {
        defer { reserved.editorState?.systemWriteInFlight -= 1 }
        let reservation = reserved.reservation
        let outcome = await SystemWriteScope.$active.withValue(true) { () async -> SystemWriteOutcome<R> in
            // Step 6: wait.
            let turnResult = await reservation.ticket.writer.waitForTurnAsync(reservation.ticket.seq)
            if turnResult == .skipped {
                let reason = reservation.ticket.writer.systemSkipReason(reservation.ticket.seq) ?? .writerReplaced
                reservation.ticket.writer.discardSystemSkipReason(reservation.ticket.seq)
                reservation.consume()
                return .refused(.skipped(reason))
            }
            // Step 8: apply.
            let outcome = await reservation.ticket.writer.applySystemWrite(
                reservation.ticket.seq, kind: kind, identity: identity, body: body)
            switch outcome {
            case .applied, .failed:
                reservation.consume()
            case .refused:
                break   // out-of-turn or retired: `reservation`'s `deinit` settles it, as in `performSystemWrite`
            }
            return outcome
        }
        return SystemWriteResult(outcome: outcome, prepareRan: false)
    }

    /// Send ID confirmations back to the editor
    private func confirmBlockIds(webView: WKWebView, mapping: [String: String]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let escaped = jsonString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        _ = try? await evaluateJS(
            "window.FinalFinal.confirmBlockIds(JSON.parse(`\(escaped)`)); true",
            in: webView
        )
    }

    // MARK: - Initial Parse

    /// Parse markdown content into blocks and store in database
    /// Called when loading a project or switching from section-based to block-based
    func parseAndStoreBlocks(markdown: String, preservingMetadata: [String: SectionMetadata]? = nil) async throws {
        guard let database = projectDatabase, let projectId else {
            throw SyncConfigurationError.notConfigured
        }

        // C5: threads the DB-resolved Notes title -- called when loading a project or switching
        // from section-based to block-based, so an already-recognized Notes heading (from a
        // prior migration/import) is threaded through explicitly rather than defaulted.
        let blocks = BlockParser.parse(
            markdown: markdown,
            projectId: projectId,
            existingSectionMetadata: preservingMetadata,
            notesHeaderName: try? database.fetchNotesHeadingTitle(projectId: projectId)
        )

        try database.replaceBlocks(blocks, for: projectId)

        DebugLog.log(.sync, "[BlockSyncService] Parsed and stored \(blocks.count) blocks")
    }

    /// Assemble markdown from blocks in the database
    func assembleMarkdown() throws -> String {
        guard let database = projectDatabase, let projectId else {
            throw SyncConfigurationError.notConfigured
        }

        let blocks = try database.fetchBlocks(projectId: projectId)
        return BlockParser.assembleMarkdown(from: blocks)
    }

    // MARK: - Errors

    enum SyncConfigurationError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "BlockSyncService not configured"
            }
        }
    }
}

// MARK: - Editor Push / Heading Updates
//
// Split out of the main class body to keep it under SwiftLint's type_body_length
// limit. `private` is file-scoped in Swift, so `projectDatabase`, `projectId`, and
// `webView` stay `private` on the class and are still readable here — no
// access-level widening.
@MainActor
extension BlockSyncService {
    // MARK: - Push Block IDs to Editor

    /// Push block IDs from DB to JS editor (aligns temp IDs with real UUIDs)
    /// - Parameter range: Optional sort order range to filter blocks (for zoom state).
    ///   When nil, pushes all block IDs.
    func pushBlockIds(for range: (start: Double, end: Double?)? = nil) async {
        guard let database = projectDatabase, let projectId, let webView else { return }

        do {
            let blocks = try database.fetchBlocks(projectId: projectId)
            let filtered: [Block]
            if let range = range {
                if let end = range.end {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography && !$0.isNotes && $0.sortOrder < end }
                } else {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography && !$0.isNotes }
                }
            } else {
                filtered = blocks
            }
            let pairs = BlockParser.alignmentPairs(filtered.sorted { $0.sortOrder < $1.sortOrder })
            let orderedIds = pairs.map { $0.id }
            let expectedBlocks = pairs.map { $0.meta }

            if let range = range {
                DebugLog.log(.sync, "[BlockSyncService] pushBlockIds filtered: \(orderedIds.count) blocks " +
                    "(range start=\(range.start), end=\(String(describing: range.end)))")
            }

            #if DEBUG
            if let testPushBlockIdsHook {
                await testPushBlockIdsHook(orderedIds)
                return
            }
            #endif

            guard let jsonData = try? JSONSerialization.data(withJSONObject: orderedIds),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")

            guard let expectedData = try? JSONEncoder().encode(expectedBlocks),
                  let expectedJsonString = String(data: expectedData, encoding: .utf8) else { return }

            let escapedExpected = expectedJsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")

            let zoomMode = range != nil ? "true" : "false"
            _ = try? await webView.evaluateJavaScript(
                "window.FinalFinal.syncBlockIds(JSON.parse(`\(escaped)`), \(zoomMode), JSON.parse(`\(escapedExpected)`)); true"
            )

            DebugLog.log(.sync, "[BlockSyncService] Pushed \(orderedIds.count) block IDs to editor")
        } catch {
            DebugLog.log(.sync, "[BlockSyncService] pushBlockIds failed: \(error)")
        }
    }

    /// Set content AND block IDs atomically (for initial load, zoom, rebuild)
    ///
    /// Returns the ACTUAL merged markdown pushed to the editor when `preserveUserBlocks` is
    /// true (t-6a0d195d) -- `nil` for every other call, matching today's void-equivalent
    /// behavior. `@discardableResult` because most callers (every pre-existing one) still don't
    /// use the return value.
    @discardableResult
    func setContentWithBlockIds(
        markdown: String,
        blockIds: [String],
        scrollToStart: Bool = false,
        imageMeta: [ContentView.ImageBlockMeta] = [],
        cursorBoundary: Int? = nil,
        /// Node index one PAST the last bibliography block — companion end bound for
        /// `cursorBoundary` so the JS-side clamp only fires for a cursor actually INSIDE the
        /// bibliography section, not merely at-or-after its start. See
        /// `BlockParser.lastBibliographyNodeIndex`'s doc comment.
        cursorBoundaryEnd: Int? = nil,
        detectPausedEdits: Bool = false,
        expectedBlocks: [BlockParser.BlockAlignmentMeta] = [],
        /// Ids of blocks flagged `isBibliography`/`isNotes` (Block.swift) in THIS push --
        /// threaded to the JS side as `managedBlockIds` so block-id-plugin.ts can stamp
        /// `data-managed` on those headings, which styles.css's ⌘-hover heading-zoom hint
        /// excludes (bug: that hint used to show unconditionally on Bibliography/Notes, since
        /// the CSS's old `.auto-bib-marker` exclusion never fired on this WYSIWYG push path).
        /// Defaults to empty, matching every pre-existing call site (and the zoomed-body push,
        /// which already excludes bibliography/Notes blocks before reaching here) unaffected.
        managedBlockIds: Set<String> = [],
        zoomMode: Bool = false,
        /// Zoom-out: land on this block, in the restored document's own coordinate space,
        /// instead of re-applying the zoomed view's captured scroll position (which lands at
        /// the document's actual top — a coordinate-space mismatch). See the matching option
        /// on the JS side, web/milkdown/src/api-content.ts's setContentWithBlockIds. Resolved
        /// and applied synchronously, in-push, during this same content replace. Unrelated to,
        /// and NOT the same mechanism as, `EditorViewState.scrollToBlockId` (EditorViewState.swift)
        /// -- that one is a deferred, smoothly-animated follow-up scroll consumed by
        /// MilkdownEditor's `@Binding`. The two happen to share a name; they do not share code.
        scrollToBlockId: String? = nil,
        /// t-6a0d195d: merge instead of replace -- every USER top-level block keeps its
        /// live-editor identity, and only the managed (bibliography/Notes) runs are taken from
        /// this push's content, so an edit typed in the window between the rebuild's DB read
        /// and this push landing survives instead of being silently overwritten. See
        /// `mergeManagedBlocks`'s doc comment (api-content.ts). Used ONLY by the three rebuild
        /// handlers in `ContentView+NotificationHandlers.swift` and `ContentView+FootnoteHandlers.swift`; every other call site omits it
        /// (defaults `false`), preserving today's whole-diff push byte-for-byte.
        preserveUserBlocks: Bool = false,
        /// Slice 0 measurement only (StructuralTrace.swift): which managed rebuild this push is. Set by the three rebuild
        /// handlers only. While tracing is on it times the push (`start`/`end <kind>-rebuild-push`, with the document size in
        /// characters) and is sent to the editor so it can name the rebuild when it drops a pending edit; while tracing is off
        /// it is ignored and the JS call is byte-for-byte what it was.
        traceKind: StructuralTrace.RebuildKind? = nil,
        /// Slice 2b (plan-v4-addendum 3): asked twice, synchronously, with no `await` between the question and the push: before the
        /// DEBUG hook and again right before `evaluateJavaScript`. False means a quick undo or redo has started since the caller read
        /// the database, so nothing is pushed and nil is returned (the caller's stale-rebuild tail reads the editor's own text).
        stillWanted: (() -> Bool)? = nil
    ) async -> String? {
        #if DEBUG
        // Test-only (t-94369a83 Phase 4b slice 2a): stands in for the JavaScript push, which has no `evaluateJS` seam.
        if let testSetContentHook {
            guard stillWanted?() ?? true else { return nil }
            testSetContentLastDetectPausedEdits = detectPausedEdits
            return await testSetContentHook(markdown, blockIds, managedBlockIds, preserveUserBlocks)
        }
        #endif
        guard let webView else { return nil }

        DebugLog.log(.sync, {
            let firstHeading = markdown.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("#") })?.prefix(60) ?? "(none)"
            return "[SYNC-DIAG:BlockSync] setContentWithBlockIds: len=\(markdown.count) "
                + "blocks=\(blockIds.count) firstH=\"\(firstHeading)\" "
                + "scrollToStart=\(scrollToStart) cursorBoundary=\(String(describing: cursorBoundary)) "
                + "scrollToBlockId=\(String(describing: scrollToBlockId))"
        }())

        // Escape markdown for JS template literal
        let escapedMarkdown = jsTemplateLiteralEscaped(markdown)

        guard let idsData = try? JSONSerialization.data(withJSONObject: blockIds),
              let idsJson = String(data: idsData, encoding: .utf8) else { return nil }

        let escapedIds = jsTemplateLiteralEscaped(idsJson)

        // Build options object
        var optionParts: [String] = []
        appendFlagOption(&optionParts, scrollToStart, "scrollToStart")
        if let imageMetaOption = imageMetaOptionString(imageMeta) {
            optionParts.append(imageMetaOption)
        }
        appendOption(&optionParts, cursorBoundary) { "cursorBoundary: \($0)" }
        appendOption(&optionParts, cursorBoundaryEnd) { "cursorBoundaryEnd: \($0)" }
        appendFlagOption(&optionParts, detectPausedEdits, "detectPausedEdits")
        appendOption(&optionParts, expectedOptionString(expectedBlocks)) { $0 }
        appendOption(&optionParts, managedBlockIdsOptionString(managedBlockIds)) { $0 }
        appendFlagOption(&optionParts, zoomMode, "zoomMode")
        appendOption(&optionParts, scrollToBlockId) { "scrollToBlockId: `\($0.escapedForJSTemplateLiteral)`" }
        appendFlagOption(&optionParts, preserveUserBlocks, "preserveUserBlocks")
        if let traceOption = StructuralTrace.traceKindOption(traceKind, tracingOn: StructuralTrace.isOn) {
            optionParts.append(traceOption)
        }
        let options = optionParts.isEmpty ? "" : ", {\(optionParts.joined(separator: ", "))}"
        let js = "window.FinalFinal.setContentWithBlockIds(`\(escapedMarkdown)`, JSON.parse(`\(escapedIds)`)\(options))"

        // Right before the push, in the same synchronous stretch (nothing suspends between this check and `evaluateJavaScript`).
        guard stillWanted?() ?? true else {
            DebugLog.log(.undo, "[BlockSyncService] setContentWithBlockIds: push skipped (stale: a quick undo or redo started since the read)")
            return nil
        }

        // Under preserveUserBlocks, the JS side returns the ACTUAL merged markdown it pushed
        // (which can differ from `markdown` -- the merge keeps in-flight user typing the DB
        // hadn't caught up with yet) -- evaluate without the `; true` suffix so that string
        // comes back as this call's result, instead of discarding it the way every other push
        // does. Every other caller keeps the `; true` result (a JS string is still returned by
        // evaluateJavaScript for that literal, but callers here have never read it).
        let tracedKind = StructuralTrace.isOn ? traceKind : nil
        let traceChars = tracedKind == nil ? 0 : markdown.utf16.count // counted once, and only while tracing
        let traceSpan = tracedKind.map { StructuralTrace.span("\($0.rawValue)-rebuild-push", "chars=\(traceChars)") }
        let evalResult = try? await webView.evaluateJavaScript(preserveUserBlocks ? js : "\(js); true")
        traceSpan?.end("chars=\(traceChars)")
        let mergedMarkdown = preserveUserBlocks ? (evalResult as? String) : nil

        // Round-3 review, parse-failure sentinel (bridge reviewer's finding A + judge's #22):
        // the JS side (setContentWithBlockIds's PRESERVE_USER_BLOCKS_PARSE_FAILURE_SENTINEL,
        // api-content.ts) returns this exact string when parser(markdown) threw or returned
        // falsy under preserveUserBlocks -- the document never actually changed. Must NOT post
        // .blockSyncDidPushContent (there is nothing new to tell the coordinator about) and
        // must NOT return it to the caller as if it were real merged content (every caller here
        // treats a non-nil return as "the editor now shows this text" and assigns it straight
        // into editorState.content). Returning nil, the same value every OTHER non-merging path
        // already returns, keeps that contract intact without callers needing their own
        // sentinel check.
        if mergedMarkdown == Self.preserveUserBlocksParseFailureSentinel {
            DebugLog.log(
                .sync,
                "[BlockSyncService] setContentWithBlockIds: preserveUserBlocks parse failed -- " +
                    "JS kept its own pending queue untouched, not posting blockSyncDidPushContent"
            )
            return nil
        }

        let pushedMarkdown = mergedMarkdown ?? markdown

        // Notify coordinator so it updates lastPushedContent (prevents redundant updateNSView push).
        // Posts the markdown actually pushed to the editor -- not always the same as the `markdown`
        // argument once preserveUserBlocks can return a merged value that differs from it.
        NotificationCenter.default.post(
            name: .blockSyncDidPushContent,
            object: nil,
            userInfo: ["markdown": pushedMarkdown]
        )

        DebugLog.log(.sync, "[BlockSyncService] Set content with \(blockIds.count) block IDs atomically")
        return mergedMarkdown
    }

    /// Must byte-for-byte match JS's `PRESERVE_USER_BLOCKS_PARSE_FAILURE_SENTINEL`
    /// (api-content.ts) -- see this function's parse-failure-sentinel handling, above.
    private static let preserveUserBlocksParseFailureSentinel = "\u{0}FF_PARSE_FAILED\u{0}"

    /// Appends a JS option-string entry (`"key: value"`) to `optionParts` iff `value` is
    /// non-nil, formatting it with `format`. Factored out of `setContentWithBlockIds`'s long
    /// chain of "if let X { optionParts.append(...) }" blocks to keep that function's branch
    /// count down — pure, no side effects beyond mutating the passed-in array.
    private func appendOption<T>(_ optionParts: inout [String], _ value: T?, format: (T) -> String) {
        if let value {
            optionParts.append(format(value))
        }
    }

    /// Appends a JS option-string boolean flag (`"key: true"`) to `optionParts` iff `flag`
    /// is true. Companion to `appendOption(_:_:format:)` for the simple boolean-flag cases.
    private func appendFlagOption(_ optionParts: inout [String], _ flag: Bool, _ key: String) {
        if flag {
            optionParts.append("\(key): true")
        }
    }

    /// Escapes `text` for embedding inside a JS template literal (`` `...` ``): backslash, backtick and `${`, nothing else.
    /// Deliberately NOT `String.escapedForJSTemplateLiteral` (StringExtensions.swift), which also turns CR and CRLF into LF and
    /// strips NUL -- using it here would change the script sent for any markdown containing those characters. Extracted from
    /// `setContentWithBlockIds` (four identical inline chains) to bring its cyclomatic complexity under the cap; pure.
    private func jsTemplateLiteralEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
    }

    /// Builds the `expected: JSON.parse(...)` JS option-string entry for `setContentWithBlockIds` -- `nil` when there are no
    /// expected blocks or JSON encoding failed, matching the no-op behavior of the nested `if` blocks this replaced. Pure.
    private func expectedOptionString(_ expectedBlocks: [BlockParser.BlockAlignmentMeta]) -> String? {
        guard !expectedBlocks.isEmpty,
              let expectedData = try? JSONEncoder().encode(expectedBlocks),
              let expectedJson = String(data: expectedData, encoding: .utf8) else { return nil }
        return "expected: JSON.parse(`\(jsTemplateLiteralEscaped(expectedJson))`)"
    }

    /// Builds the `managedBlockIds: JSON.parse(...)` JS option-string entry for `setContentWithBlockIds` -- `nil` when the set is
    /// empty or JSON encoding failed, matching the no-op behavior of the nested `if` blocks this replaced. Pure.
    private func managedBlockIdsOptionString(_ managedBlockIds: Set<String>) -> String? {
        guard !managedBlockIds.isEmpty,
              let managedData = try? JSONSerialization.data(withJSONObject: Array(managedBlockIds)),
              let managedJson = String(data: managedData, encoding: .utf8) else { return nil }
        return "managedBlockIds: JSON.parse(`\(jsTemplateLiteralEscaped(managedJson))`)"
    }

    /// Builds the `imageMeta: ...` JS option-string entry (same shape as `appendOption`'s
    /// callers, but with its own multi-field JSON encoding, hence its own helper) — `nil`
    /// when there is nothing to append (empty input, or JSON encoding failed), matching the
    /// no-op behavior of the `if !imageMeta.isEmpty { ... }` block this replaced. Extracted
    /// from `setContentWithBlockIds` (contained fix, no behavior change) to bring that
    /// function's cyclomatic complexity back under the project's cap — this block's own
    /// internal branching (the three `if let` field checks inside the `.map`, plus the
    /// outer emptiness/encoding checks) was most of what pushed it over. Pure, no side
    /// effects beyond its own local state.
    private func imageMetaOptionString(_ imageMeta: [ContentView.ImageBlockMeta]) -> String? {
        guard !imageMeta.isEmpty else { return nil }
        let metaArray = imageMeta.map { meta -> [String: Any] in
            var dict: [String: Any] = ["id": meta.id]
            if let width = meta.width { dict["width"] = width }
            if let caption = meta.caption { dict["caption"] = caption }
            if let alt = meta.alt { dict["alt"] = alt }
            return dict
        }
        guard let metaData = try? JSONSerialization.data(withJSONObject: metaArray),
              let metaJson = String(data: metaData, encoding: .utf8) else { return nil }
        let escapedMeta = metaJson
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        return "imageMeta: JSON.parse(`\(escapedMeta)`)"
    }

    /// Surgically update heading levels in the editor without replacing the document.
    /// Returns the updated content string (via getContent()) or nil on failure.
    func updateHeadingLevels(_ changes: [(blockId: String, newLevel: Int)]) async -> String? {
        guard let webView else { return nil }

        let changesArray = changes.map { ["blockId": $0.blockId, "newLevel": $0.newLevel] as [String: Any] }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: changesArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }

        // Single JS call: update headings then get canonical content
        let script = """
            (() => {
                window.FinalFinal.updateHeadingLevels(\(jsonString));
                return window.FinalFinal.getContent();
            })()
        """

        let result = try? await webView.evaluateJavaScript(script)
        guard let reply = result as? String else { return nil }
        let markdown = reply.contiguousUTF8Copy  // native text once, where it arrives (see `fetchContentFromWebView`)

        // Sync lastPushedContent to prevent updateNSView from firing plain setContent()
        NotificationCenter.default.post(
            name: .blockSyncDidPushContent,
            object: nil,
            userInfo: ["markdown": markdown]
        )

        return markdown
    }

    // MARK: - Poll Helpers

    /// Forced flush: the JS side (block-sync-plugin.ts) runs its own 100ms
    /// debounce independent of this Swift-side force flag, so a forced poll
    /// arriving in the gap before that timer fires would otherwise read a
    /// stale, unconverted pending-changes entry (e.g. a footnote trigger's
    /// raw text, not yet replaced by the confirming transaction). Flush that
    /// JS-side timer synchronously before checking/reading changes.
    private func flushPendingJSChanges(webView: WKWebView, force: Bool) async {
        if force {
            do {
                _ = try await evaluateJS(
                    "window.FinalFinal.flushPendingBlockChanges(); true", in: webView
                )
            } catch {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] flushPendingBlockChanges failed: \(error) — forced flush may read stale data")
            }
        }
    }

    /// DIAGNOSTIC (temporary, footnote-export-race investigation): dump the ACTUAL
    /// textContent of every update JS handed back, not just id+length -- to see
    /// directly whether getBlockChanges() returned a stale (pre-conversion) or
    /// fresh (post-conversion) snapshot of the edited block.
    private func logFetchedUpdates(_ changes: BlockChanges, force: Bool) {
        for update in changes.updates {
            DebugLog.log(.blockPoll, {
                "[DIAG:BlockPoll] update id=\(update.id.prefix(8)) force=\(force) "
                    + "text=\"\(update.textContent ?? "<nil>")\" md=\"\(update.markdownFragment ?? "<nil>")\""
            }())
        }
    }

    /// Change-digest logging for a non-empty batch: processing counts, delete IDs,
    /// and the Phase 0 update digest.
    private func logChangeDigest(_ changes: BlockChanges, force: Bool) {
        DebugLog.log(.blockPoll,
            "[SYNC-DIAG:BlockPoll] Processing: u=\(changes.updates.count) i=\(changes.inserts.count) " +
            "d=\(changes.deletes.count) force=\(force)")
        if !changes.deletes.isEmpty {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Deleting IDs: \(changes.deletes.prefix(5))")
        }
        // [SYNC-DIAG Phase 0] Dump first 10 updates as (idPrefix, textContentLength) tuples
        // to correlate suspicious empty-textContent UPDATEs with DB row state.
        if !changes.updates.isEmpty {
            let digest = changes.updates.prefix(10).map { ($0.id.prefix(8), $0.textContent?.count ?? -1) }
            DebugLog.log(.blockPoll,
                "[SYNC-DIAG:BlockPoll] Phase0 updateDigest=\(digest) u=\(changes.updates.count) " +
                "i=\(changes.inserts.count) d=\(changes.deletes.count)")
        } else if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            DebugLog.log(.blockPoll,
                "[SYNC-DIAG:BlockPoll] Phase0 u=0 i=\(changes.inserts.count) d=\(changes.deletes.count) " +
                "delIds=\(changes.deletes.prefix(5))")
        }
    }

    /// Stale-snapshot guard + telemetry. Hard-reject only the pre-existing
    /// 100%-delete-no-inserts pattern. Warning logs for mass delete or the
    /// balanced-churn type-theft signature — never reject on those.
    private func shouldRejectStaleSnapshot(_ changes: BlockChanges, database: ProjectDatabase, projectId: String) -> Bool {
        if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            do {
                // Known latent race (tracked separately, deliberately not addressed here):
                // this is a synchronous GRDB read running directly on MainActor, so it can
                // block the MainActor for the duration of the read (e.g. while contending
                // with the write lock a concurrent `applyChanges`'s `Task.detached` write is
                // holding). The obvious fix — hop this read off MainActor the way
                // `applyChanges` does for its write — would trade that blocking for a NEW
                // correctness window: `changes`/`database`/`projectId` are all captured
                // on-MainActor above, and re-suspending here to read `blockCount` would let a
                // concurrent wholesale rewrite (project switch, mode toggle, etc.) land in
                // that gap, exactly like the residual windows already documented on
                // `applyChanges` above — except unguarded by any generation re-check on the
                // way back in, since this function has no access to `checkGenerationGuard`'s
                // state. Fixing the blocking without also closing that new window would be a
                // net regression, not a fix; left for a follow-up that addresses both together.
                let blockCount = try database.fetchBlockCount(projectId: projectId)
                if let reason = Self.shouldRejectAsStale(changes: changes, blockCount: blockCount) {
                    DebugLog.alwaysPersisted(
                        "[SYNC-DIAG:BlockPoll] REJECTED: reason=\(reason) " +
                        "d=\(changes.deletes.count) i=\(changes.inserts.count) blockCount=\(blockCount)"
                    )
                    return true
                }
                if changes.deletes.count > blockCount / 2 && blockCount > 2 {
                    DebugLog.alwaysPersisted(
                        "[SYNC-DIAG:BlockPoll] WARNING: Mass delete detected " +
                        "(\(changes.deletes.count)/\(blockCount) blocks). May indicate stale snapshot."
                    )
                }
                if Self.hasBalancedMassiveChurnSignature(changes: changes, blockCount: blockCount) {
                    DebugLog.alwaysPersisted(
                        "[SYNC-DIAG:BlockPoll] WARNING: Balanced massive churn signature " +
                        "(d=\(changes.deletes.count) i=\(changes.inserts.count) u=\(changes.updates.count) " +
                        "blockCount=\(blockCount)). If this fires frequently, a regression of the " +
                        "block-id-plugin type-theft bug is likely."
                    )
                }
            } catch {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] fetchBlockCount failed: \(error)")
            }
        }
        return false
    }

    /// Classifies a fetched batch right after the fetch: empty (nothing to apply),
    /// rejected as a stale snapshot, or ready to apply. Not a pure predicate: it also
    /// calls `logChangeDigest` (which logs) and runs the stale-snapshot rejection
    /// check as a side effect before answering. MUST stay synchronous and
    /// non-throwing (no `await`): it sits inside the "no cancellation-OBSERVING await
    /// between here and `applyAndConfirm`" window documented on
    /// `doPollBlockChanges`'s fetch-boundary comment. Temp-id resolution is no longer
    /// done here -- `DocumentWriter.applyEditorBatch` resolves (and, while a late
    /// sequence is open, holds) temp-id references itself, as the only id authority.
    private enum BatchApplicability { case apply, empty, staleSnapshot }

    private func classifyBatch(
        _ changes: BlockChanges, database: ProjectDatabase, projectId: String, force: Bool
    ) -> BatchApplicability {
        guard !changes.updates.isEmpty || !changes.inserts.isEmpty || !changes.deletes.isEmpty else {
            return .empty
        }
        logChangeDigest(changes, force: force)
        if shouldRejectStaleSnapshot(changes, database: database, projectId: projectId) {
            return .staleSnapshot
        }
        return .apply
    }
}
