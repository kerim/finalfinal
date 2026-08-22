//
//  UnifiedUndoE2ETests.swift
//  final finalUITests
//
//  PERMANENT e2e regression suite for the unified chronological undo system
//  (docs/architecture/unified-undo.md, docs/plans/steady-unwinding-ledger.md §8 "Phase D").
//  Committed (not the disposable `E2EScratchTests.swift` scratch convention) per that plan's
//  own requirement: this feature's three live-caught bugs (find bar, mode switch x2) were all
//  in exactly the layer unit tests cannot see -- AppKit focus, WebView lifecycle, real keystroke
//  routing -- and every scenario the plan's own §8 required had, until now, only ever been run
//  as disposable scratch code that got discarded after each phase.
//
//  Mode-switch's own two directions/two trigger paths already have a dedicated permanent suite
//  (`EditorModeSwitchUndoE2ETests.swift`, landed in Phase A of this same remediation) -- not
//  duplicated here. This file covers everything else from plan §8: the canonical
//  restore/reorder/undo/redo sequence, post-undo typing non-interference, the find-bar focus
//  regression, delete/duplicate undo, the H1 laundering probe, refusal fall-through sanity, the
//  citation-bearing scenario (Task 2's Zotero seam, proving N1's `cancelPendingInsertions` port
//  holds up live), and the debug-only eviction-cap launch argument (Task 3).
//
//  Ground truth for structural (as opposed to plain text) assertions is a direct, read-only
//  `sqlite3` query against the fixture's `content.sqlite` -- via `FixtureDatabase`
//  (UITestHelpers.swift) -- rather than parsing the sidebar's rendered card layout. This mirrors
//  `E2ESectionReconcilerPseudoSectionTests.swift`'s established, safe-while-the-app-is-open (WAL
//  mode) pattern, and matters specifically for reorder: a reorder doesn't change word count or
//  section count, so only an order-sensitive read can distinguish "reorder happened and undo/
//  redo walk it correctly" from a no-op. Word count (`status-bar-word-count`, this codebase's
//  established assertion style) is used everywhere else it's sufficient.
//
//  UNVERIFIED LIVE (flagged per-site below too): this file contains this suite's first-ever
//  drag-and-drop interaction (`dragSidebarCard`, XCUITest's own synthetic press-then-drag -- see
//  its doc comment) and reuses a SwiftUI `.alert()` dialog-button pattern
//  (`saveVersion`/`restoreFullProject`) that has never been driven from a COMMITTED test before
//  (only ever from disposable scratch code per the architecture doc's Tier-1 account). Per this
//  codebase's own e2e history, a first vmtest pass finding query/timing bugs here is expected,
//  not unusual -- see this file's own per-helper comments for exactly which assumptions to
//  check first.
//

import XCTest

final class UnifiedUndoE2ETests: XCTestCase {
    var app: XCUIApplication!

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

    // MARK: - Test 1: the canonical scenario

    /// Restore -> reorder -> undo -> undo -> redo -> redo (plan §8 item 1 / original plan §1).
    /// Ground-truthed at the DB level throughout (see file header) since a reorder alone doesn't
    /// move word/section counts.
    func testCanonicalRestoreReorderUndoUndoRedoRedo() throws {
        seedCanonicalDocument()
        launchAndWaitForEditor()

        let baselineOrder = ["Anchor Section", "Middle Section", "Last Section"]
        // The committed fixture ships with ZERO `section` rows -- they're created by post-launch
        // sync, not shipped in the fixture. `launchAndWaitForEditor()` only proves editor JS is
        // up, not that sync has run yet. Poll instead of asserting immediately (established
        // precedent for this exact race: E2ESectionReconcilerPseudoSectionTests.swift's own
        // "let the real project-open sync... populate real section rows" wait).
        let initialTitles = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0 == baselineOrder })
        XCTAssertEqual(
            initialTitles, baselineOrder,
            "Seeded document should start with all three sections in source order"
        )

        // 1. Save a named version capturing the 3-section baseline -- the snapshot the later
        //    "restore" step restores FROM.
        saveVersion(named: "E2ECanonicalBaseline")

        // 2. Delete "Last Section" -- gives the restore step a real, observable content
        //    difference to restore away. This is itself a recorded structural entry UNDER the
        //    two entries the scenario below actually walks (restore, reorder) -- harmless; it's
        //    never touched by either undo/redo pair asserted here.
        rightClickSidebarCard(titled: "Last Section", thenChooseMenuItem: "Delete Section")
        let afterDelete = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0.count == 2 })
        XCTAssertEqual(afterDelete, ["Anchor Section", "Middle Section"], "Delete should remove exactly \"Last Section\"")

        // 3. Restore the named baseline snapshot (full-project restore) -- brings "Last Section"
        //    back.
        restoreFullProject(snapshotNamed: "E2ECanonicalBaseline")
        let afterRestore = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0 == baselineOrder })
        XCTAssertEqual(afterRestore, baselineOrder, "Restore should bring the document back to the saved 3-section baseline")

        // 4. Reorder: drag "Middle Section" to just after "Last Section" (dragSidebarCard's own
        //    doc comment traces the drop-zone math this depends on -- a title-text coordinate can
        //    only ever land in the `insertAfter` zone, never `insertBefore`, so the scenario is
        //    built around that rather than the reverse drag this test used before). Exact
        //    resulting order is CAPTURED here and used as the redo target below, never assumed --
        //    what matters is that SOME reorder happened and undo/redo walk it correctly.
        dragSidebarCard(titled: "Middle Section", toward: "Last Section")
        let afterReorder = waitUntil(
            probe: { queryOrderedSectionTitles() },
            predicate: { $0.count == 3 && $0 != baselineOrder }
        )
        // Two independent failure modes, distinguished so a failure here doesn't read as a
        // product bug when it's test-coordinate mechanics: (a) the drag never registered at all
        // (order is still exactly baselineOrder -- see next assertion), vs. (b) it registered but
        // something is structurally wrong (a section went missing/duplicated -- this assertion).
        XCTAssertEqual(
            Set(afterReorder), Set(baselineOrder),
            "Reorder should still contain exactly the same three sections (got \(afterReorder), " +
            "expected some permutation of \(baselineOrder)) -- a section going missing or " +
            "duplicating here would be a real structural bug, not a drag-coordinate problem"
        )
        XCTAssertNotEqual(
            afterReorder, baselineOrder,
            "Reorder should have actually changed the section order from \(baselineOrder), but " +
            "it's unchanged -- if this fails again after dragSidebarCard's two confirmed fixes " +
            "(gesture registration, insertAfter-only zone targeting), treat it as a fresh drag-" +
            "mechanics finding, not a repeat of either already-fixed cause"
        )

        // 5. Undo #1: should undo the REORDER, landing back on the restored baseline order.
        pressUndo()
        let afterUndo1 = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0 == baselineOrder })
        XCTAssertEqual(afterUndo1, baselineOrder, "First undo should undo the reorder, restoring the post-restore order")

        // 6. Undo #2: should undo the RESTORE, landing back on the post-delete (2-section) state.
        pressUndo()
        let afterUndo2 = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0.count == 2 })
        XCTAssertEqual(
            afterUndo2, ["Anchor Section", "Middle Section"],
            "Second undo should undo the restore, landing back on the pre-restore (post-delete) state"
        )

        // 7. Redo #1: should redo the RESTORE, bringing "Last Section" back in baseline order.
        pressRedo()
        let afterRedo1 = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0 == baselineOrder })
        XCTAssertEqual(afterRedo1, baselineOrder, "First redo should redo the restore")

        // 8. Redo #2: should redo the REORDER, landing back on the exact order captured in step
        //    4, not merely "some" reordered state.
        pressRedo()
        let afterRedo2 = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0 == afterReorder })
        XCTAssertEqual(
            afterRedo2, afterReorder,
            "Second redo should redo the reorder, reproducing the exact order captured after the original drag"
        )
    }

    // MARK: - Test 2: post-undo typing non-interference

    /// A regression class this feature's checkpoint-swap machinery could plausibly break: after
    /// a structural undo/redo sequence completes, normal typing must still land in the right
    /// place, and be itself a normal, undoable text edit (proves block-sync/text-history weren't
    /// left frozen or pointed at a stale checkpoint).
    func testTypingAfterUndoRedoSequenceLandsCorrectly() throws {
        launchAndWaitForEditor()

        // A short structural undo/redo/undo sequence right before typing, netting zero
        // structural change but exercising the checkpoint-swap machinery
        // (docs/architecture/unified-undo.md's "Checkpoints" section). Each step's return value
        // is asserted, not discarded -- if the duplicate/undo/redo never actually happened, the
        // document is trivially unchanged from baseline, and a discarded waitUntil would let
        // this test pass vacuously without ever proving the sequence ran.
        rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Duplicate Section")
        XCTAssertEqual(waitUntil(probe: { querySectionCount() }, predicate: { $0 == 3 }), 3, "Duplicate should raise section count to 3")
        pressUndo()
        XCTAssertEqual(waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 }), 2, "First undo should remove the duplicate")
        pressRedo()
        XCTAssertEqual(waitUntil(probe: { querySectionCount() }, predicate: { $0 == 3 }), 3, "Redo should bring the duplicate back")
        pressUndo()
        XCTAssertEqual(waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 }), 2, "Second undo should remove the duplicate again")

        clickIntoEditor()
        app.activateAndWaitForForeground()
        let marker = "PostUndoTyping_\(shortUUID())"
        app.typeText(marker)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(markerPresent(marker), "Typing right after an undo/redo sequence should land normally in the editor")

        pressUndo()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(markerPresent(marker), "The freshly-typed marker should itself be undoable via a normal Cmd-Z")
    }

    // MARK: - Test 3: find-bar focus regression (permanent port)

    /// Permanent port of the find-bar focus-restoration regression (fix landed in `e4722bfe`,
    /// "Fix undo permanently breaking after using Find" -- `FindBarState.hide()` now routes
    /// through `EditorFocusRestoration`, which does both the AppKit `makeFirstResponder` half
    /// and the JS `window.FinalFinal.focus()` half). Mode-switch's two directions/two trigger
    /// paths are already a permanent suite (`EditorModeSwitchUndoE2ETests.swift`) -- not
    /// duplicated here.
    func testUndoWorksAfterClosingFindBarNoManualClick() throws {
        launchAndWaitForEditor()

        // Extra content-based readiness gate before this test's very first interaction.
        // CONFIRMED via vmtest (run-1787342653-25801): the prior version of this test (a bare
        // 0.5s sleep before typing) failed here, and the xcresult activity log's own timestamps
        // show markerPresent's exhaustive 5-attempt scan ran for ~20 REAL seconds in the VM guest
        // (each element query costs real cross-process AX IPC time there) and still found
        // nothing -- not a narrow timing race a slightly longer retry budget would paper over,
        // but consistent with the marker never having landed at all. Unlike every other test in
        // this file, this one clicks-and-types as its literal first action right after launch,
        // with nothing else (a structural op, a mode switch) naturally giving the WebView more
        // settle time first. `waitForEditorReady()`'s word-count check only proves Swift-side
        // state is populated, not that the WebView is yet interactive enough to reliably accept a
        // click-to-focus + immediate keystroke. Waiting for real rendered content (the codebase's
        // own established idiom, e.g. `editorStaticText`/`waitForSourceEditorMounted` elsewhere)
        // is a stronger, non-arbitrary gate than a longer blind sleep.
        XCTAssertNotNil(
            app.editorStaticText(startingWith: "Test Document", timeout: 10),
            "Editor should render its first heading before this test's first interaction"
        )

        // Type a marker BEFORE opening Find, so there's something real to undo afterward.
        clickIntoEditor()
        app.activateAndWaitForForeground()
        let marker = "PreFindMarker_\(shortUUID())"
        app.typeText(marker)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(markerPresent(marker), "Marker should land before opening Find")

        // Open Find (Cmd-F), search for something, close it (Escape -- FindBarView.swift's
        // close button carries `.keyboardShortcut(.escape, modifiers: [])`) -- no manual click
        // back into the editor at any point. The whole point of the original bug is that focus
        // never returned there on its own.
        app.activateAndWaitForForeground()
        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["find-bar-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Find bar's search field should appear")
        searchField.typeText("Second")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForDisappearance(timeout: 5), "Find bar should close")
        Thread.sleep(forTimeInterval: 0.5)

        // Immediately Cmd-Z, no manual click -- this is the exact regression: undo silently did
        // nothing here because closing Find never handed keyboard focus back to the editor.
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertFalse(
            markerPresent(marker),
            "Cmd-Z right after closing Find (no manual click) should undo the pre-Find marker -- " +
            "if it's still present, undo silently did nothing (the find-bar focus regression)"
        )
    }

    // MARK: - Test 4: delete/duplicate undo

    /// Delete a section, undo it, confirm it's back; duplicate a section, undo it, confirm the
    /// duplicate is gone. Combined into one launch (both exercise the same sidebar
    /// context-menu/undo mechanics on the same default 2-section fixture) per this file's
    /// runtime-budget instruction, rather than two near-identical relaunches.
    func testDeleteAndDuplicateSectionUndo() throws {
        launchAndWaitForEditor()
        // Post-launch sync populates `section` rows asynchronously -- see the identical wait in
        // testCanonicalRestoreReorderUndoUndoRedoRedo for why this can't be a bare assert.
        let initialCount = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(initialCount, 2, "Default fixture should start with 2 sections")

        // MARK: Delete -> undo -> confirm it's back
        rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Delete Section")
        waitUntil(probe: { querySectionCount() }, predicate: { $0 == 1 })
        XCTAssertEqual(queryOrderedSectionTitles(), ["Test Document"], "Delete should remove \"Second Section\", leaving only the H1")

        pressUndo()
        waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(
            queryOrderedSectionTitles(), ["Test Document", "Second Section"],
            "Undo should bring the deleted section back"
        )

        // MARK: Duplicate -> undo -> confirm the duplicate is gone
        rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Duplicate Section")
        waitUntil(probe: { querySectionCount() }, predicate: { $0 == 3 })
        XCTAssertTrue(
            queryOrderedSectionTitles().contains("Second Section copy"),
            "Duplicate should create a \"... copy\"-titled section (Database+SectionOps.swift's naming)"
        )

        pressUndo()
        waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(
            queryOrderedSectionTitles(), ["Test Document", "Second Section"],
            "Undo should remove the duplicate, leaving the original 2-section state"
        )
    }

    // MARK: - Test 5: the H1 laundering probe

    /// Structural undo -> wait 3+ idle poll cycles (`BlockSyncService.pollInterval` = 2.0s --
    /// docs/architecture/unified-undo.md's "Checkpoints" section) -> assert at the DB level that
    /// zero spurious inserts happened. This is the exact hazard the design's central
    /// "laundering" rule exists to prevent (architecture doc's "The problem this solves"): if
    /// the block-sync poll ever mistook a structural undo's restored content for a fresh user
    /// edit, it would write that back as a real, spurious insert/duplicate row.
    func testStructuralUndoDoesNotLaunderSpuriousInserts() throws {
        launchAndWaitForEditor()

        // Post-launch sync populates `section`/`block` rows asynchronously -- see the identical
        // wait in testCanonicalRestoreReorderUndoUndoRedoRedo for why this can't be a bare
        // assert.
        let baselineCount = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(baselineCount, 2, "Default fixture should start with 2 sections")
        let baselineBlockCount = queryBlockCount()

        rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Delete Section")
        let afterDelete = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 1 })
        XCTAssertEqual(afterDelete, 1, "Delete should have actually removed a section before the undo below is meaningful")

        pressUndo()
        let afterUndo = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(afterUndo, 2, "Undo should have actually restored the deleted section before the idle-wait probe below is meaningful")

        // 3+ idle poll cycles at 2.0s each -- generous margin over the raw 6s minimum.
        Thread.sleep(forTimeInterval: 7.0)

        XCTAssertEqual(
            querySectionCount(), baselineCount,
            "Section count changed after 3+ idle block-sync poll cycles following a structural " +
            "undo -- a spurious insert would show up here as extra rows (the H1 laundering hazard)"
        )
        XCTAssertEqual(
            queryOrderedSectionTitles(), ["Test Document", "Second Section"],
            "Section titles/order should be unchanged after the idle window, not just the count " +
            "-- a laundered duplicate could keep the count right while still corrupting content"
        )
        // Section-level ground truth alone can't see a laundered duplicate BLOCK inside an
        // unchanged section -- block count must also be unchanged.
        XCTAssertEqual(
            queryBlockCount(), baselineBlockCount,
            "Block count changed after 3+ idle block-sync poll cycles following a structural " +
            "undo -- a laundered duplicate block wouldn't move section count or titles at all"
        )
    }

    // MARK: - Test 6: refusal fall-through sanity

    /// Zoom into a section, then confirm the sidebar's Delete/Duplicate context-menu items flip
    /// from enabled (before zooming) to disabled (while zoomed) -- `isSectionOperationAvailable`,
    /// ContentView+SectionOperations.swift / `.disabled(... || isZoomed)`, SectionCardView.swift
    /// -- and that attempting the interaction anyway leaves the app fully consistent: no crash,
    /// no state change.
    ///
    /// SCOPE, NARROWED FROM THE TASK'S LITERAL FRAMING (confirmed by review, not speculative):
    /// `isZoomed` is a single document-wide flag passed identically to EVERY sidebar card, not
    /// scoped to the zoomed section specifically -- every card's Delete/Duplicate disables
    /// whenever ANYTHING is zoomed. That means this test cannot distinguish "the app correctly
    /// refuses this specific op" from "every op is refused whenever anything is zoomed, correct
    /// or not" -- a disabled-item assertion alone would be statically true regardless of app
    /// correctness. What this version actually proves instead: (a) a REAL enabled -> disabled
    /// TRANSITION, via the before-zoom positive control below (rules out a vacuous query that
    /// always reports `isEnabled == false` regardless of app state -- without this control, every
    /// assertion in this test could pass even if the disabled-state query itself were simply
    /// broken), and (b) attempting the interaction anyway leaves app state byte-identical.
    ///
    /// Also per review: `deleteSectionFromSidebar`'s/`duplicateSectionFromSidebar`'s own
    /// `isSectionOperationAvailable` guard and its "Can't Delete While Zoomed" honest-message
    /// alert (`SectionOperationAlert`, N2 work) is confirmed genuinely UNREACHABLE dead code in
    /// production -- the context menu already disables the item before a click can ever reach
    /// that guard (standard AppKit menu-tracking semantics: a disabled `NSMenuItem` click never
    /// fires its action). That's real, but it predates this diff (already-merged Phase B code)
    /// and isn't fixed here -- filed as a separate follow-up.
    func testStructuralOpRefusedWhileZoomedStaysConsistent() throws {
        launchAndWaitForEditor()

        // Positive control BEFORE zooming -- see doc comment above for why this matters.
        let cardBeforeZoom = sidebarCard(titled: "Second Section")
        cardBeforeZoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let deleteItemBeforeZoom = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Delete Section")).firstMatch
        XCTAssertTrue(deleteItemBeforeZoom.waitForExistence(timeout: 5), "\"Delete Section\" menu item should exist before zooming")
        XCTAssertTrue(
            deleteItemBeforeZoom.isEnabled,
            "\"Delete Section\" should be ENABLED before zooming -- if this is false, the " +
            "disabled-state check below is vacuous (a broken query reporting false regardless " +
            "of app state), not a real refusal signal"
        )
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Re-resolve rather than reuse the handle above -- the sidebar re-renders for the zoomed
        // state (a different visible card set), and this codebase's own e2e skill documents this
        // exact stale-handle gotcha.
        let cardToZoom = sidebarCard(titled: "Second Section")
        cardToZoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        Thread.sleep(forTimeInterval: 1.5)

        let wordCountBefore = currentWordCountValue()
        let sectionCountBefore = querySectionCount()

        // Re-resolve again for the same reason.
        let zoomedCard = sidebarCard(titled: "Second Section")
        zoomedCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let deleteItemWhileZoomed = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Delete Section")).firstMatch
        XCTAssertTrue(deleteItemWhileZoomed.waitForExistence(timeout: 5), "\"Delete Section\" menu item should still exist while zoomed")
        XCTAssertFalse(deleteItemWhileZoomed.isEnabled, "\"Delete Section\" should be disabled while zoomed in on that section")

        // Dismiss the menu WITHOUT invoking a disabled item -- clicking a disabled NSMenuItem's
        // real-world behavior is exactly the thing this test can't fully verify without a live
        // run (see doc comment above); Escape is unambiguous either way.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.groups["editor-area"].exists, "App should remain fully responsive after the refused-op attempt")
        XCTAssertEqual(currentWordCountValue(), wordCountBefore, "Word count should be unchanged after a refused/disabled structural-op attempt")
        XCTAssertEqual(querySectionCount(), sectionCountBefore, "Section count should be unchanged after a refused/disabled structural-op attempt")
    }

    // MARK: - Test 7: the citation-bearing scenario (Task 2, the Zotero seam)

    /// Inserts a citation via the CAYW picker WHILE it is genuinely in-flight (the
    /// `FF_UI_TESTING_ZOTERO_MOCK_DELAY_MS` mock delay), racing it against a structural op whose
    /// step 1 calls `cancelPendingInsertions()` (N1, Phase B -- the CodeMirror port of Milkdown's
    /// pending-CAYW-cancellation). Confirms the raced insertion does NOT land at a stale offset
    /// -- the exact content-corruption hazard N1 exists to prevent -- then confirms an UNRACED
    /// citation insert via the same mock DOES land, proving the seam produces a real, working
    /// citation insert, not just that everything gets cancelled.
    ///
    /// MUST run in SOURCE mode, not the app's WYSIWYG default -- confirmed by review, not
    /// assumed: N1 is specifically the CodeMirror port of `cancelPendingInsertions`. CodeMirror's
    /// own source comment states outright that before this function existed, that call was a
    /// silent no-op in Source mode, while Milkdown already had equivalent cancellation logic
    /// (`resetCAYWState()`) BEFORE Phase B touched anything. Racing this in WYSIWYG (this app's
    /// default, and this test's original, incorrect form) would run entirely through Milkdown's
    /// pre-existing code path and prove nothing about N1 -- reverting N1 entirely would not have
    /// made a WYSIWYG-mode version of this test fail. `switchToSourceMode()` below is this test's
    /// own copy of `EditorModeSwitchUndoE2ETests.toggleWysiwygToSource`'s established
    /// retry-keystroke + mount-completion-gate pattern.
    ///
    /// Races against deleting "Last Section" while the cursor sits in "Anchor Section" (the
    /// first content in an unscrolled editor -- `clickIntoEditor()` lands there) --
    /// DELIBERATELY a different section from the one the cursor is in and the citation would
    /// insert into. Racing against a delete of the CURSOR'S OWN section would make that delete
    /// remove any evidence of a landed citation right along with the section, so the negative
    /// assertion below would read "citekey absent" regardless of whether cancellation actually
    /// worked -- a silent-pass risk, not a genuine proof.
    /// CONFIRMED ROOT CAUSE (2026-08-22, third failure mode after the section-count and
    /// keymap-collision fixes): a genuine test-timing gap, not an N1 regression -- traced
    /// against the actual mechanism, not inferred from the symptom alone.
    /// `SectionSyncService+Parsing.swift`'s bibliography-detection fix made the citation land
    /// correctly for the first time; the live log's OWN chronological order then showed
    /// `citationPickerCallback succeeded` BEFORE any of the racing delete's own log lines
    /// (`createUndoPointSnapshot`, `SectionReconciler Deleted`) -- i.e. the mock's citation had
    /// ALREADY resolved and inserted before `performSectionDelete`'s `performStructuralOp` even
    /// reached step 1's `cancelPendingInsertions()` call, so there was nothing left in flight
    /// for that call to cancel. Confirmed by code, not just log order: `citationPickerCallback`
    /// (`web/codemirror/src/api.ts`) correctly no-ops when `getPendingCAYWRequests()` no longer
    /// has the request id, and `cancelPendingInsertions` (registered unconditionally on
    /// `window.FinalFinal`, `main.ts`) correctly clears that map -- both halves of N1 are intact
    /// and reachable in this exact Source-mode path; the 2000ms mock delay just wasn't wide
    /// enough to still be pending by the time this test's OWN UI sequence (0.3s sleep, then a
    /// full right-click + context-menu-navigate + menu-click round trip, each step a real
    /// cross-process AX interaction in the VM guest) reaches the delete's own
    /// `performStructuralOp` call. Widened to 8000ms -- comfortably longer than that UI sequence
    /// realistically takes, while still leaving several seconds of margin inside both the raced
    /// check's and the later clean-insert check's 13s poll windows below.
    func testCitationInsertRacedAgainstStructuralOpIsCancelledNotCorrupted() throws {
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK_DELAY_MS"] = "8000"
        seedCanonicalDocument()
        launchAndWaitForEditor()
        let initialTitles = waitUntil(probe: { queryOrderedSectionTitles() }, predicate: { $0.count == 3 })
        XCTAssertEqual(initialTitles.count, 3, "Seeded 3-section document should be synced before the mode switch below")

        switchToSourceMode()

        let mockCitekey = "ffe2emockcitation2026" // must match ZoteroService+CAYW.swift's mockCitekey

        // Cursor lands in "Anchor Section" -- see doc comment for why the delete below targets a
        // DIFFERENT section. Fire the citation picker (Cmd-Shift-K, "Insert > Citation...") but
        // do NOT wait for it -- immediately race a structural op into its ~8s in-flight window
        // (`FF_UI_TESTING_ZOTERO_MOCK_DELAY_MS` above).
        //
        // DIAGNOSTIC INSTRUMENTATION (2026-08-22, positive-control failure round): the clean
        // (unraced) check below failed ("citekey not found") in this test's first live run --
        // its OWN positive control, meaning the raced check just above proves nothing either way
        // (a citekey correctly absent is consistent with both "cancelled correctly" and "the
        // mock seam never fired at all"). `Self.recordDiagnosticLogStartOffsets()` here + the
        // matching `captureDiagnostics` calls below (same established pattern as
        // `rightClickSidebarCard`'s own Pattern-1 instrumentation) capture the `.zotero`-category
        // DebugLog delta (`ping`/`openCAYWPicker`/`handleOpenCitationPicker`/
        // `citationPickerCallback` all log at each step -- see `ZoteroService.swift`/
        // `ZoteroService+CAYW.swift`/`CodeMirrorCoordinator+Citations.swift`) plus a full AX-tree
        // dump, so the next vmtest run shows exactly how far each attempt got: nothing logged at
        // all points at the JS bridge (`executeFormatting`'s `evaluateJavaScript` completion
        // handler discards its error, `{ _, _ in }` -- a silently-swallowed JS-side failure is
        // the leading suspect); logs stopping at `ping`/`ZoteroService+CAYW.swift`'s mock branch
        // points at the env-var/TestMode wiring instead; logs completing but no citekey in
        // content points at `citationPickerCallback`'s CodeMirror-side insertion itself.
        Self.recordDiagnosticLogStartOffsets()
        clickIntoEditor()
        app.activateAndWaitForForeground()
        app.typeKey("k", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        rightClickSidebarCard(titled: "Last Section", thenChooseMenuItem: "Delete Section")
        let afterRacedDelete = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(afterRacedDelete, 2, "The structural delete that races the citation should itself complete normally")

        // Same total waiting budget as the positive (unraced) check below -- asymmetric windows
        // here would let a citation that lands slowly (right at the mock's 8s delay boundary, or
        // slower under VM load) slip past a shorter negative-check window undetected.
        // `waitUntil`'s predicate is trivially unsatisfiable, so this always polls the FULL
        // timeout below rather than stopping the instant it happens to read clean once.
        let contentAfterRace = waitUntil(timeout: 13.0, probe: { queryAllMarkdownConcatenated() }, predicate: { _ in false })
        captureDiagnostics(context: "raced citation insert (Cmd-Shift-K then immediate delete)")
        XCTAssertFalse(
            contentAfterRace.contains(mockCitekey),
            "A CAYW citation still in-flight when a structural op started should be cancelled " +
            "(N1's cancelPendingInsertions CodeMirror port), not land at a stale offset -- " +
            "finding the mock citekey anywhere in the document means it landed anyway (content " +
            "corruption)"
        )

        // Undo the delete so there's real content to insert into for the clean check below.
        pressUndo()
        let afterUndo = waitUntil(probe: { querySectionCount() }, predicate: { $0 == 3 })
        XCTAssertEqual(afterUndo, 3, "Undo should restore the raced-away section before the clean insert below")

        // Clean (unraced) citation insert via the same mock -- proves the seam itself produces a
        // real, landed citation when nothing cancels it. No extra sleep before the poll below --
        // the explicit 13s timeout given to `waitUntil` below leaves ~5s of margin over the
        // mock's 8s delay, not the wide double-digit margin a shorter delay would have had, but
        // comfortable enough for this check's own polling interval plus realistic VM jitter.
        Self.recordDiagnosticLogStartOffsets()
        clickIntoEditor()
        app.activateAndWaitForForeground()
        app.typeKey("k", modifierFlags: [.command, .shift])

        let contentAfterCleanInsert = waitUntil(
            timeout: 13.0,
            probe: { queryAllMarkdownConcatenated() },
            predicate: { $0.contains(mockCitekey) }
        )
        captureDiagnostics(context: "clean (unraced) citation insert (Cmd-Shift-K)")
        XCTAssertTrue(
            contentAfterCleanInsert.contains(mockCitekey),
            "An unraced citation insert via the Zotero mock should land in the document -- " +
            "citekey \"\(mockCitekey)\" not found"
        )
    }

    // MARK: - Test 8: the eviction-cap debug launch argument (Task 3)

    /// Lowers `UnifiedUndoService`'s 50-entry cap to 3 via the debug-only `FF_UNDO_EVICTION_CAP`
    /// launch argument, performs 4 structural ops (duplicating the SAME section 4 times, so each
    /// duplicate carries an identical, known word-count delta), then confirms exactly `cap` (3)
    /// of them are undoable -- the 4th (oldest) entry was evicted, and eviction also clears that
    /// one entry's editor text-undo history (`UnifiedUndoService.record()`'s eviction path), so
    /// a 4th Cmd-Z has nothing left to structurally (or textually) undo.
    func testEvictionCapEvictsOldestEntryAndStaysConsistent() throws {
        app.launchEnvironment["FF_UNDO_EVICTION_CAP"] = "3"
        launchAndWaitForEditor()

        var previousWords = currentWordCountValue()
        for _ in 1...4 {
            rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Duplicate Section")
            let afterThisDuplicate = waitUntil(probe: { currentWordCountValue() }, predicate: { $0 != previousWords })
            XCTAssertNotEqual(afterThisDuplicate, previousWords, "Each duplicate should increase the word count from the previous one")
            previousWords = afterThisDuplicate
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(querySectionCount(), 6, "4 duplicates of the same section should leave 6 total sections (2 original + 4 copies)")

        // Explicit settle before the undo loop (2026-08-22, widened to 2.0s -- the final step
        // of this investigation). Everything INSIDE the app was ruled out first, with real
        // evidence, not assumed: the JS-side "in-flight" latch (`undo-coordinator.ts`) is only
        // ever set by a Cmd-Z that itself routes structurally, never touched by a forward op
        // like this loop's duplicates, so it cannot be "still held" from them. Native
        // `UndoRedoCommands.performUndo()` and the JS capture-phase keydown interceptor
        // (`handleSlashKeydown`, instrumented with an unconditional log at its very first line)
        // BOTH showed zero log activity for the failing Undo #1 -- meaning the keystroke never
        // reached either, the earliest point this app's own code can observe it. That leaves
        // exactly one remaining explanation: XCUITest's synthetic key delivery not finishing
        // its exit from AppKit's `NSMenu` tracking loop (four rapid native right-click ->
        // context-menu selections back to back, immediately followed by a synthesized keyDown)
        // before the next event is queued -- a known class of OS/XCUITest timing gap, not an
        // app defect. This settle is the standard mitigation for exactly that. `Thread.sleep`
        // is used deliberately over a `waitUntil` poll -- there is nothing in this app's own
        // state to poll for, since the gap being waited out is entirely inside XCUITest/AppKit,
        // below anything this codebase can observe or query.
        Thread.sleep(forTimeInterval: 2.0)

        // 3 undos (== the lowered cap): each should successfully undo one duplicate.
        //
        // DIAGNOSTIC INSTRUMENTATION ROUND 2 (2026-08-22): round 1's AFTER-the-fact capture
        // (still present in the `i == 1` branch below) showed `editor-area` correctly marked
        // "Keyboard Focused" and zero `.undo`-category log activity -- but that capture fires
        // AFTER `waitUntil` already spent up to 10s polling, well after the actual Cmd-Z
        // keystroke. It can't distinguish "focus was never there" from "focus wasn't there AT
        // THE MOMENT of the keystroke, then self-healed" -- exactly the ambiguity flagged for
        // this round. Undo #1 specifically is inlined below (instead of calling the shared
        // `pressUndo()`) so a capture can land BETWEEN the activate+click and the actual
        // `typeKey` -- state at the real moment that matters, not inferred after the fact.
        Self.recordDiagnosticLogStartOffsets()
        var lastWordCount = previousWords
        for i in 1...3 {
            if i == 1 {
                app.activateAndWaitForForeground()
                clickIntoEditor()
                captureDiagnostics(context: "eviction-cap test -- Undo #1 (BEFORE Cmd-Z, right after activate+click)")
                // THE decisive check (review round, 2026-08-22): `UndoRedoCommands.swift`'s
                // "Undo" menu item already carries `.accessibilityIdentifier("menu-undo")` and is
                // disabled only when `!canUndo` -- `mayHaveTextUndo` (`editorState != nil`, true
                // whenever any project window is key, independent of undo-stack contents) OR a
                // real undo entry exists. If XCUITest's synthetic Cmd-Z genuinely isn't being
                // delivered (this quarantine's own conclusion), the menu item itself must still
                // be enabled -- a disabled item wouldn't even register the key equivalent, no
                // project window needs to be key at all for that to be true, and a DIFFERENT,
                // already-passing test (`testDeleteAndDuplicateSectionUndo`) proves the identical
                // duplicate-then-undo sequence works once, ruling out "duplicating disables
                // undo." Asserting this immediately before the keystroke -- not assuming it --
                // settles definitively whether this is a pure key-delivery gap (enabled, keystroke
                // still does nothing) or a real, previously-hidden bug (disabled, in which case
                // this whole quarantine would need to be reopened).
                //
                // Mechanical fix (review round 2): two separate issues, not one.
                // (1) a closed NSMenu's items aren't present in the accessibility tree at all
                // until the menu is actually open -- open the "Edit" menu bar item first (same
                // `app.menuBars.menuBarItems[...]` + `.click()` pattern `SmokeTests.swift`'s
                // `testPrintMenuItemsExist` already establishes for inspecting a menu item
                // without invoking it), then close it again with Escape before proceeding to the
                // actual keystroke -- the menu must not still be open when Cmd-Z is sent.
                // (2) `.accessibilityIdentifier` set on a SwiftUI `Button` inside a `Commands`
                // group does not reliably surface on the resulting native `NSMenuItem`'s
                // accessibility properties (a known limitation already documented from Phase C's
                // review of a different context-menu button) even though the identifier really
                // is set in `UndoRedoCommands.swift:65` -- `menuItems["menu-undo"]` can never
                // match. Title-based matching (this codebase's own established, working pattern
                // for menu items -- see `menuItem(titleStartingWith:)` above) is used instead.
                let editMenuBarItem = app.menuBars.menuBarItems["Edit"]
                XCTAssertTrue(editMenuBarItem.waitForExistence(timeout: 5), "Edit menu bar item should exist")
                editMenuBarItem.click()
                let menuUndo = app.menuItems.matching(NSPredicate(format: "title == 'Undo'")).firstMatch
                XCTAssertTrue(menuUndo.waitForExistence(timeout: 5), "The native Undo menu item should exist")
                XCTAssertTrue(
                    menuUndo.isEnabled,
                    "The Undo menu item must be enabled immediately before Undo #1's keystroke -- " +
                    "if it's disabled here, this is a real bug (Cmd-Z's key equivalent would " +
                    "never even fire), not the pure key-delivery gap this test is quarantined for"
                )
                app.typeKey(.escape, modifierFlags: [])
                app.typeKey("z", modifierFlags: .command)
            } else {
                pressUndo()
            }
            let afterUndo = waitUntil(probe: { currentWordCountValue() }, predicate: { $0 != lastWordCount })
            if i == 1 {
                let sectionCountAfterFirstUndo = querySectionCount()
                let dbCheckAttachment = XCTAttachment(string: """
                    right after Undo #1's waitUntil settled:
                      word count read: \(afterUndo) (previous: \(lastWordCount))
                      section count (DB ground truth): \(sectionCountAfterFirstUndo) (expected 5 if the undo landed, 6 if it was a no-op)
                    """)
                dbCheckAttachment.name = "Undo #1 -- DB section-count cross-check"
                dbCheckAttachment.lifetime = .keepAlways
                add(dbCheckAttachment)
                captureDiagnostics(context: "eviction-cap test -- Undo #1 (AFTER waitUntil settled)")
            }
            XCTAssertNotEqual(afterUndo, lastWordCount, "Undo #\(i) (within the lowered cap of 3) should have undone a duplicate")
            lastWordCount = afterUndo
        }
        XCTAssertEqual(
            querySectionCount(), 3,
            "3 undos should remove 3 of the 4 duplicates, leaving 3 sections (2 original + 1 un-undoable evicted duplicate)"
        )

        // A 4th undo attempt: the oldest (1st) duplicate's structural entry was evicted -- there
        // is nothing left to undo it with. Word count / section count should be unchanged.
        //
        // "Unchanged" alone is exactly the ambiguity this whole test has been fighting (review
        // round, 2026-08-22): it's equally consistent with "the keystroke was delivered, routed,
        // and correctly found nothing to undo" and "the keystroke never reached the app at all."
        // A positive signal distinguishes them: `handleUnifiedUndoKeydown`
        // (`undo-coordinator.ts`) unconditionally logs a `[UnifiedUndo] keydown direction=...`
        // line on EVERY invocation regardless of its routing decision (confirmed while tracing
        // Undo #1's own failure above) -- its PRESENCE here proves this keystroke really was
        // observed and processed (a genuine "nothing left to undo" outcome), where its absence
        // would match the same silent-non-delivery signature Undo #1 hit.
        Self.recordDiagnosticLogStartOffsets()
        pressUndo()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            Self.currentDiagnosticLogContents().contains("[UnifiedUndo]"),
            "The 4th (past-cap) undo keystroke should have been observed and routed by the app's " +
            "own undo-coordinator (a real 'nothing left to undo' decision) -- finding no " +
            "[UnifiedUndo] log line at all means this keystroke was never delivered, the same " +
            "silent non-delivery this suite's known-flaky quarantine documents for Undo #1"
        )
        XCTAssertEqual(
            currentWordCountValue(), lastWordCount,
            "A 4th undo past the lowered eviction cap should be a no-op -- the oldest duplicate's " +
            "structural entry was evicted and should not be reachable via Cmd-Z"
        )
        XCTAssertEqual(querySectionCount(), 3, "Section count should be unchanged after the 4th (past-cap) undo attempt")
        XCTAssertTrue(app.groups["editor-area"].exists, "App should remain fully responsive after exercising eviction")
    }
}

// Shared helpers (fixture seeding, launch, sidebar/dialog interaction, DB ground-truth queries,
// diagnostic capture) live in UnifiedUndoE2ETests+Helpers.swift -- split into its own file to
// keep SwiftLint's file_length under this repo's error threshold (1000 lines), matching this
// codebase's established `Type+Feature.swift` convention (e.g. ContentView+SectionOperations.swift).
