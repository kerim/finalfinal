//
//  PrintE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e verification for the File > Print feature (Formatted +
//  Raw Markdown submenu items introduced in Commands/PrintCommands.swift +
//  Commands/FileCommands.swift). Written per the e2e-verify skill to drive
//  the real app and capture screenshot evidence; delete after evidence is
//  captured -- this is throwaway scaffolding, not a permanent regression
//  test. If any scenario here deserves to become permanent, promote it into
//  SmokeTests.swift instead of leaving this file around.
//

import XCTest

final class PrintE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Formatted print (fixture required, has content)

    /// Drives File > Print > Formatted..., which reuses the Pandoc -> xelatex ->
    /// PDFKit pipeline from "Export as PDF..." before handing off to
    /// NSPrintOperation. Because that pipeline has real external dependencies
    /// (Pandoc + a LaTeX engine) that may not be installed on every machine
    /// this test runs on, the test explicitly distinguishes three outcomes
    /// instead of only recognizing success:
    ///   1. Pandoc missing -> "Pandoc Not Found" alert -> XCTSkip (environment
    ///      precondition not met, not a feature bug).
    ///   2. Pipeline failed for another reason -> "Print Failed" alert -> fail
    ///      with that alert's text so the underlying cause is visible.
    ///   3. Success -> the system print panel appears -> screenshot + Cancel.
    func testPrintFormattedShowsPrintPanel() throws {
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistenceOrFail(timeout: 10).exists,
                      "Editor area should appear with fixture content")

        invokePrint(menuItemTitle: "Formatted...")

        // Render is real work (Pandoc + xelatex), so give it a generous window
        // before deciding nothing showed up.
        switch waitForPrintOutcome(timeout: 40) {
        case .printPanel(let cancelButton):
            attachScreenshot(named: "print-formatted-panel")
            cancelButton.click()

        case .pandocNotFound(let okButton):
            attachScreenshot(named: "print-formatted-panel-pandoc-missing")
            okButton.click()
            throw XCTSkip("""
                Pandoc is not installed on this machine, so Formatted print took \
                the "Pandoc Not Found" branch instead of ever reaching the print \
                panel. This mirrors "Export as PDF...", which has the same \
                dependency. Install pandoc + a LaTeX engine (e.g. via the same \
                setup used for PDF export) to exercise the print-panel path.
                """)

        case .printFailed(let okButton):
            attachScreenshot(named: "print-formatted-panel-print-failed")
            okButton.click()
            XCTFail("Formatted print showed a \"Print Failed\" alert instead of the print panel -- see the attached print-formatted-panel-print-failed screenshot for the error detail.")

        case .timedOut:
            XCTFail("Neither the print panel, \"Pandoc Not Found\", nor \"Print Failed\" appeared within the timeout after invoking File > Print > Formatted...")
        }
    }

    // MARK: - Raw Markdown print (fixture required, has content)

    /// Drives File > Print > Raw Markdown..., which has no Pandoc dependency
    /// (plain BlockParser + NSTextView + NSPrintOperation), so only the
    /// print-panel and generic-failure outcomes are realistic here.
    func testPrintRawMarkdownShowsPrintPanel() throws {
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistenceOrFail(timeout: 10).exists,
                      "Editor area should appear with fixture content")

        invokePrint(menuItemTitle: "Raw Markdown...")

        switch waitForPrintOutcome(timeout: 20) {
        case .printPanel(let cancelButton):
            attachScreenshot(named: "print-raw-markdown-panel")
            cancelButton.click()

        case .pandocNotFound(let okButton):
            attachScreenshot(named: "print-raw-markdown-panel-unexpected-pandoc-alert")
            okButton.click()
            XCTFail("Raw Markdown print should never touch the Pandoc pipeline, but a \"Pandoc Not Found\" alert appeared.")

        case .printFailed(let okButton):
            attachScreenshot(named: "print-raw-markdown-panel-print-failed")
            okButton.click()
            XCTFail("Raw Markdown print showed a \"Print Failed\" alert instead of the print panel -- see the attached print-raw-markdown-panel-print-failed screenshot for the error detail.")

        case .timedOut:
            XCTFail("Neither the print panel nor a failure alert appeared within the timeout after invoking File > Print > Raw Markdown...")
        }
    }

    // MARK: - No project open -> "No Content to Print" alert

    /// Launches straight to the project picker (no fixture opened) and drives
    /// File > Print > Formatted... from that state. PrintOperations.handlePrintFormatted()
    /// short-circuits before ever touching Pandoc: with no open project,
    /// DocumentManager.exportBlocks() returns [] and
    /// BlockParser.assembleMarkdownForExport([]) returns "", so the "No
    /// Content to Print" alert fires immediately -- this scenario is not
    /// affected by whether Pandoc is installed.
    func testPrintWithNoProjectOpenShowsAlert() throws {
        app = XCUIApplication.targetApp()
        app.launchForTesting()

        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistenceOrFail(timeout: 10).exists,
                      "Project picker should appear with no project open")

        invokePrint(menuItemTitle: "Formatted...")

        let alertTitle = app.staticTexts["No Content to Print"]
        XCTAssertTrue(alertTitle.waitForExistenceOrFail(timeout: 10).exists,
                      "\"No Content to Print\" alert should appear when printing with no project open")

        attachScreenshot(named: "print-no-project-alert")

        let okButton = app.buttons["OK"].firstMatch
        if okButton.waitForExistence(timeout: 5) {
            okButton.click()
        } else {
            app.typeKey(.enter, modifierFlags: [])
        }
    }

    // MARK: - Menu navigation helper

    /// Navigates File > Print > <menuItemTitle> via the menu bar, using the
    /// same query pattern as `LaunchSmokeTests.testPrintMenuItemsExist()` so
    /// the two stay consistent.
    private func invokePrint(menuItemTitle: String) {
        app.activateAndWaitForForeground()

        let fileMenuBarItem = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenuBarItem.waitForExistenceOrFail(timeout: 5).exists, "File menu should exist")
        fileMenuBarItem.click()

        let printMenuItem = app.menuItems["Print"]
        XCTAssertTrue(printMenuItem.waitForExistenceOrFail(timeout: 5).exists, "File > Print submenu should exist")
        printMenuItem.click()

        let targetItem = app.menuItems[menuItemTitle]
        XCTAssertTrue(targetItem.waitForExistenceOrFail(timeout: 5).exists, "File > Print > \(menuItemTitle) should exist")
        targetItem.click()
    }

    // MARK: - Print outcome polling

    private enum PrintOutcome {
        /// The system print panel appeared; carries its "Cancel" button.
        case printPanel(XCUIElement)
        /// The "Pandoc Not Found" alert appeared; carries its "OK" button.
        case pandocNotFound(XCUIElement)
        /// The "Print Failed" alert appeared; carries its "OK" button. The
        /// caller's screenshot captures the informative-text error detail --
        /// deliberately not scraped here via `app.staticTexts`, since that
        /// query isn't scoped to the alert and could pick up unrelated text
        /// elsewhere in the app.
        case printFailed(XCUIElement)
        case timedOut
    }

    /// Polls for whichever of the three known outcomes of a print action
    /// appears first. NSPrintOperation.run() (invoked with no target window)
    /// can present the system print panel as either a document-modal sheet
    /// or an app-modal dialog window depending on presentation context, so
    /// both AX container roles are checked, plus a bare button-role match as
    /// a last resort -- rather than assuming one specific AX shape.
    private func waitForPrintOutcome(timeout: TimeInterval) -> PrintOutcome {
        // Scoped by the print panel's own container title ("Print") rather than
        // a bare `app.buttons["Cancel"]` search -- a real run showed the system
        // TouchBar also exposes an unrelated "Cancel" button at the same time,
        // and an unscoped app-wide query matches both, making `.click()` throw
        // "Multiple matching elements found." Scoping to the "Print"-titled
        // container excludes the TouchBar match entirely.
        let cancelCandidates: [XCUIElement] = [
            app.sheets["Print"].buttons["Cancel"],
            app.dialogs["Print"].buttons["Cancel"],
            app.windows["Print"].buttons["Cancel"]
        ]

        let pandocAlert = app.staticTexts["Pandoc Not Found"]
        let printFailedAlert = app.staticTexts["Print Failed"]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pandocAlert.exists {
                return .pandocNotFound(app.buttons["OK"].firstMatch)
            }
            if printFailedAlert.exists {
                return .printFailed(app.buttons["OK"].firstMatch)
            }
            if let cancelButton = cancelCandidates.first(where: { $0.exists }) {
                return .printPanel(cancelButton)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        return .timedOut
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
