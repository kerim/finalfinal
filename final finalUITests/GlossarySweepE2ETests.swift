//
//  GlossarySweepE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for t-cacd00fa (glossary sweep: one word
//  per concept). The task's implementation already updated 7 EXISTING UI test
//  files' label assertions (WYSIWYG -> Rich Text, Source -> Markdown), so
//  those already prove the editor-mode badge/menu wording (plan's
//  user-verification items 1 and 4) once run in the VM. This scratch class
//  covers what those don't: items 6, 8, and 9 (Version History wording, the
//  Version History empty state, Preferences wording, and the sidebar
//  citation-count badge). Item 5 (slash-menu wording parity) is deliberately
//  NOT driven via XCUITest here -- see
//  testSlashMenuWordingIsCoveredAtTheJSLayerNotHere's doc comment. Items 2, 3,
//  and 7 (tooltip text, badge pixel width, single-section restore) are also
//  out of scope for this file -- see the run notes mapping table for why.
//
//  Delete this file's contents once its evidence has been captured -- it is
//  disposable verification scaffolding, not a permanent regression test. See
//  the committed placeholder's own header for the reset procedure
//  (`git restore -- "final finalUITests/GlossarySweepE2ETests.swift"`).
//
//  Renamed from E2EScratchTests.swift (this worktree's local copy only): the
//  shared class name `E2EScratchTests` was colliding across worktrees in
//  vmtest's scope-keyed retry-refusal tracking, parking this worktree's
//  unrelated tests behind another worktree's stuck test.
//

import XCTest

final class GlossarySweepE2ETests: XCTestCase {
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

    // MARK: - Plan item 8: Version History empty state (no versions saved yet)

    /// The committed fixture ships zero `snapshot` rows (confirmed directly:
    /// `sqlite3 .../test-fixture.ff/content.sqlite "SELECT COUNT(*) FROM snapshot;"` -> 0), so
    /// the empty state is reachable with no seeding.
    func testVersionHistoryEmptyStateWording() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Version History window should appear")

        let headline = window.staticTexts["No Version History"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10), "Empty state headline should read 'No Version History'")

        let body = window.staticTexts[
            "Version history will appear here when you save versions or when versions are saved automatically."
        ]
        XCTAssertTrue(body.waitForExistence(timeout: 5), "Empty state body should use the post-glossary-sweep wording")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "version-history-empty-state"
        attachment.lifetime = .keepAlways
        add(attachment)

        assertNoRetiredVersionWords(in: window)
    }

    // MARK: - Plan item 6: "Selected Version" pane title + full-restore confirmation wording

    func testVersionHistorySelectedVersionAndRestoreConfirmationWording() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        saveVersion(named: "Glossary Sweep Check")

        app.typeKey("v", modifierFlags: [.command, .option])
        let window = app.windows["version-history"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Version History window should appear")

        // Matches both label AND value -- same defensive pattern
        // `UnifiedUndoE2ETests+Helpers.swift`'s `restoreFullProject` uses for the identical
        // snapshot-row lookup. Scoped to the `version-history` window's own staticTexts, not
        // `editorArea` -- the lint's "three StaticTexts per editor heading" concern doesn't
        // apply to this native SwiftUI window at all.
        // e2e-lint: allow statictext-firstmatch -- not editor content, see comment above.
        let snapshotRow = window.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "Glossary Sweep Check", "Glossary Sweep Check")
        ).firstMatch
        XCTAssertTrue(snapshotRow.waitForExistence(timeout: 10), "Named version should appear in the version list")
        snapshotRow.click()

        // Same rationale as snapshotRow above: this is the native Version History window's own
        // DocumentPreviewView title, not editor content.
        // e2e-lint: allow statictext-firstmatch -- not editor content, see comment above.
        let selectedVersionTitle = window.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", "Selected Version", "Selected Version")
        ).firstMatch
        XCTAssertTrue(selectedVersionTitle.waitForExistence(timeout: 10), "Compare pane should be titled 'Selected Version', not 'Selected Backup'")

        let restoreAllButton = window.buttons["Restore All"]
        XCTAssertTrue(restoreAllButton.waitForExistence(timeout: 10), "'Restore All' button should appear once a version is selected")
        restoreAllButton.click()

        let confirmationSurface = waitForAlertSurface()
        XCTAssertTrue(confirmationSurface.exists, "Restore Entire Project confirmation should appear")

        // AppKit renders the whole confirmationDialog `message:` as ONE StaticText (the
        // informativeText) -- two separate exact-label lookups (as this test used to do) can't
        // both resolve against a single combined element. Walk every StaticText instead and look
        // for one whose text contains both sentences as substrings. Same defensive shape as
        // `assertNoRetiredVersionWords` below: read `.label` directly (always a safe String) and
        // `.value as? String` (never an NSPredicate CONTAINS, which can crash on a non-string
        // value).
        XCTAssertTrue(
            waitForCombinedMessage(
                in: confirmationSurface,
                containing: [
                    "replace all current content with the selected version",
                    "A version is saved automatically before restoring"
                ]
            ),
            "Confirmation should combine both sentences into one message: what happens, and that a version is saved automatically"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "version-history-restore-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Cancel -- this test only proves wording, it never actually restores.
        let cancelButton = confirmationSurface.buttons["version-history-full-restore-cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Cancel button should be present")
        cancelButton.click()

        assertNoRetiredVersionWords(in: window)
    }

    // MARK: - Plan item 9: Preferences wording

    /// A tab button in the Settings window's tab bar. Settings tab buttons come from `TabView`'s
    /// `.tabItem { Label(...) }` (PreferencesView.swift) and expose their text as the AX *title*,
    /// never a label -- confirmed in the failure-time hierarchy dump -- so this matches either.
    /// Title matching is this suite's established pattern for AppKit-backed elements
    /// (UnifiedUndoE2ETests.swift:641). Used for every tab lookup in this file, so the predicate
    /// is written once.
    private func settingsTabButton(_ name: String, in settingsWindow: XCUIElement) -> XCUIElement {
        settingsWindow.toolbars.buttons
            .matching(NSPredicate(format: "title == %@ OR label == %@", name, name))
            .firstMatch
    }

    /// "Heading Color" (Appearance pane), "Use custom export template" toggle + "Select Export
    /// Template" open-panel title (Export pane).
    func testPreferencesWording() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        app.typeKey(",", modifierFlags: .command)
        // Queried by the Settings scene's stable identifier, never its title -- the title is
        // whichever pane tab is currently selected (e.g. "Export" by default), which looks like
        // "the window never opened" if you query by title instead. e2e-verify skill lesson,
        // settings-destructive-confirm branch diagnosis.
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window should appear")

        // Settings opens on Export (`PreferencesTabRouter.defaultTab`). The click is kept anyway: harmless,
        // and it keeps this test independent of which tab is the default.
        let exportTab = settingsTabButton("Export", in: settingsWindow)
        XCTAssertTrue(exportTab.waitForExistence(timeout: 10), "Settings window should have an Export tab")
        exportTab.click()

        let exportTemplateToggle = settingsWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Use custom export template"))
            .firstMatch
        XCTAssertTrue(
            exportTemplateToggle.waitForExistence(timeout: 10),
            "'Use custom export template' toggle should be present on the Export pane, not 'Use custom reference document'"
        )

        // Turn the toggle on only if it isn't already, driven by the toggle's own boolean state --
        // NOT by whether a "Browse..." button exists. There are 4 "Browse..." buttons on this
        // pane (Pandoc's is always visible); the first one in view-hierarchy order used to be
        // Pandoc's, not this row's, so an existence check on the ambiguous label always saw a
        // match and the toggle was never actually clicked.
        if (exportTemplateToggle.value as? String) != "1" {
            exportTemplateToggle.click()
        }

        // Looked up by its own accessibility identifier (`ExportPreferencesPane.swift`'s
        // `referenceDocRow`) rather than the ambiguous "Browse..." label, which also matches
        // Pandoc's always-visible Browse button.
        let browseButton = settingsWindow.buttons["export-template-browse"]
        XCTAssertTrue(browseButton.waitForExistence(timeout: 10), "Export-template 'Browse...' button should appear once the toggle is on")
        browseButton.click()

        // NSOpenPanel presented via `runModal()` (`browseForReferenceDoc()`) has no established
        // precedent in this suite for which AX type/title it surfaces as, and the run that found
        // this bug recorded no titlebar rendering on macOS 15 -- so capture the panel's title and
        // a full debug-description dump as an attachment BEFORE asserting anything. That way, if
        // the title assertion below is wrong about how this panel exposes itself, the next run's
        // evidence settles it rather than guessing again.
        let panelSurface = app.dialogs.firstMatch
        XCTAssertTrue(panelSurface.waitForExistence(timeout: 10), "An open panel should appear for the export-template Browse button")
        let panelTitle = panelSurface.title

        let panelDebugAttachment = XCTAttachment(string: "panelSurface.title: \"\(panelTitle)\"\n\n\(panelSurface.debugDescription)")
        panelDebugAttachment.name = "export-template-open-panel-debug"
        panelDebugAttachment.lifetime = .keepAlways
        add(panelDebugAttachment)

        app.typeKey(.escape, modifierFlags: []) // dismiss the panel without picking a file

        XCTAssertEqual(
            panelTitle,
            "Select Export Template",
            "The open panel should be titled 'Select Export Template', not 'Select Reference Document'"
        )

        let appearanceTab = settingsTabButton("Appearance", in: settingsWindow)
        XCTAssertTrue(appearanceTab.waitForExistence(timeout: 10), "Appearance tab should be selectable")
        appearanceTab.click()

        // `settingRow(label:)` (PreferencesView.swift:355-382) renders a plain `Text(label)`,
        // which may not expose a `label` attribute on its AX StaticText (only a `value`) --
        // same OR-form pattern this file already uses for the sidebar bibliography card
        // (see `testSidebarCitationBadgeReadsCitationsNotRefs` below, ~line 264).
        let headingColorLabel = settingsWindow.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Heading Color", "Heading Color"))
            .firstMatch
        XCTAssertTrue(headingColorLabel.waitForExistence(timeout: 10), "Appearance pane should show a 'Heading Color' label, not 'Header Color'")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "preferences-wording"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Plan item 9: sidebar citation-count badge ("N citations", not "N refs")

    /// The committed fixture ships no Bibliography section (confirmed directly: `SELECT * FROM
    /// block WHERE isBibliography=1` against the fixture -> empty), so this seeds one raw
    /// `block` row directly -- exactly the shape `SectionCardView.bibliographyMetadataRow`/
    /// `estimateCitationCount()` reads: `SectionViewModel(from: block)` takes `markdownContent`
    /// straight from that one block's own `markdownFragment`, never aggregated with any other
    /// row (confirmed by reading `SectionCardView.swift`'s `init(from block:)`). This is a
    /// deliberate shortcut around the real citation-insert -> `BibliographySyncService`
    /// pipeline: that service stores each bibliography entry as its own SEPARATE block
    /// (`BibliographySyncService.swift`), so the heading block's own fragment there is always
    /// single-line ("# Bibliography") and would never itself trip `estimateCitationCount`'s
    /// blank-line-separated-entries count. What's under test here is only the WORDING of the
    /// badge, not how a real bibliography section gets built.
    func testSidebarCitationBadgeReadsCitationsNotRefs() throws {
        let projectId = queryFixtureProjectId()
        let bibliographyMarkdown = """
            # Bibliography

            Author One (2020). First citation entry with enough text to read as a real entry.

            Author Two (2021). Second citation entry with enough text to read as a real entry.

            Author Three (2022). Third citation entry with enough text to read as a real entry.
            """
        let escapedMarkdown = FixtureDatabase.escape(bibliographyMarkdown)
        FixtureDatabase.write(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: """
                INSERT INTO block
                    (id, projectId, sortOrder, blockType, textContent, markdownFragment, headingLevel, isBibliography)
                VALUES
                    ('E2E-SCRATCH-BIBLIOGRAPHY-0001', '\(projectId)', 999.0, 'heading', 'Bibliography', '\(escapedMarkdown)', 1, 1);
                """
        )

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()

        // Scoped to the sidebar's ScrollView, not the whole `outline-sidebar` group -- proven
        // pattern (`UnifiedUndoE2ETests+Helpers.swift`'s `sidebarCard(titled:)`), guards against
        // an unrelated same-text element (e.g. a zoom breadcrumb) matching first.
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        let bibliographyCard = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Bibliography", "Bibliography"))
            .firstMatch
        XCTAssertTrue(bibliographyCard.waitForExistence(timeout: 10), "Bibliography section card should appear in the outline sidebar")

        let citationBadge = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "3 citations", "3 citations"))
            .firstMatch
        XCTAssertTrue(
            citationBadge.waitForExistence(timeout: 10),
            "Citation count badge should read '3 citations' (plural, post-glossary-sweep wording)"
        )

        let refsBadge = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "3 refs", "3 refs"))
            .firstMatch
        XCTAssertFalse(refsBadge.exists, "Citation badge should never read the retired '3 refs' wording")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sidebar-citation-badge"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Plan item 5: slash-menu wording -- deliberately NOT covered here

    /// `/break`, `/cite`, `/image` description-string parity between Milkdown and CodeMirror is
    /// already proven at the JS layer by `web/milkdown/src/__tests__/slash-command-parity.test.ts`
    /// (added by this same task), which asserts the exported `slashCommands` arrays from both
    /// editors match on every shared label -- including these three.
    ///
    /// There is no established way to drive either editor's slash-command menu via XCUITest in
    /// this suite: `E2ESectionReconcilerPseudoSectionTests.swift`'s file header documents this
    /// directly ("there is no precedent anywhere in this suite for driving Milkdown's `/break`
    /// slash-command menu via XCUITest, and getting the exact keystroke-to-menu-selection
    /// sequence wrong would silently produce a document that doesn't reproduce the [intended]
    /// scenario at all"). Given that precedent, and that the JS test already proves the exact
    /// wording claim, no XCUITest coverage is added here. Kept as a named, empty test (rather
    /// than only a comment) so the decision to skip UI-level coverage is visible in test
    /// output/reports, not just in source -- see the run notes mapping table for the same call
    /// spelled out for a human reader.
    func testSlashMenuWordingIsCoveredAtTheJSLayerNotHere() throws {
        // Intentionally empty -- see the doc comment above.
    }

    // MARK: - Helpers

    private func waitForEditorReady() {
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
    }

    /// Cmd-Shift-S -> "Save Version..." -> types `name` into the alert's text field -> Save.
    /// Local copy of `UnifiedUndoE2ETests+Helpers.swift`'s `saveVersion(named:)` -- that
    /// extension is scoped to `UnifiedUndoE2ETests`, not reusable from this class.
    private func saveVersion(named name: String) {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = waitForAlertSurface()
        XCTAssertTrue(alert.exists, "Save Version alert should appear")
        let nameField = alert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Save Version alert should have a name field")
        nameField.click()
        nameField.typeText(name)
        let saveButton = alert.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "\"Save\" button should appear in the Save Version alert")
        saveButton.click()
        // Copied verbatim from the proven `saveVersion(named:)` in
        // UnifiedUndoE2ETests+Helpers.swift, which uses the identical fixed wait for the alert's
        // dismiss animation and the version write to settle before the caller opens Version
        // History; no observable AX signal distinguishes "write landed" from "alert still
        // dismissing" here.
        // e2e-lint: allow sleep -- see comment above.
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// SwiftUI `.alert()`/`.confirmationDialog()` render as `XCUIElementTypeSheet` in this app --
    /// confirmed live, see `UnifiedUndoE2ETests+Helpers.swift`'s own copy of this exact helper.
    /// Checks `.sheets` first, falls back to `.dialogs`.
    private func waitForAlertSurface(timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let sheet = app.sheets.firstMatch
            if sheet.exists { return sheet }
            let dialog = app.dialogs.firstMatch
            if dialog.exists { return dialog }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// Reads each StaticText's label/value directly in Swift (never via an NSPredicate CONTAINS
    /// -- a heading container's `value` can be a non-string NSNumber and throws on that
    /// operator, e2e-verify skill lesson) and fails if any retired Version-wording word
    /// ("backup", "snapshot") appears anywhere in the given window.
    private func assertNoRetiredVersionWords(in window: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let retiredWords = ["backup", "snapshot"]
        for element in window.staticTexts.allElementsBoundByIndex {
            guard element.exists else { continue }
            let label = element.label.lowercased()
            for word in retiredWords {
                XCTAssertFalse(
                    label.contains(word),
                    "Version History window should never say \"\(word)\" -- found in label \"\(element.label)\"",
                    file: file, line: line
                )
            }
            if let value = element.value as? String {
                let loweredValue = value.lowercased()
                for word in retiredWords {
                    XCTAssertFalse(
                        loweredValue.contains(word),
                        "Version History window should never say \"\(word)\" -- found in value \"\(value)\"",
                        file: file, line: line
                    )
                }
            }
        }
    }

    /// Polls `surface`'s StaticTexts until one element's label or value contains every string in
    /// `substrings`. AppKit can render a `.confirmationDialog`'s `message:` as a single combined
    /// StaticText, so this looks for one element carrying all the substrings rather than matching
    /// each sentence to its own element. See `assertNoRetiredVersionWords` for the same
    /// defensive-read shape (`.label` directly, `.value as? String` guarded).
    private func waitForCombinedMessage(
        in surface: XCUIElement, containing substrings: [String], timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for element in surface.staticTexts.allElementsBoundByIndex {
                guard element.exists else { continue }
                var candidates = [element.label]
                if let value = element.value as? String {
                    candidates.append(value)
                }
                for candidate in candidates where substrings.allSatisfy({ candidate.contains($0) }) {
                    return true
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    private func queryFixtureProjectId() -> String {
        let raw = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: "SELECT id FROM project LIMIT 1;")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "Fixture should have a project row")
        return trimmed
    }
}
