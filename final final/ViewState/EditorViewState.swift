//
//  EditorViewState.swift
//  final final
//

import SwiftUI

@MainActor
@Observable
class EditorViewState {
    /// Identity of this window's editor state; the annotation display broadcast is scoped by it.
    let windowToken = UUID()

    var editorMode: EditorMode = .wysiwyg

    /// Timestamp of last editor mode toggle request — used for debounce
    var lastToggleRequestTime: Date = .distantPast

    /// Minimum interval between editor mode toggle requests (prevents rapid double-toggle)
    private static let toggleDebounceInterval: TimeInterval = 0.5

    /// Whether enough time has passed since last toggle request to allow another
    var canToggleEditorMode: Bool {
        Date().timeIntervalSince(lastToggleRequestTime) >= Self.toggleDebounceInterval
    }

    // MARK: - The Markdown page's readiness (t-633df056, Phase 5 job A5)

    /// True from the moment `toggleEditorMode()` makes the mode Markdown until the new CodeMirror page has been mounted (its
    /// `onWebViewReady`, which moves the app's web-view pointers to it, then `markMarkdownPageReady()`). In that window the status-bar
    /// badge already says Markdown but the pointers still name the outgoing Rich Text page, so a Markdown section command waits for the
    /// page (`awaitMarkdownPage`, EditorViewState+MarkdownPageReadiness.swift) instead of asking the wrong page and quietly taking the
    /// slow route. False again when the mode leaves Markdown. A plain `editorMode = .source` (the unit-test rigs, which have no page)
    /// never sets it, so nothing waits in them.
    @ObservationIgnored var markdownPageLoading = false

    /// The commands waiting in `awaitMarkdownPage`, by waiter id, each with the task that times it out.
    @ObservationIgnored var markdownPageWaiters: [UUID: MarkdownPageWaiter] = [:]

    /// Focus mode state - persists across app launches via UserDefaults
    var focusModeEnabled: Bool = AppDefaults.store.bool(forKey: "focusModeEnabled") {
        didSet {
            AppDefaults.store.set(focusModeEnabled, forKey: "focusModeEnabled")
        }
    }

    /// LanguageTool connection status (only visible when LT mode is active)
    var proofingConnectionStatus: LTConnectionStatus = .disconnected

    /// Spelling check state - persists across app launches via UserDefaults (defaults to true)
    var isSpellingEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isSpellingEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isSpellingEnabled")
    }() {
        didSet { UserDefaults.standard.set(isSpellingEnabled, forKey: "isSpellingEnabled") }
    }

    /// Grammar check state - persists across app launches via UserDefaults (defaults to true)
    var isGrammarEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isGrammarEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isGrammarEnabled")
    }() {
        didSet { UserDefaults.standard.set(isGrammarEnabled, forKey: "isGrammarEnabled") }
    }

    /// Snapshot of pre-focus-mode state for restoration on exit (session-only, not persisted)
    var preFocusModeState: FocusModeSnapshot?

    /// Active focus mode effects (set in enterFocusMode, cleared in exitFocusMode)
    /// Pre-initialized from settings when focusModeEnabled is persisted to prevent
    /// toolbar/status bar flash on app relaunch (~500ms gap before enterFocusMode runs)
    var focusModeHidesToolbar: Bool = {
        guard AppDefaults.store.bool(forKey: "focusModeEnabled") else { return false }
        return FocusModeSettingsManager.shared.hideToolbar
    }()
    var focusModeHidesStatusBar: Bool = {
        guard AppDefaults.store.bool(forKey: "focusModeEnabled") else { return false }
        return FocusModeSettingsManager.shared.hideStatusBar
    }()

    /// Must-fix 7 (judge round): `didSet` posts `.zoomStateCleared` on every non-nil -> nil
    /// transition, from WHICHEVER of the several code paths caused it -- see that
    /// notification's own doc comment (EditorViewState+Types.swift) for the full list of
    /// non-`.didZoomOut` exit paths this closes. Guarded on `oldValue != nil` so re-affirming
    /// `nil` (already nil, set to nil again) never double-posts.
    ///
    /// Final-acceptance-round must-fix: also dismisses `zoomRootLostToastId` here (that
    /// property's own doc comment) -- this `didSet` is exactly the "existing zoom-out
    /// notification path" every zoom-out control (the empty-zoom Zoom Out button, the
    /// breadcrumb, the status-bar chevron) already funnels through uniformly, so hooking the
    /// dismiss here needs no new plumbing and covers all three the same way `.zoomStateCleared`
    /// already does.
    var zoomedSectionId: String? {
        didSet {
            if oldValue != nil && zoomedSectionId == nil {
                NotificationCenter.default.post(name: .zoomStateCleared, object: nil)
                if let toastId = zoomRootLostToastId {
                    zoomRootLostToastId = nil
                    toastCenter.dismissIfCurrent(id: toastId)
                }
            }
        }
    }

    /// The `id` of the warning toast shown by `clearZoomRestoringEditor()` (EditorViewState+Zoom.swift)
    /// when its auto-recovery exhausts its retries -- `nil` whenever that toast isn't currently
    /// showing. Set by that function right before `toastCenter.show(...)` (this instance's own
    /// injectable `ToastCenter`, defaulting to `.shared` -- same pattern `AutoBackupService` uses
    /// for its own toast, so a test can inject an isolated instance instead of touching the real
    /// singleton); cleared and
    /// used to auto-dismiss the toast by `zoomedSectionId`'s own `didSet` above the moment zoom
    /// state actually clears (from ANY zoom-out path), so the warning doesn't sit there
    /// indefinitely once the problem it describes has already resolved.
    var zoomRootLostToastId: UUID?
    var wordCount: Int = 0
    var characterCount: Int = 0
    var currentSectionName: String = ""
    var currentSectionId: String?

    // MARK: - Content State Machine
    /// Tracks content transitions to prevent race conditions
    var contentState: EditorContentState = .idle {
        didSet {
            // Increment generation on every non-idle transition
            if oldValue == .idle && contentState != .idle {
                contentGeneration += 1
            }

            // Editor content is being replaced (zoom, mode switch, project switch):
            // any reported selection is stale, so drop the selection word count.
            if contentState != .idle {
                selectedWordCount = nil
            }

            contentStateWatchdog?.cancel()
            contentStateWatchdog = nil

            if contentState != .idle {
                contentStateWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    // Exempt .structuralUndo (see docs/architecture/unified-undo.md's
                    // audited-sequences section, review round CRIT fix): a unified-undo
                    // op/undo/redo sequence
                    // (StructuralUndoController) can legitimately run longer than 5s --
                    // multiple JS round trips, two synchronous DB writes, up to two 1s/3s
                    // bibliography/footnote flushes. The controller itself already guarantees
                    // contentState returns to .idle on every one of its own exit paths
                    // (success or failure, via `defer { isPerforming = false }` alongside
                    // explicit `contentState = .idle` on each return). A force-reset HERE,
                    // mid-sequence, would let BlockSyncService's poll -- gated only on
                    // contentState == .idle -- resume and read block state mid-restore: the
                    // exact content-laundering hazard (H1) this whole design exists to
                    // prevent. If the sequence is genuinely stuck (a real bug), staying stuck
                    // and visible is safer than silently resuming sync over a half-restored
                    // document.
                    guard self.contentState != .structuralUndo else { return }
                    // A real restore (zoomOut() or the lost-zoom-root recovery) is already
                    // inside restoreFullDocumentAndClearZoom -- same reasoning as the
                    // .structuralUndo exemption above: don't stomp on it mid-restore. It owns
                    // its own contentState transition back to .idle on every exit path (M1,
                    // judge fix round).
                    guard !self.isZoomRestoreInProgress else { return }
                    // Phase 5 job A9/A10: a carried switch owns its return to `.idle` on every exit (EditorViewState+SwitchTransition.swift).
                    guard !self.transitionHolds.switchRunning else { return }
                    // Phase 2 (t-94369a83), §2.8: wait out an in-flight system write
                    // rather than force-resetting contentState from under it -- see
                    // `systemWriteInFlight`'s own doc comment.
                    //
                    // Review fix (finding #13): the old comment here claimed a flat "I-SYS's
                    // 5s stall backstop plus the 3s late-expiry margin" bound -- not actually
                    // a hard ceiling. I-SYS's stall backstop is PER SYSTEM WRITE: if several
                    // are queued, each one individually gets its own 5s window before being
                    // skipped, so N queued, all-stalling writes could take roughly N x 5s, not
                    // a flat 8s. And once a write is admitted past the stall backstop and
                    // actually reaches `applySystemWrite`, the DB write itself has NO timeout
                    // of its own -- a genuinely stuck write (e.g. blocked on a lock) could keep
                    // this loop waiting indefinitely. In the ordinary, expected case this
                    // resolves in well under a second; there is no hard bound for the
                    // pathological one.
                    while self.systemWriteInFlight > 0, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !Task.isCancelled else { return }
                    if self.contentState != .idle {
                        if self.contentState == .zoomTransition {
                            // M1 (judge fix round, CRITICAL): clearing zoomedSectionId/
                            // zoomedSectionIds here -- while the editor is still showing
                            // whatever partial/zoomed content this stuck transition left
                            // behind -- would make the NEXT flushContentToDatabase() treat
                            // that partial content as the WHOLE document (the exact silent
                            // wipe this whole task exists to prevent). Only clear the range
                            // (so flushes keep safely no-op'ing) and hand off to the same
                            // recovery path that knows how to restore the full document
                            // safely, instead of declaring "not zoomed" over content that was
                            // never actually restored.
                            self.isZoomingContent = false
                            self.zoomedBlockRange = nil
                            self.resumeAckContinuationOnce()
                            if self.zoomedSectionId != nil {
                                self.zoomEpoch += 1
                                Task { @MainActor [weak self] in
                                    await self?.clearZoomRestoringEditor()
                                }
                            }
                        }
                        self.contentState = .idle
                    }
                }
            }
        }
    }

    /// Watchdog task that resets contentState if stuck in non-idle state for >5 seconds
    private var contentStateWatchdog: Task<Void, Never>?

    #if DEBUG
    /// Test seam (t-94369a83 3a-1b C5b, N10): whether the content-state watchdog has no live task. A completed
    /// close or switch ends with `resetForProjectSwitch()` setting `contentState = .idle`, whose `didSet` cancels
    /// and drops the watchdog; the N10 test asserts that after a close tail with a system write parked behind
    /// the held barrier. Read-only; no production behaviour.
    var testContentStateWatchdogIsNil: Bool { contentStateWatchdog == nil }
    #endif

    /// Phase 2 (t-94369a83), §2.8: incremented by `BlockSyncService.performSystemWrite`
    /// for the whole reserve-through-apply span of a system write (bibliography/Notes/
    /// heading-level), decremented via `defer` on every exit. `contentStateWatchdog`
    /// waits this out (bounded by I-SYS's 5s stall backstop plus the 3s late-expiry
    /// margin) rather than force-resetting `contentState` out from under an in-flight
    /// system write -- a hierarchy-enforcement write in particular can itself run
    /// longer than this watchdog's plain 5s bound. The hierarchy flow still owns its
    /// own return to idle via `enforceHierarchyAsync`'s existing `defer { contentState
    /// = .idle }`; this only defers the WATCHDOG's own force-reset, never replaces it.
    var systemWriteInFlight: Int = 0

    // MARK: - Editor-first section delete (t-94369a83 Phase 4b, slice 2a)

    /// The one first-in-first-out queue every structural command goes through (plan D1.1): Delete Section, Duplicate Section, a
    /// version restore, a reorder, Cmd-Z, Cmd-Shift-Z and the switch to Markdown. Owned here, not by the controller, so the
    /// lifecycle step-1 wait, zoom and the mode switch can reach it without holding a controller.
    let structuralGate = StructuralCommandGate()

    /// One record per queued editor-first delete job, each with a future that always resolves (plan D2.5). Zoom, the switch to
    /// Markdown, Save Version, export and the close/quit wait await ONLY these, never the writer's whole queue (D7, A1).
    let efJobRegistry = EFJobRegistry()

    /// The leader ids (headings and section breaks) of sections an editor-first delete has already taken off the screen but whose
    /// job has not applied yet. The outline observation loop and `refreshSectionsAwaiting` drop them from every result, so the
    /// sidebar never shows a section the user just deleted while the database still holds its rows (plan D1.6, Q10).
    @ObservationIgnored
    var pendingRemovalIds: Set<String> = []

    /// The switch to or from Markdown pressed while a structural command was mid-way, waiting for it to finish
    /// (`holdModeToggleUntilStructuralWorkEnds`, fix round 2a item 4). At most one.
    @ObservationIgnored
    var heldModeToggleTask: Task<Void, Never>?
    /// Phase 5 job A7: a zoom transition in progress and the zoom held behind a transition (EditorViewState+ZoomTransition.swift).
    let transitionHolds = TransitionHoldState()

    /// Bumped by every write to the block table that does not go through the writer's queue (`flushContentToDatabase`, the
    /// whole-document row writes, the old-path structural ops' mutations, and `awaitPendingStructuralJobs`). A structural entry
    /// remembers the value it was recorded at; slice 2b's quick undo compares it to decide whether its stored rows can still be
    /// put back (plan D5b). Under option (b) it is recorded and bumped but not yet read for a decision.
    @ObservationIgnored
    var outOfQueueWriteGeneration = 0

    // MARK: - Quick undo of an editor-first section delete (t-94369a83 Phase 4b slice 2b; logic in the files named below)

    /// A second counter, bumped ONLY at the three structural out-of-queue writes (`StructuralUndoController`'s `performStructuralOp`
    /// mutation and the slow undo and redo: the writes that put fresh ids on the whole project). The quick undo's eligibility reads
    /// this one, not `outOfQueueWriteGeneration`: the idle backup, Save Version and export flush the screen's own text into the
    /// table, which a reinsert that makes the rows equal the saved pre-delete rows overwrites (plan-v3-addendum A1).
    @ObservationIgnored
    var structuralOutOfQueueGeneration = 0

    /// Bumped in the synchronous stretch before a quick undo or quick redo sends its JavaScript. A rebuild stamps this when it reads
    /// the database and skips its editor push when it has moved (`EditorViewState+RebuildGuard.swift`, plan-v4-addendum 3).
    @ObservationIgnored
    var editorRestoreGeneration = 0

    /// Quick undos whose reinsert has not yet ended (+1 in the same stretch as the bump above, -1 when the reinsert's job future
    /// resolves, whatever its outcome). A rebuild that read the database while this was above 0 read the post-delete rows.
    @ObservationIgnored
    var pendingReinsertCount = 0

    /// Bumped in the synchronous stretch of every editor-first structural CLICK (Delete Section, Duplicate Section and the whole-project
    /// Version History restore; `runEditorFirstStructuralClick`, and the quick redo of each) before its JavaScript goes out. Read ONLY by
    /// the rebuild guard: a rebuild that stamped before the click skips its editor push (t-18b7fa48 D6, option (a)). Deliberately not
    /// `editorRestoreGeneration`: that one is read by the settles of the quick undo and redo, whose behaviour a click must not change.
    @ObservationIgnored
    var editorFirstClickGeneration = 0

    /// Editor-first clicks whose job has not ended yet (+1 in the click's stretch, -1 when the job's future resolves, or at once when
    /// the click reserved no job). A rebuild that read the database while this was above 0 read the table without the click's change.
    /// Read ONLY by the rebuild guard. The count comes down BEFORE the operation's own settle starts, or the settle's rebuilds would
    /// stamp as "read while pending" and skip their own pushes (t-18b7fa48 D6 ordering).
    @ObservationIgnored
    var pendingEditorFirstJobs = 0

    /// Set when a push of the database's Notes and Bibliography into the editor was skipped because an editor-first click had made its
    /// stamp stale (`noteStalePushSkipped`: the click generation moved, or the read happened while a job was pending). The database is
    /// right and the editor is not, and nothing else would put it right: the operation's own settle cannot repair it
    /// (`FootnoteSyncService` skips a second resync of the same references). The last editor-first settle to finish re-pushes and clears
    /// it (`settleManagedRegionsAtEndOfEditorFirstSettle`), once no editor-first job is pending. t-18b7fa48 round 1b-ii.
    @ObservationIgnored
    var managedRegionsNeedRepush = false

    /// How many `flushLiveContentToDatabase` calls are running (the idle backup, Save Version, export and the old-path structural
    /// ops). A quick undo or redo waits for them before it decides (plan-v3 verdict T1).
    @ObservationIgnored
    var liveFlushRunning = 0

    /// The section leaders a quick undo has put back on the screen whose rows the database does not hold yet, by entry id. The outline
    /// results merge them in until the reinsert has applied (`withoutPendingRemovals`).
    @ObservationIgnored
    var pendingRestoreSections: [UUID: [Block]] = [:] {
        // An anchor lives only as long as its overlay entry (every clearing site sets the entry to nil).
        didSet {
            guard !pendingRestoreAnchors.isEmpty else { return }
            pendingRestoreAnchors = pendingRestoreAnchors.filter { pendingRestoreSections[$0.key] != nil }
        }
    }

    /// Where each pending restore's leaders go in the outline, by entry id (`SidebarRestoreOverlay`): the heading that stood before the
    /// section in the pre-delete document. An entry without one is placed by its leaders' old sort orders.
    @ObservationIgnored
    var pendingRestoreAnchors: [UUID: RestoreAnchor] = [:]

    /// Quick undos whose restored section the sidebar does not show yet: the update waits for the editor's next paint (up to 300 ms).
    /// Raised when the update is scheduled, lowered when it has run or been dropped.
    @ObservationIgnored
    var pendingSidebarRestoreCount = 0

    /// The order an editor-first drag-reorder has already put on the screen whose job has not renumbered the rows yet (t-0b70d1e9; the
    /// rule and the merge are in `SidebarReorderOverlay`). Every outline result is put into this order until the job's settle lifts it
    /// (`liftPendingReorder(opId:)`). ONE slot: only the newest reorder's order applies, a later reorder replaces an earlier one's, and
    /// a later slow undo or redo clears it when it records its own sidebar state (`swapSidebarLeaders`).
    @ObservationIgnored
    var pendingReorder: PendingReorder?

    /// Waits for every editor-first delete job to end (applied, failed, refused or abandoned), and for nothing else: never
    /// `writer.awaitSettled()`, so an unrelated queued bibliography job is not waited for (plan D7, addendum A1/A2). Called FIRST by
    /// every direct writer that cannot run while a delete job is pending: zoom in, zoom out, the flush before Save Version and
    /// export, and the switch to Markdown. Past one second it shows "Finishing the last change..." and dismisses it by id on the
    /// way out. Then bumps `outOfQueueWriteGeneration`, because what the caller does next is such a write.
    func awaitPendingStructuralJobs() async {
        // The delete's job AND the work after it (the footnote and bibliography resyncs, and the push of the database's Notes into
        // the editor when a lifecycle holds the editor): until that has finished the editor's Notes are half updated, and the
        // flush these callers run next would write them over the database's correct ones. Still only the delete's own work: an
        // unrelated queued write is not waited for (U11), and the follow-up part is bounded (`awaitAllSettled`).
        //
        // And, in Markdown mode (t-4a8fd8af slice 3, judge fix A), the writer's STRUCTURAL HOLD. A Markdown click changes the page
        // first and registers its job only later, and in between it awaits (the page calls, the rows read, the typing batch). Until its
        // job is queued the registry above knows nothing of it, yet the page already holds the command (a Duplicate's copy) that the
        // rows do not: a flush that wrote the page's text into the rows now would be copied again by the job (Duplicate), and a zoom's
        // push could land after the page insertion. The hold is up from the click's first page change until step 8 has saved the
        // typing, so this waits for it to fall first; the caller is HELD, never refused, and runs afterwards. Nothing that owns a
        // hold calls this (the click, the quick undo and redo, the job, step 8: none of them flushes or zooms), so it cannot wait on
        // itself. The wait for the registry follows: the settle outlives the hold.
        if hasUnfinishedStructuralWork {
            // Like every delayed progress toast it yields to a progress toast already on screen (fix round 2a, items 5 and R3):
            // Save Version and export call this wait through `flushLiveContentToDatabase`, and export already shows "Exporting...".
            let toast = DelayedProgressToast(toastCenter: toastCenter, message: DelayedProgressToast.finishingMessage)
            defer { toast.stop() }
            await markdownWriter.awaitStructuralHoldReleased()
            if efJobRegistry.hasUnsettledWork { await efJobRegistry.awaitAllSettled() }
        }
        outOfQueueWriteGeneration &+= 1
    }

    /// True while a structural command still has work that a direct writer (the zoom, the flush before Save Version, export and the idle
    /// backup) must not run beside: an editor-first job or its settle that has not settled (`efJobRegistry.hasUnsettledWork`), or, in
    /// Markdown mode, the writer's structural hold (`markdownWriter.isHeldForStructuralWork`), which covers a click from its first page
    /// change, before its job is registered. The user zoom's pre-check and `awaitPendingStructuralJobs` ask it.
    var hasUnfinishedStructuralWork: Bool {
        efJobRegistry.hasUnsettledWork || markdownWriter.isHeldForStructuralWork
    }

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// Set to true IMMEDIATELY BEFORE content change, cleared AFTER acknowledgement.
    /// This flag is passed directly to editor views and read in the same updateNSView cycle as content.
    var isZoomingContent: Bool = false

    /// When true, editor polling should skip updating the content binding.
    /// Used during project switch to prevent old editor content from bleeding into new projects.
    var isResettingContent = false

    /// Suppresses `.bibliographySectionChanged` handling for the duration of a project
    /// switch -- a bounded WINDOW, not a one-shot consumed flag (round 4,
    /// doc-open-blank-regression). Armed by the lifecycle's open tail (`ContentView.runOpenTail`,
    /// ContentView+LifecycleTails.swift) and CHECKED (never reset by the consumer) by
    /// `ContentView.handleBibliographySectionChanged()`.
    ///
    /// Round 4.1: moved here from a `@State Bool` on `ContentView` itself. That shape was
    /// correct in production (a live SwiftUI view installs `@State`'s storage normally) but
    /// made the mechanism untestable: a bare, directly-constructed `ContentView()` in a unit
    /// test never gets installed into a view graph, so `@State`'s `nonmutating set` has no
    /// backing location to write to and silently no-ops -- a write from test code was never
    /// observed by a later method call reading the same property. Every other property this
    /// window's fix needs to interact with (`isResettingContent`, `switchInProgressContent`)
    /// already lives here as a plain stored property on this `@Observable` class, which is
    /// exactly why THEIR mutations already worked reliably in tests while this one didn't.
    ///
    /// Why not one-shot: a mid-switch bibliography flush (`flushPendingSync`, called
    /// explicitly from the old `handleProjectOpened()`, before 3a-1b) and the OLD project's own independent
    /// debounce timer (`BibliographySyncService`'s 1s `debounceTask`) can BOTH post
    /// `.bibliographySectionChanged` during the same switch. A one-shot flag that resets
    /// itself on first consumption (round 3's shape) protects only whichever of the two
    /// posts first, leaving the other free to run `handleBibliographySectionChanged`'s own
    /// unstructured `Task` -- which sets `isResettingContent = true` then `false` on a
    /// schedule the open sequence doesn't control -- reopening the blank-pane publish
    /// window this mechanism exists to close.
    ///
    /// Cleared at the 3 points in `ContentView.configureAndPushContentAfterProjectSwitch` where ITS OWN switch machinery
    /// declares `isResettingContent` settled again: the synchronous Source-mode branch, the
    /// WYSIWYG branch's async content-push `Task`, and that Task's 3-second watchdog (a hard
    /// backstop, so the window is bounded to at most ~3s even if the WYSIWYG content push
    /// hangs) -- see each clear site's own comment in `ContentView+ProjectLifecycle.swift`.
    /// `isResettingContent` is exactly the state this window protects, so ending the window
    /// exactly when that function's own control over it ends is the natural boundary, not an
    /// arbitrary timer.
    ///
    /// Deliberately NOT reset by `resetForProjectSwitch()` below: that call happens WHILE
    /// this window is still meant to be armed (partway through the open tail,
    /// before any of the 3 clear points above), so clearing it there would reopen the window
    /// early.
    var suppressBibliographyRebuildsDuringSwitch = false

    /// IDs of sections included in the zoom (root + descendants)
    var zoomedSectionIds: Set<String>?

    /// Bumped on every zoom-in, zoom-out, or project-switch "episode" (`zoomToSection`,
    /// `zoomOut`, `resetForProjectSwitch`) that actually proceeds -- lets
    /// `clearZoomRestoringEditor()`'s "lost the zoom root" auto-recovery (spawned by
    /// `flushContentToDatabase`) tell apart the specific episode it was spawned to fix from a
    /// LATER, unrelated one that already resolved things by the time it wakes from its bounded
    /// wait (M3, judge fix round): a real `zoomOut()`, a fresh `zoomToSection()` into a
    /// different section, or a project switch mid-wait must each make the recovery abandon
    /// rather than tear down state that no longer belongs to the episode it was spawned for.
    var zoomEpoch: Int = 0

    /// True while either `zoomOut()` or `clearZoomRestoringEditor()`'s recovery is actually
    /// inside the shared `restoreFullDocumentAndClearZoom` restore logic -- never two at once,
    /// so the single `contentAckContinuation` (`waitForContentAcknowledgement`) can never be
    /// overwritten by a second concurrent caller. Paired with `zoomRestoreWaiters` below as a
    /// small FIFO mutex: `acquireZoomRestore()`/`releaseZoomRestore()` are the only two places
    /// that touch either property -- every entry point that wants to run a restore calls
    /// `acquireZoomRestore()` first and `releaseZoomRestore()` (via `defer`) when done, and
    /// never reads or writes these two properties directly.
    ///
    /// M3 fix-round-3 (deadlock found via a live stack sample, judge fix round): the PREVIOUS
    /// design here (`zoomRestoreTask: Task<Void, Never>?`, joined via `while let inFlight =
    /// zoomRestoreTask { await inFlight.value }`) reproduced a genuine 100%-CPU spin under
    /// concurrent callers -- something could observe an already-finished Task still installed
    /// in the property (never definitively cleared by the right owner) and keep re-awaiting
    /// it, which resolves near-instantly every time with no real suspension, so the loop never
    /// yielded long enough for whatever should have cleared the property to actually run. A
    /// FIFO continuation queue has no such failure mode: a waiter's continuation is resumed
    /// AT MOST ONCE, by construction, and ownership is handed directly from one owner to the
    /// next waiter (never bounced through a released-then-re-claimed intermediate state a
    /// third caller could race into) -- see `releaseZoomRestore()`'s own doc comment.
    private var zoomRestoreInProgress = false

    /// FIFO queue of callers waiting for `acquireZoomRestore()` to hand them ownership --
    /// see `zoomRestoreInProgress`'s doc comment.
    private var zoomRestoreWaiters: [CheckedContinuation<Void, Never>] = []

    /// Acquires the exclusive "a restore is in flight" slot: returns immediately if nothing
    /// else holds it, otherwise waits (consuming zero CPU while waiting -- a genuine
    /// suspension, not a poll) until `releaseZoomRestore()` hands it over. ALWAYS pair with a
    /// `defer { releaseZoomRestore() }` immediately after acquiring.
    func acquireZoomRestore() async {
        if zoomRestoreInProgress {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                zoomRestoreWaiters.append(continuation)
            }
            // Ownership was handed DIRECTLY to us by releaseZoomRestore() below --
            // zoomRestoreInProgress is already true; do not set it again here.
            return
        }
        zoomRestoreInProgress = true
    }

    /// Releases the "restore in flight" slot. If another caller is already waiting, ownership
    /// passes DIRECTLY to it (the flag stays `true` the whole time) rather than clearing the
    /// flag and letting whoever gets scheduled next race to claim it -- clearing it in between
    /// would let a brand-new caller that calls `acquireZoomRestore()` in that window steal the
    /// slot ahead of the waiter that was already queued for it, and (worse) could let TWO
    /// callers both believe they hold it.
    func releaseZoomRestore() {
        guard !zoomRestoreWaiters.isEmpty else {
            zoomRestoreInProgress = false
            return
        }
        let next = zoomRestoreWaiters.removeFirst()
        next.resume()
    }

    /// True whenever `acquireZoomRestore()` would currently have to wait -- read-only status
    /// check for a caller that wants to know without joining (e.g. the watchdog, which should
    /// never itself queue up behind a restore, only detect that one is running).
    var isZoomRestoreInProgress: Bool { zoomRestoreInProgress }

    /// Incremented on every content state transition away from idle.
    /// Polling captures this before JS calls and discards results if it changed.
    var contentGeneration: Int = 0

    /// Incremented every time `resetForProjectSwitch()` runs (project switch or close).
    /// `MilkdownEditor`/`CodeMirrorEditor`'s Coordinator compares this against the value
    /// it last saw in `updateNSView` and, on change, clears its `lastPolled*`
    /// equality-guard caches (word/character counts, section title/id). Without this,
    /// those caches -- which the Coordinator keeps across project switches because the
    /// editor view stays mounted -- would still hold the old project's values after
    /// `wordCount`/`characterCount`/`currentSectionName`/`currentSectionId` reset to
    /// zero/empty below, so a poll tick after reopening the same project would see the
    /// same numbers it cached before and wrongly suppress the change callbacks.
    var pollCacheResetGeneration: Int = 0

    /// Bumped by every INTENTIONAL replacement of `sourceContent` -- zoom transitions,
    /// project switch/open, structural undo/redo restores (see the one-line classification
    /// comment at each write site). `CodeMirrorEditor`'s Coordinator compares this against
    /// the last value it honoured (`lastHonouredForcedPushGeneration`) in
    /// `shouldPushContent`, same generation-counter pattern as `pollCacheResetGeneration`
    /// above: the coordinator applies the forced push exactly once per bump, not
    /// repeatedly across every `updateNSView` cycle that happens to see the same value.
    /// Added for the undo-mode-switch-focus fix: a DERIVED (unflagged) `sourceContent`
    /// write landing mid-typing must be suppressible by the settle-window guard, but an
    /// INTENTIONAL one must never be -- this is how a caller declares which kind it is.
    var forcedPushGeneration: Int = 0

    /// P3 §4d token (undo-mode-switch-focus second timing gap, judge-review M1 fix): an
    /// expiring, content-keyed suppression token, replacing an earlier plain-Bool design.
    /// The plain Bool broke for WYSIWYG specifically: its ONE real consumer is
    /// `onSectionsUpdated` (`ContentView+ProjectLifecycle.swift`), which only fires once
    /// `BlockSyncService`'s OWN poll cycle (its own ~2s timer, independent of anything
    /// here) pushes the reverted content to the DB -- by then, a plain "read-then-reset
    /// on the FIRST reader" Bool had already been consumed (or wiped by an intervening
    /// keystroke) by `ViewNotificationModifiers.handleContentChange`, which fires almost
    /// immediately after the same push. Two consumers, one shared flag, wildly different
    /// latencies -- the Bool could never serve both.
    ///
    /// Fix: two INDEPENDENT one-shot flags on the SAME token, so neither consumer's read
    /// clears the other's. Content-keyed (not just a plain flag) so a genuine NEW,
    /// non-undo edit explicitly INVALIDATES the token (hash mismatch) instead of a
    /// coincidental keystroke silently wiping suppression a slower consumer still needs.
    struct ReconcileSuppression {
        /// Hash of the (reverted) content as it stood at the moment the undo was
        /// detected. A consumer checks this against the content it's about to act on
        /// before honouring suppression -- if they don't match, something genuinely new
        /// happened since, and honouring a stale token would be wrong.
        let contentHash: Int
        let expiresAt: Date
        var consumedByContentSync = false
        var consumedByHierarchy = false

        /// The slower of the two consumers (`onSectionsUpdated`'s hierarchy re-check) fires only after the reverted
        /// content reaches the DB, so the token must still be alive when it does. It was the 2 s block poll plus a
        /// 1.5 s margin; Phase 5 job B4 removed the poll (the editor's report lands in well under a second, and a
        /// lost one is re-posted after 2 s), so the TTL is its own constant at the same 3.5 s.
        static let ttl: TimeInterval = 3.5

        var isExpired: Bool { Date() >= expiresAt }
        /// Both consumers have taken their one-shot read -- nothing left to guard, safe
        /// to discard proactively rather than waiting out the TTL.
        var isFullyConsumed: Bool { consumedByContentSync && consumedByHierarchy }
    }

    /// Set by CodeMirrorEditor's/MilkdownEditor's `onContentChange` closures right before
    /// `content`/`sourceContent` is reassigned: constructs a fresh token when the push was
    /// an undo, or explicitly invalidates (nils out) the existing token when a genuinely
    /// NEW, non-undo edit's content hash no longer matches it. Threaded into
    /// `SectionSyncService.contentChanged(_:zoomedIds:suppressReconcile:)` (content-sync
    /// consumer) and `ContentView+ProjectLifecycle.swift`'s `onSectionsUpdated` handler
    /// (hierarchy consumer) so a just-undone correction isn't immediately re-detected and
    /// re-applied before the user's next Cmd-Z can reach their own original typing.
    ///
    /// SCOPE NOTE: CodeMirror's content-sync consumer hash-checks against the actual
    /// content it's acting on. Milkdown's hierarchy consumer (`onSectionsUpdated`) has no
    /// comparable markdown string at its call site (it operates on `editorState.sections`,
    /// derived from DB blocks, not a content string) -- it consumes the one-shot flag
    /// without a hash check, relying on the TTL + explicit-invalidation-on-new-edit for
    /// staleness protection instead. Defaults nil (no active suppression).
    var reconcileSuppression: ReconcileSuppression?

    /// Whether any content transition is in progress.
    /// Services check this instead of maintaining their own suppression flags.
    var isBusy: Bool { contentState != .idle }

    // MARK: - Content
    var content: String = ""

    /// Authoritative stand-in for `content` during a project-switch flush, while `content`
    /// itself is deliberately stale for the whole window (see `freshContentForLifecycle`,
    /// EditorViewState+Lifecycle.swift, which stages it for a Markdown lifecycle; the old
    /// `flushAllPendingContent()` did the same for every project switch before 3a-1b).
    ///
    /// Set there -- to the freshest content it could obtain -- right after it
    /// resolves what to flush, and cleared by `resetForProjectSwitch()` once the window
    /// ends. `flushContentToDatabase(overrideContent:)` prefers this over `content` whenever
    /// it is set and no explicit `overrideContent` was passed.
    ///
    /// This is the fix at the level of the INVARIANT ("no code path may parse-and-write
    /// blocks from `content` while it is deliberately stale"), not a per-caller patch. Two
    /// prior rounds each threaded an explicit `overrideContent` argument through one
    /// specific call chain into `BibliographySyncService`'s flush hook and each missed the
    /// other of the two known entry paths (the explicit `flushPendingSync` call vs. the
    /// independent debounce timer firing on its own schedule mid-switch) -- because
    /// `flushContentToDatabase` itself now consults this property, ANY caller that reaches
    /// it with no override during the window is covered, including a caller not yet
    /// discovered.
    var switchInProgressContent: String?

    /// Content with section anchors injected (for source mode)
    /// This is separate from `content` to avoid anchor pollution in WYSIWYG mode
    var sourceContent: String = ""

    /// Anchor mappings extracted from source content (for section ID restoration)
    var sourceAnchors: [SectionAnchorMapping] = []

    // MARK: - Content Acknowledgement
    /// Continuation for waiting on content acknowledgement from WebView
    /// Used during zoom transitions to prevent race conditions
    var contentAckContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Scroll Request
    var scrollToOffset: Int?
    /// Block-ID-based scroll for Milkdown (avoids character-offset mismatch with atom nodes).
    /// A deferred, smoothly-animated follow-up scroll consumed by MilkdownEditor's `@Binding`
    /// (see MilkdownEditor.swift) via `scrollToBlock()`. Unrelated to, and NOT the same
    /// mechanism as, `BlockSyncService.setContentWithBlockIds`'s own `scrollToBlockId`
    /// parameter (BlockSyncService.swift) -- that one lands synchronously, in-push, during the
    /// zoom-out content replace itself. The two happen to share a name; they do not share code.
    var scrollToBlockId: String?
    /// Index into the INLINE-only annotation ordering (Document Notes excluded) — triggers
    /// scroll to the nth inline annotation in the editor. Matches the ordering the JS bridge
    /// functions (getAnnotations()/scrollToAnnotation()) use, computed via
    /// `EditorViewState.inlineAnnotationIndex(of:)` (EditorViewState+Annotations.swift), NOT
    /// an index into the full `annotations` array below (which also holds Document Notes,
    /// sorted first).
    var scrollToAnnotationIndex: Int?

    // MARK: - Sidebar State (Phase 1.6)
    var sections: [SectionViewModel] = [] {
        didSet { invalidateOutlineCache(); noteLocalSectionsWrite() }
    }
    var statusFilter: SectionStatus?
    var headerLevelFilter: Int?

    /// MF-3 (Phase 7 review round): a reorder request refused because another one was already
    /// in flight (`StructuralUndoController.isPerforming`), stashed here so `dispatchSectionReorder`
    /// can retry it once the in-flight one's `Task` exits. Deliberately on `EditorViewState`
    /// (a class), not a `ContentView` `@State` property: root-caused live (diagnostic trace,
    /// not guessed) that a `@State`-wrapped struct property written from inside a `Task { }`
    /// closure on `ContentView` does not reliably persist to be read back by that SAME closure's
    /// own `defer` a fraction of a millisecond later -- confirmed even on the main thread, same
    /// synchronous execution, no intervening `await`. Plausible cause: `@State`'s subscript
    /// setter commits through a SwiftUI transaction/diffing path that needs an active view graph
    /// to actually flush, which a `ContentView` instance never has outside of being genuinely
    /// mounted in a window -- true in production, not true for a bare `ContentView()` built
    /// directly (as this project's own test suite does for exactly these methods). A plain
    /// stored property on a class has no such dependency: the write is visible to the next
    /// read unconditionally, mounted view or not. This is a correctness fix, not just a
    /// testability one -- the original `@State` version was never proven to commit reliably
    /// even in production before a `Task`'s `defer` reads it back.
    var pendingSectionReorderRequest: SectionReorderRequest?

    /// Retry budget for a refused drag-reorder (§4.3: "Drag-reorder bailed out" -> toast): one
    /// retry per gesture. Cleared on EVERY terminal outcome of `dispatchSectionReorder`
    /// (`.performed` and `.failedAfterCommit` included, not only when the give-up toast fires)
    /// so a refusal that later succeeds doesn't poison the NEXT, unrelated drag's first refusal
    /// into being misread as a second strike.
    var sectionReorderRetryAttempted = false

    /// Not `private` -- `.shared` is the one production entry point, but tests point this at an
    /// isolated `ToastCenter()` instance instead of racing other parallel tests through the
    /// shared singleton.
    var toastCenter: ToastCenter = .shared

    /// Set when a `.bibliographySectionChanged` notification arrives while zoomed into a
    /// section (bibliography rebuilds only affect the full-document view). Drained on
    /// zoom-exit by `ContentView.handleZoomStateCleared()` -- see that method and
    /// `drainPendingBibliographyRebuildAfterZoom()` (ContentView+NotificationHandlers.swift).
    /// Deliberately on `EditorViewState` (a class), not a `ContentView` `@State` property --
    /// same root cause and same fix as `pendingSectionReorderRequest` above: a debug trace on
    /// `handleZoomStateClearedDrainsPendingFlag` (BibliographyHeaderNameWiringTests.swift)
    /// showed the guard inside `drainPendingBibliographyRebuildAfterZoom()` reading back
    /// `false` immediately after the test set it `true` on the same bare, never-mounted
    /// `ContentView()` -- the same unreliable-`@State`-on-an-unmounted-view failure shape, not
    /// a new one. Moved here for the same reason and with the same guarantee: a plain stored
    /// property on a class is visible to the next read unconditionally, mounted view or not.
    var pendingBibliographyRebuildAfterZoom: Bool = false

    /// The rebuild requests a bibliography / Notes / footnote notification could not run yet, kept until the
    /// editor is idle again: drained one per idle transition by `ContentView.handleContentStateChange`, dropped
    /// by a project switch (`ContentView+ProjectLifecycle`), and -- while a close / switch / quit holds the
    /// editor (`activeLifecycle != nil`, t-94369a83 3a-1b round C4) -- the place the three rebuild handlers
    /// DEFER to instead of starting a rebuild inside the window. A cancelled lifecycle re-posts them (round
    /// C5a), a completed one drops them (round C5b).
    ///
    /// These were `ContentView` `@State` properties. They live here, on a class, for the same reason
    /// `pendingBibliographyRebuildAfterZoom` above does: a `@State` write on a bare, never-mounted
    /// `ContentView()` is silently dropped, so a test could never observe that a handler had deferred.
    /// Not observed: no view reads them.
    @ObservationIgnored
    var pendingBibliographyRebuild = false
    @ObservationIgnored
    var pendingNotesRebuild = false
    /// Footnote labels awaiting insertion while `contentState != .idle` or a lifecycle holds the editor.
    @ObservationIgnored
    var pendingFootnoteLabels = PendingFootnoteQueue()

    // MARK: - Document Goal Settings
    var documentGoal: Int?
    var documentGoalType: GoalType = .approx
    var excludeBibliography: Bool = false

    /// Filtered word count respecting excludeBibliography setting
    /// Used by both OutlineFilterBar and StatusBar for consistency
    var filteredTotalWordCount: Int {
        sections
            .filter { !excludeBibliography || !$0.isBibliography }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// Word count of the zoomed subtree (root section + descendants), or nil when not zoomed.
    /// Applies the same bibliography filter as filteredTotalWordCount so the
    /// "X of Y words" status-bar display compares like with like.
    var zoomedFilteredWordCount: Int? {
        guard let zoomedIds = zoomedSectionIds else { return nil }
        return sections
            .filter { zoomedIds.contains($0.id) }
            .filter { !excludeBibliography || !$0.isBibliography }
            .reduce(0) { $0 + $1.wordCount }
    }

    // MARK: - Annotation State (Phase 2)
    var annotations: [AnnotationViewModel] = []

    /// Display mode for each annotation type (inline or collapsed)
    var annotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [
        .task: .inline,
        .comment: .inline,
        .reference: .inline
    ]

    /// Type filters - which annotation types are visible in the panel
    var annotationTypeFilters: Set<AnnotationType> = Set(AnnotationType.allCases)

    /// Whether the Document Notes section is collapsed in the annotation panel
    var isDocumentNotesCollapsed: Bool = UserDefaults.standard.bool(forKey: "isDocumentNotesCollapsed") {
        didSet { UserDefaults.standard.set(isDocumentNotesCollapsed, forKey: "isDocumentNotesCollapsed") }
    }

    /// ID of a newly created document annotation that should auto-enter edit mode (session-only)
    var pendingEditAnnotationId: String?

    /// Whether the annotation panel is visible
    var isAnnotationPanelVisible: Bool = true

    /// Set immediately before Focus Mode (only) mutates `isAnnotationPanelVisible`
    /// (t-784ff3aa) -- consumed and cleared by `AnnotationPanel`'s own `onChange` handler, so
    /// that EXACTLY that one visibility flip snaps `panelWidth` instantly instead of running
    /// `animateToggle`'s normal 250ms `.panelToggle` animation, matching the release build's
    /// old behavior of removing the panel from the view tree outright on Focus Mode
    /// entry/exit. Every other trigger (toolbar button, View menu, ⌘]) never touches this
    /// flag and keeps the normal animated toggle. `EditorViewState+FocusMode.swift` sets this
    /// ONLY when the upcoming assignment will actually change the value (so a Focus Mode
    /// entry/exit that leaves the panel's visibility untouched, e.g. it was already hidden
    /// before entering, never sets a flag nothing will consume) -- a flag left set with no
    /// visibility change to consume it would otherwise leak into, and wrongly de-animate, the
    /// next unrelated toggle.
    var isAnnotationPanelToggleInstant: Bool = false

    /// Set immediately before Focus Mode (only) mutates `isOutlineSidebarVisible` -- consumed and
    /// cleared by `OutlineSidebarPane`'s own `onChange` handler, so that EXACTLY that one
    /// visibility flip snaps the pane and its divider instantly (see `snapToggle`) instead of
    /// running `animateToggle`'s stepped 250ms `.panelToggle` animation, matching the release
    /// build's old behavior of removing the pane from the view tree outright on Focus Mode
    /// entry/exit. Every other trigger (toolbar button, View menu, ⌘[) never touches this flag,
    /// and `toggleOutlineSidebar()` clears it defensively on the way in. `EditorViewState
    /// +FocusMode.swift` sets this ONLY when the upcoming assignment will actually change the
    /// value (so a Focus Mode entry/exit that leaves the pane's visibility untouched, e.g. it
    /// was already hidden before entering, never sets a flag nothing will consume) -- a flag
    /// left set with no visibility change to consume it would otherwise leak into, and wrongly
    /// de-snap, the next unrelated toggle.
    var isOutlineSidebarToggleInstant: Bool = false

    /// Whether the outline sidebar is visible
    var isOutlineSidebarVisible: Bool = true

    /// Global "panel only" mode - when true, ALL annotations are hidden from editor
    /// (regardless of per-type display mode settings)
    var isPanelOnlyMode: Bool = false

    /// Hide completed tasks from the annotation panel
    var hideCompletedTasks: Bool = false

    // MARK: - Zotero Integration (Phase 1.8)

    /// Zotero service reference (injected, not owned)
    weak var zoteroService: ZoteroService?

    // MARK: - Section Sync Service (for zoom sourceContent updates)
    /// Section sync service reference (injected by ContentView)
    /// Used to inject section anchors when updating sourceContent during zoom
    weak var sectionSyncService: SectionSyncService?

    /// Block sync service reference (injected by ContentView)
    /// Used for atomic content+blockID pushes during hierarchy enforcement
    weak var blockSyncService: BlockSyncService?

    /// Annotation sync service reference (injected by ContentView)
    weak var annotationSyncService: AnnotationSyncService?

    /// Bibliography sync service reference (injected by ContentView)
    weak var bibliographySyncService: BibliographySyncService?

    /// Footnote sync service reference (injected by ContentView)
    weak var footnoteSyncService: FootnoteSyncService?

    // MARK: - Lifecycle (t-94369a83 Phase 3a-1b, round C2)
    //
    // The state a close / project switch / quit runs against (slice-3a-1b-everyday.md section 5.2). The
    // token API (`armLifecycle` / `clearLifecycle`) and everything else that operates on these lives in
    // `EditorViewState+Lifecycle.swift`; an extension cannot hold stored properties, so they sit here.
    //
    // Everything except `activeLifecycle` is `@ObservationIgnored` (N34): none of it is UI state, and an
    // observed write inside the save sequence would invalidate views for no reason.

    /// The close / switch / quit currently holding this editor, or nil. Written only through
    /// `armLifecycle(_:wasGettingStarted:)` and `clearLifecycle(_:)`; read by the gates the later rounds add.
    var activeLifecycle: LifecycleToken?

    /// The writer barrier a lifecycle holds from the end of its save sequence to its tail. Exactly ONE
    /// owner holds it (N9) and it is released through a `defer` on every exit path.
    @ObservationIgnored
    var lifecycleBarrier: BarrierHandle?

    /// Every running bibliography / Notes / footnote rebuild Task, by id (item 21: a collection, not one
    /// slot). The save sequence awaits all of them to completion before it forces a poll.
    @ObservationIgnored
    var runningRebuildTasks: [UUID: Task<Void, Never>] = [:]

    /// The closures ContentView installs in `.task` and removes in `.onDisappear` (item 11). Nil whenever
    /// no ContentView is mounted for this editor state. A lifecycle captures the host into
    /// `LifecycleEntry.current` at arm and never reads this property again (N26).
    @ObservationIgnored
    var lifecycleHost: LifecycleHost?

    /// The id of the lifecycle token whose save sequence completed (item 9): a quit that joins that
    /// lifecycle sees it and does not flush a second time.
    @ObservationIgnored
    var lifecycleFlushDoneFor: UUID?

    /// The id of the lifecycle token whose tail already made the automatic version (item 9).
    @ObservationIgnored
    var lifecycleBackupDoneFor: UUID?

    /// Pending image metadata for CodeMirror to pick up during zoom/rebuild transitions
    var pendingImageMeta: [ContentView.ImageBlockMeta]?

    /// Whether citation library has been pushed to the editor
    var isCitationLibraryPushed: Bool = false

    // MARK: - Database References
    /// Database and project references for block operations (zoom, scroll, etc.)
    var projectDatabase: ProjectDatabase?
    var currentProjectId: String?

    // MARK: - Block Zoom State
    /// Stored zoom range with its place in the renumber log; use `zoomedBlockRange` (EditorViewState+ZoomAnchor.swift), not this.
    var zoomedBlockRangeAnchor: AnchoredSortOrderRange?

    /// Task for debounced block re-parse (source mode paste)
    var blockReparseTask: Task<Void, Never>?
    /// Generation counter for blockReparseTask cooperative cancellation guard
    var blockReparseGeneration: Int = 0

    /// Phase 4a (t-94369a83): saves Markdown typing block by block through the ordered write queue. Owns the baseline (what the
    /// last write or the last load says the stored rows look like) and the write in flight; the debounced re-parse
    /// (`ContentSyncObserverHost.scheduleFullDocumentReparse`) and the bibliography flush (`ContentView.makeBibliographyFlushHandler`)
    /// call it. The Swift-side pushes into the Markdown editor, direct whole-document writes, zoom entry, mode changes and project
    /// resets tell it to drop its baseline. See `MarkdownBlockWriter`.
    let markdownWriter = MarkdownBlockWriter()

    /// How long the Source Mode re-parse waits after a content change before it writes (both the full-document
    /// and the zoomed branch, `ContentSyncObserverHost.scheduleSourceModeReparse`). One second in the app; a
    /// test shortens it on its own editor state so it does not have to wait.
    @ObservationIgnored
    var sourceReparseDebounce: Duration = .milliseconds(1000)

    /// Current persist task for cancellation on rapid successive reorders
    var currentPersistTask: Task<Void, Never>?

    // MARK: - Database Observation
    // Phase 6 (numbered sidebar snapshots): the Outline's list is read by `OutlineSnapshotPublisher` and shown by
    // `acceptOutlineSnapshot` (EditorViewState+OutlineSnapshots.swift). Declared here because stored properties cannot live in an
    // extension; they are owned by that file.
    /// The loop that shows the open project's commit-driven snapshots (`beginOutlineSnapshots`).
    @ObservationIgnored
    var observationTask: Task<Void, Never>?
    private var annotationObservationTask: Task<Void, Never>?
    /// The reader of the open project's outline. nil before a project is opened and after `stopObserving`.
    @ObservationIgnored
    var outlinePublisher: OutlineSnapshotPublisher?
    /// The number of the snapshot the sidebar last showed. A snapshot is shown only if its number is higher. Reset to 0 whenever a
    /// publisher is made.
    @ObservationIgnored
    var shownOutlineRev: Int = 0
    /// How many snapshots were refused (a higher number was already shown, or, for an explicit one, a local write to `sections`
    /// came after the call).
    @ObservationIgnored
    var staleOutlineDropCount: Int = 0

    /// Callback invoked after sections are updated from database observation
    /// Used by ContentView to enforce hierarchy constraints after slash command changes
    var onSectionsUpdated: (() -> Void)?

    // MARK: - Outline Cache (equality guard for the merge, Fix 1)
    //
    // Caches the last blocks/counts a snapshot actually applied, so an unchanged snapshot can
    // be skipped before it ever reaches `mergeSections`. This is the guard from Fix 1; Fix 2 is
    // the merge itself. Comparing blocks alone (without counts) would reintroduce a bug this
    // codebase has fixed and re-broken four times before: the heading rows do not change when a
    // paragraph is typed in, only the derived word counts do (see
    // `OutlineSnapshotPublisherTests.bodyEditProducesATick`).
    //
    // Annotations don't need an equivalent cache: `observeAnnotations` applies
    // `.removeDuplicates()` at the GRDB layer (the outline's rows hide body edits, so it
    // cannot), so an unchanged re-emission is already filtered out before this class ever
    // sees it.
    //
    // Mechanism: invalidation is automatic, via `sections`'s `didSet` above -- any wholesale
    // write to `sections` (reassignment, subscript assignment, `inout` access) clears the
    // cache on its own. `applySectionsUpdate` is the sole re-arming point, and it re-arms
    // *after* its own assignment to `sections` runs (so the `didSet` it just triggered doesn't
    // wipe what it's about to set). `invalidateOutlineCache()` itself is `private`, which
    // narrows its blast radius to this file -- no caller outside `EditorViewState.swift` can
    // hand-manage the cache. Two manual, file-local calls remain and are both audited as
    // genuinely needed: `startObserving` and `stopObserving` neither one writes `sections`, so
    // the automatic `didSet` path never fires there -- these are the only two places that must
    // still clear the cache by hand.
    //
    // Boundary: the guard is automatic for *array-level* writes only. It cannot catch in-place
    // mutation of a `SectionViewModel` element -- e.g. `recalculateParentRelationships()`
    // mutating `vm.parentId` below, or the equality-guarded `apply()` mutations in
    // `EditorViewState+ObservableListDiff.swift`. Most of these element mutations happen inside
    // the cache-consistent merge path (`applySectionsUpdate` re-arms right after them), but
    // `StructuralUndoController.performSectionReorder`'s `mutate` closure
    // (`Services/StructuralUndoController.swift`, Phase 7 -- absorbed the old
    // `ContentView+SectionManagement.swift`'s `finalizeSectionReorder`) is a second, real
    // caller of `recalculateParentRelationships()` that sits outside that path. It's still safe
    // there: `editorState.sections = mutableSections`, an unconditional whole-array
    // reassignment immediately before the call, clears the cache via `sections`'s `didSet`,
    // and nothing between that write and the call re-arms it -- `applySectionsUpdate` is the
    // sole re-arming point in this file -- so the cache is guaranteed nil for the entire
    // mutation. `enforceHierarchyConstraints()`'s own reassignment immediately after also
    // clears the cache, but that's incidental to this invariant: the cache is already nil by
    // then, so removing that trailing write wouldn't reopen anything. The preceding write is
    // what's load-bearing here, not something this type structurally enforces on its own: a
    // future edit to `performSectionReorder`'s `mutate` closure that removes the preceding
    // `editorState.sections = mutableSections` write could silently reopen a stale-cache
    // window without anything
    // here catching it. Any future code that needs the cache to notice an element mutation
    // must route it through `applySectionsUpdate`'s merge path rather than mutating a
    // `SectionViewModel` directly -- there is deliberately no escape hatch for that case.
    //
    // `@ObservationIgnored`: this is a private merge-skip cache, not UI state -- nothing should
    // ever observe it. Without the annotation, `@Observable` tracks these like any other stored
    // property, so `invalidateOutlineCache()`'s writes to them run *inside* the `withMutation`
    // that `sections`'s own write already opened, adding two redundant nested registrar
    // mutations to every array-level `sections` write for no observable benefit.
    @ObservationIgnored
    private var lastOutlineBlocks: [Block]?
    @ObservationIgnored
    private var lastOutlineCounts: [String: ProjectDatabase.HeadingWordCounts] = [:]

    /// Counts the writes to `sections` that are NOT the sidebar showing a snapshot (an overlay set by an editor-first click,
    /// hierarchy enforcement's local level fix, the old reorder path's `mutate` closure, a project reset). An explicit refresh
    /// notes the count when it is called and its snapshot is dropped if the count moved: the snapshot may have been read before
    /// the change that local write stands for reached the database. This is what the old `outlineGeneration` did for explicit
    /// refreshes (it was bumped by every write to `sections`); ticks were never held to it and still are not. Showing a snapshot
    /// does not count (`isShowingOutlineSnapshot`): the order between snapshots is their numbers.
    @ObservationIgnored
    private(set) var localSectionsWriteCount: Int = 0
    /// True while `applySectionsUpdate` assigns `sections`.
    @ObservationIgnored
    private var isShowingOutlineSnapshot = false

    private func noteLocalSectionsWrite() {
        if !isShowingOutlineSnapshot { localSectionsWriteCount &+= 1 }
    }

    /// Clear the outline equality-guard cache. Fires automatically from `sections`'s `didSet`;
    /// private so nothing outside this file can hand-manage it.
    private func invalidateOutlineCache() {
        lastOutlineBlocks = nil
        lastOutlineCounts = [:]
    }

    /// True when `blocks`/`counts` are exactly what the last applied tick produced, i.e. the
    /// merge can be skipped. Cleared automatically by `sections`'s `didSet`.
    func isOutlineUnchanged(
        blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        lastOutlineBlocks == blocks && lastOutlineCounts == counts
    }

    /// Start reading the outline from the database for the reactive sidebar.
    /// Call this once during initialization after database is ready
    func startObserving(database: ProjectDatabase, projectId: String) {
        stopObserving()  // Cancel any existing observation
        invalidateOutlineCache()
        self.projectDatabase = database
        self.currentProjectId = projectId
        beginOutlineSnapshots(database: database, projectId: projectId)
    }

    /// `blocks` without the leaders of sections an editor-first delete has removed from the screen but whose job has not applied
    /// yet (`pendingRemovalIds`). Returns `blocks` itself when there are none (the normal case: no allocation).
    ///
    /// Order of work (t-0b70d1e9): (1) the pending removals filter first and always win; (2) the restore overlays merge in; (3) the
    /// reorder overlay puts the whole result into the order the editor already shows (`pendingReorder`). The reorder overlay never adds
    /// an id the earlier steps left out, so a section deleted after the drag stays gone; it works out each unlisted leader's anchor on
    /// the UNFILTERED `blocks`, so a removed leader still anchors the leaders that hung after it (G1).
    func withoutPendingRemovals(_ blocks: [Block]) -> [Block] {
        guard !pendingRemovalIds.isEmpty || !pendingRestoreSections.isEmpty || pendingReorder != nil else { return blocks }
        let merged = mergingPendingRestores(into: blocks.filter { !pendingRemovalIds.contains($0.id) })
        return mergingPendingReorder(into: merged, unfiltered: blocks)
    }

    /// Merge a snapshot's blocks/counts into `sections` and recalculate parent
    /// relationships in one step -- the sequence `acceptOutlineSnapshot` runs for every
    /// snapshot it shows. Extracted so that call site (and tests) go through one call rather
    /// than duplicating the "merge into a local copy, assign back only if changed, then
    /// recalculate parents" sequence -- see `mergeSections`'s doc comment
    /// (EditorViewState+ObservableListDiff.swift) for why the local-copy step matters.
    ///
    /// - Returns: `true` if `mergeSections` structurally changed `sections` (see that method's
    ///   doc comment for what counts as a structural change).
    @discardableResult
    func applySectionsUpdate(
        from blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        var updatedSections = sections
        let sectionsChanged = Self.mergeSections(into: &updatedSections, from: blocks, counts: counts)
        // This write is the sidebar showing a snapshot, not a local change (see `localSectionsWriteCount`).
        isShowingOutlineSnapshot = true
        if sectionsChanged { sections = updatedSections }   // fires didSet -> clears cache
        isShowingOutlineSnapshot = false
        recalculateParentRelationships()
        // Re-arm AFTER the assignment above: `sections`'s didSet would otherwise wipe it.
        lastOutlineBlocks = blocks
        lastOutlineCounts = counts
        return sectionsChanged
    }

    /// Stop observing sections from database
    func stopObserving() {
        endOutlineSnapshots()
        annotationObservationTask?.cancel()
        annotationObservationTask = nil
        invalidateOutlineCache()
    }

    /// Start observing annotations from database for reactive UI updates
    func startObservingAnnotations(database: ProjectDatabase, contentId: String) {
        annotationObservationTask?.cancel()

        annotationObservationTask = Task { [weak self] in
            do {
                for try await dbAnnotations in database.observeAnnotations(for: contentId) {
                    guard !Task.isCancelled, let self else { break }

                    // Merge in place -- reuse existing view models by id. Merge into a
                    // local copy and only assign back when something actually changed -- see
                    // `acceptOutlineSnapshot` (EditorViewState+OutlineSnapshots.swift) for why
                    // `&self.annotations` can't be passed directly here. No equality guard is
                    // needed before this: unlike the outline, `observeAnnotations` applies
                    // `.removeDuplicates()` at the GRDB layer, so an unchanged re-emission never
                    // reaches here.
                    var updatedAnnotations = self.annotations
                    let annotationsChanged = Self.mergeAnnotations(into: &updatedAnnotations, from: dbAnnotations)
                    if annotationsChanged { self.annotations = updatedAnnotations }
                }
            } catch {
                DebugLog.log(.outline, "[EditorViewState] Annotation observation error: \(error)")
            }
        }
    }

    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level.
    ///
    /// Mutates `parentId` on the existing view model in place (equality-guarded) rather than
    /// calling `withUpdates`, which returns a new object instance. This method is shared by two
    /// callers with different cadences. The real per-tick caller is `applySectionsUpdate`
    /// (above, in this file, at the `recalculateParentRelationships()` call inside it) -- it
    /// runs on every database observation tick, which can fire every keystroke, so replacing
    /// identities here would undo Fix 2 on the very next line. The drag-reorder path
    /// (`StructuralUndoController.performSectionReorder`'s `mutate` closure, Phase 7 --
    /// absorbed the old `ContentView+SectionManagement.swift` `finalizeSectionReorder`) is the
    /// other caller, invoked once per user action via
    /// `editorState.recalculateParentRelationships()`, instead of duplicating the
    /// parent-recalculation logic locally the way it used to. Either way,
    /// in-place mutation is the right choice for this method; `withUpdates` still exists and
    /// remains in use elsewhere on the drag path (e.g. `recalculateSortOrders`/
    /// `applyComputedOffsets`) for identity-replacing updates that are unaffected by this
    /// method's approach.
    /// Delegates to `SectionHierarchy.parentIds(for:)` -- the single shared implementation of
    /// "parent = nearest preceding entry with a LOWER header level" also used by
    /// `Database+BlockParents.swift`'s `recomputeSectionParents` to persist the same answer.
    /// `headerLevel` is already coalesced (`block.headingLevel ?? 1` in
    /// `SectionViewModel.init(from:)`/`applyIdentity`), matching the coalescing contract
    /// `SectionHierarchy.parentIds` requires of its callers.
    ///
    /// Computed ONCE for the whole `sections` array rather than per-index: this method runs on
    /// every observation tick (which can fire every keystroke), and the old per-index helper it
    /// replaced rebuilt `entries` and re-ran `SectionHierarchy.parentIds` from scratch for every
    /// section just to return one answer -- O(N^2) work and N array allocations for a document
    /// with N headings.
    func recalculateParentRelationships() {
        let entries = sections.map { (id: $0.id, level: $0.headerLevel) }
        let newParentIds = SectionHierarchy.parentIds(for: entries)
        for (index, newParentId) in newParentIds.enumerated() {
            let vm = sections[index]
            if vm.parentId != newParentId { vm.parentId = newParentId }
        }
    }

    // MARK: - Selection State

    /// Word count of the current editor text selection, or nil when nothing is selected.
    /// Fed by the selectionChanged push from both editors; counted with the same
    /// MarkdownUtils rules as the document total so the two numbers agree.
    var selectedWordCount: Int?

}

extension EditorViewState {
    /// Whether a resetting-content window (e.g. version-history restore) just closed
    /// in a state where it's safe and worthwhile to ask the page for what it holds at once
    /// (`flushAndAck`, `forceSendForResettingContentRecovery`), recovering any content push
    /// `handleContentPush` silently dropped while the window was open. Gated on
    /// `contentState == .idle`: firing it while a different transition (zoom, hierarchy
    /// enforcement, etc.) is still in flight could read a half-updated document tree. A
    /// window that closes while non-idle is an accepted narrowing: the page still reports
    /// on its own (Phase 5 B4: it was the ~2s periodic poll).
    static func shouldForcePollAfterResettingContent(
        wasResetting: Bool, isResetting: Bool, contentState: EditorContentState
    ) -> Bool {
        wasResetting && !isResetting && contentState == .idle
    }
}
