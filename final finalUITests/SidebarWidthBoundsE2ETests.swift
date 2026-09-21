//
//  SidebarWidthBoundsE2ETests.swift
//  final finalUITests
//
//  Permanent e2e coverage for the Outline sidebar's `HSplitView` behaviour (plan
//  outline-hsplitview). The behaviour under test is ONLY reachable with a real window and a real
//  divider drag, so neither the unit tier (`OutlineSidebarWidthTests` covers the pane's width
//  constants and clamp) nor a web test can stand in for it:
//
//    - Dragging the Outline divider narrows the content inside the window; the window must not grow.
//    - The divider stops at the 250pt floor: drag-to-collapse is gone by the user's decision
//      (hiding is cmd-[, the View menu, or the toolbar toggle).
//    - A launch with nothing saved opens at the 300pt default (the app positions the divider
//      itself, because `HSplitView` ignores the pane's `idealWidth`).
//    - Show/hide animates the divider -- a slide through intermediate widths, not a pop -- and the
//      width comes back unchanged.
//
//  Cross-LAUNCH width persistence is NOT covered here, and cannot be: it is AppKit's
//  `NSSplitView.autosaveName` (`SplitViewAutosaveNaming.stabilize(for:)`), which returns early
//  under `TestMode.isTesting`. Verified by hand -- see the note where the relaunch test used to be.
//
//  Order independence. Every test launches with `FF_UI_TESTING_WINDOW_WIDTH = 1000` (set BEFORE
//  `launchForTesting(fixturePath:)`, asserted once the window exists), which pins the window width
//  the drag deltas are relative to. The pane's own starting width is deterministic too: the hermetic
//  UI-test defaults wipe (total again) clears any autosaved divider key before layout, so the app
//  takes its "nothing saved" path and positions the divider at the 300pt default -- asserted
//  outright in `testDraggingDividerPastItsCapDoesNotGrowTheWindow`. From there, a method that needs
//  the cap starts there already, and the one method that needs ROOM to grow normalises structurally
//  by dragging to the 250pt floor first. Every method begins by showing the sidebar and waiting for
//  it to settle at or above the floor, and ends the same way (`tearDownWithError`), so a method that
//  fails after its own cmd-[ cannot hand a hidden sidebar to the next one. XCTest's alphabetical
//  order does not matter.
//
//  Structure. The class body holds only the constants, `setUp`/`tearDown` and the four `test...`
//  methods; the launch/toggle helpers and the geometry helpers live in same-file extensions below
//  it (which still see the class's `private` members), so the class stays under SwiftLint's
//  `type_body_length` limit.
//
//  The `[SidebarWidthE2E]` emitters are plain test-side output (`print`, the same channel
//  `TestFixtureHelper` uses) recording the measured column/window/editor/annotations widths at
//  each stage, so a VM run can be read rather than only believed.
//

import XCTest

final class SidebarWidthBoundsE2ETests: XCTestCase {

    // Local copies of `OutlineSidebarWidth`'s bounds -- the UI test target cannot `@testable
    // import` the app.
    private static let minWidth: CGFloat = 250
    private static let idealWidth: CGFloat = 300
    private static let maxWidth: CGFloat = 400
    private static let launchWindowWidth: CGFloat = 1000

    /// Points added when dragging the divider. +300 reaches the 400pt cap from any configured
    /// start in [250, 400]; -300 returns to the 250pt floor from that cap.
    private static let capDragDelta: CGFloat = 300
    private static let floorDragDelta: CGFloat = -300

    private static let outlineToggleIdentifier = "toolbar-outline-toggle"

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // `app` is assigned BEFORE the fixture setup so a throw from `setupFixture` cannot leave
        // `tearDownWithError` dereferencing a nil implicitly-unwrapped optional.
        app = XCUIApplication.targetApp()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        // Re-show the sidebar before terminating (so a method that failed after its own cmd-[
        // cannot hand hidden state to the next method -- see this file's header), but ASSERT only
        // after terminate/cleanup: otherwise a crash inside the test produces a second,
        // misleading failure here.
        var settledVisible = true
        if app.state == .runningForeground {
            toggleOutlineIfHidden()
            settledVisible = waitForColumnWidth(atLeast: Self.minWidth)
        }
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        XCTAssertTrue(
            settledVisible,
            "tearDown: the Outline sidebar is hidden or collapsed -- measured "
                + "\(columnWidthDescription()), expected >= \(Self.minWidth)pt. A leaked hidden "
                + "sidebar would poison every later method in this class."
        )
    }

    // MARK: - Tests

    /// Asserts the launch width, then normalises its own start structurally: it drags to the 250pt
    /// floor first (the divider cannot pass its floor, so a -300pt drag lands there from ANY start
    /// -- the same normalisation `testDraggingDividerToItsMinimumStopsAtTheFloor` proves), and only
    /// then runs the cap drag it actually measures -- so the before/after comparison never depends
    /// on the launch position. The launch ASSERTION is the one part that does depend on the
    /// hermetic UI-test defaults wipe: that wipe clears any autosaved divider key, which is what
    /// puts the app on its "nothing saved" path and positions the divider at the 300pt default.
    /// `[SidebarWidthE2E] launch ...` still records the measured values alongside it.
    func testDraggingDividerPastItsCapDoesNotGrowTheWindow() {
        launch(width: Self.launchWindowWidth)

        emitMeasurement("launch")
        // REQUIRED 2: a launch with no autosaved divider position opens at the shared default,
        // because the app positions the divider itself (`HSplitView` ignores the pane's
        // `idealWidth`, which used to leave the pane at its 400pt maximum). Waits rather than
        // asserting instantly: the positioning lands on the pane's first layout, which can be a
        // moment after the sidebar is first measurable.
        //
        // The settle result is read FIRST and asserted only after the launch evidence is attached:
        // `continueAfterFailure = false` ends this method at the first failure, so evidence taken
        // after the assertion would never exist in exactly the run that needs it. In that failing
        // case the settle polls its whole 15s, well past the app's launch-positioning poll (up to
        // ~3s), so the app's final `[OutlineLaunchWidth]` line is in the diagnostic log by then.
        // (A passing run may return sooner and capture an earlier line; the evidence exists to
        // explain a failure.)
        let launchSettled = settleColumnWidth(Self.idealWidth)
        attachOutlineLaunchEvidence()
        XCTAssertTrue(
            launchSettled,
            "A launch with no autosaved divider position should open the Outline at the shared "
                + "default of \(Self.idealWidth)pt -- `OutlineSidebarPane` positions the divider via "
                + "`SplitViewAutosaveNaming.setTopLevelDividerPosition` because `HSplitView` ignores "
                + "the pane's `idealWidth`. Measured \(columnWidthDescription())."
        )

        // Deterministic start (see this method's doc comment): drag to the floor and assert it.
        dragDivider(by: Self.floorDragDelta)
        XCTAssertTrue(
            settleColumnWidth(Self.minWidth),
            "Normalisation precondition: dragging \(Self.floorDragDelta)pt left should land on the "
                + "\(Self.minWidth)pt floor; measured \(columnWidthDescription())"
        )
        let baselineColumn = measuredColumnWidth()
        XCTAssertEqual(
            baselineColumn, Self.minWidth, accuracy: 10,
            "After the floor normalisation the baseline column should BE the \(Self.minWidth)pt "
                + "floor, which is what makes the shrink expectation below start-independent; "
                + "measured \(columnWidthDescription())"
        )
        emitMeasurement("floor")

        let window = app.windows.firstMatch
        let baselineWindowWidth = window.frame.width
        let baselineEditorWidth = editorAreaWidth()
        let baselineAnnotationsWidth = annotationsPanelWidth()
        attachEvidenceScreenshot(app.screenshot(), name: "outline-divider-before-drag")

        dragDivider(by: Self.capDragDelta)
        XCTAssertTrue(
            settleColumnWidth(Self.maxWidth),
            "The Outline column should settle at its \(Self.maxWidth)pt cap after dragging the "
                + "divider \(Self.capDragDelta)pt right; measured \(columnWidthDescription())"
        )
        emitMeasurement("capped")
        let cappedWindowWidth = window.frame.width
        attachEvidenceScreenshot(app.screenshot(), name: "outline-divider-at-cap")

        let windowGrowth = cappedWindowWidth - baselineWindowWidth
        XCTAssertLessThanOrEqual(
            windowGrowth, 2,
            "Dragging the Outline divider must narrow the editor, never grow the window. "
                + "Window width went \(baselineWindowWidth) -> \(cappedWindowWidth)pt "
                + "(delta \(windowGrowth)pt)."
        )

        // The real claim, and the one this assertion now makes: the sidebar's gain came from
        // INSIDE the window, not from growing it. The editor alone is the wrong measure for that:
        // measured in the VM, a 250 -> 400pt sidebar gain (+150) left the editor only 86pt
        // narrower, because the Annotations panel ALSO gives width back toward its own 200pt
        // minimum (a live HSplitView re-dividing the remaining space). So:
        //   1. the editor still has to narrow meaningfully (fixed, non-vacuous floor), and
        //   2. the two content panes TOGETHER must give up the sidebar's gain.
        let editorShrink = baselineEditorWidth - editorAreaWidth()
        XCTAssertGreaterThan(
            editorShrink, 50,
            "The editor area should have narrowed by a meaningful amount once the sidebar reached "
                + "its \(Self.maxWidth)pt cap; it went \(baselineEditorWidth) -> "
                + "\(editorAreaWidth())pt (shrank \(editorShrink)pt)."
        )

        // Start-independent by construction: the baseline above is asserted to be the floor, so
        // the sidebar gains exactly maxWidth - minWidth (150pt); 80% leaves room for rounding.
        let expectedContentShrink = (Self.maxWidth - baselineColumn) * 0.8
        if let baselineAnnotationsWidth, let cappedAnnotationsWidth = annotationsPanelWidth() {
            let contentShrink = (baselineEditorWidth + baselineAnnotationsWidth)
                - (editorAreaWidth() + cappedAnnotationsWidth)
            XCTAssertGreaterThanOrEqual(
                contentShrink, expectedContentShrink,
                "The editor and Annotations panes TOGETHER should have given up at least 80% of the "
                    + "\(Self.maxWidth) - \(baselineColumn) = \(Self.maxWidth - baselineColumn)pt the "
                    + "sidebar gained; they gave up \(contentShrink)pt "
                    + "(editor \(baselineEditorWidth) -> \(editorAreaWidth())pt, annotations "
                    + "\(baselineAnnotationsWidth) -> \(cappedAnnotationsWidth)pt)."
            )
        } else {
            // Fallback, as required when the Annotations panel exposes no usable frame (absent from
            // the accessibility tree, or zero-width): this method then asserts only the
            // editor-narrowed threshold above plus the unchanged window delta -- the
            // combined-panes claim is deliberately NOT asserted in that case. Recorded rather than
            // failed, and stated here, so a reduced run is legible in the log instead of silent.
            print(
                "[SidebarWidthE2E] capped combined-shrink assertion SKIPPED: Annotations panel not "
                    + "measurable on both sides (baseline "
                    + "\(annotationsWidthDescription(baselineAnnotationsWidth)), after "
                    + "\(annotationsWidthDescription(annotationsPanelWidth()))); window delta and "
                    + "editor-narrowed threshold still asserted"
            )
        }
    }

    func testDraggingDividerToItsMinimumStopsAtTheFloor() {
        launch(width: Self.launchWindowWidth)

        dragDivider(by: Self.capDragDelta)
        XCTAssertTrue(
            settleColumnWidth(Self.maxWidth),
            "Precondition: the column should first reach its \(Self.maxWidth)pt cap; "
                + "measured \(columnWidthDescription())"
        )
        let cappedEditorWidth = editorAreaWidth()
        attachEvidenceScreenshot(app.screenshot(), name: "outline-divider-at-floor-before")

        dragDivider(by: Self.floorDragDelta)
        XCTAssertTrue(
            settleColumnWidth(Self.minWidth),
            "The divider should stop at the \(Self.minWidth)pt floor. It does NOT collapse the "
                + "sidebar -- hiding is cmd-[, the View menu, or the toolbar toggle. "
                + "Measured \(columnWidthDescription())"
        )
        attachEvidenceScreenshot(app.screenshot(), name: "outline-divider-at-floor")

        // 400 -> 250 is 150pt, so >100 is start-width independent here: the start is asserted to
        // be the cap immediately above.
        let editorGrowth = editorAreaWidth() - cappedEditorWidth
        XCTAssertGreaterThan(
            editorGrowth, 100,
            "The editor area should widen by more than 100pt when the sidebar narrows from its cap "
                + "to its floor; it went \(cappedEditorWidth) -> \(editorAreaWidth())pt"
        )
    }

    func testHidingAndShowingRetainsTheWidth() {
        launch(width: Self.launchWindowWidth)

        dragDivider(by: Self.capDragDelta)
        XCTAssertTrue(
            settleColumnWidth(Self.maxWidth),
            "Precondition: the column should reach its \(Self.maxWidth)pt cap; "
                + "measured \(columnWidthDescription())"
        )
        let cappedEditorWidth = editorAreaWidth()

        // Placement: the toggle belongs at the LEADING edge of the title bar (left of the window
        // title), where the native sidebar chevron it replaced sat -- a user-visible regression
        // once put it in the trailing cluster instead. Compares two screen-space frames, so this
        // is a real position check, not a hierarchy query.
        let toggleFrame = outlineToggleButton().frame
        let titleBarWindowFrame = app.windows.firstMatch.frame
        XCTAssertLessThan(
            toggleFrame.midX, titleBarWindowFrame.midX,
            "The Outline toggle should sit on the LEFT of the title bar (leading edge, left of the "
                + "window title), as the native sidebar chevron did. Its midX was "
                + "\(toggleFrame.midX)pt in a window spanning midX \(titleBarWindowFrame.midX)pt "
                + "(\(titleBarWindowFrame.minX)...\(titleBarWindowFrame.maxX)pt)."
        )

        XCTAssertTrue(
            waitForOutlineToggleLabel("Hide Outline"),
            "The toolbar Outline button should read \"Hide Outline\" while the sidebar is visible; "
                + "read \"\(outlineToggleLabel())\""
        )
        attachEvidenceScreenshot(app.screenshot(), name: "outline-overlay-before-hide")

        app.activateAndWaitForForeground()
        app.typeKey("[", modifierFlags: .command)

        // REQUIRED 4: prove the hide is a SLIDE, not a pop. A pop lands on the end width with
        // nothing in between; a slide passes through intermediate widths. Sampled as a bounded
        // series rather than one read, because AX queries in this VM are slow enough that a single
        // read can easily miss a 250ms transition. Every sample is recorded for the run log.
        let hideSampleStart = editorAreaWidth()
        var hideSamples: [CGFloat] = []
        let hideSampleDeadline = Date(timeIntervalSinceNow: 0.3)
        repeat {
            hideSamples.append(editorAreaWidth())
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        } while Date() < hideSampleDeadline
        let hideSampleEnd = editorAreaWidth()
        let hideSampleLow = min(hideSampleStart, hideSampleEnd)
        let hideSampleHigh = max(hideSampleStart, hideSampleEnd)
        let sampleMargin: CGFloat = 1
        let intermediateSample = hideSamples.first {
            $0 > hideSampleLow + sampleMargin && $0 < hideSampleHigh - sampleMargin
        }
        let recordedSamples = hideSamples.map { String(format: "%.1f", $0) }.joined(separator: ",")
        print(
            "[SidebarWidthE2E] hide-animation start=\(String(format: "%.1f", hideSampleStart)) "
                + "end=\(String(format: "%.1f", hideSampleEnd)) samples=[\(recordedSamples)]"
        )
        XCTAssertNotNil(
            intermediateSample,
            "Hiding the Outline should ANIMATE the pane out (a slide through intermediate widths), "
                + "not snap to the end. No sample fell strictly between "
                + "\(hideSampleLow)pt and \(hideSampleHigh)pt (margin \(sampleMargin)pt); samples "
                + "over ~300ms were [\(recordedSamples)], start \(hideSampleStart)pt, "
                + "end \(hideSampleEnd)pt."
        )

        // Geometric discriminator: hiding must actually give the pane's width back to the editor.
        // This is the real proof -- see the isHittable note below for why a bare negation is not.
        let hideDeadline = Date(timeIntervalSinceNow: 10)
        var editorGrowthAfterHide: CGFloat = 0
        repeat {
            editorGrowthAfterHide = editorAreaWidth() - cappedEditorWidth
            if editorGrowthAfterHide >= Self.minWidth { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < hideDeadline
        XCTAssertGreaterThanOrEqual(
            editorGrowthAfterHide, Self.minWidth,
            "Hiding the Outline should hand at least \(Self.minWidth)pt back to the editor area; "
                + "it grew only \(editorGrowthAfterHide)pt (a residual hidden pane would fail this)"
        )
        // Documentation, NOT proof: `.accessibilityHidden(true)` is what makes this false, so an
        // assertion built only on this would also pass on unmodified main. The editor-width
        // growth assertion immediately above is the discriminator.
        XCTAssertFalse(
            app.groups["outline-sidebar"].isHittable,
            "The hidden Outline pane should not be hittable"
        )
        XCTAssertTrue(
            waitForOutlineToggleLabel("Show Outline"),
            "The toolbar Outline button should flip to \"Show Outline\" while hidden; "
                + "read \"\(outlineToggleLabel())\""
        )
        attachEvidenceScreenshot(app.screenshot(), name: "outline-overlay-hidden")

        app.activateAndWaitForForeground()
        app.typeKey("[", modifierFlags: .command)

        XCTAssertTrue(
            settleColumnWidth(Self.maxWidth),
            "Showing the Outline again should restore the dragged width (~\(Self.maxWidth)pt); "
                + "measured \(columnWidthDescription())"
        )
        XCTAssertTrue(
            waitForOutlineToggleLabel("Hide Outline"),
            "The toolbar Outline button should flip back to \"Hide Outline\"; "
                + "read \"\(outlineToggleLabel())\""
        )
        attachEvidenceScreenshot(app.screenshot(), name: "outline-overlay-reshown")
    }

    // Width persistence is deliberately NOT tested here, and cannot be: it is owned by AppKit's
    // `NSSplitView.autosaveName` (`SplitViewAutosaveNaming.stabilize(for:)`), which returns early
    // under `TestMode.isTesting`, so no UI test can observe a divider position surviving a launch.
    // A `UserDefaults` width pair was tried here and removed after a VM run falsified it -- the
    // pane opens at `maxWidth` on every launch because `HSplitView` does not honour the pane's
    // `idealWidth` at first layout (see `OutlineSidebarWidth`'s doc comment) -- and the permanent
    // test that used it (`testDividerWidthSurvivesRelaunch`, dragging to the floor and asserting
    // 250 after a relaunch) was deleted with it. Launch width persistence is verified BY HAND;
    // the three tests above cover only in-session bounds and show/hide.
    //
    // What IS still asserted about a launch: the achieved window width (1000 +/- 5, in
    // `launch(width:)`) and the split view's own bounds, both of which are layout, not persistence.
}

// MARK: - Launch / toggle helpers

extension SidebarWidthBoundsE2ETests {

    private func launch(width: CGFloat) {
        app.launchEnvironment["FF_UI_TESTING_WINDOW_WIDTH"] = String(Int(width))
        // Forces the app's persistent diagnostic sink on (`DiagnosticLogFile.isEnabled` reads this
        // straight from the environment, bypassing the hermetic UserDefaults wipe) so the
        // `[OutlineLaunchWidth]` line the launch positioning writes reaches the diagnostic file
        // `attachOutlineLaunchEvidence()` reads. Must be set BEFORE `launchForTesting`, which only
        // adds its own two keys to `launchEnvironment` and never clears the rest.
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        // The achieved width is asserted, not assumed: a silently broken
        // FF_UI_TESTING_WINDOW_WIDTH would leave every drag delta below meaning something other
        // than what its message claims while still passing.
        let achievedWidth = windowFrame().width
        XCTAssertEqual(
            achievedWidth, width, accuracy: 5,
            "Expected FF_UI_TESTING_WINDOW_WIDTH = \(Int(width)) to size the launch window; "
                + "measured \(achievedWidth)pt. If this display clamps the window, the drag "
                + "deltas need re-deriving."
        )
        toggleOutlineIfHidden()
        assertOutlineSettledVisible("launch")
    }

    /// Plain test-side output -- NOT an assertion: lands in `xcodebuild.log` on the same channel as
    /// `TestFixtureHelper`'s `[TestFixture] Fixture copied to: ...` line (`print`, which
    /// `scripts/e2e-lint.py` does not flag). Exists so a VM run can answer WHY a launch started at
    /// a given width -- the question "did the hermetic UI-test defaults wipe reset the persisted
    /// `OutlineSidebarWidth`?" is otherwise only visible as an assertion that happened not to hold.
    ///
    /// Uses `columnWidthDescription()` rather than `measuredColumnWidth()` so it never raises a
    /// second failure of its own; a missing divider is reported inside the line instead.
    private func emitMeasurement(_ label: String) {
        print(
            "[SidebarWidthE2E] \(label) column=\(columnWidthDescription()) "
                + "window=\(String(format: "%.1f", windowFrame().width)) "
                + "editor=\(String(format: "%.1f", editorAreaWidth())) "
                + "annotations=\(annotationsWidthDescription(annotationsPanelWidth()))"
        )
    }

    /// Records HOW the launch positioned the Outline divider, whether or not the launch width
    /// assertion goes on to pass: the app's `[OutlineLaunchWidth]` diagnostic lines (read from its
    /// persistent diagnostic log), plus a screenshot of the launched window.
    ///
    /// The lines are printed on the `[SidebarWidthE2E]` channel (lands in `xcodebuild.log`) AND
    /// attached as `outline-launch-width-log`. "No lines" is itself evidence, so the two ways it can
    /// happen read differently: the log could not be read at all (a wrong path or a sandboxed read,
    /// with `AppFileHelper`'s attempted paths in the message), versus the file was read and simply
    /// holds no such line (the app never logged one, or diagnostics never turned on). Every line in
    /// the log carries an ISO timestamp, so lines from an earlier launch in the same guest are
    /// distinguishable from this one's. Only the active `diagnostic.log` is read (not the rotated
    /// slots), which is stated in the zero-lines message so a rotation cannot masquerade as silence.
    private func attachOutlineLaunchEvidence() {
        let marker = "[OutlineLaunchWidth]"
        let logRelativePath = "Library/Application Support/com.kerim.final-final/Diagnostics/diagnostic.log"
        let report: String
        do {
            let contents = try AppFileHelper.read(appRelativePath: logRelativePath)
            let lines = contents.components(separatedBy: "\n").filter { $0.contains(marker) }
            if lines.isEmpty {
                report = "[SidebarWidthE2E] launch-positioning: no \(marker) lines found "
                    + "(file read but zero matching lines; only the active diagnostic.log was read, "
                    + "not its rotated slots)"
            } else {
                report = "[SidebarWidthE2E] launch-positioning:\n" + lines.joined(separator: "\n")
            }
        } catch {
            report = "[SidebarWidthE2E] launch-positioning: no \(marker) lines found "
                + "(log unreadable: \(error))"
        }
        print(report)

        let attachment = XCTAttachment(string: report)
        attachment.name = "outline-launch-width-log"
        attachment.lifetime = .keepAlways
        add(attachment)

        attachEvidenceScreenshot(app.screenshot(), name: "outline-at-launch")
    }

    /// Shows the Outline when the toggle positively reports it is hidden.
    ///
    /// Never a blind cmd-[: a blind press can HIDE an already-visible sidebar, turning a
    /// measurement problem into a confusing hidden-state failure. When the label cannot be read
    /// at all this deliberately presses nothing and lets `assertOutlineSettledVisible` fail
    /// loudly.
    private func toggleOutlineIfHidden() {
        if outlineToggleLabel() == "Show Outline" {
            app.activateAndWaitForForeground()
            app.typeKey("[", modifierFlags: .command)
        }
    }

    /// The loud "hidden or collapsed" assertion: a settled hidden column measures ~0pt, which
    /// would otherwise let a delta assertion pass silently.
    private func assertOutlineSettledVisible(
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForColumnWidth(atLeast: Self.minWidth),
            "\(context): the Outline sidebar is hidden or collapsed -- measured "
                + "\(columnWidthDescription()), expected >= \(Self.minWidth)pt. Either a previous "
                + "method leaked hidden state, or the pane never laid out.",
            file: file, line: line
        )
    }

    private func outlineToggleLabel() -> String {
        let button = app.buttons[Self.outlineToggleIdentifier]
        guard button.waitForExistence(timeout: 10) else { return "<toolbar-outline-toggle not found>" }
        return button.label
    }

    /// The Outline toolbar toggle element, FAILING (not skipping) when it is absent: every
    /// assertion about its label or position depends on it existing.
    private func outlineToggleButton(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = app.buttons[Self.outlineToggleIdentifier]
        if !button.waitForExistence(timeout: 10) {
            XCTFail(
                "The Outline toolbar toggle (identifier \"\(Self.outlineToggleIdentifier)\") was "
                    + "not found; label and placement assertions both depend on it existing.",
                file: file, line: line
            )
        }
        return button
    }

    private func waitForOutlineToggleLabel(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label == %@", expected)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: app.buttons[Self.outlineToggleIdentifier]
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - Geometry helpers

extension SidebarWidthBoundsE2ETests {

    private var editorArea: XCUIElement { app.groups["editor-area"] }

    private func editorAreaWidth() -> CGFloat { editorArea.frame.width }

    /// The Annotations panel's width, or `nil` when it exposes no usable frame -- absent from the
    /// accessibility tree, or zero-width. `nil` rather than a sentinel so the caller can tell
    /// "could not measure" from a real 0, and fall back to the reduced claim instead of asserting
    /// a bogus combined total.
    private func annotationsPanelWidth() -> CGFloat? {
        let panel = app.groups["annotations-panel"]
        guard panel.exists else { return nil }
        let width = panel.frame.width
        guard width > 0 else { return nil }
        return width
    }

    /// `annotationsPanelWidth()` for a log line or message, including the unmeasurable case.
    private func annotationsWidthDescription(_ width: CGFloat?) -> String {
        guard let width else { return "unmeasurable" }
        return String(format: "%.1fpt", width)
    }

    private func windowFrame() -> CGRect { app.windows.firstMatch.frame }

    /// The Outline divider: the splitter with the smallest `minX`, i.e. the one immediately to
    /// the right of the leftmost (sidebar) column.
    private func outlineDivider() -> XCUIElement? {
        let splitters = app.windows.firstMatch.splitters
        guard splitters.count >= 2 else { return nil }
        let candidates = splitters.allElementsBoundByIndex.filter { $0.exists }
        return candidates.min(by: { $0.frame.minX < $1.frame.minX })
    }

    /// Width of the Outline column, measured as the divider's `minX` relative to the window's
    /// `minX` -- the pane's own leading edge is also the window's, so this needs no third
    /// element. NOTE: this measures the divider's origin, so it cannot see a few points of
    /// residual divider left by a hidden pane; hiding reclaiming the pane is asserted separately
    /// (via `editorArea.frame.width`) in `testHidingAndShowingRetainsTheWidth`.
    ///
    /// `nil` when the splitter is missing -- a POLLING result, never a sentinel number. Poll
    /// callers tolerate `nil`; anything that needs a real number goes through
    /// `measuredColumnWidth()` or `columnWidthDescription()`.
    private func outlineColumnWidth() -> CGFloat? {
        guard let divider = outlineDivider() else { return nil }
        return divider.frame.minX - windowFrame().minX
    }

    /// The measured column width, failing fast when the splitter is missing rather than
    /// returning a sentinel that would flow silently into later arithmetic.
    private func measuredColumnWidth(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        guard let width = outlineColumnWidth() else {
            XCTFail(missingDividerMessage(), file: file, line: line)
            return 0
        }
        return width
    }

    /// The measured width for a failure MESSAGE: describes the missing-splitter case instead of
    /// failing, so one cause yields one failure rather than a second one raised by the message.
    private func columnWidthDescription() -> String {
        guard let width = outlineColumnWidth() else { return missingDividerMessage() }
        return String(format: "%.1fpt", width)
    }

    private func missingDividerMessage() -> String {
        "no Outline divider found -- expected at least 2 splitters (the Outline HSplitView's "
            + "divider plus the editor/annotations one), found "
            + "\(app.windows.firstMatch.splitters.count). See this class's header: the disposable "
            + "scratch pass validates splitter exposure before this permanent class is trusted."
    }

    /// Waits until the measured column width settles at `expected` (within 10pt), which also
    /// asserts WHICH bound was reached (the cap, the floor, or a restored width).
    @discardableResult
    private func settleColumnWidth(_ expected: CGFloat, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let observed = outlineColumnWidth(), abs(observed - expected) <= 10 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return false
    }

    /// Waits for the measured column width to be at least `minimum` -- the "is the sidebar
    /// actually laid out and visible?" gate used by the leak detector above.
    @discardableResult
    private func waitForColumnWidth(atLeast minimum: CGFloat, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let observed = outlineColumnWidth(), observed >= minimum { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return false
    }

    private func dragDivider(by delta: CGFloat) {
        guard let divider = outlineDivider() else {
            XCTFail(missingDividerMessage())
            return
        }
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: delta, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
