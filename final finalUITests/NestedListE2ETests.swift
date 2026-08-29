//
//  NestedListE2ETests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the nested-list-block-sync fix:
//  nested ordered/bullet list numbering used to get destroyed whenever a
//  block CONTAINING a nested sub-list was re-saved for any reason (even an
//  edit completely unrelated to the list, elsewhere in the same block).
//
//  Root mechanism (web/milkdown/src/block-sync-plugin.ts): a list block's
//  markdownFragment is produced by walking each list_item's content via
//  `serializeInlineContent()`. That function's "container node" branch (used
//  for list_item children) only special-cased a fixed set of NESTED_BLOCK_
//  ATOM_TYPES (figure, table, code_block, ...) by delegating them back to the
//  top-level `nodeToMarkdownFragment()` dispatcher, which is the ONLY place
//  that knows how to emit `- `/`1. ` markers and (for ordered_list) the
//  order-attribute-driven start number. `bullet_list`/`ordered_list` were
//  missing from that set, so a nested list found while walking a list_item's
//  children fell through to the generic recursive-inline-serialization path
//  instead -- silently stripping its markers and indentation and merging its
//  text into the parent item's plain continuation lines. The fix adds
//  `bullet_list`/`ordered_list` to NESTED_BLOCK_ATOM_TYPES (so nesting is
//  preserved via a correct recursive delegation) plus an `order`-attribute
//  fix (`${start + index}. ` instead of the old hardcoded `${index + 1}. `)
//  so a nested ordered list's own numbering starts correctly.
//
//  Already unit-tested at the web layer (464/464 vitest tests pass). This
//  file proves the same fix end-to-end through the REAL running app: a real
//  nested-list document, a real unrelated edit elsewhere in the SAME
//  top-level list block, a real flush to the on-disk SQLite database, and a
//  real app termination + relaunch against the SAME already-mutated fixture,
//  proving the persisted block round-trips back into a correctly rendered
//  WYSIWYG document -- not just that the bytes on disk look right.
//
//  Construction mechanism -- IMPORTANT HISTORY: an earlier version of this
//  file built the nested list live, via XCUITest keystrokes (typing "1. "
//  items, then pressing Tab to invoke ProseMirror's `sinkListItem` command --
//  see listItemKeymap in
//  web/node_modules/.pnpm/@milkdown+preset-commonmark@7.18.0/.../list-item.ts,
//  "<Tab>/<Mod-]>: Sink the current list item"). A real run of that version
//  FAILED: the DB showed TWO separate top-level `ordered_list` blocks (one
//  for items 1-3, a SECOND, independently-numbered one for "Nested
//  first"/"Nested second") instead of one block with item 3 containing a
//  nested sub-list. That second block genuinely had `1.`/`2.` markers despite
//  never typing "1. " for it, which means Tab DID invoke some list-wrapping
//  command -- just not the nest-under-item-3 outcome the test needed -- and
//  this exact Tab-driven interaction had no prior precedent anywhere in this
//  UI test suite to validate the assumption against. Rather than keep
//  reasoning about exact ProseMirror position arithmetic for an unverified
//  interaction, this version sidesteps live Tab entirely: it pre-seeds
//  `content.markdown` with correctly-indented nested-list markdown via a raw
//  sqlite3 UPDATE on the fixture copy, BEFORE `app.launch()` -- the exact
//  "doctor the fixture" pattern E2EAsyncImageCorruptionTests.swift already
//  established and documents at length (see that file's `doctorFixture()`).
//  This is not a weaker proof of the fix: the bug this file verifies is
//  specifically about RE-SERIALIZING an already-nested list on an unrelated
//  re-save (block-sync-plugin.ts's live-edit flush path), which doesn't care
//  how the nested list first entered the live ProseMirror document. Parsing
//  nested-list markdown on load is standard CommonMark behavior handled by
//  Milkdown's stock remark-based parser (never the part of the codebase this
//  fix touches), and is verified as a byproduct here anyway via the baseline
//  DB check performed immediately after launch, before any edit.
//
//  Trigger mechanism -- SECOND important correction, found by actually running
//  this test: the first working version of this file used ListNumberingE2ETests.swift's
//  "press Cmd+/ to toggle Source Mode" trick to force a save. That trick calls
//  `flushContentToDatabase()` (final final/ViewState/EditorViewState+Zoom.swift),
//  which is the WRONG path for THIS fix -- it re-serializes the whole document
//  via Milkdown's STOCK `getMarkdown()` (web/milkdown/src/api-modes.ts), then
//  re-parses that markdown STRING from scratch via Swift's `BlockParser.parse()`.
//  That path never calls block-sync-plugin.ts's `getBlockChanges()`/
//  `nodeToMarkdownFragment()` at all -- the exact functions this fix touches --
//  which is why a real run of the Cmd+/-based version of this test kept failing
//  even with the fix applied (confirmed by temporarily reverting the fix and
//  seeing an IDENTICAL failure either way -- proof the Cmd+/ path is fix-blind,
//  not proof the fix is wrong). `flushContentToDatabase()`'s own doc comment
//  confirms this split explicitly: "block-sync-plugin.ts's incremental
//  `detectChanges()` ... This does a full re-parse via `flushContentToDatabase()`
//  INSTEAD". The fix's actual consumer is `BlockSyncService`'s own 2-second
//  polling `Timer` (`pollBlockChangesNow()`/`pollInterval` in
//  final final/Services/BlockSyncService.swift), which calls the JS bridge's
//  `getBlockChanges()` -- the function whose underlying `nodeToMarkdownFragment()`
//  this fix actually changes. So this version does NOT toggle Source Mode at
//  all: after the unrelated edit, it just waits (matching
//  E2EAsyncImageCorruptionTests.swift's `testMidParagraphImageSurvivesLiveEditRoundtrip()`,
//  which verifies this exact same block-sync-plugin.ts incremental-sync code
//  path and uses the identical "edit, then Thread.sleep for the JS debounce +
//  Swift poll, then read the DB" pattern with no Source Mode toggle either).
//
//  Verification mechanism: DB read (fast, precise, proves exact markdown
//  bytes) AND relaunch-and-render (proves the full persist -> reparse ->
//  render round trip, with screenshot evidence for a human reviewer).
//
//  Delete this file once its evidence has been captured -- it is disposable
//  verification scaffolding, not a permanent regression test.
//

import XCTest

final class NestedListE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// Appended verbatim to the fixture's existing content.markdown (via a
    /// raw sqlite3 UPDATE, see `doctorFixture()`). Two leading blank lines
    /// give clean block separation from the fixture's existing trailing
    /// paragraph, matching E2EAsyncImageCorruptionTests.swift's convention.
    /// Item 3 contains a 2-item nested ordered sub-list -- standard CommonMark
    /// indentation, 3 spaces (matching the "3. " marker width) before the
    /// nested "1."/"2." markers.
    private static let twoLevelAppendixMarkdown = """


        1. First item
        2. Second item
        3. Third item
           1. Nested first
           2. Nested second
        """

    /// Same shape, but item 3's nested list has a further-nested 2-item list
    /// under its own second item ("Nested second") -- 3 levels of nesting
    /// total, indented 6 spaces (3 for item 3's own marker width, 3 more for
    /// "Nested second"'s marker width) to catch depth-dependent bugs a naive
    /// single-level fix could still miss.
    private static let threeLevelAppendixMarkdown = """


        1. First item
        2. Second item
        3. Third item
           1. Nested first
           2. Nested second
              1. Deep first
              2. Deep second
        """

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication.targetApp()
        app.terminate()

        // Deliberately do NOT launch here (unlike most files in this suite):
        // each test method seeds DIFFERENT nested-list content into the fresh
        // fixture copy via doctorFixture(), which must run BEFORE app.launch()
        // reads content.markdown -- see E2EAsyncImageCorruptionTests.swift's
        // doctorFixture() for the same ordering requirement.
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Case 1: two-level nesting survives an unrelated re-save

    func testTwoLevelNestedListSurvivesUnrelatedEdit() throws {
        try Self.doctorFixture(at: TestFixtureHelper.fixturePath, appendix: Self.twoLevelAppendixMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear with the doctored fixture's content")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS is ready)")

        // Let the WYSIWYG editor's remark parse settle, and Swift's own
        // synchronous load-time BlockParser populate the `block` table.
        Thread.sleep(forTimeInterval: 1.5)

        // Baseline check BEFORE any edit: confirms the seeded markdown parsed
        // into exactly one ordered_list block with the nested sub-list
        // already correctly embedded -- isolates "seed didn't parse as
        // expected" from "the re-save fix under test broke it".
        let baselineAllBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[NestedListE2ETests] DIAGNOSTIC all blocks at baseline (2-level):\n\(baselineAllBlocks.joined(separator: "\n---\n"))")
        let baselineFragments = try Self.queryBlockMarkdownFragments(fixturePath: TestFixtureHelper.fixturePath, blockType: "ordered_list")
        XCTAssertEqual(
            baselineFragments.count, 1,
            "BUG (test setup, not product): seeded content should parse into exactly one ordered_list block on load. Got: \(baselineFragments). All blocks: \(baselineAllBlocks)"
        )

        let baselineAttachment = XCTAttachment(screenshot: app.screenshot())
        baselineAttachment.name = "two-level-nested-list-initial-render"
        baselineAttachment.lifetime = .keepAlways
        add(baselineAttachment)

        // Unrelated edit elsewhere in the SAME block: click at the START of
        // "First item" (a sibling list item, NOT the nested sub-list) and
        // prepend a word. This forces the whole top-level ordered_list block
        // to be re-serialized without the edit itself touching the nested
        // list at all -- exactly the "re-saved for any reason" scenario the
        // bug required. dx: 0.02 matches ListNumberingE2ETests' proven-precise
        // click-at-start-of-item technique -- that test's own assertions
        // require an exact, uncorrupted split boundary at this same offset.
        let firstItemText = app.staticTexts["First item"]
        XCTAssertTrue(firstItemText.waitForExistence(timeout: 10), "'First item' list item should be visible and reachable via accessibility")
        let startOfFirstItem = firstItemText.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        startOfFirstItem.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("EDITED ")

        let postEditAttachment = XCTAttachment(screenshot: app.screenshot())
        postEditAttachment.name = "two-level-nested-list-after-edit"
        postEditAttachment.lifetime = .keepAlways
        add(postEditAttachment)

        // NO Source Mode toggle here -- see file header "Trigger mechanism"
        // section for why that would exercise the wrong code path. Instead,
        // let the JS-side ~100ms debounce (block-sync-plugin.ts) and Swift's
        // 2s poll (BlockSyncService.pollInterval) both land, with margin --
        // identical wait to E2EAsyncImageCorruptionTests.swift's
        // testMidParagraphImageSurvivesLiveEditRoundtrip(), which exercises
        // this same incremental-sync code path.
        Thread.sleep(forTimeInterval: 4.0)

        let allBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[NestedListE2ETests] DIAGNOSTIC all blocks after edit:\n\(allBlocks.joined(separator: "\n---\n"))")

        let fragments = try Self.queryBlockMarkdownFragments(
            fixturePath: TestFixtureHelper.fixturePath,
            blockType: "ordered_list"
        )

        XCTAssertEqual(
            fragments.count, 1,
            "Expected exactly one ordered_list block (the nested sub-list must stay embedded in the SAME block, not become its own row). Got: \(fragments). All blocks: \(allBlocks)"
        )
        guard let fragment = fragments.first else { return }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(trimmed.contains("EDITED First item"), "Unrelated edit to item 1 should be present. Got: \(trimmed)")
        XCTAssertTrue(trimmed.contains("3. Third item"), "Item 3 should keep its own marker. Got: \(trimmed)")

        // The actual regression proof: the nested list's markers and
        // indentation must survive the unrelated re-save. Pre-fix, this
        // content would have been silently flattened into unmarked,
        // unindented continuation lines of item 3.
        XCTAssertTrue(
            trimmed.contains("\n   1. Nested first"),
            "BUG: nested list should render as an indented '1. Nested first' line (3-space indent matching item 3's '3. ' marker width). Got: \(trimmed). All blocks: \(allBlocks)"
        )
        XCTAssertTrue(
            trimmed.contains("\n   2. Nested second"),
            "BUG: nested list's second item should render as an indented '2. Nested second' line, continuing the nested list's own numbering. Got: \(trimmed). All blocks: \(allBlocks)"
        )

        // Go one step further than the DB read: terminate and relaunch
        // against the SAME (already-mutated) fixture path, proving the
        // persisted block rows round-trip back into a correctly rendered
        // WYSIWYG document, not just that the bytes on disk look right.
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorAreaAfterReopen = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterReopen.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")

        let reopenedFirst = app.staticTexts["EDITED First item"]
        XCTAssertTrue(reopenedFirst.waitForExistence(timeout: 10), "Edited first item should re-render after reload")
        let reopenedThird = app.staticTexts["Third item"]
        XCTAssertTrue(reopenedThird.waitForExistence(timeout: 10), "Third item should re-render after reload")
        let reopenedNestedFirst = app.staticTexts["Nested first"]
        XCTAssertTrue(reopenedNestedFirst.waitForExistence(timeout: 10), "Nested list's first item should re-render after reload")
        let reopenedNestedSecond = app.staticTexts["Nested second"]
        XCTAssertTrue(reopenedNestedSecond.waitForExistence(timeout: 10), "Nested list's second item should re-render after reload")

        let postReopenAttachment = XCTAttachment(screenshot: app.screenshot())
        postReopenAttachment.name = "two-level-nested-list-after-reopen"
        postReopenAttachment.lifetime = .keepAlways
        add(postReopenAttachment)
    }

    // MARK: - Case 2: three-level nesting (list inside list inside item 3's sub-list)

    func testThreeLevelNestedListSurvivesUnrelatedEdit() throws {
        try Self.doctorFixture(at: TestFixtureHelper.fixturePath, appendix: Self.threeLevelAppendixMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear with the doctored fixture's content")

        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS is ready)")

        Thread.sleep(forTimeInterval: 1.5)

        let baselineAllBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[NestedListE2ETests] DIAGNOSTIC all blocks at baseline (3-level):\n\(baselineAllBlocks.joined(separator: "\n---\n"))")
        let baselineFragments = try Self.queryBlockMarkdownFragments(fixturePath: TestFixtureHelper.fixturePath, blockType: "ordered_list")
        XCTAssertEqual(
            baselineFragments.count, 1,
            "BUG (test setup, not product): seeded content should parse into exactly one ordered_list block on load. Got: \(baselineFragments). All blocks: \(baselineAllBlocks)"
        )

        let baselineAttachment = XCTAttachment(screenshot: app.screenshot())
        baselineAttachment.name = "three-level-nested-list-initial-render"
        baselineAttachment.lifetime = .keepAlways
        add(baselineAttachment)

        // Unrelated edit elsewhere in the SAME block, same as case 1.
        let firstItemText = app.staticTexts["First item"]
        XCTAssertTrue(firstItemText.waitForExistence(timeout: 10), "'First item' list item should be visible and reachable via accessibility")
        let startOfFirstItem = firstItemText.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        startOfFirstItem.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeText("EDITED ")

        let postEditAttachment = XCTAttachment(screenshot: app.screenshot())
        postEditAttachment.name = "three-level-nested-list-after-edit"
        postEditAttachment.lifetime = .keepAlways
        add(postEditAttachment)

        // NO Source Mode toggle -- see file header. Wait for the JS debounce
        // + Swift poll cycle instead, same as case 1.
        Thread.sleep(forTimeInterval: 4.0)

        let allBlocks = try Self.queryAllBlocks(fixturePath: TestFixtureHelper.fixturePath)
        print("[NestedListE2ETests] DIAGNOSTIC all blocks after edit (3-level):\n\(allBlocks.joined(separator: "\n---\n"))")

        let fragments = try Self.queryBlockMarkdownFragments(
            fixturePath: TestFixtureHelper.fixturePath,
            blockType: "ordered_list"
        )

        XCTAssertEqual(
            fragments.count, 1,
            "Expected exactly one ordered_list block (all three nesting levels must stay embedded in the SAME block). Got: \(fragments). All blocks: \(allBlocks)"
        )
        guard let fragment = fragments.first else { return }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(trimmed.contains("EDITED First item"), "Unrelated edit to item 1 should be present. Got: \(trimmed)")
        XCTAssertTrue(trimmed.contains("3. Third item"), "Item 3 should keep its own marker. Got: \(trimmed)")

        // Depth-2 markers, indented 3 spaces (item 3's "3. " marker width).
        XCTAssertTrue(
            trimmed.contains("\n   1. Nested first"),
            "BUG: depth-2 nested list's first item should be indented 3 spaces. Got: \(trimmed). All blocks: \(allBlocks)"
        )
        XCTAssertTrue(
            trimmed.contains("\n   2. Nested second"),
            "BUG: depth-2 nested list's second item should be indented 3 spaces. Got: \(trimmed). All blocks: \(allBlocks)"
        )

        // Depth-3 markers, indented 6 spaces (3 for item 3's marker + 3 more
        // for "Nested second"'s own "2. " marker) -- this is the
        // depth-dependent case a naive one-level-only fix could still miss.
        XCTAssertTrue(
            trimmed.contains("\n      1. Deep first"),
            "BUG: depth-3 nested list's first item should be indented 6 spaces (cumulative indentation across two nesting levels). Got: \(trimmed). All blocks: \(allBlocks)"
        )
        XCTAssertTrue(
            trimmed.contains("\n      2. Deep second"),
            "BUG: depth-3 nested list's second item should be indented 6 spaces, continuing its own numbering. Got: \(trimmed). All blocks: \(allBlocks)"
        )

        // Relaunch against the same mutated fixture and confirm the full
        // 3-level structure re-renders correctly in WYSIWYG.
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorAreaAfterReopen = app.groups["editor-area"]
        XCTAssertTrue(editorAreaAfterReopen.waitForExistence(timeout: 10), "Editor area should reappear after relaunch")

        for text in ["EDITED First item", "Third item", "Nested first", "Nested second", "Deep first", "Deep second"] {
            let element = app.staticTexts[text]
            XCTAssertTrue(element.waitForExistence(timeout: 10), "'\(text)' should re-render after reload")
        }

        let postReopenAttachment = XCTAttachment(screenshot: app.screenshot())
        postReopenAttachment.name = "three-level-nested-list-after-reopen"
        postReopenAttachment.lifetime = .keepAlways
        add(postReopenAttachment)
    }

    // MARK: - Fixture doctoring

    /// Appends `appendix` to the fixture copy's `content.markdown` via
    /// `FixtureDatabase.seedMarkdown`. Must run BEFORE `app.launch()` --
    /// mirrors E2EAsyncImageCorruptionTests.swift's `doctorFixture()` exactly
    /// (same ordering requirement, same underlying helper).
    private static func doctorFixture(at fixturePath: String, appendix: String) throws {
        FixtureDatabase.seedMarkdown(fixturePath: fixturePath, markdown: appendix, appending: true)
        print("[NestedListE2ETests] Doctored fixture content.markdown at: \(fixturePath)")
    }

    // MARK: - DB query helpers

    /// Reads `markdownFragment` for every `block` row of the given `blockType`
    /// directly from the fixture's on-disk SQLite database. Copied verbatim
    /// from ListNumberingE2ETests.swift's helper of the same name/behavior.
    private static func queryBlockMarkdownFragments(fixturePath: String, blockType: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT markdownFragment || '\(sentinel)' FROM block WHERE blockType = '\(blockType)' ORDER BY sortOrder;"

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
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            XCTFail("sqlite3 query failed (status \(process.terminationStatus)): \(stderr)")
        }

        return stdout
            .components(separatedBy: "\(sentinel)\n")
            .filter { !$0.isEmpty }
    }

    /// Diagnostic helper: dumps `blockType` + `markdownFragment` for every
    /// row, in document order. Copied verbatim from ListNumberingE2ETests.swift.
    private static func queryAllBlocks(fixturePath: String) throws -> [String] {
        let dbPath = fixturePath + "/content.sqlite"
        let sentinel = "###ROWEND###"
        let sql = "SELECT blockType || ': ' || markdownFragment || '\(sentinel)' FROM block ORDER BY sortOrder;"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

        return stdout
            .components(separatedBy: "\(sentinel)\n")
            .filter { !$0.isEmpty }
    }
}
