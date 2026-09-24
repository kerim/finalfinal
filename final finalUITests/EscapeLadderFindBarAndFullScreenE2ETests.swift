//
//  EscapeLadderFindBarAndFullScreenE2ETests.swift
//  final finalUITests
//
//  Split out of EscapeLadderE2ETests.swift to keep that file's class body under SwiftLint's
//  type_body_length limit, and the file itself under the file_length limit -- see the header
//  comment there for the full Escape-ladder background. This file covers Item 3 (find bar with
//  the field genuinely focused), the judge-review regression (a card left mid-edit when Focus
//  Mode hides/shows), the direct-exit case despite a stale annotation edit started before Focus
//  Mode hid, Item 9 (Version History window's own Esc is independent of the main window's
//  ladder), and Bug 2 (a genuine native full-screen exit the app never requested).
//

import XCTest

extension EscapeLadderE2ETests {

    // MARK: - Item 3: find bar, field genuinely focused

    func testFindBarFieldFocusedEscClosesFindBarReturnsToEditor() throws {
        let markdown = """
        # Find Bar Focus Test

        Paragraph for the find bar Esc test.
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()

        // Click into the editor and type a throwaway marker first, matching
        // UnifiedUndoE2ETests.swift's testUndoWorksAfterClosingFindBarNoManualClick. Opening
        // the find bar as this test's literal first interaction right after launch let Cmd-F's
        // search-field focus claim race the window's own key-status settling, so the field was
        // never actually focused by the time typeText() ran -- "Neither element nor any
        // descendant has keyboard focus". Waiting for real rendered content (not a fixed sleep)
        // is the settle signal, per that same precedent.
        //
        // The WebView is not interactive yet when launchAndWaitForEditor() returns -- its
        // word-count gate proves Swift-side state only. CONFIRMED via vmtest run-1789026984-27747's
        // screen recording: at the moment of this click the editor was still blank, and the marker
        // landed as "ndBarSettleMarkerFind Bar Focus Test" (leading "Fi" lost to the mounting
        // editor). Gate on real rendered content first, exactly as
        // testSlashMenuEscClosesMenuLeavesTextUntouched and UnifiedUndoE2ETests's
        // testUndoWorksAfterClosingFindBarNoManualClick both do.
        XCTAssertTrue(
            app.editorContainsText("Paragraph for the find bar Esc test.", timeout: 10),
            "Seeded paragraph should render before this test's first interaction"
        )

        clickIntoEditor()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        app.activateAndWaitForForeground()

        // Verify the click above actually claimed keyboard focus before relying on
        // `typeTextVerifyingLanded`'s own retry loop -- that helper only retries when
        // something resembling the target text landed (exact OR partial-prefix); if focus
        // never landed at all, NOTHING appears, which makes it fail loud on its very first
        // attempt instead of getting the retries it was designed for (confirmed live: 1/1
        // failed here). Type one throwaway probe character and confirm it lands; if not,
        // retry the click itself (not just the typing) up to 3 times.
        var focusConfirmed = false
        for attempt in 1...3 {
            let probe = "FocusProbe\(attempt)"
            app.typeText(probe)
            if app.editorContainsText(probe, timeout: 3) {
                focusConfirmed = true
                // Clear the probe text via the same current-line clear
                // `typeTextVerifyingLanded` uses, so the caret is left on its own,
                // otherwise-empty line -- that method's own documented precondition.
                app.typeKey(.leftArrow, modifierFlags: .command)
                app.typeKey(.rightArrow, modifierFlags: [.command, .shift])
                app.typeKey(.delete, modifierFlags: [])
                break
            }
            if attempt < 3 {
                clickIntoEditor()
                app.typeKey(.downArrow, modifierFlags: .command)
                app.typeKey(.return, modifierFlags: [])
                app.activateAndWaitForForeground()
            }
        }
        XCTAssertTrue(focusConfirmed, "Click into the editor should claim keyboard focus within 3 attempts")

        let settleMarker = "FindBarSettleMarker"
        app.typeTextVerifyingLanded(settleMarker)

        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["find-bar-search-field"]
        XCTAssertTrue(searchField.waitForExistenceOrFail(timeout: 10).exists, "Find bar's search field should appear")
        // Explicitly click the field before typing into it -- don't rely on Cmd-F's own focus
        // claim alone, which is exactly what raced above.
        searchField.click()
        searchField.typeText("Paragraph")

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForDisappearance(timeout: 10), "Esc should close the find bar while its own field is focused")

        // "Editor returns": type with NO manual click back into the editor first -- proving
        // keyboard focus was automatically restored by FindBarState.hide()'s own
        // EditorFocusRestoration call, not merely that the find bar disappeared.
        app.activateAndWaitForForeground()
        let marker = "FindBarReturnMarker"
        app.typeText(marker)
        XCTAssertTrue(
            app.editorContainsText(marker, timeout: 10),
            "Typed text should land in the editor with no manual click, proving focus returned there"
        )
    }

    // MARK: - Regression (judge review, 2026-09-10, t-784ff3aa): a card left mid-edit when
    // Focus Mode hides the Annotations panel. AnnotationCardView's `.onDisappear` previously
    // claimed to cover this but never actually fired -- Focus Mode hides the panel by
    // animating its own width to zero (AnnotationPanel stays "always mounted"), not by
    // unmounting it -- so the panel's separate `.onChange(of: editorState.isAnnotationPanelVisible)`
    // fix is what these two tests exercise.

    func testAnnotationCardEditClearedAfterFocusModeHideAndShow() throws {
        let originalText = "Focus Mode hide-and-show original card text"
        let markdown = """
        # Focus Mode Hide Edit Test

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
        editor.click()
        editor.typeText(" STALE EDIT")
        XCTAssertTrue(
            editor.waitForValue("CONTAINS 'STALE EDIT'", timeout: 5),
            "Typed marker text should land in the card's edit TextEditor before Focus Mode hides the panel"
        )

        // Enter Focus Mode WITHOUT resolving the edit first -- the panel hides (width animates
        // to zero, becomes non-hittable) while the card is still mid-edit with unsaved text.
        enterFocusModeAndWait()

        // Exit Focus Mode the same way it was entered (the toggle shortcut, not Esc -- this
        // test isolates the panel-visibility fix from the escape ladder's own separate
        // behavior, which the next test covers).
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.groups["status-bar"].waitForExistence(timeout: 10), "Status bar should reappear when Focus Mode turns off")

        // The card must NOT still be showing as mid-edit with the stale text: AnnotationPanel's
        // `.onChange(of: editorState.isAnnotationPanelVisible)` should have reset it the moment
        // the panel became invisible, well before this reappearance.
        XCTAssertFalse(
            annotationCardEditor(timeout: 3).exists,
            "Card should not still be in edit mode after Focus Mode hides and reshows the panel"
        )
        XCTAssertTrue(
            panelText(originalText, timeout: 10).exists,
            "Card should show its original text, not the stale in-progress edit"
        )
        XCTAssertFalse(
            panelText("\(originalText) STALE EDIT", timeout: 3).exists,
            "The stale edit text must not be visible anywhere in the panel"
        )
    }

    /// The second, distinct symptom the judge flagged: before the fix, a stale invisible edit
    /// stayed registered at the front of the escape ladder's `annotationEditOrder` even though
    /// its card was no longer visible or reachable, so a single Esc press in Focus Mode
    /// silently cancelled that invisible edit instead of exiting Focus Mode -- "Esc does
    /// nothing" from the user's perspective, requiring a second press to actually exit. With
    /// the fix, the edit is reset and unregistered the moment the panel becomes invisible, so a
    /// single Esc press exits Focus Mode directly.
    func testEscInFocusModeExitsDirectlyDespiteStaleAnnotationEditStartedBeforeHide() throws {
        let originalText = "Stale invisible edit original card text"
        let markdown = """
        # Stale Invisible Edit Esc Test

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
        editor.click()
        editor.typeText(" STALE")
        XCTAssertTrue(
            editor.waitForValue("CONTAINS 'STALE'", timeout: 5),
            "Typed marker text should land in the card's edit TextEditor before Focus Mode hides the panel"
        )

        // Enter Focus Mode WITHOUT resolving the edit -- the panel hides while the card is
        // still mid-edit. Before the fix, this left the edit registered at the front of the
        // escape ladder's annotationEditOrder even though the card is no longer visible.
        enterFocusModeAndWait()

        // A SINGLE Esc must exit Focus Mode directly -- it must not be silently absorbed by
        // the now-invisible annotation edit first.
        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.groups["status-bar"].waitForExistence(timeout: 10),
            "A single Esc should exit Focus Mode, not get absorbed by the stale invisible annotation edit"
        )
    }

    // MARK: - Item 9: Version History window's own Esc is independent of the main window's ladder

    func testVersionHistoryWindowEscOnlyClosesThatWindowMainWindowFocusModeUnaffected() throws {
        launchAndWaitForEditor()
        enterFocusModeAndWait()

        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        XCTAssertTrue(window.waitForExistenceOrFail(timeout: 15).exists, "Version History window should appear")

        // Its async load (Loading -> content or empty state) needs a moment to settle before a
        // click -- nothing observable distinguishes those states for the purpose of this test,
        // which only needs the window to be genuinely interactive, not any particular content.
        // e2e-lint: allow sleep -- see rationale above.
        Thread.sleep(forTimeInterval: 1.0)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            window.waitForDisappearance(timeout: 15),
            "Esc should close the Version History window (its own Close button carries "
                + ".keyboardShortcut(.escape, modifiers: []), untouched by the main window's ladder -- "
                + "AppDelegate.handleEscapeCandidate passes the event through untouched for any window "
                + "with no registered EscapeLadderContext)"
        )
        // Positive check that the main window is genuinely key/foreground before trusting the
        // Focus Mode assertion below -- without this, a false pass is possible in principle: if
        // the Esc keystroke or the window teardown left focus somewhere unexpected, `status-bar`
        // simply not existing would look identical to "Focus Mode is still on" even though
        // nothing meaningful was actually checked. activateAndWaitForForeground() XCTFails with
        // a clear message if the app isn't foreground; editorArea existing confirms the main
        // window's own content is present and queryable, not just that some window somewhere is.
        app.activateAndWaitForForeground()
        XCTAssertTrue(app.editorArea.exists, "Main window's editor should still be present and foreground after the Version History window closes")
        XCTAssertFalse(
            app.groups["status-bar"].exists,
            "Main window's Focus Mode must be unaffected by the Version History window's own Esc handling"
        )
    }

    // MARK: - Bug 2 (t-784ff3aa): a genuine NATIVE full-screen exit the app never requested,
    // following a single Esc press while the slash-command menu is open in Focus Mode --
    // confirmed live by the user, twice, with diagnostic logging on.
    //
    // EscapeLadder.swift / AppDelegate.handleEscapeCandidate correctly identify the slash menu
    // as the top, web-owned layer and correctly do nothing native for this Esc press
    // (`rung=webOwned`, no `apply rung=` line at all -- confirmed in the captured log), yet the
    // WINDOW's real native full-screen state exits anyway, roughly 700ms later, per
    // FullScreenManager's own `.lifecycle` log: a `didExit` with no preceding
    // `request received: windowed` / `toggle issued` line -- i.e. this app's own code never
    // asked to leave full screen; AppKit left it on its own.
    //
    // CONFIRMED root cause (not a resend race -- an earlier round of this task chased WebKit's
    // `doneWithKeyEvent` resend of the same NSEvent as the mechanism and added a dedup-consume
    // workaround in AppDelegate.swift; that workaround has since been reverted because it did
    // not fix this bug, confirmed live by a SECOND capture showing it in place with Focus Mode
    // still exiting anyway -- no resend involved that time either): `web/shared/escape-ladder.ts`
    // never called `event.preventDefault()` on the slash-menu-dismissal path. Left formally
    // unhandled at the DOM level, WebKit's own default key handling still ran after the JS layer
    // reacted to it -- resolving the unhandled Escape via the standard macOS key-binding table
    // (`cancelOperation:`) and forwarding THAT, synchronously, straight to the native side
    // (WKWebView -> WebPageProxy::executeSavedCommandBySelector -> the responder chain ->
    // SwiftUI's NSHostingView.doCommand(by:) -> AppKitWindow.exitFullScreenMode) -- a completely
    // different, synchronous channel from the JS-report/resend mechanisms either round chased
    // before. One keypress, two independent actions: the web layer correctly closing the slash
    // menu, AND WebKit's own default handling independently telling SwiftUI to exit full screen.
    // Fixed by making `escape-ladder.ts`'s shared listener call `preventDefault()` itself,
    // unconditionally, the moment it starts handling a non-composing Escape -- see that file's
    // own doc comment for the full mechanism, and `EscapeLadder.swift`'s
    // `shouldConsiderCandidate` doc comment for how this narrows (not eliminates) the resend
    // case the earlier round mis-targeted.
    //
    // This test still asserts on the window's actual native full-screen geometry (see
    // `isMainWindowNativeFullScreen()` in EscapeLadderE2ETestsHelpers.swift), not just `app.groups["status-bar"].exists` (the
    // app's own in-memory `focusModeEnabled` flag) -- every existing "Focus Mode still on" check
    // above uses that flag, which this bug's failure mode never touches, so only a geometry
    // check on the real native state can catch a silent leak like this one.
    func testEscInFocusModeWithSlashMenuOpenDoesNotSilentlyExitNativeFullScreen() throws {
        let bodyText = "Body paragraph for the native full-screen Esc regression test."
        let markdown = """
        # Native Full-Screen Esc Regression Test

        \(bodyText)
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()

        // Focus Mode always requests real native full screen unconditionally on entry
        // (EditorViewState+FocusMode.swift's enterFocusMode(), step 2) -- confirm that actually
        // landed as genuine native full screen before this test's own Esc press, not just that
        // the app's internal flag flipped.
        enterFocusModeAndWait()
        XCTAssertTrue(
            isMainWindowNativeFullScreen(),
            "Precondition: Focus Mode's own full-screen request should have landed as genuine native full screen before this test's Esc press"
        )

        // Every other Focus-Mode-plus-slash-menu test (e.g.
        // testEscThreeTimesInFocusModeClosesSlashMenuFirstUnderRealisticDocumentLoad,
        // EscapeLadderE2ETests.swift) opens
        // the find bar between enterFocusModeAndWait() and its own click into the editor, and
        // `searchField.waitForExistenceOrFail(...)` genuinely polls -- incidentally giving the
        // full-screen transition's layout reflow several extra seconds to settle before the click
        // lands. This test deliberately has no find bar (to match the user's real repro, see
        // comment below), so it loses that incidental cushion. A flat 2.0s sleep here never
        // passed (3/3 runs failed) -- replaced with a real settle gate: poll until the window's
        // native full-screen geometry reads true AND is stable across two reads ~250ms apart
        // (`waitForFullScreenReflowSettled`, EscapeLadderE2ETestsHelpers.swift -- the reflow has genuinely finished, not
        // merely "reads full-screen-sized for one instant mid-transition"), then re-confirm the
        // editor's own seeded content is still live before clicking into it.
        // enterFocusModeAndWait() itself and every other test stay untouched.
        waitForFullScreenReflowSettled(timeout: 10)
        XCTAssertTrue(
            app.editorContainsText(bodyText, timeout: 10),
            "Seeded paragraph should still be rendered and live once the full-screen reflow has settled"
        )

        // Click into the editor and open the slash menu (web layer) -- deliberately NO find bar
        // here, unlike the item-6/6b combo tests above, to match the user's actual repro as
        // closely as possible (this bug reproduced with the slash menu as the only other layer
        // open). Bounded retry (up to 3 attempts, mirroring this suite's other keystroke-retry
        // helpers -- e.g. `typeTextVerifyingLanded`, `toggleWysiwygToSource`): if the trigger
        // doesn't land, press Esc to clear any partial "/" state and re-click before trying
        // again, rather than failing on the very first miss.
        var slashMenuOpened = false
        for attempt in 1...3 {
            clickIntoEditor()
            app.typeKey(.downArrow, modifierFlags: .command)
            app.typeKey(.return, modifierFlags: [])
            app.activateAndWaitForForeground()
            app.typeText("/")
            if app.editorContainsText("Insert task annotation", timeout: 10) {
                slashMenuOpened = true
                break
            }
            if attempt < 3 {
                app.activateAndWaitForForeground()
                app.typeKey(.escape, modifierFlags: [])
                // Why this sleep is exempt from the fixed-wait lint: fixed back-off between retries
                // of this 3-attempt slash-menu loop, not a wait for a condition: after pressing
                // Escape to clear partial "/" state, nothing observable marks that teardown as
                // "done" before the next click/keystroke attempt, so there is nothing here to
                // poll for.
                // e2e-lint: allow sleep -- fixed back-off between retries, not a wait for a condition; nothing to poll for
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTAssertTrue(slashMenuOpened, "Slash menu should open with its command list within 3 attempts")

        // The one Esc press under test -- matches the user's exact repro.
        app.activateAndWaitForForeground()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.editorContainsText("Insert task annotation", timeout: 5), "Esc should close the slash menu")
        XCTAssertFalse(
            app.editorContainsText("/", timeout: 5),
            "The '/' trigger character itself should be deleted by Esc, not left behind in the document"
        )
        XCTAssertTrue(app.editorContainsText(bodyText, timeout: 5), "Original paragraph text should be untouched")

        // The app's OWN flag says Focus Mode is still on -- this is exactly the blind spot the
        // rest of this file cannot see past, since nothing on this path ever calls
        // FullScreenManager.request(.windowed).
        XCTAssertFalse(
            app.groups["status-bar"].exists,
            "Focus Mode's own flag should still read \"on\" here -- nothing native was ever requested for this Esc press"
        )

        // The bug: poll the window's REAL native full-screen state for several seconds past the
        // ~700ms delay reported live. Polls rather than a single fixed sleep (same rationale as
        // pollDiagnosticLog above) so the failure message can also report how long it actually
        // took to drop, if it does.
        let pollDeadline = Date().addingTimeInterval(3.0)
        let pollStart = Date()
        var stillNativeFullScreen = true
        while Date() < pollDeadline {
            stillNativeFullScreen = isMainWindowNativeFullScreen()
            if !stillNativeFullScreen { break }
            // Why this sleep is exempt from the fixed-wait lint: sampling interval of this bounded
            // poll loop over computed window geometry (`isMainWindowNativeFullScreen()`), not an
            // XCUIElement attribute, which is why it can't use this codebase's element-based
            // `waitFor*` helpers. Kept short (0.1s) so the elapsed time reported in the failure
            // message below is precise rather than rounded to a coarse step.
            // e2e-lint: allow sleep -- sampling interval of a bounded poll over computed window geometry, not an XCUIElement
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Date().timeIntervalSince(pollStart)
        XCTAssertTrue(
            stillNativeFullScreen,
            "Window's REAL native full-screen state should still be on ~\(String(format: "%.2f", elapsed))s after the Esc press -- "
                + "it silently exited full screen with no native request ever issued, even though the app's own Focus Mode flag "
                + "(status-bar) above stayed on throughout the whole check. This is the bug this test exists to catch -- see "
                + "FullScreenManager.handle(_:)'s willExit backtrace log (added this same round) for what actually triggered it "
                + "the next time this reproduces."
        )
    }
}
