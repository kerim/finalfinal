//
//  E2ESectionReconcilerPseudoSectionTests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the SectionReconciler pseudo-section
//  identity-theft fix (sectionreconciler-tier3-pseudosection-gate).
//
//  Bug being verified (see final final/Services/SectionReconciler.swift's own
//  doc comments for the authoritative mechanics): section breaks
//  (`<!-- ::break:: -->` markers) get an auto-generated title derived from the
//  first paragraph that follows them. When a break is immediately followed by
//  something that ISN'T a paragraph (a bullet list, in this scenario), there is
//  no paragraph to excerpt, so the title collapses to the generic literal
//  "§ Section Break". Two or three section breaks in the same document
//  routinely share this exact title. Before this fix, SectionReconciler's
//  Tier 3 (closest-position-within-±3) matching could use that shared title as
//  admission evidence (or fall back to pure position proximity once titles tied
//  three ways), so a live edit that removed some breaks and extended another
//  could match the surviving content to the WRONG pre-existing database row
//  purely because it happened to sit closer to the new position -- silently
//  handing that row's status/tags/word-goal metadata to content that never
//  belonged to it, while hard-deleting the row that was the real origin of that
//  content (SectionReconciler.reconcile()'s "unmatched DB sections were
//  deleted" pass, which has no way to know a match was wrong). The fix makes
//  pseudo-sections match by CONTENT only (never by title alone -- see
//  `passesMatchGate`'s pseudo-section branch and Tier 3's `related`
//  content-gated candidate set), using title only as a last-resort tiebreak
//  among otherwise-equal candidates.
//
//  This is covered extensively by ~15 unit tests already (SectionReconcilerTests.swift,
//  SectionReconcilerPseudoSectionTests.swift). This file proves the same fix
//  end-to-end through the REAL running app: a real document with three
//  identically-titled section-break cards, a real sync cycle, and a real
//  single-paste edit that collapses three breaks into one -- read back via the
//  actual persisted `section` DB rows, not a synthetic reconcile() call.
//
//  Construction mechanism -- why status is set via SQL, not the sidebar UI:
//  the manual repro this file follows calls for setting a distinct status on
//  each of the three section-break cards via the sidebar before the edit. That
//  step turned out NOT to be reliably automatable via XCUITest, for reasons
//  specific to this codebase (not a general XCUITest limitation):
//    1. final final/Views/Sidebar/SectionCardView.swift and StatusBadge.swift
//       carry NO accessibility identifiers anywhere -- `grep -rn
//       accessibilityIdentifier final final/Views/Sidebar/` returns zero
//       matches. The only identified element anywhere near the sidebar is the
//       single container "outline-sidebar" (ContentView.swift).
//    2. The real sidebar renders each card via DraggableCardView.swift, which
//       wraps SectionCardView in a PassthroughHostingView whose `hitTest`
//       override returns `nil` for EVERY plain left-click (only right-click
//       and ctrl-click fall through to SwiftUI). That means a plain left
//       click anywhere on a card -- including directly on the StatusBadge --
//       is captured entirely by the wrapping DraggableNSView (select/drag
//       handling), never reaching StatusBadge's own `onTapGesture`
//       "cycle status" or `onLongPressGesture` "show menu" handlers. The ONLY
//       mechanism that actually reaches the status menu in the real sidebar is
//       right-click / ctrl-click, via StatusMenuTrigger's NSEvent local
//       monitor (which bypasses normal hit-testing by design).
//    3. Even with right-click established as the only working path, this
//       scenario's three cards render IDENTICAL title text ("§ Section
//       Break") and (initially) identical default status text ("Next"), and
//       none of them have a usable identifier or container to disambiguate.
//       Right-clicking "the second card's status badge" specifically would
//       require reconstructing its on-screen rectangle from raw, unverified
//       geometry (row height, badge width, right-alignment padding) with zero
//       precedent anywhere in this suite -- exactly the kind of unverified
//       interaction NestedListE2ETests.swift's own header explicitly
//       documents choosing to avoid in favor of doctoring the fixture instead
//       ("Rather than keep reasoning about exact position arithmetic for an
//       unverified interaction, this version sidesteps it entirely").
//  This file follows that same established precedent: it lets the REAL sync
//  pipeline create the three pseudo-section rows from seeded markdown (see
//  below), then sets each row's `status` column via
//  the exact same raw SQL form (`status.rawValue`) that
//  DocumentManager.updateSectionStatus() uses when a user really does pick a
//  status from the sidebar's right-click menu (confirmed by reading
//  Database+Sections.swift -- that path writes `status.rawValue` directly,
//  e.g. "final_" with the trailing underscore, NOT the "final" string
//  Section's own Codable/JSON encode uses elsewhere). The DB end-state this
//  step produces is therefore byte-identical to what that real, if
//  unautomatable, interaction would write. The doctoring always happens with
//  the app terminated (never against a live-held SQLite connection), matching
//  NestedListE2ETests.swift/HrTypedConversionE2ETests.swift's own
//  doctorFixture() convention.
//
//  The INITIAL document content (heading + three breaks, each followed by a
//  bullet list) is ALSO seeded via a raw content.markdown UPDATE rather than
//  live-typed/slash-commanded, for the same reason: there is no precedent
//  anywhere in this suite for driving Milkdown's `/break` slash-command menu
//  via XCUITest, and getting the exact keystroke-to-menu-selection sequence
//  wrong would silently produce a document that doesn't reproduce the bug
//  scenario at all. What matters for this fix is the RECONCILIATION behavior
//  once those rows exist, not how the rows were typed -- and the initial
//  sync that turns seeded markdown into real `section` rows (ContentView.swift's
//  `sectionSyncService.syncNow(fullContent)`, called once when a project opens)
//  is the exact same insert path a live-typed document would go through.
//
//  Trigger mechanism -- why Source Mode, and why ONE paste: the actual edit
//  (delete breaks 1 & 2, extend break 3's list) IS driven live, for real, in
//  Source Mode -- this is the part that genuinely tests SectionReconciler.
//  Source Mode is required (not optional) because literal `<!-- ::break:: -->`
//  text only becomes a real section boundary when the app re-parses it as raw
//  markdown source; WYSIWYG has no live typed-conversion for it (unlike "---"
//  for horizontal rules, see HrTypedConversionE2ETests.swift). The whole
//  replacement is sent as ONE paste (select-all, then a single Cmd+V of the
//  complete new document) rather than several incremental edits, so
//  SectionSyncService's debounce coalesces it into a SINGLE reconcile() call
//  that sees one incoming pseudo-section header against three stale,
//  identically-titled DB rows simultaneously -- the exact shape the bug
//  required. Several separate smaller edits could each resolve unambiguously
//  on their own and never exercise the three-way tie at all.
//
//  KNOWN RISK, disclosed rather than hidden: EditorSmokeTests.swift and
//  ListNumberingE2ETests.swift both document that the Source Mode toggle's
//  accessibility LABEL flips to "Source" before the WYSIWYG->CodeMirror view
//  swap's async cursor-save callback chain necessarily finishes. This file's
//  mitigation is (a) a generous settle wait after the toggle, (b) an explicit
//  click into the editor pane before Cmd+A/Cmd+V (focuses whichever editor is
//  actually showing), and (c) the "verify the status-bar word count actually
//  changed, retry the paste once if it did not" guard in step 3 below -- not
//  a guarantee. If the paste genuinely lands in the wrong editor, the
//  assertions below fail loudly with a diagnostic DB dump, rather than passing
//  vacuously.
//
//  Verification mechanism: DB read (ground truth -- proves exactly which row
//  survived and what status it carries), PLUS a relaunch-and-reopen check
//  proving the surviving row is a real persisted round trip, not an
//  in-memory artifact of the current session.
//
//  KEPT AS A PERMANENT REGRESSION TEST (not deleted as disposable
//  scaffolding, per this repo's e2e-verify skill's "keep only if it
//  exercises a real runtime path no unit test can reach" bar): this test
//  drives the REAL Milkdown WebView's whole-document markdown
//  re-serialization on load and on Source-Mode round trip. During this
//  fix's development, that real serialization step reformatted seeded
//  markdown in ways no unit test could see (bullet marker character
//  changed from "-" to "*", and tight lists loosened with a blank line
//  between every item) -- which was enough to defeat an earlier version of
//  this fix's content-matching despite 34/34 passing unit tests. This file
//  is what caught that gap. Screenshot/diagnostic-file writes to the
//  superdev run-notes folder (deleted at wrap-up) were removed before
//  keeping this file permanently.
//

import AppKit
import XCTest

final class E2ESectionReconcilerPseudoSectionTests: XCTestCase {
    var app: XCUIApplication!

    /// Seed document: one real heading (so Tier 1's exact-position match has a
    /// stable, unambiguous anchor to isolate the pseudo-section behavior from
    /// unrelated noise) followed by three section breaks, each immediately
    /// followed by a bullet list (no intervening paragraph) so ALL THREE
    /// collapse to the generic "§ Section Break" title per
    /// `extractPseudoSectionTitle` (SectionSyncService+Parsing.swift) --
    /// lines starting with "-" are explicitly skipped when hunting for
    /// title-worthy paragraph text.
    private static let seedMarkdown = """
## A

Intro paragraph for section A.

<!-- ::break:: -->
- alpha one

<!-- ::break:: -->
- beta one

<!-- ::break:: -->
- gamma one
- gamma two
"""

    /// Replacement document pasted in ONE shot: breaks 1 & 2 (and their
    /// bullet lists) are gone; break 3's list is extended with a new item.
    /// Section "A" is left byte-identical so its own Tier 1 match is never in
    /// question -- isolates the assertion to the pseudo-section behavior.
    private static let replacementMarkdown = """
## A

Intro paragraph for section A.

<!-- ::break:: -->
- gamma one
- gamma two
- gamma three
"""

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)

        // Record where the persistent diagnostic log currently ends, so
        // later reads only see lines THIS run produced (never truncates or
        // deletes the real, shared log -- see the diagnostic log helpers at
        // the bottom of this file).
        Self.recordDiagnosticLogStartOffsets()

        // Turn on persistent diagnostic logging via the NSUserDefaults
        // launch-argument domain, so SectionReconciler's `.sync`-category "Deleted id=... order=...
        // pseudo=... status=..." line -- emitted for every unmatched DB row the
        // reconciler hard-deletes -- actually reaches the on-disk file this test
        // can read from the XCUITest runner process, independent of whichever
        // DEBUG-console category set happens to be compiled in.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testSurvivingPseudoSectionKeepsOwnStatusNotNeighbors() throws {
        // MARK: 1. Seed three identically-titled pseudo-sections via a real sync

        try Self.replaceContentMarkdown(at: TestFixtureHelper.fixturePath, markdown: Self.seedMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear with seeded content")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")

        // Let the real project-open sync (ContentView.swift's
        // `sectionSyncService.syncNow(fullContent)`, called once when a
        // project opens) populate real `section` rows from the seeded
        // markdown via the actual SectionReconciler INSERT path.
        Thread.sleep(forTimeInterval: 2.0)

        let baselineRows = try Self.queryPseudoSections(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2ESectionReconcilerPseudoSectionTests] DIAGNOSTIC baseline pseudo-sections:\n\(baselineRows.joined(separator: "\n---\n"))")
        XCTAssertEqual(baselineRows.count, 3, "Seed should produce exactly 3 pseudo-sections sharing the generic title. Got: \(baselineRows)")

        let break1Id = try Self.querySingleId(fixturePath: TestFixtureHelper.fixturePath, contentContains: "alpha one")
        let break2Id = try Self.querySingleId(fixturePath: TestFixtureHelper.fixturePath, contentContains: "beta one")
        let break3Id = try Self.querySingleId(fixturePath: TestFixtureHelper.fixturePath, contentContains: "gamma one")
        XCTAssertNotEqual(break1Id, break3Id, "Sanity: break 1 and break 3 must be different DB rows before any edit")
        XCTAssertNotEqual(break2Id, break3Id, "Sanity: break 2 and break 3 must be different DB rows before any edit")

        // MARK: 2. Set a distinct status per identically-titled card (via SQL -- see file header)

        app.terminate() // never write to the fixture DB while the app holds it open
        try Self.setStatus(fixturePath: TestFixtureHelper.fixturePath, id: break1Id, status: "writing")
        try Self.setStatus(fixturePath: TestFixtureHelper.fixturePath, id: break2Id, status: "review")
        try Self.setStatus(fixturePath: TestFixtureHelper.fixturePath, id: break3Id, status: "final_")

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        let editorAreaAfterRestatus = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterRestatus.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")
        let wordCountAfterRestatus = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCountAfterRestatus.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count after relaunch")
        // Let the sidebar populate SectionViewModels from the doctored DB.
        Thread.sleep(forTimeInterval: 1.5)
        let initialWordCountValue = (wordCountAfterRestatus.value as? String) ?? ""

        // Sanity DB check (not a UI assertion -- see file header for why the
        // sidebar's own rendered status badges aren't asserted on
        // programmatically): confirms the doctoring above really landed
        // before it's relied on as the "before" state.
        let preEditStatuses = try Self.queryStatuses(fixturePath: TestFixtureHelper.fixturePath, ids: [break1Id, break2Id, break3Id])
        XCTAssertEqual(
            preEditStatuses, ["writing", "review", "final_"],
            "Doctored statuses should be in place before the edit. Got: \(preEditStatuses)"
        )

        // DIAGNOSTIC (coordinator-requested, 2026-07-27 failure investigation):
        // full byte-exact state of ALL THREE break rows -- sortOrder, title,
        // status, id, and markdownContent with embedded newlines made visible
        // -- captured immediately BEFORE the one-shot paste. This is the exact
        // starting state SectionReconciler.reconcile() will actually operate
        // on for the upcoming edit, as opposed to what the seed markdown was
        // INTENDED to produce. If the real pipeline (Milkdown round-trip
        // serialization at load, or the initial sync's own re-save) altered
        // whitespace/newlines relative to the raw seed, it will show up here.
        let fullPreEditDump = try Self.queryFullDetails(fixturePath: TestFixtureHelper.fixturePath, ids: [break1Id, break2Id, break3Id])
        print("[E2ESectionReconcilerPseudoSectionTests] DIAGNOSTIC pre-edit full row detail:\n\(fullPreEditDump.joined(separator: "\n---\n"))")

        // MARK: 3. Toggle to Source Mode and replace the WHOLE document in ONE paste

        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")
        app.activateAndWaitForForeground()
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(editorMode.waitForLabel("== 'Source'", timeout: 10), "Editor-mode button should report Source")

        // KNOWN RISK (see file header "Trigger mechanism"): the label flips
        // before the async WYSIWYG->CodeMirror view swap necessarily
        // finishes. Generous settle wait as mitigation, not a guarantee.
        Thread.sleep(forTimeInterval: 2.5)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.replacementMarkdown, forType: .string)

        func selectAllAndPasteReplacement() {
            editorAreaAfterRestatus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
            app.activateAndWaitForForeground()
            app.typeKey("a", modifierFlags: .command) // select all existing content
            app.typeKey("v", modifierFlags: .command) // replace with the new document, in one shot
        }
        selectAllAndPasteReplacement()

        let escapedInitial = initialWordCountValue.replacingOccurrences(of: "'", with: "\\'")
        var pasteLanded = wordCountAfterRestatus.waitForValue("!= '\(escapedInitial)'", timeout: 5)
        if !pasteLanded {
            selectAllAndPasteReplacement()
            pasteLanded = wordCountAfterRestatus.waitForValue("!= '\(escapedInitial)'", timeout: 15)
        }
        XCTAssertTrue(pasteLanded, "Word count never changed after the replacement paste -- it likely never reached the editor")

        // Let SectionSyncService's 500ms debounce (on top of the editor's own
        // content-polling bridge to Swift) settle and write the reconciled
        // `section` rows -- generous margin, matching this suite's
        // established ~4s convention for this class of async settle.
        Thread.sleep(forTimeInterval: 4.0)

        // DIAGNOSTIC (kept for future debugging): the real reconciler's own
        // "[sync] [SectionReconciler] Deleted id=... order=... pseudo=...
        // status=..." line (SectionReconciler.swift's reconcile(), emitted for
        // every unmatched DB row it hard-deletes) -- hard evidence of exactly
        // which two rows the REAL reconcile() call deleted and what it
        // believed their sortOrder/status were at the moment of deletion.
        let reconcilerLogLines = Self.currentDiagnosticLogContents()
            .split(separator: "\n")
            .filter { $0.contains("[sync]") }
        print("[E2ESectionReconcilerPseudoSectionTests] DIAGNOSTIC [sync] log lines this run:\n\(reconcilerLogLines.joined(separator: "\n"))")

        // MARK: 4. THE ACTUAL PROOF

        // Exactly one non-bibliography/notes pseudo-section should remain, it
        // should be break 3's OWN database row (not break 1's), and it should
        // carry break 3's OWN status (Final). Pre-fix, a pure
        // proximity+title-tiebreak Tier 3 match would instead have picked
        // break 1's row (closest by position to the new content's slot, title
        // tied three ways) -- surviving with break 1's "writing" / Writing
        // status while carrying break 3's real content, with break 2 AND the
        // real break-3 row both hard-deleted as "unmatched".
        let survivors = try Self.queryPseudoSections(fixturePath: TestFixtureHelper.fixturePath)
        print("[E2ESectionReconcilerPseudoSectionTests] DIAGNOSTIC pseudo-sections after edit:\n\(survivors.joined(separator: "\n---\n"))")
        XCTAssertEqual(survivors.count, 1, "Exactly one pseudo-section should survive the merge. Got: \(survivors)")

        let survivorId = try Self.querySingleId(fixturePath: TestFixtureHelper.fixturePath, contentContains: "gamma three")
        XCTAssertEqual(
            survivorId, break3Id,
            "BUG: the surviving row should be break 3's OWN database row (id \(break3Id)), " +
            "not a different row. Got id \(survivorId). All pseudo-sections: \(survivors)"
        )

        // Expected raw DB value is "final" here, NOT "final_", despite the row
        // having been SEEDED as "final_" earlier in this test (see MARK: 2).
        // Confirmed by reading the actual code path (not assumed):
        //   - setStatus() seeds via raw SQL (`UPDATE section SET status = 'final_'`),
        //     matching DocumentManager.updateSectionStatus()'s real write path
        //     (`arguments: [status.rawValue, ...]` -- Section.swift's
        //     SectionStatus enum has no explicit per-case raw string literals, so
        //     Swift auto-synthesizes .final_'s rawValue as the case name itself,
        //     "final_", underscore included).
        //   - The one-shot edit's reconcile() call matches and UPDATES break 3's
        //     row via SectionReconciler.swift's applySectionChanges() ->
        //     `try section.update(db)` (Database+Sections.swift). Section has no
        //     custom `encode(to container: inout PersistenceContainer)`, so GRDB's
        //     plain (non-`updateChanges`) `update(_:)` always rewrites EVERY
        //     column of the row from the record's current Codable-bridged encode
        //     -- including `status`, regardless of whether SectionUpdates (which
        //     has no status field at all) touched it.
        //   - Section.encode(to encoder:) calls `container.encode(status, ...)`,
        //     which invokes SectionStatus's own custom `encode(to encoder:)`
        //     (Section.swift): `case .final_: try container.encode("final")` --
        //     deliberately dropping the trailing underscore to avoid the `final`
        //     reserved-word collision in Codable/JSON contexts. That custom
        //     mapping is asymmetric with the raw-SQL write path above, which uses
        //     the literal `rawValue` ("final_") instead.
        //   - Net effect: ANY row a reconcile() change actually inserts or
        //     updates has its "final_" status silently rewritten to "final" as a
        //     byproduct, purely because it passed through Section's Codable
        //     round-trip -- independent of this fix, already flagged and judged
        //     noise/pre-existing by an earlier code review (finding F14).
        // This does NOT weaken what this assertion actually proves: pre-fix, the
        // wrong survivor (break 1) would show status "writing" here regardless
        // (`.writing`'s rawValue and Codable encode are identical -- only
        // `.final_` has this special-cased asymmetry) -- so the comparison below
        // still fails loudly against a pre-fix-shaped result either way. Only
        // break 3's OWN true survival, checked separately above via
        // `survivorId == break3Id`, together with THIS status matching what an
        // update-path write always produces for Final, proves the metadata
        // wasn't stolen from -- or handed to -- the wrong row.
        let survivorStatus = try Self.queryStatuses(fixturePath: TestFixtureHelper.fixturePath, ids: [survivorId]).first ?? "<missing>"
        XCTAssertEqual(
            survivorStatus, "final",
            """
            BUG: surviving section should keep its OWN status (Final, stored as "final" post-update -- \
            see comment above), not inherit break 1's ('writing' / Writing) via a stolen match, or lose \
            it to a wrongly-deleted row. Got: \(survivorStatus)
            """
        )

        let survivorContent = try Self.queryMarkdownContent(fixturePath: TestFixtureHelper.fixturePath, id: survivorId)
        XCTAssertTrue(survivorContent.contains("gamma three"), "Survivor should contain the extended list. Got: \(survivorContent)")
        XCTAssertFalse(survivorContent.contains("alpha one"), "Survivor should not contain break 1's deleted content. Got: \(survivorContent)")
        XCTAssertFalse(survivorContent.contains("beta one"), "Survivor should not contain break 2's deleted content. Got: \(survivorContent)")

        // MARK: 5. Relaunch: prove this is a real persisted round trip, not an
        // in-memory artifact of the current session.

        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        let editorAreaAfterReopen = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterReopen.waitForExistence(timeout: 10), "Editor area should reappear after final relaunch")
        Thread.sleep(forTimeInterval: 1.5)
        let survivorAfterReopen = try Self.queryPseudoSections(fixturePath: TestFixtureHelper.fixturePath)
        XCTAssertEqual(survivorAfterReopen.count, 1, "Exactly one pseudo-section should still exist after relaunch. Got: \(survivorAfterReopen)")
    }

    // MARK: - Fixture doctoring (always with the app terminated -- see file header)

    private static func replaceContentMarkdown(at fixturePath: String, markdown: String) throws {
        let dbPath = fixturePath + "/content.sqlite"
        let sql = "UPDATE content SET markdown = '\(sqlEscape(markdown))';"
        try runSqliteWrite(dbPath: dbPath, sql: sql)
    }

    private static func setStatus(fixturePath: String, id: String, status: String) throws {
        let dbPath = fixturePath + "/content.sqlite"
        let sql = "UPDATE section SET status = '\(sqlEscape(status))' WHERE id = '\(sqlEscape(id))';"
        try runSqliteWrite(dbPath: dbPath, sql: sql)
    }

    private static func runSqliteWrite(dbPath: String, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            XCTFail("sqlite3 write failed (status \(process.terminationStatus)): \(stderr)")
        }
    }

    private static func sqlEscape(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - DB query helpers (read-only; safe to run while the app is open,
    // matching NestedListE2ETests.swift/HrTypedConversionE2ETests.swift, which
    // do the same against a live WAL-mode connection)

    private static func runSqliteRead(dbPath: String, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            XCTFail("sqlite3 query failed (status \(process.terminationStatus)): \(stderr)")
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    /// All non-bibliography/non-notes pseudo-section rows, in document order.
    private static func queryPseudoSections(fixturePath: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT id || '|' || status || '|' || markdownContent || '\(sentinel)' " +
            "FROM section WHERE isPseudoSection = 1 AND isBibliography = 0 AND isNotes = 0 " +
            "ORDER BY sortOrder;"
        let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
        return stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
    }

    /// The id of the single pseudo-section whose markdownContent contains `needle`.
    private static func querySingleId(fixturePath: String, contentContains needle: String) throws -> String {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT id || '\(sentinel)' FROM section WHERE isPseudoSection = 1 AND markdownContent LIKE '%\(sqlEscape(needle))%' LIMIT 1;"
        let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
        let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
        guard let id = rows.first else {
            XCTFail("No pseudo-section found containing '\(needle)'")
            return ""
        }
        return id
    }

    private static func queryStatuses(fixturePath: String, ids: [String]) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        return try ids.map { id in
            let sql = "SELECT status || '\(sentinel)' FROM section WHERE id = '\(sqlEscape(id))';"
            let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
            let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
            return rows.first ?? "<missing>"
        }
    }

    private static func queryMarkdownContent(fixturePath: String, id: String) throws -> String {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdownContent || '\(sentinel)' FROM section WHERE id = '\(sqlEscape(id))';"
        let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
        let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
        return rows.first ?? ""
    }

    /// The full saved document (`content.markdown`), for byte-exact comparison
    /// against what a paste/seed was INTENDED to produce.
    private static func queryContentMarkdown(fixturePath: String) throws -> String {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdown || '\(sentinel)' FROM content;"
        let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
        let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
        return rows.first ?? ""
    }

    /// Full byte-exact detail (id, sortOrder, status, title, markdownContent
    /// with newlines made visible as literal "\n") for each id, in the order
    /// given. Diagnostic-only -- lets a human/coordinator see EXACTLY what
    /// SectionReconciler saw as input, rather than what the seed markdown was
    /// intended to produce.
    private static func queryFullDetails(fixturePath: String, ids: [String]) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        return try ids.map { id in
            let sql = "SELECT id || '|' || sortOrder || '|' || status || '|' || title || '|' || " +
                "replace(markdownContent, char(10), '\\n') || '\(sentinel)' " +
                "FROM section WHERE id = '\(sqlEscape(id))';"
            let stdout = try runSqliteRead(dbPath: dbPath, sql: sql)
            let rows = stdout.components(separatedBy: "\(sentinel)\n").filter { !$0.isEmpty }
            return rows.first ?? "<missing: \(id)>"
        }
    }

    // MARK: - Diagnostic log helpers (reads only bytes appended to the persistent
    // DiagnosticLogFile during THIS test run, never truncates/deletes the real
    // shared log)

    private static func diagnosticLogCandidateURLs() -> [URL] {
        let relativePath = "Library/Application Support/com.kerim.final-final/Diagnostics"
        var directories: [URL] = []
        directories.append(
            URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent(relativePath, isDirectory: true)
        )
        directories.append(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.kerim.final-final/Diagnostics", isDirectory: true)
        )
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath, isDirectory: true)
        )
        let fileNames = ["diagnostic.log", "diagnostic.log.1", "diagnostic.log.2"]
        return directories.flatMap { dir in fileNames.map { dir.appendingPathComponent($0) } }
    }

    private static var logStartOffsets: [URL: UInt64] = [:]

    private static func recordDiagnosticLogStartOffsets() {
        logStartOffsets = [:]
        for url in diagnosticLogCandidateURLs() {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
                .flatMap { $0 }?.uint64Value ?? 0
            logStartOffsets[url] = size
        }
    }

    private static func currentDiagnosticLogContents() -> String {
        diagnosticLogCandidateURLs().compactMap { url -> String? in
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: logStartOffsets[url] ?? 0)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n---\n")
    }
}
