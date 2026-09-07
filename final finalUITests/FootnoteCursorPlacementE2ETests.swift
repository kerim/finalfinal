//
//  FootnoteCursorPlacementE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression suite for notes-heading-scanner-unify (bt t-7f7e6ed2 /
//  t-mtianjujt9ub) -- Test Discipline T10/T11. Everything else this task built
//  (Stages A-E) was proven at the unit/vitest level, plus one throwaway diagnostic
//  scratch run (Stage D, restored per e2e-verify convention). This file is the piece
//  that proves the fix in the ACTUAL RUNNING APP, permanently: it exercises the real
//  `BlockSyncService` polling timer, real window/focus behavior, and the real
//  Swift<->JS bridge -- none of which a unit test or a web-layer vitest can reach.
//
//  T10 -- the position-assertion mechanism (never search-and-guess, always
//  content-verified): after a footnote insertion, with no intervening click or
//  navigation, type a unique sentinel string into wherever the cursor landed, then
//  read the block table back and assert on `markdownFragment` (what reconciliation
//  actually writes and what `FootnoteSyncService.parseNotesLabel` actually parses --
//  `textContent` alone would hide a prefix-boundary error, since it's already
//  prefix-stripped) that the sentinel sits immediately after the "[^N]: " prefix, not
//  merely somewhere inside the fragment. `textContent` is asserted too, so the two
//  fields can never silently drift apart. Timing discipline: never a sleep for the
//  3.0s debounce -- footnote insertion goes through `handleImmediateInsertion`, which
//  cancels the outstanding debounce and bumps `syncGeneration` by construction, and
//  `handleFootnoteInsertedImmediate` force-flushes via
//  `blockSyncService.pollBlockChangesNow()` before its own DB read. This XCUITest tier
//  has no direct handle on `editorState.contentState`, so it waits on an
//  `XCTNSPredicateExpectation` (`waitForValueNot`, from `UITestHelpers.swift`) over an
//  observable UI proxy instead: the status-bar word count only changes once that whole
//  async round trip -- flush, DB read, `setContentWithBlockIds` push -- has actually
//  landed and `contentState` is back at `.idle`. The DB readback after typing is a
//  bounded poll (`waitUntil`-style), never a fixed sleep either, since the typed
//  edit's own flush back to the DB still runs on the normal debounced path.
//
//  T11 -- this file itself. Six scenarios, per the plan:
//    1. `# Notes` + an existing footnote + insert a new one -> one Notes heading,
//       original definition text intact, sentinel lands correctly in the NEW
//       definition.
//    2/3. H1<->H2 heading-level flip live-edited in CodeMirror, then switch to
//       Milkdown and insert -> sentinel still lands correctly. These are the two
//       shapes attempt 1 regressed on (see notes.md's "Prior attempt" section);
//       Stage D found them ABSENT against this build, and this test is what keeps
//       them absent going forward.
//    4. A mid-document `## Notes` gets adopted AND relocated to the end of the
//       document in the SAME insertion pass (settled decision 1) -> the run ends at
//       the true document end, surrounding text (including a heading that follows
//       it, so extent-bounding is also proven) stays intact, sentinel lands
//       correctly in the new definition.
//    5. Project-open survival: quit and reopen the SAME project file (not a fresh
//       fixture copy) -> footnote text unchanged. This is the shape the user
//       actually reported, and per the plan nothing tested it at any tier before
//       this file.
//    6. Deleting the document's last footnote reference must never sweep the user's
//       own prose sitting under the Notes heading (Stage B's B1 fix, `removeNotesBlock`
//       narrowed to machine-owned rows only) -- confirmed here end-to-end, not just at
//       the unit level.
//
//  Live-edit technique for the H1/H2 flip and delete-last-reference scenarios: rather
//  than targeting a single character at a fragile per-line pixel coordinate in
//  CodeMirror (the "In Source Mode, an H1 line's raw markdown is NOT exposed via
//  staticTexts" class of gotcha the e2e-verify skill documents makes this brittle),
//  each does Cmd-A + Delete + a full-document retype with the one intended change.
//  This is still a real keystroke edit through the real CodeMirror instance -- the
//  mode switch that follows (a documented full-reparse trigger) exercises the same
//  reparse pipeline a single targeted edit would.
//
//  Footnote labels are NOT stable identifiers across renumbering (e2e-verify skill) --
//  every assertion below keys off a unique phrase in a definition's own TEXT, never
//  its current `[^N]:` label.
//

import XCTest

final class FootnoteCursorPlacementE2ETests: XCTestCase {
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

    // MARK: - Scenario 1: existing footnote + new insertion coexist under one heading

    func testExistingFootnoteAndNewInsertionCoexistUnderSingleNotesHeading() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        A body paragraph with an existing reference[^1] in it.

        # Notes

        [^1]: Preexisting definition text that must survive scenario one.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        clickIntoEditorBody(bodyLinePrefix: "A body paragraph with an existing reference")
        insertFootnoteAndWaitForLanding()
        let sentinel = "SENT1_\(shortUUID())_"
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelAtDefinitionStart(sentinel)
        XCTAssertNotNil(
            notesParagraphFragment(containing: "Preexisting definition text that must survive scenario one"),
            "The original footnote definition must survive the new insertion, not be blanked (the original bug's data-loss shape)"
        )
        XCTAssertEqual(notesHeadingCount(), 1, "Exactly one Notes heading after inserting alongside an existing footnote")
    }

    // MARK: - Scenario 2: H1 -> H2 flip in CodeMirror, switch to Milkdown, insert

    func testH1ToH2FlipInSourceThenSwitchToMilkdownInsertLandsSentinelCorrectly() throws {
        let bodyLine = "Body paragraph with a reference[^1] here for the H1 to H2 flip."
        // Preceded by `# Chapter One` (in both the seed and the retype target) because
        // `ContentView+HierarchyEnforcement.swift` enforces "the document's first section
        // must be H1" and silently re-promotes a lone `## Notes` heading back to `# Notes`
        // whenever Notes is the document's only/first heading -- app-wide hierarchy policy,
        // unrelated to Notes-specific recognition, that would otherwise undo this scenario's
        // H1->H2 retype before the footnote insertion below ever runs. (Confirmed by
        // `testMidDocumentNotesHeadingAdoptedAndRelocatedOnInsertion`, which already has a
        // preceding heading and passes.)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        # Chapter One

        \(bodyLine)

        # Notes

        [^1]: Flip H1 to H2 original definition text.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        switchToSourceMode()
        retypeWholeSourceDocument("""
        # Chapter One

        \(bodyLine)

        ## Notes

        [^1]: Flip H1 to H2 original definition text.
        """, landedEvidence: ["## Notes", "Flip H1 to H2 original definition text"])

        switchToWysiwygMode()

        clickIntoEditorBody(bodyLinePrefix: "Body paragraph with a reference")
        insertFootnoteAndWaitForLanding()
        let sentinel = "SENT2_\(shortUUID())_"
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelAtDefinitionStart(sentinel)
        XCTAssertNotNil(
            notesParagraphFragment(containing: "Flip H1 to H2 original definition text"),
            "The original definition must survive the H1->H2 flip plus insertion"
        )
        XCTAssertEqual(notesHeadingCount(), 1, "Exactly one Notes heading after an H1->H2 flip + insertion")
        // `editorContainsText` is a CONTAINS scan -- "## Notes" contains "# Notes" as a
        // substring, so a text-presence check alone can never discriminate which level
        // actually survived. Query the DB directly for the real heading level instead.
        XCTAssertEqual(notesHeadingLevel(), 2, "Notes heading must actually be H2, not silently re-promoted back to H1")
    }

    // MARK: - Scenario 3: H2 -> H1 flip in CodeMirror, insert

    func testH2ToH1FlipInSourceThenInsertLandsSentinelCorrectly() throws {
        let bodyLine = "Body paragraph with a reference[^1] here for the H2 to H1 flip."
        // Preceded by `# Chapter One` (in both the seed and the retype target) because
        // `ContentView+HierarchyEnforcement.swift` enforces "the document's first section
        // must be H1" and silently re-promotes a lone `## Notes` heading back to `# Notes`
        // whenever Notes is the document's only/first heading -- app-wide hierarchy policy,
        // unrelated to Notes-specific recognition. Without this prefix, the seeded `## Notes`
        // heading is already force-promoted to H1 before the test even starts, so this
        // scenario never actually exercised an H2->H1 flip at all. (Confirmed by
        // `testMidDocumentNotesHeadingAdoptedAndRelocatedOnInsertion`, which already has a
        // preceding heading and passes.)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        # Chapter One

        \(bodyLine)

        ## Notes

        [^1]: Flip H2 to H1 original definition text.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        switchToSourceMode()
        retypeWholeSourceDocument("""
        # Chapter One

        \(bodyLine)

        # Notes

        [^1]: Flip H2 to H1 original definition text.
        """, landedEvidence: ["# Notes", "Flip H2 to H1 original definition text"])

        switchToWysiwygMode()

        clickIntoEditorBody(bodyLinePrefix: "Body paragraph with a reference")
        insertFootnoteAndWaitForLanding()
        let sentinel = "SENT3_\(shortUUID())_"
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelAtDefinitionStart(sentinel)
        XCTAssertNotNil(
            notesParagraphFragment(containing: "Flip H2 to H1 original definition text"),
            "The original definition must survive the H2->H1 flip plus insertion"
        )
        XCTAssertEqual(notesHeadingCount(), 1, "Exactly one Notes heading after an H2->H1 flip + insertion")
        // `editorContainsText` is a CONTAINS scan -- "## Notes" contains "# Notes" as a
        // substring, so a text-presence check alone can never discriminate which level
        // actually survived. Query the DB directly for the real heading level instead.
        XCTAssertEqual(notesHeadingLevel(), 1, "Notes heading must actually be H1 after the flip")
    }

    // MARK: - Scenario 4: mid-document Notes adopted and relocated in the same pass

    func testMidDocumentNotesHeadingAdoptedAndRelocatedOnInsertion() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        # Chapter One

        Chapter body with a reference[^1] here, mid-document.

        ## Notes

        [^1]: Mid-document original definition text.

        ## Appendix

        Appendix content that must not be swallowed by the relocated Notes section.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        clickIntoEditorBody(bodyLinePrefix: "Chapter body with a reference")
        insertFootnoteAndWaitForLanding()
        let sentinel = "SENT4_\(shortUUID())_"
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelAtDefinitionStart(sentinel)
        XCTAssertNotNil(
            notesParagraphFragment(containing: "Mid-document original definition text"),
            "The original mid-document definition must survive adoption + relocation"
        )
        XCTAssertTrue(
            app.editorContainsText("Appendix content that must not be swallowed"),
            "Appendix content must remain intact -- the relocated Notes run must not swallow what follows it"
        )
        XCTAssertEqual(notesHeadingCount(), 1, "Exactly one Notes heading after adoption")
        XCTAssertTrue(
            notesRunIsAfterEveryOtherBlock(),
            "Settled decision 1: an adopted mid-document Notes section is relocated to the END of the document, not left in place"
        )
    }

    // MARK: - Scenario 5: footnote text survives a project quit + reopen

    func testFootnoteTextSurvivesProjectQuitAndReopen() throws {
        // No underscores: `MarkdownUtils.stripMarkdownSyntax`'s emphasis-stripping regex
        // (`applyInlinePattern` for `*...*`/`_..._`) legitimately strips underscores from the
        // plain-text `textContent` field (documented as lossy/search-oriented, not a byte-exact
        // copy) -- a marker containing them would make `textContent` differ from the raw marker
        // by design, not by a bug. An underscore in the marker also acted as a live SQL LIKE
        // wildcard in `notesParagraphFragment`'s query helper below, matching by luck rather
        // than by design.
        let marker = "Persisted \(shortUUID()) definition text that must survive a quit and reopen."
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        A body paragraph with a reference[^1] here.

        # Notes

        [^1]: \(marker)
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Captured as ground truth for the "after" comparison below -- proves the actual
        // quit/reopen invariant (whatever these fields held before must be exactly what they
        // hold after) regardless of what normalization either field applies, rather than
        // comparing "after" against a hand-typed literal.
        let before = notesParagraphFragment(containing: marker)
        XCTAssertNotNil(before, "Footnote definition should be present after the first launch")

        // Quit and reopen the SAME project file (not a fresh fixture copy) -- the shape
        // the user actually reported. Per the e2e-verify skill's fixture note, a relaunch
        // with an already-populated block table does NOT force a full markdown reparse;
        // this is exactly the path that must not silently drop or corrupt content.
        app.terminate()
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Bounded poll, not a single-shot read: guards against reading the DB mid-startup,
        // where `markdownFragment` (unchanged since the first launch's parse) can already
        // match the LIKE query while a still-settling `textContent` hasn't caught up yet.
        // Polls until the readback matches `before` EXACTLY on both fields.
        let after = notesParagraphFragmentSettled(containing: marker, before: before)
        // Fail loudly (e2e-verify skill: "Helpers must fail loudly") -- print exactly what
        // textContent/markdownFragment held before and after, and the full isNotes-row table,
        // rather than a bare boolean.
        if after?.markdownFragment != before?.markdownFragment || after?.textContent != before?.textContent {
            let dump = allNotesRowsDump()
            XCTFail(
                "Footnote definition must survive a quit + reopen unchanged -- " +
                    "before markdownFragment=\"\(before?.markdownFragment ?? "nil")\" " +
                    "textContent=\"\(before?.textContent ?? "nil")\" " +
                    "after markdownFragment=\"\(after?.markdownFragment ?? "nil")\" " +
                    "textContent=\"\(after?.textContent ?? "nil")\" " +
                    "all isNotes rows now:\n\(dump)",
                file: #filePath, line: #line
            )
        }
        XCTAssertTrue(app.editorContainsText(marker, timeout: 15), "The persisted footnote text should also be visible in the reopened editor")
    }

    // MARK: - Scenario 6: deleting the last footnote reference preserves user prose (B1)

    func testDeletingLastFootnoteReferencePreservesUserProseUnderNotes() throws {
        let bodyBefore = "Body paragraph with a single reference[^1] here."
        let bodyAfter = "Body paragraph with a single reference here."
        let prose = "My own commentary on these notes that must survive deletion of the reference."
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        \(bodyBefore)

        # Notes

        \(prose)

        [^1]: Only footnote definition, about to become orphaned.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        XCTAssertTrue(app.editorContainsText(prose, timeout: 15), "User prose should be present before the deletion")

        switchToSourceMode()

        // The dissolve this scenario asserts is produced by FootnoteSyncService's DEBOUNCED path
        // (checkAndUpdateFootnotes -> 3s debounce -> performFootnoteUpdate(refs: []) ->
        // removeNotesBlock), which only fires when the ref set actually CHANGES:
        // `lastKnownRefs` starts [] and advances only when a pass COMPLETES
        // (FootnoteSyncService.swift:109 guard; :380/:362/:556 assignments), and every content
        // change re-arms the 3s debounce. Without a >3s quiet window while the seeded `[^1]` is
        // still present, `lastKnownRefs` is still [] when the retype removes it, the deletion
        // reads as "no change", and nothing is ever scheduled. Unlike every other scenario here,
        // which drives the SYNCHRONOUS insertion path (handleImmediateInsertion, which sets
        // lastKnownRefs itself), this one has no non-time-based proxy for "the app has registered
        // the document's initial ref set".
        Thread.sleep(forTimeInterval: 4.0)

        retypeWholeSourceDocument("""
        \(bodyAfter)

        # Notes

        \(prose)

        [^1]: Only footnote definition, about to become orphaned.
        """, landedEvidence: [bodyAfter, prose])

        // B1's regression: `removeNotesBlock` used to sweep every isNotes-flagged row
        // (including genuine user prose, not just machine-owned definitions) once the
        // reference count hit zero. Poll -- bounded, never a blind sleep -- for the
        // debounced dissolve (see the quiet-window comment above) to actually settle,
        // while still in Source mode where the retype landed.
        let dissolved = waitUntilTrue(timeout: 20) { self.notesHeadingCount() == 0 }
        XCTAssertTrue(dissolved, "The Notes section should be fully dissolved once its last footnote reference is deleted (isNotes heading rows still present: \(notesHeadingCount()))\n\(allNotesRowsDump())")

        // A full reparse must not resurrect the dissolved section.
        switchToWysiwygMode()
        XCTAssertEqual(notesHeadingCount(), 0, "The dissolved Notes section must not be re-materialized by the mode-switch reparse")

        let stillPresent = waitUntilTrue(timeout: 15) { self.app.editorContainsText(prose) }
        XCTAssertTrue(
            stillPresent,
            "User's own prose under the Notes heading must survive deletion of the document's last footnote reference (B1 regression)"
        )
        // NOT `notesParagraphFragment` (isNotes-filtered): once the last reference is deleted,
        // reconciliation correctly dissolves the whole Notes section (heading + orphaned
        // definition) -- exactly-designed behavior, not a regression. The surviving prose row
        // is therefore correctly unflagged (isNotes=0) since it's no longer under any Notes
        // heading, so an isNotes-filtered query can structurally never find it anymore.
        // `paragraphFragment` (no isNotes filter) is the correct way to confirm the row itself
        // -- and still real text, not just stale editor content -- survives.
        XCTAssertNotNil(
            paragraphFragment(containing: prose),
            "User prose must also still exist as a real block row in the database, not just stale editor content"
        )
    }

    // MARK: - Scenario 7/8 (fix round, M3): def -> ref click returns the cursor after the
    // reference, not before it -- both editors.
    //
    // Unlike scenarios 1-6 above (which insert a NEW footnote and verify the cursor lands in
    // the new DEFINITION), these two scenarios prove the FIXED direction from M1/M2: clicking
    // an EXISTING footnote's definition to jump BACK to its reference in the body text.
    // `selectFootnoteReference` (Milkdown) and `footnote-decoration-plugin.ts`'s `handleClick`
    // ref<->def branches (CodeMirror) both call `coordsAtPos`/layout APIs that jsdom -- the unit
    // test environment used everywhere else in this fix -- cannot exercise at all (no real
    // layout engine), which is exactly why M1's silent-failure-undoes-the-fix bug was invisible
    // to that suite. This is the only tier that can catch that class of regression.

    func testClickingFootnoteDefinitionInRichTextReturnsCursorAfterReference() throws {
        let sentinel = "SENT_M3RT_\(shortUUID())_"
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        Body text with a single reference[^1] here.

        # Notes

        [^1]: the definition text.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Default launch mode is Rich Text (Milkdown) -- see scenario 1 above, which clicks
        // straight into the body with no preceding mode switch either.
        clickFootnoteDefinitionPill(label: "1")
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelImmediatelyAfterReference(sentinel, label: "1")
    }

    func testClickingFootnoteDefinitionInMarkdownReturnsCursorAfterReference() throws {
        let sentinel = "SENT_M3MD_\(shortUUID())_"
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: """
        Body text with a single reference[^1] here.

        # Notes

        [^1]: the definition text.
        """)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        switchToSourceMode()

        clickFootnoteDefinitionMarker(label: "1")
        typeSentinelWithNoIntervening(sentinel)

        assertSentinelImmediatelyAfterReference(sentinel, label: "1")
    }
}

// MARK: - Shared helpers

extension FootnoteCursorPlacementE2ETests {
    func waitForEditorReady() {
        XCTAssertTrue(app.editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        // NOT `CONTAINS 'words'` -- the status bar shows a "0 words" placeholder before the
        // seeded document's real content has actually loaded, and "0 words" itself contains
        // "words", so that predicate was satisfied instantly regardless of whether the
        // document was ready. Every fixture this file seeds has real body text, so waiting for
        // a non-zero count is a safe, general readiness signal that this content has landed.
        XCTAssertTrue(
            wordCount.waitForValueNot("== '0 words'", timeout: 15),
            "Status bar should show non-zero word count (seeded document actually loaded, not just the editor JS placeholder)"
        )
    }

    func shortUUID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    /// Places the caret inside the document's first body paragraph, addressed by its own text
    /// (never a normalized offset on `editorArea`, whose frame spans the whole window content --
    /// dy 0.15 lands in the editor's non-editable top padding above the first block, the click is
    /// swallowed, and the caret silently keeps whatever position it had. That is what made
    /// scenarios 2/3 press Cmd-Shift-N with the caret parked at the end of the existing `[^1]`
    /// definition, left there by `retypeWholeSourceDocument`'s Cmd-A + retype.) Mirrors
    /// `ListNumberingE2ETests.swift:80-82`.
    func clickIntoEditorBody(bodyLinePrefix: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let paragraph = app.editorStaticText(startingWith: bodyLinePrefix, timeout: 10) else {
            XCTFail("Body paragraph starting \"\(bodyLinePrefix)\" is not reachable in the editor -- " +
                    "the caret cannot be placed, so this scenario would test the wrong gesture",
                    file: file, line: line)
            return
        }
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
    }

    /// Sends Cmd-Shift-N (the app's global "Insert Footnote" shortcut, `EditorCommands.swift`)
    /// and waits for the insertion round trip (`handleFootnoteInsertedImmediate`'s force-flush,
    /// DB read, and `setContentWithBlockIds` push) to have actually landed.
    ///
    /// NOT the status-bar word count: a newly-inserted footnote is a zero-word event by
    /// construction on both sides of the round trip -- `insertFootnote()` (footnote-plugin.ts /
    /// api.ts) inserts the new definition as an EMPTY string, and `MarkdownUtils.wordCount`
    /// strips footnote reference markers (`[^N]`) entirely before counting -- so
    /// `filteredTotalWordCount` never changes and a wait keyed on it can never land. (Confirmed
    /// by reading `MarkdownUtils.stripForWordCount`'s "Remove footnote references" step and
    /// `insertFootnote`'s `footnoteDefinitions.set(newLabel, '')`.)
    ///
    /// Uses `notesDefinitionCount()` (a DB poll, bounded, never a fixed sleep) instead: the new
    /// blank definition row is written synchronously inside `handleImmediateInsertion`, which
    /// runs BEFORE the async Task that flushes/fetches/pushes content to the editor and moves
    /// the cursor -- so this DB signal fires earlier than full landing, not later. The settle
    /// sleep below covers that gap; if it undershoots, `assertSentinelAtDefinitionStart`'s own
    /// bounded 15s DB poll is the real safety net -- a sentinel typed before the cursor actually
    /// moved lands in the wrong row and simply isn't found there, a clear and diagnosable
    /// failure rather than a silent false pass.
    func insertFootnoteAndWaitForLanding(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let before = notesDefinitionCount()
        app.activateAndWaitForForeground()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let landed = waitUntilTrue(timeout: timeout) { self.notesDefinitionCount() > before }
        XCTAssertTrue(
            landed,
            "isNotes paragraph count did not increase within \(timeout)s after Cmd-Shift-N -- the footnote insertion round trip did not land",
            file: file, line: line
        )
        // Settle for the async round trip's tail (flush -> DB read -> setContentWithBlockIds
        // push -> `.scrollToFootnoteDefinition` cursor placement) to finish landing in the
        // editor after the early DB write above is observed. Matches this suite's established
        // settle-sleep precedent for a comparable async-tail gap (e.g.
        // `E2ESectionReconcilerPseudoSectionTests`'s 2.5s post-mode-switch settle), sized up
        // from this file's original 0.3s now that the wait above fires earlier in the pipeline.
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Types `sentinel` with no intervening click or navigation after
    /// `insertFootnoteAndWaitForLanding` -- only re-asserting OS-level app focus (never a
    /// document click), matching T10's "no intervening click or navigation" requirement.
    /// `.scrollToFootnoteDefinition` already placed and focused the caret at the new
    /// definition as part of the same landing.
    ///
    /// Deliberately raw `typeText`, not `typeTextVerifyingLanded`: this call IS the T10
    /// mechanism under test -- a verify-and-repair wrapper could silently correct a
    /// mistyped/misplaced sentinel before `assertSentinelAtDefinitionStart`'s DB readback ever
    /// saw it, masking exactly the class of cursor-placement bug this file exists to catch.
    /// `assertSentinelAtDefinitionStart` below is itself the landing check, against the DB
    /// ground truth rather than the editor's own accessibility tree.
    func typeSentinelWithNoIntervening(_ sentinel: String) {
        app.activateAndWaitForForeground()
        // e2e-lint: allow raw-typetext -- see this method's doc comment above.
        app.typeText(sentinel)
    }

    func switchToSourceMode() {
        toggleEditorMode(to: "Source")
    }

    func switchToWysiwygMode() {
        toggleEditorMode(to: "WYSIWYG")
    }

    private func toggleEditorMode(to expectedLabel: String, file: StaticString = #filePath, line: UInt = #line) {
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear", file: file, line: line)
        var toggled = false
        for _ in 1...5 {
            if editorMode.label == expectedLabel { toggled = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== '\(expectedLabel)'", timeout: 2) { toggled = true; break }
        }
        XCTAssertTrue(toggled, "Editor-mode button should report \(expectedLabel) after retrying the toggle keystroke", file: file, line: line)
        // KNOWN RISK (documented precedent: `E2ESectionReconcilerPseudoSectionTests`'s Source
        // Mode toggle): the status-bar label flips before the async WYSIWYG<->CodeMirror view
        // swap necessarily finishes. Generous settle as mitigation, not a guarantee, matching
        // that file's own 2.5s convention -- without it, a click immediately after this toggle
        // can land on a not-yet-mounted editor.
        Thread.sleep(forTimeInterval: 2.5)
    }

    /// Selects the whole CodeMirror document (Cmd-A + Delete) and retypes it as `newDocument`
    /// -- the full-document-retype technique this file's header comment explains (sidesteps
    /// fragile per-line coordinate targeting for a heading-level or reference edit). Clicks
    /// into the editor first to guarantee first-responder focus for the Cmd-A. Verifies the
    /// retype actually landed via `editorContainsText` for EVERY string in `landedEvidence`
    /// (never assumed) before returning -- callers pass more than one distinct substring
    /// spanning the document (e.g. the flipped heading AND the definition text near the end)
    /// so a `typeText` character drop -- a whole-document retype doesn't fit
    /// `typeTextVerifyingLanded`'s "own, otherwise-empty line" precondition, so that helper
    /// isn't a fit here -- landing in a region NEITHER caller happens to assert on later is
    /// still caught here, rather than surfacing later as a misleading assertion failure
    /// against the wrong evidence.
    func retypeWholeSourceDocument(_ newDocument: String, landedEvidence: [String], file: StaticString = #filePath, line: UInt = #line) {
        func attempt() -> Bool {
            app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
            app.activateAndWaitForForeground()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            // e2e-lint: allow raw-typetext -- see this method's doc comment above.
            app.typeText(newDocument)
            return landedEvidence.allSatisfy { app.editorContainsText($0, timeout: 10) }
        }

        // Retry-once fallback, matching the established, proven precedent in
        // `E2ESectionReconcilerPseudoSectionTests`'s `selectAllAndPasteReplacement` (which
        // retries its own Cmd-A + paste once on the same "did the edit actually land" evidence)
        // rather than tuning the settle timing further -- a second full click + Cmd-A + Delete +
        // retype gives the sequence a fresh attempt against an editor that has now had strictly
        // more time to settle, without loosening what has to land.
        if !attempt() {
            _ = attempt()
        }

        for evidence in landedEvidence {
            XCTAssertTrue(
                app.editorContainsText(evidence, timeout: 10),
                "Retyped source document should contain \"\(evidence)\" after the edit (even after one retry)",
                file: file, line: line
            )
        }
    }

    func waitUntilTrue(timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.3, _ probe: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if probe() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        } while Date() < deadline
        return probe()
    }

    // MARK: - DB ground-truth queries (safe to run while the app is open -- WAL mode, see
    // `FixtureDatabase`'s own doc comment in UITestHelpers.swift).

    func notesHeadingCount() -> Int {
        let sql = "SELECT count(*) FROM block WHERE isNotes = 1 AND blockType = 'heading';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// The `headingLevel` of the (first, by `sortOrder`) `isNotes` heading row, or `nil` if none
    /// exists. `editorContainsText("# Notes")` / `"## Notes"` is a CONTAINS scan -- `"## Notes"`
    /// contains `"# Notes"` as a substring, so a text-presence check alone can never actually
    /// discriminate which level is present. This queries the real level directly from the DB.
    func notesHeadingLevel() -> Int? {
        let sql = "SELECT headingLevel FROM block WHERE isNotes = 1 AND blockType = 'heading' ORDER BY sortOrder LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(stdout)
    }

    /// Count of `isNotes` paragraph rows (footnote definitions). Used by
    /// `insertFootnoteAndWaitForLanding` as the footnote-insertion landing signal -- see that
    /// method's doc comment for why the status-bar word count can never serve this purpose.
    func notesDefinitionCount() -> Int {
        let sql = "SELECT count(*) FROM block WHERE isNotes = 1 AND blockType = 'paragraph';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// True when every `isNotes` row's sortOrder is greater than every non-`isNotes` row's
    /// sortOrder -- i.e. the Notes run sits at the true end of the document. Used by scenario 4
    /// to confirm settled decision 1 (an adopted mid-document run is relocated, not left in place).
    func notesRunIsAfterEveryOtherBlock() -> Bool {
        let sql = "SELECT (SELECT MIN(sortOrder) FROM block WHERE isNotes = 1) > " +
            "(SELECT COALESCE(MAX(sortOrder), -1) FROM block WHERE isNotes = 0);"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout == "1"
    }

    /// Finds the (markdownFragment, textContent) of the `isNotes` paragraph block whose
    /// `markdownFragment` CONTAINS `substring` -- used to locate a definition by a unique
    /// phrase in its own text, never by its current `[^N]:` label (labels renumber; see
    /// e2e-verify's "Footnote labels are NOT stable identifiers" gotcha).
    func notesParagraphFragment(containing substring: String) -> (markdownFragment: String, textContent: String)? {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE isNotes = 1 AND blockType = 'paragraph' " +
            "AND markdownFragment LIKE '%\(FixtureDatabase.escape(substring))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        let trimmed = stdout.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, let range = trimmed.range(of: sep) else { return nil }
        return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
    }

    /// Sibling of `notesParagraphFragment` WITHOUT the `isNotes = 1` filter -- for content that
    /// is expected to be a real, surviving paragraph row that is correctly no longer flagged
    /// `isNotes` (e.g. user prose left behind once its enclosing Notes section has legitimately
    /// dissolved). Mirrors that helper's field-separator/parsing exactly.
    func paragraphFragment(containing substring: String) -> (markdownFragment: String, textContent: String)? {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE blockType = 'paragraph' " +
            "AND markdownFragment LIKE '%\(FixtureDatabase.escape(substring))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        let trimmed = stdout.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, let range = trimmed.range(of: sep) else { return nil }
        return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
    }

    /// Diagnostic dump of every `isNotes` row's id, blockType, headingLevel, markdownFragment,
    /// and textContent -- for a loud failure message (e2e-verify skill: "Helpers must fail
    /// loudly") when a targeted query comes back unexpectedly, so a future diagnosis round has
    /// the full picture (e.g. a duplicate/twin row) instead of just one query's result.
    func allNotesRowsDump() -> String {
        let sep = "###FF_E2E_FIELD_SEP###"
        let sql = "SELECT id || '\(sep)' || blockType || '\(sep)' || COALESCE(headingLevel, -1) || " +
            "'\(sep)' || markdownFragment || '\(sep)' || textContent FROM block " +
            "WHERE isNotes = 1 ORDER BY sortOrder;"
        return FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
    }

    /// Bounded poll (never a fixed sleep) for a `notesParagraphFragment` result that matches
    /// `before` EXACTLY on both `markdownFragment` and `textContent` -- not a substring-of-the-
    /// raw-marker containment check, which can never become true for a marker shape that
    /// `textContent`'s own normalization (e.g. `MarkdownUtils.stripMarkdownSyntax`) legitimately
    /// alters. Guards a project-reopen readback (scenario 5) against a transient startup state
    /// where `markdownFragment` (unchanged since the prior session's parse) already matches the
    /// LIKE query before a still-settling `textContent` has caught up.
    func notesParagraphFragmentSettled(
        containing substring: String,
        before: (markdownFragment: String, textContent: String)?,
        timeout: TimeInterval = 15
    ) -> (markdownFragment: String, textContent: String)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let found = notesParagraphFragment(containing: substring)
            if let found, found.markdownFragment == before?.markdownFragment, found.textContent == before?.textContent {
                return found
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while Date() < deadline
        return notesParagraphFragment(containing: substring)
    }

    /// T10's position-assertion mechanism. Polls (bounded, never a fixed sleep -- the typed
    /// sentinel's own flush back to the DB still runs on the normal debounced path) for a
    /// definition block containing `sentinel`, then asserts the sentinel sits immediately
    /// after the "]: " label-prefix boundary in `markdownFragment` -- a bare CONTAINS check
    /// would hide exactly the prefix-boundary/positional error class this whole task exists to
    /// close (the "search-and-guess, not content-verified" pattern documented in notes.md's
    /// "Prior attempt" section). `textContent` (prefix-stripped) is asserted too, so the two
    /// fields can never silently drift apart.
    func assertSentinelAtDefinitionStart(
        _ sentinel: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var found: (markdownFragment: String, textContent: String)?
        repeat {
            found = notesParagraphFragment(containing: sentinel)
            if found != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while found == nil && Date() < deadline

        guard let row = found else {
            XCTFail("No isNotes paragraph block containing sentinel \"\(sentinel)\" appeared within \(timeout)s", file: file, line: line)
            return
        }

        guard let prefixRange = row.markdownFragment.range(of: "]: ") else {
            XCTFail(
                "markdownFragment \"\(row.markdownFragment)\" does not match the expected \"[^N]: \" definition prefix shape",
                file: file, line: line
            )
            return
        }
        let afterPrefix = row.markdownFragment[prefixRange.upperBound...]
        XCTAssertTrue(
            afterPrefix.hasPrefix(sentinel),
            "markdownFragment's definition text must START with the sentinel immediately after the \"[^N]: \" prefix -- " +
                "got markdownFragment=\"\(row.markdownFragment)\"",
            file: file, line: line
        )
        // CONFIRMED (by reading the source, not guessed): a Milkdown-authored footnote
        // definition's body carries exactly one leading space ahead of its real text in
        // `textContent`, even though `markdownFragment` does not. Root cause traced to
        // `web/milkdown/src/footnote-plugin.ts`'s `remarkFootnotePlugin` (pass 1, ~line 74):
        // parsing a `[^N]: text` GFM footnoteDefinition unconditionally builds the paragraph's
        // text-node sibling to the atomic `footnote_def` pill as `` `${childText}` `` -- a
        // deliberate ONE-space separator, since the pill's own `toMarkdown` emits `[^N]:` with
        // no trailing space (block-sync-plugin.ts:472) and relies on that sibling text node to
        // supply it on re-serialization. `web/milkdown/src/block-sync-plugin.ts`'s block-sync
        // diffing (line 764) captures `Block.textContent` straight from ProseMirror's native
        // `node.textContent` -- which concatenates that same leading-space-bearing text node
        // verbatim, since `footnote_def` is an atom (`.textContent` is `''` for atoms; see the
        // comment beside block-sync-plugin.ts:474) -- so the separator space that's supposed to
        // be purely a markdown-serialization artifact leaks into the stored "body text" field.
        // `markdownFragment` escapes this because the SAME leading space is exactly what
        // supplies the "]: " separator this function already consumed above, leaving nothing
        // extra for the sentinel to be prefixed by there. Out of scope for this test file (a
        // pre-existing Milkdown round-trip quirk, unrelated to Notes H1/H2 unification) --
        // asserting what the app actually and consistently does, not loosening to a bare
        // `contains` that would also swallow a genuine prefix-boundary regression.
        let expectedTextContent = " \(sentinel)"
        XCTAssertTrue(
            row.textContent.hasPrefix(expectedTextContent),
            "textContent (prefix-stripped) must start with the sentinel, prefixed by exactly the one known " +
                "editor-internal separator space (see this assertion's comment) -- got textContent=\"\(row.textContent)\"",
            file: file, line: line
        )
    }

    // MARK: - Fix round (M3) helpers: def -> ref click, both editors

    /// Clicks the footnote_def PILL (Rich Text/Milkdown) for `label` -- the small rounded atom
    /// `footnoteDefNodeView` renders at the start of the definition paragraph
    /// (`.ff-footnote-def` in `web/milkdown/src/styles.css`) -- to trigger
    /// `selectFootnoteReference`'s def->ref jump (M1's fix). Located via the SAME
    /// `editorStaticText(startingWith:)` + dx:0.02 idiom `clickIntoEditorBody` and
    /// `ListNumberingE2ETests` already rely on for "click near the very start of a found
    /// paragraph/line's own AX element" (dx too close to 0 risks the non-editable edge padding,
    /// per `clickIntoEditorBody`'s own doc comment), searching on `label` alone rather than a
    /// prefix of the definition's body text: the pill's own rendered text IS the label digit,
    /// and (per this suite's established heading-container precedent -- "a heading container's
    /// label concatenates all child text") the atom and its text sibling are expected to
    /// concatenate into one paragraph-level AX element beginning with that digit; even if they
    /// instead surface as separate leaves, the pill's own leaf value is just the digit, so
    /// `dx: 0.02` of either shape still lands on the pill. Only safe for a single-digit,
    /// non-renumbering fixture (as these two scenarios use) since it does not disambiguate
    /// multiple footnotes sharing a leading digit.
    func clickFootnoteDefinitionPill(label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let pillElement = app.editorStaticText(startingWith: label, timeout: 10) else {
            XCTFail("Footnote definition pill for label \"\(label)\" not reachable in the editor", file: file, line: line)
            return
        }
        pillElement.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        // Small settle for the click handler's synchronous dispatch + `view.focus()` to be
        // observed by the next XCUITest keystroke -- the operation itself is synchronous
        // JS/ProseMirror work, not an async Swift<->JS round trip, so this is a much smaller
        // margin than `insertFootnoteAndWaitForLanding`'s 1.5s settle for that async tail.
        // Matches the established 0.3s post-click settle pattern used pervasively
        // elsewhere in this suite (e.g. editCaption, deleteTargetParagraph).
        // e2e-lint: allow sleep
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Clicks inside the "[^N]:" definition marker (Markdown/CodeMirror) for `label` --
    /// decorated with the `cm-footnote-def` class by `footnote-decoration-plugin.ts`'s
    /// `buildDecorations` -- to trigger `handleClick`'s def->ref branch (the already-fixed half
    /// of the mirror-image pair M2 also corrects in this same function). `handleClick` only
    /// recognizes a click whose resolved document position falls within the "[^N]:" character
    /// range itself, not the trailing definition text, so this must land inside that literal
    /// substring rather than merely "near the start of the line".
    ///
    /// CONFIRMED live (vmtest, this round): CodeMirror does NOT expose "[^1]:" as one merged AX
    /// leaf, nor does it split it arbitrarily -- it splits at exactly the same boundary as the
    /// bare reference marker "[^1]" (its own separate leaf, per this suite's documented "a line
    /// can split across multiple leaf StaticTexts" gotcha), with the colon landing in its own
    /// immediately-following sibling leaf: three consecutive `staticTexts` leaves
    /// `"[^1]"` | `":"` | `" the definition text."`. So no leaf's own text ever starts with the
    /// literal "[^1]:", which is why `editorStaticText(startingWith: marker)` (prefix-matching a
    /// single element) could never find it -- not a timing issue, a query-shape one.
    ///
    /// A bare `"[^N]"` prefix search is not enough on its own, though: the body's reference
    /// marker for the same label renders as an IDENTICAL leaf text ("[^1]"), and it always
    /// appears earlier in document order (the reference precedes its definition), so the first
    /// "[^1]"-prefixed leaf in the tree is the WRONG one -- clicking it would fire `handleClick`'s
    /// ref->def branch instead of the def->ref branch this helper exists to trigger. The
    /// distinguishing signal is the same one `footnote-decoration-plugin.ts`'s own regexes use:
    /// `FOOTNOTE_DEF_REGEX` requires the marker be immediately followed by ":", while
    /// `FOOTNOTE_REF_REGEX` explicitly excludes it (`(?!:)`). So this scans for a "[^N]"-prefixed
    /// leaf whose immediately-following sibling leaf starts with ":" -- true only for the
    /// definition's marker, never the reference's.
    func clickFootnoteDefinitionMarker(label: String, file: StaticString = #filePath, line: UInt = #line) {
        let markerPrefix = "[^\(label)]"
        let deadline = Date(timeIntervalSinceNow: 10)
        var markerElement: XCUIElement?
        repeat {
            let elements = app.editorArea.staticTexts.allElementsBoundByIndex
            for index in elements.indices {
                let element = elements[index]
                guard element.exists else { continue }
                let text = (element.value as? String) ?? element.label
                guard text.hasPrefix(markerPrefix) else { continue }

                guard index + 1 < elements.count, elements[index + 1].exists else { continue }
                let nextText = (elements[index + 1].value as? String) ?? elements[index + 1].label
                if nextText.hasPrefix(":") {
                    markerElement = element
                    break
                }
            }
            if markerElement != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline

        guard let markerElement else {
            XCTFail("Footnote definition marker \"\(markerPrefix):\" not reachable in the editor", file: file, line: line)
            return
        }
        // The found leaf's own text is just "[^N]" (the colon is a separate sibling leaf), so
        // any point inside it resolves to a document position within the "[^N]:" match range --
        // center (dx: 0.5) keeps the click well clear of the leaf's own edges.
        markerElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // See clickFootnoteDefinitionPill's matching comment on this settle's size.
        // e2e-lint: allow sleep -- same established post-click settle pattern.
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// M3 (fix round for t-fee9dce6): asserts `sentinel` sits immediately after "[^N]" in the
    /// referencing body paragraph's `markdownFragment` -- the M1/M2 regression this pair of
    /// scenarios exists to prove e2e. "Before it" would mean the caret was still landing BEFORE
    /// the "[^N]" marker (the pre-fix bug this replaces: `Selection.near` stopping at the
    /// already-legal position before the atom instead of advancing past it), so this checks the
    /// immediate AFTER-position specifically, not just presence anywhere in the block. Reuses
    /// `paragraphFragment` (no `isNotes` filter, since the target here is the BODY paragraph,
    /// not a Notes definition) rather than a new query.
    func assertSentinelImmediatelyAfterReference(
        _ sentinel: String, label: String, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var found: (markdownFragment: String, textContent: String)?
        repeat {
            found = paragraphFragment(containing: sentinel)
            if found != nil { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        } while found == nil && Date() < deadline

        guard let row = found else {
            XCTFail("No body paragraph block containing sentinel \"\(sentinel)\" appeared within \(timeout)s", file: file, line: line)
            return
        }

        guard let refRange = row.markdownFragment.range(of: "[^\(label)]") else {
            XCTFail(
                "markdownFragment \"\(row.markdownFragment)\" does not contain the expected \"[^\(label)]\" reference marker",
                file: file, line: line
            )
            return
        }
        let afterRef = row.markdownFragment[refRange.upperBound...]
        XCTAssertTrue(
            afterRef.hasPrefix(sentinel),
            "sentinel must land immediately AFTER \"[^\(label)]\", not before it (the M1/M2 regression) -- " +
                "got markdownFragment=\"\(row.markdownFragment)\"",
            file: file, line: line
        )
    }
}
