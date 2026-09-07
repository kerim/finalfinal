//
//  DiagnosticsReportSavedInlineE2ETests.swift
//  final finalUITests
//
//  e2e verification for the DiagnosticsPreferencesPane
//  success/failure state split (see DiagnosticsPreferencesPane.swift):
//  generateReport() sets `savedReportURL: URL?` on success, driving an
//  inline "Saved to: <path>" Text in the "Diagnostic Report" GroupBox,
//  separately from `reportFailureMessage: String?` on failure (unchanged
//  "Report Generation Failed" alert). Promoted out of the disposable
//  E2EScratchTests.swift scratch pad once vmtest confirmed it green
//  (run-1788749535-69278) -- see that file's header for the scratch
//  workflow this was authored under.
//

import XCTest

final class DiagnosticsReportSavedInlineE2ETests: XCTestCase {
    var app: XCUIApplication!
    private var destinationDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let destinationDir {
            try? FileManager.default.removeItem(at: destinationDir)
        }
    }

    /// Opens Preferences (Cmd-,), switches to the Diagnostics tab, generates
    /// a report via a real NSSavePanel (driven with the Cmd-Shift-G "Go to
    /// Folder" technique already proven for NSOpenPanel in
    /// ProjectOpenErrorE2ETests.swift), and asserts the new inline
    /// "Saved to: <path>" text appears with the chosen destination, rather
    /// than the failure alert. No other test in this suite drives an
    /// NSSavePanel to completion -- that part of the technique is new here.
    func testDiagnosticsGenerateReportShowsSavedToPathInline() throws {
        app = XCUIApplication.targetApp()
        app.launchForTesting()

        // No project needs to be open -- DiagnosticReportGenerator works
        // regardless (system info + rolling log + export captures are all
        // independent of an open project; see its doc comment).
        let picker = app.groups["project-picker"]
        XCTAssertTrue(picker.waitForExistenceOrFail(timeout: 10).exists,
                      "Project picker should appear with no project open")

        destinationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-diagnostics-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        app.activateAndWaitForForeground()
        app.typeKey(",", modifierFlags: .command)

        // The tab bar's "Diagnostics" control is a native Button whose title
        // is the tab's Label text -- an .accessibilityIdentifier attached
        // inside .tabItem { Label(...) } does NOT propagate to it (confirmed
        // live: TabView builds its own native tab control separately from
        // the Label view instance), so this matches on title instead.
        let diagnosticsTab = app.buttons["Diagnostics"]
        XCTAssertTrue(diagnosticsTab.waitForExistenceOrFail(timeout: 10).exists,
                      "Preferences window should open (Cmd-,) with a Diagnostics tab")
        diagnosticsTab.click()

        let generateButton = app.descendants(matching: .any)["diagnostics-generate-report-button"]
        XCTAssertTrue(generateButton.waitForExistenceOrFail(timeout: 10).exists,
                      "Diagnostics pane should show the Generate Diagnostic Report button")
        generateButton.click()

        // NSSavePanel.runModal() blocks synchronously on the main thread in a
        // nested run loop -- same modal shape PrintE2ETests.swift and
        // ProjectOpenErrorE2ETests.swift already drive successfully.
        let savePanel = app.dialogs.firstMatch
        guard savePanel.waitForExistence(timeout: 10) else {
            XCTFail("NSSavePanel did not appear after clicking Generate Diagnostic Report...")
            return
        }

        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.sheets.textFields.firstMatch
        guard pathField.waitForExistence(timeout: 5) else {
            XCTFail("Go to Folder field did not appear")
            return
        }
        pathField.typeText(destinationDir.path)
        app.typeKey(.enter, modifierFlags: [])
        // Confirms the save panel's default action (Save) with its untouched
        // default filename ("final-final-diagnostics-<isoStamp>").
        app.typeKey(.enter, modifierFlags: [])

        // 60s confirmed sufficient by vmtest run-1788749535-69278: the
        // original 20s wait was too short because report generation
        // (gethostname()-based system-info snapshot, plus rolling-log and
        // export-capture file I/O) can outrun 20s under VM disk contention.
        let savedText = app.descendants(matching: .any)["diagnostics-saved-report-text"]
        XCTAssertTrue(savedText.waitForExistenceOrFail(timeout: 60).exists,
                      "\"Saved to: ...\" text should appear once report generation finishes")

        let savedValue = (savedText.value as? String) ?? savedText.label
        XCTAssertTrue(savedValue.contains(destinationDir.path),
                      "\"Saved to:\" text (\(savedValue)) should contain the chosen destination folder (\(destinationDir.path))")

        let failureAlertTitle = app.staticTexts["Report Generation Failed"]
        XCTAssertFalse(failureAlertTitle.exists,
                       "Report generation should have succeeded, not shown the failure alert")

        // Confirms DiagnosticReportGenerator actually wrote something under
        // the chosen destination, not just that the UI text looks right.
        let createdEntries = (try? FileManager.default.contentsOfDirectory(atPath: destinationDir.path)) ?? []
        XCTAssertFalse(createdEntries.isEmpty,
                       "Report generation should have created at least one entry under \(destinationDir.path)")
    }
}
