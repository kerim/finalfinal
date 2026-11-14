//
//  ModeSwitchKeepsScrollE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression test: the switch from Markdown back to Rich Text keeps the editor's scroll position (UX contract section 2:
//  "The editor mode switch ... never loses caret position or scroll position").
//
//  The bug it pins: the carried switch to Rich Text (EditorViewState+SwitchTransitionRichText.swift, Phase 5 job A10) puts the caret
//  (or, when the caret was off screen, the scroll position) into the incoming Rich Text page while that page is still DETACHED from the
//  window. A detached page has no layout, so the caret's scroll-into-view could not scroll anything: the page came up at the top of the
//  document, with the caret in the right place but out of sight. The Rich Text to Markdown direction was fine.
//
//  Why this is a permanent UI test and not a unit or vitest one: the bug is the order of events between the page flip and the scroll in
//  the running app (a detached WKWebView has no layout; vitest's jsdom has none either way). Only the real window shows where the page
//  ends up.
//
//  What a person does here, and what each test proves:
//    1. testCaretOnScreenStaysOnScreenThroughMarkdownAndBack: a document of 90 one-line paragraphs; click into the first one, Cmd-Down
//       (caret and view go to the end of the document), Cmd-/ to Markdown, Cmd-/ back to Rich Text. The last paragraph (where the caret
//       is) must still be on screen, and the first one must not (the page did not jump to the top).
//    2. testScrolledAwayViewStaysWhereItWasThroughMarkdownAndBack: the same, but after Cmd-Down the user wheel-scrolls up into the middle
//       of the document, so the caret is OFF screen (the app then restores by scroll position, not by caret). The paragraph in the middle
//       of the view before the round trip must still be on screen after it, and neither end of the document may be.
//
//  How it reads the page (the recorded e2e-verify patterns): the editor's accessibility subtree from ONE snapshot() walked in-process;
//  a paragraph counts as on screen when its frame intersects the editor area's frame (an off-screen paragraph stays in the tree with a
//  frame outside it; this app exposes no scrollY to XCUITest). Every wait is a poll with a bound that returns the moment the condition
//  holds; the final reading must hold on three reads in a row so a read of the outgoing page cannot pass it by chance.
//

import XCTest

final class ModeSwitchKeepsScrollE2ETests: XCTestCase {
    var app: XCUIApplication!

    static let paragraphCount = 90
    static let paragraphPrefix = "Scroll paragraph "

    static func paragraphText(_ number: Int) -> String {
        String(format: "Scroll paragraph %03d. The quick brown fox jumps over the lazy dog.", number)
    }

    /// The first line is a heading (a heading-less seed defeats the readiness checks); the paragraphs follow in one chapter.
    static let seedMarkdown: String = {
        var lines = ["# Scroll Test Document", "", "## Long Chapter", ""]
        for number in 1...paragraphCount {
            lines.append(paragraphText(number))
            lines.append("")
        }
        return lines.dropLast().joined(separator: "\n")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // macOS inline predictive text can swallow keystrokes (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - The tests

    func testCaretOnScreenStaysOnScreenThroughMarkdownAndBack() throws {
        try waitForSeededDocument()
        try placeCaretAtDocumentEnd()
        let before = try requireReading(
            "TEST-SETUP: after Cmd-Down the last paragraph must be on screen and the first not (the caret is at the end of the document)"
        ) { $0.contains(Self.paragraphCount) && !$0.contains(1) }
        attachText(before.dump, name: "before-round-trip-visible-paragraphs")

        try switchMode(to: "Markdown")
        try switchMode(to: "Rich Text")

        let after = settledReading { $0.contains(Self.paragraphCount) && !$0.contains(1) }
        attachEvidenceScreenshot(app.screenshot(), name: "after-round-trip")
        attachText(after.dump, name: "after-round-trip-visible-paragraphs")
        XCTAssertTrue(
            after.visible.contains(Self.paragraphCount) && !after.visible.contains(1),
            "Back in Rich Text the page is not where the caret is: the last paragraph (the caret's) must be on screen and the first not. "
                + "Before the round trip the view showed \(before.summary); after it, \(after.summary)."
        )
    }

    func testScrolledAwayViewStaysWhereItWasThroughMarkdownAndBack() throws {
        try waitForSeededDocument()
        try placeCaretAtDocumentEnd()
        try scrollUpIntoTheMiddleOfTheDocument()
        let before = try requireReading(
            "TEST-SETUP: after the wheel scroll the caret's paragraph (the last) and the first must both be off screen"
        ) { !$0.contains(Self.paragraphCount) && !$0.contains(1) && !$0.isEmpty }
        let anchor = before.middle
        attachText(before.dump, name: "before-round-trip-visible-paragraphs")

        try switchMode(to: "Markdown")
        try switchMode(to: "Rich Text")

        let after = settledReading { $0.contains(anchor) && !$0.contains(Self.paragraphCount) && !$0.contains(1) }
        attachEvidenceScreenshot(app.screenshot(), name: "after-round-trip")
        attachText(after.dump, name: "after-round-trip-visible-paragraphs")
        XCTAssertTrue(
            after.visible.contains(anchor),
            "Back in Rich Text the view is not where it was: paragraph \(anchor) (the middle of the view before the round trip) must still "
                + "be on screen. Before the round trip the view showed \(before.summary); after it, \(after.summary)."
        )
        XCTAssertFalse(after.visible.contains(1), "Back in Rich Text the view jumped to the top of the document (\(after.summary))")
        XCTAssertFalse(
            after.visible.contains(Self.paragraphCount),
            "Back in Rich Text the view jumped to the caret at the end of the document (\(after.summary)); the user had scrolled away"
        )
    }
}

// MARK: - Steps that drive the app

private struct StopTest: Error {}

extension ModeSwitchKeepsScrollE2ETests {
    func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw StopTest()
    }

    /// Polls `probe` every `pollInterval` until it returns true or `timeout` passes; returns the last answer.
    func pollUntilTrue(timeout: TimeInterval, pollInterval: TimeInterval = 0.3, _ probe: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if probe() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return probe()
    }

    func waitForSeededDocument() throws {
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        try require(
            app.editorStaticText(startingWith: Self.paragraphText(1), timeout: 30) != nil,
            "TEST-SETUP: the seeded first paragraph never appeared in the editor"
        )
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForLabel("== 'Rich Text'", timeout: 10), "TEST-SETUP: the document must open in Rich Text mode")
    }

    /// Click into the first paragraph (on screen at the top), then Cmd-Down: the caret goes to the end of the document and the page
    /// scrolls there with it.
    func placeCaretAtDocumentEnd() throws {
        let first = app.editorStaticText(startingWith: Self.paragraphText(1), timeout: 15)
        try require(first != nil, "TEST-SETUP: the first paragraph is not in the editor")
        app.activateAndWaitForForeground()
        if let first { app.moveCaretToDocumentEnd(clickingInto: first) }
    }

    /// Mouse-wheel up by about 25 paragraphs so the caret (at the end) is far off screen. The wheel's sign is the proven one
    /// (`bringParagraphIntoView`: a positive delta moves the page toward its top); the opposite sign is the fallback.
    func scrollUpIntoTheMiddleOfTheDocument() throws {
        for delta: CGFloat in [1500, -1500] {
            app.editorArea.scroll(byDeltaX: 0, deltaY: delta)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
            if let reading = readVisibleParagraphs(), !reading.contains(Self.paragraphCount) { return }
        }
        try require(false, "TEST-SETUP: the wheel scroll did not move the page away from the end of the document")
    }

    /// Cmd-/ until the editor-mode button reports `target` ("Markdown" or "Rich Text"). The keystroke can drop when the app is not
    /// reliably in the foreground at the instant it is sent (proven pattern in EditorModeSwitchUndoE2ETests): re-activate and retry.
    func switchMode(to target: String) throws {
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button did not appear")
        var registered = false
        for _ in 1...5 {
            if editorMode.label == target {
                registered = true
                break
            }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== '\(target)'", timeout: 5) {
                registered = true
                break
            }
        }
        try require(registered, "Cmd-/ did not switch the editor to \(target) (the mode button still reads \"\(editorMode.label)\")")
    }
}

// MARK: - Reading the page

extension ModeSwitchKeepsScrollE2ETests {
    /// The paragraph numbers on screen, in document order, and a dump of what was seen.
    struct Reading {
        var visible: [Int]
        var dump: String

        func contains(_ number: Int) -> Bool { visible.contains(number) }
        var isEmpty: Bool { visible.isEmpty }

        /// The visible paragraph in the middle of the list: the one that stays on screen if the view moves by a few lines either way.
        var middle: Int { visible.isEmpty ? 0 : visible[visible.count / 2] }

        var summary: String {
            guard let first = visible.first, let last = visible.last else { return "no paragraph" }
            return "paragraphs \(first) to \(last)"
        }
    }

    /// The paragraph numbers whose frame intersects the editor area's frame, from ONE snapshot (a failed snapshot is retried), or nil.
    func readVisibleParagraphs() -> Reading? {
        for attempt in 1...4 {
            do {
                let snapshot = try app.editorArea.snapshot()
                return Self.reading(from: snapshot)
            } catch {
                print("[ModeSwitchKeepsScroll] snapshot() of editor-area failed (attempt \(attempt)): \(error)")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            }
        }
        return nil
    }

    static func reading(from snapshot: XCUIElementSnapshot) -> Reading {
        let editor = snapshot.frame
        var visible: [Int] = []
        var lines = ["editor frame \(XCUIApplication.describeFrame(editor))"]
        func walk(_ node: XCUIElementSnapshot) {
            for child in node.children {
                if child.elementType == .staticText, let value = child.value as? String, value.hasPrefix(paragraphPrefix) {
                    let digits = value.dropFirst(paragraphPrefix.count).prefix(3)
                    if let number = Int(digits) {
                        let onScreen = child.frame.intersects(editor)
                        if onScreen { visible.append(number) }
                        lines.append("paragraph \(number) \(XCUIApplication.describeFrame(child.frame)) on screen: \(onScreen)")
                    }
                }
                walk(child)
            }
        }
        walk(snapshot)
        return Reading(visible: visible.sorted(), dump: lines.joined(separator: "\n"))
    }

    /// Polls until a reading satisfies `condition` or 20 s pass; returns the last reading, which the caller asserts on.
    func waitForReading(timeout: TimeInterval = 20, _ condition: ([Int]) -> Bool) -> Reading {
        var last = Reading(visible: [], dump: "(no snapshot)")
        _ = pollUntilTrue(timeout: timeout, pollInterval: 0.5) {
            guard let reading = readVisibleParagraphs() else { return false }
            last = reading
            return condition(reading.visible)
        }
        return last
    }

    /// A setup reading that must hold for the test to mean anything; ends the test with `message` when it never does.
    func requireReading(_ message: String, _ condition: ([Int]) -> Bool) throws -> Reading {
        let reading = waitForReading(condition)
        try require(condition(reading.visible), "\(message) (saw \(reading.summary))\n\(reading.dump)")
        return reading
    }

    /// The reading after the round trip: `condition` must hold on three reads in a row, 0.7 s apart (the outgoing Markdown page is still
    /// in the tree for a moment, and its scroll position would pass the check by chance); gives up after 20 s and returns the last
    /// reading, which the caller asserts on.
    func settledReading(_ condition: ([Int]) -> Bool) -> Reading {
        var last = Reading(visible: [], dump: "(no snapshot)")
        var streak = 0
        _ = pollUntilTrue(timeout: 20, pollInterval: 0.7) {
            guard let reading = readVisibleParagraphs() else {
                streak = 0
                return false
            }
            last = reading
            streak = condition(reading.visible) ? streak + 1 : 0
            return streak >= 3
        }
        return last
    }

    func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
