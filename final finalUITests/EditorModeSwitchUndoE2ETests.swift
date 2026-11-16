//
//  EditorModeSwitchUndoE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression suite for the undo-mode-switch-focus bug and its two-press
//  recovery extension (Phase A of the unified-undo effort -- docs/architecture/
//  unified-undo.md): "switching editor mode (WYSIWYG<->Source, via Cmd-/ or the
//  status-bar mode badge) breaks Cmd-Z immediately afterward." Committed (not the
//  disposable `E2EScratchTests.swift` scratch convention) per the remediation plan's own
//  requirement to seed a permanent regression suite for this bug class, once root cause
//  and fix landed and were judge-approved. Confirmed live across two consecutive full
//  green runs of all 5 methods below.
//
//  Root cause (full detail: CodeMirrorCoordinator+Handlers.swift's `shouldPushContent` doc
//  comment): `updateSourceContentIfNeeded()` rebuilds Source-mode content from the DB and
//  reassigns `editorState.sourceContent` at arbitrary, sometimes notification-driven
//  moments -- including mid-typing right after a mode switch. The push guard had no "is the
//  user mid-edit" check, so a derived refresh landing in that window silently rewrote the
//  exact span the user just typed into; CodeMirror's `setContent` dispatches that rewrite as
//  a non-history transaction, which REMAPS (not clears) the existing undo branch and DROPS
//  history events whose changes map away -- taking the user's undo event with it, with no
//  visible error. The fix added a settle-window guard keyed off the last real local edit,
//  bypassed only for explicitly-flagged intentional replacements (zoom, project switch,
//  structural undo/redo).
//
//  What this suite covers:
//    - `testUndoAfterWysiwygToSourceViaMenuShortcut` / `testUndoAfterSourceToWysiwygViaMenuShortcut`:
//      both directions, triggered via the Cmd-/ menu shortcut.
//    - `testUndoAfterWysiwygToSourceViaStatusBarBadge`: the status-bar mode-badge click
//      trigger path, distinct from the keyboard shortcut.
//    - `testUndoAfterHeadingBreakingEditPostModeSwitch` (Source) /
//      `testUndoAfterHeadingBreakingEditInWysiwyg` (WYSIWYG): the recovery guarantee for an
//      automatic correction that overlaps text the user just typed right after a mode
//      switch, in BOTH editors -- the first Cmd-Z undoes the correction (not the typing) and
//      the correction does not immediately re-fire. Source: a second Cmd-Z then removes the
//      user's own typing and restores the original heading. WYSIWYG: the heading-breaking
//      `### ` is the user's LAST keystroke (typed after a marker), so three presses: the
//      correction, then the `### `, then the marker.
//
//  DELIBERATELY EXCLUDED: typing in the OLD editor BEFORE the switch, then undoing AFTER
//  the switch (cross-editor undo-history transfer). A freshly-mounted CodeMirror/Milkdown
//  instance starts with an EMPTY undo history seeded from the settled markdown, so undoing
//  content typed in a DIFFERENT, now-torn-down editor instance is a materially different
//  architectural limitation -- not a focus/routing/push-guard defect, and not this suite's
//  job. Filed at `docs/deferred/cross-editor-undo-history-transfer.md`. Every test below
//  types AFTER the switch completes, into the SAME editor instance it then undoes from,
//  matching the actual bug's own reproduction shape (and the original fix's own
//  verification note: "undoing something typed right after the switch with no manual
//  click").
//
//  Each of the 3 regression tests loops its switch -> type -> undo cycle several times
//  within ONE app launch and asserts every iteration: this bug was intermittent (a
//  content-push race, not a deterministic wiring defect), so a single pass proves nothing --
//  one VM boot samples the race repeatedly instead of needing several boots for the same
//  statistical power. The 2 dedicated heading-breaking recovery tests run their scenario once each
//  (the correction they pin is deterministic given the fixture, not intermittent).
//

import XCTest

final class EditorModeSwitchUndoE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// How many switch -> type -> undo cycles each test runs within its one app launch.
    /// Lowered from 4 to 2 (2026-09-04, the test-tiers-ship plan): this class alone took ~9
    /// minutes of the unscoped full-suite run because three tests each looped this cycle 4
    /// times. 2 iterations still proves the cycle is stable across a repeat, not a one-shot
    /// fluke, which is what this coverage is actually for -- it does not need 4 to do that.
    static let iterationsPerTest = 2

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        // t-177a10f1: the mode-toggle helpers read the app's diagnostic log to tell a toggle the app RECEIVED ("[TRANS] toggle received")
        // from a dropped keypress, so the log must exist in every test of this class (the launch argument each test also adds is not
        // enough on its own -- see "A test that reads diagnostic.log must launch with FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING").
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Tests

    /// WYSIWYG -> Source, triggered via the Cmd-/ menu shortcut. No manual click at any
    /// point -- focus in the new editor must come entirely from `restoreEditorFocus`'s
    /// automatic `makeFirstResponder`.
    func testUndoAfterWysiwygToSourceViaMenuShortcut() throws {
        // Must be set BEFORE launchForTesting() calls launch(). Turns on the runtime
        // Diagnostics toggle so the permanent [CodeMirrorEditor]/[UnifiedUndo]/
        // [SYNC-DIAG:Hierarchy] logging (already shipping, normally silent unless a user
        // turns this on) reaches the retrievable diagnostic log file --
        // `assertHierarchyCorrectionDidNotFire` (called from `runTypeSwitchUndoCycle`)
        // reads from it every iteration.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        for iteration in 1...Self.iterationsPerTest {
            toggleWysiwygToSource()
            // Keyboard-only reposition to a heading-safe spot before typing -- see
            // moveCursorToDocumentEndViaKeyboard()'s doc comment for why this test moved
            // away from the raw post-switch cursor-restore position.
            moveCursorToDocumentEndViaKeyboard()
            try runTypeSwitchUndoCycle(
                marker: "MenuW2S_\(iteration)_\(shortUUID())", iteration: iteration,
                direction: "WYSIWYG->Source (Cmd-/ trigger)")
            // Reset to WYSIWYG for the next iteration (also leaves the editor in a clean
            // starting state at test end).
            toggleSourceToWysiwyg()
        }
    }

    /// The reverse direction: Source -> WYSIWYG, triggered via the Cmd-/ menu shortcut.
    /// Reaching Source first is setup only, not itself under test.
    func testUndoAfterSourceToWysiwygViaMenuShortcut() throws {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Setup only -- reach Source first. Generous settle margin (this suite's documented
        // caution: the label flips before the async WYSIWYG<->CodeMirror view swap
        // necessarily finishes) since a second switch follows it immediately below.
        toggleWysiwygToSource()
        Thread.sleep(forTimeInterval: 1.0)

        for iteration in 1...Self.iterationsPerTest {
            toggleSourceToWysiwyg()
            moveCursorToDocumentEndViaKeyboard()
            try runTypeSwitchUndoCycle(
                marker: "MenuS2W_\(iteration)_\(shortUUID())",
                iteration: iteration,
                direction: "Source->WYSIWYG (Cmd-/ trigger)"
            )
            // Reset to Source for the next iteration.
            toggleWysiwygToSource()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Same direction as `testUndoAfterWysiwygToSourceViaMenuShortcut` (WYSIWYG -> Source)
    /// but triggered by clicking the status-bar mode badge instead of Cmd-/ -- the trigger
    /// path the remediation plan flagged as never having been exercised anywhere in this
    /// suite.
    func testUndoAfterWysiwygToSourceViaStatusBarBadge() throws {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        for iteration in 1...Self.iterationsPerTest {
            clickModeBadge()
            moveCursorToDocumentEndViaKeyboard()
            try runTypeSwitchUndoCycle(
                marker: "BadgeW2S_\(iteration)_\(shortUUID())",
                iteration: iteration,
                direction: "WYSIWYG->Source (badge-click trigger)"
            )
            // Reset to WYSIWYG for the next iteration -- via the keyboard shortcut, not the
            // badge; only the WYSIWYG->Source direction is under test via the badge here.
            toggleSourceToWysiwyg()
        }
    }

    // MARK: - Dedicated heading-breaking two-press recovery tests

    /// Pins the two-press recovery guarantee this whole round's fix is actually FOR: type
    /// at the SAME risky, unmoved post-switch cursor-restore position the 3 tests above now
    /// deliberately move AWAY from (no keyboard repositioning here -- this scenario is what
    /// those tests exist to avoid), wait for the reconciler's correction to genuinely land
    /// (asserted from the `.sync` log, not assumed -- a vacuous pass would prove nothing),
    /// then prove: Cmd-Z undoes the CORRECTION first (not the typing), the correction does
    /// not immediately re-fire, and a SECOND Cmd-Z then removes the typed text and restores
    /// the original heading.
    func testUndoAfterHeadingBreakingEditPostModeSwitch() throws {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        toggleWysiwygToSource()

        let marker = "HeadingBreak_S_\(shortUUID())"
        Self.recordDiagnosticLogStartOffsets()

        // Deliberately NO keyboard repositioning -- type right where automatic post-switch
        // cursor restoration lands, which is the scenario that actually breaks a heading.
        Thread.sleep(forTimeInterval: 0.3)
        app.activateAndWaitForForeground()
        app.typeText(marker)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            markerPresent(marker),
            "Marker text did not land anywhere in editor-area after typing with no click -- " +
            "cannot evaluate the two-press recovery scenario without this landing first."
        )

        // Wait for the reconciler's correction to actually run, and ASSERT it did --
        // otherwise this test would pass vacuously without ever proving the scenario
        // actually happened.
        Thread.sleep(forTimeInterval: 2.0)
        assertHierarchyCorrectionDidFire(direction: "Source mode, post-WYSIWYG->Source switch")

        // First Cmd-Z: must undo the CORRECTION, not the user's typing -- the marker
        // should still be present, proving undo reached for the correction first.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(
            markerPresent(marker),
            "First Cmd-Z should undo the automatic heading correction, NOT the user's own " +
            "typing -- the marker text should still be present immediately afterward. If " +
            "it's gone, undo skipped past the correction straight to the typing, which is " +
            "the ORIGINAL undo-mode-switch-focus regression, not the two-press recovery " +
            "this test exists to prove."
        )

        // Wait and confirm the correction does NOT immediately re-fire (P3 §4d
        // suppression) -- this is the specific scenario the user's own acceptance test
        // describes: "wait two seconds without typing -- it should NOT immediately
        // re-tidy it."
        Self.recordDiagnosticLogStartOffsets()
        Thread.sleep(forTimeInterval: 2.0)
        let deltaAfterFirstUndo = Self.currentDiagnosticLogContents()
        XCTAssertFalse(
            deltaAfterFirstUndo.contains("[SYNC-DIAG:Hierarchy]"),
            "The hierarchy correction re-fired within 2s of the first Cmd-Z undoing it -- " +
            "P3 §4d suppression should have prevented an immediate re-correction."
        )

        // Second Cmd-Z: now undoes the user's own typed marker, restoring the original
        // heading.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertFalse(
            markerPresent(marker),
            "Second Cmd-Z should have removed the user's typed marker text, restoring the " +
            "original heading -- it did not."
        )
    }

    /// WYSIWYG counterpart of `testUndoAfterHeadingBreakingEditPostModeSwitch` -- the same guarantee
    /// that the first Cmd-Z undoes an automatic heading correction (not the user's typing), staying
    /// in WYSIWYG mode throughout (typing lands in Milkdown after a Source->WYSIWYG switch, not
    /// CodeMirror). Unlike the Source twin it takes three Cmd-Z presses, because a marker is typed
    /// before the heading-breaking edit (see the order of the keystrokes below).
    ///
    /// ORDER OF THE KEYSTROKES (t-e006ebc5): the marker is typed FIRST and the heading-breaking
    /// `"### "` is the user's LAST keystroke, as in the Source twin. This test used to type
    /// `"### "` first and the marker after it, expecting the first Cmd-Z to undo the correction
    /// while the marker typing was untouched. Since Phase 5 (a415ea93, 2026-11-08, the 2 s poll
    /// is gone) the page reports the break at once and the correction lands about 0.9 s later,
    /// BEFORE most of the marker's keystrokes; it is its own undo step (`dispatchDerivedCorrection`
    /// closes the history around it), so the first Cmd-Z correctly undid the NEWEST step, the
    /// marker typing, and the test failed on every run at "First Cmd-Z should undo the
    /// automatic heading correction". Nothing was wrong in the app; the premise "the correction
    /// is the newest history step" was false. With the break last, nothing is typed after it, so
    /// the correction really is the newest step.
    ///
    /// Why `"### "` breaks the heading at all (diagnosed from a live run, screen-recording
    /// confirmed): the raw unmoved post-switch caret alone does NOT break a heading here. After
    /// a Source->WYSIWYG switch the caret restores to position 0 INSIDE the H1 node, where `#`
    /// is a node ATTRIBUTE (the heading's level), not literal text, so typing ordinary
    /// characters there just renames the heading and the document stays valid. That is why the
    /// marker, typed there first, breaks nothing. Milkdown's commonmark heading input rule ADDS
    /// to a heading's level when `"### "` is typed at position 0 of an EXISTING heading
    /// (verified against the installed `@milkdown/preset-commonmark` source), so `"### "` turns
    /// the H1 into an H4 -- violating "first section must be H1" and triggering the reconciler
    /// correction the Source-mode test relies on. Level 3 specifically (not 1 or 2) leaves the
    /// H2 sibling untouched, producing exactly one heading change to correct.
    ///
    /// The marker and the `"### "` must be separate undo steps: ProseMirror groups edits typed
    /// within `newGroupDelay` (500 ms) of each other, and both sit at the start of the heading
    /// (adjacent), so a 0.8 s pause separates them, and Cmd-Up moves the caret from the end of
    /// the marker back to the start of the document before the `"### "`.
    ///
    /// What each Cmd-Z proves, in order (the heading row is read from the fixture database by
    /// the marker it contains, because the marker is the only handle that survives the level
    /// changes):
    ///   1. Cmd-Z #1 undoes the CORRECTION: the marker is still on screen and the row is at level
    ///      4 again. Undoing the user's `"### "` instead would have given level 1, and undoing
    ///      the marker would have removed it. The correction must not re-fire for 2 s.
    ///   2. Cmd-Z #2 undoes the user's `"### "` in ONE step: the row is back at level 1 and no `#`
    ///      is left in its text after the heading's own `# ` (a leftover `#`, `##` or `###` would
    ///      mean the four keystrokes landed in separate undo steps).
    ///   3. Cmd-Z #3 undoes the marker typing: in the saved document no row holds the marker and
    ///      the first heading is the fixture's `# Test Document` at level 1 again. Only the
    ///      document's start is compared, not the rest of the fixture.
    func testUndoAfterHeadingBreakingEditInWysiwyg() throws {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Reach WYSIWYG via a real mode switch (Source -> WYSIWYG) -- this suite's whole
        // premise is post-mode-switch cursor restoration, so simply starting in WYSIWYG
        // (the app's own default) would never exercise it.
        toggleWysiwygToSource()
        Thread.sleep(forTimeInterval: 1.0)
        toggleSourceToWysiwyg()

        let marker = "HeadingBreak_W_\(shortUUID())"

        // The marker first, at the unmoved post-switch caret (position 0 inside the H1): this
        // only renames the heading, so no hierarchy violation and no correction yet.
        Thread.sleep(forTimeInterval: 0.3)
        app.activateAndWaitForForeground()
        app.typeText(marker)

        XCTAssertTrue(
            markerPresent(marker),
            "Marker text did not land anywhere in editor-area after typing with no click -- " +
            "cannot evaluate the two-press recovery scenario without this landing first."
        )

        // A pure time gap, nothing observable to wait for: ProseMirror's history merges edits
        // typed within newGroupDelay (500 ms) of each other, and the `"### "` below lands next
        // to the marker, so without this pause both could become one undo step.
        Thread.sleep(forTimeInterval: 0.8)

        // Back to the start of the document (the start of the H1), then the heading-breaking
        // edit as the user's LAST keystroke. The log checkpoint sits after the marker, so the
        // correction asserted below is proven to come after all of the user's typing.
        app.activateAndWaitForForeground()
        app.typeKey(.upArrow, modifierFlags: .command)
        Self.recordDiagnosticLogStartOffsets()
        // "### " at position 0 of the existing H1 invokes Milkdown's commonmark heading input
        // rule, which ADDS to the heading's current level -- turning the H1 into an H4
        // (violates "first section must be H1") rather than prefixing literal text onto it.
        app.typeText("### ")

        // The correction lands about 0.9 s after the break; 2 s leaves margin.
        Thread.sleep(forTimeInterval: 2.0)
        assertHierarchyCorrectionDidFire(direction: "WYSIWYG mode, post-Source->WYSIWYG switch")

        // Cmd-Z #1: the correction is the newest history step, so it is undone and nothing else.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Self.recordDiagnosticLogStartOffsets()

        XCTAssertTrue(
            markerPresent(marker),
            "First Cmd-Z should undo the automatic heading correction, NOT the user's own " +
            "typing -- the marker text should still be present immediately afterward."
        )
        // Bounded wait for the undo to reach the database. Level 4 means the correction (H4 back
        // to H1) was undone; undoing the user's `###` would have shown level 1 instead.
        let afterFirstUndo = waitForHeadingLevel(containing: marker, toBe: 4, timeout: 2)
        XCTAssertTrue(
            afterFirstUndo?.reached == true,
            "First Cmd-Z should undo the automatic heading correction (the heading comes back as an H4), " +
            "but the database heading row holding marker \"\(marker)\" did not reach headingLevel 4 within 2s. " +
            "Found: \(HeadingRowReading.describe(afterFirstUndo)). Level 1 means the undo also took out the user's " +
            "own \"### \" (or had not reached the database); no row means it removed the marker."
        )

        // The correction must not immediately re-fire (P3 §4d suppression) -- the user's own
        // acceptance test: "wait two seconds without typing -- it should NOT immediately
        // re-tidy it." The log window opened at the Cmd-Z and closes 2 s after the undo showed
        // in the database.
        Thread.sleep(forTimeInterval: 2.0)
        let deltaAfterFirstUndo = Self.currentDiagnosticLogContents()
        XCTAssertFalse(
            deltaAfterFirstUndo.contains("[SYNC-DIAG:Hierarchy]"),
            "The hierarchy correction re-fired within 2s of the first Cmd-Z undoing it in " +
            "WYSIWYG mode -- P3 §4d suppression should have prevented an immediate " +
            "re-correction."
        )

        // Cmd-Z #2: undoes the user's own `"### "` in one step, restoring the original level.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        let afterSecondUndo = waitForHeadingLevel(
            containing: marker, toBe: 1, timeout: 3, textAfterLeadingHashesMustNotContain: "#")
        XCTAssertTrue(
            afterSecondUndo?.reached == true,
            "Second Cmd-Z should undo the user's own \"### \" in one step, but the database heading row holding " +
            "marker \"\(marker)\" did not reach headingLevel 1 with no leftover \"#\" in its text within 3s. " +
            "Found: \(HeadingRowReading.describe(afterSecondUndo)). A row at level 1 that still has leftover \"#\" " +
            "characters in its text means the four \"### \" keystrokes landed in separate undo steps."
        )

        // Cmd-Z #3: undoes the marker typing. Read from the database, not the accessibility tree:
        // an absence check on the tree also passes when the tree is stale or empty. The saved
        // start of the document must be the fixture's again; the rest is not compared.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        let afterThirdUndo = waitForDocumentStartBackToFixture(withoutMarker: marker, timeout: 3)
        XCTAssertTrue(
            afterThirdUndo?.reached == true,
            "Third Cmd-Z should have removed the user's typed marker \"\(marker)\", but the saved document start did " +
            "not return to the fixture's (no row holding the marker, first heading \"\(Self.fixtureFirstHeadingFragment)\" " +
            "at level 1) within 3s. Found: \(DocumentStartReading.describe(afterThirdUndo))."
        )
    }
}

// MARK: - A switch held past the helpers' retry window is never toggled twice (t-177a10f1)

extension EditorModeSwitchUndoE2ETests {
    /// How long the app holds each of the first three CARRIED switches (`FF_UI_TESTING_TRANS_HOLD_MS`): longer than the toggle
    /// helpers' 2 s receipt window, so a helper that resends a press whose label has not flipped yet WILL resend here, which is what
    /// a slow host (two VMs running) does to the real switch.
    static let heldSwitchMs = 3000

    /// The bounded time the probe watches for a held second press to show itself as a label that flips back: the hold, plus the time
    /// the next switch needs to prepare its page, plus margin.
    static let heldSwitchSettle: TimeInterval = 6

    /// The carried switch flips the status-bar label only after the incoming page is ready, and the app HOLDS a second Cmd-/ and applies
    /// it afterwards (never drops it). The toggle helpers used to press again whenever the label had not flipped within 2 s; on a slow
    /// host that resend reached the app while the first switch was still running, and the app switched straight back, so the test
    /// failed at "CodeMirror source editor should render the raw markdown" (or its mirror) with nothing wrong in the app.
    ///
    /// This probe asks the app (its own test seam, the first three carried switches) to hold each switch for `heldSwitchMs` and drives
    /// Rich Text -> Markdown -> Rich Text -> Markdown with the real helpers. After EVERY call it asserts, from the app's own log, that
    /// the app received exactly ONE toggle, and, polling for a CHANGE for a bounded `heldSwitchSettle`, that the label still shows the
    /// mode the call asked for (a held second press would flip it back). After the Rich Text call the Markdown editor's evidence must
    /// be gone; after the Markdown calls it must still be there.
    ///
    /// The hold is required only on call 2 (Markdown -> Rich Text, the carried switch the original failure was in). The first switch
    /// after launch can take the app's OLD, unheld path: the driver's first run of this probe (run-1794811507-91803) logged "CodeMirror
    /// claim failed: state=idle" and "[SWITCH->CM] Starting" with no "[TRANS-HOLD]" line, because a switch only takes the carried path
    /// once the Rich Text page is registered with block sync (`usesCarriedSwitch`), which a freshly launched, slow VM may not have
    /// reached yet. Such a switch is neither held nor counted against the hold budget, so calls 1 and 3 do not fail on a missing hold
    /// line; they still must show exactly one received toggle and no flip-back.
    func testSwitchHeldPastRetryWindowIsNotToggledTwice() throws {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_MS"] = String(Self.heldSwitchMs)
        app.launchEnvironment["FF_UI_TESTING_TRANS_HOLD_FIRST_N"] = "3"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()
        // Bounded, best-effort readiness nudge: the word count above reads "words" before the editor page exists, so wait for the
        // document's own heading to render (an existing helper, no sleep). Not asserted: call 1 does not need the carried path.
        _ = app.editorStaticText(startingWith: "Test Document", timeout: 20)

        let editorMode = app.buttons["status-bar-editor-mode"]

        func callAndWatch(_ step: String, expecting label: String, requireHold: Bool, toggle: () -> Void) {
            let before = DiagnosticLogReader.sizesNow()
            toggle()
            // Polls for a CHANGE, bounded: a held second press shows itself as the label leaving `label`; the pass case waits it out.
            let flippedAway = editorMode.waitForLabelNot("== '\(label)'", timeout: Self.heldSwitchSettle)
            let logText = DiagnosticLogReader.text(since: before)
            let received = DiagnosticLogReader.toggleReceivedCount(since: before)
            let held = logText.contains("hold begins for \(Self.heldSwitchMs) ms")
            let attachment = XCTAttachment(string: logText)
            attachment.name = "diagnostic-log-\(step)-\(held ? "held" : "not-held")"
            attachment.lifetime = .keepAlways
            add(attachment)

            if requireHold {
                XCTAssertTrue(
                    held,
                    "TEST-SETUP (\(step)): the app logged no \"[TRANS-HOLD] ... hold begins for \(Self.heldSwitchMs) ms\" line, so the " +
                    "switch was not held past the helpers' 2 s receipt window and this run proves nothing about a resend."
                )
            }
            XCTAssertEqual(
                received, 1,
                "\(step): the app received \(received) mode toggles for one helper call (expected 1) -- the helper pressed again " +
                "for a switch the app already had, which the app holds and applies afterwards, switching straight back."
            )
            XCTAssertFalse(
                flippedAway,
                "\(step): the status-bar label left \"\(label)\" within \(Self.heldSwitchSettle)s of the helper returning -- a second " +
                "toggle held behind the first switch was applied afterwards."
            )
        }

        callAndWatch("1 Rich Text to Markdown", expecting: "Markdown", requireHold: false, toggle: toggleWysiwygToSource)
        waitForSourceEditorMounted()

        callAndWatch("2 Markdown to Rich Text", expecting: "Rich Text", requireHold: true, toggle: toggleSourceToWysiwyg)
        waitForSourceEditorUnmounted()

        callAndWatch("3 Rich Text to Markdown", expecting: "Markdown", requireHold: false, toggle: toggleWysiwygToSource)
        waitForSourceEditorMounted()
    }
}
