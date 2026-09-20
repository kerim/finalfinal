//
//  AnnotationDisplayPersistenceE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e proof for annotation-display-persistence: the five annotation display settings
//  (three per-type modes, Panel Only, Hide Completed) are saved per project; the popover's "Set as Default"
//  button stores those five as app-wide defaults that seed any project with no saved value per option (its
//  button is disabled while Focus Mode overrides the display); Settings has no General tab and opens on
//  Export unless a caller asks for a tab. The method names carry the scenario mapping.
//
//  "Relaunch" = a cold launch opening the SAME on-disk project through the UI-test fixture path: the
//  project opens in `determineInitialState()` before the editor view exists, exactly where the real
//  reopen-last-project launch opens it, so editor JS is not ready when settings load. The literal
//  bookmark-restore route cannot work here: `AppDelegate` wipes the test defaults domain, the
//  `lastProjectBookmark` included, at every UI-test launch.
//
//  DOCUMENT assertions read the WKWebView accessibility tree, never the popover alone. Every "hidden"
//  claim is checked against a non-empty tree (and usually "visible" controls) from the SAME snapshot.
//  The collapsed marker node (role=img + aria-label) is checked only by its own standalone test.
//

import AppKit
import XCTest

struct AnnotationDisplaySeed {
    let heading: String
    let paragraph: String
    let task: String
    let doneTask: String
    let comment: String
    let reference: String

    var markdown: String {
        [
            "# \(heading)", paragraph,
            "<!-- ::task:: [ ] \(task) -->", "<!-- ::task:: [x] \(doneTask) -->",
            "<!-- ::comment:: \(comment) -->", "<!-- ::reference:: \(reference) -->"
        ].joined(separator: "\n\n")
    }

    var annotations: [String] { [task, doneTask, comment, reference] }

    /// The heading, paragraph and every annotation text, minus `excluded`.
    func all(except excluded: [String] = []) -> [String] {
        ([heading, paragraph] + annotations).filter { !excluded.contains($0) }
    }

    static let projectA = AnnotationDisplaySeed(
        heading: "Annotation Display Persistence", paragraph: "Persistence probe paragraph before the annotations.",
        task: "Persistence probe task open", doneTask: "Persistence probe task done",
        comment: "Persistence probe comment", reference: "Persistence probe reference"
    )

    /// A second project with different texts, so what is on screen identifies the project.
    static let projectB = AnnotationDisplaySeed(
        heading: "Second Project Heading", paragraph: "Second project paragraph before the annotations.",
        task: "Second project task open", doneTask: "Second project task done",
        comment: "Second project comment", reference: "Second project reference"
    )
}

/// `settings`-table rows and identifiers, spelled out on purpose: importing the app's key builder would hide a rename.
enum AnnotationDisplayRow {
    static let comment = "annotationDisplayMode.comment"
    static let reference = "annotationDisplayMode.reference"
    static let panelOnly = "annotationPanelOnly"
    static let hideCompleted = "annotationHideCompleted"
}

enum AnnotationDisplayControlID {
    static let modePickerPrefix = "annotationDisplayModePicker."
    static let comment = modePickerPrefix + "comment"
    static let task = modePickerPrefix + "task"
    static let reference = modePickerPrefix + "reference"
    static let panelOnly = "annotationPanelOnlyToggle"
    static let hideCompleted = "annotationHideCompletedToggle"
    static let eyeButton = "annotationDisplayModeButton"
    static let setAsDefault = "annotationSetAsDefaultButton"
    static let setAsDefaultConfirmation = "annotationSetAsDefaultConfirmation"
    static let setAsDefaultDisabledReason = "annotationSetAsDefaultDisabledReason"
    static let focusInlinePicker = "focusInlineAnnotationsPicker"
    static let focusHidePanelToggle = "focusHideAnnotationsPanelToggle"
}

enum AnnotationDisplayControlKind { case picker, checkbox, button }

/// What the annotation-display test classes share: the app handle, a second fixture to clean up, and the helpers
/// below. A protocol extension, not a base class, so no test method is inherited and re-run.
protocol AnnotationDisplayE2EHarness: XCTestCase {
    var app: XCUIApplication! { get set }
    var secondFixturePath: String? { get set }
}

final class AnnotationDisplayPersistenceE2ETests: XCTestCase, AnnotationDisplayE2EHarness {
    var app: XCUIApplication!
    var secondFixturePath: String?
    private let seedA = Seed.projectA

    override func setUpWithError() throws { try harnessSetUp() }
    override func tearDownWithError() throws { harnessTearDown() }

    func testCollapsedCommentPersistsAcrossColdRelaunchAndRendersCollapsedInDocument() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        XCTAssertEqual(savedRows(), [], "Opening a project must not write annotation display settings")
        assertEditorRendering(visible: seedA.all(), hidden: [], "baseline (all inline, so later 'hidden' reads are observable)")

        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        assertEditorRendering(visible: seedA.all(except: [seedA.comment]), hidden: [seedA.comment], "live, right after choosing Collapsed")
        expectRows(["\(Row.comment)=collapsed"], "Choosing Collapsed must save exactly one row (Comment = collapsed)")
        attachEvidenceScreenshot(app.screenshot(), name: "v1-before-relaunch-comment-collapsed")
        dismissDisplayPopover()

        // ---- Quit and cold-relaunch against the SAME on-disk project ----
        app.terminate()
        launchAndWaitForEditor()

        // (a) the DOCUMENT renders the comment collapsed; that polled result is reused below, never re-read.
        let documentShowsCollapsed = assertEditorRendering(
            visible: seedA.all(except: [seedA.comment]), hidden: [seedA.comment], "after cold relaunch (document body)"
        )
        attachEvidenceScreenshot(app.screenshot(), name: "v1-after-relaunch-document")

        // (b) separately, the popover says Collapsed for Comment and Inline for the others
        openDisplayPopover()
        attachEvidenceScreenshot(app.screenshot(), name: "v1-after-relaunch-popover") // before any assertion that can abort
        let commentSelection = selection(ofPickerWithID: ControlID.comment)
        XCTAssertEqual(commentSelection, "Collapsed", "After relaunch the popover must show Comment = Collapsed")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.task), "Inline", "Task was never changed: still Inline")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.reference), "Inline", "Reference was never changed: still Inline")
        assertPopoverLayout()

        // (c) document and popover agree
        XCTAssertEqual(documentShowsCollapsed, commentSelection == "Collapsed", "The document and the popover (\(commentSelection)) must agree")
        expectRows(["\(Row.comment)=collapsed"], "Only the user's own change may be stored")
    }

    /// The collapsed marker on its own, so a wrong AX-mapping assumption fails only this method: with
    /// Comment saved as collapsed, the document must expose a non-StaticText node carrying its text.
    func testCollapsedCommentExposesAMarkerNodeInTheDocument() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        FixtureDatabase.write(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "INSERT OR REPLACE INTO settings (\"key\", \"value\") VALUES ('\(Row.comment)', 'collapsed');"
        )
        launchAndWaitForEditor()
        assertEditorRendering(visible: [seedA.paragraph], hidden: [], "editor populated before the marker check")
        var lastNodes: [AXNode] = []
        let found = waitUntil(timeout: 30, pollInterval: 0.5) {
            lastNodes = self.editorNodes() ?? []
            return self.hasCollapsedMarker(for: self.seedA.comment, in: lastNodes)
        }
        attachEditorTree(lastNodes, "marker check (Comment saved as collapsed)")
        XCTAssertTrue(found, "A collapsed comment must expose a non-text marker node carrying its text; see the tree attachment")
    }

    func testPanelOnlyAndHideCompletedPersistAcrossColdRelaunch() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        assertEditorRendering(visible: seedA.all(), hidden: [], "baseline (all annotations inline)")

        // Comment is saved as Collapsed first: Panel Only greys the per-type pickers out and must
        // neither change that saved mode nor stop the pickers from showing it.
        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        setCheckbox(withID: ControlID.hideCompleted, to: true)
        setCheckbox(withID: ControlID.panelOnly, to: true)
        let panelOnlyRows = ["\(Row.comment)=collapsed", "\(Row.hideCompleted)=true", "\(Row.panelOnly)=true"]
        expectRows(panelOnlyRows, "The Comment mode and both checkboxes must be saved")
        assertEditorRendering(visible: [seedA.heading, seedA.paragraph], hidden: seedA.annotations, "live, Panel Only on")
        dismissDisplayPopover()

        app.terminate()
        launchAndWaitForEditor()

        assertEditorRendering(visible: [seedA.heading, seedA.paragraph], hidden: seedA.annotations, "after cold relaunch (Panel Only on)")
        openDisplayPopover()
        attachEvidenceScreenshot(app.screenshot(), name: "v2-after-relaunch-popover-both-ticked")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.panelOnly)), "Panel Only must still be ticked after relaunch")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.hideCompleted)), "Hide Completed must still be ticked after relaunch")
        XCTAssertEqual(
            selection(ofPickerWithID: ControlID.comment), "Collapsed", "The greyed-out Comment picker must still show the saved Collapsed"
        )
        assertPopoverLayout()

        // Panel Only off exposes what is still hidden without it: the completed task (Hide Completed
        // survived the relaunch) and the collapsed comment. Toggling must not change any stored mode.
        setCheckbox(withID: ControlID.panelOnly, to: false)
        assertEditorRendering(
            visible: [seedA.paragraph, seedA.task, seedA.reference], hidden: [seedA.doneTask, seedA.comment],
            "after relaunch with Panel Only switched off (Hide Completed and the collapsed comment still hiding)"
        )
        expectRows(["\(Row.comment)=collapsed", "\(Row.hideCompleted)=true", "\(Row.panelOnly)=false"], "Toggling Panel Only must not change a mode")
        attachEvidenceScreenshot(app.screenshot(), name: "v2-panel-only-off-hide-completed-still-on")
    }

    func testSwitchingToAnotherProjectShowsItsOwnSettingsNotThePreviousProjects() throws {
        let pathA = TestFixtureHelper.fixturePath
        let seedB = Seed.projectB
        FixtureDatabase.seedMarkdown(fixturePath: pathA, markdown: seedA.markdown)
        let pathB = try makeSecondFixture(seededWith: seedB)

        launchAndWaitForEditor()
        assertEditorRendering(visible: seedA.all(), hidden: [], "project A baseline")

        // Change project A: Comment collapsed + Hide Completed on.
        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        setCheckbox(withID: ControlID.hideCompleted, to: true)
        let expectedARows = ["\(Row.comment)=collapsed", "\(Row.hideCompleted)=true"]
        expectRows(expectedARows, at: pathA, "Project A must store its two changes")
        dismissDisplayPopover()

        // Switch to project B in-session (the real Finder-open route the project-switch suites use).
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: pathB))
        XCTAssertTrue(
            waitUntil(timeout: 20) { self.blockCount(at: pathB) > 0 },
            "Switching to project B must have parsed its content into blocks"
        )
        // B's own texts are on screen, everything inline, its completed task visible (Hide
        // Completed off), and none of A's -- not A's collapsed comment or hidden completed task.
        assertEditorRendering(visible: seedB.all(), hidden: [seedA.comment, seedA.paragraph], "after switching to project B (everything inline)")
        openDisplayPopover()
        for pickerID in [ControlID.task, ControlID.comment, ControlID.reference] {
            XCTAssertEqual(selection(ofPickerWithID: pickerID), "Inline", "Project B must show \(pickerID) = Inline, not project A's setting")
        }
        XCTAssertFalse(isChecked(checkbox(withID: ControlID.panelOnly)), "Project B: Panel Only must be off")
        XCTAssertFalse(isChecked(checkbox(withID: ControlID.hideCompleted)), "Project B: Hide Completed must be off, not A's")
        attachEvidenceScreenshot(app.screenshot(), name: "v3-project-b-own-defaults")
        dismissDisplayPopover()
        expectRows([], at: pathB, "Project B never changed anything: no annotation rows")
        expectRows(expectedARows, at: pathA, "Project A's stored rows must be untouched by the switch")

        // Back to A: its own settings return from its own database.
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: pathA))
        assertEditorRendering(
            visible: [seedA.paragraph, seedA.task, seedA.reference], hidden: [seedA.comment, seedA.doneTask],
            "after switching back to project A (comment collapsed, completed task hidden)"
        )
        openDisplayPopover()
        XCTAssertEqual(selection(ofPickerWithID: ControlID.comment), "Collapsed", "Back in A: Comment = Collapsed again")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.hideCompleted)), "Back in A: Hide Completed ticked again")
        attachEvidenceScreenshot(app.screenshot(), name: "v3-back-in-project-a")
    }

    /// The default only exists for the launch that set it (the app wipes the test defaults domain at every launch), so it is
    /// observed by opening a second project in the SAME session, through the Finder-open route V4 uses. A's own values are set
    /// back to Inline / unticked AFTER Set as Default and BEFORE B opens: B reading Collapsed / ticked / ticked is then the
    /// stored default, never a carry-over of what the window last showed.
    func testSetAsDefaultAppliesToAProjectOpenedLaterInTheSameSession() throws {
        let pathA = TestFixtureHelper.fixturePath
        let seedB = Seed.projectB
        FixtureDatabase.seedMarkdown(fixturePath: pathA, markdown: seedA.markdown)
        let pathB = try makeSecondFixture(seededWith: seedB)
        launchAndWaitForEditor()
        assertEditorRendering(visible: seedA.all(), hidden: [], "project A baseline")

        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        setCheckbox(withID: ControlID.panelOnly, to: true)
        setCheckbox(withID: ControlID.hideCompleted, to: true)
        expectSetAsDefault(enabled: true, shot: "v5-popover-before-set-as-default", "Outside Focus Mode the button must be enabled")?.click()
        // The button relabels itself "Saved as default" for ~3s (its identifier switches); nothing below touches it meanwhile.
        expectSavedAsDefaultConfirmation(shot: "v5-confirmation-in-popover")
        let ownRows = ["\(Row.comment)=collapsed", "\(Row.hideCompleted)=true", "\(Row.panelOnly)=true"]
        expectRows(ownRows, at: pathA, "Project A must hold exactly the three rows its own clicks wrote -- Set as Default writes none of its own")

        // A's own values back to Inline / unticked BEFORE B opens (Panel Only first: it greys out the per-type pickers).
        setCheckbox(withID: ControlID.panelOnly, to: false)
        chooseOption("Inline", inPickerWithID: ControlID.comment)
        setCheckbox(withID: ControlID.hideCompleted, to: false)
        expectRows(
            ["\(Row.comment)=inline", "\(Row.hideCompleted)=false", "\(Row.panelOnly)=false"], at: pathA,
            "Project A's own rows must now say Inline / unticked: only the stored default still says Collapsed / ticked"
        )
        dismissDisplayPopover()

        // Project B has saved nothing: it opens on the default, in the document and in the popover.
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: pathB))
        XCTAssertTrue(waitUntil(timeout: 20) { self.blockCount(at: pathB) > 0 }, "Switching to project B must have parsed its content into blocks")
        assertEditorRendering(
            visible: [seedB.heading, seedB.paragraph], hidden: seedB.annotations,
            "project B opened on the default (Panel Only hides every annotation)", shot: "v5-project-b-document"
        )
        openDisplayPopover()
        attachEvidenceScreenshot(app.screenshot(), name: "v5-project-b-inherits-default") // before any assertion that can abort
        XCTAssertEqual(selection(ofPickerWithID: ControlID.comment), "Collapsed", "Project B must inherit Comment = Collapsed")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.task), "Inline", "Task was never set as a default: Inline")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.reference), "Inline", "Reference was never set as a default: Inline")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.panelOnly)), "Project B must inherit Panel Only ticked")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.hideCompleted)), "Project B must inherit Hide Completed ticked")
        expectRows([], at: pathB, "Project B inherited the default without saving anything of its own")
    }

    // MARK: - Set as Default under Focus Mode (one method per Inline Annotations setting; each: own launch, one Focus entry)

    /// Collapse forces all three types Collapsed. The user's own modes are NOT all Collapsed (Comment only), so the override
    /// really changes what the popover shows and the button must be disabled, with its reason on screen.
    func testSetAsDefaultIsDisabledUnderCollapseWhenTheUsersModesAreNotAllCollapsed() throws {
        openPopoverInFocusMode(inline: "Collapse", tag: "v6-collapse", ownRows: ["\(Row.comment)=collapsed"]) {
            self.chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        }
        let armed = waitUntil(timeout: 20) { self.popupModes() == ["Collapsed", "Collapsed", "Collapsed"] }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-collapse-popover")
        XCTAssertTrue(armed, "Collapse must be armed: all three popups read Collapsed; they read \(popupModes())")
        expectSetAsDefault(enabled: false, shot: "v6-collapse-button-disabled", "Set as Default must be disabled under Collapse")
        dismissDisplayPopover()
        exitFocusMode()
        expectRows(["\(Row.comment)=collapsed"], "Nothing in this test may add a row to project A")
    }

    /// Hide forces Panel Only on. The user's own Panel Only is off, so the override changes what the popover shows: the button
    /// must be disabled, with its reason on screen.
    func testSetAsDefaultIsDisabledUnderHideWhenTheUsersPanelOnlyIsOff() throws {
        openPopoverInFocusMode(inline: "Hide", tag: "v6-hide", ownRows: ["\(Row.comment)=collapsed"]) {
            self.chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        }
        let armed = waitUntil(timeout: 20) { self.isChecked(self.checkbox(withID: ControlID.panelOnly)) }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-hide-popover")
        XCTAssertTrue(armed, "Hide must be armed: Panel Only reads ticked though the user never ticked it")
        expectSetAsDefault(enabled: false, shot: "v6-hide-button-disabled", "Set as Default must be disabled under Hide")
        dismissDisplayPopover()
        exitFocusMode()
        expectRows(["\(Row.comment)=collapsed"], "Nothing in this test may add a row to project A")
    }

    /// Leave As Is arms nothing: the popover shows the user's own values, the button is enabled (no reason caption) and works.
    func testSetAsDefaultIsEnabledAndSavesUnderLeaveAsIs() throws {
        openPopoverInFocusMode(inline: "Leave As Is", tag: "v6-leave-as-is", ownRows: ["\(Row.comment)=collapsed"]) {
            self.chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        }
        let ownValues = waitUntil(timeout: 20) { self.popupModes() == ["Inline", "Collapsed", "Inline"] }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-leave-as-is-popover")
        XCTAssertTrue(ownValues, "Leave As Is arms nothing: the popups must show the user's own modes; they read \(popupModes())")
        XCTAssertFalse(isChecked(checkbox(withID: ControlID.panelOnly)), "Leave As Is arms nothing: Panel Only must read unticked")
        expectSetAsDefault(enabled: true, shot: "v6-leave-as-is-button-enabled", "Set as Default must be enabled under Leave As Is")?.click()
        expectSavedAsDefaultConfirmation(shot: "v6-leave-as-is-confirmation")
        dismissDisplayPopover()
        exitFocusMode()
        expectRows(["\(Row.comment)=collapsed"], "Nothing in this test may add a row to project A")
    }

    /// The already-applied case: Hide arms Panel Only, but the user's own Panel Only is already ticked, so the override changes
    /// nothing visible and the button stays enabled (no reason caption).
    func testSetAsDefaultStaysEnabledWhenHideChangesNothingBecausePanelOnlyIsAlreadyOn() throws {
        openPopoverInFocusMode(inline: "Hide", tag: "v6-hide-already-on", ownRows: ["\(Row.panelOnly)=true"]) {
            self.setCheckbox(withID: ControlID.panelOnly, to: true)
        }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-hide-already-on-popover")
        XCTAssertTrue(isChecked(checkbox(withID: ControlID.panelOnly)), "Panel Only reads ticked (the user's own choice, and Hide's)")
        expectSetAsDefault(enabled: true, shot: "v6-hide-already-on-button", "Hide changes nothing here: the button must stay enabled")?.click()
        expectSavedAsDefaultConfirmation(shot: "v6-hide-already-on-confirmation")
        dismissDisplayPopover()
        exitFocusMode()
        expectRows(["\(Row.panelOnly)=true"], "Nothing in this test may add a row to project A")
    }

    /// The popover is left OPEN while Focus Mode starts and ends: the button must re-evaluate in the SAME popover, disabled once
    /// Focus Mode changes what it shows (Comment Collapsed only, so Collapse alters Task and Reference) and enabled again after.
    /// Unproven in this harness: whether AppKit keeps a transient popover open while the window enters native full screen. If it
    /// closes, the method FAILS at that step, naming it; it never reopens the popover (that would prove only the initial state).
    func testSetAsDefaultReEvaluatesLiveInAnOpenPopoverWhenFocusModeStartsAndEnds() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        configureFocusKeepingTheAnnotationsPanel(inline: "Collapse")
        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        expectRows(["\(Row.comment)=collapsed"], "Project A's single row, from its own Comment click")
        XCTAssertEqual(popupModes(), ["Inline", "Collapsed", "Inline"], "Focus Mode off: the popover shows the user's own modes")
        expectSetAsDefault(enabled: true, shot: "v6-live-focus-mode-off", "Focus Mode off: the button must be enabled")

        enterFocusMode("v6-live-shortcut-pressed-popover-open") // Shift-Cmd-F with the popover still open
        let stillOpen = awaitControl(ControlID.comment, kind: .picker, timeout: 5) != nil
        XCTAssertTrue(stillOpen, "The popover closed when Focus Mode began: live re-evaluation is not observable in this harness")
        let armed = waitUntil(timeout: 20) { self.popupModes() == ["Collapsed", "Collapsed", "Collapsed"] }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-live-popover-in-focus-mode")
        XCTAssertTrue(armed, "The SAME open popover must now read Collapsed for all three types; the popups read \(popupModes())")
        expectSetAsDefault(enabled: false, shot: "v6-live-button-disabled", "The open popover's button must have become disabled")

        exitFocusMode(withShortcut: true) // Esc would close the popover first, so the same shortcut toggles Focus Mode off
        let restored = waitUntil(timeout: 20) { self.popupModes() == ["Inline", "Collapsed", "Inline"] }
        attachEvidenceScreenshot(app.screenshot(), name: "v6-live-popover-focus-mode-ended")
        XCTAssertTrue(restored, "The SAME open popover must show the user's own modes again; the popups read \(popupModes())")
        expectSetAsDefault(enabled: true, shot: "v6-live-button-enabled-again", "The open popover's button must be enabled again")
        dismissDisplayPopover()
        expectRows(["\(Row.comment)=collapsed"], "Nothing in this test may add a row to project A")
    }

    /// Regression guard only: it passes on the unchanged app too (Export was the default tab, and is again), so it is
    /// not evidence for this change -- it protects File > Export Preferences... from breaking. The router's cold-launch
    /// request path is exercised by the method below.
    func testExportPreferencesMenuItemOpensExportTabOnColdLaunch() throws {
        launchAndWaitForEditor()
        XCTAssertFalse(settingsWindow.exists, "Precondition: Settings has never been opened in this launch")
        chooseExportPreferencesFromFileMenu()
        _ = settingsWindow.waitForExistence(timeout: 10)
        attachEvidenceScreenshot(app.screenshot(), name: "v7-export-preferences-cold-launch") // before any assertion that can abort
        XCTAssertTrue(settingsWindow.exists, "Settings window should appear")
        expectSettingsTitle("Export", "File > Export Preferences... on a cold launch must open the Export tab")
        XCTAssertTrue(exportPaneToggle.waitForExistence(timeout: 10), "The Export pane content must be showing")
        // The General pane was removed: the tab bar is populated (Export is in it) and has no General button.
        XCTAssertTrue(settingsTabButton("Export").exists, "The Settings tab bar must list an Export tab")
        XCTAssertFalse(settingsTabButton("General").exists, "Settings must have no General tab")
    }

    /// Guards the router's request clearing. Export Preferences... requests Export and the request is consumed; the user then
    /// moves to Appearance and closes Settings. A stale request would redirect the next plain Cmd-, back to Export, so the
    /// reopened window must read Appearance and show no Export content. That Appearance itself is what shows is standard
    /// SwiftUI/macOS behaviour (the Settings scene keeps its content view alive, so the selected tab is retained within a
    /// session); it is deliberately NOT asserted against. PreferencesTabRouterTests covers the request clearing at unit level.
    func testSpentExportPreferencesRequestDoesNotRedirectALaterOpen() throws {
        launchAndWaitForEditor()
        chooseExportPreferencesFromFileMenu()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window should appear")
        expectSettingsTitle("Export", "Export Preferences... must open on Export first")
        selectSettingsTab("Appearance")
        expectSettingsTitle("Appearance", "Clicking the Appearance tab must show Appearance")
        closeSettingsWindow()

        openSettingsWithShortcut()
        attachEvidenceScreenshot(app.screenshot(), name: "v8-later-command-comma")
        expectSettingsTitle("Appearance", "A later Cmd-, must reopen on the tab Settings was left on; only a stale Export request would show Export")
        XCTAssertFalse(exportPaneToggle.exists, "The Export pane must not be showing: the spent Export request must not be re-applied")
    }

    func testFocusModeRoundTripDoesNotPersistItsForcedCollapse() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        assertEditorRendering(visible: seedA.all(), hidden: [], "baseline (all annotations inline)")

        // The user's choice: Comment collapsed. Task and Reference stay untouched (no row): had
        // Focus Mode's forced collapse reached the database they would read Collapsed after relaunch.
        openDisplayPopover()
        chooseOption("Collapsed", inPickerWithID: ControlID.comment)
        expectRows(["\(Row.comment)=collapsed"], "Exactly the user's Comment = collapsed row must be stored")
        dismissDisplayPopover()
        // Settings > Focus > "Inline Annotations" must be Collapse (the task's stated precondition).
        ensureFocusInlineAnnotationsIsCollapse()

        // ---- Enter Focus Mode: every type is forced collapsed IN MEMORY ----
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.groups["status-bar"].waitForDisappearance(timeout: 10), "Status bar should disappear in Focus Mode")
        waitForFullScreen(true)
        // Only what V7 needs: every annotation text is gone. Nothing is asserted VISIBLE: Focus Mode dims
        // non-cursor blocks (`.ff-dimmed`, opacity 0.3) and whether WebKit keeps dimmed blocks in the AX
        // tree is unverified; assertEditorRendering's non-empty-tree guard covers "hidden" on an empty tree.
        assertEditorRendering(visible: [], hidden: seedA.annotations, "inside Focus Mode (Inline Annotations = Collapse forces every type collapsed)")
        attachEvidenceScreenshot(app.screenshot(), name: "v7-inside-focus-mode-forced-collapse")
        expectRows(["\(Row.comment)=collapsed"], "Focus Mode's forced collapse must never be written to the project")

        // ---- Leave Focus Mode: the user's own values return ----
        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.groups["status-bar"].waitForExistence(timeout: 10), "Esc should leave Focus Mode")
        waitForFullScreen(false)
        assertEditorRendering(visible: seedA.all(except: [seedA.comment]), hidden: [seedA.comment], "after leaving Focus Mode")
        expectRows(["\(Row.comment)=collapsed"], "Leaving Focus Mode must not write anything either")

        // ---- Quit and cold-relaunch: the saved choice, not Focus Mode's forced collapse ----
        app.terminate()
        launchAndWaitForEditor()
        assertEditorRendering(visible: seedA.all(except: [seedA.comment]), hidden: [seedA.comment], "after the Focus Mode relaunch")
        openDisplayPopover()
        XCTAssertEqual(selection(ofPickerWithID: ControlID.comment), "Collapsed", "Comment keeps the user's saved choice")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.task), "Inline", "Task must not inherit Focus Mode's forced collapse")
        XCTAssertEqual(selection(ofPickerWithID: ControlID.reference), "Inline", "Reference must not inherit Focus Mode's forced collapse")
        expectRows(["\(Row.comment)=collapsed"], "Still only the user's one stored row after relaunch")
        attachEvidenceScreenshot(app.screenshot(), name: "v7-after-relaunch-saved-choice")
    }
}

extension AnnotationDisplayPersistenceE2ETests {
    /// Project A launched, Focus Mode's Inline Annotations set to `inline` with the Annotations panel kept, the user's own
    /// change made in the popover (`userChoice`, saved as `ownRows`), then Focus Mode entered and the eye popover opened.
    private func openPopoverInFocusMode(inline: String, tag: String, ownRows: [String], userChoice: () -> Void) {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: seedA.markdown)
        launchAndWaitForEditor()
        configureFocusKeepingTheAnnotationsPanel(inline: inline)
        openDisplayPopover()
        userChoice()
        dismissDisplayPopover()
        expectRows(ownRows, "Project A's rows must be exactly the user's own change")
        enterFocusMode("\(tag)-focus-mode")
        openDisplayPopover()
    }
}

extension AnnotationDisplayE2EHarness {
    // Short in-scope names: the module-level types carry the AnnotationDisplay prefix so nothing can collide.
    typealias Seed = AnnotationDisplaySeed
    typealias Row = AnnotationDisplayRow
    typealias ControlID = AnnotationDisplayControlID
    typealias ControlKind = AnnotationDisplayControlKind
    typealias AXNode = AnnotationDisplayAXNode

    func harnessSetUp() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    /// Leaves full screen BEFORE terminate(); raises its failure only AFTER cleanup (`continueAfterFailure = false`).
    func harnessTearDown() {
        let fullScreenFailure = leaveFullScreenIfNeeded()
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        if let secondFixturePath { try? FileManager.default.removeItem(atPath: secondFixturePath) }
        if let fullScreenFailure { XCTFail(fullScreenFailure) }
    }

    /// Launches with saved window state ignored (`-ApplePersistenceIgnoreState YES`): Cocoa's own restoration can reopen
    /// the window full screen. Local to this harness (launchForTesting keeps `launchArguments`, so they carry through).
    /// UITestHelpers documents that this switch can stop SwiftUI creating ANY window: if none appears, relaunch without
    /// it (a note is attached) and leave `leaveRestoredFullScreen()` as the backstop.
    func launchAndWaitForEditor() {
        let baseArguments = app.launchArguments
        defer { app.launchArguments = baseArguments }
        app.launchArguments = baseArguments + ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        if !app.editorArea.waitForExistence(timeout: 15) {
            add(XCTAttachment(string: "No window appeared with -ApplePersistenceIgnoreState YES; relaunching without it"))
            app.launchArguments = baseArguments
            app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        }
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 15), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 15), "Status bar should show word count (editor JS ready)")
        leaveRestoredFullScreen()
    }

    func makeSecondFixture(seededWith seed: Seed) throws -> String {
        let fm = FileManager.default
        // A sibling of fixture A (same parent directory and naming convention): readable wherever A is.
        let path = URL(fileURLWithPath: TestFixtureHelper.fixturePath).deletingLastPathComponent()
            .appendingPathComponent("ff-test-fixture-\(UUID().uuidString).ff").path
        let source = try XCTUnwrap(Bundle(for: type(of: self)).resourceURL?.appendingPathComponent("Fixtures/test-fixture.ff"), "Fixture missing")
        XCTAssertTrue(fm.fileExists(atPath: source.path), "Test fixture must exist at \(source.path)")
        try? fm.removeItem(atPath: path)
        try fm.copyItem(at: source, to: URL(fileURLWithPath: path))
        secondFixturePath = path
        // seedMarkdown also clears `block`, so the switch parses this content from scratch.
        FixtureDatabase.seedMarkdown(fixturePath: path, markdown: seed.markdown)
        return path
    }

    /// The annotation display rows of a project's `settings` table as "key=value", ordered by key.
    func savedRows(at path: String? = nil) -> [String] {
        let raw = FixtureDatabase.read(
            fixturePath: path ?? TestFixtureHelper.fixturePath,
            sql: "SELECT \"key\" || '=' || \"value\" FROM settings WHERE \"key\" LIKE 'annotation%' ORDER BY \"key\";"
        )
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Waits for a project's annotation display rows to equal `expected` (the CLI read is a separate process).
    func expectRows(_ expected: [String], at path: String? = nil, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil { self.savedRows(at: path) == expected }, "\(why); got \(savedRows(at: path))", file: file, line: line)
    }

    func blockCount(at path: String) -> Int {
        let raw = FixtureDatabase.read(fixturePath: path, sql: "SELECT count(*) FROM block;")
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Polls `condition` until it holds or `timeout` passes. Pure polling, no fixed sleep.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.25, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return condition()
    }
}

extension AnnotationDisplayE2EHarness {
    /// The first of `elements` that exists within `timeout`, else nil.
    func firstExisting(_ elements: [XCUIElement], timeout: TimeInterval = 0) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let hit = elements.first(where: { $0.exists }) { return hit }
            if timeout > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25)) }
        } while Date() < deadline
        return nil
    }

    /// A control by identifier. SwiftUI can stamp one identifier on several AX elements, so this
    /// takes the FIRST match of a typed query, falling back to any type only if that is absent.
    func awaitControl(_ identifier: String, kind: ControlKind, timeout: TimeInterval = 10) -> XCUIElement? {
        let expected: [XCUIElementQuery]
        switch kind {
        case .picker: expected = [app.popUpButtons, app.menuButtons, app.buttons]
        case .checkbox: expected = [app.checkBoxes, app.switches, app.buttons]
        case .button: expected = [app.buttons]
        }
        let candidates = expected.map { $0.matching(identifier: identifier).firstMatch }
            + [app.descendants(matching: .any).matching(identifier: identifier).firstMatch]
        return firstExisting(candidates, timeout: timeout)
    }

    func checkbox(withID identifier: String) -> XCUIElement {
        guard let element = awaitControl(identifier, kind: .checkbox) else {
            XCTFail("Checkbox \"\(identifier)\" not found (is the display popover open?)")
            return app.checkBoxes.matching(identifier: identifier).firstMatch
        }
        return element
    }

    func isChecked(_ element: XCUIElement) -> Bool {
        if let text = element.value as? String { return text == "1" || text == "true" }
        if let number = element.value as? NSNumber { return number.boolValue }
        return false
    }

    func setCheckbox(withID identifier: String, to desired: Bool) {
        let box = checkbox(withID: identifier)
        if isChecked(box) != desired { box.click() }
        XCTAssertTrue(
            waitUntil { self.isChecked(box) == desired },
            "Checkbox \"\(identifier)\" should read \(desired ? "ticked" : "unticked") after the click"
        )
    }

    /// The selected option's title of a pop-up picker (its value; the title as a fallback).
    func selection(ofPickerWithID identifier: String) -> String {
        guard let picker = awaitControl(identifier, kind: .picker) else {
            XCTFail("Picker \"\(identifier)\" not found (is its popover or Settings tab open?)")
            return ""
        }
        if let value = picker.value as? String, !value.isEmpty { return value }
        return picker.title
    }

    /// Opens a pop-up picker, clicks the option titled `optionTitle`, and waits for the picker to
    /// show it.
    func chooseOption(
        _ optionTitle: String, inPickerWithID identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let picker = awaitControl(identifier, kind: .picker) else {
            XCTFail("Picker \"\(identifier)\" not found", file: file, line: line)
            return
        }
        picker.click()
        let byTitle = NSPredicate(format: "title == %@", optionTitle)
        let item = firstExisting(
            [picker.menuItems.matching(byTitle).firstMatch, app.menuItems.matching(byTitle).firstMatch], timeout: 10
        )
        guard let item else {
            XCTFail("Picker \"\(identifier)\" opened no menu item titled \"\(optionTitle)\"", file: file, line: line)
            return
        }
        item.click()
        XCTAssertTrue(
            waitUntil { self.selection(ofPickerWithID: identifier) == optionTitle },
            "Picker \"\(identifier)\" should show \"\(optionTitle)\" after choosing it", file: file, line: line
        )
    }

    /// The panel is visible by default but its toggle key is unconditional: check first.
    func ensureAnnotationsPanelVisible() {
        let eye = app.buttons.matching(identifier: ControlID.eyeButton).firstMatch
        if eye.waitForExistence(timeout: 5) { return }
        app.activateAndWaitForForeground()
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(eye.waitForExistence(timeout: 10), "Annotations panel should show its display-mode (eye) button")
    }

    func openDisplayPopover() {
        ensureAnnotationsPanelVisible()
        app.buttons.matching(identifier: ControlID.eyeButton).firstMatch.click()
        XCTAssertNotNil(
            awaitControl(ControlID.comment, kind: .picker, timeout: 10), "The display-mode popover should open with its pickers"
        )
        // Wait out the open animation (a still taken mid-animation is scaled and see-through): the popups'
        // frames must read the same on two consecutive polls. Bounded; never fails on its own.
        var previous: [CGRect] = []
        waitUntil(timeout: 3) {
            let now = popoverPopups().map(\.frame)
            defer { previous = now }
            return now.count == 3 && now == previous
        }
    }

    /// The three per-type popup buttons (task, comment, reference) of the OPEN popover.
    func popoverPopups() -> [XCUIElement] {
        [ControlID.task, ControlID.comment, ControlID.reference].compactMap { awaitControl($0, kind: .picker, timeout: 0) }
    }

    /// Dismisses the transient popover by clicking empty editor margin (not Escape: the escape ladder listens too).
    func dismissDisplayPopover() {
        app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.9)).click()
        XCTAssertTrue(
            waitUntil { self.awaitControl(ControlID.comment, kind: .picker, timeout: 0) == nil },
            "The display-mode popover should close after clicking outside it"
        )
    }

    func chooseExportPreferencesFromFileMenu() {
        app.activateAndWaitForForeground()
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "File menu should exist")
        fileMenu.click()
        // Titled "Export Preferences..." -- matched by prefix so the ellipsis form can't matter.
        app.menuItem(titleStartingWith: "Export Preferences").click()
    }
}

extension AnnotationDisplayE2EHarness {
    /// By the Settings scene's stable identifier -- its TITLE is the selected tab's name.
    var settingsWindow: XCUIElement {
        app.windows["com_apple_SwiftUI_Settings_window"]
    }

    /// A tab button in the Settings toolbar (AX exposes its text as the title, so match either).
    func settingsTabButton(_ name: String) -> XCUIElement {
        settingsWindow.toolbars.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", name, name)).firstMatch
    }

    func selectSettingsTab(_ name: String) {
        let tab = settingsTabButton(name)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings should have a \(name) tab")
        tab.click()
    }

    /// The Export pane's "Use custom export template" toggle: it existing proves that pane's content is showing.
    var exportPaneToggle: XCUIElement {
        settingsWindow.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Use custom export template")).firstMatch
    }

    /// Waits for the Settings window title (the selected tab's name) to read `title`.
    func expectSettingsTitle(_ title: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil { self.settingsWindow.title == title },
            "\(why); the Settings window title was \"\(settingsWindow.title)\"", file: file, line: line
        )
    }

    func openSettingsWithShortcut() {
        app.activateAndWaitForForeground()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window should appear")
    }

    /// Via the close button -- Cmd-W is rebound app-wide to Close Project.
    func closeSettingsWindow() {
        let close = settingsWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Settings window should have a close button")
        close.click()
        XCTAssertTrue(settingsWindow.waitForDisappearance(timeout: 10), "Settings window should close")
    }
}
