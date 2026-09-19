//
//  AnnotationDeleteE2ETests.swift
//  final finalUITests
//
//  E2E proof for t-c683aa25 (inline-annotation delete + quiet, undoable Document Note delete).
//  Each test method maps to one or more items of the plan's user-verification list -- see the
//  mapping table in .claude/superdev/annotation-delete/notes.md.
//
//  Setup strategy: a Document Note is a DB-only row (charOffset == -1, never part of
//  content.markdown) and creating one leaves no undo-timeline entry at all (only the delete
//  does, per the plan's B3/B4) -- so every test seeds Document Notes directly via
//  FixtureDatabase (the same "seed via SQL, app terminated" pattern seedMarkdown already uses)
//  rather than driving the panel's "+" Menu, which has no accessibility identifier and would
//  add UI fragility to the SETUP step instead of the DELETE behavior actually under test.
//  Inline annotations are seeded as markdown HTML comments (`<!-- ::type:: text -->`,
//  Annotation.markdownSyntax / annotation-plugin.ts's annotationRegex), which the app parses
//  into real atomic annotation nodes on load -- this exercises the real parse path, unlike the
//  Document Note case.
//
//  AnnotationCardView.swift sets no accessibility identifier on either a card row or its
//  hover-revealed delete "x" button (an Image(systemName: "xmark") with only a `.help()`
//  tooltip, which XCUITest does not expose as label/value) -- deleteAnnotationPanelCard(withText:)
//  below locates it geometrically (any button that appears near the card's own text, in the
//  same row band, after hovering), mirroring this suite's own established fallback for
//  under-identified interactive elements (UnifiedUndoE2ETests+Helpers.swift's dragSidebarCard
//  coordinate math, sidebarCard(titled:)'s NSPredicate-over-subscript choice) rather than a
//  blind coordinate guess against a panel width this test has no way to measure.
//

import XCTest

final class AnnotationDeleteE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try TestFixtureHelper.setupFixture(from: self)
        app = XCUIApplication.targetApp()
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Item 1, 2, 3: Document Note delete is quiet and undoable

    func testDocumentNoteDeleteIsQuietAndUndoable() throws {
        let markdown = """
        # Document Note Delete

        Body paragraph so the editor has content to word-count.
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        let noteId = "e2e-doc-note-\(shortUUID())"
        let noteText = "Document Note delete regression note"
        seedDocumentNote(id: noteId, type: "comment", text: noteText)

        launchAndWaitForEditor()
        ensureAnnotationsPanelVisible()

        XCTAssertEqual(queryAnnotationCount(id: noteId), 1, "Seeded Document Note should exist before the delete")
        XCTAssertTrue(panelText(noteText).waitForExistenceOrFail(timeout: 10).exists, "Document Note card should show in the panel")

        // Item 1: delete via the card's x -- no warning dialog (D3).
        XCTAssertTrue(deleteAnnotationPanelCard(withText: noteText), "Should find and click the Document Note card's delete button")
        // This is a negative assertion (no alert appeared); there is no observable-change
        // event to wait on for an absence. A brief settle here gives an alert every real
        // chance to have appeared before checking it hasn't; the DB-row absence right below
        // is the actual robust (polled) assertion for "the delete happened."
        // e2e-lint: allow sleep -- see rationale above.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Deleting a Document Note must not raise a confirmation sheet (UX contract tier 1)")
        XCTAssertFalse(app.dialogs.firstMatch.exists, "Deleting a Document Note must not raise a confirmation dialog (UX contract tier 1)")
        waitUntil(probe: { self.queryAnnotationCount(id: noteId) }, predicate: { $0 == 0 })
        XCTAssertEqual(queryAnnotationCount(id: noteId), 0, "Document Note row should be gone from the DB")

        // Item 2: ⌘Z brings it back, pressed with NO click into the editor first -- this is
        // exactly the case B8's focus-restoration fix exists for (the card's x button becomes
        // first responder on click, which would otherwise send ⌘Z down UndoRedoCommands'
        // silent-no-op nil-target path).
        pressUndoWithoutClickingEditor()
        waitUntil(probe: { self.queryAnnotationCount(id: noteId) }, predicate: { $0 == 1 })
        XCTAssertEqual(queryAnnotationCount(id: noteId), 1, "⌘Z (no editor click first) should restore the Document Note row")
        XCTAssertTrue(panelText(noteText).waitForExistenceOrFail(timeout: 10).exists, "Restored Document Note should reappear in the panel")

        // Item 3: ⌘⇧Z removes it again.
        pressRedoWithoutClickingEditor()
        waitUntil(probe: { self.queryAnnotationCount(id: noteId) }, predicate: { $0 == 0 })
        XCTAssertEqual(queryAnnotationCount(id: noteId), 0, "⌘⇧Z should remove the Document Note again")
    }

    // MARK: - Item 4, 5: inline annotation delete via popup and Backspace

    func testInlineAnnotationDeleteViaPopupAndBackspace() throws {
        let popupText = "Delete via popup"
        let backspaceText = "Delete via backspace"
        let markdown = """
        # Inline Annotation Delete

        Paragraph for the popup-delete case.

        <!-- ::comment:: \(popupText) -->

        Paragraph for the backspace-delete case.

        <!-- ::comment:: \(backspaceText) -->
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()

        // Extra content-based readiness gate before this test's very first editor-content query.
        // Unlike its 4 sibling tests in this file, this one queries editor content as its
        // literal first action right after launchAndWaitForEditor() -- the siblings all call
        // ensureAnnotationsPanelVisible() first, which incidentally gives the WebView time to
        // finish mounting its accessibility tree before their first editorContainsText check.
        // This test skips that, so at the default 5s editorContainsText timeout the query can
        // return false after a single incomplete accessibility-tree pass. Waiting for real
        // rendered content (the codebase's own established idiom, e.g. `editorStaticText`
        // elsewhere -- see UnifiedUndoE2ETests.swift's testUndoWorksAfterClosingFindBarNoManualClick)
        // is a stronger, non-arbitrary gate than a longer blind sleep.
        XCTAssertNotNil(
            app.editorStaticText(startingWith: "Inline Annotation Delete", timeout: 15),
            "Editor should render its first heading before this test's first interaction"
        )

        XCTAssertTrue(app.editorContainsText(popupText, timeout: 10), "Popup-target annotation should render in the editor")
        XCTAssertTrue(app.editorContainsText(backspaceText, timeout: 10), "Backspace-target annotation should render in the editor")

        // Item 4: delete via the popup's "Delete Annotation" button, ⌘Z restores.
        openAnnotationPopup(text: popupText)
        let deleteButton = app.buttons["Delete Annotation"]
        XCTAssertTrue(deleteButton.waitForExistenceOrFail(timeout: 10).exists, "\"Delete Annotation\" popup button should appear")
        deleteButton.click()
        waitUntil(probe: { self.queryAnnotationTextExists(popupText) }, predicate: { !$0 })
        XCTAssertFalse(queryAnnotationTextExists(popupText), "Annotation row should be gone from the DB after popup delete")
        XCTAssertFalse(app.editorContainsText(popupText, timeout: 5), "Annotation text should be gone from the editor after popup delete")

        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.editorContainsText(popupText, timeout: 10), "⌘Z should restore the popup-deleted annotation")

        // Item 5: delete via Backspace with the caret right after the node, ⌘Z restores.
        // `backspaceText`'s annotation is the LAST thing in the seeded document, so Cmd-ArrowDown
        // (cursorDocEnd -- "End" does not reach true doc end in this app's line-wrapping
        // CodeMirror/Milkdown editors, see e2e-verify skill) lands the caret right after it,
        // which is exactly the position annotationDeleteKeymap's Backspace handler checks
        // ($from.nodeBefore).
        clickIntoEditor()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        waitUntil(probe: { self.queryAnnotationTextExists(backspaceText) }, predicate: { !$0 })
        XCTAssertFalse(queryAnnotationTextExists(backspaceText), "Annotation row should be gone from the DB after Backspace delete")
        XCTAssertFalse(app.editorContainsText(backspaceText, timeout: 5), "Annotation text should be gone from the editor after Backspace delete")

        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.editorContainsText(backspaceText, timeout: 10), "⌘Z should restore the Backspace-deleted annotation")
    }

    // MARK: - Item 6, 7: inline annotation delete via panel card, both editor modes

    func testInlineAnnotationDeletePanelCardBothEditorModes() throws {
        let wysiwygText = "Delete via Rich Text panel card"
        let sourceText = "Delete via Markdown panel card"
        let markdown = """
        # Panel Card Delete

        Paragraph for the Rich Text panel-card delete case.

        <!-- ::comment:: \(wysiwygText) -->

        Paragraph for the Markdown-mode panel-card delete case.

        <!-- ::comment:: \(sourceText) -->
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        ensureAnnotationsPanelVisible()

        // Item 6: delete an inline annotation from its panel card -- ⌘Z (no click into the
        // editor first) restores it in BOTH the panel and the document.
        XCTAssertTrue(panelText(wysiwygText).waitForExistenceOrFail(timeout: 10).exists)
        XCTAssertTrue(deleteAnnotationPanelCard(withText: wysiwygText))
        waitUntil(probe: { self.queryAnnotationTextExists(wysiwygText) }, predicate: { !$0 })
        XCTAssertFalse(queryAnnotationTextExists(wysiwygText), "Row should be gone from the DB")
        XCTAssertFalse(app.editorContainsText(wysiwygText, timeout: 5), "Text should be gone from the document")

        pressUndoWithoutClickingEditor()
        waitUntil(probe: { self.queryAnnotationTextExists(wysiwygText) }, predicate: { $0 })
        XCTAssertTrue(queryAnnotationTextExists(wysiwygText), "⌘Z should restore the DB row")
        XCTAssertTrue(app.editorContainsText(wysiwygText, timeout: 10), "⌘Z should restore the text in the document")
        XCTAssertTrue(panelText(wysiwygText).waitForExistenceOrFail(timeout: 10).exists, "⌘Z should restore the panel card")

        // Item 7: same behavior in Markdown mode. The panel is native SwiftUI and is not
        // conditioned on editor mode, so the card should still be there and behave the same way.
        switchToSourceMode()
        XCTAssertTrue(panelText(sourceText).waitForExistenceOrFail(timeout: 10).exists, "Panel card should still show in Markdown mode")
        XCTAssertTrue(deleteAnnotationPanelCard(withText: sourceText))
        waitUntil(probe: { self.queryAnnotationTextExists(sourceText) }, predicate: { !$0 })
        XCTAssertFalse(queryAnnotationTextExists(sourceText), "Row should be gone from the DB in Markdown mode too")

        pressUndoWithoutClickingEditor()
        waitUntil(probe: { self.queryAnnotationTextExists(sourceText) }, predicate: { $0 })
        XCTAssertTrue(
            queryAnnotationTextExists(sourceText),
            "⌘Z should restore the DB row in Markdown mode "
                + "(CodeMirror's own text history -- A4's deliberate choice not to use addToHistory.of(false))"
        )
        XCTAssertTrue(panelText(sourceText).waitForExistenceOrFail(timeout: 10).exists, "⌘Z should restore the panel card in Markdown mode")
    }

    // MARK: - Item 8 (load-bearing): cross-op interleaving undo order

    func testCrossOpInterleavingSectionDeleteThenDocumentNoteDeleteUndoOrder() throws {
        let markdown = """
        # First Section

        First section body text for word counting.

        ## Second Section

        Second section body text for word counting purposes.
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        let noteId = "e2e-interleave-note-\(shortUUID())"
        let noteText = "Interleaving cross-op test note"
        seedDocumentNote(id: noteId, type: "comment", text: noteText)

        launchAndWaitForEditor()
        ensureAnnotationsPanelVisible()
        XCTAssertEqual(querySectionCount(), 2, "Fixture should start with both sections")

        // Delete a section from the sidebar first.
        rightClickSidebarCard(titled: "Second Section", thenChooseMenuItem: "Delete Section")
        waitUntil(probe: { self.querySectionCount() }, predicate: { $0 == 1 })
        XCTAssertEqual(querySectionCount(), 1, "\"Second Section\" should be deleted")

        // Then add+delete a Document Note. The "add" was seeded before launch -- creating a
        // Document Note leaves no undo-timeline entry at all (only the delete does, per B3/B4),
        // so what matters for this scenario is that the DELETE happens chronologically after
        // the section delete, which this ordering guarantees regardless of how the note itself
        // was created.
        XCTAssertTrue(panelText(noteText).waitForExistenceOrFail(timeout: 10).exists)
        XCTAssertTrue(deleteAnnotationPanelCard(withText: noteText))
        waitUntil(probe: { self.queryAnnotationCount(id: noteId) }, predicate: { $0 == 0 })
        XCTAssertEqual(queryAnnotationCount(id: noteId), 0, "Document Note should be deleted")

        // First ⌘Z (no click into the editor -- B8's focus-restoration fix): brings back the
        // Document Note, section STILL deleted. This is B5's routing fix (pinning
        // preOpDoc/postOpDoc to the live document) proven live, together with the midOp fix --
        // a unit test cannot see either, since both require the REAL registry ordering across
        // two different kinds of tracked entry.
        pressUndoWithoutClickingEditor()
        waitUntil(probe: { self.queryAnnotationCount(id: noteId) }, predicate: { $0 == 1 })
        XCTAssertEqual(queryAnnotationCount(id: noteId), 1, "First ⌘Z should restore the Document Note")
        XCTAssertEqual(querySectionCount(), 1, "First ⌘Z should NOT restore the section yet -- undo order must match delete order")
        XCTAssertTrue(panelText(noteText).waitForExistenceOrFail(timeout: 10).exists)

        // Second ⌘Z: brings back the section.
        pressUndoWithoutClickingEditor()
        waitUntil(probe: { self.querySectionCount() }, predicate: { $0 == 2 })
        XCTAssertEqual(querySectionCount(), 2, "Second ⌘Z should restore \"Second Section\"")
        XCTAssertEqual(queryAnnotationCount(id: noteId), 1, "Document Note should still be present after the second ⌘Z")
    }

    // MARK: - Review round 1 regression: stale-index identity verification

    func testPanelCardDeleteVerifiesIdentityNotStaleIndex() throws {
        let alpha = "Alpha annotation"
        let bravo = "Bravo annotation"
        let charlie = "Charlie annotation"
        let markdown = """
        # Stale Index Regression

        <!-- ::comment:: \(alpha) -->

        <!-- ::comment:: \(bravo) -->

        <!-- ::comment:: \(charlie) -->
        """
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: markdown)
        launchAndWaitForEditor()
        ensureAnnotationsPanelVisible()

        XCTAssertTrue(panelText(alpha).waitForExistenceOrFail(timeout: 10).exists)
        XCTAssertTrue(panelText(bravo).waitForExistenceOrFail(timeout: 10).exists)
        XCTAssertTrue(panelText(charlie).waitForExistenceOrFail(timeout: 10).exists)

        // Delete the first annotation, then IMMEDIATELY (no wait for the ~500ms DB-observation
        // debounce that can desync the panel's `index` from the live document --
        // ContentView+ContentRebuilding.swift's deleteInlineAnnotation doc comment, the
        // must-fix-1 review-round fix) delete what the panel currently shows as the second
        // card. Without the identity check (expectedType/expectedText, verified against the
        // LIVE document before falling back to a unique type+text rescan), a positional-only
        // delete racing this debounce could delete the WRONG (adjacent) annotation instead.
        XCTAssertTrue(deleteAnnotationPanelCard(withText: alpha))
        XCTAssertTrue(deleteAnnotationPanelCard(withText: bravo))

        waitUntil(probe: { self.queryInlineAnnotationTexts() }, predicate: { $0 == [charlie] })
        XCTAssertEqual(
            queryInlineAnnotationTexts(), [charlie],
            "Exactly Alpha and Bravo should be deleted -- Charlie must survive untouched, never an adjacent annotation deleted by a stale index"
        )
        XCTAssertTrue(app.editorContainsText(charlie), "Charlie should remain visible in the document")
        XCTAssertFalse(app.editorContainsText(alpha, timeout: 3), "Alpha should be gone from the document")
        XCTAssertFalse(app.editorContainsText(bravo, timeout: 3), "Bravo should be gone from the document")
    }
}

// MARK: - Local helpers
//
// Self-contained copies (not shared extensions) of proven patterns from
// UnifiedUndoE2ETests+Helpers.swift -- that file's helpers are declared as
// `extension UnifiedUndoE2ETests`, tied to a different XCTestCase subclass, so the small
// subset this file needs (launch/ready, sidebar card + right-click, ⌘Z/⌘⇧Z without an editor
// click, Source-mode switch, DB polling) is reproduced here rather than shared, matching the
// same techniques verified in that file.

extension AnnotationDeleteE2ETests {
    func launchAndWaitForEditor() {
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
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

    /// Same "activate, no editor click" shape both proves (B8's focus-restoration fix means
    /// this must work) and needs (a native SwiftUI Button click, e.g. the card's own delete "x",
    /// takes first responder away from the editor -- UndoRedoCommands.focusedWebView() would
    /// otherwise resolve nil and silently no-op the keystroke).
    func pressUndoWithoutClickingEditor() {
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
    }

    func pressRedoWithoutClickingEditor() {
        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: [.command, .shift])
    }

    /// isAnnotationPanelVisible defaults to true (EditorViewState.swift), but per the
    /// e2e-verify skill's "never assume a toggleable panel's default visibility" lesson
    /// (toolbar-icon-cleanup, 2026-09-06), check first rather than assume, toggling only if
    /// the panel's own "Document Notes" section header isn't already there.
    func ensureAnnotationsPanelVisible() {
        if panelText("Document Notes", timeout: 3).exists { return }
        app.activateAndWaitForForeground()
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(
            panelText("Document Notes", timeout: 10).waitForExistenceOrFail(timeout: 5).exists,
            "Annotations panel should show its \"Document Notes\" section header once visible"
        )
    }

    /// Finds a StaticText anywhere in the app matching `text` exactly, by label OR value --
    /// same NSPredicate approach as UnifiedUndoE2ETests+Helpers.swift's sidebarCard(titled:),
    /// used here instead of a bare `app.staticTexts[text]` subscript for the same reason: this
    /// codebase's own precedent found the subscript form unreliable against real AX content.
    func panelText(_ text: String, timeout: TimeInterval = 10) -> XCUIElement {
        // The lint rule's concern is the editor's three-StaticTexts-per-heading collision
        // (.firstMatch resolving to the sidebar mirror, not the editor). This query is
        // app-wide but exact-match against native Annotations-panel card/header text (never a
        // heading, never editor content), which that collision doesn't apply to; `text` values
        // used with this helper are chosen to be unique to this test's own fixture.
        // e2e-lint: allow statictext-firstmatch -- see rationale above.
        let element = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        _ = element.waitForExistence(timeout: timeout)
        return element
    }

    /// Hovers the card whose text is `cardText` (revealing its delete "x" button, which only
    /// renders while AnnotationCardView's `isHovering` is true) then clicks that button. See
    /// this file's header comment for why the button is located geometrically instead of by
    /// identifier. Returns false (never fails the test itself) if no such button is found,
    /// so callers get a specific, assert-driven failure message.
    @discardableResult
    func deleteAnnotationPanelCard(withText cardText: String, timeout: TimeInterval = 10) -> Bool {
        let card = panelText(cardText, timeout: timeout)
        guard card.exists else { return false }
        card.hover()
        let rowY = card.frame.midY
        let cardMaxX = card.frame.maxX
        let deadline = Date(timeIntervalSinceNow: 5)
        repeat {
            for button in app.buttons.allElementsBoundByIndex {
                guard button.exists else { continue }
                let frame = button.frame
                guard frame.width > 0, frame.height > 0 else { continue }
                if frame.minX >= cardMaxX - 4, abs(frame.midY - rowY) < 20 {
                    button.click()
                    return true
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        return false
    }

    /// Clicks the rendered text span of an inline annotation (not its marker span -- a
    /// separate accessibility leaf) to open its edit popup, matching annotation-plugin.ts's
    /// NodeView click handler (`dom.addEventListener('click', ...)`, skipped only when the
    /// marker itself was clicked).
    func openAnnotationPopup(text: String, timeout: TimeInterval = 10) {
        guard let element = app.editorStaticText(startingWith: text, timeout: timeout) else {
            XCTFail("Annotation text \"\(text)\" should appear in the editor")
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Local copy of EditorModeSwitchUndoE2ETests.toggleWysiwygToSource's established pattern
    /// (retry the keystroke, since Cmd-/ can drop if the app isn't reliably foreground at the
    /// instant it's sent), simplified to this file's own fixtures (no H1-probe mount-completion
    /// gate -- a brief settle is enough here since this file doesn't depend on exact source
    /// rendering, only on the panel/DB state the mode switch doesn't touch).
    func switchToSourceMode() {
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")
        var toggled = false
        for _ in 1...5 {
            if editorMode.label == "Markdown" { toggled = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Markdown'", timeout: 2) { toggled = true; break }
        }
        XCTAssertTrue(toggled, "Editor-mode button should report Markdown after retrying the toggle keystroke")
        // The status-bar label flip (already awaited above via waitForLabel) is synchronous,
        // but the actual WYSIWYG->CodeMirror view swap runs through an async callback chain
        // that can lag behind it; nothing this file queries exposes that mount completion as a
        // waitable condition, so a brief settle stands in for it (same tradeoff
        // EditorModeSwitchUndoE2ETests.toggleWysiwygToSource documents).
        // e2e-lint: allow sleep -- see rationale above.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Local copy of UnifiedUndoE2ETests+Helpers.swift's sidebarCard(titled:).
    func sidebarCard(titled title: String, timeout: TimeInterval = 10) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        let card = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "Sidebar card titled \"\(title)\" should appear")
        return card
    }

    /// Local copy of UnifiedUndoE2ETests+Helpers.swift's rightClickSidebarCard (diagnostic
    /// capture omitted -- not needed for this file's scope).
    func rightClickSidebarCard(titled cardTitle: String, thenChooseMenuItem menuTitle: String) {
        let card = sidebarCard(titled: cardTitle)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: menuTitle).click()
        // The section-delete work this menu item triggers dispatches in a `Task { }` on the
        // Swift side, which hasn't necessarily started (let alone committed) the instant
        // `.click()` returns. This is just a hand-off buffer; the caller's own `waitUntil` on
        // the DB section count is the actual robust wait.
        // e2e-lint: allow sleep -- see rationale above.
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Polls `probe` until `predicate` is true or `timeout` elapses. Local copy of
    /// UnifiedUndoE2ETests+Helpers.swift's waitUntil -- never fails the test itself, callers
    /// assert on the returned/re-queried value so a timeout produces a specific failure message.
    @discardableResult
    func waitUntil<T>(
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.25,
        probe: () -> T, predicate: (T) -> Bool
    ) -> T {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = probe()
        while Date() < deadline {
            last = probe()
            if predicate(last) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
        return last
    }

    // MARK: - DB ground-truth queries (see UITestHelpers.swift's FixtureDatabase doc comment --
    // safe to run while the app is open, WAL mode; no forced checkpoint needed).

    func queryAnnotationCount(id: String) -> Int {
        let sql = "SELECT count(*) FROM annotation WHERE id = '\(FixtureDatabase.escape(id))';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Whether an inline (charOffset >= 0) annotation row with this exact text currently exists.
    func queryAnnotationTextExists(_ text: String) -> Bool {
        let sql = "SELECT count(*) FROM annotation WHERE charOffset >= 0 AND text = '\(FixtureDatabase.escape(text))';"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return (Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    /// Ordered text of every inline (charOffset >= 0) annotation row, by charOffset -- document
    /// order, matching the ordering getAnnotations()/deleteInlineAnnotation() use.
    func queryInlineAnnotationTexts() -> [String] {
        let sentinel = "###ROWEND###"
        let sql = "SELECT text || '\(sentinel)' FROM annotation WHERE charOffset >= 0 ORDER BY charOffset;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
    }

    func querySectionCount() -> Int {
        let sql = "SELECT count(*) FROM section WHERE isPseudoSection = 0 AND isBibliography = 0 AND isNotes = 0;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
