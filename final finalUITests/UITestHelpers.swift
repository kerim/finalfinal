//
//  UITestHelpers.swift
//  final finalUITests
//
//  Helpers for XCUITest smoke tests: launch configuration,
//  fixture setup, and wait utilities.
//
//  The query/fixture-database/document-note-seeding helpers were split out to
//  UITestQueryAndFixtureHelpers.swift to keep this file under SwiftLint's file_length limit.
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
    /// Note: the test runner is unsandboxed for this project (see
    /// `final finalUITests/final finalUITests.entitlements`, wired via the
    /// `CODE_SIGN_ENTITLEMENTS` build setting in `project.yml`), so
    /// NSHomeDirectory() there now resolves to the same real user home the
    /// app sees. Both paths are still cleaned as belt-and-braces, not
    /// because they currently differ.
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

        for path in Set([testRunnerPath, realUserPath]) {
            do { try FileManager.default.removeItem(atPath: path) } catch {
                // Was a silent `try?`: a failed delete leaves saved window state (e.g. full screen) for the next launch.
                guard ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) else { continue }
                XCTContext.runActivity(named: "Could not remove saved state \(path)") { $0.add(XCTAttachment(string: "\(error)")) }
            }
        }
    }
}

// MARK: - System Alert Interruption Handling

extension XCTestCase {
    /// Registers a UI interruption monitor that dismisses the macOS "<app> would like to find
    /// and connect to devices on your local network" permission dialog (owned by
    /// `com.apple.UserNotificationCenter`, not our app) if it ever appears mid-test.
    ///
    /// Belt-and-braces, not the real fix: this dialog's actual cause was a real `URLSession`
    /// request `ZoteroService.fetchItemsForCitekeys`/`fetchItemsForCitekeysViaExport` made to
    /// `127.0.0.1:23119` even under `FF_UI_TESTING_ZOTERO_MOCK` -- fixed at the source by giving
    /// both a UI-testing mock short-circuit (see their doc comments). That fix should mean this
    /// dialog never appears at all; this monitor exists so that if it ever does (a future call
    /// site reintroducing a real Zotero network call under mock mode, or some other local-network
    /// API), it gets dismissed immediately instead of sitting on screen and swallowing the next
    /// test's clicks/keystrokes in the same shard -- confirmed live: this exact dialog surfacing
    /// during `ProjectSwitchBibliographyE2ETests` was still on screen when
    /// `SidebarRerenderCountE2ETests` (the next class in the shard) tried to click "Middle
    /// Section", and XCTest's own BUILT-IN interruption handling ("Checking for user permission
    /// dialogs...") did not recognize or dismiss it (xcodebuild.log: "No monitors handled UI
    /// interruption... Did not handle the interruption, but will attempt to continue").
    ///
    /// Registered from `TestFixtureHelper.setupFixture(from:)` -- the one setup path essentially
    /// every permanent e2e test class already calls from its own `setUpWithError()`, rather than
    /// inventing a new shared base class this codebase doesn't have (every e2e test class here
    /// subclasses `XCTestCase` directly).
    ///
    /// Matches on the dialog's own body text, per this task's instruction to check the
    /// accessibility tree before hardcoding a button title: `staticTexts` containing "find
    /// devices on local networks" (the standard macOS local-network-access prompt wording,
    /// case-insensitive to tolerate any macOS-version wording drift), then clicks "Don't Allow"
    /// -- the privacy-preserving choice, matching this app's own "decline non-essential" default
    /// -- falling back to whatever button is present if "Don't Allow" isn't found verbatim, since
    /// dismissing SOME way is strictly better than leaving the dialog to interrupt the next test.
    @discardableResult
    func installLocalNetworkPermissionInterruptionMonitor() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Local network permission dialog") { alert in
            let bodyMatches = alert.staticTexts.matching(
                NSPredicate(
                    format: "(label CONTAINS[c] %@) OR (value CONTAINS[c] %@)",
                    "find devices on local networks", "find devices on local networks"
                )
            )
            guard bodyMatches.count > 0 else { return false }

            let dontAllow = alert.buttons["Don't Allow"]
            if dontAllow.exists {
                dontAllow.click()
                return true
            }
            // Wording/localization drift fallback: dismissing via whichever button exists beats
            // leaving the dialog on screen to interrupt whatever test runs next.
            if alert.buttons.count > 0 {
                alert.buttons.firstMatch.click()
                return true
            }
            return false
        }
    }

    /// Attach a screenshot as e2e evidence. THE way to produce screenshot
    /// evidence in this suite.
    ///
    /// A plain `FileManager` write from a UI-test method cannot work: Xcode's
    /// own RunnerEntitlements.plist sandboxes every macOS XCUITest runner
    /// (app-sandbox=true, read-only "/"), so writes outside the runner's
    /// container fail with "Operation not permitted" — silently, wherever the
    /// call site uses `try?`. Confirmed live, two instrumented VM runs,
    /// 2026-09-12. XCTAttachment goes through XCTest's own privileged export
    /// path and is unaffected; vmtest exports attachments after every run,
    /// pass or fail.
    func attachEvidenceScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    /// Example: `element.waitForValue("== 'Rich Text'")`
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
    /// Example: `element.waitForLabel("== 'Rich Text'")`
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
    /// Example: `element.waitForLabelNot("== 'Markdown'")` waits until the label
    /// is no longer "Markdown", correctly building `NOT (label == 'Markdown')`.
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

// MARK: - Screenshot Evidence Plumbing (E2EShotDir)

enum E2EShotDir {
    /// The `FF_E2E_SHOT_DIR` env-var contract — NOT itself a route for a
    /// disposable e2e test to write its screenshot evidence; see the next
    /// paragraph. Screenshot evidence goes through
    /// `attachEvidenceScreenshot(_:name:)` (above) instead.
    ///
    /// This type's WRITE path (a plain `FileManager`/`Data.write(to:)` call
    /// from inside a UI test method) now succeeds for any absolute path,
    /// including one outside the runner's own home. The XCUITest runner
    /// process for this project is unsandboxed (see
    /// `final finalUITests/final finalUITests.entitlements`, wired via the
    /// `CODE_SIGN_ENTITLEMENTS` build setting in `project.yml`), unlike
    /// Xcode's shipped default (app-sandbox=true, read-only "/"), which
    /// used to confine writes to
    /// `NSHomeDirectory()`/`NSTemporaryDirectory()` and fail with "Operation
    /// not permitted" on any target outside that — including `vmtest`'s
    /// `/tmp/vmtest-e2e-shots` (below), which sits outside the runner's own
    /// home. That old failure is why screenshot evidence was routed through
    /// `attachEvidenceScreenshot(_:name:)` (above) instead — XCTest's own
    /// privileged `XCTAttachment` export path. Evidence should still go
    /// that way, and `FF_E2E_SHOT_DIR`/`E2EShotDir` remains the contract
    /// for writers other than the runner process itself (e.g. host-side
    /// tooling) — but a direct write from the runner now works too, should
    /// one ever be added.
    ///
    /// Reads `FF_E2E_SHOT_DIR` from the process environment — set by
    /// `vmtest` (as `TEST_RUNNER_FF_E2E_SHOT_DIR`, which xcodebuild forwards
    /// to the runner process with the prefix stripped).
    ///
    /// Two cases, deliberately distinct:
    /// - Unset → `NSTemporaryDirectory()` (already relied on by
    ///   `TestFixtureHelper.fixturePath` above). This is the safe default
    ///   when nobody wired anything up.
    /// - Set to an absolute path (starts with "/") → used as-is. `vmtest`
    ///   sets it to an absolute path under `/tmp/` (e.g.
    ///   `/tmp/vmtest-e2e-shots`), the same convention its video-recording
    ///   feature already uses, and a write there from the runner now
    ///   succeeds since the runner is unsandboxed. History: before the
    ///   runner's entitlements were fixed, an earlier convention had
    ///   `vmtest` pass a bare relative name for the runner to resolve
    ///   against its own (then-sandboxed) `NSHomeDirectory()` — that write
    ///   succeeded, but still produced no usable evidence, because an
    ///   external SSH session could not read into the runner's sandboxed
    ///   container afterward. Confirmed live, two instrumented VM runs,
    ///   2026-09-12 (the run that diagnosed the sandbox as the cause).
    ///
    /// A bare relative value (no leading "/") still resolves against
    /// `NSHomeDirectory()` rather than silently falling back to the temp
    /// dir, so a misconfiguration stays visible instead of hidden — but
    /// nothing in this codebase passes one anymore.
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
