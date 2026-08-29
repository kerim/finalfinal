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
        // Must come AFTER the removeObject above -- invalidating first would leave a window
        // where a concurrent isEnabled read on another thread could repopulate the cache with
        // the pre-removal value. See DiagnosticLogFile.invalidateEnabledCache's doc comment.
        DiagnosticLogFile.invalidateEnabledCache()
    }
}
