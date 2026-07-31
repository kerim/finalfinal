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
    static var isUITestingWithScratchRecentProjectsAllowed: Bool {
        isUITesting && ProcessInfo.processInfo.environment["FF_UI_TESTING_ALLOW_SCRATCH_RECENT_PROJECTS"] == "1"
    }

    /// Clears UserDefaults keys that could interfere with test isolation.
    ///
    /// Operates on `AppDefaults.store` — an isolated suite while testing, never the real
    /// `.standard` domain — so this never wipes a real user's persisted state. See
    /// `AppDefaults.swift` for why that indirection is necessary.
    static func clearTestState() {
        let defaults = AppDefaults.store
        defaults.removeObject(forKey: "com.kerim.final-final.lastProjectBookmark")
        defaults.removeObject(forKey: "com.kerim.final-final.recentProjects")
        defaults.removeObject(forKey: "com.kerim.final-final.lastSeenVersion")
        defaults.removeObject(forKey: "focusModeEnabled")
        defaults.removeObject(forKey: "com.kerim.final-final.focusModeSettings")
        defaults.removeObject(forKey: "hasSeenSubtreeDragHint")
        defaults.removeObject(forKey: DiagnosticLogFile.loggingEnabledDefaultsKey)
        defaults.removeObject(forKey: "com.kerim.final-final.diagnosticsLastReportGeneratedAt")
    }
}
