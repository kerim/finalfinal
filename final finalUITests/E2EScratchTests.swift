//
//  E2EScratchTests.swift
//  final finalUITests
//
//  DISPOSABLE e2e DIAGNOSTIC test for bib-heading-false-positive (a fresh diagnostic round
//  after the marker/terminator two-tier fix already shipped -- see BibliographyOpeningSelector
//  .swift's doc comment for that fix's own mechanics). The user re-tested by hand and reported
//  reproducing "the same bug as before": the bibliography regenerates in the wrong place
//  (mid-document, where an old/damaged heading used to be) instead of at the end, via this
//  literal repro: open a document with a real bibliography, Source Mode, drag-select-delete
//  the whole visible bibliography section, back to normal mode, add a citation.
//
//  RULED OUT before this file was written: the closing terminator's delete-protection
//  (`web/codemirror/src/anchor-plugin.ts`'s `isBibliographyEndMarkerAdjacent`) explicitly only
//  guards a COLLAPSED cursor, never a range/drag selection -- so the terminator does NOT
//  survive a drag-delete as a leftover orphan. It has no bearing on this bug.
//
//  HYPOTHESIS under test here: the OPENING marker (`<!-- ::auto-bibliography:: -->`) is a
//  hidden, atomic CodeMirror decoration glued directly onto the SAME LINE as its heading with
//  zero separator (`<!-- ::auto-bibliography:: --># Bibliography` -- confirmed by
//  `SectionSyncService+Anchors.swift`'s `injectBibliographyMarker`, `result.insert(contentsOf:
//  marker, at: lineRanges[index].lowerBound)`, and by anchor-plugin.ts's own header comment).
//  It has NO delete-protection at all. A real user's drag-selection start point is imprecise --
//  landing not at the exact atomic-range boundary but a few characters INTO the visible heading
//  text -- deletes that prefix along with everything through the entries, leaving the marker
//  glued to a STRAY FRAGMENT (e.g. "# B") that is NOT a real heading and NOT a title-candidate
//  match. `BibliographyOpeningSelector.markerIsSupported` (BibliographyOpeningSelector.swift)
//  treats "not `isStandaloneMarker`" (the unit's content isn't EXACTLY the bare marker literal)
//  as sufficient evidence the marker is "glued to a real heading" -- confirmed by static read of
//  that function: `guard units[index].isStandaloneMarker else { return true }` returns
//  UNCONDITIONALLY true the moment the marker isn't perfectly bare, without ever checking
//  whether the glued content is actually a valid heading/candidate. This file exists to prove
//  (or disprove) that a real drag-shaped deletion in the real running app produces exactly this
//  shape, and to show where the next citation's regenerated bibliography actually lands as a
//  result.
//
//  METHOD CHOSEN, AND WHY -- keyboard-only deterministic navigation, NOT a mouse drag: this
//  suite has zero precedent anywhere for a CodeMirror source-mode mouse drag-selection (checked
//  before writing this file), and WKWebView/CodeMirror content is not reliably queryable for
//  per-character pixel geometry via XCUITest's accessibility tree (only whole-line label/value
//  CONTAINS matching is proven, per `UnifiedUndoE2ETests+Helpers.swift`'s `switchToSourceMode`
//  mount-completion gate) -- guessing pixel coordinates for a drag start/end would be unverified
//  geometry with a high flake risk and this diagnostic round's ceiling has no budget to fight
//  that. Instead, the exact interaction CodeMirror's own atomic-range mechanics produce for an
//  imprecise click is reproduced deterministically via keyboard: Cmd-Up (document start), N
//  plain Down-arrows to reach column 0 of the marker+heading's own line (still BEFORE the
//  atomic marker, which occupies that same visual column), one plain Right-arrow (CodeMirror's
//  atomic-range mechanism skips the ENTIRE hidden marker in that one keystroke, landing right
//  AFTER it, before the visible "#"), then a few more plain Right-arrows to land a few
//  characters INTO the visible heading text -- exactly the position an imprecise real mouse
//  click would produce, deterministically and with no pixel guessing. From there, Shift-Cmd-Down
//  (select to document end -- the bibliography is the last content, matching "drag to just past
//  the last visible character of the last citation entry" from the task's literal repro) extends
//  the selection through the rest of the heading, the entry, and the terminator, then Delete
//  removes it all in one shot -- exactly the shape of a real drag-select-delete, just driven by
//  keyboard instead of mouse coordinates.
//
//  SEEDING -- a short document (one ordinary chapter, then a real marker+terminator-bounded
//  bibliography with one entry) is seeded directly into `content.markdown` before the first
//  launch, then reparsed by a genuine first-launch `BlockParser.parse()` pass (matching this
//  file's own prior established convention -- see git history for
//  `testEarlyBareTitleHeadingSurvivesGenerationRegenerationAndDeletion`, which used the same
//  seed-then-real-parse approach and documented why it counts as "real" rather than
//  hand-inserted). This produces a REAL, flagged bibliography baseline without needing to first
//  drive the Zotero CAYW mock once just to create it.
//
//  Verification: raw `content.markdown` read directly from the fixture's SQLite DB (ground
//  truth for exactly what CodeMirror wrote back), captured BEFORE any new citation is added
//  (per the task's requirement), plus a `block` table dump for the same moment, plus both
//  again after a new citation is added via the Zotero CAYW mock (Cmd-Shift-K) to see where
//  regeneration actually placed the new bibliography.
//

import XCTest

final class E2EScratchTests: XCTestCase {
    var app: XCUIApplication!

    private static let mockEntrySurname = "Ffmocksurname"

    /// One ordinary chapter, then a REAL marker+terminator-bounded bibliography (one entry).
    /// The marker is glued directly onto the heading line with no separator, matching
    /// `injectBibliographyMarker`'s actual production insertion mechanics (see file header).
    private static let seedMarkdown = """
    # Chapter One

    Some intro content for chapter one that must survive untouched.

    <!-- ::auto-bibliography:: --># Bibliography

    Seed 2020 A Pre-Existing Bibliography Entry.

    <!-- ::auto-bibliography-end:: -->
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

    func testImpreciseSourceModeDeletionLeavesStrayFragmentGluedToOpeningMarker() throws {
        // MARK: 0. Seed the baseline document (app not yet launched against this fixture copy)

        FixtureDatabase.write(fixturePath: TestFixtureHelper.fixturePath, sql: "DELETE FROM block;")
        FixtureDatabase.write(
            fixturePath: TestFixtureHelper.fixturePath,
            sql: "UPDATE content SET markdown = '\(FixtureDatabase.escape(Self.seedMarkdown))';"
        )

        // MARK: 1. First launch -- real "no blocks yet" parse establishes the healthy baseline.
        // Zotero mock enabled for the whole run so step 5 below can add a real citation.

        app.launchEnvironment["FF_UI_TESTING_ZOTERO_MOCK"] = "1"
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear with seeded content")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
        Thread.sleep(forTimeInterval: 1.5)

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("00-baseline-loaded.png"))

        // Sanity: the real, marker-carrying bibliography is flagged at baseline.
        XCTAssertTrue(
            Self.isBibliographyFlagged(fixturePath: TestFixtureHelper.fixturePath, textContains: "Seed 2020"),
            "Sanity: the pre-seeded, marker-carrying bibliography entry should be flagged bibliography at baseline"
        )

        // MARK: 2. Switch to Source Mode -- retry-toggle + mount-completion gate, matching
        // `UnifiedUndoE2ETests+Helpers.switchToSourceMode`'s established, proven pattern.

        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")
        var toggledToSource = false
        for _ in 1...5 {
            if editorMode.label == "Source" { toggledToSource = true; break }
            app.activateAndWaitForForeground()
            clickIntoEditor()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Source'", timeout: 2) { toggledToSource = true; break }
        }
        XCTAssertTrue(toggledToSource, "Editor-mode button should report Source after retrying the toggle keystroke")

        let sourceEvidence = editorArea.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '# Bibliography' OR value CONTAINS '# Bibliography'")
        ).firstMatch
        XCTAssertTrue(
            sourceEvidence.waitForExistence(timeout: 10),
            "CodeMirror source editor should render the raw heading text after toggling, not just flip the status-bar label"
        )
        Thread.sleep(forTimeInterval: 1.0)

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("01-source-mode-before-delete.png"))

        // MARK: 3. Keyboard-only imprecise "drag-select-delete" of the bibliography section --
        // see file header "METHOD CHOSEN, AND WHY" for the full reasoning.
        //
        // Seed document's source-mode line layout (marker is hidden/atomic, so it renders
        // as if absent from the visible line):
        //   line 1: # Chapter One
        //   line 2: (blank)
        //   line 3: Some intro content for chapter one that must survive untouched.
        //   line 4: (blank)
        //   line 5: # Bibliography            <- marker glued here, hidden
        //   line 6: (blank)
        //   line 7: Seed 2020 A Pre-Existing Bibliography Entry.
        //   line 8: (blank)
        //   line 9: (blank, the end-terminator's line -- fully hidden/atomic)

        clickIntoEditor()
        app.activateAndWaitForForeground()
        app.typeKey(.upArrow, modifierFlags: .command) // jump to document start
        for _ in 0..<4 {
            app.typeKey(.downArrow, modifierFlags: []) // land at column 0 of line 5 (before the hidden marker)
        }
        app.typeKey(.rightArrow, modifierFlags: []) // skip the ENTIRE atomic opening marker in one keystroke
        for _ in 0..<4 {
            // Land a few characters INTO the visible heading text ("# Bi" consumed) --
            // exactly what an imprecise real mouse click would produce: past the hidden
            // marker, but not at the true visible start of the heading either.
            app.typeKey(.rightArrow, modifierFlags: [])
        }
        app.typeKey(.downArrow, modifierFlags: [.shift, .command]) // extend selection to document end

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("02-selection-extended.png"))

        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

        // Let the push-based content sync / 3s fallback poll settle and write back to
        // `content.markdown`, matching this suite's established ~4s convention.
        Thread.sleep(forTimeInterval: 4.0)

        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("03-after-deletion.png"))

        // MARK: 4. THE CRITICAL EVIDENCE -- raw content.markdown, captured BEFORE any new
        // citation is added, exactly as it was written back by CodeMirror's own sync.

        let rawAfterDeletion = Self.queryContentMarkdown(fixturePath: TestFixtureHelper.fixturePath)
        let blocksAfterDeletion = Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2EScratchTests] DIAGNOSTIC raw content.markdown after Source Mode deletion:\n---\n\(rawAfterDeletion)\n---")
        print("[E2EScratchTests] DIAGNOSTIC block table after Source Mode deletion:\n\(blocksAfterDeletion.joined(separator: "\n---\n"))")

        let leftoverMarkerRange = rawAfterDeletion.range(of: "<!-- ::auto-bibliography:: -->")
        let strayFragmentAfterMarker: String = {
            guard let markerRange = leftoverMarkerRange else { return "<no leftover marker found>" }
            let afterMarker = rawAfterDeletion[markerRange.upperBound...]
            let lineEnd = afterMarker.firstIndex(of: "\n") ?? afterMarker.endIndex
            return String(afterMarker[afterMarker.startIndex..<lineEnd])
        }()

        // Deliberately fails LOUDLY with the full raw text as evidence whenever a leftover
        // opening marker survives glued to non-empty content that is NOT a bare marker and NOT
        // a real "# Bibliography"/"# References" heading match -- this is the exact damaged
        // shape the hypothesis predicts. A clean pass here (no leftover marker, or a marker
        // cleanly glued to a genuine surviving heading) would REFUTE the hypothesis instead.
        let isBareMarkerLiteral = rawAfterDeletion.trimmingCharacters(in: .whitespacesAndNewlines) == "<!-- ::auto-bibliography:: -->"
            || strayFragmentAfterMarker.trimmingCharacters(in: .whitespaces).isEmpty
        let strayFragmentLooksLikeRealHeading = strayFragmentAfterMarker.trimmingCharacters(in: .whitespaces) == "# Bibliography"
            || strayFragmentAfterMarker.trimmingCharacters(in: .whitespaces) == "# References"

        XCTAssertTrue(
            leftoverMarkerRange == nil || isBareMarkerLiteral || strayFragmentLooksLikeRealHeading,
            """
            CONFIRMED: opening marker survived the delete, glued to a STRAY FRAGMENT that is \
            NEITHER an empty/bare marker NOR a real heading match: "\(strayFragmentAfterMarker)". \
            Full raw content.markdown after deletion:
            ---
            \(rawAfterDeletion)
            ---
            Full block table after deletion:
            \(blocksAfterDeletion.joined(separator: "\n---\n"))
            """
        )

        // MARK: 5. Switch back to normal mode, add a new citation via the Zotero CAYW mock --
        // matching the task's literal repro ("switch back to normal mode, add a citation").

        var toggledToWysiwyg = false
        for _ in 1...5 {
            if editorMode.label == "WYSIWYG" { toggledToWysiwyg = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'WYSIWYG'", timeout: 2) { toggledToWysiwyg = true; break }
        }
        XCTAssertTrue(toggledToWysiwyg, "Editor-mode button should report WYSIWYG after switching back")
        Thread.sleep(forTimeInterval: 2.0)

        clickIntoEditor()
        app.activateAndWaitForForeground()
        app.typeKey("k", modifierFlags: [.command, .shift])

        let landed = waitUntil(timeout: 15) {
            Self.blockExists(fixturePath: TestFixtureHelper.fixturePath, textContains: Self.mockEntrySurname)
        }

        Thread.sleep(forTimeInterval: 1.5) // let any further sync settle before reading
        try? app.screenshot().pngRepresentation.write(to: E2EShotDir.url.appendingPathComponent("04-after-new-citation.png"))

        let rawAfterNewCitation = Self.queryContentMarkdown(fixturePath: TestFixtureHelper.fixturePath)
        let blocksAfterNewCitation = Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2EScratchTests] DIAGNOSTIC raw content.markdown after new citation:\n---\n\(rawAfterNewCitation)\n---")
        print("[E2EScratchTests] DIAGNOSTIC block table after new citation:\n\(blocksAfterNewCitation.joined(separator: "\n---\n"))")

        XCTAssertTrue(
            landed,
            """
            New citation via Zotero CAYW mock never landed within 15s. \
            Raw content.markdown at this point:
            ---
            \(rawAfterNewCitation)
            ---
            Block table at this point:
            \(blocksAfterNewCitation.joined(separator: "\n---\n"))
            """
        )

        // Final diagnostic (always fails, deliberately -- see class-level note below): surfaces
        // exactly where the regenerated bibliography landed relative to "Chapter One" and any
        // leftover stray fragment, for the report this file exists to produce.
        XCTFail(
            """
            DIAGNOSTIC DUMP (not a real failure -- this assertion always fires so the evidence \
            reaches the test report):
            Raw content.markdown immediately after the Source-Mode deletion (before the new citation):
            ---
            \(rawAfterDeletion)
            ---
            Raw content.markdown after the new citation was added:
            ---
            \(rawAfterNewCitation)
            ---
            Block table after the new citation was added:
            \(blocksAfterNewCitation.joined(separator: "\n---\n"))
            """
        )
    }

    // MARK: - Local helpers

    private func clickIntoEditor() {
        app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
    }

    /// Bounded poll on DB ground truth. Matches this file's own prior established pattern.
    private func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.25, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: poll)
        } while Date() < deadline
        return predicate()
    }

    // MARK: - DB query helpers (read-only; safe to run while the app is open -- WAL mode,
    // matching E2ESectionReconcilerPseudoSectionTests.swift/FixtureDatabase's own doc comment)

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

    /// The full saved document (`content.markdown`), with embedded newlines made visible as
    /// literal "\n" so a single-row sqlite3 stdout read can't be misread as multiple lines.
    private static func queryContentMarkdown(fixturePath: String) -> String {
        let sentinel = "###ROWEND###"
        let sql = "SELECT replace(markdown, char(10), '\\n') || '\(sentinel)' FROM content;"
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: sql)
        let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
        return rows.first ?? "<no content row>"
    }

    /// Every block row in document order: sortOrder, blockType, isBibliography, textContent,
    /// markdownFragment (newlines made visible as literal "\n").
    private static func queryAllBlocks(fixturePath: String) -> [String] {
        let sentinel = "###ROWEND###"
        let sql = "SELECT sortOrder || '|' || blockType || '|' || isBibliography || '|' || " +
            "replace(textContent, char(10), '\\n') || '|' || replace(markdownFragment, char(10), '\\n') || " +
            "'\(sentinel)' FROM block ORDER BY sortOrder;"
        let stdout = FixtureDatabase.read(fixturePath: fixturePath, sql: sql)
        return stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
    }
}
