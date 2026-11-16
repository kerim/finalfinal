//
//  BlockSyncService.swift
//  final final
//
//  Unified sync service for block-based content model.
//  Applies the Rich Text editor's block reports to the database through the ordered writer.
//

import Foundation
import GRDB
import WebKit

/// Service to sync editor block changes with the database. Phase 5 jobs B3/B4: the Rich Text editor reports each settled batch
/// itself (`ReportApplier`, BlockSyncService+Reports.swift); there is no poll.
@MainActor
@Observable
class BlockSyncService {
    /// Phase 5 job B3: the intake of the editor's reports, the writer's input (BlockSyncService+Reports.swift).
    @ObservationIgnored lazy var reportApplier = ReportApplier(sink: self)

    private(set) var projectDatabase: ProjectDatabase?
    private(set) var projectId: String?
    /// Internal (was private) only so the DEBUG accessors in `BlockSyncService+Lifecycle.swift` can reach it.
    weak var webView: WKWebView?

    /// t-94369a83 Phase 4b slice 2a (plan D1.2): true from the moment an editor-first section command's click starts until its job
    /// holds its place in the writer's queue. Phase 5 job B3/B4: the editor's reports step aside while it is up (`ReportApplier`,
    /// `reportAdmissionHeld`): a report that arrives then is parked, unadmitted, and the `didSet` below admits the parked reports
    /// when the flag drops, behind the job (the fix of b3-notes.md "Root cause 1"). Written only by `StructuralUndoController`'s
    /// click paths, which clear it in a `defer`. It does NOT touch `EditorViewState.contentState`.
    var structuralClickPending = false {
        didSet {
            if oldValue, !structuralClickPending { reportApplier.admissionResumed() }
        }
    }
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

    // MARK: - Stale-snapshot guard helpers (pure, testable)

    /// Reason an editor batch was hard-rejected as a stale snapshot.
    enum StaleRejectReason: Equatable {
        case allDeletedNoInserts    // all blocks would be deleted with no inserts
    }

    /// Decide whether an editor batch (a report, or an editor-first route's batch) should be hard-rejected.
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

    // MARK: - Public API

    /// Configure the service for a specific project. Called from a fresh WebView's `onWebViewReady`.
    ///
    /// A batch still in flight from the OLD editor does not land: the `bumpBlockWriteEpoch` call below advances the persisted epoch,
    /// so a batch stamped before it is refused WHOLESALE (inserts included) by the epoch check inside the write transaction. Nothing
    /// the old editor typed is lost by that: the mode-toggle paths save its text first (`flushContentToDatabase`).
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
            // Retire, sequence continuity and the DEBUG test knobs: `replaceWriter` (BlockSyncService+WriterReplacement.swift).
            replaceWriter(database: database, projectId: projectId, retiringOldWriterFor: .writerReplaced)
        }
        self.projectDatabase = database
        self.projectId = projectId
        self.webView = webView
        // Phase 5 B4: the intake must exist (it registers itself for `ReportApplier.route`) before the page's first report arrives.
        // It is created lazily, and until B4 the 2-second poll's first tick created it; with no poll, a page whose service nothing
        // else had touched yet had every report ignored at routing (run-1794105228-99842: zero reports applied on the book).
        _ = reportApplier
        // A fresh WebView means every batch still in flight from the OLD editor was fetched
        // against a coordinate space this new editor does not share. Bump the persisted
        // epoch so those batches are refused wholesale in the write transaction - the
        // durable replacement for the in-memory reset that used to sit here and could not
        // see a native rewrite at all. `needsEpochBump` is set on EVERY attempt (false on
        // success, true on failure) so a failed bump is retried by the next turn reserved rather
        // than left failed open - see `needsEpochBump`.
        do {
            _ = try database.bumpBlockWriteEpoch(projectId: projectId)
            needsEpochBump = false
        } catch {
            needsEpochBump = true
            DebugLog.alwaysPersisted("[BlockSync] configure: could not bump blockWriteEpoch (\(error)) - the next turn reserved will retry it")
        }
    }

    /// Reconfigure database references for project switch (WebView stays the same).
    ///
    /// Phase 5 job B4: there is no poll cycle left to drain first (the 2-second poll is gone; the Rich Text editor's reports are the
    /// writer's input, and a report of the old project's page session is refused at receipt and at its turn: `ReportApplier`, rule b).
    /// Everything below is one synchronous stretch, so nothing can observe a half-switched state. Still `async` for its callers.
    func reconfigure(database: ProjectDatabase, projectId: String) async {
        // --- synchronous from here: nothing can observe a half-switched state ---
        // t-94369a83 Phase 1: retire the old writer (skips every turn it has
        // reserved and drops every held op) and start a new one, continuing its
        // sequence space so stamps stay monotonic across the switch (see
        // "Sequence continuity" in the plan). The save before a switch is the
        // lifecycle's own sequence (`EditorViewState.runLifecycleFlush`: the
        // force-send, FB and the writer barrier, then the tail's retire); `retire`
        // here refuses anything reserved after that, which the epoch bump below
        // already rejects today.
        replaceWriter(database: database, projectId: projectId, retiringOldWriterFor: .projectSwitch)
        self.projectDatabase = database
        self.projectId = projectId
        // A fresh project means every batch still in flight from the OLD project was
        // fetched against a coordinate space this project does not share. Bump the
        // persisted epoch so those batches are refused wholesale in the write
        // transaction - the durable replacement for the in-memory reset that used to
        // sit here and could not see a native rewrite at all. `needsEpochBump` is set on
        // EVERY attempt, so a failed bump for the previous project cannot leak into this
        // one, and a failed bump for this one is retried by the next turn reserved.
        do {
            _ = try database.bumpBlockWriteEpoch(projectId: projectId)
            needsEpochBump = false
        } catch {
            needsEpochBump = true
            DebugLog.alwaysPersisted("[BlockSync] reconfigure: could not bump blockWriteEpoch (\(error)) - the next turn reserved will retry it")
        }
    }

    /// True when the last `bumpBlockWriteEpoch` attempt in `configure`/`reconfigure`
    /// FAILED. Set on every attempt (false on success), never left over from an earlier
    /// project.
    ///
    /// Why this exists: with the bump failed, the persisted epoch is still the previous
    /// session's while the writer's sequence restarts low. Rows already edited last
    /// session carry stamps like `(E, 300)`, so every update/delete this session's
    /// low-sequence batches sent to those rows would be dropped as "superseded" until
    /// the in-memory counter caught up -- silent loss of the user's typing.
    /// `reserveWriterTurn` retries the bump BEFORE it reads the epoch, and reserves
    /// nothing while the retry keeps failing. That trades a silent-drop failure for a
    /// no-write failure, which is lossless: a report not admitted stays in the page's
    /// outbox and is sent again by the page's re-post (Phase 5 job B4).
    ///
    /// Internal (was private) in Phase 4a: `ensureWriter` (BlockSyncService+Markdown.swift) mirrors `configure`'s
    /// new-writer branch, which sets it.
    var needsEpochBump = false

    #if DEBUG
    /// Test-only per-INSTANCE override of the writer's turn-stall expiry (`DocumentWriter.lateAfterSeconds`). Threaded straight
    /// through to the writer; nil until a writer exists.
    var testWriterLateAfterSeconds: TimeInterval? {
        get { writer?.testLateAfterSeconds }
        set { writer?.testLateAfterSeconds = newValue }
    }

    /// Test-only read of the writer's loss ledger (skipped/discarded/failed/held
    /// counts) -- see `LossLedger`. Empty (all zero) if no writer exists yet.
    var testWriterLedger: LossLedger { writer?.ledger ?? LossLedger() }

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

    /// Test-only replacement for every page call routed through `evaluateJS(_:in:)` (the reports' calls, `flushAndAck`, the
    /// editor-first routes, `confirmBlockIds`, `fetchContentFromWebView`). Lets a test script replies -- including a one-shot
    /// wedge -- without a real WKWebView or a run loop.
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

    /// Test-only per-INSTANCE override of `flushForDatabaseRebuild`'s bound (`rebuildFlushAndAckBound`, 8 s), so a test of a page
    /// that does not answer runs on a short clock (the poll watchdog override played that part before Phase 5 B4).
    var testRebuildFlushBound: TimeInterval?
    #endif

    /// The tail of an editor batch's journey, shared by the editor's reports (`applyReportBatch`) and the editor-first section
    /// commands' click paths (t-94369a83 Phase 4b slice 2a): settle an empty batch at once, wait for the ticket's turn, refuse a stale
    /// snapshot judged against the rows as they are then (t-25eb1399), then apply it through
    /// the writer and confirm any minted ids back to the editor (a report's ids are confirmed by its acknowledgement, `onApplied`).
    /// Returns when the ticket has settled (applied, empty, discarded or skipped). The caller owns the "ticket always settles"
    /// `defer` for paths that never get here.
    ///
    /// `abandonAfterTurn` runs once the turn is granted and the stale-snapshot check has passed, before the apply: a report passes
    /// its duplicate / stale-session check (true = write nothing); the click paths pass nothing.
    func applyFetchedBatch( // swiftlint:disable:this function_parameter_count
        ticket: WriterTicket, changes: BlockChanges, stamp: BlockWriteStamp, webView: WKWebView,
        database: ProjectDatabase, projectId: String, force: Bool,
        abandonAfterTurn: () -> Bool = { false },
        abandonOutcome: NonApplyOutcome = .discarded(.generationChanged("postTurnWait")),
        onApplied: (@MainActor ([String: String]) async -> Void)? = nil
    ) async {
        // The empty check reads no rows: an empty batch still settles at once, without waiting for its turn.
        guard !changes.isEmpty else {
            ticket.settleIfOpen(.empty)
            return
        }

        // A non-`.go` result means the writer's own `skip()` call already logged
        // (`DebugLog.alwaysPersisted`, item 1) and counted this sequence in its ledger.
        guard await ticket.waitForTurn() == .go else { return }

        // t-25eb1399: the stale-snapshot check reads the rows, so it runs here at the turn, after every write queued ahead of this
        // batch (a section command's job, for one) has landed -- not against the rows as they were when the batch arrived. The guard
        // refuses a batch whose deletes EQUAL the current row count and that inserts nothing (it compares counts, not ids), so
        // judged on arrival it could wrongly catch a legitimate report that deletes everything it knew of while the rows an earlier
        // queued write (a Duplicate's job, or the previous report's inserts) was still to add had not been counted yet.
        logChangeDigest(changes, force: force)
        if shouldRejectStaleSnapshot(changes, database: database, projectId: projectId) {
            ticket.settleIfOpen(.discarded(.staleSnapshot))
            return
        }

        if abandonAfterTurn() {
            ticket.settleIfOpen(abandonOutcome)
            return
        }

        await applyAndConfirm(ticket, changes, webView: webView, stamp: stamp, onApplied: onApplied)
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
    /// view, so reservation order equals submission order equals JavaScript execution order. A report that arrives while the click
    /// is between N and its job's place is parked (`structuralClickPending`), and one still on its way at N is covered by the reply
    /// (`coverMark`, Phase 5 job B3).
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
        // Phase 5 job B3 (design 3.3, the covering reply): in the SAME synchronous stretch as the reservation of N, the highest report
        // number taken in; the page's reply then covers every report after it (they are in N's batch) and they are dropped later.
        let cover = reportApplier.coverMark()
        let sent = Self.coveredScript(script, session: cover.session, since: cover.since)
        do {
            let value = unwrapCoveredReply(try await evaluateJS(sent, in: webView) as? String)
            return EditorFirstSubmission(ticket: ticket, stamp: stamp, result: .success(value))
        } catch {
            return EditorFirstSubmission(ticket: ticket, stamp: stamp, result: .failure(error))
        }
    }

    /// The page calls of the reports (`flushAndAck`, the acknowledgement, the outbox fetch), the editor-first routes,
    /// `confirmBlockIds` and `fetchContentFromWebView`, funneled through one seam so a test can script replies (including a
    /// one-shot wedge) without a real WKWebView. The push-side calls (`pushBlockIds`, `setContentWithBlockIds`,
    /// `updateHeadingLevels`) do not route through here.
    ///
    /// Internal (it was private) so `releaseHeldTypingPushes` in BlockSyncService+Lifecycle.swift goes through the same seam.
    func evaluateJS(_ script: String, in webView: WKWebView) async throws -> Any? {
        #if DEBUG
        testJSWebViewObserver?(webView)
        if let testJSEvaluator { return try await testJSEvaluator(script) }
        #endif
        return try await webView.evaluateJavaScript(script)
    }

    /// Retries a deferred `blockWriteEpoch` bump, reads the current write epoch, and reserves a turn on the writer. MUST stay
    /// synchronous and non-throwing (no `await`, no `throws`): a report reserves its turn in the script-message callback itself
    /// (`ReportApplier.admit`), and an editor-first click reserves N in the same synchronous stretch as it submits its page call,
    /// so turn order is arrival order. `writer.reserve()` is itself synchronous (nonisolated, Mutex-guarded).
    ///
    /// Used by the reports, the editor-first clicks and the Markdown writer (`BlockSyncService+Markdown.swift`).
    func reserveWriterTurn(database: ProjectDatabase, projectId: String) -> (WriterTicket, BlockWriteStamp)? {
        // A `configure`/`reconfigure` epoch bump that FAILED is retried here, on THIS
        // caller's own `database`/`projectId`, before the epoch is read below - otherwise
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
                    + "reserving nothing; the batch stays in the page (outbox or pending)")
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
                + "reserving nothing; the batch stays in the page (outbox or pending)")
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
        _ ticket: WriterTicket, _ changes: BlockChanges, webView: WKWebView, stamp: BlockWriteStamp,
        onApplied: (@MainActor ([String: String]) async -> Void)? = nil
    ) async {
        // `renumberSortOrdersIfCrowded: true` (t-75d20927): every Rich Text batch keeps the room between two saved positions, so
        // a long paste or a run of Enters in one spot cannot tie or reverse its own rows. Same call the Markdown writer makes.
        let outcome = await ticket.writer.applyEditorBatch(ticket.seq, changes, stamp: stamp, renumberSortOrdersIfCrowded: true)
        switch outcome {
        case .applied(let result) where onApplied != nil:
            // Phase 5 job B3: a report's ids are confirmed by its acknowledgement (one call, `ReportApplier.acknowledge`).
            await onApplied?(result.idMapping)
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
                .first(where: { $0.hasPrefix("#") }) ?? ""
            return "[SYNC-DIAG:BlockSync] setContentWithBlockIds: len=\(markdown.count) "
                + "blocks=\(blockIds.count) firstH=\(DebugLog.docText(firstHeading)) "
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

    // MARK: - Batch helpers

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

    /// Stale-snapshot guard + telemetry, run at the batch's writer turn. Hard-reject only the pre-existing
    /// 100%-delete-no-inserts pattern. Warning logs for mass delete or the
    /// balanced-churn type-theft signature — never reject on those.
    private func shouldRejectStaleSnapshot(_ changes: BlockChanges, database: ProjectDatabase, projectId: String) -> Bool {
        if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            do {
                // Runs at the batch's writer turn (`applyFetchedBatch`, after `waitForTurn()`), so `blockCount` is the row count
                // after every write queued ahead of the batch has landed -- a section command's job included -- and not the count
                // when the batch arrived (t-25eb1399). The turn is held until this batch settles, so nothing else can write between
                // this read and the apply. The guard compares counts, not ids: it refuses a batch whose deletes equal `blockCount`
                // with no inserts. Judged at the turn it no longer wrongly catches a legitimate delete-everything report that was
                // queued behind earlier work (a Duplicate's job), nor a report whose new paragraphs were in the previous report,
                // still unwritten when this one arrived.
                //
                // Known latent race (tracked separately, deliberately not addressed here):
                // this is a synchronous GRDB read running directly on MainActor, so it can
                // block the MainActor for the duration of the read (e.g. while contending
                // with the write lock a concurrent `applyChanges`'s `Task.detached` write is
                // holding). The obvious fix -- hop this read off MainActor the way
                // `applyChanges` does for its write -- would trade that blocking for a NEW
                // correctness window: `changes`/`database`/`projectId` are all captured
                // on-MainActor above, and re-suspending here to read `blockCount` would put a
                // suspension between the turn and the apply, letting a concurrent wholesale
                // rewrite (project switch, mode toggle, etc.) land in that gap, exactly like
                // the residual windows already documented on `applyChanges` above -- except
                // unguarded on the way back in (the write's own epoch check would refuse a
                // stale batch, but this read would already have judged it). Fixing the blocking
                // without also closing that new window would be a net regression, not a fix;
                // left for a follow-up that addresses both together.
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
}
