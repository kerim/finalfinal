//
//  HeadingZoomAffordanceE2ETests.swift
//  final finalUITests
//

// e2e-verify run for t-d7f6c3b6 (ux-contract §2/D2) -- StatusBar.swift's merged
// zoom/outline pill (see that file's own doc comment above its `HStack(spacing: Spacing.s4)`):
// while zoomed, the pill's text zone reads "Zoomed: <heading>" and a small leading
// chevron.left exit glyph appears (identifier "status-bar-zoom-exit", disabled while
// contentState != .idle); the rest of the pill (identifier "status-bar-outline") keeps
// opening the outline popover even while zoomed. This proves the two tap zones are
// genuinely distinct native controls, not one region with dispatch-by-coordinate logic.

import XCTest

final class HeadingZoomAffordanceE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// Anchor (H1) + two H2 siblings -- same shape as
    /// UnifiedUndoE2ETests+Helpers.swift's own `canonicalMarkdown`, reused here rather than
    /// invented fresh, since it's already a proven-working seed for this exact
    /// "zoom into a sidebar-titled section" interaction.
    private static let seedMarkdown = """
    # Anchor Section

    Anchor section body text for zoom affordance testing.

    ## Middle Section

    Middle section body text for zoom affordance testing.

    ## Last Section

    Last section body text for zoom affordance testing too.
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    private func waitForEditorReady() {
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area should appear with seeded content")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
    }

    /// Locates a sidebar card by its EXACT title text. Copied from
    /// `UnifiedUndoE2ETests+Helpers.swift`'s `sidebarCard(titled:)` (that file's own doc comment
    /// explains why: title lives in `value` not `label`, scoped to the sidebar's `ScrollView`
    /// specifically to avoid the zoom breadcrumb's own same-titled `StaticText` sibling once
    /// zoomed) -- this file can't `import`/extend that type, so the pattern is duplicated rather
    /// than reinvented.
    private func sidebarCard(titled title: String, timeout: TimeInterval = 10) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        let card = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "Sidebar card titled \"\(title)\" should appear")
        return card
    }

    /// Zooms into "Middle Section" and confirms the exit glyph appears (i.e. the app really is
    /// zoomed, not just that a click landed somewhere).
    ///
    /// Deliberately NOT a Cmd-click on the heading in the editor, which is the feature's real
    /// trigger (`web/milkdown/src/heading-zoom-click-handler.ts` -> `zoomHeadingClicked` bridge
    /// message -> `HeadingZoomClickRouter.decide`). There is no compile-safe way to synthesize a
    /// genuine Cmd-held click through this suite's public XCTest surface on this NATIVE (non-
    /// Catalyst) macOS target: `XCUIElement.perform(withKeyModifiers:block:)` is the one API that
    /// does this, but its header in the installed macOS SDK
    /// (XCUIAutomation.framework/Headers/XCUIElement.h) annotates it
    /// `API_AVAILABLE(ios(15.0), macCatalyst(13.0))` -- macOS is not in that list, confirmed by
    /// reading the header directly (also absent from this SDK's macOS
    /// XCUIAutomation.swiftinterface), so the symbol does not exist for this target and calling
    /// it fails to compile. CGEvent-based modifier injection is separately banned by this
    /// project's own e2e-verify skill (untrusted in the VM guest, no HID trust). See this file's
    /// bottom MARK for the full note, including why this substitution still genuinely proves the
    /// status-bar behavior under test.
    ///
    /// Double-clicking a sidebar card is `OutlineSidebar`'s own, separate `onDoubleClick ->
    /// zoomToSection` trigger -- the exact mechanism
    /// `UnifiedUndoE2ETests.testStructuralOpRefusedWhileZoomedStaysConsistent` already uses to
    /// reach the same zoomed state (`UnifiedUndoE2ETests.swift`, `cardToZoom...doubleClick()`).
    /// It lands the app in an IDENTICAL `EditorViewState.zoomedSectionId` state to a Cmd-click --
    /// the one thing StatusBar.swift's affordance (under test here) actually reacts to -- so this
    /// substitution proves the status-bar behavior end to end regardless of which gesture set
    /// `zoomedSectionId`.
    /// Screenshot evidence, same pattern as `ProjectSwitchMarginsE2ETests.snap(_:)` /
    /// `ErrorPresenterE2ETests.attachScreenshot(_:name:to:)`: attach to the .xcresult
    /// (so a reviewer sees it inline in the test report) AND write the PNG to the
    /// shared `E2EShotDir` evidence folder the e2e-verify skill browses directly.
    /// This task's original complaint was purely visual (a cramped, duplicated-
    /// looking control); the previous run of this suite produced zero attachments,
    /// so nothing ever put that visual state in front of a reviewer.
    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let pngData = app.screenshot().pngRepresentation as Data? {
            try? pngData.write(to: E2EShotDir.url.appendingPathComponent("\(name).png"))
        }
    }

    private func zoomIntoMiddleSection() {
        // Positive control (e2e-verify skill convention): confirm the exit glyph genuinely does
        // NOT exist before zooming, so its later appearance isn't a vacuous/stale query match.
        XCTAssertFalse(
            app.buttons["status-bar-zoom-exit"].exists,
            "Exit-zoom glyph should not exist before zooming into anything"
        )

        let card = sidebarCard(titled: "Middle Section")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        app.buttons["status-bar-zoom-exit"].waitForExistenceOrFail(
            timeout: 10,
            file: #filePath, line: #line
        )
    }

    // MARK: - 1. Status bar shows the zoomed-state affordance

    /// Zooming in should flip the merged center control to the "Zoomed: <heading>" state:
    /// the leading exit glyph appears (checked inside `zoomIntoMiddleSection()`), and the outline
    /// button's accessibility VALUE (set via `.accessibilityValue(Text(centerIndicatorAccessibilityLabel))`
    /// in StatusBar.swift -- deliberately not its label, which stays the fixed "Document Outline"
    /// action name per that file's "Must-fix D" comment) reads "Zoomed into <heading>".
    func testStatusBarShowsZoomedAffordance() throws {
        zoomIntoMiddleSection()

        let outlineButton = app.buttons["status-bar-outline"]
        XCTAssertTrue(outlineButton.exists, "status-bar-outline control should still exist while zoomed")
        XCTAssertTrue(
            outlineButton.waitForValue("BEGINSWITH 'Zoomed'", timeout: 5),
            "status-bar-outline's accessibility value should read \"Zoomed into ...\" while zoomed, got: "
                + "\(String(describing: outlineButton.value))"
        )
        snap("zoomed-affordance-pill")
    }

    // MARK: - 2. The exit glyph exits zoom WITHOUT opening the outline popover

    func testExitGlyphExitsZoomWithoutOpeningOutlinePopover() throws {
        zoomIntoMiddleSection()

        // Click the leading exit glyph SPECIFICALLY -- by its own accessibility identifier, a
        // distinct native Button sibling of the outline button inside the shared pill HStack
        // (StatusBar.swift), not a coordinate offset into the pill as a whole. That distinction
        // is the entire point of this test: two separately-clickable controls, not one region
        // dispatching by tap position.
        app.buttons["status-bar-zoom-exit"].click()

        XCTAssertTrue(
            app.buttons["status-bar-zoom-exit"].waitForDisappearance(timeout: 5),
            "Exit-zoom glyph should disappear once zoom is exited"
        )
        XCTAssertFalse(
            app.popovers.firstMatch.waitForExistence(timeout: 1),
            "Clicking the exit glyph should exit zoom, not open the outline popover"
        )
        snap("exited-zoom-no-popover")
    }

    // MARK: - 3. Clicking the REST of the pill opens the outline popover, not exit, while zoomed

    func testOutlineZoneClickOpensPopoverWhileStillZoomed() throws {
        zoomIntoMiddleSection()

        // Click the label/outline zone -- its own distinct Button, identifier "status-bar-outline"
        // -- NOT the exit glyph.
        app.buttons["status-bar-outline"].click()

        XCTAssertTrue(
            app.popovers.firstMatch.waitForExistence(timeout: 5),
            "Clicking the outline zone while zoomed should open the outline popover"
        )
        XCTAssertTrue(
            app.buttons["status-bar-zoom-exit"].exists,
            "Clicking the outline zone must not exit zoom -- the exit glyph should still be present"
        )
        snap("outline-popover-open-while-zoomed")
    }

    // MARK: - 4. Cmd-hover hint / Cmd-click exclusion for Bibliography & Notes headings -- SKIPPED

    // Not exercised here, on two independent, already-established grounds:
    //
    //   - The hover hint itself is a pure CSS `:hover` rule (`body.ff-cmd-held h1[data-block-id]:hover`,
    //     styles.css) toggled by a document-level mousemove/keydown listener. The e2e-verify
    //     skill's own proven-patterns ledger CONFIRMS (`headings-zoom-affordance`, 2026-09-08 --
    //     this exact task) that `XCUIElement.hover()` does not reliably trigger WKWebView CSS
    //     `:hover` state in this VM guest, tried via two independent techniques (single-point and
    //     two-point "approach then land"), even though the same API works for native SwiftUI
    //     `.onHover` content elsewhere in this suite. Forcing this here would be exactly the kind
    //     of flaky test the skill says not to write.
    //   - Separately (see `zoomIntoMiddleSection()`'s doc comment above): there is no compile-safe
    //     way to synthesize a genuine Cmd-held click on this native macOS target at all, so even a
    //     non-hover proxy for this item -- Cmd-click a Bibliography/Notes heading and confirm no
    //     zoom happens -- isn't reachable through this suite's public API surface either.
    //
    // Manual verification substitutes: Cmd-hold over a Bibliography or Notes heading in the
    // running app and confirm no pointer-cursor/underline hint appears, then Cmd-click it and
    // confirm nothing zooms. The click-side exclusion itself
    // (`HeadingZoomClickRouter.decide`'s `isBibliography || isNotes` drop branch) already has
    // direct unit coverage in `final finalTests/Tier1/HeadingZoomClickRouterTests.swift`.
}
