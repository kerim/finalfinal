//
//  UITestHelpers.swift
//  final finalUITests
//
//  Helpers for XCUITest smoke tests: launch configuration,
//  fixture setup, and wait utilities.
//

import XCTest

// MARK: - Launch Helpers

extension XCUIApplication {
    /// Creates an XCUIApplication targeting our app by bundle identifier.
    /// Explicit ID avoids issues with the pipe character in PRODUCT_NAME.
    static func targetApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.kerim.final-final.testhost")
    }

    /// Launches the app in UI testing mode without a fixture (shows picker)
    func launchForTesting() {
        Self.cleanSavedApplicationState()
        // Defense-in-depth: Apple documents that `launch()` already terminates any
        // running instance before starting fresh, so this call is expected to be a
        // no-op in the common case. It costs nothing if redundant and closes the
        // gap if that documented behavior ever doesn't hold in practice.
        terminate()
        launchEnvironment["FF_UI_TESTING"] = "1"
        launch()
        activateAndWaitForForeground()
    }

    /// Launches the app in UI testing mode with a fixture (shows editor)
    func launchForTesting(fixturePath: String) {
        Self.cleanSavedApplicationState()
        terminate()
        launchEnvironment["FF_UI_TESTING"] = "1"
        launchEnvironment["FF_TEST_FIXTURE_PATH"] = fixturePath
        launch()
        activateAndWaitForForeground()
    }

    /// Re-activates the app and waits for it to report the foreground state
    /// before returning. `launch()`/`activate()` only guarantee foreground state
    /// at the instant they return (per Apple's XCUIApplication.h) — nothing
    /// guarantees focus is still there by the time a later keyboard-shortcut
    /// action fires. Call this immediately before any `typeKey` call, not just
    /// after launch, so a focus problem produces a clear, self-describing
    /// failure instead of an unrelated-looking assertion failure downstream.
    @discardableResult
    func activateAndWaitForForeground(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        activate()
        let result = wait(for: .runningForeground, timeout: timeout)
        if !result {
            XCTFail("""
                App did not reach the foreground within \(timeout)s. This is a \
                window-focus/process collision, not a real test failure — see \
                "UI test environment requirements" in docs/guides/running-tests.md.
                """, file: file, line: line)
        }
        return result
    }

    /// Remove saved window state so each test run starts fresh.
    /// This replaces `-ApplePersistenceIgnoreState YES` which prevents
    /// SwiftUI's WindowGroup from creating any window at all.
    ///
    /// Note: NSHomeDirectory() in the test runner may differ from the app's home.
    /// We clean both the test runner's home AND the real user home to be safe.
    private static func cleanSavedApplicationState() {
        // The Test action builds the app as com.kerim.final-final.testhost
        // (project.yml's DebugTest config), so only the testhost domain is
        // cleaned. The production domain (com.kerim.final-final.savedState)
        // is deliberately untouched — an earlier version deleted it from the
        // real user home on every test launch, silently discarding the
        // user's own saved window state.
        let bundleState = "Library/Saved Application State/com.kerim.final-final.testhost.savedState"
        let testRunnerPath = NSHomeDirectory() + "/" + bundleState

        // Also try the real user home (in case test runner home differs)
        let realUserHome = FileManager.default.homeDirectoryForCurrentUser.path
        let realUserPath = realUserHome + "/" + bundleState

        try? FileManager.default.removeItem(atPath: testRunnerPath)
        if realUserPath != testRunnerPath {
            try? FileManager.default.removeItem(atPath: realUserPath)
        }
    }
}

// MARK: - Wait Helpers

extension XCUIElement {
    /// Waits for the element to exist and returns it, or fails.
    @discardableResult
    func waitForExistenceOrFail(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCTFail("Element \(debugDescription) did not appear within \(timeout)s", file: file, line: line)
        }
        return self
    }

    /// Waits for the element to disappear.
    func waitForDisappearance(timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility value to match a predicate.
    /// SwiftUI `Text` views with explicit `.accessibilityIdentifier()` put their
    /// content in `value`, not `label`.
    /// Example: `element.waitForValue("== 'WYSIWYG'")`
    /// Example: `element.waitForValue("CONTAINS 'words'")`
    func waitForValue(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility label to match a predicate.
    /// SwiftUI `Button` elements expose their `Text` label content in `label`, not `value`.
    /// Example: `element.waitForLabel("== 'WYSIWYG'")`
    func waitForLabel(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - Screenshot Evidence Helpers

enum E2EShotDir {
    /// Where a disposable e2e test should write its screenshot evidence.
    ///
    /// Reads `FF_E2E_SHOT_DIR` from the process environment — set by
    /// `vmtest` (as `TEST_RUNNER_FF_E2E_SHOT_DIR`, which xcodebuild forwards
    /// to the runner process with the prefix stripped) or directly by the
    /// `e2e-verify` skill for a host run.
    ///
    /// Three cases, deliberately distinct:
    /// - Unset → `NSTemporaryDirectory()`, which the runner can always write
    ///   to (already relied on by `TestFixtureHelper.fixturePath` above).
    ///   This is the safe default when nobody wired anything up.
    /// - Set to an absolute path (starts with "/") → used as-is. This is the
    ///   host case: `e2e-verify`/superdev pass an explicit run-notes folder.
    /// - Set to a bare relative name → resolved against `NSHomeDirectory()`
    ///   **at runtime, inside this process**. This is the VM-guest case:
    ///   `vmtest` cannot know the runner's container path in advance (it
    ///   contains a UUID chosen when the runner launches), so it passes a
    ///   relative name and lets the sandboxed process resolve its own home —
    ///   which the POC proved is the one writable location in the guest, and
    ///   which matches `export-evidence.sh`'s existing container-glob
    ///   discovery (`Containers/*xctrunner/Data/e2e-shots`).
    ///
    /// Never a *bare* `NSHomeDirectory()` default — outside a VM the runner's
    /// home can be the user's real home, and a silent default there would
    /// grow an unpruned `~/e2e-shots/`. Here it is only ever reached when
    /// `vmtest` deliberately opts in with a relative value.
    static var path: String {
        guard let dir = ProcessInfo.processInfo.environment["FF_E2E_SHOT_DIR"], !dir.isEmpty else {
            return NSTemporaryDirectory() + "ff-e2e-shots"
        }
        if dir.hasPrefix("/") {
            return dir
        }
        return NSHomeDirectory() + "/" + dir
    }

    /// `path` as a URL, creating the directory if it does not exist yet.
    static var url: URL {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Fixture Helpers

enum TestFixtureHelper {
    /// Backing storage for the per-test fixture path. XCTest runs one test's
    /// setUp -> test -> tearDown serially before starting the next, so there is
    /// no real concurrent access here -- `nonisolated(unsafe)` documents that
    /// this mutable static is safe under that serial-execution contract, which
    /// Swift 6 strict concurrency cannot see on its own.
    private nonisolated(unsafe) static var currentFixturePath: String?

    /// The per-test fixture path, assigned fresh by `setupFixture(from:)` and
    /// cleared by `cleanupFixture()`. Each test gets its own
    /// `ff-test-fixture-<UUID>.ff` under `NSTemporaryDirectory()` rather than a
    /// single shared path, so one test's fixture file can't be read, mutated,
    /// or torn down out from under a previously-running test.
    ///
    /// Reading this before `setupFixture(from:)` has run (or after
    /// `cleanupFixture()` already ran) is a test-authoring bug: the old shared
    /// `static let` would have silently handed back a stale path left over
    /// from whatever test ran last, which is exactly the cross-test pollution
    /// this per-test isolation exists to prevent. Fail loudly instead of
    /// reproducing that silently-stale behavior -- via `XCTFail` rather than
    /// `fatalError`, so the misuse fails only the one offending test instead
    /// of killing the whole XCUITest runner process. Every current call site
    /// runs with `continueAfterFailure = false`, so `XCTFail` unwinds the test
    /// immediately and the sentinel path below is never actually consumed in
    /// practice; it exists only to satisfy this property's non-throwing
    /// `String` return type.
    static var fixturePath: String {
        guard let currentFixturePath else {
            XCTFail(
                "TestFixtureHelper.fixturePath read before setupFixture(from:) was called (or after "
                    + "cleanupFixture() already ran) -- call setupFixture(from:) in this test's setUp first."
            )
            return "/dev/null/TestFixtureHelper-fixturePath-read-before-setupFixture"
        }
        return currentFixturePath
    }

    /// Copies the committed fixture from the UI test bundle to a fresh,
    /// per-test path in the temp directory. Must be called in setUp before
    /// launching the app.
    static func setupFixture(from testCase: XCTestCase) throws {
        let fm = FileManager.default
        let path = NSTemporaryDirectory() + "ff-test-fixture-\(UUID().uuidString).ff"

        // Find fixture in the UI test bundle using URL-based path
        let bundle = Bundle(for: type(of: testCase))
        guard let fixtureSource = bundle.resourceURL?
            .appendingPathComponent("Fixtures/test-fixture.ff"),
              fm.fileExists(atPath: fixtureSource.path) else {
            XCTFail("Test fixture not found in UI test bundle. Ensure FixtureGeneratorTests has run and fixture is committed.")
            return
        }

        // Fresh copy for test isolation
        try? fm.removeItem(atPath: path)
        try fm.copyItem(at: fixtureSource, to: URL(fileURLWithPath: path))

        // Only publish the path once the copy has actually succeeded --
        // assigning it earlier would let a failed bundle lookup or copy leave
        // `currentFixturePath` pointing at a file that doesn't exist.
        currentFixturePath = path

        print("[TestFixture] Fixture copied to: \(path)")
    }

    /// Removes the test fixture and clears the stored path. Call from
    /// tearDown. A documented no-op when no fixture is currently set -- e.g. a
    /// test method that never called `setupFixture(from:)` sharing a
    /// `tearDown`/`tearDownWithError` with a sibling method that did (see
    /// ProjectOpenErrorE2ETests, where `tearDownWithError` calls this
    /// unconditionally but only one of its two test methods calls
    /// `setupFixture`).
    static func cleanupFixture() {
        guard let path = currentFixturePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        currentFixturePath = nil
    }
}
