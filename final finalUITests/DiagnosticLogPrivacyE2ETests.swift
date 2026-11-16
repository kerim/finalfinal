//
//  DiagnosticLogPrivacyE2ETests.swift
//  final finalUITests
//
//  t-561c4083: the diagnostic log that the user's "Enable diagnostic logging" switch writes must hold no key codes and no pieces of
//  the document. Before the fix every key-down wrote `[TYPING-TRACE] key t=<ms> code=<keyCode> editor=<bool>` (a run of key codes
//  reads back what was typed), and the log also carried slices of the writing: the autocorrect and paste diagnostics, the Markdown
//  slash-menu line (every keystroke), the first heading on every content push, the heading text at a zoom, the footnote and image
//  lines.
//
//  Why a UI test: the lines come from the whole chain, a real key press reaching the app's key monitor, the real editors posting
//  their own diagnostics through the bridge, and the real Diagnostics switch. The unit tests cover each gate on its own
//  (DiagnosticLogPrivacyTests, StructuralTraceTests, DiagnosticLogFileTests, autocorrect-diag-privacy.test.ts); only the running app
//  shows that nothing leaks through a path nobody listed.
//
//  Method 1, testTypedPastedZoomedAndSwitchedWordsAndKeyCodesNeverReachTheLog. The Diagnostics switch is ON
//  (FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING, plus the defaults key the other trace tests use) and the developer switch
//  FF_DEV_LOG_KEYS_AND_TEXT is NOT set. A person:
//    1. types a made-up sentence in Rich Text, presses Return, and pastes a made-up sentence;
//    2. zooms into a chapter whose heading is made of made-up words (a zoom used to log the heading text), types straight after the
//       double-click (no wait, so the page that is leaving is still typeable), types inside the zoom, leaves the zoom and types
//       straight after that;
//    3. presses Cmd-/ (Rich Text to Markdown) and types straight after it, so the "[TRANS] dropped the resend of a key typed in
//       the outgoing page" path may run (it used to log `code=`);
//    4. types a made-up sentence in Markdown mode.
//  Then it reads every log line written since the launch and asserts:
//    - the claim: no line holds `code=`, and no line holds any made-up word or any whole seeded sentence;
//    - positive controls, so the claim cannot pass on an empty log (each was seen in the first VM run's log): at least 10 key lines
//      with editor=true; a `[Blocks:edit]` line in which one edit adds as many words as the pasted sentence has; at least one Markdown
//      slash-menu line (`len=`); a `[CURSOR-SYNC] pmPosToMdLine` line reading `len=` at the mode switch; a `firstH=len=` line (content
//      push and load); a `[Zoom] Heading:` line reading `fragment=len=`; and the harness's own key parser
//      (Phase4bDelTypingParser.key) finds no key code in any line.
//
//  Method 2, testDeveloperSwitchStillWritesKeyCodes. The same launch with FF_DEV_LOG_KEYS_AND_TEXT=1 must write `code=` on the key
//  lines: the proof that the developer switch works, and that the harness's parser (which reads Z=6 and Cmd-/=44 from those lines) is
//  fed. It is tiny on purpose.
//
//  What this test does NOT decide (each is recorded as an attachment, never asserted): whether the straight-after keys landed in the
//  document (words typed at a transition are carried across, one rare lost letter is board t-285cf97d), and whether the "[TRANS]
//  dropped the resend" line was written in this run (it needs the key to reach the outgoing page and the incoming one at the flip).
//  The made-up words still count as leaks whether or not they landed.
//
//  How it reads the log: Phase4bDelLogTail follows diagnostic.log from before the launch, reading only the bytes written since the
//  last poll and following one rotation. Every wait below has a bound.
//

import AppKit
import XCTest

private struct PrivacyStop: Error {}

final class DiagnosticLogPrivacyE2ETests: XCTestCase {
    var app: XCUIApplication!
    var tail = Phase4bDelLogTail()

    // MARK: - What is typed, pasted and seeded (all made-up words, so a hit in the log can only be this test's own text)

    static let typedWord = "Zyxquorbit"
    static let pastedWord = "Plinthwarg"
    static let zoomedWord = "Tarnwhistle"
    static let markdownWord = "Wexcombe"
    /// Typed straight after the Cmd-/, the zoom-in double-click and the zoom exit, with nothing waited for first.
    static let afterSwitchWord = "Qwelmorph"
    static let afterZoomInWord = "Skerrimoth"
    static let afterZoomOutWord = "Ulvermoss"

    static let typedLine = "\(typedWord) typed here."
    /// Six words, so the paste is the only edit that adds six words to a block in one step (the typed lines have three each): the log's
    /// `[Blocks:edit] ... oldWC=0 newWC=6` line is the paste's positive control.
    static let pastedSentence = "\(pastedWord) pasted sentence arrives here today."
    static let zoomedLine = "\(zoomedWord) zoomed text."
    static let markdownLine = "\(markdownWord) markdown text."

    /// The seeded headings and sentences. Their words are on the leak list too: the heading text of a zoom, the first heading of a
    /// content push and the Markdown line being typed used to reach the log.
    static let topHeading = "Brindlemoss Wyvernlea"
    static let chapterOne = "Harrowfen Dunmere"
    static let chapterTwo = "Quillfenwick Marrowdeep"
    static let opening = "Opening paragraph about the privacy test."
    /// How the opening line is looked up in the MARKDOWN editor. CodeMirror draws a misspelled word (the made-up words, and the run
    /// "test.Qwelmorph" the carried-across keys can make) as its own text run, and the accessibility tree exposes one StaticText per run:
    /// the first VM run showed the line as "Opening paragraph about the privacy " + "test.Qwelmorph", so the whole sentence is never one
    /// leaf. The first words, which no misspelled word can precede, are always the start of the first leaf.
    static let openingStart = "Opening paragraph about"
    static let secondBody = "Second chapter paragraph about the privacy test."
    /// The paragraph the caret is clicked into inside the zoom. A page reload can put a word typed at the transition at the START of
    /// the document (the zoomed chapter's heading or its first paragraph), so the clicked paragraph is the second one, out of that way.
    static let secondClosing = "Closing chapter paragraph about the privacy test."

    static let seedMarkdown = """
    # Brindlemoss Wyvernlea

    ## Harrowfen Dunmere

    Opening paragraph about the privacy test.

    ## Quillfenwick Marrowdeep

    Second chapter paragraph about the privacy test.

    Closing chapter paragraph about the privacy test.
    """

    /// Every piece of the writing that must never appear in the log (matched without regard to case).
    static let leakNeedles: [String] = [
        typedWord, pastedWord, zoomedWord, markdownWord, afterSwitchWord, afterZoomInWord, afterZoomOutWord,
        "Brindlemoss", "Wyvernlea", "Harrowfen", "Dunmere", "Quillfenwick", "Marrowdeep",
        opening, secondBody, secondClosing
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        // Fast typing into the WKWebView editor: the inline predictive-text feature can swallow keystrokes, and autocorrect would
        // change the made-up words (e2e-verify, "Runner environment").
        app.launchArguments += ["-NSAutomaticInlinePredictionEnabled", "NO", "-NSAutomaticSpellingCorrectionEnabled", "NO",
                                "-NSAutomaticTextReplacementEnabled", "NO"]
        // The user's Diagnostics switch: the defaults key plus the variable that bypasses the UI-test defaults wipe (the same pair
        // Phase4bDelHarness uses). The developer switch FF_DEV_LOG_KEYS_AND_TEXT is deliberately NOT set here.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Method 1: nothing leaks with the developer switch off

    func testTypedPastedZoomedAndSwitchedWordsAndKeyCodesNeverReachTheLog() throws {
        XCTAssertNil(app.launchEnvironment["FF_DEV_LOG_KEYS_AND_TEXT"], "TEST-SETUP: the developer switch must not be set for this method")
        try launchAndWaitForSeed()
        try typeAndPasteInRichText()
        try zoomInTypeAndOut()
        try switchToMarkdownAndType()
        drainLog()
        checkTheLog()
    }

    // MARK: - Method 2: the developer switch still writes key codes

    func testDeveloperSwitchStillWritesKeyCodes() throws {
        app.launchEnvironment["FF_DEV_LOG_KEYS_AND_TEXT"] = "1"
        try launchAndWaitForSeed()
        let caret = app.placeCaretByClicking(paragraphStartingWith: Self.opening, atEnd: true, exactLine: Self.opening)
        try require(caret.confirmed, "TEST-SETUP: the caret could not be placed (probe: \(caret.probe))")
        let presses = 6
        for _ in 1...presses {
            app.typeKey("z", modifierFlags: [])
        }
        let zKeysSeen: () -> Int = {
            self.tail.poll()
            return self.tail.lines.compactMap { Phase4bDelTypingParser.key($0.text) }
                .filter { $0.code == Phase4bDelTypingParser.zKeyCode && $0.inEditor }.count
        }
        let arrived = pollUntilTrue(timeout: 20) { zKeysSeen() >= presses }
        let keyLines = tail.lines.map(\.text).filter { $0.contains("[TYPING-TRACE] key t=") }
        attachText("key-lines-developer-switch", keyLines.suffix(20).joined(separator: "\n"))
        XCTAssertTrue(arrived, "with FF_DEV_LOG_KEYS_AND_TEXT=1 the log must show \(presses) Z key lines (code=\(Phase4bDelTypingParser.zKeyCode), "
            + "editor=true) that the harness parser reads; saw \(zKeysSeen())")
        XCTAssertTrue(keyLines.contains { $0.contains(" code=") }, "with the developer switch on, no key line holds code=")
    }
}

// MARK: - Steps that drive the app

extension DiagnosticLogPrivacyE2ETests {
    /// Fails the test with `message` and ends it: for a step the rest of the test cannot meaningfully run without.
    private func require(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) throws {
        if condition { return }
        XCTFail(message(), file: file, line: line)
        throw PrivacyStop()
    }

    /// Polls `probe` every `pollInterval` until it returns true or `timeout` passes; returns the last answer.
    private func pollUntilTrue(timeout: TimeInterval, pollInterval: TimeInterval = 0.3, _ probe: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if probe() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return probe()
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text.isEmpty ? "(none)" : text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Starts following the log, launches, and waits for the seeded document in Rich Text.
    private func launchAndWaitForSeed() throws {
        tail = Phase4bDelLogTail()   // only the lines written from here on
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        try require(app.editorArea.waitForExistence(timeout: 15), "TEST-SETUP: the editor area did not appear")
        // The status-bar word count reads "0 words" before the editor exists, so it is no readiness signal: wait for real content.
        try require(
            app.editorStaticText(startingWith: Self.opening, exactLine: Self.opening, timeout: 30) != nil,
            "TEST-SETUP: the seeded opening paragraph never appeared in the editor"
        )
        try require(
            app.buttons["status-bar-editor-mode"].waitForLabel("== 'Rich Text'", timeout: 10),
            "TEST-SETUP: the document must open in Rich Text mode"
        )
    }

    /// True once the database holds every word (polled with a bound: the write queue saves behind the typing). Follows the log on the way.
    private func waitForDatabase(containing words: [String], timeout: TimeInterval = 45) -> Bool {
        pollUntilTrue(timeout: timeout, pollInterval: 0.5) {
            tail.poll()
            let text = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: "SELECT markdownFragment FROM block;")
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Step 1: caret to the end of the opening paragraph, Return, a made-up sentence, Return, then a made-up sentence pasted from the
    /// clipboard (set right before the Cmd-V: the clipboard is shared and can be overwritten between a copy and the paste).
    private func typeAndPasteInRichText() throws {
        let caret = app.placeCaretByClicking(paragraphStartingWith: Self.opening, atEnd: true, exactLine: Self.opening)
        try require(caret.confirmed, "TEST-SETUP: the caret could not be placed at the end of the opening paragraph (probe: \(caret.probe))")
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded(Self.typedLine)
        app.typeKey(.return, modifierFlags: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.pastedSentence, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        try require(
            waitForDatabase(containing: [Self.typedWord, Self.pastedWord]),
            "TEST-SETUP: the typed and pasted sentences never reached the database"
        )
    }

    /// A sidebar card by its exact title. The title lives in `value`; the query is scoped to the sidebar's scroll view (the editor also
    /// shows each heading, and a zoomed page adds a breadcrumb with the same text).
    private func sidebarCard(titled title: String) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        return sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
    }

    /// Step 2: zoom into the second chapter from its Outline card (cards are not hittable by design, so the double-click goes through a
    /// coordinate), type straight after the double-click, type inside the zoom, leave the zoom, type straight after that.
    private func zoomInTypeAndOut() throws {
        let exitGlyph = app.buttons["status-bar-zoom-exit"]
        try require(!exitGlyph.exists, "TEST-SETUP: the zoom exit glyph already exists before the zoom")
        let card = sidebarCard(titled: Self.chapterTwo)
        try require(card.waitForExistence(timeout: 15), "TEST-SETUP: the Outline sidebar has no card titled \"\(Self.chapterTwo)\"")
        let visibleBand = app.groups["outline-sidebar"].scrollViews.firstMatch.frame
        try require(
            visibleBand.contains(card.frame),
            "TEST-SETUP: the \"\(Self.chapterTwo)\" card (\(card.frame)) is outside the sidebar's visible band (\(visibleBand))"
        )
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        // Straight after the double-click, nothing waited for: the outgoing page is still typeable while the zoom is carried out. Where
        // these keys land is not decided here (they may be carried across); they are on the leak list either way.
        // e2e-lint: allow raw-typetext -- the keys are typed with no wait on purpose and are not expected to land intact.
        app.typeText(Self.afterZoomInWord)
        try require(exitGlyph.waitForExistence(timeout: 20), "TEST-SETUP: the double-click on the \"\(Self.chapterTwo)\" card did not zoom into it")

        let zoomedCaret = app.placeCaretByClicking(paragraphStartingWith: Self.secondClosing, atEnd: true, exactLine: Self.secondClosing)
        try require(zoomedCaret.confirmed, "TEST-SETUP: the caret could not be placed in the zoomed chapter (probe: \(zoomedCaret.probe))")
        app.typeKey(.return, modifierFlags: [])
        app.typeTextVerifyingLanded(Self.zoomedLine)
        try require(waitForDatabase(containing: [Self.zoomedWord]), "TEST-SETUP: the sentence typed inside the zoom never reached the database")

        // The app disables the exit glyph while the document is still busy, and a disabled control cannot be clicked: the one bounded wait
        // that gates an action here.
        try require(
            pollUntilTrue(timeout: 20) { exitGlyph.exists && exitGlyph.isEnabled },
            "TEST-SETUP: the zoom exit glyph never became enabled"
        )
        exitGlyph.click()
        // Straight after leaving the zoom, nothing waited for.
        // e2e-lint: allow raw-typetext -- the keys are typed with no wait on purpose and are not expected to land intact.
        app.typeText(Self.afterZoomOutWord)
        try require(exitGlyph.waitForDisappearance(timeout: 20), "TEST-SETUP: the click on the zoom exit glyph did not leave the zoom")
    }

    /// Steps 3 and 4: the caret back in the opening paragraph (so the keys typed at the switch go to the editor), Cmd-/ with a made-up word
    /// typed straight after it, then a made-up sentence typed in Markdown mode.
    private func switchToMarkdownAndType() throws {
        let caret = app.placeCaretByClicking(paragraphStartingWith: Self.opening, atEnd: true, exactLine: Self.opening)
        try require(caret.confirmed, "TEST-SETUP: the caret could not be placed before the mode switch (probe: \(caret.probe))")
        let editorMode = app.buttons["status-bar-editor-mode"]
        try require(editorMode.waitForExistence(timeout: 10), "TEST-SETUP: the editor-mode button did not appear")
        app.activateAndWaitForForeground()
        app.typeKey("/", modifierFlags: .command)
        // Straight after the switch key, nothing waited for: the keys reach the outgoing page, or the incoming one, or are resent at the
        // flip (the "[TRANS] dropped the resend" path). One attempt only: a second Cmd-/ would switch back.
        // e2e-lint: allow raw-typetext -- the keys are typed with no wait on purpose and are not expected to land intact.
        app.typeText(Self.afterSwitchWord)
        try require(
            editorMode.waitForLabel("== 'Markdown'", timeout: 25),
            "Cmd-/ did not switch the editor to Markdown (the mode button still reads \"\(editorMode.label)\")"
        )

        // Click the opening line in the Markdown editor itself so the caret is surely there (no caret probe in this mode; the typed
        // sentence is verified through the database below). The line is found by its first words (see `openingStart`), then Cmd-Right
        // goes to the true end of the line, past any misspelled run that follows.
        let mdCaret = app.placeCaretByClicking(paragraphStartingWith: Self.openingStart, atEnd: true, runProbe: false)
        try require(
            mdCaret.probe == "retired",
            "TEST-SETUP: the Markdown opening line could not be clicked (result: \(mdCaret.probe); attempts: \(mdCaret.attempts))"
        )
        app.typeKey(.return, modifierFlags: [])
        // Not typeTextVerifyingLanded: in this editor a misspelled word is its own text run, so the typed sentence is never one
        // accessibility value and its landing check could not pass. The database wait below is the landing check.
        app.activateAndWaitForForeground()
        // e2e-lint: allow raw-typetext -- the landing is verified through the database right below, not through the accessibility tree.
        app.typeText(Self.markdownLine)
        try require(
            waitForDatabase(containing: [Self.markdownWord]),
            "TEST-SETUP: the sentence typed in Markdown mode never reached the database"
        )
    }

    /// Reads on until the log has been quiet for two seconds (the writes behind the last typing, and the trace windows, finish
    /// asynchronously), for at most eight seconds.
    private func drainLog(maxSeconds: TimeInterval = 8) {
        let deadline = Date(timeIntervalSinceNow: maxSeconds)
        var seen = -1
        var quietSince = Date()
        repeat {
            tail.poll()
            if tail.lines.count != seen {
                seen = tail.lines.count
                quietSince = Date()
            }
            if Date().timeIntervalSince(quietSince) >= 2 { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
    }
}

// MARK: - Reading the log

extension DiagnosticLogPrivacyE2ETests {
    /// The `[Blocks:edit] block=<id> oldWC=<n> newWC=<m>` lines (the block saver's word-count line) in which one edit added at least as many
    /// words as the pasted sentence has. Only the paste does that: each typed line has three words. (The editor's own
    /// `[AUTOCORRECT-DIAG] input type=insertFromPaste` line is NOT used: ProseMirror takes a plain-text Cmd-V on the `paste` event and
    /// cancels it, so WebKit sends no `beforeinput` for it; the first VM run wrote no such line.)
    private func pasteEditLines(in texts: [String]) -> [String] {
        let pastedWords = Self.pastedSentence.split(separator: " ").count
        return texts.filter { line in
            guard line.contains("[Blocks:edit]"),
                  let before = Phase4bDelTypingParser.intAfter("oldWC=", in: line),
                  let after = Phase4bDelTypingParser.intAfter("newWC=", in: line) else { return false }
            return after - before >= pastedWords
        }
    }

    /// Every check on the lines written since the launch. All soft, so one run reports every failure, not only the first.
    private func checkTheLog() {
        let previous = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previous }

        tail.poll()
        let texts = tail.lines.map(\.text)
        let keyLines = texts.filter { $0.contains("[TYPING-TRACE] key t=") }
        let editorKeyLines = keyLines.filter { $0.contains("editor=true") }
        let pasteLines = pasteEditLines(in: texts)
        let pasteEventLines = texts.filter { $0.contains("[AUTOCORRECT-DIAG] input type=insertFromPaste") }
        let slashMenuLines = texts.filter { $0.contains("[SlashMenu] textBefore len=") }
        let cursorSyncLines = texts.filter { $0.contains("[CURSOR-SYNC] pmPosToMdLine: pmPos=") }
        // The lines the fix rewrote, in their new form: the first heading of a content push and of a content load (Swift side), and the
        // heading line of a zoom. Each must exist and read `len=`; the claim below says no text is in any of them.
        let firstHeadingLines = texts.filter { $0.contains("firstH=len=") }
        let zoomHeadingLines = texts.filter { $0.contains("[Zoom] Heading:") && $0.contains("fragment=len=") }
        let transDropped = texts.filter { $0.contains("[TRANS] dropped the resend") }
        let needles = Self.leakNeedles.map { $0.lowercased() }
        let leaks = texts.filter { line in
            let lower = line.lowercased()
            return line.contains("code=") || needles.contains { lower.contains($0) }
        }
        let keysTheHarnessParserReads = keyLines.filter { Phase4bDelTypingParser.key($0) != nil }

        // The still and the attachments come BEFORE the assertions (an aborting assertion would leave none).
        attachEvidenceScreenshot(app.screenshot(), name: "end-state")
        attachText("leaking-lines", leaks.prefix(40).joined(separator: "\n"))
        attachText("log-summary", [
            "log lines read: \(texts.count) (rotations followed: \(tail.rotationsSeen))",
            "key lines: \(keyLines.count), of them editor=true: \(editorKeyLines.count)",
            "block-edit lines of the paste (one edit adding \(Self.pastedSentence.split(separator: " ").count) words): \(pasteLines.count)",
            "autocorrect lines for the paste event (not asserted, see pasteEditLines): \(pasteEventLines.count)",
            "Markdown slash-menu lines: \(slashMenuLines.count)",
            "cursor-sync lines at the mode switch: \(cursorSyncLines.count)",
            "first-heading lines reading firstH=len=: \(firstHeadingLines.count)",
            "zoom heading lines reading fragment=len=: \(zoomHeadingLines.count)",
            "[TRANS] dropped-resend lines (not asserted; the path needs a key at the flip): \(transDropped.count)",
            "lines with code= or a made-up word: \(leaks.count)"
        ].joined(separator: "\n"))
        attachText("sample-key-lines", keyLines.prefix(6).joined(separator: "\n"))
        attachText("sample-slash-menu-lines", slashMenuLines.prefix(4).joined(separator: "\n"))
        attachText("sample-paste-lines", (pasteLines.prefix(3) + pasteEventLines.prefix(3)).joined(separator: "\n"))
        attachText("sample-cursor-sync-lines", cursorSyncLines.prefix(3).joined(separator: "\n"))
        attachText("sample-rewritten-lines", (firstHeadingLines.prefix(2) + zoomHeadingLines.prefix(2)).joined(separator: "\n"))
        attachText("trans-dropped-lines", transDropped.prefix(5).joined(separator: "\n"))

        XCTAssertLessThanOrEqual(
            tail.rotationsSeen, 1,
            "TEST-SETUP: the log rotated \(tail.rotationsSeen) times while it was read; lines in between may be missing"
        )
        // Positive controls: the trace and the editors' own diagnostics really ran, so an empty result below means something.
        XCTAssertGreaterThanOrEqual(
            editorKeyLines.count, 10,
            "positive control: too few `[TYPING-TRACE] key` lines with editor=true (\(keyLines.count) key lines in all)"
        )
        XCTAssertFalse(
            pasteLines.isEmpty,
            "positive control: no `[Blocks:edit]` line in which one edit adds "
                + "\(Self.pastedSentence.split(separator: " ").count) words, so the paste left no line"
        )
        XCTAssertGreaterThanOrEqual(
            slashMenuLines.count, 1,
            "positive control: no `[SlashMenu] textBefore len=` line, so the Markdown typing wrote nothing the slash-menu fix covers"
        )
        XCTAssertGreaterThanOrEqual(
            cursorSyncLines.filter { $0.contains(" len=") && !$0.contains("parentText=") }.count, 1,
            "positive control: no `[CURSOR-SYNC] pmPosToMdLine` line reading len= at the mode switch (or it still carries parentText=)"
        )
        XCTAssertFalse(firstHeadingLines.isEmpty, "positive control: no log line reads `firstH=len=` (the content push and load lines)")
        XCTAssertFalse(zoomHeadingLines.isEmpty, "positive control: no `[Zoom] Heading:` line reads `fragment=len=` (the zoom wrote no heading line)")
        // The claim.
        XCTAssertTrue(
            keysTheHarnessParserReads.isEmpty,
            "\(keysTheHarnessParserReads.count) key lines still carry a key code the harness parser reads, "
                + "e.g. \(keysTheHarnessParserReads.first ?? "")"
        )
        XCTAssertTrue(
            leaks.isEmpty,
            "\(leaks.count) log lines carry `code=` or a typed, pasted or seeded word (see the leaking-lines attachment); first: \(leaks.first ?? "")"
        )
    }
}
