//
//  ChromeTypographyE2ETests.swift
//  final finalUITests
//
//  PERMANENT e2e regression test, renamed here from the disposable
//  `E2EScratchTests.swift` scratch pad per that file's own header ("A class worth
//  keeping gets copied to its own named file and `git add`ed BEFORE the reset").
//  Renamed rather than left under the shared scratch-pad name because a different
//  worktree in the same superdev batch also named its e2e class `E2EScratchTests`,
//  and vmtest's retry-refusal tracking keys on that scope string (not the
//  worktree), which was blocking this worktree's unrelated tests too.
//

import XCTest

/// Permanent e2e regression test for t-e323ef1e ("main-window chrome text onto
/// the app's size table"). The task is a values-preserving rename, guarded by
/// `RawFontSizeLiteralTests` (source scanner) — but the one deliberate visual
/// change, D13's status-bar chevron fix (7pt -> `TypeScale.chromeTiny`, 10pt),
/// is a numeric-size defect fix, not a value-preserving migration, so it's the
/// one spot a wrong token pick would be user-visible without failing the
/// scanner. This drives to it and asserts it renders hittable, plus a
/// screenshot for a human/design-reviewer visual pass (font-size correctness
/// itself isn't XCUITest-assertable -- see the plan's "Test commands").
final class ChromeTypographyE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testStatusBarOutlineChevronIsPresentAndHittable() throws {
        let statusBar = app.groups["status-bar"]
        XCTAssertTrue(statusBar.waitForExistence(timeout: 10), "Status bar should appear")

        // The chevron (Image(systemName: "chevron.down"), now TypeScale.chromeTiny
        // instead of the near-invisible 7pt original) lives inside the whole
        // outline-toggle Button, which itself carries the accessibility
        // identifier -- SwiftUI doesn't expose the inner Image separately.
        let outlineButton = app.buttons["status-bar-outline"]
        XCTAssertTrue(outlineButton.waitForExistence(timeout: 10), "Status-bar outline button (chevron) should appear")
        XCTAssertTrue(outlineButton.isHittable, "Status-bar outline button (chevron) should be hittable, not near-invisible at 7pt")

        // Screenshot evidence for the human/design-reviewer visual pass this
        // task's plan calls for in place of an automated font-size assertion.
        let shotDir = E2EShotDir.url
        try? app.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("status-bar-chevron.png"))

        // Drive it for real: clicking should open the outline popover, proving
        // the enlarged chevron sits over a genuinely functional hit target,
        // not just an accessibility-tree stub.
        outlineButton.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Clicking the status-bar outline chevron should open its popover")
    }
}
