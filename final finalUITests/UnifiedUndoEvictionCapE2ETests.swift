//
//  UnifiedUndoEvictionCapE2ETests.swift
//  final finalUITests
//
//  Split out of UnifiedUndoE2ETests.swift to keep that file's class body under SwiftLint's
//  type_body_length limit -- see the header comment there for the full unified-undo background.
//  This file covers Test 8: the eviction-cap debug launch argument (Task 3) -- lowering
//  UnifiedUndoService's 50-entry cap via the debug-only FF_UNDO_EVICTION_CAP launch argument and
//  confirming the oldest entry is evicted (and its editor text-undo history cleared) once the
//  cap is exceeded. Uses the shared fixture/launch/DB-query helpers defined in
//  UnifiedUndoE2ETests+Helpers.swift.
//

import XCTest

extension UnifiedUndoE2ETests {

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
                // for menu items -- see `menuItem(titleStartingWith:)`, UITestQueryAndFixtureHelpers.swift) is used instead.
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
