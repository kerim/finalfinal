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
        XCUIApplication(bundleIdentifier: "com.kerim.final-final")
    }

    /// Launches the app in UI testing mode without a fixture (shows picker)
    func launchForTesting() {
        Self.cleanSavedApplicationState()
        launchArguments = ["--uitesting"]
        launch()
        activate()
    }

    /// Launches the app in UI testing mode with a fixture (shows editor)
    func launchForTesting(fixturePath: String) {
        Self.cleanSavedApplicationState()
        launchArguments = ["--uitesting", "--test-fixture-path", fixturePath]
        launch()
        activate()
    }

    /// Remove saved window state so each test run starts fresh.
    /// This replaces `-ApplePersistenceIgnoreState YES` which prevents
    /// SwiftUI's WindowGroup from creating any window at all.
    private static func cleanSavedApplicationState() {
        let savedStatePath = NSHomeDirectory()
            + "/Library/Saved Application State/com.kerim.final-final.savedState"
        try? FileManager.default.removeItem(atPath: savedStatePath)
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
}

// MARK: - Fixture Helpers

enum TestFixtureHelper {
    /// The path where the test fixture will be placed for the app to open.
    /// Uses NSTemporaryDirectory() which the test runner can write to.
    /// The app can read from this path since its sandbox is disabled.
    static let fixturePath: String = {
        return NSTemporaryDirectory() + "ff-test-fixture.ff"
    }()

    /// Copies the committed fixture from the UI test bundle to the temp directory.
    /// Must be called in setUp before launching the app.
    static func setupFixture(from testCase: XCTestCase) throws {
        let fm = FileManager.default

        // Find fixture in the UI test bundle using URL-based path
        let bundle = Bundle(for: type(of: testCase))
        guard let fixtureSource = bundle.resourceURL?
            .appendingPathComponent("Fixtures/test-fixture.ff"),
              fm.fileExists(atPath: fixtureSource.path) else {
            XCTFail("Test fixture not found in UI test bundle. Ensure FixtureGeneratorTests has run and fixture is committed.")
            return
        }

        // Fresh copy for test isolation
        try? fm.removeItem(atPath: fixturePath)
        try fm.copyItem(at: fixtureSource, to: URL(fileURLWithPath: fixturePath))

        print("[TestFixture] Fixture copied to: \(fixturePath)")
    }

    /// Removes the test fixture. Call from tearDown.
    static func cleanupFixture() {
        try? FileManager.default.removeItem(atPath: fixturePath)
    }
}
