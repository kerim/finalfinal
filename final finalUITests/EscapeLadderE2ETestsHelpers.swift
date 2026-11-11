//
//  EscapeLadderE2ETestsHelpers.swift
//  final finalUITests
//
//  Split out of EscapeLadderE2ETests.swift to keep that file under SwiftLint's file_length
//  limit. Self-contained copies of proven patterns from AnnotationDeleteE2ETests.swift and
//  UnifiedUndoE2ETests+Helpers.swift (see EscapeLadderE2ETests.swift's own header for why these
//  are reproduced here rather than shared) -- editor launch/click, Focus Mode entry, annotation
//  popup/panel helpers, and full-screen-state cleanup, used by every Escape-ladder test file.
//

import XCTest

// MARK: - Local helpers
//
// Self-contained copies of proven patterns from AnnotationDeleteE2ETests.swift and
// UnifiedUndoE2ETests+Helpers.swift (see this file's own header for why these are reproduced
// here rather than shared).

extension EscapeLadderE2ETests {
    func launchAndWaitForEditor() {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()
    }

    func waitForEditorReady() {
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
    }

    func clickIntoEditor() {
        app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
    }

    /// Enters Focus Mode (⇧⌘F) and waits for the status bar to disappear as confirmation --
    /// same signal SmokeTests.testFocusModeToggle already relies on
    /// (FocusModeSettingsManager's default hides the status bar). A short settle follows:
    /// enterFocusMode() also requests full screen (FullScreenManager.request(.fullScreen)),
    /// and nothing observable distinguishes "still transitioning" from "settled" for the
    /// purposes of a following click/window-open, so a short wait stands in.
    func enterFocusModeAndWait() {
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.groups["status-bar"].waitForDisappearance(timeout: 10), "Status bar should disappear when Focus Mode turns on")
        // e2e-lint: allow sleep -- see doc comment above.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Clicks the rendered text span of an inline annotation (not its marker span) to open its
    /// edit popup -- matches annotation-plugin.ts's NodeView click handler.
    func openAnnotationPopup(text: String, timeout: TimeInterval = 10) {
        guard let element = app.editorStaticText(startingWith: text, timeout: timeout) else {
            XCTFail("Annotation text \"\(text)\" should appear in the editor")
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// isAnnotationPanelVisible defaults to true (EditorViewState.swift); check first rather
    /// than assume, toggling only if the panel's own "Document Notes" header isn't already there.
    func ensureAnnotationsPanelVisible() {
        if panelText("Document Notes", timeout: 3).exists { return }
        app.activateAndWaitForForeground()
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(
            panelText("Document Notes", timeout: 10).waitForExistenceOrFail(timeout: 5).exists,
            "Annotations panel should show its \"Document Notes\" section header once visible"
        )
    }

    /// Finds a StaticText inside the Annotations panel matching `text` exactly, by label OR
    /// value. Scoped to `app.groups["annotations-panel"]` (not a bare `app.staticTexts` query)
    /// because these tests seed INLINE annotations (`<!-- ::comment:: ... -->`), whose text
    /// renders both in the document AND in the panel card -- an unscoped query could match the
    /// in-document copy instead, causing a double-click meant for the panel card to land on the
    /// web layer instead (opening its own popup rather than starting the card's edit mode),
    /// independent of any TextEditor ambiguity elsewhere in this file.
    func panelText(_ text: String, timeout: TimeInterval = 10) -> XCUIElement {
        // Exact-match against native Annotations-panel card/header text (never editor
        // content), which the editor's three-StaticTexts-per-heading collision doesn't apply
        // to; `text` values used with this helper are chosen to be unique to each test's own
        // seeded fixture.
        // e2e-lint: allow statictext-firstmatch -- see rationale above.
        let element = app.groups["annotations-panel"].staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        _ = element.waitForExistence(timeout: timeout)
        return element
    }

    /// Resolves the annotation card's edit TextEditor, scoped to the Annotations panel so it
    /// can never match the web editor's own ProseMirror contenteditable (see the file-header
    /// note on why an unscoped `app.textViews.firstMatch` is ambiguous, not unique). Prefers
    /// the explicit `.accessibilityIdentifier("annotation-card-edit-field")` set on the
    /// TextEditor in AnnotationCardView.swift; SwiftUI's TextEditor is not guaranteed to
    /// propagate that identifier down to the AppKit element XCUITest actually sees, so after a
    /// short probe this falls back to the panel-scoped `firstMatch`, which stays safely scoped
    /// on its own since the web text area lives entirely outside the "annotations-panel"
    /// accessibility container.
    func annotationCardEditor(timeout: TimeInterval = 10) -> XCUIElement {
        let panel = app.groups["annotations-panel"]
        let identified = panel.textViews["annotation-card-edit-field"]
        if identified.waitForExistence(timeout: 2) {
            return identified
        }
        _ = panel.textViews.firstMatch.waitForExistence(timeout: timeout)
        return panel.textViews.firstMatch
    }

    /// Whether an inline (charOffset >= 0) annotation row with this EXACT text currently exists
    /// (SQL `text = '...'`, not `LIKE`/`CONTAINS`) -- so, unlike `editorContainsText` (substring)
    /// below, an appended mutation such as "original MUST NOT SAVE" would NOT satisfy a query for
    /// "original": exact equality alone already disproves a wrongly-committed append. The mutation
    /// tests still add an explicit negative check for the appended text as belt-and-braces (review
    /// round: matching semantics were investigated and found exact here and in `panelText`, but
    /// substring in `editorContainsText`).
    func queryAnnotationTextExists(_ text: String) -> Bool {
        let sql = "SELECT count(*) FROM annotation WHERE charOffset >= 0 AND text = '\(FixtureDatabase.escape(text))';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return (Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// Best-effort check for whether the main window is GENUINELY in native (AppKit) full
    /// screen -- as opposed to this app's own `focusModeEnabled`/`status-bar` flag, which only
    /// reflects Focus Mode's internal state and stays "on" even if the window itself silently
    /// left real full screen underneath it (see `testEscInFocusModeWithSlashMenuOpenDoesNotSilentlyExitNativeFullScreen`
    /// above for why that distinction matters).
    ///
    /// No existing hook makes this directly queryable: `FullScreenManager.isSettledFullScreen()`
    /// / `isEffectivelyFullScreen()` (FullScreenManager.swift) are in-process Swift API, not
    /// reachable from this separate XCUITest process, and a repo-wide search found no
    /// accessibility identifier anywhere that already surfaces real window full-screen state to
    /// the accessibility tree either -- confirmed via `grep -rn "isSettledFullScreen\
    /// |isEffectivelyFullScreen"` (Swift call sites only) and a second grep across
    /// `final finalUITests/` for any existing full-screen-related check (none; every prior test
    /// in this file and the rest of the suite only ever asserts the `status-bar` group).
    ///
    /// This instead compares the main window's own accessibility-reported frame SIZE against
    /// the display's frame size (`NSScreen.main`, not `.visibleFrame`): AppKit's real full
    /// screen makes the window occupy the screen's ENTIRE frame, including the strip normally
    /// reserved for the menu bar; a merely-maximized/zoomed (non-full-screen) window is always
    /// constrained to `visibleFrame` instead, which is shorter by (at least) the menu bar's
    /// height -- comfortably outside `tolerance`. Comparing size only, not origin, sidesteps any
    /// ambiguity between AppKit's bottom-left-origin screen coordinates and the accessibility
    /// API's own frame coordinate convention, which this investigation did not need to resolve
    /// to get a reliable signal. `NSScreen.main` is safe to call from the UI test process
    /// itself: it runs on the same host/display as the app under test, this target already
    /// links AppKit elsewhere in this suite (see this file's own `import AppKit` and its
    /// precedent in e.g. ProjectOpenErrorE2ETests.swift), and it only reads screen geometry --
    /// it never touches the app process's own state.
    ///
    /// Uses `mainWindow()` (below) rather than an index-based `app.windows.firstMatch`: this
    /// class's own tests open secondary windows (Version History, Settings), and a
    /// `firstMatch` can resolve to one of those instead of the real main window, silently
    /// checking the wrong window's geometry.
    func isMainWindowNativeFullScreen(tolerance: CGFloat = 4.0) -> Bool {
        guard let screenFrame = NSScreen.main?.frame else { return false }
        let windowFrame = mainWindow().frame
        return abs(windowFrame.width - screenFrame.width) <= tolerance
            && abs(windowFrame.height - screenFrame.height) <= tolerance
    }

    /// Phase 7 (2026-11-11, found by the first full real-app run since September): the CLEANUP's test for "is the app still in native
    /// full screen". `isMainWindowNativeFullScreen()` asks only for the window that contains "editor-area"; when no window carries it
    /// (a test that ended while the page was not in the accessibility tree) `mainWindow().frame` reads `.zero`, the answer is "not full
    /// screen" and `exitFullScreenIfNeeded()` returned at its first line, so the app was closed still in full screen and the next
    /// launches of the shard started that way (the Esc-ladder class and the classes after it, sidebar width and open-error sheets,
    /// then all failed). This asks the same question of EVERY window of the app, for the cleanup only: the tests' own assertions keep
    /// using the main-window check, so a secondary window cannot weaken what they prove.
    func isAnyAppWindowNativeFullScreen(tolerance: CGFloat = 4.0) -> Bool {
        if isMainWindowNativeFullScreen(tolerance: tolerance) { return true }
        guard let screenFrame = NSScreen.main?.frame else { return false }
        return app.windows.allElementsBoundByIndex.contains { window in
            abs(window.frame.width - screenFrame.width) <= tolerance
                && abs(window.frame.height - screenFrame.height) <= tolerance
        }
    }

    /// Resolves the actual main editor window by finding the window CONTAINING the
    /// "editor-area" accessibility element, rather than:
    /// - an index-based `app.windows.firstMatch` -- wrong, because a second window (Version
    ///   History, Settings) can shadow the real one; or
    /// - a query for "any window whose frame matches the screen size" -- also wrong, because a
    ///   secondary window could itself happen to be full-screen-sized, which would weaken
    ///   `testEscInFocusModeWithSlashMenuOpenDoesNotSilentlyExitNativeFullScreen`'s whole
    ///   purpose: catching a SILENT full-screen exit on the MAIN window specifically.
    ///
    /// There's no reliable accessibility identifier on the main window itself to look up
    /// directly either: `SceneID.mainWindow`'s rawValue is `"AppWindow"`, but the real SwiftUI
    /// window's own accessibility identifier is shaped like `"...-1-AppWindow-1"`, so an exact
    /// `app.windows["AppWindow"]` lookup never matches. `"editor-area"` (`UITestHelpers.swift`'s
    /// `editorArea`) is unique to the main window and already relied on throughout this suite,
    /// so this instead asks for the window that CONTAINS it.
    func mainWindow() -> XCUIElement {
        let match = app.windows.containing(.group, identifier: "editor-area").firstMatch
        // If there ARE windows but none of them carry "editor-area" (a test aborted mid-teardown,
        // or the window genuinely isn't there for some other reason), `match` silently resolves to
        // a zero-frame element: its `.frame` reads `.zero`, `isMainWindowNativeFullScreen()` then
        // reads false (`.zero` never matches a screen size), and `exitFullScreenIfNeeded()` takes
        // its early-exit guard -- skipping cleanup entirely with no log, no evidence, nothing. Make
        // that failure mode show up in a failing run's log instead of vanishing silently, without
        // changing the guard's actual behavior (still fine to treat "no main window found" as
        // "nothing to clean up" for a test that's already terminating).
        let windowCount = app.windows.count
        if !match.exists && windowCount > 0 {
            print(
                "[EscapeLadderE2ETests] mainWindow(): no window with editor-area found among "
                    + "\(windowCount) window(s) -- treating as not full screen, but this may be "
                    + "masking a real problem; window frames "
                    + "\(app.windows.allElementsBoundByIndex.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }), "
                    + "screen \(Int(NSScreen.main?.frame.width ?? 0))x\(Int(NSScreen.main?.frame.height ?? 0)), "
                    + "status bar present \(app.groups["status-bar"].exists), menu bar items \(app.menuBars.menuBarItems.count)"
            )
        }
        return match
    }

    /// Polls until the main window's native full-screen geometry (`isMainWindowNativeFullScreen()`)
    /// reads true AND is stable across two reads ~250ms apart -- i.e. the full-screen
    /// transition's own layout reflow has genuinely finished, not merely "reads
    /// full-screen-sized for one instant mid-transition". Deadline ~10s. Best-effort: returns
    /// whether it settled before the deadline, but callers should still assert their own
    /// preconditions afterward rather than trust this alone.
    @discardableResult
    func waitForFullScreenReflowSettled(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isMainWindowNativeFullScreen() else {
                // Why this sleep is exempt from the fixed-wait lint: sampling interval of this bounded
                // wait: full screen isn't on yet, so re-check after a short pause rather than
                // spinning. Polls `isMainWindowNativeFullScreen()`, computed window geometry rather
                // than an XCUIElement attribute, which is why it can't use this codebase's
                // element-based `waitFor*` helpers.
                // e2e-lint: allow sleep -- sampling interval of a bounded wait over computed window geometry, not an XCUIElement
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let firstFrame = mainWindow().frame
            // Why this sleep is exempt from the fixed-wait lint: this is NOT a sampling gap, it IS
            // the measurement: this function defines "settled" as two window-frame reads ~250ms
            // apart (`firstFrame` above, `secondFrame` below) coming back identical, so removing or
            // shortening this gap would let a single mid-transition frame be misread as stable.
            // This sleep is load-bearing to the test's correctness, not incidental polling -- do
            // not remove or shorten it.
            // e2e-lint: allow sleep -- the gap IS the measurement (two frame reads ~250ms apart), not a sampling gap
            Thread.sleep(forTimeInterval: 0.25)
            guard isMainWindowNativeFullScreen() else { continue }
            let secondFrame = mainWindow().frame
            if firstFrame == secondFrame {
                return true
            }
        }
        return false
    }

    /// Teardown cleanup (see `tearDownWithError()` in EscapeLadderE2ETests.swift): if the main window is still in
    /// genuine native full screen -- whether this test intentionally left it that way or
    /// aborted mid-Focus-Mode after a failure -- escalate up to 5 rounds of Esc, each followed
    /// by a real settle check, before falling back to AppKit's native "Exit Full Screen" key
    /// equivalent once and then giving up and reporting the failure.
    ///
    /// **Corrected root cause (diagnostician round, 2026-09-18):** an earlier version of this
    /// method escalated with ⌃⌘F (Control-Command-F) instead of Esc. That was wrong: this app
    /// has never bound Ctrl-Cmd-F to anything -- only Shift-Cmd-F, for Focus Mode (see
    /// `ViewCommands.swift:29-32`). A key equivalent only does anything if a menu item is bound
    /// to it; with no binding, pressing Ctrl-Cmd-F is a complete no-op. Screenshot evidence from
    /// all 3 failing runs of `testVersionHistoryWindowEscOnlyClosesThatWindowMainWindowFocus-
    /// ModeUnaffected` confirmed the window really was stuck full screen the whole time -- ⌃⌘F
    /// never once succeeded, because it was never wired to anything in the first place. No
    /// other test in this file ever exercises this code path either: every other test exits
    /// Focus Mode via Esc in its own test body, before teardown's ladder would ever run, which
    /// is why the bug went unnoticed for 5 other tests that "worked" (they never reached this
    /// method with full screen still on).
    ///
    /// This also REFUTES the previous theory recorded here (Space nudge): that
    /// `testVersionHistoryWindowEscOnlyClosesThatWindowMainWindowFocusModeUnaffected` opens a
    /// secondary window (Version History) on a different Space than the main window's
    /// full-screen Space, and nothing reclaims the original Space once the secondary window
    /// closes. That confound was real -- it IS the only test in the file that opens a second
    /// window while full screen -- but it was confounded with "the only test that reaches this
    /// code path at all"; the Space theory was never actually confirmed, and a no-op key
    /// equivalent is a complete explanation on its own with no Spaces involved.
    ///
    /// Esc is this app's own PROVEN working exit mechanism: `testFocusModeEscWithNothingElse-
    /// OpenExits` (same file) exits full screen with a single Esc and passes reliably in all 3
    /// runs. Esc routes through a local `NSEvent` monitor -> `handleEscapeCandidate` ->
    /// `exitFocusMode()` -> `FullScreenManager.request(.windowed)` -- independent of menu
    /// dispatch, of which window is key, and of which Space is displayed.
    ///
    /// 5 rounds, not 3: Esc may need to walk down multiple ladder rungs (slash menu, find bar,
    /// annotation popup, Focus Mode) -- one rung cleared per press -- so more rounds are needed
    /// than a single toggle required. Each round re-activates the app (in case a previous
    /// round's press left focus elsewhere), presses Esc, then waits for a SETTLED clear -- not
    /// a single sample -- via `waitForNativeFullScreenClearedAndSettled()` below: a single
    /// instant where the geometry check reads "not full screen" mid-transition is not good
    /// enough evidence to stop escalating.
    ///
    /// Deleted entirely (this round): the `spaceOffset` tracking and `moveSpace(to:)` helper
    /// that nudged the displayed Space with Mission Control's Ctrl-Arrow shortcut between
    /// rounds. It targeted the now-refuted Spaces theory and added ~4.5s of blind Ctrl-Arrow
    /// presses per failure for no benefit this investigation could find.
    ///
    /// ⌃⌘F is kept as a LAST-RESORT fallback only, tried once after all 5 Esc rounds fail, with
    /// a longer 10s settle timeout -- in case a genuinely different stuck-window scenario needs
    /// it -- before falling through to the loud-failure path below.
    ///
    /// The evidence dump on total failure now also records the app's own Focus Mode flag
    /// (`status-bar` group) and window count: if Focus Mode's flag still reads "on" while the
    /// window is stuck full screen, that means Esc genuinely isn't reaching the main window
    /// (support for a Spaces/key-window theory after all); if the flag reads "off" while the
    /// window is still full-screen-sized, the app's internal flag and the real window state
    /// have desynced (an app-side bug). Neither of the 3 failing runs analyzed this round had
    /// this instrumentation, which is part of why the prior round's theory couldn't be checked.
    ///
    /// Returns a failure message describing the stuck state (and has already attached a
    /// screenshot + geometry dump as test evidence) if full screen never clears, or `nil` if it
    /// cleared (or was never on to begin with). Deliberately does NOT call `XCTFail` itself:
    /// `tearDownWithError()` must still run `app.terminate()` and
    /// `TestFixtureHelper.cleanupFixture()` before any failure is raised (`continueAfterFailure
    /// = false` means an earlier XCTFail could abort the rest of teardown) -- see that
    /// method's own doc comment.
    @discardableResult
    func exitFullScreenIfNeeded() -> String? {
        guard isAnyAppWindowNativeFullScreen() else { return nil }
        for round in 1...5 {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 5)
            app.typeKey(.escape, modifierFlags: [])
            if waitForNativeFullScreenClearedAndSettled(timeout: 5) {
                return nil
            }
            print("[EscapeLadderE2ETests] exitFullScreenIfNeeded Esc round \(round)/5 did not clear full screen")
        }

        // Last-resort fallback only (see doc comment above): all 5 Esc rounds failed, so try
        // the native "Exit Full Screen" key equivalent once more with a longer settle timeout,
        // in case a genuinely different stuck-window scenario needs it.
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 5)
        // Phase 7: when Focus Mode is off, Esc has nothing to close and the app never leaves a full screen it did not enter itself,
        // so also try the system's own menu item (best effort: the menu bar is hidden in full screen and the item may not exist).
        let exitItem = app.menuBars.menuItems["Exit Full Screen"]
        if exitItem.exists, exitItem.isHittable {
            exitItem.click()
            if waitForNativeFullScreenClearedAndSettled(timeout: 10) { return nil }
        }
        app.typeKey("f", modifierFlags: [.control, .command])
        if waitForNativeFullScreenClearedAndSettled(timeout: 10) {
            return nil
        }
        print("[EscapeLadderE2ETests] exitFullScreenIfNeeded last-resort \u{2303}\u{2318}F fallback did not clear full screen")

        // Capture evidence BEFORE anything else: once `app.terminate()` runs (right after this
        // method returns, in `tearDownWithError()`), there is nothing left to screenshot or
        // measure.
        attachEvidenceScreenshot(app.screenshot(), name: "escape-ladder-teardown-stuck-fullscreen")
        let windowFrame = mainWindow().frame
        let screenFrame = NSScreen.main?.frame ?? .zero
        add(XCTAttachment(string: """
            exitFullScreenIfNeeded: main window still reads native-full-screen after 5 rounds \
            of Esc plus a last-resort \u{2303}\u{2318}F (Control-Command-F, AppKit's native \
            "Exit Full Screen" shortcut) fallback.
            Main window frame: \(windowFrame)
            Screen frame: \(screenFrame)
            Focus Mode flag (status-bar absent == on): \(!app.groups["status-bar"].exists)
            Window count: \(app.windows.count)
            """))

        return "exitFullScreenIfNeeded: main window still native-full-screen after 5 rounds of "
            + "Esc plus a last-resort \u{2303}\u{2318}F fallback -- see attached "
            + "screenshot/geometry-dump evidence. This test's own full-screen state (not "
            + "necessarily its assertions) failed to clean up before teardown; later tests in "
            + "this shard may still be contaminated if this happens on the LAST test that runs "
            + "in a given process."
    }

    /// Polls until the main window's native full-screen geometry
    /// (`isMainWindowNativeFullScreen()`) reads FALSE AND is stable across two reads ~250ms
    /// apart -- the mirror image of `waitForFullScreenReflowSettled()` above, applied to
    /// confirm a full-screen EXIT has actually settled rather than merely sampling "not
    /// full-screen-sized" for one instant mid-transition (which a bare inverse of that method's
    /// polling loop could otherwise misread as done). Deadline ~10s by default. Best-effort:
    /// returns whether it settled before the deadline; the caller (`exitFullScreenIfNeeded()`)
    /// escalates to another round rather than trusting a single failed read.
    @discardableResult
    func waitForNativeFullScreenClearedAndSettled(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !isAnyAppWindowNativeFullScreen() else {
                // Why this sleep is exempt from the fixed-wait lint: sampling interval of this bounded
                // wait: full screen hasn't cleared yet, so re-check after a short pause rather than
                // spinning. Polls `isMainWindowNativeFullScreen()`, computed window geometry rather
                // than an XCUIElement attribute, which is why it can't use this codebase's
                // element-based `waitFor*` helpers.
                // e2e-lint: allow sleep -- sampling interval of a bounded wait over computed window geometry, not an XCUIElement
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            // Why this sleep is exempt from the fixed-wait lint: this is NOT a sampling gap, it IS
            // the measurement: this function defines "settled" as two reads of
            // `isMainWindowNativeFullScreen()` ~250ms apart both coming back false, matching
            // `waitForFullScreenReflowSettled()`'s own discipline above (mirrored, not shared,
            // since that one confirms frame EQUALITY across two full-screen reads, while this one
            // only needs both reads to agree the window is no longer full-screen-sized). This
            // sleep is load-bearing to the test's correctness, not incidental polling -- do not
            // remove or shorten it.
            // e2e-lint: allow sleep -- the gap IS the measurement (two full-screen reads ~250ms apart), not a sampling gap
            Thread.sleep(forTimeInterval: 0.25)
            guard !isAnyAppWindowNativeFullScreen() else { continue }
            return true
        }
        return false
    }
}
