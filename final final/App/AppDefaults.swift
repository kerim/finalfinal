//
//  AppDefaults.swift
//  final final
//
//  Central UserDefaults indirection for the handful of keys `TestMode.clearTestState()`
//  resets between test runs.
//
//  Why this exists: unit tests are hosted *inside* the real app process (XCTest injects the
//  test bundle into `final final.app` and runs it there), so `UserDefaults.standard` during a
//  unit test run IS the user's real, live `com.kerim.final-final` defaults domain — not a
//  sandboxed double (see `FinalFinalApp.swift`'s own comment on this). `scripts/build.sh` runs
//  the full unit-test suite before every release build, and several tests call
//  `TestMode.clearTestState()` directly in their setup helpers. Before this indirection
//  existed, that meant every release build permanently wiped the user's real Recent Projects
//  list, last-opened-project bookmark, focus mode preferences, and the other keys below.
//
//  The fix: route every one of those keys through `AppDefaults.store` instead of
//  `UserDefaults.standard` directly. In production this is `.standard`, unchanged. While any
//  kind of test is running (`TestMode.isTesting`), it's a separate, resettable
//  `UserDefaults(suiteName:)` instance instead, so `clearTestState()` — and everything that
//  reads/writes one of its nine keys (the eight `clearTestState()` manages directly, plus
//  `ExportService.userDefaults`'s `exportDiagnosticCaptureEnabled`, which also defaults to
//  this store so it shares a domain with `DiagnosticsSettings.userDefaults`) — only ever
//  touches that isolated domain.
//

import Foundation

enum AppDefaults {
    private static let testSuiteName = "com.kerim.final-final.testing"

    /// Isolated backing store used for the nine `AppDefaults.store`-routed keys while any kind
    /// of test is running. Created once per process and shared by every property that reads
    /// through `store`, so `clearTestState()` clears the exact same store every one of those
    /// properties sees.
    ///
    /// If suite creation ever fails, falling back to `.standard` here would silently defeat
    /// the whole point of this indirection — `clearTestState()` would resume wiping the real
    /// user's domain during every test run. Fail loudly instead: this should be unreachable in
    /// practice (`UserDefaults(suiteName:)` only returns `nil` for a malformed suite name, and
    /// `testSuiteName` is a fixed, valid literal), so a crash here is preferable to silent data
    /// loss.
    private static let testStore: UserDefaults = {
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            preconditionFailure(
                "AppDefaults.testStore: UserDefaults(suiteName: \"\(testSuiteName)\") returned nil. " +
                "Falling back to .standard here would silently defeat test isolation and let " +
                "clearTestState() wipe the real user's UserDefaults.standard domain."
            )
        }
        return suite
    }()

    /// The UserDefaults domain the nine test-isolated keys should go through: `.standard` in
    /// production, an isolated per-process suite under any kind of test run.
    static var store: UserDefaults {
        TestMode.isTesting ? testStore : .standard
    }

    /// Wipes the whole isolated test suite domain — every key, not just the nine
    /// `TestMode.clearTestState()` knows about. UI-test launches only (see
    /// `AppDelegate.applicationWillFinishLaunching`): each UI test gets its own app
    /// process, so nothing in-process can be clobbered, and the suite's plist otherwise
    /// persists state from one test's launch into the next. Unit tests must keep using
    /// `clearTestState()`'s surgical key list instead — they share one process, and a
    /// whole-domain wipe there could clobber state a concurrently-running test relies on.
    static func wipeTestDomainForUITesting() {
        guard TestMode.isUITesting else { return }
        testStore.removePersistentDomain(forName: testSuiteName)
    }
}
