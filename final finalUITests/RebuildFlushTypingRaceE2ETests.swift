//
//  RebuildFlushTypingRaceE2ETests.swift
//  final finalUITests
//
//  t-6a0d195d ("a bibliography/Notes/footnote rebuild overwrites words typed during the
//  rebuild's own flush window"). Proves the FIX (`setContentWithBlockIds`'s `preserveUserBlocks`
//  merge push, api-content.ts) end to end: this test now PASSES, driving the real
//  `TestMode.uiTestingRebuildPushDelayMilliseconds` / `holdRebuildFlushWindowForUITesting()` seam
//  that widens the rebuild's flush window wide enough to type into deterministically. A
//  genuinely new PERMANENT file, not routed through the disposable `E2EScratchTests.swift`
//  scratch pad, because it must survive across rounds -- named after the task per this
//  project's own e2e-verify lesson on generic scratch-class names colliding across parallel
//  worktrees' retry streaks.
//
//  Proof the race window was actually exercised, not merely assumed from timing: both
//  `holdRebuildFlushWindowForUITesting()` (Swift, app process) and this test's own typing loop
//  (below) log wall-clock-timestamped `NSLog` markers ("[RebuildFlushRace] hold-window
//  START/END" and "typed chunk N") to the SAME unified log stream the XCUITest run captures --
//  a human or CI log scan can directly confirm a typed-chunk timestamp fell between the
//  hold-window's own START and END markers, instead of trusting that a fixed typing cadence
//  probably overlaps a fixed delay.
//
//  This is a DIFFERENT race than `BibRebuildErasesEditE2ETests.swift` already covers: that
//  test's mock CAYW round trip and the rebuild it triggers both resolve near-instantly, long
//  before a human could type anything, and it only checks that the CITING paragraph survives.
//  This test widens the rebuild's own held-open push window (via the new
//  `FF_UI_TESTING_REBUILD_PUSH_DELAY_MS` env var) wide enough to type into deterministically,
//  and types into a DIFFERENT paragraph than the one that triggered the rebuild -- proving the
//  rebuild's blanket editor push can clobber typing ANYWHERE in the document during its flush
//  window, not just in the paragraph that triggered it.
//
//  Scenario: seed a two-paragraph document (Alpha, Beta). Insert a mock citation at the end of
//  Alpha -- the real trigger chain: citekey detected -> debounced (~1s) ->
//  handleBibliographySectionChanged -> pollBlockChangesNowForDatabaseRebuild (forced flush) ->
//  fetchBlocksWithIds() -> [held open ~2.5s by the test-only delay] -> setContentWithBlockIds()
//  (the push that overwrites the editor). While that rebuild is in flight, type into Beta in
//  small paced chunks spanning the whole window, then confirm Beta's own words survive both in
//  the database and on screen.
//
//  Zotero mock: FF_UI_TESTING_ZOTERO_MOCK makes Cmd-Shift-K insert a canned, already-resolved
//  citation (citekey "ffe2emockcitation2026", author surname "Ffmocksurname") with no real
//  Zotero connection needed -- see `ZoteroService+CAYW.swift`'s `mockCitekey` and
//  `BibRebuildErasesEditE2ETests.swift`'s own doc comment, the precedent this borrows.
//

import XCTest

final class RebuildFlushTypingRaceE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// Must match `ZoteroService+CAYW.swift`'s mock author surname -- same literal
    /// `BibRebuildErasesEditE2ETests.swift` pins for the identical reason.
    private static let mockAuthorSurname = "Ffmocksurname"
    private static let alphaText = "Alpha paragraph text."
    private static let betaText = "Beta paragraph text."
    /// Typed into Beta in ~10 paced chunks while the rebuild triggered by Alpha's citation is
    /// held open -- see the pacing loop below. The leading space continues Beta's existing
    /// sentence rather than starting a new word run; trimmed before use in a DB/screen substring
    /// check (`typedSuffix`) since markdown (re)serialization is not guaranteed to preserve a
    /// leading space exactly.
    private static let raceSuffix = " typed during rebuild window zq"
    private static var typedSuffix: String { raceSuffix.trimmingCharacters(in: .whitespaces) }

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

    func testTypingIntoOtherParagraphDuringRebuildFlushWindowSurvives() throws {
        // Known, controlled content, seeded before first launch -- same pattern as
        // BibRebuildErasesEditE2ETests.swift -- so both paragraphs are unambiguously findable by
        // their own distinctive text rather than trusting whatever the committed fixture ships
        // with today (e2e-verify skill, "Fixtures").
        FixtureDatabase.seedMarkdown(
            fixturePath: TestFixtureHelper.fixturePath,
            markdown: "# Test Document\n\n\(Self.alphaText)\n\n\(Self.betaText)\n"
        )

        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        // Widens handleBibliographySectionChanged's flush-to-push window (see this file's own
        // header) so the paced typing below has a real, wide-open target instead of racing a
        // window that closes in milliseconds.
        app.launchEnvironment["FF_UI_TESTING_REBUILD_PUSH_DELAY_MS"] = "2500"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Editor JS should be ready")

        guard let alphaParagraph = app.editorStaticText(startingWith: Self.alphaText, exactLine: Self.alphaText, timeout: 10) else {
            XCTFail("Seeded Alpha paragraph not found before edit.\n\(app.editorStaticTextsDump())")
            return
        }

        app.activateAndWaitForForeground()
        // Click near the RIGHT edge of Alpha's own frame, with NO follow-up keystroke -- a real
        // mouse event places the caret at the true end of THIS line without a further-keystroke
        // drop risk, and without overshooting into Beta (Cmd-Down/moveToEndOfDocument would land
        // in Beta instead, since Beta -- not Alpha -- is the last paragraph here). Same proven
        // pattern as `ListNumberingE2ETests.focusEditorAndGoToDocumentEnd`'s own doc comment and
        // `BibRebuildErasesEditE2ETests`'s citation-insert click.
        alphaParagraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()

        // Insert the citation via the Zotero mock -- this is the rebuild's real trigger: a
        // debounced (~1s) citekey-detected bibliography rebuild through the actual
        // handleBibliographySectionChanged handler chain (ContentView+NotificationHandlers.swift),
        // not a synthetic call into that handler.
        app.typeKey("k", modifierFlags: [.command, .shift])

        // Round-3 review (#20): wait for the citation to actually LAND in Alpha's own block row
        // before clicking into Beta -- not a fixed sleep. Without this, clicking away to Beta
        // immediately after the keystroke races the mock CAYW round trip itself (a genuinely
        // async callback); this makes the citekey-detected -> debounced rebuild trigger chain
        // deterministically armed before the typing loop below starts, instead of leaving it to
        // chance whether the trigger had even fired yet.
        let alphaAfterCitation = waitUntilString(
            timeout: 10,
            probe: {
                FixtureDatabase.read(
                    fixturePath: TestFixtureHelper.fixturePath,
                    sql: "SELECT markdownFragment FROM block WHERE markdownFragment LIKE '%\(Self.mockAuthorSurname)%' " +
                        "OR markdownFragment LIKE '%Alpha paragraph%';"
                )
            },
            predicate: { $0.contains(Self.mockAuthorSurname) }
        )
        XCTAssertTrue(
            alphaAfterCitation.contains(Self.mockAuthorSurname),
            "The citation should land in Alpha's own block row before proceeding -- not found " +
            "within 10s. Got: \(alphaAfterCitation)"
        )

        // Re-resolve Beta AFTER the citation insertion above -- a handle captured earlier can go
        // stale once Alpha's own content (and the surrounding layout) has changed.
        guard let betaParagraph = app.editorStaticText(startingWith: Self.betaText, exactLine: Self.betaText, timeout: 10) else {
            XCTFail("Seeded Beta paragraph not found after citation insert.\n\(app.editorStaticTextsDump())")
            return
        }
        betaParagraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()

        // Type across the race window in ~10 chunks, 0.5s apart -- deliberately spans the
        // bibliography debounce (~1s), the rebuild's forced pollBlockChangesNowForDatabaseRebuild
        // flush, and the 2.5s FF_UI_TESTING_REBUILD_PUSH_DELAY_MS-held-open push, so some chunks
        // land in the exact window between the forced flush's DB snapshot and the delayed push
        // that overwrites the editor with it. Fixed pacing, not a poll -- there is nothing
        // observable to wait ON between chunks, only a cadence to hold -- so this uses
        // RunLoop-based waiting (not Thread.sleep) to keep the run loop pumping AX/XCUITest event
        // delivery between chunks, matching every poll loop already in UITestHelpers.swift.
        let raceCharacters = Array(Self.raceSuffix)
        var chunkStart = raceCharacters.startIndex
        let chunkSize = max(raceCharacters.count / 10, 1)
        var chunkIndex = 0
        while chunkStart < raceCharacters.count {
            let chunkEnd = min(chunkStart + chunkSize, raceCharacters.count)
            // typeTextVerifyingLanded doesn't fit here: its precondition is a caret on its own
            // EMPTY line typing one complete string, and its repair path clears the whole
            // current line and retypes from scratch on a mismatch. Beta's line already holds
            // real seeded content, and this loop's whole point is small, precisely-paced chunks
            // landing over several seconds while a rebuild is mid-flight -- a landing-verified
            // retry here would both corrupt Beta's pre-existing text on a false-positive
            // "mismatch" (the rebuild's own push, mid-race, is exactly the kind of external
            // mutation that helper isn't built to expect) and blow the fixed cadence this race
            // depends on. The final assertions below already verify the text landed (DB +
            // on-screen), so a dropped character here fails the test loudly rather than passing
            // silently. e2e-lint: allow raw-typetext
            // Round-3 review (#20): log marker with a real wall-clock timestamp, in the SAME
            // unified log stream `holdRebuildFlushWindowForUITesting()` (Swift, app process)
            // logs its own "hold-window START/END" markers to -- lets a log scan confirm this
            // chunk's timestamp actually fell inside the held-open window, not merely assumed.
            NSLog("[RebuildFlushRace] typed chunk \(chunkIndex)")
            app.typeText(String(raceCharacters[chunkStart..<chunkEnd]))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            chunkStart = chunkEnd
            chunkIndex += 1
        }

        // Wait for a REAL rebuild to reach the `section` table (not merely that the citekey
        // landed in Alpha) -- same proof shape as BibRebuildErasesEditE2ETests. ~15s budget
        // matches that file's own citation-insert wait (debounce + mock CAYW round trip + this
        // test's own 2.5s held-open push + the rebuild's async Task).
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

        // Let the routine (non-rebuild) debounced save settle before reading final state -- a
        // fixed wait, not a poll: there is no single observable condition for "the ordinary save
        // has finished", only time to let it happen.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))

        // Read BEFORE the screenshot/assert below so the value is available for the failure
        // message either way, and the screenshot is taken before any assertion that could abort
        // the method (e2e-verify skill, "Runner environment").
        let betaBlockRow = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT markdownFragment FROM block WHERE markdownFragment LIKE '%Beta paragraph text%';"
        )
        let allBlocksDump = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT id, markdownFragment FROM block;"
        )
        attachEvidenceScreenshot(app.screenshot(), name: "after-rebuild-flush-typing-race")

        XCTAssertTrue(
            betaBlockRow.contains(Self.typedSuffix),
            "Beta's own block row should contain the words typed during the rebuild's flush " +
            "window (\"\(Self.typedSuffix)\") -- t-6a0d195d: the rebuild's push overwrote them " +
            "instead. Got: \(betaBlockRow)\nAll blocks:\n\(allBlocksDump)"
        )
        XCTAssertTrue(
            app.editorContainsText(Self.typedSuffix, timeout: 5),
            "Beta's on-screen editor text should still show the words typed during the " +
            "rebuild's flush window (\"\(Self.typedSuffix)\") -- t-6a0d195d.\n" +
            app.editorStaticTextsDump()
        )

        // Round-3 review (#20): end-to-end regression guard for #4/#9 (the structural
        // managed-span duplicate-avoidance rule, api-content.ts's mergeManagedBlocks) -- a
        // rebuild racing live typing must never ship a document with two bibliography
        // sections. `isBibliography` rows are one-per-document by construction on a healthy
        // rebuild; more than one is exactly the failure #4 targeted.
        let bibliographySectionCount = FixtureDatabase.read(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "SELECT COUNT(*) FROM section WHERE isBibliography = 1;"
        )
        XCTAssertEqual(
            bibliographySectionCount.trimmingCharacters(in: .whitespacesAndNewlines), "1",
            "Exactly one bibliography section should exist after the race -- got count=" +
            "\(bibliographySectionCount). All blocks:\n\(allBlocksDump)"
        )
    }

    // MARK: - Local poll helper (this class's own; same pattern as
    // BibRebuildErasesEditE2ETests's own waitUntilString -- not shared with other e2e classes)

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
