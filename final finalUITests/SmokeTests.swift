//
//  SmokeTests.swift
//  final finalUITests
//
//  Smoke tests verifying app launch, editor state, and basic user flows.
//  Uses accessibility identifiers and status bar text for assertions.
//  No cross-process content inspection (that's handled by integration tests).
//

import XCTest

// MARK: - Launch Smoke Tests (no fixture needed)

final class LaunchSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.launchForTesting()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testAppLaunches() {
        // App should boot without crash and show either picker or editor within 10s
        let picker = app.groups["project-picker"]
        let editor = app.groups["editor-area"]

        let pickerExists = picker.waitForExistence(timeout: 10)
        let editorExists = editor.exists

        XCTAssertTrue(pickerExists || editorExists, "App should show picker or editor after launch")
    }

    func testProjectPickerVisible() {
        // Without a fixture, the app should show the project picker
        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Project picker should appear")

        let newButton = app.buttons["new-project-button"]
        let openButton = app.buttons["open-project-button"]

        XCTAssertTrue(newButton.waitForExistence(timeout: 5), "New Project button should exist")
        XCTAssertTrue(openButton.exists, "Open Project button should exist")
    }

    func testPrintMenuItemsExist() {
        // File > Print is a Commands-level menu (scene-wide), so it should exist and be
        // enabled even without an open project. This only navigates the menu hierarchy
        // to confirm the items are present -- it never clicks "Formatted..." or "Raw
        // Markdown..." themselves, since that would open the real system print panel.
        app.activateAndWaitForForeground()

        let fileMenuBarItem = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenuBarItem.waitForExistence(timeout: 5), "File menu should exist")
        fileMenuBarItem.click()

        let printMenuItem = app.menuItems["Print"]
        XCTAssertTrue(printMenuItem.waitForExistence(timeout: 5), "File > Print submenu should exist")
        printMenuItem.click()

        let formattedItem = app.menuItems["Formatted..."]
        let rawMarkdownItem = app.menuItems["Raw Markdown..."]

        XCTAssertTrue(formattedItem.waitForExistence(timeout: 5), "File > Print > Formatted... should exist")
        XCTAssertTrue(formattedItem.isEnabled, "File > Print > Formatted... should be enabled")

        XCTAssertTrue(rawMarkdownItem.exists, "File > Print > Raw Markdown... should exist")
        XCTAssertTrue(rawMarkdownItem.isEnabled, "File > Print > Raw Markdown... should be enabled")

        // Dismiss the menu hierarchy without invoking either print action.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }
}

// MARK: - Editor Smoke Tests (fixture required)

final class EditorSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Defense-in-depth: terminate any leftover process from a prior test
        // whose own tearDown never ran (e.g. a crash) before touching the
        // fixture file below, so this test's fixture copy never races a
        // still-open file handle from that leftover process.
        app = XCUIApplication.targetApp()
        app.terminate()

        // Copy committed fixture to /tmp/ for the app to open
        try TestFixtureHelper.setupFixture(from: self)

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testEditorOpensWithFixture() {
        // Editor area should appear with status bar showing word count
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear. Fixture path: \(TestFixtureHelper.fixturePath)")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForExistence(timeout: 10), "Word count should appear in status bar")
        // SwiftUI Text with accessibilityIdentifier puts content in .value, not .label
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should display word count")
    }

    func testEditorModeToggle() {
        // Wait for editor to load
        // The identifier is on a Button (not a bare Text), so query buttons
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear in status bar")

        // Verify default mode is WYSIWYG
        XCTAssertTrue(editorMode.waitForLabel("== 'WYSIWYG'", timeout: 10), "Default editor mode should be WYSIWYG")

        // Verify the button is interactive
        XCTAssertTrue(editorMode.isHittable, "Editor mode button should be hittable")

        // Drive the toggle for real, and prove the CodeMirror source editor
        // actually loaded -- not just that the button's label flipped.
        //
        // Cmd+/ can drop if the app isn't reliably foreground when it's sent
        // (see `activateAndWaitForForeground`'s doc comment), so retry the
        // keystroke itself -- not just the wait -- until the label actually
        // moves. This mirrors the retry-the-action-not-just-the-wait pattern
        // already proven in
        // `E2ESectionReconcilerPseudoSectionTests.selectAllAndPasteReplacement`.
        // Retrying is safe here specifically because we only re-send Cmd+/
        // while the label still reads "WYSIWYG" -- once it flips we stop,
        // since Cmd+/ is a toggle and a stray extra press would flip it
        // straight back to WYSIWYG.
        var toggleRegistered = false
        for _ in 1...5 {
            if editorMode.label == "Source" {
                toggleRegistered = true
                break
            }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Source'", timeout: 2) {
                toggleRegistered = true
                break
            }
        }
        XCTAssertTrue(toggleRegistered, "Editor-mode button should report Source after retrying the toggle keystroke")

        // The label flips synchronously with the toggle request, but the
        // actual WYSIWYG->CodeMirror view swap runs through an async
        // cursor-save callback chain that can lag behind it -- documented as
        // unreliable to catch with a single fixed sleep in
        // ListNumberingE2ETests.swift and
        // E2ESectionReconcilerPseudoSectionTests.swift, both of which fall
        // back to reading persisted `block` rows instead of asserting
        // on-screen. Poll for concrete on-screen evidence instead of sleeping
        // blind: the committed fixture's raw markdown
        // (final finalTests/Fixtures/test-fixture.ff) opens with the literal
        // line "# Test Document". Milkdown's WYSIWYG rendering strips
        // markdown syntax -- the heading is exposed to accessibility as
        // "Test Document", never with the leading "#". Only CodeMirror,
        // which renders the raw source text verbatim, will ever expose an
        // element whose label or value contains "# Test Document", so its
        // appearance is proof the source editor actually loaded -- not just
        // that the status-bar button re-labeled itself.
        let editorArea = app.groups["editor-area"]
        let sourceEvidence = editorArea.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '# Test Document' OR value CONTAINS '# Test Document'")
        ).firstMatch
        XCTAssertTrue(
            sourceEvidence.waitForExistence(timeout: 10),
            "CodeMirror source editor should render the raw markdown after toggling, not just flip the status-bar label"
        )

        // The full toggle cycle's other direction (Source -> WYSIWYG) and the
        // WebView-side content plumbing are covered by EditorModeSwitchTests
        // (Tier 2, real WebView integration tests).
    }

    func testSidebarToggles() {
        // Wait for sidebar to appear
        let sidebar = app.groups["outline-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Sidebar should appear initially")

        // Toggle sidebar off with Cmd+[
        // Note: On macOS, NavigationSplitView may keep the element in hierarchy
        // even when collapsed, so we check isHittable instead of exists
        app.activateAndWaitForForeground()
        app.typeKey("[", modifierFlags: .command)

        // Wait a moment for animation, then assert the toggle actually took
        // effect. This used to fall back to "the app still has a window" when
        // the isHittable predicate didn't resolve in time -- that fallback
        // passes whether or not Cmd+[ did anything at all, so a genuinely
        // broken sidebar toggle could sail through this smoke test green.
        let hidePredicate = NSPredicate(format: "isHittable == false")
        let hideExpectation = XCTNSPredicateExpectation(predicate: hidePredicate, object: sidebar)
        let hideResult = XCTWaiter().wait(for: [hideExpectation], timeout: 5)
        XCTAssertEqual(hideResult, .completed, "Sidebar should become non-hittable after Cmd+[")

        // Toggle sidebar back on
        app.activateAndWaitForForeground()
        app.typeKey("[", modifierFlags: .command)

        // Verify sidebar is visible again -- same hard assertion, no fallback.
        let showPredicate = NSPredicate(format: "isHittable == true")
        let showExpectation = XCTNSPredicateExpectation(predicate: showPredicate, object: sidebar)
        let showResult = XCTWaiter().wait(for: [showExpectation], timeout: 5)
        XCTAssertEqual(showResult, .completed, "Sidebar should become hittable again after a second Cmd+[")
    }

    func testTypedTextPersistsAcrossRelaunch() {
        // Seed a small, known document distinct from the class's default
        // fixture content, so a stray leftover marker from an earlier run
        // can never be mistaken for the one this test cares about.
        app.terminate()
        FixtureDatabase.seedMarkdown(
            fixturePath: TestFixtureHelper.fixturePath,
            markdown: "# Persistence Smoke\n\nSeed paragraph.\n\n"
        )
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear after seeding")
        // 10s, not editorContainsText's 5s default -- found live in a sharded
        // --suite full run (two VMs contending for the same host): the
        // editor-area container existed well before the WebView had actually
        // rendered the seeded content, and 5s wasn't always enough margin for
        // that render to catch up under VM/host contention.
        XCTAssertTrue(app.editorContainsText("Seed paragraph", timeout: 10), "Seeded content should render before typing")

        // Click at the end of the seed paragraph and open a fresh, empty
        // line -- typeTextVerifyingLanded's documented precondition.
        let seedParagraph = app.staticTexts["Seed paragraph."]
        XCTAssertTrue(seedParagraph.waitForExistence(timeout: 10), "Seed paragraph should be reachable via accessibility")
        let endOfSeed = seedParagraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        endOfSeed.click()
        app.activateAndWaitForForeground()
        app.typeKey(.return, modifierFlags: [])

        let marker = "persistence-smoke-\(UUID().uuidString.prefix(8))"
        app.typeTextVerifyingLanded(marker)

        // The actual proof: terminate for real and relaunch against the same
        // (already-mutated) fixture path -- not just an in-memory check.
        app.terminate()
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorAreaAfterRelaunch = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterRelaunch.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")
        XCTAssertTrue(
            app.editorContainsText(marker, timeout: 10),
            "Typed text should survive a real terminate + relaunch, not just in-memory state"
        )
    }

    func testFocusModeToggle() {
        // Wait for status bar to appear
        let statusBar = app.groups["status-bar"]
        XCTAssertTrue(statusBar.waitForExistence(timeout: 10), "Status bar should appear")

        // Enable focus mode with Cmd+Shift+F
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: [.command, .shift])

        // Status bar should disappear in focus mode
        let disappearResult = statusBar.waitForDisappearance(timeout: 10)
        XCTAssertTrue(disappearResult, "Status bar should disappear in focus mode")

        // Exit focus mode with Escape
        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])

        // Status bar should reappear
        XCTAssertTrue(statusBar.waitForExistence(timeout: 10), "Status bar should reappear after exiting focus mode")
    }
}
