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
//      `testUndoAfterHeadingBreakingEditInWysiwyg` (WYSIWYG): the two-press recovery
//      guarantee for an automatic correction that overlaps text the user just typed right
//      after a mode switch, in BOTH editors -- the first Cmd-Z undoes the correction (not
//      the typing), the correction does not immediately re-fire, and a second Cmd-Z then
//      removes the user's own typing and restores the original heading.
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
//  statistical power. The 2 dedicated two-press-recovery tests run their scenario once each
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

    /// WYSIWYG mirror of `testUndoAfterHeadingBreakingEditPostModeSwitch` -- same two-press
    /// recovery guarantee, staying in WYSIWYG mode throughout (typing lands in Milkdown
    /// after a Source->WYSIWYG switch, not CodeMirror).
    ///
    /// DIAGNOSED (live run, screen-recording-confirmed): unlike the Source-mode twin, the
    /// raw unmoved post-switch caret alone does NOT break a heading here. After a
    /// Source->WYSIWYG switch, the caret restores to position 0 INSIDE the H1 node, where
    /// `#` is a node ATTRIBUTE (the heading's level), not literal text -- typing ordinary
    /// characters there just renames the heading, leaving the document structurally valid,
    /// so the reconciler correction never fires. Fixed by typing `"### "` before the
    /// marker: Milkdown's commonmark heading input rule ADDS to a heading's level when
    /// typed at position 0 of an EXISTING heading (verified against the installed
    /// `@milkdown/preset-commonmark` source), so `"### "` turns the H1 into an H4 --
    /// violating "first section must be H1" and triggering the same reconciler correction
    /// the Source-mode test relies on. Level 3 specifically (not 1 or 2): leaves the H2
    /// sibling untouched (its own delta-floor check exempts it), producing exactly one
    /// heading change to correct -- cleanly mirroring the Source twin's single-change
    /// scenario. No click, no cursor repositioning added -- the caret itself is still the
    /// unmoved post-switch position; only the typed content changes.
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
        Self.recordDiagnosticLogStartOffsets()

        Thread.sleep(forTimeInterval: 0.3)
        app.activateAndWaitForForeground()
        // "### " at position 0 of the existing H1 invokes Milkdown's commonmark heading
        // input rule, which ADDS to the heading's current level -- turning the H1 into an
        // H4 (violates "first section must be H1") -- rather than just prefixing literal
        // text onto it. This is what actually breaks the heading here; see this test's own
        // doc comment for the full diagnosis of why the caret position alone doesn't.
        app.typeText("### ")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText(marker)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            markerPresent(marker),
            "Marker text did not land anywhere in editor-area after typing with no click -- " +
            "cannot evaluate the two-press recovery scenario without this landing first."
        )

        Thread.sleep(forTimeInterval: 2.0)
        assertHierarchyCorrectionDidFire(direction: "WYSIWYG mode, post-Source->WYSIWYG switch")

        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(
            markerPresent(marker),
            "First Cmd-Z should undo the automatic heading correction, NOT the user's own " +
            "typing -- the marker text should still be present immediately afterward."
        )

        Self.recordDiagnosticLogStartOffsets()
        Thread.sleep(forTimeInterval: 2.0)
        let deltaAfterFirstUndo = Self.currentDiagnosticLogContents()
        XCTAssertFalse(
            deltaAfterFirstUndo.contains("[SYNC-DIAG:Hierarchy]"),
            "The hierarchy correction re-fired within 2s of the first Cmd-Z undoing it in " +
            "WYSIWYG mode -- P3 §4d suppression should have prevented an immediate " +
            "re-correction."
        )

        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertFalse(
            markerPresent(marker),
            "Second Cmd-Z should have removed the user's typed marker text, restoring the " +
            "original heading -- it did not."
        )
    }
}
