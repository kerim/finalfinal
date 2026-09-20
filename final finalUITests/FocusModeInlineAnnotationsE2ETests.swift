//
//  FocusModeInlineAnnotationsE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e proof for the Focus Mode delta of annotation-display-persistence: Settings > Focus has
//  "Hide Annotations Panel" (the panel only) and a new "Inline Annotations" menu (Leave As Is / Collapse /
//  Hide) for the annotations IN the text. Focus Mode's layer is in memory only: leaving it brings the project's
//  own saved values back, a project opened WHILE in Focus Mode gets the override and, on exit, its OWN values,
//  and changing the menu while in Focus Mode applies at once. All scenarios run in Rich Text mode.
//
//  Method -> scenario: V8 testProjectOpenedWhileInFocusMode... (Finder-open) and V8b ...ViaTheOpenProjectPanel... (the
//  in-app route; fragile, never run), V9a testHideInlineAnnotationsWithThePanelHidden...,
//  V9b testHideInlineAnnotationsWithThePanelKept..., V10 testHideAnnotationsPanelAlone..., V12
//  testChangingInlineAnnotationsWhileInFocusMode..., and testFocusPaneLayoutMatchesTheExportPane (Settings opens on
//  Export; the Focus pane must lay out like it). The persistence class drives the popover's "Set as Default" button in
//  Focus Mode through the helpers at the bottom of this file. V11 (relaunch
//  while in Focus Mode) is NOT driven here: `focusModeEnabled` lives in the test defaults domain, which
//  `AppDelegate.applicationWillFinishLaunching` (`AppDefaults.wipeTestDomainForUITesting`) AND
//  `TestMode.clearTestState()` (key "focusModeEnabled", called from `determineInitialState()`) both wipe on EVERY
//  UI-test launch before ContentView creates its EditorViewState, so a cold relaunch can never start in Focus
//  Mode; the unit test relaunchIntoFocusModeCapturesTheRestoredProjectsValues covers it.
//
//  Every launch starts with the Focus preferences wiped to their defaults, so each scenario sets them through the
//  Settings UI first. Paragraph Highlighting is switched OFF there so no block is dimmed (`.ff-dimmed`): the
//  heading and paragraph stay exposed in the AX tree, and every "annotations hidden" assertion names them as the
//  VISIBLE side, so a half-mounted tree can never satisfy it.
//

import AppKit
import XCTest

final class FocusModeInlineAnnotationsE2ETests: XCTestCase, AnnotationDisplayE2EHarness {
    var app: XCUIApplication!
    var secondFixturePath: String?
    private let seedA = Seed.projectA
    private let seedB = Seed.projectB

    override func setUpWithError() throws { try harnessSetUp() }
    override func tearDownWithError() throws { harnessTearDown() }

    // MARK: - V8 / V8b: a project opened while in Focus Mode (Finder-open, and the in-app Open Project panel)

    func testProjectOpenedWhileInFocusModeGetsTheOverrideAndKeepsItsOwnValues() throws {
        // The Finder-open route the project-switch suites use.
        let paths = try exerciseProjectOpenedWhileInFocusMode(tag: "v8") { path in
            self.app.activateAndWaitForForeground()
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        // Back to A (Focus Mode is off): A's own saved rendering.
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: paths.pathA))
        returnToDocument()
        assertEditorRendering(visible: seedA.all(except: [seedA.reference]), hidden: [seedA.reference], "A again: its own saved values")
        expectRows(["\(Row.comment)=collapsed"], at: paths.pathB, "B's rows must be unchanged after the round trip")
    }

    /// FRAGILE (never run): the same three claims through the IN-APP route, File > Open Project (Cmd-O), which posts
    /// `.projectDidOpen` like Finder-open but sends no Apple Event, so it cannot spawn a second window. Compared with V8 it tells
    /// which route is at fault. Unproven pieces: the open panel inside full-screen Focus Mode, its AX shape, and typing a path.
    func testProjectOpenedWhileInFocusModeViaTheOpenProjectPanelGetsTheOverride() throws {
        _ = try exerciseProjectOpenedWhileInFocusMode(tag: "v8b") { self.openViaOpenProjectPanel($0) }
    }

    /// A (Reference saved collapsed) and B (Comment saved collapsed); Collapse on, panel kept. Opens B through `openB` while in
    /// Focus Mode, then proves in ONE go: B is on screen, its IN-MEMORY display modes carry the override (popover), its document
    /// carries it (texts hidden), and after Esc both are B's OWN values. Returns the two project paths.
    private func exerciseProjectOpenedWhileInFocusMode(tag: String, openB: (String) -> Void) throws -> (pathA: String, pathB: String) {
        let pathA = TestFixtureHelper.fixturePath
        FixtureDatabase.seedMarkdown(fixturePath: pathA, markdown: seedA.markdown)
        saveRow(Row.reference, "collapsed", at: pathA)
        let pathB = try makeSecondFixture(seededWith: seedB)
        saveRow(Row.comment, "collapsed", at: pathB)
        // Every rendering poll below also guards (throttled: every 4th iteration, and once after the poll) that the app has
        // exactly one document window.
        func render(_ visible: [String], _ hidden: [String], _ context: String, shot: String? = nil, timeout: TimeInterval = 30, line: UInt = #line) {
            assertEditorRendering(
                visible: visible, hidden: hidden, context, shot: shot,
                onPoll: { self.assertSingleDocumentWindow(context, iteration: $0) }, timeout: timeout, line: line
            )
            assertSingleDocumentWindow(context, iteration: 0)
        }
        launchAndWaitForEditor()
        render(seedA.all(except: [seedA.reference]), [seedA.reference], "A before Focus Mode")

        // The panel is kept (Hide Annotations Panel off) so the eye popover can be read inside Focus Mode.
        configureFocusPreferences(inline: "Collapse", hideAnnotationsPanel: false)
        enterFocusMode("\(tag)-a-in-focus-mode")
        render([seedA.heading, seedA.paragraph], seedA.annotations, "A inside Focus Mode (Collapse forces every type)")

        openB(pathB)
        returnToDocument() // Finder or a panel can take focus away; the app must be brought back to its full-screen document
        recordWindows("\(tag): right after opening B")
        let bListed = panelListsCards([seedB.comment], timeout: 30)
        attachEvidenceScreenshot(app.screenshot(), name: "\(tag)-b-loaded-in-focus-mode")
        XCTAssertTrue(bListed, "B's annotations must be listed in the panel: B is the project on screen")

        // Which layer is wrong? The popover reads the window's IN-MEMORY display modes; the document below is what the editors
        // were told. Its own assertion, so the document-rendering assertion is not masked.
        openDisplayPopover()
        let overridden = waitUntil(timeout: 20) { self.popupModes() == ["Collapsed", "Collapsed", "Collapsed"] }
        attachEvidenceScreenshot(app.screenshot(), name: "\(tag)-b-popover-in-focus-mode")
        XCTAssertTrue(
            overridden, "B's in-memory state must carry Focus Mode's override (all three Collapsed); the popups read \(popupModes())"
        )
        render(
            [seedB.heading, seedB.paragraph], seedB.annotations,
            "B opened while in Focus Mode: on screen and overridden", shot: "\(tag)-b-opened-while-in-focus-mode", timeout: 40
        )
        // A short settle for the late-landing case (content pushed after the first clean snapshot).
        assertEditorStaysHidden(seedB.annotations, seconds: 3, "B opened while in Focus Mode")
        recordWindows("\(tag): after the settle")
        dismissDisplayPopover()

        // Esc in B: B's OWN values come back (its Comment collapsed, the rest inline), never A's, in the document AND in memory.
        exitFocusMode()
        render(seedB.all(except: [seedB.comment]), [seedB.comment], "B after Esc: its own saved values", shot: "\(tag)-b-after-esc")
        openDisplayPopover()
        XCTAssertEqual(
            popupModes(), ["Inline", "Collapsed", "Inline"],
            "After Esc B's in-memory state must be its OWN saved values (Task Inline, Comment Collapsed, Reference Inline)"
        )
        dismissDisplayPopover()
        expectRows(["\(Row.comment)=collapsed"], at: pathB, "B's stored rows must still be exactly its own")
        expectRows(["\(Row.reference)=collapsed"], at: pathA, "A's stored rows must be untouched")
        return (pathA, pathB)
    }

    // MARK: - V9: Inline Annotations = Hide, with and without the panel

    func testHideInlineAnnotationsWithThePanelHiddenLeavesNoTextAndNoPanel() throws {
        launchProjectAWithSavedComment()
        configureFocusPreferences(inline: "Hide", hideAnnotationsPanel: true)
        XCTAssertTrue(isPanelVisible, "The Annotations panel must be on screen before Focus Mode")
        enterFocusMode("v9a-hide-panel-hidden")
        assertEditorRendering(visible: [seedA.heading, seedA.paragraph], hidden: seedA.annotations, "Hide + panel hidden: no annotation text")
        XCTAssertTrue(waitUntil { !self.isPanelVisible }, "The Annotations panel must be gone")
        exitFocusMode()
        assertOwnRendering("after Esc")
        openDisplayPopover()
        XCTAssertFalse(isChecked(checkbox(withID: ControlID.panelOnly)), "After Esc the popover's Panel Only reads unticked")
        expectRows(["\(Row.comment)=collapsed"], "Nothing Focus Mode did may be written to the project")
    }

    func testHideInlineAnnotationsWithThePanelKeptListsTheCardsAndKeepsThePopupsEnabled() throws {
        launchProjectAWithSavedComment()
        configureFocusPreferences(inline: "Hide", hideAnnotationsPanel: false)
        XCTAssertTrue(isPanelVisible, "The Annotations panel must be on screen before Focus Mode")
        enterFocusMode("v9b-hide-panel-kept")
        assertEditorRendering(
            visible: [seedA.heading, seedA.paragraph], hidden: seedA.annotations, "Hide + panel kept: no annotation text in the document"
        )
        XCTAssertTrue(panelListsCards(seedA.annotations), "Every annotation must still be listed as a card in the panel")
        // Inside Focus Mode the popover's three popups stay ENABLED (they key off the user's own Panel Only choice) and
        // still show the project's saved mode, while its Panel Only checkbox reads ticked (the mechanism doing the hiding).
        openDisplayPopover()
        attachEvidenceScreenshot(app.screenshot(), name: "v9b-popover-inside-focus-mode")
        let popups = popoverPopups()
        XCTAssertEqual(popups.count, 3, "The three per-type popups must be present")
        XCTAssertTrue(popups.allSatisfy { $0.isEnabled }, "The per-type popups must stay ENABLED under Hide")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.comment), "Collapsed", "The Comment popup must show the saved mode")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.panelOnly)), "Panel Only reads ticked while Hide is armed")
        dismissDisplayPopover()
        exitFocusMode()
        assertOwnRendering("after Esc")
        openDisplayPopover()
        XCTAssertFalse(isChecked(checkbox(withID: ControlID.panelOnly)), "After Esc the popover's Panel Only reads unticked")
        expectRows(["\(Row.comment)=collapsed"], "Nothing Focus Mode did may be written to the project")
    }

    // MARK: - V10: the panel and the inline text are separate choices

    func testHideAnnotationsPanelAloneLeavesTheInlineTextAsItWas() throws {
        launchProjectAWithSavedComment()
        configureFocusPreferences(inline: "Leave As Is", hideAnnotationsPanel: true)
        XCTAssertTrue(isPanelVisible, "The Annotations panel must be on screen before Focus Mode")
        enterFocusMode("v10-panel-hidden-text-untouched")
        XCTAssertTrue(waitUntil { !self.isPanelVisible }, "The Annotations panel must be gone")
        assertOwnRendering("inside Focus Mode with Leave As Is: exactly as before")
        exitFocusMode()
        assertOwnRendering("after Esc: still exactly as before")
        expectRows(["\(Row.comment)=collapsed"], "Nothing may be written to the project")
    }

    // MARK: - V12: the notification seam (changing the menu while in Focus Mode)

    func testChangingInlineAnnotationsWhileInFocusModeAppliesWithoutReEntering() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        configureFocusPreferences(inline: "Leave As Is", hideAnnotationsPanel: true)
        enterFocusMode("v12-focus-mode-leave-as-is")
        assertEditorRendering(visible: seedA.all(), hidden: [], "Leave As Is: every annotation text visible inside Focus Mode")

        // Change the menu in Settings while STILL in Focus Mode: the open document must follow at once. Settings opens on
        // the desktop Space (the full-screen document has its own), so the document is observed only after returning to
        // it. Focus Mode is never left, which is what keeps this a proof of the notification seam.
        changeInlineAnnotationsInsideFocusMode(to: "Hide")
        assertEditorRendering(
            visible: [seedA.heading, seedA.paragraph], hidden: seedA.annotations, "Hide applied to the open document without re-entering Focus Mode",
            shot: "v12-hide-applied-live"
        )
        changeInlineAnnotationsInsideFocusMode(to: "Leave As Is")
        assertEditorRendering(visible: seedA.all(), hidden: [], "Leave As Is again: the annotations return")
        exitFocusMode()
        expectRows([], "Nothing may be written to the project")
    }

    // MARK: - Focus pane layout parity with Export

    func testFocusPaneLayoutMatchesTheExportPane() throws {
        launchAndWaitForEditor()
        openSettingsWithShortcut()
        attachEvidenceScreenshot(app.screenshot(), name: "layout-export-tab")
        expectSettingsTitle("Export", "Settings must open on Export")
        let export = sectionMetrics("exportPandocGroup")
        let exportWindowWidth = settledSettingsWidth()

        selectSettingsTab("Focus")
        attachEvidenceScreenshot(app.screenshot(), name: "layout-focus-tab")
        expectSettingsTitle("Focus", "The Focus tab must show Focus")
        let focus = sectionMetrics("focusGroup")
        let focusWindowWidth = settledSettingsWidth()
        XCTAssertEqual(export.leadingInset, focus.leadingInset, accuracy: 4, "Focus's group box must sit at Export's leading inset")
        XCTAssertEqual(export.width, focus.width, accuracy: 20, "Focus's group box must be as wide as Export's")
        // A long caption must wrap inside its measure instead of widening the window.
        XCTAssertEqual(exportWindowWidth, focusWindowWidth, accuracy: 4, "The Settings window must not change width between tabs")
    }
}

extension FocusModeInlineAnnotationsE2ETests {
    /// Writes one `settings` row into a project's database (only ever before the app has opened that project).
    private func saveRow(_ key: String, _ value: String, at path: String) {
        FixtureDatabase.write(
            fixturePath: path,
            sql: "INSERT OR REPLACE INTO settings (\"key\", \"value\") VALUES ('\(key)', '\(value)');"
        )
    }

    /// Project A with its own Comment saved collapsed, launched and checked against that own rendering.
    private func launchProjectAWithSavedComment() {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        saveRow(Row.comment, "collapsed", at: TestFixtureHelper.fixturePath)
        launchAndWaitForEditor()
        assertOwnRendering("before Focus Mode (Comment saved collapsed)")
    }

    private func assertOwnRendering(_ context: String, line: UInt = #line) {
        assertEditorRendering(visible: seedA.all(except: [seedA.comment]), hidden: [seedA.comment], context, line: line)
    }

    /// The Annotations panel is on screen iff its display-mode (eye) button is.
    private var isPanelVisible: Bool {
        app.buttons.matching(identifier: ControlID.eyeButton).firstMatch.exists
    }

    /// Whether every text is listed in the app's native side panel: in ONE snapshot of the main window, some
    /// StaticText whose label or value CONTAINS it (a card may decorate its text). Callers assert the document
    /// copies hidden first, so a match is a card.
    private func panelListsCards(_ texts: [String], timeout: TimeInterval = 10) -> Bool {
        let window = app.windows.containing(.group, identifier: "editor-area").firstMatch
        return waitUntil(timeout: timeout) {
            guard let nodes = self.nodes(of: window) else { return false }
            return texts.allSatisfy { text in
                nodes.contains { $0.elementType == .staticText && [$0.label, $0.value ?? ""].contains { $0.contains(text) } }
            }
        }
    }

    /// The texts must stay absent from the document across `seconds` of polling: a project's content can land
    /// after the first clean snapshot.
    private func assertEditorStaysHidden(
        _ texts: [String], seconds: TimeInterval, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var leaked: [String] = []
        waitUntil(timeout: seconds, pollInterval: 0.5) {
            if let nodes = self.editorNodes() { leaked = texts.filter { self.isTextVisible($0, in: nodes) } }
            return !leaked.isEmpty
        }
        XCTAssertTrue(leaked.isEmpty, "\(context): annotation text appeared in the document: \(leaked)", file: file, line: line)
    }

    /// Sets Settings > Focus from the UI, then closes Settings. Needed after every launch: the app wipes the test
    /// defaults on each one. Paragraph Highlighting goes OFF so no block is dimmed.
    private func configureFocusPreferences(inline: String, hideAnnotationsPanel: Bool) {
        openSettingsWithShortcut()
        selectSettingsTab("Focus")
        expectSettingsTitle("Focus", "The Focus tab must show Focus")
        setSettingsCheckbox("focusHideAnnotationsPanelToggle", to: hideAnnotationsPanel)
        setSettingsCheckbox("focusParagraphHighlightingToggle", to: false)
        setInlineAnnotations(inline)
        closeSettingsWindow()
    }

    private func setSettingsCheckbox(_ identifier: String, to desired: Bool) {
        let box = firstExisting(
            [
                settingsWindow.checkBoxes.matching(identifier: identifier).firstMatch,
                settingsWindow.switches.matching(identifier: identifier).firstMatch,
                settingsWindow.descendants(matching: .any).matching(identifier: identifier).firstMatch
            ],
            timeout: 10
        )
        guard let box else {
            attachEditorTree(settingsNodes(), "Settings window (checkbox \(identifier) not found)")
            XCTFail("Settings > Focus should have the \"\(identifier)\" checkbox; see the tree attachment")
            return
        }
        if isChecked(box) != desired { box.click() }
        XCTAssertTrue(waitUntil { self.isChecked(box) == desired }, "\"\(identifier)\" should read \(desired ? "ticked" : "unticked")")
    }

    /// Chooses an option in Settings > Focus > Inline Annotations. The popup is read before and after: the read must
    /// be non-empty (the identifier lands on the popup button) and equal the option once chosen.
    private func setInlineAnnotations(_ option: String) {
        let before = selection(ofPickerWithID: ControlID.focusInlinePicker)
        XCTAssertFalse(before.isEmpty, "The Inline Annotations popup must expose its current value")
        if before != option { chooseOption(option, inPickerWithID: ControlID.focusInlinePicker) }
        XCTAssertEqual(selection(ofPickerWithID: ControlID.focusInlinePicker), option, "Inline Annotations must read \(option)")
    }

    /// Opens Settings (which moves to the desktop Space), sets the menu, closes Settings, and returns to the full-screen document.
    private func changeInlineAnnotationsInsideFocusMode(to option: String) {
        openSettingsWithShortcut()
        attachEvidenceScreenshot(app.screenshot(), name: "v12-settings-opened-inside-focus-mode (\(option))")
        selectSettingsTab("Focus")
        expectSettingsTitle("Focus", "The Focus tab must show Focus")
        setInlineAnnotations(option)
        closeSettingsWindow()
        returnToDocument()
    }

    /// Evidence, not an assertion: how many windows the app has and what they are, so a second window spawned by a
    /// project open is visible in the artefacts.
    private func recordWindows(_ context: String) {
        let note = XCTAttachment(string: "\(context): \(app.windows.count) window(s)\n" + windowSummaries().joined(separator: "\n"))
        note.name = "windows \(context)"
        note.lifetime = .keepAlways
        add(note)
    }

    private func windowSummaries() -> [String] {
        app.windows.allElementsBoundByIndex.map { "\"\($0.title)\" id=\"\($0.identifier)\" frame=\($0.frame)" }
    }

    /// Guard run from V8's rendering polls: the app's DOCUMENT windows (every window except Settings and the open panel)
    /// must never number more than one. It costs three `app.windows` queries, so it is THROTTLED to poll iterations 1, 5, 9, ...
    /// (on top of `editorNodes()` every 0.5s, a check per iteration could exhaust the poll's timeout) and always runs when
    /// `iteration` is 0 (the call after a rendering poll). Names the iteration and every window. Zero is tolerated (a Space or
    /// full-screen transition can hide the window for a moment): `assertEditorRendering` fails on a missing editor by itself.
    private func assertSingleDocumentWindow(_ context: String, iteration: Int) {
        guard iteration % 4 == 1 || iteration == 0 else { return }
        let excluded = ["com_apple_SwiftUI_Settings_window", "open-panel"].map { app.windows.matching(identifier: $0).count }.reduce(0, +)
        let count = app.windows.count - excluded
        guard count > 1 else { return }
        let summary = "\(context): \(count) document windows at poll iteration \(iteration)\n" + windowSummaries().joined(separator: "\n")
        let note = XCTAttachment(string: summary)
        note.name = "windows guard \(context)"
        note.lifetime = .keepAlways
        add(note)
        XCTFail("A second document window appeared \(context) (poll iteration \(iteration)): \(windowSummaries())")
    }

    /// The in-app route to open a project: File > Open Project (Cmd-O), the open panel, Go to Folder (Cmd-Shift-G), the path,
    /// then the panel's own Open button. Element-driven: each step waits on its own postcondition and fails naming the step;
    /// one bounded attempt, no retries and no blind Return (a second Return never reached the default button in run 88955).
    private func openViaOpenProjectPanel(_ path: String) {
        app.activateAndWaitForForeground()
        app.typeKey("o", modifierFlags: .command)
        let panel = app.windows["open-panel"]
        let appeared = panel.waitForExistence(timeout: 10)
        attachEvidenceScreenshot(app.screenshot(), name: "v8b-open-panel")
        guard appeared else { return XCTFail("Step 1 (Cmd-O): no open panel appeared inside full-screen Focus Mode; see v8b-open-panel") }
        app.typeKey("g", modifierFlags: [.command, .shift])
        // The sheet's own field, not `TextField (First Match)` (the panel's toolbar Search field is a second text field).
        let pathField = panel.sheets.firstMatch.textFields.firstMatch
        guard pathField.waitForExistence(timeout: 5) else { return XCTFail("Step 2 (Cmd-Shift-G): the Go to Folder field did not appear") }
        pathField.typeText(path)
        app.typeKey(.enter, modifierFlags: [])
        guard panel.sheets.firstMatch.waitForDisappearance(timeout: 10) else { return XCTFail("Step 3 (Return): the sheet did not close") }
        let open = panel.buttons["Open"]
        guard open.waitForExistence(timeout: 5) else { return XCTFail("Step 4: the open panel has no Open button after Go to Folder") }
        open.click()
        guard panel.waitForDisappearance(timeout: 15) else { return XCTFail("Step 5 (Open): the open panel did not close after clicking Open") }
        guard app.editorArea.waitForExistence(timeout: 15) else { return XCTFail("Step 6: the editor did not come back after the panel closed") }
    }

    /// Leading inset (relative to the window) and width of a Settings section's group box. The GroupBox's TITLE
    /// view ("Pandoc", "Focus") shows in the window's AX snapshot but is NOT reachable by an XCUITest query
    /// (10 polls found nothing while the same-moment dump showed it). Never query it; the group carries the geometry.
    private func sectionMetrics(_ groupID: String) -> (leadingInset: CGFloat, width: CGFloat) {
        let group = app.descendants(matching: .any).matching(identifier: groupID).firstMatch
        guard group.waitForExistence(timeout: 10) else {
            XCTFail("Settings group box \"\(groupID)\" not found")
            return (0, 0)
        }
        return (group.frame.minX - settingsWindow.frame.minX, group.frame.width)
    }

    /// The Settings window's width once it reads the same on two consecutive polls (a tab switch can resize mid-animation).
    private func settledSettingsWidth() -> CGFloat {
        var previous: CGFloat = -1
        waitUntil(timeout: 3, pollInterval: 0.3) {
            let now = self.settingsWindow.frame.width
            defer { previous = now }
            return now == previous
        }
        return settingsWindow.frame.width
    }
}

// MARK: - Full screen and Spaces (shared with the persistence class through the harness protocol)

extension AnnotationDisplayE2EHarness {
    /// The document window: the one containing the editor area (a Settings window can shadow `windows.firstMatch`).
    var mainWindow: XCUIElement { app.windows.containing(.group, identifier: "editor-area").firstMatch }

    func isMainWindowFullScreen(tolerance: CGFloat = 4) -> Bool {
        guard let screen = NSScreen.main?.frame, mainWindow.exists else { return false }
        let frame = mainWindow.frame
        return abs(frame.width - screen.width) <= tolerance && abs(frame.height - screen.height) <= tolerance
    }

    /// Waits for the full-screen geometry to read `expected` on two consecutive polls (settled, not mid-animation).
    @discardableResult
    func waitForFullScreen(_ expected: Bool, timeout: TimeInterval = 12) -> Bool {
        var consecutive = 0
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            consecutive = isMainWindowFullScreen() == expected ? consecutive + 1 : 0
            if consecutive >= 2 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        }
        return false
    }

    /// Leaves native full screen; true once the window is out. Ctrl-Cmd-F is deliberately never pressed: it is bound to
    /// nothing in this app (four presses over 25s changed nothing, verified in run 49061). Rungs: Esc twice, only when Focus
    /// Mode may be on (its proven exit); then the app's own path twice (Shift-Cmd-F enters Focus Mode, the status bar
    /// goes, Esc leaves it); then the window's own full-screen button. The last rung exists because Focus Mode's entry
    /// snapshot records a window that is ALREADY full screen and its exit then leaves it that way.
    @discardableResult
    func leaveFullScreen(escapeFirst: Bool) -> Bool {
        let escape = { self.app.typeKey(.escape, modifierFlags: []) }
        let focusRoundTrip = {
            self.app.typeKey("f", modifierFlags: [.command, .shift])
            _ = self.app.groups["status-bar"].waitForDisappearance(timeout: 10)
            self.app.typeKey(.escape, modifierFlags: [])
        }
        let windowButton = {
            let button = self.mainWindow.buttons[XCUIIdentifierFullScreenWindow]
            if button.exists { button.click() }
        }
        for rung in (escapeFirst ? [escape, escape] : []) + [focusRoundTrip, focusRoundTrip, windowButton] {
            app.activate()
            rung()
            if waitForFullScreen(false, timeout: 8) { return true }
        }
        return false
    }

    /// Full screen restored at launch is Cocoa's own window-state restoration (the app's own restore is off under test):
    /// leave it before the body runs, so no test depends on the one before it. Reports what it saw when it cannot.
    func leaveRestoredFullScreen() {
        guard isMainWindowFullScreen() else { return }
        attachEvidenceScreenshot(app.screenshot(), name: "launch-restored-full-screen")
        guard !leaveFullScreen(escapeFirst: false) else { return }
        XCTFail(
            "The window was restored in full screen at launch and would not leave it: window frame \(mainWindow.frame), "
                + "screen frame \(NSScreen.main?.frame ?? .zero), status bar exists (Focus Mode off): \(app.groups["status-bar"].exists)"
        )
    }

    /// Teardown: returns a failure message rather than raising it (see `harnessTearDown`). A main window that cannot be
    /// found is NOT "nothing to do": the app may be full screen on another Space.
    func leaveFullScreenIfNeeded() -> String? {
        guard app.state != .notRunning else { return nil }
        // An open, key Settings window swallows Esc: close it first with its close button (never Cmd-W).
        let close = settingsWindow.buttons[XCUIIdentifierCloseWindow]
        if close.exists {
            close.click()
            _ = settingsWindow.waitForDisappearance(timeout: 5)
        }
        if !mainWindow.exists {
            app.activate()
            _ = mainWindow.waitForExistence(timeout: 5)
        }
        guard mainWindow.exists else {
            attachEvidenceScreenshot(app.screenshot(), name: "teardown-main-window-not-found")
            return "The main window (editor area) could not be found at teardown: the app may be full screen on another Space"
        }
        guard isMainWindowFullScreen() else { return nil }
        if leaveFullScreen(escapeFirst: true) { return nil }
        attachEvidenceScreenshot(app.screenshot(), name: "teardown-stuck-full-screen")
        return "Main window is still in native full screen after Esc and Ctrl-Cmd-F; later tests in this shard may be contaminated"
    }

    /// Brings the app, and the Space of its full-screen document, back after Settings or a Finder-open moved focus to
    /// the desktop Space, and waits for the editor.
    func returnToDocument() {
        for _ in 1...3 {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 5)
            if app.editorArea.waitForExistence(timeout: 5) { return }
        }
        XCTFail("The document window did not come back on screen after re-activating the app")
    }
}

// MARK: - Focus Mode, Settings > Focus and popover helpers (shared with the persistence class through the harness protocol)

extension AnnotationDisplayE2EHarness {
    /// Enters Focus Mode with the shortcut, waits for the status bar to go and full screen to settle, then takes
    /// the still (before any assertion that can abort).
    func enterFocusMode(_ shotName: String) {
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: [.command, .shift])
        let entered = app.groups["status-bar"].waitForDisappearance(timeout: 10)
        waitForFullScreen(true)
        attachEvidenceScreenshot(app.screenshot(), name: shotName)
        XCTAssertTrue(entered, "The status bar should disappear in Focus Mode")
    }

    /// Leaves Focus Mode with Esc, or with the toggle shortcut when `withShortcut` (Esc would close an open popover first).
    func exitFocusMode(withShortcut: Bool = false) {
        app.activateAndWaitForForeground()
        if withShortcut { app.typeKey("f", modifierFlags: [.command, .shift]) } else { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(app.groups["status-bar"].waitForExistence(timeout: 10), "Focus Mode should end (status bar back)")
        waitForFullScreen(false)
    }

    /// The Task / Comment / Reference popups' selections in the OPEN popover, i.e. the window's in-memory display modes
    /// ("?" for a popup that is missing). Never fails: callers poll it.
    func popupModes() -> [String] {
        [ControlID.task, ControlID.comment, ControlID.reference].map { identifier in
            guard let popup = awaitControl(identifier, kind: .picker, timeout: 0) else { return "?" }
            if let value = popup.value as? String, !value.isEmpty { return value }
            return popup.title
        }
    }

    /// Focus Mode with the Annotations panel KEPT, so the eye button and its popover stay reachable in Focus Mode: "Hide
    /// Annotations Panel" (FocusModeSettings.hideRightSidebar) defaults to TRUE and would hide the panel the popover lives
    /// in. Must run after every launch (the app wipes the test defaults domain on each one); it is idempotent, so it also
    /// re-selects Inline Annotations while windowed. Uses the app-wide setCheckbox/chooseOption, which resolve controls in
    /// the Settings window too.
    func configureFocusKeepingTheAnnotationsPanel(inline: String) {
        openSettingsWithShortcut()
        selectSettingsTab("Focus")
        expectSettingsTitle("Focus", "The Focus tab must show Focus")
        setCheckbox(withID: ControlID.focusHidePanelToggle, to: false)
        chooseOption(inline, inPickerWithID: ControlID.focusInlinePicker)
        closeSettingsWindow()
    }

    /// Makes sure Settings > Focus > "Inline Annotations" reads "Collapse" (the default, so it normally only reads it).
    func ensureFocusInlineAnnotationsIsCollapse() {
        openSettingsWithShortcut()
        selectSettingsTab("Focus")
        let picker = ControlID.focusInlinePicker
        if selection(ofPickerWithID: picker) != "Collapse" { chooseOption("Collapse", inPickerWithID: picker) }
        XCTAssertEqual(selection(ofPickerWithID: picker), "Collapse", "Inline Annotations must be Collapse for the Focus Mode round trip")
        closeSettingsWindow()
    }

    /// The OPEN popover's "Set as Default" button, once it reads `enabled` (polled: the state can land a beat after the popover
    /// opens), and its reason caption: shown with its text while the button is disabled, absent while it is enabled. Every read
    /// comes first, then the still, then the assertions, so an abort never skips the evidence. Returns the button for a click.
    @discardableResult
    func expectSetAsDefault(
        enabled: Bool, shot: String, _ why: String, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement? {
        let popover = app.popovers.firstMatch
        let button = awaitControl(ControlID.setAsDefault, kind: .button)
        let settled = button.map { found in waitUntil(timeout: 5) { found.isEnabled == enabled } } ?? false
        let reason = popover.descendants(matching: .any).matching(identifier: ControlID.setAsDefaultDisabledReason).firstMatch
        let reasonAsExpected = button != nil && waitUntil(timeout: 5) { reason.exists == !enabled }
        let reasonTexts = reason.exists ? [reason.label, reason.title, reason.value as? String ?? ""] : []
        attachEvidenceScreenshot(app.screenshot(), name: shot)
        guard let button else {
            attachEditorTree(nodes(of: popover) ?? [], "popover tree: no Set as Default button (\(why))")
            XCTFail("The display popover has no \"Set as Default\" button (\(why)); see \(shot) and the popover tree", file: file, line: line)
            return nil
        }
        XCTAssertTrue(settled, "\(why): the button read isEnabled = \(button.isEnabled)", file: file, line: line)
        XCTAssertTrue(reasonAsExpected, "\(why): the reason caption must be \(enabled ? "absent" : "shown under the button")", file: file, line: line)
        if !enabled {
            let reasonText = "Unavailable while Focus Mode is changing how annotations are shown"
            XCTAssertTrue(reasonTexts.contains { $0.contains(reasonText) }, "\(why): the caption read \(reasonTexts)", file: file, line: line)
        }
        return button
    }

    /// A TRANSIENT text in the popover (the confirming button fades back after ~3s): it is READ as soon as the element exists, then
    /// the still is taken, then the assertions run, so a slow still cannot lose it. The query is scoped to the popover (small;
    /// searching the whole app tree is slow). The text may be in the label, title or value.
    func expectPopoverText(_ identifier: String, _ text: String, shot: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.popovers.firstMatch.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let appeared = element.waitForExistence(timeout: 5)
        let read = appeared ? [element.label, element.title, element.value as? String ?? ""] : []
        attachEvidenceScreenshot(app.screenshot(), name: shot)
        XCTAssertTrue(appeared, "\"\(identifier)\" must appear; see \(shot)", file: file, line: line)
        XCTAssertTrue(read.contains { $0.contains(text) }, "\"\(identifier)\" must read \"\(text)\"; it read \(read)", file: file, line: line)
    }

    /// Right after a Set as Default click the button is relabelled in place ("Saved as default", identifier switched to the
    /// confirmation's) for ~3s: that text is asserted FIRST. Only then is it checked that no toast about the default appeared (the
    /// confirmation is the only success feedback), so a slow query cannot mask the primary assertion. Focus Mode's own exit-hint
    /// toast can still be up in a Focus scenario, so this looks for a toast mentioning the default, not for any toast.
    func expectSavedAsDefaultConfirmation(shot: String, file: StaticString = #filePath, line: UInt = #line) {
        expectPopoverText(ControlID.setAsDefaultConfirmation, "Saved as default", shot: shot, file: file, line: line)
        let toast = app.descendants(matching: .any).matching(identifier: "toast-message").firstMatch
        let read = toast.exists ? [toast.label, toast.title, toast.value as? String ?? ""] : []
        XCTAssertFalse(
            read.contains { $0.localizedCaseInsensitiveContains("default") }, "Set as Default must show no toast; a toast read \(read)",
            file: file, line: line
        )
    }
}

// MARK: - Document accessibility-tree reading and popover layout (shared with the persistence class through the harness protocol)

struct AnnotationDisplayAXNode {
    let elementType: XCUIElement.ElementType
    let label: String
    let title: String
    let identifier: String
    let value: String?
}

extension AnnotationDisplayE2EHarness {
    func flatten(_ snapshot: XCUIElementSnapshot, into nodes: inout [AXNode]) {
        for child in snapshot.children {
            nodes.append(AXNode(
                elementType: child.elementType, label: child.label, title: child.title,
                identifier: child.identifier, value: child.value as? String
            ))
            flatten(child, into: &nodes)
        }
    }

    /// The whole subtree of `element` in ONE accessibility round trip, or nil if it is not there.
    func nodes(of element: XCUIElement) -> [AXNode]? {
        guard let root = try? element.snapshot() else { return nil }
        var nodes: [AXNode] = []
        flatten(root, into: &nodes)
        return nodes
    }

    func editorNodes() -> [AXNode]? { nodes(of: app.editorArea) }

    func settingsNodes() -> [AXNode] { nodes(of: settingsWindow) ?? [] }

    /// Editor text lives in `value`, never `label`; only StaticText counts (a collapsed marker is not visible text).
    func isTextVisible(_ text: String, in nodes: [AXNode]) -> Bool {
        nodes.contains { $0.elementType == .staticText && ($0.value ?? "").contains(text) }
    }

    /// A collapsed annotation should expose a wrapper (role=img, aria-label) named by its text; the AX mapping
    /// is unverified, so match loosely: any NON-StaticText node whose label, title or value contains the text.
    func hasCollapsedMarker(for text: String, in nodes: [AXNode]) -> Bool {
        nodes.contains { node in
            node.elementType != .staticText && [node.label, node.title, node.value ?? ""].contains { $0.contains(text) }
        }
    }

    /// Attaches a dump of `nodes` (element type, label, title, identifier, value) as evidence.
    func attachEditorTree(_ nodes: [AXNode], _ context: String, limit: Int = 250) {
        let lines = nodes.prefix(limit).enumerated().map { index, node in
            "[\(index)] \(node.elementType) label=\"\(node.label)\" title=\"\(node.title)\" "
                + "id=\"\(node.identifier)\" value=\"\(node.value ?? "<nil>")\""
        }
        let dump = XCTAttachment(string: lines.joined(separator: "\n"))
        dump.name = "editor-tree: \(context)"
        dump.lifetime = .keepAlways
        add(dump)
    }

    /// Polls the editor's tree until every `visible` text is present, every `hidden` text is
    /// absent, and the tree holds at least one non-empty StaticText (so an empty or half-mounted
    /// tree can never satisfy "hidden"), all read from ONE snapshot. Attaches the tree dump either
    /// way and returns whether it was satisfied; a failure names the texts on the wrong side.
    /// `shot` names a still taken after the poll but before any failure is raised; `onPoll` runs at the start of every
    /// poll iteration with its number (a per-iteration guard; nil for every caller that does not pass one).
    @discardableResult
    func assertEditorRendering(
        visible: [String], hidden: [String], _ context: String, shot: String? = nil, onPoll: ((Int) -> Void)? = nil,
        timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        guard app.editorArea.waitForExistence(timeout: min(timeout, 15)) else {
            attachEvidenceScreenshot(app.screenshot(), name: "editor-not-on-screen")
            XCTFail("Editor not on screen \(context): the app may be off its document's Space", file: file, line: line)
            return false
        }
        var lastNodes: [AXNode] = []
        var iteration = 0
        let satisfied = waitUntil(timeout: timeout, pollInterval: 0.5) {
            iteration += 1
            onPoll?(iteration)
            guard let nodes = self.editorNodes() else { return false }
            lastNodes = nodes
            return nodes.contains { $0.elementType == .staticText && !($0.value ?? "").isEmpty }
                && visible.allSatisfy { self.isTextVisible($0, in: nodes) }
                && hidden.allSatisfy { !self.isTextVisible($0, in: nodes) }
        }
        attachEditorTree(lastNodes, context)
        if let shot { attachEvidenceScreenshot(app.screenshot(), name: shot) }
        if !satisfied {
            let missing = visible.filter { !isTextVisible($0, in: lastNodes) }
            let shown = hidden.filter { isTextVisible($0, in: lastNodes) }
            XCTFail("Editor rendering wrong \(context): missing \(missing); still shown \(shown); see the tree attachment", file: file, line: line)
        }
        return satisfied
    }
}

extension AnnotationDisplayE2EHarness {
    /// Layout of the OPEN popover (Comment Collapsed, the others Inline). A `.menu` Picker draws at INTRINSIC
    /// width (Collapsed 108pt, 110 via XCUITest; the old 90pt frame clipped it), so the provable claims are: one
    /// shared leading edge (no sideways jump), the Collapsed popup not clamped (>= 105), row labels not wrapped,
    /// and content no wider than needed. maxX is not compared: drawn widths legitimately differ.
    func assertPopoverLayout() {
        let popups = popoverPopups()
        XCTAssertEqual(popups.count, 3, "All three per-type popups must be present")
        let leftEdges = popups.map { $0.frame.minX }
        XCTAssertLessThanOrEqual((leftEdges.max() ?? 0) - (leftEdges.min() ?? 0), 1, "The popups must share one leading edge; minX: \(leftEdges)")
        XCTAssertGreaterThanOrEqual(popups[1].frame.width, 105, "The Collapsed popup must not be clamped back to 90pt")
        // Content span = Panel Only checkbox left edge to the widest popup's right edge, plus 16pt padding each
        // side: ~254 at the 260 popover, ~274 at the old 280. The popover element's own AX frame includes ~13pt of
        // AppKit window chrome per side (240 wide reads 266), so it is deliberately not used.
        let span = (popups.map { $0.frame.maxX }.max() ?? 0) - checkbox(withID: ControlID.panelOnly).frame.minX + 32
        XCTAssertLessThanOrEqual(span, 265, "The popover content must be no wider than needed (span \(span))")
        // A label taller than one line is wrapped mid-word ("Comme / nt"): the label column lost width.
        for name in ["Task", "Comment", "Reference"] {
            let byName = NSPredicate(format: "label == %@ OR value == %@", name, name)
            let label = app.popovers.firstMatch.descendants(matching: .staticText).matching(byName).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), "Row label \"\(name)\" not found in the popover")
            XCTAssertLessThanOrEqual(label.frame.height, 20, "Row label \"\(name)\" is taller than one line: it wraps")
        }
    }
}
