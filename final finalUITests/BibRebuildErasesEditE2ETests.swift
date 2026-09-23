//
//  BibRebuildErasesEditE2ETests.swift
//  final finalUITests
//
//  PERMANENT e2e regression test, moved here from the disposable
//  `E2EScratchTests.swift` scratch pad per that file's own header ("A class worth
//  keeping gets copied to its own named file and `git add`ed BEFORE the reset").
//
//  t-7c1d3fd8 (Finding #1, Calm_Bibliography, docs/architecture/tla/README.md): disposable e2e
//  proof that a citation typed into an existing paragraph survives a bibliography rebuild,
//  through the REAL handler wiring (ContentView.handleBibliographySectionChanged ->
//  BlockSyncService.beginDatabaseRebuild() / pollBlockChangesNowForDatabaseRebuild()) -- not
//  just the service-level unit tests (BlockSyncPollWatchdogTests+RebuildKeepsBatch.swift) that
//  call those two methods directly. See
//  final final/Services/BlockSyncService+DatabaseRebuild.swift for the fix itself.
//
//  Real Zotero is unavailable in the vmtest VM guest -- established pattern (see
//  ProjectSwitchBibliographyE2ETests.swift's own doc comment, and UnifiedUndoE2ETests.swift's
//  testCitationInsertRacedAgainstStructuralOpIsCancelledNotCorrupted): FF_UI_TESTING_ZOTERO_MOCK
//  makes Cmd-Shift-K insert a canned, already-resolved citation (citekey
//  "ffe2emockcitation2026", author "Ffmocksurname") with no real Zotero connection needed. Only
//  the citation's SOURCE is mocked here -- the citekey-detected -> debounced bibliography
//  rebuild -> handleBibliographySectionChanged path this test drives is the real one, identical
//  to what a genuine Zotero-resolved `[@somekey]` citation would trigger.
//
//  Plan user-verification mapping: "with Zotero running, type a citation in a paragraph, wait
//  for the bibliography to update, and confirm the citation text is still present in the
//  paragraph afterward" maps onto this file's single test method,
//  testCitationTypedIntoParagraphSurvivesBibliographyRebuild, in three steps: (1) type the
//  citation via Cmd-Shift-K (Zotero-mocked, see above) into a paragraph with known,
//  distinctive pre-existing text; (2) poll `section.markdownContent WHERE isBibliography = 1`
//  for the mock's author surname -- proof a REAL rebuild reached the `section` table, not just
//  that the citekey landed; (3) read that SAME paragraph's `block` row back and assert it still
//  holds BOTH its original distinctive text AND the citekey. Evidence produced: a screenshot
//  attachment ("after-bibliography-rebuild") plus the two DB reads themselves, both printed on
//  any assertion failure.
//

import XCTest

final class BibRebuildErasesEditE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// Must match `ZoteroService+CAYW.swift`'s `mockCitekey` -- same literal
    /// `UnifiedUndoE2ETests.swift` pins for the identical reason.
    private static let mockCitekey = "ffe2emockcitation2026"
    private static let mockAuthorSurname = "Ffmocksurname"
    /// 49 chars, matching the length budget of UnifiedUndoE2ETests+Helpers.swift's
    /// canonicalMarkdown paragraphs -- harmless to keep this short, but NOT what makes the
    /// citation land cleanly (see the end-of-document click below for that).
    private static let targetParagraphText = "Distinctive text for bib rebuild proof paragraph."

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

    func testCitationTypedIntoParagraphSurvivesBibliographyRebuild() throws {
        // Known, controlled content, seeded before first launch -- same pattern as
        // UnifiedUndoE2ETests+Helpers.swift's seedCanonicalDocument(), so the target paragraph
        // is unambiguously findable by its own distinctive text rather than trusting whatever
        // the committed fixture happens to ship with today (see the e2e-verify skill's
        // "Fixtures" section on never assuming a committed fixture's content).
        FixtureDatabase.seedMarkdown(
            fixturePath: TestFixtureHelper.fixturePath,
            markdown: "# Test Document\n\n\(Self.targetParagraphText)\n"
        )

        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Editor JS should be ready")

        // Confirm the seeded paragraph is present before the edit -- the baseline this test's
        // final assertion proves survives the rebuild, not an assumption.
        guard let paragraph = app.editorStaticText(startingWith: Self.targetParagraphText, timeout: 10) else {
            XCTFail("Seeded target paragraph not found before edit.\n\(app.editorStaticTextsDump())")
            return
        }

        // `coordinate(withNormalizedOffset:)` scales by the ELEMENT'S OWN frame, not a fixed
        // pixel distance -- a small dx like 0.05 is not reliably "near the start of the text"
        // (it can land a couple of characters in, mid-word). Click at the paragraph's far
        // right edge instead and use Cmd-Down (moveToEndOfDocument, not Cmd-Right, which only
        // reaches end-of-VISUAL-line) to land the caret at the true end of the document --
        // this seeded document is just the heading plus this one paragraph (no Bibliography
        // section exists yet), so end-of-document IS end-of-this-paragraph, and appending the
        // citation there keeps the original text one unbroken run.
        app.activateAndWaitForForeground()
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .command)

        // Insert the citation at that caret position via the Zotero mock -- Cmd-Shift-K, the
        // same trigger a real Zotero-backed insert uses; only the network round trip is mocked.
        app.typeKey("k", modifierFlags: [.command, .shift])

        // Plan step "wait for the bibliography to update": poll until a REAL rebuild has
        // reached the `section` table, not merely that the citekey landed in the paragraph.
        // ~15s budget matches ProjectSwitchBibliographyE2ETests' own citation-insert wait
        // (bibliography debounce ~1s + mock CAYW round trip + the rebuild's own async Task).
        let bibliographyEntry = waitUntilString(
            timeout: 15,
            probe: {
                FixtureDatabase.read(
                    fixturePath: TestFixtureHelper.fixturePath,
                    sql: "SELECT markdownContent FROM section WHERE isBibliography = 1;"
                )
            },
            predicate: { $0.contains(Self.mockAuthorSurname) }
        )
        XCTAssertTrue(
            bibliographyEntry.contains(Self.mockAuthorSurname),
            "The bibliography section should rebuild to include the mock citation's author " +
            "(\"\(Self.mockAuthorSurname)\") -- not found in section.markdownContent WHERE " +
            "isBibliography = 1 within 15s. Got: \(bibliographyEntry)"
        )

        // Plan step "confirm the citation text is still present in the paragraph afterward":
        // read the SAME paragraph's block row back. Before t-7c1d3fd8, the routine 2s poll
        // cycle that picked up this citation edit could be discarded the instant the
        // bibliography rebuild above began (BlockSyncService.checkGenerationGuard's
        // postFetch/postChainWait generation check), and the rebuild would then push the
        // paragraph's OLDER, pre-citation database text back into the editor -- the citekey
        // silently vanishes even though the bibliography itself updated correctly. Read
        // BEFORE the screenshot/assert below so the value is available for the failure
        // message either way, and the screenshot is taken before any assertion that could
        // abort the method (e2e-verify skill, "Runner environment").
        let paragraphAfterRebuild = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT markdownFragment FROM block WHERE markdownFragment LIKE '%Distinctive text%' " +
                "OR markdownFragment LIKE '%\(Self.mockCitekey)%';"
        )
        // Self-explaining on failure: a full block dump shows where the text/citekey actually
        // landed instead of leaving a failed LIKE match as an unexplained empty string.
        let allBlocksDump = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT id, markdownFragment FROM block;"
        )
        attachEvidenceScreenshot(app.screenshot(), name: "after-bibliography-rebuild")

        XCTAssertTrue(
            paragraphAfterRebuild.contains(Self.targetParagraphText),
            "The paragraph's own block row should still be findable by its original text after " +
            "the bibliography rebuild -- got: \(paragraphAfterRebuild)\nAll blocks:\n\(allBlocksDump)"
        )
        XCTAssertTrue(
            paragraphAfterRebuild.contains(Self.mockCitekey),
            "The citation must still be present in the paragraph after the bibliography " +
            "rebuild, not reverted to its pre-edit text (Finding #1, t-7c1d3fd8) -- citekey " +
            "\"\(Self.mockCitekey)\" not found in the paragraph's block row: " +
            "\(paragraphAfterRebuild)\nAll blocks:\n\(allBlocksDump)"
        )
    }

    // MARK: - Local poll helper (this class's own; not shared with other e2e classes -- same
    // pattern as ProjectSwitchBibliographyE2ETests' own waitUntilString)

    private func waitUntilString(
        timeout: TimeInterval, pollInterval: TimeInterval = 0.25,
        probe: () -> String, predicate: (String) -> Bool
    ) -> String {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = probe()
        while Date() < deadline {
            last = probe()
            if predicate(last) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
        return last
    }
}
