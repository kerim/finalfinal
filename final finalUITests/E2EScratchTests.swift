//
//  E2EScratchTests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for t-277d71eb (replaceblocks-guard).
//
//  Bug being verified (see Database+BlocksReplace.swift's `replaceBlocks` doc
//  comment and its private `carryBibliographyFlagForward` for the authoritative
//  mechanics): `replaceBlocks()`'s DEFAULT path deletes every block and
//  reinserts from a fresh parse, restoring `isBibliography` onto a HEADING row
//  by title match (`applyPreservedHeading`) but, before this fix, never onto
//  the non-heading ENTRY rows beneath it. When a fresh parse fails to
//  recognize a heading as a bibliography heading -- the doc comment names two
//  causes: "a custom bibliography header name changed since the heading was
//  written" or "a demoted heading level" -- every entry paragraph silently
//  lost its flag, and the next bibliography regeneration left them behind as
//  duplicate body text. The fix carries the flag forward onto entries too,
//  bounded by the next heading OR the document's bibliography-end terminator
//  (`BlockParser.bibliographyEndMarker`, recorded via the transient
//  `Block.endsBibliographyRun` `BlockParser.parse()` sets), whichever comes
//  first -- and specifically ensures trailing text typed below an
//  already-mismatched bibliography, with no heading in between, is never
//  swept into the flag.
//
//  DEVIATION FROM THE PLAN'S SCENARIO 1 TRIGGER -- read before changing this
//  file: the plan's core scenario calls for changing a CUSTOM bibliography
//  header-name Export Setting. That setting (`ExportSettings.bibliographyHeaderName`,
//  ExportSettings.swift) has NO discoverable UI anywhere in the app:
//  `grep -rn bibliographyHeaderName final final/Views` returns zero matches,
//  and ExportPreferencesPane.swift (the only export-preferences pane) has no
//  field for it at all -- confirmed by reading that file in full. It is also
//  not seedable from the XCUITest runner process: it is stored as a single
//  JSON-encoded `Data` blob under one UserDefaults key
//  (`com.kerim.final-final.exportSettings`), and the standard XCUITest
//  `-<key> <value>` launch-argument technique (used elsewhere in this suite,
//  e.g. `-com.kerim.final-final.diagnosticsLoggingEnabled YES`) only works for
//  scalar values UserDefaults can type-coerce from a command-line string --
//  `data(forKey:)` requires an actual `Data` object and will not coerce a
//  string, so that route silently no-ops rather than setting the value.
//
//  This file instead drives the OTHER cause the fix's own doc comment names:
//  a DEMOTED HEADING LEVEL. `BlockParser.isBibliographyHeading` only
//  recognizes `# Title` or `## Title` (BlockParser.swift:227-228); `### Title`
//  is never recognized, regardless of title text. Demoting "## Bibliography"
//  (a heading whose exact title is unconditionally recognized, since
//  `"Bibliography"` is a hardcoded literal in that titles list, independent
//  of any Export Setting) to "### Bibliography" via a live Source Mode edit
//  reproduces EXACTLY the same detection-mismatch code path
//  (`carryBibliographyFlagForward`, `mismatchedBibliographyHeadingIndices`)
//  the custom-header-name trigger would have -- it is not a substitute
//  mechanism, it is the fix's own documented alternate cause for the identical
//  bug. Using the literal "Bibliography" title also sidesteps the real
//  settings-collision risk the unit suite (`BibliographyCarryForwardTests.swift`)
//  had to work around for its OWN synthetic custom-header-name tests (a stray
//  swap of `ExportSettings.userDefaults`/`.standard` poisoning a neighboring
//  suite) -- this file never touches ExportSettings at all.
//
//  HIERARCHY-ENFORCEMENT CORRECTION (round 4, from a dedicated diagnostician
//  after two identical VM failures): an earlier round's fixture had the
//  Bibliography heading as the document's ONLY section, i.e. `sections[0]`.
//  `ContentView+HierarchyEnforcement.hasHierarchyViolations` unconditionally
//  requires the FIRST section to be H1; demoting a lone `sections[0]` heading
//  away from H1 is a hierarchy violation the app auto-detects and surgically
//  reverts back to H1 within roughly 1-2 seconds (confirmed via screen
//  recording: the paste landed at ~1s showing the demoted heading, then the
//  app reverted it within another ~1-2s, both times the round tried). The
//  test was fighting a real, intentional app feature, not exercising the
//  detection-mismatch bug -- and even a lucky catch of the transient window
//  would have made the downstream flag assertions pass vacuously against an
//  already-healthy, already-reverted document. Fixed by giving the document
//  THREE sections (H1 "Paper Title", H2 "Methods", H2 "Bibliography") so the
//  Bibliography heading is `sections[2]`, not `sections[0]`, and demoting it
//  by exactly one level (H2 -> H3) -- the max level hierarchy enforcement
//  allows for a section whose predecessor ("Methods") is H2, per
//  `hasHierarchyViolations`'s `maxLevel = min(6, predecessorLevel + 1)` rule.
//  This keeps the demotion permanently hierarchy-legal (never auto-reverted)
//  while remaining unrecognized by `isBibliographyHeading` (which only
//  accepts `#`/`##` forms) -- see `baselineMarkdown`'s doc comment below.
//
//  SCENARIO 3 (export/PDF) NOT DRIVEN -- also read before adding it back:
//  `PrintE2ETests.swift` documents that Pandoc + a LaTeX engine may not be
//  installed in the VM guest at all (its own tests XCTSkip on "Pandoc Not
//  Found"), and no test anywhere in this suite reads PDF content for
//  assertions. The DB-level assertions below already read the exact
//  `isBibliography` ground truth that bibliography regeneration and export
//  both consume directly (`BibliographySyncService.updateBibliographyBlock`
//  opens with a delete of every `isBibliography == true` row, and
//  `DocumentManager.exportBlocks()` filters on the same flag) -- a PDF
//  round-trip would be redundant with what's already proven here, per the
//  task brief's own "may be redundant -- use your judgment" guidance.
//
//  Construction mechanism -- why the bibliography section is seeded via a
//  direct `content.markdown` UPDATE plus a real first launch, not via typed
//  citations + Zotero: `BibliographySyncService.checkAndUpdateBibliography`
//  only regenerates when citekeys are present and change; a citekey-free seed
//  (used here) is a documented no-op for it (`lastKnownCitekeys` starts
//  empty, current citekeys are also empty, no transition -> early return), so
//  the hand-authored bibliography entries below are never touched by that
//  separate subsystem. The baseline flagged state itself is NOT hand-inserted
//  via SQL -- `block` is cleared and `content.markdown` is seeded, then a REAL
//  app launch takes `ContentView+ProjectLifecycle.loadInitialContent`'s
//  "no blocks yet" branch, which calls the exact same `BlockParser.parse` +
//  `db.replaceBlocks(_:for:)` pair the fix touches, establishing a genuinely
//  parsed, correctly-flagged starting state (heading + both entries all
//  `isBibliography = true`) exactly as a healthy document would have it.
//
//  Trigger mechanism -- why Source Mode, and why the terminator is embedded
//  by hand in the pasted replacement text: literal `<!-- ::auto-bibliography-end:: -->`
//  text only becomes a real parse-time boundary when the app re-parses it as
//  raw markdown source (`BlockParser.parse`'s `trimmed == bibliographyEndMarker`
//  branch) -- WYSIWYG has no live typed-conversion for it, matching
//  `E2ESectionReconcilerPseudoSectionTests.swift`'s identical reasoning for
//  its own HTML-comment section-break marker. In real use the terminator is
//  inserted automatically by `BlockParser.assembleMarkdownForEditor` on every
//  editor-content assembly (immediately after the last flagged block); it is
//  embedded directly in this file's replacement strings instead of obtained
//  via an extra relaunch-and-reassemble round trip, purely to keep the test to
//  one relaunch. Its content/position is byte-identical to what that real
//  assembler would produce for this exact document shape.
//
//  Verification mechanism: DB read (ground truth -- the `block` table's
//  `isBibliography`/`headingLevel`/`textContent` columns are exactly what the
//  fix reads and writes), matching `E2ESectionReconcilerPseudoSectionTests.swift`'s
//  established preference for DB-level proof over fragile live-editor text
//  assertions, PLUS one direct editor-visibility check for the trailing
//  paragraph (task explicitly asks that it not be "silently hidden").
//
//  Mapping to the plan's user-verification list (recorded in
//  .claude/superdev/replaceblocks-guard/notes.md):
//    1. Core scenario (custom header-name mismatch) -> DRIVEN, via the
//       heading-level-demotion equivalent described above, not the literal
//       Export Settings UI step (no such UI exists -- see above).
//    2. Trailing-text scenario -> DRIVEN as specified.
//    3. Export/PDF scenario -> NOT DRIVEN -- redundant with #1/#2's DB-level
//       ground truth, and impractical given the VM's undetermined Pandoc
//       availability and no PDF-reading precedent in this suite.
//    4. "Fix is preventive, not curative" (the plan's pinned no-op) -> NOT
//       re-tested here; already covered by the unit suite
//       (`BibliographyCarryForwardTests.swift`'s `alreadyDamagedDocumentIsNotRepaired`),
//       and explicitly out of scope for this e2e pass per the task brief.
//

import AppKit
import XCTest

final class E2EScratchTests: XCTestCase {
    var app: XCUIApplication!

    /// Baseline document: three sections -- an H1 title, an H2 "Methods"
    /// section, and an H2 "Bibliography" section whose title ("Bibliography")
    /// is unconditionally recognized by `BlockParser.isBibliographyHeading`
    /// regardless of any Export Setting. The Bibliography heading is
    /// deliberately NOT the document's only section and NOT `sections[0]`:
    /// see the file header's "HIERARCHY-ENFORCEMENT CORRECTION" note for why
    /// that shape is load-bearing (a lone `sections[0]` Bibliography heading
    /// gets its demotion silently auto-reverted by hierarchy enforcement).
    /// Seeded directly into `content.markdown` (app terminated) so the FIRST
    /// real launch's legacy "no blocks yet" parse establishes a genuinely
    /// healthy, correctly-flagged starting state.
    private static let baselineMarkdown = """
    # Paper Title

    Intro paragraph for the carry-forward fixture.

    ## Methods

    Methods paragraph for the carry-forward fixture.

    ## Bibliography

    Smith 2020 A Study of Carry Forward Fixtures.

    Jones 2021 Another Study of Detection Mismatches.
    """

    /// Replacement 1 -- establishes the detection mismatch: the Bibliography
    /// heading is demoted from H2 to H3 (title text unchanged, so
    /// `applyPreservedHeading` still matches and restores the flag by title
    /// -- but the fresh parse's own `isBibliographyHeading` no longer
    /// recognizes an H3 heading, which is the mismatch this fix carries the
    /// flag forward from). H2 -> H3 is exactly the max level hierarchy
    /// enforcement allows for a section whose predecessor ("Methods") is H2
    /// (`hasHierarchyViolations`'s `maxLevel = min(6, predecessorLevel + 1)`
    /// rule), so this demotion is hierarchy-legal and is left alone rather
    /// than auto-reverted. The terminator is embedded so the carry has a
    /// bound to work within -- see file header "Trigger mechanism".
    private static let mismatchMarkdown = """
    # Paper Title

    Intro paragraph for the carry-forward fixture.

    ## Methods

    Methods paragraph for the carry-forward fixture.

    ### Bibliography

    Smith 2020 A Study of Carry Forward Fixtures.

    Jones 2021 Another Study of Detection Mismatches.

    <!-- ::auto-bibliography-end:: -->
    """

    /// Replacement 2 -- adds a brand-new paragraph AFTER the terminator (i.e.
    /// genuinely past the bibliography section's real end, exactly the shape
    /// `carryBibliographyFlagForward`'s bound must exclude), simulating a user
    /// typing new content below an already-mismatched bibliography with no
    /// heading in between.
    private static let trailingTextMarkdown = """
    # Paper Title

    Intro paragraph for the carry-forward fixture.

    ## Methods

    Methods paragraph for the carry-forward fixture.

    ### Bibliography

    Smith 2020 A Study of Carry Forward Fixtures.

    Jones 2021 Another Study of Detection Mismatches.

    <!-- ::auto-bibliography-end:: -->

    Trailing paragraph typed directly below the bibliography with no heading in between.
    """

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

    func testBibliographyFlagCarryForwardAndTrailingTextGuard() throws {
        // MARK: 1. Seed the baseline document (app not yet launched against this fixture copy)

        FixtureDatabase.write(fixturePath: TestFixtureHelper.fixturePath, sql: "DELETE FROM block;")
        FixtureDatabase.write(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "UPDATE content SET markdown = '\(FixtureDatabase.escape(Self.baselineMarkdown))';"
        )

        // MARK: 2. First launch -- real legacy "no blocks yet" parse establishes the healthy baseline

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear with seeded content")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
        Thread.sleep(forTimeInterval: 2.0)

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("01-baseline-loaded.png"))

        let baselineFlaggedCount = Self.countBibliographyFlaggedBlocks(fixturePath: TestFixtureHelper.fixturePath)
        XCTAssertEqual(
            baselineFlaggedCount, 3,
            "Baseline first-parse should flag the heading + both entries as bibliography. Got count: \(baselineFlaggedCount)"
        )
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Smith 2020"),
            "Baseline: Smith entry should be flagged bibliography before any mismatch is introduced"
        )
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Jones 2021"),
            "Baseline: Jones entry should be flagged bibliography before any mismatch is introduced"
        )

        // MARK: 3. Switch to Source Mode (needed for the raw HTML-comment terminator to parse)

        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")
        app.activateAndWaitForForeground()
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(editorMode.waitForLabel("== 'Source'", timeout: 10), "Editor-mode button should report Source")

        // Mount-completion gate -- established pattern, EditorModeSwitchUndoE2ETests.swift's
        // waitForSourceEditorMounted() (file lines ~399-407, ~463-482): the status-bar label
        // flip above is synchronous with the toggle keystroke, but the actual
        // WYSIWYG->CodeMirror view swap runs through an async callback chain that can lag
        // behind it. A caller that clicks/selects/pastes right after the label flips (or after
        // only a FIXED sleep) risks landing the click and Cmd+A/Cmd+V in the still-live
        // Milkdown instance rather than the new CodeMirror one.
        //
        // CORRECTION (post-mortem from a dedicated diagnostician, round 4, after this test
        // failed on the same key for a THIRD time): an earlier round attributed its failures
        // to a word-count-based landing probe being structurally invariant (`mismatchMarkdown`
        // and `baselineMarkdown` share the same 16-word count), and replaced it with an
        // AX-tree marker scan (`editorArea.staticTexts.allElementsBoundByIndex`). That probe
        // was ALSO wrong: `.staticTexts` doesn't reliably enumerate CodeMirror source-mode
        // content in this app. The real root cause of every failure in this test was a
        // fixture-shape bug entirely unrelated to the landing probe -- see the file header's
        // "HIERARCHY-ENFORCEMENT CORRECTION" note. The landing gate below is now driven by DB
        // ground truth instead, which sidesteps the AX-enumeration reliability issue entirely:
        // every downstream assertion in this test reads the same DB table anyway. This
        // mount-completion gate itself stays and is unaffected by any of the above: it is
        // still correct and still established practice elsewhere in this suite. "# Paper
        // Title" (with the literal leading "#", and now the document's actual first line) is
        // unique proof of CodeMirror having mounted: Milkdown's WYSIWYG rendering strips
        // markdown syntax, so no WYSIWYG element can ever expose the raw "#" character -- only
        // CodeMirror, which renders the raw source verbatim, can.
        waitForSourceEditorMounted(editorArea: editorArea, markerText: "# Paper Title")

        // MARK: 4. Scenario 1 (core, via heading-demotion equivalent): replace the whole
        // document in one paste, demoting the Bibliography heading from H2 to H3

        // Landing gate: waits for actual DB reparse ground truth -- not an AX-tree marker
        // scan, and not the status-bar word count (`mismatchMarkdown` and `baselineMarkdown`
        // share the same 16-word count, so a word-count-delta probe is structurally invariant
        // here). Every downstream assertion in this test already depends on this same DB
        // table, so driving the landing gate off it directly both proves what actually
        // matters and sidesteps `.staticTexts`'s CodeMirror-enumeration unreliability (see the
        // CORRECTION comment above `waitForSourceEditorMounted`). `landed` must return true
        // only once the specific reparse this paste should trigger has actually completed.
        func pasteWholeDocument(_ markdown: String, landed: @escaping () -> Bool) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)

            func selectAllAndPaste() {
                editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
                app.activateAndWaitForForeground()
                app.typeKey("a", modifierFlags: .command)
                app.typeKey("v", modifierFlags: .command)
            }

            selectAllAndPaste()
            var pasteLanded = Self.waitUntil(timeout: 8, landed)
            if !pasteLanded {
                selectAllAndPaste()
                pasteLanded = Self.waitUntil(timeout: 15, landed)
            }
            XCTAssertTrue(pasteLanded, "Pasted document never reached the app (no reparse observed in the block table)")
        }

        pasteWholeDocument(Self.mismatchMarkdown) {
            Self.headingLevel(fixturePath: TestFixtureHelper.fixturePath, textContains: "Bibliography") == 3
        }

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("02-heading-demoted-mismatch.png"))

        // THE ACTUAL PROOF for scenario 1: pre-fix, the fresh parse's failure to recognize an H3
        // heading as bibliography would leave both entries unflagged (only the heading itself
        // would be restored via title-match applyPreservedHeading). Post-fix, both entries carry
        // the flag forward too.
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Bibliography"),
            "BUG: the demoted (H3) heading itself should still be flagged bibliography (restored by title match)"
        )
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Smith 2020"),
            "BUG: Smith entry lost its bibliography flag after the heading-detection mismatch -- " +
            "this is exactly the data-loss bug t-277d71eb fixes. It would next be left behind as " +
            "duplicate body text on bibliography regeneration."
        )
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Jones 2021"),
            "BUG: Jones entry lost its bibliography flag after the heading-detection mismatch -- " +
            "same data-loss bug as the Smith entry above."
        )
        let flaggedAfterMismatch = Self.countBibliographyFlaggedBlocks(fixturePath: TestFixtureHelper.fixturePath)
        XCTAssertEqual(
            flaggedAfterMismatch, 3,
            "Exactly heading + 2 entries should be flagged -- not fewer (data loss) and not more " +
            "(an over-broad, unbounded carry). Got count: \(flaggedAfterMismatch)"
        )

        // MARK: 5. Scenario 2 (trailing text): type a new paragraph below the bibliography,
        // past the terminator, with no heading in between -- must never be swept into the flag

        pasteWholeDocument(Self.trailingTextMarkdown) {
            Self.blockExists(fixturePath: TestFixtureHelper.fixturePath, textContains: "Trailing paragraph typed directly")
        }

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("03-trailing-text-added.png"))

        // (The landing gate inside `pasteWholeDocument` above already proved the new trailing
        // paragraph exists as a real block -- no separate poll needed here.)
        XCTAssertFalse(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Trailing paragraph typed directly"),
            "BUG: the new trailing paragraph (typed below an already-mismatched bibliography, no " +
            "heading in between) was wrongly swept into the bibliography flag -- it would be hidden " +
            "from export and silently deleted by the next bibliography regeneration."
        )
        // The original entries must be unaffected by this second reparse.
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Smith 2020"),
            "Smith entry should still be flagged bibliography after the trailing-text edit"
        )
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Jones 2021"),
            "Jones entry should still be flagged bibliography after the trailing-text edit"
        )
        let flaggedAfterTrailingText = Self.countBibliographyFlaggedBlocks(fixturePath: TestFixtureHelper.fixturePath)
        XCTAssertEqual(
            flaggedAfterTrailingText, 3,
            "Still exactly heading + 2 entries flagged -- the trailing paragraph must add a new " +
            "unflagged block, not a fourth flagged one. Got count: \(flaggedAfterTrailingText)"
        )

        // UI-level check (task explicitly asks that the trailing text remain visible, not
        // silently hidden): the new paragraph must actually be present on screen in the editor.
        // `.descendants(matching: .any)`, not `.staticTexts` (the shared `editorStaticText`
        // helper's query) -- the latter doesn't reliably enumerate CodeMirror source-mode
        // content in this app; same reasoning as the landing gate and the mount-gate above,
        // both of which already use this exact idiom.
        let trailingTextEvidence = editorArea.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Trailing paragraph typed directly", "Trailing paragraph typed directly"
            )
        ).firstMatch
        XCTAssertTrue(
            trailingTextEvidence.waitForExistence(timeout: 10),
            "The new trailing paragraph should be visible in the editor, not silently hidden"
        )
    }

    // MARK: - Editor-mode helpers

    /// Poll for concrete evidence that the CodeMirror source editor actually mounted -- not
    /// just that the status-bar label flipped. Same technique as
    /// `EditorModeSwitchUndoE2ETests.swift`'s `waitForSourceEditorMounted()`: `markerText` must
    /// be a substring that can only ever appear in the raw markdown source (i.e. it contains
    /// characters Milkdown's WYSIWYG rendering strips, like a leading "#"), so its appearance
    /// anywhere in the `editor-area` subtree is proof CodeMirror mounted, not just that the
    /// button re-labeled itself.
    private func waitForSourceEditorMounted(editorArea: XCUIElement, markerText: String) {
        let sourceEvidence = editorArea.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", markerText, markerText)
        ).firstMatch
        XCTAssertTrue(
            sourceEvidence.waitForExistence(timeout: 10),
            "CodeMirror source editor should render the raw markdown after toggling, not just flip the status-bar label"
        )
    }

    // MARK: - DB query helpers (read-only; safe to run while the app is open --
    // WAL mode, matching E2ESectionReconcilerPseudoSectionTests.swift/FixtureDatabase's own doc comment)

    private static func countBibliographyFlaggedBlocks(fixturePath: String) -> Int {
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: "SELECT COUNT(*) FROM block WHERE isBibliography = 1;")
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private static func isBibliographyFlagged(fixturePath: String, textContains needle: String) -> Bool {
        let sql = "SELECT isBibliography FROM block WHERE textContent LIKE '%\(FixtureDatabase.escape(needle))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout == "1"
    }

    private static func blockExists(fixturePath: String, textContains needle: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM block WHERE textContent LIKE '%\(FixtureDatabase.escape(needle))%';"
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(stdout) ?? 0) > 0
    }

    private static func headingLevel(fixturePath: String, textContains needle: String) -> Int? {
        let sql = "SELECT headingLevel FROM block WHERE blockType = 'heading' AND textContent LIKE '%\(FixtureDatabase.escape(needle))%' LIMIT 1;"
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: sql).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(stdout)
    }

    /// Bounded poll on DB ground truth, replacing a blind settle sleep: retries `predicate`
    /// (a read of the fixture DB) until it returns true or `timeout` elapses, returning the
    /// final result either way. Used after each `pasteWholeDocument` call so the test waits
    /// for the actual reparse to land instead of assuming a fixed duration is always enough.
    private static func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.25, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: poll)
        } while Date() < deadline
        return predicate()
    }
}
