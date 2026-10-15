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
