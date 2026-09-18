//
//  ProjectSwitchMarginsE2ETests.swift
//  final finalUITests
//
//  Per user direction (2026-08-29): reproduce via SWITCHING projects after launch, not via
//  the project that opens on launch -- switching is the more reliable repro path, and the
//  specific switching mechanism doesn't matter. Focuses specifically on MARGINS (not just
//  blank-vs-not), since that's the persistent half of the user's report that this task's
//  earlier fixes (project-switch content invariant, compositor-repaint nudge) did not
//  clearly verify one way or the other.
//

import XCTest

final class ProjectSwitchMarginsE2ETests: XCTestCase {
    var app: XCUIApplication!
    private var fixtureBPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        // Investigative-only: force real DebugLog output for this run so the exact
        // switch-back-to-a-previously-visited-project sequence can be read afterward, instead
        // of inferred from screenshots alone.
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        if let fixtureBPath {
            try? FileManager.default.removeItem(atPath: fixtureBPath)
        }
    }

    func testSwitchingToAnotherProjectPreservesMargins() throws {
        let fixtureAPath = TestFixtureHelper.fixturePath

        // Second, independent project -- a fresh copy of the same committed fixture at its
        // own path, never opened before in this session.
        let fm = FileManager.default
        let bPath = NSTemporaryDirectory() + "ff-test-fixture-B-\(UUID().uuidString).ff"
        let bundle = Bundle(for: type(of: self))
        guard let fixtureSource = bundle.resourceURL?.appendingPathComponent("Fixtures/test-fixture.ff"),
              fm.fileExists(atPath: fixtureSource.path) else {
            XCTFail("Test fixture not found in UI test bundle")
            return
        }
        try? fm.removeItem(atPath: bPath)
        try fm.copyItem(at: fixtureSource, to: URL(fileURLWithPath: bPath))
        fixtureBPath = bPath
        FixtureDatabase.write(fixturePath: bPath, sql: "DELETE FROM block;")

        // ---- Open project A first ----
        app.launchForTesting(fixturePath: fixtureAPath)
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area should appear for project A")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Project A editor JS should be ready")

        // ---- Switch to project B (never opened before in this session) ----
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: bPath))

        // Sync point: B's block table goes from the deliberately-cleared 0 to non-zero only
        // once the switch has actually landed and parsed B's content.
        let blockCountAfterSwitch = waitUntilInt(
            timeout: 20,
            probe: {
                Int(FixtureDatabase.read(fixturePath: bPath, sql: "SELECT count(*) FROM block;")
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            },
            predicate: { $0 > 0 }
        )
        XCTAssertGreaterThan(blockCountAfterSwitch, 0, "Switch to fixture B should have parsed its content into blocks")

        Thread.sleep(forTimeInterval: 1.0)
        snap("switch-settled")

        // ---- Switch back to A, then back to B again -- CONFIRMED (2026-08-29): the repeat
        // switch back to B is where the persistent blank + wrong-margins-after-click bug
        // actually reproduces, not the first switch to it. ----
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: fixtureAPath))
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 15), "Should switch back to A")
        Thread.sleep(forTimeInterval: 0.5)
        snap("switch-back-to-A")

        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: bPath))
        Thread.sleep(forTimeInterval: 3.0)
        snap("switch-to-B-again-persistent-blank")

        // Click reveals content with wrong margins, per the confirmed repro.
        let sidebarHeadingB = app.staticTexts["Test Document"].firstMatch
        if sidebarHeadingB.waitForExistence(timeout: 5) {
            sidebarHeadingB.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            Thread.sleep(forTimeInterval: 0.5)
            snap("switch-to-B-again-after-click-wrong-margins")
        }

        // Investigative-only: dump the real diagnostic log this run produced, so the exact
        // switch-back sequence (project close/open ordering, content pushes, lastPushedContent
        // updates) can be read directly instead of inferred from screenshots.
        attachDiagnosticLog()
    }

    /// Reads the app's real diagnostic log (forced on via FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING)
    /// and attaches its tail as evidence. The app is not sandboxed, so this resolves to the same
    /// real file both processes see -- no cross-container copying needed.
    private func attachDiagnosticLog() {
        // Try every plausible location: the test runner's own container may not be the app's
        // real home in a VM guest (NSHomeDirectory() is documented elsewhere in this suite as
        // differing between the two), so don't assume just one.
        var candidates: [URL] = []
        for base in FileManager.default.urls(for: .applicationSupportDirectory, in: .allDomainsMask) {
            candidates.append(base.appendingPathComponent("com.kerim.final-final/Diagnostics/diagnostic.log"))
        }
        candidates.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.kerim.final-final/Diagnostics/diagnostic.log"))
        candidates.append(URL(fileURLWithPath: "/Users/admin/Library/Application Support/com.kerim.final-final/Diagnostics/diagnostic.log"))

        var report = "NSHomeDirectory()=\(NSHomeDirectory())\n"
        report += "Candidates tried:\n"
        var found: String?
        for candidate in candidates {
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            report += "  [\(exists ? "EXISTS" : "missing")] \(candidate.path)\n"
            if exists, found == nil, let data = try? Data(contentsOf: candidate), let text = String(data: data, encoding: .utf8) {
                found = text
            }
        }

        let attachment: XCTAttachment
        if let found {
            // A plain tail can silently drop the switch we actually care about behind chatty
            // per-keystroke noise (proofing dispatch, outline batchWordCounts) from LATER
            // switches -- confirmed 2026-08-29: a 500-line tail captured only the first 2 of 3+
            // setContentWithBlockIds pushes in one run. Keep every line matching the signal
            // patterns this investigation depends on, in original order, regardless of volume.
            let signalPatterns = [
                "SYNC-DIAG", "DIAG:MarginCheck", "FINDER-OPEN", "BlockPoll", "resetForProjectSwitch",
                "DocumentManager", "clearStructuralRegistry", "clearEditorHistories", "EditorPreloader",
                "Creating new WebView", "Using preloaded WebView", "WebView claimed", "ContentView] flushAllPendingContent",
            ]
            let filtered = found.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in signalPatterns.contains { line.contains($0) } }
                .joined(separator: "\n")
            attachment = XCTAttachment(string: report + "\n---FILTERED (signal lines only, full run)---\n" + filtered)
        } else {
            attachment = XCTAttachment(string: report + "\n(no log found at any candidate path)")
        }
        attachment.name = "diagnostic-log-tail"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? (found ?? report).write(to: E2EShotDir.url.appendingPathComponent("diagnostic-log-full.txt"), atomically: true, encoding: .utf8)
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

    private func waitUntilInt(
        timeout: TimeInterval, pollInterval: TimeInterval = 0.25,
        probe: () -> Int, predicate: (Int) -> Bool
    ) -> Int {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = probe()
        while Date() < deadline {
            last = probe()
            if predicate(last) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
        return last
    }
}
