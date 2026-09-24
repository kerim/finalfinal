//
//  EscapeLadderPopupAndLatencyE2ETests.swift
//  final finalUITests
//
//  Split out of EscapeLadderE2ETests.swift to keep that file's class body under SwiftLint's
//  type_body_length limit, and the file itself under the file_length limit -- see the header
//  comment there for the full Escape-ladder background. This file covers Item 1 (slash menu
//  alone), Item 2 (in-document annotation edit popup, standalone), Item 4 (annotation panel
//  card edit, standalone), Item 5 (Focus Mode alone), and the Focus-Mode-exit latency
//  measurement (t-784ff3aa), plus the diagnostic-log read/attach/poll helpers those tests (and
//  EscapeLadderE2ETests.swift's own web-layer-delay test) drive through. Members are `internal`
//  (not `private`) because both files call them directly by name -- Swift's `private`
//  same-file relaxation only covers extensions in the SAME file.
//

import XCTest

extension EscapeLadderE2ETests {

    // MARK: - Item 1: slash menu alone, text untouched

    func testSlashMenuEscClosesMenuLeavesTextUntouched() throws {
        let bodyText = "Existing paragraph text that must remain untouched."
        let markdown = """
        # Slash Menu Standalone Test

        \(bodyText)
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        XCTAssertTrue(app.editorContainsText(bodyText, timeout: 10), "Seeded paragraph should render")

        clickIntoEditor()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.activateAndWaitForForeground()
        app.typeText("/")
        XCTAssertTrue(app.editorContainsText("Insert task annotation", timeout: 10), "Slash menu should open")

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.editorContainsText("Insert task annotation", timeout: 5), "Esc should close the slash menu")
        XCTAssertFalse(
            app.editorContainsText("/", timeout: 5),
            "The '/' trigger character itself should be deleted by Esc, not left behind in the document"
        )
        XCTAssertTrue(app.editorContainsText(bodyText, timeout: 5), "Original paragraph text should be untouched")
        XCTAssertTrue(app.groups["status-bar"].exists, "Nothing else (e.g. Focus Mode) should have changed")
    }

    // MARK: - Item 2: in-document annotation edit popup, standalone

    func testAnnotationEditPopupEscCancelsPreservingOldText() throws {
        let originalText = "Standalone popup edit original text"
        let markdown = """
        # Popup Standalone Test

        <!-- ::comment:: \(originalText) -->
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        XCTAssertTrue(app.editorContainsText(originalText, timeout: 10), "Seeded annotation should render")

        openAnnotationPopup(text: originalText)
        XCTAssertTrue(app.editorContainsText("Escape to cancel", timeout: 10), "Annotation edit popup should open")

        app.activateAndWaitForForeground()
        app.typeText(" MUST NOT SAVE")

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.editorContainsText("Escape to cancel", timeout: 5), "Esc should close the popup")
        XCTAssertFalse(app.editorContainsText("MUST NOT SAVE", timeout: 3), "In-progress edit must be discarded, never committed")
        XCTAssertTrue(app.editorContainsText(originalText, timeout: 5), "Original annotation text should be preserved")
        XCTAssertTrue(queryAnnotationTextExists(originalText), "DB row should be unchanged")
    }

    // MARK: - Item 4: annotation panel card edit, standalone

    func testAnnotationPanelCardEditEscDiscardsChanges() throws {
        let originalText = "Panel card edit original text"
        let markdown = """
        # Panel Card Standalone Test

        <!-- ::comment:: \(originalText) -->
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        ensureAnnotationsPanelVisible()

        let card = panelText(originalText, timeout: 10)
        XCTAssertTrue(card.exists, "Card should show in the panel")
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        let editor = annotationCardEditor(timeout: 10)
        XCTAssertTrue(editor.waitForExistenceOrFail(timeout: 10).exists, "Card's edit TextEditor should appear")

        app.activateAndWaitForForeground()
        // Explicitly click the resolved TextEditor element before typing into it -- don't rely
        // on the double-click alone to have left it focused, and target the element directly
        // rather than typing app-wide.
        editor.click()
        editor.typeText(" APPENDED SHOULD NOT SAVE")
        XCTAssertTrue(
            editor.waitForValue("CONTAINS 'APPENDED SHOULD NOT SAVE'", timeout: 5),
            "Typed marker text should land in the card's edit TextEditor before Esc "
                + "-- proves the double-click genuinely opened edit mode rather than silently missing its target"
        )

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(editor.waitForDisappearance(timeout: 10), "Esc should close the edit TextEditor")
        XCTAssertTrue(panelText(originalText, timeout: 10).exists, "Card should return to normal, showing the original text")
        // DB check fires immediately (no polling) -- see the matching comment in
        // testFocusedAnnotationCardEscCancelsNotFindBarWhenFindBarUnfocused: this cancel path
        // never calls onUpdateText, so there is no debounced/async write to race against.
        XCTAssertTrue(queryAnnotationTextExists(originalText), "DB row should be unchanged -- the edit was discarded, not committed")
        XCTAssertFalse(
            queryAnnotationTextExists("\(originalText) APPENDED SHOULD NOT SAVE"),
            "DB must not contain the appended mutation text -- explicit check independent of queryAnnotationTextExists's own exact-match semantics"
        )
    }

    // MARK: - Item 5: Focus Mode alone, nothing else open

    func testFocusModeEscWithNothingElseOpenExits() throws {
        launchAndWaitForEditor()
        enterFocusModeAndWait()

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.groups["status-bar"].waitForExistence(timeout: 10), "Esc with nothing else open should exit Focus Mode")
    }

    // MARK: - Latency measurement (t-784ff3aa): user reported Focus Mode exit via Escape feels
    // "much slower, not instant like the current release build". This test doesn't assert a
    // number (there's no established latency budget to assert against yet) -- it forces on the
    // app's real diagnostic-logging sink so a human can read the ACTUAL measured
    // arm/resolve/apply timeline for a single, simple Escape-exits-Focus-Mode press (nothing
    // else open, matching exactly what the user described) under a realistic document, instead
    // of another estimate. See `attachDiagnosticLog()` below for what the driver should grep the
    // attached log for.

    func testFocusModeEscExitLatencyUnderRealisticDocumentLoad() throws {
        // Force real DebugLog output for `.escape` (normally excluded from DebugLog.enabled by
        // default -- see DebugLog.swift's own doc comment on that category) for this run only,
        // via the diagnostic-logging force-flag (DiagnosticLogFile.swift:96). Must be set before
        // launch; `launchForTesting(fixturePath:)` only adds its own two keys to
        // `launchEnvironment`, so setting this first survives into the launched process.
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"

        // Realistic-size document -- reusing the exact same large-fixture pattern
        // `testEscThreeTimesInFocusModeClosesSlashMenuFirstUnderRealisticDocumentLoad`
        // (EscapeLadderE2ETests.swift) already uses, so this measurement isn't taken against a trivial 2-line fixture whose
        // block-sync round trip never resembles what the user actually saw.
        var markdown = "# Focus Mode Exit Latency Test\n\n"
        for index in 0..<300 {
            markdown += "Body padding paragraph \(index) for the large-document Focus Mode exit "
                + "latency measurement -- long enough, and repeated enough times, to give the "
                + "block-sync serialization pass real weight instead of the near-instant round "
                + "trip a trivial fixture produces.\n\n"
        }
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        // Gate on the LAST paragraph (index 299), not the first: `editorContainsText` scans
        // whatever is currently in the editor's accessibility tree, and Milkdown mounts/paints
        // this 300-paragraph document progressively, so "paragraph 0 for" can appear in the
        // tree well before the rest of the document -- and the rest of it -- has actually
        // painted. Entering Focus Mode (and this test's own forced diagnostic-logging overhead)
        // while the tail of the document is still mid-render is exactly the class of bug this
        // session already diagnosed and fixed once for
        // `testFindBarFieldFocusedEscClosesFindBarReturnsToEditor` (interacting with the editor
        // before the WKWebView has actually finished painting the seeded content). Checking the
        // final paragraph's distinctive text is the only one of the 300 that is guaranteed not
        // to exist in the tree until the whole document has painted.
        // 30s, not the default: this is the slowest-to-render gate in the suite, chosen
        // specifically because paragraph 299 is the last thing to paint in a 300-paragraph
        // Milkdown mount, and the old, un-batched `editorContainsText` polling loop's ~50s-per-
        // poll overshoot was quietly giving it far more real settle time than its stated timeout
        // ever promised.
        XCTAssertTrue(
            app.editorContainsText("Body padding paragraph 299 for", timeout: 30),
            "Seeded large document should render before this test's first interaction"
        )

        enterFocusModeAndWait()

        // The simple case, matching what the user described: nothing else open, just Focus
        // Mode exit latency on its own -- one Escape press.
        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.groups["status-bar"].waitForExistence(timeout: 10), "Esc should exit Focus Mode")

        attachDiagnosticLog()
    }

    /// Reads the app's real diagnostic log (forced on via FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING),
    /// filtered to its `.escape`-category lines, without attaching anything -- split out from
    /// `attachDiagnosticLog()` below so `pollDiagnosticLog(untilContains:timeout:)` can poll it
    /// repeatedly without spamming the test result with one attachment per poll (see each of
    /// those two functions' own doc comment). Structure (candidate log locations, report format)
    /// copied from `ProjectSwitchMarginsE2ETests.attachDiagnosticLog()`
    /// (ProjectSwitchMarginsE2ETests.swift:112) per the diagnostician's precedent -- only
    /// `signalPatterns` differs, since that investigation's list (SYNC-DIAG, DIAG:MarginCheck,
    /// ...) has nothing to do with Escape. Every `DebugLog.log(.escape, ...)` line is written to
    /// the file as `[escape] <message>` (DebugLog.swift's `log()`: `"[\(category.rawValue)]
    /// \(text)"`), so filtering on the literal `"[escape]"` category tag catches all of them
    /// regardless of which specific message shape a call site uses -- including every shape as
    /// of this writing (t-784ff3aa fix round -- `webPopupOpen=` was added to the two
    /// `focusIsInWebView=true` lines, replacing the single always-arms-a-watchdog line the
    /// earlier design had; the `escapeLadder report handled=` line was added in the same round to
    /// give `testEscClosesSlashMenuCorrectlyEvenWithAnArtificiallyHugeWebLayerReportDelay`
    /// something to assert on directly instead of the accessibility tree):
    ///   [Escape#N] keydown timestamp=... isARepeat=... windowNumber=...
    ///   [Escape#N] focusIsInWebView=true webPopupOpen=true rung=webOwned (arming hang-protection watchdog)
    ///   [Escape#N] focusIsInWebView=true webPopupOpen=false applying native ladder immediately
    ///   [Escape#N] focusIsInWebView=false rung=<rung>
    ///   [EscapeWatchdog] armed generation=<n>
    ///   [EscapeWatchdog] fired generation=<n>
    ///   [EscapeWatchdog] resolvePendingEscape generation=<n> resolved=<bool> elapsedMs=<ms>
    ///   [Escape] apply rung=<rung>
    ///   [Escape] escapeLadder report handled=<bool>
    /// (AppDelegate.swift, EscapeLadder.swift.) `testFocusModeEscExitLatencyUnderRealisticDocumentLoad`'s
    /// own scenario (Focus Mode exit, nothing else open, no click into the editor first) never
    /// enters the web-focused branch at all, so its own log lines are just the plain
    /// `focusIsInWebView=false rung=focusMode` / `apply rung=focusMode` pair -- no watchdog
    /// lines. The watchdog lines above are documented here for whichever OTHER investigation
    /// next greps this same log format: since the fix, `armed`/`fired` mean the web layer's own
    /// popup-open signal was true but it never reported back at all (hang protection, the
    /// rare/pathological path) -- they no longer mean anything about ordinary Escape-report
    /// latency the way they used to before this round. The app is not sandboxed, so this
    /// resolves to the same real file both processes see -- no cross-container copying needed.
    /// Return value of `readDiagnosticLog()` -- named struct instead of a 3-member tuple
    /// (SwiftLint's `large_tuple` caps tuples at 2 members). Used only within this file.
    struct DiagnosticLogRead {
        let report: String
        let found: String?
        let filtered: String
    }

    func readDiagnosticLog() -> DiagnosticLogRead {
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

        let signalPatterns = ["[escape]"]
        let filtered = found.map { text in
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in signalPatterns.contains { line.contains($0) } }
                .joined(separator: "\n")
        } ?? ""
        return DiagnosticLogRead(report: report, found: found, filtered: filtered)
    }

    /// Reads the current diagnostic log (see `readDiagnosticLog()`), attaches it as test
    /// evidence, and returns its filtered `.escape`-category lines -- so a caller can also
    /// assert on them directly rather than re-scanning the accessibility tree. See
    /// `testEscClosesSlashMenuCorrectlyEvenWithAnArtificiallyHugeWebLayerReportDelay`'s own doc
    /// comment for why that test needs this.
    @discardableResult
    func attachDiagnosticLog() -> String {
        let result = readDiagnosticLog()
        let attachment: XCTAttachment
        if result.found != nil {
            attachment = XCTAttachment(string: result.report + "\n---FILTERED (signal lines only, full run)---\n" + result.filtered)
        } else {
            attachment = XCTAttachment(string: result.report + "\n(no log found at any candidate path)")
        }
        attachment.name = "diagnostic-log-tail"
        attachment.lifetime = .keepAlways
        add(attachment)
        return result.filtered
    }

    /// Polls `readDiagnosticLog()`'s filtered `.escape`-category lines every 0.25s until they
    /// contain `substring`, or `timeout` elapses, then returns whatever was last read (matched
    /// or not). Absorbs ordinary jitter in exactly when a delayed web-layer report reaches Swift
    /// (JS event-loop scheduling, WebKit background-tab timer throttling, WKScriptMessage IPC
    /// latency) -- none of which is the timing RACE this suite exists to rule out (that race was
    /// a fixed native deadline competing against the web layer's own report; this is only "give
    /// the read a moment to catch a value that's about to land"). Does not attach anything
    /// itself -- callers that want an attachment call `attachDiagnosticLog()` separately, same as
    /// every other diagnostic-log read site in this file.
    func pollDiagnosticLog(untilContains substring: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var filtered = ""
        while true {
            filtered = readDiagnosticLog().filtered
            if filtered.contains(substring) || Date() >= deadline {
                return filtered
            }
            // Why this sleep is exempt from the fixed-wait lint: sampling interval of the bounded
            // poll loop above (already re-checks a file read via `readDiagnosticLog()` each
            // iteration and is bounded by `deadline`), keeping it from spinning the CPU between
            // reads. Polls a file read, not an XCUIElement attribute, which is why it can't use
            // this codebase's element-based `waitFor*` helpers.
            // e2e-lint: allow sleep -- sampling interval of a bounded poll over a file read, not an XCUIElement attribute
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

}
