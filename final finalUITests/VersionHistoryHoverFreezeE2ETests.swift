//
//  VersionHistoryHoverFreezeE2ETests.swift
//  final finalUITests
//
//  Regression test for t-65f85d38: hovering a section row in File > Version History froze the whole
//  app (spinning wheel, force-quit) whenever the document had footnotes or citations. The preview
//  columns' LazyVStack never finished laying out once the last rows (Notes, Bibliography) were drawn
//  -- see docs/lessons/swiftui-lazyvstack-hover-layout-hang.md. Fix: plain VStack + row-owned hover
//  state in DocumentPreviewView.swift.
//
//  Detection without in-app instrumentation: XCUITest waits for the app to go idle around every
//  hover, scroll and query, so on a wedged app those calls block. Every hover, scroll and click is
//  timed and fails past its limit (accessibility lookups are not timed, so a slow lookup cannot read
//  as a freeze), and a final bounded query proves the app still answers. tearDown attaches the timing
//  list (slowest interaction first) on success and failure, and on a wedged app force-quits it and
//  attaches a screenshot and a `sample` stack.
//
//  Two tests: hovering across the rows (the freeze itself), and the user's whole path -- hover a row,
//  right-click it, Replace Current Section, Restore -- which must complete with the window closed,
//  the section restored and its footnote intact.
//
import XCTest
import AppKit

final class VersionHistoryHoverFreezeE2ETests: XCTestCase {
    var app: XCUIApplication!
    var launched = false
    var appMayBeHung = false
    var stopped = false
    var hoveredNotes = false
    /// Per column (0 = Current, 1 = Selected): position in `orderedTitles` of the last row hovered.
    var lastOrder: [Int: Int] = [0: 0, 1: 0]
    /// One line per timed interaction (hover, scroll, click, final query) and the slowest of them; attached
    /// at teardown on success and failure so a slow-but-passing run is visible.
    var timings: [String] = []
    var longestTimed: (what: String, seconds: TimeInterval) = ("(none)", 0)
    /// Raw sqlite3 output of the most recent row-count query, for failure messages.
    var lastDBOutput = ""

    static let bundleId = "com.kerim.final-final.testhost"   // UITestHelpers.targetApp()
    static let versionName = "Before hover edit"
    static let body = "Original hover body sentence"
    static let sectionTitles = (1...12).map { String(format: "Hover Section %02d", $0) }
    static let orderedTitles = sectionTitles + ["Notes", "Bibliography"]
    static let words = ["alpha", "brook", "cedar", "delta", "ember", "fjord", "garnet", "harbor",
                        "island", "juniper", "kernel", "lantern", "meadow", "nectar", "orchard", "prairie"]

    private struct HoverStep {
        let title: String
        let column: Int
        let rest: TimeInterval
        var optional = false
        var expectReplaceButton = false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        let failed = !(testRun?.hasSucceeded ?? false)
        if launched { attachTimings() }
        if launched && (failed || appMayBeHung) {
            // XCUIScreen + Process only -- never the (possibly wedged) app's AX tree.
            attachEvidenceScreenshot(XCUIScreen.main.screenshot(), name: "version-history-hover screen at teardown")
            attachSample(name: "version-history-hover sample of app")
        }
        if failed || appMayBeHung {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).forEach { $0.forceTerminate() }
        }
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    /// 12 sections (~4k words) with footnotes and a mock citation, so the preview has Notes (and,
    /// when the mock citation resolves, Bibliography) as its last rows -- the rows that hung main's
    /// LazyVStack. ~14 hovers across both columns, including the bottom rows and a quick sweep.
    func testHoverAcrossVersionHistoryRowsDoesNotFreeze() throws {
        guard let setup = prepareVersionHistory() else { return }
        let window = setup.window
        let columns = setup.columns

        appMayBeHung = true   // from here a wedge is possible (hover, or the scrolling between hovers)
        let plan: [HoverStep] = [
            HoverStep(title: "Hover Section 01", column: 1, rest: 1.0, expectReplaceButton: true),
            HoverStep(title: "Hover Section 06", column: 1, rest: 1.0),
            HoverStep(title: "Hover Section 12", column: 1, rest: 1.0),
            HoverStep(title: "Notes", column: 1, rest: 1.5, optional: true),
            HoverStep(title: "Bibliography", column: 1, rest: 1.5, optional: true),
            HoverStep(title: "Notes", column: 0, rest: 1.5, optional: true),
            HoverStep(title: "Hover Section 12", column: 0, rest: 0),
            HoverStep(title: "Hover Section 06", column: 0, rest: 0),
            HoverStep(title: "Hover Section 01", column: 0, rest: 0),
            // Quick sweep over the bottom of the Selected column, no rest.
            HoverStep(title: "Hover Section 11", column: 1, rest: 0),
            HoverStep(title: "Hover Section 12", column: 1, rest: 0),
            HoverStep(title: "Notes", column: 1, rest: 0, optional: true),
            HoverStep(title: "Hover Section 12", column: 1, rest: 0),
            HoverStep(title: "Hover Section 11", column: 1, rest: 0)
        ]
        for step in plan where !hover(step, columns: columns) { return }

        XCTAssertTrue(hoveredNotes, "SETUP FAULT: the Notes row was never found in either column -- the seed no "
                      + "longer puts Notes at the bottom of the preview, so this test no longer exercises the freeze")
        assertResponsive(window, after: "the whole hover sequence")
        appMayBeHung = false
    }

    /// The user's whole path after the hover: hover the Selected-column row (its Replace button shows),
    /// right-click its title, choose Replace Current Section, click Restore. The input events and the window
    /// closing are timed (the freeze signal); lookups and database reads are not. The window must close,
    /// the edit must be gone, the original text and the footnote definition must be in the database, and
    /// the app must still answer a query.
    func testReplaceCurrentSectionAfterHoverCompletes() throws {
        guard let setup = prepareVersionHistory() else { return }
        let window = setup.window
        let columns = setup.columns
        let rowTitle = Self.sectionTitles[0]

        appMayBeHung = true   // from here a wedge is possible (hover, context menu, restore)
        if !hover(HoverStep(title: rowTitle, column: 1, rest: 0.5, expectReplaceButton: true), columns: columns) { return }

        // Right-click that row's title in the SELECTED column. Lookups carry no custom limit (XCTest's own
        // timeouts apply); only the input events are timed.
        guard let titleToClick = titleElement(rowTitle, in: columns[1]) else {
            return XCTFail("SETUP FAULT: \(rowTitle) vanished from Selected Version after hovering it")
        }
        guard timed("right-clicking \(rowTitle) in Selected Version", { titleToClick.rightClick() }) else { return }

        // Choose Replace Current Section from the context menu.
        let replaceItem = app.menuItems["Replace Current Section"]
        XCTAssertTrue(replaceItem.waitForExistence(timeout: 5), "Context menu should offer Replace Current Section")
        guard timed("choosing Replace Current Section", { replaceItem.click() }) else { return }

        // Confirm with Restore (the section picker would show instead if the original section were gone).
        let confirmButton = alertSurface(timeout: 5).buttons["version-history-restore-confirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5),
                      "Restore confirmation did not appear (section picker shown instead?)")
        guard timed("clicking Restore", { confirmButton.click() }) else { return }

        // The window closes by itself once the restore is done.
        var closed = false
        guard timed("waiting for Version History to close after Restore", {
            closed = window.waitForDisappearance(timeout: 15)
        }) else { return }
        XCTAssertTrue(closed, "Version History should close after the restore")

        // Database ground truth: edit replaced, original text back, footnote definition intact.
        let restoredLike = "markdownFragment LIKE '%Original hover body sentence%'"
        let footnoteLike = "markdownFragment LIKE '%Hover footnote one%'"
        let editedLike = "markdownFragment LIKE '%EDITED%'"
        // Not timed: slow persistence must not be reported as the hover freeze.
        let settled = poll(timeout: 15) {
            self.dbCountIfAvailable(editedLike) == 0
                && (self.dbCountIfAvailable(restoredLike) ?? 0) > 0
                && (self.dbCountIfAvailable(footnoteLike) ?? 0) > 0
        }
        XCTAssertEqual(dbCount(editedLike), 0, "The edited text should be replaced by the restore (settled=\(settled))")
        XCTAssertGreaterThan(dbCount(restoredLike), 0, "The original section text should be restored")
        XCTAssertGreaterThan(dbCount(footnoteLike), 0, "The footnote definition must survive the restore")

        // The app still answers a bounded query.
        var answered = false
        guard timed("final responsiveness check", limit: 30, {
            self.app.activateAndWaitForForeground()
            answered = self.app.staticTexts["status-bar-word-count"].waitForExistence(timeout: 15)
        }) else { return }
        XCTAssertTrue(answered, "The app should still answer queries after the restore")
        appMayBeHung = false
    }

    // MARK: - Scenario steps

    /// Seeds the 12-section document, launches, saves a version, edits section 1, opens Version History,
    /// selects the saved version and finds the two document columns. Nil once a failure was recorded.
    private func prepareVersionHistory() -> (window: XCUIElement, columns: [XCUIElement])? {
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seed())
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        launched = true
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 15), "Editor area should appear")
        // Readiness of the editor itself is proven by editBody (it needs the body leaf to render); this is
        // only a plain existence check that the status bar is present.
        XCTAssertTrue(app.staticTexts["status-bar-word-count"].waitForExistence(timeout: 15),
                      "Status bar should be present")

        saveVersion(named: Self.versionName)
        editBody()
        guard let window = openVersionHistoryAndSelectSavedVersion(),
              let columns = documentColumns(in: window) else { return nil }
        return (window, columns)
    }

    private func saveVersion(named versionName: String) {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let saveSurface = alertSurface(timeout: 10)
        let nameField = saveSurface.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Save Version alert should have a name field")
        nameField.click()
        nameField.typeText(versionName)
        let saveButton = saveSurface.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button should appear")
        saveButton.click()
    }

    /// Content-addressed click on section 1's body leaf, Cmd-Left, type; landing proven by a DB poll.
    private func editBody() {
        app.activateAndWaitForForeground()
        guard let bodyLeaf = app.editorStaticText(startingWith: Self.body, timeout: 45) else {
            return XCTFail("Body paragraph leaf not found in editor-area. Editor AX dump:\n\(app.editorStaticTextsDump())")
        }
        bodyLeaf.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        app.activateAndWaitForForeground()
        XCTAssertFalse(app.popovers.firstMatch.exists, "A popover opened after the body click -- wrong click target")
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeText("EDITED ") // e2e-lint: allow raw-typetext -- caret placed by a content-addressed click; landing proven by the DB poll below
        XCTAssertTrue(poll(timeout: 15) { (self.dbCountIfAvailable("markdownFragment LIKE '%EDITED%'") ?? 0) > 0 },
                      "Edit should reach the block table before opening Version History "
                      + "(last sqlite3 output: \"\(lastDBOutput)\")")
    }

    private func openVersionHistoryAndSelectSavedVersion() -> XCUIElement? {
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Version History window should appear")
        let name = Self.versionName
        // e2e-lint: allow statictext-firstmatch -- Version History window scope, no sidebar mirror
        let row = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Saved version row should appear")
        row.click()
        let first = Self.sectionTitles[0]
        let firstMatches = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", first, first))
        XCTAssertTrue(poll(timeout: 20) { firstMatches.count >= 2 },
                      "First section title should show in both Current and Selected columns")
        return window
    }

    /// The two document columns' ScrollViews (Current, Selected), left to right (the version list is
    /// narrower than 250pt).
    private func documentColumns(in window: XCUIElement) -> [XCUIElement]? {
        let all = window.scrollViews
        var wide: [XCUIElement] = []
        var frames: [String] = []
        for index in 0..<all.count {
            let candidate = all.element(boundBy: index)
            guard candidate.exists else { continue }
            frames.append("\(candidate.frame)")
            if candidate.frame.width > 250 { wide.append(candidate) }
        }
        wide.sort { $0.frame.minX < $1.frame.minX }
        guard wide.count >= 2 else {
            XCTFail("SETUP FAULT: expected two document-column scroll views in the Version History window; "
                    + "found \(wide.count) wide of \(frames.count): \(frames)")
            return nil
        }
        return Array(wide.suffix(2))
    }

    // MARK: - Hover helpers (input events and the final query are timed; accessibility lookups are not)

    /// Runs one XCUITest input event (hover, scroll, click) or the final responsiveness query; fails if it
    /// took longer than `limit`. On a wedged app XCUITest's wait-for-idle makes these calls block, so elapsed
    /// time is the freeze signal. Accessibility lookups (`titleElement`, frame reads) are deliberately NOT
    /// wrapped: a slow accessibility walk in the VM must not read as "stopped responding". Every call is
    /// recorded in `timings` / `longestTimed`, attached at teardown.
    private func timed(_ what: String, limit: TimeInterval = 20, _ action: () -> Void) -> Bool {
        let started = Date()
        action()
        let elapsed = Date().timeIntervalSince(started)
        timings.append(String(format: "%7.2fs  %@", elapsed, what))
        if elapsed > longestTimed.seconds { longestTimed = (what, elapsed) }
        guard elapsed <= limit else {
            stopped = true
            XCTFail("Version History stopped responding: \(what) took \(Int(elapsed))s (limit \(Int(limit))s) "
                    + "-- the t-65f85d38 hover freeze")
            return false
        }
        return true
    }

    private func titleElement(_ title: String, in column: XCUIElement) -> XCUIElement? {
        let matches = column.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
        guard matches.count > 0 else { return nil }
        let candidate = matches.element(boundBy: 0)
        return candidate.exists ? candidate : nil
    }

    /// Scrolls the column until `title` is inside its viewport; nil if not found after 40 steps or if a
    /// timed interaction failed (`stopped`). Negative deltaY scrolls down.
    private func reveal(_ title: String, column: Int, columns: [XCUIElement]) -> XCUIElement? {
        let scrollView = columns[column]
        let order = Self.orderedTitles.firstIndex(of: title) ?? 0
        let direction: CGFloat = order >= (lastOrder[column] ?? 0) ? -1 : 1
        for attempt in 0..<40 {
            // Accessibility lookups: no custom limit (XCTest's own timeouts apply).
            let columnFrame = scrollView.frame
            let found = titleElement(title, in: scrollView)
            let frame = found?.frame ?? .zero
            let delta: CGFloat
            if found != nil {
                if columnFrame.contains(frame) { return found }
                let needed = frame.minY - (columnFrame.minY + 40)
                delta = -max(-1500, min(1500, needed))
            } else {
                delta = (attempt < 20 ? direction : -direction) * 400
            }
            guard timed("scrolling column \(column) toward \(title)", {
                scrollView.scroll(byDeltaX: 0, deltaY: delta)
            }) else { return nil }
        }
        return nil
    }

    private func hover(_ step: HoverStep, columns: [XCUIElement]) -> Bool {
        guard let element = reveal(step.title, column: step.column, columns: columns) else {
            if stopped { return false }
            if step.optional {
                // e.g. no Bibliography row when the mock citation produced none -- recorded so a reader of the
                // report knows this path did not run.
                XCTContext.runActivity(named: "Skipped optional hover: \(step.title) (column \(step.column)) "
                                       + "\u{2014} row not present") { _ in }
                return true
            }
            XCTFail("SETUP FAULT: could not bring \(step.title) into view in column \(step.column) after 40 scroll steps")
            return false
        }
        guard timed("hovering \(step.title) in column \(step.column)", { element.hover() }) else { return false }
        lastOrder[step.column] = Self.orderedTitles.firstIndex(of: step.title) ?? 0
        if step.title == "Notes" { hoveredNotes = true }
        if step.expectReplaceButton {
            let shown = columns[step.column].buttons["Replace"].waitForExistence(timeout: 5)   // a lookup: untimed
            XCTAssertTrue(shown, "SETUP FAULT: hovering \(step.title) in Selected Version did not show its Replace "
                          + "button -- hover() is not reaching the row's onHover")
        }
        if step.rest > 0 { RunLoop.current.run(until: Date().addingTimeInterval(step.rest)) }
        return true
    }

    private func assertResponsive(_ window: XCUIElement, after what: String) {
        let header = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                             "Current Version", "Current Version"))
        var answered = false
        guard timed("final responsiveness check", limit: 30, {
            answered = header.element(boundBy: 0).waitForExistence(timeout: 15)
        }) else { return }
        XCTAssertTrue(answered, "Version History stopped answering accessibility queries after \(what)")
    }

    // MARK: - Fixture and utilities

    /// ~4k words: 12 level-1 sections of ~300 words; footnote refs in sections 1, 5 and 9 (definitions
    /// under a trailing Notes section) and the mock citation in section 7. Section 1 starts with `body`.
    static func seed() -> String {
        var parts: [String] = []
        for (offset, title) in sectionTitles.enumerated() {
            let number = offset + 1
            var paragraphs = (0..<3).map { prose(section: number, paragraph: $0, words: 100) }
            switch number {
            case 1: paragraphs[0] = "\(body) with a note[^1]. " + paragraphs[0]
            case 5: paragraphs[1] += " A second note follows here[^2]."
            case 7: paragraphs[2] += " The mock source agrees [@ffe2emockcitation2026]."
            case 9: paragraphs[1] += " A third note follows here[^3]."
            default: break
            }
            parts.append("# \(title)\n\n" + paragraphs.joined(separator: "\n\n"))
        }
        parts.append("# Notes\n\n[^1]: Hover footnote one.\n\n[^2]: Hover footnote two.\n\n[^3]: Hover footnote three.")
        return parts.joined(separator: "\n\n")
    }

    static func prose(section: Int, paragraph: Int, words count: Int) -> String {
        var sentences: [String] = []
        var produced = 0
        var cursor = section * 5 + paragraph * 3
        while produced < count {
            let length = min(11 + cursor % 4, count - produced)
            var parts: [String] = []
            for _ in 0..<length {
                parts.append(words[cursor % words.count])
                cursor += 3
            }
            parts[0] = parts[0].capitalized
            sentences.append(parts.joined(separator: " ") + ".")
            produced += length
        }
        return sentences.joined(separator: " ")
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return condition()
    }

    /// Row count for a WHERE clause; nil when sqlite3's output is not a number (e.g. a transient lock).
    /// Poll conditions use this and simply retry on nil.
    private func dbCountIfAvailable(_ whereClause: String) -> Int? {
        let out = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath,
                                       sql: "SELECT COUNT(*) FROM block WHERE \(whereClause);")
        lastDBOutput = out
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Same, but a missing number is a loud failure naming the fixture path and the raw output (returns -1,
    /// which makes the caller's own assertion fail too). Used for the final assertions, never inside polls.
    private func dbCount(_ whereClause: String) -> Int {
        guard let count = dbCountIfAvailable(whereClause) else {
            XCTFail("SETUP FAULT: could not read a row count from the fixture database "
                    + "(\(TestFixtureHelper.fixturePath)/content.sqlite) for WHERE \(whereClause); "
                    + "raw sqlite3 output: \"\(lastDBOutput)\"")
            return -1
        }
        return count
    }

    private func alertSurface(timeout: TimeInterval) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
            if app.dialogs.firstMatch.exists { return app.dialogs.firstMatch }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// Attaches the slowest timed interaction and the per-step timing list (success and failure alike).
    private func attachTimings() {
        let text = String(format: "Slowest timed interaction: %.2fs -- ", longestTimed.seconds) + longestTimed.what
            + "\nFreeze limit: 20s per interaction (30s for the final responsiveness check)\n\n"
            + (timings.isEmpty ? "(no timed interactions ran)" : timings.joined(separator: "\n"))
        let attachment = XCTAttachment(string: text)
        attachment.name = "version-history-hover interaction timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Best effort: a 3s stack sample of the (possibly hung) app; attaches whatever it gets.
    private func attachSample(name: String) {
        var text: String
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first {
            // A unique file per run (never a path an earlier run could have left behind).
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vh-hover-sample-\(UUID().uuidString).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(running.processIdentifier), "3", "-mayDie", "-file", out.path]
            do {
                try process.run(); process.waitUntilExit()
                text = (try? String(contentsOf: out, encoding: .utf8))
                    ?? "(sample wrote nothing; exit \(process.terminationStatus); path \(out.path))"
            } catch { text = "(sample failed to launch: \(error))" }
        } else { text = "(no running app with bundle id \(Self.bundleId))" }
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
