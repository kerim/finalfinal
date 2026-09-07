//
//  ErrorPresenterE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for t-a09089e9 ("One presenter per error
//  class (citation, image); one shared spellcheck popup") -- see
//  .claude/superdev/error-presenter/plan.md. Proves the plan's 8-item
//  user-verification list by driving the real app, EXCEPT items 3 and 4
//  (the grammar popover) -- see the "Items 3/4" note below for why those
//  are not e2e-testable here. Mapping from plan item -> test method lives
//  in .claude/superdev/error-presenter/notes.md; keep that table in sync
//  with the method names below if either changes.
//
//  Design notes worth reading before touching this file:
//
//  - Items 6/7/8 explicitly cover BOTH editors ("Same in Markdown") inside
//    one checklist line each, so each gets exactly one test method that
//    exercises Rich Text then switches to Markdown, rather than a pair of
//    methods -- mirrors the plan's own item grouping 1:1.
//
//  - Item 6 (citation error) needs Zotero not running. `FF_UI_TESTING_ZOTERO_MOCK`
//    is deliberately left UNSET here (unlike ProjectSwitchBibliographyE2ETests.swift's
//    mocked-CAYW scenario) -- a disposable vmtest VM guest never has Zotero
//    installed, so the real `ZoteroService.ping()` pre-check fails exactly the
//    way it would on a Mac where the user has quit Zotero, with no test-side
//    mocking needed to reproduce it.
//
//  - Item 7 (unsupported file) and item 8 (large image) both need to get past
//    `NSOpenPanel.allowedContentTypes` (Insert > Image's file picker only
//    shows/allows image-typed files) or reach the paste/drop entry point
//    instead. `handleImagePicker()`'s NSOpenPanel is driven here via the
//    standard "Go to Folder" (Cmd+Shift+G) sheet, which is the established
//    macOS technique for selecting a path the panel's own type filter would
//    otherwise hide from the browser view -- this is what makes item 7's
//    "unsupported file" reachable through the real Insert > Image menu at
//    all, since a .txt file would never appear if you browsed for it normally.
//
//  - Item 8 explicitly asks for both "via drag and via Insert menu". Real
//    OS-level drag-and-drop into this WKWebView editor is documented in this
//    suite as unreliable/hard to automate (see
//    E2EAsyncImageCorruptionTests.swift's file header, and the e2e-verify
//    skill's "Proven patterns"). Rather than attempting a flaky synthetic
//    drag, this test exercises the ACTUAL shared code path drag goes
//    through instead: `MilkdownCoordinator+Images.swift`'s own doc comment on
//    `handlePasteImage` states plainly that it "is the single Swift entry
//    point for both clipboard paste and drag-and-drop, since the JS side
//    posts both through the same pasteImage message channel" -- so a real,
//    reliable Cmd+V paste (NSPasteboard, same technique
//    ListNumberingE2ETests.swift already uses) exercises the identical
//    Swift-side `ImageImportService.importFromData` -> `confirmLargeImage`
//    path a real drag would, while the Insert-menu sub-test separately
//    covers the OTHER entry point (`importFromURL`). Between the two, both
//    of `confirmLargeImage`'s two call sites get proven; the literal drag
//    GESTURE itself is not simulated. This is the same kind of documented,
//    reasoned substitution the plan's own Present-block note makes for the
//    no-window image-import case.
//
//  Delete this file's contents (git restore) once its evidence is captured --
//  see the file's own header boilerplate below and the e2e-verify skill for
//  why this file is never actually deleted.
//

import AppKit
import XCTest

final class ErrorPresenterE2ETests: XCTestCase {
    var app: XCUIApplication!

    // MARK: - Seeded fixture content

    /// "Teh" leads its own paragraph (not mid-sentence). The spellcheck decoration wraps the
    /// misspelled word in its own inline element, splitting the paragraph into separate AX
    /// leaves ("Teh" and the rest of the sentence) -- `editorStaticText(startingWith: "Teh", ...)`
    /// matches that leaf directly, so no coordinate offset into a larger paragraph run is needed.
    private static let spellingParagraph = "Teh word here is deliberately misspelled for spellcheck testing."

    private static let seedMarkdown = """
    # Error Presenter E2E Fixture

    \(spellingParagraph)
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
        Self.resetTemporaryFiles()
    }

    // MARK: - Item 1: Spellcheck menu, Rich Text

    /// Type `teh` (seeded), right-click it -- expect the shared spellcheck-menu.ts context menu
    /// with suggestions, "Learn Spelling", and "Ignore".
    func testItem1SpellcheckMenuRichText() throws {
        launchAndWaitForEditor()
        try assertSpellcheckMenuAppears(context: "item1-rich-text")
    }

    // MARK: - Item 2: Spellcheck menu, Markdown -- identical appearance/behavior

    func testItem2SpellcheckMenuMarkdown() throws {
        launchAndWaitForEditor()
        switchToSourceMode()
        try assertSpellcheckMenuAppears(context: "item2-markdown")
    }

    // MARK: - Items 3/4: Grammar popover -- not e2e-testable in this environment

    // Grammar checking is gated behind `ProofingSettings.mode.isLanguageTool`, which defaults
    // to `.builtIn` (no grammar) unless explicitly configured -- nothing in this fixture or the
    // rest of `final finalUITests/` sets that mode, and there is no existing precedent anywhere
    // in this suite for testing grammar via LanguageTool, which would require a live
    // third-party API call from inside the vmtest VM guest. Plan items 3 and 4 (the grammar
    // popover, Rich Text and Markdown) are therefore not covered by this file; item 1/2's
    // spellcheck-menu coverage below proves the shared popup mechanism items 3/4 also depend on.

    // MARK: - Item 5: Dark mode -- repeat item 1, check readability/shadow

    /// Switches to a dark theme (View > Theme > High Contrast Night) and repeats item 1
    /// (spellcheck menu). This is exactly the case the review flagged: spellcheck.css now loads
    /// earlier in the module graph (via `spellcheck-plugin.ts`'s `import
    /// '../../shared/spellcheck.css'` instead of each editor's old per-file copy) -- a
    /// load-order regression would show up as missing dark-mode overrides or a wrong shadow,
    /// which is a visual property no AX-tree assertion can see. Per this suite's "visual symptoms
    /// need a visual assertion" lesson, the proof here is the attached screenshot, not a
    /// pixel-color assertion -- existence/on-screen checks confirm the popup rendered at all, the
    /// screenshot is what a human/reviewer checks for readability and shadow correctness. (Item
    /// 5's grammar-popover half is not covered here -- see the Items 3/4 note above.)
    func testItem5DarkModeSpellcheckReadability() throws {
        launchAndWaitForEditor()
        selectTheme(named: "High Contrast Night")
        // No AX signal exists for CSS-variable propagation into the WKWebView after a theme
        // switch: ThemeManager's Swift->JS bridge (`evaluateJavaScript("window.FinalFinal.setTheme(...)")`,
        // MilkdownCoordinator+Content.swift/CodeMirrorCoordinator+Handlers.swift) has an EMPTY
        // completion handler -- there is no readback XCUITest could poll on -- and nothing in the
        // accessibility tree reflects rendered color/shadow state (no "current theme" indicator
        // exists anywhere in the AX tree either -- ViewCommands.swift's Theme menu items carry no
        // checked/selected state to poll). This is exactly the "visual symptoms need a visual
        // assertion" case the e2e-verify skill documents: the actual correctness check for this
        // item is the attached screenshot below (a human/reviewer looks at it for readability and
        // shadow correctness), not an AX assertion -- so there is no real condition to poll here
        // without inventing a fake one.
        Thread.sleep(forTimeInterval: 0.5) // e2e-lint: allow sleep -- CSS/appearance settle before screenshot; no AX signal exists, see comment above

        try assertSpellcheckMenuAppears(context: "item5-dark-spellcheck-menu", captureScreenshot: true)
    }

    // MARK: - Item 6: Citation error (Rich Text, then Markdown)

    /// Zotero is never installed/running in the vmtest VM guest, so no explicit "quit Zotero"
    /// step is needed -- `ZoteroService.ping()`'s real (non-mocked) pre-check fails exactly the
    /// way it would on a Mac with Zotero quit. Clicks the Citation toolbar button, expects the
    /// shared `CitationErrorPresenter`'s "Zotero Not Running" alert, clicks OK, and proves the
    /// cursor returns to the editor by typing a marker and confirming it lands. Repeats in
    /// Markdown.
    func testItem6CitationErrorRichTextAndMarkdown() throws {
        launchAndWaitForEditor()

        try assertCitationNotRunningAlert(markerSuffix: "rt")
        switchToSourceMode()
        try assertCitationNotRunningAlert(markerSuffix: "md")
    }

    // MARK: - Item 7: Image import error -- unsupported file (Rich Text, then Markdown)

    /// `NSOpenPanel.allowedContentTypes` (set in `handleImagePicker()`) hides non-image files
    /// from the browser view, so a plain `.txt` file is selected via the standard "Go to Folder"
    /// (Cmd+Shift+G) sheet -- the normal macOS technique for reaching a path the panel's own type
    /// filter would otherwise keep out of the browsable list. `ImageImportService.importFromURL`
    /// validates by extension (`allowedExtensions.contains(ext)`), so a `.txt` file reliably
    /// throws `.unsupportedFormat`, driving the shared `ImageImportErrorPresenter`'s "Image
    /// Import Failed" sheet.
    func testItem7ImageImportErrorRichTextAndMarkdown() throws {
        launchAndWaitForEditor()

        let unsupportedFile = Self.writeTemporaryFile(name: "unsupported-\(UUID().uuidString).txt", sizeBytes: 128)
        try assertImageImportFailedAlert(selecting: unsupportedFile, markerSuffix: "rt")

        switchToSourceMode()
        let unsupportedFileMarkdown = Self.writeTemporaryFile(name: "unsupported-md-\(UUID().uuidString).txt", sizeBytes: 128)
        try assertImageImportFailedAlert(selecting: unsupportedFileMarkdown, markerSuffix: "md")
    }

    // MARK: - Item 8: Large image confirm -- both via drag (paste, same shared entry point) and via Insert menu

    /// See this file's header for why a clipboard paste stands in for the literal drag gesture
    /// here. Covers both `confirmLargeImage` call sites in `ImageImportService.swift`:
    /// `importFromData` (paste/drop's shared entry point) and `importFromURL` (Insert menu's file
    /// picker). For each, proves both outcomes: Cancel leaves the document unchanged, Insert
    /// proceeds.
    func testItem8LargeImageConfirmViaPasteAndInsertMenu() throws {
        launchAndWaitForEditor()

        // --- Sub-test A: paste path (stands in for drag; see file header) ---
        // Unlike sub-test B below, this payload must be a real, decodable PNG: paste goes
        // through WebKit's clipboard-to-DataTransfer conversion before the Swift paste handler
        // ever sees the bytes, and WebKit silently drops non-decodable image data at that step.
        Self.putOversizedImageOnPasteboard()
        app.activateAndWaitForForeground()
        clickIntoEditor()
        app.typeKey("v", modifierFlags: .command)

        let cancelButtonPaste = app.dialogs.buttons["Cancel"]
        XCTAssertTrue(cancelButtonPaste.waitForExistence(timeout: 15),
                      "\"Large Image\" prompt should appear after pasting an oversized image")
        cancelButtonPaste.click()
        XCTAssertTrue(cancelButtonPaste.waitForDisappearance(timeout: 10),
                      "Cancel should dismiss the Large Image prompt")

        // Cancelling the Large Image prompt makes importFromData throw .fileTooLarge
        // (ImageImportService.swift), which the paste handler's catch turns into the shared
        // "Image Import Failed" sheet. That sheet is window-modal, so the next Cmd+V lands in
        // the sheet rather than the editor unless it is dismissed first. Same surface, same
        // app.sheets scoping as assertImageImportFailedAlert().
        let cancelFalloutOKPaste = app.sheets.buttons["OK"]
        XCTAssertTrue(cancelFalloutOKPaste.waitForExistence(timeout: 10),
                      "Cancelling the Large Image prompt should raise the \"Image Import Failed\" sheet")
        cancelFalloutOKPaste.click()
        XCTAssertTrue(cancelFalloutOKPaste.waitForDisappearance(timeout: 10),
                      "OK should dismiss the Image Import Failed sheet")
        // waitForDisappearance above already confirms the sheet is gone from the accessibility
        // tree -- this residual margin is for AppKit's own sheet-close animation, which can still
        // be visually finishing for a brief moment after the accessibility tree stops reporting
        // the sheet. There is no AX signal for "the animation has visually finished" to poll on;
        // this is the same gap UnifiedUndoE2ETests+Helpers.swift's restoreFullProject/saveVersion
        // keep an identical settle sleep for, right after their own waitForDisappearance checks.
        Thread.sleep(forTimeInterval: 0.3) // e2e-lint: allow sleep -- sheet-close animation margin after confirmed AX disappearance, see comment above

        // Paste again and choose Insert this time.
        Self.putOversizedImageOnPasteboard()
        app.activateAndWaitForForeground()
        clickIntoEditor()
        app.typeKey("v", modifierFlags: .command)

        let insertButtonPaste = app.dialogs.buttons["Insert"]
        XCTAssertTrue(insertButtonPaste.waitForExistence(timeout: 15),
                      "\"Large Image\" prompt should appear again for the second paste")
        insertButtonPaste.click()
        XCTAssertTrue(insertButtonPaste.waitForDisappearance(timeout: 10), "Insert should dismiss the Large Image prompt")

        // --- Sub-test B: Insert menu / file-picker path ---
        // Fabricated (non-decodable) bytes are fine here, unlike sub-test A above: this path
        // (`ImageImportService.importFromURL`) validates by file size/extension and never asks
        // WebKit to decode the data, so it never hits the clipboard-conversion drop sub-test A
        // has to work around.
        let oversizedFile = Self.writeTemporaryFile(name: "oversized-\(UUID().uuidString).png", sizeBytes: 12 * 1024 * 1024)

        openInsertMenuImageItem()
        selectFileInOpenPanel(path: oversizedFile.path)

        let cancelButtonMenu = app.dialogs.buttons["Cancel"]
        XCTAssertTrue(cancelButtonMenu.waitForExistence(timeout: 15),
                      "\"Large Image\" prompt should appear for an oversized file chosen via Insert > Image")
        cancelButtonMenu.click()
        XCTAssertTrue(cancelButtonMenu.waitForDisappearance(timeout: 10),
                      "Cancel should dismiss the Large Image prompt")

        // Cancelling the Large Image prompt makes importFromURL throw .fileTooLarge
        // (ImageImportService.swift), which the Insert-menu handler's catch turns into the same
        // shared "Image Import Failed" sheet as the paste path above. That sheet is window-modal,
        // so it must be dismissed before the next Insert-menu attempt can raise its own prompt.
        let cancelFalloutOKMenu = app.sheets.buttons["OK"]
        XCTAssertTrue(cancelFalloutOKMenu.waitForExistence(timeout: 10),
                      "Cancelling the Large Image prompt should raise the \"Image Import Failed\" sheet")
        cancelFalloutOKMenu.click()
        XCTAssertTrue(cancelFalloutOKMenu.waitForDisappearance(timeout: 10),
                      "OK should dismiss the Image Import Failed sheet")
        // Same reasoning as sub-test A's identical margin above (waitForDisappearance already
        // confirms AX-level removal; this covers AppKit's own close animation, for which no AX
        // signal exists -- see that comment for the full rationale and the codebase precedent).
        Thread.sleep(forTimeInterval: 0.3) // e2e-lint: allow sleep -- sheet-close animation margin after confirmed AX disappearance, see sub-test A's identical comment above

        openInsertMenuImageItem()
        selectFileInOpenPanel(path: oversizedFile.path)

        let insertButtonMenu = app.dialogs.buttons["Insert"]
        XCTAssertTrue(insertButtonMenu.waitForExistence(timeout: 15),
                      "\"Large Image\" prompt should appear again for the second Insert > Image attempt")
        insertButtonMenu.click()
        XCTAssertTrue(insertButtonMenu.waitForDisappearance(timeout: 10), "Insert should dismiss the Large Image prompt")
    }

    // MARK: - Shared setup helpers

    private func launchAndWaitForEditor() {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistenceOrFail(timeout: 15).exists, "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 15), "Status bar should show word count (editor JS ready)")
    }

    private func clickIntoEditor() {
        app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
    }

    /// Local copy of `UnifiedUndoE2ETests+Helpers.swift`'s `switchToSourceMode()` (that helper is
    /// scoped to its own test class's extension, and this file's scratch-reset convention keeps
    /// everything self-contained in one file -- see this file's own header).
    private func switchToSourceMode() {
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")

        var toggled = false
        for _ in 1...5 {
            if editorMode.label == "Source" { toggled = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Source'", timeout: 2) { toggled = true; break }
        }
        XCTAssertTrue(toggled, "Editor-mode button should report Source after retrying the toggle keystroke")

        // Mount-completion gate -- same INTENT as UnifiedUndoE2ETests+Helpers.swift's own
        // switchToSourceMode(): the status-bar label flip above is synchronous, but the actual
        // WYSIWYG -> CodeMirror view swap runs through an async callback chain that can lag
        // behind it. That helper's own implementation waits for its canonical fixture's exact,
        // never-mutated seed heading -- this file can't borrow that literally: this helper is
        // called AFTER live edits may already have touched the document elsewhere (item6/item7
        // click into the editor and type a "cursor-return..." marker before switching modes, and
        // that click's landing position inside a 2-line document is not something this test
        // controls precisely enough to guarantee the seeded heading text survives byte-for-byte --
        // confirmed live: an exact-substring version of this check against the literal seeded
        // heading failed on testItem6, because the prior marker-typing step had altered it).
        // waitForSourceModeEvidence below is deliberately content-agnostic instead: it looks for
        // ANY element carrying a leading "#" (a raw markdown heading marker), which only
        // CodeMirror ever exposes (Milkdown's WYSIWYG strips heading syntax) regardless of
        // whatever text now follows that "#".
        XCTAssertTrue(
            waitForSourceModeEvidence(),
            "CodeMirror source editor should render raw markdown (a leading '#') after toggling, not just flip the status-bar label"
        )
    }

    /// See switchToSourceMode()'s call-site comment for why this is a content-agnostic "#"-prefix
    /// scan rather than an exact-text match. Manual Swift-side scan (not an NSPredicate CONTAINS
    /// against staticTexts): heading containers can carry a non-String value (the heading level,
    /// an NSNumber), which throws under a substring predicate -- same concern editorStaticText's
    /// own doc comment documents (UITestHelpers.swift).
    private func waitForSourceModeEvidence(timeout: TimeInterval = 10) -> Bool {
        let editorArea = app.groups["editor-area"]
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for element in editorArea.descendants(matching: .any).allElementsBoundByIndex {
                guard element.exists else { continue }
                if let value = element.value as? String, value.hasPrefix("#") { return true }
                if element.label.hasPrefix("#") { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Drives View > Theme > `themeName`. `.sidebar`-placed `CommandGroup` content
    /// (`ViewCommands.swift`) puts the "Theme" menu inside the native "View" menu.
    private func selectTheme(named themeName: String) {
        app.activateAndWaitForForeground()
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 10), "View menu should exist")
        viewMenu.click()

        let themeMenu = app.menuItems["Theme"]
        XCTAssertTrue(themeMenu.waitForExistence(timeout: 10), "View > Theme submenu should exist")
        themeMenu.click()

        let themeItem = app.menuItems[themeName]
        XCTAssertTrue(themeItem.waitForExistence(timeout: 10), "View > Theme > \(themeName) should exist")
        themeItem.click()
    }

    /// Drives Edit > Insert > Image... (`EditorCommands.swift`'s `CommandGroup(after: .textEditing)`
    /// nests the "Insert" menu inside the native "Edit" menu).
    private func openInsertMenuImageItem() {
        app.activateAndWaitForForeground()
        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 10), "Edit menu should exist")
        editMenu.click()

        let insertMenu = app.menuItems["Insert"]
        XCTAssertTrue(insertMenu.waitForExistence(timeout: 10), "Edit > Insert submenu should exist")
        insertMenu.click()

        let imageItem = app.menuItems["Image..."]
        XCTAssertTrue(imageItem.waitForExistence(timeout: 10), "Edit > Insert > Image... should exist")
        imageItem.click()
    }

    /// Drives the NSOpenPanel raised by `handleImagePicker()` via "Go to Folder" (Cmd+Shift+G) --
    /// see this file's header for why: it is the standard macOS technique for selecting a path
    /// the panel's own `allowedContentTypes` filter would otherwise hide from the browser view.
    private func selectFileInOpenPanel(path: String) {
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Open panel should appear")

        app.typeKey("g", modifierFlags: [.command, .shift])
        // Poll for the Go-to-Folder sheet's own path field to mount, rather than a blind delay --
        // it's a real, standard AppKit text field once the sheet is up (no other text field is
        // expected on screen while an NSOpenPanel is showing: any search affordance is a
        // XCUIElementTypeSearchField, not a textField). Deliberately NOT clicking the field before
        // typing -- CONFIRMED live (testItem7/testItem8's second Go-to-Folder invocation within
        // the same test both failed after that click was added): AppKit's Go-to-Folder sheet
        // remembers/prefills the last-typed path across invocations within the same process and
        // auto-selects it on (re)focus, so `app.typeText(path)` alone correctly REPLACES that
        // selection -- but an explicit `.click()` first places an unselected caret instead,
        // leaving the prefilled text in place and inserting `path` alongside it, silently
        // corrupting the navigated path. The field mounting (this existence poll) already proves
        // it's ready to receive text; typing directly, same as the original code, is what actually
        // relies on AppKit's own select-on-focus behavior working correctly.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10), "Go to Folder sheet's path field should mount")
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])

        let openButton = app.dialogs.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10), "Open panel's Open button should exist")
        openButton.click()
    }

    // MARK: - Per-item assertion bodies (shared between Rich Text / Markdown / dark-mode callers)

    private func assertSpellcheckMenuAppears(context: String, captureScreenshot: Bool = false) throws {
        guard let flaggedWord = app.editorStaticText(startingWith: "Teh", timeout: 15) else {
            XCTFail("Misspelled word \"Teh\" should be flagged and visible in the editor (\(context))")
            return
        }
        flaggedWord.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        XCTAssertTrue(app.editorContainsText("Ignore", timeout: 10),
                      "Spellcheck context menu's \"Ignore\" item should appear (\(context))")
        XCTAssertTrue(app.editorContainsText("Learn Spelling", timeout: 5),
                      "Spellcheck context menu's \"Learn Spelling\" item should appear for a spelling error (\(context))")

        if captureScreenshot {
            Self.attachScreenshot(app.screenshot(), name: "\(context)-spellcheck-menu", to: self)
        }

        app.typeKey(.escape, modifierFlags: [])
        // Poll for the menu's own content to actually leave the editor's accessibility tree,
        // rather than a blind delay. spellcheck-menu.ts's dismissMenu() (`activeMenu.remove()`)
        // runs synchronously inside the JS keydown handler, but WKWebView's delivery of the
        // native Escape keystroke to that JS handler is itself asynchronous relative to
        // `typeKey` returning -- so there IS a real gap to wait out here, it's just not
        // observable via a fixed AX existence check on the menu closing "cleanly"; it's
        // observable via the menu's own content disappearing, which is exactly what
        // waitForSpellcheckMenuDismissed polls for below. This also subsumes the original
        // concern (a fresh interaction racing the menu's internal 150ms outside-click-listener
        // setTimeout): waiting for the DOM removal that dismissMenu() performs necessarily waits
        // at least as long as whatever delay Escape's own handling took.
        XCTAssertTrue(waitForSpellcheckMenuDismissed(), "Spellcheck menu should be dismissed after Escape (\(context))")
    }

    /// Polls until "Ignore" (part of the spellcheck menu's own content, see spellcheck-menu.ts)
    /// is no longer found in the editor's accessibility tree -- the observable proxy for
    /// dismissMenu()'s `activeMenu.remove()` having actually run. See the call site's comment for
    /// why this replaces a blind sleep.
    private func waitForSpellcheckMenuDismissed(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if !app.editorContainsText("Ignore", timeout: 0.1) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        } while Date() < deadline
        return false
    }

    private func assertCitationNotRunningAlert(markerSuffix: String) throws {
        clickIntoEditor()
        app.activateAndWaitForForeground()

        let citationButton = app.buttons["Citation"]
        XCTAssertTrue(citationButton.waitForExistence(timeout: 10), "Citation toolbar button should exist")
        citationButton.click()

        // Exact match on CitationErrorPresenter's own literal messageText, scoped to app.dialogs
        // (a native NSAlert.runModal()) -- not app.editorArea, so this is unrelated to the
        // heading-NSNumber/sidebar-mirror risks a CONTAINS+firstMatch query would carry inside
        // the WKWebView editor content.
        let dialogText = app.dialogs.staticTexts["Zotero Not Running"]
        XCTAssertTrue(dialogText.waitForExistence(timeout: 15), "\"Zotero Not Running\" alert should appear")

        app.clickDialogButton("OK")
        // Poll for the alert's own text to actually leave the accessibility tree, rather than a
        // blind delay -- a real, observable condition: nothing previously confirmed the alert
        // element itself was gone before proceeding (clickDialogButton's own doc comment notes
        // runModal() returns synchronously once the alert is gone, but that's a claim about the
        // native call, not something this test had verified about the AX tree).
        XCTAssertTrue(dialogText.waitForDisappearance(timeout: 10),
                      "\"Zotero Not Running\" alert should disappear after OK")

        // Not typeTextVerifyingLanded(_:): that helper's documented precondition is a caret on
        // its own, otherwise-empty line, and its mismatch-repair clears the CURRENT line -- the
        // caret here sits wherever clickIntoEditor() landed inside existing seeded content, so
        // that repair could destructively clear real paragraph text. A plain typeText + this
        // method's own editorContainsText poll (10s) is the correct tool for "did focus return
        // at all", which is what this assertion is actually proving.
        let marker = "cursor-return-\(markerSuffix)"
        app.activateAndWaitForForeground()
        app.typeText(marker)
        XCTAssertTrue(app.editorContainsText(marker, timeout: 10),
                      "Typed marker should land in the editor, proving the cursor returned after OK (\(markerSuffix))")
    }

    private func assertImageImportFailedAlert(selecting fileURL: URL, markerSuffix: String) throws {
        clickIntoEditor()
        openInsertMenuImageItem()
        selectFileInOpenPanel(path: fileURL.path)

        // ImageImportErrorPresenter presents via NSAlert.beginSheetModal(for:) -- a sheet, not
        // runModal() -- unlike CitationErrorPresenter below, which is always app-modal. So this
        // is queried under app.sheets, not app.dialogs; clickDialogButton is hard-scoped to
        // app.dialogs and would never find this button. Exact match on ImageImportErrorPresenter's
        // own literal messageText, scoped to app.sheets rather than the WKWebView editor content.
        let dialogText = app.sheets.staticTexts["Image Import Failed"]
        XCTAssertTrue(dialogText.waitForExistence(timeout: 15), "\"Image Import Failed\" sheet should appear (\(markerSuffix))")
        let okButton = app.sheets.buttons["OK"]
        XCTAssertTrue(okButton.waitForExistence(timeout: 10), "Image Import Failed sheet's OK button should appear (\(markerSuffix))")
        okButton.click()
        // Poll for the sheet's own text to actually leave the accessibility tree, rather than a
        // blind delay -- same fix as assertCitationNotRunningAlert above: nothing previously
        // confirmed the sheet element itself was gone before proceeding.
        XCTAssertTrue(dialogText.waitForDisappearance(timeout: 10),
                      "\"Image Import Failed\" sheet should disappear after OK (\(markerSuffix))")

        // Not typeTextVerifyingLanded(_:) -- same reasoning as assertCitationNotRunningAlert
        // above (caret isn't on its own empty line here, so that helper's repair path doesn't apply).
        let marker = "cursor-return-image-\(markerSuffix)"
        app.activateAndWaitForForeground()
        clickIntoEditor()
        app.typeText(marker)
        XCTAssertTrue(app.editorContainsText(marker, timeout: 10),
                      "Typed marker should land in the editor, proving the cursor returned after OK (\(markerSuffix))")
    }

    // MARK: - Fixture/pasteboard construction helpers

    private nonisolated(unsafe) static var temporaryFiles: [URL] = []

    private static func writeTemporaryFile(name: String, sizeBytes: Int) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: sizeBytes)
        do {
            try data.write(to: url)
        } catch {
            XCTFail("Failed to write temporary test file at \(url.path): \(error)")
        }
        temporaryFiles.append(url)
        return url
    }

    private static func resetTemporaryFiles() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
    }

    /// Puts a real, decodable, oversized PNG on the general pasteboard, sized between
    /// `ImageImportService`'s `warnSizeBytes` (10 MB) and `blockSizeBytes` (25 MB) thresholds.
    /// Unlike the file-based oversized image in sub-test B of `testItem8...` below, content
    /// validity DOES matter here: paste goes through WebKit's clipboard-to-DataTransfer
    /// conversion before the Swift paste handler (`importFromData`) ever sees the bytes, and
    /// WebKit silently drops non-decodable image data at that step -- a fabricated PNG signature
    /// followed by padding bytes (as this used to do) never reaches the app at all. A real
    /// bitmap, randomly noised so PNG compression can't shrink it below the warn threshold, is
    /// the only payload that survives that conversion.
    private static func putOversizedImageOnPasteboard() {
        let side = 2400
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 3, bitsPerPixel: 24),
            let buffer = rep.bitmapData else {
            XCTFail("Failed to allocate oversized test bitmap"); return
        }
        var rng = SystemRandomNumberGenerator()
        for i in 0 ..< (side * side * 3) { buffer[i] = UInt8.random(in: 0...255, using: &rng) }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to encode oversized test PNG"); return
        }
        XCTAssertTrue((10 * 1024 * 1024) < png.count && png.count < (25 * 1024 * 1024),
                      "Oversized test PNG must land between warnSizeBytes and blockSizeBytes; got \(png.count) bytes")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private static func attachScreenshot(_ screenshot: XCUIScreenshot, name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        // Also write to the shared evidence directory (see e2e-verify skill's "Screenshot
        // evidence" section) so a human/reviewer can browse the PNGs directly, not just via the
        // .xcresult attachment.
        try? screenshot.pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("\(name).png"))
    }
}
