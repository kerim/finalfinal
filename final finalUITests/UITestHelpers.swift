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
    ///
    /// `predicateFormat` is prefixed with `"value "`, so it must be an infix
    /// comparison (`== 'x'`, `CONTAINS 'x'`, `!= 'x'`, ...), not an expression
    /// that starts with a logical operator like `NOT (...)` — prefixing that
    /// produces invalid predicate syntax (`value NOT (...)`) and throws at
    /// parse time. Use `waitForValueNot(_:)` for negation.
    func waitForValue(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility value to NOT match a predicate.
    /// Example: `element.waitForValueNot("CONTAINS 'words'")` waits until the
    /// value no longer contains "words", correctly building `NOT (value CONTAINS 'words')`.
    /// `predicateFormat` must still be an infix comparison, same as `waitForValue(_:)`.
    ///
    /// Guarded with `exists == true`: NSPredicate comparison operators evaluate
    /// to false when an operand is nil, so an ungated `NOT (value ...)` would
    /// be TRUE the instant the element doesn't exist yet (its `value` reads as
    /// nil) — a silent false pass for "the UI hasn't come up yet". Folding the
    /// existence check into the same compound predicate makes this one atomic
    /// wait: the negation is only ever evaluated once the element genuinely
    /// exists, and if it never does, the expectation times out and this
    /// returns `false` rather than reporting the negation satisfied.
    func waitForValueNot(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND NOT (value \(predicateFormat))")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility label to match a predicate.
    /// SwiftUI `Button` elements expose their `Text` label content in `label`, not `value`.
    /// Example: `element.waitForLabel("== 'WYSIWYG'")`
    ///
    /// `predicateFormat` is prefixed with `"label "`, so it must be an infix
    /// comparison, not a NOT/AND/OR-prefixed expression — see `waitForValue(_:)`.
    /// Use `waitForLabelNot(_:)` for negation.
    func waitForLabel(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility label to NOT match a predicate.
    /// Example: `element.waitForLabelNot("== 'Source'")` waits until the label
    /// is no longer "Source", correctly building `NOT (label == 'Source')`.
    /// `predicateFormat` must still be an infix comparison, same as `waitForLabel(_:)`.
    ///
    /// Guarded with `exists == true`, same rationale as `waitForValueNot(_:)`:
    /// without it, `NOT (label ...)` reads TRUE the instant the element
    /// doesn't exist yet, silently passing before the UI has come up.
    func waitForLabelNot(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND NOT (label \(predicateFormat))")
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

// MARK: - Proven-Pattern Query Helpers
//
// Each helper below encodes a failure mode diagnosed live in the 2026-08-16
// superdev batch (see "Proven patterns" in .claude/skills/e2e-verify/SKILL.md).
// Disposable e2e tests should compose these instead of re-deriving queries.

extension XCUIApplication {
    /// The WKWebView editor container. Every query for editor content must be
    /// scoped here: a bare `app.staticTexts[...]` also matches the outline
    /// sidebar's mirror of each heading, and `.firstMatch` resolves to the
    /// *sidebar* match first — so an unscoped "click the heading" clicks a
    /// sidebar row instead.
    var editorArea: XCUIElement {
        groups["editor-area"]
    }

    /// First StaticText inside the editor whose value (or, for heading
    /// containers, label) starts with `text`, or nil if none appears within
    /// `timeout`.
    ///
    /// Matching is done in Swift, not NSPredicate: heading containers carry a
    /// non-string value (the heading level, an NSNumber), and any substring
    /// predicate (`CONTAINS`, `BEGINSWITH`) evaluated against one throws
    /// NSInvalidArgumentException at resolution time. Prefix (not exact)
    /// matching, because a leaf text run carries a trailing space when an
    /// inline link follows, and a heading container's label concatenates all
    /// child text — exact equality matches neither.
    ///
    /// Re-call after every mutation: a handle resolved before typing goes
    /// stale once the text changes.
    func editorStaticText(startingWith text: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for element in editorArea.staticTexts.allElementsBoundByIndex {
                if let value = element.value as? String, value.hasPrefix(text) {
                    return element
                }
                if element.label.hasPrefix(text) {
                    return element
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return nil
    }

    /// Waits for a menu item by TITLE and returns it, or fails. XCUITest gives
    /// `NSMenuItem` only `title` and an identifier (`menuAction:`) — no
    /// `label` — so a `label BEGINSWITH` query against `menuItems` matches
    /// nothing, forever, while the item sits open and visible on screen.
    /// Prefix matching, for items whose title embeds a document name
    /// ("Undo Restore of ...").
    @discardableResult
    func menuItem(titleStartingWith prefix: String, timeout: TimeInterval = 10,
                  file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = menuItems.matching(
            NSPredicate(format: "title BEGINSWITH %@", prefix)
        ).firstMatch
        if !item.waitForExistence(timeout: timeout) {
            XCTFail("No menu item with title starting \"\(prefix)\" appeared within \(timeout)s "
                + "(note: menu items match on title, never label)", file: file, line: line)
        }
        return item
    }

    /// Waits for and clicks a button in a modal alert raised via
    /// `NSAlert.runModal()` (e.g. from a menu command). Those alerts are
    /// top-level Dialog siblings of the windows, so `windows.buttons[...]`
    /// can never reach them; and a bare `app.buttons[...]` can resolve to the
    /// Touch Bar mirror of the dialog's default button instead of the real
    /// one. Dialog scope avoids both.
    func clickDialogButton(_ title: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line) {
        let button = dialogs.buttons[title]
        if !button.waitForExistence(timeout: timeout) {
            XCTFail("Dialog button \"\(title)\" did not appear within \(timeout)s "
                + "(runModal alerts live under app.dialogs, not app.windows)", file: file, line: line)
            return
        }
        button.click()
    }
}

extension XCUIElement {
    /// Clicks via coordinates instead of element hit-testing. Sidebar cards
    /// are non-hittable by design — `PassthroughHostingView.hitTest` returns
    /// nil for anything but right-clicks — so `element.click()` on one can
    /// never land, and the failure masquerades as a layout/obstruction
    /// problem. Every positioned click in this suite goes through
    /// coordinates; this wraps that precedent.
    func clickViaCoordinate(dx: CGFloat = 0.5, dy: CGFloat = 0.5,
                            timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) {
        if !waitForExistence(timeout: timeout) {
            XCTFail("Element \(debugDescription) did not appear within \(timeout)s "
                + "for coordinate click", file: file, line: line)
            return
        }
        coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).click()
    }
}

// MARK: - App File Helpers

/// Reads files the APP writes (logs, exports) from inside the test runner.
/// The runner's own home is containerized: `NSHomeDirectory()` and
/// `FileManager.default.homeDirectoryForCurrentUser` point at the xctrunner
/// container, not the app's home — a read helper built on either silently
/// returns nothing.
enum AppFileHelper {
    struct ReadError: Error, CustomStringConvertible {
        let relativePath: String
        let attempted: [String]
        var description: String {
            "AppFileHelper: \"\(relativePath)\" not found. Attempted: \(attempted.joined(separator: ", ")). "
                + "A missing file is a real failure — never treat it as \"the app wrote nothing\"."
        }
    }

    /// Candidate locations for an app-written path relative to the app's home
    /// (e.g. "Library/Application Support/com.kerim.final-final/..."), as
    /// home roots in the order worth trying: the real user home by name
    /// (works around the runner's containerized home), the home implied by
    /// the standard Application Support lookup, then the runner's own idea
    /// of home as a last resort.
    static func candidateURLs(appRelativePath: String) -> [URL] {
        let fm = FileManager.default
        var homes: [URL] = [URL(fileURLWithPath: "/Users/\(NSUserName())")]
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Strip "Application Support" and "Library" to get a home root.
            homes.append(appSupport.deletingLastPathComponent().deletingLastPathComponent())
        }
        homes.append(fm.homeDirectoryForCurrentUser)
        // De-dup while preserving order (the three often agree outside a VM).
        var seen = Set<String>()
        return homes.filter { seen.insert($0.path).inserted }
            .map { $0.appendingPathComponent(appRelativePath) }
    }

    /// Returns the contents of the first candidate that exists. Throws a
    /// descriptive error naming every attempted path — never an empty string
    /// for a missing file, which made a wrong path indistinguishable from
    /// "the app never wrote" and burned three VM cycles on one silent read
    /// failure.
    static func read(appRelativePath: String) throws -> String {
        var attempted: [String] = []
        for url in candidateURLs(appRelativePath: appRelativePath) {
            attempted.append(url.path)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        throw ReadError(relativePath: appRelativePath, attempted: attempted)
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
