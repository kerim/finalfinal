//
//  FirstProjectOpenBlankMarginsE2ETests.swift
//  final finalUITests
//
//  Faithful reproduction of the user's exact report on t-b3142f13 (2026-08-29), which is
//  DIFFERENT from the project-switch race fixed earlier in this task:
//
//  1. Open a project for the first time in this app session -> editor pane is BLANK
//     (not a brief flash -- stays blank indefinitely until something forces a repaint).
//  2. Click a sidebar section -> content appears, but with WRONG MARGINS (no centered
//     column -- text runs closer to the pane's edges than it should).
//  3. Close the project and reopen the SAME project again -> renders correctly immediately,
//     no click needed, correct margins.
//
//  The user was explicit that the entry path (menu, File > Open, Recents, a live switch)
//  does not matter -- what matters is whether this exact project has just been opened
//  before in this session. This test uses launchForTesting(fixturePath:) for the first
//  open (real DocumentManager.openProject(at:) under the hood, same as every entry path)
//  and NSWorkspace.shared.open for the reopen, to isolate exactly that variable.
//

import XCTest

final class FirstProjectOpenBlankMarginsE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testFirstOpenIsBlankThenWrongMarginsThenReopenIsCorrect() throws {
        let fixturePath = TestFixtureHelper.fixturePath

        // ---- First open of this project in the session ----
        // Launch to the picker first (no fixture path yet), then idle for a few seconds before
        // opening -- closer to real usage (a user reads the picker, decides, clicks) than
        // opening instantly on launch, in case EditorPreloader's claim/mount timing depends on
        // how long the app has been sitting idle before the first real open.
        app.launchEnvironment["FF_UI_TESTING"] = "1"
        app.launch()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 5.0)

        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: fixturePath))

        // Confirm the editor area exists at all (the AX node), independent of whether the
        // WebView has actually painted anything -- this must not silently pass on a
        // real crash/no-launch.
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area AX node should exist after first open")

        // Screenshot immediately, no click, no extra wait -- this is the user's "Picture 1".
        snap("first-open-before-click")

        // Click a sidebar heading -- an UNSCOPED staticTexts query resolves to the sidebar
        // mirror first (see editorStaticText's doc comment), which is exactly "click a
        // sidebar section" from the bug report.
        // Sidebar cards are non-hittable by design (PassthroughHostingView.hitTest returns nil
        // for non-right-clicks) -- element.click() can never work there. Coordinate-click, per
        // the e2e-verify skill's proven pattern.
        let sidebarHeading = app.staticTexts["Test Document"].firstMatch
        XCTAssertTrue(sidebarHeading.waitForExistence(timeout: 10), "Sidebar should list the fixture's heading")
        sidebarHeading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        snap("first-open-immediately-after-click-t0ms")

        // Give the click's own scroll/repaint side effect time, with intermediate shots --
        // this is the user's "Picture 2" (content visible, margins allegedly wrong). Extended
        // wait to disambiguate "click triggers it" from "it eventually self-corrects
        // regardless of the click" (my synthetic coordinate click may not trigger the same
        // native path a real click does).
        for stepMs in [500, 1000, 2000, 4000] {
            Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
            snap("first-open-after-click-cumulative-t\(stepMs)ms")
        }

        // Also try clicking again, in case the first click's timing missed something.
        sidebarHeading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 1.0)
        snap("first-open-after-second-click")

        // ---- Close, then reopen the SAME project ----
        app.activateAndWaitForForeground()
        app.typeKey("w", modifierFlags: [.command]) // Close Project, rebound app-wide

        // Verify the close actually happened -- do NOT just wait for editor-area to
        // "reappear", which would trivially pass immediately if Close never fired at all
        // (the element never went away). The project picker has a real AX identifier.
        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Close Project (Cmd-W) should return to the project picker")
        XCTAssertFalse(app.editorArea.exists, "Editor area should be gone once the project picker is showing")

        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: fixturePath))
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area should reappear after reopening the same project")
        XCTAssertFalse(picker.exists, "Project picker should be gone once the project reopened")

        // No click this time -- this is the user's "Picture 3". Multiple timed shots at
        // increasing CUMULATIVE delays, same reasoning as the earlier bisection: distinguish
        // "never renders" from "renders late".
        let stepDelaysMs = [0, 300, 500, 700, 1500]
        for stepMs in stepDelaysMs {
            if stepMs > 0 { Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0) }
            snap("second-open-cumulative-t\(stepMs)ms")
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let pngData = app.screenshot().pngRepresentation as Data? {
            try? pngData.write(to: E2EShotDir.url.appendingPathComponent("\(name).png"))
        }
    }
}
