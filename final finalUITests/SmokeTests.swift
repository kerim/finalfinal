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
        XCTAssertTrue(editorMode.waitForLabel("== 'Rich Text'", timeout: 10), "Default editor mode should be Rich Text")

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
        // while the label still reads "Rich Text" -- once it flips we stop,
        // since Cmd+/ is a toggle and a stray extra press would flip it
        // straight back to Rich Text.
        var toggleRegistered = false
        for _ in 1...5 {
            if editorMode.label == "Markdown" {
                toggleRegistered = true
                break
            }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Markdown'", timeout: 2) {
                toggleRegistered = true
                break
            }
        }
        XCTAssertTrue(toggleRegistered, "Editor-mode button should report Markdown after retrying the toggle keystroke")

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
        // Note: the pane stays MOUNTED while hidden (OutlineSidebarPane animates its own width
        // to zero rather than being removed from the HSplitView), but `.accessibilityHidden(true)`
        // does take it out of the accessibility tree -- so `exists` is expected to go false, and
        // an `exists == false` assertion would pass for a reason that is about accessibility
        // rather than about the toggle. `isHittable` is what this asserts instead: it is false
        // both when the pane is hidden from AX and while it is genuinely not interactive.
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
        // Widened 5s -> 10s -> 30s. The 10s step (found live in a sharded --suite full run: the
        // editor-area container existed well before the WebView had actually rendered the seeded
        // content) was itself not enough margin: the 2026-09-12 run-1789176950-2627 investigation
        // (shard-1) found this call has the SAME defect as the post-relaunch call below --
        // editorContainsText only checks its deadline BETWEEN complete accessibility passes, never
        // during one -- and it nearly failed in that very run. Two passes started at t=6.23 and
        // t=8.10 against this call's own ~16.2s deadline (start + the old timeout:10), yet the
        // seed paragraph wasn't actually found until t=20.87 -- a pass already running when the
        // deadline lapsed was allowed to finish rather than being cut off. It only happened to
        // succeed that time under contention; 30 buys real margin instead of relying on luck.
        XCTAssertTrue(app.editorContainsText("Seed paragraph", timeout: 30), "Seeded content should render before typing")

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

        // The save this test is actually about is asynchronous: BlockSyncService polls the
        // WebView every 2s and only then writes the block rows to disk. typeTextVerifyingLanded
        // above only proves the marker reached the DOM, not that it reached disk -- and the
        // accessibility scan that helper uses to prove DOM landing keeps the app's main thread
        // (the same thread the poll Timer and its evaluateJavaScript round-trip need) busy long
        // enough that terminate() below could fire before the poll ever runs. Wait for the bytes
        // on disk directly, so a failure here (a real save bug) is never conflated with a failure
        // in the relaunch assertion below (a reload bug).
        let persistDeadline = Date(timeIntervalSinceNow: 20)
        var landedInDatabase = false
        repeat {
            let count = FixtureDatabase.read(
                fixturePath: TestFixtureHelper.fixturePath,
                sql: "SELECT count(*) FROM block WHERE markdownFragment LIKE '%\(marker)%';"
            )
            if Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 > 0 {
                landedInDatabase = true
                break
            }
            // RunLoop.run(until:), not Thread.sleep -- keeps the main run loop alive so
            // XCUITest's own internal event handling isn't starved during the poll, same
            // pattern as FootnoteCursorPlacementE2ETests.swift's private waitFor helper.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        } while Date() < persistDeadline
        XCTAssertTrue(
            landedInDatabase,
            "Typed text should reach the block table within 20s of typing (BlockSyncService's 2s poll)"
        )

        // The actual proof: terminate for real and relaunch against the same
        // (already-mutated) fixture path -- not just an in-memory check.
        app.terminate()

        // Confirm persistence survived the real termination above, independent of whatever the
        // post-relaunch rendering check further down finds -- so a rendering/timing bug there is
        // never conflated with a real save/reload bug. FixtureDatabase.read is a direct `sqlite3`
        // query against the fixture, not a UI action, so it produces no xcodebuild.log entry of
        // its own; per the 2026-09-12 run-1789176950-2627 investigation, what IS in that log
        // around this point is a ~0.25s gap between the last accessibility action and Terminate,
        // and the fact that the save itself was already confirmed fine before terminate (the
        // block row was on disk, 26 elements found pre-terminate) -- this assertion is a second,
        // independent check of the same fact after a real process termination, not a new claim.
        let countAfterTerminate = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT count(*) FROM block WHERE markdownFragment LIKE '%\(marker)%';"
        )
        XCTAssertTrue(
            (Int(countAfterTerminate.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0,
            "Typed text should still be on disk after a real terminate, before any relaunch/render check runs"
        )

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorAreaAfterRelaunch = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterRelaunch.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")

        // Widened 10s -> 30s (2026-09-12 run-1789176950-2627 investigation, shard-1, against the
        // actual xcodebuild.log). The save itself was fine -- the disk check right after
        // terminate() above, and the block row already confirmed on disk pre-terminate (26
        // elements found then), prove that independently. The failure was entirely in THIS check:
        // editorContainsText only checks its deadline BETWEEN complete accessibility passes, never
        // during one, and under two-shard host contention a single pass cost 8.6s in that run --
        // so timeout: 10 bought at most 2 passes while the relaunched WKWebView was still
        // hydrating (7 elements found on pass 1, 16 on pass 2 -- still short of the pre-terminate
        // 26). That the element count was still growing across passes, and never reached its
        // pre-terminate size before the old deadline, is the stronger evidence of
        // hydration-in-progress; the 8.6s-per-pass cost is what explains why 10s wasn't enough
        // passes to let it finish.
        let foundAfterRelaunch = app.editorContainsText(marker, timeout: 30)
        if !foundAfterRelaunch {
            // Self-diagnose rather than just failing blind: a non-zero count here means the
            // marker is still on disk and this is a render/timing bug (rendering hadn't caught up
            // within the widened 30s deadline); a zero count means a genuine reload/persistence
            // bug (the write from before terminate didn't actually stick). Dump the block table
            // and every post-relaunch editor accessibility element's value/label alongside it, so
            // a failure carries enough evidence to tell the two apart without re-running anything.
            let countAfterRelaunch = FixtureDatabase.read(
                fixturePath: TestFixtureHelper.fixturePath,
                sql: "SELECT count(*) FROM block WHERE markdownFragment LIKE '%\(marker)%';"
            )
            let stillOnDisk = (Int(countAfterRelaunch.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            let blockDump = FixtureDatabase.read(
                fixturePath: TestFixtureHelper.fixturePath,
                sql: "SELECT id, blockType, substr(markdownFragment, 1, 80) FROM block ORDER BY sortOrder;"
            )
            let elementDump = editorAreaAfterRelaunch.descendants(matching: .any).allElementsBoundByIndex
                .compactMap { element -> String? in
                    guard element.exists else { return nil }
                    let value = (element.value as? String) ?? ""
                    let label = element.label
                    guard !value.isEmpty || !label.isEmpty else { return nil }
                    return "value=\"\(value)\" label=\"\(label)\""
                }
                .joined(separator: "\n")
            XCTFail("""
                Typed text should survive a real terminate + relaunch, not just in-memory state. \
                \(stillOnDisk
                    ? "Marker IS still on disk -- render/timing bug, not a reload bug."
                    : "Marker is NOT on disk -- genuine reload/persistence bug.")
                Block table (id, blockType, markdownFragment prefix):
                \(blockDump)
                Post-relaunch editor accessibility elements (value/label):
                \(elementDump)
                """)
        }
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
