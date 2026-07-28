//
//  ProjectOpenErrorE2ETests.swift
//  final finalUITests
//
//  e2e proof for the project-open-error-alert plan: the fix rests on
//  ProjectOpenErrorState.pending being set and rendered by the always-mounted
//  host before any specific view exists to show it. The unit tests
//  (ProjectIntegrityTests's ProjectOpenErrorState suite) only exercise the
//  funnel's routing logic in isolation -- they cannot touch presentation. This
//  drives the real app to prove the sheet actually appears, doesn't crash, and
//  names the failing file.
//
//  Pre-flight per MEMORY: confirm no production build of the app is already
//  running (`pgrep -f "final final"`) before the first test_macos call of the
//  session, or XCUITest activation can fail silently, and a second running
//  instance registered for the .ff UTI could steal the Apple Event
//  testBrokenProjectShowsErrorSheetOverPicker relies on.
//

import XCTest
import AppKit

final class ProjectOpenErrorE2ETests: XCTestCase {
    private static let bundleIdentifier = "com.kerim.final-final"

    var app: XCUIApplication!
    private var brokenProjectURL: URL!
    private var recentProjectPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Safety guard, before any other setup/test logic: NSWorkspace.shared.open
        // (used below) + XCUIApplication(bundleIdentifier:) can both attach to and
        // drive the user's actual installed PRODUCTION app (same bundle ID) if one
        // is already running, and tearDown's app.terminate() would then kill that
        // real running instance -- discarding any real unsaved work. Fail loudly
        // and stop rather than silently operating on the wrong process.
        let runningBeforeLaunch = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        guard runningBeforeLaunch.isEmpty else {
            let pids = runningBeforeLaunch.map { $0.processIdentifier }
            XCTFail("""
                A non-test instance of final final (bundle \(Self.bundleIdentifier)) is \
                already running (pid \(pids)). Quit it before running this suite -- \
                tearDown terminates the app under test, and this test cannot tell a \
                production instance apart from the one it launches.
                """)
            throw NSError(domain: "ProjectOpenErrorE2ETests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to run: a non-test instance of the app is already running."
            ])
        }

        app = XCUIApplication.targetApp()

        // A .ff directory with no content.sqlite inside is enough to produce a
        // .missingDatabase issue (critical -- ProjectIntegrityChecker.swift:163-166).
        // No fixture factory needed for this.
        brokenProjectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uitest-broken-\(UUID().uuidString).ff")
        try? FileManager.default.removeItem(at: brokenProjectURL)
        try FileManager.default.createDirectory(at: brokenProjectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Optional-chained deliberately: if the safety guard above threw before
        // `app` was assigned (production instance detected), `app` is still nil
        // here. XCTest still runs tearDown after a setUp throw, so an unconditional
        // `app.terminate()` on the implicitly-unwrapped `app` would crash teardown
        // itself -- turning a caught, well-messaged safety failure into a bare
        // "unexpectedly found nil" instead.
        app?.terminate()
        // brokenProjectURL is also assigned after the safety guard above, so it
        // can be nil here for the same reason `app` can -- `removeItem(at:)` takes
        // a non-optional URL, so passing the IUO directly would force-unwrap (and
        // crash) even under `try?`, which only catches thrown errors, not traps.
        if let brokenProjectURL {
            try? FileManager.default.removeItem(at: brokenProjectURL)
        }
        if let recentProjectPath {
            try? FileManager.default.removeItem(atPath: recentProjectPath)
        }
        TestFixtureHelper.cleanupFixture()
    }

    /// Finder-open case: app running, picker on screen. Before this fix,
    /// AppDelegate.openProjectFromFinder posted `.projectIntegrityError` into an
    /// empty room (ContentView, the only subscriber, isn't mounted while the
    /// picker shows) and nothing happened.
    func testBrokenProjectShowsErrorSheetOverPicker() {
        app.launchForTesting()  // No fixture -> lands on the picker.

        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Project picker should appear")

        deliverBrokenProjectOpen()

        let sheet = app.descendants(matching: .any)["project-open-error-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10),
            "project-open-error-sheet should appear after opening a broken .ff package")

        let filename = brokenProjectURL.lastPathComponent
        let namesFile = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", filename, filename)
        ).firstMatch
        XCTAssertTrue(namesFile.waitForExistence(timeout: 5),
            "Sheet should name the broken file (\(filename))")

        let namesIssue = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'content.sqlite' OR label CONTAINS 'content.sqlite'")
        ).firstMatch
        XCTAssertTrue(namesIssue.waitForExistence(timeout: 5),
            "Sheet should list the missing-database issue")

        // Cancel and confirm it does not reappear.
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Cancel button should exist")
        cancelButton.click()

        XCTAssertTrue(sheet.waitForDisappearance(timeout: 5), "Sheet should close on Cancel")

        // Give a wrongly-reappearing sheet a moment to show itself.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(sheet.exists, "Sheet must not reappear after Cancel")
    }

    /// Primary trigger for the round-2 review's blocking fixes: Open Recent on a
    /// project that's been deleted, with the app already sitting in steady state
    /// (picker) rather than mid-launch. This is deliberately NOT the launch-time
    /// case: launch happened to work even with the pre-fix untracked-Binding bug,
    /// because determineInitialState() also flips appViewState right after
    /// reporting, forcing an unrelated re-render that masked the bug. This
    /// scenario has no such coincidental re-render, so it's the direct proof that
    /// (1) the sheet doesn't crash for lack of ThemeManager in its environment,
    /// (2) the sheet actually appears via the tracked-read fix rather than by
    /// accident, and (3) the .other sheet names the failing file.
    ///
    /// Uses launchForTesting(fixturePath:) rather than driving "New Project" +
    /// NSSavePanel: launching with a fixture both lands the app straight in the
    /// editor AND legitimately adds the fixture to Recent Projects with a real,
    /// app-created security-scoped bookmark (DocumentManager.openProject(at:) does
    /// this internally) -- no hand-rolled bookmark data, no UserDefaults poking,
    /// no untested NSSavePanel automation.
    func testOpenRecentOnDeletedProjectShowsErrorSheetWhileAppRunning() throws {
        try TestFixtureHelper.setupFixture(from: self)
        let recentPath = NSTemporaryDirectory() + "uitest-recent-\(UUID().uuidString).ff"
        recentProjectPath = recentPath
        try? FileManager.default.removeItem(atPath: recentPath)
        try FileManager.default.copyItem(atPath: TestFixtureHelper.fixturePath, toPath: recentPath)

        app.launchForTesting(fixturePath: recentPath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor should open with the fixture")

        // Close back to the picker -- this is what makes the app "already
        // running" rather than mid-launch. The Recent Projects entry added above
        // survives the close.
        app.activateAndWaitForForeground()
        app.typeKey("w", modifierFlags: .command)
        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Picker should reappear after Cmd-W")

        // Delete the project out from under its own Recent Projects entry --
        // simulates moving it to the Trash while the app keeps running.
        try FileManager.default.removeItem(atPath: recentPath)

        app.activateAndWaitForForeground()
        let fileMenuBarItem = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenuBarItem.waitForExistence(timeout: 5), "File menu should exist")
        fileMenuBarItem.click()

        let openRecentItem = app.menuItems["Open Recent"]
        XCTAssertTrue(openRecentItem.waitForExistence(timeout: 5), "File > Open Recent should exist")
        openRecentItem.click()

        // "Test Project" is TestFixtureFactory.createFixture's default title --
        // Recent Projects' displayed entry title comes from the project record,
        // not the filename.
        let recentEntry = app.menuItems["Test Project"]
        XCTAssertTrue(recentEntry.waitForExistence(timeout: 5),
            "Recent entry for the deleted project should still be listed")
        recentEntry.click()

        let sheet = app.descendants(matching: .any)["project-open-error-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), """
            project-open-error-sheet should appear for a deleted Recent Project while the \
            app is already running. If this fails, the .sheet(item:) tracked-read fix may \
            have regressed -- this scenario has no coincidental appViewState change to mask \
            a broken (untracked) presentation binding, unlike the launch-time path.
            """)

        let filename = URL(fileURLWithPath: recentPath).lastPathComponent
        let namesFile = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", filename, filename)
        ).firstMatch
        XCTAssertTrue(namesFile.waitForExistence(timeout: 5), "Sheet should name the deleted file (\(filename))")

        // Whichever sheet variant fires (.other for a bookmark/access failure,
        // .integrity if it somehow resolves to an integrity error instead), one of
        // these dismiss buttons exists.
        let dismissButton = app.buttons["OK"].firstMatch.exists ? app.buttons["OK"].firstMatch : app.buttons["Cancel"].firstMatch
        XCTAssertTrue(dismissButton.exists, "Sheet should have a dismiss button")
        dismissButton.click()

        XCTAssertTrue(sheet.waitForDisappearance(timeout: 5), "Sheet should close")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(sheet.exists, "Sheet must not reappear")
    }

    /// Attempts to deliver the broken package via a real Finder-open Apple Event
    /// (NSWorkspace.shared.open), which exercises
    /// AppDelegate.application(_:open:) -> openProjectFromFinder exactly like a real
    /// Finder double-click. Falls back to driving Cmd-O + Cmd-Shift-G ("Go to
    /// Folder") if the Apple Event doesn't reach the test-launched app instance --
    /// plausible under XCUITest's activation model (see MEMORY: same-bundle-ID
    /// activation issues are a known flake source for this app). Best-effort: now
    /// that testOpenRecentOnDeletedProjectShowsErrorSheetWhileAppRunning exists as
    /// the more reliable primary trigger, this fallback is not load-bearing.
    private func deliverBrokenProjectOpen() {
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(brokenProjectURL)

        let sheet = app.descendants(matching: .any)["project-open-error-sheet"]
        if sheet.waitForExistence(timeout: 5) {
            return
        }

        app.activateAndWaitForForeground()
        app.typeKey("o", modifierFlags: .command)

        let openPanel = app.dialogs.firstMatch
        guard openPanel.waitForExistence(timeout: 5) else {
            XCTFail("Neither the Finder-open Apple Event nor Cmd-O produced an open panel")
            return
        }

        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.sheets.textFields.firstMatch
        guard pathField.waitForExistence(timeout: 5) else {
            XCTFail("Go to Folder field did not appear")
            return
        }
        pathField.typeText(brokenProjectURL.path)
        app.typeKey(.enter, modifierFlags: [])
        app.typeKey(.enter, modifierFlags: [])
    }
}
