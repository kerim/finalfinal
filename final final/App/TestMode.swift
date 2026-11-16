//
//  TestMode.swift
//  final final
//

import Foundation

enum TestMode {
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["FF_UI_TESTING"] == "1"
    }

    /// True when running unit tests (test bundle injected into app process).
    /// Uses XCTestConfigurationFilePath — set by Xcode's test runner before
    /// any test bundle code runs. This is undocumented but has been the
    /// canonical detection approach since Xcode 8.
    static var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when running any kind of test (unit or UI)
    static var isTesting: Bool {
        isUITesting || isUnitTesting
    }

    static var testFixturePath: String? {
        ProcessInfo.processInfo.environment["FF_TEST_FIXTURE_PATH"]
    }

    /// UI-test-only override for `UnifiedUndoService`'s 50-entry eviction cap (Phase D, plan
    /// §9.3 -- a decision the user already made, not re-litigated here). Lets an e2e test
    /// exercise real eviction (oldest entry dropped, its editor text-undo history cleared) in a
    /// handful of operations instead of 51. `nil` (unset, unparseable, <= 0, or `isUITesting` is
    /// false) leaves the real 50-entry cap untouched -- read fresh on every access rather than
    /// cached, so it can never silently latch a stale value across a project switch within the
    /// same test process.
    ///
    /// Review fix (was missing `isUITesting &&`, unlike every sibling flag here): without that
    /// guard, a user with `FF_UNDO_EVICTION_CAP` set in their own shell profile for unrelated
    /// reasons would silently get a capped undo history in a Release build too -- not test-only
    /// at all, despite this property's own name and every caller's doc comments.
    static var undoEvictionCapOverride: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UNDO_EVICTION_CAP"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// UI-test-only stretch of the two waits in front of the automatic rewrites that follow a document change
    /// (`FootnoteSyncService.debounceInterval`, normally 3 s, and `BibliographySyncService.debounceInterval`, normally
    /// 1 s): the footnote renumber and the Notes update, and the bibliography update. Lets a test type a word BEFORE
    /// those rewrites land every time, instead of racing a 3 s window (Phase 4b, Cmd-Z after typing early). `nil`
    /// (unset, unparseable, <= 0, or `isUITesting` is false) leaves both waits at their real values; a unit test or a
    /// normal launch never sees it. Computed on every access, but both services read it ONCE, in their
    /// `debounceInterval` property initialiser, when the service is created: setting the variable later in a
    /// running app has no effect.
    static var uiTestingRewriteDelaySeconds: Double? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_REWRITE_DELAY_SECONDS"],
              let value = Double(raw), value > 0 else { return nil }
        return value
    }

    /// UI-test-only bypass for `ZoteroService`'s real Zotero/Better-BibTeX network calls (Phase
    /// D, plan §8.2 "the Zotero seam") -- lets a citation-bearing e2e scenario exercise the CAYW
    /// insert path (and the N1 `cancelPendingInsertions` port, Phase B) without a real running
    /// Zotero, which is unavailable in the vmtest VM/CI. Deliberately its own flag, not folded
    /// into `isUITesting`: every OTHER UI test relies on `ZoteroService.ping()` genuinely
    /// failing there, so gating this on the general flag would silently fake a Zotero
    /// connection for every UI test, not just the one that wants it. See
    /// `ZoteroService.ping()`/`ZoteroService.openCAYWPicker()` for the mock branches this gates.
    static var isUITestingZoteroMockEnabled: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_ZOTERO_MOCK"] == "1"
    }

    /// UI-test-only (Phase 7, board t-a54c1950): holds the OPEN-TIME Zotero connection (`ContentView.connectToZotero`) back until the
    /// first bibliography update of the session has made its attempt, so a test gets the order that used to lose the first
    /// bibliography check (check first, connection second) every time instead of by a few milliseconds of timing. It holds nothing else:
    /// `ZoteroService.ping()` itself is untouched, so a bibliography update that asks Zotero for itself still gets its answer. Needs
    /// the Zotero mock above (a real Zotero is not wanted in a test) AND its own variable; unset, a normal launch and every other test
    /// connect at once as before. Read fresh on every access.
    static var isUITestingZoteroConnectHeld: Bool {
        isUITestingZoteroMockEnabled && ProcessInfo.processInfo.environment["FF_UI_TESTING_ZOTERO_HOLD_CONNECT"] == "1"
    }

    /// UI-test-only extension of the Zotero mock above (complex-document switch measurements): the path of a file holding a CSL-JSON
    /// array that `ZoteroService`'s mock fetch resolves citekeys against, IN ADDITION to the one canned item. Lets a test document that
    /// cites dozens of distinct keys see them all resolve (real citation formatting in the Rich Text editor, a real generated
    /// bibliography). Inert for a normal user: it needs `isUITestingZoteroMockEnabled` (UI testing AND the Zotero mock flag) AND this
    /// variable; otherwise it is nil and the mock behaves exactly as before. The file is written by the test into the runner's own
    /// container, which the (unsandboxed) app can read, like the fixture. Read fresh on every access.
    static var uiTestingZoteroMockLibraryPath: String? {
        guard isUITestingZoteroMockEnabled,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_ZOTERO_MOCK_LIBRARY_FILE"],
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Optional artificial delay (milliseconds) `ZoteroService.openCAYWPicker()`'s mock path
    /// waits before returning its canned result, when `isUITestingZoteroMockEnabled` is set.
    /// Zero (the default, and always when unset/unparseable) mimics an instant Zotero response.
    /// A test that needs a genuine in-flight window to interleave a structural op into -- proving
    /// N1's `cancelPendingInsertions` port actually cancels a REAL pending request, not just one
    /// that already resolved before the op ran -- sets this explicitly.
    ///
    /// Review fix (was missing `isUITesting &&`, unlike every sibling flag here -- the same gap
    /// `undoEvictionCapOverride` above already had fixed once this phase): without that guard, a
    /// user with `FF_UI_TESTING_ZOTERO_MOCK_DELAY_MS` set in their own shell profile for
    /// unrelated reasons would have this value ready to read outside any UI test, not test-only
    /// at all despite this property's own name.
    static var uiTestingZoteroMockDelayMilliseconds: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_ZOTERO_MOCK_DELAY_MS"],
              let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    /// Narrow, opt-in escape hatch for exactly one pre-existing UI test
    /// (`ProjectOpenErrorE2ETests.testOpenRecentOnDeletedProjectShowsErrorSheetWhileAppRunning`),
    /// which must exercise the real `openProject` -> `addToRecentProjects` flow against a
    /// fixture that lives under `NSTemporaryDirectory()` -- a path
    /// `DocumentManager.excludedRecentProjectRoots` excludes by default (see
    /// `DocumentManager.swift`).
    ///
    /// Deliberately NOT gated on `isUITesting` alone: that flag is set for every UI test in
    /// the suite, including the ones that specifically prove scratch-path exclusion works
    /// during UI testing. Gating on the general flag would silently defeat that behavior for
    /// every other UI test. Only this one test's launch sets the more specific env var below;
    /// everything else -- other UI tests and real usage -- keeps the exclusion active.
    static var isUITestingScratchRecentProjectsAllowed: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_ALLOW_SCRATCH_RECENT_PROJECTS"] == "1"
    }

    /// Narrow, opt-in escape hatch that lets a UI test actually exercise
    /// `DocumentManager.restoreLastProject()` — the "reopen the last project on a cold launch"
    /// path (`FinalFinalApp.determineInitialState()`'s non-testing branch). Every ordinary UI
    /// test bypasses that branch entirely: `isUITesting` alone always routes to either the
    /// explicit `FF_TEST_FIXTURE_PATH` fixture or straight to the picker (see
    /// `determineInitialState()`), so this path has never been exercised by the automated
    /// suite. A second launch with this flag set (and no `FF_TEST_FIXTURE_PATH`) calls the real
    /// `restoreLastProject()` instead, reading back whatever bookmark a prior launch in the same
    /// test saved via `openProject()` -> `saveAsLastProject()`.
    static var shouldExerciseRestoreLastProject: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_EXERCISE_RESTORE_LAST_PROJECT"] == "1"
    }

    /// UI-test-only artificial delay (milliseconds), applied to the WEB layer's own Escape
    /// -report path via `window.FinalFinal.__testSetEscapeReportDelayMs` (see
    /// `web/shared/escape-ladder.ts`'s `setTestEscapeReportDelayMs` doc comment) -- exists ONLY
    /// to prove the t-784ff3aa fix is genuinely timing-independent (EscapeLadderE2ETests.swift),
    /// not a production behavior switch. `nil`/unset/unparseable/<= 0 leaves the web layer's
    /// real (zero-delay) Escape reporting untouched. Same `isUITesting &&` guard as every
    /// sibling flag here, for the same reason: without it, a value left in a shell profile for
    /// unrelated testing would silently delay Escape handling outside any UI test too.
    static var uiTestingEscapeReportDelayMilliseconds: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_ESCAPE_REPORT_DELAY_MS"],
              let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    /// UI-test-only artificial delay (milliseconds), held open in each of the three rebuild
    /// handlers (`handleBibliographySectionChanged`, `handleNotesSectionChanged` in
    /// `ContentView+NotificationHandlers.swift`, `handleFootnoteInsertedImmediate` in
    /// `ContentView+FootnoteHandlers.swift`) between
    /// `fetchBlocksWithIds()` and the push of the rebuilt content back to the editor. Exists
    /// ONLY to widen that window wide enough for an e2e test to type into it deterministically
    /// -- proving a rebuild's own flush window can overwrite words typed during it -- not a
    /// production behavior switch. `nil`/unset/unparseable/<= 0 leaves the real (effectively
    /// instant) rebuild push untouched. Same `isUITesting &&` guard as every sibling flag here,
    /// for the same reason: without it, a value left in a shell profile for unrelated testing
    /// would silently delay every rebuild's editor push outside any UI test too.
    static var uiTestingRebuildPushDelayMilliseconds: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_REBUILD_PUSH_DELAY_MS"],
              let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    /// UI-test-only: `FF_UI_TESTING_MD_LEGACY_REPARSE=1` turns EVERY piece of the Phase 4a per-block Markdown save OFF for the
    /// whole process, so a UI test can measure today's code in the same VM run as the new code: the debounced Markdown re-parse
    /// runs `legacyWholeDocumentReparse` (a whole-document `replaceBlocks`, outside the writer), the bibliography flush runs
    /// `flushContentToDatabase(overrideContent:)`, `BlockSyncService.ensureWriter` is not called, and the set-point hooks
    /// (`MarkdownBlockWriter.noteLoaded`, `noteDirectWholeWrite`, `reset`) do nothing. `MarkdownBlockWriter.isLegacyReparse` reads
    /// this once, when an editor state is created. Same `isUITesting &&` guard as every sibling flag here, so a value left in a
    /// shell profile can never switch the per-block save off for a real user, and a unit-test run can never set it.
    static var isUITestingMarkdownLegacyReparse: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_MD_LEGACY_REPARSE"] == "1"
    }

    /// UI-test-only (t-2fbe4c9b, Phase 4c job 3): `FF_UI_TESTING_NO_PARSE_MEMO=1` turns the writer's parse memo and the handler scan memo OFF
    /// for the whole process, so a UI test can run the same build with and without the job-3 background work, back to back on one host:
    /// every `prepare` parses on the main thread (`[MdWrite] ... cache=miss`), nothing is prepared in the background, `ensure` returns at
    /// once, and the content-change handlers scan as they did before. `MarkdownBlockWriter` reads this once, when it is created
    /// (`MarkdownParseCache.isDisabled`). Same `isUITesting &&` guard as every sibling flag here, so a value left in a shell profile can
    /// never switch the memo off for a real user, and a unit-test run can never set it.
    static var isUITestingNoParseMemo: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_NO_PARSE_MEMO"] == "1"
    }

    /// UI-test-only (t-94369a83 Phase 4b slice 2a): `FF_UI_TESTING_STRUCT_LEGACY_DELETE=1` makes Delete Section take today's whole
    /// sequence (flush the editor, undo-point copy, delete the rows, push the whole document back) instead of the editor-first
    /// path, so a UI test can time old and new in one session. Mirrors `isUITestingMarkdownLegacyReparse`: same `isUITesting &&`
    /// guard, so a value left in a shell profile never switches the fast delete off for a real user and a unit-test run can
    /// never set it. Read on every access.
    static var isUITestingStructuralLegacyDelete: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_STRUCT_LEGACY_DELETE"] == "1"
    }

    /// UI-test-only (t-94369a83 Phase 4b slice 2a): `FF_UI_TESTING_STRUCT_JOB_HOLD_MS=<n>` delays the BODY of the queued
    /// section-delete job by `n` milliseconds, so a test can press Cmd-Z, switch to Markdown, zoom or close while the job is
    /// still pending. `0` (unset, unparseable, <= 0, or `isUITesting` false) means no delay. Same guard as every sibling flag.
    static var uiTestingStructuralJobHoldMs: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_STRUCT_JOB_HOLD_MS"],
              let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    /// UI-test-only (t-18b7fa48 Phase 4b slice 1, round 1i): `FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N=<n>` limits the
    /// `FF_UI_TESTING_STRUCT_JOB_HOLD_MS` hold to the first `n` editor-first jobs of this launch (counted in the order their
    /// clicks created them, by `consumeStructuralJobHold()`); every later job runs without a hold. Exists because two held jobs
    /// in a row keep the writer busy for twice the hold, past the 5 s content-state watchdog, which changes the behaviour a test
    /// is about: a test that only needs its FIRST job still pending when a second command arrives holds the first alone.
    /// `nil` (unset, unparseable, <= 0, or `isUITesting` false) means no limit: every job is held, as before. Same
    /// `isUITesting &&` guard as every sibling flag here.
    static var uiTestingStructuralJobHoldFirstN: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// How many jobs `consumeStructuralJobHold()` has granted a hold so far in this launch.
    private static var structuralJobHoldsGranted = 0

    /// True (and counted) while the next job is to be held: always, when no limit is set; else while fewer than
    /// `uiTestingStructuralJobHoldFirstN` jobs have been held in this launch. Called once per job, where the job is created.
    @MainActor
    static func consumeStructuralJobHold() -> Bool {
        guard let limit = uiTestingStructuralJobHoldFirstN else { return true }
        guard structuralJobHoldsGranted < limit else { return false }
        structuralJobHoldsGranted += 1
        return true
    }

    /// UI-test-only (t-f1a22aa7, Phase 4c): `FF_UI_TESTING_EF_SETTLE_HOLD_MS=<n>` holds the follow-up work (the "settle") of an
    /// editor-first section command for `n` milliseconds, after its queued job has applied and BEFORE the footnote, bibliography and
    /// section resyncs run (`StructuralUndoController.editorFirstJobSettled`, next to the unit tests' `testEFSettleHold`). It is a plain
    /// suspension (the writer is free), so the footnote burst timer can come due while the command is still unfinished: the drag test
    /// needs this because a drag's queued job is too short to hold with `FF_UI_TESTING_STRUCT_JOB_HOLD_MS`. `nil` (unset, unparseable,
    /// <= 0, or `isUITesting` false) means no hold. Same `isUITesting &&` guard as every sibling flag here.
    static var uiTestingEFSettleHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_EF_SETTLE_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// UI-test-only (t-f1a22aa7): `FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N=<n>` limits the `FF_UI_TESTING_EF_SETTLE_HOLD_MS` hold to the
    /// first `n` settles of this launch (counted by `holdEditorFirstSettle()`, in the order the settles reach the hold); every later
    /// settle runs without a hold, mirroring `FF_UI_TESTING_STRUCT_JOB_HOLD_FIRST_N`. Unlike that flag the default is ONE (unset or
    /// unparseable or <= 0 gives 1): a test that holds a settle almost always wants the command's own settle held and the undo that
    /// follows it free. Same `isUITesting &&` guard as every sibling flag here.
    static var uiTestingEFSettleHoldFirstN: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N"],
              let value = Int(raw), value > 0 else { return 1 }
        return value
    }

    /// How many settles `holdEditorFirstSettle()` has held so far in this launch.
    private static var efSettleHoldsGranted = 0

    /// Waits `uiTestingEFSettleHoldMs` milliseconds (a plain suspension) while fewer than `uiTestingEFSettleHoldFirstN` settles have been
    /// held in this launch; returns at once otherwise (every normal launch and every non-UI-test run: the first guard). Called where
    /// `editorFirstJobSettled` awaits `testEFSettleHold`. When a hold begins it persists one `[EF-SETTLE-HOLD]` line (the marker the
    /// drag test reads to prove the footnote timer came due INSIDE the hold, i.e. after the settle's own early work had ended).
    @MainActor
    static func holdEditorFirstSettle() async {
        guard let milliseconds = uiTestingEFSettleHoldMs, efSettleHoldsGranted < uiTestingEFSettleHoldFirstN else { return }
        efSettleHoldsGranted += 1
        DebugLog.alwaysPersisted("[EF-SETTLE-HOLD] editor first settle hold begins for \(milliseconds) milliseconds")
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// UI-test-only (t-2fbe4c9b, Phase 4c job 3): `FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS=<n>` makes the first Markdown structural command's
    /// page preparation (`prepareMarkdownPageForStructuralCommand`, steps 3 and 4 of the click) wait `n` milliseconds in a plain
    /// suspension, so a real-app test can make a click last longer than the "Finishing the last change…" notice's one-second delay. The
    /// wait holds no writer and no hold of its own beyond the one the click already holds. `nil` (unset, unparseable, <= 0, or
    /// `isUITesting` false) means no hold. Same `isUITesting &&` guard as every sibling flag here.
    static var uiTestingMdPagePrepareHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// UI-test-only (t-2fbe4c9b): `FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_FIRST_N=<n>` limits the `FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_MS` wait to
    /// the first `n` page preparations of this launch; every later one runs without it. The default is ONE (unset, unparseable or <= 0),
    /// like `FF_UI_TESTING_EF_SETTLE_HOLD_FIRST_N`. Same `isUITesting &&` guard as every sibling flag here.
    static var uiTestingMdPagePrepareHoldFirstN: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_MD_PAGE_PREPARE_HOLD_FIRST_N"],
              let value = Int(raw), value > 0 else { return 1 }
        return value
    }

    /// How many page preparations `holdMarkdownPagePrepare()` has held so far in this launch.
    private static var mdPagePrepareHoldsGranted = 0

    /// Waits `uiTestingMdPagePrepareHoldMs` milliseconds (a plain suspension) while fewer than `uiTestingMdPagePrepareHoldFirstN` page
    /// preparations have been held in this launch; returns at once otherwise (every normal launch and every non-UI-test run: the first
    /// guard). Called first in `prepareMarkdownPageForStructuralCommand`. Persists one `[MD-PREPARE-HOLD]` line when a hold begins.
    @MainActor
    static func holdMarkdownPagePrepare() async {
        guard let milliseconds = uiTestingMdPagePrepareHoldMs, mdPagePrepareHoldsGranted < uiTestingMdPagePrepareHoldFirstN else { return }
        mdPagePrepareHoldsGranted += 1
        DebugLog.alwaysPersisted("[MD-PREPARE-HOLD] markdown page preparation hold begins for \(milliseconds) milliseconds")
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// UI-test-only (Phase 5 job B3): `FF_UI_TESTING_PUSH_DROP=<n>` makes `ReportApplier` discard every n-th block report that
    /// arrives on the message handler for the first time (a re-post is never dropped), as if it were lost, so the recovery (the
    /// page's re-post, or Swift's gap fetch) must save its text.
    static var uiTestingPushDrop: Int? {
        guard isUITesting, let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_PUSH_DROP"],
              let value = Int(raw), value >= 1 else { return nil }
        return value
    }

    /// UI-test-only (Phase 5 job B4): `FF_UI_TESTING_PUSH_GAP_FETCH_OFF=1` turns Swift's gap fetch off (a report after a gap waits,
    /// parked, until the missing one arrives), so a test can prove the page's re-post alone recovers a dropped report.
    static var isUITestingPushGapFetchOff: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_PUSH_GAP_FETCH_OFF"] == "1"
    }

    /// UI-test-only (Phase 5 job B4): `FF_UI_TESTING_PUSH_REPOST_OFF=1` turns the page's re-post of unacknowledged reports off
    /// (`window.__FF_REPORTS__.repost = false`): the must-fail twin of the re-post test.
    static var isUITestingPushRepostOff: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_PUSH_REPOST_OFF"] == "1"
    }

    /// UI-test-only (Phase 5 job B2): `FF_UI_TESTING_REPORT_INTERVAL_MS=<n>` sets R, the least time between two block reports
    /// (report-outbox.ts, default 250), for the coalescing measurement.
    static var uiTestingReportIntervalMs: Int? {
        guard isUITesting, let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_REPORT_INTERVAL_MS"],
              let value = Int(raw), value >= 0 else { return nil }
        return value
    }

    /// UI-test-only (Phase 5 job B2): `FF_UI_TESTING_LAG_SAMPLER=1` starts the main-run-loop lag sampler (`MainLagSampler`).
    static var isUITestingLagSampler: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_LAG_SAMPLER"] == "1"
    }

    /// UI-test-only (t-633df056, Phase 5 job A5): `FF_UI_TESTING_MD_PAGE_READY_HOLD_MS=<n>` makes the FIRST Markdown (CodeMirror) page of
    /// this launch wait `n` milliseconds after its load has finished and BEFORE it is mounted (`onWebViewReady`, which moves the app's
    /// web-view pointers to it, and `batchInitialize`, which hands it its text: `CodeMirrorEditor.Coordinator.mountLoadedPageAfterTestHold`).
    /// It widens the window between the status-bar badge saying Markdown and the page being there (about 1 s idle, 2.5 s busy on the
    /// twelve-chapter book, VM figures), so a real-app test can press a section command inside it on purpose instead of racing it. A plain
    /// suspension: nothing is held, the badge and the mode have already flipped. `nil` (unset, unparseable, <= 0, or `isUITesting` false)
    /// means no hold and the mount runs synchronously, as always. Same `isUITesting &&` guard as every sibling flag here.
    static var uiTestingMdPageReadyHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_MD_PAGE_READY_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// Whether `holdMarkdownPageReady()` has already held the one page it holds in this launch.
    private static var mdPageReadyHoldGranted = false

    /// True while the next Markdown page mount is to be held (the variable is set and no page has been held yet in this launch). Read
    /// synchronously by the mount, so every page that is NOT held is mounted right there, with no task hop.
    @MainActor
    static var willHoldMarkdownPageReady: Bool { uiTestingMdPageReadyHoldMs != nil && !mdPageReadyHoldGranted }

    /// Waits `uiTestingMdPageReadyHoldMs` milliseconds (a plain suspension) for the first Markdown page of this launch; returns at once for
    /// every later page and in every normal launch (the first guard). Persists one `[MD-PAGE-READY-HOLD]` line when a hold begins (the
    /// marker the real-app test reads to prove the window was widened).
    @MainActor
    static func holdMarkdownPageReady() async {
        guard let milliseconds = uiTestingMdPageReadyHoldMs, !mdPageReadyHoldGranted else { return }
        mdPageReadyHoldGranted = true
        DebugLog.alwaysPersisted("[MD-PAGE-READY-HOLD] markdown page ready hold begins for \(milliseconds) milliseconds")
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// UI-test-only (board task t-dfc4fb02): `FF_UI_TESTING_FOOTNOTE_WRITE_HOLD_MS=<n>` delays the NOTES NOTIFICATION after the
    /// footnote write has committed (the writer is NOT blocked: a blocking hold trips the 5 s content-state watchdog and a plain
    /// whole-document push, see board). Concretely, `FootnoteSyncService.performFootnoteUpdate` waits `n` milliseconds in a plain
    /// suspension after its Notes write has applied and before it posts `.notesSectionChanged` (and pushes the definitions to the
    /// editor); the footnote renumber, posted earlier from the write's `prepare` step, has already reached the editor. Exists only
    /// so a UI test can type into the gap between the renumber and the Notes rebuild on purpose (Delete Section on a document with
    /// footnotes) instead of hoping to hit a window of a few milliseconds. `nil` (unset, unparseable, <= 0, or `isUITesting`
    /// false) means no delay. Same `isUITesting &&` guard as every sibling flag here, so a value left in a shell profile never
    /// slows a real user's footnote updates.
    static var uiTestingFootnoteWriteHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_FOOTNOTE_WRITE_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// The wait `uiTestingFootnoteWriteHoldMs` asks for, called by `FootnoteSyncService.performFootnoteUpdate` AFTER its Notes
    /// write has committed and BEFORE it posts `.notesSectionChanged`, so the renumber (posted from `prepare`) reaches the
    /// editor first and the Notes notification and push come later. A plain suspension: the database writer, the system write
    /// and `contentState` are all already free. Returns at once when unset (every normal launch, every non-UI-test run) or
    /// when the task is cancelled (the notification still goes out: the write has committed either way).
    static func holdFootnoteNotesNotification() async {
        guard let milliseconds = uiTestingFootnoteWriteHoldMs else { return }
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - Quick undo of an editor-first section delete (t-94369a83 Phase 4b slice 2b)
    //
    // Every seam below is read through `isUITesting &&`, so a value left in a shell profile can never change a real user's undo, and a
    // unit-test run can never set one. None of them blocks the database writer: the holds are plain suspensions (the writer, the
    // system write and `contentState` are all free while they wait), so the 5 s content-state watchdog never meets them.

    /// `FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N=<n>`: the first `n` Cmd-Z presses on an editor-first section delete (or, since
    /// t-18b7fa48 round 1e-i, an editor-first duplicate) that WOULD take the
    /// quick path take today's slow path instead (so a test can time old and new in one session). 0 (unset, unparseable, <= 0, or
    /// `isUITesting` false) means none. The decision is counted per launch, once per press, by `consumeSlowDeleteUndoSeam()`.
    static var uiTestingSlowDeleteUndoFirstN: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N"],
              let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    /// How many presses `consumeSlowDeleteUndoSeam()` has forced slow so far in this launch.
    private static var slowDeleteUndosForced = 0

    /// True (and counted) while fewer than `uiTestingSlowDeleteUndoFirstN` presses have been forced slow in this launch.
    @MainActor
    static func consumeSlowDeleteUndoSeam() -> Bool {
        guard slowDeleteUndosForced < uiTestingSlowDeleteUndoFirstN else { return false }
        slowDeleteUndosForced += 1
        return true
    }

    /// `FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS=<n>`: the quick undo waits `n` ms between the editor's restore (`quick restore done`)
    /// and the start of the reinsert, so the window holds nothing but the paused editor: the reinsert, its sidebar update and the Notes
    /// / bibliography rebuild it triggers all start after the wait, and none can land inside it and end the editor's pause early
    /// (`resumeSyncAfterQuickUndo` follows the reinsert's reservation, still after the wait). Block-sync is paused and the writer is
    /// free for that whole time, so a UI test can type into the paused window on purpose instead of hoping to hit a few
    /// milliseconds. `nil` means no wait.
    static var uiTestingQuickUndoResumeHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_QUICK_UNDO_RESUME_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// `FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS=<n>`: the reinsert's settle (the resyncs and the push of the database's Notes and
    /// Bibliography into the editor) waits `n` ms after the reinsert's rows have committed, before its first step. A plain
    /// suspension: the writer is free. `nil` means no wait.
    static var uiTestingReinsertSettleHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_REINSERT_SETTLE_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// The wait `uiTestingQuickUndoResumeHoldMs` asks for. Logs its two ends twice: with `NSLog` (unified log) and with `DebugLog` at
    /// `.undo` (diagnostic.log, like the other quick-undo lines), `op` being the entry's first 8 characters, so a test can show that
    /// every key it typed fell inside.
    @MainActor   // code review C-L2: no hop to the global executor and back when the seam is off
    static func holdQuickUndoResume(opId: String) async {
        guard let milliseconds = uiTestingQuickUndoResumeHoldMs else { return }
        NSLog("[QuickUndoHold] resume-hold START delayMs=\(milliseconds)")
        DebugLog.log(.undo, "[QuickUndoHold] start ms=\(milliseconds) op=\(opId)")
        try? await Task.sleep(for: .milliseconds(milliseconds))
        DebugLog.log(.undo, "[QuickUndoHold] end op=\(opId)")
        NSLog("[QuickUndoHold] resume-hold END")
    }

    /// The wait `uiTestingReinsertSettleHoldMs` asks for (same logging, marker family `[ReinsertSettleHold]`).
    @MainActor   // code review C-L2: as above
    static func holdReinsertSettle(opId: String) async {
        guard let milliseconds = uiTestingReinsertSettleHoldMs else { return }
        NSLog("[QuickUndoHold] settle-hold START delayMs=\(milliseconds)")
        DebugLog.log(.undo, "[ReinsertSettleHold] start ms=\(milliseconds) op=\(opId)")
        try? await Task.sleep(for: .milliseconds(milliseconds))
        DebugLog.log(.undo, "[ReinsertSettleHold] end op=\(opId)")
        NSLog("[QuickUndoHold] settle-hold END")
    }

    /// `FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS=<n>` (t-18b7fa48 round 3d; t-d2061b27 added the Markdown twin and the Rich Text quick undo):
    /// a SLOW (snapshot) undo or redo waits `n` ms (clamped to 15,000) after its plan has been read and BEFORE its swap. BOTH slow routes
    /// and the Rich Text QUICK undo call it: the Rich Text slow one (`StructuralUndoController.queuedSnapshotUndo`, before its swap click),
    /// the Markdown slow one (`markdownQueuedSnapshotUndo`, before the press raises its own writer hold and calls the page) and the Rich
    /// Text quick undo (`performQuickUndoOfDelete`, which serves Delete, Duplicate and the three restores). It makes the window the
    /// model calls EFSnapTypedInWait (the user types
    /// between the press and the swap) as wide as a UI test needs, instead of hoping that the test's own typing falls inside the few
    /// hundred milliseconds a real wait leaves it, or inside a writer hold, which cannot exceed about 3.9 s (the content-state watchdog
    /// fires at 5 s). The wait is on the Swift side only: a plain `Task.sleep` on the main actor in the press's gate turn, as a real wait
    /// for a delete's job is; the editor is live and the writer is free, so the typing is seen by the page's swap exactly as typing during
    /// a real wait is: the page recorded it since the press, held its pushes, and now puts it back on top of the swapped-in document
    /// (`typingReplayed`), no refusal. `nil` (unset, unparseable, <= 0, or `isUITesting` false) means no wait, and nothing differs from a
    /// normal press. Same `isUITesting &&` guard as every sibling flag, so a value left in a shell profile never slows a real user's undo.
    ///
    /// WHERE IT SITS (Markdown route, review F15): right after the route's wait for the previous job (`awaitStructuralHoldReleased`) and
    /// BEFORE the guards that follow a real wait (`isClosedToNewWork` -> `.cancelled`, a lifecycle armed, zoom, the timeline epoch), so
    /// it stands for that wait: a Cmd-W, Cmd-Q or project switch that begins during the hold cancels the press the way it cancels one
    /// that waited for a job. The Rich Text slow route's seam sits after its plan is read, as it always did.
    ///
    /// WHERE IT SITS (Rich Text quick undo, round S5): in `performQuickUndoOfDelete`, right after its `start (quick)` trace line and BEFORE
    /// `quickUndoBody`, i.e. before anything is mutated (the click flag, the epoch bump, the counters, the registry, the writer ticket).
    /// The quick undo is one synchronous stretch and does not wait behind the delete's held job (only its reinsert queues behind it), so
    /// the page's latch lasts only a few milliseconds and a UI test cannot type into a wait; this hold stands for that wait. A press
    /// forced onto the slow path (`FF_UI_TESTING_SLOW_DELETE_UNDO_FIRST_N`, `testForceSlowDeleteUndo`) returns nil from `resolveQuickPath`
    /// before it gets here, so it holds once, in the slow route, never twice. The quick REDO has no such seam.
    ///
    /// WATCHDOG INTERPLAY (Markdown route, read from the code 2026-10-31 for t-d2061b27, not measured): the sleep runs before this press
    /// raises its writer hold
    /// (`beginStructuralHold`) and before anything sets `contentState`, and the previous Markdown job's hold has already been released
    /// (`awaitStructuralHoldReleased` returned), so neither the writer's 5 s stall backstop nor the content-state watchdog is running
    /// while it sleeps; its only bounds are the 15 s clamp above and the page's 30 s latch timeout (`LATCH_TIMEOUT_MS`, which would
    /// release the latch under a held press). The Phase 4c UI tests (`WriteQueuePhase4cTypingAcrossUndoE2ETests`) hold 8,000 ms on the
    /// Rich Text slow route (the 12-chapter driver needs more than 3.5 s from the Cmd-Z to its first key), 3,500 ms on the Markdown slow
    /// route and 3,000 ms on the Rich Text quick route (the Markdown quick routes use the job hold instead, 3,500 ms). Keep any use of
    /// the Markdown route at or under about 3,900 ms, the limit the hold knobs above have, since that is the proven-safe number.
    static var uiTestingSlowUndoPressHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_SLOW_UNDO_PRESS_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return min(value, 15_000)
    }

    /// The wait `uiTestingSlowUndoPressHoldMs` asks for, called ONCE per press by `queuedSnapshotUndo` (Rich Text), by
    /// `markdownQueuedSnapshotUndo` (Markdown; right after its wait for the previous job, before its post-wait guards) and by
    /// `performQuickUndoOfDelete` (the Rich Text quick undo, before anything is mutated) before the
    /// first swap (not again before the `noCheckpoint` fallback's second click). The marker is the same for every route; the press's
    /// own `[STRUCT-TRACE]` lines
    /// (`start (editor-first undo)` / `start (markdown queued undo)` / `start (quick)`) say which one it was. Logs its two ends at `.undo`
    /// (diagnostic.log, marker family `[SlowUndoPressHold]`, `op` being the entry's first 8 characters), so a test can show that every key
    /// it typed fell inside. A plain suspension: nothing is blocked. Returns at once when unset (every normal launch).
    @MainActor
    static func holdSlowUndoPress(opId: String) async {
        guard let milliseconds = uiTestingSlowUndoPressHoldMs else { return }
        DebugLog.log(.undo, "[SlowUndoPressHold] start ms=\(milliseconds) op=\(opId)")
        try? await Task.sleep(for: .milliseconds(milliseconds))
        DebugLog.log(.undo, "[SlowUndoPressHold] end op=\(opId)")
    }

    /// `FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS=<n>`: ONE idle backup per launch fires after `n` seconds of idle instead of 60, and only
    /// AFTER the first editor-first section delete of the launch: the seam stays dormant (every idle timer takes the real 60 s) until
    /// `armAutoBackupIdleSeamAfterStructuralClick()` has run at that delete's click, so the document load cannot use the one firing up before the
    /// delete. From then on the next idle timer that is armed (the delete's own content change arms one) uses `n`;
    /// `consumeAutoBackupIdleSeam()` is called when it really fires and the seam is spent. The 5-minute minimum between backups is NOT
    /// changed, so later backups do not add flushes at random moments. `nil` means the real timing.
    static var uiTestingAutoBackupIdleSeconds: Double? {
        guard isUITesting, autoBackupIdleSeamArmed, !autoBackupIdleSeamFired,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_AUTOBACKUP_IDLE_SECONDS"],
              let value = Double(raw), value > 0 else { return nil }
        return value
    }

    private static var autoBackupIdleSeamArmed = false
    private static var autoBackupIdleSeamFired = false

    /// Called by `runEditorFirstStructuralClick` at the first editor-first structural click (a section delete or a duplicate): from
    /// here on the idle seam may take effect. A no-op outside a UI test (the getter above checks `isUITesting` and the variable
    /// again). (Named `...AfterDelete` until t-18b7fa48 round 1e-i, when a duplicate began to arm it too.)
    @MainActor
    static func armAutoBackupIdleSeamAfterStructuralClick() {
        guard isUITesting else { return }
        autoBackupIdleSeamArmed = true
    }

    /// UI-test-only (Phase 5 job B4): `FF_UI_TESTING_AUTOBACKUP_NO_LIVE_FLUSH=1` makes an idle auto-backup snapshot what the database
    /// already holds and skip its live whole-document flush, which gives most rows new ids. Tests that compare row ids before and
    /// after a command (the Version History restore tests) set it, because the real idle backup can fall in the middle of such a test.
    /// Until Phase 5 the poll's first tick started an early idle backup in every launch, and its "too soon" rule then kept the real one
    /// away for five minutes; with no poll the first idle backup is the one after the test's own edit. False outside a UI test.
    static var uiTestingAutoBackupNoLiveFlush: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_AUTOBACKUP_NO_LIVE_FLUSH"] == "1"
    }

    /// UI-test-only (t-18b7fa48 round 1e-i): `FF_UI_TESTING_LEGACY_STRUCTURAL=1` makes Duplicate Section and (round 2d-i) the
    /// whole-project version restore take today's whole sequence (flush the editor, undo-point copy, copy the rows, push the whole
    /// document back) instead of the editor-first path, so a UI test can time old and new in one session. Later rounds extend it to
    /// the two section restores and the slow undo and redo. Delete
    /// Section keeps its own flag (`isUITestingStructuralLegacyDelete`). Same `isUITesting &&` guard as every sibling flag, so a value
    /// left in a shell profile never switches the fast duplicate off for a real user and a unit-test run can never set it.
    static var isUITestingLegacyStructural: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_LEGACY_STRUCTURAL"] == "1"
    }

    /// Called by `AutoBackupService` when an idle timer that used the seam's wait has really fired: the seam is spent for this launch.
    @MainActor
    static func consumeAutoBackupIdleSeam() {
        autoBackupIdleSeamFired = true
    }

    /// UI-test-only deterministic main-window width, consumed by
    /// `FinalFinalApp.defaultWindowPlacement` and, as a backstop once the window exists, by
    /// `AppDelegate.applyUITestingWindowWidthOverride(to:)`. Exists because the Outline sidebar's
    /// divider-drag regression test has to assert against a KNOWN starting window width, and the
    /// saved-frame branch of that placement closure is deliberately skipped while testing (so
    /// otherwise the default 1400x900/min(visible) size would apply, which varies with the
    /// display). `nil` (unset, unparseable, <= 0, or `isUITesting` false) leaves the real
    /// placement untouched -- read fresh on every access like every sibling flag here, so it can
    /// never silently latch a stale value.
    static var uiTestingWindowWidthOverride: CGFloat? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_WINDOW_WIDTH"],
              let value = Double(raw), value > 0 else { return nil }
        return CGFloat(value)
    }

    /// UI-test-only: `FF_UI_TESTING_ENABLE_PRELOADER=1` lets `EditorPreloader` run
    /// under UI testing exactly as it does in production (it otherwise returns at its first line when `TestMode.isTesting`),
    /// so the incoming editor of a mode switch is normally a claimed, already page-loaded spare instead of a view created and
    /// page-loaded from scratch. It changes nothing else in the preloader. Unset (or anything but "1"): today's path exactly.
    /// Same `isUITesting &&` guard as every sibling flag here, so a unit-test run can never enable it.
    static var isUITestingEditorPreloaderEnabled: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_ENABLE_PRELOADER"] == "1"
    }

    // MARK: - Citation prefill (plan-citations-ahead-of-time.md)

    /// What `FF_UI_TESTING_CITATION_PREFILL` asks for. The app works the document's citations out ahead of time by default
    /// (`CitationPrefillScheduler`); the variable exists only so a UI test can measure the other columns. A UI test that sets nothing
    /// gets the app as the user has it.
    enum UITestingCitationPrefillMode: String {
        /// No scheduler: the standby page never works citations out ahead of time. The page's citation memo stays on.
        case off
        /// The page's citation memo is turned off at every Rich Text page load (`window.FinalFinal.setCitationMemoEnabled(false)`),
        /// which restores today's one-formatting-per-citation behaviour; the scheduler is off too (it would have nothing to fill).
        case memoOff
        /// Accepted so a launch environment written for the measurement before the scheduler existed still parses. Means exactly
        /// what an unset variable means: the scheduler is on.
        case trigger
    }

    /// The pure part of `uiTestingCitationPrefillMode`: only a UI-test launch honours the variable, and an unknown value is ignored.
    static func citationPrefillMode(environment: [String: String], isUITesting: Bool) -> UITestingCitationPrefillMode? {
        guard isUITesting, let raw = environment["FF_UI_TESTING_CITATION_PREFILL"] else { return nil }
        return UITestingCitationPrefillMode(rawValue: raw)
    }

    /// `FF_UI_TESTING_CITATION_PREFILL` = `off` | `memoOff` | `trigger` (= unset). Read once. Same `isUITesting &&` guard as every sibling flag here.
    static let uiTestingCitationPrefillMode: UITestingCitationPrefillMode? =
        citationPrefillMode(environment: ProcessInfo.processInfo.environment, isUITesting: isUITesting)

    /// True when every Rich Text page must run with its citation memo off (the "today" column of the measurement).
    static var isUITestingCitationMemoOff: Bool { uiTestingCitationPrefillMode == .memoOff }

    /// Whether `EditorPreloader.startPreloading()` creates the citation-prefill scheduler: always, except in a UI test that asked for
    /// `off` or `memoOff`. Unit tests never start the preloader, so they never get one either way.
    static var isCitationPrefillSchedulerEnabled: Bool { citationPrefillSchedulerEnabled(for: uiTestingCitationPrefillMode) }

    /// The pure part of `isCitationPrefillSchedulerEnabled`.
    static func citationPrefillSchedulerEnabled(for mode: UITestingCitationPrefillMode?) -> Bool {
        switch mode {
        case .off?, .memoOff?: return false
        case .trigger?, nil: return true
        }
    }

    /// Clears UserDefaults keys that could interfere with test isolation.
    ///
    /// Operates on `AppDefaults.store` — an isolated suite while testing, never the real
    /// `.standard` domain — so this never wipes a real user's persisted state. See
    /// `AppDefaults.swift` for why that indirection is necessary.
    ///
    /// - Parameter preservingLastProjectBookmark: when true, skips wiping
    ///   `lastProjectBookmark` — needed by `shouldExerciseRestoreLastProject`'s second launch,
    ///   which must read back the bookmark a prior launch in the same test just saved. Every
    ///   other caller wants the normal full wipe (default `false`).
    static func clearTestState(preservingLastProjectBookmark: Bool = false) {
        let defaults = AppDefaults.store
        if !preservingLastProjectBookmark {
            defaults.removeObject(forKey: "com.kerim.final-final.lastProjectBookmark")
        }
        defaults.removeObject(forKey: "com.kerim.final-final.recentProjects")
        defaults.removeObject(forKey: "com.kerim.final-final.lastSeenVersion")
        defaults.removeObject(forKey: "focusModeEnabled")
        defaults.removeObject(forKey: "com.kerim.final-final.focusModeSettings")
        defaults.removeObject(forKey: "hasSeenSubtreeDragHint")
        defaults.removeObject(forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        defaults.removeObject(forKey: "com.kerim.final-final.diagnosticsLastReportGeneratedAt")
        // The app-wide annotation display default ("Set as Default"). The isolated suite is a plist
        // on disk shared by every unit-test RUN, so a run cut short between a test setting one
        // and restoring it must not leave the next run starting from a non-neutral default.
        defaults.removeObject(forKey: AnnotationDisplayDefaults.defaultsKey)
        // Must come AFTER the removeObject above -- invalidating first would leave a window
        // where a concurrent isEnabled read on another thread could repopulate the cache with
        // the pre-removal value. See DiagnosticLogFile.invalidateEnabledCache's doc comment.
        DiagnosticLogFile.invalidateEnabledCache()
    }
}

// MARK: - Phase 5 job A7: the zoom and switch transitions (docs/architecture/write-queue-plan/phase5/a7-a10-design.md, section 6)

/// Which transition a `FF_UI_TESTING_LEGACY_TRANSITION` value turns back to today's path.
enum UITestingTransitionKind {
    case zoom
    case modeSwitch
}

extension TestMode {
    /// UI-test-only: `FF_UI_TESTING_LEGACY_TRANSITION=1|zoom|switch` makes the named transitions take today's code path (`1`: zoom and the
    /// Rich Text / Markdown switch; `zoom`: the zooms only; `switch`: the switches only), so each job's A/B (speed, and the must-fail run of
    /// the typing test) runs on one build. Removed with the legacy path after the user's approval. Same `isUITesting &&` guard as every
    /// sibling flag.
    static func isUITestingLegacyTransition(for kind: UITestingTransitionKind) -> Bool {
        guard isUITesting, let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_LEGACY_TRANSITION"] else { return false }
        switch raw {
        case "1": return true
        case "zoom": return kind == .zoom
        case "switch": return kind == .modeSwitch
        default: return false
        }
    }

    /// UI-test-only: `FF_UI_TESTING_TRANS_HOLD_MS=<n>` makes a transition wait `n` milliseconds (a plain suspension) inside the window in
    /// which typing used to be lost, so a real-app test can type there on purpose (the driver cannot type earlier than about 0.3 to 1 s
    /// after a command). New path (a Rich Text zoom): after the barrier, while the page holds and records the typing, before the rows are
    /// read and swapped in. Legacy path: after `flushContentToDatabase` and before the push, which is where today's loss lives. `nil`
    /// (unset, unparseable, <= 0, or `isUITesting` false) means no hold.
    static var uiTestingTransHoldMs: Int? {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_TRANS_HOLD_MS"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// UI-test-only: `FF_UI_TESTING_TRANS_HOLD_FIRST_N=<n>` limits `FF_UI_TESTING_TRANS_HOLD_MS` to the first `n` transitions of this
    /// launch. Default ONE (unset, unparseable or <= 0).
    static var uiTestingTransHoldFirstN: Int {
        guard isUITesting,
              let raw = ProcessInfo.processInfo.environment["FF_UI_TESTING_TRANS_HOLD_FIRST_N"],
              let value = Int(raw), value > 0 else { return 1 }
        return value
    }

    /// How many transitions `holdTransition(_:)` has held so far in this launch.
    @MainActor private static var transHoldsGranted = 0

    /// Waits `uiTestingTransHoldMs` milliseconds while fewer than `uiTestingTransHoldFirstN` transitions have been held in this launch;
    /// returns at once otherwise (every normal launch: the first guard). Persists one `[TRANS-HOLD]` line when a hold begins (the marker
    /// the real-app test reads to prove the window was really widened) and one when it ends.
    @MainActor
    static func holdTransition(_ label: String) async {
        guard let milliseconds = uiTestingTransHoldMs, transHoldsGranted < uiTestingTransHoldFirstN else { return }
        transHoldsGranted += 1
        DebugLog.alwaysPersisted("[TRANS-HOLD] \(label) hold begins for \(milliseconds) ms")
        try? await Task.sleep(for: .milliseconds(milliseconds))
        DebugLog.alwaysPersisted("[TRANS-HOLD] \(label) hold ends")
    }
}
