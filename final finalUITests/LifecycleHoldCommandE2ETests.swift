//
//  LifecycleHoldCommandE2ETests.swift
//  final finalUITests
//
//  t-eb07cd67: a project command pressed while another close or open is still saving is HELD, never refused, and runs when the
//  first one ends (the last one pressed wins). Before this task the second command got a "Try again in a moment" warning and was
//  thrown away. Each test drives the real app in the VM at the speed the UI driver can click, and asserts what a user would see:
//  the window, the text, the Outline cards, the notices, and what ended up in each project's database.
//
//  HOW THE SECOND COMMAND IS MADE TO ARRIVE DURING THE SAVE (no luck, no click speed): the app's test seam
//  `FF_UI_TESTING_LIFECYCLE_SAVE_HOLD_MS` (App/TestMode.swift, `TestMode.holdLifecycleSave`) keeps the FIRST close of a launch
//  waiting for `saveHoldMs` (10 s) before its save starts. The driver needs a few seconds to click File, Open Recent and a project
//  (first VM run, run-1794763391-65517: 4.2 s for Help > Getting Started and 5.8 s for Open Recent from Cmd-W to the held line in the
//  app's log, about three seconds of it the one-second polls of `waitForExistence`, which the menu helpers below no longer use), so
//  the second command lands inside that wait. The test does not trust that: it reads the app's own log afterwards
//  (`[LIFECYCLE-SAVE-HOLD]`, `held behind close`, `admitted`, with their time stamps) and fails with a TEST-SETUP message when the
//  command reached the app too late to have been held, or was held for under 2.5 s (the "Finishing the last change..." notice
//  needs more than 1 s of waiting, and the driver needs a second or two to see it).
//
//  MENUS (lesson of that run): a CLOSED menu keeps every item in the accessibility tree with an empty frame at the bottom left of the
//  screen (`{{0, 768}, {0, 0}}`), so `menuItems["..."].exists` is true whether or not the menu is open, and `waitForNonExistence` of a
//  clicked item can never succeed (it failed all three tests after 5 s although the app had already switched project). A menu item is
//  on screen when its frame is not empty (`waitUntilShowing`); after the click nothing is waited for: the click itself returns only
//  once the app is idle again, which is after the menu has closed and the command has run or been held.
//
//  THE THREE TESTS (each launches the app afresh, so each gets its own "first close"):
//    testCloseThenOpenRecentAtOnceOpensTheOtherProject
//      Project A is open and a unique word was just typed into it. Cmd-W, and straight away File > Open Recent > B. Ends with B open:
//      the window title, the text and the Outline cards are B's. A word typed into B afterwards is saved in B's database and not in
//      A's; the word typed into A is saved in A's. From Cmd-W until B is open no notice says "Couldn't", "Try again" or "wait" (nor
//      any stuck-save notice), "Finishing the last change..." shows once the wait passed a second and not before, and the app log
//      has no "a post site was missed" line (an unkeyed project post).
//    testCloseThenGettingStartedAtOnceEndsOnGettingStarted
//      The same with Help > Getting Started instead of Open Recent: ends with the Getting Started project showing, no warning.
//    testCloseThenOpenRecentThenCloseAgainEndsAtThePicker
//      Cmd-W, Open Recent > B, then Cmd-W again straight away: the last command pressed wins, so B is never opened and the app ends
//      at the project picker, with no warning. The app log says the held open was replaced by the later close.
//
//  PROJECTS: A and B are two copies of the committed fixture, each seeded with its own text (heading, section, two paragraphs) and
//  its own title, so the window title, the editor text, the sidebar cards and the Open Recent entry can each tell them apart. B is
//  the launch project and A is opened from Finder (`NSWorkspace.shared.open`, a switch: the hold does not apply to a switch), so
//  both are in File > Open Recent and A is the open project when the scenario starts. Titles carry a per-run suffix, so the Open
//  Recent entries cannot be confused with a leftover from an earlier test.
//
//  WAITS: every wait is a polled condition with a timeout. The only waiting the scenario owns is the app's own 10 s hold, and the
//  3 s look at the end of the third test that proves a project does NOT open (an absence cannot be waited for; the log line that
//  says the open was dropped is the primary proof, the look is the safety net).
//
//  VM ONLY: runs in the disposable VM through scripts/vmtest/vmtest, never on the host screen. Suggested run:
//    scripts/vmtest/vmtest run --scope "final finalUITests/LifecycleHoldCommandE2ETests" --detach
//
//  LOG LINES THIS CLASS DEPENDS ON (Services/LifecycleEntry.swift, App/TestMode.swift; the diagnostic log is forced on with
//  FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING): "[LIFECYCLE-SAVE-HOLD]", "[Lifecycle] <kind> held behind <kind>", "[Lifecycle] held
//  <kind> admitted", "[Lifecycle] held <kind> replaced by a later <kind>: the last one wins", "[Lifecycle] UNKEYED ... A post site
//  was missed", "[Lifecycle] <kind> cancelled (section operation)" and "(barrier refused)", "[Lifecycle] perform threw".
//

import AppKit
import XCTest

/// One of the two projects of a test: its package, the title the window and File > Open Recent show, and the texts only it holds.
private struct HoldProject {
    let path: String
    let title: String
    let heading: String
    let section: String
    let opening: String
    let closing: String
    /// A unique word typed into this project during the test.
    let word: String
}

final class LifecycleHoldCommandE2ETests: XCTestCase {
    var app: XCUIApplication!
    private var fixtureBPath: String?
    /// When the test pressed Cmd-W for the first time (zero of the notice timeline).
    private var closePressedAt: Date?
    /// When the last menu click of the scenario came back.
    private var commandClickedAt: Date?
    /// Every distinct notice text seen on screen, with the seconds since Cmd-W.
    private var notices: [(seconds: TimeInterval, text: String)] = []
    /// When the "Finishing the last change..." notice was first seen.
    private var firstFinishingSeen: Date?
    private var runNotes: [String] = []

    /// How long the first close of a launch holds before its save starts (the app's test seam).
    private static let saveHoldMs = 10000
    /// A command that waited less than this long cannot be shown to have waited past the notice's one-second delay.
    private static let shortestUsableWait: TimeInterval = 2.5
    private static let finishingPrefix = "Finishing the last change"
    private static let gettingStartedTitle = "Getting Started"
    /// Fragments no notice may contain (lowercased, straight apostrophes): the old refusal ("Couldn't ... Try again in a moment"),
    /// the word "wait", and the wording of the stuck-save notices (a save that gave up).
    private static let unwantedFragments = ["couldn't", "try again", "wait", "wasn't", "didn't finish"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        attachRunNotes()
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        if let fixtureBPath {
            try? FileManager.default.removeItem(atPath: fixtureBPath)
        }
    }

    // MARK: - 1. Cmd-W, then File > Open Recent > the other project

    func testCloseThenOpenRecentAtOnceOpensTheOtherProject() throws {
        let (projectA, projectB) = try makeTwoProjects()
        launchWithBothInRecents(a: projectA, b: projectB)
        typeNewParagraph(projectA.word, after: projectA.closing)

        // The scenario: Cmd-W, and straight away File > Open Recent > B.
        pressCloseProject()
        chooseOpenRecent(titled: projectB.title)

        // From here until B is open, every poll looks for a notice with a forbidden word, and for an alert.
        let opened = observeNotices(timeout: 60) {
            windowTitled(projectB.title).exists && app.editorContainsText(projectB.opening, timeout: 0.3)
        }
        let readAt = Date()
        attachEvidenceScreenshot(app.screenshot(), name: "after-open-recent-b")
        let log = Self.scenarioLog()
        XCTAssertTrue(opened, """
            B never opened within 60 s of Cmd-W + Open Recent (window title "\(projectB.title)" and B's text). Notices seen: \
            \(noticeSummary()). Lifecycle lines:\n\(Self.lifecycleExcerpt(log))
            """)

        // What the window shows: B's title, B's text and B's Outline cards, and none of A's.
        XCTAssertFalse(windowTitled(projectA.title).exists, "A's title \"\(projectA.title)\" is still on a window after B opened")
        XCTAssertFalse(app.editorContainsText(projectA.opening, timeout: 1), "A's text is still in the editor after B opened")
        XCTAssertFalse(app.editorContainsText(projectA.heading, timeout: 0.5), "A's heading is still in the editor after B opened")
        XCTAssertTrue(sidebarCard(projectB.heading).waitForExistence(timeout: 15), "B's heading card is missing from the Outline")
        XCTAssertTrue(sidebarCard(projectB.section).waitForExistence(timeout: 15), "B's section card is missing from the Outline")
        XCTAssertFalse(sidebarCard(projectA.heading).exists, "A's heading card is still in the Outline after B opened")
        XCTAssertFalse(sidebarCard(projectA.section).exists, "A's section card is still in the Outline after B opened")

        // The command was HELD during the first close's hold, and the notice came after a second, not before.
        guard let heldAt = heldDuringTheHold(log, requested: "projectSwitch", what: "Open Recent") else { return }
        guard let admittedAt = Self.logTime(of: "[Lifecycle] held projectSwitch admitted", in: log) else {
            XCTFail("The held Open Recent was never admitted (no \"held projectSwitch admitted\" line).\n\(Self.lifecycleExcerpt(log))")
            return
        }
        assertFinishingNoticeAppearedAfterOneSecond(heldAt: heldAt, endedAt: admittedAt, what: "Open Recent")
        assertNoMissedPostOrGiveUpLines(in: log)
        runNotes.append("B was open \(Self.seconds(readAt, since: closePressedAt)) s after Cmd-W")

        // A word typed into B afterwards, then the close (no hold now: the hold is for the first close only) to save it.
        typeNewParagraph(projectB.word, after: projectB.closing)
        pressCloseProject()
        let atPicker = observeNotices(timeout: 40) { app.groups["project-picker"].exists }
        XCTAssertTrue(atPicker, "The project picker never appeared after the last Cmd-W. Notices seen: \(noticeSummary())")

        // The databases: each word is in its own project and nowhere else.
        XCTAssertTrue(
            pollUntil(timeout: 20) { blockCount(containing: projectA.word, in: projectA.path) >= 1 },
            "The word typed into A before Cmd-W is not in A's database (the close should have saved it)"
        )
        XCTAssertTrue(
            pollUntil(timeout: 20) { blockCount(containing: projectB.word, in: projectB.path) >= 1 },
            "The word typed into B after the open is not in B's database"
        )
        XCTAssertEqual(blockCount(containing: projectB.word, in: projectA.path), 0, "B's word was written into A's database")
        XCTAssertEqual(blockCount(containing: projectA.word, in: projectB.path), 0, "A's word was written into B's database")
        assertNoMissedPostOrGiveUpLines(in: Self.scenarioLog())
    }

    // MARK: - 2. Cmd-W, then Help > Getting Started

    func testCloseThenGettingStartedAtOnceEndsOnGettingStarted() throws {
        let projectA = makeProject(at: TestFixtureHelper.fixturePath, name: "Alpha", suffix: shortUUID())
        configureLaunch()
        app.launchForTesting(fixturePath: projectA.path)
        waitForProjectShown(projectA)
        UnifiedUndoE2ETests.recordDiagnosticLogStartOffsets()
        typeNewParagraph(projectA.word, after: projectA.closing)

        pressCloseProject()
        chooseGettingStarted()

        let opened = observeNotices(timeout: 60) { windowTitled(Self.gettingStartedTitle).exists && app.editorArea.exists }
        attachEvidenceScreenshot(app.screenshot(), name: "after-getting-started")
        let log = Self.scenarioLog()
        XCTAssertTrue(opened, """
            Getting Started never showed within 60 s of Cmd-W + Help > Getting Started (window title "\(Self.gettingStartedTitle)" \
            and the editor). Notices seen: \(noticeSummary()). Lifecycle lines:\n\(Self.lifecycleExcerpt(log))
            """)
        XCTAssertFalse(app.groups["project-picker"].exists, "The project picker is showing instead of Getting Started")
        XCTAssertFalse(windowTitled(projectA.title).exists, "A's title is still on a window after Getting Started opened")

        guard let heldAt = heldDuringTheHold(log, requested: "projectSwitch", what: "Help > Getting Started") else { return }
        guard let admittedAt = Self.logTime(of: "[Lifecycle] held projectSwitch admitted", in: log) else {
            XCTFail("The held Getting Started was never admitted (no \"held projectSwitch admitted\" line).\n\(Self.lifecycleExcerpt(log))")
            return
        }
        assertFinishingNoticeAppearedAfterOneSecond(heldAt: heldAt, endedAt: admittedAt, what: "Help > Getting Started")
        assertNoMissedPostOrGiveUpLines(in: log)

        // The close that came first saved A's last typing before Getting Started took over.
        XCTAssertTrue(
            pollUntil(timeout: 20) { blockCount(containing: projectA.word, in: projectA.path) >= 1 },
            "The word typed into A before Cmd-W is not in A's database"
        )
    }

    // MARK: - 3. Cmd-W, Open Recent, Cmd-W again: the last one wins

    func testCloseThenOpenRecentThenCloseAgainEndsAtThePicker() throws {
        let (projectA, projectB) = try makeTwoProjects()
        launchWithBothInRecents(a: projectA, b: projectB)
        typeNewParagraph(projectA.word, after: projectA.closing)

        pressCloseProject()
        chooseOpenRecent(titled: projectB.title)
        pressCloseProject()

        // The first close ends, the held Cmd-W (which replaced the held open) is admitted, and the app is at the picker.
        let ended = observeNotices(timeout: 60) {
            app.groups["project-picker"].exists && Self.scenarioLog().contains("[Lifecycle] held close admitted")
        }
        attachEvidenceScreenshot(app.screenshot(), name: "after-close-open-recent-close")
        let log = Self.scenarioLog()
        XCTAssertTrue(ended, """
            The app did not end at the picker with the held Cmd-W admitted within 60 s. Notices seen: \(noticeSummary()). \
            Lifecycle lines:\n\(Self.lifecycleExcerpt(log))
            """)

        // B must never open: look for it for a few seconds (the open was dropped, so nothing should come).
        let openedAnyway = observeNotices(timeout: 3) { windowTitled(projectB.title).exists || app.editorArea.exists }
        attachEvidenceScreenshot(app.screenshot(), name: "still-at-the-picker")
        XCTAssertFalse(openedAnyway, "B (or any editor) opened although a later Cmd-W replaced the held Open Recent")
        XCTAssertTrue(app.groups["project-picker"].exists, "The app is not at the project picker")

        // The log: the open was held behind the close, then replaced by the later close, and never admitted.
        guard heldDuringTheHold(log, requested: "projectSwitch", what: "Open Recent") != nil else { return }
        XCTAssertTrue(
            log.contains("[Lifecycle] held projectSwitch replaced by a later close: the last one wins"),
            "TEST-SETUP: the second Cmd-W did not arrive while the open was still held (it was not the held request that replaced it). "
                + "Lifecycle lines:\n\(Self.lifecycleExcerpt(log))"
        )
        XCTAssertFalse(log.contains("[Lifecycle] held projectSwitch admitted"), "The held Open Recent was admitted although it was replaced")
        assertNoMissedPostOrGiveUpLines(in: log)

        // The first close saved A's typing; nothing was written into B.
        XCTAssertTrue(
            pollUntil(timeout: 20) { blockCount(containing: projectA.word, in: projectA.path) >= 1 },
            "The word typed into A before Cmd-W is not in A's database"
        )
        XCTAssertEqual(blockCount(containing: projectA.word, in: projectB.path), 0, "A's word was written into B's database")
    }
}

// MARK: - Setup, driving and reading helpers

extension LifecycleHoldCommandE2ETests {

    /// Two projects: A is the fixture the test case copied, B a second copy. Each gets its own text and title.
    fileprivate func makeTwoProjects() throws -> (HoldProject, HoldProject) {
        let suffix = shortUUID()
        let bPath = NSTemporaryDirectory() + "ff-test-fixture-B-\(UUID().uuidString).ff"
        let source = try XCTUnwrap(
            Bundle(for: type(of: self)).resourceURL?.appendingPathComponent("Fixtures/test-fixture.ff"),
            "Test fixture not found in UI test bundle"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Test fixture not found at \(source.path)")
        try? FileManager.default.removeItem(atPath: bPath)
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: bPath))
        fixtureBPath = bPath
        let projectA = makeProject(at: TestFixtureHelper.fixturePath, name: "Alpha", suffix: suffix)
        let projectB = makeProject(at: bPath, name: "Bravo", suffix: suffix)
        return (projectA, projectB)
    }

    /// Seeds the package (before the app has opened it): the markdown, with its block rows cleared so the app parses it, and the title.
    fileprivate func makeProject(at path: String, name: String, suffix: String) -> HoldProject {
        let project = HoldProject(
            path: path,
            title: "Hold \(name) \(suffix)",
            heading: "\(name) Chapter",
            section: "\(name) Section One",
            opening: "\(name) opening paragraph for the hold test.",
            closing: "\(name) closing paragraph for the hold test.",
            word: "Hold\(name)\(suffix)Word"
        )
        let markdown = "# \(project.heading)\n\n\(project.opening)\n\n## \(project.section)\n\n\(project.closing)\n"
        FixtureDatabase.seedMarkdown(fixturePath: path, markdown: markdown)
        FixtureDatabase.write(fixturePath: path, sql: "UPDATE project SET title = '\(FixtureDatabase.escape(project.title))';")
        return project
    }

    /// The launch environment of every test: the hold seam, the diagnostic log forced on, recents allowed under the temp directory.
    fileprivate func configureLaunch() {
        app.launchEnvironment["FF_UI_TESTING_ALLOW_SCRATCH_RECENT_PROJECTS"] = "1"
        app.launchEnvironment["FF_UI_TESTING_LIFECYCLE_SAVE_HOLD_MS"] = String(Self.saveHoldMs)
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
        // One typed word per project; macOS's inline prediction can swallow keystrokes (e2e-verify skill, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
    }

    /// B is the launch project and A is opened from Finder (a switch, so the hold does not apply to it): both are in File > Open Recent,
    /// A is the open project, and the app log is read from here on.
    fileprivate func launchWithBothInRecents(a projectA: HoldProject, b projectB: HoldProject) {
        configureLaunch()
        app.launchForTesting(fixturePath: projectB.path)
        waitForProjectShown(projectB)
        UnifiedUndoE2ETests.recordDiagnosticLogStartOffsets()
        app.activateAndWaitForForeground()
        NSWorkspace.shared.open(URL(fileURLWithPath: projectA.path))
        waitForProjectShown(projectA)
    }

    /// The project's title is on the window and its closing paragraph is in the editor.
    fileprivate func waitForProjectShown(_ project: HoldProject) {
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 30), "The editor area never appeared for \"\(project.title)\"")
        XCTAssertTrue(windowTitled(project.title).waitForExistence(timeout: 30), "No window titled \"\(project.title)\" appeared")
        XCTAssertTrue(
            app.editorContainsText(project.closing, timeout: 30),
            "\"\(project.title)\"'s text (\"\(project.closing)\") never appeared in the editor"
        )
    }

    /// A new paragraph at the end of the open project holding `word`: click its last paragraph, Cmd-Down, Return, type.
    fileprivate func typeNewParagraph(_ word: String, after paragraph: String) {
        guard let leaf = app.editorStaticText(startingWith: paragraph, timeout: 30) else {
            XCTFail("The paragraph \"\(paragraph)\" was not found in the editor, so \"\(word)\" could not be typed after it.")
            return
        }
        app.activateAndWaitForForeground()
        app.moveCaretToDocumentEnd(clickingInto: leaf)
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded(word)
    }

    fileprivate func windowTitled(_ title: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// A card of the Outline sidebar by its exact title, scoped to the sidebar's ScrollView (never the editor's heading mirror).
    fileprivate func sidebarCard(_ title: String) -> XCUIElement {
        app.groups["outline-sidebar"].scrollViews.firstMatch.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    /// Cmd-W (Close Project). The first press starts the clock the notice timeline is measured from.
    fileprivate func pressCloseProject() {
        if closePressedAt == nil { closePressedAt = Date() }
        // e2e-lint: allow cmd-w -- closing the project IS the scenario (Cmd-W is the app's Close Project).
        app.typeKey("w", modifierFlags: .command)
    }

    /// Waits, polling every 0.05 s, until `element` is on screen: its frame (from one snapshot) is not empty. `exists` cannot say this
    /// for a menu item: a closed menu keeps its items in the accessibility tree with an empty frame (see the file header), and
    /// `waitForExistence` always spends its one-second poll first, which is time the held command does not have.
    fileprivate func waitUntilShowing(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let frame = (try? element.snapshot())?.frame, frame.width > 0, frame.height > 0 { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while Date() < deadline
        return false
    }

    /// File > Open Recent > the entry titled `title`. No activate and no fixed waits: the next command has to arrive during the hold.
    /// Nothing is waited for after the last click (see the file header: a clicked menu item never "stops existing").
    fileprivate func chooseOpenRecent(titled title: String) {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(waitUntilShowing(fileMenu), "The File menu bar item is not on screen")
        fileMenu.click()
        let openRecent = app.menuItems["Open Recent"]
        XCTAssertTrue(waitUntilShowing(openRecent), "File > Open Recent did not show after the File menu was clicked")
        openRecent.click()
        let entry = app.menuItems[title]
        XCTAssertTrue(
            waitUntilShowing(entry),
            "File > Open Recent does not show \"\(title)\" (a project opened earlier in this launch)"
        )
        entry.click()
        noteClickReturned("File > Open Recent > \"\(title)\"")
    }

    /// Help > Getting Started.
    fileprivate func chooseGettingStarted() {
        let helpMenu = app.menuBars.menuBarItems["Help"]
        XCTAssertTrue(waitUntilShowing(helpMenu), "The Help menu bar item is not on screen")
        helpMenu.click()
        let item = app.menuItems[Self.gettingStartedTitle]
        XCTAssertTrue(waitUntilShowing(item), "Help > Getting Started did not show after the Help menu was clicked")
        item.click()
        noteClickReturned("Help > Getting Started")
    }

    private func noteClickReturned(_ what: String) {
        commandClickedAt = Date()
        runNotes.append("\(what) clicked \(Self.seconds(commandClickedAt, since: closePressedAt)) s after Cmd-W")
    }

    /// Polls every 0.15 s until `done()` or the timeout. Each pass reads the notice on screen and looks for an alert; a notice with an
    /// unwanted fragment, or an alert, fails the test on the spot (screenshot first). Returns whether `done()` became true.
    @discardableResult
    fileprivate func observeNotices(timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            recordNotice()
            failOnAlert()
            if done() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        } while Date() < deadline
        return false
    }

    /// The message of the toast on screen right now, from one accessibility snapshot (`toast-message`): a toast that goes away between
    /// an existence check and a property read cannot fail the test.
    fileprivate func toastMessage() -> String? {
        guard let snapshot = try? app.staticTexts["toast-message"].snapshot() else { return nil }
        let value = (snapshot.value as? String) ?? ""
        return value.isEmpty ? snapshot.label : value
    }

    private func recordNotice() {
        guard let text = toastMessage(), !text.isEmpty else { return }
        if notices.last?.text != text {
            notices.append((Date().timeIntervalSince(closePressedAt ?? Date()), text))
        }
        if text.hasPrefix(Self.finishingPrefix) {
            if firstFinishingSeen == nil {
                firstFinishingSeen = Date()
                attachEvidenceScreenshot(app.screenshot(), name: "finishing-notice-while-held")
            }
            return
        }
        let plain = text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        if let fragment = Self.unwantedFragments.first(where: { plain.contains($0) }) {
            attachEvidenceScreenshot(app.screenshot(), name: "unwanted-notice")
            XCTFail("A notice with \"\(fragment)\" came up \(Self.seconds(Date(), since: closePressedAt)) s after Cmd-W: \"\(text)\"")
        }
    }

    private func failOnAlert() {
        guard app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists else { return }
        attachEvidenceScreenshot(app.screenshot(), name: "unexpected-alert")
        XCTFail("An alert or sheet came up after Cmd-W (the project command should simply have run). Notices seen: \(noticeSummary())")
    }

    fileprivate func noticeSummary() -> String {
        notices.isEmpty ? "none" : notices.map { "\"\($0.text)\" at \(String(format: "%.1f", $0.seconds)) s" }.joined(separator: ", ")
    }

    /// Polls `condition` every 0.25 s for at most `timeout` seconds.
    fileprivate func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return condition()
    }

    /// How many block rows of the package at `path` hold `word` (-1 when the read printed nothing usable).
    fileprivate func blockCount(containing word: String, in path: String) -> Int {
        let sql = "SELECT count(*) FROM block WHERE markdownFragment LIKE '%\(FixtureDatabase.escape(word))%';"
        let raw = FixtureDatabase.read(fixturePath: path, sql: sql)
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}

// MARK: - The app's log: what proves the command was held

extension LifecycleHoldCommandE2ETests {

    private static let stampParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The app's diagnostic log since `recordDiagnosticLogStartOffsets()` (the helpers of `UnifiedUndoE2ETests`).
    fileprivate static func lifecycleLog() -> String {
        UnifiedUndoE2ETests.currentDiagnosticLogContents()
    }

    /// The log from the first close's hold on, which is the Cmd-W the scenario starts with: what the setup's own opens logged earlier
    /// (a Finder open can log a held or duplicate command of its own) is left out, so every marker below belongs to the scenario.
    fileprivate static func scenarioLog() -> String {
        let log = lifecycleLog()
        guard let hold = log.range(of: "[LIFECYCLE-SAVE-HOLD]") else { return log }
        let lineStart = log[..<hold.lowerBound].lastIndex(of: "\n").map { log.index(after: $0) } ?? log.startIndex
        return String(log[lineStart...])
    }

    /// The time stamp (the start of the line) of the first log line containing `marker`.
    fileprivate static func logTime(of marker: String, in log: String) -> Date? {
        guard let line = log.split(separator: "\n").first(where: { $0.contains(marker) }) else { return nil }
        return stampParser.date(from: String(line.prefix(while: { $0 != " " })))
    }

    /// The lifecycle lines of the log (the last 80), for a failure message and the run notes.
    fileprivate static func lifecycleExcerpt(_ log: String) -> String {
        let markers = ["[Lifecycle]", "LIFECYCLE-SAVE-HOLD", "[ProjectCommands]", "[FinalFinalApp]"]
        let lines = log.split(separator: "\n").filter { line in markers.contains { line.contains($0) } }
        return lines.suffix(80).joined(separator: "\n")
    }

    /// `later` minus `earlier`, in seconds with one decimal ("?" when either is missing).
    fileprivate static func seconds(_ later: Date?, since earlier: Date?) -> String {
        guard let later, let earlier else { return "?" }
        return String(format: "%.1f", later.timeIntervalSince(earlier))
    }

    /// The log proves the first close held (the seam ran) and that the second command was HELD behind it: returns when the command was
    /// held. Fails with a TEST-SETUP message when the command reached the app too late to have been held.
    fileprivate func heldDuringTheHold(_ log: String, requested: String, what: String) -> Date? {
        guard let holdAt = Self.logTime(of: "[LIFECYCLE-SAVE-HOLD]", in: log) else {
            XCTFail("The app never wrote its [LIFECYCLE-SAVE-HOLD] line: the test seam did not reach the first close.\n\(Self.lifecycleExcerpt(log))")
            return nil
        }
        guard let heldAt = Self.logTime(of: "[Lifecycle] \(requested) held behind close", in: log) else {
            XCTFail("""
                TEST-SETUP: \(what) was not held behind the first close: the command reached the app after the close had finished \
                (Cmd-W to menu click: \(Self.seconds(commandClickedAt, since: closePressedAt)) s; the hold is \(Self.saveHoldMs) ms). \
                Lifecycle lines:\n\(Self.lifecycleExcerpt(log))
                """)
            return nil
        }
        let holdSeconds = Self.seconds(holdAt, since: closePressedAt)
        let heldSeconds = Self.seconds(heldAt, since: closePressedAt)
        runNotes.append("hold began \(holdSeconds) s and \(what) was held \(heldSeconds) s after Cmd-W")
        return heldAt
    }

    /// "Finishing the last change..." shows once the command has waited more than a second, and not before. The command must have
    /// waited long enough for the driver to see it; otherwise the run says so (TEST-SETUP) instead of passing without proof.
    fileprivate func assertFinishingNoticeAppearedAfterOneSecond(heldAt: Date, endedAt: Date, what: String) {
        let waited = endedAt.timeIntervalSince(heldAt)
        runNotes.append("\(what) waited \(String(format: "%.1f", waited)) s before it ran")
        guard waited >= Self.shortestUsableWait else {
            XCTFail("""
                TEST-SETUP: \(what) waited only \(String(format: "%.1f", waited)) s (needs at least \(Self.shortestUsableWait) s to show the \
                1 s notice and let the driver see it): the command reached the app too close to the end of the hold. Cmd-W to menu click: \
                \(Self.seconds(commandClickedAt, since: closePressedAt)) s; hold \(Self.saveHoldMs) ms.
                """)
            return
        }
        guard let seen = firstFinishingSeen else {
            XCTFail("""
                "Finishing the last change\u{2026}" never showed although \(what) waited \(String(format: "%.1f", waited)) s. \
                Notices seen: \(noticeSummary())
                """)
            return
        }
        let afterHeld = seen.timeIntervalSince(heldAt)
        XCTAssertGreaterThanOrEqual(
            afterHeld, 0.7,
            """
            "Finishing the last change\u{2026}" was on screen only \(String(format: "%.2f", afterHeld)) s after \(what) was held: \
            nothing may show in the first second
            """
        )
    }

    /// No unkeyed project post ("a post site was missed") and no give-up of the close or open (a stuck save, a throwing perform).
    fileprivate func assertNoMissedPostOrGiveUpLines(in log: String) {
        let forbidden = [
            "post site was missed", "UNKEYED", "cancelled (section operation)", "cancelled (barrier refused)", "perform threw"
        ]
        for marker in forbidden {
            XCTAssertFalse(log.contains(marker), "The app log has a \"\(marker)\" line.\n\(Self.lifecycleExcerpt(log))")
        }
    }

    /// The run notes and the lifecycle log lines, attached to the result (also when the test failed).
    fileprivate func attachRunNotes() {
        let timeline = notices.map { "\(String(format: "%6.2f", $0.seconds)) s  \($0.text)" }.joined(separator: "\n")
        let text = """
            RUN NOTES
            \(runNotes.joined(separator: "\n"))

            NOTICES SEEN (seconds after the first Cmd-W)
            \(timeline.isEmpty ? "(none)" : timeline)

            LIFECYCLE LOG LINES
            \(Self.lifecycleExcerpt(Self.lifecycleLog()))
            """
        let attachment = XCTAttachment(string: text)
        attachment.name = "lifecycle-hold-run-notes.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
